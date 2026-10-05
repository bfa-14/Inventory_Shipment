SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ==================================================================================================
   46: Supplier payments - foundation (US-PAY-001, Phase 1)
   --------------------------------------------------------------------------------------------------
   Money going OUT to a supplier or a service provider: the mirror of the customer receipt (35-36).
   A payment has payment lines (method, currency, amount, rate to the payment currency, the cash or
   bank account it left from, cheque details), may be allocated to purchase invoices OR to container
   charges - never both - and can carry files.

   THIS SCRIPT BUILDS THE GROUND, NOT THE PAYMENT. It creates:
     - purchase.Payments, PaymentLines, PaymentAllocations, PaymentFiles, PaymentAudit - empty and
       constrained;
     - the document type PAY (PAY-2026-0001), numbered at the first save like a receipt;
     - purchase.fn_InvoiceSettlement and logistics.fn_ContainerChargeSettlement: what a purchase
       invoice / container charge has been paid and still owes;
     - attachment types for payments (AppliesTo = Payment), and type names unique PER LIST;
     - the payment permissions.
   Save / post / reverse / allocate arrive in Phase 2.

   THE CONTROL CURRENCY IS THE PAYMENT'S OWN (the header currency):
     header      Amount in the payment currency, ExchangeRate = units of it per 1 base currency
                 (1 USD = 2,800 CDF stores 2800, as everywhere), AmountBase = Amount / ExchangeRate.
     line        Amount in the line currency x RateToPayment = AmountPaymentCurrency. RateToPayment is
                 the MULTIPLIER the page shows ("Exchange Rate to Payment Currency"), frozen at posting.
     allocation  AmountDocCurrency in the INVOICE's / CHARGE's currency x RateToPayment =
                 AmountPaymentCurrency; its base value is AmountDocCurrency / the document's own stored
                 rate, so settling a document in full lands exactly on its base total.
   Balancing is done in the payment currency: header = SUM(lines) (= SUM(allocations) when allocated).

   PAID AND OUTSTANDING ARE NOT STORED. A document's paid amount is the sum of its LIVE allocations on
   POSTED payments, so reversing a payment gives the balance back with nothing to repair; RemovedAtUtc
   lets an allocation of an unapplied advance be taken back without deleting the row that proves it.
   A purchase invoice's outstanding is its total LESS posted purchase returns made from it.

   Requires scripts up to 45 (35-36 for the payment methods and accounts). Idempotent.
   ================================================================================================== */

IF OBJECT_ID(N'masterdata.PaymentMethods', N'U') IS NULL
   OR OBJECT_ID(N'masterdata.CashBankAccounts', N'U') IS NULL
   OR OBJECT_ID(N'purchase.PurchaseDocuments', N'U') IS NULL
   OR OBJECT_ID(N'logistics.ContainerCharges', N'U') IS NULL
   OR COL_LENGTH(N'masterdata.AttachmentTypes', N'AppliesTo') IS NULL
BEGIN
    RAISERROR ('Run the earlier scripts (35-36 and the purchase / logistics scripts) before script 46.', 16, 1);
    SET NOEXEC ON;
END
GO

/* ================================================================== 1. The payment tables */

