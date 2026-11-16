SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 105: REPORTING - THE CONTAINER CHARGES REPORT

   Reports › Container Charges: the containers offloaded (or dispatched) in a period and, for each charge type asked,
   whether the charge is entered on the container, its amount, what is paid of it and its payments - the logistics
   team's "charge per CONTAINER" sheet (# / container ref / container number / items / final destination / current
   location / amount / paid), worked out by the system, several charge types side by side.

     1. THE PERMISSION reports.containercharges.view "View Container Charges Report" (module Reports, 1520). Not granted
        to any role here: the start-up sync gives every permission to the system roles, and the others get it in Role
        Permissions. Its payment columns also need View Supplier Payments: the API sends them empty to others.
     2. reporting.usp_ContainerChargeReport:
          the containers   every container not cancelled whose OFFLOAD date (received: Offloaded or Closed) or whose
                           DISPATCH date (logistics.Containers.DispatchDate: the first start of its Sea leg, or typed) is
                           in the period - one basis at a time, the page's radio button; no period = every container.
                           Searched by container ref, container no. or B/L; limited to one supplier (its order lines').
                           Items ("HLX125 ×180, KING+ ×22"), pieces, suppliers, orders, the final destination and the
                           current location (StageSort / StageLabel) as the Container Report (script 100) works them out.
          the charges      every Draft or Posted charge of the asked types on those containers, one row each, with its
                           date, reference, provider, currency, amount (and in the base currency) and what posted payments
                           allocate to it (allocations taken back are left out), with their numbers and dates.
          the charge types the ones asked, in the order asked.
        The service adds the charges up per container and type (a container may have several freight invoices), says
        Entered / Draft / Missing and Paid / Partly paid / Unpaid, and filters on them.

   Errors: no new number. Requires scripts 27, 46, 100 and 102 (Schema.sql runs them first). Idempotent, additive.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'logistics.ContainerCharges', N'U') IS NULL
   OR OBJECT_ID(N'purchase.PaymentAllocations', N'U') IS NULL
   OR COL_LENGTH(N'purchase.ChargeTypes', N'IsDeduction') IS NULL
    THROW 50000, 'Script 105 requires scripts 27, 46 and 102: apply them first.', 1;
GO

IF SCHEMA_ID(N'reporting') IS NULL EXEC (N'CREATE SCHEMA reporting');
GO

/* ================================================================== 1. reports.containercharges.view */

-- The texts are PermissionCatalog.cs's, so the start-up sync changes nothing.
MERGE security.Permissions AS target
USING (VALUES (N'reports.containercharges.view', N'View Container Charges Report', N'Reports',
               N'Reports › Container Charges: the containers offloaded or dispatched in a period with each charge type entered or missing, its amount and its payments.',
               1520)) AS source (Code, Name, Module, Description, SortOrder)
ON target.Code = source.Code
WHEN MATCHED AND (target.Name <> source.Name OR target.Module <> source.Module
                  OR ISNULL(target.Description, N'') <> source.Description OR target.SortOrder <> source.SortOrder) THEN
    UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Module, Description, SortOrder)
    VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder);
GO

/* ================================================================== 2. reporting.usp_ContainerChargeReport */

