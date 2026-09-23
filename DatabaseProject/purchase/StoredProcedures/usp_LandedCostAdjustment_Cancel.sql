CREATE   PROCEDURE purchase.usp_LandedCostAdjustment_Cancel
    @Id         INT,
    @Reason     NVARCHAR(300),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 67000, 'A cancellation reason is required.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE @Status TINYINT, @InvoiceId INT, @Number NVARCHAR(30), @BranchId INT;
        SELECT @Status = Status, @InvoiceId = SourceInvoiceId, @Number = DocumentNumber, @BranchId = BranchId
        FROM purchase.LandedCostAdjustments WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NULL THROW 67006, 'Adjustment not found.', 1;
        IF @Status <> 2 THROW 67010, 'Only posted adjustments can be cancelled.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.LandedCostAdjustments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 67004, 'This adjustment was modified by another user. Reload the page and try again.', 1;

        -- Reverse the value ledger and the invoice landed cost.
        INSERT INTO inventory.CostAdjustments (AdjustmentDate, ItemId, WarehouseId, BranchId, Kind, AmountBase, SourceKind, SourceId, SourceNumber, PurchaseLineId, CreatedBy)
        SELECT SYSUTCDATETIME(), c.ItemId, c.WarehouseId, c.BranchId, c.Kind, -c.AmountBase, c.SourceKind, c.SourceId, c.SourceNumber, c.PurchaseLineId, @UserId
        FROM inventory.CostAdjustments c WHERE c.SourceKind = N'LCA' AND c.SourceId = @Id AND c.AmountBase > 0;

        UPDATE l SET AllocatedChargesBase = l.AllocatedChargesBase - x.AllocatedBase, UnitCostBase = x.LandedCostBefore
        FROM purchase.PurchaseDocumentLines l INNER JOIN purchase.LandedCostAdjustmentLines x ON x.PurchaseLineId = l.Id
        WHERE x.AdjustmentId = @Id;
        UPDATE d SET TotalChargesBase = ISNULL(x.Charges, 0), TotalLandedCostBase = d.TotalAmountBase + ISNULL(x.Charges, 0)
        FROM purchase.PurchaseDocuments d
        CROSS APPLY (SELECT SUM(AllocatedChargesBase) AS Charges FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId) x
        WHERE d.Id = @InvoiceId;

        UPDATE purchase.LandedCostAdjustments
        SET Status = 3, CancelledAtUtc = SYSUTCDATETIME(), CancelledBy = @UserId, CancelReason = @Reason, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;
        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@InvoiceId, N'Updated', N'Landed cost adjustment ' + @Number + N' cancelled: ' + @Reason, @UserId);

        -- Average / last cost recomputed from the ledger (the reversal rows net the adjustment out).
        DECLARE @ItemId INT;
        DECLARE items CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT ItemId FROM purchase.LandedCostAdjustmentLines WHERE AdjustmentId = @Id;
        OPEN items; FETCH NEXT FROM items INTO @ItemId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC inventory.usp_Item_RebuildCosts @ItemId;
            FETCH NEXT FROM items INTO @ItemId;
        END
        CLOSE items; DEALLOCATE items;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

