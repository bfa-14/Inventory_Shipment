/* =====================================================================================
   Inventory_Shipment - 12: Price Lists + Unit Price List   (user story US-MD-006)
   DATABASE ONLY (pages come later).

   Schema:  masterdata
   Tables:  masterdata.PriceLists         - header: code, name, currency, active
            masterdata.UnitPrices         - ONE current selling price per
                                            Branch (NULL = All Branches) + Item Unit + Price List
            masterdata.UnitPriceHistory   - system-generated, read-only log of every change
   Procs:   masterdata.usp_PriceList_Search / _Get / _Lookup / _Create / _Update / _SetActive / _Delete
            masterdata.usp_UnitPrice_Search / _Get / _Create / _Update / _SetActive / _Delete /
            _History / _Resolve
            inventory.usp_Item_Lookup, inventory.usp_ItemUnit_ListByItem   (grid dropdown helpers)
   Func:    masterdata.fn_GetUnitPrice (branch-specific -> all-branches -> NULL)
   Seeds:   permissions masterdata.pricelists.* (440-470) and masterdata.unitprices.* (480-510);
            price list PL-001 "Retail USD" (currency USD); a demo price for TVS-AP160 / PC when present.

   Design:
     - Currency belongs to the PRICE LIST; every price in it is in that currency. The currency of a
       price list can no longer be changed once it contains prices (58009).
     - A price row is the CURRENT price for its key; changing the price updates the row and writes a
       history record (old -> new). History survives deletion (no FK, names snapshotted).
     - Price lookup priority (fn_GetUnitPrice / usp_UnitPrice_Resolve):
         1. active price for the exact branch  2. active "All Branches" price  3. NULL (no price)
     - Keys (Branch, Item, Unit, Price List) are immutable after creation: edit changes Price/Status;
       a different key = new row. Unit must belong to the item.
     - Price DECIMAL(18,4) >= 0. Quantities are pieces; the price is per the chosen UNIT (PC, Box...).

   Error numbers (read by the API):
     Price lists: 58000 validation, 58001 duplicate code / name, 58003 referenced (delete),
                  58004 concurrency, 58006 not found, 58008 currency missing/inactive,
                  58009 currency locked (price list already has prices)
     Unit prices: 59000 validation, 59001 duplicate key (branch + item + unit + price list),
                  59004 concurrency, 59006 not found, 59007 unit does not belong to the item,
                  59008 related master data missing/inactive (branch, item, price list)

   Requires 01, 03, 06 (Branches), 08 (Currencies), 11 (Items). Idempotent. SQL Server 2016 SP1+.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'security.Users', N'U') IS NULL OR OBJECT_ID(N'masterdata.Branches', N'U') IS NULL
   OR OBJECT_ID(N'masterdata.Currencies', N'U') IS NULL OR OBJECT_ID(N'inventory.ItemUnits', N'U') IS NULL
BEGIN
    RAISERROR ('Run scripts 01, 03, 06, 08 and 11 before this script.', 16, 1);
    RETURN;
END
GO

/* ================================================================== 1. Tables */

IF OBJECT_ID(N'masterdata.PriceLists', N'U') IS NULL
BEGIN
    CREATE TABLE masterdata.PriceLists
    (
        Id            INT IDENTITY(1,1) NOT NULL,
        PriceListCode NVARCHAR(20)      NOT NULL,
        PriceListName NVARCHAR(100)     NOT NULL,
        CurrencyId    INT               NOT NULL,
        Description   NVARCHAR(500)     NULL,
        IsActive      BIT               NOT NULL CONSTRAINT DF_PriceLists_IsActive DEFAULT (1),
        CreatedAtUtc  DATETIME2(3)      NOT NULL CONSTRAINT DF_PriceLists_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy     INT               NULL,
        UpdatedAtUtc  DATETIME2(3)      NULL,
        UpdatedBy     INT               NULL,
        RowVersion    ROWVERSION        NOT NULL,
        CONSTRAINT PK_PriceLists PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_PriceLists_Code UNIQUE (PriceListCode),
        CONSTRAINT UQ_PriceLists_Name UNIQUE (PriceListName),
        CONSTRAINT CK_PriceLists_Code_NotBlank CHECK (LEN(LTRIM(RTRIM(PriceListCode))) > 0),
        CONSTRAINT CK_PriceLists_Name_NotBlank CHECK (LEN(LTRIM(RTRIM(PriceListName))) > 0),
        CONSTRAINT FK_PriceLists_Currency  FOREIGN KEY (CurrencyId) REFERENCES masterdata.Currencies (Id),
        CONSTRAINT FK_PriceLists_CreatedBy FOREIGN KEY (CreatedBy)  REFERENCES security.Users (Id),
        CONSTRAINT FK_PriceLists_UpdatedBy FOREIGN KEY (UpdatedBy)  REFERENCES security.Users (Id)
    );
    PRINT 'Created masterdata.PriceLists';
END
GO

