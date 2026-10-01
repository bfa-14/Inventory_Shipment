CREATE   PROCEDURE configuration.usp_Setting_Reset
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

