namespace Inventory_Shipment.Repository.Exceptions;

/// <summary>
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
}
