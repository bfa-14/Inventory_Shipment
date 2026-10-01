/* ==================================================================================================
   39: Global settings - the "ViewLookup" pattern
   --------------------------------------------------------------------------------------------------
   ONE PLACE for every system-wide setting, so a new setting is a row, not a table, a screen and an
   endpoint.

     configuration.SettingDefinitions  WHAT a setting is: key, group, label, type, default, limits.
                                       Owned by the application (scripts add rows); never edited by users.
     configuration.SettingValues       WHAT the administrator chose. A row exists only while the choice
                                       differs from the default - no row means "use the default".
     configuration.SettingChanges      Who changed which setting, from what to what, and when.

   VIEW   usp_Setting_List     every setting with its effective value, for the Settings page, or only
                               the public ones, for the lookup any signed-in screen may read.
   SAVE   usp_Setting_Save     validates the value against the setting's type and limits, stores it.
   RESET  usp_Setting_Reset    drops the choice; the default applies again.
   READ   fn_SettingValue      the effective value as text, for use INSIDE other procedures.
          fn_SettingBool       the same, as a bit (true / 1 / yes = 1). An unknown key reads as 0.

   Types: bool, int, decimal, text. Values are stored as normalised text (bool: 'true' / 'false').

   A setting that also varies by something narrower (a warehouse, a branch) keeps its OWN override
   column or table beside this one and resolves override -> global -> default in the procedure that
   needs it. This script is the global level.

   Errors 72000-72999:  72000 validation   72006 setting not found
   Idempotent. Seeds no settings: each feature adds its own definition when it ships.
   ================================================================================================== */

IF SCHEMA_ID(N'configuration') IS NULL EXEC (N'CREATE SCHEMA configuration AUTHORIZATION dbo');
GO

IF OBJECT_ID(N'configuration.SettingDefinitions', N'U') IS NULL
BEGIN
    CREATE TABLE configuration.SettingDefinitions
    (
        SettingKey   NVARCHAR(100)  NOT NULL,                -- 'Sales.AllowOutOfStock': Area.Name, unique
        GroupName    NVARCHAR(60)   NOT NULL,                -- the heading it sits under on the page
        Label        NVARCHAR(150)  NOT NULL,
        Description  NVARCHAR(500)  NULL,
        ValueType    NVARCHAR(10)   NOT NULL,                -- bool | int | decimal | text
        DefaultValue NVARCHAR(400)  NOT NULL,
        MinValue     DECIMAL(18,4)  NULL,                    -- int / decimal only
        MaxValue     DECIMAL(18,4)  NULL,
        IsPublic     BIT            NOT NULL CONSTRAINT DF_SettingDefinitions_IsPublic DEFAULT (0),   -- readable by any signed-in user
        SortOrder    INT            NOT NULL CONSTRAINT DF_SettingDefinitions_SortOrder DEFAULT (100),
        CONSTRAINT PK_SettingDefinitions PRIMARY KEY CLUSTERED (SettingKey),
        CONSTRAINT CK_SettingDefinitions_ValueType CHECK (ValueType IN (N'bool', N'int', N'decimal', N'text')),
        CONSTRAINT CK_SettingDefinitions_Key_NotBlank CHECK (LEN(LTRIM(RTRIM(SettingKey))) > 0)
    );
END
GO

IF OBJECT_ID(N'configuration.SettingValues', N'U') IS NULL
BEGIN
    CREATE TABLE configuration.SettingValues
    (
        SettingKey   NVARCHAR(100)  NOT NULL,
        Value        NVARCHAR(400)  NOT NULL,
        UpdatedAtUtc DATETIME2(3)   NOT NULL CONSTRAINT DF_SettingValues_UpdatedAtUtc DEFAULT (SYSUTCDATETIME()),
        UpdatedBy    INT            NULL,
        CONSTRAINT PK_SettingValues PRIMARY KEY CLUSTERED (SettingKey),
        CONSTRAINT FK_SettingValues_Definitions FOREIGN KEY (SettingKey) REFERENCES configuration.SettingDefinitions (SettingKey) ON DELETE CASCADE,
        CONSTRAINT FK_SettingValues_UpdatedBy   FOREIGN KEY (UpdatedBy)  REFERENCES security.Users (Id)
    );
END
GO

IF OBJECT_ID(N'configuration.SettingChanges', N'U') IS NULL
BEGIN
    CREATE TABLE configuration.SettingChanges
    (
        Id           INT IDENTITY(1,1) NOT NULL,
        SettingKey   NVARCHAR(100)  NOT NULL,
        Action       NVARCHAR(10)   NOT NULL,                -- Set | Reset
        OldValue     NVARCHAR(400)  NULL,                    -- the effective value before
        NewValue     NVARCHAR(400)  NULL,                    -- the effective value after
        ChangedAtUtc DATETIME2(3)   NOT NULL CONSTRAINT DF_SettingChanges_ChangedAtUtc DEFAULT (SYSUTCDATETIME()),
        ChangedBy    INT            NULL,
        CONSTRAINT PK_SettingChanges PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_SettingChanges_ChangedBy FOREIGN KEY (ChangedBy) REFERENCES security.Users (Id)
    );
    CREATE INDEX IX_SettingChanges_Key ON configuration.SettingChanges (SettingKey, Id DESC);
END
GO

/* -- reading a setting from inside other procedures --------------------------------------------- */

CREATE OR ALTER FUNCTION configuration.fn_SettingValue (@SettingKey NVARCHAR(100))
RETURNS NVARCHAR(400)
AS
BEGIN
    RETURN (SELECT ISNULL(v.Value, d.DefaultValue)
            FROM configuration.SettingDefinitions d
            LEFT JOIN configuration.SettingValues v ON v.SettingKey = d.SettingKey
            WHERE d.SettingKey = @SettingKey);
