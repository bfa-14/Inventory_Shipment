using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Exceptions;

namespace Inventory_Shipment.Service.Implementations;

/// <summary>
/// The THROWs of the approval procedures (scripts 26 and 42), classified once for the approval service.
/// THE MESSAGE IS ALWAYS THE PROCEDURE'S - "This order was already approved by Manager One on 1 Oct 2026."
/// - and only the status and the code are added: 410 for a link that can no longer be used, 403 for a
/// user who may not decide, 409 for the state of the order or of the settings.
/// </summary>
internal static class ApprovalRuleFailures
{
    internal readonly record struct RuleFailure(ErrorType Type, string Message, string Code);

    internal static RuleFailure Describe(BusinessRuleException exception) => exception.Number switch
    {
        SqlErrors.PurchaseOrderApprovalRequired => new(ErrorType.Validation, exception.Message, "VALIDATION"),
        SqlErrors.ApprovalLinkNotUsable => new(ErrorType.Gone, exception.Message, "LINK_NOT_USABLE"),
        SqlErrors.ApprovalNoApprover => new(ErrorType.Conflict, exception.Message, "NO_APPROVER"),
        SqlErrors.ApprovalSupplierWithoutEmail => new(ErrorType.Validation, exception.Message, "VALIDATION"),
        SqlErrors.ApprovalNotApprover => new(ErrorType.Forbidden, exception.Message, "NOT_APPROVER"),
        SqlErrors.ApprovalNotNeeded => new(ErrorType.Conflict, exception.Message, "APPROVAL_NOT_NEEDED"),
        SqlErrors.ApprovalSelfApproval => new(ErrorType.Forbidden, exception.Message, "SELF_APPROVAL"),
        SqlErrors.ApprovalSettingsValidation => new(ErrorType.Validation, exception.Message, "VALIDATION"),
        SqlErrors.PurchaseDocumentConcurrency => new(ErrorType.Conflict, exception.Message, "CONCURRENCY"),
        SqlErrors.PurchaseDocumentNotFound => new(ErrorType.NotFound, exception.Message, "NOT_FOUND"),
        SqlErrors.PurchaseDocumentInvalidStatus => new(ErrorType.Conflict, exception.Message, "INVALID_STATUS"),
        SqlErrors.PurchaseDocumentNoLines => new(ErrorType.Validation, exception.Message, "NO_LINES"),
        SqlErrors.PurchaseDocumentMasterInactive => new(ErrorType.Validation, exception.Message, "MASTER_INACTIVE"),
        _ => new(ErrorType.Validation, exception.Message, "VALIDATION"),
    };

    internal static Result<T> Failure<T>(BusinessRuleException exception)
    {
        var failure = Describe(exception);
        return Result<T>.Failure(failure.Type, failure.Message, failure.Code);
    }
}
