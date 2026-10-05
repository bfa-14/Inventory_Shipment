using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Exceptions;

namespace Inventory_Shipment.Service.Implementations;

/// <summary>
/// The 69xxx / 70xxx THROWs of scripts 24 and 27, classified once for the container, movement and
/// container charge services and the logistics master data services. THE MESSAGE IS ALWAYS THE PROCEDURE'S — "Line 2: MOTO-01 - 90 base units allocated
/// but only 70 remain on invoice line 1 of PINV-2026-0003." — and only the code is added.
///
/// Refusals that come from the state of the world rather than from the request are 409: over
/// capacity (the caller may confirm and retry), an allocation above the invoice, an invoice another
/// document holds, a used master data row, stock already gone.
/// </summary>
internal static class LogisticsRuleFailures
{
    internal readonly record struct RuleFailure(ErrorType Type, string Message, string Code);

    /// <param name="duplicateCode">69013 is a container number on the containers, a code on the master data.</param>
    internal static RuleFailure Describe(BusinessRuleException exception, string duplicateCode = "DUPLICATE_CONTAINER_NO")
        => exception.Number switch
        {
            SqlErrors.ContainerValidation => new(ErrorType.Validation, exception.Message, "VALIDATION"),
            SqlErrors.ContainerConcurrency => new(ErrorType.Conflict, exception.Message, "CONCURRENCY"),
            SqlErrors.ContainerNotEditable => new(ErrorType.Conflict, exception.Message, "NOT_EDITABLE"),
            SqlErrors.ContainerNotFound => new(ErrorType.NotFound, exception.Message, "NOT_FOUND"),
            SqlErrors.ContainerOverCapacity => new(ErrorType.Conflict, exception.Message, "OVER_CAPACITY"),
            SqlErrors.ContainerAllocationExceedsInvoice => new(ErrorType.Conflict, exception.Message, "ALLOCATION_EXCEEDS_INVOICE"),
            SqlErrors.ContainerNoLines => new(ErrorType.Validation, exception.Message, "NO_LINES"),
            SqlErrors.ContainerInvalidStatus => new(ErrorType.Conflict, exception.Message, "INVALID_STATUS"),
            SqlErrors.ContainerAlreadyOffloaded => new(ErrorType.Conflict, exception.Message, "ALREADY_OFFLOADED"),
            SqlErrors.ContainerInvoiceInUse => new(ErrorType.Conflict, exception.Message, "INVOICE_IN_USE"),
            SqlErrors.ContainerDuplicate => new(ErrorType.Conflict, exception.Message, duplicateCode),
            SqlErrors.LogisticsMasterInUse => new(ErrorType.Conflict, exception.Message, "IN_USE"),
            SqlErrors.ContainerInsufficientStock => new(ErrorType.Conflict, exception.Message, "INSUFFICIENT_STOCK"),
            SqlErrors.ContainerNotFullyInvoiced => new(ErrorType.Conflict, exception.Message, "NOT_FULLY_INVOICED"),
            SqlErrors.ContainerLineInvoiced => new(ErrorType.Conflict, exception.Message, "LINE_INVOICED"),
            SqlErrors.ContainerCostAdjusted => new(ErrorType.Conflict, exception.Message, "COST_ADJUSTED"),
            SqlErrors.LogisticsValidation => new(ErrorType.Validation, exception.Message, "VALIDATION"),
            SqlErrors.LogisticsDuplicate => new(ErrorType.Conflict, exception.Message, "DUPLICATE"),
            SqlErrors.LogisticsConcurrency => new(ErrorType.Conflict, exception.Message, "CONCURRENCY"),
            SqlErrors.LogisticsNotEditable => new(ErrorType.Conflict, exception.Message, "NOT_EDITABLE"),
            SqlErrors.LogisticsNotFound => new(ErrorType.NotFound, exception.Message, "NOT_FOUND"),
            SqlErrors.LogisticsInvalidStatus => new(ErrorType.Conflict, exception.Message, "INVALID_STATUS"),
            SqlErrors.ContainerBusy => new(ErrorType.Conflict, exception.Message, "CONTAINER_BUSY"),
            SqlErrors.ChargeAllocationDataMissing => new(ErrorType.Conflict, exception.Message, "ALLOCATION_DATA_MISSING"),
            SqlErrors.LogisticsInUse => new(ErrorType.Conflict, exception.Message, "IN_USE"),
            SqlErrors.ContainerNotAtFrom => new(ErrorType.Conflict, exception.Message, "CONTAINER_NOT_AT_FROM"),
            SqlErrors.PreviousMovementOpen => new(ErrorType.Conflict, exception.Message, "PREVIOUS_MOVEMENT_OPEN"),
            SqlErrors.ContainerAttachmentType => new(ErrorType.Validation, exception.Message, "VALIDATION"),
            SqlErrors.PurchaseExporterReferenceRequired => new(ErrorType.Validation, exception.Message, "EXPORTER_REFERENCE_REQUIRED"),
            SqlErrors.PurchaseContainerLineInvalid => new(ErrorType.Conflict, exception.Message, "CONTAINER_LINE_INVALID"),
            SqlErrors.PurchaseChargesOnContainer => new(ErrorType.Conflict, exception.Message, "CHARGES_ON_CONTAINER"),
            SqlErrors.PurchaseOrderInContainers => new(ErrorType.Conflict, exception.Message, "PO_IN_CONTAINERS"),
            SqlErrors.LandedCostImportedInvoice => new(ErrorType.Conflict, exception.Message, "IMPORTED_INVOICE"),
            // Script 51: the container procedures called for an invoice check its rules first.
            SqlErrors.PurchaseInvoiceCannotTakeContainers => new(ErrorType.Conflict, exception.Message, "CANNOT_TAKE_CONTAINERS"),
            SqlErrors.PurchaseInvoiceTooManyPieces => new(ErrorType.Validation, exception.Message, "TOO_MANY_PIECES"),
            _ => new(ErrorType.Validation, exception.Message, "VALIDATION"),
        };

    internal static Result<T> Failure<T>(BusinessRuleException exception, string duplicateCode = "DUPLICATE_CONTAINER_NO")
    {
        var failure = Describe(exception, duplicateCode);
        return Result<T>.Failure(failure.Type, failure.Message, failure.Code);
    }

    internal static Result Failure(BusinessRuleException exception, string duplicateCode = "DUPLICATE_CONTAINER_NO")
    {
        var failure = Describe(exception, duplicateCode);
        return Result.Failure(failure.Type, failure.Message, failure.Code);
    }

    internal static Result<T> Forbidden<T>(string permission)
        => Result<T>.Failure(ErrorType.Forbidden, $"This action needs the {permission} permission.", "FORBIDDEN");

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
