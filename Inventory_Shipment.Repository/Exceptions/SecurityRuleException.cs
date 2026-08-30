namespace Inventory_Shipment.Repository.Exceptions;

/// <summary>
/// A business rule raised by one of the security stored procedures (error numbers 50001-50999).
/// A specialization of <see cref="BusinessRuleException"/> so the security services can keep
/// catching only their own failures.
/// </summary>
public sealed class SecurityRuleException : BusinessRuleException
{
    public SecurityRuleException(int code, string message, Exception? innerException = null)
        : base(code, message, innerException)
    {
    }

    /// <summary>The SQL error number, e.g. <see cref="Database.SqlErrors.LastAdministrator"/>.</summary>
    public int Code => Number;
}