IF OBJECT_ID(N'masterdata.UnitPrices', N'U') IS NULL
BEGIN
    CREATE TABLE masterdata.UnitPrices
    (
        Id           INT IDENTITY(1,1) NOT NULL,
        BranchId     INT               NULL,        -- NULL = All Branches
        ItemId       INT               NOT NULL,
        ItemUnitId   INT               NOT NULL,    -- must belong to ItemId (checked by the procs)
        PriceListId  INT               NOT NULL,
        Price        DECIMAL(18,4)     NOT NULL,    -- in the price list currency, per the unit
        IsActive     BIT               NOT NULL CONSTRAINT DF_UnitPrices_IsActive DEFAULT (1),
        CreatedAtUtc DATETIME2(3)      NOT NULL CONSTRAINT DF_UnitPrices_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy    INT               NULL,
        UpdatedAtUtc DATETIME2(3)      NULL,
        UpdatedBy    INT               NULL,
        RowVersion   ROWVERSION        NOT NULL,
        CONSTRAINT PK_UnitPrices PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_UnitPrices_Price CHECK (Price >= 0),
        CONSTRAINT FK_UnitPrices_Branch    FOREIGN KEY (BranchId)    REFERENCES masterdata.Branches (Id),
        CONSTRAINT FK_UnitPrices_Item      FOREIGN KEY (ItemId)      REFERENCES inventory.Items (Id),
        CONSTRAINT FK_UnitPrices_ItemUnit  FOREIGN KEY (ItemUnitId)  REFERENCES inventory.ItemUnits (Id),
        CONSTRAINT FK_UnitPrices_PriceList FOREIGN KEY (PriceListId) REFERENCES masterdata.PriceLists (Id),
        CONSTRAINT FK_UnitPrices_CreatedBy FOREIGN KEY (CreatedBy)   REFERENCES security.Users (Id),
        CONSTRAINT FK_UnitPrices_UpdatedBy FOREIGN KEY (UpdatedBy)   REFERENCES security.Users (Id)
    );

    -- One current price per Branch + Unit + Price List. NULL branches compare equal in a unique
    -- index, so this also enforces a single "All Branches" price per Unit + Price List.
    CREATE UNIQUE NONCLUSTERED INDEX UX_UnitPrices_Key
        ON masterdata.UnitPrices (ItemUnitId, PriceListId, BranchId);

    CREATE NONCLUSTERED INDEX IX_UnitPrices_Item      ON masterdata.UnitPrices (ItemId);
    CREATE NONCLUSTERED INDEX IX_UnitPrices_PriceList ON masterdata.UnitPrices (PriceListId);
    CREATE NONCLUSTERED INDEX IX_UnitPrices_Branch    ON masterdata.UnitPrices (BranchId);

    PRINT 'Created masterdata.UnitPrices';
END
GO

IF OBJECT_ID(N'masterdata.UnitPriceHistory', N'U') IS NULL
BEGIN
    CREATE TABLE masterdata.UnitPriceHistory
    (
        Id            BIGINT IDENTITY(1,1) NOT NULL,
        UnitPriceId   INT            NULL,       -- no FK on purpose: history outlives the price row
        BranchId      INT            NULL,
        BranchName    NVARCHAR(150)  NOT NULL,   -- snapshot; 'All Branches' when BranchId is NULL
        ItemId        INT            NOT NULL,
        ItemCode      NVARCHAR(30)   NOT NULL,   -- snapshot
        ItemName      NVARCHAR(200)  NOT NULL,   -- snapshot
        ItemUnitId    INT            NOT NULL,
        UnitTypeName  NVARCHAR(50)   NOT NULL,   -- snapshot
        PriceListId   INT            NOT NULL,
        PriceListName NVARCHAR(100)  NOT NULL,   -- snapshot
        CurrencyCode  NVARCHAR(3)    NOT NULL,   -- snapshot
        OldPrice      DECIMAL(18,4)  NULL,
        NewPrice      DECIMAL(18,4)  NULL,
        ChangeType    TINYINT        NOT NULL,   -- 1 Created, 2 PriceChanged, 3 Activated, 4 Deactivated, 5 Deleted
        ChangedBy     INT            NULL,
        ChangedByName NVARCHAR(100)  NOT NULL,   -- snapshot
        ChangedAtUtc  DATETIME2(3)   NOT NULL CONSTRAINT DF_UnitPriceHistory_ChangedAtUtc DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_UnitPriceHistory PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_UnitPriceHistory_ChangeType CHECK (ChangeType BETWEEN 1 AND 5),
        CONSTRAINT FK_UnitPriceHistory_ChangedBy FOREIGN KEY (ChangedBy) REFERENCES security.Users (Id)
    );

    -- History is read per key (Branch + Unit + Price List), newest first.
    CREATE NONCLUSTERED INDEX IX_UnitPriceHistory_Key
        ON masterdata.UnitPriceHistory (ItemUnitId, PriceListId, BranchId, ChangedAtUtc DESC);

    PRINT 'Created masterdata.UnitPriceHistory';
END
GO

/* ================================================================== 2. Helpers */

