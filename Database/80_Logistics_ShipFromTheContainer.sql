SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 80: LOGISTICS - SHIP FROM THE CONTAINER (shipment, phase 1)

   The owner's words: "in the containers the shipment is not flexible for the user, I cannot start the shipment of a
   specific container in the containers page or any other place; make shipment more user friendly and flexible."

   Phase 1 of the container-first design: every container says what its next step is, and the pages offer it in one
   click - "Start shipment..." (never moved), "Start Inland transport..." (its next planned movement), "Arrived at Dar es
   Salaam..." (the movement carrying it is in progress), "Next leg..." (its last movement is completed). Movements stay
   the only record: every step still goes through usp_Movement_Save and usp_Movement_SetStatus, so the place rule
   (70015), one movement at a time (70012), the previous leg (70016), the container dates and statuses, and the draft
   goods receipts of a completed Delivery (made by the API after the commit) all keep working.

     1. NEW logistics.fn_Movement_StartBlock: why a PLANNED movement cannot start yet (the refusal Start would give:
        no container, a draft or received container, one travelling with another movement, the previous leg not
        completed, a container not at the From) and the earliest start date (the latest end of its containers'
        previous legs; for a movement in progress too, whose start date stays editable). The Movements list, the
        movement page and the container's button say it before the click.
     1b. logistics.fn_ContainerFitForMovement (the place rules of Save, Start and the pickers): a container that already
        travelled with a LATER movement (in progress or completed) no longer fits an older planned or in-progress one.
        "Previous" is the movement with the highest Id below, so on an older movement the container was checked against
        a stale leg: it could be added to it and started from a place it had already left. "Already travelled further
        with MOV-2026-000005 (Dar es Salaam -> Kasumbalesa), a later movement: take it off this one." (70015).
     2. NEW logistics.fn_Container_ShipState: where a container is (the end of its latest movement, else its port of
        loading), the movement in progress that carries it, its next planned movement (after the latest leg it started
        or made: an older planned one is no longer its next step, and 1b refuses it) and why it cannot start yet, its
        last completed movement, and how many movements it has. The API turns it into the container's next step.
     3. logistics.usp_Container_Search: + the ship state columns. The Movement column can now show a planned next
        movement ("Planned: MOV-..."): planned movements were never shown, yet they decide where a container "is".
     4. logistics.usp_Container_Get: + the same columns on the header (set 1); the other sets are unchanged.
     5. logistics.usp_Movement_Search and logistics.usp_Movement_Get: + StartBlockedReason and StartNotBefore (rule 1),
        for the list's "Start..." row action and the Start dialogs.
     6. logistics.usp_Movement_SetStatus: two new refusals.
          - Start before the previous leg of one of its containers ended (70018): "Container KTG-2026-0031 cannot start
            MOV-2026-000051 before MOV-2026-000046 reached Dar es Salaam on 12/10/2026."
          - A start or end date in the future (70000), the owner's decision: a start and an arrival record facts. One
            day of tolerance, as for the document dates (the reader's date against the server's UTC date).
        Cancel is unchanged.
     6b. logistics.usp_Movement_Save: the same two rules for the start date of a movement IN PROGRESS, which the movement
        page lets the user change after Start: never in the future (70000), never before the previous leg of one of its
        containers ended (70018). Otherwise a start made today could be moved to next month, or before the container
        got to the From, with a plain Save.
     7. logistics.usp_Movement_ShipContainers: the "empty From / To = the containers' ports" default only for
        containers that never moved. A container that moved leaves from where it is: an empty From is the place every
        selected container is at (the end of its latest movement; a container that never moved is at its port of
        loading), refused when they are at different places; the To stays required for it. A stay (Port, Customs,
        Border) with an empty To takes the From.
     8. NEW logistics.usp_Movement_JoinCandidates: the planned movements a container can really join ("Add to a
        movement..."): planned, after its latest movement, and passing the checks Save makes for it
        (fn_Movement_ContainerCheck). The list no longer offers a movement that would be refused after the click.

   Procedures re-created from their current bodies: logistics.usp_Container_Search (78), logistics.usp_Container_Get
   (65), logistics.usp_Movement_Search (27), logistics.usp_Movement_Get (79), logistics.usp_Movement_SetStatus (65),
   logistics.usp_Movement_Save (53), logistics.usp_Movement_ShipContainers (28); the function
   logistics.fn_ContainerFitForMovement (53).
   New: logistics.fn_Movement_StartBlock, logistics.fn_Container_ShipState, logistics.usp_Movement_JoinCandidates.
   New error: 70018 a movement started before the previous leg of one of its containers ended.

   Requires scripts 53, 65 and 78 (Schema.sql runs them first). Idempotent, additive: re-applied at every API start-up,
   and builds a brand-new empty database (no table or column is added).
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'logistics.fn_ContainerFitForMovement') IS NULL                    -- 53
   OR OBJECT_ID(N'logistics.fn_Movement_ContainerCheck') IS NULL                 -- 50 / 53
   OR OBJECT_ID(N'logistics.fn_Container_ReceivedBy') IS NULL                    -- 65
   OR OBJECT_ID(N'logistics.usp_Container_Lookup', N'P') IS NULL                 -- 78
    THROW 70000, 'Script 80 requires scripts 53, 65 and 78: apply them first.', 1;
GO

/* ================================================================== 1. Why a planned movement cannot start yet */

-- One row for a PLANNED movement (none for the others): the first refusal its Start would give, in the order of
-- usp_Movement_SetStatus (no container; a draft, received, closed or cancelled container; one travelling with another
-- movement in progress, 70012; a previous movement not completed, 70016; a container not at the From, 70015), NULL when
-- it can start; and the earliest start date: the latest end date of its containers' previous movements (70018), with
-- that movement and where it ended. The future-date rule is the dialog's (any date up to today).
-- A movement IN PROGRESS gets a row too, with no Reason: its start date stays editable on the movement page, and
-- usp_Movement_Save holds it to the same earliest start (70018), which the page shows on the field before the Save.
CREATE OR ALTER FUNCTION logistics.fn_Movement_StartBlock (@MovementId INT)
RETURNS TABLE
AS
RETURN
SELECT m.Id AS MovementId,
       Reason = CAST(CASE WHEN m.Status = 1 THEN COALESCE(
           CASE WHEN NOT EXISTS (SELECT 1 FROM logistics.MovementContainers x WHERE x.MovementId = m.Id)
                THEN N'Tick at least one container before starting.' END,
           (SELECT TOP (1) N'Container ' + c.ContainerRef + CASE WHEN c.Status = 1 THEN N' is not confirmed yet.'
                                                                 ELSE N' is already offloaded, closed or cancelled.' END
            FROM logistics.MovementContainers mc
            INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
            WHERE mc.MovementId = m.Id AND (c.Status = 1 OR c.Status >= 6)
            ORDER BY c.ContainerRef),
           (SELECT TOP (1) N'Container ' + c.ContainerRef + N' is already travelling with movement ' + o.MovementNo + N'. Complete it first.'
            FROM logistics.MovementContainers mc
            INNER JOIN logistics.Containers c          ON c.Id = mc.ContainerId
            INNER JOIN logistics.MovementContainers oc ON oc.ContainerId = mc.ContainerId AND oc.MovementId <> m.Id
            INNER JOIN logistics.Movements o           ON o.Id = oc.MovementId AND o.Status = 2
            WHERE mc.MovementId = m.Id
            ORDER BY c.ContainerRef),
           (SELECT TOP (1) N'Container ' + c.ContainerRef + N': the previous movement ' + p.PreviousMovementNo + N' (' + pf.PortName
                           + N' ' + NCHAR(8594) + N' ' + p.PlaceName + N') is not completed yet.'
            FROM logistics.MovementContainers mc
            INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
            INNER JOIN logistics.fn_ContainerPlaceForMovement(m.Id) p ON p.ContainerId = mc.ContainerId
            INNER JOIN logistics.Movements pm ON pm.Id = p.PreviousMovementId
            INNER JOIN masterdata.Ports pf    ON pf.Id = pm.FromPlaceId
            WHERE mc.MovementId = m.Id AND p.PreviousStatus <> 3
            ORDER BY c.ContainerRef),
           (SELECT TOP (1) N'Container ' + c.ContainerRef + N' cannot leave from ' + f.PortName + N'. ' + p.Reason
            FROM logistics.MovementContainers mc
            INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
            INNER JOIN logistics.fn_ContainerFitForMovement(m.Id, m.FromPlaceId, m.ToPlaceId, m.MovementTypeId) p ON p.ContainerId = mc.ContainerId
            INNER JOIN masterdata.Ports f     ON f.Id = m.FromPlaceId
            WHERE mc.MovementId = m.Id AND p.Fits = 0
            ORDER BY c.ContainerRef)) END AS NVARCHAR(400)),
       StartNotBefore = nb.EndDate, StartNotBeforeMovementNo = nb.MovementNo, StartNotBeforePlaceName = nb.PlaceName
FROM logistics.Movements m
OUTER APPLY (SELECT TOP (1) pm.EndDate, pm.MovementNo, PlaceName = tp.PortName
             FROM logistics.MovementContainers mc
             INNER JOIN logistics.fn_ContainerPlaceForMovement(m.Id) p ON p.ContainerId = mc.ContainerId
             INNER JOIN logistics.Movements pm ON pm.Id = p.PreviousMovementId
             INNER JOIN masterdata.Ports tp    ON tp.Id = pm.ToPlaceId
             WHERE mc.MovementId = m.Id AND pm.Status = 3 AND pm.EndDate IS NOT NULL
             ORDER BY pm.EndDate DESC, pm.Id DESC) nb
WHERE m.Id = @MovementId AND m.Status IN (1, 2);
GO

/* ================================================================== 1b. The place rules: never behind a leg already made */

