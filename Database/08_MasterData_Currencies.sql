/* =====================================================================================
   Inventory_Shipment - 08: Master Data - Currencies & Exchange Rates

   Schema:  masterdata (created if missing). One schema per module - nothing in dbo.
   Tables:  masterdata.Currencies, masterdata.ExchangeRates
   Procs:   masterdata.usp_Currency_Search / _Get / _GetBase / _Lookup / _Create / _Update /
            _SetActive / _Delete,
            masterdata.usp_ExchangeRate_Search / _Get / _GetLatest / _Create / _Update / _Delete
   Func:    masterdata.fn_GetRate (latest rate on or before a date; 1 for the base currency)
   Seeds:   permissions masterdata.currencies.* (sort 180-210) and masterdata.exchangerates.*
            (sort 220-250), module "Master Data"; currencies USD (base) / EUR / INR / CDF when
            the table is empty.

   Conventions:
     - Exactly one ACTIVE currency is the BASE currency (filtered unique index), same pattern
       as the Main Branch. Amounts are stored and reported in the base currency.
     - A rate means: 1 unit of the BASE currency = Rate units of the quoted currency
       (e.g. base USD, CDF rate 2800.000000 -> 1 USD = 2,800 CDF).
     - The base currency never has rate rows - its rate is 1 by definition.
     - RateType: 1 = Official, 2 = NonOfficial (parallel), 3 = Market.
     - One rate per (currency, type, date); a rate stays effective until a newer date exists
       (fn_GetRate takes the latest RateDate <= the asked date).
     - Future transactions must SNAPSHOT the rate they used into their own rows; deleting or
       editing a rate here never rewrites history.

   Business rules enforced here (error numbers are read by the API):
     53000  validation (required field / invalid value / future date)
     53001  Currency Code already exists
     53002  another active currency is already the Base Currency (confirm: @ReplaceBaseCurrency = 1)
     53003  currency is referenced by other records - cannot be deleted (deactivate instead)
     53004  concurrency conflict (RowVersion changed)
     53005  Base Currency protected (must stay active / cannot be demoted, deleted, or given rates)
     53006  currency / exchange rate not found
     53007  a rate for this currency, type and date already exists
     53008  currency is inactive - rates cannot be added for it

   Requires 01_Create_Schema.sql (security.Users) and 03_Security_RBAC.sql (security.Permissions).
   Idempotent - safe to run repeatedly. SQL Server 2016 SP1+.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'security.Users', N'U') IS NULL OR OBJECT_ID(N'security.Permissions', N'U') IS NULL
BEGIN
    RAISERROR ('Run 01_Create_Schema.sql and 03_Security_RBAC.sql before this script.', 16, 1);
    RETURN;
END
GO

IF SCHEMA_ID(N'masterdata') IS NULL
    EXEC (N'CREATE SCHEMA [masterdata] AUTHORIZATION [dbo];');
GO

/* ------------------------------------------------------------------ 1. Tables */

