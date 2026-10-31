using System.Globalization;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Model.Entities;
using Inventory_Shipment.Model.Enums;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Excel;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Logging;
using static Inventory_Shipment.Service.Implementations.LogisticsRuleFailures;

namespace Inventory_Shipment.Service.Implementations;

/// <summary>
/// Container charges from an Excel file: one row = one charge on one container.
///
/// THE RULES OF A CHARGE STAY IN THE PROCEDURES. The import creates every row with usp_ContainerCharge_Create
/// — the call of the charge dialog for one container, split rule Same — and posts it with _Post, so a charge
/// imported is exactly a charge typed. The validation here only looks things up (containers by number or
/// ref, charge types, currencies, suppliers, the rate of the date) so the preview can say what each row will
/// do before anything is created; whatever it cannot know (a container closed in between) the procedure
/// still refuses, row by row.
///
/// THE ROWS OF ONE PROVIDER INVOICE SHARE A CHARGE GROUP, so the invoice is attached once. A group of
/// different amounts is not something _Create makes (it splits one total), but _CopyToContainers is: the
/// first row is created, every other row of the group is a copy of it with its own amount, date and
/// allocation — the "Apply to other containers" of the charge page. A copy takes the original's type,
/// provider, reference, currency, rate and notes, so those (with the date) are the group's key.
///
/// EACH ROW ON ITS OWN, like the person would type them: a row refused at creation or at posting is reported
/// with its reason, and the rows after it are still created.
/// </summary>
public sealed class ContainerChargeImportService : IContainerChargeImportService
{
    private const string InvalidFileCode = "INVALID_FILE";

    /// <summary>The procedures' DECIMAL(18,2).</summary>
    private const decimal MaxAmount = 9999999999999999.99m;

    private const int ReferenceMaxLength = 100;
    private const int NotesMaxLength = 300;

    /// <summary>usp_Party_Lookup's ceiling; the exact match is made here among what it returns.</summary>
    private const int PartyLookupTop = 500;

    /// <summary>The methods a file may name. Manual is typed line by line on a charge, never imported.</summary>
    private static readonly string[] ImportMethods =
        [ChargeAllocationMethods.Value, ChargeAllocationMethods.Quantity, ChargeAllocationMethods.Weight, ChargeAllocationMethods.Volume];

    private static readonly CultureInfo Invariant = CultureInfo.InvariantCulture;

    private readonly IContainerChargeRepository _charges;
    private readonly IChargeTypeRepository _chargeTypes;
    private readonly ICurrencyRepository _currencies;
    private readonly IPartyRepository _parties;
    private readonly IExchangeRateRepository _rates;
    private readonly ContainerChargeImportParser _parser;
    private readonly ContainerChargeImportWorkbooks _workbooks;
    private readonly TimeProvider _clock;
    private readonly ILogger<ContainerChargeImportService> _logger;

    public ContainerChargeImportService(
        IContainerChargeRepository charges,
        IChargeTypeRepository chargeTypes,
        ICurrencyRepository currencies,
        IPartyRepository parties,
        IExchangeRateRepository rates,
        ContainerChargeImportParser parser,
        ContainerChargeImportWorkbooks workbooks,
        TimeProvider clock,
        ILogger<ContainerChargeImportService> logger)
    {
        _charges = charges;
        _chargeTypes = chargeTypes;
        _currencies = currencies;
        _parties = parties;
        _rates = rates;
        _parser = parser;
        _workbooks = workbooks;
        _clock = clock;
        _logger = logger;
    }

    /* ── template and error report ────────────────────────────────────────────────────────────── */