-- Writes one history row for a price (snapshots names so the log stays readable after deletions).
CREATE OR ALTER PROCEDURE masterdata.usp_UnitPrice_LogHistory
    @UnitPriceId INT,
    @ChangeType  TINYINT,          -- 1 Created, 2 PriceChanged, 3 Activated, 4 Deactivated, 5 Deleted
    @OldPrice    DECIMAL(18,4) = NULL,
    @NewPrice    DECIMAL(18,4) = NULL,
    @UserId      INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO masterdata.UnitPriceHistory
        (UnitPriceId, BranchId, BranchName, ItemId, ItemCode, ItemName, ItemUnitId, UnitTypeName,
         PriceListId, PriceListName, CurrencyCode, OldPrice, NewPrice, ChangeType, ChangedBy, ChangedByName)
    SELECT up.Id, up.BranchId, ISNULL(b.BranchName, N'All Branches'), up.ItemId, i.ItemCode, i.ItemName,
           up.ItemUnitId, ut.UnitTypeName, up.PriceListId, pl.PriceListName, c.CurrencyCode,
           @OldPrice, @NewPrice, @ChangeType, @UserId, ISNULL(u.FullName, N'System')
    FROM masterdata.UnitPrices up
    INNER JOIN inventory.Items i        ON i.Id  = up.ItemId
    INNER JOIN inventory.ItemUnits iu   ON iu.Id = up.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut  ON ut.Id = iu.UnitTypeId
    INNER JOIN masterdata.PriceLists pl ON pl.Id = up.PriceListId
    INNER JOIN masterdata.Currencies c  ON c.Id  = pl.CurrencyId
    LEFT  JOIN masterdata.Branches b    ON b.Id  = up.BranchId
    LEFT  JOIN security.Users u         ON u.Id  = @UserId
    WHERE up.Id = @UnitPriceId;
END
GO

-- Item search for the grid ("Search & Select Item"): code or name, active only by default.
CREATE OR ALTER PROCEDURE inventory.usp_Item_Lookup
    @Search     NVARCHAR(200) = NULL,
    @ActiveOnly BIT           = 1,
    @IncludeId  INT           = NULL,
    @Top        INT           = 20
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @Top IS NULL OR @Top < 1 SET @Top = 20;
    IF @Top > 200 SET @Top = 200;

    SELECT TOP (@Top) i.Id, i.ItemCode, i.ItemName, i.IsActive,
           ut.UnitTypeName AS BaseUnitName, bu.Id AS BaseUnitId
    FROM inventory.Items i
    LEFT JOIN inventory.ItemUnits bu    ON bu.ItemId = i.Id AND bu.IsBaseUnit = 1
    LEFT JOIN masterdata.UnitTypes ut   ON ut.Id = bu.UnitTypeId
    WHERE (@ActiveOnly = 0 OR i.IsActive = 1 OR i.Id = @IncludeId)
      AND (@Search IS NULL OR i.ItemCode LIKE N'%' + @Search + N'%' OR i.ItemName LIKE N'%' + @Search + N'%')
    ORDER BY CASE WHEN i.ItemCode LIKE @Search + N'%' THEN 0 ELSE 1 END, i.ItemCode;
END
GO

-- Units configured for one item ("Unit" dropdown): base first.
CREATE OR ALTER PROCEDURE inventory.usp_ItemUnit_ListByItem
    @ItemId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT u.Id, u.ItemId, u.UnitTypeId, ut.UnitTypeName, u.PackingFormula, u.SkuCode, u.Barcode,
           u.IsSalesUnit, u.IsPurchaseUnit, u.IsBaseUnit
    FROM inventory.ItemUnits u
    INNER JOIN masterdata.UnitTypes ut ON ut.Id = u.UnitTypeId
    WHERE u.ItemId = @ItemId
    ORDER BY u.IsBaseUnit DESC, u.PackingFormula, ut.UnitTypeName;
END
GO

/* ================================================================== 3. Price list procedures */

