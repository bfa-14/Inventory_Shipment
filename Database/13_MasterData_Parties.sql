/* =====================================================================================
   Inventory_Shipment - 13: Master Data - Parties   (user story US-MD-007)

   ONE centralized party master (suppliers, clients, salesmen, employees) with MULTI-TYPE flags.

   Schema:  masterdata. Table: masterdata.Parties
   Procs:   masterdata.usp_Party_Search / _Get / _Lookup / _NextCode / _Create / _Update /
            _SetActive / _Delete
   Seeds:   permissions masterdata.parties.view / create / edit / delete (sort 520-550);
            supplier SUP-0001 "TVS Motor Company" when the table is empty.

   Design (agreed):
     - Types are four flags (IsSupplier / IsClient / IsSalesman / IsEmployee); at least one is set.
     - Party Code is auto-SUGGESTED from the first checked type (SUP-/CLI-/SAL-/EMP- + 4 digits),
       editable, unique, never renamed later.
     - Optional links: BranchId (active branch), UserId (security.Users - one party per user, for
       "current user is salesman X"), DefaultCurrencyId (suppliers), and ONE PRICE LIST PER ROLE:
       ClientPriceListId (the list this party gets when it buys) and SalesmanPriceListId (the list this
       person sells with). Sales resolution order: client's list -> salesman's list -> company default.
     - Email format validated when entered; phone/mobile free text; no uniqueness on contacts.
     - A type cannot be REMOVED while the party is referenced in that role. Convention for future
       tables: name the FK column after the role - SupplierId / ClientId / SalesmanId / EmployeeId
       (a generic PartyId column blocks the removal of any type). The guard reads sys.foreign_keys,
       so it switches on automatically when purchase/sales tables arrive.
     - Delete only when nothing references the party (any FK) - else deactivate.

   Error numbers (read by the API):
     60000 validation   60001 Party Code already exists   60002 user already linked to another party
     60003 referenced - cannot delete   60004 concurrency   60005 type in use - cannot be removed
     60006 not found   60008 related master data missing/inactive (branch, price list, currency, user)

   Requires 01, 03, 06 (Branches), 08 (Currencies), 12 (Price Lists). Idempotent. SQL Server 2016 SP1+.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'security.Users', N'U') IS NULL OR OBJECT_ID(N'masterdata.Branches', N'U') IS NULL
   OR OBJECT_ID(N'masterdata.Currencies', N'U') IS NULL OR OBJECT_ID(N'masterdata.PriceLists', N'U') IS NULL
BEGIN
    RAISERROR ('Run scripts 01, 03, 06, 08 and 12 before this script.', 16, 1);
    RETURN;
END
GO

/* ------------------------------------------------------------------ 1. Table */

