# Currencies & Exchange Rates — SQL + VS Code prompts

Two pages under Master Data: **Currencies** (with a single base currency, like the main branch)
and **Exchange Rates** (history per currency with three rate types: Official, Non-official, Market).

| Step | What | Who |
|------|------|-----|
| 1 | `Database\08_MasterData_Currencies.sql` in SSMS on **Inventory_Shipment** (needs 01 + 03) | you (or the assistant) |
| 2 | **Prompt A** — backend: Model / Repository / Service / API + embed the script | VS Code assistant |
| 3 | **Prompt B** — frontend: Currencies page + Exchange Rates page | VS Code assistant |

Conventions decided in the SQL (the code must match):
- Exactly one active **base currency** (seeded: USD). Amounts are stored/reported in it.
- A rate means **1 base currency = Rate × quoted currency** (base USD, CDF 2800 → 1 USD = 2,800 CDF).
- The base currency never has rate rows (rate = 1 by definition).
- `RateType`: 1 = Official, 2 = NonOfficial, 3 = Market. One rate per (currency, type, date); a rate
  stays in force until a newer date exists (`masterdata.fn_GetRate`). No future dates.
- Future transactions snapshot the rate they used — deleting/editing a rate never rewrites history.

Business-rule error numbers thrown by the procedures:

| Number | Meaning | HTTP | `code` |
|--------|---------|------|--------|
| 53000 | validation (required / invalid / future date) | 400 | `VALIDATION` |
| 53001 | Currency Code already exists | 409 | `DUPLICATE_CODE` |
| 53002 | another active Base Currency exists — confirm replacement | 409 | `BASE_CURRENCY_EXISTS` (+ `data.currentBaseCurrency`) |
| 53003 | referenced (rates, future prices/invoices) — cannot delete | 409 | `REFERENCED` |
| 53004 | RowVersion changed (concurrency) | 409 | `CONCURRENCY` |
| 53005 | Base Currency protected (stay active / no demote / no delete / no rates) | 400 | `BASE_CURRENCY_PROTECTED` |
| 53006 | currency / exchange rate not found | 404 | `NOT_FOUND` |
| 53007 | rate for this currency + type + date already exists | 409 | `DUPLICATE_RATE` |
| 53008 | currency inactive — cannot add rates | 400 | `CURRENCY_INACTIVE` |

---

## Prompt A — Backend (Model, Repository, Service, API)

