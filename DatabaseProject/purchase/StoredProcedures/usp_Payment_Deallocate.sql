CREATE   PROCEDURE purchase.usp_Payment_Deallocate
    @AllocationId INT,
    @UserId       INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @PaymentId INT, @Removed DATETIME2(3), @Amount DECIMAL(18,2), @Kind NVARCHAR(10), @DocId INT;
        SELECT @PaymentId = PaymentId, @Removed = RemovedAtUtc, @Amount = AmountDocCurrency, @Kind = DocumentKind,
               @DocId = ISNULL(PurchaseDocumentId, ContainerChargeId)
        FROM purchase.PaymentAllocations WHERE Id = @AllocationId;
        IF @PaymentId IS NULL THROW 73006, 'Allocation not found.', 1;

        DECLARE @Status TINYINT, @Type TINYINT;
        SELECT @Status = Status, @Type = PaymentType FROM purchase.Payments WITH (UPDLOCK, HOLDLOCK) WHERE Id = @PaymentId;
        IF @Removed IS NOT NULL THROW 73010, 'This allocation has already been removed.', 1;
        IF @Status <> 2 THROW 73010, 'Only an allocation of a posted payment can be removed.', 1;
        -- An invoice / charge payment's allocations ARE the payment: taking one away would unbalance it.
        IF @Type <> 1 THROW 73010, 'The allocations of an invoice or charge payment are part of it. Reverse the payment instead.', 1;

        UPDATE purchase.PaymentAllocations SET RemovedAtUtc = SYSUTCDATETIME(), RemovedBy = @UserId WHERE Id = @AllocationId;

        INSERT INTO purchase.PaymentAudit (PaymentId, Action, Details, UserId)
        VALUES (@PaymentId, N'Deallocated', ISNULL((SELECT DocumentNumber FROM purchase.fn_PayableDocument(@Kind, @DocId)), N'#' + CAST(@DocId AS NVARCHAR(10)))
                + N', ' + FORMAT(@Amount, N'N2', N'en-US'), @UserId);

        UPDATE purchase.Payments SET UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @PaymentId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