IF OBJECT_ID(N'masterdata.Currencies', N'U') IS NULL
BEGIN
    CREATE TABLE masterdata.Currencies
    (
        Id             INT IDENTITY(1,1) NOT NULL,
        CurrencyCode   NVARCHAR(3)       NOT NULL,   -- ISO 4217, stored upper-case (USD, EUR, CDF...)
        CurrencyName   NVARCHAR(100)     NOT NULL,
        Symbol         NVARCHAR(10)      NULL,       -- $, EUR sign, FC ...
        DecimalPlaces  TINYINT           NOT NULL CONSTRAINT DF_Currencies_DecimalPlaces DEFAULT (2),
        IsBaseCurrency BIT               NOT NULL CONSTRAINT DF_Currencies_IsBaseCurrency DEFAULT (0),
        IsActive       BIT               NOT NULL CONSTRAINT DF_Currencies_IsActive DEFAULT (1),
        CreatedAtUtc   DATETIME2(3)      NOT NULL CONSTRAINT DF_Currencies_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy      INT               NULL,       -- security.Users.Id
        UpdatedAtUtc   DATETIME2(3)      NULL,
        UpdatedBy      INT               NULL,       -- security.Users.Id
        RowVersion     ROWVERSION        NOT NULL,   -- optimistic concurrency
        CONSTRAINT PK_Currencies PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_Currencies_CurrencyCode UNIQUE (CurrencyCode),
        CONSTRAINT CK_Currencies_CurrencyCode_NotBlank CHECK (LEN(LTRIM(RTRIM(CurrencyCode))) > 0),
        CONSTRAINT CK_Currencies_CurrencyName_NotBlank CHECK (LEN(LTRIM(RTRIM(CurrencyName))) > 0),
        CONSTRAINT CK_Currencies_DecimalPlaces CHECK (DecimalPlaces <= 6),
        CONSTRAINT CK_Currencies_BaseIsActive CHECK (IsBaseCurrency = 0 OR IsActive = 1),  -- the base currency is always active
        CONSTRAINT FK_Currencies_CreatedBy FOREIGN KEY (CreatedBy) REFERENCES security.Users (Id),
        CONSTRAINT FK_Currencies_UpdatedBy FOREIGN KEY (UpdatedBy) REFERENCES security.Users (Id)
    );

    -- Only one active currency can be the Base Currency (same pattern as the Main Branch).
    CREATE UNIQUE NONCLUSTERED INDEX UX_Currencies_ActiveBaseCurrency
        ON masterdata.Currencies (IsBaseCurrency)
        WHERE IsBaseCurrency = 1 AND IsActive = 1;

    CREATE NONCLUSTERED INDEX IX_Currencies_CurrencyName ON masterdata.Currencies (CurrencyName);

    PRINT 'Created masterdata.Currencies';
END
GO

IF OBJECT_ID(N'masterdata.ExchangeRates', N'U') IS NULL
BEGIN
    CREATE TABLE masterdata.ExchangeRates
    (
        Id           INT IDENTITY(1,1) NOT NULL,
        CurrencyId   INT               NOT NULL,     -- the quoted currency (never the base currency)
        RateType     TINYINT           NOT NULL,     -- 1 = Official, 2 = NonOfficial, 3 = Market
        RateDate     DATE              NOT NULL,     -- effective date (no future dates)
        Rate         DECIMAL(18,6)     NOT NULL,     -- 1 base currency = Rate x this currency
        Notes        NVARCHAR(300)     NULL,         -- e.g. the market source
        CreatedAtUtc DATETIME2(3)      NOT NULL CONSTRAINT DF_ExchangeRates_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy    INT               NULL,
        UpdatedAtUtc DATETIME2(3)      NULL,
        UpdatedBy    INT               NULL,
        RowVersion   ROWVERSION        NOT NULL,
        CONSTRAINT PK_ExchangeRates PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_ExchangeRates_Currency  FOREIGN KEY (CurrencyId) REFERENCES masterdata.Currencies (Id),
        CONSTRAINT FK_ExchangeRates_CreatedBy FOREIGN KEY (CreatedBy)  REFERENCES security.Users (Id),
        CONSTRAINT FK_ExchangeRates_UpdatedBy FOREIGN KEY (UpdatedBy)  REFERENCES security.Users (Id),
        CONSTRAINT CK_ExchangeRates_RateType CHECK (RateType IN (1, 2, 3)),
        CONSTRAINT CK_ExchangeRates_Rate     CHECK (Rate > 0)
    );

    -- One rate per currency + type + day; also the covering index for latest-rate lookups.
    CREATE UNIQUE NONCLUSTERED INDEX UX_ExchangeRates_Currency_Type_Date
        ON masterdata.ExchangeRates (CurrencyId, RateType, RateDate DESC)
        INCLUDE (Rate);

    CREATE NONCLUSTERED INDEX IX_ExchangeRates_RateDate ON masterdata.ExchangeRates (RateDate);

    PRINT 'Created masterdata.ExchangeRates';
END
GO

/* ------------------------------------------------------------------ 2. Function */

