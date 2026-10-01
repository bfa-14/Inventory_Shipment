/* ================================================================== 2. What an invoice has been paid */

/* ONE DEFINITION OF "PAID". An inline table function, so the optimizer folds it into the calling
   query (it is applied per invoice row in the list) rather than running it row by row.

   Only a POSTED SALES INVOICE has a payment status: a draft owes nothing yet, a cancelled one owes
   nothing any more, and a return is not a debt. 0.005 is half the smallest unit of a two-decimal
   amount: a balance that small is rounding, not money. */
CREATE   FUNCTION sales.fn_InvoiceSettlement (@DocumentId INT)
RETURNS TABLE
AS
RETURN
(
    SELECT p.PaidAmount,
           OutstandingAmount = CASE WHEN d.Status = 2 AND d.DocumentTypeId = t.Id THEN d.TotalAmount - p.PaidAmount END,
           PaymentStatus     = CASE WHEN d.Status <> 2 OR d.DocumentTypeId <> t.Id THEN NULL
                                    WHEN p.PaidAmount <= 0 THEN N'Unpaid'
                                    WHEN d.TotalAmount - p.PaidAmount <= 0.005 THEN N'Paid'
                                    ELSE N'Partial' END
    FROM sales.SalesDocuments d
    CROSS APPLY (SELECT Id FROM inventory.DocumentTypes WHERE Code = N'SINV') t
    CROSS APPLY (SELECT PaidAmount = ISNULL((SELECT SUM(a.AmountInvoiceCurrency)
                                             FROM sales.ReceiptAllocations a
                                             INNER JOIN sales.Receipts r ON r.Id = a.ReceiptId
                                             WHERE a.SalesDocumentId = d.Id AND a.RemovedAtUtc IS NULL AND r.Status = 2), 0)) p
    WHERE d.Id = @DocumentId
);

GO