CREATE OR ALTER PROCEDURE reporting.usp_ContainerChargeReport
    @ChargeTypeIds NVARCHAR(MAX),                -- comma separated, in the order of the columns
    @DateBasis     NVARCHAR(10)  = N'Offload',   -- Offload | Dispatch
    @DateFrom      DATE          = NULL,
    @DateTo        DATE          = NULL,
    @Search        NVARCHAR(100) = NULL,         -- container ref or no., B/L
    @SupplierId    INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Today DATE = CAST(SYSUTCDATETIME() AS DATE);
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @Like NVARCHAR(110) = N'%' + REPLACE(REPLACE(REPLACE(@Search, N'[', N'[[]'), N'%', N'[%]'), N'_', N'[_]') + N'%';
    DECLARE @ByDispatch BIT = CASE WHEN @DateBasis = N'Dispatch' THEN 1 ELSE 0 END;

    DECLARE @Types TABLE (Id INT NOT NULL PRIMARY KEY, Seq INT NOT NULL);
    INSERT INTO @Types (Id, Seq)
    -- Seq: where the id stands in the list (STRING_SPLIT's ordinal needs compatibility level 160).
    SELECT t.Id, MIN(x.Seq)
    FROM (SELECT Id = TRY_CAST(LTRIM(RTRIM(value)) AS INT),
                 Seq = CHARINDEX(N',' + LTRIM(RTRIM(value)) + N',', N',' + REPLACE(@ChargeTypeIds, N' ', N'') + N',')
          FROM STRING_SPLIT(ISNULL(@ChargeTypeIds, N''), N',')) x
    INNER JOIN purchase.ChargeTypes t ON t.Id = x.Id
    GROUP BY t.Id;

    /* ---------------------------------------------------------------- the containers */
    CREATE TABLE #C (ContainerId INT NOT NULL PRIMARY KEY);
    INSERT INTO #C (ContainerId)
    SELECT c.Id
    FROM logistics.Containers c
    WHERE c.Status <> 8
      AND (@DateFrom IS NULL OR (@ByDispatch = 1 AND c.DispatchDate >= @DateFrom)
                             OR (@ByDispatch = 0 AND c.Status IN (6, 7) AND c.OffloadedDate >= @DateFrom))
      AND (@DateTo IS NULL OR (@ByDispatch = 1 AND c.DispatchDate <= @DateTo)
                           OR (@ByDispatch = 0 AND c.Status IN (6, 7) AND c.OffloadedDate <= @DateTo))
      AND (@Search IS NULL OR c.ContainerRef LIKE @Like OR ISNULL(c.ContainerNo, N'') LIKE @Like OR ISNULL(c.BlNo, N'') LIKE @Like)
      AND (@SupplierId IS NULL OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                                          INNER JOIN purchase.PurchaseDocuments po ON po.Id = cl.PurchaseOrderId
                                          WHERE cl.ContainerId = c.Id AND po.SupplierId = @SupplierId));

    /* ---------------------------------------------------------------- their legs (as script 100) */
    CREATE TABLE #Legs (
        ContainerId INT NOT NULL, MovementId INT NOT NULL, Status TINYINT NOT NULL, Stage NVARCHAR(10) NOT NULL,
        TypeCode NVARCHAR(10) NOT NULL, FromId INT NOT NULL, ToId INT NOT NULL, FromKind NVARCHAR(10) NULL,
        ToKind NVARCHAR(10) NULL, FromName NVARCHAR(100) NULL, ToName NVARCHAR(100) NULL, StartDate DATE NULL,
        EndDate DATE NULL, Seq INT NULL, IsVessel BIT NULL, IsStay BIT NULL, PRIMARY KEY (ContainerId, MovementId));

    INSERT INTO #Legs (ContainerId, MovementId, Status, Stage, TypeCode, FromId, ToId, FromKind, ToKind, FromName, ToName,
                       StartDate, EndDate)
    SELECT mc.ContainerId, m.Id, m.Status, mt.Stage, mt.TypeCode, m.FromPlaceId, m.ToPlaceId, pf.Kind, pt.Kind,
           pf.PortName, pt.PortName, m.StartDate, m.EndDate
    FROM logistics.MovementContainers mc
    INNER JOIN #C c ON c.ContainerId = mc.ContainerId
    INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    LEFT JOIN masterdata.Ports pf ON pf.Id = m.FromPlaceId
    LEFT JOIN masterdata.Ports pt ON pt.Id = m.ToPlaceId
    WHERE m.Status IN (2, 3);

    UPDATE l SET Seq = s.Seq,
                 IsVessel = CASE WHEN l.Stage = N'Sea' OR (l.Stage = N'Transit' AND l.TypeCode <> N'INLAND'
                                                            AND l.FromKind = N'Sea' AND l.ToKind = N'Sea') THEN 1 ELSE 0 END,
                 IsStay = CASE WHEN l.Stage IN (N'Port', N'Customs') OR l.FromId = l.ToId THEN 1 ELSE 0 END
    FROM #Legs l
    INNER JOIN (SELECT ContainerId, MovementId,
                       Seq = ROW_NUMBER() OVER (PARTITION BY ContainerId ORDER BY StartDate, MovementId)
                FROM #Legs) s ON s.ContainerId = l.ContainerId AND s.MovementId = l.MovementId;

    CREATE TABLE #J (
        ContainerId INT NOT NULL PRIMARY KEY, FinalDestination NVARCHAR(400) NULL, DeliveredTo NVARCHAR(100) NULL,
        ActiveMovementId INT NULL, LastMovementId INT NULL);

    INSERT INTO #J (ContainerId, DeliveredTo, ActiveMovementId, LastMovementId)
    SELECT c.ContainerId,
           (SELECT TOP (1) l.ToName FROM #Legs l WHERE l.ContainerId = c.ContainerId AND l.Stage = N'Delivery' AND l.Status = 3
            ORDER BY l.EndDate DESC, l.Seq DESC),
           (SELECT TOP (1) l.MovementId FROM #Legs l WHERE l.ContainerId = c.ContainerId AND l.Status = 2 ORDER BY l.Seq DESC),
           (SELECT TOP (1) l.MovementId FROM #Legs l WHERE l.ContainerId = c.ContainerId AND l.Status = 3
            ORDER BY l.EndDate DESC, l.Seq DESC)
    FROM #C c;

    -- The places after the port, in order ("Mokambo → Lubumbashi").
    UPDATE j SET FinalDestination = d.Places
    FROM #J j
    OUTER APPLY (SELECT Places = STRING_AGG(x.ToName, N' → ') WITHIN GROUP (ORDER BY x.FirstSeq)
                 FROM (SELECT l.ToName, FirstSeq = MIN(l.Seq) FROM #Legs l
                       WHERE l.ContainerId = j.ContainerId AND l.IsVessel = 0 AND l.IsStay = 0 AND ISNULL(l.ToKind, N'') <> N'Sea'
                       GROUP BY l.ToName) x) d;

    /* ---------------------------------------------------------------- 1. the containers */
    SELECT c.Id AS ContainerId, c.ContainerRef, c.ContainerNo, c.BlNo, ContainerStatus = c.Status,
           Items = it.Items, Pieces = ISNULL(it.Pieces, 0), Suppliers = sp.Names, Orders = po.Numbers,
           FinalDestination = COALESCE(j.FinalDestination, fd.PortName),
           st.StageSort, st.StageLabel,
           DispatchDate = c.DispatchDate,
           OffloadedDate = CASE WHEN c.Status IN (6, 7) THEN c.OffloadedDate END,
           BranchName = b.BranchName, WarehouseName = w.WarehouseName
    FROM #C x
    INNER JOIN logistics.Containers c ON c.Id = x.ContainerId
    LEFT JOIN masterdata.Branches b ON b.Id = c.BranchId
    LEFT JOIN masterdata.Warehouses w ON w.Id = c.WarehouseId
    LEFT JOIN masterdata.Ports fd ON fd.Id = c.FinalDestinationId
    LEFT JOIN #J j ON j.ContainerId = c.Id
    LEFT JOIN #Legs act ON act.ContainerId = c.Id AND act.MovementId = j.ActiveMovementId
    LEFT JOIN #Legs lst ON lst.ContainerId = c.Id AND lst.MovementId = j.LastMovementId
    OUTER APPLY (SELECT Items = STRING_AGG(z.ItemCode + N' ×' + CAST(z.Qty AS NVARCHAR(12)), N', ') WITHIN GROUP (ORDER BY z.ItemCode),
                        Pieces = SUM(z.Qty)
                 FROM (SELECT i.ItemCode, Qty = SUM(cl.QuantityBase)
                       FROM logistics.ContainerLines cl INNER JOIN inventory.Items i ON i.Id = cl.ItemId
                       WHERE cl.ContainerId = c.Id GROUP BY i.ItemCode) z) it
    OUTER APPLY (SELECT Names = STRING_AGG(z.PartyName, N', ') WITHIN GROUP (ORDER BY z.PartyName)
                 FROM (SELECT DISTINCT p.PartyName
                       FROM logistics.ContainerLines cl
                       INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                       INNER JOIN masterdata.Parties p ON p.Id = d.SupplierId
                       WHERE cl.ContainerId = c.Id) z) sp
    OUTER APPLY (SELECT Numbers = STRING_AGG(z.DocumentNumber, N', ') WITHIN GROUP (ORDER BY z.DocumentNumber)
                 FROM (SELECT DISTINCT d.DocumentNumber
                       FROM logistics.ContainerLines cl
                       INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                       WHERE cl.ContainerId = c.Id AND d.DocumentNumber IS NOT NULL) z) po
    -- the stage (script 100's, without the order lines still to load)
    CROSS APPLY (SELECT StageSort = CASE
                     WHEN c.Status IN (6, 7) THEN 90
                     WHEN act.MovementId IS NOT NULL AND act.IsVessel = 1 THEN 20
                     WHEN act.MovementId IS NOT NULL AND act.Stage = N'Port' THEN 30
                     WHEN act.MovementId IS NOT NULL AND act.IsStay = 1 THEN 50
                     WHEN act.MovementId IS NOT NULL AND act.FromKind = N'Sea' THEN 40
                     WHEN act.MovementId IS NOT NULL THEN 55
                     WHEN lst.MovementId IS NULL THEN 10
                     WHEN lst.Stage = N'Delivery' THEN 60
                     WHEN lst.ToKind = N'Sea' THEN 30
                     ELSE 50 END) s0
    CROSS APPLY (SELECT StageSort = CAST(s0.StageSort AS INT),
                        StageLabel = CASE s0.StageSort
                            WHEN 90 THEN N'Offloaded in ' + COALESCE(j.DeliveredTo, w.WarehouseName, N'the warehouse')
                            WHEN 20 THEN N'In transit ' + ISNULL(act.FromName, N'?') + N' → ' + ISNULL(act.ToName, N'?')
                            WHEN 30 THEN ISNULL(CASE WHEN act.MovementId IS NOT NULL THEN act.ToName ELSE lst.ToName END, N'At port')
                            WHEN 50 THEN ISNULL(CASE WHEN act.MovementId IS NOT NULL THEN act.ToName ELSE lst.ToName END, N'At border / customs')
                            WHEN 40 THEN ISNULL(act.FromName, N'?') + N' → ' + ISNULL(act.ToName, N'?')
                            WHEN 55 THEN ISNULL(act.FromName, N'?') + N' → ' + ISNULL(act.ToName, N'?')
                            WHEN 60 THEN N'Delivered to ' + ISNULL(lst.ToName, N'?') + N', to receive'
                            ELSE N'Not dispatched yet' END) st
    ORDER BY st.StageSort, st.StageLabel, c.ContainerRef;

    /* ---------------------------------------------------------------- 2. the charges of the asked types */
    SELECT ChargeId = ch.Id, ch.ContainerId, ch.ChargeTypeId, ch.Status, ch.ChargeDate, Reference = NULLIF(ch.Reference, N''),
           ProviderName = pr.PartyName, cu.CurrencyCode, ch.Amount, ch.AmountBase,
           PaidAmount = ISNULL(pay.Paid, 0), PaidBase = ISNULL(pay.PaidBase, 0),
           Payments = pay.List
    FROM logistics.ContainerCharges ch
    INNER JOIN #C c ON c.ContainerId = ch.ContainerId
    INNER JOIN @Types t ON t.Id = ch.ChargeTypeId
    LEFT JOIN masterdata.Parties pr ON pr.Id = ch.ProviderPartyId
    LEFT JOIN masterdata.Currencies cu ON cu.Id = ch.CurrencyId
    OUTER APPLY (SELECT Paid = SUM(z.Amount), PaidBase = SUM(z.AmountBase),
                        List = STRING_AGG(z.PaymentNumber + N' · ' + CONVERT(NVARCHAR(10), z.PaymentDate, 103)
                                          + N' · ' + FORMAT(z.Amount, N'N2', 'en-US'), N'; ')
                                   WITHIN GROUP (ORDER BY z.PaymentDate, z.PaymentNumber)
                 FROM (SELECT PaymentNumber = ISNULL(p.PaymentNumber, N'#' + CAST(p.Id AS NVARCHAR(12))), p.PaymentDate,
                              Amount = SUM(a.AmountDocCurrency), AmountBase = SUM(a.AmountBase)
                       FROM purchase.PaymentAllocations a
                       INNER JOIN purchase.Payments p ON p.Id = a.PaymentId
                       WHERE a.ContainerChargeId = ch.Id AND a.RemovedAtUtc IS NULL AND p.Status = 2
                       GROUP BY p.Id, p.PaymentNumber, p.PaymentDate) z) pay
    WHERE ch.Status IN (1, 2)
    ORDER BY ch.ContainerId, ch.ChargeTypeId, ch.ChargeDate, ch.Id;

    /* ---------------------------------------------------------------- 3. the charge types asked */
    SELECT ct.Id, ct.ChargeCode, ct.ChargeName, ct.IsDeduction
    FROM @Types t INNER JOIN purchase.ChargeTypes ct ON ct.Id = t.Id
    ORDER BY t.Seq;
END
GO

/* ================================================================== 3. Check */

SELECT Code, Name, Module, SortOrder FROM security.Permissions WHERE Code = N'reports.containercharges.view';

PRINT 'Script 105 applied: the Container Charges Report (reports.containercharges.view, reporting.usp_ContainerChargeReport).';
GO
