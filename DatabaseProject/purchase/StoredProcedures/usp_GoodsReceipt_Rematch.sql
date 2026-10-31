/* ================================================================== 4. The matching is unchanged: only where the cost comes from */

-- Re-created (79) from the body of script 64: every invoice is matched as before (the counters, the return caps,
-- container Close and the payments need it); a receipt line's CostSource counts only the matches to invoices that
-- change item costs, the same rule as section 3.
CREATE   PROCEDURE purchase.usp_GoodsReceipt_Rematch
    @Anchors     purchase.tvp_GoodsReceiptAnchor READONLY,
    @ReturnLines BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC purchase.usp_GoodsReceipt_LockMatching;

        DECLARE @G TABLE (GroupKey NVARCHAR(40) NOT NULL PRIMARY KEY, PoLineId INT NULL, SupplierId INT NULL, ItemId INT NULL);
        INSERT INTO @G (GroupKey, PoLineId, SupplierId, ItemId)
        SELECT N'P' + CAST(a.PoLineId AS NVARCHAR(12)), a.PoLineId, NULL, NULL
        FROM @Anchors a WHERE a.Kind = 'P' AND a.PoLineId IS NOT NULL
        UNION
        SELECT N'S' + CAST(a.SupplierId AS NVARCHAR(12)) + N'.' + CAST(a.ItemId AS NVARCHAR(12)), NULL, a.SupplierId, a.ItemId
        FROM @Anchors a WHERE a.Kind = 'S' AND a.SupplierId IS NOT NULL AND a.ItemId IS NOT NULL;

        -- every receipt line of the groups, whatever its status: a cancelled receipt loses its matches here.
        -- Rem = what it can still take (posted receipts only).
        DECLARE @R TABLE (LineId INT NOT NULL PRIMARY KEY, GroupKey NVARCHAR(40) NOT NULL, Posted BIT NOT NULL,
                          InvoiceLineId INT NULL, ContainerLineId INT NULL, PoLineId INT NULL, T DATETIME2(3) NOT NULL,
                          Qty INT NOT NULL, Rem INT NOT NULL);
        -- (the two kinds of group apart, one statement each, so each seeks its own index - an order line's filtered
        -- index needs its IS NOT NULL said - and reads the groups' rows only: an OR join read every receipt line, and
        -- waited on rows other users were writing)
        INSERT INTO @R (LineId, GroupKey, Posted, InvoiceLineId, ContainerLineId, PoLineId, T, Qty, Rem)
        SELECT gl.Id, gk.GroupKey, CASE WHEN g.Status = 2 THEN 1 ELSE 0 END, gl.InvoiceLineId, gl.ContainerLineId, gl.PoLineId,
               ISNULL(g.PostedAtUtc, g.CreatedAtUtc), gl.QuantityBase,
               CASE WHEN g.Status = 2 THEN gl.QuantityBase ELSE 0 END
        FROM @G gk
        INNER JOIN purchase.GoodsReceiptLines gl ON gl.PoLineId = gk.PoLineId AND gl.PoLineId IS NOT NULL
        INNER JOIN purchase.GoodsReceipts g      ON g.Id = gl.GoodsReceiptId
        WHERE gk.PoLineId IS NOT NULL;

        INSERT INTO @R (LineId, GroupKey, Posted, InvoiceLineId, ContainerLineId, PoLineId, T, Qty, Rem)
        SELECT gl.Id, gk.GroupKey, CASE WHEN g.Status = 2 THEN 1 ELSE 0 END, gl.InvoiceLineId, gl.ContainerLineId, gl.PoLineId,
               ISNULL(g.PostedAtUtc, g.CreatedAtUtc), gl.QuantityBase,
               CASE WHEN g.Status = 2 THEN gl.QuantityBase ELSE 0 END
        FROM @G gk
        INNER JOIN purchase.GoodsReceiptLines gl ON gl.SupplierId = gk.SupplierId AND gl.ItemId = gk.ItemId AND gl.PoLineId IS NULL
        INNER JOIN purchase.GoodsReceipts g      ON g.Id = gl.GoodsReceiptId
        WHERE gk.PoLineId IS NULL;

        -- every supplier invoice line of the groups. Eligible = goods receipts receive its goods (its matches and its
        -- ReceivedQuantityBase are this procedure's); Rem = what it can still pay for (posted or closed, eligible).
        DECLARE @I TABLE (LineId INT NOT NULL PRIMARY KEY, GroupKey NVARCHAR(40) NOT NULL, Eligible BIT NOT NULL,
                          ContainerLineId INT NULL, T DATETIME2(3) NOT NULL, Rem INT NOT NULL);
        -- (the lines of the groups first, one statement per kind of group, as for the receipt lines)
        DECLARE @IL TABLE (LineId INT NOT NULL PRIMARY KEY, GroupKey NVARCHAR(40) NOT NULL);
        INSERT INTO @IL (LineId, GroupKey)
        SELECT l.Id, gk.GroupKey
        FROM @G gk
        INNER JOIN purchase.PurchaseDocumentLines l ON l.SourceLineId = gk.PoLineId AND l.SourceLineId IS NOT NULL
        WHERE gk.PoLineId IS NOT NULL;

        INSERT INTO @IL (LineId, GroupKey)
        SELECT l.Id, gk.GroupKey
        FROM @G gk
        INNER JOIN purchase.PurchaseDocumentLines l ON l.ItemId = gk.ItemId AND l.SourceLineId IS NULL
        INNER JOIN purchase.PurchaseDocuments d     ON d.Id = l.DocumentId AND d.SupplierId = gk.SupplierId
        WHERE gk.PoLineId IS NULL;

        INSERT INTO @I (LineId, GroupKey, Eligible, ContainerLineId, T, Rem)
        SELECT l.Id, x.GroupKey, e.Eligible, l.ContainerLineId, ISNULL(d.PostedAtUtc, d.CreatedAtUtc),
               CASE WHEN e.Eligible = 1 AND d.Status IN (2, 4) THEN l.QuantityBase ELSE 0 END
        FROM @IL x
        INNER JOIN purchase.PurchaseDocumentLines l ON l.Id = x.LineId
        INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
        INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId AND dt.Code = N'PINV'
        LEFT  JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
        OUTER APPLY logistics.fn_Container_ReceivedBy(cl.ContainerId) rb
        CROSS APPLY (SELECT Eligible = CAST(CASE WHEN d.UsesGoodsReceipts = 0 AND d.ReceiptMode = 1 THEN 0
                                                 WHEN rb.ReceivedBy = N'Offload' THEN 0
                                                 ELSE 1 END AS BIT)) e;

        DECLARE @M    TABLE (RLineId INT NOT NULL, ILineId INT NOT NULL, Qty INT NOT NULL);
        DECLARE @Pass TABLE (RLineId INT NOT NULL, ILineId INT NOT NULL, Qty INT NOT NULL);

        -- Each pass pairs the two sides of one key first in first out: the running totals give each line an interval
        -- [E - Rem, E) of the key's pieces, and a receipt line and an invoice line share the overlap of their intervals.

        -- pass 0: the invoice line the receipt was made from
        WITH r AS (SELECT LineId, K = InvoiceLineId, Rem,
                          E = SUM(Rem) OVER (PARTITION BY InvoiceLineId ORDER BY T, LineId ROWS UNBOUNDED PRECEDING)
                   FROM @R WHERE Rem > 0 AND InvoiceLineId IS NOT NULL),
             i AS (SELECT LineId, K = LineId, Rem, E = Rem FROM @I WHERE Rem > 0)
        INSERT INTO @Pass (RLineId, ILineId, Qty)
        SELECT r.LineId, i.LineId,
               (CASE WHEN r.E < i.E THEN r.E ELSE i.E END) - (CASE WHEN r.E - r.Rem > i.E - i.Rem THEN r.E - r.Rem ELSE i.E - i.Rem END)
        FROM r INNER JOIN i ON i.K = r.K
        WHERE r.E - r.Rem < i.E AND i.E - i.Rem < r.E;

        UPDATE r SET Rem = r.Rem - p.Qty FROM @R r INNER JOIN (SELECT RLineId, Qty = SUM(Qty) FROM @Pass GROUP BY RLineId) p ON p.RLineId = r.LineId;
        UPDATE i SET Rem = i.Rem - p.Qty FROM @I i INNER JOIN (SELECT ILineId, Qty = SUM(Qty) FROM @Pass GROUP BY ILineId) p ON p.ILineId = i.LineId;
        INSERT INTO @M (RLineId, ILineId, Qty) SELECT RLineId, ILineId, Qty FROM @Pass;
        DELETE FROM @Pass;

        -- pass 1: the container line
        WITH r AS (SELECT LineId, K = ContainerLineId, Rem,
                          E = SUM(Rem) OVER (PARTITION BY ContainerLineId ORDER BY T, LineId ROWS UNBOUNDED PRECEDING)
                   FROM @R WHERE Rem > 0 AND ContainerLineId IS NOT NULL),
             i AS (SELECT LineId, K = ContainerLineId, Rem,
                          E = SUM(Rem) OVER (PARTITION BY ContainerLineId ORDER BY T, LineId ROWS UNBOUNDED PRECEDING)
                   FROM @I WHERE Rem > 0 AND ContainerLineId IS NOT NULL)
        INSERT INTO @Pass (RLineId, ILineId, Qty)
        SELECT r.LineId, i.LineId,
               (CASE WHEN r.E < i.E THEN r.E ELSE i.E END) - (CASE WHEN r.E - r.Rem > i.E - i.Rem THEN r.E - r.Rem ELSE i.E - i.Rem END)
        FROM r INNER JOIN i ON i.K = r.K
        WHERE r.E - r.Rem < i.E AND i.E - i.Rem < r.E;

        UPDATE r SET Rem = r.Rem - p.Qty FROM @R r INNER JOIN (SELECT RLineId, Qty = SUM(Qty) FROM @Pass GROUP BY RLineId) p ON p.RLineId = r.LineId;
        UPDATE i SET Rem = i.Rem - p.Qty FROM @I i INNER JOIN (SELECT ILineId, Qty = SUM(Qty) FROM @Pass GROUP BY ILineId) p ON p.ILineId = i.LineId;
        INSERT INTO @M (RLineId, ILineId, Qty) SELECT RLineId, ILineId, Qty FROM @Pass;
        DELETE FROM @Pass;

        -- passes 2 and 3: the group itself (the order line, or the supplier + item)
        WITH r AS (SELECT LineId, K = GroupKey, Rem,
                          E = SUM(Rem) OVER (PARTITION BY GroupKey ORDER BY T, LineId ROWS UNBOUNDED PRECEDING)
                   FROM @R WHERE Rem > 0),
             i AS (SELECT LineId, K = GroupKey, Rem,
                          E = SUM(Rem) OVER (PARTITION BY GroupKey ORDER BY T, LineId ROWS UNBOUNDED PRECEDING)
                   FROM @I WHERE Rem > 0)
        INSERT INTO @Pass (RLineId, ILineId, Qty)
        SELECT r.LineId, i.LineId,
               (CASE WHEN r.E < i.E THEN r.E ELSE i.E END) - (CASE WHEN r.E - r.Rem > i.E - i.Rem THEN r.E - r.Rem ELSE i.E - i.Rem END)
        FROM r INNER JOIN i ON i.K = r.K
        WHERE r.E - r.Rem < i.E AND i.E - i.Rem < r.E;

        INSERT INTO @M (RLineId, ILineId, Qty) SELECT RLineId, ILineId, Qty FROM @Pass;

        DECLARE @New TABLE (RLineId INT NOT NULL, ILineId INT NOT NULL, Qty INT NOT NULL, PRIMARY KEY (RLineId, ILineId));
        INSERT INTO @New (RLineId, ILineId, Qty)
        SELECT RLineId, ILineId, SUM(Qty) FROM @M GROUP BY RLineId, ILineId HAVING SUM(Qty) > 0;

        -- the matches of the groups become @New; an unchanged pair keeps its MatchedAtUtc
        DELETE m
        FROM purchase.GoodsReceiptInvoiceMatches m
        WHERE (EXISTS (SELECT 1 FROM @R r WHERE r.LineId = m.GoodsReceiptLineId) OR EXISTS (SELECT 1 FROM @I i WHERE i.LineId = m.InvoiceLineId))
          AND NOT EXISTS (SELECT 1 FROM @New n WHERE n.RLineId = m.GoodsReceiptLineId AND n.ILineId = m.InvoiceLineId);

        UPDATE m SET QuantityBase = n.Qty, MatchedAtUtc = SYSUTCDATETIME()
        FROM purchase.GoodsReceiptInvoiceMatches m
        INNER JOIN @New n ON n.RLineId = m.GoodsReceiptLineId AND n.ILineId = m.InvoiceLineId
        WHERE m.QuantityBase <> n.Qty;

        INSERT INTO purchase.GoodsReceiptInvoiceMatches (GoodsReceiptLineId, InvoiceLineId, QuantityBase)
        SELECT n.RLineId, n.ILineId, n.Qty
        FROM @New n
        WHERE NOT EXISTS (SELECT 1 FROM purchase.GoodsReceiptInvoiceMatches m WHERE m.GoodsReceiptLineId = n.RLineId AND m.InvoiceLineId = n.ILineId);

        -- receipt lines: pieces invoiced, and where their cost comes from (posted lines)
        UPDATE gl
        SET InvoicedBase = x.Qty,
            -- (79) the cost comes from an invoice only when that invoice changes item costs (section 3)
            CostSource = CASE WHEN r.Posted = 0 THEN gl.CostSource
                              WHEN gl.QuantityBase > 0 AND x.CostQty >= gl.QuantityBase THEN N'Invoice'
                              WHEN gl.PoLineId IS NULL AND gl.InvoiceLineId IS NOT NULL AND ISNULL(ri.AffectsCost, 1) = 1 THEN N'Invoice'   -- received at its invoice's cost
                              WHEN x.CostQty > 0 THEN N'Mixed'
                              WHEN gl.PoLineId IS NOT NULL THEN N'Order'
                              ELSE N'Manual' END
        FROM purchase.GoodsReceiptLines gl
        INNER JOIN @R r ON r.LineId = gl.Id
        CROSS APPLY (SELECT Qty     = ISNULL((SELECT SUM(n.Qty) FROM @New n WHERE n.RLineId = gl.Id), 0),
                            CostQty = ISNULL((SELECT SUM(n.Qty) FROM @New n
                                              INNER JOIN purchase.PurchaseDocumentLines p ON p.Id = n.ILineId
                                              INNER JOIN purchase.PurchaseDocuments pd    ON pd.Id = p.DocumentId
                                              WHERE n.RLineId = gl.Id AND pd.AffectsCost = 1), 0)) x
        OUTER APPLY (SELECT pd.AffectsCost FROM purchase.PurchaseDocumentLines p
                     INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = p.DocumentId
                     WHERE p.Id = gl.InvoiceLineId) ri;

        -- invoice lines that goods receipts receive: received = the pieces matched to them
        UPDATE l
        SET ReceivedQuantityBase = x.Qty
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN @I i ON i.LineId = l.Id AND i.Eligible = 1
        CROSS APPLY (SELECT Qty = ISNULL((SELECT SUM(n.Qty) FROM @New n WHERE n.ILineId = l.Id), 0)) x
        WHERE l.ReceivedQuantityBase <> x.Qty;

        COMMIT TRANSACTION;

        IF @ReturnLines = 1
            SELECT GoodsReceiptLineId = LineId FROM @R WHERE Posted = 1 ORDER BY LineId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

