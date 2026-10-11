/* ================================================================== 3. What a document has been paid */

/* ONE DEFINITION OF "PAID" for a purchase invoice. Inline, so the optimizer folds it into the calling
   query. Only a POSTED purchase invoice has a payment status.
     Returned     posted purchase returns made from it, in the invoice's currency
     Paid         live allocations on POSTED payments, in the invoice's currency
     Outstanding  Total - Returned - Paid                                                           */
CREATE   FUNCTION purchase.fn_InvoiceSettlement (@DocumentId INT)
RETURNS TABLE
AS
RETURN
(
    SELECT r.ReturnedAmount, p.PaidAmount,
           OutstandingAmount = CASE WHEN d.Status = 2 AND d.DocumentTypeId = t.Id THEN d.TotalAmount - r.ReturnedAmount - p.PaidAmount END,
           PaymentStatus     = CASE WHEN d.Status <> 2 OR d.DocumentTypeId <> t.Id THEN NULL
                                    WHEN d.TotalAmount - r.ReturnedAmount - p.PaidAmount <= 0.005 THEN N'Paid'
                                    WHEN p.PaidAmount <= 0 THEN N'Unpaid'
                                    ELSE N'Partial' END
    FROM purchase.PurchaseDocuments d
    CROSS APPLY (SELECT Id FROM inventory.DocumentTypes WHERE Code = N'PINV') t
    CROSS APPLY (SELECT ReturnedAmount = CONVERT(DECIMAL(18,2), ISNULL((SELECT SUM(q.Amount)
                                                 FROM (SELECT Amount = CASE WHEN x.CurrencyId = d.CurrencyId THEN x.TotalAmount
                                                                            ELSE ROUND(x.TotalAmountBase * d.ExchangeRate, 2) END
                                                       FROM purchase.PurchaseDocuments x
                                                       INNER JOIN inventory.DocumentTypes xt ON xt.Id = x.DocumentTypeId AND xt.Code = N'PRET'
                                                       WHERE x.SourceDocumentId = d.Id AND x.Status = 2) q), 0))) r
    CROSS APPLY (SELECT PaidAmount = ISNULL((SELECT SUM(a.AmountDocCurrency)
                                             FROM purchase.PaymentAllocations a
                                             INNER JOIN purchase.Payments pay ON pay.Id = a.PaymentId
                                             WHERE a.PurchaseDocumentId = d.Id AND a.RemovedAtUtc IS NULL AND pay.Status = 2), 0)) p
    WHERE d.Id = @DocumentId
);

GO