IF OBJECT_ID(N'masterdata.Parties', N'U') IS NULL
BEGIN
    CREATE TABLE masterdata.Parties
    (
        Id                 INT IDENTITY(1,1) NOT NULL,
        PartyCode          NVARCHAR(20)      NOT NULL,
        PartyName          NVARCHAR(200)     NOT NULL,
        IsSupplier         BIT               NOT NULL CONSTRAINT DF_Parties_IsSupplier DEFAULT (0),
        IsClient           BIT               NOT NULL CONSTRAINT DF_Parties_IsClient   DEFAULT (0),
        IsSalesman         BIT               NOT NULL CONSTRAINT DF_Parties_IsSalesman DEFAULT (0),
        IsEmployee         BIT               NOT NULL CONSTRAINT DF_Parties_IsEmployee DEFAULT (0),
        BranchId           INT               NULL,
        ContactPerson      NVARCHAR(150)     NULL,
        Phone              NVARCHAR(50)      NULL,
        Mobile             NVARCHAR(50)      NULL,
        Email              NVARCHAR(150)     NULL,
        Address            NVARCHAR(500)     NULL,
        Country            NVARCHAR(2)       NULL,        -- ISO 3166-1 alpha-2
        TaxRegistrationNo  NVARCHAR(50)      NULL,
        Notes              NVARCHAR(1000)    NULL,
        UserId             INT               NULL,        -- linked application user (salesman / employee)
        ClientPriceListId   INT              NULL,        -- clients: price list applied when this party buys
        SalesmanPriceListId INT              NULL,        -- salesmen: price list this person sells with
        DefaultCurrencyId  INT               NULL,        -- suppliers: currency used by default on purchases
        IsActive           BIT               NOT NULL CONSTRAINT DF_Parties_IsActive DEFAULT (1),
        CreatedAtUtc       DATETIME2(3)      NOT NULL CONSTRAINT DF_Parties_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy          INT               NULL,
        UpdatedAtUtc       DATETIME2(3)      NULL,
        UpdatedBy          INT               NULL,
        RowVersion         ROWVERSION        NOT NULL,
        CONSTRAINT PK_Parties PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_Parties_PartyCode UNIQUE (PartyCode),
        CONSTRAINT CK_Parties_PartyCode_NotBlank CHECK (LEN(LTRIM(RTRIM(PartyCode))) > 0),
        CONSTRAINT CK_Parties_PartyName_NotBlank CHECK (LEN(LTRIM(RTRIM(PartyName))) > 0),
        CONSTRAINT CK_Parties_AtLeastOneType CHECK (IsSupplier = 1 OR IsClient = 1 OR IsSalesman = 1 OR IsEmployee = 1),
        CONSTRAINT FK_Parties_Branch        FOREIGN KEY (BranchId)           REFERENCES masterdata.Branches (Id),
        CONSTRAINT FK_Parties_User          FOREIGN KEY (UserId)             REFERENCES security.Users (Id),
        CONSTRAINT FK_Parties_ClientPriceList   FOREIGN KEY (ClientPriceListId)   REFERENCES masterdata.PriceLists (Id),
        CONSTRAINT FK_Parties_SalesmanPriceList FOREIGN KEY (SalesmanPriceListId) REFERENCES masterdata.PriceLists (Id),
        CONSTRAINT FK_Parties_Currency      FOREIGN KEY (DefaultCurrencyId)  REFERENCES masterdata.Currencies (Id),
        CONSTRAINT FK_Parties_CreatedBy     FOREIGN KEY (CreatedBy)          REFERENCES security.Users (Id),
        CONSTRAINT FK_Parties_UpdatedBy     FOREIGN KEY (UpdatedBy)          REFERENCES security.Users (Id)
    );

    -- One party per application user.
    CREATE UNIQUE NONCLUSTERED INDEX UX_Parties_UserId ON masterdata.Parties (UserId) WHERE UserId IS NOT NULL;
    CREATE NONCLUSTERED INDEX IX_Parties_PartyName ON masterdata.Parties (PartyName);
    CREATE NONCLUSTERED INDEX IX_Parties_Branch    ON masterdata.Parties (BranchId);
    CREATE NONCLUSTERED INDEX IX_Parties_Types     ON masterdata.Parties (IsSupplier, IsClient, IsSalesman, IsEmployee) INCLUDE (PartyCode, PartyName, IsActive);

    PRINT 'Created masterdata.Parties';
END
GO

-- Upgrade for databases created with the first version of this script (single DefaultPriceListId).
IF COL_LENGTH(N'masterdata.Parties', N'DefaultPriceListId') IS NOT NULL
BEGIN
    EXEC sp_rename N'masterdata.Parties.DefaultPriceListId', N'ClientPriceListId', N'COLUMN';
    IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_Parties_PriceList')
        EXEC sp_rename N'masterdata.FK_Parties_PriceList', N'FK_Parties_ClientPriceList', N'OBJECT';
    PRINT 'Renamed DefaultPriceListId -> ClientPriceListId';
END
GO

IF COL_LENGTH(N'masterdata.Parties', N'SalesmanPriceListId') IS NULL
BEGIN
    ALTER TABLE masterdata.Parties ADD SalesmanPriceListId INT NULL
        CONSTRAINT FK_Parties_SalesmanPriceList FOREIGN KEY REFERENCES masterdata.PriceLists (Id);
    PRINT 'Added SalesmanPriceListId';
