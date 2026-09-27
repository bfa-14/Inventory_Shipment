CREATE   PROCEDURE masterdata.usp_MovementType_SetActive
    @Id INT, @IsActive BIT, @RowVersion BINARY(8) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.MovementTypes WHERE Id = @Id) THROW 70006, 'Movement type not found.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.MovementTypes WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 70004, 'This movement type was modified by another user. Reload the page and try again.', 1;
    UPDATE masterdata.MovementTypes SET IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;
END

GO

