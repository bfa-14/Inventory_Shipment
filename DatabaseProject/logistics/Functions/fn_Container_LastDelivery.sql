-- Delivery (whatever the type's code). No row when there is none. Goods cannot be received before it (Save, Post), the
-- receipt page names its place, and the "Delivered, not received" filters start from it.
CREATE   FUNCTION logistics.fn_Container_LastDelivery (@ContainerId INT)
RETURNS TABLE
AS
RETURN
    SELECT TOP (1) MovementId = m.Id, m.MovementNo, m.EndDate, PlaceId = m.ToPlaceId, PlaceName = tp.PortName,
                   m.CompletedAtUtc
    FROM logistics.MovementContainers mc
    INNER JOIN logistics.Movements m       ON m.Id = mc.MovementId AND m.Status = 3
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId AND mt.Stage = N'Delivery'
    INNER JOIN masterdata.Ports tp         ON tp.Id = m.ToPlaceId
    WHERE mc.ContainerId = @ContainerId
    ORDER BY m.EndDate DESC, m.CompletedAtUtc DESC, m.Id DESC;

GO

