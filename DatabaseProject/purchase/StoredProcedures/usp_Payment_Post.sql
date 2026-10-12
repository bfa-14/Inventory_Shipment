/* ================================================================== 4. Post */

CREATE   PROCEDURE purchase.usp_Payment_Post
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @Type TINYINT, @PayeeId INT, @Amount DECIMAL(18,2), @Number NVARCHAR(30), @Cur NVARCHAR(10);
        SELECT @Status = p.Status, @Type = p.PaymentType, @PayeeId = p.PayeeId, @Amount = p.Amount, @Number = p.PaymentNumber, @Cur = c.CurrencyCode
        FROM purchase.Payments p WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN masterdata.Currencies c ON c.Id = p.CurrencyId
        WHERE p.Id = @Id;

        IF @Status IS NULL THROW 73006, 'Payment not found.', 1;
        IF @Status <> 1 THROW 73010, 'Only a draft payment can be posted.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.Payments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 73004, 'This payment was modified by another user. Reload the page and try again.', 1;

        DECLARE @Msg NVARCHAR(400);

        IF NOT EXISTS (SELECT 1 FROM purchase.PaymentLines WHERE PaymentId = @Id)
            THROW 73000, 'At least one Payment Detail line is required before the payment can be posted.', 1;
        IF NOT EXISTS (SELECT 1 FROM masterdata.Parties p INNER JOIN purchase.Payments x ON x.PayeeId = p.Id WHERE x.Id = @Id AND p.IsActive = 1 AND p.IsSupplier = 1)
            THROW 73000, 'The payee is no longer an active supplier.', 1;

        /* A LIST ENTRY CAN BE DEACTIVATED BETWEEN THE SAVE AND THE POST: the draft must still be valid when
           it moves money. */
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': '
                              + CASE WHEN pm.IsActive = 0 THEN N'the payment method ' + pm.MethodCode + N' is no longer active.'
                                     ELSE N'the account ' + a.AccountCode + N' is no longer active.' END
        FROM purchase.PaymentLines l
        INNER JOIN masterdata.PaymentMethods pm  ON pm.Id = l.PaymentMethodId
        INNER JOIN masterdata.CashBankAccounts a ON a.Id = l.CashBankAccountId
        WHERE l.PaymentId = @Id AND (pm.IsActive = 0 OR a.IsActive = 0)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 73000, @Msg, 1;

        /* THE KEY CONTROL (section 3): header = payment details, in the PAYMENT currency, within 0.01 -
           converting several currencies rounds each line. */
        DECLARE @LinesTotal DECIMAL(18,2) = (SELECT ISNULL(SUM(AmountPaymentCurrency), 0) FROM purchase.PaymentLines WHERE PaymentId = @Id);
        IF ABS(@Amount - @LinesTotal) > 0.01
        BEGIN
            SET @Msg = N'Unbalanced Payment - Payment Details Total (' + FORMAT(@LinesTotal, N'N2', N'en-US') + N' ' + @Cur
                     + N') does not match the Payment Amount (' + FORMAT(@Amount, N'N2', N'en-US') + N' ' + @Cur + N').';
            THROW 73008, @Msg, 1;
        END

        IF @Type IN (2, 3)
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM purchase.PaymentAllocations WHERE PaymentId = @Id)
                THROW 73008, 'Unbalanced Allocation - Total allocated amount must equal the Payment Amount. Allocate the payment to at least one document.', 1;

            DECLARE @AllocTotal DECIMAL(18,2) = (SELECT ISNULL(SUM(AmountPaymentCurrency), 0) FROM purchase.PaymentAllocations WHERE PaymentId = @Id);
            IF ABS(@Amount - @AllocTotal) > 0.01
            BEGIN
                SET @Msg = N'Unbalanced Allocation - Total allocated amount (' + FORMAT(@AllocTotal, N'N2', N'en-US') + N' ' + @Cur
                         + N') must equal the Payment Amount (' + FORMAT(@Amount, N'N2', N'en-US') + N' ' + @Cur + N').';
                THROW 73008, @Msg, 1;
            END

            /* LOCK THE DOCUMENTS, THEN READ WHAT THEY OWE. Two drafts paying the same invoice each looked
               fine when saved; whichever posts second must see the first one's money. */
            DECLARE @LockedInv TABLE (Id INT PRIMARY KEY);
            INSERT INTO @LockedInv (Id)
            SELECT d.Id FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
            WHERE d.Id IN (SELECT PurchaseDocumentId FROM purchase.PaymentAllocations WHERE PaymentId = @Id AND PurchaseDocumentId IS NOT NULL);
            DECLARE @LockedCh TABLE (Id INT PRIMARY KEY);
            INSERT INTO @LockedCh (Id)
            SELECT c.Id FROM logistics.ContainerCharges c WITH (UPDLOCK, HOLDLOCK)
            WHERE c.Id IN (SELECT ContainerChargeId FROM purchase.PaymentAllocations WHERE PaymentId = @Id AND ContainerChargeId IS NOT NULL);

            SELECT TOP (1) @Msg = CASE a.DocumentKind WHEN N'PINV' THEN N'Purchase invoice ' ELSE N'Charge ' END + pd.DocumentNumber + N': '
                                  + CASE WHEN pd.PaymentStatus IS NULL THEN N'it is no longer posted, so it cannot be paid.'
                                         ELSE N'it does not belong to this payee.' END
            FROM purchase.PaymentAllocations a
            CROSS APPLY purchase.fn_PayableDocument(a.DocumentKind, ISNULL(a.PurchaseDocumentId, a.ContainerChargeId)) pd
            WHERE a.PaymentId = @Id AND (pd.PaymentStatus IS NULL OR ISNULL(pd.PayeeId, -1) <> @PayeeId)
            ORDER BY pd.DocumentNumber;
            IF @Msg IS NOT NULL THROW 73000, @Msg, 1;

            SELECT TOP (1) @Msg = CASE a.DocumentKind WHEN N'PINV' THEN N'Purchase invoice ' ELSE N'Charge ' END + pd.DocumentNumber + N': '
                                  + FORMAT(a.AmountDocCurrency, N'N2', N'en-US') + N' is more than its outstanding '
                                  + FORMAT(pd.OutstandingAmount, N'N2', N'en-US') + N' ' + pd.CurrencyCode
                                  + N' - another payment may have been posted against it since this draft was saved.'
            FROM purchase.PaymentAllocations a
            CROSS APPLY purchase.fn_PayableDocument(a.DocumentKind, ISNULL(a.PurchaseDocumentId, a.ContainerChargeId)) pd
            WHERE a.PaymentId = @Id AND a.AmountDocCurrency > pd.OutstandingAmount + 0.005
            ORDER BY pd.DocumentNumber;
            IF @Msg IS NOT NULL THROW 73009, @Msg, 1;
        END

        UPDATE purchase.Payments
        SET Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO purchase.PaymentAudit (PaymentId, Action, Details, UserId)
        VALUES (@Id, N'Posted', @Number + N' - ' + FORMAT(@Amount, N'N2', N'en-US') + N' ' + @Cur, @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