-- The rate in force for a currency/type on a date: the latest RateDate <= @AsOfDate.
-- Returns 1 for the base currency and NULL when no rate has been entered yet.
CREATE OR ALTER FUNCTION masterdata.fn_GetRate
(
    @CurrencyId INT,
    @RateType   TINYINT,       -- 1 Official | 2 NonOfficial | 3 Market
    @AsOfDate   DATE
)
RETURNS DECIMAL(18,6)
AS
BEGIN
    IF EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsBaseCurrency = 1)
        RETURN 1;

    RETURN
    (
        SELECT TOP (1) Rate
        FROM masterdata.ExchangeRates
        WHERE CurrencyId = @CurrencyId AND RateType = @RateType AND RateDate <= @AsOfDate
        ORDER BY RateDate DESC
    );
END
GO

/* ------------------------------------------------------------------ 3. Currency procedures */

CREATE OR ALTER PROCEDURE masterdata.usp_Currency_Search
    @Search         NVARCHAR(100) = NULL,          -- matches Currency Code or Currency Name (contains)
    @IsActive       BIT           = NULL,          -- NULL = all
    @IsBaseCurrency BIT           = NULL,          -- NULL = all
    @SortColumn     NVARCHAR(30)  = N'CurrencyCode', -- CurrencyCode | CurrencyName | DecimalPlaces | IsBaseCurrency | IsActive | CreatedAtUtc
    @SortDirection  NVARCHAR(4)   = N'ASC',
    @PageNumber     INT           = 1,
    @PageSize       INT           = 10
AS
BEGIN
    SET NOCOUNT ON;

    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'CurrencyCode', N'CurrencyName', N'DecimalPlaces', N'IsBaseCurrency', N'IsActive', N'CreatedAtUtc')
        SET @SortColumn = N'CurrencyCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC')
        SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT c.Id, c.CurrencyCode, c.CurrencyName, c.Symbol, c.DecimalPlaces, c.IsBaseCurrency, c.IsActive,
           c.CreatedAtUtc, c.CreatedBy, c.UpdatedAtUtc, c.UpdatedBy, c.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.Currencies c
    WHERE (@Search IS NULL OR c.CurrencyCode LIKE N'%' + @Search + N'%' OR c.CurrencyName LIKE N'%' + @Search + N'%')
      AND (@IsActive IS NULL OR c.IsActive = @IsActive)
      AND (@IsBaseCurrency IS NULL OR c.IsBaseCurrency = @IsBaseCurrency)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'CurrencyCode' THEN c.CurrencyCode WHEN N'CurrencyName' THEN c.CurrencyName END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'CurrencyCode' THEN c.CurrencyCode WHEN N'CurrencyName' THEN c.CurrencyName END
        END DESC,
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'DecimalPlaces' THEN CAST(c.DecimalPlaces AS INT)
                             WHEN N'IsBaseCurrency' THEN CAST(c.IsBaseCurrency AS INT)
                             WHEN N'IsActive' THEN CAST(c.IsActive AS INT) END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'DecimalPlaces' THEN CAST(c.DecimalPlaces AS INT)
                             WHEN N'IsBaseCurrency' THEN CAST(c.IsBaseCurrency AS INT)
                             WHEN N'IsActive' THEN CAST(c.IsActive AS INT) END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN c.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN c.CreatedAtUtc END DESC,
        c.CurrencyCode ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Currency_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, CurrencyCode, CurrencyName, Symbol, DecimalPlaces, IsBaseCurrency, IsActive,
           CreatedAtUtc, CreatedBy, UpdatedAtUtc, UpdatedBy, RowVersion
    FROM masterdata.Currencies
    WHERE Id = @Id;
END
GO

-- The current active Base Currency (0 or 1 row).
CREATE OR ALTER PROCEDURE masterdata.usp_Currency_GetBase
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (1) Id, CurrencyCode, CurrencyName, Symbol, DecimalPlaces, IsBaseCurrency, IsActive,
           CreatedAtUtc, CreatedBy, UpdatedAtUtc, UpdatedBy, RowVersion
    FROM masterdata.Currencies
    WHERE IsBaseCurrency = 1 AND IsActive = 1;
END
GO

