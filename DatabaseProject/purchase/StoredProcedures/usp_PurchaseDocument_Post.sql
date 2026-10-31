/* ================================================================== 8. Posting an invoice: the type's two switches captured, and its goods received */

-- Re-created (79) from the body of script 77:
--   - a supplier invoice captures its type's AffectsItemCost and AffectsOnHand in the same UPDATE that posts it (before
--     the rematch and the true-up, which read AffectsCost through section 3);
--   - AffectsOnHand: once the invoice is committed, its goods are received as "Receive the goods now" does, without
--     the tick - the type's rule, whoever posts (no goods receipt right is needed: the rule is the type's); a receipt
--     that fails leaves the invoice posted, with the reason in @ReceiveWarning as before;
--   - a return from an invoice that does not change item costs goes out at the base cost of the matched receipt
--     lines (section 7);
--   - the answer's row says what the type made of it (ReceiveOnPost, AffectsCost).
CREATE   PROCEDURE purchase.usp_PurchaseDocument_Post
    @Id         INT,
    @RowVersion   BINARY(8) = NULL,
    @UserId       INT       = NULL,
    @FromApproval BIT       = 0,     -- 1 = called by the approval
    -- (65) "Receive the goods now" (a supplier invoice only): once the invoice is posted and committed, its lines not in
    --      a container are received with a goods receipt, created and posted in a second transaction. The API passes 1
    --      only for a user who may also create and post goods receipts. A receipt that fails leaves the invoice posted
    --      and says why in @ReceiveWarning.
    @ReceiveNow         BIT           = 0,
    @GoodsReceiptId     INT           = NULL OUTPUT,
    @GoodsReceiptNumber NVARCHAR(30)  = NULL OUTPUT,
    @ReceiveWarning     NVARCHAR(700) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SELECT @GoodsReceiptId = NULL, @GoodsReceiptNumber = NULL, @ReceiveWarning = NULL;
    -- (65) the cost of goods already received, brought to this invoice's price (usp_GoodsReceipt_TrueUpCost)
    DECLARE @CostAmount DECIMAL(18,2) = 0, @CostInventory DECIMAL(18,2) = 0, @CostCogs DECIMAL(18,2) = 0, @CostLines INT = 0;
    -- (79) what the type says when the invoice is posted, captured on it: its price becomes the cost of the goods received
    --      against it (AffectsItemCost), posting it receives its goods (AffectsOnHand)
    DECLARE @AffectsCost BIT = 1, @AutoReceive BIT = 0;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- (65) lock order: the goods receipt matcher first, then rows, or two postings deadlock. Only a supplier invoice or
        --      a return (their type, read without a lock: it never changes).
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                   WHERE d.Id = @Id AND dt.Code IN (N'PINV', N'PRET'))
            EXEC purchase.usp_GoodsReceipt_LockMatching;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Direction SMALLINT, @Number NVARCHAR(30), @DocumentDate DATE,
                @BranchId INT, @SupplierId INT, @Rate DECIMAL(18,6), @SourceId INT, @ReceiptMode TINYINT,
                @OneItemOnly BIT;

        SELECT @Status = d.Status, @TypeCode = dt.Code, @Direction = dt.StockDirection, @Number = d.DocumentNumber,
               @DocumentDate = d.DocumentDate, @BranchId = d.BranchId, @SupplierId = d.SupplierId, @Rate = d.ExchangeRate,
               @SourceId = d.SourceDocumentId, @ReceiptMode = d.ReceiptMode,
               @OneItemOnly = d.OneItemOnly,
               @AffectsCost = CASE WHEN dt.Code = N'PINV' THEN dt.AffectsItemCost ELSE 1 END,
               @AutoReceive = CASE WHEN dt.Code = N'PINV' THEN dt.AffectsOnHand ELSE 0 END
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @TypeCode = N'PO' AND ISNULL(@FromApproval, 0) = 1 AND @Status <> 5
            THROW 65010, 'Only a purchase order waiting for approval can be approved.', 1;
        IF (@TypeCode <> N'PO' OR ISNULL(@FromApproval, 0) = 0) AND @Status <> 1
            THROW 65010, 'Only draft documents can be posted.', 1;

        DECLARE @PostedWithoutApproval BIT = CASE WHEN @TypeCode = N'PO' AND ISNULL(@FromApproval, 0) = 0 THEN 1 ELSE 0 END;
        IF @PostedWithoutApproval = 1 AND purchase.fn_PurchaseOrder_NeedsApproval(@Id) = 1
            THROW 65013, 'This order needs approval: send it for approval.', 1;

        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id)
            THROW 65009, 'The document has no lines. Add at least one item before posting.', 1;

        -- (45) A supplier invoice holds ONE item: a draft saved with several before script 45 is split first.
        -- (63) Only when its mode is one item: its own, or the setting when it has none (saved before script 63).
        IF @TypeCode = N'PINV' AND COALESCE(@OneItemOnly, configuration.fn_SettingBool(N'Purchase.OneItemPerInvoice')) = 1
           AND (SELECT COUNT(DISTINCT ItemId) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id) > 1
        BEGIN
            DECLARE @ItemCount INT = (SELECT COUNT(DISTINCT ItemId) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id),
                    @ItemCodes NVARCHAR(400);
            SELECT @ItemCodes = STRING_AGG(x.ItemCode, N', ') WITHIN GROUP (ORDER BY x.FirstLine)
            FROM (SELECT TOP (5) i.ItemCode, FirstLine = MIN(l.LineNumber)
                  FROM purchase.PurchaseDocumentLines l INNER JOIN inventory.Items i ON i.Id = l.ItemId
                  WHERE l.DocumentId = @Id
                  GROUP BY l.ItemId, i.ItemCode
                  ORDER BY MIN(l.LineNumber)) x;
            SET @ItemCodes = N'A supplier invoice holds one item. This one has ' + CAST(@ItemCount AS NVARCHAR(10)) + N': ' + @ItemCodes
                         + CASE WHEN @ItemCount > 5 THEN N'...' ELSE N'.' END + N' Create one invoice per item, or use Split by item.';
            THROW 65029, @ItemCodes, 1;
        END
        IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SupplierId AND IsActive = 1)
            THROW 65008, 'The supplier is inactive.', 1;

        -- Imports: the goods are received by the container, not by this posting.
        -- (65) EVERY SUPPLIER INVOICE, whatever its receipt mode: goods enter stock only through a posted goods receipt.
        --      The invoice still gets its FOB, its charges and its landed cost per line (the INVOICE COST that received
        --      goods are valued at or corrected to), and it is marked UsesGoodsReceipts = 1 when it is posted below.
        --      Returns still take their goods out at posting. (Was @ReceiveNow, now the name of the parameter.)
        DECLARE @StockAtPosting BIT = CASE WHEN @TypeCode = N'PINV' THEN 0 ELSE 1 END;

        DECLARE @FromContainers BIT = CASE WHEN @TypeCode = N'PINV' AND EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines
                                                                                WHERE DocumentId = @Id AND ContainerLineId IS NOT NULL) THEN 1 ELSE 0 END;
        -- (43) Shipped in containers: an imported invoice, linked to its containers now or later. Lines not in a container
        --      yet are allowed: they enter the stock at the offload of the containers they are linked to afterwards.
        IF @TypeCode = N'PINV' AND @ReceiptMode = 2
        BEGIN
            IF NULLIF(LTRIM(RTRIM((SELECT ExporterReference FROM purchase.PurchaseDocuments WHERE Id = @Id))), N'') IS NULL
                THROW 65018, 'The exporter reference is required on an imported invoice. Enter it before posting.', 1;
            IF EXISTS (SELECT 1 FROM purchase.PurchaseCharges WHERE DocumentKind = N'PINV' AND DocumentId = @Id)
                THROW 65020, 'This invoice has its own charges. Remove them: the charges of an import are entered on its containers.', 1;
        END

        IF @FromContainers = 1
        BEGIN

            -- (65) A container received with a goods receipt can be invoiced (the goods may arrive first): only a cancelled
            --      container, or one offloaded before goods receipts, is refused - and more than the loaded pieces.
            DECLARE @CtMsg NVARCHAR(400);
            SELECT TOP (1) @CtMsg = N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                                    + CASE WHEN c.Status = 8 OR (c.Status IN (6, 7) AND rb.ReceivedBy = N'Offload')
                                           THEN N'the container is cancelled or was offloaded before goods receipts.'
                                           ELSE CAST(q.Here AS NVARCHAR(20)) + N' invoiced here + ' + CAST(ISNULL(o.Posted, 0) AS NVARCHAR(20))
                                                + N' in posted invoices, but only ' + CAST(cl.QuantityBase AS NVARCHAR(20)) + N' are loaded.' END
            FROM (SELECT ContainerLineId, Here = SUM(QuantityBase) FROM purchase.PurchaseDocumentLines
                  WHERE DocumentId = @Id GROUP BY ContainerLineId) q
            INNER JOIN logistics.ContainerLines cl ON cl.Id = q.ContainerLineId
            INNER JOIN logistics.Containers c      ON c.Id = cl.ContainerId
            INNER JOIN inventory.Items i           ON i.Id = cl.ItemId
            OUTER APPLY (SELECT Posted = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                         INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                         WHERE pil.ContainerLineId = cl.Id AND pd.Status IN (2, 4) AND pd.Id <> @Id) o
            CROSS APPLY logistics.fn_Container_ReceivedBy(c.Id) rb
            WHERE c.Status = 8 OR (c.Status IN (6, 7) AND rb.ReceivedBy = N'Offload') OR q.Here + ISNULL(o.Posted, 0) > cl.QuantityBase
            ORDER BY c.ContainerRef, cl.LineNumber;
            IF @CtMsg IS NOT NULL THROW 65019, @CtMsg, 1;
        END

        DECLARE @Msg NVARCHAR(400);
        SELECT TOP (1) @Msg =
            CASE WHEN i.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item ' + i.ItemCode + N' is inactive.'
                 WHEN w.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is inactive.' END
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id AND (i.IsActive = 0 OR w.IsActive = 0)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 65000, @Msg, 1;

        -- A parent warehouse holds no stock of its own: a line takes a warehouse at the bottom of the tree (script 70).
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' has warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree.'
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id AND masterdata.fn_Warehouse_IsLeaf(w.Id) = 0
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 65000, @Msg, 1;

        IF @SourceId IS NOT NULL
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @SourceId AND Status = 2)
                THROW 65011, 'The source document is no longer open (cancelled).', 1;

            IF @TypeCode = N'PINV'
            BEGIN
                SELECT TOP (1) @Msg = N'Line ' + CAST(x.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - ' + CAST(x.Qty AS NVARCHAR(20))
                                     + N' base units invoiced but only ' + CAST(s.QuantityBase - s.ReceivedQuantityBase AS NVARCHAR(20)) + N' remain on the order line.'
                FROM (SELECT SourceLineId, SUM(QuantityBase) AS Qty, MIN(LineNumber) AS LineNumber FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x
                INNER JOIN purchase.PurchaseDocumentLines s ON s.Id = x.SourceLineId
                INNER JOIN inventory.Items i ON i.Id = s.ItemId
                WHERE x.Qty > s.QuantityBase - s.ReceivedQuantityBase
                ORDER BY x.LineNumber;
                IF @Msg IS NOT NULL THROW 65011, @Msg, 1;
            END
            IF @TypeCode = N'PRET'
            BEGIN
                -- (65) From an invoice that uses goods receipts, or is shipped in containers, only what was RECEIVED and not
                --      returned yet goes back (rule 23): goods received but not invoiced, or invoiced but not received, are
                --      not on the invoice line. An invoice posted with its stock before goods receipts keeps invoiced - returned.
                --      The source lines are locked until the return raises their ReturnedQuantityBase below, so what they
                --      received cannot move in between (the matching lock above keeps goods receipts out meanwhile).
                SELECT TOP (1) @Msg = N'Line ' + CAST(x.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - ' + CAST(x.Qty AS NVARCHAR(20))
                                     + CASE WHEN g.ByReceipts = 1
                                            THEN N' base units returned but only ' + CAST(CASE WHEN g.Avail > 0 THEN g.Avail ELSE 0 END AS NVARCHAR(20))
                                                 + N' were received and not returned on the invoice line.'
                                            ELSE N' base units returned but only ' + CAST(s.QuantityBase - s.ReturnedQuantityBase AS NVARCHAR(20)) + N' can still be returned from the invoice line.' END
                FROM (SELECT SourceLineId, SUM(QuantityBase) AS Qty, MIN(LineNumber) AS LineNumber FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x
                INNER JOIN purchase.PurchaseDocumentLines s WITH (UPDLOCK, HOLDLOCK) ON s.Id = x.SourceLineId
                INNER JOIN purchase.PurchaseDocuments sd    ON sd.Id = s.DocumentId
                INNER JOIN inventory.Items i ON i.Id = s.ItemId
                CROSS APPLY (SELECT ByReceipts = CASE WHEN sd.UsesGoodsReceipts = 1 OR sd.ReceiptMode = 2 THEN 1 ELSE 0 END,
                                    Avail      = CASE WHEN sd.UsesGoodsReceipts = 1 OR sd.ReceiptMode = 2 THEN s.ReceivedQuantityBase - s.ReturnedQuantityBase
                                                      ELSE s.QuantityBase - s.ReturnedQuantityBase END) g
                WHERE x.Qty > g.Avail
                ORDER BY x.LineNumber;
                IF @Msg IS NOT NULL THROW 65011, @Msg, 1;
            END
        END

        IF @Direction = -1
        BEGIN
            SELECT TOP (1) @Msg = N'Insufficient stock for ' + i.ItemCode + N' in ' + w.WarehouseCode + N': available '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N', required ' + CAST(x.Qty AS NVARCHAR(20)) + N' (base units).'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 65007, @Msg, 1;
        END

        IF @Number IS NULL
            EXEC inventory.usp_DocumentType_NextNumber @TypeCode, @Number OUTPUT, @BranchId;

        IF @TypeCode = N'PINV'
        BEGIN
            -- FOB per base unit, then charges allocated over the lines, then landed cost per base unit.
            EXEC purchase.usp_PurchaseCharges_Allocate N'PINV', @Id, @Id;

            UPDATE l
            SET FobCostBase = (l.LineTotal / @Rate) / l.QuantityBase,
                AllocatedChargesBase = ISNULL(a.Total, 0),
                UnitCostBase = ((l.LineTotal / @Rate) + ISNULL(a.Total, 0)) / l.QuantityBase
            FROM purchase.PurchaseDocumentLines l
            OUTER APPLY (SELECT SUM(x.AmountBase) AS Total
                         FROM purchase.PurchaseChargeAllocations x
                         INNER JOIN purchase.PurchaseCharges c ON c.Id = x.ChargeId
                         WHERE x.PurchaseLineId = l.Id AND c.DocumentKind = N'PINV' AND c.DocumentId = @Id AND c.IncludeInLandedCost = 1) a
            WHERE l.DocumentId = @Id;

            UPDATE d
            SET TotalChargesBase = ISNULL(x.Charges, 0), TotalLandedCostBase = d.TotalAmountBase + ISNULL(x.Charges, 0)
            FROM purchase.PurchaseDocuments d
            CROSS APPLY (SELECT SUM(AllocatedChargesBase) AS Charges FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id) x
            WHERE d.Id = @Id;
        END
        ELSE IF @TypeCode = N'PRET'
        BEGIN
            -- (65) Rule 23: from an invoice that uses goods receipts, or is shipped in containers, the goods go back at the
            --      invoice line's OWN CURRENT cost, worked out again now (a landed cost adjustment or a late container
            --      charge may have moved it since the draft): its landed cost, or for a container line its FOB + the
            --      container line's charges per piece received; for a line NOT linked whose pieces are matched to goods
            --      received in containers, those containers' charges per matched piece (as usp_PurchaseDocument_Save).
            --      The FOB is the invoice line's.
            -- (79) From an invoice that does not change item costs: the base cost of the receipt lines matched to the
            --      invoice line, what its pieces entered stock at (usp_PurchaseDocument_Save); none -> the average, below.
            UPDATE l
            SET UnitCostBase = CASE WHEN sd.AffectsCost = 0 THEN rc.Unit
                                    WHEN scl.Id IS NOT NULL THEN src.FobCostBase + ISNULL(scl.ChargesBase / NULLIF(scl.ReceivedQuantityBase, 0), 0)
                                    WHEN mc.CtPcs > 0 THEN (mc.CtPcs * src.FobCostBase + mc.CtCharges + (mc.Pcs - mc.CtPcs) * src.UnitCostBase) / mc.Pcs
                                    ELSE src.UnitCostBase END,
                FobCostBase  = CASE WHEN sd.AffectsCost = 0 THEN rc.Fob ELSE src.FobCostBase END
            FROM purchase.PurchaseDocumentLines l
            INNER JOIN purchase.PurchaseDocumentLines src ON src.Id = l.SourceLineId
            INNER JOIN purchase.PurchaseDocuments sd      ON sd.Id = src.DocumentId
            LEFT  JOIN logistics.ContainerLines scl       ON scl.Id = src.ContainerLineId
            OUTER APPLY (SELECT Pcs       = SUM(m.QuantityBase),
                                CtPcs     = SUM(CASE WHEN gl.ContainerLineId IS NOT NULL THEN m.QuantityBase ELSE 0 END),
                                CtCharges = SUM(CASE WHEN gl.ContainerLineId IS NOT NULL
                                                     THEN m.QuantityBase * ISNULL(mcl.ChargesBase / NULLIF(mcl.ReceivedQuantityBase, 0), 0)
                                                     ELSE 0 END)
                         FROM purchase.GoodsReceiptInvoiceMatches m
                         INNER JOIN purchase.GoodsReceiptLines gl ON gl.Id = m.GoodsReceiptLineId
                         LEFT  JOIN logistics.ContainerLines mcl  ON mcl.Id = gl.ContainerLineId
                         WHERE m.InvoiceLineId = src.Id AND src.ContainerLineId IS NULL) mc
            -- (79) an invoice that does not change item costs: its pieces entered stock at their receipt line's BASE cost (the
            --      order price, or a manual line's cost; a container line adds its container's charges per piece), so they
            --      go back at that cost - never at the line's current cost, which blends in the price of any invoice that
            --      does change costs matched to the same line (that difference would stay in stock for good: the later
            --      true-ups work per line, on its net received pieces)
            OUTER APPLY (SELECT Unit = SUM(m.QuantityBase * (t.BaseFobBase + CASE WHEN t.IsContainerLine = 1 THEN t.TargetChargesBase
                                                                                   ELSE t.BaseChargesBase END))
                                       / NULLIF(SUM(m.QuantityBase), 0),
                                Fob  = SUM(m.QuantityBase * t.BaseFobBase) / NULLIF(SUM(m.QuantityBase), 0)
                         FROM purchase.GoodsReceiptInvoiceMatches m
                         INNER JOIN purchase.GoodsReceiptLines gl ON gl.Id = m.GoodsReceiptLineId
                         CROSS APPLY purchase.fn_GoodsReceiptLine_TargetCost(gl.GoodsReceiptId) t
                         WHERE sd.AffectsCost = 0 AND m.InvoiceLineId = src.Id AND t.GoodsReceiptLineId = gl.Id) rc
            WHERE l.DocumentId = @Id AND (sd.UsesGoodsReceipts = 1 OR sd.ReceiptMode = 2) AND src.FobCostBase IS NOT NULL;

            UPDATE l SET UnitCostBase = ISNULL(l.UnitCostBase, ISNULL(inventory.fn_AverageCost(l.ItemId), 0))
            FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = @Id;
        END

        IF @Direction = 1 AND @StockAtPosting = 1
        BEGIN
            DECLARE @R inventory.tvp_ItemReceipt;
            INSERT INTO @R (ItemId, QuantityBase, UnitCostBase, FobCostBase)
            SELECT l.ItemId, l.QuantityBase, ISNULL(l.UnitCostBase, 0), l.FobCostBase FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = @Id;
            EXEC inventory.usp_Item_ApplyReceipts @R, @SupplierId, @UserId, 1;
        END

        IF @Direction <> 0 AND @StockAtPosting = 1
        BEGIN
            DECLARE @MovementDate DATETIME2(3) =
                DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@DocumentDate AS DATETIME2(3)));

            INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                                  DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, CreatedBy)
            -- (48) the branch of the line's warehouse, which need not be the document's branch
            SELECT @MovementDate, l.ItemId, l.WarehouseId, w.BranchId, @Direction * l.QuantityBase, l.UnitCostBase,
                   N'Purchase', @TypeCode, @Id, l.Id, @Number, NULL, l.ExpiryDate, @UserId
            FROM purchase.PurchaseDocumentLines l
            INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
            WHERE l.DocumentId = @Id;

            IF @Direction = 1
                UPDATE purchase.PurchaseDocumentLines SET ReceivedQuantityBase = QuantityBase WHERE DocumentId = @Id;
        END

        IF @SourceId IS NOT NULL AND @TypeCode = N'PINV'
        BEGIN
            UPDATE s SET ReceivedQuantityBase = s.ReceivedQuantityBase + x.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;

            -- (77) An order no longer closes: it stays approved (2), and what it shows - Saved, Partially posted, Posted -
            --      follows its POSTED invoices (purchase.fn_PurchaseOrder_Invoicing). The order's history says which
            --      invoice completed it; the goods may still be to receive, and are received as before.
            IF (SELECT InvoicingStatus FROM purchase.fn_PurchaseOrder_Invoicing(@SourceId)) = 2
                INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
                VALUES (@SourceId, N'Updated', N'Fully invoiced by ' + @Number, @UserId);
        END
        IF @SourceId IS NOT NULL AND @TypeCode = N'PRET'
        BEGIN
            UPDATE s SET ReturnedQuantityBase = s.ReturnedQuantityBase + x.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;
        END

        -- (65) A supplier invoice is marked as using goods receipts WHEN IT IS POSTED (never as a draft): from now on its
        --      lines are matched to received pieces, and their ReceivedQuantityBase is the pieces matched to them.
        UPDATE purchase.PurchaseDocuments
        SET DocumentNumber = @Number, Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId,
            UsesGoodsReceipts = CASE WHEN @TypeCode = N'PINV' THEN 1 ELSE UsesGoodsReceipts END,
            -- (79) captured from the type now, before the rematch below reads AffectsCost: changing the type later never
            --      re-prices or re-receives this invoice
            AffectsCost       = CASE WHEN @TypeCode = N'PINV' THEN @AffectsCost ELSE AffectsCost END,
            ReceiveOnPost     = CASE WHEN @TypeCode = N'PINV' THEN @AutoReceive ELSE ReceiveOnPost END,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        -- (65) GOODS ALREADY RECEIVED FOLLOW THIS INVOICE'S COST. Its pieces are matched to the received pieces of its
        --      groups - each order line it invoices, and the supplier + item for lines without an order - now that it is
        --      posted (usp_GoodsReceipt_Rematch, first in first out); then every posted receipt line of those groups is
        --      brought to its target cost (usp_GoodsReceipt_TrueUpCost, cause PINV): the part still in stock to the
        --      stock value, the rest to cost of sales.
        IF @TypeCode = N'PINV'
        BEGIN
            DECLARE @Anchors purchase.tvp_GoodsReceiptAnchor;
            INSERT INTO @Anchors (Kind, PoLineId, SupplierId, ItemId)
            SELECT DISTINCT 'P', l.SourceLineId, NULL, NULL FROM purchase.PurchaseDocumentLines l
            WHERE l.DocumentId = @Id AND l.SourceLineId IS NOT NULL
            UNION
            SELECT DISTINCT 'S', NULL, @SupplierId, l.ItemId FROM purchase.PurchaseDocumentLines l
            WHERE l.DocumentId = @Id AND l.SourceLineId IS NULL;

            EXEC purchase.usp_GoodsReceipt_Rematch @Anchors;

            DECLARE @GroupLines logistics.tvp_IdList;
            INSERT INTO @GroupLines (Id) SELECT GoodsReceiptLineId FROM purchase.fn_GoodsReceipt_GroupLines(@Anchors);
            IF EXISTS (SELECT 1 FROM @GroupLines)
                EXEC purchase.usp_GoodsReceipt_TrueUpCost @GroupLines, N'PINV', @Id, @Number, @UserId,
                     @CostAmount OUTPUT, @CostInventory OUTPUT, @CostCogs OUTPUT, @CostLines OUTPUT;
        END

        DECLARE @LineCount INT = (SELECT COUNT(*) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id);
        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@Id, N'Posted', LEFT(N'Posted as ' + @Number + N' - ' + CAST(@LineCount AS NVARCHAR(10)) + N' line(s)'
                                + CASE WHEN @Direction <> 0 AND @StockAtPosting = 1 THEN N' written to the stock ledger'
                                       WHEN @StockAtPosting = 0 THEN N'; goods are received with goods receipts'     -- (65) every supplier invoice
                                       WHEN @PostedWithoutApproval = 1 THEN N' (approval not needed)'
                                       ELSE N' (order approved)' END
                                + CASE WHEN @TypeCode = N'PINV' THEN N'; landed charges ' + CAST((SELECT TotalChargesBase FROM purchase.PurchaseDocuments WHERE Id = @Id) AS NVARCHAR(30)) ELSE N'' END
                                + CASE WHEN @TypeCode = N'PINV' AND @AffectsCost = 0 THEN N'; does not change item costs' ELSE N'' END   -- (79)
                                + CASE WHEN @CostLines > 0 THEN N'; cost of received goods adjusted by ' + CAST(@CostAmount AS NVARCHAR(30))
                                                                + N' (stock ' + CAST(@CostInventory AS NVARCHAR(30)) + N', cost of sales ' + CAST(@CostCogs AS NVARCHAR(30)) + N')'
                                       ELSE N'' END, 500), @UserId);

        -- A purchase order posted without approval: the user who posts it is recorded as approver, as an approval does.
        IF @PostedWithoutApproval = 1
        BEGIN
            UPDATE purchase.PurchaseDocuments SET ApprovedAtUtc = SYSUTCDATETIME(), ApprovedBy = @UserId WHERE Id = @Id;

            DECLARE @RequireApproval BIT, @ApprovalLimit DECIMAL(19, 4);
            SELECT @RequireApproval = RequireApproval, @ApprovalLimit = ApprovalLimitBase FROM purchase.ApprovalSettings WHERE Id = 1;
            INSERT INTO purchase.PurchaseOrderApprovalEvents (PurchaseDocumentId, EventType, UserId, Note)
            VALUES (@Id, 7, @UserId,
                    CASE WHEN @RequireApproval = 0 THEN N'Approval not required'
                         ELSE N'Under the approval limit of ' + FORMAT(@ApprovalLimit, N'N2', N'en-US')
                              + ISNULL(N' ' + (SELECT TOP (1) CurrencyCode FROM masterdata.Currencies
                                               WHERE IsBaseCurrency = 1 AND IsActive = 1), N'') END);
        END

        -- containers of an import: the invoice is known now (value basis of the charges, history)
        IF @FromContainers = 1
        BEGIN
            DECLARE @Cid INT;
            DECLARE cts CURSOR LOCAL FAST_FORWARD FOR
                SELECT DISTINCT cl.ContainerId FROM purchase.PurchaseDocumentLines l
                INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
                WHERE l.DocumentId = @Id;
            OPEN cts;
            FETCH NEXT FROM cts INTO @Cid;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC logistics.usp_Container_ReallocateCharges @Cid, 1, 1;
                INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
                VALUES (@Cid, N'Updated', N'Purchase invoice ' + @Number + N' posted', @UserId);
                FETCH NEXT FROM cts INTO @Cid;
            END
            CLOSE cts;
            DEALLOCATE cts;
        END

        COMMIT TRANSACTION;
        -- (65) + what the posting did to the cost of goods already received (0 when nothing)
        IF ISNULL(@FromApproval, 0) = 0
            SELECT @Number AS DocumentNumber, CostAdjustedBase = @CostAmount, CostAdjustedInventoryBase = @CostInventory,
                   CostAdjustedCogsBase = @CostCogs, CostAdjustedLines = @CostLines,
                   ReceiveOnPost = @AutoReceive, AffectsCost = @AffectsCost;      -- (79) what the type made of it
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    /* (65) "RECEIVE THE GOODS NOW" (decision 7): the invoice is posted and committed above, whatever happens here. Its
       lines not in a container are received with ONE goods receipt (usp_GoodsReceipt_CreateFromInvoice: every line with
       something to receive, into the line's warehouse, dated like the invoice) and posted at once
       (usp_GoodsReceipt_Post), in a second transaction: all or nothing, so a refusal leaves no draft behind and
       "Receive goods..." on the invoice still offers everything. The refusal comes back in @ReceiveWarning; the
       receipt's id and number in @GoodsReceiptId / @GoodsReceiptNumber. usp_GoodsReceipt_Post returns its own
       DocumentNumber as a further result set, after the invoice's row: the receipt's outcome is read from the OUTPUT
       parameters. Inside a caller's transaction there is no second transaction to make: nothing is received. */
    /* (79) THE TYPE'S RULE (Affects on-hand): the same receipt, whoever posts and however (the page, Post selected, an
       import that posts) - for an invoice not shipped in containers with something to receive; otherwise there is
       nothing for it to do, and it says nothing (its container lines are received with their containers). A tick of
       "Receive the goods now" keeps its own answer, a refusal included. */
    DECLARE @Receive BIT = CASE WHEN ISNULL(@ReceiveNow, 0) = 1 AND @TypeCode = N'PINV' THEN 1 ELSE 0 END;
    IF @Receive = 0 AND @AutoReceive = 1 AND @TypeCode = N'PINV' AND ISNULL(@ReceiptMode, 1) <> 2
       AND EXISTS (SELECT 1 FROM purchase.fn_InvoiceLine_ToReceive(@Id) t WHERE t.ToReceiveBase > 0)
        SET @Receive = 1;

    IF @Receive = 1
    BEGIN
        DECLARE @ReceiptId INT = NULL, @ReceiptReason NVARCHAR(600) = NULL, @ReceiptDate DATE = @DocumentDate;
        IF @@TRANCOUNT > 0
            SET @ReceiptReason = N'it is made in a transaction of its own, and this posting runs inside another one';
        ELSE
        BEGIN
            BEGIN TRY
                BEGIN TRANSACTION;

                -- the matcher first, before the draft's rows are written (usp_GoodsReceipt_Post takes it again)
                EXEC purchase.usp_GoodsReceipt_LockMatching;

                DECLARE @NoLines purchase.tvp_GoodsReceiptLine;
                EXEC purchase.usp_GoodsReceipt_CreateFromInvoice @InvoiceId = @Id, @Lines = @NoLines, @DocumentDate = @ReceiptDate,
                     @UserId = @UserId, @NewId = @ReceiptId OUTPUT;
                EXEC purchase.usp_GoodsReceipt_Post @Id = @ReceiptId, @RowVersion = NULL, @UserId = @UserId;

                SELECT @GoodsReceiptId = Id, @GoodsReceiptNumber = DocumentNumber FROM purchase.GoodsReceipts WHERE Id = @ReceiptId;
                COMMIT TRANSACTION;
            END TRY
            BEGIN CATCH
                IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
                SELECT @GoodsReceiptId = NULL, @GoodsReceiptNumber = NULL, @ReceiptReason = ERROR_MESSAGE();
            END CATCH
        END

        IF @ReceiptReason IS NOT NULL
        BEGIN
            -- "Invoice posted; the goods receipt was not: {reason}. Use Receive goods..." (one final period)
            SET @ReceiptReason = LTRIM(RTRIM(@ReceiptReason));
            IF RIGHT(@ReceiptReason, 1) = N'.' SET @ReceiptReason = LEFT(@ReceiptReason, LEN(@ReceiptReason) - 1);
            SET @ReceiveWarning = LEFT(N'Invoice posted; the goods receipt was not: ' + @ReceiptReason + N'. Use Receive goods' + NCHAR(8230), 700);
        END
    END
END

GO