-- Re-created (80) from the body of script 53: + a container that already travelled with a LATER movement (in progress
-- or completed) does not fit an older planned or in-progress one. "Previous" is the movement with the highest Id BELOW
-- @MovementId, so on an older movement the container was judged by a leg it had long finished: it could be added to it
-- and started from a place it had already left, two journeys at once. Save (70015), Start (70015), the movement page's
-- picker and Start's reason on the lists (fn_Movement_StartBlock) all read this one function. A LATER movement only
-- planned still fits (planning ahead), and a completed or cancelled @MovementId is never judged (its history stays).
-- One row per container for a movement (@MovementId NULL = a new one) leaving @FromPlaceId for @ToPlaceId with the
-- type @MovementTypeId: where the container is (its previous movement's To, else its port of loading), whether it
-- fits the movement and why not. Note only on a container that never moved and fits.
CREATE OR ALTER FUNCTION logistics.fn_ContainerFitForMovement (@MovementId INT, @FromPlaceId INT, @ToPlaceId INT, @MovementTypeId INT)
RETURNS TABLE
AS
RETURN
SELECT p.ContainerId, p.PreviousMovementId, p.PreviousMovementNo, p.PreviousStatus,
       PlaceId   = CASE WHEN p.PreviousMovementId IS NULL THEN p.PortOfLoadingId ELSE p.PlaceId END,
       PlaceName = CASE WHEN p.PreviousMovementId IS NULL THEN p.PortOfLoadingName ELSE p.PlaceName END,
       p.PortOfLoadingId, p.PortOfLoadingName, s.IsOrigin,
       Fits = CAST(CASE WHEN r.Reason IS NULL THEN 1 ELSE 0 END AS BIT),
       r.Reason,
       Note = CAST(CASE WHEN r.Reason IS NULL AND p.PreviousMovementId IS NULL
                        THEN ISNULL(N'Not moved yet - port of loading: ' + p.PortOfLoadingName + N'.',
                                    N'No port of loading on this container: check it.') END AS NVARCHAR(200))
FROM logistics.fn_ContainerPlaceForMovement(@MovementId) p
CROSS JOIN (SELECT IsOrigin = CAST(CASE WHEN EXISTS (SELECT 1 FROM masterdata.MovementTypes t
                                                     WHERE t.Id = @MovementTypeId AND t.Stage = N'Origin') THEN 1 ELSE 0 END AS BIT),
                   FromName = (SELECT f.PortName FROM masterdata.Ports f WHERE f.Id = @FromPlaceId)) s
-- (80) the latest movement it started or made after this one (only while this one is planned or in progress)
OUTER APPLY (SELECT TOP (1) lm.MovementNo, LegFrom = lf.PortName, LegTo = lt.PortName
             FROM logistics.MovementContainers lc
             INNER JOIN logistics.Movements lm ON lm.Id = lc.MovementId
             INNER JOIN masterdata.Ports lf    ON lf.Id = lm.FromPlaceId
             INNER JOIN masterdata.Ports lt    ON lt.Id = lm.ToPlaceId
             WHERE lc.ContainerId = p.ContainerId AND lm.Id > @MovementId AND lm.Status IN (2, 3)
               AND EXISTS (SELECT 1 FROM logistics.Movements om WHERE om.Id = @MovementId AND om.Status IN (1, 2))
             ORDER BY lm.Id DESC) ll
CROSS APPLY (SELECT Reason = CAST(CASE
                 WHEN ll.MovementNo IS NOT NULL                                                      -- (80)
                     THEN N'Already travelled further with ' + ll.MovementNo + N' (' + ll.LegFrom + N' ' + NCHAR(8594) + N' '
                          + ll.LegTo + N'), a later movement: take it off this one.'
                 WHEN p.PreviousMovementId IS NOT NULL AND s.IsOrigin = 1
                     THEN N'Loading at the supplier is only for containers that have not moved yet.'
                 WHEN p.PreviousMovementId IS NOT NULL AND p.PlaceId <> @FromPlaceId
                     THEN N'At ' + p.PlaceName + N' (end of ' + p.PreviousMovementNo + N'), not at ' + s.FromName + N'.'
                 WHEN p.PreviousMovementId IS NULL AND p.PortOfLoadingId <> @FromPlaceId
                      AND NOT (s.IsOrigin = 1 AND p.PortOfLoadingId = ISNULL(@ToPlaceId, 0))
                     THEN N'Not moved yet: it starts from its port of loading ' + p.PortOfLoadingName + N'.' END
             AS NVARCHAR(300))) r;
GO

/* ================================================================== 2. Where a container is, and its movements */

-- One row per container. "Previous" keeps the meaning of fn_ContainerPlaceForMovement: the movement NOT cancelled with
-- the highest Id. Place = the To of that movement (planned, in progress or completed), else the port of loading of a
-- container that never moved (NULL when it has none: any From fits it). PlaceSince = its end date once completed.
-- Active = the movement in progress that carries it (one at most: 70012). Planned = its next planned movement (the
-- lowest Id ABOVE the latest movement it started or made: an older planned one would send it back to a place it has
-- left, and fn_ContainerFitForMovement refuses it), with why it cannot start yet and its earliest start
-- (fn_Movement_StartBlock). Last = its last completed movement. The API makes the next step of it
-- (ContainerStatusFlags.ShipStep).
CREATE OR ALTER FUNCTION logistics.fn_Container_ShipState (@ContainerId INT)
RETURNS TABLE
AS
RETURN
SELECT c.Id AS ContainerId,
       MovementCount = ISNULL(n.Cnt, 0),
       PlaceId   = CASE WHEN lm.Id IS NULL THEN c.PortOfLoadingId ELSE lm.ToPlaceId END,
       PlaceName = CASE WHEN lm.Id IS NULL THEN pl.PortName ELSE lp.PortName END,
       PlaceSince = CASE WHEN lm.Status = 3 THEN lm.EndDate END,
       ActiveMovementId = ip.Id, ActiveMovementNo = ip.MovementNo, ActiveMovementTypeName = ip.TypeName,
       ActiveMovementStage = ip.Stage, ActiveMovementFromName = ip.FromName, ActiveMovementToName = ip.ToName,
       ActiveMovementStartDate = ip.StartDate, ActiveMovementEta = ip.Eta, ActiveMovementContainerCount = ip.Cnt,
       PlannedMovementId = np.Id, PlannedMovementNo = np.MovementNo, PlannedMovementTypeName = np.TypeName,
       PlannedMovementStage = np.Stage, PlannedMovementFromName = np.FromName, PlannedMovementToName = np.ToName,
       PlannedMovementDate = np.PlannedDate, PlannedMovementContainerCount = np.Cnt,
       PlannedMovementBlockedReason = sb.Reason, PlannedMovementNotBefore = sb.StartNotBefore,
       LastMovementId = lc.Id, LastMovementNo = lc.MovementNo, LastMovementEndDate = lc.EndDate
FROM logistics.Containers c
LEFT JOIN masterdata.Ports pl ON pl.Id = c.PortOfLoadingId
OUTER APPLY (SELECT Cnt = COUNT(*)
             FROM logistics.MovementContainers mc
             INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
             WHERE mc.ContainerId = c.Id AND m.Status <> 4) n
OUTER APPLY (SELECT TOP (1) m.Id, m.Status, m.ToPlaceId, m.EndDate
             FROM logistics.MovementContainers mc
             INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
             WHERE mc.ContainerId = c.Id AND m.Status <> 4
             ORDER BY m.Id DESC) lm
LEFT JOIN masterdata.Ports lp ON lp.Id = lm.ToPlaceId
OUTER APPLY (SELECT MaxId = MAX(m.Id)
             FROM logistics.MovementContainers mc
             INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
             WHERE mc.ContainerId = c.Id AND m.Status IN (2, 3)) ls
OUTER APPLY (SELECT TOP (1) m.Id, m.MovementNo, mt.TypeName, mt.Stage, FromName = fp.PortName, ToName = tp.PortName,
                    m.StartDate, m.Eta,
                    Cnt = (SELECT COUNT(*) FROM logistics.MovementContainers x WHERE x.MovementId = m.Id)
             FROM logistics.MovementContainers mc
             INNER JOIN logistics.Movements m       ON m.Id = mc.MovementId
             INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
             INNER JOIN masterdata.Ports fp         ON fp.Id = m.FromPlaceId
             INNER JOIN masterdata.Ports tp         ON tp.Id = m.ToPlaceId
             WHERE mc.ContainerId = c.Id AND m.Status = 2
             ORDER BY m.Id DESC) ip
OUTER APPLY (SELECT TOP (1) m.Id, m.MovementNo, mt.TypeName, mt.Stage, FromName = fp.PortName, ToName = tp.PortName,
                    m.PlannedDate,
                    Cnt = (SELECT COUNT(*) FROM logistics.MovementContainers x WHERE x.MovementId = m.Id)
             FROM logistics.MovementContainers mc
             INNER JOIN logistics.Movements m       ON m.Id = mc.MovementId
             INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
             INNER JOIN masterdata.Ports fp         ON fp.Id = m.FromPlaceId
             INNER JOIN masterdata.Ports tp         ON tp.Id = m.ToPlaceId
             WHERE mc.ContainerId = c.Id AND m.Status = 1 AND m.Id > ISNULL(ls.MaxId, 0)
             ORDER BY m.Id ASC) np
OUTER APPLY logistics.fn_Movement_StartBlock(np.Id) sb
OUTER APPLY (SELECT TOP (1) m.Id, m.MovementNo, m.EndDate
             FROM logistics.MovementContainers mc
             INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
             WHERE mc.ContainerId = c.Id AND m.Status = 3
             ORDER BY m.Id DESC) lc
WHERE c.Id = @ContainerId;
GO


/* ================================================================== 3. The container list: the shipment of each row */

-- Re-created (80) from the body of script 78: + the ship state of each container (fn_Container_ShipState), so the row's
-- "..." menu offers its next step and the Movement column shows a planned next movement. Nothing else changes.
CREATE OR ALTER PROCEDURE logistics.usp_Container_Search
    @Search              NVARCHAR(100) = NULL,   -- ref, container no., B/L, vessel, PO / PI no., commercial invoice, supplier
    @ContainerRef        NVARCHAR(30)  = NULL,
    @ContainerNo         NVARCHAR(20)  = NULL,
    @SupplierId          INT           = NULL,
    @PurchaseDocumentId  INT           = NULL,   -- a purchase ORDER or a purchase INVOICE linked to the container
    @PurchaseOrderId     INT           = NULL,   -- containers carrying lines of this order
    @CommercialInvoiceNo NVARCHAR(50)  = NULL,
    @ItemId              INT           = NULL,
    @BlNo                NVARCHAR(30)  = NULL,
    @Status              TINYINT       = NULL,
    @PortId              INT           = NULL,
    @WarehouseId         INT           = NULL,
    @BranchId            INT           = NULL,
    @MovementId          INT           = NULL,   -- containers of this movement
    @OrderMonthKey       INT           = NULL,   -- e.g. 202601
    @DateFrom            DATE          = NULL,   -- order date
    @DateTo              DATE          = NULL,
    @SortColumn          NVARCHAR(30)  = N'OrderDate',  -- ContainerRef | ContainerNo | OrderDate | DispatchDate | Eta | Status | CreatedAtUtc
    @SortDirection       NVARCHAR(4)   = N'DESC',
    @PageNumber          INT           = 1,
    @PageSize            INT           = 10,
    @DeliveredNotReceived BIT          = 0       -- (65) 1 = delivered (or with a draft receipt) and not received yet
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    -- (78) PAGES OF UP TO 5,000 (200 before): every container's figures are worked out before the OFFSET, so each page
    -- costs about the whole search - the 2,000 containers of one order took ten calls of 2 s each. The order's Containers
    -- card and a movement's list now ask for them in one page; the grids keep asking for pages of 200 or less.
    IF @PageSize > 5000 SET @PageSize = 5000;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @ContainerRef = NULLIF(LTRIM(RTRIM(@ContainerRef)), N'');
    SET @ContainerNo = NULLIF(LTRIM(RTRIM(@ContainerNo)), N'');
    SET @CommercialInvoiceNo = NULLIF(LTRIM(RTRIM(@CommercialInvoiceNo)), N'');
    SET @BlNo = NULLIF(LTRIM(RTRIM(@BlNo)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'ContainerRef', N'ContainerNo', N'OrderDate', N'DispatchDate', N'Eta', N'Status', N'CreatedAtUtc')
        SET @SortColumn = N'OrderDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT c.Id, c.ContainerRef, c.ContainerNo, ct.TypeCode AS ContainerTypeCode, ct.TypeName AS ContainerTypeName,
           c.OrderDate, c.OrderMonthKey, OrderMonth = FORMAT(c.OrderDate, N'MMM-yyyy', N'en-US'),
           c.BranchId, b.BranchCode, b.BranchName, c.WarehouseId, w.WarehouseCode, w.WarehouseName,
           c.PurchaseOrderId, mpo.DocumentNumber AS PurchaseOrderNumber,
           OrderCount = ISNULL(po.OrderCount, 0),
           OrderNumbers = CASE WHEN ISNULL(po.OrderCount, 0) = 0 THEN NULL
                               WHEN po.OrderCount = 1 THEN po.FirstOrder
                               ELSE po.FirstOrder + N' +' + CAST(po.OrderCount - 1 AS NVARCHAR(10)) END,
           SupplierCount = ISNULL(po.SupplierCount, 0),
           SupplierNames = CASE WHEN ISNULL(po.SupplierCount, 0) = 0 THEN NULL
                                WHEN po.SupplierCount = 1 THEN po.FirstSupplier
                                ELSE po.FirstSupplier + N' +' + CAST(po.SupplierCount - 1 AS NVARCHAR(10)) END,
           InvoiceCount = ISNULL(inv.InvoiceCount, 0),
           InvoiceNumbers = CASE WHEN ISNULL(inv.InvoiceCount, 0) = 0 THEN NULL
                                 WHEN inv.InvoiceCount = 1 THEN inv.FirstInvoice
                                 ELSE inv.FirstInvoice + N' +' + CAST(inv.InvoiceCount - 1 AS NVARCHAR(10)) END,
           CommercialInvoiceNos = CASE WHEN inv.CiCount = 1 THEN inv.FirstCi
                                       WHEN inv.CiCount > 1 THEN inv.FirstCi + N' +' + CAST(inv.CiCount - 1 AS NVARCHAR(10)) END,
           ExporterReferences = CASE WHEN inv.ErCount = 1 THEN inv.FirstEr
                                     WHEN inv.ErCount > 1 THEN inv.FirstEr + N' +' + CAST(inv.ErCount - 1 AS NVARCHAR(10)) END,
           ItemCount = ISNULL(ln.ItemCount, 0),
           ItemSummary = CASE WHEN ISNULL(ln.ItemCount, 0) = 0 THEN NULL
                              WHEN ln.ItemCount = 1 THEN ln.FirstItem
                              ELSE N'Mixed - ' + CAST(ln.ItemCount AS NVARCHAR(10)) + N' items' END,
           TotalQtyBase = ISNULL(ln.Qty, 0),
           InvoicedQtyBase = ISNULL(inv.PostedQty, 0),
           InvoicingStatus = CASE WHEN ISNULL(inv.PostedQty, 0) = 0 THEN 0
                                  WHEN inv.PostedQty >= ISNULL(ln.Qty, 0) THEN 2 ELSE 1 END,     -- 0 none, 1 partly, 2 fully (posted)
           TotalReceivedBase = c.TotalReceivedBase, c.TotalOilQty,
           fl.FillPct, fl.CapacityKnown, fl.MissingContainerUnitItems, fl.RemainingPcs, fl.IsOverCapacity,
           c.BlNo, c.BlDate, c.DispatchDate, c.Eta, c.ActualPortArrival, c.CustomsReleaseDate, c.OffloadedDate,
           c.FreeDays, c.LastFreeDay,
           DaysAtPort = CASE WHEN c.ActualPortArrival IS NOT NULL      -- (65) up to the receipt, else the Delivery, else today
                             THEN DATEDIFF(DAY, c.ActualPortArrival, COALESCE(c.OffloadedDate, dl.EndDate, CAST(SYSUTCDATETIME() AS DATE))) END,
           c.CurrentLocation, c.Status, c.StatusNote,
           CurrentMovementId = mv.Id, CurrentMovementNo = mv.MovementNo, CurrentMovementStatus = mv.Status,
           ChargesPostedBase = ISNULL(chg.Posted, 0), ChargesDraftBase = ISNULL(chg.Draft, 0),
           AttachmentCount = (SELECT COUNT(*) FROM logistics.ContainerAttachments a WHERE a.ContainerId = c.Id),
           pl.PortName AS PortOfLoadingName, pd.PortName AS PortOfDestinationName,
           c.CreatedAtUtc, c.CreatedBy, cu.FullName AS CreatedByName, c.UpdatedAtUtc, c.RowVersion,
           COUNT(*) OVER () AS TotalCount,
           -- (65) goods receipts
           rb.ReceivedBy, rb.GoodsReceiptId, rb.GoodsReceiptNumber, rb.GoodsReceiptStatus,
           DeliveredDate = dl.EndDate,
           CanReceive = CAST(CASE WHEN c.Status BETWEEN 2 AND 5 AND rb.GoodsReceiptId IS NULL THEN 1 ELSE 0 END AS BIT),
           CloseBlockedReason = cb.Reason,
           -- (80) the shipment (fn_Container_ShipState): where it is, the movement in progress carrying it, its next
           -- planned movement (why it cannot start yet, its earliest start) and its last completed one
           ss.MovementCount, ss.PlaceId, ss.PlaceName, ss.PlaceSince,
           ss.ActiveMovementId, ss.ActiveMovementNo, ss.ActiveMovementTypeName, ss.ActiveMovementStage,
           ss.ActiveMovementFromName, ss.ActiveMovementToName, ss.ActiveMovementStartDate, ss.ActiveMovementEta,
           ss.ActiveMovementContainerCount,
           ss.PlannedMovementId, ss.PlannedMovementNo, ss.PlannedMovementTypeName, ss.PlannedMovementStage,
           ss.PlannedMovementFromName, ss.PlannedMovementToName, ss.PlannedMovementDate, ss.PlannedMovementContainerCount,
           ss.PlannedMovementBlockedReason, ss.PlannedMovementNotBefore,
           ss.LastMovementId, ss.LastMovementNo, ss.LastMovementEndDate
    FROM logistics.Containers c
    INNER JOIN masterdata.ContainerTypes ct ON ct.Id = c.ContainerTypeId
    INNER JOIN masterdata.Branches b        ON b.Id = c.BranchId
    LEFT  JOIN masterdata.Warehouses w      ON w.Id = c.WarehouseId
    LEFT  JOIN masterdata.Ports pl          ON pl.Id = c.PortOfLoadingId
    LEFT  JOIN masterdata.Ports pd          ON pd.Id = c.PortOfDestinationId
    LEFT  JOIN purchase.PurchaseDocuments mpo ON mpo.Id = c.PurchaseOrderId
    LEFT  JOIN security.Users cu            ON cu.Id = c.CreatedBy
    CROSS APPLY logistics.fn_ContainerFill(c.Id) fl
    CROSS APPLY logistics.fn_Container_ReceivedBy(c.Id) rb      -- (65) who received it; its open goods receipt
    OUTER APPLY logistics.fn_Container_LastDelivery(c.Id) dl    -- (65) its latest completed Delivery
    OUTER APPLY (SELECT b.Reason FROM logistics.fn_Container_CloseBlock(c.Id) b WHERE c.Status = 6) cb  -- (65) why not Close
    CROSS APPLY logistics.fn_Container_ShipState(c.Id) ss       -- (80) the shipment
    OUTER APPLY (SELECT OrderCount = COUNT(DISTINCT cl.PurchaseOrderId), SupplierCount = COUNT(DISTINCT d.SupplierId),
                        FirstOrder = MIN(d.DocumentNumber), FirstSupplier = MIN(sp.PartyName)
                 FROM logistics.ContainerLines cl
                 INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                 INNER JOIN masterdata.Parties sp        ON sp.Id = d.SupplierId
                 WHERE cl.ContainerId = c.Id) po
    OUTER APPLY (SELECT InvoiceCount = COUNT(DISTINCT d.Id),
                        CiCount = COUNT(DISTINCT d.CommercialInvoiceNo), ErCount = COUNT(DISTINCT d.ExporterReference),
                        FirstInvoice = MIN(d.DocumentNumber), FirstCi = MIN(d.CommercialInvoiceNo), FirstEr = MIN(d.ExporterReference),
                        PostedQty = SUM(CASE WHEN d.Status IN (2, 4) THEN pil.QuantityBase ELSE 0 END)
                 FROM logistics.ContainerLines cl
                 INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
                 INNER JOIN purchase.PurchaseDocuments d        ON d.Id = pil.DocumentId
                 WHERE cl.ContainerId = c.Id AND d.Status <> 3) inv
    OUTER APPLY (SELECT ItemCount = COUNT(DISTINCT cl.ItemId), Qty = SUM(cl.QuantityBase), FirstItem = MIN(i.ItemName)
                 FROM logistics.ContainerLines cl
                 INNER JOIN inventory.Items i ON i.Id = cl.ItemId
                 WHERE cl.ContainerId = c.Id) ln
    OUTER APPLY (SELECT Posted = SUM(CASE WHEN ch.Status = 2 THEN ch.AmountBase END),
                        Draft  = SUM(CASE WHEN ch.Status = 1 THEN ch.AmountBase END)
                 FROM logistics.ContainerCharges ch WHERE ch.ContainerId = c.Id) chg
    OUTER APPLY (SELECT TOP (1) m.Id, m.MovementNo, m.Status
                 FROM logistics.MovementContainers mc
                 INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
                 WHERE mc.ContainerId = c.Id AND m.Status IN (2, 3)
                 ORDER BY CASE WHEN m.Status = 2 THEN 0 ELSE 1 END, COALESCE(m.EndDate, m.StartDate) DESC, m.Id DESC) mv
    WHERE (@Search IS NULL OR c.ContainerRef LIKE N'%' + @Search + N'%' OR c.ContainerNo LIKE N'%' + @Search + N'%'
           OR c.BlNo LIKE N'%' + @Search + N'%' OR c.VesselName LIKE N'%' + @Search + N'%'
           OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                      INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                      INNER JOIN masterdata.Parties sp        ON sp.Id = d.SupplierId
                      WHERE cl.ContainerId = c.Id AND (d.DocumentNumber LIKE N'%' + @Search + N'%' OR sp.PartyName LIKE N'%' + @Search + N'%'))
           OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                      INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
                      INNER JOIN purchase.PurchaseDocuments d        ON d.Id = pil.DocumentId
                      WHERE cl.ContainerId = c.Id AND d.Status <> 3
                        AND (d.DocumentNumber LIKE N'%' + @Search + N'%' OR d.CommercialInvoiceNo LIKE N'%' + @Search + N'%'
                             OR d.ExporterReference LIKE N'%' + @Search + N'%')))
      AND (@ContainerRef IS NULL OR c.ContainerRef LIKE N'%' + @ContainerRef + N'%')
      AND (@ContainerNo IS NULL OR c.ContainerNo LIKE N'%' + @ContainerNo + N'%')
      AND (@BlNo IS NULL OR c.BlNo LIKE N'%' + @BlNo + N'%')
      AND (@Status IS NULL OR c.Status = @Status)
      AND (@BranchId IS NULL OR c.BranchId = @BranchId)
      AND (@WarehouseId IS NULL OR c.WarehouseId = @WarehouseId)
      AND (@PortId IS NULL OR c.PortOfLoadingId = @PortId OR c.PortOfDestinationId = @PortId OR c.FinalDestinationId = @PortId)
      AND (@OrderMonthKey IS NULL OR c.OrderMonthKey = @OrderMonthKey)
      AND (@DateFrom IS NULL OR c.OrderDate >= @DateFrom)
      AND (@DateTo IS NULL OR c.OrderDate <= @DateTo)
      AND (@SupplierId IS NULL OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                                          INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                                          WHERE cl.ContainerId = c.Id AND d.SupplierId = @SupplierId))
      AND (@PurchaseOrderId IS NULL OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl WHERE cl.ContainerId = c.Id AND cl.PurchaseOrderId = @PurchaseOrderId))
      AND (@PurchaseDocumentId IS NULL
           OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl WHERE cl.ContainerId = c.Id AND cl.PurchaseOrderId = @PurchaseDocumentId)
           OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                      INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
                      WHERE cl.ContainerId = c.Id AND pil.DocumentId = @PurchaseDocumentId))
      AND (@CommercialInvoiceNo IS NULL OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                                                   INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
                                                   INNER JOIN purchase.PurchaseDocuments d        ON d.Id = pil.DocumentId
                                                   WHERE cl.ContainerId = c.Id AND d.Status <> 3
                                                     AND d.CommercialInvoiceNo LIKE N'%' + @CommercialInvoiceNo + N'%'))
      AND (@ItemId IS NULL OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl WHERE cl.ContainerId = c.Id AND cl.ItemId = @ItemId))
      AND (@MovementId IS NULL OR EXISTS (SELECT 1 FROM logistics.MovementContainers mc WHERE mc.ContainerId = c.Id AND mc.MovementId = @MovementId))
      AND (ISNULL(@DeliveredNotReceived, 0) = 0
           OR (c.Status BETWEEN 2 AND 5 AND ISNULL(rb.ReceivedBy, N'') <> N'GRN'
               AND (dl.MovementId IS NOT NULL OR rb.GoodsReceiptStatus = 1)))
    ORDER BY
        -- (78) a ref sorts by its length first: KTG-2026-9999 before KTG-2026-10000 (numbers past NumberLength)
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'ContainerRef' THEN LEN(c.ContainerRef) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'ContainerRef' THEN LEN(c.ContainerRef) END DESC,
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'ContainerRef' THEN c.ContainerRef WHEN N'ContainerNo' THEN c.ContainerNo END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'ContainerRef' THEN c.ContainerRef WHEN N'ContainerNo' THEN c.ContainerNo END END DESC,
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'OrderDate' THEN c.OrderDate WHEN N'DispatchDate' THEN c.DispatchDate WHEN N'Eta' THEN c.Eta END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'OrderDate' THEN c.OrderDate WHEN N'DispatchDate' THEN c.DispatchDate WHEN N'Eta' THEN c.Eta END END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Status' THEN CAST(c.Status AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Status' THEN CAST(c.Status AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN c.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN c.CreatedAtUtc END DESC,
        c.OrderDate DESC, c.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

/* ================================================================== 4. The container page: its next step */

-- Re-created (80) from the body of script 65: + the ship state columns at the end of set 1 (the action bar's button,
-- the From of its next leg). The other sets are unchanged.
CREATE OR ALTER PROCEDURE logistics.usp_Container_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT c.Id, c.DocumentTypeId, c.ContainerRef, c.ContainerNo,
           c.ContainerTypeId, ct.TypeCode AS ContainerTypeCode, ct.TypeName AS ContainerTypeName,
           ct.MaxWeightKg, ct.MaxVolumeCbm,
           c.SealNo, c.CustomsSealNo, c.Description,
           c.OrderDate, c.OrderMonthKey, OrderMonth = FORMAT(c.OrderDate, N'MMM-yyyy', N'en-US'),
           c.ShippingMethod, c.CountryOfOrigin,
           c.PurchaseOrderId, mpo.DocumentNumber AS PurchaseOrderNumber, mpo.SupplierId AS PurchaseOrderSupplierId,
           mps.PartyName AS PurchaseOrderSupplierName,
           c.ForwarderId, fw.PartyName AS ForwarderName, c.TransporterId, tr.PartyName AS TransporterName,
           c.ShippingLine, c.VesselName, c.VoyageNo, c.BookingNo,
           c.PortOfLoadingId, pl.PortName AS PortOfLoadingName, pl.CountryCode AS PortOfLoadingCountry,
           c.PortOfDestinationId, pd.PortName AS PortOfDestinationName, pd.CountryCode AS PortOfDestinationCountry,
           c.FinalDestinationId, fd.PortName AS FinalDestinationName,
           c.DispatchDate, c.Eta, c.FreeDays, c.LastFreeDay, c.GrossWeightKg, c.VolumeCbm, c.Packages,
           c.BlNo, c.BlDate, c.BlNotes,
           c.TotalLines, c.TotalAllocatedBase, c.TotalReceivedBase, c.TotalOilQty,
           fl.FillPct, fl.CapacityKnown, fl.MissingContainerUnitItems, fl.RemainingPcs, fl.IsOverCapacity,
           c.BranchId, b.BranchCode, b.BranchName, c.WarehouseId, w.WarehouseCode, w.WarehouseName,
           c.TruckNo, c.WaybillNo, c.DeclarationNo, c.FeriNo,
           c.ActualPortArrival, c.BorderCrossingDate, c.CustomsReleaseDate,
           DaysAtPort = CASE WHEN c.ActualPortArrival IS NOT NULL      -- (65) up to the receipt, else the Delivery, else today
                             THEN DATEDIFF(DAY, c.ActualPortArrival, COALESCE(c.OffloadedDate, dl.EndDate, CAST(SYSUTCDATETIME() AS DATE))) END,
           c.OffloadedDate, c.OffloadedAtUtc, c.OffloadedBy, ou.FullName AS OffloadedByName,
           c.Status, c.StatusNote, c.CurrentLocation, c.Notes,
           c.DatesFromMovements,
           HasMovements = CAST(CASE WHEN EXISTS (SELECT 1 FROM logistics.MovementContainers mc
                                                 INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
                                                 WHERE mc.ContainerId = c.Id AND m.Status IN (2, 3)) THEN 1 ELSE 0 END AS BIT),
           InvoicedPostedBase = ISNULL(inv.Posted, 0), InvoicedDraftBase = ISNULL(inv.Draft, 0),
           IsFullyInvoiced = CAST(CASE WHEN c.TotalAllocatedBase > 0 AND NOT EXISTS
                                       (SELECT 1 FROM logistics.ContainerLines cl
                                        OUTER APPLY (SELECT Q = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                                                     INNER JOIN purchase.PurchaseDocuments pid ON pid.Id = pil.DocumentId
                                                     WHERE pil.ContainerLineId = cl.Id AND pid.Status IN (2, 4)) q
                                        WHERE cl.ContainerId = c.Id AND ISNULL(q.Q, 0) < cl.QuantityBase) THEN 1 ELSE 0 END AS BIT),
           ChargesPostedBase = ISNULL(chg.Posted, 0), ChargesDraftBase = ISNULL(chg.Draft, 0),
           ChargesLandedPostedBase = ISNULL(chg.LandedPosted, 0),
           FobTotalBase = cost.Fob, LandedTotalBase = cost.Fob + ISNULL(chg.LandedPosted, 0),
           c.ConfirmedAtUtc, c.ConfirmedBy, fu.FullName AS ConfirmedByName,
           c.ClosedAtUtc, c.ClosedBy, ku.FullName AS ClosedByName,
           c.CancelledAtUtc, c.CancelledBy, xu.FullName AS CancelledByName, c.CancelReason,
           c.CreatedAtUtc, c.CreatedBy, cu.FullName AS CreatedByName,
           c.UpdatedAtUtc, c.UpdatedBy, uu.FullName AS UpdatedByName, c.RowVersion,
           -- (65) goods receipts
           rb.ReceivedBy,
           rb.GoodsReceiptId, rb.GoodsReceiptNumber, rb.GoodsReceiptStatus,
           GoodsReceiptDate = gr.DocumentDate, GoodsReceiptIsAuto = gr.IsAuto,
           GoodsReceiptWarehouseId = gr.WarehouseId, GoodsReceiptWarehouseCode = gw.WarehouseCode,
           GoodsReceiptCreatedAtUtc = gr.CreatedAtUtc,
           DeliveredDate = dl.EndDate, DeliveryMovementId = dl.MovementId, DeliveryMovementNo = dl.MovementNo,
           DeliveryPlaceName = dl.PlaceName,
           CanReceive = CAST(CASE WHEN c.Status BETWEEN 2 AND 5 AND rb.GoodsReceiptId IS NULL THEN 1 ELSE 0 END AS BIT),
           CloseBlockedReason = cb.Reason,
           -- (80) the shipment (fn_Container_ShipState): where it is, the movement in progress carrying it, its next
           -- planned movement (why it cannot start yet, its earliest start) and its last completed one
           ss.MovementCount, ss.PlaceId, ss.PlaceName, ss.PlaceSince,
           ss.ActiveMovementId, ss.ActiveMovementNo, ss.ActiveMovementTypeName, ss.ActiveMovementStage,
           ss.ActiveMovementFromName, ss.ActiveMovementToName, ss.ActiveMovementStartDate, ss.ActiveMovementEta,
           ss.ActiveMovementContainerCount,
           ss.PlannedMovementId, ss.PlannedMovementNo, ss.PlannedMovementTypeName, ss.PlannedMovementStage,
           ss.PlannedMovementFromName, ss.PlannedMovementToName, ss.PlannedMovementDate, ss.PlannedMovementContainerCount,
           ss.PlannedMovementBlockedReason, ss.PlannedMovementNotBefore,
           ss.LastMovementId, ss.LastMovementNo, ss.LastMovementEndDate
    FROM logistics.Containers c
    INNER JOIN masterdata.ContainerTypes ct ON ct.Id = c.ContainerTypeId
    INNER JOIN masterdata.Branches b        ON b.Id = c.BranchId
    LEFT  JOIN masterdata.Warehouses w      ON w.Id = c.WarehouseId
    CROSS APPLY logistics.fn_ContainerFill(c.Id) fl
    CROSS APPLY logistics.fn_Container_ReceivedBy(c.Id) rb      -- (65) who received it; its open goods receipt
    OUTER APPLY logistics.fn_Container_LastDelivery(c.Id) dl    -- (65) its latest completed Delivery
    OUTER APPLY (SELECT b.Reason FROM logistics.fn_Container_CloseBlock(c.Id) b WHERE c.Status = 6) cb  -- (65) why not Close
    CROSS APPLY logistics.fn_Container_ShipState(c.Id) ss       -- (80) the shipment
    LEFT  JOIN purchase.GoodsReceipts gr    ON gr.Id = rb.GoodsReceiptId
    LEFT  JOIN masterdata.Warehouses gw     ON gw.Id = gr.WarehouseId
    LEFT  JOIN purchase.PurchaseDocuments mpo ON mpo.Id = c.PurchaseOrderId
    LEFT  JOIN masterdata.Parties mps       ON mps.Id = mpo.SupplierId
    LEFT  JOIN masterdata.Parties fw        ON fw.Id = c.ForwarderId
    LEFT  JOIN masterdata.Parties tr        ON tr.Id = c.TransporterId
    LEFT  JOIN masterdata.Ports pl          ON pl.Id = c.PortOfLoadingId
    LEFT  JOIN masterdata.Ports pd          ON pd.Id = c.PortOfDestinationId
    LEFT  JOIN masterdata.Ports fd          ON fd.Id = c.FinalDestinationId
    LEFT  JOIN security.Users ou ON ou.Id = c.OffloadedBy
    LEFT  JOIN security.Users fu ON fu.Id = c.ConfirmedBy
    LEFT  JOIN security.Users ku ON ku.Id = c.ClosedBy
    LEFT  JOIN security.Users xu ON xu.Id = c.CancelledBy
    LEFT  JOIN security.Users cu ON cu.Id = c.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = c.UpdatedBy
    OUTER APPLY (SELECT Posted = SUM(CASE WHEN d.Status IN (2, 4) THEN pil.QuantityBase END),
                        Draft  = SUM(CASE WHEN d.Status = 1 THEN pil.QuantityBase END)
                 FROM logistics.ContainerLines cl
                 INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
                 INNER JOIN purchase.PurchaseDocuments d        ON d.Id = pil.DocumentId
                 WHERE cl.ContainerId = c.Id) inv
    OUTER APPLY (SELECT Posted = SUM(CASE WHEN ch.Status = 2 THEN ch.AmountBase END),
                        Draft  = SUM(CASE WHEN ch.Status = 1 THEN ch.AmountBase END),
                        LandedPosted = SUM(CASE WHEN ch.Status = 2 AND ch.IncludeInLandedCost = 1 THEN ch.AmountBase END)
                 FROM logistics.ContainerCharges ch WHERE ch.ContainerId = c.Id) chg
    OUTER APPLY (SELECT Fob = SUM(CAST(ISNULL(cl.ReceivedQuantityBase, cl.QuantityBase) AS DECIMAL(18,6)) * ISNULL(u.UnitFob, 0))
                 FROM logistics.ContainerLines cl
                 OUTER APPLY (SELECT UnitFob = COALESCE(cl.FobCostBase,
                                                        (SELECT SUM(pil.LineTotal / pid.ExchangeRate) / NULLIF(SUM(pil.QuantityBase), 0)
                                                         FROM purchase.PurchaseDocumentLines pil
                                                         INNER JOIN purchase.PurchaseDocuments pid ON pid.Id = pil.DocumentId
                                                         WHERE pil.ContainerLineId = cl.Id AND pid.Status IN (1, 2, 4)),
                                                        (SELECT pol.LineTotal / pod.ExchangeRate / NULLIF(pol.QuantityBase, 0)
                                                         FROM purchase.PurchaseDocumentLines pol
                                                         INNER JOIN purchase.PurchaseDocuments pod ON pod.Id = pol.DocumentId
                                                         WHERE pol.Id = cl.PoLineId))) u
                 WHERE cl.ContainerId = c.Id) cost
    WHERE c.Id = @Id;

    -- 2: lines. FOB per unit: once the goods are received the container line's value (frozen by an offload of before; set by
    -- the goods receipt and moved by the invoices since), else the invoices (posted or draft), else the order price.
    SELECT cl.Id, cl.ContainerId, cl.LineNumber,
           cl.PurchaseOrderId, po.DocumentNumber AS PurchaseOrderNumber, po.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName,
           cl.PoLineId, pol.LineNumber AS PoLineNumber,
           cl.ItemId, i.ItemCode, i.ItemName, i.Model, br.BrandName,
           cl.ItemUnitId, ut.UnitTypeName, cl.PackingFormula,
           PoUnitTypeName = pt.UnitTypeName, PoPackingFormula = pol.PackingFormula,
           PcsPerContainer = ipc.PcsPerContainer,
           cl.Quantity, cl.QuantityBase, cl.OilIncluded, cl.OilQtyPerUnit, cl.TotalOilQty,
           OrderedBase = pol.QuantityBase,
           LoadedElsewhereBase = ISNULL(oth.Qty, 0),
           InvoicedPostedBase = ISNULL(inv.Posted, 0), InvoicedDraftBase = ISNULL(inv.Draft, 0),
           AvailableToInvoiceBase = cl.QuantityBase - ISNULL(inv.Posted, 0) - ISNULL(inv.Draft, 0),
           InvoiceNumbers = inv.Numbers,
           cl.ReceivedQuantityBase, cl.VarianceReason, cl.Notes,
           UnitFobBase = COALESCE(cl.FobCostBase, inv.UnitValue, pol.LineTotal / po.ExchangeRate / NULLIF(pol.QuantityBase, 0)),
           FobSource = CASE WHEN cl.FobCostBase IS NOT NULL THEN N'Received' WHEN inv.UnitValue IS NOT NULL THEN N'Invoice' ELSE N'Order' END,
           cl.FobCostBase, cl.ChargesBase,
           DraftChargesBase = ISNULL(dch.Draft, 0),
           ChargesPerUnitBase = cl.ChargesBase / NULLIF(ISNULL(cl.ReceivedQuantityBase, cl.QuantityBase), 0),
           LandedCostBase = COALESCE(cl.LandedCostBase,
                                     COALESCE(inv.UnitValue, pol.LineTotal / po.ExchangeRate / NULLIF(pol.QuantityBase, 0))
                                     + cl.ChargesBase / NULLIF(cl.QuantityBase, 0)),
           IsLandedFinal = CAST(CASE WHEN cl.LandedCostBase IS NOT NULL THEN 1 ELSE 0 END AS BIT),
           i.WeightKg, i.VolumeCbm
    FROM logistics.ContainerLines cl
    INNER JOIN purchase.PurchaseDocuments po     ON po.Id = cl.PurchaseOrderId
    INNER JOIN masterdata.Parties sp             ON sp.Id = po.SupplierId
    INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = cl.PoLineId
    INNER JOIN inventory.ItemUnits piu           ON piu.Id = pol.ItemUnitId
    INNER JOIN masterdata.UnitTypes pt           ON pt.Id = piu.UnitTypeId
    INNER JOIN inventory.Items i                 ON i.Id = cl.ItemId
    INNER JOIN masterdata.Brands br              ON br.Id = i.BrandId
    INNER JOIN inventory.ItemUnits iu            ON iu.Id = cl.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut           ON ut.Id = iu.UnitTypeId
    CROSS APPLY logistics.fn_ItemPcsPerContainer(cl.ItemId) ipc
    OUTER APPLY (SELECT Qty = SUM(o.QuantityBase) FROM logistics.ContainerLines o
                 INNER JOIN logistics.Containers oc ON oc.Id = o.ContainerId
                 WHERE o.PoLineId = cl.PoLineId AND o.ContainerId <> cl.ContainerId AND oc.Status <> 8) oth
    OUTER APPLY (SELECT Posted = SUM(CASE WHEN d.Status IN (2, 4) THEN pil.QuantityBase END),
                        Draft  = SUM(CASE WHEN d.Status = 1 THEN pil.QuantityBase END),
                        UnitValue = SUM(pil.LineTotal / d.ExchangeRate) / NULLIF(SUM(pil.QuantityBase), 0),
                        Numbers = STRING_AGG(d.DocumentNumber, N', ')
                 FROM purchase.PurchaseDocumentLines pil
                 INNER JOIN purchase.PurchaseDocuments d ON d.Id = pil.DocumentId
                 WHERE pil.ContainerLineId = cl.Id AND d.Status <> 3) inv
    OUTER APPLY (SELECT Draft = SUM(a.AmountBase) FROM logistics.ContainerChargeAllocations a
                 INNER JOIN logistics.ContainerCharges ch ON ch.Id = a.ChargeId
                 WHERE a.ContainerLineId = cl.Id AND ch.Status = 1) dch
    WHERE cl.ContainerId = @Id
    ORDER BY cl.LineNumber;

    -- 3: invoices of the container (derived from the invoice lines)
    SELECT d.Id AS PurchaseDocumentId, d.DocumentNumber, d.DocumentDate, d.Status AS InvoiceStatus, d.ReceiptMode,
           d.SourceDocumentId AS PurchaseOrderId, po.DocumentNumber AS PurchaseOrderNumber,
           d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName,
           d.CurrencyId, cur.CurrencyCode, cur.Symbol AS CurrencySymbol, d.ExchangeRate,
           d.SupplierReference, d.ExporterReference, d.CommercialInvoiceNo,
           QtyInContainerBase = SUM(pil.QuantityBase),
           AmountInContainer = SUM(pil.LineTotal),
           AmountInContainerBase = SUM(pil.LineTotal / d.ExchangeRate),
           d.TotalAmount, d.TotalAmountBase
    FROM logistics.ContainerLines cl
    INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
    INNER JOIN purchase.PurchaseDocuments d        ON d.Id = pil.DocumentId
    INNER JOIN masterdata.Parties sp               ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies cur           ON cur.Id = d.CurrencyId
    LEFT  JOIN purchase.PurchaseDocuments po       ON po.Id = d.SourceDocumentId
    WHERE cl.ContainerId = @Id AND d.Status <> 3
    GROUP BY d.Id, d.DocumentNumber, d.DocumentDate, d.Status, d.ReceiptMode, d.SourceDocumentId, po.DocumentNumber,
             d.SupplierId, sp.PartyCode, sp.PartyName, d.CurrencyId, cur.CurrencyCode, cur.Symbol, d.ExchangeRate,
             d.SupplierReference, d.ExporterReference, d.CommercialInvoiceNo, d.TotalAmount, d.TotalAmountBase
    ORDER BY d.DocumentDate, d.Id;

    -- 4: movements of the container (the route), oldest first
    SELECT m.Id AS MovementId, m.MovementNo, m.MovementTypeId, mt.TypeCode, mt.TypeName, mt.Stage,
           m.FromPlaceId, fp.PortCode AS FromCode, fp.PortName AS FromName, fp.CountryCode AS FromCountry, fp.Kind AS FromKind,
           m.ToPlaceId, tp.PortCode AS ToCode, tp.PortName AS ToName, tp.CountryCode AS ToCountry, tp.Kind AS ToKind,
           m.PlannedDate, m.StartDate, m.Eta, m.EndDate, m.Status,
           m.CarrierPartyId, cp.PartyName AS CarrierName, m.VehicleOrVessel, m.VoyageNo, m.Reference, m.Notes,
           ContainerCount = (SELECT COUNT(*) FROM logistics.MovementContainers x WHERE x.MovementId = m.Id),
           ChargesBase = (SELECT SUM(ch.AmountBase) FROM logistics.ContainerCharges ch
                          WHERE ch.ContainerId = @Id AND ch.MovementId = m.Id AND ch.Status = 2),
           AttachmentCount = (SELECT COUNT(*) FROM logistics.ContainerAttachments a WHERE a.ContainerId = @Id AND a.MovementId = m.Id)
    FROM logistics.MovementContainers mc
    INNER JOIN logistics.Movements m       ON m.Id = mc.MovementId
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    INNER JOIN masterdata.Ports fp         ON fp.Id = m.FromPlaceId
    INNER JOIN masterdata.Ports tp         ON tp.Id = m.ToPlaceId
    LEFT  JOIN masterdata.Parties cp       ON cp.Id = m.CarrierPartyId
    WHERE mc.ContainerId = @Id
    ORDER BY CASE m.Status WHEN 4 THEN 1 ELSE 0 END, COALESCE(m.StartDate, m.PlannedDate, CAST(m.CreatedAtUtc AS DATE)), m.Id;

    -- 5: charges of the container
    SELECT ch.Id, ch.ContainerId, ch.MovementId, m.MovementNo, ch.GroupId,
           GroupSize = CASE WHEN ch.GroupId IS NULL THEN 1 ELSE (SELECT COUNT(*) FROM logistics.ContainerCharges g WHERE g.GroupId = ch.GroupId) END,
           ch.ChargeTypeId, t.ChargeCode, t.ChargeName, ch.Description, ch.ProviderPartyId, pp.PartyName AS ProviderName, ch.Reference,
           ch.ChargeDate, ch.CurrencyId, cur.CurrencyCode, ch.RateType, ch.ExchangeRate, ch.Amount, ch.AmountBase,
           ch.AllocationMethod, ch.IncludeInLandedCost, ch.Status, ch.AppliedAtOffload, ch.AdjustedAfterOffload,
           AllocatedBase = (SELECT SUM(a.AmountBase) FROM logistics.ContainerChargeAllocations a WHERE a.ChargeId = ch.Id),
           AttachmentCount = (SELECT COUNT(*) FROM logistics.ContainerAttachments a WHERE a.ChargeId = ch.Id),
           ch.Notes, ch.PostedAtUtc, pu.FullName AS PostedByName, ch.CancelledAtUtc, ch.CancelReason,
           ch.CreatedAtUtc, cu.FullName AS CreatedByName, ch.RowVersion
    FROM logistics.ContainerCharges ch
    INNER JOIN purchase.ChargeTypes t    ON t.Id = ch.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = ch.CurrencyId
    LEFT  JOIN masterdata.Parties pp     ON pp.Id = ch.ProviderPartyId
    LEFT  JOIN logistics.Movements m     ON m.Id = ch.MovementId
    LEFT  JOIN security.Users pu         ON pu.Id = ch.PostedBy
    LEFT  JOIN security.Users cu         ON cu.Id = ch.CreatedBy
    WHERE ch.ContainerId = @Id
    ORDER BY ch.ChargeDate, ch.Id;

    -- 6: how every charge is divided over the lines (the real cost of each item)
    SELECT a.ChargeId, a.ContainerLineId, cl.LineNumber, cl.ItemId, i.ItemCode, i.ItemName,
           a.Basis, a.AmountBase, a.IsManual,
           PerUnitBase = a.AmountBase / NULLIF(ISNULL(cl.ReceivedQuantityBase, cl.QuantityBase), 0)
    FROM logistics.ContainerChargeAllocations a
    INNER JOIN logistics.ContainerCharges ch ON ch.Id = a.ChargeId
    INNER JOIN logistics.ContainerLines cl   ON cl.Id = a.ContainerLineId
    INNER JOIN inventory.Items i             ON i.Id = cl.ItemId
    WHERE ch.ContainerId = @Id
    ORDER BY a.ChargeId, cl.LineNumber;

    -- 7: attachments (general, per movement, per charge); SharedWith = other containers holding the same file
    SELECT a.Id, a.ContainerId, a.MovementId, m.MovementNo, a.ChargeId, a.AttachmentTypeId, at.Category, at.SubType,
           a.FileId, f.FileName, f.ContentType, f.SizeBytes, a.Note, a.DocumentDate, a.GroupId,
           SharedWith = (SELECT COUNT(*) FROM logistics.ContainerAttachments s WHERE s.FileId = a.FileId AND s.Id <> a.Id),
           a.CreatedAtUtc, a.CreatedBy, u.FullName AS CreatedByName
    FROM logistics.ContainerAttachments a
    INNER JOIN logistics.Files f ON f.Id = a.FileId
    LEFT  JOIN masterdata.AttachmentTypes at ON at.Id = a.AttachmentTypeId
    LEFT  JOIN logistics.Movements m         ON m.Id = a.MovementId
    LEFT  JOIN security.Users u              ON u.Id = a.CreatedBy
    WHERE a.ContainerId = @Id
    ORDER BY a.CreatedAtUtc DESC, a.Id DESC;

    -- 8: audit
    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM logistics.ContainerAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.ContainerId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;