-- Dropdown data. @ActiveOnly = 1 hides inactive currencies; @IncludeId keeps one inactive row
-- visible (the value already saved on the record being edited).
CREATE OR ALTER PROCEDURE masterdata.usp_Currency_Lookup
    @ActiveOnly BIT = 1,
    @IncludeId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, CurrencyCode, CurrencyName, Symbol, DecimalPlaces, IsBaseCurrency, IsActive
    FROM masterdata.Currencies
    WHERE (@ActiveOnly = 0 OR IsActive = 1 OR Id = @IncludeId)
    ORDER BY IsBaseCurrency DESC, CurrencyCode;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Currency_Create
    @CurrencyCode        NVARCHAR(3),
    @CurrencyName        NVARCHAR(100),
    @Symbol              NVARCHAR(10) = NULL,
    @DecimalPlaces       TINYINT      = 2,
    @IsBaseCurrency      BIT          = 0,
    @IsActive            BIT          = 1,
    @ReplaceBaseCurrency BIT          = 0,    -- 1 = the caller confirmed replacing the current Base Currency
    @UserId              INT          = NULL,
    @NewId               INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @CurrencyCode  = UPPER(LTRIM(RTRIM(@CurrencyCode)));
    SET @CurrencyName  = LTRIM(RTRIM(@CurrencyName));
    SET @Symbol        = NULLIF(LTRIM(RTRIM(@Symbol)), N'');
    SET @DecimalPlaces = ISNULL(@DecimalPlaces, 2);
    SET @IsBaseCurrency = ISNULL(@IsBaseCurrency, 0);
    SET @IsActive       = ISNULL(@IsActive, 1);

    IF @CurrencyCode IS NULL OR @CurrencyCode = N''
        THROW 53000, 'Currency Code is required.', 1;

    IF LEN(@CurrencyCode) <> 3 OR @CurrencyCode LIKE N'%[^A-Z]%'
        THROW 53000, 'Currency Code must be exactly 3 letters (ISO 4217, e.g. USD).', 1;

    IF @CurrencyName IS NULL OR @CurrencyName = N''
        THROW 53000, 'Currency Name is required.', 1;

    IF @DecimalPlaces > 6
        THROW 53000, 'Decimal Places must be between 0 and 6.', 1;

    IF @IsBaseCurrency = 1 AND @IsActive = 0
        THROW 53005, 'The Base Currency must be active.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.Currencies WHERE CurrencyCode = @CurrencyCode)
        THROW 53001, 'A currency with this Currency Code already exists.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @IsBaseCurrency = 1
        BEGIN
            DECLARE @CurrentBaseId INT =
                (SELECT TOP (1) Id FROM masterdata.Currencies WITH (UPDLOCK, HOLDLOCK) WHERE IsBaseCurrency = 1 AND IsActive = 1);

            IF @CurrentBaseId IS NOT NULL
            BEGIN
                IF @ReplaceBaseCurrency = 0
                    THROW 53002, 'Another active currency is already designated as the Base Currency. Confirm to replace it.', 1;

                UPDATE masterdata.Currencies
                SET IsBaseCurrency = 0, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
                WHERE Id = @CurrentBaseId;
            END
        END

        INSERT INTO masterdata.Currencies (CurrencyCode, CurrencyName, Symbol, DecimalPlaces, IsBaseCurrency, IsActive, CreatedBy)
        VALUES (@CurrencyCode, @CurrencyName, @Symbol, @DecimalPlaces, @IsBaseCurrency, @IsActive, @UserId);

        SET @NewId = SCOPE_IDENTITY();

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Currency_Update
    @Id                  INT,
    @CurrencyCode        NVARCHAR(3),
    @CurrencyName        NVARCHAR(100),
    @Symbol              NVARCHAR(10) = NULL,
    @DecimalPlaces       TINYINT      = 2,
    @IsBaseCurrency      BIT          = 0,
    @IsActive            BIT          = 1,
    @ReplaceBaseCurrency BIT          = 0,
    @RowVersion          BINARY(8)    = NULL,   -- pass the value read earlier; NULL skips the concurrency check
    @UserId              INT          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @CurrencyCode  = UPPER(LTRIM(RTRIM(@CurrencyCode)));
    SET @CurrencyName  = LTRIM(RTRIM(@CurrencyName));
    SET @Symbol        = NULLIF(LTRIM(RTRIM(@Symbol)), N'');
    SET @DecimalPlaces = ISNULL(@DecimalPlaces, 2);
    SET @IsBaseCurrency = ISNULL(@IsBaseCurrency, 0);
    SET @IsActive       = ISNULL(@IsActive, 1);

    IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @Id)
        THROW 53006, 'Currency not found.', 1;

    IF @CurrencyCode IS NULL OR @CurrencyCode = N''
        THROW 53000, 'Currency Code is required.', 1;

    IF LEN(@CurrencyCode) <> 3 OR @CurrencyCode LIKE N'%[^A-Z]%'
        THROW 53000, 'Currency Code must be exactly 3 letters (ISO 4217, e.g. USD).', 1;

    IF @CurrencyName IS NULL OR @CurrencyName = N''
        THROW 53000, 'Currency Name is required.', 1;

    IF @DecimalPlaces > 6
        THROW 53000, 'Decimal Places must be between 0 and 6.', 1;

    IF @IsBaseCurrency = 1 AND @IsActive = 0
        THROW 53005, 'The Base Currency must be active.', 1;

    -- The base currency cannot be demoted or deactivated from here; another currency must take
    -- over the base flag first (or in the same call on that other currency with @ReplaceBaseCurrency = 1).
    IF EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @Id AND IsBaseCurrency = 1 AND IsActive = 1)
       AND (@IsBaseCurrency = 0 OR @IsActive = 0)
        THROW 53005, 'The Base Currency cannot be demoted or deactivated. Designate another currency as the Base Currency first.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.Currencies WHERE CurrencyCode = @CurrencyCode AND Id <> @Id)
        THROW 53001, 'A currency with this Currency Code already exists.', 1;

    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 53004, 'This currency was modified by another user. Reload the page and try again.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @IsBaseCurrency = 1
        BEGIN
            DECLARE @CurrentBaseId INT =
                (SELECT TOP (1) Id FROM masterdata.Currencies WITH (UPDLOCK, HOLDLOCK)
                 WHERE IsBaseCurrency = 1 AND IsActive = 1 AND Id <> @Id);

            IF @CurrentBaseId IS NOT NULL
            BEGIN
                IF @ReplaceBaseCurrency = 0
                    THROW 53002, 'Another active currency is already designated as the Base Currency. Confirm to replace it.', 1;

                UPDATE masterdata.Currencies
                SET IsBaseCurrency = 0, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
                WHERE Id = @CurrentBaseId;
            END
        END

        UPDATE masterdata.Currencies
        SET CurrencyCode   = @CurrencyCode,
            CurrencyName   = @CurrencyName,
            Symbol         = @Symbol,
            DecimalPlaces  = @DecimalPlaces,
            IsBaseCurrency = @IsBaseCurrency,
            IsActive       = @IsActive,
            UpdatedAtUtc   = SYSUTCDATETIME(),
            UpdatedBy      = @UserId
        WHERE Id = @Id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Currency_SetActive
    @Id       INT,
    @IsActive BIT,
    @UserId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @Id)
        THROW 53006, 'Currency not found.', 1;

    IF @IsActive = 0 AND EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @Id AND IsBaseCurrency = 1)
        THROW 53005, 'The Base Currency cannot be deactivated. Designate another currency as the Base Currency first.', 1;

    UPDATE masterdata.Currencies
    SET IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
