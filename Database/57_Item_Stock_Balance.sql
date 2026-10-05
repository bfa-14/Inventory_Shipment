SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ==================================================================================================
   57: Item stock balance per warehouse
   --------------------------------------------------------------------------------------------------
   The item card's "Stock Balance" quick link: one item, its on-hand quantity in every warehouse that
   has ever held it (zero included, so a warehouse that emptied still shows), with the warehouse's
   branch, the last movement and the value at the item's moving average cost.

     inventory.usp_Item_StockBalance   @ItemId -> one row per warehouse, largest stock first
                                        (an unknown item answers nothing; the API turns that into 404)
   ================================================================================================== */

IF OBJECT_ID(N'inventory.vw_StockBalance', N'V') IS NULL
BEGIN
    RAISERROR ('The inventory scripts must run before script 57.', 16, 1);
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_Item_StockBalance
    @ItemId INT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inventory.Items WHERE Id = @ItemId) RETURN;

    SELECT b.WarehouseId, b.WarehouseCode, b.WarehouseName, w.IsActive AS WarehouseIsActive,
           b.BranchId, br.BranchCode, br.BranchName,
           b.OnHandBase, b.LastMovementAtUtc,
           AverageCost    = i.AverageCost,
           InventoryValue = CONVERT(DECIMAL(18,2), CASE WHEN b.OnHandBase > 0 THEN b.OnHandBase * ISNULL(i.AverageCost, 0) ELSE 0 END)
    FROM inventory.vw_StockBalance b
    INNER JOIN inventory.Items i      ON i.Id = b.ItemId
    INNER JOIN masterdata.Warehouses w ON w.Id = b.WarehouseId
    INNER JOIN masterdata.Branches br  ON br.Id = b.BranchId
    WHERE b.ItemId = @ItemId
    ORDER BY b.OnHandBase DESC, b.WarehouseCode;
END
GO

PRINT 'Script 57 applied: item stock balance per warehouse.';
GO

SET NOEXEC OFF;
GO
