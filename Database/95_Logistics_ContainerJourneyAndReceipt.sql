SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 95: LOGISTICS - WHERE A CONTAINER IS ON ITS JOURNEY, AND RECEIVE GOODS ONLY ONCE DELIVERED

     1. THE JOURNEY OF A CONTAINER (logistics.fn_Container_Journey), for the Containers list's columns "From -> To" and
        "Journey" and its filter: the latest leg that started (in progress or completed, never planned or cancelled):
          On the way    a leg in progress that moves (From <> To): "Dar es Salaam -> Kasumbalesa"
          Arrived       the latest leg is completed, or a stay (Port, Customs, Border) is in progress: at its To since
                        its end (a stay: its start)
          Not dispatched no leg started yet: From -> To = its port of loading -> port of destination (the journey ahead)
          Received      offloaded or closed (6, 7): at its warehouse
        A container followed by typed dates only (no leg) follows its status: In Transit on the way to its port of
        destination, At Port arrived there, Cleared arrived at its final destination (else its port of destination).
        A cancelled container has none (NULL).
     2. RECEIVE GOODS... ONLY ONCE DELIVERED (logistics.fn_Container_ReceiveBlock, the one place of the rule and its
        words): a container that travels with movements is received only after one of its Delivery legs is completed -
        "KTG-2026-0031 has not been delivered yet: complete its Delivery movement first, then receive its goods." (63010).
        Before, any container from Confirmed to Cleared could be received by hand. One followed by typed dates only (no
        movement at all) keeps the rule of before (it can have no Delivery). Read by the Containers list and page
        (CanReceive, ReceiveBlockedReason), the goods receipt dialogs (the API) and Receive goods... itself.

   Objects
     New          logistics.fn_Container_Journey, logistics.fn_Container_ReceiveBlock
     Re-created   logistics.usp_Container_Search (from 81: + @Journey, the journey columns, CanReceive by the rule,
                  ReceiveBlockedReason), logistics.usp_Container_Get (from 82: the same columns),
                  purchase.usp_GoodsReceipt_CreateForContainer (from 72: the rule for Receive goods..., not for the
                  Delivery hook)

   Errors: no new number (63010).
   Not changed: the automatic draft of a completed Delivery, the posting of a goods receipt, movements, the Shipments
   board, the next step of a container (its "Receive goods..." already came after its Delivery).

   Requires scripts 65 and 82. Idempotent, additive: re-applied at every API start-up, and builds an empty database.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'logistics.fn_Container_ShipState', N'IF') IS NULL OR OBJECT_ID(N'logistics.fn_Container_LastDelivery', N'IF') IS NULL
    THROW 69000, 'Script 95 requires scripts 65 and 82: apply them first.', 1;
GO

/* ================================================================== 1. The journey of a container */

-- (95) ONE ROW PER CONTAINER (none for an unknown id): its latest leg that started, by movement id as everywhere (the
-- legs follow the travel order), else its status for a container followed by typed dates. Names, not ids: a list column.
CREATE OR ALTER FUNCTION logistics.fn_Container_Journey (@ContainerId INT)
RETURNS TABLE
AS
RETURN
SELECT c.Id AS ContainerId,
       JourneyStatus = CAST(CASE
           WHEN c.Status = 8 THEN NULL
           WHEN c.Status IN (6, 7) THEN N'Received'
           WHEN lg.Id IS NOT NULL THEN CASE WHEN lg.Status = 2 AND lg.FromPlaceId <> lg.ToPlaceId THEN N'OnTheWay' ELSE N'Arrived' END
           WHEN c.Status = 3 THEN N'OnTheWay'
           WHEN c.Status IN (4, 5) THEN N'Arrived'
           ELSE N'NotDispatched' END AS NVARCHAR(20)),
       JourneyFromName = CASE WHEN c.Status = 8 THEN NULL WHEN lg.Id IS NOT NULL THEN fp.PortName ELSE pl.PortName END,
       JourneyToName = CASE WHEN c.Status = 8 THEN NULL
                            WHEN c.Status IN (6, 7) AND lg.Id IS NULL THEN COALESCE(w.WarehouseName, fd.PortName, pd.PortName)
                            WHEN lg.Id IS NOT NULL THEN tp.PortName
                            WHEN c.Status = 5 THEN COALESCE(fd.PortName, pd.PortName)
                            ELSE pd.PortName END,
       JourneySince = CASE WHEN c.Status = 8 THEN NULL
                           WHEN c.Status IN (6, 7) THEN c.OffloadedDate
                           WHEN lg.Id IS NOT NULL THEN CASE WHEN lg.Status = 3 THEN lg.EndDate ELSE lg.StartDate END
                           WHEN c.Status = 3 THEN c.DispatchDate
                           WHEN c.Status = 4 THEN c.ActualPortArrival
                           WHEN c.Status = 5 THEN c.CustomsReleaseDate END,
       JourneyMovementNo = CASE WHEN c.Status = 8 THEN NULL ELSE lg.MovementNo END
