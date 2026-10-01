CREATE   PROCEDURE messaging.usp_EmailSettings_SetTestResult
    @Ok    BIT,
    @Error NVARCHAR(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @Ok IS NULL THROW 65025, 'The result of the test is required.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        IF NOT EXISTS (SELECT 1 FROM messaging.EmailSettings WITH (UPDLOCK, HOLDLOCK) WHERE Id = 1)
            INSERT INTO messaging.EmailSettings (Id) VALUES (1);

        UPDATE messaging.EmailSettings
        SET LastTestAtUtc = SYSUTCDATETIME(), LastTestOk = @Ok,
            LastTestError = CASE WHEN @Ok = 1 THEN NULL ELSE LEFT(NULLIF(LTRIM(RTRIM(@Error)), N''), 1000) END
        WHERE Id = 1;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT RowVersion FROM messaging.EmailSettings WHERE Id = 1;
END

GO

