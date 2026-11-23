SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 117: REPORTING - THE DASHBOARD BY WAREHOUSE

   The owner asked for a Warehouse filter on the Dashboard, between the branch and the period. The five procedures the
   Dashboard reads take one more, optional parameter, @WarehouseId (last, default NULL: nothing changes for a caller
   that does not send it). A warehouse with warehouses under it takes them all (masterdata.fn_Warehouse_Subtree): a
   parent is a group, not a place. The branch filter still applies beside it.

   What "of the warehouse" means, one rule per kind of figure:
     a document (sales invoice / return, purchase order / invoice / return, Inventory In / Out, goods receipt)
                    counts, whole, when one of its lines is in the warehouse: its totals, what is still owed on it,
                    its draft. (A goods receipt also by its "Receive into".)
     a figure read line by line (top items, sales by family, an item's last sale, what order and invoice lines still
                    bring, the lead time's received pieces, out-of-stock sales)
                    counts only the lines in the warehouse.
     a container, and its charges
                    by the warehouse its goods are received into (logistics.Containers.WarehouseId); a container
                    without one yet is in no warehouse.
     stock          the warehouse's own: inventory value, items in stock, below zero, value by warehouse, slow stock,
                    warehouse levels below Min.
     a transfer     when it leaves from or goes to the warehouse.
   NOT narrowed, because they have no warehouse (they stay the branch's, or the company's):
     customer receipts and supplier payments - the cash / bank accounts, the cheques to clear, their drafts;
     "Items below their minimum" (the company's Minimum Quantity against the branch's or the company's stock, the
     figure Stock Levels' company view computes); the sales of every branch.

   Each procedure is re-created from its last body with that parameter, the list of warehouses (@Wh) and one more
   condition beside each branch condition; nothing else changes:
     reporting.usp_Dashboard_Summary      (from script 72)
     reporting.usp_Dashboard_Charts       (from script 68)
     reporting.usp_Dashboard_StockLevels  (from script 91)
     reporting.usp_Dashboard_Cards        (from script 115)
     reporting.usp_Dashboard_Insights     (from script 116)

   No table, column, permission or error number. Requires scripts 91, 115 and 116. Idempotent.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'reporting.usp_Dashboard_Insights', N'P') IS NULL
   OR OBJECT_ID(N'reporting.usp_Dashboard_Cards', N'P') IS NULL
   OR OBJECT_ID(N'reporting.usp_Dashboard_StockLevels', N'P') IS NULL
   OR OBJECT_ID(N'masterdata.fn_Warehouse_Subtree', N'TF') IS NULL
    THROW 50000, 'Script 117 requires scripts 91, 115 and 116: apply them first.', 1;
GO

/* ================================================================== 1. reporting.usp_Dashboard_Summary (from script 72) */

CREATE OR ALTER PROCEDURE reporting.usp_Dashboard_Summary
    @BranchId INT  = NULL,
    @From     DATE,
    @To       DATE,
    @PrevFrom DATE,
    @PrevTo   DATE,
    @Today    DATE = NULL,
    @WarehouseId INT = NULL   -- (117)
AS
BEGIN
    SET NOCOUNT ON;

    -- (117) THE WAREHOUSE CHOSEN, AND THE WAREHOUSES UNDER IT (a parent is a group, not a place). Empty: no warehouse filter.
    DECLARE @Wh TABLE (Id INT NOT NULL PRIMARY KEY);
    IF @WarehouseId IS NOT NULL
        INSERT INTO @Wh (Id) SELECT s.Id FROM masterdata.fn_Warehouse_Subtree(@WarehouseId) s;
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
      AND (@WarehouseId IS NULL OR EXISTS (SELECT 1 FROM sales.SalesDocumentLines wl INNER JOIN @Wh wh ON wh.Id = wl.WarehouseId WHERE wl.DocumentId = d.Id))
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
      AND (@BranchId IS NULL OR d.BranchId = @BranchId)
      AND (@WarehouseId IS NULL OR EXISTS (SELECT 1 FROM sales.SalesDocumentLines wl INNER JOIN @Wh wh ON wh.Id = wl.WarehouseId WHERE wl.DocumentId = d.Id));

    /* 3 ---------------------------------------------------------------------------- payables */
    SELECT InvoicesBase = (SELECT CONVERT(DECIMAL(18,2), ISNULL(SUM(s.OutstandingAmount / NULLIF(d.ExchangeRate, 0)), 0))
                           FROM purchase.PurchaseDocuments d
                           INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId AND t.Code = N'PINV'
                           CROSS APPLY purchase.fn_InvoiceSettlement(d.Id) s
                           WHERE d.Status = 2 AND s.OutstandingAmount > 0.005
                             AND (@BranchId IS NULL OR d.BranchId = @BranchId)
                             AND (@WarehouseId IS NULL OR EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines wl INNER JOIN @Wh wh ON wh.Id = wl.WarehouseId WHERE wl.DocumentId = d.Id))),
           InvoiceCount = (SELECT COUNT(*)
                           FROM purchase.PurchaseDocuments d
                           INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId AND t.Code = N'PINV'
                           CROSS APPLY purchase.fn_InvoiceSettlement(d.Id) s
                           WHERE d.Status = 2 AND s.OutstandingAmount > 0.005
                             AND (@BranchId IS NULL OR d.BranchId = @BranchId)
                             AND (@WarehouseId IS NULL OR EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines wl INNER JOIN @Wh wh ON wh.Id = wl.WarehouseId WHERE wl.DocumentId = d.Id))),
           ChargesBase  = (SELECT CONVERT(DECIMAL(18,2), ISNULL(SUM(s.OutstandingAmount / NULLIF(c.ExchangeRate, 0)), 0))
                           FROM logistics.ContainerCharges c
                           INNER JOIN logistics.Containers k ON k.Id = c.ContainerId
                           CROSS APPLY logistics.fn_ContainerChargeSettlement(c.Id) s
                           WHERE c.Status = 2 AND s.OutstandingAmount > 0.005
                             AND (@BranchId IS NULL OR k.BranchId = @BranchId)
                             AND (@WarehouseId IS NULL OR k.WarehouseId IN (SELECT Id FROM @Wh))),
           ChargeCount  = (SELECT COUNT(*)
                           FROM logistics.ContainerCharges c
                           INNER JOIN logistics.Containers k ON k.Id = c.ContainerId
                           CROSS APPLY logistics.fn_ContainerChargeSettlement(c.Id) s
                           WHERE c.Status = 2 AND s.OutstandingAmount > 0.005
                             AND (@BranchId IS NULL OR k.BranchId = @BranchId)
                             AND (@WarehouseId IS NULL OR k.WarehouseId IN (SELECT Id FROM @Wh)));

    /* the stock of every item in every warehouse of the branch, used by 4 and 7 */
    DECLARE @Stock TABLE (ItemId INT NOT NULL, WarehouseId INT NOT NULL, OnHand INT NOT NULL, PRIMARY KEY (ItemId, WarehouseId));
    INSERT INTO @Stock (ItemId, WarehouseId, OnHand)
    SELECT m.ItemId, m.WarehouseId, SUM(m.QuantityBase)
    FROM inventory.StockMovements m
    INNER JOIN masterdata.Warehouses w ON w.Id = m.WarehouseId
    WHERE (@BranchId IS NULL OR w.BranchId = @BranchId)
    GROUP BY m.ItemId, m.WarehouseId;

    /* 4 ---------------------------------------------------------------------------- inventory */
    SELECT ValueBase    = CONVERT(DECIMAL(18,2), ISNULL(SUM(CASE WHEN s.OnHand > 0 THEN s.OnHand * ISNULL(i.AverageCost, 0) END), 0)),
           ItemsInStock = COUNT(DISTINCT CASE WHEN s.OnHand > 0 THEN s.ItemId END)
    FROM @Stock s
    INNER JOIN inventory.Items i ON i.Id = s.ItemId
    WHERE @WarehouseId IS NULL OR s.WarehouseId IN (SELECT Id FROM @Wh);   -- (117)

    /* 5 ---------------------------------------------------------------------------- on the way */
    -- (72) STILL TO RECEIVE, THE GOODS RECEIPTS' WAY (script 65), in the three parts of the "Outstanding order" and
    --      "Transit" of Shortages (rule 25), each for the reader who may see where it comes from (the API trims them):
    --      OnOrderPieces    the order lines' OutstandingBase (ordered - received - settled short on an open order,
    --                       invoiced - received - short on a closed one; ReceivedQuantityBase is what was INVOICED, which
    --                       no longer brings goods in), less the pieces of the line travelling in containers that left
    --                       the supplier (In Transit, At Port, Cleared), which InTransitPieces counts: the two add up
    --                       without counting a piece twice. The orders only, like the item's "still to come".
    --      OutstandingPieces the same, the travelling pieces included: the "on order" the API shows instead to a reader
    --                       who may not see the containers, so those pieces do not drop out of sight with InTransitPieces.
    --      InvoicedNotReceivedPieces the posted invoices WITHOUT an order whose goods come with goods receipts, invoiced -
    --                       received (InvPending of fn_Shortage_Live): before the switch they were stock as soon as the
    --                       invoice was posted; now they wait for a goods receipt. Never in a container (an invoice
    --                       without an order cannot have one), so nothing to take off.
    --      OpenOrders       the orders with something still to receive; the invoices are not orders.
    --      The branch filter takes a document's branch, and a container's for the pieces it carries (where they will be
    --      received): over every branch each piece counts once.
    DECLARE @OnOrder TABLE (OrderId INT NOT NULL, Outstanding INT NOT NULL, Pieces INT NOT NULL);
    INSERT INTO @OnOrder (OrderId, Outstanding, Pieces)
    SELECT d.Id, p.OutstandingBase, CASE WHEN p.OutstandingBase > tr.Travelling THEN p.OutstandingBase - tr.Travelling ELSE 0 END
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId AND t.Code = N'PO'
    CROSS APPLY purchase.fn_PoLine_Progress(d.Id) p
    CROSS APPLY (SELECT Travelling = ISNULL((SELECT SUM(cl.QuantityBase - ISNULL(cl.ReceivedQuantityBase, 0))
                                             FROM logistics.ContainerLines cl
                                             INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                                             WHERE cl.PoLineId = p.PoLineId AND c.Status IN (3, 4, 5)), 0)) tr
    WHERE d.Status IN (2, 4) AND p.OutstandingBase > 0   -- a closed order still brings what was invoiced and not received
      AND (@BranchId IS NULL OR d.BranchId = @BranchId)
      AND (@WarehouseId IS NULL OR EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines wl INNER JOIN @Wh wh ON wh.Id = wl.WarehouseId WHERE wl.Id = p.PoLineId));

    SELECT OnOrderPieces = (SELECT ISNULL(SUM(o.Pieces), 0) FROM @OnOrder o),
           OpenOrders    = (SELECT COUNT(DISTINCT o.OrderId) FROM @OnOrder o),
           OutstandingPieces = (SELECT ISNULL(SUM(o.Outstanding), 0) FROM @OnOrder o),
           InvoicedNotReceivedPieces = (SELECT ISNULL(SUM(l.QuantityBase - l.ReceivedQuantityBase), 0)
                                        FROM purchase.PurchaseDocumentLines l
                                        INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
                                        INNER JOIN inventory.DocumentTypes t    ON t.Id = d.DocumentTypeId AND t.Code = N'PINV'
                                        WHERE d.Status IN (2, 4) AND d.UsesGoodsReceipts = 1 AND l.SourceLineId IS NULL
                                          AND l.QuantityBase > l.ReceivedQuantityBase
                                          AND (@BranchId IS NULL OR d.BranchId = @BranchId)
                                          AND (@WarehouseId IS NULL OR l.WarehouseId IN (SELECT Id FROM @Wh))),
           InTransitPieces = (SELECT ISNULL(SUM(cl.QuantityBase - ISNULL(cl.ReceivedQuantityBase, 0)), 0)
                            FROM logistics.ContainerLines cl
                            INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                            WHERE c.Status IN (3, 4, 5) AND cl.QuantityBase > ISNULL(cl.ReceivedQuantityBase, 0)
                              AND (@BranchId IS NULL OR c.BranchId = @BranchId)
                              AND (@WarehouseId IS NULL OR c.WarehouseId IN (SELECT Id FROM @Wh))),
           ContainersInTransit = (SELECT COUNT(*) FROM logistics.Containers c
                                  WHERE c.Status IN (3, 4, 5) AND (@BranchId IS NULL OR c.BranchId = @BranchId)
                                                              AND (@WarehouseId IS NULL OR c.WarehouseId IN (SELECT Id FROM @Wh)));

    /* 6 ---------------------------------------------------------------------------- drafts */
    SELECT x.Kind, x.TypeCode, x.DraftCount
    FROM (
        SELECT Kind = N'Sales', TypeCode = t.Code, DraftCount = COUNT(*)
        FROM sales.SalesDocuments d INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId
        WHERE d.Status = 1 AND (@BranchId IS NULL OR d.BranchId = @BranchId)
                           AND (@WarehouseId IS NULL OR EXISTS (SELECT 1 FROM sales.SalesDocumentLines wl INNER JOIN @Wh wh ON wh.Id = wl.WarehouseId WHERE wl.DocumentId = d.Id))
        GROUP BY t.Code
        UNION ALL
        SELECT N'Purchase', t.Code, COUNT(*)
        FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId
        WHERE d.Status = 1 AND (@BranchId IS NULL OR d.BranchId = @BranchId)
                           AND (@WarehouseId IS NULL OR EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines wl INNER JOIN @Wh wh ON wh.Id = wl.WarehouseId WHERE wl.DocumentId = d.Id))
        GROUP BY t.Code
        UNION ALL
        SELECT N'Inventory', t.Code, COUNT(*)
        FROM inventory.StockDocuments d INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId
        WHERE d.Status = 1 AND (@BranchId IS NULL OR d.BranchId = @BranchId)
                           AND (@WarehouseId IS NULL OR EXISTS (SELECT 1 FROM inventory.StockDocumentLines wl INNER JOIN @Wh wh ON wh.Id = wl.WarehouseId WHERE wl.DocumentId = d.Id))
        GROUP BY t.Code
        UNION ALL
        -- (72) goods receipts (script 64): a draft holds goods not in stock yet
        SELECT N'Purchase', N'GRN', COUNT(*) FROM purchase.GoodsReceipts g
        WHERE g.Status = 1 AND (@BranchId IS NULL OR g.BranchId = @BranchId)
                           AND (@WarehouseId IS NULL OR g.WarehouseId IN (SELECT Id FROM @Wh)
                                OR EXISTS (SELECT 1 FROM purchase.GoodsReceiptLines wl INNER JOIN @Wh wh ON wh.Id = wl.WarehouseId WHERE wl.GoodsReceiptId = g.Id))
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
           NegativeStock     = (SELECT COUNT(*) FROM @Stock s WHERE s.OnHand < 0
                                  AND (@WarehouseId IS NULL OR s.WarehouseId IN (SELECT Id FROM @Wh))),
           OutOfStockSales   = (SELECT COUNT(*) FROM sales.OutOfStockSaleAudit a
                                INNER JOIN sales.SalesDocuments d ON d.Id = a.SalesDocumentId
                                WHERE CAST(a.SoldAtUtc AS DATE) BETWEEN @From AND @To
                                  AND (@BranchId IS NULL OR d.BranchId = @BranchId)
                                  AND (@WarehouseId IS NULL OR a.WarehouseId IN (SELECT Id FROM @Wh)));

    /* 8 ---------------------------------------------------------------------------- below minimum */
    SELECT TOP (5) i.Id AS ItemId, i.ItemCode, i.ItemName, x.OnHand, i.MinQuantity, Missing = i.MinQuantity - x.OnHand
    FROM @Item x INNER JOIN inventory.Items i ON i.Id = x.ItemId
    WHERE x.OnHand < i.MinQuantity
    ORDER BY i.MinQuantity - x.OnHand DESC, i.ItemCode;

    /* 9 ---------------------------------------------------------------------------- containers */
    -- (72) THE FREE TIME STOPS AT THE DELIVERY (edge case 29), as on the container's own page: since goods receipts a
    --      delivered container stays Cleared until its receipt is posted, and the shipping line counts no demurrage once
    --      the box left the port. FreeOver = the last free day passed before the Delivery's end (else before today):
    --      demurrage really ran. FreeNear = not delivered yet, and the last free day is within the week.
    DECLARE @Soon DATE = DATEADD(DAY, 14, @Today), @FreeDayWarning DATE = DATEADD(DAY, 7, @Today);
    SELECT ArrivingSoon    = ISNULL(SUM(CASE WHEN c.Status IN (2, 3) AND c.Eta BETWEEN @Today AND @Soon THEN 1 END), 0),
           AtPort          = ISNULL(SUM(CASE WHEN c.Status = 4 THEN 1 END), 0),
           NearLastFreeDay = ISNULL(SUM(CASE WHEN f.FreeOver = 1 OR f.FreeNear = 1 THEN 1 END), 0)   -- near or past
    FROM logistics.Containers c
    OUTER APPLY logistics.fn_Container_LastDelivery(c.Id) dl
    CROSS APPLY (SELECT FreeOver = CASE WHEN c.Status IN (4, 5) AND c.LastFreeDay IS NOT NULL
                                             AND c.LastFreeDay < ISNULL(dl.EndDate, @Today) THEN 1 ELSE 0 END,
                        FreeNear = CASE WHEN c.Status IN (4, 5) AND c.LastFreeDay IS NOT NULL AND dl.MovementId IS NULL
                                             AND c.LastFreeDay BETWEEN @Today AND @FreeDayWarning THEN 1 ELSE 0 END) f
    WHERE (@BranchId IS NULL OR c.BranchId = @BranchId)
      AND (@WarehouseId IS NULL OR c.WarehouseId IN (SELECT Id FROM @Wh));

    /* 10 --------------------------------------------------------------------------- container list */
    -- (72) the free-time reasons with the flags of 9
    SELECT TOP (8) c.Id AS ContainerId, c.ContainerRef, c.ContainerNo, c.Status AS StatusCode, c.Eta, c.LastFreeDay,
           Reason = CASE WHEN f.FreeOver = 1 THEN N'PastLastFreeDay'
                         WHEN f.FreeNear = 1 THEN N'NearLastFreeDay'
                         WHEN c.Status = 4 THEN N'AtPort'
                         ELSE N'ArrivingSoon' END
    FROM logistics.Containers c
    OUTER APPLY logistics.fn_Container_LastDelivery(c.Id) dl
    CROSS APPLY (SELECT FreeOver = CASE WHEN c.Status IN (4, 5) AND c.LastFreeDay IS NOT NULL
                                             AND c.LastFreeDay < ISNULL(dl.EndDate, @Today) THEN 1 ELSE 0 END,
                        FreeNear = CASE WHEN c.Status IN (4, 5) AND c.LastFreeDay IS NOT NULL AND dl.MovementId IS NULL
                                             AND c.LastFreeDay BETWEEN @Today AND @FreeDayWarning THEN 1 ELSE 0 END) f
    WHERE (@BranchId IS NULL OR c.BranchId = @BranchId)
      AND (@WarehouseId IS NULL OR c.WarehouseId IN (SELECT Id FROM @Wh))
      AND ((c.Status IN (2, 3) AND c.Eta BETWEEN @Today AND @Soon)
        OR c.Status = 4
        OR f.FreeOver = 1 OR f.FreeNear = 1)
    ORDER BY CASE WHEN f.FreeOver = 1 OR f.FreeNear = 1 THEN c.LastFreeDay ELSE ISNULL(c.Eta, '9999-12-31') END, c.ContainerRef;

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
      AND (@WarehouseId IS NULL OR EXISTS (SELECT 1 FROM sales.SalesDocumentLines wl INNER JOIN @Wh wh ON wh.Id = wl.WarehouseId WHERE wl.DocumentId = d.Id))
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

