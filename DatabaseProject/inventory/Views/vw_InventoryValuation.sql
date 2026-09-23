CREATE   VIEW inventory.vw_InventoryValuation
AS
    SELECT i.Id AS ItemId, i.ItemCode, i.ItemName, i.BrandId, i.ItemFamilyId,
           OnHandBase = inventory.fn_StockOnHand(i.Id, NULL),
           i.AverageCost, i.LastCost, i.FobCost,
           InventoryValue = CAST(inventory.fn_StockOnHand(i.Id, NULL) * i.AverageCost AS DECIMAL(18,2))
    FROM inventory.Items i
    WHERE i.IsActive = 1;

GO

