CREATE   PROCEDURE purchase.usp_Payment_Allocate
    @PaymentId   INT,
    @Allocations purchase.tvp_PaymentAllocation READONLY,
    @AllocationContainers purchase.tvp_PaymentAllocationContainer READONLY,   -- script 73
    @RowVersion  BINARY(8) = NULL,
    @UserId      INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM @Allocations) THROW 73000, 'Choose at least one document to allocate to.', 1;
    IF (SELECT COUNT(DISTINCT DocumentKind) FROM @Allocations) > 1
        THROW 73000, 'A payment is allocated to purchase invoices OR to container charges, never both.', 1;
    IF EXISTS (SELECT 1 FROM @Allocations WHERE DocumentKind NOT IN (N'PINV', N'CHARGE'))
        THROW 73000, 'Unknown document kind.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @Type TINYINT, @PayeeId INT, @Amount DECIMAL(18,2), @CurrencyId INT, @Rate DECIMAL(18,6), @Cur NVARCHAR(10);
        SELECT @Status = p.Status, @Type = p.PaymentType, @PayeeId = p.PayeeId, @Amount = p.Amount, @CurrencyId = p.CurrencyId,
               @Rate = p.ExchangeRate, @Cur = c.CurrencyCode
        FROM purchase.Payments p WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN masterdata.Currencies c ON c.Id = p.CurrencyId
        WHERE p.Id = @PaymentId;

        IF @Status IS NULL THROW 73006, 'Payment not found.', 1;
        IF @Status <> 2 THROW 73010, 'Only a posted payment can be allocated.', 1;
        IF @Type <> 1 THROW 73010, 'Only a Free Payment can be allocated later; an invoice or charge payment is already allocated.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.Payments WHERE Id = @PaymentId AND RowVersion = @RowVersion)
            THROW 73004, 'This payment was modified by another user. Reload the page and try again.', 1;

        -- Decision 6: the first allocation decides the kind; a payment never mixes invoices and charges.
        IF EXISTS (SELECT 1 FROM purchase.PaymentAllocations x WHERE x.PaymentId = @PaymentId AND x.RemovedAtUtc IS NULL
                   AND x.DocumentKind <> (SELECT TOP (1) DocumentKind FROM @Allocations))
            THROW 73000, 'This payment is already allocated to another kind of document; a payment never mixes purchase invoices and container charges.', 1;

        DECLARE @LockedInv TABLE (Id INT PRIMARY KEY);
        INSERT INTO @LockedInv (Id)
        SELECT d.Id FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        WHERE d.Id IN (SELECT DocumentId FROM @Allocations WHERE DocumentKind = N'PINV');
        DECLARE @LockedCh TABLE (Id INT PRIMARY KEY);
        INSERT INTO @LockedCh (Id)
        SELECT c.Id FROM logistics.ContainerCharges c WITH (UPDLOCK, HOLDLOCK)
        WHERE c.Id IN (SELECT DocumentId FROM @Allocations WHERE DocumentKind = N'CHARGE');

        DECLARE @Msg NVARCHAR(400);
        DECLARE @Today DATE = CAST(SYSUTCDATETIME() AS DATE);
        SELECT TOP (1) @Msg = CASE a.DocumentKind WHEN N'PINV' THEN N'Purchase invoice ' ELSE N'Charge ' END
                              + ISNULL(pd.DocumentNumber, N'#' + CAST(a.DocumentId AS NVARCHAR(10))) + N': ' + x.Problem
        FROM @Allocations a
        OUTER APPLY purchase.fn_PayableDocument(a.DocumentKind, a.DocumentId) pd
        CROSS APPLY (SELECT Problem =
            CASE WHEN pd.DocumentId IS NULL THEN N'not found.'
                 WHEN pd.PaymentStatus IS NULL THEN N'only a posted document can be paid.'
                 WHEN ISNULL(pd.PayeeId, -1) <> @PayeeId THEN N'it does not belong to this payee.'
                 WHEN a.Amount IS NULL OR a.Amount <= 0 THEN N'the allocated amount must be greater than zero.'
                 WHEN a.Amount > pd.OutstandingAmount + 0.005 THEN FORMAT(a.Amount, N'N2', N'en-US') + N' is more than its outstanding '
                                                                  + FORMAT(pd.OutstandingAmount, N'N2', N'en-US') + N' ' + pd.CurrencyCode + N'.'
                 WHEN a.RateToPayment IS NOT NULL AND a.RateToPayment <= 0 THEN N'exchange rate must be greater than zero.'
                 WHEN a.RateToPayment IS NULL AND purchase.fn_RateToPayment(pd.CurrencyId, @CurrencyId, @Rate, @Today) IS NULL
                      THEN N'no official exchange rate is defined for ' + pd.CurrencyCode + N'.'
            END) x
        WHERE x.Problem IS NOT NULL
        ORDER BY a.DocumentKind, a.DocumentId;
        IF @Msg IS NOT NULL THROW 73009, @Msg, 1;

        /* WHAT IS LEFT TO ALLOCATE, in the payment currency: the amount less its live allocations. */
        DECLARE @Applied DECIMAL(18,2) = (SELECT ISNULL(SUM(AmountPaymentCurrency), 0) FROM purchase.PaymentAllocations WHERE PaymentId = @PaymentId AND RemovedAtUtc IS NULL);
        DECLARE @Unapplied DECIMAL(18,2) = @Amount - @Applied;
        DECLARE @New DECIMAL(18,2) = (SELECT ISNULL(SUM(CONVERT(DECIMAL(18,2), ROUND(a.Amount * CASE WHEN pd.CurrencyId = @CurrencyId THEN 1
                                                    ELSE COALESCE(a.RateToPayment, purchase.fn_RateToPayment(pd.CurrencyId, @CurrencyId, @Rate, @Today)) END, 2))), 0)
                                      FROM @Allocations a CROSS APPLY purchase.fn_PayableDocument(a.DocumentKind, a.DocumentId) pd);
        IF @New > @Unapplied + 0.01
        BEGIN
            SET @Msg = N'This payment has only ' + FORMAT(@Unapplied, N'N2', N'en-US') + N' ' + @Cur + N' unapplied, but '
                     + FORMAT(@New, N'N2', N'en-US') + N' ' + @Cur + N' was allocated.';
            THROW 73011, @Msg, 1;
        END

        -- Script 73: an invoice with containers is allocated container by container, and the split adds up.
        -- One container and nothing else: the whole amount is that container's, without a split typed by hand.
        DECLARE @Split purchase.tvp_PaymentAllocationContainer;
        INSERT INTO @Split (DocumentId, ContainerId, Amount) SELECT DocumentId, ContainerId, Amount FROM @AllocationContainers;
        INSERT INTO @Split (DocumentId, ContainerId, Amount)
        SELECT a.DocumentId, s.ContainerKey, a.Amount
        FROM @Allocations a
        CROSS APPLY purchase.fn_InvoiceContainerSettlement(a.DocumentId) s
        WHERE a.DocumentKind = N'PINV' AND s.HasContainers = 1 AND s.NeedsSplit = 0 AND a.Amount > 0
          AND NOT EXISTS (SELECT 1 FROM @AllocationContainers c WHERE c.DocumentId = a.DocumentId);
        EXEC purchase.usp_Payment_CheckContainerSplit @Allocations, @Split, 1;
        DECLARE @NewAlloc TABLE (Id INT PRIMARY KEY, DocumentId INT NULL);

        INSERT INTO purchase.PaymentAllocations (PaymentId, DocumentKind, PurchaseDocumentId, ContainerChargeId, AmountDocCurrency, DocExchangeRate, RateToPayment, AllocatedBy)
        OUTPUT inserted.Id, inserted.PurchaseDocumentId INTO @NewAlloc (Id, DocumentId)
        SELECT @PaymentId, a.DocumentKind,
               CASE WHEN a.DocumentKind = N'PINV' THEN a.DocumentId END,
               CASE WHEN a.DocumentKind = N'CHARGE' THEN a.DocumentId END,
               a.Amount, pd.ExchangeRate,
               CASE WHEN pd.CurrencyId = @CurrencyId THEN 1 ELSE COALESCE(a.RateToPayment, purchase.fn_RateToPayment(pd.CurrencyId, @CurrencyId, @Rate, @Today)) END,
               @UserId
        FROM @Allocations a
        CROSS APPLY purchase.fn_PayableDocument(a.DocumentKind, a.DocumentId) pd;

        INSERT INTO purchase.PaymentAllocationContainers (PaymentAllocationId, ContainerId, AmountDocCurrency)
        SELECT n.Id, NULLIF(c.ContainerId, 0), c.Amount
        FROM @Split c
        INNER JOIN @NewAlloc n ON n.DocumentId = c.DocumentId
        WHERE c.Amount > 0;

        INSERT INTO purchase.PaymentAudit (PaymentId, Action, Details, UserId)
        VALUES (@PaymentId, N'Allocated', CAST((SELECT COUNT(*) FROM @Allocations) AS NVARCHAR(10)) + N' document(s), '
                + FORMAT(@New, N'N2', N'en-US') + N' ' + @Cur, @UserId);

        UPDATE purchase.Payments SET UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @PaymentId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

