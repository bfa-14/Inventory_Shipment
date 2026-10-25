--      refusal of usp_Warehouse_Create / _Update and by every caller of script 90 (unchanged for a warehouse without
--      levels: its tests are fn_Warehouse_IsUsedInTransactions', moved there unchanged).
-- Re-created (91) from the body of script 90: its tests moved unchanged to fn_Warehouse_IsUsedInTransactions, + a
-- warehouse with stock levels counts as used.
CREATE   FUNCTION masterdata.fn_Warehouse_IsUsed (@WarehouseId INT)
RETURNS BIT
AS
BEGIN
    RETURN CASE WHEN masterdata.fn_Warehouse_IsUsedInTransactions(@WarehouseId) = 1
                  OR EXISTS (SELECT 1 FROM inventory.ItemWarehouseLevels WHERE WarehouseId = @WarehouseId)   -- (91)
                THEN 1 ELSE 0 END;
END

GO

