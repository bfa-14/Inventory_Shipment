/* ================================================================== 2. Procedures */


CREATE   PROCEDURE sales.usp_Receipt_Reverse
    @Id         INT,
    @Reason     NVARCHAR(500),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL,
    /* ONLY THE INVOICE CANCELLATION PASSES 1. Nothing the API sends can set it, so a receipt that an
       invoice created cannot be reversed from the receipt screen - see the guard below. */
    @FromInvoiceCancel BIT    = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 71000, 'A reason is required to reverse a receipt.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @Type TINYINT;
        SELECT @Status = Status, @Type = PaymentType FROM sales.Receipts WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;

        IF @Status IS NULL THROW 71006, 'Receipt not found.', 1;
        IF @Status <> 2 THROW 71010, 'Only a posted receipt can be reversed.', 1;

        /* A CASH INVOICE'S RECEIPT IS PART OF THE INVOICE. Reversing it alone would leave an invoice
           that says "Cash" and owes the whole amount. The way to undo it is to cancel the invoice,
           which reverses this receipt in the same transaction and says why. */
        DECLARE @SourceInvoiceId INT = (SELECT SourceSalesDocumentId FROM sales.Receipts WHERE Id = @Id);
        IF @SourceInvoiceId IS NOT NULL AND ISNULL(@FromInvoiceCancel, 0) = 0
        BEGIN
            DECLARE @AutoMsg NVARCHAR(300) = N'This receipt was created automatically when invoice '
                + ISNULL((SELECT DocumentNumber FROM sales.SalesDocuments WHERE Id = @SourceInvoiceId), N'#' + CAST(@SourceInvoiceId AS NVARCHAR(10)))
                + N' was posted. Cancel that invoice to reverse it.';
            THROW 71015, @AutoMsg, 1;
        END
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sales.Receipts WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 71004, 'This receipt was modified by another user. Reload the page and try again.', 1;

        /* A FREE RECEIPT THAT HAS SINCE PAID INVOICES CANNOT JUST VANISH. Those invoices would go back
           to owing money nobody told them about. The allocations have to be removed first, so somebody
           chooses what happens to each invoice. A Sales Allocation receipt's own allocations are part
           of it: reversing it simply stops them counting. */
        IF @Type = 1 AND EXISTS (SELECT 1 FROM sales.ReceiptAllocations WHERE ReceiptId = @Id AND RemovedAtUtc IS NULL)
            THROW 71012, 'This receipt has been applied to invoices since it was posted. Remove those allocations before reversing it.', 1;

        UPDATE sales.Receipts
        SET Status = 3, ReversedAtUtc = SYSUTCDATETIME(), ReversedBy = @UserId, ReverseReason = @Reason,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO sales.ReceiptAudit (ReceiptId, Action, Details, UserId) VALUES (@Id, N'Reversed', @Reason, @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