```text
You are working on D:\VSProjects\Inventory_Shipment (Inventory_Shipment.slnx, .NET 10, C# 13, nullable). You may
read and modify every file in it. Do not touch D:\VSProjects\Inventory_Shipment.Web in this task.

The Branches (US-MD-001) and Warehouses (US-MD-002) features are already implemented and are the pattern to copy
exactly: Model/Entities/*, Model/DTOs/MasterData/*, PagedResult, Result.Code/Result.Data,
Repository/Interfaces + Implementations (stored procedures via Dapper, SqlErrors + BusinessRuleException for
THROW 5xxxx), Service/Interfaces + Implementations + Mapping, API/Controllers/MasterData/* ([HasPermission] per
action, ResultExtensions with problem.code / problem.data), Security/PermissionCatalog.cs (module "Master Data"),
Repository\Database\Schema.sql (embedded, applied at start-up, batches split on GO). Conventions: schema per
module (never dbo); services return Result and never throw for expected failures; UTC timestamps; no new NuGet
packages; 0 build warnings. Database: SQL Server default instance (Server=.), database Inventory_Shipment,
Windows Authentication. Dev sign-in: admin / Admin@12345.

Feature: Currencies & Exchange Rates. Domain rules (already enforced in SQL - the code mirrors them):
- exactly one ACTIVE base currency (seeded USD) - same single-main pattern as branches (@ReplaceBaseCurrency);
- a rate means 1 BASE currency = Rate x quoted currency; the base currency never has rate rows;
- RateType: 1 Official, 2 NonOfficial, 3 Market; one rate per (currency, type, date); no future dates;
- rates carry forward: the rate in force on a date is the latest RateDate <= that date (masterdata.fn_GetRate).

The database work is written: D:\VSProjects\Inventory_Shipment\Database\08_MasterData_Currencies.sql creates
masterdata.Currencies (Id, CurrencyCode NVARCHAR(3) unique upper-case ISO 4217, CurrencyName NVARCHAR(100),
Symbol NVARCHAR(10) NULL, DecimalPlaces TINYINT 0..6 default 2, IsBaseCurrency, IsActive, audit columns,
RowVersion) and masterdata.ExchangeRates (Id, CurrencyId FK, RateType TINYINT 1|2|3, RateDate DATE,
Rate DECIMAL(18,6) > 0, Notes NVARCHAR(300) NULL, audit columns, RowVersion; unique (CurrencyId, RateType,
RateDate)), plus masterdata.fn_GetRate(@CurrencyId, @RateType, @AsOfDate) and the error table in
docs/prompts/10-masterdata-currencies.md (53000..53008).
Procedures:
  masterdata.usp_Currency_Search @Search, @IsActive, @IsBaseCurrency, @SortColumn (CurrencyCode|CurrencyName|
      DecimalPlaces|IsBaseCurrency|IsActive|CreatedAtUtc), @SortDirection, @PageNumber, @PageSize -> rows + TotalCount
  masterdata.usp_Currency_Get @Id / usp_Currency_GetBase
  masterdata.usp_Currency_Lookup @ActiveOnly BIT = 1, @IncludeId INT = NULL
      -> Id, CurrencyCode, CurrencyName, Symbol, DecimalPlaces, IsBaseCurrency, IsActive (base first)
  masterdata.usp_Currency_Create @CurrencyCode, @CurrencyName, @Symbol, @DecimalPlaces, @IsBaseCurrency,
      @IsActive, @ReplaceBaseCurrency, @UserId, @NewId OUTPUT
  masterdata.usp_Currency_Update @Id, ... same ..., @RowVersion BINARY(8), @UserId
  masterdata.usp_Currency_SetActive @Id, @IsActive, @UserId      masterdata.usp_Currency_Delete @Id
  masterdata.usp_ExchangeRate_Search @CurrencyId, @RateType, @DateFrom, @DateTo, @SortColumn (RateDate|
      CurrencyCode|RateType|Rate|CreatedAtUtc), @SortDirection (default RateDate DESC), @PageNumber, @PageSize
      -> rows joined with the currency (CurrencyCode, CurrencyName, Symbol, DecimalPlaces) + TotalCount
  masterdata.usp_ExchangeRate_Get @Id
  masterdata.usp_ExchangeRate_GetLatest @CurrencyId, @AsOfDate DATE = NULL (default today UTC)
      -> up to 3 rows, the rate in force per RateType
  masterdata.usp_ExchangeRate_Create @CurrencyId, @RateType, @RateDate, @Rate, @Notes, @UserId, @NewId OUTPUT
  masterdata.usp_ExchangeRate_Update @Id, @CurrencyId, @RateType, @RateDate, @Rate, @Notes, @RowVersion, @UserId
  masterdata.usp_ExchangeRate_Delete @Id

TASK

1. Database: run the script (sqlcmd -S . -E -d Inventory_Shipment -i "D:\VSProjects\Inventory_Shipment\Database\08_MasterData_Currencies.sql")
   and show its output; then append it to Repository\Database\Schema.sql under "-- ===== 08: Master Data -
   Currencies & Exchange Rates =====" without the USE batch and without the final report batch. Keep every GO
   and the guard batch.

2. Model
   - Enums/RateType.cs (or Model/MasterData): enum RateType : byte { Official = 1, NonOfficial = 2, Market = 3 },
     serialized as a STRING in JSON (JsonStringEnumConverter is already global or add it), stored as TINYINT.
   - Entities: Currency (all columns); ExchangeRate (all columns + read-only CurrencyCode, CurrencyName, Symbol,
     DecimalPlaces from the join; RateType as the enum; RateDate as DateOnly - if Dapper/SqlClient mapping of
     DateOnly gives trouble, map DateTime in the entity and convert to DateOnly in the DTO mapper).
   - DTOs/MasterData/:
     CurrencyDto (id, currencyCode, currencyName, symbol, decimalPlaces, isBaseCurrency, isActive, createdAtUtc,
       updatedAtUtc, rowVersion Base64);
     SaveCurrencyRequest (CurrencyCode [Required, StringLength(3, MinimumLength = 3), RegularExpression
       "^[A-Za-z]{3}$" - normalized to upper in the service], CurrencyName [Required, StringLength(100,
       MinimumLength = 1)], Symbol [StringLength(10)], byte DecimalPlaces [Range(0, 6)] = 2,
       bool IsBaseCurrency = false, bool IsActive = true, bool ReplaceBaseCurrency = false, string? RowVersion);
     SetCurrencyStatusRequest (bool IsActive);
     CurrencyQuery (Search, bool? IsActive, bool? IsBaseCurrency, SortBy = "CurrencyCode", SortDir = "asc",
       Page = 1, PageSize = 10 [Range(1, 200)]);
     CurrencyLookupDto (id, currencyCode, currencyName, symbol, decimalPlaces, isBaseCurrency, isActive);
     ExchangeRateDto (id, currencyId, currencyCode, currencyName, symbol, decimalPlaces, rateType (string),
       rateDate "yyyy-MM-dd", rate, notes, createdAtUtc, updatedAtUtc, rowVersion Base64);
     SaveExchangeRateRequest (CurrencyId [Required, Range(1, int.MaxValue)], RateType [Required] (enum),
       RateDate [Required] DateOnly, Rate [Required, Range(0.000001, 999999999999.999999)] decimal,
       Notes [StringLength(300)], string? RowVersion);
     ExchangeRateQuery (int? CurrencyId, RateType? RateType, DateOnly? DateFrom, DateOnly? DateTo,
       SortBy = "RateDate", SortDir = "desc", Page = 1, PageSize = 10 [Range(1, 200)]).
   - Security/PermissionCatalog.cs: Permissions.MasterData.CurrenciesView/Create/Edit/Delete =
     "masterdata.currencies.view|create|edit|delete" (sort 180..210) and ExchangeRatesView/Create/Edit/Delete =
     "masterdata.exchangerates.view|create|edit|delete" (sort 220..250), module "Master Data", names/descriptions
     as in the SQL MERGE.

3. Repository
   - ICurrencyRepository / CurrencyRepository: SearchAsync(CurrencyQuery) -> (rows, totalCount);
     GetAsync(id); GetBaseAsync(); LookupAsync(activeOnly, includeId); CreateAsync(...) -> new id;
     UpdateAsync(...); SetActiveAsync(id, isActive, userId); DeleteAsync(id). CommandType.StoredProcedure
     everywhere, SqlErrors wrap turning THROW 53xxx into BusinessRuleException.
   - IExchangeRateRepository / ExchangeRateRepository: SearchAsync(ExchangeRateQuery); GetAsync(id);
     GetLatestAsync(currencyId, asOfDate?); CreateAsync(...); UpdateAsync(...); DeleteAsync(id).
     RateType passed as byte; RateDate as DATE.
   - Register both in DependencyInjection.AddRepositoryLayer.

4. Service
   - ICurrencyService / CurrencyService + CurrencyMapper: mirror BranchService exactly. Map BusinessRuleException:
     53000 -> Validation; 53001 -> Conflict code DUPLICATE_CODE; 53002 -> Conflict code BASE_CURRENCY_EXISTS with
     data { currentBaseCurrency: { id, currencyCode, currencyName } } (fetch via GetBaseAsync); 53003 -> Conflict
     REFERENCED; 53004 -> Conflict CONCURRENCY; 53005 -> Validation BASE_CURRENCY_PROTECTED; 53006 -> NotFound.
   - IExchangeRateService / ExchangeRateService + mapper: same mapping plus 53007 -> Conflict DUPLICATE_RATE and
     53008 -> Validation CURRENCY_INACTIVE. LatestAsync returns the up-to-3 rows as ExchangeRateDto list.
   - Register in AddServiceLayer.

5. API (API/Controllers/MasterData/)
   - CurrenciesController, route api/masterdata/currencies:
       GET    ?query...            [HasPermission(masterdata.currencies.view)]  -> PagedResult<CurrencyDto>
       GET    {id}                 [view]                                       -> CurrencyDto / 404
       GET    base                 [Authorize] only                             -> CurrencyDto / 404
       GET    lookup?activeOnly=&includeId=  [Authorize] only (dropdown data)   -> CurrencyLookupDto[]
       POST                        [create]  SaveCurrencyRequest -> 201 with CurrencyDto
       PUT    {id}                 [edit]    SaveCurrencyRequest -> 200 with CurrencyDto
       PUT    {id}/status          [edit]    SetCurrencyStatusRequest -> 204
       DELETE {id}                 [delete]  -> 204
   - ExchangeRatesController, route api/masterdata/exchange-rates:
       GET    ?query...            [HasPermission(masterdata.exchangerates.view)] -> PagedResult<ExchangeRateDto>
       GET    {id}                 [view]                                          -> ExchangeRateDto / 404
       GET    latest?currencyId=&asOf=  [Authorize] only                           -> ExchangeRateDto[] (0..3)
       POST                        [create]  SaveExchangeRateRequest -> 201
       PUT    {id}                 [edit]                             -> 200
       DELETE {id}                 [delete]  -> 204
   - ResultExtensions already emits problem.code / problem.data - make sure the two new codes flow through.

6. Quality: dotnet build with 0 warnings; API starts, log shows "Database schema verified"; Scalar lists the new
   endpoints grouped under Master Data.

VERIFY (API running; get a token via POST /api/auth/login admin / Admin@12345) - run each with curl and show output:
  a. GET /api/masterdata/currencies -> USD (isBaseCurrency true), EUR, INR, CDF seeded.
  b. POST a currency { "currencyCode": "aed", "currencyName": "UAE Dirham" } -> 201, code stored as "AED".
  c. POST the same code again -> 409 code DUPLICATE_CODE.
  d. POST { "currencyCode": "XXX", ..., "isBaseCurrency": true } -> 409 code BASE_CURRENCY_EXISTS with
     data.currentBaseCurrency = USD; repeat with "replaceBaseCurrency": true -> 201 and USD is no longer base;
     then PUT USD back as base with replaceBaseCurrency true and DELETE XXX (cleanup).
  e. PUT /currencies/{usdId}/status { "isActive": false } -> 400 code BASE_CURRENCY_PROTECTED.
  f. POST /api/masterdata/exchange-rates { currencyId: CDF, rateType: "Official", rateDate: today, rate: 2800 }
     -> 201; same again -> 409 DUPLICATE_RATE; rateType "Market", rate 2950 -> 201; future date -> 400;
     currencyId = USD -> 400 BASE_CURRENCY_PROTECTED.
  g. GET /api/masterdata/exchange-rates/latest?currencyId={cdfId} -> the Official and Market rows.
  h. DELETE the CDF currency -> 409 REFERENCED (rates exist).
  i. SELECT masterdata.fn_GetRate({cdfId}, 1, GETUTCDATE()) via sqlcmd -> 2800.000000.
Report: script output, files added/changed, and every verification result.
```