END
GO

/* ================================================================== 5. The movements: why a planned one cannot start yet */

-- Re-created (80) from the body of script 27: + StartBlockedReason and StartNotBefore (fn_Movement_StartBlock), for the
-- row's "Start..." action. Nothing else changes.
CREATE OR ALTER PROCEDURE logistics.usp_Movement_Search
    @Search         NVARCHAR(100) = NULL,   -- movement no., vessel / truck, voyage, reference, container ref / no.
    @Status         TINYINT       = NULL,
    @MovementTypeId INT           = NULL,
    @PlaceId        INT           = NULL,   -- from or to
    @ContainerId    INT           = NULL,
    @CarrierPartyId INT           = NULL,
    @DateFrom       DATE          = NULL,   -- start date, else planned date
    @DateTo         DATE          = NULL,
    @SortColumn     NVARCHAR(30)  = N'StartDate',   -- MovementNo | StartDate | Eta | EndDate | Status | CreatedAtUtc
    @SortDirection  NVARCHAR(4)   = N'DESC',
    @PageNumber     INT           = 1,
    @PageSize       INT           = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'MovementNo', N'StartDate', N'Eta', N'EndDate', N'Status', N'CreatedAtUtc') SET @SortColumn = N'StartDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);
    DECLARE @Today DATE = CAST(SYSUTCDATETIME() AS DATE);

    SELECT m.Id, m.MovementNo, m.MovementTypeId, mt.TypeCode, mt.TypeName, mt.Stage,
           m.FromPlaceId, fp.PortCode AS FromCode, fp.PortName AS FromName, fp.Kind AS FromKind,
           m.ToPlaceId, tp.PortCode AS ToCode, tp.PortName AS ToName, tp.Kind AS ToKind,
           m.PlannedDate, m.StartDate, m.Eta, m.EndDate, m.Status,
           m.CarrierPartyId, cp.PartyName AS CarrierName, m.VehicleOrVessel, m.VoyageNo, m.Reference,
           ContainerCount = ISNULL(ctn.Cnt, 0),
           ContainerRefs = CASE WHEN ISNULL(ctn.Cnt, 0) = 0 THEN NULL WHEN ctn.Cnt = 1 THEN ctn.FirstRef
                                ELSE ctn.FirstRef + N' +' + CAST(ctn.Cnt - 1 AS NVARCHAR(10)) END,
           ChargesPostedBase = (SELECT SUM(ch.AmountBase) FROM logistics.ContainerCharges ch WHERE ch.MovementId = m.Id AND ch.Status = 2),
           AttachmentCount = (SELECT COUNT(*) FROM logistics.ContainerAttachments a WHERE a.MovementId = m.Id),
           DurationDays = CASE WHEN m.StartDate IS NOT NULL THEN DATEDIFF(DAY, m.StartDate, ISNULL(m.EndDate, @Today)) END,
           IsLate = CAST(CASE WHEN m.Status IN (1, 2) AND m.Eta < @Today THEN 1 ELSE 0 END AS BIT),
           m.CreatedAtUtc, cu.FullName AS CreatedByName, m.UpdatedAtUtc, m.RowVersion,
           -- (80) a planned movement: why it cannot start yet (NULL = it can) and its earliest start date; a movement in
           -- progress: the earliest start date its edited start date may take (usp_Movement_Save, 70018)
           StartBlockedReason = sb.Reason, sb.StartNotBefore, sb.StartNotBeforeMovementNo, sb.StartNotBeforePlaceName,
           COUNT(*) OVER () AS TotalCount
    FROM logistics.Movements m
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    INNER JOIN masterdata.Ports fp         ON fp.Id = m.FromPlaceId
    INNER JOIN masterdata.Ports tp         ON tp.Id = m.ToPlaceId
    LEFT  JOIN masterdata.Parties cp       ON cp.Id = m.CarrierPartyId
    LEFT  JOIN security.Users cu           ON cu.Id = m.CreatedBy
    OUTER APPLY (SELECT Cnt = COUNT(*), FirstRef = MIN(c.ContainerRef)
                 FROM logistics.MovementContainers mc INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
                 WHERE mc.MovementId = m.Id) ctn
    OUTER APPLY logistics.fn_Movement_StartBlock(m.Id) sb   -- (80)
    WHERE (@Search IS NULL OR m.MovementNo LIKE N'%' + @Search + N'%' OR m.VehicleOrVessel LIKE N'%' + @Search + N'%'
           OR m.VoyageNo LIKE N'%' + @Search + N'%' OR m.Reference LIKE N'%' + @Search + N'%'
           OR EXISTS (SELECT 1 FROM logistics.MovementContainers mc INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
                      WHERE mc.MovementId = m.Id AND (c.ContainerRef LIKE N'%' + @Search + N'%' OR c.ContainerNo LIKE N'%' + @Search + N'%')))
      AND (@Status IS NULL OR m.Status = @Status)
      AND (@MovementTypeId IS NULL OR m.MovementTypeId = @MovementTypeId)
      AND (@PlaceId IS NULL OR m.FromPlaceId = @PlaceId OR m.ToPlaceId = @PlaceId)
      AND (@CarrierPartyId IS NULL OR m.CarrierPartyId = @CarrierPartyId)
      AND (@ContainerId IS NULL OR EXISTS (SELECT 1 FROM logistics.MovementContainers mc WHERE mc.MovementId = m.Id AND mc.ContainerId = @ContainerId))
      AND (@DateFrom IS NULL OR COALESCE(m.StartDate, m.PlannedDate) >= @DateFrom)
      AND (@DateTo IS NULL OR COALESCE(m.StartDate, m.PlannedDate) <= @DateTo)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'MovementNo' THEN m.MovementNo END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'MovementNo' THEN m.MovementNo END DESC,
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'StartDate' THEN COALESCE(m.StartDate, m.PlannedDate) WHEN N'Eta' THEN m.Eta WHEN N'EndDate' THEN m.EndDate END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'StartDate' THEN COALESCE(m.StartDate, m.PlannedDate) WHEN N'Eta' THEN m.Eta WHEN N'EndDate' THEN m.EndDate END END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Status' THEN CAST(m.Status AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Status' THEN CAST(m.Status AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN m.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN m.CreatedAtUtc END DESC,
        m.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

-- Re-created (80) from the body of script 79: + StartBlockedReason and StartNotBefore on the header (set 1). Nothing else
-- changes.
CREATE OR ALTER PROCEDURE logistics.usp_Movement_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT m.Id, m.DocumentTypeId, m.MovementNo, m.MovementTypeId, mt.TypeCode, mt.TypeName, mt.Stage,
           m.FromPlaceId, fp.PortCode AS FromCode, fp.PortName AS FromName, fp.CountryCode AS FromCountry, fp.Kind AS FromKind,
           m.ToPlaceId, tp.PortCode AS ToCode, tp.PortName AS ToName, tp.CountryCode AS ToCountry, tp.Kind AS ToKind,
           m.PlannedDate, m.StartDate, m.Eta, m.EndDate, m.Status, m.CancelReason,
           m.CarrierPartyId, cp.PartyName AS CarrierName, m.VehicleOrVessel, m.VoyageNo, m.Reference, m.Notes,
           m.StartedAtUtc, su.FullName AS StartedByName, m.CompletedAtUtc, ku.FullName AS CompletedByName,
           m.CancelledAtUtc, xu.FullName AS CancelledByName,
           m.CreatedAtUtc, m.CreatedBy, cu.FullName AS CreatedByName, m.UpdatedAtUtc, m.UpdatedBy, uu.FullName AS UpdatedByName,
           m.RowVersion,
           -- (79) the GRN type's switch: does completing a Delivery draft the goods receipts (the Complete dialog says)
           GoodsReceiptsAutomatic = CAST(ISNULL((SELECT dt.AutoCreateOnDelivery FROM inventory.DocumentTypes dt WHERE dt.Code = N'GRN'), 1) AS BIT),
           -- (80) a planned movement: why it cannot start yet (NULL = it can) and its earliest start date; a movement in
           -- progress: the earliest start date its edited start date may take (usp_Movement_Save, 70018)
           StartBlockedReason = sb.Reason, sb.StartNotBefore, sb.StartNotBeforeMovementNo, sb.StartNotBeforePlaceName
    FROM logistics.Movements m
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    INNER JOIN masterdata.Ports fp         ON fp.Id = m.FromPlaceId
    INNER JOIN masterdata.Ports tp         ON tp.Id = m.ToPlaceId
    LEFT  JOIN masterdata.Parties cp       ON cp.Id = m.CarrierPartyId
    LEFT  JOIN security.Users su ON su.Id = m.StartedBy
    LEFT  JOIN security.Users ku ON ku.Id = m.CompletedBy
    LEFT  JOIN security.Users xu ON xu.Id = m.CancelledBy
    LEFT  JOIN security.Users cu ON cu.Id = m.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = m.UpdatedBy
    OUTER APPLY logistics.fn_Movement_StartBlock(m.Id) sb   -- (80)
    WHERE m.Id = @Id;

    SELECT c.Id AS ContainerId, c.ContainerRef, c.ContainerNo, ct.TypeCode AS ContainerTypeCode, c.Status AS ContainerStatus,
           c.CurrentLocation, c.TotalAllocatedBase, c.TotalOilQty,
           ItemSummary = CASE WHEN ln.ItemCount = 1 THEN ln.FirstItem WHEN ln.ItemCount > 1 THEN N'Mixed - ' + CAST(ln.ItemCount AS NVARCHAR(10)) + N' items' END,
           SupplierName = ln.FirstSupplier,
           ChargesBase = (SELECT SUM(ch.AmountBase) FROM logistics.ContainerCharges ch WHERE ch.ContainerId = c.Id AND ch.MovementId = @Id AND ch.Status = 2),
           DraftChargesBase = (SELECT SUM(ch.AmountBase) FROM logistics.ContainerCharges ch WHERE ch.ContainerId = c.Id AND ch.MovementId = @Id AND ch.Status = 1),
           AttachmentCount = (SELECT COUNT(*) FROM logistics.ContainerAttachments a WHERE a.ContainerId = c.Id AND a.MovementId = @Id),
           c.RowVersion AS ContainerRowVersion,
           -- (65) the container's open goods receipt (a draft or the posted one) and the warehouse its draft would take:
           -- the Complete dialog of a Delivery says what will be created ("draft goods receipt into LUB-WH", "warehouse to
           -- choose", "already has GRN-..."). WarehouseInBranch = the container's warehouse is active, of its branch and
           -- (72) at the bottom of the tree (script 70): the rule of usp_GoodsReceipt_CreateForContainer. AutoDraftOfThisMovement = the receipt is a draft made by
           -- this movement's completion: cancelling the movement deletes it (usp_Movement_SetStatus); the Cancel dialog
           -- names those edited since (GoodsReceiptUpdatedAtUtc / ByName, NULL when never edited).
           GoodsReceiptId = gr.GoodsReceiptId, GoodsReceiptNumber = gr.GoodsReceiptNumber, GoodsReceiptStatus = gr.GoodsReceiptStatus,
           WarehouseCode = w.WarehouseCode,
           WarehouseInBranch = CAST(CASE WHEN w.IsActive = 1 AND w.BranchId = c.BranchId AND masterdata.fn_Warehouse_IsLeaf(w.Id) = 1
                                         THEN 1 ELSE 0 END AS BIT),
           -- (72) why it will not be taken, NULL when it will be (or the container has none: "warehouse to choose")
           WarehouseNote = CAST(CASE WHEN w.Id IS NULL THEN NULL
                                     WHEN w.IsActive = 0 THEN w.WarehouseCode + N', the container''s, is inactive'
                                     WHEN w.BranchId <> c.BranchId THEN w.WarehouseCode + N', the container''s, is not of the container''s branch'
                                     WHEN masterdata.fn_Warehouse_IsLeaf(w.Id) = 0 THEN w.WarehouseCode + N', the container''s, has warehouses under it'
                                END AS NVARCHAR(200)),
           AutoDraftOfThisMovement = CAST(CASE WHEN g.Status = 1 AND g.IsAuto = 1 AND g.MovementId = @Id THEN 1 ELSE 0 END AS BIT),
           GoodsReceiptUpdatedAtUtc = g.UpdatedAtUtc, GoodsReceiptUpdatedByName = gu.FullName
    FROM logistics.MovementContainers mc
    INNER JOIN logistics.Containers c       ON c.Id = mc.ContainerId
    INNER JOIN masterdata.ContainerTypes ct ON ct.Id = c.ContainerTypeId
    CROSS APPLY logistics.fn_Container_ReceivedBy(c.Id) gr
    LEFT  JOIN purchase.GoodsReceipts g     ON g.Id = gr.GoodsReceiptId
    LEFT  JOIN security.Users gu            ON gu.Id = g.UpdatedBy
    LEFT  JOIN masterdata.Warehouses w      ON w.Id = c.WarehouseId
    OUTER APPLY (SELECT ItemCount = COUNT(DISTINCT cl.ItemId), FirstItem = MIN(i.ItemName), FirstSupplier = MIN(sp.PartyName)
                 FROM logistics.ContainerLines cl
                 INNER JOIN inventory.Items i ON i.Id = cl.ItemId
                 INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                 INNER JOIN masterdata.Parties sp ON sp.Id = d.SupplierId
                 WHERE cl.ContainerId = c.Id) ln
    WHERE mc.MovementId = @Id
    ORDER BY c.ContainerRef;

    SELECT ch.Id, ch.ContainerId, c.ContainerRef, ch.GroupId, ch.ChargeTypeId, t.ChargeCode, t.ChargeName, ch.Description,
           pp.PartyName AS ProviderName, ch.Reference, ch.ChargeDate, cur.CurrencyCode, ch.Amount, ch.AmountBase,
           ch.AllocationMethod, ch.IncludeInLandedCost, ch.Status, ch.RowVersion
    FROM logistics.ContainerCharges ch
    INNER JOIN logistics.Containers c    ON c.Id = ch.ContainerId
    INNER JOIN purchase.ChargeTypes t    ON t.Id = ch.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = ch.CurrencyId
    LEFT  JOIN masterdata.Parties pp     ON pp.Id = ch.ProviderPartyId
    WHERE ch.MovementId = @Id
    ORDER BY ch.ChargeDate, c.ContainerRef, ch.Id;

    SELECT a.Id, a.ContainerId, c.ContainerRef, a.ChargeId, a.AttachmentTypeId, at.Category, at.SubType,
           a.FileId, f.FileName, f.ContentType, f.SizeBytes, a.Note, a.DocumentDate, a.GroupId,
           a.CreatedAtUtc, u.FullName AS CreatedByName
    FROM logistics.ContainerAttachments a
    INNER JOIN logistics.Containers c        ON c.Id = a.ContainerId
    INNER JOIN logistics.Files f             ON f.Id = a.FileId
    LEFT  JOIN masterdata.AttachmentTypes at ON at.Id = a.AttachmentTypeId
    LEFT  JOIN security.Users u              ON u.Id = a.CreatedBy
    WHERE a.MovementId = @Id
    ORDER BY a.CreatedAtUtc DESC, c.ContainerRef;
END
GO

/* ================================================================== 6. Start and Complete: real dates, in travel order */

-- Re-created (80) from the body of script 65: + a start or end date in the future is refused (70000), and a start before
-- the previous leg of one of its containers ended (70018). Cancel is unchanged.
CREATE OR ALTER PROCEDURE logistics.usp_Movement_SetStatus
    @Id         INT,
    @Action     NVARCHAR(10),
    @Date       DATE          = NULL,    -- Start: start date; Complete: end date (default today)
    @Reason     NVARCHAR(300) = NULL,    -- Cancel
    @RowVersion BINARY(8)     = NULL,
    @UserId     INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Action = NULLIF(LTRIM(RTRIM(@Action)), N'');
    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Date IS NULL SET @Date = CAST(SYSUTCDATETIME() AS DATE);
    IF @Action IS NULL OR @Action NOT IN (N'Start', N'Complete', N'Cancel') THROW 70000, 'Action must be Start, Complete or Cancel.', 1;

    DECLARE @Status TINYINT, @StartDate DATE, @Label NVARCHAR(300), @FromPlaceId INT, @ToPlaceId INT, @MovementTypeId INT,
            @MovementNo NVARCHAR(30);
    SELECT @Status = m.Status, @StartDate = m.StartDate, @MovementNo = m.MovementNo,
           @FromPlaceId = m.FromPlaceId, @ToPlaceId = m.ToPlaceId, @MovementTypeId = m.MovementTypeId,
           @Label = m.MovementNo + N' ' + mt.TypeName + N': ' + fp.PortName + N' ' + NCHAR(8594) + N' ' + tp.PortName
    FROM logistics.Movements m WITH (UPDLOCK, HOLDLOCK)
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    INNER JOIN masterdata.Ports fp ON fp.Id = m.FromPlaceId
    INNER JOIN masterdata.Ports tp ON tp.Id = m.ToPlaceId
    WHERE m.Id = @Id;

    IF @Status IS NULL THROW 70006, 'Movement not found.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Movements WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 70004, 'This movement was modified by another user. Reload the page and try again.', 1;
    IF @Action = N'Start' AND @Status <> 1 THROW 70010, 'Only a planned movement can be started.', 1;
    IF @Action = N'Complete' AND @Status <> 2 THROW 70010, 'Only a movement in progress can be completed.', 1;
    IF @Action = N'Complete' AND @Date < @StartDate THROW 70000, 'The end date cannot be earlier than the start date.', 1;
    IF @Action = N'Cancel' AND @Status = 4 THROW 70010, 'The movement is already cancelled.', 1;
    IF @Action = N'Cancel' AND @Reason IS NULL THROW 70000, 'A cancellation reason is required.', 1;
    -- (80) THE OWNER'S DECISION: A START AND AN ARRIVAL RECORD FACTS, never a plan (a plan is the planned date). One day of
    -- tolerance, as for the document dates: the date is the reader's, SYSUTCDATETIME() the server's in UTC.
    IF @Action = N'Start' AND @Date > DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE))
        THROW 70000, 'The start date cannot be in the future: start the movement on the day it really leaves.', 1;
    IF @Action = N'Complete' AND @Date > DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE))
        THROW 70000, 'The end date cannot be in the future: complete the movement on the day it really arrives.', 1;
    IF NOT EXISTS (SELECT 1 FROM logistics.MovementContainers WHERE MovementId = @Id) AND @Action = N'Start'
        THROW 70000, 'Tick at least one container before starting.', 1;
    IF NOT EXISTS (SELECT 1 FROM logistics.MovementContainers WHERE MovementId = @Id) AND @Action = N'Complete'
        THROW 70000, 'The movement has no containers.', 1;

    DECLARE @Msg NVARCHAR(400);
    IF @Action = N'Start'
    BEGIN
        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + CASE WHEN c.Status = 1 THEN N' is not confirmed yet.'
                                                                    ELSE N' is already offloaded, closed or cancelled.' END
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
        WHERE mc.MovementId = @Id AND (c.Status = 1 OR c.Status >= 6)
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70010, @Msg, 1;

        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' is already travelling with movement ' + m.MovementNo + N'. Complete it first.'
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Containers c         ON c.Id = mc.ContainerId
        INNER JOIN logistics.MovementContainers o ON o.ContainerId = mc.ContainerId AND o.MovementId <> @Id
        INNER JOIN logistics.Movements m          ON m.Id = o.MovementId AND m.Status = 2
        WHERE mc.MovementId = @Id
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70012, @Msg, 1;

        -- the place rules (script 53): the previous movement of every container is completed (70016), then every
        -- container fits the movement's From, To and stage (70015) - the rules of Save, fn_ContainerFitForMovement
        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N': the previous movement ' + p.PreviousMovementNo + N' (' + pf.PortName
                              + N' ' + NCHAR(8594) + N' ' + p.PlaceName + N') is not completed yet.'
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
        INNER JOIN logistics.fn_ContainerPlaceForMovement(@Id) p ON p.ContainerId = mc.ContainerId
        INNER JOIN logistics.Movements pm ON pm.Id = p.PreviousMovementId
        INNER JOIN masterdata.Ports pf    ON pf.Id = pm.FromPlaceId
        WHERE mc.MovementId = @Id AND p.PreviousStatus <> 3
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70016, @Msg, 1;

        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' cannot leave from ' + f.PortName + N'. ' + p.Reason
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
        INNER JOIN logistics.fn_ContainerFitForMovement(@Id, @FromPlaceId, @ToPlaceId, @MovementTypeId) p ON p.ContainerId = mc.ContainerId
        INNER JOIN masterdata.Ports f     ON f.Id = @FromPlaceId
        WHERE mc.MovementId = @Id AND p.Fits = 0
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70015, @Msg, 1;

        -- (80) NOT BEFORE THE PREVIOUS LEG ENDED (70018): a container cannot set off from a place before it got there.
        -- The previous movement is completed here (70016 above); its end date is the earliest start.
        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' cannot start ' + @MovementNo + N' before ' + pm.MovementNo
                              + N' reached ' + tp.PortName + N' on ' + CONVERT(NVARCHAR(10), pm.EndDate, 103) + N'.'
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
        INNER JOIN logistics.fn_ContainerPlaceForMovement(@Id) p ON p.ContainerId = mc.ContainerId
        INNER JOIN logistics.Movements pm ON pm.Id = p.PreviousMovementId
        INNER JOIN masterdata.Ports tp    ON tp.Id = pm.ToPlaceId
        WHERE mc.MovementId = @Id AND pm.EndDate > @Date
        ORDER BY pm.EndDate DESC, c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70018, @Msg, 1;
    END
    IF @Action = N'Cancel'
    BEGIN
        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' is already offloaded: its route can no longer change.'
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
        WHERE mc.MovementId = @Id AND c.Status IN (6, 7) AND @Status IN (2, 3)
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70010, @Msg, 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE logistics.Movements
        SET Status = CASE @Action WHEN N'Start' THEN 2 WHEN N'Complete' THEN 3 ELSE 4 END,
            StartDate = CASE WHEN @Action = N'Start' THEN @Date ELSE StartDate END,
            EndDate = CASE WHEN @Action = N'Complete' THEN @Date ELSE EndDate END,
            StartedAtUtc = CASE WHEN @Action = N'Start' THEN SYSUTCDATETIME() ELSE StartedAtUtc END,
            StartedBy = CASE WHEN @Action = N'Start' THEN @UserId ELSE StartedBy END,
            CompletedAtUtc = CASE WHEN @Action = N'Complete' THEN SYSUTCDATETIME() ELSE CompletedAtUtc END,
            CompletedBy = CASE WHEN @Action = N'Complete' THEN @UserId ELSE CompletedBy END,
            CancelledAtUtc = CASE WHEN @Action = N'Cancel' THEN SYSUTCDATETIME() ELSE CancelledAtUtc END,
            CancelledBy = CASE WHEN @Action = N'Cancel' THEN @UserId ELSE CancelledBy END,
            CancelReason = CASE WHEN @Action = N'Cancel' THEN @Reason ELSE CancelReason END,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        SELECT mc.ContainerId, N'Event',
               LEFT(CASE @Action WHEN N'Start' THEN N'Started ' WHEN N'Complete' THEN N'Arrived / completed ' ELSE N'Cancelled ' END
                    + @Label + N' on ' + CONVERT(NVARCHAR(10), @Date, 23) + ISNULL(N' - ' + @Reason, N''), 500),
               @UserId
        FROM logistics.MovementContainers mc WHERE mc.MovementId = @Id;

        -- (65) RULE 22: CANCELLING A COMPLETED DELIVERY TAKES BACK THE DRAFT GOODS RECEIPTS ITS COMPLETION CREATED (IsAuto,
        -- MovementId = this movement), edited or not - the cancel dialog names the edited ones first (usp_Movement_Get).
        -- A draft made by hand is kept. A posted receipt made its container Offloaded, so the check above refused the
        -- cancel. The same plain deletes as usp_GoodsReceipt_Delete: a draft has no stock, number or cost to undo.
        IF @Action = N'Cancel' AND @Status = 3
        BEGIN
            DECLARE @AutoDrafts TABLE (Id INT NOT NULL PRIMARY KEY, ContainerId INT NOT NULL);
            INSERT INTO @AutoDrafts (Id, ContainerId)
            SELECT g.Id, g.ContainerId
            FROM purchase.GoodsReceipts g WITH (UPDLOCK, HOLDLOCK)
            WHERE g.MovementId = @Id AND g.IsAuto = 1 AND g.Status = 1;

            IF EXISTS (SELECT 1 FROM @AutoDrafts)
            BEGIN
                DELETE m FROM purchase.GoodsReceiptInvoiceMatches m
                INNER JOIN purchase.GoodsReceiptLines l ON l.Id = m.GoodsReceiptLineId
                INNER JOIN @AutoDrafts d                ON d.Id = l.GoodsReceiptId;
                DELETE f FROM purchase.GoodsReceiptFiles f INNER JOIN @AutoDrafts d ON d.Id = f.GoodsReceiptId;
                DELETE l FROM purchase.GoodsReceiptLines l INNER JOIN @AutoDrafts d ON d.Id = l.GoodsReceiptId;
                DELETE a FROM purchase.GoodsReceiptAudit a INNER JOIN @AutoDrafts d ON d.Id = a.GoodsReceiptId;
                DELETE g FROM purchase.GoodsReceipts g INNER JOIN @AutoDrafts d ON d.Id = g.Id;

                INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
                SELECT d.ContainerId, N'Event', LEFT(N'Draft goods receipt removed: movement ' + @MovementNo + N' cancelled', 500), @UserId
                FROM @AutoDrafts d;
            END
        END

        DECLARE @Cid INT;
        DECLARE ctn CURSOR LOCAL FAST_FORWARD FOR SELECT ContainerId FROM logistics.MovementContainers WHERE MovementId = @Id;
        OPEN ctn;
        FETCH NEXT FROM ctn INTO @Cid;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC logistics.usp_Container_RefreshStatus @Cid;
            FETCH NEXT FROM ctn INTO @Cid;
        END
        CLOSE ctn;
        DEALLOCATE ctn;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 6b. Save: the start date of a movement in progress */

