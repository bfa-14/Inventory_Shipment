
CREATE   PROCEDURE masterdata.usp_Port_SetActive
    @Id INT, @IsActive BIT, @RowVersion BINARY(8) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Ports WHERE Id = @Id) THROW 69006, 'Port not found.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Ports WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 69004, 'This port was modified by another user. Reload the page and try again.', 1;
    UPDATE masterdata.Ports SET IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;
END
GO

