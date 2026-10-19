CREATE   PROCEDURE purchase.usp_Payment_OpenDocuments
    @PayeeId           INT,
    @DocumentKind      NVARCHAR(10),          -- PINV | CHARGE
    @PaymentCurrencyId INT           = NULL,
    @PaymentRate       DECIMAL(18,6) = NULL,
    @AsOfDate          DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @AsOfDate IS NULL SET @AsOfDate = CAST(SYSUTCDATETIME() AS DATE);
    IF @DocumentKind NOT IN (N'PINV', N'CHARGE') THROW 73000, 'Document kind must be PINV or CHARGE.', 1;

    SELECT pd.DocumentKind, pd.DocumentId, pd.DocumentNumber, pd.DocumentDate, pd.ContainerRef, pd.ChargeTypeName, pd.Reference AS DocumentReference,
           pd.CurrencyId, pd.CurrencyCode, pd.DecimalPlaces, pd.ExchangeRate,
           pd.DocumentTotal, pd.ReturnedAmount, PreviouslyPaid = pd.PaidAmount, pd.OutstandingAmount, pd.PaymentStatus,
           OutstandingBase = CONVERT(DECIMAL(18,2), pd.OutstandingAmount / pd.ExchangeRate),
           DefaultRateToPayment = CASE WHEN @PaymentCurrencyId IS NULL THEN NULL
                                       ELSE purchase.fn_RateToPayment(pd.CurrencyId, @PaymentCurrencyId,
                                            COALESCE(@PaymentRate, masterdata.fn_GetRate(@PaymentCurrencyId, 1, @AsOfDate)), @AsOfDate) END
    FROM (SELECT d.Id FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId AND t.Code = N'PINV'
          WHERE @DocumentKind = N'PINV' AND d.SupplierId = @PayeeId AND d.Status = 2
          UNION ALL
          SELECT Id FROM logistics.ContainerCharges WHERE @DocumentKind = N'CHARGE' AND ProviderPartyId = @PayeeId AND Status = 2) ids
    CROSS APPLY purchase.fn_PayableDocument(@DocumentKind, ids.Id) pd
    WHERE pd.PaymentStatus IN (N'Unpaid', N'Partial') AND pd.OutstandingAmount > 0.005
    ORDER BY pd.DocumentDate, pd.DocumentId;

    -- Script 73: the containers of each open invoice that has some, for the container split.
    SELECT s.DocumentId, s.ContainerId, s.ContainerRef, s.ContainerNo, s.Items, s.ContainerAmount,
           PreviouslyPaid = s.PaidAmount, s.OutstandingAmount, s.PaymentStatus, AllocatedAmount = CAST(0 AS DECIMAL(18,2))
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId AND t.Code = N'PINV'
    CROSS APPLY purchase.fn_InvoiceSettlement(d.Id) st
    CROSS APPLY purchase.fn_InvoiceContainerSettlement(d.Id) s
    WHERE @DocumentKind = N'PINV' AND d.SupplierId = @PayeeId AND d.Status = 2
      AND st.OutstandingAmount > 0.005 AND s.HasContainers = 1
    ORDER BY d.DocumentDate, d.Id, CASE WHEN s.ContainerKey = 0 THEN 1 ELSE 0 END, s.ContainerRef;
END

GO