/* ================================================================== 2. reporting.usp_Dashboard_Charts (from script 68) */

CREATE OR ALTER PROCEDURE reporting.usp_Dashboard_Charts
    @BranchId INT = NULL,
    @From     DATE,
    @To       DATE,
    @WarehouseId INT = NULL   -- (117)
AS
BEGIN
    SET NOCOUNT ON;

    -- (117) THE WAREHOUSE CHOSEN, AND THE WAREHOUSES UNDER IT (a parent is a group, not a place). Empty: no warehouse filter.
    DECLARE @Wh TABLE (Id INT NOT NULL PRIMARY KEY);
    IF @WarehouseId IS NOT NULL
        INSERT INTO @Wh (Id) SELECT s.Id FROM masterdata.fn_Warehouse_Subtree(@WarehouseId) s;
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
          AND (@WarehouseId IS NULL OR EXISTS (SELECT 1 FROM sales.SalesDocumentLines wl INNER JOIN @Wh wh ON wh.Id = wl.WarehouseId WHERE wl.DocumentId = d.Id))
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
          AND (@WarehouseId IS NULL OR EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines wl INNER JOIN @Wh wh ON wh.Id = wl.WarehouseId WHERE wl.DocumentId = d.Id))
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
          AND (@WarehouseId IS NULL OR l.WarehouseId IN (SELECT Id FROM @Wh))
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
                           AND (@WarehouseId IS NULL OR w.Id IN (SELECT Id FROM @Wh))
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
          AND (@WarehouseId IS NULL OR EXISTS (SELECT 1 FROM sales.SalesDocumentLines wl INNER JOIN @Wh wh ON wh.Id = wl.WarehouseId WHERE wl.DocumentId = d.Id))
    LEFT JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId AND t.Code IN (N'SINV', N'SRET')
    GROUP BY dd.DayNo
    ORDER BY dd.DayNo;