CREATE OR ALTER PROCEDURE masterdata.usp_PriceList_Search
    @Search        NVARCHAR(100) = NULL,          -- code or name
    @CurrencyId    INT           = NULL,
    @IsActive      BIT           = NULL,
    @SortColumn    NVARCHAR(30)  = N'PriceListCode', -- PriceListCode | PriceListName | CurrencyCode | IsActive | CreatedAtUtc
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
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'PriceListCode', N'PriceListName', N'CurrencyCode', N'IsActive', N'CreatedAtUtc')
        SET @SortColumn = N'PriceListCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT pl.Id, pl.PriceListCode, pl.PriceListName, pl.CurrencyId, c.CurrencyCode, c.CurrencyName, c.DecimalPlaces,
           pl.Description, pl.IsActive,
           PriceCount = (SELECT COUNT(*) FROM masterdata.UnitPrices up WHERE up.PriceListId = pl.Id),
           pl.CreatedAtUtc, pl.CreatedBy, pl.UpdatedAtUtc, pl.UpdatedBy, pl.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.PriceLists pl
    INNER JOIN masterdata.Currencies c ON c.Id = pl.CurrencyId
    WHERE (@Search IS NULL OR pl.PriceListCode LIKE N'%' + @Search + N'%' OR pl.PriceListName LIKE N'%' + @Search + N'%')
      AND (@CurrencyId IS NULL OR pl.CurrencyId = @CurrencyId)
      AND (@IsActive IS NULL OR pl.IsActive = @IsActive)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'PriceListCode' THEN pl.PriceListCode WHEN N'PriceListName' THEN pl.PriceListName
                             WHEN N'CurrencyCode' THEN c.CurrencyCode END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'PriceListCode' THEN pl.PriceListCode WHEN N'PriceListName' THEN pl.PriceListName
                             WHEN N'CurrencyCode' THEN c.CurrencyCode END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(pl.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(pl.IsActive AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN pl.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN pl.CreatedAtUtc END DESC,
        pl.PriceListCode ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_PriceList_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT pl.Id, pl.PriceListCode, pl.PriceListName, pl.CurrencyId, c.CurrencyCode, c.CurrencyName, c.DecimalPlaces,
           pl.Description, pl.IsActive,
           PriceCount = (SELECT COUNT(*) FROM masterdata.UnitPrices up WHERE up.PriceListId = pl.Id),
           pl.CreatedAtUtc, pl.CreatedBy, pl.UpdatedAtUtc, pl.UpdatedBy, pl.RowVersion
    FROM masterdata.PriceLists pl
    INNER JOIN masterdata.Currencies c ON c.Id = pl.CurrencyId
    WHERE pl.Id = @Id;
END
GO

-- Dropdown data ("Price List" -> currency auto-displayed).
CREATE OR ALTER PROCEDURE masterdata.usp_PriceList_Lookup
    @ActiveOnly BIT = 1,
    @IncludeId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT pl.Id, pl.PriceListCode, pl.PriceListName, pl.CurrencyId, c.CurrencyCode, c.Symbol, c.DecimalPlaces, pl.IsActive
    FROM masterdata.PriceLists pl
    INNER JOIN masterdata.Currencies c ON c.Id = pl.CurrencyId
    WHERE (@ActiveOnly = 0 OR pl.IsActive = 1 OR pl.Id = @IncludeId)
    ORDER BY pl.PriceListName;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_PriceList_Create
    @PriceListCode NVARCHAR(20),
    @PriceListName NVARCHAR(100),
    @CurrencyId    INT,
    @Description   NVARCHAR(500) = NULL,
    @IsActive      BIT           = 1,
    @UserId        INT           = NULL,
    @NewId         INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @PriceListCode = LTRIM(RTRIM(@PriceListCode));
    SET @PriceListName = LTRIM(RTRIM(@PriceListName));
    SET @Description   = NULLIF(LTRIM(RTRIM(@Description)), N'');
    SET @IsActive      = ISNULL(@IsActive, 1);

    IF @PriceListCode IS NULL OR @PriceListCode = N'' THROW 58000, 'Price List Code is required.', 1;
    IF @PriceListName IS NULL OR @PriceListName = N'' THROW 58000, 'Price List Name is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsActive = 1)
        THROW 58008, 'Currency not found or inactive.', 1;
    IF EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE PriceListCode = @PriceListCode)
        THROW 58001, 'A price list with this code already exists.', 1;
    IF EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE PriceListName = @PriceListName)
        THROW 58001, 'A price list with this name already exists.', 1;

    INSERT INTO masterdata.PriceLists (PriceListCode, PriceListName, CurrencyId, Description, IsActive, CreatedBy)
    VALUES (@PriceListCode, @PriceListName, @CurrencyId, @Description, @IsActive, @UserId);

    SET @NewId = SCOPE_IDENTITY();
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_PriceList_Update
    @Id            INT,
    @PriceListCode NVARCHAR(20),
    @PriceListName NVARCHAR(100),
    @CurrencyId    INT,
    @Description   NVARCHAR(500) = NULL,
    @IsActive      BIT           = 1,
    @RowVersion    BINARY(8)     = NULL,
    @UserId        INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @PriceListCode = LTRIM(RTRIM(@PriceListCode));
    SET @PriceListName = LTRIM(RTRIM(@PriceListName));
    SET @Description   = NULLIF(LTRIM(RTRIM(@Description)), N'');
    SET @IsActive      = ISNULL(@IsActive, 1);

    IF NOT EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE Id = @Id)
        THROW 58006, 'Price list not found.', 1;
    IF @PriceListCode IS NULL OR @PriceListCode = N'' THROW 58000, 'Price List Code is required.', 1;
    IF @PriceListName IS NULL OR @PriceListName = N'' THROW 58000, 'Price List Name is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsActive = 1)
        THROW 58008, 'Currency not found or inactive.', 1;
    IF EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE PriceListCode = @PriceListCode AND Id <> @Id)
        THROW 58001, 'A price list with this code already exists.', 1;
    IF EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE PriceListName = @PriceListName AND Id <> @Id)
        THROW 58001, 'A price list with this name already exists.', 1;

    -- The currency is locked once prices exist (all its prices are expressed in it).
    IF EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE Id = @Id AND CurrencyId <> @CurrencyId)
       AND EXISTS (SELECT 1 FROM masterdata.UnitPrices WHERE PriceListId = @Id)
        THROW 58009, 'The currency cannot be changed because this price list already contains prices. Create a new price list instead.', 1;

    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 58004, 'This price list was modified by another user. Reload the page and try again.', 1;

    UPDATE masterdata.PriceLists
    SET PriceListCode = @PriceListCode, PriceListName = @PriceListName, CurrencyId = @CurrencyId,
        Description = @Description, IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_PriceList_SetActive
    @Id INT, @IsActive BIT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE Id = @Id)
        THROW 58006, 'Price list not found.', 1;
    UPDATE masterdata.PriceLists SET IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;
END
GO

