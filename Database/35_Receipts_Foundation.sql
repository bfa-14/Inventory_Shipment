/* ==================================================================================================
   35: Customer receipts - foundation (Phase 1)
   --------------------------------------------------------------------------------------------------
   Money coming IN from a customer. A receipt has payment lines (method, currency, amount, rate and
   the cash or bank account it landed in), may be allocated to sales invoices, and can carry files.

   THIS SCRIPT BUILDS THE GROUND, NOT THE RECEIPT. It creates:
     - the two lists a receipt line picks from: masterdata.PaymentMethods and
       masterdata.CashBankAccounts (with Search / Get / Lookup / Save / SetActive / Delete);
     - the receipt tables themselves, empty and constrained: sales.Receipts, ReceiptLines,
       ReceiptAllocations, ReceiptFiles, ReceiptAudit;
     - the document type RCPT (RCP-2026-0001), numbered at first save like a container;
     - the permissions that manage the two lists.
   Receipt save / post / reverse arrive in Phase 2, with their own permissions.

   RATES FOLLOW THE INVOICE: ExchangeRate is "units of the currency per 1 base currency" (1 USD =
   2,800 CDF stores 2800), and AmountBase = Amount / ExchangeRate. The base currency is read from
   masterdata.Currencies.IsBaseCurrency, never assumed to be USD.

   PAID AND OUTSTANDING ARE NOT STORED. An invoice's paid amount is the sum of its live allocations
   on POSTED receipts, so reversing a receipt gives the balance back with nothing to repair.
   ReceiptAllocations therefore carries RemovedAtUtc: a later allocation of unapplied credit can be
   taken back without deleting the row that proves it happened.

   Errors 71xxx: 71000 validation, 71004 concurrency, 71006 not found, 71013 duplicate code,
                 71014 master data in use.
   Permissions (module Master Data): masterdata.paymentmethods.manage 1480 /
                 masterdata.cashbankaccounts.manage 1490.

   Requires scripts up to 34. Idempotent.
   ================================================================================================== */
GO

IF OBJECT_ID(N'sales.SalesDocuments', N'U') IS NULL
   OR OBJECT_ID(N'masterdata.Parties', N'U') IS NULL
   OR OBJECT_ID(N'masterdata.AttachmentTypes', N'U') IS NULL
BEGIN
    RAISERROR ('Run the earlier scripts before script 35.', 16, 1);
    RETURN;
END
GO

/* ================================================================== 1. Payment methods */

IF OBJECT_ID(N'masterdata.PaymentMethods', N'U') IS NULL
BEGIN
    CREATE TABLE masterdata.PaymentMethods
    (
        Id           INT IDENTITY(1,1) NOT NULL,
        MethodCode   NVARCHAR(10)   NOT NULL,
        MethodName   NVARCHAR(100)  NOT NULL,
        Description  NVARCHAR(500)  NULL,
        IsActive     BIT            NOT NULL CONSTRAINT DF_PaymentMethods_IsActive DEFAULT (1),
        CreatedAtUtc DATETIME2(3)   NOT NULL CONSTRAINT DF_PaymentMethods_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy    INT            NULL,
        UpdatedAtUtc DATETIME2(3)   NULL,
        UpdatedBy    INT            NULL,
        RowVersion   ROWVERSION     NOT NULL,
        CONSTRAINT PK_PaymentMethods PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_PaymentMethods_Code UNIQUE (MethodCode),
        CONSTRAINT CK_PaymentMethods_Code_NotBlank CHECK (LEN(LTRIM(RTRIM(MethodCode))) > 0),
        CONSTRAINT CK_PaymentMethods_Name_NotBlank CHECK (LEN(LTRIM(RTRIM(MethodName))) > 0),
        CONSTRAINT FK_PaymentMethods_CreatedBy FOREIGN KEY (CreatedBy) REFERENCES security.Users (Id),
        CONSTRAINT FK_PaymentMethods_UpdatedBy FOREIGN KEY (UpdatedBy) REFERENCES security.Users (Id)
    );
    PRINT 'Created masterdata.PaymentMethods';
END
GO

/* The methods nearly every business starts with. Nothing here is special to the code: they are rows
   like any other, and can be renamed, deactivated or joined by others. */
