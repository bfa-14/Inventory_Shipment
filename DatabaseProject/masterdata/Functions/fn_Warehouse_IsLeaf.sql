/* ================================================================== 9. Leaf, used, attachment kinds: the On the way warehouse and the transfer orders */

-- Re-created (90) from the body of script 70: + an On the way warehouse is never a leaf. FB rule 32's safety net: every
-- family that takes a warehouse on a line (stock documents, sales, purchase, goods receipts, the imports, a container's
-- draft receipt) refuses it at save and at posting with the leaf sentence. No screen offers one, so only a typed code in
-- an import file or a crafted call reaches it; transfers name it themselves and never ask.
CREATE   FUNCTION masterdata.fn_Warehouse_IsLeaf (@WarehouseId INT)
RETURNS BIT
AS
BEGIN
    RETURN CASE WHEN EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE ParentId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsTransit = 1) THEN 0 ELSE 1 END;   -- (90)
END

GO

