SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ==================================================================================================
   68: Dashboard summary
   --------------------------------------------------------------------------------------------------
   Everything the Dashboard's key figures and "Needs attention" lists show, in one call, for one
   branch (NULL = all) and one period, with the period before it for the comparisons.

     reporting.usp_Dashboard_Summary   @BranchId, @From, @To, @PrevFrom, @PrevTo, @Today
     (and reporting.usp_Dashboard_Charts, below, for the charts)
       1  sales            sales and gross profit in the period and the one before (posted invoices less posted returns)
       2  receivables      what customers still owe on posted invoices, and the overdue part (as of @Today)
       3  payables         what we still owe on posted purchase invoices and posted container charges
       4  inventory        stock on hand at the item's moving average cost
       5  on the way       open purchase orders still to receive, and containers in transit / at port / cleared
       6  drafts           documents saved but not posted, per document type
       7  stock alerts     items below their minimum, warehouses below zero, out-of-stock sales in the period
       8  below minimum    the five items furthest below their minimum
       9  containers       arriving within 14 days, at port, near or past their last free day
      10  container list   up to eight of those, the most urgent first
      11  overdue          the five overdue customer invoices owing the most
      12  cheques          supplier-payment cheques still pending clearance
      13  cheque list      the five pending cheques due first
      14  base currency    the code of the currency every amount is in

   Money is in the base currency (each document's own amount divided by its own rate). Dates are the
   documents' dates; @Today is the reader's date, so "overdue" and "within 14 days" are theirs.
   The API decides which of these a reader may see; this procedure only computes them.
   ================================================================================================== */

IF SCHEMA_ID(N'reporting') IS NULL EXEC (N'CREATE SCHEMA reporting');
GO

CREATE OR ALTER PROCEDURE reporting.usp_Dashboard_Summary
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

/* --------------------------------------------------------------------------------------------------
   reporting.usp_Dashboard_Charts   @BranchId, @From, @To
     1  trend          the twelve months ending with @To's month: sales and gross profit (posted
                       invoices less returns) and purchases (posted supplier invoices less returns)
     2  by family      sales in the period per item family, the five largest and "Other"
     3  by warehouse   stock value now per warehouse, the five largest and "Other"
     4  by weekday     invoices and sales in the period per day of the week (1 = Monday)
   -------------------------------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE reporting.usp_Dashboard_Charts
    @BranchId INT = NULL,
    @From     DATE,
    @To       DATE
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @LastMonth DATE = DATEFROMPARTS(YEAR(@To), MONTH(@To), 1);
    DECLARE @FirstMonth DATE = DATEADD(MONTH, -11, @LastMonth);

    /* 1 ---------------------------------------------------------------------------- trend */
    WITH months AS (
        SELECT n = 0, MonthStart = @FirstMonth
        UNION ALL SELECT n + 1, DATEADD(MONTH, 1, MonthStart) FROM months WHERE n < 11
    ),
    sales AS (
        SELECT MonthStart = DATEFROMPARTS(YEAR(d.DocumentDate), MONTH(d.DocumentDate), 1),
               SalesBase = SUM(x.Sign * d.TotalAmountBase), GrossProfitBase = SUM(x.Sign * d.TotalGrossProfitBase)
        FROM sales.SalesDocuments d
        INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId
        CROSS APPLY (SELECT Sign = CASE t.Code WHEN N'SINV' THEN 1 WHEN N'SRET' THEN -1 ELSE 0 END) x
        WHERE d.Status = 2 AND x.Sign <> 0 AND d.DocumentDate >= @FirstMonth AND d.DocumentDate < DATEADD(MONTH, 1, @LastMonth)
          AND (@BranchId IS NULL OR d.BranchId = @BranchId)
        GROUP BY DATEFROMPARTS(YEAR(d.DocumentDate), MONTH(d.DocumentDate), 1)
    ),
    purchases AS (
        SELECT MonthStart = DATEFROMPARTS(YEAR(d.DocumentDate), MONTH(d.DocumentDate), 1),
               PurchasesBase = SUM(x.Sign * d.TotalAmountBase)
        FROM purchase.PurchaseDocuments d
        INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId
        CROSS APPLY (SELECT Sign = CASE t.Code WHEN N'PINV' THEN 1 WHEN N'PRET' THEN -1 ELSE 0 END) x
        WHERE d.Status IN (2, 4) AND x.Sign <> 0 AND d.DocumentDate >= @FirstMonth AND d.DocumentDate < DATEADD(MONTH, 1, @LastMonth)
          AND (@BranchId IS NULL OR d.BranchId = @BranchId)
        GROUP BY DATEFROMPARTS(YEAR(d.DocumentDate), MONTH(d.DocumentDate), 1)
    )
    SELECT m.MonthStart,
           SalesBase       = CONVERT(DECIMAL(18,2), ISNULL(s.SalesBase, 0)),
           GrossProfitBase = CONVERT(DECIMAL(18,2), ISNULL(s.GrossProfitBase, 0)),
           PurchasesBase   = CONVERT(DECIMAL(18,2), ISNULL(p.PurchasesBase, 0))
    FROM months m
    LEFT JOIN sales s ON s.MonthStart = m.MonthStart
    LEFT JOIN purchases p ON p.MonthStart = m.MonthStart
    ORDER BY m.MonthStart;

    /* 2 ---------------------------------------------------------------------------- by family */
    WITH byFamily AS (
        SELECT FamilyName = ISNULL(f.FamilyName, N'No family'),
               SalesBase = SUM(CASE t.Code WHEN N'SRET' THEN -1 ELSE 1 END * l.NetSalesBase)
        FROM sales.SalesDocumentLines l
        INNER JOIN sales.SalesDocuments d ON d.Id = l.DocumentId
        INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId AND t.Code IN (N'SINV', N'SRET')
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        LEFT JOIN masterdata.ItemFamilies f ON f.Id = i.ItemFamilyId
        WHERE d.Status = 2 AND d.DocumentDate BETWEEN @From AND @To
          AND (@BranchId IS NULL OR d.BranchId = @BranchId)
        GROUP BY ISNULL(f.FamilyName, N'No family')
    ),
    ranked AS (SELECT *, r = ROW_NUMBER() OVER (ORDER BY SalesBase DESC, FamilyName) FROM byFamily WHERE SalesBase > 0)
    SELECT Label = CASE WHEN r <= 5 THEN FamilyName ELSE N'Other' END,
           ValueBase = CONVERT(DECIMAL(18,2), SUM(SalesBase))
    FROM ranked
    GROUP BY CASE WHEN r <= 5 THEN FamilyName ELSE N'Other' END, CASE WHEN r <= 5 THEN r ELSE 6 END
    ORDER BY CASE WHEN r <= 5 THEN r ELSE 6 END;

    /* 3 ---------------------------------------------------------------------------- by warehouse */
    WITH byWarehouse AS (
        SELECT w.WarehouseName, ValueBase = SUM(s.OnHand * ISNULL(i.AverageCost, 0))
        FROM (SELECT m.ItemId, m.WarehouseId, OnHand = SUM(m.QuantityBase)
              FROM inventory.StockMovements m GROUP BY m.ItemId, m.WarehouseId) s
        INNER JOIN masterdata.Warehouses w ON w.Id = s.WarehouseId
        INNER JOIN inventory.Items i ON i.Id = s.ItemId
        WHERE s.OnHand > 0 AND (@BranchId IS NULL OR w.BranchId = @BranchId)
        GROUP BY w.WarehouseName
    ),
    ranked AS (SELECT *, r = ROW_NUMBER() OVER (ORDER BY ValueBase DESC, WarehouseName) FROM byWarehouse WHERE ValueBase > 0)
    SELECT Label = CASE WHEN r <= 5 THEN WarehouseName ELSE N'Other' END,
           ValueBase = CONVERT(DECIMAL(18,2), SUM(ValueBase))
    FROM ranked
    GROUP BY CASE WHEN r <= 5 THEN WarehouseName ELSE N'Other' END, CASE WHEN r <= 5 THEN r ELSE 6 END
    ORDER BY CASE WHEN r <= 5 THEN r ELSE 6 END;

    /* 4 ---------------------------------------------------------------------------- by weekday (1900-01-01 was a Monday) */
    WITH days AS (SELECT DayNo = 1 UNION ALL SELECT DayNo + 1 FROM days WHERE DayNo < 7)
    SELECT dd.DayNo,
           InvoiceCount = ISNULL(SUM(CASE WHEN t.Code = N'SINV' THEN 1 END), 0),
           SalesBase    = CONVERT(DECIMAL(18,2), ISNULL(SUM(CASE t.Code WHEN N'SINV' THEN d.TotalAmountBase WHEN N'SRET' THEN -d.TotalAmountBase END), 0))
    FROM days dd
    LEFT JOIN sales.SalesDocuments d
           ON DATEDIFF(DAY, '19000101', d.DocumentDate) % 7 + 1 = dd.DayNo
          AND d.Status = 2 AND d.DocumentDate BETWEEN @From AND @To
          AND (@BranchId IS NULL OR d.BranchId = @BranchId)
    LEFT JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId AND t.Code IN (N'SINV', N'SRET')
    GROUP BY dd.DayNo
    ORDER BY dd.DayNo;
END
GO

PRINT 'Script 68 applied: dashboard summary and charts.';
GO
