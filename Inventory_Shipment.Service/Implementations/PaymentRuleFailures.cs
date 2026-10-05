using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Exceptions;

namespace Inventory_Shipment.Service.Implementations;

/// <summary>
/// The 73xxx THROWs of scripts 46-47, classified once for the supplier payments. THE MESSAGE IS ALWAYS
/// THE PROCEDURE'S and only the code is added, so "Unbalanced Payment - Payment Details Total ... does not
/// match the Payment Amount" reaches the reader exactly as written.
///
/// What the reader can fix by editing the payment is 400; what comes from the state of the world (a row
/// another user changed, an invoice paid since the draft was saved) is 409.
/// </summary>
internal static class PaymentRuleFailures
{
    internal readonly record struct RuleFailure(ErrorType Type, string Message, string Code);

    internal static RuleFailure Describe(BusinessRuleException exception)
        => exception.Number switch
        {
            SqlErrors.PaymentValidation => new(ErrorType.Validation, exception.Message, "VALIDATION"),
            SqlErrors.PaymentConcurrency => new(ErrorType.Conflict, exception.Message, "CONCURRENCY"),
            SqlErrors.PaymentNotEditable => new(ErrorType.Conflict, exception.Message, "NOT_EDITABLE"),
            SqlErrors.PaymentNotFound => new(ErrorType.NotFound, exception.Message, "NOT_FOUND"),
            SqlErrors.PaymentNotBalanced => new(ErrorType.Validation, exception.Message, "UNBALANCED"),
            SqlErrors.PaymentAllocationExceeds => new(ErrorType.Conflict, exception.Message, "ALLOCATION_EXCEEDS_OUTSTANDING"),
            SqlErrors.PaymentInvalidStatus => new(ErrorType.Conflict, exception.Message, "INVALID_STATUS"),
            SqlErrors.PaymentUnappliedExceeded => new(ErrorType.Conflict, exception.Message, "UNAPPLIED_EXCEEDED"),
            SqlErrors.PaymentHasAllocations => new(ErrorType.Conflict, exception.Message, "HAS_ALLOCATIONS"),
            SqlErrors.PaymentAttachmentType => new(ErrorType.Validation, exception.Message, "VALIDATION"),
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
