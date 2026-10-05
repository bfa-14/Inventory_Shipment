SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ==================================================================================================
   47: Supplier payments - logic (US-PAY-001, Phase 2)
   --------------------------------------------------------------------------------------------------
   What a supplier payment DOES, all of it here so the page cannot get round it.

     usp_Payment_Save          a draft: header, payment lines, allocations (replaced as a whole)
     usp_Payment_Post          the controls of sections 3, 7 and 11, then Draft -> Posted
     usp_Payment_Reverse       Posted -> Reversed, with a reason; nothing is deleted
     usp_Payment_Delete        drafts only
     usp_Payment_Allocate      a posted FREE payment's unapplied advance -> invoices OR charges
     usp_Payment_Deallocate    take one such allocation back (the row stays as proof)
     usp_Payment_SetChequeStatus   Pending / Cleared / Returned on a cheque line of a posted payment
     usp_Payment_Get / _Search
     usp_Payment_OpenDocuments the invoices / charges of a payee that still owe something
     usp_Payment_RateToPayment the multiplier a line or allocation pre-fills
     usp_PaymentFile_Add / _Get / _Delete

   THE RULES
     - Payee: an active SUPPLIER. Branch active. Payment Type 1 Free, 2 Purchase Invoice, 3 Container Charge.
     - Header rate: units of the payment currency per 1 base (1 for the base currency), the official rate
       on the payment date unless typed.
     - Line: its account must hold the line's currency and be usable from the payment's branch. RateToPayment
       (line currency -> payment currency) is 1 when the currencies match, else what was typed, else
       header rate / the official rate of the line currency on the payment date. A CHEQUE line (method code
       CHQ) needs a cheque number and date and starts Pending; other lines carry no cheque fields.
     - Allocation: Free -> none; Purchase Invoice -> posted purchase invoices of this payee only; Container
       Charge -> posted container charges billed by this payee only. Never above what the document still
       owes (posted payments only - drafts settle under a lock when they post). Entered in the document's
       currency; RateToPayment pre-filled from the official rates like a line.
     - Post: at least one line; header Amount = SUM(lines in payment currency) and, for types 2 / 3,
       = SUM(allocations in payment currency), each within 0.01, in the PAYMENT currency. The documents are
       locked while what they owe is re-read. Rates are frozen as stored.
     - Reverse: a posted payment only. A Free payment that has since been applied must have those
       allocations removed first. Reversing stops its allocations counting: the documents owe again.
     - Free payment, allocated later: to invoices OR to charges, never both (the first allocation decides),
       within its unapplied balance in the payment currency.

   ALSO: a posted purchase invoice / container charge with live payment allocations cannot be cancelled;
   purchase invoice and container charge lists and reads return Paid, Outstanding and PaymentStatus.

   Errors 73xxx: 73000 validation, 73004 concurrency, 73005 not editable, 73006 not found,
                 73008 unbalanced, 73009 allocation above outstanding, 73010 invalid status,
                 73011 unapplied exceeded, 73012 has allocations.
   Requires script 46. Idempotent.
   ================================================================================================== */

IF OBJECT_ID(N'purchase.Payments', N'U') IS NULL OR OBJECT_ID(N'purchase.fn_InvoiceSettlement', N'IF') IS NULL
BEGIN
    RAISERROR ('Run script 46 before script 47.', 16, 1);
    SET NOEXEC ON;
END
GO

/* ================================================================== 1. Table types */

