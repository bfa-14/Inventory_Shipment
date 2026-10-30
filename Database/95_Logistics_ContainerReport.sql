SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 95: LOGISTICS - THE CONTAINER REPORT (prompt 52)

   Reports › Container Report: every container line and every approved order line still to load, with its order, PI,
   invoices, payments, journey, charges and cost, grouped by where the goods are now - the purchasing team's tracking
   sheet ("ORDER PENDING - NOVEMBER 2026", "IN TRANSIT FROM INDIA TO DAR ES SALAAM", "DAR ES SALAAM", "DAR ES SALAAM TO
   MOKAMBO", ..., "OFFLOADED IN LUBUMBASHI"), worked out from the system instead of typed.

     1. THE PERMISSION containers.report.view "View Container Report" (Containers, 1408), granted ONCE per database
        (inventory.OneTimeSteps, step 95.ContainerReportGrant) to the system roles and to every role holding View
        Containers. A role unticked later is never granted again.
     2. ONE ROW PER CONTAINER LINE (a cancelled container is left out) AND ONE PER APPROVED ORDER LINE WITH PIECES STILL
        TO LOAD (ordered - loaded on containers not cancelled - received outside containers - settled short, when above
        0). Its STAGE, the first that applies:
          received (Offloaded / Closed)       "Offloaded in {the To of its last Delivery leg, else its warehouse}"
          a leg in progress, by vessel        "In transit {From} → {To}"   (a Sea leg, or a transshipment sea port → sea port)
          a leg in progress at a port         "{place}"                    (Port stage)
          a leg in progress, a stay           "{place}"                    (Customs, or From = To)
          a leg in progress, by road          "{From} → {To}"
          never moved                         "Order pending - {month}"    (the container's order month)
          last leg a Delivery, not received   "Delivered to {To}, to receive"
          else                                "{the To of its last completed leg}"
        An order line still to load: "Order pending - {month of the order date}". StageSort orders the groups the way
        the sheet does: pending (newest month first), at sea, at a port, on the road from a port, at a border or inland
        place, on the road from there, delivered, offloaded.
     3. THE JOURNEY from the legs not cancelled: Dispatch = the first start of a Sea leg; Arrived at port = the last end of
        a Sea leg; Left port = the first start of a leg leaving a sea port by land; Final destination = the places the
        legs after the port go to, in order ("Mokambo → Lubumbashi"); Truck = their vehicles; Offloaded = the container's
        offload date. LEAD TIME (MONTHS) = (offloaded - order date) / 30 days; before the offload, (today - order date)
        / 30, flagged "so far".
     4. AMOUNTS in the base currency. FOB = pieces × the line's FOB per piece (the invoice price once received; before,
        the estimate of the container page, logistics.fn_ContainerLine_FobEstimate; an order line still to load: the
        order price), flagged estimate until received. Charges = the line's share of the POSTED charges, per charge
        type (second result set); Freight / Shipping (FRE) and Inland Transportation (TRP) are the transport charges:
        their container-level invoices are listed ("05/11/2025 · 2500323 · 10,000.00") and summed. Cost per unit = the
        container line's landed cost (final once received, else the estimate of the container page).
     5. A PACKING FORMULA OF 1 ON A CONTAINER UNIT MEANS "NOT SPECIFIED" (the owner): logistics.fn_ItemPcsPerContainer, the
        one place every capacity reads, returns NULL for it - the fill is unknown, no over-capacity warning, Auto-plan
        asks for the Container unit, exactly as for an item without one.

   Objects
     New data, once    security.Permissions containers.report.view and its once-grant (security.RolePermissions)
     Re-created        logistics.fn_ItemPcsPerContainer   (from script 54) + a packing formula of 1 is "not specified"
     New               logistics.usp_ContainerReport      the report: rows, their charges per type, the charge types

   Errors: no new number. Not changed: every container, movement, charge, invoice and payment rule; every other permission.

   Requires scripts 54, 82 and 89 (Schema.sql runs them first). Idempotent, additive: re-applied at every API start-up, and
   builds a brand-new empty database.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'logistics.fn_ContainerLine_FobEstimate', N'IF') IS NULL
   OR OBJECT_ID(N'logistics.fn_ItemPcsPerContainer', N'IF') IS NULL
   OR OBJECT_ID(N'inventory.OneTimeSteps', N'U') IS NULL
    THROW 70000, 'Script 95 requires scripts 54, 82 and 89: apply them first.', 1;
GO

/* ================================================================== 1. containers.report.view "View Container Report", granted once */

