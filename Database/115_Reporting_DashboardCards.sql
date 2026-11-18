SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 115: REPORTING - THE DASHBOARD'S NEW CARDS

   The owner asked for four more parts on the Dashboard: where the containers are (by shipment stage), what we owe
   (supplier invoices and container charges, by payment status and by creditor), what customers owe (by age, and the
   largest debtors), and the purchases of each month. The summary and the charts of script 68 already had one figure
   for each of the money parts ("Customers owe", "We owe") and a "Purchases" line; this script gives the detail.

     reporting.usp_Dashboard_Cards   @BranchId, @From, @To, @Today              (NEW, six result sets)
       1  stages        one row per shipment stage (script 111): the containers standing there and their pieces.
                        Open containers (Draft to Cleared) stand where logistics.fn_Container_Stage puts them;
                        those delivered and waiting for their goods receipt (ReceiptPending) are counted apart on
                        their Offload stage, and so are the containers RECEIVED IN THE PERIOD (by their offload date)
                        - received containers of other periods are not on the Dashboard. FilterId is the Containers
                        list's Stage filter (script 111): a stage's Id, 0 Pending (never moved, or followed by typed
                        dates), -1 not on a stage; NULL for containers received without an Offload stage (no
                        filter names them). Every active stage is listed, even at 0, so the pipeline keeps its shape.
       2  payables      posted supplier invoices and posted container charges still owed, Unpaid and Partly paid
                        (purchase.fn_InvoiceSettlement, logistics.fn_ContainerChargeSettlement): count and the amount
                        outstanding. A cash charge (script 113) is paid when it is posted, so what is owed on charges
                        is what was taken on account. A deduction is never owed.
       3  creditors     the same, one row per supplier or charge provider (a charge without one: PartyId NULL); the
                        API removes the half a reader may not see and keeps the five owed the most.
       4  aging         posted sales invoices still owed, by how late they are on @Today: not due yet (or no due date),
                        1-30, 31-60, 61-90 and over 90 days; and the number of customers who owe.
       5  debtors       the five customers owing the most, with the overdue part and the oldest due date.
       6  purchases     the twelve months to @To's month (the trend's months, script 68): supplier invoices less
                        returns (the trend's "Purchases"), goods received (posted goods receipts at their value at
                        receipt, and their pieces) and container charges posted (deductions take off).

   Money is in the base currency (each document's own amount divided by its own rate, as script 68). The branch is
   the document's, a container's for its charges and its stage. The API decides which of these a reader may see
   (the screens they come from); this procedure only computes them.

   No table, column, permission or error number. Requires scripts 68, 102, 111 and 113. Idempotent.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'logistics.fn_Container_Stage') IS NULL
   OR COL_LENGTH(N'logistics.ContainerCharges', N'PaymentType') IS NULL
   OR OBJECT_ID(N'reporting.usp_Dashboard_Summary', N'P') IS NULL
    THROW 50000, 'Script 115 requires scripts 68, 111 and 113: apply them first.', 1;
GO

/* ================================================================== 1. reporting.usp_Dashboard_Cards */

CREATE OR ALTER PROCEDURE reporting.usp_Dashboard_Cards
    @BranchId INT  = NULL,
    @From     DATE,
    @To       DATE,
    @Today    DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
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
      AND (@BranchId IS NULL OR d.BranchId = @BranchId);

    INSERT INTO @Owed (Kind, PartyId, OutstandingBase, PaymentStatus)
    SELECT 'C', c.ProviderPartyId, CONVERT(DECIMAL(18,2), s.OutstandingAmount / NULLIF(c.ExchangeRate, 0)), s.PaymentStatus
    FROM logistics.ContainerCharges c
    INNER JOIN logistics.Containers k ON k.Id = c.ContainerId
    CROSS APPLY logistics.fn_ContainerChargeSettlement(c.Id) s
    WHERE c.Status = 2 AND s.OutstandingAmount > 0.005
      AND (@BranchId IS NULL OR k.BranchId = @BranchId);

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
      AND (@BranchId IS NULL OR d.BranchId = @BranchId);

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
        GROUP BY DATEFROMPARTS(YEAR(d.DocumentDate), MONTH(d.DocumentDate), 1)
    ),
    received AS (   -- posted goods receipts, at the value fixed when they were posted
        SELECT MonthStart = DATEFROMPARTS(YEAR(g.DocumentDate), MONTH(g.DocumentDate), 1),
               Amount = SUM(g.ValueAtReceiptBase), Pieces = SUM(g.TotalReceivedBase)
        FROM purchase.GoodsReceipts g
        WHERE g.Status = 2 AND g.DocumentDate >= @FirstMonth AND g.DocumentDate < @End
          AND (@BranchId IS NULL OR g.BranchId = @BranchId)
        GROUP BY DATEFROMPARTS(YEAR(g.DocumentDate), MONTH(g.DocumentDate), 1)
    ),
    charges AS (    -- container charges posted (a deduction is stored negative, script 102: it takes off)
        SELECT MonthStart = DATEFROMPARTS(YEAR(c.ChargeDate), MONTH(c.ChargeDate), 1),
               Amount = SUM(c.AmountBase)
        FROM logistics.ContainerCharges c
        INNER JOIN logistics.Containers k ON k.Id = c.ContainerId
        WHERE c.Status = 2 AND c.ChargeDate >= @FirstMonth AND c.ChargeDate < @End
          AND (@BranchId IS NULL OR k.BranchId = @BranchId)
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

/* ================================================================== 2. Check */

-- The procedure is there (it is not run here: Schema.sql applies this script at every start, and the Dashboard's
-- figures are no work for a start-up). By hand: EXEC reporting.usp_Dashboard_Cards @From = '2026-11-01', @To = '2026-11-18';
-- six result sets - on an empty database the Pending row and the stages at 0, zeros, and twelve months.
SELECT ObjectName = N'reporting.usp_Dashboard_Cards',
       ObjectType = ISNULL((SELECT type_desc FROM sys.objects WHERE object_id = OBJECT_ID(N'reporting.usp_Dashboard_Cards')), N'MISSING');

PRINT 'Script 115 applied: reporting.usp_Dashboard_Cards (containers by stage, payables, receivables by age, purchases by month).';
GO