END
GO

/* ================================================================== 3. reporting.usp_Dashboard_StockLevels (from script 91) */

CREATE OR ALTER PROCEDURE reporting.usp_Dashboard_StockLevels
    @BranchId INT = NULL,
    @WarehouseId INT = NULL   -- (117)
AS
BEGIN
    SET NOCOUNT ON;

    -- (117) THE WAREHOUSE CHOSEN, AND THE WAREHOUSES UNDER IT (a parent is a group, not a place). Empty: no warehouse filter.
    DECLARE @Wh TABLE (Id INT NOT NULL PRIMARY KEY);
    IF @WarehouseId IS NOT NULL
        INSERT INTO @Wh (Id) SELECT s.Id FROM masterdata.fn_Warehouse_Subtree(@WarehouseId) s;

    -- The levels counted: active items at active warehouses of the branch (or the company)
    CREATE TABLE #lv (ItemId INT NOT NULL, WarehouseId INT NOT NULL, MinQuantityBase INT NOT NULL, MaxQuantityBase INT NULL,
                      PRIMARY KEY (ItemId, WarehouseId));
    INSERT INTO #lv (ItemId, WarehouseId, MinQuantityBase, MaxQuantityBase)
    SELECT lv.ItemId, lv.WarehouseId, lv.MinQuantityBase, lv.MaxQuantityBase
    FROM inventory.ItemWarehouseLevels lv
    INNER JOIN inventory.Items i       ON i.Id = lv.ItemId AND i.IsActive = 1
    INNER JOIN masterdata.Warehouses w ON w.Id = lv.WarehouseId AND w.IsActive = 1
    WHERE (@BranchId IS NULL OR w.BranchId = @BranchId)
      AND (@WarehouseId IS NULL OR lv.WarehouseId IN (SELECT Id FROM @Wh));

    -- What released transfer orders bring and take, every pair at once (fn_TransferPositions, as Stock Levels reads it)
    CREATE TABLE #tp (ItemId INT NOT NULL, WarehouseId INT NOT NULL, InOnTheWayBase INT NOT NULL, InToDispatchBase INT NOT NULL,
                      OutToDispatchBase INT NOT NULL, PRIMARY KEY (ItemId, WarehouseId));
    INSERT INTO #tp (ItemId, WarehouseId, InOnTheWayBase, InToDispatchBase, OutToDispatchBase)
    SELECT tp.ItemId, tp.WarehouseId, tp.InOnTheWayBase, tp.InToDispatchBase, tp.OutToDispatchBase
    FROM inventory.fn_TransferPositions(NULL) tp
    WHERE EXISTS (SELECT 1 FROM #lv lv WHERE lv.ItemId = tp.ItemId AND lv.WarehouseId = tp.WarehouseId);

    SELECT BelowWarehouseMin = COUNT(*)
    FROM #lv lv
    LEFT JOIN #tp tp ON tp.ItemId = lv.ItemId AND tp.WarehouseId = lv.WarehouseId
    LEFT JOIN (SELECT m.ItemId, m.WarehouseId, Qty = SUM(m.QuantityBase)
               FROM inventory.StockMovements m
               INNER JOIN #lv x ON x.ItemId = m.ItemId AND x.WarehouseId = m.WarehouseId
               GROUP BY m.ItemId, m.WarehouseId) oh ON oh.ItemId = lv.ItemId AND oh.WarehouseId = lv.WarehouseId
    CROSS APPLY inventory.fn_StockLevelState(ISNULL(oh.Qty, 0), ISNULL(tp.InOnTheWayBase, 0), ISNULL(tp.InToDispatchBase, 0),
                                             ISNULL(tp.OutToDispatchBase, 0), lv.MinQuantityBase, lv.MaxQuantityBase) st
    WHERE st.Status = N'BelowMin';
END
GO

/* ================================================================== 4. reporting.usp_Dashboard_Cards (from script 115) */

CREATE OR ALTER PROCEDURE reporting.usp_Dashboard_Cards
    @BranchId INT  = NULL,
    @From     DATE,
    @To       DATE,
    @Today    DATE = NULL,
    @WarehouseId INT = NULL   -- (117)
AS
BEGIN
    SET NOCOUNT ON;

    -- (117) THE WAREHOUSE CHOSEN, AND THE WAREHOUSES UNDER IT (a parent is a group, not a place). Empty: no warehouse filter.
    DECLARE @Wh TABLE (Id INT NOT NULL PRIMARY KEY);
    IF @WarehouseId IS NOT NULL
        INSERT INTO @Wh (Id) SELECT s.Id FROM masterdata.fn_Warehouse_Subtree(@WarehouseId) s;
    IF @Today IS NULL SET @Today = CAST(SYSUTCDATETIME() AS DATE);

    /* 1 ---------------------------------------------------------------------------- stages */
    -- Each container once: where it stands, its pieces, and which of the three counts it falls in.
    DECLARE @Stand TABLE (ContainerId INT NOT NULL PRIMARY KEY, GroupKey INT NOT NULL, StageName NVARCHAR(100) NOT NULL,
                          Pieces INT NOT NULL, Bucket TINYINT NOT NULL);   -- Bucket: 1 open, 2 to receive, 3 received in the period
    INSERT INTO @Stand (ContainerId, GroupKey, StageName, Pieces, Bucket)
    SELECT c.Id,
           -- the Containers list's Stage filter; -2: received without an Offload stage (no filter)
           GroupKey = CASE WHEN st.StageId IS NOT NULL THEN st.StageId
                           WHEN st.StageKind = 0 THEN 0
                           WHEN st.FitsStages = 0 THEN -1
                           ELSE -2 END,
           StageName = CASE WHEN st.StageId IS NULL AND st.StageKind = 0 THEN N'Pending' ELSE st.StageName END,
           Pieces = ISNULL(p.Pieces, 0),
           Bucket = CASE WHEN c.Status IN (6, 7) THEN 3 WHEN st.ReceiptPending = 1 THEN 2 ELSE 1 END
    FROM logistics.Containers c
    CROSS APPLY logistics.fn_Container_Stage(c.Id) st
    OUTER APPLY (SELECT Pieces = SUM(cl.QuantityBase) FROM logistics.ContainerLines cl WHERE cl.ContainerId = c.Id) p
    WHERE (@BranchId IS NULL OR c.BranchId = @BranchId)
      AND (@WarehouseId IS NULL OR c.WarehouseId IN (SELECT Id FROM @Wh))
      AND (c.Status BETWEEN 1 AND 5 OR (c.Status IN (6, 7) AND c.OffloadedDate BETWEEN @From AND @To));

    -- The groups: Pending first, every active stage (and an inactive one a container still stands on) in its order,
    -- then the containers no stage describes and those received without an Offload stage, when there are some.
    WITH groups AS (
        SELECT GroupKey = 0, StageName = N'Pending', StageKind = CAST(0 AS TINYINT), SortKey = -1
        UNION ALL
        SELECT s.Id, s.StageName, s.Kind, s.SortOrder
        FROM logistics.ShipmentStages s
        WHERE s.IsActive = 1 OR s.Id IN (SELECT GroupKey FROM @Stand)
        UNION ALL
        SELECT -1, N'Not on a stage', NULL, 2147483646 WHERE EXISTS (SELECT 1 FROM @Stand WHERE GroupKey = -1)
        UNION ALL
        SELECT -2, N'Offloaded', CAST(3 AS TINYINT), 2147483645 WHERE EXISTS (SELECT 1 FROM @Stand WHERE GroupKey = -2)
    )
    SELECT FilterId = CASE WHEN g.GroupKey = -2 THEN NULL ELSE g.GroupKey END,
           g.StageName, g.StageKind,
           OpenContainers      = COUNT(CASE WHEN s.Bucket = 1 THEN 1 END),
           OpenPieces          = ISNULL(SUM(CASE WHEN s.Bucket = 1 THEN s.Pieces END), 0),
           ToReceiveContainers = COUNT(CASE WHEN s.Bucket = 2 THEN 1 END),
           ToReceivePieces     = ISNULL(SUM(CASE WHEN s.Bucket = 2 THEN s.Pieces END), 0),
           ReceivedContainers  = COUNT(CASE WHEN s.Bucket = 3 THEN 1 END),
           ReceivedPieces      = ISNULL(SUM(CASE WHEN s.Bucket = 3 THEN s.Pieces END), 0)
    FROM groups g
    LEFT JOIN @Stand s ON s.GroupKey = g.GroupKey
    GROUP BY g.GroupKey, g.StageName, g.StageKind, g.SortKey
    ORDER BY g.SortKey, g.GroupKey;

    /* 2 and 3 ---------------------------------------------------------------------- payables, creditors */
    DECLARE @Owed TABLE (Kind CHAR(1) NOT NULL,          -- I supplier invoice, C container charge
                         PartyId INT NULL, OutstandingBase DECIMAL(18,2) NOT NULL, PaymentStatus NVARCHAR(10) NOT NULL);
    INSERT INTO @Owed (Kind, PartyId, OutstandingBase, PaymentStatus)
    SELECT 'I', d.SupplierId, CONVERT(DECIMAL(18,2), s.OutstandingAmount / NULLIF(d.ExchangeRate, 0)), s.PaymentStatus
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId AND t.Code = N'PINV'
    CROSS APPLY purchase.fn_InvoiceSettlement(d.Id) s
    WHERE d.Status = 2 AND s.OutstandingAmount > 0.005
      AND (@BranchId IS NULL OR d.BranchId = @BranchId)
      AND (@WarehouseId IS NULL OR EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines wl INNER JOIN @Wh wh ON wh.Id = wl.WarehouseId WHERE wl.DocumentId = d.Id));

    INSERT INTO @Owed (Kind, PartyId, OutstandingBase, PaymentStatus)
    SELECT 'C', c.ProviderPartyId, CONVERT(DECIMAL(18,2), s.OutstandingAmount / NULLIF(c.ExchangeRate, 0)), s.PaymentStatus
    FROM logistics.ContainerCharges c
    INNER JOIN logistics.Containers k ON k.Id = c.ContainerId
    CROSS APPLY logistics.fn_ContainerChargeSettlement(c.Id) s
    WHERE c.Status = 2 AND s.OutstandingAmount > 0.005
      AND (@BranchId IS NULL OR k.BranchId = @BranchId)
      AND (@WarehouseId IS NULL OR k.WarehouseId IN (SELECT Id FROM @Wh));

    SELECT UnpaidInvoiceCount   = COUNT(CASE WHEN o.Kind = 'I' AND o.PaymentStatus = N'Unpaid' THEN 1 END),
           UnpaidInvoicesBase   = ISNULL(SUM(CASE WHEN o.Kind = 'I' AND o.PaymentStatus = N'Unpaid' THEN o.OutstandingBase END), 0),
           PartialInvoiceCount  = COUNT(CASE WHEN o.Kind = 'I' AND o.PaymentStatus = N'Partial' THEN 1 END),
           PartialInvoicesBase  = ISNULL(SUM(CASE WHEN o.Kind = 'I' AND o.PaymentStatus = N'Partial' THEN o.OutstandingBase END), 0),
           UnpaidChargeCount    = COUNT(CASE WHEN o.Kind = 'C' AND o.PaymentStatus = N'Unpaid' THEN 1 END),
           UnpaidChargesBase    = ISNULL(SUM(CASE WHEN o.Kind = 'C' AND o.PaymentStatus = N'Unpaid' THEN o.OutstandingBase END), 0),
           PartialChargeCount   = COUNT(CASE WHEN o.Kind = 'C' AND o.PaymentStatus = N'Partial' THEN 1 END),
           PartialChargesBase   = ISNULL(SUM(CASE WHEN o.Kind = 'C' AND o.PaymentStatus = N'Partial' THEN o.OutstandingBase END), 0)
    FROM @Owed o;

    SELECT PartyId = o.PartyId,
           PartyName = ISNULL(p.PartyName, N'No provider'),
           InvoicesBase = ISNULL(SUM(CASE WHEN o.Kind = 'I' THEN o.OutstandingBase END), 0),
           InvoiceCount = COUNT(CASE WHEN o.Kind = 'I' THEN 1 END),
           ChargesBase  = ISNULL(SUM(CASE WHEN o.Kind = 'C' THEN o.OutstandingBase END), 0),
           ChargeCount  = COUNT(CASE WHEN o.Kind = 'C' THEN 1 END)
    FROM @Owed o
    LEFT JOIN masterdata.Parties p ON p.Id = o.PartyId
    GROUP BY o.PartyId, p.PartyName
    ORDER BY SUM(o.OutstandingBase) DESC, ISNULL(p.PartyName, N'No provider');

    /* 4 and 5 ---------------------------------------------------------------------- aging, debtors */
    DECLARE @Due TABLE (ClientId INT NOT NULL, DueDate DATE NULL, DaysLate INT NOT NULL, OutstandingBase DECIMAL(18,2) NOT NULL);
    INSERT INTO @Due (ClientId, DueDate, DaysLate, OutstandingBase)
    SELECT d.ClientId, d.DueDate,
           DaysLate = CASE WHEN d.DueDate < @Today THEN DATEDIFF(DAY, d.DueDate, @Today) ELSE 0 END,
           CONVERT(DECIMAL(18,2), s.OutstandingAmount / NULLIF(d.ExchangeRate, 0))
    FROM sales.SalesDocuments d
    INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId AND t.Code = N'SINV'
    CROSS APPLY sales.fn_InvoiceSettlement(d.Id) s
    WHERE d.Status = 2 AND s.OutstandingAmount > 0.005
      AND (@BranchId IS NULL OR d.BranchId = @BranchId)
      AND (@WarehouseId IS NULL OR EXISTS (SELECT 1 FROM sales.SalesDocumentLines wl INNER JOIN @Wh wh ON wh.Id = wl.WarehouseId WHERE wl.DocumentId = d.Id));

    SELECT NotDueCount   = COUNT(CASE WHEN x.DaysLate = 0 THEN 1 END),
           NotDueBase    = ISNULL(SUM(CASE WHEN x.DaysLate = 0 THEN x.OutstandingBase END), 0),
           Days1To30Count  = COUNT(CASE WHEN x.DaysLate BETWEEN 1 AND 30 THEN 1 END),
           Days1To30Base   = ISNULL(SUM(CASE WHEN x.DaysLate BETWEEN 1 AND 30 THEN x.OutstandingBase END), 0),
           Days31To60Count = COUNT(CASE WHEN x.DaysLate BETWEEN 31 AND 60 THEN 1 END),
           Days31To60Base  = ISNULL(SUM(CASE WHEN x.DaysLate BETWEEN 31 AND 60 THEN x.OutstandingBase END), 0),
           Days61To90Count = COUNT(CASE WHEN x.DaysLate BETWEEN 61 AND 90 THEN 1 END),
           Days61To90Base  = ISNULL(SUM(CASE WHEN x.DaysLate BETWEEN 61 AND 90 THEN x.OutstandingBase END), 0),
           Over90Count   = COUNT(CASE WHEN x.DaysLate > 90 THEN 1 END),
           Over90Base    = ISNULL(SUM(CASE WHEN x.DaysLate > 90 THEN x.OutstandingBase END), 0),
           DebtorCount   = COUNT(DISTINCT x.ClientId)
    FROM @Due x;

    SELECT TOP (5) x.ClientId, ClientName = p.PartyName,
           OutstandingBase = SUM(x.OutstandingBase),
           OverdueBase     = ISNULL(SUM(CASE WHEN x.DaysLate > 0 THEN x.OutstandingBase END), 0),
           InvoiceCount    = COUNT(*),
           OldestDueDate   = MIN(CASE WHEN x.DaysLate > 0 THEN x.DueDate END)
    FROM @Due x
    INNER JOIN masterdata.Parties p ON p.Id = x.ClientId
    GROUP BY x.ClientId, p.PartyName
    ORDER BY SUM(x.OutstandingBase) DESC, p.PartyName;

    /* 6 ---------------------------------------------------------------------------- purchases by month */
    DECLARE @LastMonth DATE = DATEFROMPARTS(YEAR(@To), MONTH(@To), 1);
    DECLARE @FirstMonth DATE = DATEADD(MONTH, -11, @LastMonth);
    DECLARE @End DATE = DATEADD(MONTH, 1, @LastMonth);

    WITH months AS (
        SELECT n = 0, MonthStart = @FirstMonth
        UNION ALL SELECT n + 1, DATEADD(MONTH, 1, MonthStart) FROM months WHERE n < 11
    ),
    invoiced AS (   -- the trend's "Purchases" (script 68): supplier invoices less returns
        SELECT MonthStart = DATEFROMPARTS(YEAR(d.DocumentDate), MONTH(d.DocumentDate), 1),
               Amount = SUM(x.Sign * d.TotalAmountBase)
        FROM purchase.PurchaseDocuments d
        INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId
        CROSS APPLY (SELECT Sign = CASE t.Code WHEN N'PINV' THEN 1 WHEN N'PRET' THEN -1 ELSE 0 END) x
        WHERE d.Status IN (2, 4) AND x.Sign <> 0 AND d.DocumentDate >= @FirstMonth AND d.DocumentDate < @End
          AND (@BranchId IS NULL OR d.BranchId = @BranchId)
          AND (@WarehouseId IS NULL OR EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines wl INNER JOIN @Wh wh ON wh.Id = wl.WarehouseId WHERE wl.DocumentId = d.Id))
        GROUP BY DATEFROMPARTS(YEAR(d.DocumentDate), MONTH(d.DocumentDate), 1)
    ),
    received AS (   -- posted goods receipts, at the value fixed when they were posted
        SELECT MonthStart = DATEFROMPARTS(YEAR(g.DocumentDate), MONTH(g.DocumentDate), 1),
               Amount = SUM(g.ValueAtReceiptBase), Pieces = SUM(g.TotalReceivedBase)
        FROM purchase.GoodsReceipts g
        WHERE g.Status = 2 AND g.DocumentDate >= @FirstMonth AND g.DocumentDate < @End
          AND (@BranchId IS NULL OR g.BranchId = @BranchId)
          AND (@WarehouseId IS NULL OR g.WarehouseId IN (SELECT Id FROM @Wh)
               OR EXISTS (SELECT 1 FROM purchase.GoodsReceiptLines wl INNER JOIN @Wh wh ON wh.Id = wl.WarehouseId WHERE wl.GoodsReceiptId = g.Id))
        GROUP BY DATEFROMPARTS(YEAR(g.DocumentDate), MONTH(g.DocumentDate), 1)
    ),
    charges AS (    -- container charges posted (a deduction is stored negative, script 102: it takes off)
        SELECT MonthStart = DATEFROMPARTS(YEAR(c.ChargeDate), MONTH(c.ChargeDate), 1),
               Amount = SUM(c.AmountBase)
        FROM logistics.ContainerCharges c
        INNER JOIN logistics.Containers k ON k.Id = c.ContainerId
        WHERE c.Status = 2 AND c.ChargeDate >= @FirstMonth AND c.ChargeDate < @End
          AND (@BranchId IS NULL OR k.BranchId = @BranchId)
          AND (@WarehouseId IS NULL OR k.WarehouseId IN (SELECT Id FROM @Wh))
        GROUP BY DATEFROMPARTS(YEAR(c.ChargeDate), MONTH(c.ChargeDate), 1)
    )
    SELECT m.MonthStart,
           InvoicedBase   = CONVERT(DECIMAL(18,2), ISNULL(i.Amount, 0)),
           ReceivedBase   = CONVERT(DECIMAL(18,2), ISNULL(r.Amount, 0)),
           ReceivedPieces = ISNULL(r.Pieces, 0),
           ChargesBase    = CONVERT(DECIMAL(18,2), ISNULL(c.Amount, 0))
    FROM months m
    LEFT JOIN invoiced i ON i.MonthStart = m.MonthStart
    LEFT JOIN received r ON r.MonthStart = m.MonthStart
    LEFT JOIN charges  c ON c.MonthStart = m.MonthStart
    ORDER BY m.MonthStart;