-- Delete only when the list holds no prices and nothing else references it.
CREATE OR ALTER PROCEDURE masterdata.usp_PriceList_Delete
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE Id = @Id)
        THROW 58006, 'Price list not found.', 1;

    DECLARE @sql NVARCHAR(MAX) = N'';
    SELECT @sql = @sql
        + N'IF @Referenced = 0 AND EXISTS (SELECT 1 FROM ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name)
        + N' WHERE ' + QUOTENAME(c.name) + N' = @Id) SET @Referenced = 1;' + NCHAR(10)
    FROM sys.foreign_keys fk
    INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    INNER JOIN sys.tables t  ON t.object_id = fk.parent_object_id
    INNER JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
    WHERE fk.referenced_object_id = OBJECT_ID(N'masterdata.PriceLists');

    DECLARE @Referenced BIT = 0;
    IF @sql <> N'' EXEC sp_executesql @sql, N'@Id INT, @Referenced BIT OUTPUT', @Id = @Id, @Referenced = @Referenced OUTPUT;
    IF @Referenced = 1
        THROW 58003, 'This price list cannot be deleted because it contains prices or is referenced by other records. You may deactivate it instead.', 1;

    DELETE FROM masterdata.PriceLists WHERE Id = @Id;
END
GO

/* ================================================================== 4. Unit price procedures */

