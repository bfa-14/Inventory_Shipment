SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ==================================================================================================
   73: Supplier payments - a purchase invoice is paid container by container (change to US-PAY-001)
   --------------------------------------------------------------------------------------------------
   A payment to a purchase invoice whose lines travel in containers is split over those containers, so
   each container shows what is paid on it: Pending, Partially Paid or Fully Paid.

   THE RULES
     - Which containers: an invoice line LINKED to a container line (Create Invoice from Containers, Link
       containers) belongs to that container. Its lines in no container form one more row, "Unlinked items",
       naming its items. Amounts in the invoice's currency, less what was returned.
     - An invoice without containers is allocated as before, with no split.
     - An invoice with ONE container and nothing else is allocated as before; the whole amount is recorded
       against that container by itself.
     - An invoice with two rows or more (containers, or a container and unlinked items) MUST be split: the
       amounts add up to the invoice amount, none is above what that row still owes (posted payments only),
       none is negative.
     - A draft may hold an incomplete split; posting a Purchase Invoice Payment demands the full split, and so
       does allocating a Free payment later.
     - Removing an allocation or reversing the payment stops its container amounts counting.
     - The invoice's own paid / outstanding / status is unchanged: the total of all its allocations.
     - Container charge payments are not concerned.

     purchase.PaymentAllocationContainers        new table: allocation -> container (NULL = Unlinked items) -> amount
     purchase.tvp_PaymentAllocationContainer     new type: invoice, container (0 = Unlinked items), amount
     purchase.fn_InvoiceContainerSettlement      new: an invoice, container by container
     purchase.usp_Payment_CheckContainerSplit    new: the split rules (73000 / 73008 / 73009)
     purchase.usp_Payment_Save                   new parameter @AllocationContainers; checks and stores the split
     purchase.usp_Payment_Post                   demands a balanced split for a Purchase Invoice Payment
     purchase.usp_Payment_Allocate               new parameter @AllocationContainers; balanced split
     purchase.usp_Payment_Get                    one more result set (last): the split of each invoice allocation
     purchase.usp_Payment_OpenDocuments          one more result set: the containers of each open invoice

   Each changed procedure is re-created from its current body with only these changes. Idempotent.
   ================================================================================================== */

/* ================================================================== 1. Table and type */

/* ONE ROW PER CONTAINER (or "Unlinked items") UNDER AN INVOICE ALLOCATION, in the invoice's currency. The
   row lives and dies with its allocation: removing or reversing the allocation stops it counting. */
