CREATE   PROCEDURE masterdata.usp_ContainerType_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.ContainerTypes WHERE Id = @Id) THROW 69006, 'Container type not found.', 1;
    IF EXISTS (SELECT 1 FROM logistics.Containers WHERE ContainerTypeId = @Id)
        THROW 69014, 'This container type is used by containers and cannot be deleted. Deactivate it instead.', 1;
    DELETE FROM masterdata.ContainerTypes WHERE Id = @Id;
END

GO

