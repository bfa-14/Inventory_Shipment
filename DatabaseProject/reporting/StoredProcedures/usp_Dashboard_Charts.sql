/* --------------------------------------------------------------------------------------------------
   reporting.usp_Dashboard_Charts   @BranchId, @From, @To
     1  trend          the twelve months ending with @To's month: sales and gross profit (posted
                       invoices less returns) and purchases (posted supplier invoices less returns)
     2  by family      sales in the period per item family, the five largest and "Other"
     3  by warehouse   stock value now per warehouse, the five largest and "Other"
     4  by weekday     invoices and sales in the period per day of the week (1 = Monday)
   -------------------------------------------------------------------------------------------------- */
CREATE   PROCEDURE reporting.usp_Dashboard_Charts
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

