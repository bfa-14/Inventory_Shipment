/* ================================================================== 2. The port of a container, and the BIVAC cost there */

-- (97) The port a container's BIVAC is paid at: its port of destination, else its final destination, else its port of loading.
CREATE   FUNCTION logistics.fn_Container_BivacPort (@ContainerId INT)
RETURNS TABLE
AS
RETURN
SELECT c.Id AS ContainerId, PortId = p.Id, PortName = p.PortName
FROM logistics.Containers c
LEFT JOIN masterdata.Ports p ON p.Id = COALESCE(c.PortOfDestinationId, c.FinalDestinationId, c.PortOfLoadingId)
WHERE c.Id = @ContainerId;

GO