-- (95) Granted ONCE per database (step 95.ContainerReportGrant) to the system roles and the roles holding View Containers:
--      the report shows nothing a container's own page does not already show them. The texts are PermissionCatalog.cs's.
SET XACT_ABORT ON;
BEGIN TRY
    BEGIN TRANSACTION;
    MERGE security.Permissions AS target
    USING (VALUES (N'containers.report.view', N'View Container Report', N'Containers',
                   N'Reports › Container Report: every container and order still to load with its order, invoices, payments, journey, charges and cost, by stage.',
                   1408)) AS source (Code, Name, Module, Description, SortOrder)
    ON target.Code = source.Code
    WHEN MATCHED AND (target.Name <> source.Name OR target.Module <> source.Module
                      OR ISNULL(target.Description, N'') <> source.Description OR target.SortOrder <> source.SortOrder) THEN
        UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (Code, Name, Module, Description, SortOrder)
        VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder);

    IF NOT EXISTS (SELECT 1 FROM inventory.OneTimeSteps WHERE StepCode = N'95.ContainerReportGrant')
    BEGIN
        DECLARE @PermissionId INT = (SELECT p.Id FROM security.Permissions p WHERE p.Code = N'containers.report.view');
        INSERT INTO security.RolePermissions (RoleId, PermissionId)
        SELECT r.Id, @PermissionId
        FROM security.Roles r
        WHERE (r.IsSystem = 1
               OR EXISTS (SELECT 1 FROM security.RolePermissions rp INNER JOIN security.Permissions p ON p.Id = rp.PermissionId
                          WHERE rp.RoleId = r.Id AND p.Code = N'containers.view'))
          AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = @PermissionId);
        DECLARE @Grants INT = @@ROWCOUNT;
        INSERT INTO inventory.OneTimeSteps (StepCode, DoneAtUtc, Progress, Details)
        VALUES (N'95.ContainerReportGrant', SYSUTCDATETIME(), @Grants, N'View Container Report granted once to the roles holding View Containers.');
        PRINT 'Container report permission granted once: ' + CAST(@Grants AS NVARCHAR(10)) + ' role grant(s).';
    END
    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH
GO

/* ================================================================== 2. Pieces per container: 1 is "not specified" */

-- Re-created (95) from the body of script 54: + A PACKING FORMULA OF 1 MEANS "NOT SPECIFIED" (the owner: a container unit of
-- 1 piece is the value nobody typed). NULL then, as for an item without a Container unit, so the fill is unknown, no
-- over-capacity warning is raised and Auto-plan asks for the Container unit. The PackingFormula of the item's Container unit
-- (the first by Id), NULL when it has none or a value <= 1. Always one row, so a CROSS APPLY keeps the item.
CREATE OR ALTER FUNCTION logistics.fn_ItemPcsPerContainer (@ItemId INT)
RETURNS TABLE
AS
RETURN
SELECT PcsPerContainer = (SELECT TOP (1) CASE WHEN u.PackingFormula > 1 THEN u.PackingFormula END
                          FROM inventory.ItemUnits u
                          INNER JOIN masterdata.UnitTypes t ON t.Id = u.UnitTypeId
                          WHERE u.ItemId = @ItemId AND t.IsContainer = 1
                          ORDER BY u.Id);
GO

/* ================================================================== 3. The report */