    public async Task<Result<(byte[] Content, string FileName)>> GenerateTemplateAsync(
        IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.ChargesCreate))
        {
            return Forbidden<(byte[], string)>(Permissions.Containers.ChargesCreate);
        }

        var types = await _chargeTypes.LookupAsync(activeOnly: true, cancellationToken: cancellationToken);
        var currencies = await _currencies.LookupAsync(activeOnly: true, includeId: null, cancellationToken);

        return Result<(byte[], string)>.Success(
            (_workbooks.GenerateTemplate(types, currencies, ServerToday()), ContainerChargeImportWorkbooks.TemplateFileName));
    }

    public Result<(byte[] Content, string FileName)> GenerateErrorReport(
        IReadOnlyList<ContainerChargeImportValidatedRow> rows, IReadOnlySet<string> permissions)
    {
        if (!permissions.Contains(Permissions.Containers.ChargesCreate))
        {
            return Forbidden<(byte[], string)>(Permissions.Containers.ChargesCreate);
        }

        return Result<(byte[], string)>.Success(
            (_workbooks.GenerateErrorReport(rows ?? []), ContainerChargeImportWorkbooks.ErrorReportFileName));
    }

    /* ── validation ───────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<ContainerChargeImportValidation>> ValidateAsync(
        Stream file, string fileName, long fileLength, DateOnly? today, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.ChargesCreate))
        {
            return Forbidden<ContainerChargeImportValidation>(Permissions.Containers.ChargesCreate);
        }

        if (fileLength <= 0)
        {
            return Invalid("The file is empty.");
        }

        if (fileLength > ContainerChargeImportParser.MaxFileBytes)
        {
            return Invalid($"The file is larger than {ContainerChargeImportParser.MaxFileBytes / (1024 * 1024)} MB.");
        }

        if (!fileName.EndsWith(".xlsx", StringComparison.OrdinalIgnoreCase))
        {
            return Invalid("Only .xlsx files can be imported. Save the file as an Excel workbook and try again.");
        }

        IReadOnlyList<ContainerChargeImportRow> rows;
        try
        {
            rows = _parser.Parse(file);
        }
        catch (ContainerChargeImportFileException ex)
        {
            // The parser's own sentence: it is written for the person holding the file.
            return Invalid(ex.Message);
        }

        if (rows.Count == 0)
        {
            return Invalid("The file has no rows to import.");
        }

        var date = EffectiveToday(today);
        var lookups = await LoadLookupsAsync(rows, date, cancellationToken);
        var verdicts = rows.Select(r => Judge(r, lookups, date)).ToList();

        WarnDuplicates(verdicts);
        await RefuseReferenceClashesAsync(verdicts, cancellationToken);

        foreach (var verdict in verdicts)
        {
            verdict.Close();
        }

        var judged = verdicts.Select(v => v.Row).ToList();
        foreach (var group in Batches(judged.Where(r => r.Status != ContainerChargeImportStatus.Error)).Where(b => b.Count > 1))
        {
            foreach (var member in group)
            {
                member.GroupRowNumber = group[0].RowNumber;
            }
        }

        var result = new ContainerChargeImportValidation
        {
            FileName = fileName,
            TotalRows = judged.Count,
            ValidRows = judged.Count(r => r.Status == ContainerChargeImportStatus.Valid),
            WarningRows = judged.Count(r => r.Status == ContainerChargeImportStatus.Warning),
            ErrorRows = judged.Count(r => r.Status == ContainerChargeImportStatus.Error),
            BaseCurrencyCode = lookups.BaseCurrency?.CurrencyCode,
            Rows = judged,
        };

        _logger.LogInformation(
            "Container charge import validated {FileName}: {Total} rows, {Valid} valid, {Warning} warning, {Error} error.",
            fileName, result.TotalRows, result.ValidRows, result.WarningRows, result.ErrorRows);

        return Result<ContainerChargeImportValidation>.Success(result);
    }

    /// <summary>Everything the rows name, read once for the whole file.</summary>
    private sealed class Lookups
    {
        public required IReadOnlyList<ChargeTypeLookupDto> ChargeTypes { get; init; }
        public required IReadOnlyList<CurrencyLookup> Currencies { get; init; }
        public CurrencyLookup? BaseCurrency { get; init; }
        public required Dictionary<string, List<ContainerChargeImportContainer>> ByNumber { get; init; }
        public required Dictionary<string, List<ContainerChargeImportContainer>> ByRef { get; init; }
        public required ILookup<int, ContainerChargeImportExistingCharge> ChargesByContainer { get; init; }

        /// <summary>By the text as typed, upper case: a supplier, or the sentence saying why there is none.</summary>
        public required Dictionary<string, (PartyLookup? Party, string? Error)> Providers { get; init; }

        /// <summary>The official rate per currency and date; null when none is entered for that date.</summary>
        public required Dictionary<(int CurrencyId, DateOnly Date), decimal?> Rates { get; init; }
    }

    private async Task<Lookups> LoadLookupsAsync(
        IReadOnlyList<ContainerChargeImportRow> rows, DateOnly today, CancellationToken cancellationToken)
    {
        // Inactive ones too: "inactive" is a better answer than "unknown" for a code that exists.
        var types = await _chargeTypes.LookupAsync(activeOnly: false, cancellationToken: cancellationToken);
        var currencies = await _currencies.LookupAsync(activeOnly: false, includeId: null, cancellationToken);
        var baseCurrency = currencies.FirstOrDefault(c => c.IsBaseCurrency && c.IsActive);

        var keys = rows
            .Select(r => ContainerKey(r.Container))
            .Where(k => k.Length is > 0 and <= 100)
            .ToHashSet(StringComparer.Ordinal);
        var (containers, charges) = await _charges.FindImportContainersAsync(keys, cancellationToken);

        var providers = new Dictionary<string, (PartyLookup?, string?)>(StringComparer.Ordinal);
        foreach (var text in rows.Select(r => r.Provider?.Trim()).Where(p => !string.IsNullOrEmpty(p)).Distinct(StringComparer.OrdinalIgnoreCase))
        {
            providers[text!.ToUpperInvariant()] = await FindProviderAsync(text!, cancellationToken);
        }

        // The rate of each currency and date a row leaves to the import, as the charge dialog looks it up.
        var rates = new Dictionary<(int, DateOnly), decimal?>();
        foreach (var row in rows.Where(r => r.ExchangeRate is null && r.RawExchangeRate is null && r.RawChargeDate is null))
        {
            var currency = FindCurrency(currencies, row.Currency);
            if (currency is null || !currency.IsActive || currency.IsBaseCurrency)
            {
                continue;
            }

            var key = (currency.Id, row.ChargeDate ?? today);
            if (!rates.ContainsKey(key))
            {
                var latest = await _rates.GetLatestAsync(currency.Id, key.Item2, cancellationToken);
                rates[key] = latest.FirstOrDefault(r => r.RateType == RateType.Official)?.Rate;
            }
        }

        return new Lookups
        {
            ChargeTypes = types,
            Currencies = currencies,
            BaseCurrency = baseCurrency,
            ByNumber = containers.Where(c => c.NumberKey.Length > 0)
                .GroupBy(c => c.NumberKey, StringComparer.Ordinal).ToDictionary(g => g.Key, g => g.ToList(), StringComparer.Ordinal),
            ByRef = containers.Where(c => c.RefKey.Length > 0)
                .GroupBy(c => c.RefKey, StringComparer.Ordinal).ToDictionary(g => g.Key, g => g.ToList(), StringComparer.Ordinal),
            ChargesByContainer = charges.ToLookup(c => c.ContainerId),
            Providers = providers,
            Rates = rates,
        };
    }

    /// <summary>
    /// A supplier by code, then by name — the charge dialog offers suppliers only. A party that exists but is
    /// not a supplier gets its own sentence, since "unknown" would send the person looking for a typo.
    /// </summary>
    private async Task<(PartyLookup? Party, string? Error)> FindProviderAsync(string text, CancellationToken cancellationToken)
    {
        var suppliers = await _parties.LookupAsync(PartyType.Supplier, text, activeOnly: false, includeId: null, PartyLookupTop, cancellationToken);
        var match = PickParty(suppliers, text, out var ambiguous);

        if (ambiguous is not null)
        {
            return (null, $"Several suppliers are named '{text}' ({ambiguous}): type the supplier's code.");
        }

        if (match is not null)
        {
            return match.IsActive ? (match, null) : (null, $"Provider {match.PartyCode} - {match.PartyName} is inactive.");
        }

        var others = await _parties.LookupAsync(null, text, activeOnly: false, includeId: null, PartyLookupTop, cancellationToken);
        var other = PickParty(others, text, out _);
        return other is not null
            ? (null, $"{other.PartyCode} - {other.PartyName} is not a supplier: tick Supplier on the party in Master Data › Parties, or leave Provider blank.")
            : (null, $"Unknown provider '{text}'. Type the code or the name of a supplier (Master Data › Parties).");
    }

    private static PartyLookup? PickParty(IReadOnlyList<PartyLookup> parties, string text, out string? ambiguous)
    {
        ambiguous = null;
        var byCode = parties.FirstOrDefault(p => string.Equals(p.PartyCode.Trim(), text, StringComparison.OrdinalIgnoreCase));
        if (byCode is not null)
        {
            return byCode;
        }

        var byName = parties.Where(p => string.Equals(p.PartyName.Trim(), text, StringComparison.OrdinalIgnoreCase)).ToList();
        if (byName.Count <= 1)
        {
            return byName.FirstOrDefault();
        }

        // Two parties of one name: the active one is meant, when there is exactly one.
        var active = byName.Where(p => p.IsActive).ToList();
        if (active.Count == 1)
        {
            return active[0];
        }

        ambiguous = string.Join(", ", byName.Select(p => p.PartyCode).Order(StringComparer.OrdinalIgnoreCase));
        return null;
    }

    /// <summary>A row being judged: its errors and its warnings, until <see cref="Close"/> writes the verdict.</summary>
    private sealed class Verdict(ContainerChargeImportValidatedRow row)
    {
        public ContainerChargeImportValidatedRow Row { get; } = row;
        public List<string> Errors { get; } = [];
        public List<string> Warnings { get; } = [];

        /// <summary>An Error row says only what is wrong; a Warning row what to look at.</summary>
        public void Close()
        {
            Row.Status = Errors.Count > 0 ? ContainerChargeImportStatus.Error
                : Warnings.Count > 0 ? ContainerChargeImportStatus.Warning
                : ContainerChargeImportStatus.Valid;
            var lines = Errors.Count > 0 ? Errors : Warnings;
            Row.Message = lines.Count > 0 ? string.Join(" ", lines) : null;
        }
    }

    private static Verdict Judge(ContainerChargeImportRow row, Lookups lookups, DateOnly today)
    {
        var verdict = new Verdict(new ContainerChargeImportValidatedRow
        {
            RowNumber = row.RowNumber,
            ContainerInput = row.Container,
            ChargeTypeInput = row.ChargeType,
            RawAmount = row.RawAmount,
            CurrencyInput = row.Currency,
            RawChargeDate = row.RawChargeDate,
            RawExchangeRate = row.RawExchangeRate,
            ProviderInput = row.Provider,
            Reference = row.ProviderInvoiceNo,
            AllocationInput = row.Allocation,
            Notes = row.Notes,
        });
        var v = verdict.Row;
        var errors = verdict.Errors;

        if (row.Notes?.StartsWith(ContainerChargeImportWorkbooks.ExampleMarker, StringComparison.OrdinalIgnoreCase) == true)
        {
            errors.Add("This is an example row of the template: delete it before importing.");
        }

        var container = JudgeContainer(row, lookups, verdict);
        var type = JudgeChargeType(row, lookups, verdict);
        JudgeAmount(row, verdict);
        var currency = JudgeCurrency(row, lookups, verdict);

        // Charge Date: blank = today.
        if (row.RawChargeDate is not null)
        {
            errors.Add($"Charge Date '{row.RawChargeDate}' is not a date. Type it as dd/MM/yyyy.");
        }
        else
        {
            v.ChargeDate = row.ChargeDate ?? today;
            v.ChargeDateDefaulted = row.ChargeDate is null;
        }

        JudgeRate(row, lookups, currency, verdict);

        if (v.Amount is { } amount and > 0 && v.ExchangeRate is { } rate and > 0)
        {
            v.AmountBase = Math.Round(amount / rate, 2, MidpointRounding.AwayFromZero);
        }

        // Provider: blank = none.
        if (!string.IsNullOrWhiteSpace(row.Provider))
        {
            var (party, error) = lookups.Providers[row.Provider.Trim().ToUpperInvariant()];
            if (party is null)
            {
                errors.Add(error!);
            }
            else
            {
                v.ProviderPartyId = party.Id;
                v.ProviderCode = party.PartyCode;
                v.ProviderName = party.PartyName;
            }
        }

        if (row.ProviderInvoiceNo?.Length > ReferenceMaxLength)
        {
            errors.Add($"Provider Invoice No. is longer than {ReferenceMaxLength} characters.");
        }

        if (row.Notes?.Length > NotesMaxLength)
        {
            errors.Add($"Notes are longer than {NotesMaxLength} characters.");
        }

        JudgeAllocation(row, type, verdict);

        if (container is not null && type is not null && v.ContainerId is not null)
        {
            WarnAboutContainer(container, type, lookups, verdict);
        }

        return verdict;
    }

    /// <summary>
    /// The container number first, then the ref, compared as the movement import does
    /// (usp_Movement_MatchContainers): one container not yet offloaded wins over the others, two not yet
    /// offloaded are ambiguous, and among the others the latest one is taken. Here an offloaded one also wins
    /// over a closed one, and a closed one over a cancelled one: neither takes a charge.
    ///
    /// A BOX NUMBER COMES BACK YEAR AFTER YEAR, and late charges go on offloaded containers, so two offloaded
    /// containers with one number are not refused. The row is not silent about it either: a charge that may be
    /// for the other container would move the wrong costs, so the row warns, names the others and says to type
    /// the ref to choose.
    /// </summary>
    private static ContainerChargeImportContainer? JudgeContainer(ContainerChargeImportRow row, Lookups lookups, Verdict verdict)
    {
        if (string.IsNullOrWhiteSpace(row.Container))
        {
            verdict.Errors.Add("Container is required.");
            return null;
        }

        var key = ContainerKey(row.Container);
        var hits = lookups.ByNumber.GetValueOrDefault(key) ?? lookups.ByRef.GetValueOrDefault(key);
        if (hits is null or { Count: 0 })
        {
            verdict.Errors.Add($"No container with the number or ref '{row.Container}'. The number may not be typed on its container yet.");
            return null;
        }

        var best = hits.Min(c => Rank(c.Status));
        var candidates = hits.Where(c => Rank(c.Status) == best).OrderByDescending(c => c.ContainerId).ToList();
        if (best == 0 && candidates.Count > 1)
        {
            var refs = string.Join(", ", candidates.Select(c => c.ContainerRef).Order(StringComparer.OrdinalIgnoreCase));
            verdict.Errors.Add($"'{row.Container}' is on {candidates.Count} containers not yet offloaded ({refs}): type the container ref instead.");
            return null;
        }

        var container = candidates[0];
        var others = hits.Where(c => c.ContainerId != container.ContainerId).OrderByDescending(c => c.ContainerId).ToList();
        if (others.Count > 0)
        {
            // Only a Warning row says it: on an Error row (a closed container) the error is the message.
            const int shown = 3;
            var named = string.Join(", ", others.Take(shown).Select(c => $"{c.ContainerRef} ({ContainerStatus.Name(c.Status).ToLowerInvariant()})"))
                        + (others.Count > shown ? $" and {others.Count - shown} more" : string.Empty);
            verdict.Warnings.Add($"'{row.Container}' is also the number of {named}: the charge goes on {container.ContainerRef}. "
                                 + "Type the container ref if it is for another one.");
        }

        var v = verdict.Row;
        v.ContainerRef = container.ContainerRef;
        v.ContainerNo = container.ContainerNo;
        v.ContainerStatus = container.Status;
        v.ContainerStatusName = ContainerStatus.Name(container.Status);

        switch (container.Status)
        {
            case ContainerStatus.Closed:
                verdict.Errors.Add($"Container {container.ContainerRef} is closed: reopen it to add a late charge.");
                return null;
            case ContainerStatus.Cancelled:
                verdict.Errors.Add($"Container {container.ContainerRef} is cancelled.");
                return null;
            default:
                v.ContainerId = container.ContainerId;
                return container;
        }

        // A closed container before a cancelled one: "reopen it" is something the person can do.
        static int Rank(byte status) => status switch
        {
            < ContainerStatus.Offloaded => 0,
            ContainerStatus.Offloaded => 1,
            ContainerStatus.Closed => 2,
            _ => 3,
        };
    }

    /// <summary>The code, then the name. An inactive type is named as such rather than "unknown".</summary>
    private static ChargeTypeLookupDto? JudgeChargeType(ContainerChargeImportRow row, Lookups lookups, Verdict verdict)
    {
        if (string.IsNullOrWhiteSpace(row.ChargeType))
        {
            verdict.Errors.Add("Charge Type is required.");
            return null;
        }

        var text = row.ChargeType.Trim();
        var type = Best(lookups.ChargeTypes.Where(t => string.Equals(t.ChargeCode.Trim(), text, StringComparison.OrdinalIgnoreCase)))
                   ?? Best(lookups.ChargeTypes.Where(t => string.Equals(t.ChargeName.Trim(), text, StringComparison.OrdinalIgnoreCase)));

        if (type is null)
        {
            verdict.Errors.Add($"Unknown charge type '{text}'. Use a code or a name of the Lists sheet (Purchase › Charge Types).");
            return null;
        }

        if (!type.IsActive)
        {
            verdict.Errors.Add($"Charge type {type.ChargeCode} - {type.ChargeName} is inactive.");
            return null;
        }

        // (97) A BIVAC charge names its BIVAC item and takes that item's cost at each container's port: typed with
        // Add charge…, never imported.
        if (string.Equals(type.ChargeCode.Trim(), "BIV", StringComparison.OrdinalIgnoreCase))
        {
            verdict.Errors.Add("A BIVAC charge is entered with Add charge…: it names the BIVAC item and takes its cost at each "
                               + "container's port (Item Definition › BIVAC cost per port).");
            return null;
        }

        var v = verdict.Row;
        v.ChargeTypeId = type.Id;
        v.ChargeCode = type.ChargeCode;
        v.ChargeName = type.ChargeName;
        v.IncludeInLandedCost = type.IncludeInLandedCost;
        return type;

        static ChargeTypeLookupDto? Best(IEnumerable<ChargeTypeLookupDto> found)
            => found.OrderByDescending(t => t.IsActive).FirstOrDefault();
    }

    /// <summary>Greater than zero, to the cent: a figure with more decimals is rounded, and the row says so.</summary>
    private static void JudgeAmount(ContainerChargeImportRow row, Verdict verdict)
    {
        if (row.RawAmount is not null)
        {
            verdict.Errors.Add(NotANumber(ContainerChargeImportParser.ColumnAmount, row.RawAmount));
            return;
        }

        if (row.Amount is not { } typed)
        {
            verdict.Errors.Add("Amount is required.");
            return;
        }

        // Six decimals first: a double read from Excel carries noise far below the cent (2100.0000000001).
        var precise = Math.Round(typed, 6, MidpointRounding.AwayFromZero);
        var amount = Math.Round(typed, 2, MidpointRounding.AwayFromZero);

        // Kept on an Error row too, so the preview and the error report show what was typed.
        verdict.Row.Amount = amount;
        if (amount <= 0)
        {
            verdict.Errors.Add("Amount must be greater than zero.");
            return;
        }

        if (amount > MaxAmount)
        {
            verdict.Errors.Add("Amount is too large.");
            return;
        }

        if (precise != amount)
        {
            verdict.Warnings.Add($"Amount {precise.ToString("0.######", Invariant)} rounded to {amount.ToString("N2", Invariant)}.");
        }
    }

    /// <summary>
    /// "… is not a number", and how to write it when the text holds a comma: the parser takes a comma only
    /// between thousands, so 2100,50 (a decimal comma) lands here rather than as 210050.
    /// </summary>
    private static string NotANumber(string column, string raw) => raw.Contains(',', StringComparison.Ordinal)
        ? $"{column} '{raw}' is not a number: use a point for the decimals and commas only between thousands (2,100.50), "
          + "or format the cell as a number."
        : $"{column} '{raw}' is not a number.";

    /// <summary>The code (or the name); blank = the base currency.</summary>
    private static CurrencyLookup? JudgeCurrency(ContainerChargeImportRow row, Lookups lookups, Verdict verdict)
    {
        CurrencyLookup? currency;
        if (string.IsNullOrWhiteSpace(row.Currency))
        {
            currency = lookups.BaseCurrency;
            if (currency is null)
            {
                verdict.Errors.Add("No active base currency is set: set one in Master Data › Currencies.");
                return null;
            }
        }
        else
        {
            currency = FindCurrency(lookups.Currencies, row.Currency);
            if (currency is null)
            {
                verdict.Errors.Add($"Unknown currency '{row.Currency.Trim()}'. Use a code of the Lists sheet (Master Data › Currencies).");
                return null;
            }

            if (!currency.IsActive)
            {
                verdict.Errors.Add($"Currency {currency.CurrencyCode} is inactive.");
                return null;
            }
        }

        var v = verdict.Row;
        v.CurrencyId = currency.Id;
        v.CurrencyCode = currency.CurrencyCode;
        v.IsBaseCurrency = currency.IsBaseCurrency;
        return currency;
    }

    private static CurrencyLookup? FindCurrency(IReadOnlyList<CurrencyLookup> currencies, string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return currencies.FirstOrDefault(c => c.IsBaseCurrency && c.IsActive);
        }

        var trimmed = text.Trim();
        return currencies.Where(c => string.Equals(c.CurrencyCode.Trim(), trimmed, StringComparison.OrdinalIgnoreCase))
                   .OrderByDescending(c => c.IsActive).FirstOrDefault()
               ?? currencies.Where(c => string.Equals(c.CurrencyName.Trim(), trimmed, StringComparison.OrdinalIgnoreCase))
                   .OrderByDescending(c => c.IsActive).FirstOrDefault();
    }

    /// <summary>
    /// The rate typed, else the official rate of the charge date — what the charge dialog proposes. The base
    /// currency is always 1. A row without a rate is refused, in the procedure's words.
    /// </summary>
    private static void JudgeRate(ContainerChargeImportRow row, Lookups lookups, CurrencyLookup? currency, Verdict verdict)
    {
        var v = verdict.Row;
        if (row.RawExchangeRate is not null)
        {
            verdict.Errors.Add(NotANumber(ContainerChargeImportParser.ColumnExchangeRate, row.RawExchangeRate));
            return;
        }

        v.ExchangeRateLookedUp = row.ExchangeRate is null;
        if (currency is null)
        {
            return;
        }

        if (currency.IsBaseCurrency)
        {
            v.ExchangeRate = 1m;
            if (row.ExchangeRate is { } typedForBase && typedForBase != 1m)
            {
                verdict.Warnings.Add($"{currency.CurrencyCode} is the base currency: its rate is always 1, the Exchange Rate typed is ignored.");
            }

            return;
        }

        if (row.ExchangeRate is { } typed)
        {
            // Kept on an Error row too, like the amount.
            v.ExchangeRate = Math.Round(typed, 6, MidpointRounding.AwayFromZero);
            if (v.ExchangeRate <= 0)
            {
                verdict.Errors.Add("Exchange Rate must be greater than zero.");
            }

            return;
        }

        if (v.ChargeDate is not { } date)
        {
            return;
        }

        if (lookups.Rates.GetValueOrDefault((currency.Id, date)) is { } found and > 0)
        {
            v.ExchangeRate = found;
            return;
        }

        verdict.Errors.Add($"No exchange rate for {currency.CurrencyCode} on {date.ToString("dd/MM/yyyy", Invariant)}. "
                           + "Add one in Master Data › Exchange Rates, or type the rate in the Exchange Rate column.");
    }

    /// <summary>
    /// The method typed (Manual refused), else the charge type's. A type allocated manually by default cannot
    /// be imported as it is when it enters the cost; one that does not enter the cost takes Value, which
    /// moves nothing — as a copy of a manual charge does.
    /// </summary>
    private static void JudgeAllocation(ContainerChargeImportRow row, ChargeTypeLookupDto? type, Verdict verdict)
    {
        var v = verdict.Row;
        if (!string.IsNullOrWhiteSpace(row.Allocation))
        {
            var text = row.Allocation.Trim();
            if (string.Equals(text, ChargeAllocationMethods.Manual, StringComparison.OrdinalIgnoreCase))
            {
                verdict.Errors.Add("Manual allocation is not possible in an import: choose Value, Quantity, Weight or Volume, "
                                   + "and change the allocation on the charge afterwards.");
                return;
            }

            var method = ImportMethods.FirstOrDefault(m => string.Equals(m, text, StringComparison.OrdinalIgnoreCase));
            if (method is null)
            {
                verdict.Errors.Add($"Allocation '{text}' must be Value, Quantity, Weight or Volume (blank = the charge type's).");
                return;
            }

            v.AllocationMethod = method;
            return;
        }

        v.AllocationDefaulted = true;
        if (type is null)
        {
            return;
        }

        var typeMethod = ImportMethods.FirstOrDefault(m => string.Equals(m, type.AllocationMethod, StringComparison.OrdinalIgnoreCase));
        if (typeMethod is not null)
        {
            v.AllocationMethod = typeMethod;
        }
        else if (type.IncludeInLandedCost)
        {
            verdict.Errors.Add($"Charge type {type.ChargeCode} is allocated manually by default, which an import cannot do: "
                               + "type Value, Quantity, Weight or Volume in the Allocation column.");
        }
        else
        {
            v.AllocationMethod = ChargeAllocationMethods.Value;
        }
    }

    /// <summary>
    /// What the procedures accept but the person should know: a charge that cannot be posted yet (no items, an
    /// item without weight or volume — _Post refuses it, _Create does not), a late charge, the same charge twice.
    /// A container with one line takes the whole charge whatever the method (script 88): no weight or volume is
    /// needed for it, so only a container of several lines is warned about.
    /// </summary>
    private static void WarnAboutContainer(
        ContainerChargeImportContainer container, ChargeTypeLookupDto type, Lookups lookups, Verdict verdict)
    {
        var v = verdict.Row;
        var warnings = verdict.Warnings;

        if (type.IncludeInLandedCost)
        {
            if (container.LineCount == 0)
            {
                warnings.Add($"Container {container.ContainerRef} has no items yet: the charge can be created as a draft, "
                             + "but not posted until it has some.");
            }
            else if (container.LineCount > 1 && v.AllocationMethod == ChargeAllocationMethods.Weight && container.ItemWithoutWeight is not null)
            {
                warnings.Add($"Item {container.ItemWithoutWeight} on {container.ContainerRef} has no weight (kg): the charge can be created as a draft, "
                             + "but not posted until the weight is set in Item Definition (or the allocation changed).");
            }
            else if (container.LineCount > 1 && v.AllocationMethod == ChargeAllocationMethods.Volume && container.ItemWithoutVolume is not null)
            {
                warnings.Add($"Item {container.ItemWithoutVolume} on {container.ContainerRef} has no volume (CBM): the charge can be created as a draft, "
                             + "but not posted until the volume is set in Item Definition (or the allocation changed).");
            }

            if (container.Status == ContainerStatus.Offloaded)
            {
                warnings.Add($"Container {container.ContainerRef} is offloaded: posting this charge adjusts the cost of its items (a late charge).");
            }
        }

        if (v.Amount is not { } amount || v.CurrencyId is not { } currencyId || v.ChargeDate is not { } date)
        {
            return;
        }

        var same = lookups.ChargesByContainer[container.ContainerId].FirstOrDefault(c =>
            c.ChargeTypeId == type.Id && c.Amount == amount && c.CurrencyId == currencyId
            && DateOnly.FromDateTime(c.ChargeDate) == date
            && string.Equals(c.Reference?.Trim() ?? string.Empty, v.Reference?.Trim() ?? string.Empty, StringComparison.OrdinalIgnoreCase));
        if (same is not null)
        {
            warnings.Add($"Container {container.ContainerRef} already has this charge ({type.ChargeCode} {amount.ToString("N2", Invariant)} "
                         + $"{v.CurrencyCode} of {date.ToString("dd/MM/yyyy", Invariant)}, {ContainerChargeStatus.Name(same.Status).ToLowerInvariant()}): "
                         + "importing adds it again.");
        }
    }

    /// <summary>Two rows of the file for the same charge are both imported: the second one says so.</summary>
    private static void WarnDuplicates(IReadOnlyList<Verdict> verdicts)
    {
        var first = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var verdict in verdicts.Where(x => x.Errors.Count == 0))
        {
            var v = verdict.Row;
            var key = string.Join('|', v.ContainerId, v.ChargeTypeId, v.Amount?.ToString("0.00", Invariant), v.CurrencyId,
                v.ChargeDate?.ToString("yyyy-MM-dd", Invariant), v.ProviderPartyId, Normalized(v.Reference));
            if (first.TryGetValue(key, out var rowNumber))
            {
                verdict.Warnings.Add($"Same charge as row {rowNumber}: both rows are imported.");
            }
            else
            {
                first.Add(key, v.RowNumber);
            }
        }
    }

    /// <summary>
    /// (96) A PROVIDER'S INVOICE IS ENTERED ONCE: a row whose Provider Invoice No. a charge already carries for the same
    /// provider (logistics.fn_ContainerCharge_ReferenceClash, the rule Create applies) is an Error with its sentence; so
    /// are rows of the file that share a provider and an invoice no. but cannot be one charge group (another charge type,
    /// date, currency, rate or notes, or the same container twice) - the second group would be refused at Create.
    /// </summary>
    private async Task RefuseReferenceClashesAsync(IReadOnlyList<Verdict> verdicts, CancellationToken cancellationToken)
    {
        var candidates = verdicts.Where(x => x.Errors.Count == 0 && !string.IsNullOrWhiteSpace(x.Row.Reference)).ToList();
        foreach (var invoice in candidates.GroupBy(x => (x.Row.ProviderPartyId, Normalized(x.Row.Reference))))
        {
            var reference = invoice.First().Row.Reference!.Trim();
            if (await _charges.ReferenceClashAsync(invoice.Key.ProviderPartyId, reference, cancellationToken) is { } clash)
            {
                foreach (var verdict in invoice)
                {
                    verdict.Errors.Add(clash);
                }

                continue;
            }

            var groups = Batches(invoice.Select(x => x.Row));
            if (groups.Count > 1)
            {
                var rows = string.Join(", ", invoice.Select(x => x.Row.RowNumber).OrderBy(n => n));
                foreach (var verdict in invoice)
                {
                    verdict.Errors.Add($"Rows {rows} have the Provider Invoice No. {reference} but are not one charge: the charge type, "
                                       + "date, currency, rate or notes differ, or a container is on two of them. A provider's invoice is "
                                       + "entered once - give its rows the same values, one row per container.");
                }
            }
        }
    }

    /* ── import ───────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<ContainerChargeImportResult>> ImportAsync(
        ContainerChargeImportRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.ChargesCreate))
        {
            return Forbidden<ContainerChargeImportResult>(Permissions.Containers.ChargesCreate);
        }

        // POSTING IS THE POST RIGHT, like posting any draft: refused here, before a single charge is created.
        if (request.Post && !permissions.Contains(Permissions.Containers.ChargesPost))
        {
            return Result<ContainerChargeImportResult>.Failure(
                ErrorType.Forbidden,
                $"Posting the charges needs the {Permissions.Containers.ChargesPost} permission; import them as drafts instead.",
                "FORBIDDEN");
        }

        var rows = request.Rows ?? [];
        if (rows.Count == 0)
        {
            return Result<ContainerChargeImportResult>.Failure(ErrorType.Validation, "There are no rows to import.", "VALIDATION");
        }

        if (rows.Count > ContainerChargeImportParser.MaxDataRows)
        {
            return Result<ContainerChargeImportResult>.Failure(ErrorType.Validation,
                $"At most {ContainerChargeImportParser.MaxDataRows} rows can be imported at a time.", "VALIDATION");
        }

        var importable = rows
            .Where(r => !string.Equals(r.Status, ContainerChargeImportStatus.Error, StringComparison.Ordinal))
            .OrderBy(r => r.RowNumber)
            .ToList();
        if (importable.Count == 0)
        {
            return Result<ContainerChargeImportResult>.Failure(ErrorType.Validation,
                "Nothing to import: every row has an error. Correct the file and validate it again.", "VALIDATION");
        }

        var outcomes = new Dictionary<ContainerChargeImportValidatedRow, ContainerChargeImportRowResult>(ReferenceEqualityComparer.Instance);
        var ready = new List<ContainerChargeImportValidatedRow>(importable.Count);
        foreach (var row in importable)
        {
            if (NotImportable(row) is { } reason)
            {
                outcomes[row] = Failed(row, reason);
            }
            else
            {
                ready.Add(row);
            }
        }

        /* NOT THE REQUEST'S TOKEN for the writes: a person who closes the tab halfway must find every row up to
           there created and the rest not, never a row cut in two — and each call is one procedure, one
           transaction. The charges are in the list either way; only this answer would be lost. */
        var created = new List<(ContainerChargeImportValidatedRow Row, int Id, Guid? GroupId, decimal Amount, decimal AmountBase, string ContainerRef, string? ContainerNo)>();

        foreach (var batch in Batches(ready))
        {
            int? sourceId = null;
            var batchStart = created.Count;

            foreach (var row in batch)
            {
                try
                {
                    if (sourceId is null)
                    {
                        var made = await _charges.CreateAsync(new CreateContainerChargeRequest
                        {
                            ContainerIds = [row.ContainerId!.Value],
                            ChargeTypeId = row.ChargeTypeId!.Value,
                            ProviderPartyId = row.ProviderPartyId,
                            Reference = Trimmed(row.Reference),
                            ChargeDate = row.ChargeDate!.Value,
                            CurrencyId = row.CurrencyId,
                            RateType = (byte)RateType.Official,
                            ExchangeRate = row.ExchangeRate,
                            TotalAmount = row.Amount!.Value,
                            SplitRule = ChargeSplitRules.Same,
                            AllocationMethod = row.AllocationMethod,
                            Notes = Trimmed(row.Notes),
                        }, userId, CancellationToken.None);

                        var charge = made[0];
                        sourceId = charge.Id;
                        created.Add((row, charge.Id, charge.GroupId, charge.Amount, charge.AmountBase, charge.ContainerRef, charge.ContainerNo));
                    }
                    else
                    {
                        var copies = await _charges.CopyToContainersAsync(sourceId.Value, new CopyContainerChargeRequest
                        {
                            ContainerIds = [row.ContainerId!.Value],
                            Amount = row.Amount,
                            ChargeDate = row.ChargeDate,
                            AllocationMethod = row.AllocationMethod,
                            Post = false,
                        }, userId, CancellationToken.None);

                        var copy = copies[0];
                        created.Add((row, copy.Id, copy.GroupId, copy.Amount, copy.AmountBase, copy.ContainerRef, copy.ContainerNo));

                        // The first copy puts the original in a new group: every charge of the batch carries it.
                        for (var i = batchStart; i < created.Count; i++)
                        {
                            created[i] = created[i] with { GroupId = copy.GroupId };
                        }
                    }
                }
                catch (BusinessRuleException ex)
                {
                    outcomes[row] = Failed(row, ex.Message);
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    _logger.LogError(ex, "Container charge import: row {RowNumber} could not be created", row.RowNumber);
                    outcomes[row] = Failed(row, "The charge could not be created (unexpected error). Import this row again.");
                }
            }
        }

        foreach (var (row, id, groupId, amount, amountBase, containerRef, containerNo) in created)
        {
            var outcome = ContainerChargeImportOutcome.Draft;
            string? message = null;

            if (request.Post)
            {
                try
                {
                    await _charges.PostAsync(id, [], null, userId, CancellationToken.None);
                    outcome = ContainerChargeImportOutcome.Posted;
                }
                catch (BusinessRuleException ex)
                {
                    message = $"Created as a draft, not posted: {ex.Message}";
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    _logger.LogError(ex, "Container charge import: charge {ChargeId} (row {RowNumber}) could not be posted", id, row.RowNumber);
                    message = "Created as a draft, not posted (unexpected error). Post it from the container.";
                }
            }

            outcomes[row] = new ContainerChargeImportRowResult
            {
                RowNumber = row.RowNumber,
                Outcome = outcome,
                Message = message,
                ChargeId = id,
                GroupId = groupId,
                ContainerId = row.ContainerId,
                ContainerRef = containerRef,
                ContainerNo = containerNo,
                ChargeCode = row.ChargeCode,
                ChargeName = row.ChargeName,
                Amount = amount,
                CurrencyCode = row.CurrencyCode,
                AmountBase = amountBase,
            };
        }

        var results = importable.Select(r => outcomes[r]).ToList();
        var result = new ContainerChargeImportResult
        {
            TotalRows = results.Count,
            SkippedRows = rows.Count - importable.Count,
            CreatedRows = results.Count(r => r.ChargeId is not null),
            PostedRows = results.Count(r => r.Outcome == ContainerChargeImportOutcome.Posted),
            DraftRows = results.Count(r => r.Outcome == ContainerChargeImportOutcome.Draft),
            FailedRows = results.Count(r => r.Outcome == ContainerChargeImportOutcome.Failed),
            Post = request.Post,
            Rows = results,
        };

        _logger.LogInformation(
            "Container charges imported from {FileName} by user {UserId}: {Created} created ({Posted} posted), {Failed} failed, {Skipped} skipped.",
            request.FileName ?? "(no name)", userId, result.CreatedRows, result.PostedRows, result.FailedRows, result.SkippedRows);

        return Result<ContainerChargeImportResult>.Success(result);
    }

    /// <summary>A row sent back without what validation resolves (or changed since) is not created from guesses.</summary>
    private static string? NotImportable(ContainerChargeImportValidatedRow row)
    {
        if (row.AllocationMethod is not null
            && string.Equals(row.AllocationMethod.Trim(), ChargeAllocationMethods.Manual, StringComparison.OrdinalIgnoreCase))
        {
            return "Manual allocation is not possible in an import: choose Value, Quantity, Weight or Volume.";
        }

        var complete = row.ContainerId > 0 && row.ChargeTypeId > 0 && row.CurrencyId > 0 && row.ChargeDate is not null
                       && row.Amount is > 0 and <= MaxAmount && row.ExchangeRate is > 0
                       && row.AllocationMethod is { } method && ImportMethods.Contains(method, StringComparer.Ordinal)
                       && (row.Reference?.Length ?? 0) <= ReferenceMaxLength && (row.Notes?.Length ?? 0) <= NotesMaxLength;

        return complete ? null : "This row was not validated: validate the file again before importing it.";
    }

    private static ContainerChargeImportRowResult Failed(ContainerChargeImportValidatedRow row, string message) => new()
    {
        RowNumber = row.RowNumber,
        Outcome = ContainerChargeImportOutcome.Failed,
        Message = message,
        ContainerId = row.ContainerId,
        ContainerRef = row.ContainerRef,
        ContainerNo = row.ContainerNo,
        ChargeCode = row.ChargeCode,
        ChargeName = row.ChargeName,
        Amount = row.Amount,
        CurrencyCode = row.CurrencyCode,
        AmountBase = row.AmountBase,
    };

    /* ── shared ───────────────────────────────────────────────────────────────────────────────── */

    /// <summary>
    /// The rows in the order they are created: one batch per charge group, in the order of its first row.
    /// Only rows with a Provider Invoice No. are grouped, by everything a copy takes from its original (type,
    /// provider, invoice no., currency, rate, notes) and the date; a container already in a group starts
    /// another one, since a group holds one charge per container.
    /// </summary>
    private static List<List<ContainerChargeImportValidatedRow>> Batches(IEnumerable<ContainerChargeImportValidatedRow> rows)
    {
        var batches = new List<List<ContainerChargeImportValidatedRow>>();
        var open = new Dictionary<string, List<List<ContainerChargeImportValidatedRow>>>(StringComparer.Ordinal);

        foreach (var row in rows.OrderBy(r => r.RowNumber))
        {
            if (string.IsNullOrWhiteSpace(row.Reference))
            {
                batches.Add([row]);
                continue;
            }

            var key = string.Join('|', row.ChargeTypeId, row.ProviderPartyId, Normalized(row.Reference),
                row.ChargeDate?.ToString("yyyy-MM-dd", Invariant), row.CurrencyId,
                row.ExchangeRate?.ToString("0.######", Invariant), row.Notes?.Trim() ?? string.Empty);

            if (!open.TryGetValue(key, out var groups))
            {
                groups = [];
                open.Add(key, groups);
            }

            var group = groups.FirstOrDefault(g => g.All(member => member.ContainerId != row.ContainerId));
            if (group is null)
            {
                group = [];
                groups.Add(group);
                batches.Add(group);
            }

            group.Add(row);
        }

        return batches;
    }

    /// <summary>A container number or ref as logistics.fn_ContainerNumberKey compares it.</summary>
    internal static string ContainerKey(string? value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return string.Empty;
        }

        Span<char> buffer = value.Length <= 256 ? stackalloc char[value.Length] : new char[value.Length];
        var length = 0;
        foreach (var character in value)
        {
            if (character is ' ' or ' ' or ' ' or '\t' or '\n' or '\r' or '-' or '.' or '/')
            {
                continue;
            }

            buffer[length++] = char.ToUpperInvariant(character);
        }

        return new string(buffer[..length]);
    }

    private static string Normalized(string? value) => value?.Trim().ToUpperInvariant() ?? string.Empty;

    private static string? Trimmed(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    private DateOnly ServerToday() => DateOnly.FromDateTime(_clock.GetUtcNow().UtcDateTime);

    /// <summary>The browser's date when it is within a day or two of the server's (time zones); the server's otherwise.</summary>
    private DateOnly EffectiveToday(DateOnly? today)
    {
        var server = ServerToday();
        return today is { } local && Math.Abs(local.DayNumber - server.DayNumber) <= 2 ? local : server;
    }

    private static Result<ContainerChargeImportValidation> Invalid(string message)
        => Result<ContainerChargeImportValidation>.Failure(ErrorType.Validation, message, InvalidFileCode);
}
