CREATE   PROCEDURE sales.usp_SalesDocument_Cancel
    @Id         INT,
    @Reason     NVARCHAR(300),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 64000, 'A cancellation reason is required.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @Direction SMALLINT, @TypeCode NVARCHAR(20), @SourceId INT;
        SELECT @Status = d.Status, @Direction = dt.StockDirection, @TypeCode = dt.Code, @SourceId = d.SourceDocumentId
        FROM sales.SalesDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 64006, 'Document not found.', 1;
        IF @Status <> 2 THROW 64010, 'Only posted documents can be cancelled (delete drafts instead).', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 64004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE SourceDocumentId = @Id AND Status = 2)
            THROW 64010, 'This invoice cannot be cancelled: posted returns refer to it. Cancel those first.', 1;

        /* A CANCELLED INVOICE CANNOT KEEP MONEY APPLIED TO IT. Receipts allocated to it would be paying
           an invoice that no longer exists, and the customer's balance would quietly be wrong. The
           receipt has to be reversed (or its allocation removed) first, so somebody decides what
           happens to the money. Only receipts that are POSTED count: a draft allocates nothing yet. */
        /* THE AUTOMATIC RECEIPT OF A CASH INVOICE IS THE ONE EXCEPTION: it was made with the invoice,
           so it is undone with it - reversed here, in this transaction, with the reason. Money any
           OTHER receipt has put on the invoice is still somebody's decision and still blocks. */
        DECLARE @AutoReceiptId INT = (SELECT TOP (1) Id FROM sales.Receipts WHERE SourceSalesDocumentId = @Id AND Status = 2);
        IF EXISTS (SELECT 1 FROM sales.ReceiptAllocations a
                   INNER JOIN sales.Receipts r ON r.Id = a.ReceiptId
                   WHERE a.SalesDocumentId = @Id AND a.RemovedAtUtc IS NULL AND r.Status = 2
                     AND r.Id <> ISNULL(@AutoReceiptId, 0))
            THROW 64010, 'This invoice cannot be cancelled: receipts have been applied to it. Reverse those receipts first.', 1;

        IF @AutoReceiptId IS NOT NULL
        BEGIN
            DECLARE @RcReason NVARCHAR(500) = N'Invoice cancelled: ' + @Reason;
            EXEC sales.usp_Receipt_Reverse @Id = @AutoReceiptId, @Reason = @RcReason, @RowVersion = NULL, @UserId = @UserId, @FromInvoiceCancel = 1;
            INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'ReceiptReversed', N'Cash sale: receipt ' + (SELECT ReceiptNumber FROM sales.Receipts WHERE Id = @AutoReceiptId) + N' reversed', @UserId);
        END

        IF @Direction = 1
        BEGIN
            DECLARE @Msg NVARCHAR(400);
            SELECT TOP (1) @Msg = N'Cannot cancel: ' + i.ItemCode + N' in ' + w.WarehouseCode + N' has only '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N' left, but this document added ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM sales.SalesDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 64007, @Msg, 1;
        END

        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, IsReversal, CreatedBy)
        SELECT SYSUTCDATETIME(), m.ItemId, m.WarehouseId, m.BranchId, -m.QuantityBase, m.UnitCostBase,
               m.DocumentFamily, m.DocumentTypeCode, m.DocumentId, m.DocumentLineId, m.DocumentNumber, m.ReasonCode, m.ExpiryDate, 1, @UserId
        FROM inventory.StockMovements m
        WHERE m.DocumentFamily = N'Sales' AND m.DocumentId = @Id AND m.IsReversal = 0;

        IF @TypeCode = N'SRET' AND @SourceId IS NOT NULL
            UPDATE s SET ReturnedQuantityBase = s.ReturnedQuantityBase - x.Qty
            FROM sales.SalesDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM sales.SalesDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;

        UPDATE sales.SalesDocuments
        SET Status = 3, CancelledAtUtc = SYSUTCDATETIME(), CancelledBy = @UserId, CancelReason = @Reason,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@Id, N'Cancelled', @Reason, @UserId);

        -- A cancelled return was a receipt: replay the cost history of its items.
        IF @Direction = 1
        BEGIN
            DECLARE @ItemId INT;
            DECLARE items CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT ItemId FROM sales.SalesDocumentLines WHERE DocumentId = @Id;
            OPEN items; FETCH NEXT FROM items INTO @ItemId;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC inventory.usp_Item_RebuildCosts @ItemId;
                FETCH NEXT FROM items INTO @ItemId;
            END
            CLOSE items; DEALLOCATE items;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