END
GO

-- Physical delete, allowed only when nothing references the currency. The check reads
-- sys.foreign_keys, so exchange rates and every future table with a foreign key to
-- masterdata.Currencies (prices, invoices, payments...) are covered automatically.
CREATE OR ALTER PROCEDURE masterdata.usp_Currency_Delete
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @Id)
        THROW 53006, 'Currency not found.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @Id AND IsBaseCurrency = 1)
        THROW 53005, 'The Base Currency cannot be deleted. Designate another currency as the Base Currency first.', 1;

    DECLARE @sql NVARCHAR(MAX) = N'';

    SELECT @sql = @sql
        + N'IF @Referenced = 0 AND EXISTS (SELECT 1 FROM ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name)
        + N' WHERE ' + QUOTENAME(c.name) + N' = @Id) SET @Referenced = 1;' + NCHAR(10)
    FROM sys.foreign_keys fk
    INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    INNER JOIN sys.tables t  ON t.object_id = fk.parent_object_id
    INNER JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
    WHERE fk.referenced_object_id = OBJECT_ID(N'masterdata.Currencies');

    DECLARE @Referenced BIT = 0;

    IF @sql <> N''
        EXEC sp_executesql @sql, N'@Id INT, @Referenced BIT OUTPUT', @Id = @Id, @Referenced = @Referenced OUTPUT;

    IF @Referenced = 1
        THROW 53003, 'This currency cannot be deleted because it is referenced by other records (e.g. exchange rates). You may deactivate the currency instead.', 1;

    DELETE FROM masterdata.Currencies WHERE Id = @Id;
