CREATE   PROCEDURE masterdata.usp_UnitType_SetActive
    @Id INT, @IsActive BIT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.UnitTypes WHERE Id = @Id)
        THROW 57006, 'Unit type not found.', 1;
    UPDATE masterdata.UnitTypes SET IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;
END