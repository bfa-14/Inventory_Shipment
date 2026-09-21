using Inventory_Shipment.Repository.Exceptions;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Database;

/// <summary>
/// Error numbers raised with THROW by the stored procedures, and the translation from a
/// <see cref="SqlException"/> into a <see cref="BusinessRuleException"/> the service layer understands.
/// Each module owns a block: 50xxx security, 56xxx inventory, 51xxx-55xxx + 57xxx-60xxx master data,
/// 61xxx sales imports, 62xxx inventory documents, and 64xxx sales documents.
/// </summary>
public static class SqlErrors
{
    // ----- 50xxx: security -----
    public const int RoleNotFound = 50001;
    public const int SystemRolePermissions = 50002;
    public const int UserNotFound = 50003;
    public const int LastAdministrator = 50004;
    public const int SystemRoleDelete = 50005;
    public const int RoleStillAssigned = 50006;

    // ----- 51xxx: master data -----
    public const int Validation = 51000;
    public const int BranchDuplicateCode = 51001;
    public const int BranchMainExists = 51002;
    public const int BranchReferenced = 51003;
    public const int Concurrency = 51004;
    public const int BranchMainProtected = 51005;
    public const int BranchNotFound = 51006;

    // ----- 52xxx: master data - warehouses -----
    public const int WarehouseValidation = 52000;
    public const int WarehouseDuplicateCode = 52001;
    public const int WarehouseMainExists = 52002;
    public const int WarehouseReferenced = 52003;
    public const int WarehouseConcurrency = 52004;
    public const int WarehouseMainProtected = 52005;
    public const int WarehouseNotFound = 52006;
    public const int WarehouseBranchInactive = 52007;

    // ----- 53xxx: master data - currencies and exchange rates -----
    public const int CurrencyValidation = 53000;
    public const int CurrencyDuplicateCode = 53001;
    public const int CurrencyBaseExists = 53002;
    public const int CurrencyReferenced = 53003;
    public const int CurrencyConcurrency = 53004;
    public const int CurrencyBaseProtected = 53005;
    public const int CurrencyNotFound = 53006;
    public const int ExchangeRateDuplicate = 53007;
    public const int CurrencyInactive = 53008;

    // ----- 54xxx: master data - item families (self-referencing tree) -----
    public const int ItemFamilyValidation = 54000;
    public const int ItemFamilyDuplicateCode = 54001;
    public const int ItemFamilyDuplicateName = 54002;
    public const int ItemFamilyReferenced = 54003;
    public const int ItemFamilyConcurrency = 54004;
    public const int ItemFamilyHasChildren = 54005;
    public const int ItemFamilyNotFound = 54006;
    public const int ItemFamilyCircularHierarchy = 54007;
    public const int ItemFamilyParentInactive = 54008;

    // ----- 55xxx: master data - brands -----
    public const int BrandValidation = 55000;
    public const int BrandDuplicateCode = 55001;
    public const int BrandReferenced = 55003;
    public const int BrandConcurrency = 55004;
    public const int BrandNotFound = 55006;

    // ----- 56xxx: inventory - item definition (items, units, files) -----
    public const int ItemValidation = 56000;
    public const int ItemDuplicateCode = 56001;
    public const int ItemDuplicateBarcode = 56002;
    public const int ItemReferenced = 56003;
    public const int ItemConcurrency = 56004;
    public const int ItemBaseUnitRule = 56005;
    public const int ItemNotFound = 56006;
    public const int ItemDuplicateSku = 56007;
    public const int ItemMasterInactive = 56008;

    // ----- 57xxx: master data - unit types -----
    public const int UnitTypeValidation = 57000;
    public const int UnitTypeDuplicateName = 57001;
    public const int UnitTypeReferenced = 57003;
    public const int UnitTypeConcurrency = 57004;
    public const int UnitTypeNotFound = 57006;

    // ----- 58xxx: master data - price lists -----
    public const int PriceListValidation = 58000;
    public const int PriceListDuplicateCode = 58001;
    public const int PriceListReferenced = 58003;
    public const int PriceListConcurrency = 58004;
    public const int PriceListNotFound = 58006;
    public const int PriceListCurrencyInactive = 58008;
    public const int PriceListCurrencyLocked = 58009;

    // ----- 60xxx: master data - parties (suppliers / clients / salesmen / employees) -----
    public const int PartyValidation = 60000;
    public const int PartyDuplicateCode = 60001;
    public const int PartyUserAlreadyLinked = 60002;
    public const int PartyReferenced = 60003;
    public const int PartyConcurrency = 60004;
    public const int PartyTypeInUse = 60005;
    public const int PartyNotFound = 60006;
    public const int PartyMasterInactive = 60008;

    // ----- 61xxx: sales - invoice import -----
    public const int InvoiceImportValidation = 61000;

    /// <summary>Branch, default warehouse or price list missing or inactive, or the warehouse is not in the branch.</summary>
    public const int InvoiceImportMasterInactive = 61008;

    // ----- 62xxx: inventory - stock documents and the ledger -----
    public const int StockDocumentValidation = 62000;
    public const int StockDocumentConcurrency = 62004;

