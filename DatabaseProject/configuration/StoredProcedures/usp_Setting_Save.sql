/* -- save / reset ------------------------------------------------------------------------------- */

CREATE   PROCEDURE configuration.usp_Setting_Save
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

