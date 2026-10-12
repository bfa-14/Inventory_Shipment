/* ================================================================== 11. What a payee is still owed */

/* The documents the allocation table lists: this payee's POSTED purchase invoices (PINV) or container
   charges (CHARGE) with something left to pay, oldest first. Fully paid ones never appear. When the
   payment's currency, rate and date are given, DefaultRateToPayment is the multiplier the row pre-fills. */
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
END

GO

