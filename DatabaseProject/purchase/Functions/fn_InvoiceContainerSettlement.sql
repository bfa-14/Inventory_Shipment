/* ================================================================== 2. A purchase invoice, container by container */

/* ONE ROW PER CONTAINER OF A PURCHASE INVOICE, plus one row ContainerKey 0 "Unlinked items" for its lines in no
   container, in the invoice's currency. A line belongs to a container when it is LINKED to one of that
   container's lines (Create Invoice from Containers, Link containers on the invoice).
     ContainerAmount  the invoice lines in that container, less what was returned from those lines
     PaidAmount       what POSTED payments allocated to that container (live allocations only)
     PaymentStatus    Pending | Partially Paid | Fully Paid
   HasContainers  1 when at least one line is in a container.
   NeedsSplit     1 when the invoice has two rows or more (two containers, or a container and unlinked items):
                  only then is a payment split by hand; with one container and nothing else, the whole amount
                  is that container's. */
CREATE   FUNCTION purchase.fn_InvoiceContainerSettlement (@DocumentId INT)
RETURNS TABLE
AS
RETURN
(
    WITH lines AS (
        SELECT ContainerKey = ISNULL(cl.ContainerId, 0), l.ItemId,
               Amount = l.LineTotal - ISNULL(r.Returned, 0)
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
        LEFT  JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
        -- What posted returns took back from this line, in the invoice's currency.
        OUTER APPLY (SELECT Returned = SUM(v.Amount)
                     FROM (SELECT Amount = CASE WHEN x.CurrencyId = d.CurrencyId THEN rl.LineTotal
                                                ELSE ROUND(rl.LineTotal / NULLIF(x.ExchangeRate, 0) * d.ExchangeRate, 2) END
                           FROM purchase.PurchaseDocumentLines rl
                           INNER JOIN purchase.PurchaseDocuments x ON x.Id = rl.DocumentId AND x.Status = 2
                           INNER JOIN inventory.DocumentTypes xt ON xt.Id = x.DocumentTypeId AND xt.Code = N'PRET'
                           WHERE rl.SourceLineId = l.Id) v) r
        WHERE l.DocumentId = @DocumentId
    ),
    paid AS (
        SELECT ContainerKey = pac.ContainerKey, PaidAmount = SUM(pac.AmountDocCurrency)
        FROM purchase.PaymentAllocationContainers pac
        INNER JOIN purchase.PaymentAllocations a ON a.Id = pac.PaymentAllocationId AND a.RemovedAtUtc IS NULL
        INNER JOIN purchase.Payments p ON p.Id = a.PaymentId AND p.Status = 2
        WHERE a.PurchaseDocumentId = @DocumentId
        GROUP BY pac.ContainerKey
    ),
    -- A row whose amount came to nothing (all returned) and was never paid is not shown.
    groups AS (
        SELECT ContainerKey, ContainerAmount = CONVERT(DECIMAL(18,2), SUM(Amount))
        FROM lines GROUP BY ContainerKey
        HAVING ABS(SUM(Amount)) > 0.005 OR ContainerKey IN (SELECT ContainerKey FROM paid)
    )
    SELECT DocumentId = @DocumentId,
           g.ContainerKey,
           ContainerId = NULLIF(g.ContainerKey, 0),
           ContainerRef = CASE WHEN g.ContainerKey = 0 THEN N'Unlinked items' ELSE k.ContainerRef END,
           k.ContainerNo,
           Items = (SELECT STRING_AGG(i.ItemCode, N', ') WITHIN GROUP (ORDER BY i.ItemCode)
                    FROM (SELECT DISTINCT ItemId FROM lines WHERE ContainerKey = g.ContainerKey) li
                    INNER JOIN inventory.Items i ON i.Id = li.ItemId),
           g.ContainerAmount,
           PaidAmount = CONVERT(DECIMAL(18,2), ISNULL(p.PaidAmount, 0)),
           OutstandingAmount = CONVERT(DECIMAL(18,2), g.ContainerAmount - ISNULL(p.PaidAmount, 0)),
           PaymentStatus = CASE WHEN g.ContainerAmount - ISNULL(p.PaidAmount, 0) <= 0.005 THEN N'Fully Paid'
                                WHEN ISNULL(p.PaidAmount, 0) <= 0 THEN N'Pending'
                                ELSE N'Partially Paid' END,
           HasContainers = CAST(CASE WHEN EXISTS (SELECT 1 FROM groups WHERE ContainerKey <> 0) THEN 1 ELSE 0 END AS BIT),
           NeedsSplit = CAST(CASE WHEN EXISTS (SELECT 1 FROM groups WHERE ContainerKey <> 0)
                                   AND (SELECT COUNT(*) FROM groups) > 1 THEN 1 ELSE 0 END AS BIT)
    FROM groups g
    LEFT JOIN logistics.Containers k ON k.Id = g.ContainerKey
    LEFT JOIN paid p ON p.ContainerKey = g.ContainerKey
);

GO