-- Reports › Container Report (see the header, 2-4). Three result sets:
--   1. the rows: one per container line, then one per order line still to load;
--   2. each row's share of the posted charges, per charge type (RowKey, ChargeTypeId, AmountBase);
--   3. the charge types: every active one and any inactive one the rows carry (IsTransport: FRE, TRP).
-- The filters are the server's; no paging (the page holds the whole report). @IncludePending / @IncludeReceived leave the
-- order lines still to load / the received containers out. @OffloadedFrom / @OffloadedTo narrow the received ones only.
-- SET-BASED: the rows are found first, their legs read once, every list built over them - never a function per row
-- but the FOB estimate of a line not received yet (the container page's own).
CREATE OR ALTER PROCEDURE logistics.usp_ContainerReport
    @Search          NVARCHAR(100) = NULL,   -- container ref or no., B/L, order number, PI no., invoice no.
    @SupplierId      INT           = NULL,
    @ItemId          INT           = NULL,
    @ItemFamilyId    INT           = NULL,   -- with the families under it
    @BranchId        INT           = NULL,
    @OrderDateFrom   DATE          = NULL,
    @OrderDateTo     DATE          = NULL,
    @OffloadedFrom   DATE          = NULL,
    @OffloadedTo     DATE          = NULL,
    @IncludePending  BIT           = 1,
    @IncludeReceived BIT           = 1
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Today DATE = CAST(SYSUTCDATETIME() AS DATE);
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @Like NVARCHAR(110) = N'%' + REPLACE(REPLACE(REPLACE(@Search, N'[', N'[[]'), N'%', N'[%]'), N'_', N'[_]') + N'%';

    DECLARE @Families TABLE (Id INT PRIMARY KEY);
    IF @ItemFamilyId IS NOT NULL INSERT INTO @Families (Id) SELECT Id FROM masterdata.fn_ItemFamily_Subtree(@ItemFamilyId);

    DECLARE @PoTypeId INT = (SELECT Id FROM inventory.DocumentTypes WHERE Code = N'PO');
    DECLARE @InvTypeId INT = (SELECT Id FROM inventory.DocumentTypes WHERE Code = N'PINV');

    /* ---------------------------------------------------------------- the rows */
    CREATE TABLE #R (
        RowKey NVARCHAR(20) NOT NULL PRIMARY KEY, IsPending BIT NOT NULL,
        ContainerId INT NULL, ContainerLineId INT NULL, PoId INT NOT NULL, PoLineId INT NOT NULL, ItemId INT NOT NULL,
        Qty INT NOT NULL, OrderPriceBase DECIMAL(18,6) NULL);

    -- Container lines: every container not cancelled.
    INSERT INTO #R (RowKey, IsPending, ContainerId, ContainerLineId, PoId, PoLineId, ItemId, Qty, OrderPriceBase)
    SELECT N'C' + CAST(cl.Id AS NVARCHAR(12)), 0, c.Id, cl.Id, cl.PurchaseOrderId, cl.PoLineId, cl.ItemId,
           cl.QuantityBase, pol.LineTotal / NULLIF(po.ExchangeRate, 0) / NULLIF(pol.QuantityBase, 0)
    FROM logistics.ContainerLines cl
    INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
    INNER JOIN purchase.PurchaseDocuments po ON po.Id = cl.PurchaseOrderId
    INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = cl.PoLineId
    WHERE c.Status <> 8
      AND (@IncludeReceived = 1 OR c.Status NOT IN (6, 7))
      AND (@OffloadedFrom IS NULL OR c.Status NOT IN (6, 7) OR c.OffloadedDate >= @OffloadedFrom)
      AND (@OffloadedTo IS NULL OR c.Status NOT IN (6, 7) OR c.OffloadedDate <= @OffloadedTo);

    -- Order lines still to load: approved orders (status 2), pieces not on a container, not received outside one, not
    -- settled short.
    IF @IncludePending = 1
        INSERT INTO #R (RowKey, IsPending, ContainerId, ContainerLineId, PoId, PoLineId, ItemId, Qty, OrderPriceBase)
        SELECT N'P' + CAST(pol.Id AS NVARCHAR(12)), 1, NULL, NULL, po.Id, pol.Id, pol.ItemId, x.ToLoad,
               pol.LineTotal / NULLIF(po.ExchangeRate, 0) / NULLIF(pol.QuantityBase, 0)
        FROM purchase.PurchaseDocumentLines pol
        INNER JOIN purchase.PurchaseDocuments po ON po.Id = pol.DocumentId
        OUTER APPLY (SELECT Qty = SUM(cl.QuantityBase)
                     FROM logistics.ContainerLines cl INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                     WHERE cl.PoLineId = pol.Id AND c.Status <> 8) ld
        OUTER APPLY (SELECT Qty = SUM(gl.QuantityBase)
                     FROM purchase.GoodsReceiptLines gl INNER JOIN purchase.GoodsReceipts g ON g.Id = gl.GoodsReceiptId
                     WHERE gl.PoLineId = pol.Id AND gl.ContainerLineId IS NULL AND g.Status = 2) rc
        CROSS APPLY (SELECT ToLoad = pol.QuantityBase - ISNULL(ld.Qty, 0) - ISNULL(rc.Qty, 0)
                                     - ISNULL(pol.GoodsShortBase, 0)) x
        WHERE po.DocumentTypeId = @PoTypeId AND po.Status = 2 AND x.ToLoad > 0;

    -- The filters.
    DELETE r FROM #R r
    INNER JOIN purchase.PurchaseDocuments po ON po.Id = r.PoId
    INNER JOIN inventory.Items i ON i.Id = r.ItemId
    LEFT JOIN logistics.Containers c ON c.Id = r.ContainerId
    WHERE (@SupplierId IS NOT NULL AND po.SupplierId <> @SupplierId)
       OR (@ItemId IS NOT NULL AND r.ItemId <> @ItemId)
       OR (@ItemFamilyId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM @Families f WHERE f.Id = i.ItemFamilyId))
       OR (@BranchId IS NOT NULL AND ISNULL(c.BranchId, po.BranchId) <> @BranchId)
       OR (@OrderDateFrom IS NOT NULL AND po.DocumentDate < @OrderDateFrom)
       OR (@OrderDateTo IS NOT NULL AND po.DocumentDate > @OrderDateTo)
       OR (@Search IS NOT NULL
           AND ISNULL(c.ContainerRef, N'') NOT LIKE @Like AND ISNULL(c.ContainerNo, N'') NOT LIKE @Like
           AND ISNULL(c.BlNo, N'') NOT LIKE @Like AND ISNULL(po.DocumentNumber, N'') NOT LIKE @Like
           AND ISNULL(po.SupplierReference, N'') NOT LIKE @Like
           AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines il
                           INNER JOIN purchase.PurchaseDocuments inv ON inv.Id = il.DocumentId
                           WHERE inv.DocumentTypeId = @InvTypeId AND inv.Status <> 3
                             AND (il.ContainerLineId = r.ContainerLineId OR (r.IsPending = 1 AND il.SourceLineId = r.PoLineId))
                             AND (ISNULL(inv.DocumentNumber, N'') LIKE @Like OR ISNULL(inv.CommercialInvoiceNo, N'') LIKE @Like
                                  OR ISNULL(inv.ExporterReference, N'') LIKE @Like)));

    /* ---------------------------------------------------------------- the legs of their containers */
    CREATE TABLE #Legs (
        ContainerId INT NOT NULL, MovementId INT NOT NULL, Status TINYINT NOT NULL, Stage NVARCHAR(10) NOT NULL,
        TypeCode NVARCHAR(10) NOT NULL, FromId INT NOT NULL, ToId INT NOT NULL, FromKind NVARCHAR(10) NULL,
        ToKind NVARCHAR(10) NULL, FromName NVARCHAR(100) NULL, ToName NVARCHAR(100) NULL, StartDate DATE NULL,
        EndDate DATE NULL, Eta DATE NULL, Vehicle NVARCHAR(100) NULL, Seq INT NULL,
        IsVessel BIT NULL, IsStay BIT NULL, PRIMARY KEY (ContainerId, MovementId));

    INSERT INTO #Legs (ContainerId, MovementId, Status, Stage, TypeCode, FromId, ToId, FromKind, ToKind, FromName, ToName,
                       StartDate, EndDate, Eta, Vehicle)
    SELECT mc.ContainerId, m.Id, m.Status, mt.Stage, mt.TypeCode, m.FromPlaceId, m.ToPlaceId, pf.Kind, pt.Kind,
           pf.PortName, pt.PortName, m.StartDate, m.EndDate, m.Eta, NULLIF(LTRIM(RTRIM(m.VehicleOrVessel)), N'')
    FROM logistics.MovementContainers mc
    INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    LEFT JOIN masterdata.Ports pf ON pf.Id = m.FromPlaceId
    LEFT JOIN masterdata.Ports pt ON pt.Id = m.ToPlaceId
    WHERE m.Status IN (2, 3)
      AND mc.ContainerId IN (SELECT DISTINCT ContainerId FROM #R WHERE ContainerId IS NOT NULL);

    UPDATE l SET Seq = s.Seq,
                 IsVessel = CASE WHEN l.Stage = N'Sea' OR (l.Stage = N'Transit' AND l.TypeCode <> N'INLAND'
                                                            AND l.FromKind = N'Sea' AND l.ToKind = N'Sea') THEN 1 ELSE 0 END,
                 IsStay = CASE WHEN l.Stage IN (N'Port', N'Customs') OR l.FromId = l.ToId THEN 1 ELSE 0 END
    FROM #Legs l
    INNER JOIN (SELECT ContainerId, MovementId,
                       Seq = ROW_NUMBER() OVER (PARTITION BY ContainerId ORDER BY StartDate, MovementId)
                FROM #Legs) s ON s.ContainerId = l.ContainerId AND s.MovementId = l.MovementId;

    CREATE TABLE #J (
        ContainerId INT NOT NULL PRIMARY KEY, DispatchDate DATE NULL, ArrivedPortDate DATE NULL, LeftPortDate DATE NULL,
        FinalDestination NVARCHAR(400) NULL, Trucks NVARCHAR(400) NULL, DeliveredTo NVARCHAR(100) NULL,
        ActiveMovementId INT NULL, LastMovementId INT NULL);

    INSERT INTO #J (ContainerId, DispatchDate, ArrivedPortDate, LeftPortDate, DeliveredTo, ActiveMovementId, LastMovementId)
    SELECT c.ContainerId,
           (SELECT MIN(l.StartDate) FROM #Legs l WHERE l.ContainerId = c.ContainerId AND l.Stage = N'Sea'),
           (SELECT MAX(l.EndDate) FROM #Legs l WHERE l.ContainerId = c.ContainerId AND l.Stage = N'Sea' AND l.Status = 3),
           (SELECT MIN(l.StartDate) FROM #Legs l WHERE l.ContainerId = c.ContainerId AND l.FromKind = N'Sea'
                                                     AND l.IsVessel = 0 AND l.IsStay = 0),
           (SELECT TOP (1) l.ToName FROM #Legs l WHERE l.ContainerId = c.ContainerId AND l.Stage = N'Delivery' AND l.Status = 3
            ORDER BY l.EndDate DESC, l.Seq DESC),
           (SELECT TOP (1) l.MovementId FROM #Legs l WHERE l.ContainerId = c.ContainerId AND l.Status = 2 ORDER BY l.Seq DESC),
           (SELECT TOP (1) l.MovementId FROM #Legs l WHERE l.ContainerId = c.ContainerId AND l.Status = 3
            ORDER BY l.EndDate DESC, l.Seq DESC)
    FROM (SELECT DISTINCT ContainerId FROM #R WHERE ContainerId IS NOT NULL) c;

    -- The places after the port, in order ("Mokambo → Lubumbashi"), and the vehicles that took them there.
    UPDATE j SET FinalDestination = d.Places, Trucks = t.Vehicles
    FROM #J j
    OUTER APPLY (SELECT Places = STRING_AGG(x.ToName, N' → ') WITHIN GROUP (ORDER BY x.FirstSeq)
                 FROM (SELECT l.ToName, FirstSeq = MIN(l.Seq) FROM #Legs l
                       WHERE l.ContainerId = j.ContainerId AND l.IsVessel = 0 AND l.IsStay = 0 AND ISNULL(l.ToKind, N'') <> N'Sea'
                       GROUP BY l.ToName) x) d
    OUTER APPLY (SELECT Vehicles = STRING_AGG(x.Vehicle, N' / ') WITHIN GROUP (ORDER BY x.FirstSeq)
                 FROM (SELECT l.Vehicle, FirstSeq = MIN(l.Seq) FROM #Legs l
                       WHERE l.ContainerId = j.ContainerId AND l.IsVessel = 0 AND l.Vehicle IS NOT NULL
                       GROUP BY l.Vehicle) x) t;

    /* ---------------------------------------------------------------- invoices and payments */
    CREATE TABLE #Inv (RowKey NVARCHAR(20) NOT NULL, InvoiceId INT NOT NULL, PRIMARY KEY (RowKey, InvoiceId));
    INSERT INTO #Inv (RowKey, InvoiceId)
    SELECT DISTINCT r.RowKey, inv.Id
    FROM #R r
    INNER JOIN purchase.PurchaseDocumentLines il
            ON il.ContainerLineId = r.ContainerLineId OR (r.IsPending = 1 AND il.SourceLineId = r.PoLineId AND il.ContainerLineId IS NULL)
    INNER JOIN purchase.PurchaseDocuments inv ON inv.Id = il.DocumentId
    WHERE inv.DocumentTypeId = @InvTypeId AND inv.Status = 2;

    CREATE TABLE #Pay (InvoiceId INT NOT NULL, PaymentId INT NOT NULL, Amount DECIMAL(18,2) NOT NULL, PRIMARY KEY (InvoiceId, PaymentId));
    INSERT INTO #Pay (InvoiceId, PaymentId, Amount)
    SELECT a.PurchaseDocumentId, a.PaymentId, SUM(a.AmountDocCurrency)
    FROM purchase.PaymentAllocations a
    INNER JOIN purchase.Payments p ON p.Id = a.PaymentId
    WHERE p.Status = 2 AND a.RemovedAtUtc IS NULL AND a.PurchaseDocumentId IN (SELECT InvoiceId FROM #Inv)
    GROUP BY a.PurchaseDocumentId, a.PaymentId;

    /* ---------------------------------------------------------------- charges */
    CREATE TABLE #Ch (RowKey NVARCHAR(20) NOT NULL, ChargeTypeId INT NOT NULL, AmountBase DECIMAL(18,2) NOT NULL,
                      PRIMARY KEY (RowKey, ChargeTypeId));
    INSERT INTO #Ch (RowKey, ChargeTypeId, AmountBase)
    SELECT r.RowKey, ch.ChargeTypeId, SUM(a.AmountBase)
    FROM #R r
    INNER JOIN logistics.ContainerChargeAllocations a ON a.ContainerLineId = r.ContainerLineId
    INNER JOIN logistics.ContainerCharges ch ON ch.Id = a.ChargeId
    WHERE ch.Status = 2
    GROUP BY r.RowKey, ch.ChargeTypeId;

    DECLARE @Transport TABLE (Id INT PRIMARY KEY);
    INSERT INTO @Transport (Id) SELECT Id FROM purchase.ChargeTypes WHERE ChargeCode IN (N'FRE', N'TRP');

    /* ---------------------------------------------------------------- 1. the rows */
    SELECT r.RowKey, r.IsPending,
           st.StageSort, st.StageLabel,
           OrderDate = po.DocumentDate, PurchaseOrderId = po.Id, PoNumber = po.DocumentNumber,
           OrderMonth = CASE WHEN c.OrderMonthKey IS NOT NULL
                             THEN LEFT(DATENAME(MONTH, DATEFROMPARTS(c.OrderMonthKey / 100, c.OrderMonthKey % 100, 1)), 3)
                                  + N'-' + RIGHT(CAST(c.OrderMonthKey / 100 AS NVARCHAR(4)), 2)
                             ELSE LEFT(DATENAME(MONTH, po.DocumentDate), 3) + N'-' + RIGHT(CAST(YEAR(po.DocumentDate) AS NVARCHAR(4)), 2) END,
           InvoiceDate = inv.FirstDate, InvoiceDates = inv.Dates, InvoiceNumbers = inv.Numbers,
           CommercialInvoiceNos = inv.CommercialNos, ExporterReferences = inv.ExporterRefs,
           r.ContainerId, c.ContainerRef, c.ContainerNo, ContainerStatus = c.Status,
           r.ItemId, i.ItemCode, Model = i.ItemName, Quantity = r.Qty,
           PiNumber = po.SupplierReference,
           SupplierId = po.SupplierId, SupplierName = sp.PartyName,
           BranchName = b.BranchName, WarehouseCode = w.WarehouseCode,
           FobAmountBase = CAST(r.Qty * fob.UnitFob AS DECIMAL(18,2)),
           FobIsEstimate = CAST(CASE WHEN cl.FobCostBase IS NULL THEN 1 ELSE 0 END AS BIT),
           OilQtyPerUnit = cl.OilQtyPerUnit,
           PaidDates = pay.Dates, PaymentReferences = pay.Refs,
           PaymentStatus = CASE WHEN inv.FirstDate IS NULL THEN N'Not invoiced'
                                WHEN pay.Paid IS NULL THEN N'Not paid'
                                WHEN pay.Paid >= inv.Total - 0.005 THEN N'Paid'
                                ELSE N'Partly paid' END,
           j.DispatchDate, j.ArrivedPortDate, j.LeftPortDate,
           FinalDestination = COALESCE(j.FinalDestination, fd.PortName),
           Trucks = COALESCE(j.Trucks, NULLIF(LTRIM(RTRIM(c.TruckNo)), N'')),
           OffloadedDate = CASE WHEN c.Status IN (6, 7) THEN c.OffloadedDate END,
           GoodsReceiptNumbers = grn.Numbers,
           LeadTimeMonths = CAST(ROUND(DATEDIFF(DAY, po.DocumentDate,
                                CASE WHEN c.Status IN (6, 7) THEN c.OffloadedDate ELSE @Today END) / 30.0, 2) AS DECIMAL(9,2)),
           LeadTimeSoFar = CAST(CASE WHEN c.Status IN (6, 7) THEN 0 ELSE 1 END AS BIT),
           c.BlNo, c.FeriNo,
           TransportReferences = tr.Refs, TransportInvoices = tr.Invoices,
           TransportBase = trs.Amount,
           ChargesBase = chs.Amount,
           TotalExpensesBase = CAST(r.Qty * fob.UnitFob AS DECIMAL(18,2)) + ISNULL(chs.Amount, 0),
           CostPerUnitBase = CAST(CASE WHEN r.IsPending = 1 THEN r.OrderPriceBase
                                       ELSE COALESCE(cl.LandedCostBase, fob.UnitFob + cl.ChargesBase / NULLIF(cl.QuantityBase, 0)) END
                                  AS DECIMAL(18,4)),
           CostIsEstimate = CAST(CASE WHEN cl.LandedCostBase IS NOT NULL THEN 0 ELSE 1 END AS BIT),
           IsLate = CAST(CASE WHEN act.Eta < @Today THEN 1 ELSE 0 END AS BIT),
           IsFreeTimeOver = CAST(CASE WHEN c.Status IN (4, 5) AND c.LastFreeDay < @Today THEN 1 ELSE 0 END AS BIT)
    FROM #R r
    INNER JOIN purchase.PurchaseDocuments po ON po.Id = r.PoId
    INNER JOIN masterdata.Parties sp ON sp.Id = po.SupplierId
    INNER JOIN inventory.Items i ON i.Id = r.ItemId
    LEFT JOIN logistics.ContainerLines cl ON cl.Id = r.ContainerLineId
    LEFT JOIN logistics.Containers c ON c.Id = r.ContainerId
    LEFT JOIN masterdata.Branches b ON b.Id = ISNULL(c.BranchId, po.BranchId)
    LEFT JOIN masterdata.Warehouses w ON w.Id = ISNULL(c.WarehouseId, po.WarehouseId)
    LEFT JOIN masterdata.Ports fd ON fd.Id = c.FinalDestinationId
    LEFT JOIN #J j ON j.ContainerId = r.ContainerId
    LEFT JOIN #Legs act ON act.ContainerId = r.ContainerId AND act.MovementId = j.ActiveMovementId
    LEFT JOIN #Legs lst ON lst.ContainerId = r.ContainerId AND lst.MovementId = j.LastMovementId
    -- the FOB per piece: the line's own once received, else the container page's estimate; the order price for an order
    -- line still to load
    OUTER APPLY (SELECT UnitFob = CASE WHEN r.IsPending = 1 THEN r.OrderPriceBase
                                       ELSE COALESCE(cl.FobCostBase,
                                                     (SELECT fe.EstimatedFobBase FROM logistics.fn_ContainerLine_FobEstimate(cl.Id) fe)) END) fob
    OUTER APPLY (SELECT FirstDate = MIN(d.DocumentDate),
                        Dates = STRING_AGG(CONVERT(NVARCHAR(10), d.DocumentDate, 103), N', ') WITHIN GROUP (ORDER BY d.DocumentDate),
                        Numbers = STRING_AGG(d.DocumentNumber, N', ') WITHIN GROUP (ORDER BY d.DocumentDate, d.Id),
                        CommercialNos = STRING_AGG(NULLIF(d.CommercialInvoiceNo, N''), N', ') WITHIN GROUP (ORDER BY d.DocumentDate, d.Id),
                        ExporterRefs = STRING_AGG(NULLIF(d.ExporterReference, N''), N', ') WITHIN GROUP (ORDER BY d.DocumentDate, d.Id),
                        Total = SUM(d.TotalAmount)
                 FROM #Inv x INNER JOIN purchase.PurchaseDocuments d ON d.Id = x.InvoiceId
                 WHERE x.RowKey = r.RowKey) inv
    OUTER APPLY (SELECT Paid = SUM(q.Amount),
                        Dates = STRING_AGG(CONVERT(NVARCHAR(10), q.PaymentDate, 103), N', ') WITHIN GROUP (ORDER BY q.PaymentDate),
                        Refs = STRING_AGG(q.Reference, N', ') WITHIN GROUP (ORDER BY q.PaymentDate)
                 FROM (SELECT p.Id, p.PaymentDate, Reference = NULLIF(p.Reference, N''), Amount = SUM(y.Amount)
                       FROM #Inv x
                       INNER JOIN #Pay y ON y.InvoiceId = x.InvoiceId
                       INNER JOIN purchase.Payments p ON p.Id = y.PaymentId
                       WHERE x.RowKey = r.RowKey
                       GROUP BY p.Id, p.PaymentDate, p.Reference) q) pay
    OUTER APPLY (SELECT Numbers = STRING_AGG(g.DocumentNumber, N', ') WITHIN GROUP (ORDER BY g.DocumentDate)
                 FROM purchase.GoodsReceipts g WHERE g.ContainerId = r.ContainerId AND g.Status = 2) grn
    -- the transport invoices of the container, at container level ("05/11/2025 · 2500323 · 10,000.00")
    OUTER APPLY (SELECT Refs = STRING_AGG(z.Reference, N', ') WITHIN GROUP (ORDER BY z.ChargeDate, z.Id),
                        Invoices = STRING_AGG(CONVERT(NVARCHAR(10), z.ChargeDate, 103) + ISNULL(N' · ' + z.Reference, N'')
                                              + N' · ' + FORMAT(z.AmountBase, N'N2', 'en-US'), N'; ')
                                   WITHIN GROUP (ORDER BY z.ChargeDate, z.Id)
                 FROM (SELECT ch.Id, ch.ChargeDate, Reference = NULLIF(ch.Reference, N''), ch.AmountBase
                       FROM logistics.ContainerCharges ch
                       WHERE ch.ContainerId = r.ContainerId AND ch.Status = 2
                         AND ch.ChargeTypeId IN (SELECT Id FROM @Transport)) z) tr
    OUTER APPLY (SELECT Amount = SUM(x.AmountBase) FROM #Ch x WHERE x.RowKey = r.RowKey AND x.ChargeTypeId IN (SELECT Id FROM @Transport)) trs
    OUTER APPLY (SELECT Amount = SUM(x.AmountBase) FROM #Ch x WHERE x.RowKey = r.RowKey) chs
    -- the stage (see the header, 2)
    CROSS APPLY (SELECT StageSort = CASE
                     WHEN c.Status IN (6, 7) THEN 90
                     WHEN act.MovementId IS NOT NULL AND act.IsVessel = 1 THEN 20
                     WHEN act.MovementId IS NOT NULL AND act.Stage = N'Port' THEN 30
                     WHEN act.MovementId IS NOT NULL AND act.IsStay = 1 THEN 50
                     WHEN act.MovementId IS NOT NULL AND act.FromKind = N'Sea' THEN 40
                     WHEN act.MovementId IS NOT NULL THEN 55
                     WHEN r.IsPending = 1 OR lst.MovementId IS NULL THEN 10
                     WHEN lst.Stage = N'Delivery' THEN 60
                     WHEN lst.ToKind = N'Sea' THEN 30
                     ELSE 50 END) s0
    CROSS APPLY (SELECT PendingMonth = CASE WHEN s0.StageSort = 10
                                            THEN ISNULL(c.OrderMonthKey, YEAR(po.DocumentDate) * 100 + MONTH(po.DocumentDate)) END) pm
    CROSS APPLY (SELECT StageSort = CASE WHEN s0.StageSort = 10 THEN 10 + (999999 - pm.PendingMonth) / 1000000.0
                                         ELSE CAST(s0.StageSort AS DECIMAL(12,6)) END,
                        StageLabel = CASE s0.StageSort
                            WHEN 90 THEN N'Offloaded in ' + COALESCE(j.DeliveredTo, w.WarehouseName, N'the warehouse')
                            WHEN 20 THEN N'In transit ' + ISNULL(act.FromName, N'?') + N' → ' + ISNULL(act.ToName, N'?')
                            WHEN 30 THEN ISNULL(CASE WHEN act.MovementId IS NOT NULL THEN act.ToName ELSE lst.ToName END, N'At port')
                            WHEN 50 THEN ISNULL(CASE WHEN act.MovementId IS NOT NULL THEN act.ToName ELSE lst.ToName END, N'At border / customs')
                            WHEN 40 THEN ISNULL(act.FromName, N'?') + N' → ' + ISNULL(act.ToName, N'?')
                            WHEN 55 THEN ISNULL(act.FromName, N'?') + N' → ' + ISNULL(act.ToName, N'?')
                            WHEN 60 THEN N'Delivered to ' + ISNULL(lst.ToName, N'?') + N', to receive'
                            ELSE N'Order pending - ' + DATENAME(MONTH, DATEFROMPARTS(pm.PendingMonth / 100, pm.PendingMonth % 100, 1))
                                 + N' ' + CAST(pm.PendingMonth / 100 AS NVARCHAR(4)) END) st
    ORDER BY st.StageSort, st.StageLabel, c.ContainerRef, po.DocumentDate, r.RowKey;

    /* ---------------------------------------------------------------- 2. the charges per type */
    SELECT RowKey, ChargeTypeId, AmountBase FROM #Ch ORDER BY RowKey, ChargeTypeId;

    /* ---------------------------------------------------------------- 3. the charge types */
    SELECT t.Id, t.ChargeCode, t.ChargeName,
           IsTransport = CAST(CASE WHEN t.Id IN (SELECT Id FROM @Transport) THEN 1 ELSE 0 END AS BIT)
    FROM purchase.ChargeTypes t
    WHERE t.IsActive = 1 OR t.Id IN (SELECT ChargeTypeId FROM #Ch)
    ORDER BY t.Id;
END
GO

PRINT 'Script 95 applied: the Container Report (containers.report.view), and a packing formula of 1 is "not specified" for capacity.';
GO