-- Re-created (80) from the body of script 53: + while the movement is in progress (the page lets its start date be
-- changed after Start), the start date is refused in the future (70000) and before the previous leg of one of its
-- containers ended (70018), in the words of usp_Movement_SetStatus. A planned movement has no start date: unchanged.
-- Planned movements: everything editable. In progress: header and containers editable (start date too), no end date.
CREATE OR ALTER PROCEDURE logistics.usp_Movement_Save
    @Id              INT            = NULL,
    @MovementTypeId  INT,
    @FromPlaceId     INT,
    @ToPlaceId       INT,
    @PlannedDate     DATE           = NULL,
    @StartDate       DATE           = NULL,   -- used only while in progress (Start sets it)
    @Eta             DATE           = NULL,
    @CarrierPartyId  INT            = NULL,
    @VehicleOrVessel NVARCHAR(100)  = NULL,
    @VoyageNo        NVARCHAR(30)   = NULL,
    @Reference       NVARCHAR(50)   = NULL,
    @Notes           NVARCHAR(1000) = NULL,
    @ContainerIds    logistics.tvp_IdList READONLY,
    @RowVersion      BINARY(8)      = NULL,
    @UserId          INT            = NULL,
    @NewId           INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @VehicleOrVessel = NULLIF(LTRIM(RTRIM(@VehicleOrVessel)), N'');
    SET @VoyageNo = NULLIF(LTRIM(RTRIM(@VoyageNo)), N'');
    SET @Reference = NULLIF(LTRIM(RTRIM(@Reference)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');

    IF NOT EXISTS (SELECT 1 FROM masterdata.MovementTypes WHERE Id = @MovementTypeId AND IsActive = 1)
        THROW 70000, 'Movement type not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Ports WHERE Id = @FromPlaceId AND IsActive = 1)
        THROW 70000, 'The departure place is not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Ports WHERE Id = @ToPlaceId AND IsActive = 1)
        THROW 70000, 'The destination place is not found or inactive.', 1;
    IF @CarrierPartyId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @CarrierPartyId AND IsActive = 1)
        THROW 70000, 'The carrier is not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM @ContainerIds) THROW 70000, 'Select at least one container.', 1;

    DECLARE @Status TINYINT = 1, @MovementNo NVARCHAR(30);
    IF @Id IS NOT NULL
    BEGIN
        SELECT @Status = Status, @MovementNo = MovementNo FROM logistics.Movements WHERE Id = @Id;
        IF @Status IS NULL THROW 70006, 'Movement not found.', 1;
        IF @Status NOT IN (1, 2) THROW 70005, 'A completed or cancelled movement can no longer be changed.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Movements WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 70004, 'This movement was modified by another user. Reload the page and try again.', 1;
        IF @Status = 2 AND @StartDate IS NULL THROW 70000, 'The start date of a movement in progress is required.', 1;
    END
    IF @Status = 1 SET @StartDate = NULL;
    IF @StartDate IS NOT NULL AND @Eta IS NOT NULL AND @Eta < @StartDate THROW 70000, 'The ETA cannot be earlier than the start date.', 1;
    IF @PlannedDate IS NOT NULL AND @Eta IS NOT NULL AND @Eta < @PlannedDate THROW 70000, 'The ETA cannot be earlier than the planned date.', 1;
    -- (80) THE START DATE OF A MOVEMENT IN PROGRESS STAYS A FACT: the rule of its Start (usp_Movement_SetStatus), with the
    -- same day of tolerance (the reader's date against the server's UTC date). Otherwise a start made today could be
    -- moved to next month with a plain Save.
    IF @Status = 2 AND @StartDate > DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE))
        THROW 70000, 'The start date cannot be in the future: start the movement on the day it really leaves.', 1;

    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg = CASE WHEN c.Id IS NULL THEN N'A selected container no longer exists.'
                               WHEN c.Status >= 6 THEN N'Container ' + c.ContainerRef + N' is already offloaded, closed or cancelled.'
                               WHEN @Status = 2 AND c.Status = 1 THEN N'Container ' + c.ContainerRef + N' is not confirmed yet.' END
    FROM @ContainerIds x
    LEFT JOIN logistics.Containers c ON c.Id = x.Id
    WHERE (c.Id IS NULL OR c.Status >= 6 OR (@Status = 2 AND c.Status = 1))
      AND (@Id IS NULL OR NOT EXISTS (SELECT 1 FROM logistics.MovementContainers mc WHERE mc.MovementId = @Id AND mc.ContainerId = x.Id))
    ORDER BY c.ContainerRef;
    IF @Msg IS NOT NULL THROW 70000, @Msg, 1;

    IF @Status = 2
    BEGIN
        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' is already travelling with movement ' + m.MovementNo + N'.'
        FROM @ContainerIds x
        INNER JOIN logistics.Containers c         ON c.Id = x.Id
        INNER JOIN logistics.MovementContainers o ON o.ContainerId = x.Id AND o.MovementId <> @Id
        INNER JOIN logistics.Movements m          ON m.Id = o.MovementId AND m.Status = 2
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70012, @Msg, 1;
    END

    -- the place rules (script 53): every container of the movement, added or kept, fits its From, To and stage
    SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' cannot leave from ' + f.PortName + N'. ' + p.Reason
    FROM @ContainerIds x
    INNER JOIN logistics.Containers c ON c.Id = x.Id
    INNER JOIN logistics.fn_ContainerFitForMovement(@Id, @FromPlaceId, @ToPlaceId, @MovementTypeId) p ON p.ContainerId = x.Id
    INNER JOIN masterdata.Ports f ON f.Id = @FromPlaceId
    WHERE p.Fits = 0
    ORDER BY c.ContainerRef;
    IF @Msg IS NOT NULL THROW 70015, @Msg, 1;

    -- (80) NOT BEFORE THE PREVIOUS LEG ENDED (70018), as at Start: an edited start date, or a container added to a
    -- movement in progress, cannot make a container set off from a place before it got there.
    IF @Status = 2
    BEGIN
        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' cannot start ' + @MovementNo + N' before ' + pm.MovementNo
                              + N' reached ' + tp.PortName + N' on ' + CONVERT(NVARCHAR(10), pm.EndDate, 103) + N'.'
        FROM @ContainerIds x
        INNER JOIN logistics.Containers c ON c.Id = x.Id
        INNER JOIN logistics.fn_ContainerPlaceForMovement(@Id) p ON p.ContainerId = x.Id
        INNER JOIN logistics.Movements pm ON pm.Id = p.PreviousMovementId
        INNER JOIN masterdata.Ports tp    ON tp.Id = pm.ToPlaceId
        WHERE pm.Status = 3 AND pm.EndDate > @StartDate
        ORDER BY pm.EndDate DESC, c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70018, @Msg, 1;
    END

    DECLARE @Affected TABLE (ContainerId INT PRIMARY KEY);

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Label NVARCHAR(300);
        IF @Id IS NULL
        BEGIN
            DECLARE @Number NVARCHAR(30), @TypeId INT = (SELECT Id FROM inventory.DocumentTypes WHERE Code = N'MOV');
            EXEC inventory.usp_DocumentType_NextNumber N'MOV', @Number OUTPUT, NULL;
            INSERT INTO logistics.Movements (DocumentTypeId, MovementNo, MovementTypeId, FromPlaceId, ToPlaceId, PlannedDate, Eta,
                                             CarrierPartyId, VehicleOrVessel, VoyageNo, Reference, Notes, Status, CreatedBy)
            VALUES (@TypeId, @Number, @MovementTypeId, @FromPlaceId, @ToPlaceId, @PlannedDate, @Eta,
                    @CarrierPartyId, @VehicleOrVessel, @VoyageNo, @Reference, @Notes, 1, @UserId);
            SET @Id = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            UPDATE logistics.Movements
            SET MovementTypeId = @MovementTypeId, FromPlaceId = @FromPlaceId, ToPlaceId = @ToPlaceId, PlannedDate = @PlannedDate,
                StartDate = CASE WHEN Status = 2 THEN @StartDate ELSE NULL END, Eta = @Eta,
                CarrierPartyId = @CarrierPartyId, VehicleOrVessel = @VehicleOrVessel, VoyageNo = @VoyageNo, Reference = @Reference,
                Notes = @Notes, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;
        END

        SELECT @Label = m.MovementNo + N' ' + mt.TypeName + N': ' + fp.PortName + N' ' + NCHAR(8594) + N' ' + tp.PortName
        FROM logistics.Movements m
        INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
        INNER JOIN masterdata.Ports fp ON fp.Id = m.FromPlaceId
        INNER JOIN masterdata.Ports tp ON tp.Id = m.ToPlaceId
        WHERE m.Id = @Id;

        INSERT INTO @Affected (ContainerId)
        SELECT mc.ContainerId FROM logistics.MovementContainers mc
        WHERE mc.MovementId = @Id AND NOT EXISTS (SELECT 1 FROM @ContainerIds x WHERE x.Id = mc.ContainerId)
        UNION
        SELECT x.Id FROM @ContainerIds x
        WHERE NOT EXISTS (SELECT 1 FROM logistics.MovementContainers mc WHERE mc.MovementId = @Id AND mc.ContainerId = x.Id);

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        SELECT a.ContainerId, N'Updated',
               LEFT(CASE WHEN EXISTS (SELECT 1 FROM @ContainerIds x WHERE x.Id = a.ContainerId) THEN N'Added to movement ' ELSE N'Removed from movement ' END + @Label, 500),
               @UserId
        FROM @Affected a;

        DELETE mc FROM logistics.MovementContainers mc
        WHERE mc.MovementId = @Id AND NOT EXISTS (SELECT 1 FROM @ContainerIds x WHERE x.Id = mc.ContainerId);
        INSERT INTO logistics.MovementContainers (MovementId, ContainerId)
        SELECT @Id, x.Id FROM @ContainerIds x
        WHERE NOT EXISTS (SELECT 1 FROM logistics.MovementContainers mc WHERE mc.MovementId = @Id AND mc.ContainerId = x.Id);

        -- in progress: the containers' status follows (all of them, the dates may have changed)
        IF @Status = 2
        BEGIN
            INSERT INTO @Affected (ContainerId)
            SELECT x.Id FROM @ContainerIds x WHERE NOT EXISTS (SELECT 1 FROM @Affected a WHERE a.ContainerId = x.Id);
            DECLARE @Cid INT;
            DECLARE ctn CURSOR LOCAL FAST_FORWARD FOR SELECT ContainerId FROM @Affected;
            OPEN ctn;
            FETCH NEXT FROM ctn INTO @Cid;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC logistics.usp_Container_RefreshStatus @Cid;
                FETCH NEXT FROM ctn INTO @Cid;
            END
            CLOSE ctn;
            DEALLOCATE ctn;
        END

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 7. Start shipment: a container leaves from where it is */