IF OBJECT_ID(N'purchase.Payments', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.Payments
    (
        Id             INT IDENTITY(1,1) NOT NULL,
        PaymentNumber  NVARCHAR(30)   NULL,                    -- PAY-2026-0001, assigned at the first save
        PaymentDate    DATE           NOT NULL,
        PayeeId        INT            NOT NULL,                -- masterdata.Parties (IsSupplier)
        BranchId       INT            NOT NULL,
        PaymentType    TINYINT        NOT NULL CONSTRAINT DF_Payments_PaymentType DEFAULT (1),   -- 1 Free Payment, 2 Purchase Invoice Payment, 3 Container Charge Payment
        CurrencyId     INT            NOT NULL,                -- the payment (control) currency
        Amount         DECIMAL(18,2)  NOT NULL,                -- in the payment currency
        ExchangeRate   DECIMAL(18,6)  NOT NULL CONSTRAINT DF_Payments_Rate DEFAULT (1),          -- units of the currency per 1 base
        AmountBase     AS (CONVERT(DECIMAL(18,2), Amount / ExchangeRate)) PERSISTED,
        Reference      NVARCHAR(100)  NULL,
        Notes          NVARCHAR(500)  NULL,
        Status         TINYINT        NOT NULL CONSTRAINT DF_Payments_Status DEFAULT (1),        -- 1 Draft, 2 Posted, 3 Reversed
        PostedAtUtc    DATETIME2(3)   NULL,
        PostedBy       INT            NULL,
        ReversedAtUtc  DATETIME2(3)   NULL,
        ReversedBy     INT            NULL,
        ReverseReason  NVARCHAR(500)  NULL,
        CreatedAtUtc   DATETIME2(3)   NOT NULL CONSTRAINT DF_Payments_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy      INT            NULL,
        UpdatedAtUtc   DATETIME2(3)   NULL,
        UpdatedBy      INT            NULL,
        RowVersion     ROWVERSION     NOT NULL,
        CONSTRAINT PK_Payments PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_Payments_PaymentType CHECK (PaymentType IN (1, 2, 3)),
        CONSTRAINT CK_Payments_Status      CHECK (Status IN (1, 2, 3)),
        CONSTRAINT CK_Payments_Amount      CHECK (Amount > 0),
        CONSTRAINT CK_Payments_Rate        CHECK (ExchangeRate > 0),
        CONSTRAINT CK_Payments_Posting     CHECK (Status = 1 OR (PostedAtUtc IS NOT NULL AND PostedBy IS NOT NULL)),
        CONSTRAINT CK_Payments_Reversal    CHECK (Status <> 3 OR (ReversedAtUtc IS NOT NULL AND ReversedBy IS NOT NULL)),
        CONSTRAINT FK_Payments_Payee       FOREIGN KEY (PayeeId)    REFERENCES masterdata.Parties (Id),
        CONSTRAINT FK_Payments_Branch      FOREIGN KEY (BranchId)   REFERENCES masterdata.Branches (Id),
        CONSTRAINT FK_Payments_Currency    FOREIGN KEY (CurrencyId) REFERENCES masterdata.Currencies (Id),
        CONSTRAINT FK_Payments_PostedBy    FOREIGN KEY (PostedBy)   REFERENCES security.Users (Id),
        CONSTRAINT FK_Payments_ReversedBy  FOREIGN KEY (ReversedBy) REFERENCES security.Users (Id),
        CONSTRAINT FK_Payments_CreatedBy   FOREIGN KEY (CreatedBy)  REFERENCES security.Users (Id),
        CONSTRAINT FK_Payments_UpdatedBy   FOREIGN KEY (UpdatedBy)  REFERENCES security.Users (Id)
    );
    CREATE UNIQUE NONCLUSTERED INDEX UX_Payments_Number ON purchase.Payments (PaymentNumber) WHERE PaymentNumber IS NOT NULL;
    CREATE NONCLUSTERED INDEX IX_Payments_Payee  ON purchase.Payments (PayeeId, PaymentDate DESC);
    CREATE NONCLUSTERED INDEX IX_Payments_Status ON purchase.Payments (Status, PaymentDate DESC);
    PRINT 'Created purchase.Payments';
END
GO

IF OBJECT_ID(N'purchase.PaymentLines', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.PaymentLines
    (
        Id                    INT IDENTITY(1,1) NOT NULL,
        PaymentId             INT            NOT NULL,
        LineNumber            INT            NOT NULL,
        PaymentMethodId       INT            NOT NULL,
        CurrencyId            INT            NOT NULL,             -- the currency actually paid on this line
        Amount                DECIMAL(18,2)  NOT NULL,             -- in the line currency
        RateToPayment         DECIMAL(24,12) NOT NULL CONSTRAINT DF_PaymentLines_Rate DEFAULT (1),   -- multiplier: line currency -> payment currency (12 places: 1 / 2800 CDF)
        AmountPaymentCurrency AS (CONVERT(DECIMAL(18,2), ROUND(Amount * RateToPayment, 2))) PERSISTED,
        AmountBase            DECIMAL(18,2)  NOT NULL CONSTRAINT DF_PaymentLines_AmountBase DEFAULT (0),   -- AmountPaymentCurrency / header rate, written by the save
        CashBankAccountId     INT            NOT NULL,             -- where the money left from; its currency must be the line's
        Reference             NVARCHAR(100)  NULL,                 -- transfer / reference number
        ChequeNo              NVARCHAR(50)   NULL,                 -- cheque lines only
        ChequeDate            DATE           NULL,
        ChequeDueDate         DATE           NULL,
        ClearanceStatus       TINYINT        NULL,                 -- cheque lines: 1 Pending, 2 Cleared, 3 Returned
        ClearanceUpdatedAtUtc DATETIME2(3)   NULL,
        ClearanceUpdatedBy    INT            NULL,
        CONSTRAINT PK_PaymentLines PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_PaymentLines_Number UNIQUE (PaymentId, LineNumber),
        CONSTRAINT CK_PaymentLines_Amount    CHECK (Amount > 0),
        CONSTRAINT CK_PaymentLines_Rate      CHECK (RateToPayment > 0),
        CONSTRAINT CK_PaymentLines_Clearance CHECK (ClearanceStatus IS NULL OR ClearanceStatus IN (1, 2, 3)),
        CONSTRAINT FK_PaymentLines_Payment   FOREIGN KEY (PaymentId)          REFERENCES purchase.Payments (Id),
        CONSTRAINT FK_PaymentLines_Method    FOREIGN KEY (PaymentMethodId)    REFERENCES masterdata.PaymentMethods (Id),
        CONSTRAINT FK_PaymentLines_Currency  FOREIGN KEY (CurrencyId)         REFERENCES masterdata.Currencies (Id),
        CONSTRAINT FK_PaymentLines_Account   FOREIGN KEY (CashBankAccountId)  REFERENCES masterdata.CashBankAccounts (Id),
        CONSTRAINT FK_PaymentLines_ClearedBy FOREIGN KEY (ClearanceUpdatedBy) REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_PaymentLines_Method  ON purchase.PaymentLines (PaymentMethodId);
    CREATE NONCLUSTERED INDEX IX_PaymentLines_Account ON purchase.PaymentLines (CashBankAccountId);
    PRINT 'Created purchase.PaymentLines';
END
GO

IF OBJECT_ID(N'purchase.PaymentAllocations', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.PaymentAllocations
    (
        Id                    INT IDENTITY(1,1) NOT NULL,
        PaymentId             INT            NOT NULL,
        DocumentKind          NVARCHAR(10)   NOT NULL,             -- PINV (purchase invoice) | CHARGE (container charge)
        PurchaseDocumentId    INT            NULL,                 -- PINV
        ContainerChargeId     INT            NULL,                 -- CHARGE
        AmountDocCurrency     DECIMAL(18,2)  NOT NULL,             -- entered in the DOCUMENT's currency
        DocExchangeRate       DECIMAL(18,6)  NOT NULL,             -- the document's own stored rate (per 1 base), snapshotted
        AmountBase            AS (CONVERT(DECIMAL(18,2), AmountDocCurrency / DocExchangeRate)) PERSISTED,
        RateToPayment         DECIMAL(24,12) NOT NULL CONSTRAINT DF_PaymentAllocations_Rate DEFAULT (1),   -- multiplier: document currency -> payment currency
        AmountPaymentCurrency AS (CONVERT(DECIMAL(18,2), ROUND(AmountDocCurrency * RateToPayment, 2))) PERSISTED,
        AllocatedAtUtc        DATETIME2(3)   NOT NULL CONSTRAINT DF_PaymentAllocations_At DEFAULT (SYSUTCDATETIME()),
        AllocatedBy           INT            NULL,
        RemovedAtUtc          DATETIME2(3)   NULL,                 -- a taken-back later allocation; the row stays as proof
        RemovedBy             INT            NULL,
        CONSTRAINT PK_PaymentAllocations PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_PaymentAllocations_Kind     CHECK ((DocumentKind = N'PINV'   AND PurchaseDocumentId IS NOT NULL AND ContainerChargeId IS NULL)
                                                      OR (DocumentKind = N'CHARGE' AND ContainerChargeId IS NOT NULL AND PurchaseDocumentId IS NULL)),
        CONSTRAINT CK_PaymentAllocations_Amount   CHECK (AmountDocCurrency > 0),
        CONSTRAINT CK_PaymentAllocations_DocRate  CHECK (DocExchangeRate > 0),
        CONSTRAINT CK_PaymentAllocations_PayRate  CHECK (RateToPayment > 0),
        CONSTRAINT CK_PaymentAllocations_Removed  CHECK ((RemovedAtUtc IS NULL AND RemovedBy IS NULL) OR (RemovedAtUtc IS NOT NULL AND RemovedBy IS NOT NULL)),
        CONSTRAINT FK_PaymentAllocations_Payment   FOREIGN KEY (PaymentId)          REFERENCES purchase.Payments (Id),
        CONSTRAINT FK_PaymentAllocations_Invoice   FOREIGN KEY (PurchaseDocumentId) REFERENCES purchase.PurchaseDocuments (Id),
        CONSTRAINT FK_PaymentAllocations_Charge    FOREIGN KEY (ContainerChargeId)  REFERENCES logistics.ContainerCharges (Id),
        CONSTRAINT FK_PaymentAllocations_By        FOREIGN KEY (AllocatedBy)        REFERENCES security.Users (Id),
        CONSTRAINT FK_PaymentAllocations_RemovedBy FOREIGN KEY (RemovedBy)          REFERENCES security.Users (Id)
    );
    -- THE INDEXES THE LISTS WILL LEAN ON: paid = SUM over a document's live allocations.
    CREATE NONCLUSTERED INDEX IX_PaymentAllocations_Invoice ON purchase.PaymentAllocations (PurchaseDocumentId)
        INCLUDE (PaymentId, AmountDocCurrency, RemovedAtUtc) WHERE PurchaseDocumentId IS NOT NULL;
    CREATE NONCLUSTERED INDEX IX_PaymentAllocations_Charge ON purchase.PaymentAllocations (ContainerChargeId)
        INCLUDE (PaymentId, AmountDocCurrency, RemovedAtUtc) WHERE ContainerChargeId IS NOT NULL;
    CREATE NONCLUSTERED INDEX IX_PaymentAllocations_Payment ON purchase.PaymentAllocations (PaymentId);
    PRINT 'Created purchase.PaymentAllocations';
END
GO

IF OBJECT_ID(N'purchase.PaymentFiles', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.PaymentFiles
    (
        Id               INT IDENTITY(1,1) NOT NULL,
        PaymentId        INT            NOT NULL,
        AttachmentTypeId INT            NULL,                     -- Type / Sub Type, from masterdata.AttachmentTypes (AppliesTo = Payment)
        Note             NVARCHAR(300)  NULL,
        FileName         NVARCHAR(255)  NOT NULL,
        ContentType      NVARCHAR(100)  NOT NULL,
        SizeBytes        INT            NOT NULL,
        Content          VARBINARY(MAX) NOT NULL,
        CreatedAtUtc     DATETIME2(3)   NOT NULL CONSTRAINT DF_PaymentFiles_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy        INT            NULL,
        CONSTRAINT PK_PaymentFiles PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_PaymentFiles_Size CHECK (SizeBytes > 0),
        CONSTRAINT FK_PaymentFiles_Payment   FOREIGN KEY (PaymentId)        REFERENCES purchase.Payments (Id),
        CONSTRAINT FK_PaymentFiles_Type      FOREIGN KEY (AttachmentTypeId) REFERENCES masterdata.AttachmentTypes (Id),
        CONSTRAINT FK_PaymentFiles_CreatedBy FOREIGN KEY (CreatedBy)        REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_PaymentFiles_Payment ON purchase.PaymentFiles (PaymentId);
    PRINT 'Created purchase.PaymentFiles';
END
GO

IF OBJECT_ID(N'purchase.PaymentAudit', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.PaymentAudit
    (
        Id        BIGINT IDENTITY(1,1) NOT NULL,
        PaymentId INT           NOT NULL,
        Action    NVARCHAR(20)  NOT NULL,   -- Created | Updated | Posted | Reversed | Allocated | Deallocated | ChequeStatus | FileAdded | FileDeleted
        Details   NVARCHAR(500) NULL,
        UserId    INT           NULL,
        AtUtc     DATETIME2(3)  NOT NULL CONSTRAINT DF_PaymentAudit_AtUtc DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_PaymentAudit PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_PaymentAudit_Payment FOREIGN KEY (PaymentId) REFERENCES purchase.Payments (Id),
        CONSTRAINT FK_PaymentAudit_User    FOREIGN KEY (UserId)    REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_PaymentAudit_Payment ON purchase.PaymentAudit (PaymentId, AtUtc DESC);
    PRINT 'Created purchase.PaymentAudit';
END
GO

/* ================================================================== 2. Document type PAY */

IF EXISTS (SELECT 1 FROM sys.check_constraints
           WHERE name = N'CK_DocumentTypes_Family'
             AND parent_object_id = OBJECT_ID(N'inventory.DocumentTypes')
             AND [definition] NOT LIKE N'%Payment%')
BEGIN
    DECLARE @Def NVARCHAR(MAX) = (SELECT [definition] FROM sys.check_constraints
                                  WHERE name = N'CK_DocumentTypes_Family' AND parent_object_id = OBJECT_ID(N'inventory.DocumentTypes'));
    -- Whatever families exist today, plus Payment: a later script may have added one this one does not know about.
    DECLARE @NewDef NVARCHAR(MAX) = N'(' + @Def + N' OR [Family]=N''Payment'')';
    IF @NewDef = @Def THROW 73000, 'Could not extend CK_DocumentTypes_Family with Payment.', 1;
    ALTER TABLE inventory.DocumentTypes DROP CONSTRAINT CK_DocumentTypes_Family;
    EXEC (N'ALTER TABLE inventory.DocumentTypes ADD CONSTRAINT CK_DocumentTypes_Family CHECK ' + @NewDef);
    PRINT 'DocumentTypes: family Payment allowed';
END
GO

MERGE inventory.DocumentTypes AS t
USING (VALUES (N'PAY', N'Supplier Payment', N'Payment', 0, N'PAY-', 0, 0)) AS s (Code, Name, Family, StockDirection, NumberPrefix, NumberOnPost, RequiresReason)
ON t.Code = s.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Family, StockDirection, NumberPrefix, NumberOnPost, RequiresReason)
    VALUES (s.Code, s.Name, s.Family, s.StockDirection, s.NumberPrefix, s.NumberOnPost, s.RequiresReason);
GO

/* Numbered at the FIRST SAVE (NumberOnPost = 0), with the year and four digits, shared across branches:
   PAY-2026-0001, as the mockup shows. The WHERE keeps a re-run from touching a configuration somebody
   has since changed on purpose. */
UPDATE inventory.DocumentTypes
SET DefaultPricing = N'None', PriceEditable = 0, NumberPerBranch = 0, YearInNumber = 1, NumberLength = 4
WHERE Code = N'PAY' AND NextNumber = 1 AND UpdatedAtUtc IS NULL;
GO

/* ================================================================== 3. What a document has been paid */

/* ONE DEFINITION OF "PAID" for a purchase invoice. Inline, so the optimizer folds it into the calling
   query. Only a POSTED purchase invoice has a payment status.
     Returned     posted purchase returns made from it, in the invoice's currency
     Paid         live allocations on POSTED payments, in the invoice's currency
     Outstanding  Total - Returned - Paid                                                           */
CREATE OR ALTER FUNCTION purchase.fn_InvoiceSettlement (@DocumentId INT)
RETURNS TABLE
AS
RETURN
(
    SELECT r.ReturnedAmount, p.PaidAmount,
           OutstandingAmount = CASE WHEN d.Status = 2 AND d.DocumentTypeId = t.Id THEN d.TotalAmount - r.ReturnedAmount - p.PaidAmount END,
           PaymentStatus     = CASE WHEN d.Status <> 2 OR d.DocumentTypeId <> t.Id THEN NULL
                                    WHEN d.TotalAmount - r.ReturnedAmount - p.PaidAmount <= 0.005 THEN N'Paid'
                                    WHEN p.PaidAmount <= 0 THEN N'Unpaid'
                                    ELSE N'Partial' END
    FROM purchase.PurchaseDocuments d
    CROSS APPLY (SELECT Id FROM inventory.DocumentTypes WHERE Code = N'PINV') t
    CROSS APPLY (SELECT ReturnedAmount = CONVERT(DECIMAL(18,2), ISNULL((SELECT SUM(q.Amount)
                                                 FROM (SELECT Amount = CASE WHEN x.CurrencyId = d.CurrencyId THEN x.TotalAmount
                                                                            ELSE ROUND(x.TotalAmountBase * d.ExchangeRate, 2) END
                                                       FROM purchase.PurchaseDocuments x
                                                       INNER JOIN inventory.DocumentTypes xt ON xt.Id = x.DocumentTypeId AND xt.Code = N'PRET'
                                                       WHERE x.SourceDocumentId = d.Id AND x.Status = 2) q), 0))) r
    CROSS APPLY (SELECT PaidAmount = ISNULL((SELECT SUM(a.AmountDocCurrency)
                                             FROM purchase.PaymentAllocations a
                                             INNER JOIN purchase.Payments pay ON pay.Id = a.PaymentId
                                             WHERE a.PurchaseDocumentId = d.Id AND a.RemovedAtUtc IS NULL AND pay.Status = 2), 0)) p
    WHERE d.Id = @DocumentId
);
GO

/* The same for a container charge: only a POSTED charge owes anything. */
CREATE OR ALTER FUNCTION logistics.fn_ContainerChargeSettlement (@ChargeId INT)
RETURNS TABLE
AS
RETURN
(
    SELECT p.PaidAmount,
           OutstandingAmount = CASE WHEN c.Status = 2 THEN c.Amount - p.PaidAmount END,
           PaymentStatus     = CASE WHEN c.Status <> 2 THEN NULL
                                    WHEN c.Amount - p.PaidAmount <= 0.005 THEN N'Paid'
                                    WHEN p.PaidAmount <= 0 THEN N'Unpaid'
                                    ELSE N'Partial' END
    FROM logistics.ContainerCharges c
    CROSS APPLY (SELECT PaidAmount = ISNULL((SELECT SUM(a.AmountDocCurrency)
                                             FROM purchase.PaymentAllocations a
                                             INNER JOIN purchase.Payments pay ON pay.Id = a.PaymentId
                                             WHERE a.ContainerChargeId = c.Id AND a.RemovedAtUtc IS NULL AND pay.Status = 2), 0)) p
    WHERE c.Id = @ChargeId
);
GO

/* ================================================================== 4. Attachment types for payments */

-- Payment joins the lists a type can belong to.
IF EXISTS (SELECT 1 FROM sys.check_constraints
           WHERE name = N'CK_AttachmentTypes_AppliesTo' AND parent_object_id = OBJECT_ID(N'masterdata.AttachmentTypes')
             AND [definition] NOT LIKE N'%Payment%')
BEGIN
    ALTER TABLE masterdata.AttachmentTypes DROP CONSTRAINT CK_AttachmentTypes_AppliesTo;
    ALTER TABLE masterdata.AttachmentTypes ADD CONSTRAINT CK_AttachmentTypes_AppliesTo CHECK (AppliesTo IN (N'Logistics', N'Receipt', N'Payment'));
    PRINT 'AttachmentTypes: AppliesTo Payment allowed';
END
GO

-- A type name is unique within ITS list: receipts and payments may both have "Cheque / Cheque Copy".
IF EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = N'UQ_AttachmentTypes_Name' AND parent_object_id = OBJECT_ID(N'masterdata.AttachmentTypes'))
   AND NOT EXISTS (SELECT 1 FROM sys.index_columns ic
                   INNER JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                   INNER JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                   WHERE i.name = N'UQ_AttachmentTypes_Name' AND i.object_id = OBJECT_ID(N'masterdata.AttachmentTypes') AND c.name = N'AppliesTo')
BEGIN
    ALTER TABLE masterdata.AttachmentTypes DROP CONSTRAINT UQ_AttachmentTypes_Name;
    ALTER TABLE masterdata.AttachmentTypes ADD CONSTRAINT UQ_AttachmentTypes_Name UNIQUE (Category, SubType, AppliesTo);
    PRINT 'AttachmentTypes: names unique per list';
END
GO

/* The spec's Type / Sub Type pairs. Matched on the pair WITHIN the Payment list, so a re-run changes
   nothing and a renamed row is left alone. */
MERGE masterdata.AttachmentTypes AS t
USING (VALUES
    (N'Bank Transfer', N'SWIFT Copy',      10),
    (N'Cheque',        N'Cheque Copy',     20),
    (N'Cash',          N'Payment Voucher', 30),
    (N'Other',         N'Supplier Advice', 40),
    (N'Bank',          N'Bank Statement',  50),
    (N'Other',         N'Other',           60)
) AS s (Category, SubType, SortOrder)
ON t.Category = s.Category AND t.SubType = s.SubType AND t.AppliesTo = N'Payment'
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Category, SubType, SortOrder, AppliesTo) VALUES (s.Category, s.SubType, s.SortOrder, N'Payment');
GO

/* ================================================================== 5. The shared lists learn about payments */

CREATE OR ALTER PROCEDURE masterdata.usp_AttachmentType_Save
    @Id         INT          = NULL,
    @Category   NVARCHAR(30),
    @SubType    NVARCHAR(60),
    @SortOrder  INT          = 0,
    @IsActive   BIT          = 1,
    @RowVersion BINARY(8)    = NULL,
    @UserId     INT          = NULL,
    @NewId      INT OUTPUT,
    /* NULL = leave it alone on an update, and Logistics on an insert: every caller that predates the
       column keeps doing exactly what it did. */
    @AppliesTo  NVARCHAR(12) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Category = NULLIF(LTRIM(RTRIM(@Category)), N'');
    SET @SubType = NULLIF(LTRIM(RTRIM(@SubType)), N'');
    SET @AppliesTo = NULLIF(LTRIM(RTRIM(@AppliesTo)), N'');
    IF @Category IS NULL THROW 69000, 'Category is required.', 1;
    IF @SubType IS NULL THROW 69000, 'Sub type is required.', 1;
    IF @AppliesTo IS NOT NULL AND @AppliesTo NOT IN (N'Logistics', N'Receipt', N'Payment') THROW 69000, 'Applies to must be Logistics, Receipt or Payment.', 1;
    /* Unique PER LIST: a receipt and a payment may both have a "Cheque / Cheque Copy". The list a row
       belongs to is the one it is being saved into, or the one it already has when that is not said. */
    DECLARE @List NVARCHAR(12) = COALESCE(@AppliesTo, (SELECT AppliesTo FROM masterdata.AttachmentTypes WHERE Id = @Id), N'Logistics');
    IF EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Category = @Category AND SubType = @SubType AND AppliesTo = @List AND (@Id IS NULL OR Id <> @Id))
        THROW 69013, 'This category and sub type already exist.', 1;

    IF @Id IS NULL
    BEGIN
        INSERT INTO masterdata.AttachmentTypes (Category, SubType, SortOrder, IsActive, AppliesTo, CreatedBy)
        VALUES (@Category, @SubType, ISNULL(@SortOrder, 0), ISNULL(@IsActive, 1), ISNULL(@AppliesTo, N'Logistics'), @UserId);
        SET @NewId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Id = @Id) THROW 69006, 'Attachment type not found.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 69004, 'This attachment type was modified by another user. Reload the page and try again.', 1;
        UPDATE masterdata.AttachmentTypes
        SET Category = @Category, SubType = @SubType, SortOrder = ISNULL(@SortOrder, 0), IsActive = ISNULL(@IsActive, 1),
            AppliesTo = ISNULL(@AppliesTo, AppliesTo),
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;
        SET @NewId = @Id;
    END
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_AttachmentType_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Id = @Id) THROW 69006, 'Attachment type not found.', 1;
    IF EXISTS (SELECT 1 FROM logistics.ContainerAttachments WHERE AttachmentTypeId = @Id)
       OR EXISTS (SELECT 1 FROM sales.ReceiptFiles WHERE AttachmentTypeId = @Id)
       OR EXISTS (SELECT 1 FROM purchase.PaymentFiles WHERE AttachmentTypeId = @Id)
        THROW 69014, 'This attachment type is used by documents and cannot be deleted. Deactivate it instead.', 1;
    DELETE FROM masterdata.AttachmentTypes WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_PaymentMethod_Search
    @Search        NVARCHAR(100) = NULL,
    @IsActive      BIT           = NULL,
    @SortColumn    NVARCHAR(30)  = N'MethodCode',   -- MethodCode | MethodName | IsActive
    @SortDirection NVARCHAR(4)   = N'ASC',
    @PageNumber    INT           = 1,
    @PageSize      INT           = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'MethodCode', N'MethodName', N'IsActive') SET @SortColumn = N'MethodCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT m.Id, m.MethodCode, m.MethodName, m.Description, m.IsActive,
           UsedCount = (SELECT COUNT(*) FROM sales.ReceiptLines x WHERE x.PaymentMethodId = m.Id)
                     + (SELECT COUNT(*) FROM purchase.PaymentLines y WHERE y.PaymentMethodId = m.Id),
           m.CreatedAtUtc, m.CreatedBy, m.UpdatedAtUtc, m.UpdatedBy, m.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.PaymentMethods m
    WHERE (@Search IS NULL OR m.MethodCode LIKE N'%' + @Search + N'%' OR m.MethodName LIKE N'%' + @Search + N'%')
      AND (@IsActive IS NULL OR m.IsActive = @IsActive)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'MethodCode' THEN m.MethodCode WHEN N'MethodName' THEN m.MethodName END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'MethodCode' THEN m.MethodCode WHEN N'MethodName' THEN m.MethodName END END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(m.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(m.IsActive AS INT) END DESC,
        m.MethodCode ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_PaymentMethod_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.PaymentMethods WHERE Id = @Id) THROW 71006, 'Payment method not found.', 1;
    IF EXISTS (SELECT 1 FROM sales.ReceiptLines WHERE PaymentMethodId = @Id)
       OR EXISTS (SELECT 1 FROM purchase.PaymentLines WHERE PaymentMethodId = @Id)
        THROW 71014, 'This payment method is used by receipts or supplier payments and cannot be deleted. Deactivate it instead.', 1;
    DELETE FROM masterdata.PaymentMethods WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_CashBankAccount_Search
    @Search        NVARCHAR(100) = NULL,
    @AccountType   NVARCHAR(10)  = NULL,
    @CurrencyId    INT           = NULL,
    @IsActive      BIT           = NULL,
    @SortColumn    NVARCHAR(30)  = N'AccountCode',   -- AccountCode | AccountName | AccountType | CurrencyCode | IsActive
    @SortDirection NVARCHAR(4)   = N'ASC',
    @PageNumber    INT           = 1,
    @PageSize      INT           = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @AccountType = NULLIF(LTRIM(RTRIM(@AccountType)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'AccountCode', N'AccountName', N'AccountType', N'CurrencyCode', N'IsActive') SET @SortColumn = N'AccountCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT a.Id, a.AccountCode, a.AccountName, a.AccountType, a.CurrencyId, c.CurrencyCode,
           a.BranchId, BranchName = b.BranchName, a.Description, a.IsActive,
           UsedCount = (SELECT COUNT(*) FROM sales.ReceiptLines x WHERE x.CashBankAccountId = a.Id)
                     + (SELECT COUNT(*) FROM purchase.PaymentLines y WHERE y.CashBankAccountId = a.Id),
           a.CreatedAtUtc, a.CreatedBy, a.UpdatedAtUtc, a.UpdatedBy, a.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.CashBankAccounts a
    INNER JOIN masterdata.Currencies c ON c.Id = a.CurrencyId
    LEFT JOIN masterdata.Branches b ON b.Id = a.BranchId
    WHERE (@Search IS NULL OR a.AccountCode LIKE N'%' + @Search + N'%' OR a.AccountName LIKE N'%' + @Search + N'%')
      AND (@AccountType IS NULL OR a.AccountType = @AccountType)
      AND (@CurrencyId IS NULL OR a.CurrencyId = @CurrencyId)
      AND (@IsActive IS NULL OR a.IsActive = @IsActive)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'AccountCode' THEN a.AccountCode WHEN N'AccountName' THEN a.AccountName
                                                                 WHEN N'AccountType' THEN a.AccountType WHEN N'CurrencyCode' THEN c.CurrencyCode END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'AccountCode' THEN a.AccountCode WHEN N'AccountName' THEN a.AccountName
                                                                 WHEN N'AccountType' THEN a.AccountType WHEN N'CurrencyCode' THEN c.CurrencyCode END END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(a.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(a.IsActive AS INT) END DESC,
        a.AccountCode ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_CashBankAccount_Save
    @Id          INT           = NULL,
    @AccountCode NVARCHAR(20),
    @AccountName NVARCHAR(100),
    @AccountType NVARCHAR(10),
    @CurrencyId  INT,
    @BranchId    INT           = NULL,
    @Description NVARCHAR(500) = NULL,
    @IsActive    BIT           = 1,
    @RowVersion  BINARY(8)     = NULL,
    @UserId      INT           = NULL,
    @NewId       INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @AccountCode = UPPER(NULLIF(LTRIM(RTRIM(@AccountCode)), N''));
    SET @AccountName = NULLIF(LTRIM(RTRIM(@AccountName)), N'');
    SET @AccountType = NULLIF(LTRIM(RTRIM(@AccountType)), N'');
    SET @Description = NULLIF(LTRIM(RTRIM(@Description)), N'');
    IF @AccountCode IS NULL THROW 71000, 'Account code is required.', 1;
    IF @AccountName IS NULL THROW 71000, 'Account name is required.', 1;
    IF @AccountType IS NULL OR @AccountType NOT IN (N'Cash', N'Bank') THROW 71000, 'Account type must be Cash or Bank.', 1;
    IF @CurrencyId IS NULL OR NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsActive = 1)
        THROW 71000, 'Currency not found or inactive.', 1;
    IF @BranchId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 71000, 'Branch not found or inactive.', 1;
    IF EXISTS (SELECT 1 FROM masterdata.CashBankAccounts WHERE AccountCode = @AccountCode AND (@Id IS NULL OR Id <> @Id))
        THROW 71013, 'This account code already exists.', 1;

    IF @Id IS NULL
    BEGIN
        INSERT INTO masterdata.CashBankAccounts (AccountCode, AccountName, AccountType, CurrencyId, BranchId, Description, IsActive, CreatedBy)
        VALUES (@AccountCode, @AccountName, @AccountType, @CurrencyId, @BranchId, @Description, ISNULL(@IsActive, 1), @UserId);
        SET @NewId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM masterdata.CashBankAccounts WHERE Id = @Id) THROW 71006, 'Cash / bank account not found.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.CashBankAccounts WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 71004, 'This account was modified by another user. Reload the page and try again.', 1;

        /* A used account keeps its currency. Receipt lines were checked against it when they were
           saved, and changing it afterwards would leave posted money sitting in the wrong one. */
        IF EXISTS (SELECT 1 FROM masterdata.CashBankAccounts WHERE Id = @Id AND CurrencyId <> @CurrencyId)
           AND (EXISTS (SELECT 1 FROM sales.ReceiptLines WHERE CashBankAccountId = @Id)
                OR EXISTS (SELECT 1 FROM purchase.PaymentLines WHERE CashBankAccountId = @Id))
            THROW 71000, 'The currency of an account that receipts or supplier payments already use cannot be changed.', 1;

        UPDATE masterdata.CashBankAccounts
        SET AccountCode = @AccountCode, AccountName = @AccountName, AccountType = @AccountType, CurrencyId = @CurrencyId,
            BranchId = @BranchId, Description = @Description, IsActive = ISNULL(@IsActive, 1),
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;
        SET @NewId = @Id;
    END
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_CashBankAccount_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.CashBankAccounts WHERE Id = @Id) THROW 71006, 'Cash / bank account not found.', 1;
    IF EXISTS (SELECT 1 FROM sales.ReceiptLines WHERE CashBankAccountId = @Id)
       OR EXISTS (SELECT 1 FROM purchase.PaymentLines WHERE CashBankAccountId = @Id)
        THROW 71014, 'This account is used by receipts or supplier payments and cannot be deleted. Deactivate it instead.', 1;
    DELETE FROM masterdata.CashBankAccounts WHERE Id = @Id;