---

## Prompt B — Frontend (Currencies page + Exchange Rates page)

```text
You are working on D:\VSProjects\Inventory_Shipment.Web (React 19 + Vite 8 + TypeScript, Mantine 9 +
mantine-datatable + @mantine/form + @mantine/modals + @mantine/notifications + @mantine/dates + @tabler/icons-react).
Follow docs/frontend-conventions.md and the shared components in src/components/ui (PageHeader, FilterBar with
AUTO-APPLY filters - no Filter button, DataTable, FormModal, StatusBadge, RowActions, notify, confirm). You may
read D:\VSProjects\Inventory_Shipment for reference but not change it. The backend endpoints exist:
api/masterdata/currencies (search/get/base/lookup/create/update/status/delete) and api/masterdata/exchange-rates
(search/get/latest/create/update/delete) - see docs/prompts/10-masterdata-currencies.md in the API repo for the
DTOs and the error codes (DUPLICATE_CODE, BASE_CURRENCY_EXISTS + data.currentBaseCurrency, REFERENCED,
CONCURRENCY, BASE_CURRENCY_PROTECTED, NOT_FOUND, DUPLICATE_RATE, CURRENCY_INACTIVE).
Dev: npm run dev, sign in admin / Admin@12345.

Domain rules to reflect: one active BASE currency (USD seeded); a rate means 1 BASE = Rate x currency; the base
currency never has rates; rate types Official / Non-official / Market; one rate per currency + type + date; no
future dates; rates carry forward until a newer date.

TASK

1. API modules: src/api/masterdata/currencies.ts and exchangeRates.ts with typed functions for every endpoint
   (types in src/api/types.ts or next to the modules): Currency, CurrencyLookup, ExchangeRate,
   RateType = 'Official' | 'NonOfficial' | 'Market', queries, save requests. Reuse request<T> from http.ts.

2. Navigation: under Master Data, after Warehouses: "Currencies" (masterdata.currencies.view) and
   "Exchange Rates" (masterdata.exchangerates.view). Breadcrumbs "Setup › Master Data › ...".

3. Currencies page (mirror the Branches page exactly, Mantine + auto-apply filters):
   - Filters: search (code/name, debounced), Status (All/Active/Inactive), Base (All/Base only/Non-base),
     Clear Filters.
   - DataTable (server-side sort + paging): #, Code, Name, Symbol, Decimals, Base (blue "Base" Badge or -),
     Status (StatusBadge), Created, RowActions (edit / activate-deactivate / delete), all permission-gated.
   - New/Edit FormModal (@mantine/form): Code (TextInput, maxLength 3, auto-uppercase, withAsterisk,
     3-letter validation), Name (withAsterisk), Symbol (TextInput, optional), Decimal Places (NumberInput 0..6,
     default 2, hint "0 for currencies without cents"), Checkbox "Yes, this is the base currency" with the info
     text "Amounts are stored and reported in the base currency.", Switch "Active".
   - Error handling: DUPLICATE_CODE -> field error under Code; BASE_CURRENCY_EXISTS -> confirm() "USD - US Dollar
     is currently the base currency. Make <code> the base instead?" (names from error.data.currentBaseCurrency)
     -> retry with replaceBaseCurrency: true; BASE_CURRENCY_PROTECTED -> notify.error with the API message;
     REFERENCED on delete -> confirm-style dialog offering "Deactivate instead"; CONCURRENCY -> notify + reload row.

4. Exchange Rates page:
   - Filters (auto-apply): Currency (searchable Select from the lookup, shows "CODE - Name", base currency
     included but marked "(base)"), Rate Type (All / Official / Non-official / Market), Date from / Date to
     (DatePickerInput), Clear Filters.
   - "Latest rates" summary: when a non-base currency is selected in the filter, show three small cards above the
     grid - Official / Non-official / Market - each with the rate in force (from GET latest, formatted with the
     currency's decimalPlaces and thousand separators, e.g. "1 USD = 2,800.00 CDF") and its date; show "-" when
     no rate exists. Hide the cards when no currency (or the base) is selected.
   - DataTable (server-side, default sort RateDate desc): #, Date, Currency (CODE - name), Type (Badge: Official
     blue, Non-official orange, Market teal), Rate (right-aligned, formatted), Notes (truncated with Tooltip),
     Updated, RowActions (edit / delete; no activate).
   - New/Edit FormModal: Currency (searchable Select, ACTIVE non-base currencies only - the base is excluded with
     a helper text "The base currency (USD) always equals 1."), Rate Type (Select of the three), Date (DateInput,
     default today, maxDate today), Rate (NumberInput, min 0.000001, decimalScale 6, thousandSeparator ",",
     withAsterisk, live hint under it: "1 USD = <entered value> <selected code>"), Notes (Textarea, optional,
     e.g. the market source).
   - Error handling: DUPLICATE_RATE -> error under Date: "A rate for this currency, type and date already exists -
     edit that row instead."; CURRENCY_INACTIVE and BASE_CURRENCY_PROTECTED -> notify.error with the API message;
     CONCURRENCY -> notify + refresh; delete via confirm() (danger).
   - After create/update/delete: toast + refresh grid AND the latest-rates cards.

5. Quality: npm run typecheck, npm run lint, npm run build clean; both pages responsive (filters wrap, cards
   stack, table scrolls at 390 px); permission-gated (a view-only user sees no New/edit/delete controls).

VERIFY (API running) and report each with screenshots at 1440 px and 390 px:
  a. Currencies: seeded USD (Base badge) / EUR / INR / CDF listed; create AED; duplicate code shows under the
     field; try making EUR the base -> confirmation names USD, confirm -> EUR is base; put USD back the same way.
  b. Deactivating the base currency is blocked with a clear message; deactivating INR works; the Exchange Rates
     currency dropdown then hides INR for new rates.
  c. Exchange Rates: add CDF Official 2800 today and Market 2950 today; the latest-rates cards show both and "-"
     for Non-official; adding CDF Official today again shows the duplicate message under Date; future dates are
     blocked by the picker.
  d. Filters: picking CDF + Official shows one row; date range works; Clear Filters resets; all auto-apply.
  e. Edit the Market rate to 2900 -> card updates; delete it -> card shows "-".
  f. Deleting the CDF currency on the Currencies page -> "referenced" dialog offering Deactivate instead.
Report: files added/changed and every verification result.
```
