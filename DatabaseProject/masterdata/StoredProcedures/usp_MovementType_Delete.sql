CREATE   PROCEDURE masterdata.usp_MovementType_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.MovementTypes WHERE Id = @Id) THROW 70006, 'Movement type not found.', 1;
    IF EXISTS (SELECT 1 FROM logistics.Movements WHERE MovementTypeId = @Id)
        THROW 70014, 'This movement type is used by movements and cannot be deleted. Deactivate it instead.', 1;
    DELETE FROM masterdata.MovementTypes WHERE Id = @Id;
END

GO

