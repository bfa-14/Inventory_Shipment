/* ================================================================== 4. What Add charge offers for a BIVAC charge */

-- (97) The active BIVAC items, each with its cost at each container's port (NULL = none there) and the total.
CREATE   PROCEDURE logistics.usp_ContainerCharge_BivacOptions
    @ContainerIds logistics.tvp_IdList READONLY
AS
BEGIN
    SET NOCOUNT ON;
    SELECT i.Id AS ItemId, i.ItemCode, i.ItemName,
           Containers = (SELECT COUNT(*) FROM @ContainerIds),
           Priced = (SELECT COUNT(*) FROM @ContainerIds x CROSS APPLY logistics.fn_Container_BivacCost(x.Id, i.Id) bc WHERE bc.CostBase IS NOT NULL),
           TotalBase = (SELECT SUM(bc.CostBase) FROM @ContainerIds x CROSS APPLY logistics.fn_Container_BivacCost(x.Id, i.Id) bc),
           MissingPorts = STUFF((SELECT DISTINCT N', ' + ISNULL(bc.PortName, N'(no port)')
                                 FROM @ContainerIds x CROSS APPLY logistics.fn_Container_BivacCost(x.Id, i.Id) bc
                                 WHERE bc.CostBase IS NULL
                                 FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(400)'), 1, 2, N'')
    FROM inventory.Items i
    WHERE i.IsBivac = 1 AND i.IsActive = 1
    ORDER BY i.ItemCode;

    SELECT x.Id AS ContainerId, c.ContainerRef, bp.PortId, bp.PortName
    FROM @ContainerIds x
    INNER JOIN logistics.Containers c ON c.Id = x.Id
    CROSS APPLY logistics.fn_Container_BivacPort(x.Id) bp
    ORDER BY c.ContainerRef;
END

GO

