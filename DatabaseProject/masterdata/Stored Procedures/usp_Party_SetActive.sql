
CREATE   PROCEDURE masterdata.usp_Party_SetActive
    @Id INT, @IsActive BIT, @ActorUserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @Id)
        THROW 60006, 'Party not found.', 1;
    UPDATE masterdata.Parties SET IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @ActorUserId WHERE Id = @Id;
END