-- PostBlockedReason, CancelBlockedReason, DeleteBlockedReason, EditBlockedReason): one row per failed rule, Action
-- 'Post' | 'Cancel' | 'Delete' | 'Edit', in the order of the checks (Seq); the first row of an action is its reason,
-- none = allowed. The Post and Cancel rows ARE the refusals of usp_GoodsReceipt_Post / _Cancel
-- (fn_GoodsReceipt_PostCheck / _CancelCheck, written once), so the page and the refusal always say the same thing.
-- One more Cancel row is only an ESTIMATE (Seq 50, after the binding ones): a purchase return that took back goods of
-- this receipt. Cancel decides it after rebuilding the matches, inside its transaction, and never reads this row.
CREATE   FUNCTION purchase.fn_GoodsReceipt_Blocks (@Id INT)
RETURNS TABLE
AS
RETURN
    WITH g AS
    (
        SELECT gr.Id, gr.Status FROM purchase.GoodsReceipts gr WHERE gr.Id = @Id
    )
    /* ---------- Post: the refusals of usp_GoodsReceipt_Post ---------- */
    SELECT Action = CAST(N'Post' AS NVARCHAR(10)), p.Seq, p.ErrorNumber, Message = CAST(p.Message AS NVARCHAR(400))
    FROM purchase.fn_GoodsReceipt_PostCheck(@Id) p
    /* ---------- Cancel: the refusals of usp_GoodsReceipt_Cancel ---------- */
    UNION ALL
    SELECT N'Cancel', c.Seq, c.ErrorNumber, CAST(c.Message AS NVARCHAR(400))
    FROM purchase.fn_GoodsReceipt_CancelCheck(@Id) c
    UNION ALL
    -- ESTIMATE of Cancel's purchase-return rule: an invoice line matched to this receipt keeps what the other posted
    -- receipts of its group still hold unmatched; returned pieces beyond that would be left without a receipt
    SELECT x.Action, x.Seq, x.ErrorNumber, x.Message
    FROM (SELECT TOP (1) Action = N'Cancel', Seq = 50, ErrorNumber = 63010,
                 Message = CAST(ISNULL(N'Purchase return ' + rt.DocumentNumber, N'A purchase return')
                                + N' took back goods of this receipt. Cancel the return first.' AS NVARCHAR(400))
          FROM g
          CROSS APPLY (SELECT m.InvoiceLineId, Mine = SUM(m.QuantityBase)
                       FROM purchase.GoodsReceiptInvoiceMatches m
                       INNER JOIN purchase.GoodsReceiptLines l ON l.Id = m.GoodsReceiptLineId
                       WHERE l.GoodsReceiptId = g.Id
                       GROUP BY m.InvoiceLineId) z
          INNER JOIN purchase.PurchaseDocumentLines pil ON pil.Id = z.InvoiceLineId
          INNER JOIN purchase.PurchaseDocuments pid     ON pid.Id = pil.DocumentId
          CROSS APPLY (SELECT Spare = ISNULL(SUM(ol.QuantityBase - ol.InvoicedBase), 0)
                       FROM purchase.GoodsReceiptLines ol
                       INNER JOIN purchase.GoodsReceipts og ON og.Id = ol.GoodsReceiptId AND og.Status = 2 AND og.Id <> g.Id
                       WHERE (pil.SourceLineId IS NOT NULL AND ol.PoLineId = pil.SourceLineId)
                          OR (pil.SourceLineId IS NULL AND ol.PoLineId IS NULL AND ol.SupplierId = pid.SupplierId AND ol.ItemId = pil.ItemId)) sp
          OUTER APPLY (SELECT TOP (1) rd.DocumentNumber
                       FROM purchase.PurchaseDocumentLines rl
                       INNER JOIN purchase.PurchaseDocuments rd ON rd.Id = rl.DocumentId AND rd.Status IN (2, 4)
                       WHERE rl.SourceLineId = pil.Id
                       ORDER BY rd.PostedAtUtc DESC, rd.Id DESC) rt
          WHERE g.Status = 2 AND pil.ReturnedQuantityBase > 0 AND pil.ReturnedQuantityBase > pil.ReceivedQuantityBase - z.Mine + sp.Spare
          ORDER BY pil.Id) x
    /* ---------- Delete, Edit: a draft only ---------- */
    UNION ALL
    SELECT N'Delete', 10, 63005, N'Only a draft goods receipt can be changed or deleted.'
    FROM g WHERE g.Status <> 1
    UNION ALL
    SELECT N'Edit', 10, 63005, N'Only a draft goods receipt can be changed or deleted.'
    FROM g WHERE g.Status <> 1;

GO

