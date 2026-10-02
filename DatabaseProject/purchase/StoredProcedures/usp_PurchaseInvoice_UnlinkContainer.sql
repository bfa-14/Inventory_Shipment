/* ================================================================== 13. Unlink an invoice from a container */

-- The container must still be Draft or Confirmed (nothing received). The invoice lines on it lose their container and
-- go back into the unlinked line of the same order line, item, unit, price, discount, warehouse and expiry when there
-- is one (otherwise they stay as separate unlinked lines). The invoice stays "shipped in containers".
CREATE   PROCEDURE purchase.usp_PurchaseInvoice_UnlinkContainer
    @InvoiceId   INT,
    @ContainerId INT,
    @RowVersion  BINARY(8) = NULL,
    @UserId      INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @TypeCode NVARCHAR(20), @Status TINYINT, @Number NVARCHAR(30);
        SELECT @TypeCode = dt.Code, @Status = d.Status, @Number = ISNULL(d.DocumentNumber, N'draft #' + CAST(d.Id AS NVARCHAR(10)))
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @InvoiceId;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @TypeCode <> N'PINV' THROW 65028, 'Only a purchase invoice can be unlinked from a container.', 1;
        IF @Status NOT IN (1, 2) THROW 65010, 'A cancelled invoice cannot be changed.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @InvoiceId AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;

        DECLARE @Ref NVARCHAR(30), @CStatus TINYINT, @Msg NVARCHAR(400);
        SELECT @Ref = ContainerRef, @CStatus = Status FROM logistics.Containers WITH (UPDLOCK, HOLDLOCK) WHERE Id = @ContainerId;
        IF @Ref IS NULL OR NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines l
                                       INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
                                       WHERE l.DocumentId = @InvoiceId AND cl.ContainerId = @ContainerId)
        BEGIN
            SET @Msg = N'Container ' + ISNULL(@Ref, N'#' + CAST(@ContainerId AS NVARCHAR(10))) + N' is not linked to this invoice.';
            THROW 65019, @Msg, 1;
        END
        IF @CStatus NOT IN (1, 2) OR EXISTS (SELECT 1 FROM logistics.ContainerLines WHERE ContainerId = @ContainerId AND ISNULL(ReceivedQuantityBase, 0) > 0)
        BEGIN
            SET @Msg = N'Container ' + @Ref + N' has started moving: it can no longer be unlinked.';
            THROW 65027, @Msg, 1;
        END

        DECLARE @OldTotal DECIMAL(18,2) = (SELECT ISNULL(SUM(LineTotal), 0) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId);
        DECLARE @Pieces INT;

        DECLARE @Freed TABLE (Id INT PRIMARY KEY);
        UPDATE l SET ContainerLineId = NULL
        OUTPUT inserted.Id INTO @Freed (Id)
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
        WHERE l.DocumentId = @InvoiceId AND cl.ContainerId = @ContainerId;
        SET @Pieces = (SELECT SUM(l.QuantityBase) FROM purchase.PurchaseDocumentLines l INNER JOIN @Freed f ON f.Id = l.Id);

        -- back into the unlinked line of the same kind: the one that was there before, else the first freed one
        DECLARE @Merge TABLE (Id INT PRIMARY KEY, KeeperId INT NOT NULL);
        INSERT INTO @Merge (Id, KeeperId)
        SELECT g.Id, g.KeeperId
        FROM (SELECT l.Id,
                     IsFreed  = CASE WHEN f.Id IS NOT NULL THEN 1 ELSE 0 END,
                     KeeperId = FIRST_VALUE(l.Id) OVER (PARTITION BY l.SourceLineId, l.ItemId, l.ItemUnitId, l.UnitPrice, l.DiscountPercent,
                                                                     l.WarehouseId, l.ExpiryDate
                                                        ORDER BY CASE WHEN f.Id IS NULL THEN 0 ELSE 1 END, l.Id)
              FROM purchase.PurchaseDocumentLines l
              LEFT JOIN @Freed f ON f.Id = l.Id
              WHERE l.DocumentId = @InvoiceId AND l.ContainerLineId IS NULL) g
        WHERE g.IsFreed = 1 AND g.Id <> g.KeeperId;

        UPDATE k SET Quantity = k.Quantity + x.Qty
        FROM purchase.PurchaseDocumentLines k
        INNER JOIN (SELECT m.KeeperId, Qty = SUM(l.Quantity) FROM @Merge m
                    INNER JOIN purchase.PurchaseDocumentLines l ON l.Id = m.Id GROUP BY m.KeeperId) x ON x.KeeperId = k.Id;
        DELETE l FROM purchase.PurchaseDocumentLines l INNER JOIN @Merge m ON m.Id = l.Id;

        UPDATE l SET LineNumber = x.Seq
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN (SELECT pl.Id, Seq = ROW_NUMBER() OVER (ORDER BY CASE WHEN pl.ContainerLineId IS NULL THEN 1 ELSE 0 END,
                                                                    c.ContainerRef, cl.LineNumber, pl.LineNumber, pl.Id)
                    FROM purchase.PurchaseDocumentLines pl
                    LEFT JOIN logistics.ContainerLines cl ON cl.Id = pl.ContainerLineId
                    LEFT JOIN logistics.Containers c      ON c.Id = cl.ContainerId
                    WHERE pl.DocumentId = @InvoiceId) x ON x.Id = l.Id
        WHERE l.LineNumber <> x.Seq;

        -- the document total does not change: a rounding difference goes on the line the pieces went back to
        DECLARE @LastLine INT = (SELECT TOP (1) KeeperId FROM @Merge ORDER BY KeeperId DESC);
        DECLARE @Diff DECIMAL(18,2) = @OldTotal - (SELECT ISNULL(SUM(LineTotal), 0) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId);
        IF @Diff <> 0 AND @LastLine IS NOT NULL
            UPDATE purchase.PurchaseDocumentLines
            SET UnitPrice = ROUND(UnitPrice + @Diff / NULLIF(Quantity * (1 - DiscountPercent / 100.0), 0), 4)
            WHERE Id = @LastLine;

        UPDATE d
        SET TotalItems = x.Items, TotalQuantity = x.Qty, Subtotal = x.Sub, TotalAmount = x.Amt, TotalDiscount = x.Sub - x.Amt,
            TotalAmountBase = ROUND(x.Amt / d.ExchangeRate, 2), TotalLandedCostBase = ROUND(x.Amt / d.ExchangeRate, 2) + d.TotalChargesBase,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        FROM purchase.PurchaseDocuments d
        CROSS APPLY (SELECT COUNT(*) AS Items, ISNULL(SUM(QuantityBase), 0) AS Qty,
                            ISNULL(SUM(CONVERT(DECIMAL(18,2), Quantity * UnitPrice)), 0) AS Sub, ISNULL(SUM(LineTotal), 0) AS Amt
                     FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId) x
        WHERE d.Id = @InvoiceId;

        EXEC logistics.usp_Container_ReallocateCharges @ContainerId, 1, 1;
        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        VALUES (@ContainerId, N'Updated', N'Unlinked from purchase invoice ' + @Number + N': ' + CAST(ISNULL(@Pieces, 0) AS NVARCHAR(20)) + N' pieces', @UserId);
        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@InvoiceId, N'Updated', N'Unlinked from container ' + @Ref + N' (' + CAST(ISNULL(@Pieces, 0) AS NVARCHAR(20)) + N')', @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    EXEC purchase.usp_PurchaseInvoice_ContainerSummary @InvoiceId;
END

GO