END
GO

/* ================================================================== 6. Permissions */

MERGE security.Permissions AS target
USING
(
    VALUES
        (N'purchase.payments.view',     N'View Supplier Payments',     N'Purchase', N'See supplier payments and the invoices or charges they paid.',                            1230),
        (N'purchase.payments.create',   N'Create Supplier Payments',   N'Purchase', N'Create and edit draft supplier payments, and attach files to them.',                      1240),
        (N'purchase.payments.post',     N'Post Supplier Payments',     N'Purchase', N'Post a supplier payment: it starts paying the invoices or charges it is allocated to.',   1250),
        (N'purchase.payments.reverse',  N'Reverse Supplier Payments',  N'Purchase', N'Reverse a posted supplier payment; what it paid is owed again.',                           1260),
        (N'purchase.payments.delete',   N'Delete Supplier Payments',   N'Purchase', N'Delete draft supplier payments.',                                                         1270),
        (N'purchase.payments.allocate', N'Allocate Supplier Payments', N'Purchase', N'Apply the unapplied advance of a posted payment to invoices or charges, or take it back.', 1280)
) AS source (Code, Name, Module, Description, SortOrder)
ON target.Code = source.Code
WHEN MATCHED THEN
    UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Module, Description, SortOrder)
    VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder);
GO

-- System roles get everything; a Manager everything but reversing and deleting, as for receipts.
INSERT INTO security.RolePermissions (RoleId, PermissionId)
SELECT r.Id, p.Id
FROM security.Roles r
CROSS JOIN security.Permissions p
WHERE p.Code LIKE N'purchase.payments.%'
  AND (r.IsSystem = 1
       OR (r.Name = N'Manager' AND p.Code IN (N'purchase.payments.view', N'purchase.payments.create', N'purchase.payments.post', N'purchase.payments.allocate')))
  AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);
GO

/* ================================================================== 7. Check */

SELECT Code, Name, Family, NumberPrefix FROM inventory.DocumentTypes WHERE Code = N'PAY';
SELECT Category, SubType, AppliesTo FROM masterdata.AttachmentTypes WHERE AppliesTo = N'Payment' ORDER BY SortOrder;
SELECT Code, Name FROM security.Permissions WHERE Code LIKE N'purchase.payments.%' ORDER BY SortOrder;
PRINT 'Script 46 applied: supplier payments foundation.';
GO

SET NOEXEC OFF;
GO
