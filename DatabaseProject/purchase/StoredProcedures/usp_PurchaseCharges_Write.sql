CREATE   PROCEDURE purchase.usp_PurchaseCharges_Write
    @DocumentKind      NVARCHAR(10),
    @DocumentId        INT,
    @DocumentDate      DATE,
    @DefaultCurrencyId INT,
    @TargetInvoiceId   INT,
    @Charges           purchase.tvp_PurchaseCharge READONLY,
    @ManualAllocations purchase.tvp_ManualAllocation READONLY,
    @UserId            INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg = N'Charge ' + CAST(c.LineNumber AS NVARCHAR(10)) + N': ' +
        CASE WHEN ct.Id IS NULL THEN N'charge type not found.'
             WHEN ct.IsActive = 0 THEN N'charge type ' + ct.ChargeName + N' is inactive.'
             WHEN c.Amount < 0 THEN N'amount cannot be negative.'
             WHEN c.AllocationMethod IS NOT NULL AND c.AllocationMethod NOT IN (N'Value', N'Quantity', N'Weight', N'Volume', N'Manual') THEN N'unknown allocation method.'
             WHEN c.ExchangeRate IS NOT NULL AND c.ExchangeRate <= 0 THEN N'exchange rate must be greater than zero.'
             WHEN c.CurrencyId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = c.CurrencyId AND IsActive = 1) THEN N'currency not found or inactive.'
             WHEN c.ProviderPartyId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = c.ProviderPartyId AND IsActive = 1) THEN N'provider not found or inactive.' END
    FROM @Charges c
    LEFT JOIN purchase.ChargeTypes ct ON ct.Id = c.ChargeTypeId
    WHERE ct.Id IS NULL OR ct.IsActive = 0 OR c.Amount < 0
       OR (c.AllocationMethod IS NOT NULL AND c.AllocationMethod NOT IN (N'Value', N'Quantity', N'Weight', N'Volume', N'Manual'))
       OR (c.ExchangeRate IS NOT NULL AND c.ExchangeRate <= 0)
       OR (c.CurrencyId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = c.CurrencyId AND IsActive = 1))
       OR (c.ProviderPartyId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = c.ProviderPartyId AND IsActive = 1))
    ORDER BY c.LineNumber;
    IF @Msg IS NOT NULL THROW 65012, @Msg, 1;

    -- Resolve currency + rate per charge (base currency -> 1).
    DECLARE @Resolved TABLE (LineNumber INT PRIMARY KEY, CurrencyId INT, RateType TINYINT, Rate DECIMAL(18,6), AmountBase DECIMAL(18,2), Method NVARCHAR(10), InLanded BIT);
    INSERT INTO @Resolved (LineNumber, CurrencyId, RateType, Rate, AmountBase, Method, InLanded)
    SELECT c.LineNumber, cur.Id, ISNULL(c.RateType, 1),
           r.Rate,
           ROUND(c.Amount / NULLIF(r.Rate, 0), 2),
           ISNULL(c.AllocationMethod, ct.AllocationMethod),
           ct.IncludeInLandedCost
    FROM @Charges c
    INNER JOIN purchase.ChargeTypes ct ON ct.Id = c.ChargeTypeId
    CROSS APPLY (SELECT Id, IsBaseCurrency FROM masterdata.Currencies WHERE Id = ISNULL(c.CurrencyId, @DefaultCurrencyId)) cur
    CROSS APPLY (SELECT Rate = CASE WHEN cur.IsBaseCurrency = 1 THEN 1 ELSE COALESCE(c.ExchangeRate, masterdata.fn_GetRate(cur.Id, ISNULL(c.RateType, 1), @DocumentDate)) END) r;

    SELECT TOP (1) @Msg = N'Charge ' + CAST(LineNumber AS NVARCHAR(10)) + N': no exchange rate for its currency on ' + CONVERT(NVARCHAR(10), @DocumentDate, 120) + N' - add one or enter the rate.'
    FROM @Resolved WHERE Rate IS NULL ORDER BY LineNumber;
    IF @Msg IS NOT NULL THROW 65008, @Msg, 1;

    -- Manual allocations must match a Manual charge, reference lines of the target invoice and sum to the charge amount.
    IF EXISTS (SELECT 1 FROM @ManualAllocations m LEFT JOIN @Resolved r ON r.LineNumber = m.ChargeLineNumber WHERE r.LineNumber IS NULL OR r.Method <> N'Manual')
        THROW 65012, 'A manual allocation refers to a charge that does not exist or is not allocated manually.', 1;
    IF EXISTS (SELECT 1 FROM @ManualAllocations m WHERE NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines l WHERE l.Id = m.PurchaseLineId AND l.DocumentId = @TargetInvoiceId))
        THROW 65012, 'A manual allocation refers to a line that does not belong to the invoice.', 1;
    IF EXISTS (SELECT 1 FROM @ManualAllocations WHERE AmountBase < 0) THROW 65012, 'Manual allocation amounts cannot be negative.', 1;
    SELECT TOP (1) @Msg = N'Charge ' + CAST(r.LineNumber AS NVARCHAR(10)) + N': manual allocations (' + CAST(ISNULL(m.Total, 0) AS NVARCHAR(30)) + N') must equal the charge amount in base currency (' + CAST(r.AmountBase AS NVARCHAR(30)) + N').'
    FROM @Resolved r
    LEFT JOIN (SELECT ChargeLineNumber, Total = SUM(AmountBase) FROM @ManualAllocations GROUP BY ChargeLineNumber) m ON m.ChargeLineNumber = r.LineNumber
    WHERE r.Method = N'Manual' AND r.InLanded = 1 AND r.AmountBase > 0 AND ABS(ISNULL(m.Total, 0) - r.AmountBase) > 0.01
    ORDER BY r.LineNumber;
    IF @Msg IS NOT NULL THROW 65012, @Msg, 1;

    DELETE a FROM purchase.PurchaseChargeAllocations a INNER JOIN purchase.PurchaseCharges c ON c.Id = a.ChargeId WHERE c.DocumentKind = @DocumentKind AND c.DocumentId = @DocumentId;
    DELETE FROM purchase.PurchaseCharges WHERE DocumentKind = @DocumentKind AND DocumentId = @DocumentId;

    INSERT INTO purchase.PurchaseCharges (DocumentKind, DocumentId, LineNumber, ChargeTypeId, Description, ProviderPartyId, Reference, CurrencyId, RateType, ExchangeRate,
                                          Amount, AmountBase, AllocationMethod, IncludeInLandedCost, IncludedInSupplierInvoice, Notes, CreatedBy)
    SELECT @DocumentKind, @DocumentId, c.LineNumber, c.ChargeTypeId, NULLIF(LTRIM(RTRIM(c.Description)), N''), c.ProviderPartyId, NULLIF(LTRIM(RTRIM(c.Reference)), N''),
           r.CurrencyId, r.RateType, r.Rate, c.Amount, r.AmountBase, r.Method, r.InLanded, ISNULL(c.IncludedInSupplierInvoice, 0), NULLIF(LTRIM(RTRIM(c.Notes)), N''), @UserId
    FROM @Charges c INNER JOIN @Resolved r ON r.LineNumber = c.LineNumber;

    INSERT INTO purchase.PurchaseChargeAllocations (ChargeId, PurchaseLineId, Basis, AmountBase, IsManual)
    SELECT pc.Id, m.PurchaseLineId, NULL, m.AmountBase, 1
    FROM @ManualAllocations m
    INNER JOIN purchase.PurchaseCharges pc ON pc.DocumentKind = @DocumentKind AND pc.DocumentId = @DocumentId AND pc.LineNumber = m.ChargeLineNumber
    WHERE pc.IncludeInLandedCost = 1;
END

GO

