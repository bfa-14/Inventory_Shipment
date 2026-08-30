namespace Inventory_Shipment.Repository.Exceptions;

/// <summary>
<<<<<<< HEAD
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
=======
/// A business rule enforced inside a stored procedure with THROW (error numbers 50001-50999).
/// The service layer maps <see cref="Code"/> to the right <c>ErrorType</c> instead of letting a
/// raw SqlException escape.
/// </summary>
public sealed class SecurityRuleException : Exception
{
    public SecurityRuleException(int code, string message, Exception? innerException = null)
        : base(message, innerException)
    {
        Code = code;
    }

    /// <summary>The SQL error number, e.g. <see cref="Database.SqlErrors.LastAdministrator"/>.</summary>
    public int Code { get; }
>>>>>>> b5d1b30fa9d8e07e232f3ce84e9d4b71191cf21a
}