-- Re-created (80) from the body of script 28: the "empty From / To = the containers' ports" default only for containers
-- that never moved; one that moved leaves from where it is (an empty From = the place they are all at, the To
-- required); a stay with an empty To takes the From. Nothing else changes.
CREATE OR ALTER PROCEDURE logistics.usp_Movement_ShipContainers
    @ContainerIds     logistics.tvp_IdList READONLY,
    @MovementTypeId   INT            = NULL,   -- NULL = SEA
    @FromPlaceId      INT            = NULL,
    @ToPlaceId        INT            = NULL,
    @StartDate        DATE           = NULL,   -- NULL = today (planned date when @StartNow = 0)
    @Eta              DATE           = NULL,
    @CarrierPartyId   INT            = NULL,
    @VehicleOrVessel  NVARCHAR(100)  = NULL,
    @VoyageNo         NVARCHAR(30)   = NULL,
    @Reference        NVARCHAR(50)   = NULL,   -- booking / waybill / declaration...
    @BlNo             NVARCHAR(30)   = NULL,
    @BlDate           DATE           = NULL,
    @Notes            NVARCHAR(1000) = NULL,
    @StartNow         BIT            = 1,      -- 0 = the movement stays planned
    @ConfirmDrafts    BIT            = 1,
    @UpdateContainers BIT            = 1,
    @UserId           INT            = NULL,
    @NewId            INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @VehicleOrVessel = NULLIF(LTRIM(RTRIM(@VehicleOrVessel)), N'');
    SET @VoyageNo = NULLIF(LTRIM(RTRIM(@VoyageNo)), N'');
    SET @Reference = NULLIF(LTRIM(RTRIM(@Reference)), N'');
    SET @BlNo = NULLIF(LTRIM(RTRIM(@BlNo)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    IF @StartDate IS NULL SET @StartDate = CAST(SYSUTCDATETIME() AS DATE);
    SET @StartNow = ISNULL(@StartNow, 1);
    SET @ConfirmDrafts = ISNULL(@ConfirmDrafts, 1);
    SET @UpdateContainers = ISNULL(@UpdateContainers, 1);

    IF @MovementTypeId IS NULL
        SELECT @MovementTypeId = Id FROM masterdata.MovementTypes WHERE TypeCode = N'SEA' AND IsActive = 1;
    DECLARE @Stage NVARCHAR(10), @TypeCode NVARCHAR(10);
    SELECT @Stage = Stage, @TypeCode = TypeCode FROM masterdata.MovementTypes WHERE Id = @MovementTypeId AND IsActive = 1;
    IF @Stage IS NULL THROW 70000, 'Movement type not found or inactive.', 1;

    DECLARE @Ids TABLE (Id INT NOT NULL PRIMARY KEY);
    INSERT INTO @Ids (Id) SELECT Id FROM @ContainerIds;
    IF NOT EXISTS (SELECT 1 FROM @Ids) THROW 70000, 'Select at least one container.', 1;
    IF EXISTS (SELECT 1 FROM @Ids x WHERE NOT EXISTS (SELECT 1 FROM logistics.Containers c WHERE c.Id = x.Id))
        THROW 70006, 'A selected container no longer exists.', 1;

    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef
                        + CASE WHEN c.Status >= 6 THEN N' is already offloaded, closed or cancelled.'
                               ELSE N' is a draft: confirm it first, or let this shipment confirm the drafts.' END
    FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id
    WHERE c.Status >= 6 OR (c.Status = 1 AND @ConfirmDrafts = 0 AND @StartNow = 1)
    ORDER BY c.ContainerRef;
    IF @Msg IS NOT NULL THROW 70010, @Msg, 1;

    -- (80) A CONTAINER LEAVES FROM WHERE IT IS: the end of its latest movement, else (never moved) its port of loading.
    -- The ports default below is only for containers that never moved; for one that moved, an empty From is the place
    -- every selected container is at, and the To is required.
    DECLARE @Places TABLE (ContainerId INT NOT NULL PRIMARY KEY, Moved BIT NOT NULL, PlaceId INT NULL);
    INSERT INTO @Places (ContainerId, Moved, PlaceId)
    SELECT x.Id, CASE WHEN p.PreviousMovementId IS NULL THEN 0 ELSE 1 END,
           CASE WHEN p.PreviousMovementId IS NULL THEN p.PortOfLoadingId ELSE p.PlaceId END
    FROM @Ids x
    INNER JOIN logistics.fn_ContainerPlaceForMovement(NULL) p ON p.ContainerId = x.Id;
    DECLARE @AnyMoved BIT = CASE WHEN EXISTS (SELECT 1 FROM @Places WHERE Moved = 1) THEN 1 ELSE 0 END;

    IF @FromPlaceId IS NULL AND @AnyMoved = 1
    BEGIN
        IF EXISTS (SELECT 1 FROM @Places WHERE PlaceId IS NULL) OR (SELECT COUNT(DISTINCT PlaceId) FROM @Places) > 1
            THROW 70000, 'Choose the From: the selected containers are not all at the same place.', 1;
        SELECT TOP (1) @FromPlaceId = PlaceId FROM @Places;
    END
    IF @Stage = N'Sea' AND @FromPlaceId IS NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id WHERE c.PortOfLoadingId IS NULL)
           OR (SELECT COUNT(DISTINCT c.PortOfLoadingId) FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id) > 1
            THROW 70000, 'Choose the departure port: the selected containers have no port of loading, or different ones.', 1;
        SELECT TOP (1) @FromPlaceId = c.PortOfLoadingId FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id;
    END
    IF @Stage = N'Sea' AND @ToPlaceId IS NULL AND @AnyMoved = 0
    BEGIN
        IF EXISTS (SELECT 1 FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id WHERE c.PortOfDestinationId IS NULL)
           OR (SELECT COUNT(DISTINCT c.PortOfDestinationId) FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id) > 1
            THROW 70000, 'Choose the destination port: the selected containers have no port of destination, or different ones.', 1;
        SELECT TOP (1) @ToPlaceId = c.PortOfDestinationId FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id;
    END
    -- (80) a stay (a port call, customs, a border crossing) happens at one place
    IF @ToPlaceId IS NULL AND @Stage IN (N'Port', N'Customs', N'Border') SET @ToPlaceId = @FromPlaceId;
    IF @FromPlaceId IS NULL OR @ToPlaceId IS NULL THROW 70000, 'Choose the departure and destination places.', 1;

    DECLARE @CarrierName NVARCHAR(100) = (SELECT LEFT(PartyName, 100) FROM masterdata.Parties WHERE Id = @CarrierPartyId);
    DECLARE @FromKind NVARCHAR(10) = (SELECT Kind FROM masterdata.Ports WHERE Id = @FromPlaceId),
            @ToKind   NVARCHAR(10) = (SELECT Kind FROM masterdata.Ports WHERE Id = @ToPlaceId);
    -- a vessel leg: sea freight, or a transshipment between two sea ports (feeder vessel, not inland transport);
    -- a road leg: the other legs that move (inland transport, border, delivery)
    DECLARE @VesselLeg BIT = CASE WHEN @Stage = N'Sea'
                                    OR (@Stage = N'Transit' AND @TypeCode <> N'INLAND' AND @FromKind = N'Sea' AND @ToKind = N'Sea')
                                  THEN 1 ELSE 0 END;
    DECLARE @RoadLeg BIT = CASE WHEN @VesselLeg = 0 AND @Stage IN (N'Transit', N'Border', N'Delivery') THEN 1 ELSE 0 END;
    DECLARE @MovementId INT, @Cid INT, @Ref NVARCHAR(30) = NULL, @MovementNo NVARCHAR(30);
    DECLARE @Changed TABLE (ContainerId INT NOT NULL PRIMARY KEY, Details NVARCHAR(450) NOT NULL);

    BEGIN TRY
        BEGIN TRANSACTION;

        -- 1. the drafts are confirmed
        IF @ConfirmDrafts = 1
        BEGIN
            DECLARE draft_cur CURSOR LOCAL STATIC READ_ONLY FORWARD_ONLY FOR
                SELECT c.Id, c.ContainerRef FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id
                WHERE c.Status = 1 ORDER BY c.ContainerRef;
            OPEN draft_cur;
            FETCH NEXT FROM draft_cur INTO @Cid, @Ref;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC logistics.usp_Container_Confirm @Id = @Cid, @UserId = @UserId;
                FETCH NEXT FROM draft_cur INTO @Cid, @Ref;
            END
            CLOSE draft_cur;
            DEALLOCATE draft_cur;
            SET @Ref = NULL;
        END

        -- 2. one movement for all of them, 3. started
        EXEC logistics.usp_Movement_Save
             @MovementTypeId  = @MovementTypeId,
             @FromPlaceId     = @FromPlaceId,
             @ToPlaceId       = @ToPlaceId,
             @PlannedDate     = @StartDate,
             @Eta             = @Eta,
             @CarrierPartyId  = @CarrierPartyId,
             @VehicleOrVessel = @VehicleOrVessel,
             @VoyageNo        = @VoyageNo,
             @Reference       = @Reference,
             @Notes           = @Notes,
             @ContainerIds    = @ContainerIds,
             @UserId          = @UserId,
             @NewId           = @MovementId OUTPUT;

        IF @StartNow = 1
            EXEC logistics.usp_Movement_SetStatus @Id = @MovementId, @Action = N'Start', @Date = @StartDate, @UserId = @UserId;

        -- 4. shipping details on the containers (only the values that change; the ports only when empty)
        IF @UpdateContainers = 1
        BEGIN
            SET @MovementNo = (SELECT MovementNo FROM logistics.Movements WHERE Id = @MovementId);

            UPDATE c
            SET VesselName = v.VesselName, VoyageNo = v.VoyageNo, ShippingLine = v.ShippingLine, Eta = v.Eta,
                PortOfLoadingId = v.PortOfLoadingId, PortOfDestinationId = v.PortOfDestinationId, TruckNo = v.TruckNo,
                BlNo = v.BlNo, BlDate = v.BlDate, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            OUTPUT inserted.Id,
                   LEFT(CONCAT_WS(N', ',
                        CASE WHEN ISNULL(inserted.VesselName, N'') <> ISNULL(deleted.VesselName, N'') THEN N'vessel ' + inserted.VesselName END,
                        CASE WHEN ISNULL(inserted.VoyageNo, N'') <> ISNULL(deleted.VoyageNo, N'') THEN N'voyage ' + inserted.VoyageNo END,
                        CASE WHEN ISNULL(inserted.ShippingLine, N'') <> ISNULL(deleted.ShippingLine, N'') THEN N'shipping line ' + inserted.ShippingLine END,
                        CASE WHEN ISNULL(inserted.Eta, '19000101') <> ISNULL(deleted.Eta, '19000101') THEN N'ETA ' + CONVERT(NVARCHAR(10), inserted.Eta, 23) END,
                        CASE WHEN ISNULL(inserted.PortOfLoadingId, 0) <> ISNULL(deleted.PortOfLoadingId, 0) THEN N'port of loading' END,
                        CASE WHEN ISNULL(inserted.PortOfDestinationId, 0) <> ISNULL(deleted.PortOfDestinationId, 0) THEN N'port of destination' END,
                        CASE WHEN ISNULL(inserted.TruckNo, N'') <> ISNULL(deleted.TruckNo, N'') THEN N'truck ' + inserted.TruckNo END,
                        CASE WHEN ISNULL(inserted.BlNo, N'') <> ISNULL(deleted.BlNo, N'') THEN N'B/L ' + inserted.BlNo END,
                        CASE WHEN ISNULL(inserted.BlDate, '19000101') <> ISNULL(deleted.BlDate, '19000101') THEN N'B/L date ' + CONVERT(NVARCHAR(10), inserted.BlDate, 23) END), 450)
            INTO @Changed (ContainerId, Details)
            FROM logistics.Containers c
            INNER JOIN @Ids x ON x.Id = c.Id
            CROSS APPLY (SELECT VesselName          = CASE WHEN @VesselLeg = 1 THEN ISNULL(@VehicleOrVessel, c.VesselName) ELSE c.VesselName END,
                                VoyageNo            = CASE WHEN @VesselLeg = 1 THEN ISNULL(@VoyageNo, c.VoyageNo) ELSE c.VoyageNo END,
                                ShippingLine        = CASE WHEN @VesselLeg = 1 THEN ISNULL(@CarrierName, c.ShippingLine) ELSE c.ShippingLine END,
                                Eta                 = CASE WHEN @VesselLeg = 1 THEN ISNULL(@Eta, c.Eta) ELSE c.Eta END,
                                PortOfLoadingId     = CASE WHEN @Stage = N'Sea' THEN ISNULL(c.PortOfLoadingId, @FromPlaceId) ELSE c.PortOfLoadingId END,
                                PortOfDestinationId = CASE WHEN @Stage = N'Sea' THEN ISNULL(c.PortOfDestinationId, @ToPlaceId) ELSE c.PortOfDestinationId END,
                                TruckNo             = CASE WHEN @RoadLeg = 1 AND @VehicleOrVessel IS NOT NULL THEN LEFT(@VehicleOrVessel, 30) ELSE c.TruckNo END,
                                BlNo                = ISNULL(@BlNo, c.BlNo),
                                BlDate              = ISNULL(@BlDate, c.BlDate)) v
            WHERE ISNULL(v.VesselName, N'') <> ISNULL(c.VesselName, N'') OR ISNULL(v.VoyageNo, N'') <> ISNULL(c.VoyageNo, N'')
               OR ISNULL(v.ShippingLine, N'') <> ISNULL(c.ShippingLine, N'') OR ISNULL(v.Eta, '19000101') <> ISNULL(c.Eta, '19000101')
               OR ISNULL(v.PortOfLoadingId, 0) <> ISNULL(c.PortOfLoadingId, 0) OR ISNULL(v.PortOfDestinationId, 0) <> ISNULL(c.PortOfDestinationId, 0)
               OR ISNULL(v.TruckNo, N'') <> ISNULL(c.TruckNo, N'') OR ISNULL(v.BlNo, N'') <> ISNULL(c.BlNo, N'')
               OR ISNULL(v.BlDate, '19000101') <> ISNULL(c.BlDate, '19000101');

            INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
            SELECT ContainerId, N'Updated', LEFT(N'Shipping details from ' + @MovementNo + N': ' + Details, 500), @UserId
            FROM @Changed WHERE Details <> N'';
        END

        SET @NewId = @MovementId;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrNo INT = ERROR_NUMBER(), @ErrMsg NVARCHAR(2048) = ERROR_MESSAGE();
        IF @ErrNo >= 50000 AND @Ref IS NOT NULL
        BEGIN
            SET @ErrMsg = LEFT(@Ref + N': ' + @ErrMsg, 2048);
            THROW @ErrNo, @ErrMsg, 1;
        END;
        THROW;
    END CATCH

    SELECT m.Id, m.MovementNo, m.Status, m.StartDate, m.PlannedDate, m.Eta,
           ContainerCount = (SELECT COUNT(*) FROM logistics.MovementContainers mc WHERE mc.MovementId = m.Id),
           m.RowVersion
    FROM logistics.Movements m
    WHERE m.Id = @NewId;
END
GO

/* ================================================================== 8. "Add to a movement...": the movements a container can join */

-- The PLANNED movements @ContainerId can really join: not on it yet, created after its latest movement (legs follow the
-- travel order: "previous" is the movement with the highest Id below, so joining an older one would put it before a
-- leg already made), and passing the checks usp_Movement_Save makes for it at that movement's From, To and type
-- (fn_Movement_ContainerCheck: not received, closed or cancelled; at the From). Newest first, every one of them.
-- 70006 when there is no such container.
CREATE OR ALTER PROCEDURE logistics.usp_Movement_JoinCandidates
    @ContainerId INT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @ContainerId) THROW 70006, 'Container not found.', 1;

    DECLARE @Latest INT = (SELECT MAX(m.Id)
                           FROM logistics.MovementContainers mc
                           INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
                           WHERE mc.ContainerId = @ContainerId AND m.Status <> 4);

    SELECT m.Id, m.MovementNo, m.MovementTypeId, mt.TypeCode, mt.TypeName, mt.Stage,
           m.FromPlaceId, fp.PortCode AS FromCode, fp.PortName AS FromName,
           m.ToPlaceId, tp.PortCode AS ToCode, tp.PortName AS ToName,
           m.PlannedDate, m.Eta, m.Status,
           m.CarrierPartyId, cp.PartyName AS CarrierName, m.VehicleOrVessel,
           ContainerCount = ISNULL(ctn.Cnt, 0),
           ContainerRefs = CASE WHEN ISNULL(ctn.Cnt, 0) = 0 THEN NULL WHEN ctn.Cnt = 1 THEN ctn.FirstRef
                                ELSE ctn.FirstRef + N' +' + CAST(ctn.Cnt - 1 AS NVARCHAR(10)) END,
           k.Note,
           m.RowVersion
    FROM logistics.Movements m
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    INNER JOIN masterdata.Ports fp         ON fp.Id = m.FromPlaceId
    INNER JOIN masterdata.Ports tp         ON tp.Id = m.ToPlaceId
    LEFT  JOIN masterdata.Parties cp       ON cp.Id = m.CarrierPartyId
    CROSS APPLY (SELECT x.CanAdd, x.OnMovement, x.Note
                 FROM logistics.fn_Movement_ContainerCheck(m.Id, m.FromPlaceId, m.ToPlaceId, m.MovementTypeId) x
                 WHERE x.ContainerId = @ContainerId) k
    OUTER APPLY (SELECT Cnt = COUNT(*), FirstRef = MIN(c.ContainerRef)
                 FROM logistics.MovementContainers mc INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
                 WHERE mc.MovementId = m.Id) ctn
    WHERE m.Status = 1
      AND m.Id > ISNULL(@Latest, 0)
      AND k.OnMovement = 0 AND k.CanAdd = 1
    ORDER BY m.Id DESC;
