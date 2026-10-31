/* ================================================================== 9. The invoice page reads them */

-- Re-created (79) from the body of script 77: + AffectsCost and ReceiveOnPost on the header. Nothing else changes.
CREATE   PROCEDURE purchase.usp_PurchaseDocument_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.Id, d.DocumentTypeId, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, dt.StockDirection, dt.NumberOnPost,
           d.DocumentNumber, d.DocumentDate, d.ExpectedDate,
           d.BranchId, b.BranchCode, b.BranchName, d.WarehouseId, w.WarehouseCode, w.WarehouseName,
           d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName, sp.Phone AS SupplierPhone, sp.Email AS SupplierEmail, sp.Address AS SupplierAddress,
           d.CurrencyId, c.CurrencyCode, c.CurrencyName, c.Symbol AS CurrencySymbol, c.DecimalPlaces, c.IsBaseCurrency,
           d.RateType, d.ExchangeRate, bc.CurrencyCode AS BaseCurrencyCode,
           d.SupplierReference, d.ExporterReference, d.CommercialInvoiceNo, d.ReceiptMode, d.Notes, d.Status,
           IsContainerBound = CAST(CASE WHEN EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines x
                                                    WHERE x.DocumentId = d.Id AND x.ContainerLineId IS NOT NULL) THEN 1 ELSE 0 END AS BIT),
           ContainerCount = CASE WHEN dt.Code = N'PO'
                                 THEN (SELECT COUNT(DISTINCT cl.ContainerId) FROM logistics.ContainerLines cl
                                       INNER JOIN logistics.Containers c9 ON c9.Id = cl.ContainerId
                                       WHERE cl.PurchaseOrderId = d.Id AND c9.Status <> 8)
                                 ELSE (SELECT COUNT(DISTINCT cl.ContainerId) FROM purchase.PurchaseDocumentLines x
                                       INNER JOIN logistics.ContainerLines cl ON cl.Id = x.ContainerLineId
                                       WHERE x.DocumentId = d.Id) END,
           LoadedBase = CASE WHEN dt.Code = N'PO'
                             THEN ISNULL((SELECT SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                                          INNER JOIN logistics.Containers c9 ON c9.Id = cl.ContainerId
                                          WHERE cl.PurchaseOrderId = d.Id AND c9.Status <> 8), 0) END,
           ContainerChargesBase = cch.Share,
           ContainersNeeded = need.Containers,     -- (43) invoices: sum over the items of the pieces / pieces per container
           d.ApprovalRequestedAtUtc, d.ApprovalRequestedBy, rqu.FullName AS ApprovalRequestedByName,
           d.ApprovedAtUtc, d.ApprovedBy, apu.FullName AS ApprovedByName, d.ApprovalChannel,
           d.RejectedAtUtc, d.RejectedBy, rju.FullName AS RejectedByName, d.RejectReason,
           OrderedBase = prog.Ordered, InvoicedBase = prog.Invoiced, InDraftInvoicesBase = ISNULL(drf.InDraft, 0),
           InvoicingStatus = CASE WHEN dt.Code <> N'PO' THEN NULL WHEN ISNULL(prog.Invoiced, 0) = 0 THEN 0
                                  WHEN prog.Invoiced >= prog.Ordered THEN 2 ELSE 1 END,      -- 0 not, 1 partially, 2 fully invoiced
           d.TotalItems, d.TotalQuantity, d.Subtotal, d.TotalDiscount, d.TotalAmount, d.TotalAmountBase, d.TotalChargesBase, d.TotalLandedCostBase,
           d.SourceDocumentId, src.DocumentNumber AS SourceDocumentNumber, sdt.Code AS SourceDocumentTypeCode,
           d.SourceShortageId, sh.DocumentNumber AS SourceShortageNumber,
           d.PostedAtUtc, d.PostedBy, pu.FullName AS PostedByName,
           d.CancelledAtUtc, d.CancelledBy, xu.FullName AS CancelledByName, d.CancelReason,
           d.ClosedAtUtc, d.ClosedBy, ku.FullName AS ClosedByName, d.CloseReason,
           d.CreatedAtUtc, d.CreatedBy, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.UpdatedBy, uu.FullName AS UpdatedByName,
           d.RowVersion,
           -- (47) supplier payments: posted purchase invoices only (NULL otherwise)
           PaidAmount = pst.PaidAmount, ReturnedAmount = pst.ReturnedAmount, OutstandingAmount = pst.OutstandingAmount, PaymentStatus = pst.PaymentStatus,
           -- (63) supplier invoices: 1 = it holds one item (65029 refuses a second), 0 = it may hold several. Its own mode,
           --      or the setting when it has none (saved before script 63). 0 on orders and returns: not concerned.
           OneItemOnly = CAST(CASE WHEN dt.Code = N'PINV'
                                   THEN COALESCE(d.OneItemOnly, configuration.fn_SettingBool(N'Purchase.OneItemPerInvoice')) ELSE 0 END AS BIT),
           -- (65) goods receipts: 1 = a supplier invoice posted after the switch (its goods enter with goods receipts);
           --      CanReceive / ReceiveBlockedReason = "Receive goods..." on this order or invoice (rules 14, 15);
           --      GoodsReceiptsSinceUtc = the switch ("Posted before goods receipts ({date})")
           d.UsesGoodsReceipts,
           CanReceive = CAST(CASE WHEN rcv.Reason IS NULL THEN 1 ELSE 0 END AS BIT),
           ReceiveBlockedReason = rcv.Reason,
           GoodsReceiptsSinceUtc = (SELECT TOP (1) s.SwitchedAtUtc FROM purchase.GoodsReceiptSwitch s),
           -- (79) a supplier invoice: its price becomes the cost of the goods received against it (AffectsCost), posting it
           --      receives its goods (ReceiveOnPost) - what it captured when posted, the type's switch while a draft;
           --      1 / 0 on orders and returns, not concerned
           AffectsCost   = CAST(CASE WHEN dt.Code <> N'PINV' THEN 1 WHEN d.Status = 1 THEN dt.AffectsItemCost ELSE d.AffectsCost END AS BIT),
           ReceiveOnPost = CAST(CASE WHEN dt.Code <> N'PINV' THEN 0 WHEN d.Status = 1 THEN dt.AffectsOnHand ELSE d.ReceiveOnPost END AS BIT)
    FROM purchase.PurchaseDocuments d
    OUTER APPLY purchase.fn_InvoiceSettlement(d.Id) pst
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Branches b      ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w    ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Parties sp      ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    LEFT  JOIN masterdata.Currencies bc   ON bc.IsBaseCurrency = 1 AND bc.IsActive = 1
    LEFT  JOIN purchase.PurchaseDocuments src ON src.Id = d.SourceDocumentId
    LEFT  JOIN inventory.DocumentTypes sdt ON sdt.Id = src.DocumentTypeId
    LEFT  JOIN inventory.ShortageDocuments sh ON sh.Id = d.SourceShortageId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = d.UpdatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    LEFT  JOIN security.Users xu ON xu.Id = d.CancelledBy
    LEFT  JOIN security.Users ku ON ku.Id = d.ClosedBy
    LEFT  JOIN security.Users rqu ON rqu.Id = d.ApprovalRequestedBy
    LEFT  JOIN security.Users apu ON apu.Id = d.ApprovedBy
    LEFT  JOIN security.Users rju ON rju.Id = d.RejectedBy
    OUTER APPLY (SELECT Ordered = SUM(pl.QuantityBase), Invoiced = SUM(pl.ReceivedQuantityBase)
                 FROM purchase.PurchaseDocumentLines pl WHERE pl.DocumentId = d.Id) prog
    OUTER APPLY (SELECT InDraft = SUM(x.QuantityBase)
                 FROM purchase.PurchaseDocumentLines pl
                 INNER JOIN purchase.PurchaseDocumentLines x ON x.SourceLineId = pl.Id
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId AND xd.Status = 1
                 WHERE pl.DocumentId = d.Id) drf
    OUTER APPLY (SELECT Share = SUM(a.AmountBase * CAST(x.QuantityBase AS DECIMAL(18,6)) / NULLIF(cl.QuantityBase, 0))
                 FROM purchase.PurchaseDocumentLines x
                 INNER JOIN logistics.ContainerLines cl            ON cl.Id = x.ContainerLineId
                 INNER JOIN logistics.ContainerChargeAllocations a ON a.ContainerLineId = cl.Id
                 INNER JOIN logistics.ContainerCharges ch          ON ch.Id = a.ChargeId AND ch.Status = 2 AND ch.IncludeInLandedCost = 1
                 WHERE x.DocumentId = d.Id) cch
    OUTER APPLY (SELECT Containers = CASE WHEN dt.Code = N'PINV'
                                          THEN CAST(SUM(CAST(s.InvoicedBase AS DECIMAL(19,4)) / s.PcsPerContainer) AS DECIMAL(18,2)) END
                 FROM purchase.fn_PurchaseInvoice_ItemContainers(d.Id) s) need
    -- (65) what "Receive goods..." would find: an order's lines (rule 14), an invoice's lines not in a container (rule 15)
    OUTER APPLY (SELECT ToReceive = SUM(p.ToReceiveBase), MaxOutside = SUM(p.MaxOutsideBase), InContainers = SUM(p.InContainersBase),
                        NotReceived = SUM(CASE WHEN p.OrderedBase - p.GoodsReceivedBase - p.GoodsShortBase > 0
                                               THEN p.OrderedBase - p.GoodsReceivedBase - p.GoodsShortBase ELSE 0 END),
                        InDrafts = SUM(p.InDraftReceiptsBase),
                        Room = SUM(CASE WHEN p.MaxOutsideBase > p.InDraftReceiptsBase THEN p.MaxOutsideBase - p.InDraftReceiptsBase ELSE 0 END)
                 FROM purchase.fn_PoLine_Progress(d.Id) p
                 WHERE dt.Code = N'PO') pr
    OUTER APPLY (SELECT Lines = COUNT(*), ToReceive = SUM(t.ToReceiveBase), InDrafts = SUM(t.InDraftReceiptsBase),
                        NotReceived = SUM(CASE WHEN t.InvoicedBase - t.ReceivedBase > 0 THEN t.InvoicedBase - t.ReceivedBase ELSE 0 END)
                 FROM purchase.fn_InvoiceLine_ToReceive(d.Id) t
                 WHERE dt.Code = N'PINV') ir
    -- (65) why "Receive goods..." is disabled (NULL = it is not). An order also opens it for pieces recorded short that
    --      turn up later (MaxOutsideBase: what remains outside containers, settled pieces included; the dialog proposes 0),
    --      but not for what draft goods receipts already hold (Room: MaxOutsideBase - InDraftReceiptsBase per line).
    CROSS APPLY (SELECT Reason = CAST(CASE
                     WHEN dt.Code = N'PO' THEN
                         CASE WHEN d.Status = 1 THEN N'Approve the order first: goods are received against an approved order.'
                              WHEN d.Status = 5 THEN N'This order is waiting for approval.'
                              WHEN d.Status = 3 THEN N'This order is cancelled.'
                              WHEN ISNULL(pr.ToReceive, 0) > 0 OR ISNULL(pr.Room, 0) > 0 THEN NULL
                              WHEN ISNULL(pr.InDrafts, 0) > 0
                                  THEN N'The rest of this order is on draft goods receipts: post or delete them first.'
                              WHEN ISNULL(pr.InContainers, 0) > 0 AND ISNULL(pr.NotReceived, 0) > 0
                                  THEN N'Everything still to receive travels in containers: it is received with its containers.'
                              ELSE N'Everything ordered is already received.' END
                     WHEN dt.Code = N'PINV' THEN
                         CASE WHEN d.Status = 1 THEN N'Post the invoice first: goods are received against a posted invoice, or from the order.'
                              WHEN d.Status = 3 THEN N'This invoice is cancelled.'
                              WHEN d.UsesGoodsReceipts = 0 AND d.ReceiptMode = 1
                                  THEN N'Posted before goods receipts: its stock entered when it was posted (or when its container was offloaded).'
                              -- an older "Shipped in containers" invoice whose lines are all in containers offloaded the old way
                              WHEN d.UsesGoodsReceipts = 0 AND ISNULL(ir.Lines, 0) = 0
                                   AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines x
                                                   INNER JOIN logistics.ContainerLines cl ON cl.Id = x.ContainerLineId
                                                   CROSS APPLY logistics.fn_Container_ReceivedBy(cl.ContainerId) rb
                                                   WHERE x.DocumentId = d.Id AND ISNULL(rb.ReceivedBy, N'') <> N'Offload')
                                  THEN N'Posted before goods receipts: its stock entered when it was posted (or when its container was offloaded).'
                              WHEN ISNULL(ir.Lines, 0) = 0 THEN N'This invoice''s goods travel in containers: they are received with their containers.'
                              WHEN ISNULL(ir.ToReceive, 0) > 0 THEN NULL
                              WHEN ISNULL(ir.InDrafts, 0) > 0 AND ISNULL(ir.NotReceived, 0) > 0
                                  THEN N'The rest of this invoice is on draft goods receipts: post or delete them first.'
                              ELSE N'Every piece of this invoice is already received.' END
                     ELSE N'A purchase return takes goods out: it is not received.' END AS NVARCHAR(400))) rcv
    WHERE d.Id = @Id;

    SELECT l.Id, l.DocumentId, l.LineNumber, l.ItemId, i.ItemCode, i.ItemName,
           l.ItemUnitId, ut.UnitTypeName, iu.SkuCode, iu.Barcode, l.PackingFormula,
           l.WarehouseId, w.WarehouseCode, w.WarehouseName, l.ExpiryDate,
           l.Quantity, l.QuantityBase, l.UnitPrice, l.DiscountPercent, l.LineDiscount, l.LineTotal,
           l.UnitCostBase, LandedCostBase = l.UnitCostBase, l.FobCostBase, l.AllocatedChargesBase,
           l.ReceivedQuantityBase, l.ReturnedQuantityBase, l.ShippedQuantityBase,
           AllocatedToContainersBase = CASE WHEN dt.Code = N'PO' THEN ISNULL(ct.Allocated, 0)
                                            WHEN l.ContainerLineId IS NOT NULL THEN l.QuantityBase ELSE 0 END,
           TransitBase = CASE WHEN dt.Code = N'PO' THEN ISNULL(ct.Transit, 0)
                              WHEN lct.Status IN (3, 4, 5) THEN l.QuantityBase ELSE 0 END,
           -- (65) an invoice whose goods come through goods receipts returns what was received (rule 23), as Post checks it
           RemainingBase = CASE WHEN dt.Code = N'PO' THEN l.QuantityBase - l.ReceivedQuantityBase
                                WHEN dt.Code = N'PINV' AND (d.UsesGoodsReceipts = 1 OR d.ReceiptMode = 2) THEN l.ReceivedQuantityBase - l.ReturnedQuantityBase
                                WHEN dt.Code = N'PINV' THEN l.QuantityBase - l.ReturnedQuantityBase END,
           AvailableForContainerBase = CASE WHEN dt.Code = N'PO' THEN l.QuantityBase - ISNULL(ct.Allocated, 0) - ISNULL(dir.Qty, 0) END,
           InvoicedDirectBase = CASE WHEN dt.Code = N'PO' THEN ISNULL(dir.Qty, 0) END,
           l.ContainerLineId, ContainerId = lcl.ContainerId, ContainerRef = lct.ContainerRef, ContainerNo = lct.ContainerNo,
           ContainerStatus = lct.Status,
           ContainerChargesBase = CASE WHEN l.ContainerLineId IS NOT NULL THEN ISNULL(lch.Share, 0) END,
           EstimatedLandedCostBase = CASE WHEN l.ContainerLineId IS NOT NULL
                                          THEN COALESCE(lcl.LandedCostBase,
                                                        ISNULL(l.FobCostBase, l.LineTotal / NULLIF(d.ExchangeRate, 0) / NULLIF(l.QuantityBase, 0))
                                                        + ISNULL(lch.Share, 0) / NULLIF(l.QuantityBase, 0)) END,
           InDraftDocumentsBase = ISNULL(dr.Qty, 0),
           AvailableToInvoiceBase = CASE WHEN dt.Code = N'PO' THEN l.QuantityBase - l.ReceivedQuantityBase - ISNULL(dr.Qty, 0) END,
           l.ImportRowNumber, l.Notes, l.SourceLineId,
           OnHandBase  = inventory.fn_StockOnHand(l.ItemId, l.WarehouseId),
           ItemLastCost = i.LastCost, ItemAverageCost = i.AverageCost, ItemFobCost = i.FobCost,
           -- (65) order lines: received, settled short, in containers / draft receipts, to receive, still to come
           --      (purchase.fn_PoLine_Progress); invoice lines: to receive with "Receive goods..." (fn_InvoiceLine_ToReceive;
           --      0 on a line in a container). InvoicedDirectBase above now holds what the order line committed outside
           --      containers (fn_PoLine_CommittedOutside: the larger of invoiced, and received + on draft receipts); its parts:
           GoodsReceivedBase   = pp.GoodsReceivedBase,
           GoodsShortBase      = pp.GoodsShortBase,
           InContainersBase    = pp.InContainersBase,
           InDraftReceiptsBase = COALESCE(pp.InDraftReceiptsBase, ip.InDraftReceiptsBase, CASE WHEN dt.Code = N'PINV' THEN 0 END),
           ToReceiveBase       = COALESCE(pp.ToReceiveBase, ip.ToReceiveBase, CASE WHEN dt.Code = N'PINV' THEN 0 END),
           MaxOutsideBase      = pp.MaxOutsideBase,
           OutstandingBase     = pp.OutstandingBase,
           InvoicedOutsideBase        = CASE WHEN dt.Code = N'PO' THEN ISNULL(dir.InvoicedOutsideBase, 0) END,
           ReceivedOutsideBase        = CASE WHEN dt.Code = N'PO' THEN ISNULL(dir.ReceivedOutsideBase, 0) END,
           InDraftReceiptsOutsideBase = CASE WHEN dt.Code = N'PO' THEN ISNULL(dir.InDraftReceiptsOutsideBase, 0) END
    FROM purchase.PurchaseDocumentLines l
    INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
    INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId
    INNER JOIN inventory.Items i            ON i.Id = l.ItemId
    INNER JOIN inventory.ItemUnits iu       ON iu.Id = l.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut      ON ut.Id = iu.UnitTypeId
    INNER JOIN masterdata.Warehouses w      ON w.Id = l.WarehouseId
    OUTER APPLY (SELECT Allocated = SUM(cl.QuantityBase),
                        Transit   = SUM(CASE WHEN c.Status IN (3, 4, 5) THEN cl.QuantityBase - ISNULL(cl.ReceivedQuantityBase, 0) ELSE 0 END)
                 FROM logistics.ContainerLines cl
                 INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                 WHERE cl.PoLineId = l.Id AND c.Status <> 8) ct
    -- (65) committed outside containers: the larger of invoiced, and received + on draft goods receipts (was: invoiced)
    OUTER APPLY (SELECT co.Qty, co.InvoicedOutsideBase, co.ReceivedOutsideBase, co.InDraftReceiptsOutsideBase
                 FROM purchase.fn_PoLine_CommittedOutside(l.Id, NULL) co
                 WHERE dt.Code = N'PO') dir
    LEFT  JOIN purchase.fn_PoLine_Progress(@Id) pp      ON pp.PoLineId = l.Id
    LEFT  JOIN purchase.fn_InvoiceLine_ToReceive(@Id) ip ON ip.InvoiceLineId = l.Id
    LEFT  JOIN logistics.ContainerLines lcl ON lcl.Id = l.ContainerLineId
    LEFT  JOIN logistics.Containers lct     ON lct.Id = lcl.ContainerId
    OUTER APPLY (SELECT Charges = SUM(a.AmountBase)
                 FROM logistics.ContainerChargeAllocations a
                 INNER JOIN logistics.ContainerCharges ch ON ch.Id = a.ChargeId AND ch.Status = 2 AND ch.IncludeInLandedCost = 1
                 WHERE a.ContainerLineId = l.ContainerLineId) lcc
    OUTER APPLY (SELECT Share = lcc.Charges * CAST(l.QuantityBase AS DECIMAL(18,6)) / NULLIF(lcl.QuantityBase, 0)) lch
    OUTER APPLY (SELECT Qty = SUM(x.QuantityBase) FROM purchase.PurchaseDocumentLines x
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
                 WHERE x.SourceLineId = l.Id AND xd.Status = 1) dr
    WHERE l.DocumentId = @Id
    ORDER BY l.LineNumber;

    SELECT f.Id, f.DocumentId, f.FileName, f.ContentType, f.SizeBytes, f.CreatedAtUtc, u.FullName AS CreatedByName
    FROM purchase.PurchaseDocumentFiles f
    LEFT JOIN security.Users u ON u.Id = f.CreatedBy
    WHERE f.DocumentId = @Id
    ORDER BY f.CreatedAtUtc DESC;

    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM purchase.PurchaseDocumentAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.DocumentId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;

    -- (77) + InvoicingStatus of a linked purchase order (0 / 1 / 2: Saved, Partially posted, Posted); NULL otherwise
    SELECT Relation = N'Source', x.Id, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, x.DocumentNumber, x.DocumentDate, x.Status, x.TotalAmount, c.CurrencyCode,
           inv.InvoicingStatus
    FROM purchase.PurchaseDocuments d
    INNER JOIN purchase.PurchaseDocuments x ON x.Id = d.SourceDocumentId
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = x.DocumentTypeId
    INNER JOIN masterdata.Currencies c ON c.Id = x.CurrencyId
    OUTER APPLY purchase.fn_PurchaseOrder_Invoicing(x.Id) inv
    WHERE d.Id = @Id
    UNION ALL
    SELECT N'Child', x.Id, dt.Code, dt.Name, x.DocumentNumber, x.DocumentDate, x.Status, x.TotalAmount, c.CurrencyCode,
           inv.InvoicingStatus
    FROM purchase.PurchaseDocuments x
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = x.DocumentTypeId
    INNER JOIN masterdata.Currencies c ON c.Id = x.CurrencyId
    OUTER APPLY purchase.fn_PurchaseOrder_Invoicing(x.Id) inv
    WHERE x.SourceDocumentId = @Id
    ORDER BY Relation DESC, DocumentDate, Id;

    -- 6: charges of the invoice (kind PINV), of its landed cost adjustments (kind LCA) and, for an import, the charges of
    --    its containers (kind CNT, read-only: DocumentId = container, AdjustmentStatus = charge status) with ShareBase =
    --    the part that falls on this invoice's lines.
    SELECT c.Id, c.DocumentKind, c.DocumentId, SourceNumber = CASE WHEN c.DocumentKind = N'LCA' THEN lca.DocumentNumber ELSE d.DocumentNumber END,
           c.LineNumber, c.ChargeTypeId, ct.ChargeCode, ct.ChargeName, c.Description, c.ProviderPartyId, pp.PartyName AS ProviderName, c.Reference,
           c.CurrencyId, cur.CurrencyCode, c.RateType, c.ExchangeRate, c.Amount, c.AmountBase, c.AllocationMethod, c.IncludeInLandedCost, c.IncludedInSupplierInvoice, c.Notes,
           AllocatedBase = (SELECT SUM(AmountBase) FROM purchase.PurchaseChargeAllocations x WHERE x.ChargeId = c.Id),
           AdjustmentStatus = lca.Status,
           ContainerId = CAST(NULL AS INT), ContainerRef = CAST(NULL AS NVARCHAR(30)), ChargeDate = CAST(NULL AS DATE),
           ChargeStatus = CAST(NULL AS TINYINT), ShareBase = CAST(NULL AS DECIMAL(18,2))
    FROM purchase.PurchaseCharges c
    INNER JOIN purchase.ChargeTypes ct ON ct.Id = c.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = c.CurrencyId
    LEFT  JOIN masterdata.Parties pp ON pp.Id = c.ProviderPartyId
    LEFT  JOIN purchase.PurchaseDocuments d ON d.Id = c.DocumentId AND c.DocumentKind = N'PINV'
    LEFT  JOIN purchase.LandedCostAdjustments lca ON lca.Id = c.DocumentId AND c.DocumentKind = N'LCA'
    WHERE (c.DocumentKind = N'PINV' AND c.DocumentId = @Id)
       OR (c.DocumentKind = N'LCA' AND lca.SourceInvoiceId = @Id)
    UNION ALL
    SELECT ch.Id, N'CNT', ch.ContainerId, cn.ContainerRef,
           CAST(ROW_NUMBER() OVER (ORDER BY cn.ContainerRef, ch.ChargeDate, ch.Id) AS INT),
           ch.ChargeTypeId, t.ChargeCode, t.ChargeName, ch.Description, ch.ProviderPartyId, pp.PartyName, ch.Reference,
           ch.CurrencyId, cur.CurrencyCode, ch.RateType, ch.ExchangeRate, ch.Amount, ch.AmountBase, ch.AllocationMethod, ch.IncludeInLandedCost,
           CAST(0 AS BIT), ch.Notes,
           ISNULL(s.Share, 0), ch.Status,
           ch.ContainerId, cn.ContainerRef, ch.ChargeDate, ch.Status, CAST(ISNULL(s.Share, 0) AS DECIMAL(18,2))
    FROM logistics.ContainerCharges ch
    INNER JOIN logistics.Containers cn   ON cn.Id = ch.ContainerId
    INNER JOIN purchase.ChargeTypes t    ON t.Id = ch.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = ch.CurrencyId
    LEFT  JOIN masterdata.Parties pp     ON pp.Id = ch.ProviderPartyId
    OUTER APPLY (SELECT Share = SUM(a.AmountBase * CAST(l.QuantityBase AS DECIMAL(18,6)) / NULLIF(cl.QuantityBase, 0))
                 FROM purchase.PurchaseDocumentLines l
                 INNER JOIN logistics.ContainerLines cl            ON cl.Id = l.ContainerLineId
                 INNER JOIN logistics.ContainerChargeAllocations a ON a.ContainerLineId = cl.Id AND a.ChargeId = ch.Id
                 WHERE l.DocumentId = @Id) s
    WHERE ch.Status IN (1, 2)
      AND EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines l
                  INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
                  WHERE l.DocumentId = @Id AND cl.ContainerId = ch.ContainerId)
    ORDER BY 2, 3, 5;

    -- 7: containers of the document: for an order the containers carrying its lines, for an invoice its containers.
    SELECT ct.Id, ct.ContainerRef, ct.ContainerNo, ct.Status, ct.DispatchDate, ct.Eta, ct.OffloadedDate,
           ct.CurrentLocation, w.WarehouseCode, w.WarehouseName,
           AllocatedBase = ISNULL(x.Allocated, 0), ReceivedBase = ISNULL(x.Received, 0), InvoicedBase = ISNULL(x.Invoiced, 0),
           ct.ContainerTypeId, ctt.TypeCode AS ContainerTypeCode, ct.PurchaseOrderId
    FROM logistics.Containers ct
    INNER JOIN masterdata.ContainerTypes ctt ON ctt.Id = ct.ContainerTypeId
    LEFT  JOIN masterdata.Warehouses w       ON w.Id = ct.WarehouseId
    CROSS APPLY (SELECT Allocated = SUM(q.Allocated), Received = SUM(q.Received), Invoiced = SUM(q.Invoiced)
                 FROM (SELECT Allocated = cl.QuantityBase, Received = ISNULL(cl.ReceivedQuantityBase, 0),
                              Invoiced = ISNULL((SELECT SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                                                 INNER JOIN purchase.PurchaseDocuments pid ON pid.Id = pil.DocumentId
                                                 WHERE pil.ContainerLineId = cl.Id AND pid.Status IN (2, 4)), 0)
                       FROM logistics.ContainerLines cl
                       WHERE cl.ContainerId = ct.Id AND cl.PurchaseOrderId = @Id
                       UNION ALL
                       SELECT l.QuantityBase, l.ReceivedQuantityBase, l.QuantityBase
                       FROM purchase.PurchaseDocumentLines l
                       INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
                       WHERE l.DocumentId = @Id AND cl.ContainerId = ct.Id) q) x
    WHERE ct.Status <> 8
      AND (EXISTS (SELECT 1 FROM logistics.ContainerLines cl WHERE cl.ContainerId = ct.Id AND cl.PurchaseOrderId = @Id)
           OR EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines l
                      INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
                      WHERE l.DocumentId = @Id AND cl.ContainerId = ct.Id))
    ORDER BY ct.ContainerRef;

    -- 8: approval requests and decisions (purchase orders).
    SELECT a.Id, a.RequestNo, a.ApproverUserId, u.FullName AS ApproverName, u.Email AS ApproverEmail,
           a.Status, a.ExpiresAtUtc, a.DecidedAtUtc, a.DecisionNote, a.Channel, a.RequestedAtUtc, ru.FullName AS RequestedByName
    FROM purchase.PurchaseOrderApprovals a
    INNER JOIN security.Users u ON u.Id = a.ApproverUserId
    LEFT  JOIN security.Users ru ON ru.Id = a.RequestedBy
    WHERE a.DocumentId = @Id
    ORDER BY a.RequestNo DESC, a.Id;

    -- 9 (65): goods receipts of the document - an order: those of its lines (from the order, its invoices, its
    --    containers); an invoice: those made from it and those whose pieces are matched to its lines. HereBase = the
    --    pieces of the receipt that concern this document (an order: on its lines; an invoice: matched to its lines,
    --    or received from it). Value = the value at receipt (fixed when posted).
    SELECT g.Id, g.DocumentNumber, g.DocumentDate, g.Status, g.SourceKind, g.IsAuto,
           g.ContainerId, ContainerRef = c.ContainerRef, g.WarehouseId, w.WarehouseCode, w.WarehouseName,
           ReceivedBase = g.TotalReceivedBase, HereBase = ISNULL(h.Pcs, 0), ValueAtReceiptBase = g.ValueAtReceiptBase,
           g.PostedAtUtc, g.CreatedAtUtc
    FROM purchase.GoodsReceipts g
    LEFT  JOIN logistics.Containers c    ON c.Id = g.ContainerId
    LEFT  JOIN masterdata.Warehouses w   ON w.Id = g.WarehouseId
    OUTER APPLY (SELECT Pcs = SUM(x.Pcs)
                 FROM (SELECT Pcs = gl.QuantityBase
                       FROM purchase.GoodsReceiptLines gl
                       WHERE gl.GoodsReceiptId = g.Id AND gl.PurchaseOrderId = @Id
                       UNION ALL
                       SELECT m.QuantityBase
                       FROM purchase.GoodsReceiptLines gl
                       INNER JOIN purchase.GoodsReceiptInvoiceMatches m ON m.GoodsReceiptLineId = gl.Id
                       INNER JOIN purchase.PurchaseDocumentLines il     ON il.Id = m.InvoiceLineId AND il.DocumentId = @Id
                       WHERE gl.GoodsReceiptId = g.Id
                       UNION ALL
                       SELECT gl.QuantityBase
                       FROM purchase.GoodsReceiptLines gl
                       INNER JOIN purchase.PurchaseDocumentLines il ON il.Id = gl.InvoiceLineId AND il.DocumentId = @Id
                       WHERE gl.GoodsReceiptId = g.Id AND g.Status = 1) x) h
    WHERE g.PurchaseOrderId = @Id OR g.PurchaseInvoiceId = @Id
       OR EXISTS (SELECT 1 FROM purchase.GoodsReceiptLines gl WHERE gl.GoodsReceiptId = g.Id AND gl.PurchaseOrderId = @Id)
       OR EXISTS (SELECT 1 FROM purchase.GoodsReceiptLines gl
                  INNER JOIN purchase.GoodsReceiptInvoiceMatches m ON m.GoodsReceiptLineId = gl.Id
                  INNER JOIN purchase.PurchaseDocumentLines il     ON il.Id = m.InvoiceLineId AND il.DocumentId = @Id
                  WHERE gl.GoodsReceiptId = g.Id)
    ORDER BY g.DocumentDate, g.Id;

    -- 10 (65): cost adjustments of received goods caused by this invoice - posted or cancelled - and by its landed
    --    cost adjustments (purchase.GoodsReceiptCostChanges; empty for an order or a return).
    SELECT cc.Id, cc.ChangedAtUtc, cc.CauseKind, cc.CauseId, cc.CauseNumber,
           cc.GoodsReceiptLineId, GoodsReceiptId = g.Id, GoodsReceiptNumber = g.DocumentNumber, gl.ItemId, i.ItemCode, i.ItemName,
           cc.ReceivedBase, cc.InStockBase, cc.FobBefore, cc.FobAfter, cc.UnitCostBefore, cc.UnitCostAfter,
           cc.AmountBase, cc.InventoryBase, cc.CogsBase
    FROM purchase.GoodsReceiptCostChanges cc
    INNER JOIN purchase.GoodsReceiptLines gl ON gl.Id = cc.GoodsReceiptLineId
    INNER JOIN purchase.GoodsReceipts g      ON g.Id = gl.GoodsReceiptId
    INNER JOIN inventory.Items i             ON i.Id = gl.ItemId
    WHERE (cc.CauseKind IN (N'PINV', N'PINVCANCEL') AND cc.CauseId = @Id)
       OR (cc.CauseKind IN (N'LCA', N'LCACANCEL')
           AND cc.CauseId IN (SELECT a.Id FROM purchase.LandedCostAdjustments a WHERE a.SourceInvoiceId = @Id))
    ORDER BY cc.ChangedAtUtc, cc.Id;
END

GO

