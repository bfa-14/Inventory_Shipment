/* ------------------------------------------------------------------ Master data procedures that check usage (re-created) */

-- Re-created: ports are used by containers and by movements (the route events of script 24 are gone).
CREATE   PROCEDURE masterdata.usp_Port_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Ports WHERE Id = @Id) THROW 69006, 'Port not found.', 1;
    IF EXISTS (SELECT 1 FROM logistics.Containers WHERE PortOfLoadingId = @Id OR PortOfDestinationId = @Id OR FinalDestinationId = @Id)
       OR EXISTS (SELECT 1 FROM logistics.Movements WHERE FromPlaceId = @Id OR ToPlaceId = @Id)
        THROW 69014, 'This place is used by containers or movements and cannot be deleted. Deactivate it instead.', 1;
    DELETE FROM masterdata.Ports WHERE Id = @Id;
END

GO

