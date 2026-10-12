/* ONE ROW PER PAYABLE DOCUMENT, whatever its kind: what the allocation tables, the open-documents list and
   the checks read. Number, date, payee, currency and rate, total, paid / outstanding / status, the
   container(s) it concerns and, for a charge, its type. */
CREATE   FUNCTION purchase.fn_PayableDocument (@Kind NVARCHAR(10), @DocumentId INT)
RETURNS TABLE
AS
RETURN
(
    SELECT DocumentKind = N'PINV', DocumentId = d.Id, d.DocumentNumber, d.DocumentDate, PayeeId = d.SupplierId,
           d.CurrencyId, c.CurrencyCode, c.DecimalPlaces, d.ExchangeRate,
           DocumentTotal = d.TotalAmount, st.ReturnedAmount, st.PaidAmount, st.OutstandingAmount, st.PaymentStatus,
           ContainerRef = (SELECT STRING_AGG(r.ContainerRef, N', ') WITHIN GROUP (ORDER BY r.ContainerRef)
                           FROM (SELECT DISTINCT k.ContainerRef
                                 FROM purchase.PurchaseDocumentLines l
                                 INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
                                 INNER JOIN logistics.Containers k      ON k.Id = cl.ContainerId
                                 WHERE l.DocumentId = d.Id) r),
           ChargeTypeName = CAST(NULL AS NVARCHAR(100)), Reference = d.SupplierReference
    FROM purchase.PurchaseDocuments d
    INNER JOIN masterdata.Currencies c ON c.Id = d.CurrencyId
    CROSS APPLY purchase.fn_InvoiceSettlement(d.Id) st
    WHERE @Kind = N'PINV' AND d.Id = @DocumentId
    UNION ALL
    SELECT N'CHARGE', ch.Id, N'CHG-' + RIGHT(N'000000' + CAST(ch.Id AS NVARCHAR(10)), 6), ch.ChargeDate, ch.ProviderPartyId,
           ch.CurrencyId, c.CurrencyCode, c.DecimalPlaces, ch.ExchangeRate,
           ch.Amount, CAST(0 AS DECIMAL(18,2)), st.PaidAmount, st.OutstandingAmount, st.PaymentStatus,
           k.ContainerRef, t.ChargeName, ch.Reference
    FROM logistics.ContainerCharges ch
    INNER JOIN masterdata.Currencies c ON c.Id = ch.CurrencyId
    INNER JOIN logistics.Containers k  ON k.Id = ch.ContainerId
    INNER JOIN purchase.ChargeTypes t  ON t.Id = ch.ChargeTypeId
    CROSS APPLY logistics.fn_ContainerChargeSettlement(ch.Id) st
    WHERE @Kind = N'CHARGE' AND ch.Id = @DocumentId
);

GO