END
GO

/* ------------------------------------------------------------------ 2. Procedures */

CREATE OR ALTER PROCEDURE masterdata.usp_Party_Search
    @Search        NVARCHAR(200) = NULL,   -- code, name, phone, mobile or email
    @PartyType     NVARCHAR(20)  = NULL,   -- Supplier | Client | Salesman | Employee | NULL = all
    @BranchId      INT           = NULL,
    @IsActive      BIT           = NULL,
    @SortColumn    NVARCHAR(30)  = N'PartyCode', -- PartyCode | PartyName | BranchName | Email | Phone | IsActive | CreatedAtUtc
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
    SET @PartyType = NULLIF(LTRIM(RTRIM(@PartyType)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'PartyCode', N'PartyName', N'BranchName', N'Email', N'Phone', N'IsActive', N'CreatedAtUtc')
        SET @SortColumn = N'PartyCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT p.Id, p.PartyCode, p.PartyName, p.IsSupplier, p.IsClient, p.IsSalesman, p.IsEmployee,
           p.BranchId, b.BranchCode, b.BranchName, p.ContactPerson, p.Phone, p.Mobile, p.Email,
           p.Address, p.Country, p.TaxRegistrationNo, p.Notes,
           p.UserId, u.Username AS UserName, u.FullName AS UserFullName,
           p.ClientPriceListId, cpl.PriceListName AS ClientPriceListName,
           p.SalesmanPriceListId, spl.PriceListName AS SalesmanPriceListName,
           p.DefaultCurrencyId, c.CurrencyCode AS DefaultCurrencyCode,
           p.IsActive, p.CreatedAtUtc, p.CreatedBy, p.UpdatedAtUtc, p.UpdatedBy, p.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.Parties p
    LEFT JOIN masterdata.Branches b    ON b.Id  = p.BranchId
    LEFT JOIN security.Users u         ON u.Id  = p.UserId
    LEFT JOIN masterdata.PriceLists cpl ON cpl.Id = p.ClientPriceListId
    LEFT JOIN masterdata.PriceLists spl ON spl.Id = p.SalesmanPriceListId
    LEFT JOIN masterdata.Currencies c   ON c.Id   = p.DefaultCurrencyId
    WHERE (@Search IS NULL OR p.PartyCode LIKE N'%' + @Search + N'%' OR p.PartyName LIKE N'%' + @Search + N'%'
           OR p.Phone LIKE N'%' + @Search + N'%' OR p.Mobile LIKE N'%' + @Search + N'%' OR p.Email LIKE N'%' + @Search + N'%')
      AND (@PartyType IS NULL
           OR (@PartyType = N'Supplier' AND p.IsSupplier = 1)
           OR (@PartyType = N'Client'   AND p.IsClient   = 1)
           OR (@PartyType = N'Salesman' AND p.IsSalesman = 1)
           OR (@PartyType = N'Employee' AND p.IsEmployee = 1))
      AND (@BranchId IS NULL OR p.BranchId = @BranchId)
      AND (@IsActive IS NULL OR p.IsActive = @IsActive)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'PartyCode' THEN p.PartyCode WHEN N'PartyName' THEN p.PartyName
                             WHEN N'BranchName' THEN b.BranchName WHEN N'Email' THEN p.Email WHEN N'Phone' THEN p.Phone END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'PartyCode' THEN p.PartyCode WHEN N'PartyName' THEN p.PartyName
                             WHEN N'BranchName' THEN b.BranchName WHEN N'Email' THEN p.Email WHEN N'Phone' THEN p.Phone END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(p.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(p.IsActive AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN p.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN p.CreatedAtUtc END DESC,
        p.PartyCode ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Party_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT p.Id, p.PartyCode, p.PartyName, p.IsSupplier, p.IsClient, p.IsSalesman, p.IsEmployee,
           p.BranchId, b.BranchCode, b.BranchName, p.ContactPerson, p.Phone, p.Mobile, p.Email,
           p.Address, p.Country, p.TaxRegistrationNo, p.Notes,
           p.UserId, u.Username AS UserName, u.FullName AS UserFullName,
           p.ClientPriceListId, cpl.PriceListName AS ClientPriceListName,
           p.SalesmanPriceListId, spl.PriceListName AS SalesmanPriceListName,
           p.DefaultCurrencyId, c.CurrencyCode AS DefaultCurrencyCode,
           p.IsActive, p.CreatedAtUtc, p.CreatedBy, p.UpdatedAtUtc, p.UpdatedBy, p.RowVersion
    FROM masterdata.Parties p
    LEFT JOIN masterdata.Branches b    ON b.Id  = p.BranchId
    LEFT JOIN security.Users u         ON u.Id  = p.UserId
    LEFT JOIN masterdata.PriceLists cpl ON cpl.Id = p.ClientPriceListId
    LEFT JOIN masterdata.PriceLists spl ON spl.Id = p.SalesmanPriceListId
    LEFT JOIN masterdata.Currencies c   ON c.Id   = p.DefaultCurrencyId
    WHERE p.Id = @Id;
END
GO

-- Typed dropdown data for the other modules (purchase orders -> Supplier, invoices -> Client...).
CREATE OR ALTER PROCEDURE masterdata.usp_Party_Lookup
    @PartyType  NVARCHAR(20)  = NULL,   -- Supplier | Client | Salesman | Employee | NULL = any
    @Search     NVARCHAR(200) = NULL,
    @ActiveOnly BIT           = 1,
    @IncludeId  INT           = NULL,
    @Top        INT           = 50
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @PartyType = NULLIF(LTRIM(RTRIM(@PartyType)), N'');
    IF @Top IS NULL OR @Top < 1 SET @Top = 50;
    IF @Top > 500 SET @Top = 500;

    SELECT TOP (@Top) p.Id, p.PartyCode, p.PartyName, p.IsSupplier, p.IsClient, p.IsSalesman, p.IsEmployee,
           p.BranchId, p.ClientPriceListId, p.SalesmanPriceListId, p.DefaultCurrencyId, p.UserId, p.IsActive
    FROM masterdata.Parties p
    WHERE (@ActiveOnly = 0 OR p.IsActive = 1 OR p.Id = @IncludeId)
      AND (@PartyType IS NULL
           OR (@PartyType = N'Supplier' AND p.IsSupplier = 1)
           OR (@PartyType = N'Client'   AND p.IsClient   = 1)
           OR (@PartyType = N'Salesman' AND p.IsSalesman = 1)
           OR (@PartyType = N'Employee' AND p.IsEmployee = 1)
           OR p.Id = @IncludeId)
      AND (@Search IS NULL OR p.PartyCode LIKE N'%' + @Search + N'%' OR p.PartyName LIKE N'%' + @Search + N'%')
    ORDER BY CASE WHEN p.PartyCode LIKE @Search + N'%' THEN 0 ELSE 1 END, p.PartyName;
END
GO

-- Suggested code from the first checked type: SUP-0001 / CLI-0001 / SAL-0001 / EMP-0001 (editable).
CREATE OR ALTER PROCEDURE masterdata.usp_Party_NextCode
    @PartyType NVARCHAR(20)   -- Supplier | Client | Salesman | Employee
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Prefix NVARCHAR(4) =
        CASE @PartyType WHEN N'Supplier' THEN N'SUP-' WHEN N'Client' THEN N'CLI-'
                        WHEN N'Salesman' THEN N'SAL-' WHEN N'Employee' THEN N'EMP-' END;
    IF @Prefix IS NULL
        THROW 60000, 'Party type must be Supplier, Client, Salesman or Employee.', 1;

    DECLARE @Seq INT = 1, @Code NVARCHAR(20);
    SET @Code = @Prefix + RIGHT(N'0000' + CAST(@Seq AS NVARCHAR(10)), 4);
    WHILE EXISTS (SELECT 1 FROM masterdata.Parties WHERE PartyCode = @Code) AND @Seq < 100000
    BEGIN
        SET @Seq += 1;
        SET @Code = @Prefix + RIGHT(N'0000' + CAST(@Seq AS NVARCHAR(10)), 4);
    END

    SELECT SuggestedCode = @Code;
END
GO

-- Shared validation (called by Create and Update).
CREATE OR ALTER PROCEDURE masterdata.usp_Party_Validate
    @Id                 INT = NULL,       -- NULL when creating
    @PartyCode          NVARCHAR(20),
    @PartyName          NVARCHAR(200),
    @IsSupplier         BIT, @IsClient BIT, @IsSalesman BIT, @IsEmployee BIT,
    @BranchId           INT,
    @Email              NVARCHAR(150),
    @UserId              INT,
    @ClientPriceListId   INT,
    @SalesmanPriceListId INT,
    @DefaultCurrencyId   INT
AS
BEGIN
    SET NOCOUNT ON;

    IF @PartyCode IS NULL OR @PartyCode = N'' THROW 60000, 'Party Code is required.', 1;
    IF @PartyName IS NULL OR @PartyName = N'' THROW 60000, 'Party Name is required.', 1;
    IF ISNULL(@IsSupplier, 0) = 0 AND ISNULL(@IsClient, 0) = 0 AND ISNULL(@IsSalesman, 0) = 0 AND ISNULL(@IsEmployee, 0) = 0
        THROW 60000, 'At least one Party Type must be selected.', 1;
    IF @Email IS NOT NULL AND (@Email NOT LIKE N'%_@_%.__%' OR @Email LIKE N'% %')
        THROW 60000, 'Email address format is not valid.', 1;

    IF @BranchId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 60008, 'Branch not found or inactive.', 1;
    IF @ClientPriceListId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE Id = @ClientPriceListId AND IsActive = 1)
        THROW 60008, 'Client price list not found or inactive.', 1;
    IF @SalesmanPriceListId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE Id = @SalesmanPriceListId AND IsActive = 1)
        THROW 60008, 'Salesman price list not found or inactive.', 1;
    IF @ClientPriceListId IS NOT NULL AND ISNULL(@IsClient, 0) = 0
        THROW 60000, 'A client price list can only be set when the Client type is selected.', 1;
    IF @SalesmanPriceListId IS NOT NULL AND ISNULL(@IsSalesman, 0) = 0
        THROW 60000, 'A salesman price list can only be set when the Salesman type is selected.', 1;
    IF @DefaultCurrencyId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @DefaultCurrencyId AND IsActive = 1)
        THROW 60008, 'Default currency not found or inactive.', 1;
    IF @UserId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM security.Users WHERE Id = @UserId)
        THROW 60008, 'Linked user not found.', 1;
    IF @UserId IS NOT NULL AND EXISTS (SELECT 1 FROM masterdata.Parties WHERE UserId = @UserId AND (@Id IS NULL OR Id <> @Id))
        THROW 60002, 'This user is already linked to another party.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.Parties WHERE PartyCode = @PartyCode AND (@Id IS NULL OR Id <> @Id))
        THROW 60001, 'A party with this Party Code already exists.', 1;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Party_Create
    @PartyCode          NVARCHAR(20),
    @PartyName          NVARCHAR(200),
    @IsSupplier         BIT = 0,
    @IsClient           BIT = 0,
    @IsSalesman         BIT = 0,
    @IsEmployee         BIT = 0,
    @BranchId           INT            = NULL,
    @ContactPerson      NVARCHAR(150)  = NULL,
    @Phone              NVARCHAR(50)   = NULL,
    @Mobile             NVARCHAR(50)   = NULL,
    @Email              NVARCHAR(150)  = NULL,
    @Address            NVARCHAR(500)  = NULL,
    @Country            NVARCHAR(2)    = NULL,
    @TaxRegistrationNo  NVARCHAR(50)   = NULL,
    @Notes              NVARCHAR(1000) = NULL,
    @UserId              INT           = NULL,
    @ClientPriceListId   INT           = NULL,
    @SalesmanPriceListId INT           = NULL,
    @DefaultCurrencyId   INT           = NULL,
    @IsActive           BIT            = 1,
    @ActorUserId        INT            = NULL,   -- who is saving (CreatedBy)
    @NewId              INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @PartyCode = LTRIM(RTRIM(@PartyCode));  SET @PartyName = LTRIM(RTRIM(@PartyName));
    SET @ContactPerson = NULLIF(LTRIM(RTRIM(@ContactPerson)), N'');
    SET @Phone   = NULLIF(LTRIM(RTRIM(@Phone)), N'');   SET @Mobile = NULLIF(LTRIM(RTRIM(@Mobile)), N'');
    SET @Email   = NULLIF(LTRIM(RTRIM(@Email)), N'');   SET @Address = NULLIF(LTRIM(RTRIM(@Address)), N'');
    SET @Country = NULLIF(UPPER(LTRIM(RTRIM(@Country))), N'');
    SET @TaxRegistrationNo = NULLIF(LTRIM(RTRIM(@TaxRegistrationNo)), N'');
    SET @Notes   = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    SET @IsSupplier = ISNULL(@IsSupplier, 0); SET @IsClient = ISNULL(@IsClient, 0);
    SET @IsSalesman = ISNULL(@IsSalesman, 0); SET @IsEmployee = ISNULL(@IsEmployee, 0);
    SET @IsActive = ISNULL(@IsActive, 1);

    EXEC masterdata.usp_Party_Validate NULL, @PartyCode, @PartyName, @IsSupplier, @IsClient, @IsSalesman, @IsEmployee,
         @BranchId, @Email, @UserId, @ClientPriceListId, @SalesmanPriceListId, @DefaultCurrencyId;

    INSERT INTO masterdata.Parties (PartyCode, PartyName, IsSupplier, IsClient, IsSalesman, IsEmployee, BranchId,
                                    ContactPerson, Phone, Mobile, Email, Address, Country, TaxRegistrationNo, Notes,
                                    UserId, ClientPriceListId, SalesmanPriceListId, DefaultCurrencyId, IsActive, CreatedBy)
    VALUES (@PartyCode, @PartyName, @IsSupplier, @IsClient, @IsSalesman, @IsEmployee, @BranchId,
            @ContactPerson, @Phone, @Mobile, @Email, @Address, @Country, @TaxRegistrationNo, @Notes,
            @UserId, @ClientPriceListId, @SalesmanPriceListId, @DefaultCurrencyId, @IsActive, @ActorUserId);

    SET @NewId = SCOPE_IDENTITY();
