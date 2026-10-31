CREATE   FUNCTION logistics.fn_Container_BivacCost (@ContainerId INT, @ItemId INT)
RETURNS TABLE
AS
RETURN
SELECT bp.ContainerId, bp.PortId, bp.PortName, pc.CostBase
FROM logistics.fn_Container_BivacPort(@ContainerId) bp
LEFT JOIN inventory.ItemBivacPortCosts pc ON pc.ItemId = @ItemId AND pc.PortId = bp.PortId;

GO

