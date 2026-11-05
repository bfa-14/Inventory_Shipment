/* ================================================================== 1. A container's payment status */

-- (108) What the posted supplier invoices of a container's goods are paid, from its share of each (script 73's split).
-- Always one row, so a CROSS APPLY keeps the container.
CREATE   FUNCTION purchase.fn_Container_PaymentStatus (@ContainerId INT)
RETURNS TABLE
AS
RETURN
(
    WITH inv AS (
        SELECT DISTINCT d.Id, d.ExchangeRate
        FROM logistics.ContainerLines cl
        INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
        INNER JOIN purchase.PurchaseDocuments d       ON d.Id = pil.DocumentId AND d.Status = 2
        INNER JOIN inventory.DocumentTypes t          ON t.Id = d.DocumentTypeId AND t.Code = N'PINV'
        WHERE cl.ContainerId = @ContainerId
    ),
    shares AS (
        SELECT inv.ExchangeRate, x.ContainerAmount, x.PaidAmount
        FROM inv
        CROSS APPLY purchase.fn_InvoiceContainerSettlement(inv.Id) x
        WHERE x.ContainerId = @ContainerId
    )
    SELECT PaymentStatus = CASE WHEN NOT EXISTS (SELECT 1 FROM shares) THEN N'NotInvoiced'
                                WHEN NOT EXISTS (SELECT 1 FROM shares WHERE ContainerAmount - PaidAmount > 0.005) THEN N'Paid'
                                WHEN NOT EXISTS (SELECT 1 FROM shares WHERE PaidAmount > 0) THEN N'Unpaid'
                                ELSE N'Partial' END,
           InvoicedAmountBase = (SELECT CAST(SUM(ContainerAmount / NULLIF(ExchangeRate, 0)) AS DECIMAL(18,2)) FROM shares),
           PaidAmountBase = (SELECT CAST(SUM(PaidAmount / NULLIF(ExchangeRate, 0)) AS DECIMAL(18,2)) FROM shares)
);