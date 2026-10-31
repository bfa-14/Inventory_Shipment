/* ================================================================== 7. inventory.usp_ShortageDocument_CreatePurchaseOrder */

-- Posted only: one draft purchase order (supplier, branch) from the lines with Required Qty > 0.
-- Re-created (89) from the body of script 22: A PLAN FOR A PARENT WAREHOUSE CREATES ITS ORDER AGAIN. Since script 70 a
-- purchase line takes a warehouse at the bottom of the tree (65000), and this procedure put the plan's warehouse - a
-- parent, which script 62 allows - on every line. Each line now takes the item's default warehouse when it is an active
-- warehouse at the bottom of the plan's tree, else the first of those (the plan's branch first, then by code); the header
-- takes its first line's (the purchase save's own rule) and the Notes say so. A plan for an active warehouse at the
-- bottom of the tree is unchanged. A tree with none refuses (66000). ONE TRANSACTION: the order, its link to the plan
-- and the plan's audit row are written together (the API retries a deadlock).
CREATE   PROCEDURE inventory.usp_ShortageDocument_CreatePurchaseOrder
    @Id           INT,
    @DocumentDate DATE = NULL,
    @ExpectedDate DATE = NULL,
    @UserId       INT  = NULL,
    @NewId        INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;                                                                  -- (89)
    IF @DocumentDate IS NULL SET @DocumentDate = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @Status TINYINT, @BranchId INT, @WarehouseId INT, @SupplierId INT, @Number NVARCHAR(30), @Description NVARCHAR(200);
    SELECT @Status = Status, @BranchId = BranchId, @WarehouseId = WarehouseId, @SupplierId = SupplierId, @Number = DocumentNumber, @Description = Description
    FROM inventory.ShortageDocuments WHERE Id = @Id;
    IF @Status IS NULL THROW 66006, 'Shortage document not found.', 1;
    IF @Status <> 2 THROW 66010, 'Post the shortage document before creating a purchase order from it.', 1;
    IF NOT EXISTS (SELECT 1 FROM inventory.ShortageDocumentLines WHERE DocumentId = @Id AND RequiredQty > 0)
        THROW 66011, 'No line has a required quantity greater than zero.', 1;

    -- (89) WHERE THE GOODS GO: the active warehouses at the bottom of the plan's tree (one at the bottom is its own tree)
    DECLARE @PlanWhCode NVARCHAR(20), @PlanWhActive BIT, @PlanWhIsLeaf BIT;
    SELECT @PlanWhCode = w.WarehouseCode, @PlanWhActive = w.IsActive, @PlanWhIsLeaf = masterdata.fn_Warehouse_IsLeaf(w.Id)
    FROM masterdata.Warehouses w WHERE w.Id = @WarehouseId;

    DECLARE @Leaves TABLE (WarehouseId INT NOT NULL PRIMARY KEY, Code NVARCHAR(20) NOT NULL, Rn INT NOT NULL);
    INSERT INTO @Leaves (WarehouseId, Code, Rn)
    SELECT w.Id, w.WarehouseCode,
           ROW_NUMBER() OVER (ORDER BY CASE WHEN w.BranchId = @BranchId THEN 0 ELSE 1 END, w.WarehouseCode, w.Id)
    FROM masterdata.fn_Warehouse_Subtree(@WarehouseId) t
    INNER JOIN masterdata.Warehouses w ON w.Id = t.Id
    WHERE w.IsActive = 1 AND masterdata.fn_Warehouse_IsLeaf(w.Id) = 1;

    DECLARE @Msg NVARCHAR(400);
    IF NOT EXISTS (SELECT 1 FROM @Leaves)
    BEGIN
        SET @Msg = CASE WHEN @PlanWhIsLeaf = 1
                        THEN N'Warehouse ' + ISNULL(@PlanWhCode, N'?') + N' of this plan is inactive. Activate it in Master Data > Warehouses, then create the purchase order again.'
                        ELSE N'Warehouse ' + ISNULL(@PlanWhCode, N'?') + N' of this plan has no active warehouse at the bottom of its tree to receive the goods into. Activate one in Master Data > Warehouses, then create the purchase order again.' END;
        THROW 66000, @Msg, 1;
    END

    DECLARE @Direct BIT = CASE WHEN @PlanWhIsLeaf = 1 AND @PlanWhActive = 1 THEN 1 ELSE 0 END;   -- as before 89
    DECLARE @FirstLeaf INT, @FirstLeafCode NVARCHAR(20);
    SELECT @FirstLeaf = WarehouseId, @FirstLeafCode = Code FROM @Leaves WHERE Rn = 1;
    DECLARE @HeaderWarehouseId INT = CASE WHEN @Direct = 1 THEN @WarehouseId END;      -- NULL: the save takes the first line's

    DECLARE @Lines purchase.tvp_PurchaseDocumentLine;
    INSERT INTO @Lines (LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, UnitPrice, DiscountPercent, ImportRowNumber, Notes, SourceLineId)
    SELECT ROW_NUMBER() OVER (ORDER BY l.LineNumber), l.ItemId, l.PurchaseItemUnitId,
           CASE WHEN @Direct = 1 THEN @WarehouseId ELSE COALESCE(dl.WarehouseId, @FirstLeaf) END,           -- (89)
           NULL, l.RequiredQty, NULL, NULL, NULL,
           LEFT(N'Shortage ' + @Number + ISNULL(N' - ' + l.Notes, N''), 300), NULL
    FROM inventory.ShortageDocumentLines l
    INNER JOIN inventory.Items i ON i.Id = l.ItemId
    LEFT  JOIN @Leaves dl        ON dl.WarehouseId = i.DefaultWarehouseId                                 -- (89)
    WHERE l.DocumentId = @Id AND l.RequiredQty > 0;

    DECLARE @Notes NVARCHAR(1000) = LEFT(N'Created from shortage plan ' + @Number + N' - ' + @Description
        + CASE WHEN @Direct = 1 THEN N''
               ELSE N'. Warehouse ' + @PlanWhCode + N' has warehouses under it: each line goes to the item''s default warehouse when it is an active warehouse at the bottom of '
                    + @PlanWhCode + N'''s tree, else to ' + @FirstLeafCode + N'. Change them on the order if needed.' END, 1000);

    BEGIN TRY
        BEGIN TRANSACTION;                                                               -- (89)

        EXEC purchase.usp_PurchaseDocument_Save
             @Id = NULL, @DocumentTypeCode = N'PO', @DocumentDate = @DocumentDate, @ExpectedDate = @ExpectedDate,
             @BranchId = @BranchId, @WarehouseId = @HeaderWarehouseId, @SupplierId = @SupplierId, @CurrencyId = NULL,
             @RateType = 1, @ExchangeRate = NULL, @SupplierReference = NULL, @Notes = @Notes,
             @Lines = @Lines, @MaxDiscountPercent = 100, @SourceDocumentId = NULL, @RowVersion = NULL, @UserId = @UserId, @NewId = @NewId OUTPUT;

        UPDATE purchase.PurchaseDocuments SET SourceShortageId = @Id WHERE Id = @NewId;
        INSERT INTO inventory.ShortageDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@Id, N'POCreated', N'Purchase order draft created (' + CAST((SELECT COUNT(*) FROM @Lines) AS NVARCHAR(10)) + N' line(s))', @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