FROM logistics.Containers c
LEFT JOIN masterdata.Ports pl      ON pl.Id = c.PortOfLoadingId
LEFT JOIN masterdata.Ports pd      ON pd.Id = c.PortOfDestinationId
LEFT JOIN masterdata.Ports fd      ON fd.Id = c.FinalDestinationId
LEFT JOIN masterdata.Warehouses w  ON w.Id = c.WarehouseId
OUTER APPLY (SELECT TOP (1) m.Id, m.MovementNo, m.Status, m.FromPlaceId, m.ToPlaceId, m.StartDate, m.EndDate
             FROM logistics.MovementContainers mc
             INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
             WHERE mc.ContainerId = c.Id AND m.Status IN (2, 3)
             ORDER BY m.Id DESC) lg
LEFT JOIN masterdata.Ports fp ON fp.Id = lg.FromPlaceId
LEFT JOIN masterdata.Ports tp ON tp.Id = lg.ToPlaceId
WHERE c.Id = @ContainerId;
GO

/* ================================================================== 2. Why a container cannot be received now */

-- (95) ONE ROW PER CONTAINER: Reason NULL when "Receive goods..." can make its draft now, else the first that applies,
-- in the words of usp_GoodsReceipt_CreateForContainer.
CREATE OR ALTER FUNCTION logistics.fn_Container_ReceiveBlock (@ContainerId INT)
RETURNS TABLE
AS
RETURN
SELECT c.Id AS ContainerId,
       Reason = CAST(CASE
           WHEN c.Status = 8 THEN N'This container is cancelled.'
           WHEN c.Status IN (6, 7) OR og.Status = 2 THEN N'This container is received: its journey is over.'
           WHEN og.Status = 1 THEN N'Container ' + c.ContainerRef + N' already has a draft goods receipt. Open it instead.'
           WHEN c.Status = 1 THEN N'Confirm the container first: a draft container is not received.'
           WHEN mv.Cnt > 0 AND dl.MovementId IS NULL
               THEN c.ContainerRef + N' has not been delivered yet: complete its Delivery movement first, then receive its goods.'
           END AS NVARCHAR(400))
FROM logistics.Containers c
OUTER APPLY (SELECT TOP (1) g.Status FROM purchase.GoodsReceipts g
             WHERE g.ContainerId = c.Id AND g.Status < 3 ORDER BY g.Status DESC, g.Id DESC) og
OUTER APPLY (SELECT Cnt = COUNT(*)
             FROM logistics.MovementContainers mc
             INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
             WHERE mc.ContainerId = c.Id AND m.Status <> 4) mv
OUTER APPLY logistics.fn_Container_LastDelivery(c.Id) dl
WHERE c.Id = @ContainerId;
GO

/* ================================================================== 3. The Containers list: the journey and the receive rule */