CREATE OR ALTER PROCEDURE masterdata.usp_UnitPrice_Search
    @Search          NVARCHAR(200) = NULL,   -- Item Code or Item Name
    @BranchId        INT           = NULL,   -- a branch: its rows only; NULL: no branch filter
    @AllBranchesOnly BIT           = 0,      -- 1: only "All Branches" rows (BranchId IS NULL)
    @PriceListId     INT           = NULL,
    @ItemFamilyId    INT           = NULL,   -- family and its whole subtree
    @BaseUnitTypeId  INT           = NULL,   -- "Basic Unit" filter: the item's base unit type
    @UnitTypeId      INT           = NULL,   -- "Unit" filter: the priced unit's type
    @IsActive        BIT           = NULL,
    @SortColumn      NVARCHAR(30)  = N'ItemCode', -- ItemCode | ItemName | BranchName | UnitTypeName | PriceListName | Price | IsActive | UpdatedAtUtc
    @SortDirection   NVARCHAR(4)   = N'ASC',
    @PageNumber      INT           = 1,
    @PageSize        INT           = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'ItemCode', N'ItemName', N'BranchName', N'UnitTypeName', N'PriceListName', N'Price', N'IsActive', N'UpdatedAtUtc')
        SET @SortColumn = N'ItemCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT up.Id, up.BranchId, b.BranchCode, ISNULL(b.BranchName, N'All Branches') AS BranchName,
           up.ItemId, i.ItemCode, i.ItemName, but.UnitTypeName AS BaseUnitName,
           up.ItemUnitId, iu.UnitTypeId, ut.UnitTypeName, iu.PackingFormula, iu.SkuCode,
           up.PriceListId, pl.PriceListCode, pl.PriceListName,
           pl.CurrencyId, c.CurrencyCode, c.Symbol, c.DecimalPlaces,
           up.Price, up.IsActive,
           up.CreatedAtUtc, up.CreatedBy, up.UpdatedAtUtc, up.UpdatedBy, up.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.UnitPrices up
    INNER JOIN inventory.Items i        ON i.Id   = up.ItemId
    INNER JOIN inventory.ItemUnits iu   ON iu.Id  = up.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut  ON ut.Id  = iu.UnitTypeId
    INNER JOIN masterdata.PriceLists pl ON pl.Id  = up.PriceListId
    INNER JOIN masterdata.Currencies c  ON c.Id   = pl.CurrencyId
    LEFT  JOIN masterdata.Branches b    ON b.Id   = up.BranchId
    LEFT  JOIN inventory.ItemUnits bu   ON bu.ItemId = i.Id AND bu.IsBaseUnit = 1
    LEFT  JOIN masterdata.UnitTypes but ON but.Id = bu.UnitTypeId
    WHERE (@Search IS NULL OR i.ItemCode LIKE N'%' + @Search + N'%' OR i.ItemName LIKE N'%' + @Search + N'%')
      AND (@BranchId IS NULL OR up.BranchId = @BranchId)
      AND (@AllBranchesOnly = 0 OR up.BranchId IS NULL)
      AND (@PriceListId IS NULL OR up.PriceListId = @PriceListId)
      AND (@ItemFamilyId IS NULL OR i.ItemFamilyId IN (SELECT Id FROM masterdata.fn_ItemFamily_Subtree(@ItemFamilyId)))
      AND (@BaseUnitTypeId IS NULL OR bu.UnitTypeId = @BaseUnitTypeId)
      AND (@UnitTypeId IS NULL OR iu.UnitTypeId = @UnitTypeId)
      AND (@IsActive IS NULL OR up.IsActive = @IsActive)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'ItemCode' THEN i.ItemCode WHEN N'ItemName' THEN i.ItemName
                             WHEN N'BranchName' THEN ISNULL(b.BranchName, N'') WHEN N'UnitTypeName' THEN ut.UnitTypeName
                             WHEN N'PriceListName' THEN pl.PriceListName END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'ItemCode' THEN i.ItemCode WHEN N'ItemName' THEN i.ItemName
                             WHEN N'BranchName' THEN ISNULL(b.BranchName, N'') WHEN N'UnitTypeName' THEN ut.UnitTypeName
                             WHEN N'PriceListName' THEN pl.PriceListName END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Price' THEN up.Price END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Price' THEN up.Price END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(up.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(up.IsActive AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'UpdatedAtUtc' THEN ISNULL(up.UpdatedAtUtc, up.CreatedAtUtc) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'UpdatedAtUtc' THEN ISNULL(up.UpdatedAtUtc, up.CreatedAtUtc) END DESC,
        i.ItemCode ASC, pl.PriceListName ASC, ut.UnitTypeName ASC, ISNULL(b.BranchName, N'') ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_UnitPrice_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT up.Id, up.BranchId, b.BranchCode, ISNULL(b.BranchName, N'All Branches') AS BranchName,
           up.ItemId, i.ItemCode, i.ItemName, but.UnitTypeName AS BaseUnitName,
           up.ItemUnitId, iu.UnitTypeId, ut.UnitTypeName, iu.PackingFormula, iu.SkuCode,
           up.PriceListId, pl.PriceListCode, pl.PriceListName,
           pl.CurrencyId, c.CurrencyCode, c.Symbol, c.DecimalPlaces,
           up.Price, up.IsActive,
           up.CreatedAtUtc, up.CreatedBy, up.UpdatedAtUtc, up.UpdatedBy, up.RowVersion
    FROM masterdata.UnitPrices up
    INNER JOIN inventory.Items i        ON i.Id   = up.ItemId
    INNER JOIN inventory.ItemUnits iu   ON iu.Id  = up.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut  ON ut.Id  = iu.UnitTypeId
    INNER JOIN masterdata.PriceLists pl ON pl.Id  = up.PriceListId
    INNER JOIN masterdata.Currencies c  ON c.Id   = pl.CurrencyId
    LEFT  JOIN masterdata.Branches b    ON b.Id   = up.BranchId
    LEFT  JOIN inventory.ItemUnits bu   ON bu.ItemId = i.Id AND bu.IsBaseUnit = 1
    LEFT  JOIN masterdata.UnitTypes but ON but.Id = bu.UnitTypeId
    WHERE up.Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_UnitPrice_Create
    @BranchId    INT           = NULL,   -- NULL = All Branches
    @ItemId      INT,
    @ItemUnitId  INT,
    @PriceListId INT,
    @Price       DECIMAL(18,4),
    @IsActive    BIT           = 1,
    @UserId      INT           = NULL,
    @NewId       INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @IsActive = ISNULL(@IsActive, 1);

    IF @BranchId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 59008, 'Branch not found or inactive.', 1;
    IF @ItemId IS NULL THROW 59000, 'Item is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM inventory.Items WHERE Id = @ItemId AND IsActive = 1)
        THROW 59008, 'Item not found or inactive.', 1;
    IF @ItemUnitId IS NULL THROW 59000, 'Unit is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM inventory.ItemUnits WHERE Id = @ItemUnitId AND ItemId = @ItemId)
        THROW 59007, 'The selected unit does not belong to the selected item.', 1;
    IF @PriceListId IS NULL THROW 59000, 'Price List is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE Id = @PriceListId AND IsActive = 1)
        THROW 59008, 'Price list not found or inactive.', 1;
    IF @Price IS NULL THROW 59000, 'Price is required.', 1;
    IF @Price < 0 THROW 59000, 'Price cannot be negative.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.UnitPrices
               WHERE ItemUnitId = @ItemUnitId AND PriceListId = @PriceListId
                 AND ((BranchId IS NULL AND @BranchId IS NULL) OR BranchId = @BranchId))
        THROW 59001, 'A price already exists for this branch, item, unit, and price list. Please edit the existing record instead.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO masterdata.UnitPrices (BranchId, ItemId, ItemUnitId, PriceListId, Price, IsActive, CreatedBy)
        VALUES (@BranchId, @ItemId, @ItemUnitId, @PriceListId, @Price, @IsActive, @UserId);

        SET @NewId = SCOPE_IDENTITY();

        EXEC masterdata.usp_UnitPrice_LogHistory @UnitPriceId = @NewId, @ChangeType = 1, @OldPrice = NULL, @NewPrice = @Price, @UserId = @UserId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Keys (branch / item / unit / price list) are immutable: edit changes Price and/or Status only.
CREATE OR ALTER PROCEDURE masterdata.usp_UnitPrice_Update
    @Id         INT,
    @Price      DECIMAL(18,4),
    @IsActive   BIT       = NULL,   -- NULL = leave unchanged
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @OldPrice DECIMAL(18,4), @OldActive BIT;
    SELECT @OldPrice = Price, @OldActive = IsActive FROM masterdata.UnitPrices WHERE Id = @Id;

    IF @OldPrice IS NULL
        THROW 59006, 'Unit price not found.', 1;
    IF @Price IS NULL THROW 59000, 'Price is required.', 1;
    IF @Price < 0 THROW 59000, 'Price cannot be negative.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.UnitPrices WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 59004, 'This price was modified by another user. Reload the page and try again.', 1;

    SET @IsActive = ISNULL(@IsActive, @OldActive);

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE masterdata.UnitPrices
        SET Price = @Price, IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        IF @Price <> @OldPrice
            EXEC masterdata.usp_UnitPrice_LogHistory @UnitPriceId = @Id, @ChangeType = 2, @OldPrice = @OldPrice, @NewPrice = @Price, @UserId = @UserId;

        IF @IsActive <> @OldActive
        BEGIN
            DECLARE @StatusType TINYINT = CASE WHEN @IsActive = 1 THEN 3 ELSE 4 END;
            EXEC masterdata.usp_UnitPrice_LogHistory @UnitPriceId = @Id, @ChangeType = @StatusType, @OldPrice = @Price, @NewPrice = @Price, @UserId = @UserId;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_UnitPrice_SetActive
    @Id       INT,
    @IsActive BIT,
    @UserId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Price DECIMAL(18,4), @OldActive BIT;
    SELECT @Price = Price, @OldActive = IsActive FROM masterdata.UnitPrices WHERE Id = @Id;
    IF @Price IS NULL
        THROW 59006, 'Unit price not found.', 1;
    IF @OldActive = @IsActive
        RETURN;

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE masterdata.UnitPrices SET IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;

        DECLARE @StatusType TINYINT = CASE WHEN @IsActive = 1 THEN 3 ELSE 4 END;
        EXEC masterdata.usp_UnitPrice_LogHistory @UnitPriceId = @Id, @ChangeType = @StatusType, @OldPrice = @Price, @NewPrice = @Price, @UserId = @UserId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Physical delete is allowed (transactions snapshot the price they used); the deletion is logged first.
CREATE OR ALTER PROCEDURE masterdata.usp_UnitPrice_Delete
    @Id     INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Price DECIMAL(18,4) = (SELECT Price FROM masterdata.UnitPrices WHERE Id = @Id);
    IF @Price IS NULL
        THROW 59006, 'Unit price not found.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        EXEC masterdata.usp_UnitPrice_LogHistory @UnitPriceId = @Id, @ChangeType = 5, @OldPrice = @Price, @NewPrice = NULL, @UserId = @UserId;
        DELETE FROM masterdata.UnitPrices WHERE Id = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- History of one key (Branch + Item Unit + Price List), newest first. Pass @UnitPriceId for an existing
-- row, or the key columns directly (works even after the row was deleted).
CREATE OR ALTER PROCEDURE masterdata.usp_UnitPrice_History
    @UnitPriceId INT = NULL,
    @ItemUnitId  INT = NULL,
    @PriceListId INT = NULL,
    @BranchId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @UnitPriceId IS NOT NULL
        SELECT @ItemUnitId = ItemUnitId, @PriceListId = PriceListId, @BranchId = BranchId
        FROM masterdata.UnitPrices WHERE Id = @UnitPriceId;

    IF @ItemUnitId IS NULL OR @PriceListId IS NULL
        THROW 59000, 'Item unit and price list are required to read the price history.', 1;

    SELECT h.Id, h.UnitPriceId, h.BranchId, h.BranchName, h.ItemId, h.ItemCode, h.ItemName,
           h.ItemUnitId, h.UnitTypeName, h.PriceListId, h.PriceListName, h.CurrencyCode,
           h.OldPrice, h.NewPrice, h.ChangeType,
           CASE h.ChangeType WHEN 1 THEN N'Created' WHEN 2 THEN N'Price Changed' WHEN 3 THEN N'Activated'
                             WHEN 4 THEN N'Deactivated' WHEN 5 THEN N'Deleted' END AS ChangeTypeName,
           h.ChangedBy, h.ChangedByName, h.ChangedAtUtc
    FROM masterdata.UnitPriceHistory h
    WHERE h.ItemUnitId = @ItemUnitId AND h.PriceListId = @PriceListId
      AND ((h.BranchId IS NULL AND @BranchId IS NULL) OR h.BranchId = @BranchId)
    ORDER BY h.ChangedAtUtc DESC, h.Id DESC;
END
GO

/* ================================================================== 5. Price resolution (for sales / invoices later) */

-- Selling price for a unit on a price list at a branch:
-- 1. active branch-specific price  2. active "All Branches" price  3. NULL (no price defined).
CREATE OR ALTER FUNCTION masterdata.fn_GetUnitPrice
(
    @ItemUnitId  INT,
    @PriceListId INT,
    @BranchId    INT      -- NULL = look only at the "All Branches" price
)
RETURNS DECIMAL(18,4)
AS
BEGIN
    DECLARE @Price DECIMAL(18,4);

    IF @BranchId IS NOT NULL
        SELECT @Price = Price FROM masterdata.UnitPrices
        WHERE ItemUnitId = @ItemUnitId AND PriceListId = @PriceListId AND BranchId = @BranchId AND IsActive = 1;

    IF @Price IS NULL
        SELECT @Price = Price FROM masterdata.UnitPrices
        WHERE ItemUnitId = @ItemUnitId AND PriceListId = @PriceListId AND BranchId IS NULL AND IsActive = 1;

    RETURN @Price;
END
GO

-- Same rule, returning the full row + where it came from (0 or 1 row). The API answers
-- "No price is defined for the selected item, unit, price list, and branch." when empty.
CREATE OR ALTER PROCEDURE masterdata.usp_UnitPrice_Resolve
    @ItemUnitId  INT,
    @PriceListId INT,
    @BranchId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP (1) up.Id, up.BranchId, ISNULL(b.BranchName, N'All Branches') AS BranchName,
           up.ItemId, i.ItemCode, i.ItemName, up.ItemUnitId, ut.UnitTypeName, iu.PackingFormula,
           up.PriceListId, pl.PriceListName, pl.CurrencyId, c.CurrencyCode, c.DecimalPlaces, up.Price,
           CASE WHEN up.BranchId IS NULL THEN N'AllBranches' ELSE N'Branch' END AS PriceSource
    FROM masterdata.UnitPrices up
    INNER JOIN inventory.Items i        ON i.Id  = up.ItemId
    INNER JOIN inventory.ItemUnits iu   ON iu.Id = up.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut  ON ut.Id = iu.UnitTypeId
    INNER JOIN masterdata.PriceLists pl ON pl.Id = up.PriceListId
    INNER JOIN masterdata.Currencies c  ON c.Id  = pl.CurrencyId
    LEFT  JOIN masterdata.Branches b    ON b.Id  = up.BranchId
    WHERE up.ItemUnitId = @ItemUnitId AND up.PriceListId = @PriceListId AND up.IsActive = 1
      AND (up.BranchId = @BranchId OR up.BranchId IS NULL)
    ORDER BY CASE WHEN up.BranchId IS NULL THEN 1 ELSE 0 END;   -- branch-specific wins
END
GO

/* ================================================================== 6. Permissions */

MERGE security.Permissions AS target
USING
(
    VALUES
        (N'masterdata.pricelists.view',   N'View price lists',   N'Master Data', N'See the Price Lists page.',                                   440),
        (N'masterdata.pricelists.create', N'Create price lists', N'Master Data', N'Add new price lists.',                                        450),
        (N'masterdata.pricelists.edit',   N'Edit price lists',   N'Master Data', N'Change price lists and activate / deactivate them.',          460),
        (N'masterdata.pricelists.delete', N'Delete price lists', N'Master Data', N'Delete empty price lists.',                                   470),
        (N'masterdata.unitprices.view',   N'View unit prices',   N'Master Data', N'See the Unit Price List and price history.',                  480),
        (N'masterdata.unitprices.create', N'Create unit prices', N'Master Data', N'Add prices for item units.',                                  490),
        (N'masterdata.unitprices.edit',   N'Edit unit prices',   N'Master Data', N'Change prices and activate / deactivate them (logged).',      500),
        (N'masterdata.unitprices.delete', N'Delete unit prices', N'Master Data', N'Delete prices (logged in the price history).',                510)
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
WHERE (p.Code LIKE N'masterdata.pricelists.%' OR p.Code LIKE N'masterdata.unitprices.%')
  AND (r.IsSystem = 1 OR (r.Name = N'Manager' AND p.Code IN (N'masterdata.pricelists.view', N'masterdata.unitprices.view')))
  AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);
GO

/* ================================================================== 7. Seeds */

IF NOT EXISTS (SELECT 1 FROM masterdata.PriceLists)
BEGIN
    DECLARE @UsdId INT = (SELECT TOP (1) Id FROM masterdata.Currencies WHERE CurrencyCode = N'USD' AND IsActive = 1);
    IF @UsdId IS NOT NULL
    BEGIN
        INSERT INTO masterdata.PriceLists (PriceListCode, PriceListName, CurrencyId, Description, IsActive)
        VALUES (N'PL-001', N'Retail USD', @UsdId, N'Default retail selling prices in US Dollars', 1);
        PRINT 'Seeded price list PL-001 Retail USD';
    END
END
GO

-- Demo price (All Branches) for the demo item's base unit, when everything it needs exists.
IF NOT EXISTS (SELECT 1 FROM masterdata.UnitPrices)
BEGIN
    DECLARE @ItemId INT = (SELECT TOP (1) Id FROM inventory.Items WHERE ItemCode = N'TVS-AP160' AND IsActive = 1);
    DECLARE @UnitId INT = (SELECT TOP (1) Id FROM inventory.ItemUnits WHERE ItemId = @ItemId AND IsBaseUnit = 1);
    DECLARE @PlId   INT = (SELECT TOP (1) Id FROM masterdata.PriceLists WHERE PriceListCode = N'PL-001' AND IsActive = 1);

    IF @ItemId IS NOT NULL AND @UnitId IS NOT NULL AND @PlId IS NOT NULL
    BEGIN
        DECLARE @NewId INT;
        EXEC masterdata.usp_UnitPrice_Create @BranchId = NULL, @ItemId = @ItemId, @ItemUnitId = @UnitId,
             @PriceListId = @PlId, @Price = 2500.0000, @IsActive = 1, @UserId = NULL, @NewId = @NewId OUTPUT;
        PRINT 'Seeded demo price: TVS-AP160 / PC / Retail USD / All Branches = 2,500.00 (history row written).';
    END
END
GO

/* ================================================================== 8. Report */

SELECT pl.PriceListCode, pl.PriceListName, c.CurrencyCode, pl.IsActive
FROM masterdata.PriceLists pl INNER JOIN masterdata.Currencies c ON c.Id = pl.CurrencyId ORDER BY pl.PriceListCode;

EXEC masterdata.usp_UnitPrice_Search @PageSize = 20;

SELECT TOP (10) ChangedAtUtc, BranchName, ItemCode, UnitTypeName, PriceListName, OldPrice, NewPrice, ChangeType, ChangedByName
FROM masterdata.UnitPriceHistory ORDER BY Id DESC;

SELECT p.Code, STUFF((SELECT N', ' + r.Name
                      FROM security.RolePermissions rp
                      INNER JOIN security.Roles r ON r.Id = rp.RoleId
                      WHERE rp.PermissionId = p.Id
                      ORDER BY r.Name
                      FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'') AS Roles
FROM security.Permissions p
WHERE p.Code LIKE N'masterdata.pricelists.%' OR p.Code LIKE N'masterdata.unitprices.%'
ORDER BY p.SortOrder;

PRINT 'Price Lists + Unit Price List database objects are ready.';
GO