END
GO

/* ================================================================== 9. Check */

-- Where every container that is still travelling stands, by its next step (what its page's button offers).
SELECT NextStep = CASE WHEN s.ActiveMovementId IS NOT NULL THEN N'Complete'
                       WHEN s.PlannedMovementId IS NOT NULL THEN N'Start'
                       WHEN s.MovementCount = 0 THEN N'Start shipment'
                       ELSE N'Next leg' END,
       Containers = COUNT(*)
FROM logistics.Containers c
CROSS APPLY logistics.fn_Container_ShipState(c.Id) s
WHERE c.Status BETWEEN 1 AND 5
GROUP BY CASE WHEN s.ActiveMovementId IS NOT NULL THEN N'Complete'
              WHEN s.PlannedMovementId IS NOT NULL THEN N'Start'
              WHEN s.MovementCount = 0 THEN N'Start shipment'
              ELSE N'Next leg' END;

-- Planned movements that cannot start yet, and why (the Movements list says it on the row).
SELECT m.MovementNo, b.Reason
FROM logistics.Movements m
CROSS APPLY logistics.fn_Movement_StartBlock(m.Id) b
WHERE b.Reason IS NOT NULL;

-- Planned or in-progress movements holding a container that already travelled further with a later movement (1b):
-- their next Save or Start refuses it until it is taken off them.
SELECT m.MovementNo, c.ContainerRef, p.Reason
FROM logistics.Movements m
INNER JOIN logistics.MovementContainers mc ON mc.MovementId = m.Id
INNER JOIN logistics.Containers c          ON c.Id = mc.ContainerId
CROSS APPLY logistics.fn_ContainerFitForMovement(m.Id, m.FromPlaceId, m.ToPlaceId, m.MovementTypeId) p
WHERE m.Status IN (1, 2) AND p.ContainerId = mc.ContainerId AND p.Reason LIKE N'Already travelled further%'
ORDER BY m.MovementNo, c.ContainerRef;

PRINT 'Script 80 applied: shipment from the container - each container''s next step, planned movements shown, Start and Complete with real dates in travel order, the movements a container can join.';
GO
