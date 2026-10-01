/* ================================================================== 9. Allocate unapplied credit later */

CREATE   PROCEDURE sales.usp_Receipt_Allocate
    @ReceiptId   INT,
    @Allocations sales.tvp_ReceiptAllocation READONLY,
    @RowVersion  BINARY(8) = NULL,
    @UserId      INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM @Allocations) THROW 71000, 'Choose at least one invoice to allocate to.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @Type TINYINT, @ClientId INT, @HeaderBase DECIMAL(18,2);
        SELECT @Status = Status, @Type = PaymentType, @ClientId = ClientId, @HeaderBase = AmountBase
        FROM sales.Receipts WITH (UPDLOCK, HOLDLOCK) WHERE Id = @ReceiptId;

        IF @Status IS NULL THROW 71006, 'Receipt not found.', 1;
        IF @Status <> 2 THROW 71010, 'Only a posted receipt can be allocated.', 1;
        IF @Type <> 1 THROW 71010, 'Only a Free Receipt can be allocated later; a Sales Allocation receipt is already allocated.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sales.Receipts WHERE Id = @ReceiptId AND RowVersion = @RowVersion)
            THROW 71004, 'This receipt was modified by another user. Reload the page and try again.', 1;

        DECLARE @Base NVARCHAR(3) = (SELECT TOP (1) CurrencyCode FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1);
        DECLARE @Msg NVARCHAR(400);

        DECLARE @Locked TABLE (Id INT PRIMARY KEY);
        INSERT INTO @Locked (Id)
        SELECT d.Id FROM sales.SalesDocuments d WITH (UPDLOCK, HOLDLOCK)
        WHERE d.Id IN (SELECT SalesDocumentId FROM @Allocations);

        SELECT TOP (1) @Msg = N'Invoice ' + ISNULL(d.DocumentNumber, N'#' + CAST(a.SalesDocumentId AS NVARCHAR(10))) + N': ' + x.Problem
        FROM @Allocations a
        LEFT JOIN sales.SalesDocuments d ON d.Id = a.SalesDocumentId
        OUTER APPLY sales.fn_InvoiceSettlement(a.SalesDocumentId) st
        CROSS APPLY (SELECT Problem =
            CASE WHEN d.Id IS NULL THEN N'not found.'
                 WHEN st.PaymentStatus IS NULL THEN N'only a posted sales invoice can be paid.'
                 WHEN d.ClientId <> @ClientId THEN N'it belongs to another customer.'
                 WHEN a.Amount IS NULL OR a.Amount <= 0 THEN N'the allocated amount must be greater than zero.'
            END) x
        WHERE x.Problem IS NOT NULL
        ORDER BY a.SalesDocumentId;
        IF @Msg IS NOT NULL THROW 71000, @Msg, 1;

        SELECT TOP (1) @Msg = N'Invoice ' + d.DocumentNumber + N': ' + FORMAT(a.Amount, N'N2', N'en-US') + N' is more than its outstanding '
                              + FORMAT(st.OutstandingAmount, N'N2', N'en-US') + N' ' + c.CurrencyCode + N'.'
        FROM @Allocations a
        INNER JOIN sales.SalesDocuments d ON d.Id = a.SalesDocumentId
        INNER JOIN masterdata.Currencies c ON c.Id = d.CurrencyId
        CROSS APPLY sales.fn_InvoiceSettlement(a.SalesDocumentId) st
        WHERE a.Amount > st.OutstandingAmount + 0.005
        ORDER BY a.SalesDocumentId;
        IF @Msg IS NOT NULL THROW 71009, @Msg, 1;

        /* WHAT IS LEFT TO ALLOCATE: the receipt's base amount less its live allocations. */
        DECLARE @Applied DECIMAL(18,2) = (SELECT ISNULL(SUM(AmountBase), 0) FROM sales.ReceiptAllocations WHERE ReceiptId = @ReceiptId AND RemovedAtUtc IS NULL);
        DECLARE @Unapplied DECIMAL(18,2) = @HeaderBase - @Applied;
        DECLARE @NewBase DECIMAL(18,2) = (SELECT ISNULL(SUM(CONVERT(DECIMAL(18,2), a.Amount / d.ExchangeRate)), 0)
                                          FROM @Allocations a INNER JOIN sales.SalesDocuments d ON d.Id = a.SalesDocumentId);
        IF @NewBase > @Unapplied + 0.01
        BEGIN
            SET @Msg = N'This receipt has only ' + FORMAT(@Unapplied, N'N2', N'en-US') + N' ' + @Base + N' unapplied, but '
                     + FORMAT(@NewBase, N'N2', N'en-US') + N' ' + @Base + N' was allocated.';
            THROW 71011, @Msg, 1;
        END

        INSERT INTO sales.ReceiptAllocations (ReceiptId, SalesDocumentId, AmountInvoiceCurrency, InvoiceExchangeRate, AllocatedBy)
        SELECT @ReceiptId, a.SalesDocumentId, a.Amount, d.ExchangeRate, @UserId
        FROM @Allocations a INNER JOIN sales.SalesDocuments d ON d.Id = a.SalesDocumentId;

        INSERT INTO sales.ReceiptAudit (ReceiptId, Action, Details, UserId)
        VALUES (@ReceiptId, N'Allocated', CAST((SELECT COUNT(*) FROM @Allocations) AS NVARCHAR(10)) + N' invoice(s), '
                + FORMAT(@NewBase, N'N2', N'en-US') + N' ' + @Base, @UserId);

        UPDATE sales.Receipts SET UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @ReceiptId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

