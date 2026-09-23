
-- Makes this unit type THE container unit (the previous one is released).
CREATE   PROCEDURE masterdata.usp_UnitType_SetContainer
    @Id     INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.UnitTypes WHERE Id = @Id) THROW 57006, 'Unit type not found.', 1;
    IF EXISTS (SELECT 1 FROM masterdata.UnitTypes WHERE Id = @Id AND IsActive = 0)
        THROW 57000, 'An inactive unit type cannot be the container unit.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        UPDATE masterdata.UnitTypes SET IsContainer = 0, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE IsContainer = 1 AND Id <> @Id;
        UPDATE masterdata.UnitTypes SET IsContainer = 1, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

