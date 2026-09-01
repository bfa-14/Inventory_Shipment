CREATE   PROCEDURE masterdata.usp_Currency_Update
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