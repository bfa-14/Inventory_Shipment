CREATE   PROCEDURE masterdata.usp_ContainerType_SetActive
    @Id INT, @IsActive BIT, @RowVersion BINARY(8) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.ContainerTypes WHERE Id = @Id) THROW 69006, 'Container type not found.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.ContainerTypes WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 69004, 'This container type was modified by another user. Reload the page and try again.', 1;
    UPDATE masterdata.ContainerTypes SET IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;
END
GO

