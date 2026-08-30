using Inventory_Shipment.Repository.Exceptions;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Database;

/// <summary>
/// Error numbers raised with THROW by the security stored procedures, and the translation from a
/// <see cref="SqlException"/> into a <see cref="SecurityRuleException"/> the service layer understands.
/// </summary>
public static class SqlErrors
{
    public const int RoleNotFound = 50001;
    public const int SystemRolePermissions = 50002;
    public const int UserNotFound = 50003;
    public const int LastAdministrator = 50004;
    public const int SystemRoleDelete = 50005;
    public const int RoleStillAssigned = 50006;

    private const int FirstUserDefined = 50001;
    private const int LastUserDefined = 50999;

    /// <summary>True when the exception is a deliberate business-rule THROW rather than a database failure.</summary>
    public static bool IsBusinessRule(SqlException exception)
        => exception.Number is >= FirstUserDefined and <= LastUserDefined;

    /// <summary>Wraps a business-rule SqlException, keeping the message written in the procedure.</summary>
    public static SecurityRuleException ToSecurityRuleException(SqlException exception)
        => new(exception.Number, exception.Message, exception);
}