END
GO

CREATE OR ALTER FUNCTION configuration.fn_SettingBool (@SettingKey NVARCHAR(100))
RETURNS BIT
AS
BEGIN
    RETURN CASE WHEN LOWER(ISNULL(configuration.fn_SettingValue(@SettingKey), N'')) IN (N'true', N'1', N'yes') THEN 1 ELSE 0 END;
END
GO

/* -- the view ----------------------------------------------------------------------------------- */

CREATE OR ALTER PROCEDURE configuration.usp_Setting_List
    @OnlyPublic BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.SettingKey, d.GroupName, d.Label, d.Description, d.ValueType, d.DefaultValue, d.MinValue, d.MaxValue,
           d.IsPublic, d.SortOrder,
           Value     = ISNULL(v.Value, d.DefaultValue),
           IsDefault = CAST(CASE WHEN v.SettingKey IS NULL THEN 1 ELSE 0 END AS BIT),
           UpdatedAtUtc = v.UpdatedAtUtc,
           UpdatedByName = u.FullName
    FROM configuration.SettingDefinitions d
    LEFT JOIN configuration.SettingValues v ON v.SettingKey = d.SettingKey
    LEFT JOIN security.Users u ON u.Id = v.UpdatedBy
    WHERE @OnlyPublic = 0 OR d.IsPublic = 1
    ORDER BY d.GroupName, d.SortOrder, d.Label;
END
GO

/* -- save / reset ------------------------------------------------------------------------------- */

CREATE OR ALTER PROCEDURE configuration.usp_Setting_Save
    @SettingKey NVARCHAR(100),
    @Value      NVARCHAR(400),
    @UserId     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Type NVARCHAR(10), @Default NVARCHAR(400), @Min DECIMAL(18,4), @Max DECIMAL(18,4), @Label NVARCHAR(150);
    SELECT @Type = ValueType, @Default = DefaultValue, @Min = MinValue, @Max = MaxValue, @Label = Label
    FROM configuration.SettingDefinitions WHERE SettingKey = @SettingKey;

    IF @Type IS NULL THROW 72006, 'Setting not found.', 1;

    SET @Value = LTRIM(RTRIM(ISNULL(@Value, N'')));

    -- Normalise to the one spelling the reader functions understand.
    IF @Type = N'bool'
    BEGIN
        SET @Value = CASE WHEN LOWER(@Value) IN (N'true', N'1', N'yes', N'on')  THEN N'true'
                          WHEN LOWER(@Value) IN (N'false', N'0', N'no', N'off') THEN N'false' END;
        IF @Value IS NULL THROW 72000, 'This setting is a yes / no choice.', 1;
    END
    ELSE IF @Type = N'int'
    BEGIN
        DECLARE @I BIGINT = TRY_CAST(@Value AS BIGINT);
        IF @I IS NULL THROW 72000, 'This setting must be a whole number.', 1;
        IF @Min IS NOT NULL AND @I < @Min THROW 72000, 'The value is below the allowed minimum.', 1;
        IF @Max IS NOT NULL AND @I > @Max THROW 72000, 'The value is above the allowed maximum.', 1;
        SET @Value = CAST(@I AS NVARCHAR(40));
    END
    ELSE IF @Type = N'decimal'
    BEGIN
        DECLARE @D DECIMAL(18,4) = TRY_CAST(@Value AS DECIMAL(18,4));
        IF @D IS NULL THROW 72000, 'This setting must be a number.', 1;
        IF @Min IS NOT NULL AND @D < @Min THROW 72000, 'The value is below the allowed minimum.', 1;
        IF @Max IS NOT NULL AND @D > @Max THROW 72000, 'The value is above the allowed maximum.', 1;
        SET @Value = FORMAT(@D, N'0.####', N'en-US');   -- 2.2500 reads as 2.25
    END
    ELSE IF LEN(@Value) = 0
        THROW 72000, 'This setting cannot be empty.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Old NVARCHAR(400) = configuration.fn_SettingValue(@SettingKey);

        IF @Value = @Default
            -- Back on the default: keep no row, so a later change of the default reaches this setting too.
            DELETE FROM configuration.SettingValues WHERE SettingKey = @SettingKey;
        ELSE IF EXISTS (SELECT 1 FROM configuration.SettingValues WHERE SettingKey = @SettingKey)
            UPDATE configuration.SettingValues SET Value = @Value, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE SettingKey = @SettingKey;
        ELSE
            INSERT INTO configuration.SettingValues (SettingKey, Value, UpdatedBy) VALUES (@SettingKey, @Value, @UserId);

        IF ISNULL(@Old, N'') <> @Value
            INSERT INTO configuration.SettingChanges (SettingKey, Action, OldValue, NewValue, ChangedBy)
            VALUES (@SettingKey, N'Set', @Old, @Value, @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE configuration.usp_Setting_Reset
    @SettingKey NVARCHAR(100),
    @UserId     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM configuration.SettingDefinitions WHERE SettingKey = @SettingKey)
        THROW 72006, 'Setting not found.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Old NVARCHAR(400) = configuration.fn_SettingValue(@SettingKey);
        DELETE FROM configuration.SettingValues WHERE SettingKey = @SettingKey;
        DECLARE @New NVARCHAR(400) = configuration.fn_SettingValue(@SettingKey);

        IF ISNULL(@Old, N'') <> ISNULL(@New, N'')
            INSERT INTO configuration.SettingChanges (SettingKey, Action, OldValue, NewValue, ChangedBy)
            VALUES (@SettingKey, N'Reset', @Old, @New, @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

PRINT 'Script 39 applied: global settings (ViewLookup pattern).';
GO
