--      Dispatch read them; the Receive's To-only half lives in fn_TransferOrder_Blocks, Seq 92). One row, the first
--      failing of: 1. From / To missing; 2. From = To; 3. an On the way warehouse; 4. a warehouse not found or inactive;
--      5. a warehouse with warehouses under it (the sentence of script 70). From before To within each rule. None =
--      both are fit. A transfer may join any two branches: no branch rule.
CREATE   FUNCTION inventory.fn_TransferOrder_WarehouseProblem (@FromId INT, @ToId INT)
RETURNS TABLE
AS
RETURN
SELECT TOP (1) Message = CAST(p.Message AS NVARCHAR(400))
FROM
(
    SELECT Seq = 1, Message = CASE WHEN @FromId IS NULL THEN N'Choose the warehouse the goods leave from.' END
    UNION ALL
    SELECT 2, CASE WHEN @ToId IS NULL THEN N'Choose the warehouse the goods go to.' END
    UNION ALL
    SELECT 3, CASE WHEN @FromId = @ToId THEN N'The destination must differ from the source.' END
    UNION ALL
    -- rules 3-5, per side (1 From, 2 To): Seq 11 / 12, 21 / 22, 31 / 32
    SELECT 10 * k.Step + s.Side,
           CASE k.Step
                WHEN 1 THEN CASE WHEN w.IsTransit = 1
                                 THEN w.WarehouseCode + N' is an On the way warehouse: it holds goods travelling between warehouses and cannot be chosen.' END
                WHEN 2 THEN CASE WHEN w.Id IS NULL THEN N'The warehouse was not found.'
                                 WHEN w.IsActive = 0 THEN N'Warehouse ' + w.WarehouseCode + N' is inactive.' END
                WHEN 3 THEN CASE WHEN EXISTS (SELECT 1 FROM masterdata.Warehouses c WHERE c.ParentId = w.Id)
                                 THEN N'Warehouse ' + w.WarehouseCode + N' has warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree.' END
           END
    FROM (VALUES (1, @FromId), (2, @ToId)) s (Side, WarehouseId)
    CROSS JOIN (VALUES (1), (2), (3)) k (Step)
    LEFT JOIN masterdata.Warehouses w ON w.Id = s.WarehouseId
    WHERE s.WarehouseId IS NOT NULL
) p
WHERE p.Message IS NOT NULL
ORDER BY p.Seq;

GO

