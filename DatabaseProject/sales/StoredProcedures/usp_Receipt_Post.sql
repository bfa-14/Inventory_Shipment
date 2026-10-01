/* ================================================================== 6. Post */

CREATE   PROCEDURE sales.usp_Receipt_Post
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @Type TINYINT, @ClientId INT, @HeaderBase DECIMAL(18,2), @Number NVARCHAR(30);
        SELECT @Status = Status, @Type = PaymentType, @ClientId = ClientId, @HeaderBase = AmountBase, @Number = ReceiptNumber
        FROM sales.Receipts WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;

        IF @Status IS NULL THROW 71006, 'Receipt not found.', 1;
        IF @Status <> 1 THROW 71010, 'Only a draft receipt can be posted.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sales.Receipts WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 71004, 'This receipt was modified by another user. Reload the page and try again.', 1;

        DECLARE @Base NVARCHAR(3) = (SELECT TOP (1) CurrencyCode FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1);
        DECLARE @Msg NVARCHAR(400);

        IF NOT EXISTS (SELECT 1 FROM sales.ReceiptLines WHERE ReceiptId = @Id)
            THROW 71000, 'A receipt needs at least one payment line before it can be posted.', 1;

        /* A LIST ENTRY CAN BE DEACTIVATED BETWEEN THE SAVE AND THE POST. The draft was valid when it was
           saved; it must still be valid when it moves money. */
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': '
                              + CASE WHEN pm.IsActive = 0 THEN N'the payment method ' + pm.MethodCode + N' is no longer active.'
                                     ELSE N'the account ' + a.AccountCode + N' is no longer active.' END
        FROM sales.ReceiptLines l
        INNER JOIN masterdata.PaymentMethods pm ON pm.Id = l.PaymentMethodId
        INNER JOIN masterdata.CashBankAccounts a ON a.Id = l.CashBankAccountId
        WHERE l.ReceiptId = @Id AND (pm.IsActive = 0 OR a.IsActive = 0)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 71000, @Msg, 1;

        /* THE KEY CONTROL: header = payment lines (= allocations, when there are any). Compared in the
           BASE currency, within 0.01 - converting several currencies rounds each line, and an exact
           match would refuse receipts that are right to the cent. */
        DECLARE @LinesBase DECIMAL(18,2) = (SELECT ISNULL(SUM(AmountBase), 0) FROM sales.ReceiptLines WHERE ReceiptId = @Id);
        IF ABS(@HeaderBase - @LinesBase) > 0.01
        BEGIN
            SET @Msg = N'Unbalanced Receipt: Payment Details Total (' + @Base + N') ' + FORMAT(@LinesBase, N'N2', N'en-US')
                     + N' does not match the Receipt Amount (' + @Base + N') ' + FORMAT(@HeaderBase, N'N2', N'en-US') + N'.';
            THROW 71008, @Msg, 1;
        END

        IF @Type = 2
        BEGIN
            DECLARE @AllocBase DECIMAL(18,2) = (SELECT ISNULL(SUM(AmountBase), 0) FROM sales.ReceiptAllocations WHERE ReceiptId = @Id);
            IF ABS(@HeaderBase - @AllocBase) > 0.01
            BEGIN
                SET @Msg = N'Unbalanced Allocation: Total Allocated (' + @Base + N') ' + FORMAT(@AllocBase, N'N2', N'en-US')
                         + N' does not match the Receipt Amount (' + @Base + N') ' + FORMAT(@HeaderBase, N'N2', N'en-US') + N'.';
                THROW 71008, @Msg, 1;
            END

            /* LOCK THE INVOICES, THEN READ WHAT THEY OWE. Two drafts that allocate the same invoice
               each looked fine when they were saved. Whichever posts second must see the first one's
               money, and it can only do that if the read happens after the other transaction has
               finished - which the lock on the invoice rows guarantees. */
            DECLARE @Locked TABLE (Id INT PRIMARY KEY);
            INSERT INTO @Locked (Id)
            SELECT d.Id
            FROM sales.SalesDocuments d WITH (UPDLOCK, HOLDLOCK)
            WHERE d.Id IN (SELECT SalesDocumentId FROM sales.ReceiptAllocations WHERE ReceiptId = @Id);

            SET @Msg = NULL;
            SELECT TOP (1) @Msg = N'Invoice ' + d.DocumentNumber + N': '
                                  + CASE WHEN st.PaymentStatus IS NULL THEN N'it is no longer a posted invoice, so it cannot be paid.'
                                         WHEN d.ClientId <> @ClientId THEN N'it belongs to another customer.' END
            FROM sales.ReceiptAllocations a
            INNER JOIN sales.SalesDocuments d ON d.Id = a.SalesDocumentId
            OUTER APPLY sales.fn_InvoiceSettlement(a.SalesDocumentId) st
            WHERE a.ReceiptId = @Id AND (st.PaymentStatus IS NULL OR d.ClientId <> @ClientId)
            ORDER BY d.DocumentNumber;
            IF @Msg IS NOT NULL THROW 71000, @Msg, 1;

            SELECT TOP (1) @Msg = N'Invoice ' + d.DocumentNumber + N': ' + FORMAT(a.AmountInvoiceCurrency, N'N2', N'en-US')
                                  + N' is more than its outstanding ' + FORMAT(st.OutstandingAmount, N'N2', N'en-US') + N' ' + c.CurrencyCode
                                  + N' - another receipt may have been posted against it since this draft was saved.'
            FROM sales.ReceiptAllocations a
            INNER JOIN sales.SalesDocuments d ON d.Id = a.SalesDocumentId
            INNER JOIN masterdata.Currencies c ON c.Id = d.CurrencyId
            CROSS APPLY sales.fn_InvoiceSettlement(a.SalesDocumentId) st
            WHERE a.ReceiptId = @Id AND a.AmountInvoiceCurrency > st.OutstandingAmount + 0.005
            ORDER BY d.DocumentNumber;
            IF @Msg IS NOT NULL THROW 71009, @Msg, 1;
        END

        UPDATE sales.Receipts
        SET Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO sales.ReceiptAudit (ReceiptId, Action, Details, UserId)
        VALUES (@Id, N'Posted', @Number + N' - ' + FORMAT(@HeaderBase, N'N2', N'en-US') + N' ' + @Base, @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

