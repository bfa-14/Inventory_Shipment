namespace Inventory_Shipment.Repository.Exceptions;

/// <summary>
/// Raised when an INSERT/UPDATE violates a unique constraint (SQL Server errors 2627 / 2601),
/// so callers can respond with a conflict instead of a generic database error.
/// </summary>
public sealed class DuplicateRecordException : Exception
{
    public DuplicateRecordException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
