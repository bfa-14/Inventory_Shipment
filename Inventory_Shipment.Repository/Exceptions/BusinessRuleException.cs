namespace Inventory_Shipment.Repository.Exceptions;

/// <summary>
/// A business rule enforced inside a stored procedure with THROW (error numbers 50000-59999).
/// The service layer maps <see cref="Number"/> to the right <c>ErrorType</c> instead of letting a
/// raw SqlException escape. Each module owns a block of numbers: 50xxx security, 51xxx master data.
/// </summary>
public class BusinessRuleException : Exception
{
    public BusinessRuleException(int number, string message, Exception? innerException = null)
        : base(message, innerException)
    {
        Number = number;
    }

    /// <summary>The SQL error number, e.g. <see cref="Database.SqlErrors.BranchDuplicateCode"/>.</summary>
    public int Number { get; }
}