-- Re-created (95) from the body of script 81: + @Journey (the list's Journey filter, read in step 1 only when given),
-- the journey columns, CanReceive by fn_Container_ReceiveBlock and its reason. Nothing else changes.
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
    @DeliveredNotReceived BIT          = 0,      -- (65) 1 = delivered (or with a draft receipt) and not received yet
    @NextStep            NVARCHAR(20)  = NULL,   -- (81) Ship | StartPlanned | Complete | NextLeg | Receive (the to-do list)
    @Journey             NVARCHAR(20)  = NULL    -- (95) NotDispatched | OnTheWay | Arrived | Received (fn_Container_Journey)
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    -- (78) PAGES OF UP TO 5,000 (200 before): every container's figures are worked out before the OFFSET, so each page
    -- costs about the whole search - the 2,000 containers of one order took ten calls of 2 s each. The order's Containers
    -- card and a movement's list now ask for them in one page; the grids keep asking for pages of 200 or less.
    -- (81) Since the page is found first (step 1), only the page's rows are worked out; the cap stays.
    IF @PageSize > 5000 SET @PageSize = 5000;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @ContainerRef = NULLIF(LTRIM(RTRIM(@ContainerRef)), N'');
    SET @ContainerNo = NULLIF(LTRIM(RTRIM(@ContainerNo)), N'');
    SET @CommercialInvoiceNo = NULLIF(LTRIM(RTRIM(@CommercialInvoiceNo)), N'');
    SET @BlNo = NULLIF(LTRIM(RTRIM(@BlNo)), N'');
    SET @NextStep = NULLIF(LTRIM(RTRIM(@NextStep)), N'');
    SET @Journey = NULLIF(LTRIM(RTRIM(@Journey)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'ContainerRef', N'ContainerNo', N'OrderDate', N'DispatchDate', N'Eta', N'Status', N'CreatedAtUtc')
        SET @SortColumn = N'OrderDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);

    -- (81) 1. THE PAGE FIRST: the filters and the order of before, on what they read only (the container, who received
    -- it, its latest Delivery, its next step for @NextStep), then every figure of the list for the page's rows only.
    -- They were worked out for every container before the OFFSET: 9.5 s a page on 50,000 containers. RECOMPILE: an
    -- empty filter costs nothing (the next step of every container is read only for @NextStep, the latest Delivery
    -- only for @DeliveredNotReceived).
    CREATE TABLE #Pg (Ord INT NOT NULL PRIMARY KEY, Id INT NOT NULL, TotalCount INT NOT NULL);
    INSERT INTO #Pg (Ord, Id, TotalCount)
    SELECT Ord = ROW_NUMBER() OVER (ORDER BY
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
        c.OrderDate DESC, c.Id DESC), c.Id, COUNT(*) OVER ()
    FROM logistics.Containers c
    -- one row each for a container: OUTER, so that the ones a filter does not read are not read at all
    OUTER APPLY logistics.fn_Container_ReceivedBy(c.Id) rb
    OUTER APPLY logistics.fn_Container_LastDelivery(c.Id) dl
    OUTER APPLY logistics.fn_Container_ShipState(c.Id) ss
    OUTER APPLY logistics.fn_Container_NextStepKind(c.Id, c.Status, ss.MovementCount, ss.ActiveMovementId, ss.PlannedMovementId,
                                                    NULL, ss.LastMovementId, dl.MovementId, rb.GoodsReceiptStatus) nk
    OUTER APPLY logistics.fn_Container_Journey(c.Id) jr                 -- (95) read only for @Journey
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
      AND (@NextStep IS NULL OR nk.Kind = @NextStep                                     -- (81) the to-do list
           OR (@NextStep = N'Receive' AND nk.Kind = N'OpenReceipt'))
      AND (@Journey IS NULL OR jr.JourneyStatus = @Journey)                       -- (95)
    ORDER BY Ord
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY
    OPTION (RECOMPILE);

    -- 2. the list's figures, for the page's rows. Why a planned movement cannot start yet (fn_Movement_StartBlock) is
    -- read once per planned movement of the page, apart: read through each row's ship state it cost seconds a page.
    SELECT p.MovementId, b.Reason, b.StartNotBefore
    INTO #Sb
    FROM (SELECT DISTINCT MovementId = ss.PlannedMovementId
          FROM #Pg pg CROSS APPLY logistics.fn_Container_ShipState(pg.Id) ss
          WHERE ss.PlannedMovementId IS NOT NULL) p
    CROSS APPLY logistics.fn_Movement_StartBlock(p.MovementId) b;

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
           pg.TotalCount,                                              -- (81) of the search (step 1)
           -- (65) goods receipts
           rb.ReceivedBy, rb.GoodsReceiptId, rb.GoodsReceiptNumber, rb.GoodsReceiptStatus,
           DeliveredDate = dl.EndDate,
           -- (95) Receive goods... only once delivered (fn_Container_ReceiveBlock: one place for the rule and its words)
           CanReceive = CAST(CASE WHEN rbk.Reason IS NULL THEN 1 ELSE 0 END AS BIT), ReceiveBlockedReason = rbk.Reason,
           -- (95) the journey: the latest leg's From -> To and whether it is on its way or arrived there
           jr.JourneyStatus, jr.JourneyFromName, jr.JourneyToName, jr.JourneySince, jr.JourneyMovementNo,
           CloseBlockedReason = cb.Reason,
           -- (80) the shipment (fn_Container_ShipState): where it is, the movement in progress carrying it, its next
           -- planned movement (why it cannot start yet, its earliest start) and its last completed one
           ss.MovementCount, ss.PlaceId, ss.PlaceName, ss.PlaceSince,
           ss.ActiveMovementId, ss.ActiveMovementNo, ss.ActiveMovementTypeName, ss.ActiveMovementStage,
           ss.ActiveMovementFromName, ss.ActiveMovementToName, ss.ActiveMovementStartDate, ss.ActiveMovementEta,
           ss.ActiveMovementContainerCount,
           ss.PlannedMovementId, ss.PlannedMovementNo, ss.PlannedMovementTypeName, ss.PlannedMovementStage,
           ss.PlannedMovementFromName, ss.PlannedMovementToName, ss.PlannedMovementDate, ss.PlannedMovementContainerCount,
           PlannedMovementBlockedReason = sb.Reason, PlannedMovementNotBefore = sb.StartNotBefore,   -- (81) once per movement
           ss.LastMovementId, ss.LastMovementNo, ss.LastMovementEndDate,
           -- (81) its next step (fn_Container_NextStepKind), and the planned movement's refusal for this page's rows
           NextStepKind = nk.Kind, NextStepBlockedReason = nk.BlockedReason,
           SortOrd = pg.Ord
    INTO #Page
    FROM #Pg pg
    INNER JOIN logistics.Containers c       ON c.Id = pg.Id      -- (81) the page's rows only
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
    LEFT  JOIN #Sb sb                       ON sb.MovementId = ss.PlannedMovementId          -- (81)
    CROSS APPLY logistics.fn_Container_ReceiveBlock(c.Id) rbk   -- (95)
    CROSS APPLY logistics.fn_Container_Journey(c.Id) jr         -- (95)
    CROSS APPLY logistics.fn_Container_NextStepKind(c.Id, c.Status, ss.MovementCount, ss.ActiveMovementId, ss.PlannedMovementId,
                                                    sb.Reason, ss.LastMovementId, dl.MovementId,
                                                    rb.GoodsReceiptStatus) nk   -- (81) its next step
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
                 ORDER BY CASE WHEN m.Status = 2 THEN 0 ELSE 1 END, COALESCE(m.EndDate, m.StartDate) DESC, m.Id DESC) mv;

    -- 3. THE PROPOSED NEXT LEG (Ship, NextLeg: "Inland transport to Kasumbalesa..."), the usual leg from a place worked
    -- out once per (place, last stage) of the page, not once per row.
    SELECT p.Id AS ContainerId, p.PlaceId, LastStage = CASE WHEN p.MovementCount = 0 THEN NULL ELSE lt.Stage END,
           IsCleared = CAST(CASE WHEN p.Status = 5 THEN 1 ELSE 0 END AS BIT)
    INTO #Leg
    FROM #Page p
    LEFT JOIN logistics.Movements lm      ON lm.Id = p.LastMovementId
    LEFT JOIN masterdata.MovementTypes lt ON lt.Id = lm.MovementTypeId
    WHERE p.NextStepKind IN (N'Ship', N'NextLeg');

    SELECT g.PlaceId, g.LastStage, h.MovementTypeId, h.ToPlaceId, h.Legs
    INTO #Hist
    FROM (SELECT DISTINCT PlaceId, LastStage FROM #Leg WHERE PlaceId IS NOT NULL) g
    CROSS APPLY logistics.fn_Movement_NextLegHistory(g.PlaceId, g.LastStage) h;

    SELECT p.*,
           ProposedTypeId = pr.TypeId, ProposedTypeCode = pr.TypeCode, ProposedTypeName = pr.TypeName, ProposedStage = pr.Stage,
           ProposedFromPlaceId = pr.FromPlaceId, ProposedFromName = pr.FromName,
           ProposedToPlaceId = pr.ToPlaceId, ProposedToName = pr.ToName,
           ProposalSource = pr.Source, ProposalLegs = pr.Legs, ProposedIsStay = pr.IsStay
    FROM #Page p
    LEFT JOIN #Leg l  ON l.ContainerId = p.Id
    LEFT JOIN #Hist h ON h.PlaceId = l.PlaceId AND ISNULL(h.LastStage, N'') = ISNULL(l.LastStage, N'')
    OUTER APPLY (SELECT x.*
                 FROM logistics.fn_Container_NextLegProposal(p.Id, l.PlaceId, l.LastStage, l.IsCleared,
                                                             h.MovementTypeId, h.ToPlaceId, h.Legs) x
                 WHERE l.ContainerId IS NOT NULL) pr
    ORDER BY p.SortOrd;
END
GO

/* ================================================================== 4. The container page: the same */

-- Re-created (95) from the body of script 82: + the journey columns, CanReceive by fn_Container_ReceiveBlock and its
-- reason. Nothing else changes.
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
           -- (95) Receive goods... only once delivered (fn_Container_ReceiveBlock)
           CanReceive = CAST(CASE WHEN rbk.Reason IS NULL THEN 1 ELSE 0 END AS BIT), ReceiveBlockedReason = rbk.Reason,
           jr.JourneyStatus, jr.JourneyFromName, jr.JourneyToName, jr.JourneySince, jr.JourneyMovementNo,   -- (95)
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
           ss.LastMovementId, ss.LastMovementNo, ss.LastMovementEndDate,
           -- (81) its next step (fn_Container_NextStep): the label of its button, the proposed next leg, and for a movement
           -- to complete the leg proposed after it
           NextStepKind = nx.Kind, NextStepBlockedReason = nx.BlockedReason, nx.HasTypedDates, nx.PlaceKind, nx.LastStage,
           NextStepMovementId = nx.MovementId, NextStepMovementNo = nx.MovementNo, NextStepMovementStage = nx.MovementStage,
           NextStepMovementTypeName = nx.MovementTypeName, NextStepMovementToName = nx.MovementToName,
           NextStepMovementContainerCount = nx.MovementContainerCount, NextStepNotBefore = nx.MovementNotBefore,
           nx.ProposedTypeId, nx.ProposedTypeCode, nx.ProposedTypeName, nx.ProposedStage,
           nx.ProposedFromPlaceId, nx.ProposedFromName, nx.ProposedToPlaceId, nx.ProposedToName,
           nx.ProposalSource, nx.ProposalLegs, nx.ProposedIsStay,
           nx.ThenTypeId, nx.ThenTypeName, nx.ThenStage, nx.ThenToPlaceId, nx.ThenToName, nx.ThenIsStay, nx.ThenDefault
    FROM logistics.Containers c
    INNER JOIN masterdata.ContainerTypes ct ON ct.Id = c.ContainerTypeId
    INNER JOIN masterdata.Branches b        ON b.Id = c.BranchId
    LEFT  JOIN masterdata.Warehouses w      ON w.Id = c.WarehouseId
    CROSS APPLY logistics.fn_ContainerFill(c.Id) fl
    CROSS APPLY logistics.fn_Container_ReceivedBy(c.Id) rb      -- (65) who received it; its open goods receipt
    OUTER APPLY logistics.fn_Container_LastDelivery(c.Id) dl    -- (65) its latest completed Delivery
    OUTER APPLY (SELECT b.Reason FROM logistics.fn_Container_CloseBlock(c.Id) b WHERE c.Status = 6) cb  -- (65) why not Close
    CROSS APPLY logistics.fn_Container_ShipState(c.Id) ss       -- (80) the shipment
    CROSS APPLY logistics.fn_Container_ReceiveBlock(c.Id) rbk   -- (95)
    CROSS APPLY logistics.fn_Container_Journey(c.Id) jr         -- (95)
    OUTER APPLY logistics.fn_Container_NextStep(c.Id) nx        -- (81) its next step
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
                 -- (82) the received value, else the estimate of the cost rule (fn_ContainerLine_FobEstimate)
                 OUTER APPLY (SELECT UnitFob = e.UnitFobBase FROM logistics.fn_ContainerLine_FobEstimate(cl.Id) e) u
                 WHERE cl.ContainerId = c.Id) cost
    WHERE c.Id = @Id;

    -- 2: lines. FOB per unit: once the goods are received the container line's value (frozen by an offload of before; set by
    -- the goods receipt and moved by the invoices since), else (82) the estimate of what the goods receipt will give it: the
    -- invoice pieces its matching will give the line, those of invoices that change item costs at their price, every other
    -- piece at the order price (fn_ContainerLine_FobEstimate).
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
           UnitFobBase = COALESCE(cl.FobCostBase, fe.EstimatedFobBase),                    -- (82)
           FobSource = fe.FobSource,                                                     -- (82)
           cl.FobCostBase, cl.ChargesBase,
           DraftChargesBase = ISNULL(dch.Draft, 0),
           ChargesPerUnitBase = cl.ChargesBase / NULLIF(ISNULL(cl.ReceivedQuantityBase, cl.QuantityBase), 0),
           LandedCostBase = COALESCE(cl.LandedCostBase,
                                     fe.EstimatedFobBase + cl.ChargesBase / NULLIF(cl.QuantityBase, 0)),   -- (82)
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
    CROSS APPLY logistics.fn_ContainerLine_FobEstimate(cl.Id) fe                    -- (82) the estimate of the cost rule
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