IF OBJECT_ID(N'purchase.PaymentAllocationContainers', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.PaymentAllocationContainers
    (
        Id                  INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PaymentAllocationContainers PRIMARY KEY,
        PaymentAllocationId INT               NOT NULL
            CONSTRAINT FK_PaymentAllocationContainers_Allocation REFERENCES purchase.PaymentAllocations (Id) ON DELETE CASCADE,
        ContainerId         INT               NULL          -- NULL = the invoice lines in no container ("Unlinked items")
            CONSTRAINT FK_PaymentAllocationContainers_Container REFERENCES logistics.Containers (Id),
        AmountDocCurrency   DECIMAL(18,2)     NOT NULL CONSTRAINT CK_PaymentAllocationContainers_Amount CHECK (AmountDocCurrency > 0),
        ContainerKey        AS ISNULL(ContainerId, 0) PERSISTED,
        CONSTRAINT UQ_PaymentAllocationContainers UNIQUE (PaymentAllocationId, ContainerKey)
    );
    PRINT 'Created table purchase.PaymentAllocationContainers';
END
GO

IF TYPE_ID(N'purchase.tvp_PaymentAllocationContainer') IS NULL
BEGIN
    CREATE TYPE purchase.tvp_PaymentAllocationContainer AS TABLE
    (
        DocumentId  INT           NOT NULL,       -- the purchase invoice
        ContainerId INT           NOT NULL,       -- 0 = "Unlinked items"
        Amount      DECIMAL(18,2) NOT NULL,       -- in the invoice's currency
        PRIMARY KEY (DocumentId, ContainerId)
    );
    PRINT 'Created type purchase.tvp_PaymentAllocationContainer';
END
GO

/* ================================================================== 2. A purchase invoice, container by container */

/* ONE ROW PER CONTAINER OF A PURCHASE INVOICE, plus one row ContainerKey 0 "Unlinked items" for its lines in no
   container, in the invoice's currency. A line belongs to a container when it is LINKED to one of that
   container's lines (Create Invoice from Containers, Link containers on the invoice).
     ContainerAmount  the invoice lines in that container, less what was returned from those lines
     PaidAmount       what POSTED payments allocated to that container (live allocations only)
     PaymentStatus    Pending | Partially Paid | Fully Paid
   HasContainers  1 when at least one line is in a container.
   NeedsSplit     1 when the invoice has two rows or more (two containers, or a container and unlinked items):
                  only then is a payment split by hand; with one container and nothing else, the whole amount
                  is that container's. */
CREATE OR ALTER FUNCTION purchase.fn_InvoiceContainerSettlement (@DocumentId INT)
RETURNS TABLE
AS
RETURN
(
    WITH lines AS (
        SELECT ContainerKey = ISNULL(cl.ContainerId, 0), l.ItemId,
               Amount = l.LineTotal - ISNULL(r.Returned, 0)
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
        LEFT  JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
        -- What posted returns took back from this line, in the invoice's currency.
        OUTER APPLY (SELECT Returned = SUM(v.Amount)
                     FROM (SELECT Amount = CASE WHEN x.CurrencyId = d.CurrencyId THEN rl.LineTotal
                                                ELSE ROUND(rl.LineTotal / NULLIF(x.ExchangeRate, 0) * d.ExchangeRate, 2) END
                           FROM purchase.PurchaseDocumentLines rl
                           INNER JOIN purchase.PurchaseDocuments x ON x.Id = rl.DocumentId AND x.Status = 2
                           INNER JOIN inventory.DocumentTypes xt ON xt.Id = x.DocumentTypeId AND xt.Code = N'PRET'
                           WHERE rl.SourceLineId = l.Id) v) r
        WHERE l.DocumentId = @DocumentId
    ),
    paid AS (
        SELECT ContainerKey = pac.ContainerKey, PaidAmount = SUM(pac.AmountDocCurrency)
        FROM purchase.PaymentAllocationContainers pac
        INNER JOIN purchase.PaymentAllocations a ON a.Id = pac.PaymentAllocationId AND a.RemovedAtUtc IS NULL
        INNER JOIN purchase.Payments p ON p.Id = a.PaymentId AND p.Status = 2
        WHERE a.PurchaseDocumentId = @DocumentId
        GROUP BY pac.ContainerKey
    ),
    -- A row whose amount came to nothing (all returned) and was never paid is not shown.
    groups AS (
        SELECT ContainerKey, ContainerAmount = CONVERT(DECIMAL(18,2), SUM(Amount))
        FROM lines GROUP BY ContainerKey
        HAVING ABS(SUM(Amount)) > 0.005 OR ContainerKey IN (SELECT ContainerKey FROM paid)
    )
    SELECT DocumentId = @DocumentId,
           g.ContainerKey,
           ContainerId = NULLIF(g.ContainerKey, 0),
           ContainerRef = CASE WHEN g.ContainerKey = 0 THEN N'Unlinked items' ELSE k.ContainerRef END,
           k.ContainerNo,
           Items = (SELECT STRING_AGG(i.ItemCode, N', ') WITHIN GROUP (ORDER BY i.ItemCode)
                    FROM (SELECT DISTINCT ItemId FROM lines WHERE ContainerKey = g.ContainerKey) li
                    INNER JOIN inventory.Items i ON i.Id = li.ItemId),
           g.ContainerAmount,
           PaidAmount = CONVERT(DECIMAL(18,2), ISNULL(p.PaidAmount, 0)),
           OutstandingAmount = CONVERT(DECIMAL(18,2), g.ContainerAmount - ISNULL(p.PaidAmount, 0)),
           PaymentStatus = CASE WHEN g.ContainerAmount - ISNULL(p.PaidAmount, 0) <= 0.005 THEN N'Fully Paid'
                                WHEN ISNULL(p.PaidAmount, 0) <= 0 THEN N'Pending'
                                ELSE N'Partially Paid' END,
           HasContainers = CAST(CASE WHEN EXISTS (SELECT 1 FROM groups WHERE ContainerKey <> 0) THEN 1 ELSE 0 END AS BIT),
           NeedsSplit = CAST(CASE WHEN EXISTS (SELECT 1 FROM groups WHERE ContainerKey <> 0)
                                   AND (SELECT COUNT(*) FROM groups) > 1 THEN 1 ELSE 0 END AS BIT)
    FROM groups g
    LEFT JOIN logistics.Containers k ON k.Id = g.ContainerKey
    LEFT JOIN paid p ON p.ContainerKey = g.ContainerKey
);
GO

/* ================================================================== 3. The split rules, in one place */

/* THE CONTAINER SPLIT OF THE INVOICE ALLOCATIONS, judged in one place for Save, Post and Allocate. THROWs
   the first problem, naming the invoice and the container.
     - an invoice with containers: its amount is split over its containers (and "Unlinked items" when some
       of its lines are in no container); @RequireBalanced = 1 (post, allocate) demands the split, and that
       it adds up to the invoice amount;
     - an invoice without containers is allocated as before: no split;
     - a container amount is never negative, never above what that container still owes. */
CREATE OR ALTER PROCEDURE purchase.usp_Payment_CheckContainerSplit
    @Allocations     purchase.tvp_PaymentAllocation READONLY,
    @Containers      purchase.tvp_PaymentAllocationContainer READONLY,
    @RequireBalanced BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Msg NVARCHAR(400);

    SELECT TOP (1) @Msg = N'Purchase invoice ' + ISNULL(d.DocumentNumber, N'#' + CAST(c.DocumentId AS NVARCHAR(10))) + N': '
                          + CASE WHEN a.DocumentId IS NULL THEN N'a container amount was given, but the invoice is not allocated.'
                                 WHEN c.Amount < 0 THEN N'a container amount cannot be negative.'
                                 WHEN s.ContainerKey IS NULL AND c.ContainerId = 0 THEN N'every line of this invoice is in a container: there are no unlinked items.'
                                 WHEN s.ContainerKey IS NULL THEN N'container #' + CAST(c.ContainerId AS NVARCHAR(10)) + N' is not one of its containers.'
                                 ELSE N'it has no containers: allocate it directly, without a container split.' END
    FROM @Containers c
    LEFT JOIN @Allocations a ON a.DocumentKind = N'PINV' AND a.DocumentId = c.DocumentId
    LEFT JOIN purchase.PurchaseDocuments d ON d.Id = c.DocumentId
    OUTER APPLY (SELECT TOP (1) HasContainers FROM purchase.fn_InvoiceContainerSettlement(c.DocumentId)) h
    OUTER APPLY (SELECT ContainerKey FROM purchase.fn_InvoiceContainerSettlement(c.DocumentId) WHERE ContainerKey = c.ContainerId) s
    WHERE a.DocumentId IS NULL OR c.Amount < 0 OR s.ContainerKey IS NULL OR ISNULL(h.HasContainers, 0) = 0
    ORDER BY c.DocumentId, c.ContainerId;
    IF @Msg IS NOT NULL THROW 73000, @Msg, 1;

    SELECT TOP (1) @Msg = N'Purchase invoice ' + d.DocumentNumber + N', ' + s.ContainerRef + N': '
                          + FORMAT(c.Amount, N'N2', N'en-US') + N' is more than its outstanding '
                          + FORMAT(s.OutstandingAmount, N'N2', N'en-US') + N' ' + cu.CurrencyCode + N'.'
    FROM @Containers c
    INNER JOIN purchase.PurchaseDocuments d ON d.Id = c.DocumentId
    INNER JOIN masterdata.Currencies cu ON cu.Id = d.CurrencyId
    CROSS APPLY (SELECT ContainerRef, OutstandingAmount FROM purchase.fn_InvoiceContainerSettlement(c.DocumentId) WHERE ContainerKey = c.ContainerId) s
    WHERE c.Amount > s.OutstandingAmount + 0.005
    ORDER BY c.DocumentId, c.ContainerId;
    IF @Msg IS NOT NULL THROW 73009, @Msg, 1;

    IF @RequireBalanced = 1
    BEGIN
        SELECT TOP (1) @Msg = N'Purchase invoice ' + d.DocumentNumber + N': the container amounts ('
                              + FORMAT(ISNULL(t.Total, 0), N'N2', N'en-US') + N') must add up to the invoice amount ('
                              + FORMAT(a.Amount, N'N2', N'en-US') + N' ' + cu.CurrencyCode + N'). Split the amount over its containers.'
        FROM @Allocations a
        INNER JOIN purchase.PurchaseDocuments d ON d.Id = a.DocumentId
        INNER JOIN masterdata.Currencies cu ON cu.Id = d.CurrencyId
        OUTER APPLY (SELECT Total = SUM(Amount) FROM @Containers WHERE DocumentId = a.DocumentId) t
        WHERE a.DocumentKind = N'PINV'
          AND EXISTS (SELECT 1 FROM purchase.fn_InvoiceContainerSettlement(a.DocumentId) WHERE HasContainers = 1)
          AND ABS(a.Amount - ISNULL(t.Total, 0)) > 0.005
        ORDER BY d.DocumentNumber;
        IF @Msg IS NOT NULL THROW 73008, @Msg, 1;
    END
END
GO

/* ================================================================== 4. Payments */

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

            -- Script 73: an invoice with containers is paid container by container, and the split adds up.
            IF @Type = 2
            BEGIN
                DECLARE @SplitA purchase.tvp_PaymentAllocation, @SplitC purchase.tvp_PaymentAllocationContainer;
                INSERT INTO @SplitA (DocumentKind, DocumentId, Amount, RateToPayment)
                SELECT N'PINV', PurchaseDocumentId, AmountDocCurrency, RateToPayment
                FROM purchase.PaymentAllocations WHERE PaymentId = @Id AND PurchaseDocumentId IS NOT NULL;
                INSERT INTO @SplitC (DocumentId, ContainerId, Amount)
                SELECT a.PurchaseDocumentId, pac.ContainerKey, pac.AmountDocCurrency
                FROM purchase.PaymentAllocationContainers pac
                INNER JOIN purchase.PaymentAllocations a ON a.Id = pac.PaymentAllocationId
                WHERE a.PaymentId = @Id;
                EXEC purchase.usp_Payment_CheckContainerSplit @SplitA, @SplitC, 1;
            END
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

CREATE OR ALTER PROCEDURE purchase.usp_Payment_Allocate
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

    /* Script 73: the container split of each invoice allocation - EVERY container of the invoice (and
       "Unlinked items"), with this payment's amount on it, so a draft can be edited. PreviouslyPaid leaves
       out this payment's own share once it is posted, like the allocation above. */
    SELECT AllocationId = al.Id, s.DocumentId, s.ContainerId, s.ContainerRef, s.ContainerNo, s.Items, s.ContainerAmount,
           PreviouslyPaid = s.PaidAmount - CASE WHEN p.Status = 2 AND al.RemovedAtUtc IS NULL THEN ISNULL(pac.AmountDocCurrency, 0) ELSE 0 END,
           s.OutstandingAmount, s.PaymentStatus,
           AllocatedAmount = ISNULL(pac.AmountDocCurrency, 0)
    FROM purchase.PaymentAllocations al
    INNER JOIN purchase.Payments p ON p.Id = al.PaymentId
    CROSS APPLY purchase.fn_InvoiceContainerSettlement(al.PurchaseDocumentId) s
    LEFT JOIN purchase.PaymentAllocationContainers pac ON pac.PaymentAllocationId = al.Id AND pac.ContainerKey = s.ContainerKey
    WHERE al.PaymentId = @Id AND al.PurchaseDocumentId IS NOT NULL AND s.HasContainers = 1
    ORDER BY al.Id, CASE WHEN s.ContainerKey = 0 THEN 1 ELSE 0 END, s.ContainerRef;
END
GO

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

    -- Script 73: the containers of each open invoice that has some, for the container split.
    SELECT s.DocumentId, s.ContainerId, s.ContainerRef, s.ContainerNo, s.Items, s.ContainerAmount,
           PreviouslyPaid = s.PaidAmount, s.OutstandingAmount, s.PaymentStatus, AllocatedAmount = CAST(0 AS DECIMAL(18,2))
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId AND t.Code = N'PINV'
    CROSS APPLY purchase.fn_InvoiceSettlement(d.Id) st
    CROSS APPLY purchase.fn_InvoiceContainerSettlement(d.Id) s
    WHERE @DocumentKind = N'PINV' AND d.SupplierId = @PayeeId AND d.Status = 2
      AND st.OutstandingAmount > 0.005 AND s.HasContainers = 1
    ORDER BY d.DocumentDate, d.Id, CASE WHEN s.ContainerKey = 0 THEN 1 ELSE 0 END, s.ContainerRef;
END
GO


PRINT 'Script 73 applied: a purchase invoice is paid container by container.';
GO
