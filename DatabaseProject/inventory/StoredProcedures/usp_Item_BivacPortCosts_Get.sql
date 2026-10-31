/* ================================================================== 3. The BIVAC cost per port of an item */

CREATE   PROCEDURE inventory.usp_Item_BivacPortCosts_Get
    @ItemId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT pc.PortId, p.PortCode, p.PortName, p.CountryCode, pc.CostBase, pc.UpdatedAtUtc, u.FullName AS UpdatedByName
    FROM inventory.ItemBivacPortCosts pc
    INNER JOIN masterdata.Ports p ON p.Id = pc.PortId
    LEFT  JOIN security.Users u   ON u.Id = pc.UpdatedBy
    WHERE pc.ItemId = @ItemId
    ORDER BY p.PortName;
END

GO