END
GO

/* ------------------------------------------------------------------ 4. Exchange rate procedures */

CREATE OR ALTER PROCEDURE masterdata.usp_ExchangeRate_Search
    @CurrencyId    INT          = NULL,          -- NULL = all currencies
    @RateType      TINYINT      = NULL,          -- NULL = all types (1 Official | 2 NonOfficial | 3 Market)
    @DateFrom      DATE         = NULL,
    @DateTo        DATE         = NULL,
    @SortColumn    NVARCHAR(30) = N'RateDate',   -- RateDate | CurrencyCode | RateType | Rate | CreatedAtUtc
    @SortDirection NVARCHAR(4)  = N'DESC',
    @PageNumber    INT          = 1,
    @PageSize      INT          = 10
AS
BEGIN
    SET NOCOUNT ON;

    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'RateDate', N'CurrencyCode', N'RateType', N'Rate', N'CreatedAtUtc')
        SET @SortColumn = N'RateDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC')
        SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT er.Id, er.CurrencyId, c.CurrencyCode, c.CurrencyName, c.Symbol, c.DecimalPlaces,
           er.RateType, er.RateDate, er.Rate, er.Notes,
           er.CreatedAtUtc, er.CreatedBy, er.UpdatedAtUtc, er.UpdatedBy, er.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.ExchangeRates er
    INNER JOIN masterdata.Currencies c ON c.Id = er.CurrencyId
    WHERE (@CurrencyId IS NULL OR er.CurrencyId = @CurrencyId)
      AND (@RateType   IS NULL OR er.RateType = @RateType)
      AND (@DateFrom   IS NULL OR er.RateDate >= @DateFrom)
      AND (@DateTo     IS NULL OR er.RateDate <= @DateTo)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'RateDate' THEN er.RateDate END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'RateDate' THEN er.RateDate END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CurrencyCode' THEN c.CurrencyCode END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CurrencyCode' THEN c.CurrencyCode END DESC,
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'RateType' THEN CAST(er.RateType AS INT) END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'RateType' THEN CAST(er.RateType AS INT) END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Rate' THEN er.Rate END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Rate' THEN er.Rate END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN er.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN er.CreatedAtUtc END DESC,
        er.RateDate DESC, c.CurrencyCode ASC, er.RateType ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_ExchangeRate_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT er.Id, er.CurrencyId, c.CurrencyCode, c.CurrencyName, c.Symbol, c.DecimalPlaces,
           er.RateType, er.RateDate, er.Rate, er.Notes,
           er.CreatedAtUtc, er.CreatedBy, er.UpdatedAtUtc, er.UpdatedBy, er.RowVersion
    FROM masterdata.ExchangeRates er
    INNER JOIN masterdata.Currencies c ON c.Id = er.CurrencyId
    WHERE er.Id = @Id;
END
GO