MERGE masterdata.PaymentMethods AS t
USING (VALUES (N'CASH', N'Cash'), (N'BANK', N'Bank Transfer'), (N'CHQ', N'Cheque')) AS s (MethodCode, MethodName)
ON t.MethodCode = s.MethodCode
WHEN NOT MATCHED BY TARGET THEN INSERT (MethodCode, MethodName) VALUES (s.MethodCode, s.MethodName);
GO

/* ================================================================== 2. Cash and bank accounts */

IF OBJECT_ID(N'masterdata.CashBankAccounts', N'U') IS NULL
BEGIN
    CREATE TABLE masterdata.CashBankAccounts
    (
        Id           INT IDENTITY(1,1) NOT NULL,
        AccountCode  NVARCHAR(20)   NOT NULL,
        AccountName  NVARCHAR(100)  NOT NULL,
        AccountType  NVARCHAR(10)   NOT NULL,                  -- Cash | Bank
        CurrencyId   INT            NOT NULL,                  -- an account holds ONE currency
        BranchId     INT            NULL,                      -- NULL = usable from every branch
        Description  NVARCHAR(500)  NULL,
        IsActive     BIT            NOT NULL CONSTRAINT DF_CashBankAccounts_IsActive DEFAULT (1),
        CreatedAtUtc DATETIME2(3)   NOT NULL CONSTRAINT DF_CashBankAccounts_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy    INT            NULL,
        UpdatedAtUtc DATETIME2(3)   NULL,
        UpdatedBy    INT            NULL,
        RowVersion   ROWVERSION     NOT NULL,
        CONSTRAINT PK_CashBankAccounts PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_CashBankAccounts_Code UNIQUE (AccountCode),
        CONSTRAINT CK_CashBankAccounts_Type CHECK (AccountType IN (N'Cash', N'Bank')),
        CONSTRAINT CK_CashBankAccounts_Code_NotBlank CHECK (LEN(LTRIM(RTRIM(AccountCode))) > 0),
        CONSTRAINT CK_CashBankAccounts_Name_NotBlank CHECK (LEN(LTRIM(RTRIM(AccountName))) > 0),
        CONSTRAINT FK_CashBankAccounts_Currency  FOREIGN KEY (CurrencyId) REFERENCES masterdata.Currencies (Id),
        CONSTRAINT FK_CashBankAccounts_Branch    FOREIGN KEY (BranchId)   REFERENCES masterdata.Branches (Id),
        CONSTRAINT FK_CashBankAccounts_CreatedBy FOREIGN KEY (CreatedBy)  REFERENCES security.Users (Id),
        CONSTRAINT FK_CashBankAccounts_UpdatedBy FOREIGN KEY (UpdatedBy)  REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_CashBankAccounts_Currency ON masterdata.CashBankAccounts (CurrencyId, IsActive);
    PRINT 'Created masterdata.CashBankAccounts';
END
GO

/* ================================================================== 3. The receipt tables */

IF OBJECT_ID(N'sales.Receipts', N'U') IS NULL
BEGIN
    CREATE TABLE sales.Receipts
    (
        Id             INT IDENTITY(1,1) NOT NULL,
        ReceiptNumber  NVARCHAR(30)   NULL,                    -- RCP-2026-0001, assigned at the first save
        ReceiptDate    DATE           NOT NULL,
        ClientId       INT            NOT NULL,                -- masterdata.Parties (IsClient)
        BranchId       INT            NOT NULL,
        PaymentType    TINYINT        NOT NULL CONSTRAINT DF_Receipts_PaymentType DEFAULT (1),   -- 1 Free Receipt, 2 Sales Allocation
        CurrencyId     INT            NOT NULL,                -- the header currency
        Amount         DECIMAL(18,2)  NOT NULL,                -- in the header currency
        ExchangeRate   DECIMAL(18,6)  NOT NULL CONSTRAINT DF_Receipts_Rate DEFAULT (1),          -- units of the currency per 1 base
        AmountBase     AS (CONVERT(DECIMAL(18,2), Amount / ExchangeRate)) PERSISTED,
        Notes          NVARCHAR(1000) NULL,
        Status         TINYINT        NOT NULL CONSTRAINT DF_Receipts_Status DEFAULT (1),        -- 1 Draft, 2 Posted, 3 Reversed
        PostedAtUtc    DATETIME2(3)   NULL,
        PostedBy       INT            NULL,
        ReversedAtUtc  DATETIME2(3)   NULL,
        ReversedBy     INT            NULL,
        ReverseReason  NVARCHAR(500)  NULL,
        CreatedAtUtc   DATETIME2(3)   NOT NULL CONSTRAINT DF_Receipts_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy      INT            NULL,
        UpdatedAtUtc   DATETIME2(3)   NULL,
        UpdatedBy      INT            NULL,
        RowVersion     ROWVERSION     NOT NULL,
        CONSTRAINT PK_Receipts PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_Receipts_PaymentType CHECK (PaymentType IN (1, 2)),
        CONSTRAINT CK_Receipts_Status      CHECK (Status IN (1, 2, 3)),
        CONSTRAINT CK_Receipts_Amount      CHECK (Amount > 0),
        CONSTRAINT CK_Receipts_Rate        CHECK (ExchangeRate > 0),
        CONSTRAINT CK_Receipts_Reversal    CHECK (Status <> 3 OR (ReversedAtUtc IS NOT NULL AND ReversedBy IS NOT NULL)),
        CONSTRAINT FK_Receipts_Client      FOREIGN KEY (ClientId)   REFERENCES masterdata.Parties (Id),
        CONSTRAINT FK_Receipts_Branch      FOREIGN KEY (BranchId)   REFERENCES masterdata.Branches (Id),
        CONSTRAINT FK_Receipts_Currency    FOREIGN KEY (CurrencyId) REFERENCES masterdata.Currencies (Id),
        CONSTRAINT FK_Receipts_PostedBy    FOREIGN KEY (PostedBy)   REFERENCES security.Users (Id),
        CONSTRAINT FK_Receipts_ReversedBy  FOREIGN KEY (ReversedBy) REFERENCES security.Users (Id),
        CONSTRAINT FK_Receipts_CreatedBy   FOREIGN KEY (CreatedBy)  REFERENCES security.Users (Id),
        CONSTRAINT FK_Receipts_UpdatedBy   FOREIGN KEY (UpdatedBy)  REFERENCES security.Users (Id)
    );
    CREATE UNIQUE NONCLUSTERED INDEX UX_Receipts_Number ON sales.Receipts (ReceiptNumber) WHERE ReceiptNumber IS NOT NULL;
    CREATE NONCLUSTERED INDEX IX_Receipts_Client ON sales.Receipts (ClientId, ReceiptDate DESC);
    CREATE NONCLUSTERED INDEX IX_Receipts_Status ON sales.Receipts (Status, ReceiptDate DESC);
    PRINT 'Created sales.Receipts';
END
GO

IF OBJECT_ID(N'sales.ReceiptLines', N'U') IS NULL
BEGIN
    CREATE TABLE sales.ReceiptLines
    (
        Id                INT IDENTITY(1,1) NOT NULL,
        ReceiptId         INT            NOT NULL,
        LineNumber        INT            NOT NULL,
        PaymentMethodId   INT            NOT NULL,
        CurrencyId        INT            NOT NULL,                -- the currency actually received on this line
        Amount            DECIMAL(18,2)  NOT NULL,
        ExchangeRate      DECIMAL(18,6)  NOT NULL CONSTRAINT DF_ReceiptLines_Rate DEFAULT (1),
        AmountBase        AS (CONVERT(DECIMAL(18,2), Amount / ExchangeRate)) PERSISTED,
        CashBankAccountId INT            NOT NULL,                -- where the money went; its currency must be the line's
        Reference         NVARCHAR(100)  NULL,                    -- cheque / transfer number
        CONSTRAINT PK_ReceiptLines PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_ReceiptLines_Number UNIQUE (ReceiptId, LineNumber),
        CONSTRAINT CK_ReceiptLines_Amount CHECK (Amount > 0),
        CONSTRAINT CK_ReceiptLines_Rate   CHECK (ExchangeRate > 0),
        CONSTRAINT FK_ReceiptLines_Receipt  FOREIGN KEY (ReceiptId)         REFERENCES sales.Receipts (Id),
        CONSTRAINT FK_ReceiptLines_Method   FOREIGN KEY (PaymentMethodId)   REFERENCES masterdata.PaymentMethods (Id),
        CONSTRAINT FK_ReceiptLines_Currency FOREIGN KEY (CurrencyId)        REFERENCES masterdata.Currencies (Id),
        CONSTRAINT FK_ReceiptLines_Account  FOREIGN KEY (CashBankAccountId) REFERENCES masterdata.CashBankAccounts (Id)
    );
    CREATE NONCLUSTERED INDEX IX_ReceiptLines_Method  ON sales.ReceiptLines (PaymentMethodId);
    CREATE NONCLUSTERED INDEX IX_ReceiptLines_Account ON sales.ReceiptLines (CashBankAccountId);
    PRINT 'Created sales.ReceiptLines';
END
GO

IF OBJECT_ID(N'sales.ReceiptAllocations', N'U') IS NULL
BEGIN
    CREATE TABLE sales.ReceiptAllocations
    (
        Id                    INT IDENTITY(1,1) NOT NULL,
        ReceiptId             INT            NOT NULL,
        SalesDocumentId       INT            NOT NULL,           -- the invoice being paid
        AmountInvoiceCurrency DECIMAL(18,2)  NOT NULL,           -- entered in the INVOICE's currency
        InvoiceExchangeRate   DECIMAL(18,6)  NOT NULL,           -- the invoice's own stored rate, snapshotted
        AmountBase            AS (CONVERT(DECIMAL(18,2), AmountInvoiceCurrency / InvoiceExchangeRate)) PERSISTED,
        AllocatedAtUtc        DATETIME2(3)   NOT NULL CONSTRAINT DF_ReceiptAllocations_At DEFAULT (SYSUTCDATETIME()),
        AllocatedBy           INT            NULL,
        RemovedAtUtc          DATETIME2(3)   NULL,               -- a taken-back later allocation; the row stays as proof
        RemovedBy             INT            NULL,
        CONSTRAINT PK_ReceiptAllocations PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_ReceiptAllocations_Amount  CHECK (AmountInvoiceCurrency > 0),
        CONSTRAINT CK_ReceiptAllocations_Rate    CHECK (InvoiceExchangeRate > 0),
        CONSTRAINT CK_ReceiptAllocations_Removed CHECK ((RemovedAtUtc IS NULL AND RemovedBy IS NULL) OR (RemovedAtUtc IS NOT NULL AND RemovedBy IS NOT NULL)),
        CONSTRAINT FK_ReceiptAllocations_Receipt   FOREIGN KEY (ReceiptId)       REFERENCES sales.Receipts (Id),
        CONSTRAINT FK_ReceiptAllocations_Invoice   FOREIGN KEY (SalesDocumentId) REFERENCES sales.SalesDocuments (Id),
        CONSTRAINT FK_ReceiptAllocations_By        FOREIGN KEY (AllocatedBy)     REFERENCES security.Users (Id),
        CONSTRAINT FK_ReceiptAllocations_RemovedBy FOREIGN KEY (RemovedBy)       REFERENCES security.Users (Id)
    );
    -- THE INDEX THE INVOICE LIST WILL LEAN ON: paid = SUM over an invoice's live allocations.
    CREATE NONCLUSTERED INDEX IX_ReceiptAllocations_Invoice ON sales.ReceiptAllocations (SalesDocumentId)
        INCLUDE (ReceiptId, AmountInvoiceCurrency, RemovedAtUtc);
    CREATE NONCLUSTERED INDEX IX_ReceiptAllocations_Receipt ON sales.ReceiptAllocations (ReceiptId);
    PRINT 'Created sales.ReceiptAllocations';
END
GO

IF OBJECT_ID(N'sales.ReceiptFiles', N'U') IS NULL
BEGIN
    CREATE TABLE sales.ReceiptFiles
    (
        Id               INT IDENTITY(1,1) NOT NULL,
        ReceiptId        INT            NOT NULL,
        AttachmentTypeId INT            NULL,                     -- Type / Sub Type, from masterdata.AttachmentTypes
        Note             NVARCHAR(300)  NULL,
        FileName         NVARCHAR(255)  NOT NULL,
        ContentType      NVARCHAR(100)  NOT NULL,
        SizeBytes        INT            NOT NULL,
        Content          VARBINARY(MAX) NOT NULL,
        CreatedAtUtc     DATETIME2(3)   NOT NULL CONSTRAINT DF_ReceiptFiles_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy        INT            NULL,
        CONSTRAINT PK_ReceiptFiles PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_ReceiptFiles_Size CHECK (SizeBytes > 0),
        CONSTRAINT FK_ReceiptFiles_Receipt   FOREIGN KEY (ReceiptId)        REFERENCES sales.Receipts (Id),
        CONSTRAINT FK_ReceiptFiles_Type      FOREIGN KEY (AttachmentTypeId) REFERENCES masterdata.AttachmentTypes (Id),
        CONSTRAINT FK_ReceiptFiles_CreatedBy FOREIGN KEY (CreatedBy)        REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_ReceiptFiles_Receipt ON sales.ReceiptFiles (ReceiptId);
    PRINT 'Created sales.ReceiptFiles';
END
GO

IF OBJECT_ID(N'sales.ReceiptAudit', N'U') IS NULL
BEGIN
    CREATE TABLE sales.ReceiptAudit
    (
        Id        BIGINT IDENTITY(1,1) NOT NULL,
        ReceiptId INT           NOT NULL,
        Action    NVARCHAR(20)  NOT NULL,   -- Created | Updated | Posted | Reversed | Allocated | Deallocated | FileAdded | FileDeleted
        Details   NVARCHAR(500) NULL,
        UserId    INT           NULL,
        AtUtc     DATETIME2(3)  NOT NULL CONSTRAINT DF_ReceiptAudit_AtUtc DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_ReceiptAudit PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_ReceiptAudit_Receipt FOREIGN KEY (ReceiptId) REFERENCES sales.Receipts (Id),
        CONSTRAINT FK_ReceiptAudit_User    FOREIGN KEY (UserId)    REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_ReceiptAudit_Receipt ON sales.ReceiptAudit (ReceiptId, AtUtc DESC);
    PRINT 'Created sales.ReceiptAudit';
END
GO

/* ================================================================== 4. Document type RCPT */

IF EXISTS (SELECT 1 FROM sys.check_constraints
           WHERE name = N'CK_DocumentTypes_Family'
             AND parent_object_id = OBJECT_ID(N'inventory.DocumentTypes')
             AND [definition] NOT LIKE N'%Receipt%')
BEGIN
    ALTER TABLE inventory.DocumentTypes DROP CONSTRAINT CK_DocumentTypes_Family;
    ALTER TABLE inventory.DocumentTypes ADD CONSTRAINT CK_DocumentTypes_Family
        CHECK (Family IN (N'Inventory', N'Purchase', N'Sales', N'Logistics', N'Receipt'));
    PRINT 'DocumentTypes: family Receipt allowed';
END
GO

MERGE inventory.DocumentTypes AS t
USING (VALUES (N'RCPT', N'Customer Receipt', N'Receipt', 0, N'RCP-', 0, 0)) AS s (Code, Name, Family, StockDirection, NumberPrefix, NumberOnPost, RequiresReason)
ON t.Code = s.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Family, StockDirection, NumberPrefix, NumberOnPost, RequiresReason)
    VALUES (s.Code, s.Name, s.Family, s.StockDirection, s.NumberPrefix, s.NumberOnPost, s.RequiresReason);
GO

/* Numbered at the FIRST SAVE (NumberOnPost = 0) so a draft already has the number the mockup shows,
   with the year in it and four digits, shared across branches: RCP-2026-0001. The WHERE keeps a
   re-run from touching a configuration somebody has since changed on purpose. */
UPDATE inventory.DocumentTypes
SET DefaultPricing = N'None', PriceEditable = 0, NumberPerBranch = 0, YearInNumber = 1, NumberLength = 4
WHERE Code = N'RCPT' AND NextNumber = 1 AND UpdatedAtUtc IS NULL;
GO

/* ================================================================== 5. Payment method procedures */

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
           UsedCount = (SELECT COUNT(*) FROM sales.ReceiptLines x WHERE x.PaymentMethodId = m.Id),
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

CREATE OR ALTER PROCEDURE masterdata.usp_PaymentMethod_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, MethodCode, MethodName, Description, IsActive,
           CreatedAtUtc, CreatedBy, UpdatedAtUtc, UpdatedBy, RowVersion
    FROM masterdata.PaymentMethods WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_PaymentMethod_Lookup
    @ActiveOnly BIT = 1,
    @IncludeId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, MethodCode, MethodName, IsActive
    FROM masterdata.PaymentMethods
    WHERE (@ActiveOnly = 0 OR IsActive = 1 OR Id = @IncludeId)
    ORDER BY MethodName;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_PaymentMethod_Save
    @Id          INT           = NULL,
    @MethodCode  NVARCHAR(10),
    @MethodName  NVARCHAR(100),
    @Description NVARCHAR(500) = NULL,
    @IsActive    BIT           = 1,
    @RowVersion  BINARY(8)     = NULL,
    @UserId      INT           = NULL,
    @NewId       INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @MethodCode = UPPER(NULLIF(LTRIM(RTRIM(@MethodCode)), N''));
    SET @MethodName = NULLIF(LTRIM(RTRIM(@MethodName)), N'');
    SET @Description = NULLIF(LTRIM(RTRIM(@Description)), N'');
    IF @MethodCode IS NULL THROW 71000, 'Payment method code is required.', 1;
    IF @MethodName IS NULL THROW 71000, 'Payment method name is required.', 1;
    IF EXISTS (SELECT 1 FROM masterdata.PaymentMethods WHERE MethodCode = @MethodCode AND (@Id IS NULL OR Id <> @Id))
        THROW 71013, 'This payment method code already exists.', 1;

    IF @Id IS NULL
    BEGIN
        INSERT INTO masterdata.PaymentMethods (MethodCode, MethodName, Description, IsActive, CreatedBy)
        VALUES (@MethodCode, @MethodName, @Description, ISNULL(@IsActive, 1), @UserId);
        SET @NewId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM masterdata.PaymentMethods WHERE Id = @Id) THROW 71006, 'Payment method not found.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.PaymentMethods WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 71004, 'This payment method was modified by another user. Reload the page and try again.', 1;
        UPDATE masterdata.PaymentMethods
        SET MethodCode = @MethodCode, MethodName = @MethodName, Description = @Description, IsActive = ISNULL(@IsActive, 1),
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;
        SET @NewId = @Id;
    END
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_PaymentMethod_SetActive
    @Id INT, @IsActive BIT, @RowVersion BINARY(8) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.PaymentMethods WHERE Id = @Id) THROW 71006, 'Payment method not found.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.PaymentMethods WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 71004, 'This payment method was modified by another user. Reload the page and try again.', 1;
    UPDATE masterdata.PaymentMethods SET IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_PaymentMethod_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.PaymentMethods WHERE Id = @Id) THROW 71006, 'Payment method not found.', 1;
    IF EXISTS (SELECT 1 FROM sales.ReceiptLines WHERE PaymentMethodId = @Id)
        THROW 71014, 'This payment method is used by receipts and cannot be deleted. Deactivate it instead.', 1;
    DELETE FROM masterdata.PaymentMethods WHERE Id = @Id;
