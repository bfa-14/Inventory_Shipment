CREATE   PROCEDURE reporting.usp_Dashboard_Summary
    @BranchId INT  = NULL,
    @From     DATE,
    @To       DATE,
    @PrevFrom DATE,
    @PrevTo   DATE,
    @Today    DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @Today IS NULL SET @Today = CAST(SYSUTCDATETIME() AS DATE);

    /* 1 ---------------------------------------------------------------------------- sales */
    SELECT SalesBase           = CONVERT(DECIMAL(18,2), ISNULL(SUM(CASE WHEN d.DocumentDate BETWEEN @From AND @To THEN x.Sign * d.TotalAmountBase END), 0)),
           GrossProfitBase     = ISNULL(SUM(CASE WHEN d.DocumentDate BETWEEN @From AND @To THEN x.Sign * d.TotalGrossProfitBase END), 0),
           InvoiceCount        = ISNULL(SUM(CASE WHEN d.DocumentDate BETWEEN @From AND @To AND x.Sign = 1 THEN 1 END), 0),
           PrevSalesBase       = ISNULL(SUM(CASE WHEN d.DocumentDate BETWEEN @PrevFrom AND @PrevTo THEN x.Sign * d.TotalAmountBase END), 0),
           PrevGrossProfitBase = ISNULL(SUM(CASE WHEN d.DocumentDate BETWEEN @PrevFrom AND @PrevTo THEN x.Sign * d.TotalGrossProfitBase END), 0)
    FROM sales.SalesDocuments d
    INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId
    CROSS APPLY (SELECT Sign = CASE t.Code WHEN N'SINV' THEN 1 WHEN N'SRET' THEN -1 ELSE 0 END) x
    WHERE d.Status = 2 AND x.Sign <> 0
      AND (@BranchId IS NULL OR d.BranchId = @BranchId)
      AND (d.DocumentDate BETWEEN @From AND @To OR d.DocumentDate BETWEEN @PrevFrom AND @PrevTo);

    /* 2 ---------------------------------------------------------------------------- receivables */
    SELECT OutstandingBase = CONVERT(DECIMAL(18,2), ISNULL(SUM(s.OutstandingAmount / NULLIF(d.ExchangeRate, 0)), 0)),
           OverdueBase     = CONVERT(DECIMAL(18,2), ISNULL(SUM(CASE WHEN d.DueDate < @Today THEN s.OutstandingAmount / NULLIF(d.ExchangeRate, 0) END), 0)),
           OpenCount       = COUNT(*),
           OverdueCount    = ISNULL(SUM(CASE WHEN d.DueDate < @Today THEN 1 END), 0)
    FROM sales.SalesDocuments d
    INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId AND t.Code = N'SINV'
    CROSS APPLY sales.fn_InvoiceSettlement(d.Id) s
    WHERE d.Status = 2 AND s.OutstandingAmount > 0.005
      AND (@BranchId IS NULL OR d.BranchId = @BranchId);

    /* 3 ---------------------------------------------------------------------------- payables */
    SELECT InvoicesBase = (SELECT CONVERT(DECIMAL(18,2), ISNULL(SUM(s.OutstandingAmount / NULLIF(d.ExchangeRate, 0)), 0))
                           FROM purchase.PurchaseDocuments d
                           INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId AND t.Code = N'PINV'
                           CROSS APPLY purchase.fn_InvoiceSettlement(d.Id) s
                           WHERE d.Status = 2 AND s.OutstandingAmount > 0.005
                             AND (@BranchId IS NULL OR d.BranchId = @BranchId)),
           InvoiceCount = (SELECT COUNT(*)
                           FROM purchase.PurchaseDocuments d
                           INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId AND t.Code = N'PINV'
                           CROSS APPLY purchase.fn_InvoiceSettlement(d.Id) s
                           WHERE d.Status = 2 AND s.OutstandingAmount > 0.005
                             AND (@BranchId IS NULL OR d.BranchId = @BranchId)),
           ChargesBase  = (SELECT CONVERT(DECIMAL(18,2), ISNULL(SUM(s.OutstandingAmount / NULLIF(c.ExchangeRate, 0)), 0))
                           FROM logistics.ContainerCharges c
                           INNER JOIN logistics.Containers k ON k.Id = c.ContainerId
                           CROSS APPLY logistics.fn_ContainerChargeSettlement(c.Id) s
                           WHERE c.Status = 2 AND s.OutstandingAmount > 0.005
                             AND (@BranchId IS NULL OR k.BranchId = @BranchId)),
           ChargeCount  = (SELECT COUNT(*)
                           FROM logistics.ContainerCharges c
                           INNER JOIN logistics.Containers k ON k.Id = c.ContainerId
                           CROSS APPLY logistics.fn_ContainerChargeSettlement(c.Id) s
                           WHERE c.Status = 2 AND s.OutstandingAmount > 0.005
                             AND (@BranchId IS NULL OR k.BranchId = @BranchId));

    /* the stock of every item in every warehouse of the branch, used by 4 and 7 */
    DECLARE @Stock TABLE (ItemId INT NOT NULL, WarehouseId INT NOT NULL, OnHand INT NOT NULL, PRIMARY KEY (ItemId, WarehouseId));
    INSERT INTO @Stock (ItemId, WarehouseId, OnHand)
    SELECT m.ItemId, m.WarehouseId, SUM(m.QuantityBase)
    FROM inventory.StockMovements m
    INNER JOIN masterdata.Warehouses w ON w.Id = m.WarehouseId
    WHERE @BranchId IS NULL OR w.BranchId = @BranchId
    GROUP BY m.ItemId, m.WarehouseId;

    /* 4 ---------------------------------------------------------------------------- inventory */
    SELECT ValueBase    = CONVERT(DECIMAL(18,2), ISNULL(SUM(CASE WHEN s.OnHand > 0 THEN s.OnHand * ISNULL(i.AverageCost, 0) END), 0)),
           ItemsInStock = COUNT(DISTINCT CASE WHEN s.OnHand > 0 THEN s.ItemId END)
    FROM @Stock s
    INNER JOIN inventory.Items i ON i.Id = s.ItemId;

    /* 5 ---------------------------------------------------------------------------- on the way */
    SELECT OnOrderPieces = (SELECT ISNULL(SUM(l.QuantityBase - l.ReceivedQuantityBase), 0)
                            FROM purchase.PurchaseDocumentLines l
                            INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
                            INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId AND t.Code = N'PO'
                            WHERE d.Status = 2 AND l.QuantityBase > l.ReceivedQuantityBase
                              AND (@BranchId IS NULL OR d.BranchId = @BranchId)),
           OpenOrders    = (SELECT COUNT(DISTINCT d.Id)
                            FROM purchase.PurchaseDocumentLines l
                            INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
                            INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId AND t.Code = N'PO'
                            WHERE d.Status = 2 AND l.QuantityBase > l.ReceivedQuantityBase
                              AND (@BranchId IS NULL OR d.BranchId = @BranchId)),
           InTransitPieces = (SELECT ISNULL(SUM(cl.QuantityBase - ISNULL(cl.ReceivedQuantityBase, 0)), 0)
                            FROM logistics.ContainerLines cl
                            INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                            WHERE c.Status IN (3, 4, 5) AND cl.QuantityBase > ISNULL(cl.ReceivedQuantityBase, 0)
                              AND (@BranchId IS NULL OR c.BranchId = @BranchId)),
           ContainersInTransit = (SELECT COUNT(*) FROM logistics.Containers c
                                  WHERE c.Status IN (3, 4, 5) AND (@BranchId IS NULL OR c.BranchId = @BranchId));

    /* 6 ---------------------------------------------------------------------------- drafts */
    SELECT x.Kind, x.TypeCode, x.DraftCount
    FROM (
        SELECT Kind = N'Sales', TypeCode = t.Code, DraftCount = COUNT(*)
        FROM sales.SalesDocuments d INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId
        WHERE d.Status = 1 AND (@BranchId IS NULL OR d.BranchId = @BranchId)
        GROUP BY t.Code
        UNION ALL
        SELECT N'Purchase', t.Code, COUNT(*)
        FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId
        WHERE d.Status = 1 AND (@BranchId IS NULL OR d.BranchId = @BranchId)
        GROUP BY t.Code
        UNION ALL
        SELECT N'Inventory', t.Code, COUNT(*)
        FROM inventory.StockDocuments d INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId
        WHERE d.Status = 1 AND (@BranchId IS NULL OR d.BranchId = @BranchId)
        GROUP BY t.Code
        UNION ALL
        SELECT N'Receipt', N'RCPT', COUNT(*) FROM sales.Receipts r
        WHERE r.Status = 1 AND (@BranchId IS NULL OR r.BranchId = @BranchId)
        UNION ALL
        SELECT N'Payment', N'PAY', COUNT(*) FROM purchase.Payments p
        WHERE p.Status = 1 AND (@BranchId IS NULL OR p.BranchId = @BranchId)
    ) x
    WHERE x.DraftCount > 0;

    /* per item: the stock that counts against its minimum (the branch's, or the company's) */
    DECLARE @Item TABLE (ItemId INT PRIMARY KEY, OnHand INT NOT NULL);
    INSERT INTO @Item (ItemId, OnHand)
    SELECT i.Id, ISNULL((SELECT SUM(s.OnHand) FROM @Stock s WHERE s.ItemId = i.Id), 0)
    FROM inventory.Items i
    WHERE i.IsActive = 1 AND i.MinQuantity > 0;

    /* 7 ---------------------------------------------------------------------------- stock alerts */
    SELECT BelowMinimum      = (SELECT COUNT(*) FROM @Item x INNER JOIN inventory.Items i ON i.Id = x.ItemId WHERE x.OnHand < i.MinQuantity),
           NegativeStock     = (SELECT COUNT(*) FROM @Stock s WHERE s.OnHand < 0),
           OutOfStockSales   = (SELECT COUNT(*) FROM sales.OutOfStockSaleAudit a
                                INNER JOIN sales.SalesDocuments d ON d.Id = a.SalesDocumentId
                                WHERE CAST(a.SoldAtUtc AS DATE) BETWEEN @From AND @To
                                  AND (@BranchId IS NULL OR d.BranchId = @BranchId));

    /* 8 ---------------------------------------------------------------------------- below minimum */
    SELECT TOP (5) i.Id AS ItemId, i.ItemCode, i.ItemName, x.OnHand, i.MinQuantity, Missing = i.MinQuantity - x.OnHand
    FROM @Item x INNER JOIN inventory.Items i ON i.Id = x.ItemId
    WHERE x.OnHand < i.MinQuantity
    ORDER BY i.MinQuantity - x.OnHand DESC, i.ItemCode;

    /* 9 ---------------------------------------------------------------------------- containers */
    DECLARE @Soon DATE = DATEADD(DAY, 14, @Today), @FreeDayWarning DATE = DATEADD(DAY, 7, @Today);
    SELECT ArrivingSoon    = ISNULL(SUM(CASE WHEN c.Status IN (2, 3) AND c.Eta BETWEEN @Today AND @Soon THEN 1 END), 0),
           AtPort          = ISNULL(SUM(CASE WHEN c.Status = 4 THEN 1 END), 0),
           NearLastFreeDay = ISNULL(SUM(CASE WHEN c.Status IN (4, 5) AND c.LastFreeDay IS NOT NULL AND c.LastFreeDay <= @FreeDayWarning THEN 1 END), 0)
    FROM logistics.Containers c
    WHERE @BranchId IS NULL OR c.BranchId = @BranchId;

    /* 10 --------------------------------------------------------------------------- container list */
    SELECT TOP (8) c.Id AS ContainerId, c.ContainerRef, c.ContainerNo, c.Status AS StatusCode, c.Eta, c.LastFreeDay,
           Reason = CASE WHEN c.Status IN (4, 5) AND c.LastFreeDay IS NOT NULL AND c.LastFreeDay <= @FreeDayWarning
                              THEN CASE WHEN c.LastFreeDay < @Today THEN N'PastLastFreeDay' ELSE N'NearLastFreeDay' END
                         WHEN c.Status = 4 THEN N'AtPort'
                         ELSE N'ArrivingSoon' END
    FROM logistics.Containers c
    WHERE (@BranchId IS NULL OR c.BranchId = @BranchId)
      AND ((c.Status IN (2, 3) AND c.Eta BETWEEN @Today AND @Soon)
        OR c.Status = 4
        OR (c.Status IN (4, 5) AND c.LastFreeDay IS NOT NULL AND c.LastFreeDay <= @FreeDayWarning))
    ORDER BY CASE WHEN c.LastFreeDay IS NOT NULL AND c.Status IN (4, 5) THEN c.LastFreeDay ELSE ISNULL(c.Eta, '9999-12-31') END, c.ContainerRef;

    /* 11 --------------------------------------------------------------------------- overdue */
    SELECT TOP (5) d.Id AS DocumentId, d.DocumentNumber, p.PartyName AS ClientName, d.DueDate,
           DaysOverdue = DATEDIFF(DAY, d.DueDate, @Today),
           OutstandingBase = CONVERT(DECIMAL(18,2), s.OutstandingAmount / NULLIF(d.ExchangeRate, 0))
    FROM sales.SalesDocuments d
    INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId AND t.Code = N'SINV'
    INNER JOIN masterdata.Parties p ON p.Id = d.ClientId
    CROSS APPLY sales.fn_InvoiceSettlement(d.Id) s
    WHERE d.Status = 2 AND s.OutstandingAmount > 0.005 AND d.DueDate < @Today
      AND (@BranchId IS NULL OR d.BranchId = @BranchId)
    ORDER BY s.OutstandingAmount / NULLIF(d.ExchangeRate, 0) DESC;

    /* 12 --------------------------------------------------------------------------- cheques */
    SELECT PendingCount = COUNT(*), PendingBase = CONVERT(DECIMAL(18,2), ISNULL(SUM(l.AmountBase), 0)),
           DueCount = ISNULL(SUM(CASE WHEN l.ChequeDueDate <= @Today THEN 1 END), 0)
    FROM purchase.PaymentLines l
    INNER JOIN purchase.Payments p ON p.Id = l.PaymentId
    WHERE p.Status = 2 AND l.ClearanceStatus = 1
      AND (@BranchId IS NULL OR p.BranchId = @BranchId);

    /* 13 --------------------------------------------------------------------------- cheque list */
    SELECT TOP (5) p.Id AS PaymentId, p.PaymentNumber, pt.PartyName AS PayeeName, l.ChequeNo, l.ChequeDueDate, l.AmountBase
    FROM purchase.PaymentLines l
    INNER JOIN purchase.Payments p ON p.Id = l.PaymentId
    INNER JOIN masterdata.Parties pt ON pt.Id = p.PayeeId
    WHERE p.Status = 2 AND l.ClearanceStatus = 1
      AND (@BranchId IS NULL OR p.BranchId = @BranchId)
    ORDER BY ISNULL(l.ChequeDueDate, '9999-12-31'), p.PaymentNumber;

    /* 14 --------------------------------------------------------------------------- the base currency the money is in */
    SELECT BaseCurrencyCode = (SELECT TOP (1) CurrencyCode FROM masterdata.Currencies WHERE IsBaseCurrency = 1 ORDER BY Id);
END

GO

