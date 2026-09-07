using Inventory_Shipment.Repository.Exceptions;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Database;

/// <summary>
/// Error numbers raised with THROW by the stored procedures, and the translation from a
/// <see cref="SqlException"/> into a <see cref="BusinessRuleException"/> the service layer understands.
/// Each module owns a block: 50xxx security, 56xxx inventory, and 51xxx-55xxx + 57xxx-60xxx master data.
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

    private const int FirstBusinessRule = 50000;
    private const int LastBusinessRule = 60999;

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
