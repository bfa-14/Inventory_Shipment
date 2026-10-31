-- = it can): a BIV charge needs an active BIVAC item with a cost at every container's port; another type names none.
CREATE   FUNCTION logistics.fn_ContainerCharge_BivacBlock
(
    @ChargeTypeId INT,
    @BivacItemId  INT,
    @ContainerIds logistics.tvp_IdList READONLY
)
RETURNS TABLE
AS
RETURN
SELECT Reason = CAST(CASE
    WHEN t.ChargeCode = N'BIV' AND @BivacItemId IS NULL
        THEN N'A BIVAC charge names its BIVAC: choose which BIVAC item (Item Definition''s items with BIVAC Item ticked).'
    WHEN ISNULL(t.ChargeCode, N'') <> N'BIV' AND @BivacItemId IS NOT NULL
        THEN N'Only a BIVAC / Inspection charge names a BIVAC item.'
    WHEN @BivacItemId IS NOT NULL AND (i.Id IS NULL OR i.IsBivac = 0 OR i.IsActive = 0)
        THEN N'The BIVAC item is not an active item with BIVAC Item ticked.'
    WHEN @BivacItemId IS NOT NULL
        THEN (SELECT TOP (1) i.ItemCode + N' has no BIVAC cost for ' + ISNULL(bc.PortName, N'the port of container ' + c.ContainerRef)
                             + N': set it on Item Definition (BIVAC cost per port).'
              FROM @ContainerIds x
              INNER JOIN logistics.Containers c ON c.Id = x.Id
              CROSS APPLY logistics.fn_Container_BivacCost(x.Id, @BivacItemId) bc
              WHERE bc.CostBase IS NULL
              ORDER BY c.ContainerRef)
    END AS NVARCHAR(400))
FROM (SELECT Dummy = 1) d
LEFT JOIN purchase.ChargeTypes t ON t.Id = @ChargeTypeId
LEFT JOIN inventory.Items i      ON i.Id = @BivacItemId;

GO

