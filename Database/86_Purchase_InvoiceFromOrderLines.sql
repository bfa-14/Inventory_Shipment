SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 86: PURCHASE - CREATE PURCHASE INVOICE FROM AN ORDER, LINE BY LINE

   "Create Purchase Invoice" on an approved order made its draft invoices from everything still to invoice, with no
   choice: its dialog only asked "...with everything that remains to invoice?". The owner: "this is when creating
   purchase invoice from container, the same way must be when creating the purchase invoice from purchase order". So the
   order's dialog now works like "Create Invoice from Containers...": the document date, the exporter's reference and
   the commercial invoice no. once for every invoice, and the order's lines still to invoice, each with what it ordered,
   what posted invoices took, what draft invoices hold and what is still available, ticked with that quantity - which
   the user may lower, or untick the line.

     1. NEW purchase.usp_PurchaseOrder_InvoiceCandidates: the lines of a purchase order that can still be invoiced, in
        line order (with @IncludeAll = 1 the fully invoiced ones too), with the item and the line's warehouse:
          OrderedBase    the line's quantity;
          InvoicedBase   invoiced by posted invoices (ReceivedQuantityBase, the old name that has always meant invoiced);
          InDraftsBase   held by the draft supplier invoices made from the line - from the order or from its containers
                         (their lines' SourceLineId);
          AvailableBase  OrderedBase - InvoicedBase - InDraftsBase, never below 0: THE SAME RULE as the selection check
                         of purchase.usp_PurchaseDocument_CreateFromSource, which refuses more (65011 "Line 2: 90 base
                         units selected but only 60 are still available (the rest is in posted or draft documents).").
        All in base units (pieces). 65006 "Purchase order not found." for an id that is not a purchase order. Pieces
        settled short ("Nothing more will come") can still be invoiced, as before: the supplier claim covers them.

   Not changed: purchase.usp_PurchaseDocument_CreateFromSource already takes the chosen lines (@Selection,
   purchase.tvp_SourceLineSelection: the order line and its base quantity, script 26) and the document date; the API now
   sends them. No new table, column, type, permission or error number.

   Requires script 26 (purchase.tvp_SourceLineSelection) - Schema.sql runs it first. Idempotent, additive: re-applied at
   every API start-up, and builds a brand-new empty database.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF TYPE_ID(N'purchase.tvp_SourceLineSelection') IS NULL                          -- 26
   OR COL_LENGTH(N'purchase.PurchaseDocumentLines', N'SourceLineId') IS NULL
    THROW 65000, 'Script 86 requires script 26: apply it first.', 1;
GO

/* ================================================================== 1. The lines of an order still to invoice */

-- What "Create Purchase Invoice" offers on an order, line by line (the containers' dialog reads
-- logistics.usp_Container_InvoiceCandidates the same way). Available is what usp_PurchaseDocument_CreateFromSource lets
-- a selection take from the line: ordered - invoiced by posted invoices - in draft invoices.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_InvoiceCandidates
    @PurchaseOrderId INT,
    @IncludeAll      BIT = 0      -- 1 = also the lines with nothing left to invoice
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments d
                   INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                   WHERE d.Id = @PurchaseOrderId AND dt.Code = N'PO')
        THROW 65006, 'Purchase order not found.', 1;

    SELECT LineId = l.Id, l.LineNumber, l.ItemId, i.ItemCode, i.ItemName,
           l.WarehouseId, w.WarehouseCode, w.WarehouseName,
           OrderedBase   = l.QuantityBase,
           InvoicedBase  = l.ReceivedQuantityBase,
           InDraftsBase  = ISNULL(dr.Qty, 0),
           AvailableBase = CASE WHEN av.Available > 0 THEN av.Available ELSE 0 END
    FROM purchase.PurchaseDocumentLines l
    INNER JOIN inventory.Items i       ON i.Id = l.ItemId
    INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
    OUTER APPLY (SELECT Qty = SUM(x.QuantityBase) FROM purchase.PurchaseDocumentLines x
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
                 INNER JOIN inventory.DocumentTypes xt ON xt.Id = xd.DocumentTypeId
                 WHERE x.SourceLineId = l.Id AND xd.Status = 1 AND xt.Code = N'PINV') dr
    CROSS APPLY (SELECT Available = l.QuantityBase - l.ReceivedQuantityBase - ISNULL(dr.Qty, 0)) av
    WHERE l.DocumentId = @PurchaseOrderId
      AND (@IncludeAll = 1 OR av.Available > 0)
    ORDER BY l.LineNumber;
END
GO

/* ================================================================== 2. Check */

-- The 10 latest approved orders and what each still has to invoice (the procedure's rule, summed by order). The orders
-- are taken first, so every start-up reads their lines only.
SELECT d.DocumentNumber, Lines = COUNT(*),
       OrderedBase = SUM(l.QuantityBase), InvoicedBase = SUM(l.ReceivedQuantityBase), InDraftsBase = SUM(ISNULL(dr.Qty, 0)),
       AvailableBase = SUM(CASE WHEN l.QuantityBase - l.ReceivedQuantityBase - ISNULL(dr.Qty, 0) > 0
                                THEN l.QuantityBase - l.ReceivedQuantityBase - ISNULL(dr.Qty, 0) ELSE 0 END)
FROM (SELECT TOP (10) po.Id, po.DocumentNumber
      FROM purchase.PurchaseDocuments po
      INNER JOIN inventory.DocumentTypes dt ON dt.Id = po.DocumentTypeId AND dt.Code = N'PO'
      WHERE po.Status = 2
      ORDER BY po.Id DESC) d
INNER JOIN purchase.PurchaseDocumentLines l ON l.DocumentId = d.Id
OUTER APPLY (SELECT Qty = SUM(x.QuantityBase) FROM purchase.PurchaseDocumentLines x
             INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
             INNER JOIN inventory.DocumentTypes xt ON xt.Id = xd.DocumentTypeId
             WHERE x.SourceLineId = l.Id AND xd.Status = 1 AND xt.Code = N'PINV') dr
GROUP BY d.Id, d.DocumentNumber
ORDER BY d.Id DESC;

PRINT 'Script 86 applied: Create Purchase Invoice on an order offers its lines still to invoice, each with its available quantity (purchase.usp_PurchaseOrder_InvoiceCandidates).';
GO
