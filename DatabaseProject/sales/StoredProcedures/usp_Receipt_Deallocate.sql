CREATE   PROCEDURE sales.usp_Receipt_Deallocate
    @AllocationId INT,
    @UserId       INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @ReceiptId INT, @Removed DATETIME2(3), @Amount DECIMAL(18,2), @InvoiceId INT;
        SELECT @ReceiptId = ReceiptId, @Removed = RemovedAtUtc, @Amount = AmountInvoiceCurrency, @InvoiceId = SalesDocumentId
        FROM sales.ReceiptAllocations WHERE Id = @AllocationId;
        IF @ReceiptId IS NULL THROW 71006, 'Allocation not found.', 1;

        DECLARE @Status TINYINT, @Type TINYINT;
        SELECT @Status = Status, @Type = PaymentType FROM sales.Receipts WITH (UPDLOCK, HOLDLOCK) WHERE Id = @ReceiptId;
        IF @Removed IS NOT NULL THROW 71010, 'This allocation has already been removed.', 1;
        IF @Status <> 2 THROW 71010, 'Only an allocation of a posted receipt can be removed.', 1;
        -- A Sales Allocation receipt's allocations ARE the receipt: taking one away would unbalance it.
        IF @Type <> 1 THROW 71010, 'The allocations of a Sales Allocation receipt are part of it. Reverse the receipt instead.', 1;

        UPDATE sales.ReceiptAllocations SET RemovedAtUtc = SYSUTCDATETIME(), RemovedBy = @UserId WHERE Id = @AllocationId;

        INSERT INTO sales.ReceiptAudit (ReceiptId, Action, Details, UserId)
        VALUES (@ReceiptId, N'Deallocated',
                N'Invoice ' + ISNULL((SELECT DocumentNumber FROM sales.SalesDocuments WHERE Id = @InvoiceId), N'#' + CAST(@InvoiceId AS NVARCHAR(10)))
                + N', ' + FORMAT(@Amount, N'N2', N'en-US'), @UserId);

        UPDATE sales.Receipts SET UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @ReceiptId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

