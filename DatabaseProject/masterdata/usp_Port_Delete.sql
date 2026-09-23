
CREATE   PROCEDURE masterdata.usp_Port_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Ports WHERE Id = @Id) THROW 69006, 'Port not found.', 1;
    IF EXISTS (SELECT 1 FROM logistics.Containers WHERE PortOfLoadingId = @Id OR PortOfDestinationId = @Id OR FinalDestinationId = @Id)
       OR EXISTS (SELECT 1 FROM logistics.ContainerEvents WHERE PortId = @Id)
        THROW 69014, 'This port is used by containers and cannot be deleted. Deactivate it instead.', 1;
    DELETE FROM masterdata.Ports WHERE Id = @Id;
END
GO