END
GO

/* ================================================================== 5. reporting.usp_Dashboard_Insights (from script 116) */

CREATE OR ALTER PROCEDURE reporting.usp_Dashboard_Insights
    @BranchId INT  = NULL,
    @From     DATE,
    @To       DATE,
    @Today    DATE = NULL,
    @WarehouseId INT = NULL   -- (117)
AS
BEGIN
    SET NOCOUNT ON;

    -- (117) THE WAREHOUSE CHOSEN, AND THE WAREHOUSES UNDER IT (a parent is a group, not a place). Empty: no warehouse filter.
    DECLARE @Wh TABLE (Id INT NOT NULL PRIMARY KEY);
    IF @WarehouseId IS NOT NULL
        INSERT INTO @Wh (Id) SELECT s.Id FROM masterdata.fn_Warehouse_Subtree(@WarehouseId) s;
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
      AND (@WarehouseId IS NULL OR l.WarehouseId IN (SELECT Id FROM @Wh))
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
          AND (@WarehouseId IS NULL OR EXISTS (SELECT 1 FROM sales.SalesDocumentLines wl INNER JOIN @Wh wh ON wh.Id = wl.WarehouseId WHERE wl.DocumentId = d.Id))
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
                   AND (@BranchId IS NULL OR d.BranchId = @BranchId)
                   AND (@WarehouseId IS NULL OR EXISTS (SELECT 1 FROM sales.SalesDocumentLines wl INNER JOIN @Wh wh ON wh.Id = wl.WarehouseId WHERE wl.DocumentId = d.Id))) o
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
      AND (@WarehouseId IS NULL OR p.FromWarehouseId IN (SELECT Id FROM @Wh) OR p.ToWarehouseId IN (SELECT Id FROM @Wh))
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
                                AND (@WarehouseId IS NULL OR m.WarehouseId IN (SELECT Id FROM @Wh))
          GROUP BY m.ItemId) s
    INNER JOIN inventory.Items i ON i.Id = s.ItemId
    OUTER APPLY (SELECT LastSale = MAX(d.DocumentDate)
                 FROM sales.SalesDocumentLines l
                 INNER JOIN sales.SalesDocuments d ON d.Id = l.DocumentId AND d.Status = 2
                 INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId AND t.Code = N'SINV'
                 WHERE l.ItemId = s.ItemId
                   AND (@BranchId IS NULL OR d.BranchId = @BranchId)
                   AND (@WarehouseId IS NULL OR l.WarehouseId IN (SELECT Id FROM @Wh))) ls
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
      AND (@BranchId IS NULL OR c.BranchId = @BranchId)
      AND (@WarehouseId IS NULL OR c.WarehouseId IN (SELECT Id FROM @Wh));

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
      AND (@WarehouseId IS NULL OR ISNULL(l.WarehouseId, g.WarehouseId) IN (SELECT Id FROM @Wh))
    GROUP BY po.SupplierId, p.PartyName
    ORDER BY SUM(l.QuantityBase) DESC, p.PartyName;
END
GO

/* ================================================================== 6. Check */

-- Each of the five procedures takes @WarehouseId (they are not run here: the Dashboard's figures are no work for a
-- start-up). By hand: EXEC reporting.usp_Dashboard_Summary @From = '2026-11-01', @To = '2026-11-23',
-- @PrevFrom = '2026-10-01', @PrevTo = '2026-10-23', @WarehouseId = 1;
SELECT o.ObjectName,
       HasWarehouseId = CASE WHEN EXISTS (SELECT 1 FROM sys.parameters p
                                          WHERE p.object_id = OBJECT_ID(o.ObjectName) AND p.name = N'@WarehouseId') THEN N'yes' ELSE N'MISSING' END
FROM (VALUES (N'reporting.usp_Dashboard_Summary'), (N'reporting.usp_Dashboard_Charts'), (N'reporting.usp_Dashboard_StockLevels'),
             (N'reporting.usp_Dashboard_Cards'), (N'reporting.usp_Dashboard_Insights')) o (ObjectName);

PRINT 'Script 117 applied: the Dashboard''s five procedures take @WarehouseId (a parent takes the warehouses under it).';
GO