IF TYPE_ID(N'purchase.tvp_PaymentLine') IS NULL
BEGIN
    CREATE TYPE purchase.tvp_PaymentLine AS TABLE
    (
        LineNumber        INT            NOT NULL PRIMARY KEY,
        PaymentMethodId   INT            NOT NULL,
        CurrencyId        INT            NOT NULL,
        Amount            DECIMAL(18,2)  NOT NULL,
        RateToPayment     DECIMAL(24,12) NULL,       -- NULL = from the official rates (1 when the currency is the payment's)
        CashBankAccountId INT            NOT NULL,
        Reference         NVARCHAR(100)  NULL,
        ChequeNo          NVARCHAR(50)   NULL,
        ChequeDate        DATE           NULL,
        ChequeDueDate     DATE           NULL
    );
    PRINT 'Created type purchase.tvp_PaymentLine';
END
GO

IF TYPE_ID(N'purchase.tvp_PaymentAllocation') IS NULL
BEGIN
    CREATE TYPE purchase.tvp_PaymentAllocation AS TABLE
    (
        DocumentKind  NVARCHAR(10)   NOT NULL,       -- PINV | CHARGE
        DocumentId    INT            NOT NULL,       -- purchase.PurchaseDocuments.Id | logistics.ContainerCharges.Id
        Amount        DECIMAL(18,2)  NOT NULL,       -- in the DOCUMENT's currency
        RateToPayment DECIMAL(24,12) NULL,           -- NULL = from the official rates
        PRIMARY KEY (DocumentKind, DocumentId)
    );
    PRINT 'Created type purchase.tvp_PaymentAllocation';
END
GO

/* ================================================================== 2. Rates and documents, defined once */

/* The multiplier from one currency to the payment currency: 1 when they are the same; otherwise the
   payment's rate over the other currency's official rate on the date (both per 1 base). NULL when the
   other currency has no rate - the caller turns that into a message. */
CREATE OR ALTER FUNCTION purchase.fn_RateToPayment (@FromCurrencyId INT, @PaymentCurrencyId INT, @PaymentRate DECIMAL(18,6), @AsOfDate DATE)
RETURNS DECIMAL(24,12)
AS
BEGIN
    IF @FromCurrencyId = @PaymentCurrencyId RETURN 1;
    DECLARE @FromRate DECIMAL(18,6) = masterdata.fn_GetRate(@FromCurrencyId, 1, @AsOfDate);
    IF @FromRate IS NULL OR @FromRate <= 0 OR @PaymentRate IS NULL OR @PaymentRate <= 0 RETURN NULL;
    RETURN CONVERT(DECIMAL(24,12), CONVERT(DECIMAL(38,18), @PaymentRate) / @FromRate);
END
GO

/* ONE ROW PER PAYABLE DOCUMENT, whatever its kind: what the allocation tables, the open-documents list and
   the checks read. Number, date, payee, currency and rate, total, paid / outstanding / status, the
   container(s) it concerns and, for a charge, its type. */
CREATE OR ALTER FUNCTION purchase.fn_PayableDocument (@Kind NVARCHAR(10), @DocumentId INT)
RETURNS TABLE
AS
RETURN
(
    SELECT DocumentKind = N'PINV', DocumentId = d.Id, d.DocumentNumber, d.DocumentDate, PayeeId = d.SupplierId,
           d.CurrencyId, c.CurrencyCode, c.DecimalPlaces, d.ExchangeRate,
           DocumentTotal = d.TotalAmount, st.ReturnedAmount, st.PaidAmount, st.OutstandingAmount, st.PaymentStatus,
           ContainerRef = (SELECT STRING_AGG(r.ContainerRef, N', ') WITHIN GROUP (ORDER BY r.ContainerRef)
                           FROM (SELECT DISTINCT k.ContainerRef
                                 FROM purchase.PurchaseDocumentLines l
                                 INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
                                 INNER JOIN logistics.Containers k      ON k.Id = cl.ContainerId
                                 WHERE l.DocumentId = d.Id) r),
           ChargeTypeName = CAST(NULL AS NVARCHAR(100)), Reference = d.SupplierReference
    FROM purchase.PurchaseDocuments d
    INNER JOIN masterdata.Currencies c ON c.Id = d.CurrencyId
    CROSS APPLY purchase.fn_InvoiceSettlement(d.Id) st
    WHERE @Kind = N'PINV' AND d.Id = @DocumentId
    UNION ALL
    SELECT N'CHARGE', ch.Id, N'CHG-' + RIGHT(N'000000' + CAST(ch.Id AS NVARCHAR(10)), 6), ch.ChargeDate, ch.ProviderPartyId,
           ch.CurrencyId, c.CurrencyCode, c.DecimalPlaces, ch.ExchangeRate,
           ch.Amount, CAST(0 AS DECIMAL(18,2)), st.PaidAmount, st.OutstandingAmount, st.PaymentStatus,
           k.ContainerRef, t.ChargeName, ch.Reference
    FROM logistics.ContainerCharges ch
    INNER JOIN masterdata.Currencies c ON c.Id = ch.CurrencyId
    INNER JOIN logistics.Containers k  ON k.Id = ch.ContainerId
    INNER JOIN purchase.ChargeTypes t  ON t.Id = ch.ChargeTypeId
    CROSS APPLY logistics.fn_ContainerChargeSettlement(ch.Id) st
    WHERE @Kind = N'CHARGE' AND ch.Id = @DocumentId
);
GO

/* ================================================================== 3. Save (a draft) */

CREATE OR ALTER PROCEDURE purchase.usp_Payment_Save
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

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 4. Post */

CREATE OR ALTER PROCEDURE purchase.usp_Payment_Post
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

/* ================================================================== 5. Reverse */

CREATE OR ALTER PROCEDURE purchase.usp_Payment_Reverse
    @Id         INT,
    @Reason     NVARCHAR(500),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 73000, 'A reason is required to reverse a payment.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @Type TINYINT;
        SELECT @Status = Status, @Type = PaymentType FROM purchase.Payments WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;

        IF @Status IS NULL THROW 73006, 'Payment not found.', 1;
        IF @Status <> 2 THROW 73010, 'Only a posted payment can be reversed.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.Payments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 73004, 'This payment was modified by another user. Reload the page and try again.', 1;

        /* A FREE PAYMENT THAT HAS SINCE PAID DOCUMENTS CANNOT JUST VANISH: they would go back to owing money
           nobody told them about. Its allocations are removed first, so somebody decides about each one. An
           allocated payment's own allocations are part of it: reversing it simply stops them counting. */
        IF @Type = 1 AND EXISTS (SELECT 1 FROM purchase.PaymentAllocations WHERE PaymentId = @Id AND RemovedAtUtc IS NULL)
            THROW 73012, 'This payment has been applied to documents since it was posted. Remove those allocations before reversing it.', 1;

        UPDATE purchase.Payments
        SET Status = 3, ReversedAtUtc = SYSUTCDATETIME(), ReversedBy = @UserId, ReverseReason = @Reason,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO purchase.PaymentAudit (PaymentId, Action, Details, UserId) VALUES (@Id, N'Reversed', @Reason, @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 6. Delete (a draft) */

CREATE OR ALTER PROCEDURE purchase.usp_Payment_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT;
        SELECT @Status = Status FROM purchase.Payments WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NULL THROW 73006, 'Payment not found.', 1;
        -- A posted payment moved money and a reversed one proves it did: neither is ever deleted.
        IF @Status <> 1 THROW 73010, 'Only a draft payment can be deleted. A posted payment is corrected by reversing it.', 1;

        DELETE FROM purchase.PaymentFiles WHERE PaymentId = @Id;
        DELETE FROM purchase.PaymentAllocations WHERE PaymentId = @Id;
        DELETE FROM purchase.PaymentLines WHERE PaymentId = @Id;
        DELETE FROM purchase.PaymentAudit WHERE PaymentId = @Id;
        DELETE FROM purchase.Payments WHERE Id = @Id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 7. Allocate a Free payment's advance later */

CREATE OR ALTER PROCEDURE purchase.usp_Payment_Allocate
    @PaymentId   INT,
    @Allocations purchase.tvp_PaymentAllocation READONLY,
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

        INSERT INTO purchase.PaymentAllocations (PaymentId, DocumentKind, PurchaseDocumentId, ContainerChargeId, AmountDocCurrency, DocExchangeRate, RateToPayment, AllocatedBy)
        SELECT @PaymentId, a.DocumentKind,
               CASE WHEN a.DocumentKind = N'PINV' THEN a.DocumentId END,
               CASE WHEN a.DocumentKind = N'CHARGE' THEN a.DocumentId END,
               a.Amount, pd.ExchangeRate,
               CASE WHEN pd.CurrencyId = @CurrencyId THEN 1 ELSE COALESCE(a.RateToPayment, purchase.fn_RateToPayment(pd.CurrencyId, @CurrencyId, @Rate, @Today)) END,
               @UserId
        FROM @Allocations a
        CROSS APPLY purchase.fn_PayableDocument(a.DocumentKind, a.DocumentId) pd;

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

CREATE OR ALTER PROCEDURE purchase.usp_Payment_Deallocate
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

/* ================================================================== 8. Cheque clearance (decision 5) */

/* THE ONE FIELD OF A POSTED PAYMENT THAT STILL MOVES: a cheque is Pending until the bank clears or returns
   it. Changing it moves no money - a returned cheque is dealt with by reversing the payment. */
CREATE OR ALTER PROCEDURE purchase.usp_Payment_SetChequeStatus
    @LineId          INT,
    @ClearanceStatus TINYINT,        -- 1 Pending, 2 Cleared, 3 Returned
    @UserId          INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @ClearanceStatus NOT IN (1, 2, 3) THROW 73000, 'Clearance status must be Pending, Cleared or Returned.', 1;

    DECLARE @PaymentId INT, @Status TINYINT, @Old TINYINT, @IsCheque BIT, @ChequeNo NVARCHAR(50);
    SELECT @PaymentId = l.PaymentId, @Status = p.Status, @Old = l.ClearanceStatus, @ChequeNo = l.ChequeNo,
           @IsCheque = CASE WHEN pm.MethodCode = N'CHQ' THEN 1 ELSE 0 END
    FROM purchase.PaymentLines l
    INNER JOIN purchase.Payments p ON p.Id = l.PaymentId
    INNER JOIN masterdata.PaymentMethods pm ON pm.Id = l.PaymentMethodId
    WHERE l.Id = @LineId;

    IF @PaymentId IS NULL THROW 73006, 'Payment line not found.', 1;
    IF @IsCheque = 0 THROW 73000, 'Only a cheque line has a clearance status.', 1;
    IF @Status <> 2 THROW 73010, 'The clearance status is kept for a posted payment only.', 1;
    IF @Old = @ClearanceStatus RETURN;

    BEGIN TRY
        BEGIN TRANSACTION;
        UPDATE purchase.PaymentLines
        SET ClearanceStatus = @ClearanceStatus, ClearanceUpdatedAtUtc = SYSUTCDATETIME(), ClearanceUpdatedBy = @UserId
        WHERE Id = @LineId;

        INSERT INTO purchase.PaymentAudit (PaymentId, Action, Details, UserId)
        VALUES (@PaymentId, N'ChequeStatus', N'Cheque ' + ISNULL(@ChequeNo, N'') + N': '
                + CASE ISNULL(@Old, 1) WHEN 1 THEN N'Pending' WHEN 2 THEN N'Cleared' ELSE N'Returned' END + N' -> '
                + CASE @ClearanceStatus WHEN 1 THEN N'Pending' WHEN 2 THEN N'Cleared' ELSE N'Returned' END, @UserId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 9. Get */

-- Five result sets: the payment, its lines, its allocations, its files, its audit trail (newest first).
CREATE OR ALTER PROCEDURE purchase.usp_Payment_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT p.Id, p.PaymentNumber, p.PaymentDate, p.PayeeId, py.PartyCode AS PayeeCode, py.PartyName AS PayeeName, py.Address AS PayeeAddress,
           p.BranchId, b.BranchCode, b.BranchName, p.PaymentType,
           p.CurrencyId, c.CurrencyCode, c.CurrencyName, c.Symbol AS CurrencySymbol, c.DecimalPlaces, c.IsBaseCurrency,
           p.Amount, p.ExchangeRate, p.AmountBase, bc.CurrencyCode AS BaseCurrencyCode,
           p.Reference, p.Notes, p.Status,
           LinesTotal     = ISNULL(ln.Total, 0),
           AllocatedTotal = ISNULL(al.Total, 0),
           -- Only a posted FREE payment holds an advance; an allocated one is spent by definition.
           UnappliedAmount = CASE WHEN p.Status = 2 AND p.PaymentType = 1 THEN p.Amount - ISNULL(al.Total, 0) ELSE 0 END,
           AllocationKind = al.Kind,
           p.PostedAtUtc, p.PostedBy, pu.FullName AS PostedByName,
           p.ReversedAtUtc, p.ReversedBy, ru.FullName AS ReversedByName, p.ReverseReason,
           p.CreatedAtUtc, p.CreatedBy, cu.FullName AS CreatedByName, p.UpdatedAtUtc, p.UpdatedBy, uu.FullName AS UpdatedByName,
           p.RowVersion
    FROM purchase.Payments p
    INNER JOIN masterdata.Parties py    ON py.Id = p.PayeeId
    INNER JOIN masterdata.Branches b    ON b.Id = p.BranchId
    INNER JOIN masterdata.Currencies c  ON c.Id = p.CurrencyId
    LEFT  JOIN masterdata.Currencies bc ON bc.IsBaseCurrency = 1 AND bc.IsActive = 1
    OUTER APPLY (SELECT Total = SUM(AmountPaymentCurrency) FROM purchase.PaymentLines WHERE PaymentId = p.Id) ln
    OUTER APPLY (SELECT Total = SUM(AmountPaymentCurrency), Kind = MIN(DocumentKind)
                 FROM purchase.PaymentAllocations WHERE PaymentId = p.Id AND RemovedAtUtc IS NULL) al
    LEFT  JOIN security.Users pu ON pu.Id = p.PostedBy
    LEFT  JOIN security.Users ru ON ru.Id = p.ReversedBy
    LEFT  JOIN security.Users cu ON cu.Id = p.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = p.UpdatedBy
    WHERE p.Id = @Id;

    SELECT l.Id, l.PaymentId, l.LineNumber, l.PaymentMethodId, pm.MethodCode, pm.MethodName,
           IsCheque = CAST(CASE WHEN pm.MethodCode = N'CHQ' THEN 1 ELSE 0 END AS BIT),
           l.CurrencyId, cu.CurrencyCode, cu.DecimalPlaces, l.Amount, l.RateToPayment, l.AmountPaymentCurrency, l.AmountBase,
           l.CashBankAccountId, a.AccountCode, a.AccountName, l.Reference,
           l.ChequeNo, l.ChequeDate, l.ChequeDueDate, l.ClearanceStatus,
           ClearanceStatusName = CASE l.ClearanceStatus WHEN 1 THEN N'Pending' WHEN 2 THEN N'Cleared' WHEN 3 THEN N'Returned' END,
           l.ClearanceUpdatedAtUtc, xu.FullName AS ClearanceUpdatedByName
    FROM purchase.PaymentLines l
    INNER JOIN masterdata.PaymentMethods pm  ON pm.Id = l.PaymentMethodId
    INNER JOIN masterdata.Currencies cu      ON cu.Id = l.CurrencyId
    INNER JOIN masterdata.CashBankAccounts a ON a.Id = l.CashBankAccountId
    LEFT  JOIN security.Users xu ON xu.Id = l.ClearanceUpdatedBy
    WHERE l.PaymentId = @Id
    ORDER BY l.LineNumber;

    /* PreviouslyPaid is what OTHER posted payments have paid the document: this payment's own share is
       taken out when it is posted and still live, so a draft and a posted payment read the same. */
    SELECT al.Id, al.PaymentId, al.DocumentKind, DocumentId = ISNULL(al.PurchaseDocumentId, al.ContainerChargeId),
           pd.DocumentNumber, pd.DocumentDate, pd.ContainerRef, pd.ChargeTypeName, pd.Reference AS DocumentReference,
           pd.CurrencyId AS DocumentCurrencyId, pd.CurrencyCode AS DocumentCurrencyCode, pd.DecimalPlaces AS DocumentDecimalPlaces,
           pd.DocumentTotal, pd.ReturnedAmount,
           PreviouslyPaid = pd.PaidAmount - CASE WHEN p.Status = 2 AND al.RemovedAtUtc IS NULL THEN al.AmountDocCurrency ELSE 0 END,
           pd.OutstandingAmount, pd.PaymentStatus,
           al.AmountDocCurrency, al.DocExchangeRate, al.RateToPayment, al.AmountPaymentCurrency, al.AmountBase,
           al.AllocatedAtUtc, au.FullName AS AllocatedByName, al.RemovedAtUtc, xu.FullName AS RemovedByName
    FROM purchase.PaymentAllocations al
    INNER JOIN purchase.Payments p ON p.Id = al.PaymentId
    CROSS APPLY purchase.fn_PayableDocument(al.DocumentKind, ISNULL(al.PurchaseDocumentId, al.ContainerChargeId)) pd
    LEFT  JOIN security.Users au ON au.Id = al.AllocatedBy
    LEFT  JOIN security.Users xu ON xu.Id = al.RemovedBy
    WHERE al.PaymentId = @Id
    ORDER BY al.AllocatedAtUtc, al.Id;

    SELECT f.Id, f.PaymentId, f.AttachmentTypeId, t.Category, t.SubType, f.Note, f.FileName, f.ContentType, f.SizeBytes,
           f.CreatedAtUtc, u.FullName AS CreatedByName
    FROM purchase.PaymentFiles f
    LEFT JOIN masterdata.AttachmentTypes t ON t.Id = f.AttachmentTypeId
    LEFT JOIN security.Users u ON u.Id = f.CreatedBy
    WHERE f.PaymentId = @Id
    ORDER BY f.CreatedAtUtc, f.Id;

    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM purchase.PaymentAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.PaymentId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;
END
GO

/* ================================================================== 10. Search */

CREATE OR ALTER PROCEDURE purchase.usp_Payment_Search
    @Search        NVARCHAR(100) = NULL,           -- number, reference, payee code / name, notes
    @PayeeId       INT           = NULL,
    @BranchId      INT           = NULL,
    @Status        TINYINT       = NULL,           -- 1 Draft | 2 Posted | 3 Reversed
    @PaymentType   TINYINT       = NULL,           -- 1 Free | 2 Purchase Invoice | 3 Container Charge
    @CurrencyId    INT           = NULL,
    @DateFrom      DATE          = NULL,
    @DateTo        DATE          = NULL,
    @SortColumn    NVARCHAR(30)  = N'PaymentDate', -- PaymentNumber | PaymentDate | PayeeName | Status | AmountBase | CreatedAtUtc
    @SortDirection NVARCHAR(4)   = N'DESC',
    @PageNumber    INT           = 1,
    @PageSize      INT           = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'PaymentNumber', N'PaymentDate', N'PayeeName', N'Status', N'AmountBase', N'CreatedAtUtc')
        SET @SortColumn = N'PaymentDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT p.Id, p.PaymentNumber, p.PaymentDate, p.PayeeId, py.PartyCode AS PayeeCode, py.PartyName AS PayeeName,
           p.BranchId, b.BranchName, p.PaymentType, p.CurrencyId, c.CurrencyCode, c.DecimalPlaces,
           p.Amount, p.ExchangeRate, p.AmountBase, p.Reference, p.Status,
           Methods = (SELECT STRING_AGG(m.MethodName, N', ') WITHIN GROUP (ORDER BY m.MethodName)
                      FROM (SELECT DISTINCT pm.MethodName FROM purchase.PaymentLines l
                            INNER JOIN masterdata.PaymentMethods pm ON pm.Id = l.PaymentMethodId WHERE l.PaymentId = p.Id) m),
           AllocatedAmount = ISNULL(al.Total, 0),
           UnappliedAmount = CASE WHEN p.Status = 2 AND p.PaymentType = 1 THEN p.Amount - ISNULL(al.Total, 0) ELSE 0 END,
           DocumentCount   = ISNULL(al.Docs, 0),
           p.PostedAtUtc, pu.FullName AS PostedByName, p.ReversedAtUtc,
           p.CreatedAtUtc, cu.FullName AS CreatedByName, p.UpdatedAtUtc, p.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM purchase.Payments p
    INNER JOIN masterdata.Parties py   ON py.Id = p.PayeeId
    INNER JOIN masterdata.Branches b   ON b.Id = p.BranchId
    INNER JOIN masterdata.Currencies c ON c.Id = p.CurrencyId
    OUTER APPLY (SELECT Total = SUM(AmountPaymentCurrency), Docs = COUNT(*)
                 FROM purchase.PaymentAllocations WHERE PaymentId = p.Id AND RemovedAtUtc IS NULL) al
    LEFT  JOIN security.Users cu ON cu.Id = p.CreatedBy
    LEFT  JOIN security.Users pu ON pu.Id = p.PostedBy
    WHERE (@Search IS NULL OR p.PaymentNumber LIKE N'%' + @Search + N'%' OR p.Reference LIKE N'%' + @Search + N'%'
           OR py.PartyCode LIKE N'%' + @Search + N'%' OR py.PartyName LIKE N'%' + @Search + N'%' OR p.Notes LIKE N'%' + @Search + N'%')
      AND (@PayeeId IS NULL OR p.PayeeId = @PayeeId)
      AND (@BranchId IS NULL OR p.BranchId = @BranchId)
      AND (@Status IS NULL OR p.Status = @Status)
      AND (@PaymentType IS NULL OR p.PaymentType = @PaymentType)
      AND (@CurrencyId IS NULL OR p.CurrencyId = @CurrencyId)
      AND (@DateFrom IS NULL OR p.PaymentDate >= @DateFrom)
      AND (@DateTo IS NULL OR p.PaymentDate <= @DateTo)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'PaymentNumber' THEN p.PaymentNumber WHEN N'PayeeName' THEN py.PartyName END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'PaymentNumber' THEN p.PaymentNumber WHEN N'PayeeName' THEN py.PartyName END END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'PaymentDate' THEN p.PaymentDate END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'PaymentDate' THEN p.PaymentDate END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Status' THEN CAST(p.Status AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Status' THEN CAST(p.Status AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'AmountBase' THEN p.AmountBase END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'AmountBase' THEN p.AmountBase END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN p.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN p.CreatedAtUtc END DESC,
        p.PaymentDate DESC, p.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

/* ================================================================== 11. What a payee is still owed */

/* The documents the allocation table lists: this payee's POSTED purchase invoices (PINV) or container
   charges (CHARGE) with something left to pay, oldest first. Fully paid ones never appear. When the
   payment's currency, rate and date are given, DefaultRateToPayment is the multiplier the row pre-fills. */
CREATE OR ALTER PROCEDURE purchase.usp_Payment_OpenDocuments
    @PayeeId           INT,
    @DocumentKind      NVARCHAR(10),          -- PINV | CHARGE
    @PaymentCurrencyId INT           = NULL,
    @PaymentRate       DECIMAL(18,6) = NULL,
    @AsOfDate          DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @AsOfDate IS NULL SET @AsOfDate = CAST(SYSUTCDATETIME() AS DATE);
    IF @DocumentKind NOT IN (N'PINV', N'CHARGE') THROW 73000, 'Document kind must be PINV or CHARGE.', 1;

    SELECT pd.DocumentKind, pd.DocumentId, pd.DocumentNumber, pd.DocumentDate, pd.ContainerRef, pd.ChargeTypeName, pd.Reference AS DocumentReference,
           pd.CurrencyId, pd.CurrencyCode, pd.DecimalPlaces, pd.ExchangeRate,
           pd.DocumentTotal, pd.ReturnedAmount, PreviouslyPaid = pd.PaidAmount, pd.OutstandingAmount, pd.PaymentStatus,
           OutstandingBase = CONVERT(DECIMAL(18,2), pd.OutstandingAmount / pd.ExchangeRate),
           DefaultRateToPayment = CASE WHEN @PaymentCurrencyId IS NULL THEN NULL
                                       ELSE purchase.fn_RateToPayment(pd.CurrencyId, @PaymentCurrencyId,
                                            COALESCE(@PaymentRate, masterdata.fn_GetRate(@PaymentCurrencyId, 1, @AsOfDate)), @AsOfDate) END
    FROM (SELECT d.Id FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId AND t.Code = N'PINV'
          WHERE @DocumentKind = N'PINV' AND d.SupplierId = @PayeeId AND d.Status = 2
          UNION ALL
          SELECT Id FROM logistics.ContainerCharges WHERE @DocumentKind = N'CHARGE' AND ProviderPartyId = @PayeeId AND Status = 2) ids
    CROSS APPLY purchase.fn_PayableDocument(@DocumentKind, ids.Id) pd
    WHERE pd.PaymentStatus IN (N'Unpaid', N'Partial') AND pd.OutstandingAmount > 0.005
    ORDER BY pd.DocumentDate, pd.DocumentId;
END
GO

/* The multiplier a line or an allocation pre-fills: from a currency to the payment currency, on a date.
   NULL when either has no official rate (a warning on the page, never an error here). */
CREATE OR ALTER PROCEDURE purchase.usp_Payment_RateToPayment
    @FromCurrencyId    INT,
    @PaymentCurrencyId INT,
    @PaymentRate       DECIMAL(18,6) = NULL,  -- NULL = the payment currency's official rate on the date
    @AsOfDate          DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @AsOfDate IS NULL SET @AsOfDate = CAST(SYSUTCDATETIME() AS DATE);
    DECLARE @PayRate DECIMAL(18,6) = COALESCE(@PaymentRate, masterdata.fn_GetRate(@PaymentCurrencyId, 1, @AsOfDate));
    SELECT FromCurrencyId = @FromCurrencyId, PaymentCurrencyId = @PaymentCurrencyId, PaymentRate = @PayRate,
           FromRate = masterdata.fn_GetRate(@FromCurrencyId, 1, @AsOfDate),
           RateToPayment = purchase.fn_RateToPayment(@FromCurrencyId, @PaymentCurrencyId, @PayRate, @AsOfDate);
END
GO

/* ================================================================== 12. Files */

CREATE OR ALTER PROCEDURE purchase.usp_PaymentFile_Add
    @PaymentId        INT,
    @AttachmentTypeId INT            = NULL,
    @Note             NVARCHAR(300)  = NULL,
    @FileName         NVARCHAR(255),
    @ContentType      NVARCHAR(100),
    @SizeBytes        INT,
    @Content          VARBINARY(MAX),
    @UserId           INT            = NULL,
    @NewId            INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Note = NULLIF(LTRIM(RTRIM(@Note)), N'');

    DECLARE @Status TINYINT = (SELECT Status FROM purchase.Payments WHERE Id = @PaymentId);
    IF @Status IS NULL THROW 73006, 'Payment not found.', 1;
    -- Evidence keeps arriving after a payment is posted (a SWIFT copy, a bank statement), so a posted payment
    -- takes files. A reversed one is closed.
    IF @Status = 3 THROW 73005, 'A reversed payment is closed; files can no longer be added.', 1;
    IF @AttachmentTypeId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Id = @AttachmentTypeId AND AppliesTo = N'Payment' AND IsActive = 1)
        THROW 73000, 'Attachment type not found, inactive, or not one for payments.', 1;
    IF @SizeBytes IS NULL OR @SizeBytes <= 0 THROW 73000, 'The file is empty.', 1;

    INSERT INTO purchase.PaymentFiles (PaymentId, AttachmentTypeId, Note, FileName, ContentType, SizeBytes, Content, CreatedBy)
    VALUES (@PaymentId, @AttachmentTypeId, @Note, @FileName, @ContentType, @SizeBytes, @Content, @UserId);
    SET @NewId = SCOPE_IDENTITY();

    INSERT INTO purchase.PaymentAudit (PaymentId, Action, Details, UserId) VALUES (@PaymentId, N'FileAdded', @FileName, @UserId);
END
GO

CREATE OR ALTER PROCEDURE purchase.usp_PaymentFile_Get
    @PaymentId INT, @FileId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, PaymentId, FileName, ContentType, SizeBytes, Content
    FROM purchase.PaymentFiles WHERE Id = @FileId AND PaymentId = @PaymentId;
END
GO

CREATE OR ALTER PROCEDURE purchase.usp_PaymentFile_Delete
    @PaymentId INT, @FileId INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT = (SELECT Status FROM purchase.Payments WHERE Id = @PaymentId);
    IF @Status IS NULL THROW 73006, 'Payment not found.', 1;
    -- Evidence of a posted payment is not removable: that is what it is evidence of.
    IF @Status <> 1 THROW 73005, 'Files can only be removed from a draft payment.', 1;

    DECLARE @Name NVARCHAR(255) = (SELECT FileName FROM purchase.PaymentFiles WHERE Id = @FileId AND PaymentId = @PaymentId);
    IF @Name IS NULL THROW 73006, 'File not found.', 1;

    DELETE FROM purchase.PaymentFiles WHERE Id = @FileId AND PaymentId = @PaymentId;
    INSERT INTO purchase.PaymentAudit (PaymentId, Action, Details, UserId) VALUES (@PaymentId, N'FileDeleted', @Name, @UserId);
END
GO

/* ================================================================== 13. Purchase invoices and container charges learn what they were paid */

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Search
    @DocumentTypeCode NVARCHAR(20) = NULL,     -- PO | PINV | PRET | NULL = whole family
    @Search           NVARCHAR(100) = NULL,    -- number, supplier / exporter reference, commercial invoice no., supplier code/name, notes,
                                               -- (45) the item code of a supplier invoice
    @BranchId         INT          = NULL,
    @WarehouseId      INT          = NULL,
    @SupplierId       INT          = NULL,
    @Status           TINYINT      = NULL,     -- 1 Draft | 2 Posted (PO: approved) | 3 Cancelled | 4 Closed | 5 Pending approval
    @InvoicingStatus  TINYINT      = NULL,     -- purchase orders: 0 not invoiced | 1 partially | 2 fully
    @DateFrom         DATE         = NULL,
    @DateTo           DATE         = NULL,
    @SortColumn       NVARCHAR(30) = N'DocumentDate',  -- DocumentNumber | DocumentDate | SupplierName | Status | TotalAmount | CreatedAtUtc
    @SortDirection    NVARCHAR(4)  = N'DESC',
    @PageNumber       INT          = 1,
    @PageSize         INT          = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @DocumentTypeCode = NULLIF(LTRIM(RTRIM(@DocumentTypeCode)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'DocumentNumber', N'DocumentDate', N'SupplierName', N'Status', N'TotalAmount', N'CreatedAtUtc')
        SET @SortColumn = N'DocumentDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT d.Id, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, dt.StockDirection,
           d.DocumentNumber, d.DocumentDate, d.ExpectedDate, d.BranchId, b.BranchName, d.WarehouseId, w.WarehouseName,
           d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName,
           d.CurrencyId, c.CurrencyCode, c.Symbol AS CurrencySymbol, c.DecimalPlaces, d.ExchangeRate,
           d.SupplierReference, d.ExporterReference, d.CommercialInvoiceNo, d.ReceiptMode,
           d.Status, d.TotalItems, d.TotalQuantity, d.Subtotal, d.TotalDiscount, d.TotalAmount, d.TotalAmountBase,
           d.SourceDocumentId, src.DocumentNumber AS SourceDocumentNumber,
           ReceivedPercent = CASE WHEN dt.Code = N'PO' AND ISNULL(prog.Ordered, 0) > 0 THEN CAST(100.0 * prog.Invoiced / prog.Ordered AS DECIMAL(5,1)) END,
           InvoicedPercent = CASE WHEN dt.Code = N'PO' AND ISNULL(prog.Ordered, 0) > 0 THEN CAST(100.0 * prog.Invoiced / prog.Ordered AS DECIMAL(5,1)) END,
           InvoicingStatus = CASE WHEN dt.Code <> N'PO' THEN NULL WHEN ISNULL(prog.Invoiced, 0) = 0 THEN 0
                                  WHEN prog.Invoiced >= prog.Ordered THEN 2 ELSE 1 END,
           DraftInvoiceCount = CASE WHEN dt.Code = N'PO' THEN (SELECT COUNT(*) FROM purchase.PurchaseDocuments x WHERE x.SourceDocumentId = d.Id AND x.Status = 1) END,
           -- (45) the item of a supplier invoice (the one of its first line) and how many it holds (more than 1: made before 45)
           ItemId = itm.ItemId, ItemCode = itm.ItemCode, ItemName = itm.ItemName, ItemCount = itm.ItemCount,
           d.ApprovalRequestedAtUtc, d.ApprovedAtUtc, apu.FullName AS ApprovedByName,
           d.PostedAtUtc, pu.FullName AS PostedByName, d.CancelledAtUtc, d.ClosedAtUtc,
           d.CreatedAtUtc, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.RowVersion,
           -- (47) supplier payments: posted purchase invoices only (NULL otherwise)
           PaidAmount = pst.PaidAmount, ReturnedAmount = pst.ReturnedAmount, OutstandingAmount = pst.OutstandingAmount, PaymentStatus = pst.PaymentStatus,
           COUNT(*) OVER () AS TotalCount
    FROM purchase.PurchaseDocuments d
    OUTER APPLY purchase.fn_InvoiceSettlement(d.Id) pst
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Branches b      ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w    ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Parties sp      ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    LEFT  JOIN purchase.PurchaseDocuments src ON src.Id = d.SourceDocumentId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    LEFT  JOIN security.Users apu ON apu.Id = d.ApprovedBy
    OUTER APPLY (SELECT Ordered = SUM(QuantityBase), Invoiced = SUM(ReceivedQuantityBase)
                 FROM purchase.PurchaseDocumentLines WHERE DocumentId = d.Id) prog
    OUTER APPLY (SELECT TOP (1) fl.ItemId, fi.ItemCode, fi.ItemName,
                        ItemCount = (SELECT COUNT(DISTINCT ItemId) FROM purchase.PurchaseDocumentLines WHERE DocumentId = d.Id)
                 FROM purchase.PurchaseDocumentLines fl INNER JOIN inventory.Items fi ON fi.Id = fl.ItemId
                 WHERE fl.DocumentId = d.Id AND dt.Code = N'PINV'
                 ORDER BY fl.LineNumber) itm
    WHERE dt.Family = N'Purchase'
      AND (@DocumentTypeCode IS NULL OR dt.Code = @DocumentTypeCode)
      AND (@Search IS NULL OR d.DocumentNumber LIKE N'%' + @Search + N'%' OR d.SupplierReference LIKE N'%' + @Search + N'%'
           OR d.ExporterReference LIKE N'%' + @Search + N'%' OR d.CommercialInvoiceNo LIKE N'%' + @Search + N'%'
           OR sp.PartyCode LIKE N'%' + @Search + N'%' OR sp.PartyName LIKE N'%' + @Search + N'%' OR d.Notes LIKE N'%' + @Search + N'%'
           OR (dt.Code = N'PINV' AND EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines sl INNER JOIN inventory.Items si ON si.Id = sl.ItemId
                                             WHERE sl.DocumentId = d.Id AND si.ItemCode LIKE N'%' + @Search + N'%')))
      AND (@BranchId IS NULL OR d.BranchId = @BranchId)
      AND (@WarehouseId IS NULL OR d.WarehouseId = @WarehouseId)
      AND (@SupplierId IS NULL OR d.SupplierId = @SupplierId)
      AND (@Status IS NULL OR d.Status = @Status)
      AND (@InvoicingStatus IS NULL OR (dt.Code = N'PO' AND
           CASE WHEN ISNULL(prog.Invoiced, 0) = 0 THEN 0 WHEN prog.Invoiced >= prog.Ordered THEN 2 ELSE 1 END = @InvoicingStatus))
      AND (@DateFrom IS NULL OR d.DocumentDate >= @DateFrom)
      AND (@DateTo IS NULL OR d.DocumentDate <= @DateTo)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN d.DocumentNumber WHEN N'SupplierName' THEN sp.PartyName END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN d.DocumentNumber WHEN N'SupplierName' THEN sp.PartyName END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'DocumentDate' THEN d.DocumentDate END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'DocumentDate' THEN d.DocumentDate END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Status' THEN CAST(d.Status AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Status' THEN CAST(d.Status AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'TotalAmount' THEN d.TotalAmount END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'TotalAmount' THEN d.TotalAmount END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN d.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN d.CreatedAtUtc END DESC,
        d.DocumentDate DESC, d.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.Id, d.DocumentTypeId, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, dt.StockDirection, dt.NumberOnPost,
           d.DocumentNumber, d.DocumentDate, d.ExpectedDate,
           d.BranchId, b.BranchCode, b.BranchName, d.WarehouseId, w.WarehouseCode, w.WarehouseName,
           d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName, sp.Phone AS SupplierPhone, sp.Email AS SupplierEmail, sp.Address AS SupplierAddress,
           d.CurrencyId, c.CurrencyCode, c.CurrencyName, c.Symbol AS CurrencySymbol, c.DecimalPlaces, c.IsBaseCurrency,
           d.RateType, d.ExchangeRate, bc.CurrencyCode AS BaseCurrencyCode,
           d.SupplierReference, d.ExporterReference, d.CommercialInvoiceNo, d.ReceiptMode, d.Notes, d.Status,
           IsContainerBound = CAST(CASE WHEN EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines x
                                                    WHERE x.DocumentId = d.Id AND x.ContainerLineId IS NOT NULL) THEN 1 ELSE 0 END AS BIT),
           ContainerCount = CASE WHEN dt.Code = N'PO'
                                 THEN (SELECT COUNT(DISTINCT cl.ContainerId) FROM logistics.ContainerLines cl
                                       INNER JOIN logistics.Containers c9 ON c9.Id = cl.ContainerId
                                       WHERE cl.PurchaseOrderId = d.Id AND c9.Status <> 8)
                                 ELSE (SELECT COUNT(DISTINCT cl.ContainerId) FROM purchase.PurchaseDocumentLines x
                                       INNER JOIN logistics.ContainerLines cl ON cl.Id = x.ContainerLineId
                                       WHERE x.DocumentId = d.Id) END,
           LoadedBase = CASE WHEN dt.Code = N'PO'
                             THEN ISNULL((SELECT SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                                          INNER JOIN logistics.Containers c9 ON c9.Id = cl.ContainerId
                                          WHERE cl.PurchaseOrderId = d.Id AND c9.Status <> 8), 0) END,
           ContainerChargesBase = cch.Share,
           ContainersNeeded = need.Containers,     -- (43) invoices: sum over the items of the pieces / pieces per container
           d.ApprovalRequestedAtUtc, d.ApprovalRequestedBy, rqu.FullName AS ApprovalRequestedByName,
           d.ApprovedAtUtc, d.ApprovedBy, apu.FullName AS ApprovedByName, d.ApprovalChannel,
           d.RejectedAtUtc, d.RejectedBy, rju.FullName AS RejectedByName, d.RejectReason,
           OrderedBase = prog.Ordered, InvoicedBase = prog.Invoiced, InDraftInvoicesBase = ISNULL(drf.InDraft, 0),
           InvoicingStatus = CASE WHEN dt.Code <> N'PO' THEN NULL WHEN ISNULL(prog.Invoiced, 0) = 0 THEN 0
                                  WHEN prog.Invoiced >= prog.Ordered THEN 2 ELSE 1 END,      -- 0 not, 1 partially, 2 fully invoiced
           d.TotalItems, d.TotalQuantity, d.Subtotal, d.TotalDiscount, d.TotalAmount, d.TotalAmountBase, d.TotalChargesBase, d.TotalLandedCostBase,
           d.SourceDocumentId, src.DocumentNumber AS SourceDocumentNumber, sdt.Code AS SourceDocumentTypeCode,
           d.SourceShortageId, sh.DocumentNumber AS SourceShortageNumber,
           d.PostedAtUtc, d.PostedBy, pu.FullName AS PostedByName,
           d.CancelledAtUtc, d.CancelledBy, xu.FullName AS CancelledByName, d.CancelReason,
           d.ClosedAtUtc, d.ClosedBy, ku.FullName AS ClosedByName, d.CloseReason,
           d.CreatedAtUtc, d.CreatedBy, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.UpdatedBy, uu.FullName AS UpdatedByName,
           d.RowVersion,
           -- (47) supplier payments: posted purchase invoices only (NULL otherwise)
           PaidAmount = pst.PaidAmount, ReturnedAmount = pst.ReturnedAmount, OutstandingAmount = pst.OutstandingAmount, PaymentStatus = pst.PaymentStatus
    FROM purchase.PurchaseDocuments d
    OUTER APPLY purchase.fn_InvoiceSettlement(d.Id) pst
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Branches b      ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w    ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Parties sp      ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    LEFT  JOIN masterdata.Currencies bc   ON bc.IsBaseCurrency = 1 AND bc.IsActive = 1
    LEFT  JOIN purchase.PurchaseDocuments src ON src.Id = d.SourceDocumentId
    LEFT  JOIN inventory.DocumentTypes sdt ON sdt.Id = src.DocumentTypeId
    LEFT  JOIN inventory.ShortageDocuments sh ON sh.Id = d.SourceShortageId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = d.UpdatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    LEFT  JOIN security.Users xu ON xu.Id = d.CancelledBy
    LEFT  JOIN security.Users ku ON ku.Id = d.ClosedBy
    LEFT  JOIN security.Users rqu ON rqu.Id = d.ApprovalRequestedBy
    LEFT  JOIN security.Users apu ON apu.Id = d.ApprovedBy
    LEFT  JOIN security.Users rju ON rju.Id = d.RejectedBy
    OUTER APPLY (SELECT Ordered = SUM(pl.QuantityBase), Invoiced = SUM(pl.ReceivedQuantityBase)
                 FROM purchase.PurchaseDocumentLines pl WHERE pl.DocumentId = d.Id) prog
    OUTER APPLY (SELECT InDraft = SUM(x.QuantityBase)
                 FROM purchase.PurchaseDocumentLines pl
                 INNER JOIN purchase.PurchaseDocumentLines x ON x.SourceLineId = pl.Id
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId AND xd.Status = 1
                 WHERE pl.DocumentId = d.Id) drf
    OUTER APPLY (SELECT Share = SUM(a.AmountBase * CAST(x.QuantityBase AS DECIMAL(18,6)) / NULLIF(cl.QuantityBase, 0))
                 FROM purchase.PurchaseDocumentLines x
                 INNER JOIN logistics.ContainerLines cl            ON cl.Id = x.ContainerLineId
                 INNER JOIN logistics.ContainerChargeAllocations a ON a.ContainerLineId = cl.Id
                 INNER JOIN logistics.ContainerCharges ch          ON ch.Id = a.ChargeId AND ch.Status = 2 AND ch.IncludeInLandedCost = 1
                 WHERE x.DocumentId = d.Id) cch
    OUTER APPLY (SELECT Containers = CASE WHEN dt.Code = N'PINV'
                                          THEN CAST(SUM(CAST(s.InvoicedBase AS DECIMAL(19,4)) / s.PcsPerContainer) AS DECIMAL(18,2)) END
                 FROM purchase.fn_PurchaseInvoice_ItemContainers(d.Id) s) need
    WHERE d.Id = @Id;

    SELECT l.Id, l.DocumentId, l.LineNumber, l.ItemId, i.ItemCode, i.ItemName,
           l.ItemUnitId, ut.UnitTypeName, iu.SkuCode, iu.Barcode, l.PackingFormula,
           l.WarehouseId, w.WarehouseCode, w.WarehouseName, l.ExpiryDate,
           l.Quantity, l.QuantityBase, l.UnitPrice, l.DiscountPercent, l.LineDiscount, l.LineTotal,
           l.UnitCostBase, LandedCostBase = l.UnitCostBase, l.FobCostBase, l.AllocatedChargesBase,
           l.ReceivedQuantityBase, l.ReturnedQuantityBase, l.ShippedQuantityBase,
           AllocatedToContainersBase = CASE WHEN dt.Code = N'PO' THEN ISNULL(ct.Allocated, 0)
                                            WHEN l.ContainerLineId IS NOT NULL THEN l.QuantityBase ELSE 0 END,
           TransitBase = CASE WHEN dt.Code = N'PO' THEN ISNULL(ct.Transit, 0)
                              WHEN lct.Status IN (3, 4, 5) THEN l.QuantityBase ELSE 0 END,
           RemainingBase = CASE WHEN dt.Code = N'PO' THEN l.QuantityBase - l.ReceivedQuantityBase
                                WHEN dt.Code = N'PINV' THEN l.QuantityBase - l.ReturnedQuantityBase END,
           AvailableForContainerBase = CASE WHEN dt.Code = N'PO' THEN l.QuantityBase - ISNULL(ct.Allocated, 0) - ISNULL(dir.Qty, 0) END,
           InvoicedDirectBase = CASE WHEN dt.Code = N'PO' THEN ISNULL(dir.Qty, 0) END,
           l.ContainerLineId, ContainerId = lcl.ContainerId, ContainerRef = lct.ContainerRef, ContainerNo = lct.ContainerNo,
           ContainerStatus = lct.Status,
           ContainerChargesBase = CASE WHEN l.ContainerLineId IS NOT NULL THEN ISNULL(lch.Share, 0) END,
           EstimatedLandedCostBase = CASE WHEN l.ContainerLineId IS NOT NULL
                                          THEN COALESCE(lcl.LandedCostBase,
                                                        ISNULL(l.FobCostBase, l.LineTotal / NULLIF(d.ExchangeRate, 0) / NULLIF(l.QuantityBase, 0))
                                                        + ISNULL(lch.Share, 0) / NULLIF(l.QuantityBase, 0)) END,
           InDraftDocumentsBase = ISNULL(dr.Qty, 0),
           AvailableToInvoiceBase = CASE WHEN dt.Code = N'PO' THEN l.QuantityBase - l.ReceivedQuantityBase - ISNULL(dr.Qty, 0) END,
           l.ImportRowNumber, l.Notes, l.SourceLineId,
           OnHandBase  = inventory.fn_StockOnHand(l.ItemId, l.WarehouseId),
           ItemLastCost = i.LastCost, ItemAverageCost = i.AverageCost, ItemFobCost = i.FobCost
    FROM purchase.PurchaseDocumentLines l
    INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
    INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId
    INNER JOIN inventory.Items i            ON i.Id = l.ItemId
    INNER JOIN inventory.ItemUnits iu       ON iu.Id = l.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut      ON ut.Id = iu.UnitTypeId
    INNER JOIN masterdata.Warehouses w      ON w.Id = l.WarehouseId
    OUTER APPLY (SELECT Allocated = SUM(cl.QuantityBase),
                        Transit   = SUM(CASE WHEN c.Status IN (3, 4, 5) THEN cl.QuantityBase - ISNULL(cl.ReceivedQuantityBase, 0) ELSE 0 END)
                 FROM logistics.ContainerLines cl
                 INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                 WHERE cl.PoLineId = l.Id AND c.Status <> 8) ct
    OUTER APPLY (SELECT Qty = SUM(x.QuantityBase) FROM purchase.PurchaseDocumentLines x
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
                 WHERE x.SourceLineId = l.Id AND x.ContainerLineId IS NULL AND xd.Status IN (1, 2, 4) AND xd.ReceiptMode <> 2 AND dt.Code = N'PO') dir
    LEFT  JOIN logistics.ContainerLines lcl ON lcl.Id = l.ContainerLineId
    LEFT  JOIN logistics.Containers lct     ON lct.Id = lcl.ContainerId
    OUTER APPLY (SELECT Charges = SUM(a.AmountBase)
                 FROM logistics.ContainerChargeAllocations a
                 INNER JOIN logistics.ContainerCharges ch ON ch.Id = a.ChargeId AND ch.Status = 2 AND ch.IncludeInLandedCost = 1
                 WHERE a.ContainerLineId = l.ContainerLineId) lcc
    OUTER APPLY (SELECT Share = lcc.Charges * CAST(l.QuantityBase AS DECIMAL(18,6)) / NULLIF(lcl.QuantityBase, 0)) lch
    OUTER APPLY (SELECT Qty = SUM(x.QuantityBase) FROM purchase.PurchaseDocumentLines x
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
                 WHERE x.SourceLineId = l.Id AND xd.Status = 1) dr
    WHERE l.DocumentId = @Id
    ORDER BY l.LineNumber;

    SELECT f.Id, f.DocumentId, f.FileName, f.ContentType, f.SizeBytes, f.CreatedAtUtc, u.FullName AS CreatedByName
    FROM purchase.PurchaseDocumentFiles f
    LEFT JOIN security.Users u ON u.Id = f.CreatedBy
    WHERE f.DocumentId = @Id
    ORDER BY f.CreatedAtUtc DESC;

    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM purchase.PurchaseDocumentAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.DocumentId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;

    SELECT Relation = N'Source', x.Id, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, x.DocumentNumber, x.DocumentDate, x.Status, x.TotalAmount, c.CurrencyCode
    FROM purchase.PurchaseDocuments d
    INNER JOIN purchase.PurchaseDocuments x ON x.Id = d.SourceDocumentId
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = x.DocumentTypeId
    INNER JOIN masterdata.Currencies c ON c.Id = x.CurrencyId
    WHERE d.Id = @Id
    UNION ALL
    SELECT N'Child', x.Id, dt.Code, dt.Name, x.DocumentNumber, x.DocumentDate, x.Status, x.TotalAmount, c.CurrencyCode
    FROM purchase.PurchaseDocuments x
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = x.DocumentTypeId
    INNER JOIN masterdata.Currencies c ON c.Id = x.CurrencyId
    WHERE x.SourceDocumentId = @Id
    ORDER BY Relation DESC, DocumentDate, Id;

    -- 6: charges of the invoice (kind PINV), of its landed cost adjustments (kind LCA) and, for an import, the charges of
    --    its containers (kind CNT, read-only: DocumentId = container, AdjustmentStatus = charge status) with ShareBase =
    --    the part that falls on this invoice's lines.
    SELECT c.Id, c.DocumentKind, c.DocumentId, SourceNumber = CASE WHEN c.DocumentKind = N'LCA' THEN lca.DocumentNumber ELSE d.DocumentNumber END,
           c.LineNumber, c.ChargeTypeId, ct.ChargeCode, ct.ChargeName, c.Description, c.ProviderPartyId, pp.PartyName AS ProviderName, c.Reference,
           c.CurrencyId, cur.CurrencyCode, c.RateType, c.ExchangeRate, c.Amount, c.AmountBase, c.AllocationMethod, c.IncludeInLandedCost, c.IncludedInSupplierInvoice, c.Notes,
           AllocatedBase = (SELECT SUM(AmountBase) FROM purchase.PurchaseChargeAllocations x WHERE x.ChargeId = c.Id),
           AdjustmentStatus = lca.Status,
           ContainerId = CAST(NULL AS INT), ContainerRef = CAST(NULL AS NVARCHAR(30)), ChargeDate = CAST(NULL AS DATE),
           ChargeStatus = CAST(NULL AS TINYINT), ShareBase = CAST(NULL AS DECIMAL(18,2))
    FROM purchase.PurchaseCharges c
    INNER JOIN purchase.ChargeTypes ct ON ct.Id = c.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = c.CurrencyId
    LEFT  JOIN masterdata.Parties pp ON pp.Id = c.ProviderPartyId
    LEFT  JOIN purchase.PurchaseDocuments d ON d.Id = c.DocumentId AND c.DocumentKind = N'PINV'
    LEFT  JOIN purchase.LandedCostAdjustments lca ON lca.Id = c.DocumentId AND c.DocumentKind = N'LCA'
    WHERE (c.DocumentKind = N'PINV' AND c.DocumentId = @Id)
       OR (c.DocumentKind = N'LCA' AND lca.SourceInvoiceId = @Id)
    UNION ALL
    SELECT ch.Id, N'CNT', ch.ContainerId, cn.ContainerRef,
           CAST(ROW_NUMBER() OVER (ORDER BY cn.ContainerRef, ch.ChargeDate, ch.Id) AS INT),
           ch.ChargeTypeId, t.ChargeCode, t.ChargeName, ch.Description, ch.ProviderPartyId, pp.PartyName, ch.Reference,
           ch.CurrencyId, cur.CurrencyCode, ch.RateType, ch.ExchangeRate, ch.Amount, ch.AmountBase, ch.AllocationMethod, ch.IncludeInLandedCost,
           CAST(0 AS BIT), ch.Notes,
           ISNULL(s.Share, 0), ch.Status,
           ch.ContainerId, cn.ContainerRef, ch.ChargeDate, ch.Status, CAST(ISNULL(s.Share, 0) AS DECIMAL(18,2))
    FROM logistics.ContainerCharges ch
    INNER JOIN logistics.Containers cn   ON cn.Id = ch.ContainerId
    INNER JOIN purchase.ChargeTypes t    ON t.Id = ch.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = ch.CurrencyId
    LEFT  JOIN masterdata.Parties pp     ON pp.Id = ch.ProviderPartyId
    OUTER APPLY (SELECT Share = SUM(a.AmountBase * CAST(l.QuantityBase AS DECIMAL(18,6)) / NULLIF(cl.QuantityBase, 0))
                 FROM purchase.PurchaseDocumentLines l
                 INNER JOIN logistics.ContainerLines cl            ON cl.Id = l.ContainerLineId
                 INNER JOIN logistics.ContainerChargeAllocations a ON a.ContainerLineId = cl.Id AND a.ChargeId = ch.Id
                 WHERE l.DocumentId = @Id) s
    WHERE ch.Status IN (1, 2)
      AND EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines l
                  INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
                  WHERE l.DocumentId = @Id AND cl.ContainerId = ch.ContainerId)
    ORDER BY 2, 3, 5;

    -- 7: containers of the document: for an order the containers carrying its lines, for an invoice its containers.
    SELECT ct.Id, ct.ContainerRef, ct.ContainerNo, ct.Status, ct.DispatchDate, ct.Eta, ct.OffloadedDate,
           ct.CurrentLocation, w.WarehouseCode, w.WarehouseName,
           AllocatedBase = ISNULL(x.Allocated, 0), ReceivedBase = ISNULL(x.Received, 0), InvoicedBase = ISNULL(x.Invoiced, 0),
           ct.ContainerTypeId, ctt.TypeCode AS ContainerTypeCode, ct.PurchaseOrderId
    FROM logistics.Containers ct
    INNER JOIN masterdata.ContainerTypes ctt ON ctt.Id = ct.ContainerTypeId
    LEFT  JOIN masterdata.Warehouses w       ON w.Id = ct.WarehouseId
    CROSS APPLY (SELECT Allocated = SUM(q.Allocated), Received = SUM(q.Received), Invoiced = SUM(q.Invoiced)
                 FROM (SELECT Allocated = cl.QuantityBase, Received = ISNULL(cl.ReceivedQuantityBase, 0),
                              Invoiced = ISNULL((SELECT SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                                                 INNER JOIN purchase.PurchaseDocuments pid ON pid.Id = pil.DocumentId
                                                 WHERE pil.ContainerLineId = cl.Id AND pid.Status IN (2, 4)), 0)
                       FROM logistics.ContainerLines cl
                       WHERE cl.ContainerId = ct.Id AND cl.PurchaseOrderId = @Id
                       UNION ALL
                       SELECT l.QuantityBase, l.ReceivedQuantityBase, l.QuantityBase
                       FROM purchase.PurchaseDocumentLines l
                       INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
                       WHERE l.DocumentId = @Id AND cl.ContainerId = ct.Id) q) x
    WHERE ct.Status <> 8
      AND (EXISTS (SELECT 1 FROM logistics.ContainerLines cl WHERE cl.ContainerId = ct.Id AND cl.PurchaseOrderId = @Id)
           OR EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines l
                      INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
                      WHERE l.DocumentId = @Id AND cl.ContainerId = ct.Id))
    ORDER BY ct.ContainerRef;

    -- 8: approval requests and decisions (purchase orders).
    SELECT a.Id, a.RequestNo, a.ApproverUserId, u.FullName AS ApproverName, u.Email AS ApproverEmail,
           a.Status, a.ExpiresAtUtc, a.DecidedAtUtc, a.DecisionNote, a.Channel, a.RequestedAtUtc, ru.FullName AS RequestedByName
    FROM purchase.PurchaseOrderApprovals a
    INNER JOIN security.Users u ON u.Id = a.ApproverUserId
    LEFT  JOIN security.Users ru ON ru.Id = a.RequestedBy
    WHERE a.DocumentId = @Id
    ORDER BY a.RequestNo DESC, a.Id;