END
GO

/* ================================================================== 6. Cash / bank account procedures */

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
           UsedCount = (SELECT COUNT(*) FROM sales.ReceiptLines x WHERE x.CashBankAccountId = a.Id),
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

CREATE OR ALTER PROCEDURE masterdata.usp_CashBankAccount_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT a.Id, a.AccountCode, a.AccountName, a.AccountType, a.CurrencyId, c.CurrencyCode,
           a.BranchId, BranchName = b.BranchName, a.Description, a.IsActive,
           a.CreatedAtUtc, a.CreatedBy, a.UpdatedAtUtc, a.UpdatedBy, a.RowVersion
    FROM masterdata.CashBankAccounts a
    INNER JOIN masterdata.Currencies c ON c.Id = a.CurrencyId
    LEFT JOIN masterdata.Branches b ON b.Id = a.BranchId
    WHERE a.Id = @Id;
END
GO

/* What a receipt line's account picker reads. FILTERED BY CURRENCY AND BRANCH because both are rules
   of the line: the account must hold the line's currency, and must be one the receipt's branch may
   use (an account with no branch belongs to everybody). */
CREATE OR ALTER PROCEDURE masterdata.usp_CashBankAccount_Lookup
    @ActiveOnly BIT = 1,
    @CurrencyId INT = NULL,
    @BranchId   INT = NULL,
    @IncludeId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT a.Id, a.AccountCode, a.AccountName, a.AccountType, a.CurrencyId, c.CurrencyCode, a.BranchId, a.IsActive
    FROM masterdata.CashBankAccounts a
    INNER JOIN masterdata.Currencies c ON c.Id = a.CurrencyId
    WHERE (@ActiveOnly = 0 OR a.IsActive = 1 OR a.Id = @IncludeId)
      AND (@CurrencyId IS NULL OR a.CurrencyId = @CurrencyId OR a.Id = @IncludeId)
      AND (@BranchId IS NULL OR a.BranchId IS NULL OR a.BranchId = @BranchId OR a.Id = @IncludeId)
    ORDER BY a.AccountName;
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
           AND EXISTS (SELECT 1 FROM sales.ReceiptLines WHERE CashBankAccountId = @Id)
            THROW 71000, 'The currency of an account that receipts already use cannot be changed.', 1;

        UPDATE masterdata.CashBankAccounts
        SET AccountCode = @AccountCode, AccountName = @AccountName, AccountType = @AccountType, CurrencyId = @CurrencyId,
            BranchId = @BranchId, Description = @Description, IsActive = ISNULL(@IsActive, 1),
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;
        SET @NewId = @Id;
    END
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_CashBankAccount_SetActive
    @Id INT, @IsActive BIT, @RowVersion BINARY(8) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.CashBankAccounts WHERE Id = @Id) THROW 71006, 'Cash / bank account not found.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.CashBankAccounts WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 71004, 'This account was modified by another user. Reload the page and try again.', 1;
    UPDATE masterdata.CashBankAccounts SET IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_CashBankAccount_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.CashBankAccounts WHERE Id = @Id) THROW 71006, 'Cash / bank account not found.', 1;
    IF EXISTS (SELECT 1 FROM sales.ReceiptLines WHERE CashBankAccountId = @Id)
        THROW 71014, 'This account is used by receipts and cannot be deleted. Deactivate it instead.', 1;
    DELETE FROM masterdata.CashBankAccounts WHERE Id = @Id;
