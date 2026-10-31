-- KTG-2026-0003 +1996 more" above, in number order), so Supplier Payments opens an invoice of any number of containers (the
-- per-container split, purchase.fn_InvoiceContainerSettlement, lists them all); a CHG- number above 999,999 keeps all
-- its digits. Nothing else changes.
CREATE   FUNCTION purchase.fn_PayableDocument (@Kind NVARCHAR(10), @DocumentId INT)
RETURNS TABLE
AS
RETURN
(
    SELECT DocumentKind = N'PINV', DocumentId = d.Id, d.DocumentNumber, d.DocumentDate, PayeeId = d.SupplierId,
           d.CurrencyId, c.CurrencyCode, c.DecimalPlaces, d.ExchangeRate,
           DocumentTotal = d.TotalAmount, st.ReturnedAmount, st.PaidAmount, st.OutstandingAmount, st.PaymentStatus,
           -- (78) at most 5 refs, else the first 3 and "+N more" (aggregated as NVARCHAR(MAX): 9829 above about 267)
           ContainerRef = (SELECT CAST(STRING_AGG(CASE WHEN r.N <= 5 OR r.Rn <= 3 THEN CAST(r.ContainerRef AS NVARCHAR(MAX)) END, N', ')
                                           WITHIN GROUP (ORDER BY LEN(r.ContainerRef), r.ContainerRef)
                                       + CASE WHEN MAX(r.N) > 5 THEN N' +' + CAST(MAX(r.N) - 3 AS NVARCHAR(10)) + N' more' ELSE N'' END
                                       AS NVARCHAR(200))
                           FROM (SELECT q.ContainerRef, Rn = ROW_NUMBER() OVER (ORDER BY LEN(q.ContainerRef), q.ContainerRef), N = COUNT(*) OVER ()
                                 FROM (SELECT DISTINCT k.ContainerRef
                                       FROM purchase.PurchaseDocumentLines l
                                       INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
                                       INNER JOIN logistics.Containers k      ON k.Id = cl.ContainerId
                                       WHERE l.DocumentId = d.Id) q) r),
           ChargeTypeName = CAST(NULL AS NVARCHAR(100)), Reference = d.SupplierReference
    FROM purchase.PurchaseDocuments d
    INNER JOIN masterdata.Currencies c ON c.Id = d.CurrencyId
    CROSS APPLY purchase.fn_InvoiceSettlement(d.Id) st
    WHERE @Kind = N'PINV' AND d.Id = @DocumentId
    UNION ALL
    SELECT N'CHARGE', ch.Id, N'CHG-' + CASE WHEN ch.Id > 999999 THEN CAST(ch.Id AS NVARCHAR(10)) ELSE RIGHT(N'000000' + CAST(ch.Id AS NVARCHAR(10)), 6) END, ch.ChargeDate, ch.ProviderPartyId,
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

