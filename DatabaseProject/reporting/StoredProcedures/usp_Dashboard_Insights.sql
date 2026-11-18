/* ================================================================== 1. reporting.usp_Dashboard_Insights */

CREATE   PROCEDURE reporting.usp_Dashboard_Insights
    @BranchId INT  = NULL,
    @From     DATE,
    @To       DATE,
    @Today    DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @Today IS NULL SET @Today = CAST(SYSUTCDATETIME() AS DATE);
    DECLARE @SlowDays INT = 90;

    /* 1 ---------------------------------------------------------------------------- top items */
    SELECT TOP (10) i.Id AS ItemId, i.ItemCode, i.ItemName,
           Pieces          = SUM(x.Sign * l.QuantityBase),
           SalesBase       = CONVERT(DECIMAL(18,2), SUM(x.Sign * l.NetSalesBase)),
           GrossProfitBase = CONVERT(DECIMAL(18,2), SUM(x.Sign * l.GrossProfitBase))
    FROM sales.SalesDocumentLines l
    INNER JOIN sales.SalesDocuments d ON d.Id = l.DocumentId
    INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId
    CROSS APPLY (SELECT Sign = CASE t.Code WHEN N'SINV' THEN 1 WHEN N'SRET' THEN -1 ELSE 0 END) x
    INNER JOIN inventory.Items i ON i.Id = l.ItemId
    WHERE d.Status = 2 AND x.Sign <> 0 AND d.DocumentDate BETWEEN @From AND @To
      AND (@BranchId IS NULL OR d.BranchId = @BranchId)
    GROUP BY i.Id, i.ItemCode, i.ItemName
    HAVING SUM(x.Sign * l.NetSalesBase) > 0
    ORDER BY SUM(x.Sign * l.NetSalesBase) DESC, i.ItemCode;

    /* 2 ---------------------------------------------------------------------------- top customers */
    WITH bought AS (
        SELECT TOP (10) d.ClientId,
               SalesBase    = SUM(x.Sign * d.TotalAmountBase),
               InvoiceCount = SUM(CASE WHEN x.Sign = 1 THEN 1 ELSE 0 END)
        FROM sales.SalesDocuments d
        INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId
        CROSS APPLY (SELECT Sign = CASE t.Code WHEN N'SINV' THEN 1 WHEN N'SRET' THEN -1 ELSE 0 END) x
        WHERE d.Status = 2 AND x.Sign <> 0 AND d.DocumentDate BETWEEN @From AND @To
          AND (@BranchId IS NULL OR d.BranchId = @BranchId)
        GROUP BY d.ClientId
        HAVING SUM(x.Sign * d.TotalAmountBase) > 0
        ORDER BY SUM(x.Sign * d.TotalAmountBase) DESC
    )
    SELECT b.ClientId, ClientName = p.PartyName,
           SalesBase = CONVERT(DECIMAL(18,2), b.SalesBase), b.InvoiceCount,
           OutstandingBase = CONVERT(DECIMAL(18,2), ISNULL(o.OutstandingBase, 0))
    FROM bought b
    INNER JOIN masterdata.Parties p ON p.Id = b.ClientId
    OUTER APPLY (SELECT OutstandingBase = SUM(s.OutstandingAmount / NULLIF(d.ExchangeRate, 0))
                 FROM sales.SalesDocuments d
                 INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId AND t.Code = N'SINV'
                 CROSS APPLY sales.fn_InvoiceSettlement(d.Id) s
                 WHERE d.ClientId = b.ClientId AND d.Status = 2 AND s.OutstandingAmount > 0.005
                   AND (@BranchId IS NULL OR d.BranchId = @BranchId)) o
    ORDER BY b.SalesBase DESC, p.PartyName;

    /* 3 ---------------------------------------------------------------------------- sales by branch (every branch) */
    SELECT b.Id AS BranchId, b.BranchName,
           SalesBase       = CONVERT(DECIMAL(18,2), ISNULL(SUM(x.Sign * d.TotalAmountBase), 0)),
           GrossProfitBase = CONVERT(DECIMAL(18,2), ISNULL(SUM(x.Sign * d.TotalGrossProfitBase), 0)),
           InvoiceCount    = ISNULL(SUM(CASE WHEN x.Sign = 1 THEN 1 END), 0)
    FROM sales.SalesDocuments d
    INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId
    CROSS APPLY (SELECT Sign = CASE t.Code WHEN N'SINV' THEN 1 WHEN N'SRET' THEN -1 ELSE 0 END) x
    INNER JOIN masterdata.Branches b ON b.Id = d.BranchId
    WHERE d.Status = 2 AND x.Sign <> 0 AND d.DocumentDate BETWEEN @From AND @To
    GROUP BY b.Id, b.BranchName
    ORDER BY ISNULL(SUM(x.Sign * d.TotalAmountBase), 0) DESC, b.BranchName;

    /* 4 ---------------------------------------------------------------------------- cash / bank accounts */
    DECLARE @Cash TABLE (AccountId INT NULL, InBase DECIMAL(18,2) NOT NULL, InCount INT NOT NULL,
                         OutBase DECIMAL(18,2) NOT NULL, OutCount INT NOT NULL);
    INSERT INTO @Cash (AccountId, InBase, InCount, OutBase, OutCount)
    SELECT m.AccountId, SUM(m.InBase), SUM(m.InCount), SUM(m.OutBase), SUM(m.OutCount)
    FROM (
        SELECT AccountId = l.CashBankAccountId, InBase = l.AmountBase, InCount = 1, OutBase = CAST(0 AS DECIMAL(18,2)), OutCount = 0
        FROM sales.ReceiptLines l
        INNER JOIN sales.Receipts r ON r.Id = l.ReceiptId
        WHERE r.Status = 2 AND r.ReceiptDate BETWEEN @From AND @To
          AND (@BranchId IS NULL OR r.BranchId = @BranchId)
        UNION ALL
        SELECT l.CashBankAccountId, 0, 0, l.AmountBase, 1
        FROM purchase.PaymentLines l
        INNER JOIN purchase.Payments p ON p.Id = l.PaymentId
        WHERE p.Status = 2 AND p.PaymentDate BETWEEN @From AND @To
          AND (@BranchId IS NULL OR p.BranchId = @BranchId)
    ) m
    GROUP BY m.AccountId;

    SELECT x.AccountId, x.AccountCode, x.AccountName, x.AccountType, x.CurrencyCode, x.InBase, x.InCount, x.OutBase, x.OutCount
    FROM (
        SELECT AccountId = a.Id, a.AccountCode, a.AccountName, a.AccountType, CurrencyCode = cu.CurrencyCode,
               InBase = ISNULL(c.InBase, 0), InCount = ISNULL(c.InCount, 0),
               OutBase = ISNULL(c.OutBase, 0), OutCount = ISNULL(c.OutCount, 0)
        FROM masterdata.CashBankAccounts a
        LEFT JOIN masterdata.Currencies cu ON cu.Id = a.CurrencyId
        LEFT JOIN @Cash c ON c.AccountId = a.Id
        WHERE a.IsActive = 1 OR c.AccountId IS NOT NULL
        UNION ALL
        SELECT NULL, NULL, N'No account', NULL, NULL, c.InBase, c.InCount, c.OutBase, c.OutCount
        FROM @Cash c
        WHERE c.AccountId IS NULL
    ) x
    ORDER BY CASE WHEN x.AccountId IS NULL THEN 1 ELSE 0 END, x.AccountName;

    /* 5 and 6 ---------------------------------------------------------------------- transfers on the way */
    DECLARE @Way TABLE (PostingId INT NOT NULL PRIMARY KEY, Pieces INT NOT NULL);
    INSERT INTO @Way (PostingId, Pieces)
    SELECT p.Id, SUM(pl.QuantityBase - pl.SettledBase)
    FROM inventory.TransferPostings p
    INNER JOIN inventory.TransferPostingLines pl ON pl.PostingId = p.Id AND pl.QuantityBase > pl.SettledBase
    INNER JOIN masterdata.Warehouses wf ON wf.Id = p.FromWarehouseId
    INNER JOIN masterdata.Warehouses wt ON wt.Id = p.ToWarehouseId
    WHERE p.Kind = N'Dispatch' AND p.Status = 2
      AND (@BranchId IS NULL OR wf.BranchId = @BranchId OR wt.BranchId = @BranchId)
    GROUP BY p.Id;

    SELECT Dispatches = COUNT(*),
           Pieces     = ISNULL(SUM(w.Pieces), 0),
           Late       = ISNULL(SUM(CASE WHEN p.Eta < @Today THEN 1 END), 0)
    FROM @Way w
    INNER JOIN inventory.TransferPostings p ON p.Id = w.PostingId;

    SELECT TOP (10) PostingId = p.Id, p.TransferOrderId, DispatchNumber = p.DocumentNumber, OrderNumber = o.DocumentNumber,
           FromWarehouse = wf.WarehouseCode, ToWarehouse = wt.WarehouseCode,
           p.PostingDate, p.Eta, w.Pieces,
           IsLate = CAST(CASE WHEN p.Eta < @Today THEN 1 ELSE 0 END AS BIT)
    FROM @Way w
    INNER JOIN inventory.TransferPostings p ON p.Id = w.PostingId
    INNER JOIN inventory.TransferOrders o ON o.Id = p.TransferOrderId
    INNER JOIN masterdata.Warehouses wf ON wf.Id = p.FromWarehouseId
    INNER JOIN masterdata.Warehouses wt ON wt.Id = p.ToWarehouseId
    ORDER BY p.Eta, p.Id;

    /* 7 and 8 ---------------------------------------------------------------------- slow-moving stock */
    DECLARE @Since DATE = DATEADD(DAY, -@SlowDays, @Today);
    DECLARE @Slow TABLE (ItemId INT NOT NULL PRIMARY KEY, OnHand INT NOT NULL, ValueBase DECIMAL(18,2) NOT NULL, LastSale DATE NULL);
    INSERT INTO @Slow (ItemId, OnHand, ValueBase, LastSale)
    SELECT s.ItemId, s.OnHand, CONVERT(DECIMAL(18,2), s.OnHand * ISNULL(i.AverageCost, 0)), ls.LastSale
    FROM (SELECT m.ItemId, OnHand = SUM(m.QuantityBase),
                 FirstIn = MIN(CASE WHEN m.QuantityBase > 0 THEN CAST(m.MovementDate AS DATE) END)
          FROM inventory.StockMovements m
          INNER JOIN masterdata.Warehouses w ON w.Id = m.WarehouseId
          WHERE w.IsTransit = 0 AND (@BranchId IS NULL OR w.BranchId = @BranchId)
          GROUP BY m.ItemId) s
    INNER JOIN inventory.Items i ON i.Id = s.ItemId
    OUTER APPLY (SELECT LastSale = MAX(d.DocumentDate)
                 FROM sales.SalesDocumentLines l
                 INNER JOIN sales.SalesDocuments d ON d.Id = l.DocumentId AND d.Status = 2
                 INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId AND t.Code = N'SINV'
                 WHERE l.ItemId = s.ItemId
                   AND (@BranchId IS NULL OR d.BranchId = @BranchId)) ls
    WHERE s.OnHand > 0 AND i.IsActive = 1
      AND s.FirstIn <= @Since                                   -- in stock long enough to have sold
      AND (ls.LastSale IS NULL OR ls.LastSale < @Since);

    SELECT Items = COUNT(*), Pieces = ISNULL(SUM(s.OnHand), 0), ValueBase = ISNULL(SUM(s.ValueBase), 0), SlowDays = @SlowDays
    FROM @Slow s;

    WITH ranked AS (
        SELECT s.ItemId, i.ItemCode, i.ItemName, s.OnHand, s.ValueBase, s.LastSale,
               ByValue  = ROW_NUMBER() OVER (ORDER BY s.ValueBase DESC, i.ItemCode),
               ByPieces = ROW_NUMBER() OVER (ORDER BY s.OnHand DESC, i.ItemCode)
        FROM @Slow s
        INNER JOIN inventory.Items i ON i.Id = s.ItemId
    )
    SELECT r.ItemId, r.ItemCode, r.ItemName, r.OnHand, r.ValueBase, LastSaleDate = r.LastSale, r.ByValue, r.ByPieces
    FROM ranked r
    WHERE r.ByValue <= 10 OR r.ByPieces <= 10
    ORDER BY r.ByValue;

    /* 9, 10 and 11 ----------------------------------------------------------------- container charges missing */
    DECLARE @Received TABLE (ContainerId INT NOT NULL PRIMARY KEY, Posted INT NOT NULL, Drafts INT NOT NULL);
    INSERT INTO @Received (ContainerId, Posted, Drafts)
    SELECT c.Id,
           (SELECT COUNT(*) FROM logistics.ContainerCharges ch WHERE ch.ContainerId = c.Id AND ch.Status = 2),
           (SELECT COUNT(*) FROM logistics.ContainerCharges ch WHERE ch.ContainerId = c.Id AND ch.Status = 1)
    FROM logistics.Containers c
    WHERE c.Status IN (6, 7) AND c.OffloadedDate BETWEEN @From AND @To
      AND (@BranchId IS NULL OR c.BranchId = @BranchId);

    SELECT ReceivedContainers = COUNT(*),
           WithoutCharge      = ISNULL(SUM(CASE WHEN r.Posted = 0 THEN 1 END), 0),
           DraftOnly          = ISNULL(SUM(CASE WHEN r.Posted = 0 AND r.Drafts > 0 THEN 1 END), 0)
    FROM @Received r;

    WITH perContainer AS (   -- each received container and charge type once: posted, or in draft only
        SELECT ch.ContainerId, ch.ChargeTypeId, IsPosted = MAX(CASE WHEN ch.Status = 2 THEN 1 ELSE 0 END)
        FROM logistics.ContainerCharges ch
        INNER JOIN @Received r ON r.ContainerId = ch.ContainerId
        WHERE ch.Status IN (1, 2)
        GROUP BY ch.ContainerId, ch.ChargeTypeId
    )
    SELECT TOP (8) ct.Id AS ChargeTypeId, ct.ChargeName,
           EnteredContainers = SUM(pc.IsPosted),
           DraftContainers   = SUM(1 - pc.IsPosted),
           MissingContainers = (SELECT COUNT(*) FROM @Received) - COUNT(*)
    FROM perContainer pc
    INNER JOIN purchase.ChargeTypes ct ON ct.Id = pc.ChargeTypeId AND ct.IsDeduction = 0
    GROUP BY ct.Id, ct.ChargeName
    ORDER BY COUNT(*) DESC, ct.ChargeName;

    SELECT TOP (10) c.Id AS ContainerId, c.ContainerRef, c.ContainerNo, c.OffloadedDate, DraftCharges = r.Drafts
    FROM @Received r
    INNER JOIN logistics.Containers c ON c.Id = r.ContainerId
    WHERE r.Posted = 0
    ORDER BY c.OffloadedDate, c.Id;

    /* 12 --------------------------------------------------------------------------- lead time per supplier */
    DECLARE @LtFrom DATE = DATEADD(DAY, 1, DATEADD(MONTH, -12, @To));
    SELECT SupplierId = po.SupplierId, SupplierName = p.PartyName,
           Days     = CONVERT(DECIMAL(9,1), SUM(CAST(DATEDIFF(DAY, po.DocumentDate, g.DocumentDate) AS DECIMAL(18,2)) * l.QuantityBase) / SUM(l.QuantityBase)),
           Pieces   = SUM(l.QuantityBase),
           Receipts = COUNT(DISTINCT g.Id)
    FROM purchase.GoodsReceiptLines l
    INNER JOIN purchase.GoodsReceipts g          ON g.Id = l.GoodsReceiptId AND g.Status = 2
    INNER JOIN purchase.PurchaseDocumentLines pl ON pl.Id = l.PoLineId
    INNER JOIN purchase.PurchaseDocuments po     ON po.Id = pl.DocumentId
    INNER JOIN masterdata.Parties p              ON p.Id = po.SupplierId
    WHERE l.QuantityBase > 0
      AND g.DocumentDate BETWEEN @LtFrom AND @To
      AND po.DocumentDate <= g.DocumentDate
      AND (@BranchId IS NULL OR g.BranchId = @BranchId)
    GROUP BY po.SupplierId, p.PartyName
    ORDER BY SUM(l.QuantityBase) DESC, p.PartyName;
END

GO

