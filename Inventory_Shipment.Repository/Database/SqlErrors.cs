using Inventory_Shipment.Repository.Exceptions;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Database;

/// <summary>
/// Error numbers raised with THROW by the stored procedures, and the translation from a
/// <see cref="SqlException"/> into a <see cref="BusinessRuleException"/> the service layer understands.
/// Each module owns a block: 50xxx security, 51xxx master data.
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

    private const int FirstBusinessRule = 50000;
    private const int LastBusinessRule = 59999;

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
