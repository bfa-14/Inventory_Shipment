/* ================================================================== 5. The BIVAC Out of a BIVAC charge */

-- (97) Called by usp_ContainerCharge_Post, in its transaction: a BIVAC Out (BIV_OUT) of 1 piece of the charge's BIVAC
-- item from the container's warehouse, saved and posted with the BIVAC Out's own procedures, linked to the charge.
CREATE   PROCEDURE logistics.usp_ContainerCharge_PostBivacOut
    @ChargeId INT,
    @UserId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @ItemId INT, @Date DATE, @BranchId INT, @WarehouseId INT, @Ref NVARCHAR(30), @ChargeRef NVARCHAR(100), @Msg NVARCHAR(400);
    SELECT @ItemId = ch.BivacItemId, @Date = ch.ChargeDate, @BranchId = c.BranchId, @Ref = c.ContainerRef, @ChargeRef = ch.Reference,
           @WarehouseId = (SELECT w.Id FROM masterdata.Warehouses w
                           WHERE w.Id = c.WarehouseId AND w.IsActive = 1 AND masterdata.fn_Warehouse_IsLeaf(w.Id) = 1)
    FROM logistics.ContainerCharges ch INNER JOIN logistics.Containers c ON c.Id = ch.ContainerId
    WHERE ch.Id = @ChargeId;
    IF @ItemId IS NULL RETURN;
    IF @WarehouseId IS NULL
    BEGIN
        SET @Msg = N'Container ' + @Ref + N' has no warehouse to take its BIVAC from (active, at the bottom of the tree): set the container''s warehouse first.';
        THROW 70010, @Msg, 1;
    END
    IF @Date > CAST(SYSUTCDATETIME() AS DATE) SET @Date = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @Lines inventory.tvp_StockDocumentLine, @DocId INT;
    INSERT INTO @Lines (LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, UnitCost, Notes)
    SELECT 1, @ItemId, u.Id, @WarehouseId, NULL, 1, NULL, LEFT(N'BIVAC of container ' + @Ref, 300)
    FROM (SELECT TOP (1) Id FROM inventory.ItemUnits WHERE ItemId = @ItemId ORDER BY CASE WHEN IsBaseUnit = 1 THEN 0 ELSE 1 END, Id) u;
    IF NOT EXISTS (SELECT 1 FROM @Lines)
    BEGIN
        SET @Msg = N'The BIVAC item has no unit: add its base unit on Item Definition first.';
        THROW 70010, @Msg, 1;
    END
    DECLARE @Notes NVARCHAR(1000) = N'Made by the BIVAC charge of container ' + @Ref + ISNULL(N' (' + @ChargeRef + N')', N'') + N'.';
    EXEC inventory.usp_StockDocument_Save @DocumentTypeCode = N'BIV_OUT', @DocumentDate = @Date, @BranchId = @BranchId,
         @WarehouseId = @WarehouseId, @ReferenceNo = @Ref, @Notes = @Notes, @Lines = @Lines, @UserId = @UserId, @NewId = @DocId OUTPUT;
    EXEC inventory.usp_StockDocument_Post @Id = @DocId, @UserId = @UserId;
    UPDATE logistics.ContainerCharges SET BivacOutDocumentId = @DocId WHERE Id = @ChargeId;
END

GO