END
GO

-- Returns 1 when the party is referenced in a given role. Convention: FK columns named
-- SupplierId / ClientId / SalesmanId / EmployeeId (role-specific) or PartyId (any role).
CREATE OR ALTER PROCEDURE masterdata.usp_Party_IsReferencedAs
    @Id         INT,
    @Role       NVARCHAR(20),   -- Supplier | Client | Salesman | Employee | NULL = any reference at all
    @Referenced BIT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Referenced = 0;

    DECLARE @sql NVARCHAR(MAX) = N'';
    SELECT @sql = @sql
        + N'IF @Referenced = 0 AND EXISTS (SELECT 1 FROM ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name)
        + N' WHERE ' + QUOTENAME(c.name) + N' = @Id) SET @Referenced = 1;' + NCHAR(10)
    FROM sys.foreign_keys fk
    INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    INNER JOIN sys.tables t  ON t.object_id = fk.parent_object_id
    INNER JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
    WHERE fk.referenced_object_id = OBJECT_ID(N'masterdata.Parties')
      AND (@Role IS NULL OR c.name LIKE @Role + N'%' OR c.name LIKE N'Party%');

    IF @sql <> N''
        EXEC sp_executesql @sql, N'@Id INT, @Referenced BIT OUTPUT', @Id = @Id, @Referenced = @Referenced OUTPUT;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Party_Update
    @Id                 INT,
    @PartyCode          NVARCHAR(20),
    @PartyName          NVARCHAR(200),
    @IsSupplier         BIT = 0,
    @IsClient           BIT = 0,
    @IsSalesman         BIT = 0,
    @IsEmployee         BIT = 0,
    @BranchId           INT            = NULL,
    @ContactPerson      NVARCHAR(150)  = NULL,
    @Phone              NVARCHAR(50)   = NULL,
    @Mobile             NVARCHAR(50)   = NULL,
    @Email              NVARCHAR(150)  = NULL,
    @Address            NVARCHAR(500)  = NULL,
    @Country            NVARCHAR(2)    = NULL,
    @TaxRegistrationNo  NVARCHAR(50)   = NULL,
    @Notes              NVARCHAR(1000) = NULL,
    @UserId              INT           = NULL,
    @ClientPriceListId   INT           = NULL,
    @SalesmanPriceListId INT           = NULL,
    @DefaultCurrencyId   INT           = NULL,
    @IsActive           BIT            = 1,
    @RowVersion         BINARY(8)      = NULL,
    @ActorUserId        INT            = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SET @PartyCode = LTRIM(RTRIM(@PartyCode));  SET @PartyName = LTRIM(RTRIM(@PartyName));
    SET @ContactPerson = NULLIF(LTRIM(RTRIM(@ContactPerson)), N'');
    SET @Phone   = NULLIF(LTRIM(RTRIM(@Phone)), N'');   SET @Mobile = NULLIF(LTRIM(RTRIM(@Mobile)), N'');
    SET @Email   = NULLIF(LTRIM(RTRIM(@Email)), N'');   SET @Address = NULLIF(LTRIM(RTRIM(@Address)), N'');
    SET @Country = NULLIF(UPPER(LTRIM(RTRIM(@Country))), N'');
    SET @TaxRegistrationNo = NULLIF(LTRIM(RTRIM(@TaxRegistrationNo)), N'');
    SET @Notes   = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    SET @IsSupplier = ISNULL(@IsSupplier, 0); SET @IsClient = ISNULL(@IsClient, 0);
    SET @IsSalesman = ISNULL(@IsSalesman, 0); SET @IsEmployee = ISNULL(@IsEmployee, 0);
    SET @IsActive = ISNULL(@IsActive, 1);

    DECLARE @WasSupplier BIT, @WasClient BIT, @WasSalesman BIT, @WasEmployee BIT;
    SELECT @WasSupplier = IsSupplier, @WasClient = IsClient, @WasSalesman = IsSalesman, @WasEmployee = IsEmployee
    FROM masterdata.Parties WHERE Id = @Id;
    IF @WasSupplier IS NULL
        THROW 60006, 'Party not found.', 1;

    EXEC masterdata.usp_Party_Validate @Id, @PartyCode, @PartyName, @IsSupplier, @IsClient, @IsSalesman, @IsEmployee,
         @BranchId, @Email, @UserId, @ClientPriceListId, @SalesmanPriceListId, @DefaultCurrencyId;

    -- A type cannot be removed while the party is referenced in that role.
    DECLARE @Ref BIT;
    IF @WasSupplier = 1 AND @IsSupplier = 0
    BEGIN
        EXEC masterdata.usp_Party_IsReferencedAs @Id, N'Supplier', @Ref OUTPUT;
        IF @Ref = 1 THROW 60005, 'The Supplier type cannot be removed: this party is used as a supplier in existing transactions.', 1;
    END
    IF @WasClient = 1 AND @IsClient = 0
    BEGIN
        EXEC masterdata.usp_Party_IsReferencedAs @Id, N'Client', @Ref OUTPUT;
        IF @Ref = 1 THROW 60005, 'The Client type cannot be removed: this party is used as a client in existing transactions.', 1;
    END
    IF @WasSalesman = 1 AND @IsSalesman = 0
    BEGIN
        EXEC masterdata.usp_Party_IsReferencedAs @Id, N'Salesman', @Ref OUTPUT;
        IF @Ref = 1 THROW 60005, 'The Salesman type cannot be removed: this party is used as a salesman in existing transactions.', 1;
    END
    IF @WasEmployee = 1 AND @IsEmployee = 0
    BEGIN
        EXEC masterdata.usp_Party_IsReferencedAs @Id, N'Employee', @Ref OUTPUT;
        IF @Ref = 1 THROW 60005, 'The Employee type cannot be removed: this party is used as an employee in existing transactions.', 1;
    END

    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 60004, 'This party was modified by another user. Reload the page and try again.', 1;

    UPDATE masterdata.Parties
    SET PartyCode = @PartyCode, PartyName = @PartyName,
        IsSupplier = @IsSupplier, IsClient = @IsClient, IsSalesman = @IsSalesman, IsEmployee = @IsEmployee,
        BranchId = @BranchId, ContactPerson = @ContactPerson, Phone = @Phone, Mobile = @Mobile, Email = @Email,
        Address = @Address, Country = @Country, TaxRegistrationNo = @TaxRegistrationNo, Notes = @Notes,
        UserId = @UserId, ClientPriceListId = @ClientPriceListId, SalesmanPriceListId = @SalesmanPriceListId,
        DefaultCurrencyId = @DefaultCurrencyId,
        IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @ActorUserId
    WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Party_SetActive
    @Id INT, @IsActive BIT, @ActorUserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @Id)
        THROW 60006, 'Party not found.', 1;
    UPDATE masterdata.Parties SET IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @ActorUserId WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Party_Delete
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @Id)
        THROW 60006, 'Party not found.', 1;

    DECLARE @Ref BIT;
    EXEC masterdata.usp_Party_IsReferencedAs @Id, NULL, @Ref OUTPUT;
    IF @Ref = 1
        THROW 60003, 'This party cannot be deleted because it is referenced by existing transactions. You may deactivate the party instead.', 1;

    DELETE FROM masterdata.Parties WHERE Id = @Id;