-- The rate in force per type (up to 3 rows: Official / NonOfficial / Market) for one currency,
-- as of a date (default: today, UTC).
CREATE OR ALTER PROCEDURE masterdata.usp_ExchangeRate_GetLatest
    @CurrencyId INT,
    @AsOfDate   DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @AsOfDate IS NULL SET @AsOfDate = CAST(SYSUTCDATETIME() AS DATE);

    SELECT x.Id, x.CurrencyId, c.CurrencyCode, c.CurrencyName, c.Symbol, c.DecimalPlaces,
           x.RateType, x.RateDate, x.Rate, x.Notes,
           x.CreatedAtUtc, x.CreatedBy, x.UpdatedAtUtc, x.UpdatedBy, x.RowVersion
    FROM
    (
        SELECT er.*, ROW_NUMBER() OVER (PARTITION BY er.RateType ORDER BY er.RateDate DESC) AS rn
        FROM masterdata.ExchangeRates er
        WHERE er.CurrencyId = @CurrencyId AND er.RateDate <= @AsOfDate
    ) x
    INNER JOIN masterdata.Currencies c ON c.Id = x.CurrencyId
    WHERE x.rn = 1
    ORDER BY x.RateType;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_ExchangeRate_Create
    @CurrencyId INT,
    @RateType   TINYINT,               -- 1 Official | 2 NonOfficial | 3 Market
    @RateDate   DATE,
    @Rate       DECIMAL(18,6),
    @Notes      NVARCHAR(300) = NULL,
    @UserId     INT           = NULL,
    @NewId      INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');

    IF @CurrencyId IS NULL
        THROW 53000, 'Currency is required.', 1;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId)
        THROW 53006, 'Currency not found.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsBaseCurrency = 1)
        THROW 53005, 'The Base Currency always has a rate of 1 - exchange rates are entered for the other currencies.', 1;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsActive = 1)
        THROW 53008, 'This currency is inactive. Activate it before adding exchange rates.', 1;

    IF @RateType IS NULL OR @RateType NOT IN (1, 2, 3)
        THROW 53000, 'Rate Type must be Official, Non-official or Market.', 1;

    IF @RateDate IS NULL
        THROW 53000, 'Rate Date is required.', 1;

    IF @RateDate > CAST(SYSUTCDATETIME() AS DATE)
        THROW 53000, 'Rate Date cannot be in the future.', 1;

    IF @Rate IS NULL OR @Rate <= 0
        THROW 53000, 'Rate must be greater than zero.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.ExchangeRates
               WHERE CurrencyId = @CurrencyId AND RateType = @RateType AND RateDate = @RateDate)
        THROW 53007, 'A rate for this currency, rate type and date already exists. Edit that rate instead.', 1;

    INSERT INTO masterdata.ExchangeRates (CurrencyId, RateType, RateDate, Rate, Notes, CreatedBy)
    VALUES (@CurrencyId, @RateType, @RateDate, @Rate, @Notes, @UserId);

    SET @NewId = SCOPE_IDENTITY();
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_ExchangeRate_Update
    @Id         INT,
    @CurrencyId INT,
    @RateType   TINYINT,
    @RateDate   DATE,
    @Rate       DECIMAL(18,6),
    @Notes      NVARCHAR(300) = NULL,
    @RowVersion BINARY(8)     = NULL,   -- NULL skips the concurrency check
    @UserId     INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');

    IF NOT EXISTS (SELECT 1 FROM masterdata.ExchangeRates WHERE Id = @Id)
        THROW 53006, 'Exchange rate not found.', 1;

    IF @CurrencyId IS NULL
        THROW 53000, 'Currency is required.', 1;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId)
        THROW 53006, 'Currency not found.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsBaseCurrency = 1)
        THROW 53005, 'The Base Currency always has a rate of 1 - exchange rates are entered for the other currencies.', 1;

    IF @RateType IS NULL OR @RateType NOT IN (1, 2, 3)
        THROW 53000, 'Rate Type must be Official, Non-official or Market.', 1;

    IF @RateDate IS NULL
        THROW 53000, 'Rate Date is required.', 1;

    IF @RateDate > CAST(SYSUTCDATETIME() AS DATE)
        THROW 53000, 'Rate Date cannot be in the future.', 1;

    IF @Rate IS NULL OR @Rate <= 0
        THROW 53000, 'Rate must be greater than zero.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.ExchangeRates
               WHERE CurrencyId = @CurrencyId AND RateType = @RateType AND RateDate = @RateDate AND Id <> @Id)
        THROW 53007, 'A rate for this currency, rate type and date already exists. Edit that rate instead.', 1;

    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.ExchangeRates WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 53004, 'This exchange rate was modified by another user. Reload the page and try again.', 1;

    UPDATE masterdata.ExchangeRates
    SET CurrencyId   = @CurrencyId,
        RateType     = @RateType,
        RateDate     = @RateDate,
        Rate         = @Rate,
        Notes        = @Notes,
        UpdatedAtUtc = SYSUTCDATETIME(),
        UpdatedBy    = @UserId
    WHERE Id = @Id;
