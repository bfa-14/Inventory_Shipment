using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Exceptions;

namespace Inventory_Shipment.Service.Implementations;

/// <summary>
/// The 71xxx THROWs of scripts 35 and 36, classified once for the receipt master data services and
/// the receipts themselves. THE MESSAGE IS ALWAYS THE PROCEDURE'S and only the code is
/// added, so a sentence such as "The currency of an account that receipts already use cannot be
/// changed." reaches the reader exactly as written.
///
/// Refusals that come from the state of the world rather than from the request are 409: a code
/// that is taken, a row another user changed, a list entry receipts already use.
/// </summary>
internal static class ReceiptRuleFailures
{
    internal readonly record struct RuleFailure(ErrorType Type, string Message, string Code);

    internal static RuleFailure Describe(BusinessRuleException exception)
        => exception.Number switch
        {
            SqlErrors.ReceiptValidation => new(ErrorType.Validation, exception.Message, "VALIDATION"),
            SqlErrors.ReceiptConcurrency => new(ErrorType.Conflict, exception.Message, "CONCURRENCY"),
            SqlErrors.ReceiptNotEditable => new(ErrorType.Conflict, exception.Message, "NOT_EDITABLE"),
            SqlErrors.ReceiptNotFound => new(ErrorType.NotFound, exception.Message, "NOT_FOUND"),
            // The reader can fix an unbalanced receipt, so it is a validation; the rest describe the world.
            SqlErrors.ReceiptNotBalanced => new(ErrorType.Validation, exception.Message, "UNBALANCED"),
            SqlErrors.ReceiptAllocationExceeds => new(ErrorType.Conflict, exception.Message, "ALLOCATION_EXCEEDS_OUTSTANDING"),
            SqlErrors.ReceiptInvalidStatus => new(ErrorType.Conflict, exception.Message, "INVALID_STATUS"),
            SqlErrors.ReceiptUnappliedExceeded => new(ErrorType.Conflict, exception.Message, "UNAPPLIED_EXCEEDED"),
            SqlErrors.ReceiptHasAllocations => new(ErrorType.Conflict, exception.Message, "HAS_ALLOCATIONS"),
            SqlErrors.ReceiptDuplicateCode => new(ErrorType.Conflict, exception.Message, "DUPLICATE_CODE"),
            SqlErrors.ReceiptMasterInUse => new(ErrorType.Conflict, exception.Message, "IN_USE"),
            SqlErrors.ReceiptAutomatic => new(ErrorType.Conflict, exception.Message, "AUTOMATIC_RECEIPT"),
            SqlErrors.ReceiptAttachmentType => new(ErrorType.Validation, exception.Message, "VALIDATION"),
            _ => new(ErrorType.Validation, exception.Message, "VALIDATION"),
        };

    internal static Result<T> Failure<T>(BusinessRuleException exception)
    {
        var failure = Describe(exception);
        return Result<T>.Failure(failure.Type, failure.Message, failure.Code);
    }

    internal static Result Failure(BusinessRuleException exception)
    {
        var failure = Describe(exception);
        return Result.Failure(failure.Type, failure.Message, failure.Code);
    }

    internal static Result<T> Forbidden<T>(string permission)
        => Result<T>.Failure(ErrorType.Forbidden, $"This action needs the {permission} permission.", "FORBIDDEN");

    internal static Result Forbidden(string permission)
        => Result.Failure(ErrorType.Forbidden, $"This action needs the {permission} permission.", "FORBIDDEN");

    internal static byte[]? ToRowVersion(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        return Convert.TryFromBase64String(value, new byte[8], out var written) && written == 8
            ? Convert.FromBase64String(value)
            : null;
    }
}