END
GO

/* ------------------------------------------------------------------ 3. Permissions */

MERGE security.Permissions AS target
USING
(
    VALUES
        (N'masterdata.parties.view',   N'View parties',   N'Master Data', N'See the Parties list (suppliers, clients, salesmen, employees).', 520),
        (N'masterdata.parties.create', N'Create parties', N'Master Data', N'Add new parties.',                                                530),
        (N'masterdata.parties.edit',   N'Edit parties',   N'Master Data', N'Change parties and activate / deactivate them.',                 540),
        (N'masterdata.parties.delete', N'Delete parties', N'Master Data', N'Delete parties never referenced by transactions.',               550)
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
WHERE p.Code LIKE N'masterdata.parties.%'
  AND (r.IsSystem = 1 OR (r.Name = N'Manager' AND p.Code = N'masterdata.parties.view'))
  AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);
GO

/* ------------------------------------------------------------------ 4. Seed */

IF NOT EXISTS (SELECT 1 FROM masterdata.Parties)
BEGIN
    DECLARE @InrId INT = (SELECT TOP (1) Id FROM masterdata.Currencies WHERE CurrencyCode = N'INR' AND IsActive = 1);
    INSERT INTO masterdata.Parties (PartyCode, PartyName, IsSupplier, IsClient, IsSalesman, IsEmployee, Country, DefaultCurrencyId, IsActive, Notes)
    VALUES (N'SUP-0001', N'TVS Motor Company', 1, 0, 0, 0, N'IN', @InrId, 1, N'Principal supplier of motorcycles and spare parts.');
    PRINT 'Seeded party SUP-0001 TVS Motor Company (supplier).';
END
GO

/* ------------------------------------------------------------------ 5. Report */

SELECT Id, PartyCode, PartyName, IsSupplier, IsClient, IsSalesman, IsEmployee, Country, IsActive FROM masterdata.Parties ORDER BY PartyCode;

SELECT p.Code, STUFF((SELECT N', ' + r.Name
                      FROM security.RolePermissions rp
                      INNER JOIN security.Roles r ON r.Id = rp.RoleId
                      WHERE rp.PermissionId = p.Id
                      ORDER BY r.Name
                      FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'') AS Roles
FROM security.Permissions p
WHERE p.Code LIKE N'masterdata.parties.%'
ORDER BY p.SortOrder;

PRINT 'Master Data - Parties is ready.';
GO
