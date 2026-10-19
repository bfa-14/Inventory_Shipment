/* ================================================================== 18. Get */

/* ONE GOODS RECEIPT, 6 result sets (none when the id is unknown):
     1 header: names, the source documents, the Delivery movement that made it (number, type, route, end date) and the
       container's latest completed Delivery (place, date: "Delivered"), totals (expected, received, short, invoiced,
       value at receipt, current value - an estimate on a draft), Can* and the *BlockedReason sentences of
       fn_GoodsReceipt_Blocks (the same as the refusals), the switch date, RowVersion
     2 lines: item, unit, warehouse, supplier, order / invoice / container line, expected / received / difference /
       reason / settled short (an estimate on a draft), order price, current cost (the container line's for a
       container line), cost at receipt, cost source, invoiced, value
     3 matches: which posted invoice lines pay for which received pieces (invoice number, pieces, invoice FOB)
     4 cost changes (history of the cost of the received goods)
     5 files (no content), shaped as usp_GoodsReceipt_File_List
     6 audit, newest first */
CREATE   PROCEDURE purchase.usp_GoodsReceipt_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT g.Id, g.DocumentTypeId, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, DocumentTypeIsActive = dt.IsActive,
           g.DocumentNumber, g.DocumentDate, g.Status,
           StatusName = CASE g.Status WHEN 1 THEN N'Draft' WHEN 2 THEN N'Posted' ELSE N'Cancelled' END,
           g.SourceKind, g.IsAuto,
           g.BranchId, b.BranchCode, b.BranchName,
           g.WarehouseId, w.WarehouseCode, w.WarehouseName, WarehouseIsActive = w.IsActive,
           WarehouseInBranch = CAST(CASE WHEN w.Id IS NULL THEN NULL
                                         WHEN w.BranchId = ISNULL(c.BranchId, g.BranchId) THEN 1 ELSE 0 END AS BIT),
           g.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName,
           SupplierDisplayName = ISNULL(sp.PartyName, CASE WHEN g.SourceKind = N'Container' THEN N'Several suppliers' END),
           g.ContainerId, c.ContainerRef, c.ContainerNo, c.SealNo, c.TruckNo, c.WaybillNo, ContainerStatus = c.Status,
           ContainerBranchId = c.BranchId, ContainerWarehouseId = c.WarehouseId, ContainerWarehouseCode = cw.WarehouseCode,
           g.PurchaseOrderId, po.DocumentNumber AS PurchaseOrderNumber,
           g.PurchaseInvoiceId, pi.DocumentNumber AS PurchaseInvoiceNumber,
           g.MovementId, mv.MovementNo, MovementEndDate = mv.EndDate, MovementTypeName = mvt.TypeName, MovementStage = mvt.Stage,
           MovementFromName = mfp.PortName, MovementToName = mtp.PortName,
           DeliveryMovementId = ld.MovementId, DeliveryMovementNo = ld.MovementNo, DeliveredDate = ld.EndDate, DeliveryPlaceName = ld.PlaceName,
           g.SupplierReference, g.Notes,
           LineCount = ISNULL(tot.Lines, 0), g.TotalExpectedBase, g.TotalReceivedBase,
           TotalShortBase = ISNULL(CASE WHEN g.Status = 1 THEN tot.ShortDraft ELSE tot.Settled END, 0), TotalInvoicedBase = ISNULL(tot.Invoiced, 0),
           g.ValueAtReceiptBase, CurrentValueBase = ISNULL(val.Value, 0),
           IsValueEstimate = CAST(CASE WHEN g.Status = 1 THEN 1 ELSE 0 END AS BIT),
           BaseCurrencyCode = bc.CurrencyCode,
           g.PostedAtUtc, g.PostedBy, pu.FullName AS PostedByName,
           g.CancelledAtUtc, g.CancelledBy, xu.FullName AS CancelledByName, g.CancelReason,
           g.CreatedAtUtc, g.CreatedBy, cu.FullName AS CreatedByName, g.UpdatedAtUtc, g.UpdatedBy, uu.FullName AS UpdatedByName,
           CanEdit   = CAST(CASE WHEN g.Status = 1 THEN 1 ELSE 0 END AS BIT),
           CanPost   = CAST(CASE WHEN g.Status = 1 AND pb.Message IS NULL THEN 1 ELSE 0 END AS BIT),
           CanCancel = CAST(CASE WHEN g.Status = 2 AND cb.Message IS NULL THEN 1 ELSE 0 END AS BIT),
           CanDelete = CAST(CASE WHEN g.Status = 1 THEN 1 ELSE 0 END AS BIT),
           EditBlockedReason = eb.Message, PostBlockedReason = pb.Message, CancelBlockedReason = cb.Message, DeleteBlockedReason = db.Message,
           SwitchedAtUtc = (SELECT s.SwitchedAtUtc FROM purchase.GoodsReceiptSwitch s WHERE s.Id = 1),
           g.RowVersion
    FROM purchase.GoodsReceipts g
    INNER JOIN inventory.DocumentTypes dt   ON dt.Id = g.DocumentTypeId
    INNER JOIN masterdata.Branches b        ON b.Id = g.BranchId
    LEFT  JOIN masterdata.Warehouses w      ON w.Id = g.WarehouseId
    LEFT  JOIN masterdata.Parties sp        ON sp.Id = g.SupplierId
    LEFT  JOIN logistics.Containers c       ON c.Id = g.ContainerId
    LEFT  JOIN masterdata.Warehouses cw     ON cw.Id = c.WarehouseId
    LEFT  JOIN purchase.PurchaseDocuments po ON po.Id = g.PurchaseOrderId
    LEFT  JOIN purchase.PurchaseDocuments pi ON pi.Id = g.PurchaseInvoiceId
    LEFT  JOIN logistics.Movements mv       ON mv.Id = g.MovementId
    LEFT  JOIN masterdata.MovementTypes mvt ON mvt.Id = mv.MovementTypeId
    LEFT  JOIN masterdata.Ports mfp         ON mfp.Id = mv.FromPlaceId
    LEFT  JOIN masterdata.Ports mtp         ON mtp.Id = mv.ToPlaceId
    LEFT  JOIN masterdata.Currencies bc     ON bc.IsBaseCurrency = 1 AND bc.IsActive = 1
    LEFT  JOIN security.Users pu ON pu.Id = g.PostedBy
    LEFT  JOIN security.Users xu ON xu.Id = g.CancelledBy
    LEFT  JOIN security.Users cu ON cu.Id = g.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = g.UpdatedBy
    OUTER APPLY logistics.fn_Container_LastDelivery(g.ContainerId) ld
    OUTER APPLY (SELECT Lines = COUNT(*), Invoiced = SUM(l.InvoicedBase),
                        Settled = SUM(l.SettledShortBase),
                        ShortDraft = SUM(CASE WHEN (l.ContainerLineId IS NOT NULL OR l.CloseShort = 1) AND l.ExpectedQuantityBase > l.QuantityBase
                                              THEN l.ExpectedQuantityBase - l.QuantityBase ELSE 0 END)
                 FROM purchase.GoodsReceiptLines l WHERE l.GoodsReceiptId = g.Id) tot
    OUTER APPLY (SELECT Value = SUM(k.ValueBase) FROM purchase.fn_GoodsReceiptLine_Cost(g.Id) k) val
    OUTER APPLY (SELECT TOP (1) k.Message FROM purchase.fn_GoodsReceipt_Blocks(g.Id) k WHERE k.Action = N'Post'   ORDER BY k.Seq) pb
    OUTER APPLY (SELECT TOP (1) k.Message FROM purchase.fn_GoodsReceipt_Blocks(g.Id) k WHERE k.Action = N'Cancel' ORDER BY k.Seq) cb
    OUTER APPLY (SELECT TOP (1) k.Message FROM purchase.fn_GoodsReceipt_Blocks(g.Id) k WHERE k.Action = N'Delete' ORDER BY k.Seq) db
    OUTER APPLY (SELECT TOP (1) k.Message FROM purchase.fn_GoodsReceipt_Blocks(g.Id) k WHERE k.Action = N'Edit'   ORDER BY k.Seq) eb
    WHERE g.Id = @Id;

    -- 2: lines
    SELECT l.Id, l.GoodsReceiptId, l.LineNumber, l.ItemId, i.ItemCode, i.ItemName,
           l.ItemUnitId, ut.UnitTypeName, iu.SkuCode, l.PackingFormula,
           l.Quantity, l.QuantityBase, l.ExpectedQuantityBase,
           DifferenceBase = l.QuantityBase - l.ExpectedQuantityBase,
           l.VarianceReasonCode,
           VarianceReasonName = CASE l.VarianceReasonCode WHEN N'SHORT' THEN N'Short-shipped' WHEN N'DAMAGED' THEN N'Damaged'
                                                          WHEN N'MISSING' THEN N'Missing' WHEN N'LOADCOUNT' THEN N'Wrongly counted at loading'
                                                          WHEN N'OTHER' THEN N'Other' END,
           l.VarianceReason, l.CloseShort,
           SettledShortBase = CASE WHEN g.Status <> 1 THEN l.SettledShortBase
                                   WHEN (l.ContainerLineId IS NOT NULL OR l.CloseShort = 1) AND l.ExpectedQuantityBase > l.QuantityBase
                                       THEN l.ExpectedQuantityBase - l.QuantityBase ELSE 0 END,
           l.WarehouseId, w.WarehouseCode, w.WarehouseName,
           l.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName,
           l.PurchaseOrderId, po.DocumentNumber AS OrderNumber, l.PoLineId, pol.LineNumber AS PoLineNumber,
           OrderedBase = pol.QuantityBase, OrderUnitTypeName = put.UnitTypeName, OrderPackingFormula = pol.PackingFormula,
           l.InvoiceLineId, InvoiceId = pil.DocumentId, pid.DocumentNumber AS InvoiceNumber, pil.LineNumber AS InvoiceLineNumber,
           l.ContainerLineId, cl.LineNumber AS ContainerLineNumber, LoadedBase = cl.QuantityBase,
           l.ExpiryDate,
           l.PoFobBase, k.OrderPriceBase, l.ManualUnitCostBase,
           FobCostBase = k.FobBase, ChargesBase = k.ChargesBase, UnitCostBase = k.UnitCostBase, IsCostEstimate = k.IsEstimate,
           l.CostAtReceiptBase, l.CostSource,
           CostSourceName = CASE l.CostSource WHEN N'Order' THEN N'Order price' WHEN N'Invoice' THEN N'Invoice'
                                              WHEN N'Mixed' THEN N'Order + invoice' WHEN N'Manual' THEN N'Typed' END,
           l.InvoicedBase, NotInvoicedBase = l.QuantityBase - l.InvoicedBase,
           k.ValueBase, l.Notes,
           ItemLastCost = i.LastCost, ItemAverageCost = i.AverageCost
    FROM purchase.GoodsReceiptLines l
    INNER JOIN purchase.GoodsReceipts g             ON g.Id = l.GoodsReceiptId
    INNER JOIN inventory.Items i                    ON i.Id = l.ItemId
    INNER JOIN inventory.ItemUnits iu               ON iu.Id = l.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut              ON ut.Id = iu.UnitTypeId
    LEFT  JOIN masterdata.Warehouses w              ON w.Id = l.WarehouseId
    LEFT  JOIN masterdata.Parties sp                ON sp.Id = l.SupplierId
    LEFT  JOIN purchase.PurchaseDocuments po        ON po.Id = l.PurchaseOrderId
    LEFT  JOIN purchase.PurchaseDocumentLines pol   ON pol.Id = l.PoLineId
    LEFT  JOIN inventory.ItemUnits piu              ON piu.Id = pol.ItemUnitId
    LEFT  JOIN masterdata.UnitTypes put             ON put.Id = piu.UnitTypeId
    LEFT  JOIN purchase.PurchaseDocumentLines pil   ON pil.Id = l.InvoiceLineId
    LEFT  JOIN purchase.PurchaseDocuments pid       ON pid.Id = pil.DocumentId
    LEFT  JOIN logistics.ContainerLines cl          ON cl.Id = l.ContainerLineId
    LEFT  JOIN purchase.fn_GoodsReceiptLine_Cost(@Id) k ON k.LineId = l.Id
    WHERE l.GoodsReceiptId = @Id
    ORDER BY l.LineNumber;

    -- 3: matches
    SELECT m.GoodsReceiptLineId, l.LineNumber, l.ItemId, i.ItemCode,
           m.InvoiceLineId, InvoiceId = pil.DocumentId, pid.DocumentNumber AS InvoiceNumber, pid.DocumentDate AS InvoiceDate,
           pid.PostedAtUtc AS InvoicePostedAtUtc, pil.LineNumber AS InvoiceLineNumber,
           m.QuantityBase, InvoiceFobBase = pil.FobCostBase, InvoiceUnitCostBase = pil.UnitCostBase, m.MatchedAtUtc
    FROM purchase.GoodsReceiptInvoiceMatches m
    INNER JOIN purchase.GoodsReceiptLines l       ON l.Id = m.GoodsReceiptLineId
    INNER JOIN inventory.Items i                  ON i.Id = l.ItemId
    INNER JOIN purchase.PurchaseDocumentLines pil ON pil.Id = m.InvoiceLineId
    INNER JOIN purchase.PurchaseDocuments pid     ON pid.Id = pil.DocumentId
    WHERE l.GoodsReceiptId = @Id
    ORDER BY l.LineNumber, pid.PostedAtUtc, pid.Id, pil.LineNumber;

    -- 4: cost changes
    SELECT cc.Id, cc.GoodsReceiptLineId, l.LineNumber, l.ItemId, i.ItemCode, i.ItemName,
           cc.ChangedAtUtc, cc.CauseKind, cc.CauseId, cc.CauseNumber, cc.ReceivedBase, cc.InStockBase,
           cc.FobBefore, cc.FobAfter, cc.UnitCostBefore, cc.UnitCostAfter, cc.AmountBase, cc.InventoryBase, cc.CogsBase,
           cc.CreatedBy, u.FullName AS CreatedByName
    FROM purchase.GoodsReceiptCostChanges cc
    INNER JOIN purchase.GoodsReceiptLines l ON l.Id = cc.GoodsReceiptLineId
    INNER JOIN inventory.Items i            ON i.Id = l.ItemId
    LEFT  JOIN security.Users u             ON u.Id = cc.CreatedBy
    WHERE l.GoodsReceiptId = @Id
    ORDER BY cc.ChangedAtUtc, cc.Id;

    -- 5: files (no content)
    SELECT f.Id, f.GoodsReceiptId AS DocumentId, f.FileName, f.ContentType, f.SizeBytes, f.AttachmentTypeId, t.Category, t.SubType,
           IsOther = CAST(CASE WHEN t.SubType = N'Other' AND t.Category IN (N'Other', N'General') THEN 1 ELSE 0 END AS BIT),
           f.DocumentDate, f.Note, f.CreatedAtUtc, f.CreatedBy, u.FullName AS CreatedByName
    FROM purchase.GoodsReceiptFiles f
    LEFT JOIN masterdata.AttachmentTypes t ON t.Id = f.AttachmentTypeId
    LEFT JOIN security.Users u             ON u.Id = f.CreatedBy
    WHERE f.GoodsReceiptId = @Id
    ORDER BY f.CreatedAtUtc DESC, f.Id DESC;

    -- 6: audit
    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM purchase.GoodsReceiptAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.GoodsReceiptId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;
END

GO

