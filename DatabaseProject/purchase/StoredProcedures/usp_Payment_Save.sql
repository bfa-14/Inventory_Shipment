
/* ================================================================== 4. Payments */

CREATE   PROCEDURE purchase.usp_Payment_Save
    @Id           INT            = NULL,           -- NULL = create
    @PaymentDate  DATE,
    @PayeeId      INT,
    @BranchId     INT,
    @PaymentType  TINYINT        = 1,              -- 1 Free Payment, 2 Purchase Invoice Payment, 3 Container Charge Payment
    @CurrencyId   INT,
    @Amount       DECIMAL(18,2),
    @ExchangeRate DECIMAL(18,6)  = NULL,           -- NULL = the official rate on the payment date
    @Reference    NVARCHAR(100)  = NULL,
    @Notes        NVARCHAR(500)  = NULL,
    @Lines        purchase.tvp_PaymentLine READONLY,
    @Allocations  purchase.tvp_PaymentAllocation READONLY,
    @AllocationContainers purchase.tvp_PaymentAllocationContainer READONLY,   -- script 73: the container split of the invoice allocations
    @RowVersion   BINARY(8)      = NULL,
    @UserId       INT            = NULL,
    @NewId        INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    SET @Reference = NULLIF(LTRIM(RTRIM(@Reference)), N'');
    SET @PaymentType = ISNULL(@PaymentType, 1);

    IF @PaymentDate IS NULL THROW 73000, 'Payment Date is required.', 1;
    -- A day of tolerance, as on the invoices: the date is the reader's local one, the check is UTC.
    IF @PaymentDate > DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE)) THROW 73000, 'Payment Date cannot be in the future.', 1;
    IF @PayeeId IS NULL OR NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @PayeeId AND IsSupplier = 1 AND IsActive = 1)
        THROW 73000, 'Payee not found, inactive, or not a supplier.', 1;
    IF @BranchId IS NULL OR NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 73000, 'Branch not found or inactive.', 1;
    IF @PaymentType NOT IN (1, 2, 3) THROW 73000, 'Payment Type must be Free Payment, Purchase Invoice Payment or Container Charge Payment.', 1;
    IF @CurrencyId IS NULL OR NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsActive = 1)
        THROW 73000, 'Payment Currency not found or inactive.', 1;
    IF @Amount IS NULL OR @Amount <= 0 THROW 73000, 'Payment Amount must be greater than zero.', 1;
    IF @ExchangeRate IS NOT NULL AND @ExchangeRate <= 0 THROW 73000, 'Exchange rate must be greater than zero.', 1;

    /* THE HEADER RATE. The base currency is always 1, whatever was typed; any other takes what was typed,
       else the official rate on the payment date, else it is an error the reader can fix. */
    IF EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsBaseCurrency = 1) SET @ExchangeRate = 1;
    SET @ExchangeRate = COALESCE(@ExchangeRate, masterdata.fn_GetRate(@CurrencyId, 1, @PaymentDate));
    IF @ExchangeRate IS NULL
    BEGIN
        DECLARE @RateMsg NVARCHAR(300) = N'No official exchange rate is defined for ' + (SELECT CurrencyCode FROM masterdata.Currencies WHERE Id = @CurrencyId)
            + N' on or before ' + CONVERT(NVARCHAR(10), @PaymentDate, 120) + N'. Add one in Master Data > Exchange Rates or enter the rate manually.';
        THROW 73000, @RateMsg, 1;
    END

    /* EVERY LINE IS JUDGED, and the first failing one is named. */
    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' + x.Problem
    FROM @Lines l
    LEFT JOIN masterdata.PaymentMethods pm   ON pm.Id = l.PaymentMethodId
    LEFT JOIN masterdata.Currencies cu       ON cu.Id = l.CurrencyId
    LEFT JOIN masterdata.CashBankAccounts a  ON a.Id = l.CashBankAccountId
    LEFT JOIN masterdata.Currencies ac       ON ac.Id = a.CurrencyId
    CROSS APPLY (SELECT Problem =
        CASE WHEN pm.Id IS NULL OR pm.IsActive = 0 THEN N'payment method not found or inactive.'
             WHEN cu.Id IS NULL OR cu.IsActive = 0 THEN N'currency not found or inactive.'
             WHEN l.Amount IS NULL OR l.Amount <= 0 THEN N'amount must be greater than zero.'
             WHEN l.RateToPayment IS NOT NULL AND l.RateToPayment <= 0 THEN N'exchange rate must be greater than zero.'
             WHEN a.Id IS NULL OR a.IsActive = 0 THEN N'cash / bank account not found or inactive.'
             WHEN a.CurrencyId <> l.CurrencyId THEN N'account ' + a.AccountCode + N' holds ' + ac.CurrencyCode + N', not ' + cu.CurrencyCode + N'.'
             WHEN a.BranchId IS NOT NULL AND a.BranchId <> @BranchId THEN N'account ' + a.AccountCode + N' is not available for this payment''s branch.'
             WHEN pm.MethodCode = N'CHQ' AND NULLIF(LTRIM(RTRIM(l.ChequeNo)), N'') IS NULL THEN N'a cheque needs its Cheque No.'
             WHEN pm.MethodCode = N'CHQ' AND l.ChequeDate IS NULL THEN N'a cheque needs its Cheque Date.'
             WHEN pm.MethodCode = N'CHQ' AND l.ChequeDueDate IS NOT NULL AND l.ChequeDueDate < l.ChequeDate THEN N'the cheque''s due date is before its date.'
             WHEN l.RateToPayment IS NULL AND purchase.fn_RateToPayment(l.CurrencyId, @CurrencyId, @ExchangeRate, @PaymentDate) IS NULL
                  THEN N'no official exchange rate is defined for ' + cu.CurrencyCode + N' on or before ' + CONVERT(NVARCHAR(10), @PaymentDate, 120) + N'.'
        END) x
    WHERE x.Problem IS NOT NULL
    ORDER BY l.LineNumber;
    IF @Msg IS NOT NULL THROW 73000, @Msg, 1;

    /* ALLOCATIONS: none on a Free payment; only the type's own kind of document otherwise - a payment never
       mixes invoices and charges. Only POSTED documents of THIS payee, never above what they still owe
       (posted payments only: a competing draft is settled under a lock when one of them posts). */
    IF @PaymentType = 1 AND EXISTS (SELECT 1 FROM @Allocations)
        THROW 73000, 'A Free Payment cannot be allocated to documents. Choose Purchase Invoice or Container Charge Payment, or allocate it after posting.', 1;
    IF @PaymentType = 2 AND EXISTS (SELECT 1 FROM @Allocations WHERE DocumentKind <> N'PINV')
        THROW 73000, 'A Purchase Invoice Payment can only be allocated to purchase invoices.', 1;
    IF @PaymentType = 3 AND EXISTS (SELECT 1 FROM @Allocations WHERE DocumentKind <> N'CHARGE')
        THROW 73000, 'A Container Charge Payment can only be allocated to container charges.', 1;

    SELECT TOP (1) @Msg = CASE a.DocumentKind WHEN N'PINV' THEN N'Purchase invoice ' ELSE N'Charge ' END
                          + ISNULL(pd.DocumentNumber, N'#' + CAST(a.DocumentId AS NVARCHAR(10))) + N': ' + x.Problem
    FROM @Allocations a
    OUTER APPLY purchase.fn_PayableDocument(a.DocumentKind, a.DocumentId) pd
    CROSS APPLY (SELECT Problem =
        CASE WHEN pd.DocumentId IS NULL THEN N'not found.'
             WHEN pd.PaymentStatus IS NULL THEN N'only a posted document can be paid.'
             WHEN ISNULL(pd.PayeeId, -1) <> @PayeeId THEN N'it does not belong to this payee.'
             WHEN a.Amount IS NULL OR a.Amount <= 0 THEN N'the allocated amount must be greater than zero.'
             WHEN a.RateToPayment IS NOT NULL AND a.RateToPayment <= 0 THEN N'exchange rate must be greater than zero.'
             WHEN a.RateToPayment IS NULL AND purchase.fn_RateToPayment(pd.CurrencyId, @CurrencyId, @ExchangeRate, @PaymentDate) IS NULL
                  THEN N'no official exchange rate is defined for ' + pd.CurrencyCode + N' on or before ' + CONVERT(NVARCHAR(10), @PaymentDate, 120) + N'.'
        END) x
    WHERE x.Problem IS NOT NULL
    ORDER BY a.DocumentKind, a.DocumentId;
    IF @Msg IS NOT NULL THROW 73000, @Msg, 1;

    SELECT TOP (1) @Msg = CASE a.DocumentKind WHEN N'PINV' THEN N'Purchase invoice ' ELSE N'Charge ' END + pd.DocumentNumber + N': '
                          + FORMAT(a.Amount, N'N2', N'en-US') + N' is more than its outstanding ' + FORMAT(pd.OutstandingAmount, N'N2', N'en-US') + N' ' + pd.CurrencyCode + N'.'
    FROM @Allocations a
    CROSS APPLY purchase.fn_PayableDocument(a.DocumentKind, a.DocumentId) pd
    WHERE a.Amount > pd.OutstandingAmount + 0.005
    ORDER BY a.DocumentKind, a.DocumentId;
    IF @Msg IS NOT NULL THROW 73009, @Msg, 1;

    -- Script 73: the container split may be incomplete on a draft, never wrong.
    -- One container and nothing else: the whole amount is that container's, without a split typed by hand.
    DECLARE @Split purchase.tvp_PaymentAllocationContainer;
    INSERT INTO @Split (DocumentId, ContainerId, Amount) SELECT DocumentId, ContainerId, Amount FROM @AllocationContainers;
    INSERT INTO @Split (DocumentId, ContainerId, Amount)
    SELECT a.DocumentId, s.ContainerKey, a.Amount
    FROM @Allocations a
    CROSS APPLY purchase.fn_InvoiceContainerSettlement(a.DocumentId) s
    WHERE a.DocumentKind = N'PINV' AND s.HasContainers = 1 AND s.NeedsSplit = 0 AND a.Amount > 0
      AND NOT EXISTS (SELECT 1 FROM @AllocationContainers c WHERE c.DocumentId = a.DocumentId);
    EXEC purchase.usp_Payment_CheckContainerSplit @Allocations, @Split, 0;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Id IS NULL
        BEGIN
            -- Numbered at the FIRST SAVE, inside this transaction: a save that fails gives the number back.
            DECLARE @Number NVARCHAR(30);
            EXEC inventory.usp_DocumentType_NextNumber @Code = N'PAY', @DocumentNumber = @Number OUTPUT;

            INSERT INTO purchase.Payments (PaymentNumber, PaymentDate, PayeeId, BranchId, PaymentType, CurrencyId, Amount, ExchangeRate, Reference, Notes, Status, CreatedBy)
            VALUES (@Number, @PaymentDate, @PayeeId, @BranchId, @PaymentType, @CurrencyId, @Amount, @ExchangeRate, @Reference, @Notes, 1, @UserId);
            SET @Id = SCOPE_IDENTITY();

            INSERT INTO purchase.PaymentAudit (PaymentId, Action, Details, UserId) VALUES (@Id, N'Created', N'Draft ' + @Number, @UserId);
        END
        ELSE
        BEGIN
            DECLARE @Status TINYINT;
            SELECT @Status = Status FROM purchase.Payments WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
            IF @Status IS NULL THROW 73006, 'Payment not found.', 1;
            IF @Status <> 1 THROW 73005, 'Only a draft payment can be edited.', 1;
            IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.Payments WHERE Id = @Id AND RowVersion = @RowVersion)
                THROW 73004, 'This payment was modified by another user. Reload the page and try again.', 1;

            UPDATE purchase.Payments
            SET PaymentDate = @PaymentDate, PayeeId = @PayeeId, BranchId = @BranchId, PaymentType = @PaymentType,
                CurrencyId = @CurrencyId, Amount = @Amount, ExchangeRate = @ExchangeRate, Reference = @Reference, Notes = @Notes,
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;

            DELETE FROM purchase.PaymentAllocations WHERE PaymentId = @Id;
            DELETE FROM purchase.PaymentLines WHERE PaymentId = @Id;

            INSERT INTO purchase.PaymentAudit (PaymentId, Action, Details, UserId)
            VALUES (@Id, N'Updated', N'Header, ' + CAST((SELECT COUNT(*) FROM @Lines) AS NVARCHAR(10)) + N' payment line(s) and '
                    + CAST((SELECT COUNT(*) FROM @Allocations) AS NVARCHAR(10)) + N' allocation(s) saved', @UserId);
        END

        -- A cheque line starts Pending; any other line carries no cheque fields, whatever was sent.
        INSERT INTO purchase.PaymentLines (PaymentId, LineNumber, PaymentMethodId, CurrencyId, Amount, RateToPayment, CashBankAccountId, Reference,
                                           ChequeNo, ChequeDate, ChequeDueDate, ClearanceStatus)
        SELECT @Id, l.LineNumber, l.PaymentMethodId, l.CurrencyId, l.Amount,
               CASE WHEN l.CurrencyId = @CurrencyId THEN 1 ELSE COALESCE(l.RateToPayment, purchase.fn_RateToPayment(l.CurrencyId, @CurrencyId, @ExchangeRate, @PaymentDate)) END,
               l.CashBankAccountId, NULLIF(LTRIM(RTRIM(l.Reference)), N''),
               CASE WHEN pm.MethodCode = N'CHQ' THEN NULLIF(LTRIM(RTRIM(l.ChequeNo)), N'') END,
               CASE WHEN pm.MethodCode = N'CHQ' THEN l.ChequeDate END,
               CASE WHEN pm.MethodCode = N'CHQ' THEN l.ChequeDueDate END,
               CASE WHEN pm.MethodCode = N'CHQ' THEN 1 END
        FROM @Lines l
        INNER JOIN masterdata.PaymentMethods pm ON pm.Id = l.PaymentMethodId;

        -- The base value of each line, at the header's rate.
        UPDATE purchase.PaymentLines SET AmountBase = CONVERT(DECIMAL(18,2), ROUND(AmountPaymentCurrency / @ExchangeRate, 2)) WHERE PaymentId = @Id;

        -- THE DOCUMENT'S OWN RATE IS SNAPSHOTTED, so the base value of an allocation can never move.
        INSERT INTO purchase.PaymentAllocations (PaymentId, DocumentKind, PurchaseDocumentId, ContainerChargeId, AmountDocCurrency, DocExchangeRate, RateToPayment, AllocatedBy)
        SELECT @Id, a.DocumentKind,
               CASE WHEN a.DocumentKind = N'PINV' THEN a.DocumentId END,
               CASE WHEN a.DocumentKind = N'CHARGE' THEN a.DocumentId END,
               a.Amount, pd.ExchangeRate,
               CASE WHEN pd.CurrencyId = @CurrencyId THEN 1 ELSE COALESCE(a.RateToPayment, purchase.fn_RateToPayment(pd.CurrencyId, @CurrencyId, @ExchangeRate, @PaymentDate)) END,
               @UserId
        FROM @Allocations a
        CROSS APPLY purchase.fn_PayableDocument(a.DocumentKind, a.DocumentId) pd;

        -- Script 73: the container split, under the allocation of its invoice (zero amounts are not kept).
        INSERT INTO purchase.PaymentAllocationContainers (PaymentAllocationId, ContainerId, AmountDocCurrency)
        SELECT al.Id, NULLIF(c.ContainerId, 0), c.Amount
        FROM @Split c
        INNER JOIN purchase.PaymentAllocations al ON al.PaymentId = @Id AND al.PurchaseDocumentId = c.DocumentId AND al.RemovedAtUtc IS NULL
        WHERE c.Amount > 0;

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