/* ================================================================== 5. Receive goods... on a container: only once delivered */

-- Re-created (95) from the body of script 72: + the rule of fn_Container_ReceiveBlock for "Receive goods..." (@Silent =
-- 0); the Delivery hook (@Silent = 1) runs once the Delivery is completed and is unchanged. Nothing else changes.
CREATE OR ALTER PROCEDURE purchase.usp_GoodsReceipt_CreateForContainer
    @ContainerId  INT,
    @DocumentDate DATE         = NULL,
    @MovementId   INT          = NULL,
    @UserId       INT          = NULL,
    @Silent       BIT          = 0,
    @NewId        INT          = NULL OUTPUT,
    @SkipReason   NVARCHAR(20) = NULL OUTPUT,
    @WarehouseId  INT          = NULL,
    @Lines        purchase.tvp_GoodsReceiptLine READONLY
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @NewId = NULL;
    SET @SkipReason = NULL;

    DECLARE @Status TINYINT, @Ref NVARCHAR(30), @BranchId INT, @CtWarehouse INT, @OpenId INT, @OpenNo NVARCHAR(30),
            @OpenStatus TINYINT, @Msg NVARCHAR(400);

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = Status, @Ref = ContainerRef, @BranchId = BranchId, @CtWarehouse = WarehouseId
        FROM logistics.Containers WITH (UPDLOCK, HOLDLOCK) WHERE Id = @ContainerId;
        IF @Status IS NULL THROW 63006, 'Container not found.', 1;

        SELECT TOP (1) @OpenId = Id, @OpenNo = DocumentNumber, @OpenStatus = Status
        FROM purchase.GoodsReceipts WITH (UPDLOCK, HOLDLOCK)
        WHERE ContainerId = @ContainerId AND Status < 3
        ORDER BY Status DESC, Id DESC;

        SET @SkipReason = CASE WHEN @Status = 8 THEN N'Cancelled'
                               WHEN @Status = 1 THEN N'NotConfirmed'
                               WHEN @Status IN (6, 7) OR @OpenStatus = 2 THEN N'Received'
                               WHEN @OpenStatus = 1 THEN N'HasDraft'
                               WHEN NOT EXISTS (SELECT 1 FROM logistics.ContainerLines WHERE ContainerId = @ContainerId) THEN N'NoLines' END;
        IF @SkipReason IS NOT NULL
        BEGIN
            IF @Silent = 1
            BEGIN
                COMMIT TRANSACTION;
                RETURN;
            END
            IF @OpenId IS NOT NULL
            BEGIN
                SET @Msg = N'Container ' + @Ref + N' already has ' + ISNULL(N'goods receipt ' + @OpenNo, N'a draft goods receipt') + N'. Open it instead.';
                THROW 63013, @Msg, 1;
            END
            IF @SkipReason = N'NoLines'
            BEGIN
                SET @Msg = N'Container ' + @Ref + N' has no lines to receive.';
                THROW 63009, @Msg, 1;
            END;
            THROW 63010, 'Only a confirmed container that is not received yet can be received.', 1;
        END

        -- (95) RECEIVE GOODS... ONLY ONCE DELIVERED: a container that travels with movements is received after its
        -- Delivery is completed (the Delivery drafts it, or Receive goods... after it). One followed by typed dates only
        -- (no movement) keeps the rule of before. The Delivery hook (@Silent = 1) runs after the completion: delivered.
        IF @Silent = 0
        BEGIN
            SET @Msg = (SELECT b.Reason FROM logistics.fn_Container_ReceiveBlock(@ContainerId) b);
            IF @Msg IS NOT NULL THROW 63010, @Msg, 1;
        END

        -- the received pieces given by the dialog: rows of this container's lines, each once, in a unit of the item
        SELECT TOP (1) @Msg = N'Line ' + CAST(r.LineNumber AS NVARCHAR(10)) + N': ' +
            CASE WHEN cl.Id IS NULL THEN N'it is not a line of container ' + @Ref + N'.'
                 WHEN iu.Id IS NULL THEN N'the unit does not belong to the item of the container line.'
                 WHEN r.Quantity < 0 THEN N'the received quantity cannot be negative.'
                 ELSE N'the container line is given twice.' END
        FROM @Lines r
        LEFT JOIN logistics.ContainerLines cl ON cl.Id = r.ContainerLineId AND cl.ContainerId = @ContainerId
        LEFT JOIN inventory.ItemUnits iu      ON iu.Id = r.ItemUnitId AND iu.ItemId = cl.ItemId
        WHERE cl.Id IS NULL OR iu.Id IS NULL OR r.Quantity < 0
           OR (SELECT COUNT(*) FROM @Lines d WHERE d.ContainerLineId = r.ContainerLineId) > 1
        ORDER BY r.LineNumber;
        IF @Msg IS NOT NULL THROW 63000, @Msg, 1;

        DECLARE @T purchase.tvp_GoodsReceiptLine;
        INSERT INTO @T (LineNumber, ItemId, ItemUnitId, Quantity, PoLineId, ContainerLineId, ExpectedQuantityBase,
                        VarianceReasonCode, VarianceReason, CloseShort, ExpiryDate, Notes)
        SELECT ROW_NUMBER() OVER (ORDER BY cl.LineNumber), cl.ItemId, COALESCE(bu.Id, cl.ItemUnitId),
               CASE WHEN r.ContainerLineId IS NOT NULL THEN r.Quantity * iu.PackingFormula ELSE cl.QuantityBase END,
               cl.PoLineId, cl.Id, cl.QuantityBase, r.VarianceReasonCode, r.VarianceReason, 0,
               COALESCE(r.ExpiryDate, pol.ExpiryDate), r.Notes
        FROM logistics.ContainerLines cl
        INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = cl.PoLineId
        OUTER APPLY (SELECT TOP (1) u.Id FROM inventory.ItemUnits u WHERE u.ItemId = cl.ItemId AND u.IsBaseUnit = 1 ORDER BY u.Id) bu
        LEFT  JOIN @Lines r                           ON r.ContainerLineId = cl.Id
        LEFT  JOIN inventory.ItemUnits iu             ON iu.Id = r.ItemUnitId
        WHERE cl.ContainerId = @ContainerId;

        -- AN INACTIVE ITEM: Save refuses the draft (rule 12). Silent (the Delivery hook), the container is skipped with its
        -- reason, like the other skips, so the completion goes on; otherwise Save says which line.
        IF @Silent = 1 AND EXISTS (SELECT 1 FROM @T t INNER JOIN inventory.Items i ON i.Id = t.ItemId WHERE i.IsActive = 0)
        BEGIN
            SET @SkipReason = N'InactiveItem';
            COMMIT TRANSACTION;
            RETURN;
        END

        -- "Receive into": the container's warehouse only when it can take the goods (active, of the container's branch, and
        -- (72) at the bottom of the tree, script 70); otherwise the draft is made without one, "to choose", and
        -- usp_GoodsReceipt_CreateForMovement says why
        IF @WarehouseId IS NULL
            SET @WarehouseId = (SELECT w.Id FROM masterdata.Warehouses w WHERE w.Id = @CtWarehouse AND w.IsActive = 1 AND w.BranchId = @BranchId
                                                                          AND masterdata.fn_Warehouse_IsLeaf(w.Id) = 1);
        IF @DocumentDate IS NULL
            SET @DocumentDate = COALESCE((SELECT EndDate FROM logistics.Movements WHERE Id = @MovementId), CAST(SYSUTCDATETIME() AS DATE));

        EXEC purchase.usp_GoodsReceipt_Save @SourceKind = N'Container', @ContainerId = @ContainerId, @MovementId = @MovementId,
             @DocumentDate = @DocumentDate, @BranchId = @BranchId, @WarehouseId = @WarehouseId, @Lines = @T,
             @UserId = @UserId, @NewId = @NewId OUTPUT;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 6. Check */

-- 95a: how many open containers each journey status holds; 95b: the containers that could be received by hand before
-- and must now be delivered first (they keep a draft or receipt they already have)
SELECT j.JourneyStatus, Containers = COUNT(*)
FROM logistics.Containers c CROSS APPLY logistics.fn_Container_Journey(c.Id) j
GROUP BY j.JourneyStatus ORDER BY j.JourneyStatus;
SELECT c.ContainerRef, c.Status, b.Reason
FROM logistics.Containers c CROSS APPLY logistics.fn_Container_ReceiveBlock(c.Id) b
WHERE c.Status BETWEEN 2 AND 5 AND b.Reason LIKE N'%has not been delivered yet%'
ORDER BY c.ContainerRef;
PRINT 'Script 95 applied: the containers'' journey (From -> To, Not dispatched / On the way / Arrived / Received); Receive goods... only once delivered.';
GO