END
GO

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Cancel
    @Id         INT,
    @Reason     NVARCHAR(300),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 65000, 'A cancellation reason is required.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Direction SMALLINT, @SourceId INT, @Number NVARCHAR(30), @ReceiptMode TINYINT;
        SELECT @Status = d.Status, @TypeCode = dt.Code, @Direction = dt.StockDirection, @SourceId = d.SourceDocumentId,
               @Number = d.DocumentNumber, @ReceiptMode = d.ReceiptMode
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @Status NOT IN (2, 4) THROW 65010, 'Only posted documents can be cancelled (delete drafts instead).', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE SourceDocumentId = @Id AND Status IN (2, 4))
            THROW 65011, 'This document cannot be cancelled: posted documents were created from it. Cancel those first.', 1;
        IF EXISTS (SELECT 1 FROM purchase.LandedCostAdjustments WHERE SourceInvoiceId = @Id AND Status = 2)
            THROW 65011, 'This invoice cannot be cancelled: posted landed cost adjustments refer to it. Cancel those first.', 1;
        -- (47) Money paid against it would be left pointing at nothing: the payments are reversed (or de-allocated) first.
        IF EXISTS (SELECT 1 FROM purchase.PaymentAllocations a INNER JOIN purchase.Payments p ON p.Id = a.PaymentId
                   WHERE a.PurchaseDocumentId = @Id AND a.RemovedAtUtc IS NULL AND p.Status = 2)
            THROW 65011, 'This invoice cannot be cancelled: supplier payments are allocated to it. Reverse those payments (or remove the allocations) first.', 1;

        DECLARE @Ct NVARCHAR(400);
        IF @TypeCode = N'PO' AND EXISTS (SELECT 1 FROM logistics.ContainerLines cl INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                                         WHERE cl.PurchaseOrderId = @Id AND c.Status <> 8)
            THROW 65021, 'This purchase order is loaded into containers. Cancel those containers (or remove its lines from them) first.', 1;
        SELECT TOP (1) @Ct = N'This invoice cannot be cancelled: container ' + c.ContainerRef + N' was already offloaded with it. Reverse the offload first.'
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
        INNER JOIN logistics.Containers c      ON c.Id = cl.ContainerId
        WHERE l.DocumentId = @Id AND c.Status IN (6, 7)
        ORDER BY c.ContainerRef;
        IF @Ct IS NOT NULL THROW 69012, @Ct, 1;

        DECLARE @Msg NVARCHAR(400);
        IF @Direction = 1 AND @ReceiptMode = 1
        BEGIN
            SELECT TOP (1) @Msg = N'Cannot cancel: ' + i.ItemCode + N' in ' + w.WarehouseCode + N' has only '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N' left, but this document added ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 65007, @Msg, 1;
        END

        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, IsReversal, CreatedBy)
        SELECT SYSUTCDATETIME(), m.ItemId, m.WarehouseId, m.BranchId, -m.QuantityBase, m.UnitCostBase,
               m.DocumentFamily, m.DocumentTypeCode, m.DocumentId, m.DocumentLineId, m.DocumentNumber, m.ReasonCode, m.ExpiryDate, 1, @UserId
        FROM inventory.StockMovements m
        WHERE m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = @TypeCode AND m.DocumentId = @Id AND m.IsReversal = 0;

        IF @TypeCode = N'PINV'
            UPDATE purchase.PurchaseDocumentLines SET ReceivedQuantityBase = 0 WHERE DocumentId = @Id;

        IF @SourceId IS NOT NULL AND @TypeCode = N'PINV'
        BEGIN
            UPDATE s SET ReceivedQuantityBase = s.ReceivedQuantityBase - x.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;

            IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @SourceId AND Status = 4 AND CloseReason = N'Fully received')
            BEGIN
                UPDATE purchase.PurchaseDocuments SET Status = 2, ClosedAtUtc = NULL, ClosedBy = NULL, CloseReason = NULL WHERE Id = @SourceId;
                INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@SourceId, N'Updated', N'Re-opened: ' + @Number + N' was cancelled', @UserId);
            END
        END
        IF @SourceId IS NOT NULL AND @TypeCode = N'PRET'
        BEGIN
            UPDATE s SET ReturnedQuantityBase = s.ReturnedQuantityBase - x.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;
        END

        UPDATE purchase.PurchaseDocuments
        SET Status = 3, CancelledAtUtc = SYSUTCDATETIME(), CancelledBy = @UserId, CancelReason = @Reason,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@Id, N'Cancelled', @Reason, @UserId);

        -- A cancelled receipt / return changes the cost history: replay the ledger for the items concerned.
        IF @Direction <> 0
        BEGIN
            DECLARE @ItemId INT;
            DECLARE items CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT ItemId FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id;
            OPEN items; FETCH NEXT FROM items INTO @ItemId;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC inventory.usp_Item_RebuildCosts @ItemId;
                FETCH NEXT FROM items INTO @ItemId;
            END
            CLOSE items; DEALLOCATE items;
        END

        -- containers of an import: the value basis of their charges changed
        DECLARE @Cid INT;
        DECLARE cts CURSOR LOCAL FAST_FORWARD FOR
            SELECT DISTINCT cl.ContainerId FROM purchase.PurchaseDocumentLines l
            INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
            WHERE l.DocumentId = @Id;
        OPEN cts;
        FETCH NEXT FROM cts INTO @Cid;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC logistics.usp_Container_ReallocateCharges @Cid, 1, 1;
            INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
            VALUES (@Cid, N'Updated', LEFT(N'Purchase invoice ' + ISNULL(@Number, N'') + N' cancelled: ' + @Reason, 500), @UserId);
            FETCH NEXT FROM cts INTO @Cid;
        END
        CLOSE cts;
        DEALLOCATE cts;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE logistics.usp_ContainerCharge_Search
    @Search          NVARCHAR(100) = NULL,   -- container ref / no., reference, description, provider
    @ContainerId     INT           = NULL,
    @MovementId      INT           = NULL,
    @ChargeTypeId    INT           = NULL,
    @ProviderPartyId INT           = NULL,
    @Status          TINYINT       = NULL,
    @DateFrom        DATE          = NULL,
    @DateTo          DATE          = NULL,
    @SortColumn      NVARCHAR(30)  = N'ChargeDate',   -- ChargeDate | ContainerRef | ChargeName | AmountBase | Status | CreatedAtUtc
    @SortDirection   NVARCHAR(4)   = N'DESC',
    @PageNumber      INT           = 1,
    @PageSize        INT           = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'ChargeDate', N'ContainerRef', N'ChargeName', N'AmountBase', N'Status', N'CreatedAtUtc') SET @SortColumn = N'ChargeDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT ch.Id, ch.ContainerId, c.ContainerRef, c.ContainerNo, c.Status AS ContainerStatus,
           ch.MovementId, m.MovementNo, ch.GroupId,
           GroupSize = CASE WHEN ch.GroupId IS NULL THEN 1 ELSE (SELECT COUNT(*) FROM logistics.ContainerCharges g WHERE g.GroupId = ch.GroupId) END,
           ch.ChargeTypeId, t.ChargeCode, t.ChargeName, ch.Description, ch.ProviderPartyId, pp.PartyName AS ProviderName, ch.Reference,
           ch.ChargeDate, ch.CurrencyId, cur.CurrencyCode, ch.RateType, ch.ExchangeRate, ch.Amount, ch.AmountBase,
           ch.AllocationMethod, ch.IncludeInLandedCost, ch.Status, ch.AppliedAtOffload, ch.AdjustedAfterOffload,
           AttachmentCount = (SELECT COUNT(*) FROM logistics.ContainerAttachments a WHERE a.ChargeId = ch.Id),
           ch.PostedAtUtc, ch.CreatedAtUtc, cu.FullName AS CreatedByName, ch.RowVersion,
           TotalAmountBase = SUM(ch.AmountBase) OVER (),
           -- (47) supplier payments: posted charges only (NULL otherwise)
           PaidAmount = pst.PaidAmount, OutstandingAmount = pst.OutstandingAmount, PaymentStatus = pst.PaymentStatus,
           COUNT(*) OVER () AS TotalCount
    FROM logistics.ContainerCharges ch
    OUTER APPLY logistics.fn_ContainerChargeSettlement(ch.Id) pst
    INNER JOIN logistics.Containers c    ON c.Id = ch.ContainerId
    INNER JOIN purchase.ChargeTypes t    ON t.Id = ch.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = ch.CurrencyId
    LEFT  JOIN masterdata.Parties pp     ON pp.Id = ch.ProviderPartyId
    LEFT  JOIN logistics.Movements m     ON m.Id = ch.MovementId
    LEFT  JOIN security.Users cu         ON cu.Id = ch.CreatedBy
    WHERE (@Search IS NULL OR c.ContainerRef LIKE N'%' + @Search + N'%' OR c.ContainerNo LIKE N'%' + @Search + N'%'
           OR ch.Reference LIKE N'%' + @Search + N'%' OR ch.Description LIKE N'%' + @Search + N'%' OR pp.PartyName LIKE N'%' + @Search + N'%')
      AND (@ContainerId IS NULL OR ch.ContainerId = @ContainerId)
      AND (@MovementId IS NULL OR ch.MovementId = @MovementId)
      AND (@ChargeTypeId IS NULL OR ch.ChargeTypeId = @ChargeTypeId)
      AND (@ProviderPartyId IS NULL OR ch.ProviderPartyId = @ProviderPartyId)
      AND (@Status IS NULL OR ch.Status = @Status)
      AND (@DateFrom IS NULL OR ch.ChargeDate >= @DateFrom)
      AND (@DateTo IS NULL OR ch.ChargeDate <= @DateTo)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'ContainerRef' THEN c.ContainerRef WHEN N'ChargeName' THEN t.ChargeName END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'ContainerRef' THEN c.ContainerRef WHEN N'ChargeName' THEN t.ChargeName END END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'ChargeDate' THEN ch.ChargeDate END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'ChargeDate' THEN ch.ChargeDate END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'AmountBase' THEN ch.AmountBase END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'AmountBase' THEN ch.AmountBase END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Status' THEN CAST(ch.Status AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Status' THEN CAST(ch.Status AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN ch.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN ch.CreatedAtUtc END DESC,
        ch.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE logistics.usp_ContainerCharge_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT ch.Id, ch.ContainerId, c.ContainerRef, c.ContainerNo, c.Status AS ContainerStatus,
           ch.MovementId, m.MovementNo, ch.GroupId,
           ch.ChargeTypeId, t.ChargeCode, t.ChargeName, ch.Description, ch.ProviderPartyId, pp.PartyName AS ProviderName, ch.Reference,
           ch.ChargeDate, ch.CurrencyId, cur.CurrencyCode, ch.RateType, ch.ExchangeRate, ch.Amount, ch.AmountBase,
           ch.AllocationMethod, ch.IncludeInLandedCost, ch.Status, ch.AppliedAtOffload, ch.AdjustedAfterOffload, ch.Notes,
           ch.PostedAtUtc, pu.FullName AS PostedByName, ch.CancelledAtUtc, xu.FullName AS CancelledByName, ch.CancelReason,
           ch.CreatedAtUtc, cu.FullName AS CreatedByName, ch.UpdatedAtUtc, uu.FullName AS UpdatedByName, ch.RowVersion,
           -- (47) supplier payments: posted charges only (NULL otherwise)
           PaidAmount = pst.PaidAmount, OutstandingAmount = pst.OutstandingAmount, PaymentStatus = pst.PaymentStatus
    FROM logistics.ContainerCharges ch
    OUTER APPLY logistics.fn_ContainerChargeSettlement(ch.Id) pst
    INNER JOIN logistics.Containers c    ON c.Id = ch.ContainerId
    INNER JOIN purchase.ChargeTypes t    ON t.Id = ch.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = ch.CurrencyId
    LEFT  JOIN masterdata.Parties pp     ON pp.Id = ch.ProviderPartyId
    LEFT  JOIN logistics.Movements m     ON m.Id = ch.MovementId
    LEFT  JOIN security.Users pu ON pu.Id = ch.PostedBy
    LEFT  JOIN security.Users xu ON xu.Id = ch.CancelledBy
    LEFT  JOIN security.Users cu ON cu.Id = ch.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = ch.UpdatedBy
    WHERE ch.Id = @Id;

    SELECT cl.Id AS ContainerLineId, cl.LineNumber, cl.ItemId, i.ItemCode, i.ItemName,
           QuantityBase = ISNULL(cl.ReceivedQuantityBase, cl.QuantityBase),
           a.Basis, AmountBase = ISNULL(a.AmountBase, 0), IsManual = ISNULL(a.IsManual, 0),
           PerUnitBase = ISNULL(a.AmountBase, 0) / NULLIF(ISNULL(cl.ReceivedQuantityBase, cl.QuantityBase), 0)
    FROM logistics.ContainerCharges ch
    INNER JOIN logistics.ContainerLines cl ON cl.ContainerId = ch.ContainerId
    INNER JOIN inventory.Items i           ON i.Id = cl.ItemId
    LEFT  JOIN logistics.ContainerChargeAllocations a ON a.ChargeId = ch.Id AND a.ContainerLineId = cl.Id
    WHERE ch.Id = @Id
    ORDER BY cl.LineNumber;

    SELECT a.Id, a.ContainerId, a.MovementId, a.AttachmentTypeId, at.Category, at.SubType,
           a.FileId, f.FileName, f.ContentType, f.SizeBytes, a.Note, a.DocumentDate, a.CreatedAtUtc, u.FullName AS CreatedByName
    FROM logistics.ContainerAttachments a
    INNER JOIN logistics.Files f ON f.Id = a.FileId
    LEFT  JOIN masterdata.AttachmentTypes at ON at.Id = a.AttachmentTypeId
    LEFT  JOIN security.Users u ON u.Id = a.CreatedBy
    WHERE a.ChargeId = @Id
    ORDER BY a.CreatedAtUtc DESC;

    SELECT g.Id, g.ContainerId, c.ContainerRef, c.ContainerNo, g.Amount, g.AmountBase, g.Status, g.RowVersion
    FROM logistics.ContainerCharges ch
    INNER JOIN logistics.ContainerCharges g ON g.GroupId = ch.GroupId AND g.Id <> ch.Id
    INNER JOIN logistics.Containers c       ON c.Id = g.ContainerId
    WHERE ch.Id = @Id AND ch.GroupId IS NOT NULL
    ORDER BY c.ContainerRef;
END
GO

CREATE OR ALTER PROCEDURE logistics.usp_ContainerCharge_Cancel
    @Id         INT,
    @Reason     NVARCHAR(300),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 70000, 'A cancellation reason is required.', 1;

    DECLARE @ContainerId INT, @Status TINYINT, @CtStatus TINYINT, @InCost BIT, @Label NVARCHAR(200);
    SELECT @ContainerId = ch.ContainerId, @Status = ch.Status, @CtStatus = c.Status,
           @InCost = CASE WHEN c.Status = 6 AND ch.IncludeInLandedCost = 1 AND (ch.AppliedAtOffload = 1 OR ch.AdjustedAfterOffload = 1) THEN 1 ELSE 0 END,
           @Label = t.ChargeCode + N' ' + t.ChargeName + N' ' + CAST(ch.Amount AS NVARCHAR(30)) + N' ' + cur.CurrencyCode
    FROM logistics.ContainerCharges ch
    INNER JOIN logistics.Containers c    ON c.Id = ch.ContainerId
    INNER JOIN purchase.ChargeTypes t    ON t.Id = ch.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = ch.CurrencyId
    WHERE ch.Id = @Id;

    IF @ContainerId IS NULL THROW 70006, 'Charge not found.', 1;
    IF @Status <> 2 THROW 70010, 'Only a posted charge can be cancelled (delete a draft instead).', 1;
    -- (47) Money paid against it would be left pointing at nothing: the payments are reversed (or de-allocated) first.
    IF EXISTS (SELECT 1 FROM purchase.PaymentAllocations a INNER JOIN purchase.Payments p ON p.Id = a.PaymentId
               WHERE a.ContainerChargeId = @Id AND a.RemovedAtUtc IS NULL AND p.Status = 2)
        THROW 70010, 'This charge cannot be cancelled: supplier payments are allocated to it. Reverse those payments (or remove the allocations) first.', 1;
    IF @CtStatus = 7 THROW 70010, 'The container is closed. Reopen it first.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.ContainerCharges WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 70004, 'This charge was modified by another user. Reload the page and try again.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        UPDATE logistics.ContainerCharges
        SET Status = 3, CancelledAtUtc = SYSUTCDATETIME(), CancelledBy = @UserId, CancelReason = @Reason,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        EXEC logistics.usp_Container_RecalcCosts @ContainerId;
        IF @InCost = 1 EXEC logistics.usp_ContainerCharge_ApplyCost @Id, -1, @UserId;

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        VALUES (@ContainerId, N'Updated', LEFT(N'Charge cancelled: ' + @Label + N' - ' + @Reason
                                               + CASE WHEN @InCost = 1 THEN N' (item costs adjusted back)' ELSE N'' END, 500), @UserId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 14. Check */

SELECT name FROM sys.objects WHERE schema_id = SCHEMA_ID(N'purchase') AND (name LIKE N'usp_Payment%' OR name LIKE N'fn_%Payment%' OR name = N'fn_PayableDocument') ORDER BY name;
PRINT 'Script 47 applied: supplier payments logic.';
GO

SET NOEXEC OFF;
GO