END
GO

/* ================================================================== 7. Permissions */

MERGE security.Permissions AS target
USING
(
    VALUES
        (N'masterdata.paymentmethods.manage',  N'Manage payment methods',   N'Master Data', N'Define the payment methods a receipt line can use.',           1480),
        (N'masterdata.cashbankaccounts.manage', N'Manage cash / bank accounts', N'Master Data', N'Define the cash boxes and bank accounts receipts are paid into.', 1490)
) AS source (Code, Name, Module, Description, SortOrder)
ON target.Code = source.Code
WHEN MATCHED THEN
    UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Module, Description, SortOrder)
    VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder);
GO

INSERT INTO security.RolePermissions (RoleId, PermissionId)
SELECT r.Id, p.Id
FROM security.Roles r
CROSS JOIN security.Permissions p
WHERE p.Code IN (N'masterdata.paymentmethods.manage', N'masterdata.cashbankaccounts.manage')
  AND r.IsSystem = 1
  AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);
GO

/* ================================================================== 8. Check */

SELECT MethodCode, MethodName FROM masterdata.PaymentMethods ORDER BY MethodCode;
SELECT Code, Name, Family, NumberPrefix, NumberLength, YearInNumber, NumberPerBranch, NumberOnPost FROM inventory.DocumentTypes WHERE Code = N'RCPT';
SELECT Code, Name, Module, SortOrder FROM security.Permissions WHERE Code IN (N'masterdata.paymentmethods.manage', N'masterdata.cashbankaccounts.manage');
PRINT 'Script 35 applied: payment methods, cash / bank accounts, receipt tables, document type RCPT.';
GO