END
GO

-- Rates are reference data: transactions snapshot the rate they used, so deleting a wrongly
-- entered rate is safe and allowed.
CREATE OR ALTER PROCEDURE masterdata.usp_ExchangeRate_Delete
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM masterdata.ExchangeRates WHERE Id = @Id)
        THROW 53006, 'Exchange rate not found.', 1;

    DELETE FROM masterdata.ExchangeRates WHERE Id = @Id;
END
GO

/* ------------------------------------------------------------------ 5. Permissions */

MERGE security.Permissions AS target
USING
(
    VALUES
        (N'masterdata.currencies.view',      N'View currencies',       N'Master Data', N'See the Currencies list.',                                        180),
        (N'masterdata.currencies.create',    N'Create currencies',     N'Master Data', N'Add new currencies.',                                             190),
        (N'masterdata.currencies.edit',      N'Edit currencies',       N'Master Data', N'Change currency details, the base currency and active status.',   200),
        (N'masterdata.currencies.delete',    N'Delete currencies',     N'Master Data', N'Delete currencies that are not referenced by other records.',     210),
        (N'masterdata.exchangerates.view',   N'View exchange rates',   N'Master Data', N'See the Exchange Rates page and the latest rates.',               220),
        (N'masterdata.exchangerates.create', N'Create exchange rates', N'Master Data', N'Enter official, non-official and market rates.',                  230),
        (N'masterdata.exchangerates.edit',   N'Edit exchange rates',   N'Master Data', N'Correct entered rates.',                                          240),
        (N'masterdata.exchangerates.delete', N'Delete exchange rates', N'Master Data', N'Remove wrongly entered rates.',                                   250)
) AS source (Code, Name, Module, Description, SortOrder)
ON target.Code = source.Code
WHEN MATCHED THEN
    UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Module, Description, SortOrder)
    VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder);
GO

-- System roles (Admin) hold every permission; Manager can view.
INSERT INTO security.RolePermissions (RoleId, PermissionId)
SELECT r.Id, p.Id
FROM security.Roles r
CROSS JOIN security.Permissions p
WHERE (p.Code LIKE N'masterdata.currencies.%' OR p.Code LIKE N'masterdata.exchangerates.%')
  AND (r.IsSystem = 1 OR (r.Name = N'Manager' AND p.Code IN (N'masterdata.currencies.view', N'masterdata.exchangerates.view')))
  AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);
GO

/* ------------------------------------------------------------------ 6. Seed */

IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies)
BEGIN
    INSERT INTO masterdata.Currencies (CurrencyCode, CurrencyName, Symbol, DecimalPlaces, IsBaseCurrency, IsActive)
    VALUES (N'USD', N'US Dollar',        N'$',  2, 1, 1),
           (N'EUR', N'Euro',             N'€',  2, 0, 1),
           (N'INR', N'Indian Rupee',     N'₹',  2, 0, 1),
           (N'CDF', N'Congolese Franc',  N'FC', 2, 0, 1);
    PRINT 'Seeded currencies: USD (base), EUR, INR, CDF - deactivate the ones you do not use.';
END
GO

/* ------------------------------------------------------------------ 7. Report */

SELECT Id, CurrencyCode, CurrencyName, Symbol, DecimalPlaces, IsBaseCurrency, IsActive, CreatedAtUtc
FROM masterdata.Currencies
ORDER BY IsBaseCurrency DESC, CurrencyCode;

SELECT p.Code, STUFF((SELECT N', ' + r.Name
                      FROM security.RolePermissions rp
                      INNER JOIN security.Roles r ON r.Id = rp.RoleId
                      WHERE rp.PermissionId = p.Id
                      ORDER BY r.Name
                      FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'') AS Roles
FROM security.Permissions p
WHERE p.Code LIKE N'masterdata.currencies.%' OR p.Code LIKE N'masterdata.exchangerates.%'
ORDER BY p.SortOrder;

PRINT 'Master Data - Currencies & Exchange Rates is ready.';
GO