    /// <summary>The document is not a draft, so it cannot be edited or deleted.</summary>
    public const int StockDocumentNotDraft = 62005;

    public const int StockDocumentNotFound = 62006;

    /// <summary>Posting or cancelling would take stock below zero. The message names the item, the warehouse and both figures.</summary>
    public const int StockDocumentInsufficientStock = 62007;

    public const int StockDocumentMasterInactive = 62008;
    public const int StockDocumentNoLines = 62009;

    /// <summary>The lifecycle forbids the move — posting something already posted, cancelling a draft.</summary>
    public const int StockDocumentInvalidStatus = 62010;

    // ----- 64xxx: sales - invoices (the Sales document family) -----
    public const int SalesDocumentValidation = 64000;
    public const int SalesDocumentConcurrency = 64004;
    public const int SalesDocumentNotDraft = 64005;
    public const int SalesDocumentNotFound = 64006;
    public const int SalesDocumentInsufficientStock = 64007;

    /// <summary>Branch, warehouse, client, salesman or price list missing / inactive — or no exchange rate for the date.</summary>
    public const int SalesDocumentMasterInactive = 64008;

    public const int SalesDocumentNoLines = 64009;
    public const int SalesDocumentInvalidStatus = 64010;

    /// <summary>A line whose item unit has no price in the chosen list, and the caller may not override. The message names the line.</summary>
    public const int SalesDocumentNoPrice = 64011;

    // ----- 65xxx: purchase - orders, invoices and returns (the Purchase document family) -----
    public const int PurchaseDocumentValidation = 65000;
    public const int PurchaseDocumentConcurrency = 65004;
    public const int PurchaseDocumentNotDraft = 65005;
    public const int PurchaseDocumentNotFound = 65006;
    public const int PurchaseDocumentInsufficientStock = 65007;
    public const int PurchaseDocumentMasterInactive = 65008;
    public const int PurchaseDocumentNoLines = 65009;
    public const int PurchaseDocumentInvalidStatus = 65010;

    /// <summary>The chain is broken: wrong source kind, source not open, more than remains, or a posted child in the way.</summary>
    public const int PurchaseDocumentSourceInvalid = 65011;

    // ----- 66xxx: inventory - shortage planning documents -----
    public const int ShortageDocumentValidation = 66000;
    public const int ShortageDocumentConcurrency = 66004;
    public const int ShortageDocumentNotDraft = 66005;
    public const int ShortageDocumentNotFound = 66006;
    public const int ShortageDocumentNoLines = 66009;
    public const int ShortageDocumentInvalidStatus = 66010;

    /// <summary>A purchase order was asked of a posted plan on which no line has a required quantity above zero.</summary>
    public const int ShortageDocumentNothingToOrder = 66011;

    /// <summary>A purchase charge could not be allocated: no weight, no volume, a zero basis, or manual amounts that do not add up.</summary>
    public const int PurchaseChargeAllocation = 65012;

    // ----- 67xxx: purchase - landed cost adjustments (charges arriving after receipt) -----
    public const int LandedCostValidation = 67000;
    public const int LandedCostConcurrency = 67004;
    public const int LandedCostNotDraft = 67005;
    public const int LandedCostNotFound = 67006;
    public const int LandedCostInvalidStatus = 67010;

    /// <summary>The source invoice is missing, not a purchase invoice, not posted, or still carries a posted adjustment.</summary>
    public const int LandedCostSourceInvalid = 67011;

    // ----- 68xxx: purchase - charge types (US-MD-008) -----
    public const int ChargeTypeValidation = 68000;
    public const int ChargeTypeDuplicateCode = 68001;
    public const int ChargeTypeDuplicateName = 68002;
    public const int ChargeTypeConcurrency = 68004;
    public const int ChargeTypeInUse = 68005;
    public const int ChargeTypeNotFound = 68006;

    private const int FirstBusinessRule = 50000;

    // The ceiling moves with the newest block (68xxx is the charge types): a ceiling left behind
    // its own module is how a deliberate THROW reaches the API as an unhandled database failure.
    private const int LastBusinessRule = 68999;

    private const int FirstSecurityRule = 50001;
    private const int LastSecurityRule = 50999;

    /// <summary>True when the exception is a deliberate business-rule THROW rather than a database failure.</summary>
    public static bool IsBusinessRule(SqlException exception)
        => exception.Number is >= FirstBusinessRule and <= LastBusinessRule;

    /// <summary>
    /// Wraps a business-rule SqlException, keeping the message written in the procedure. Numbers in the
    /// security block become a <see cref="SecurityRuleException"/> so existing catch blocks still match.
    /// </summary>
    public static BusinessRuleException Wrap(SqlException exception)
        => exception.Number is >= FirstSecurityRule and <= LastSecurityRule
            ? new SecurityRuleException(exception.Number, exception.Message, exception)
            : new BusinessRuleException(exception.Number, exception.Message, exception);

    /// <summary>Wraps a security-procedure SqlException (50001-50999).</summary>
    public static SecurityRuleException ToSecurityRuleException(SqlException exception)
        => new(exception.Number, exception.Message, exception);
}
