/* =====================================================================================
   Inventory_Shipment - 28: MANY CONTAINERS PER ORDER - auto-plan, bulk actions, a shipment for the chosen
                            containers, a charge copied to other containers, approvers of purchase orders

   1. Auto-plan (e.g. an order of 30 containers)
        logistics.usp_Container_PlanFromOrder proposes the containers of an approved order for one container type.
        Nothing is saved. Pieces per container of an item = the value typed in the dialog, else the item's Container
        unit (script 25), else the capacity of the container type.
          a. every order line first fills whole containers of its own item (in order line order);
          b. what is left of every line is packed without cutting a line (first fit, largest first); when cutting
             lines needs fewer containers than that, the containers are filled to the brim instead and a cut line goes
             on in the next container. With @MixRemainders = 0 the rest of every line gets its own container.
        At most 200 containers per plan.
        logistics.usp_Container_CreateBatch creates the (edited) plan in ONE transaction, every container through
        usp_Container_Save (same checks as one by one), optionally confirmed. Give it the same capacities as the
        proposal. Each container gets its equivalent capacity in pieces as Max units (a container full of an 84-piece
        item holds 84; a mixed container of 42 x 84-piece + 60 x 120-piece items holds 102), so a full container shows
        100 %. That Max units is fixed at creation: when its items are changed later on the container page, check the
        Max units there (it is editable, as before).
   2. Bulk actions on selected containers: usp_Container_SetNumbers (container no. + seal no.),
        usp_Container_ConfirmMany, usp_Container_DeleteMany (drafts only).
   3. A shipment for the chosen containers (e.g. the 5 of 30 still waiting):
        logistics.usp_Movement_ShipContainers confirms the drafts, creates the movement (default SEA, from the common
        port of loading to the common port of destination) and starts it, in one transaction; it copies vessel,
        voyage, shipping line, B/L and ETA to the containers (and the ports when they have none).
        @StartNow = 0 only plans the movement.
   4. A charge copied to other containers (e.g. 1,000 USD on one container, the same on four others):
        logistics.usp_ContainerCharge_CopyCandidates lists the containers that can receive it;
        logistics.usp_ContainerCharge_CopyToContainers creates one DRAFT per container in the same group as the
        original (same type, provider, reference, currency and rate), optionally posted at once.
   5. Purchase order approval: the roles Owner and Manager and the system (administrator) roles hold
        purchase.orders.approve, so their users receive the approval email (script 26). Nothing else changes in SQL
        for "Create & send": the application saves the draft, then calls purchase.usp_PurchaseOrder_RequestApproval.

   Errors (no new number): 69000 validation, 69005 not editable, 69006 not found, 69007 over capacity
           (usp_Container_Save), 69008 more than the order line still allows, 69009 nothing to create,
           69013 container number already used, 70000 validation, 70001 the container already has this charge,
           70006 not found, 70010 invalid status, 70012 container travelling with another movement.
   Errors raised for one container of a batch start with "Container 3 of 30: " or with its reference.

   Requires script 27. Idempotent: re-applied at every API start-up through Schema.sql.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'logistics.ContainerCharges', N'U') IS NULL OR TYPE_ID(N'logistics.tvp_ContainerLoadLine') IS NULL
BEGIN
    RAISERROR ('Run script 27 before this script.', 16, 1);
    SET NOEXEC ON;
END
GO

/* ================================================================== 1. Types */

IF TYPE_ID(N'logistics.tvp_ContainerPlanLine') IS NULL
BEGIN
    CREATE TYPE logistics.tvp_ContainerPlanLine AS TABLE
    (
        Seq          INT NOT NULL,      -- container of the plan: 1, 2, 3...
        PoLineId     INT NOT NULL,      -- purchase ORDER line
        QuantityBase INT NOT NULL,      -- pieces
        OilIncluded  BIT NULL,          -- NULL = yes when the item has an oil quantity per unit
        PRIMARY KEY (Seq, PoLineId)
    );
    PRINT 'Created type logistics.tvp_ContainerPlanLine';
END
GO

IF TYPE_ID(N'logistics.tvp_ItemCapacity') IS NULL
BEGIN
    CREATE TYPE logistics.tvp_ItemCapacity AS TABLE (ItemId INT NOT NULL PRIMARY KEY, PcsPerContainer INT NOT NULL);
    PRINT 'Created type logistics.tvp_ItemCapacity';
END
GO

IF TYPE_ID(N'logistics.tvp_ContainerNumber') IS NULL
BEGIN
    CREATE TYPE logistics.tvp_ContainerNumber AS TABLE
    (
        ContainerId INT          NOT NULL PRIMARY KEY,
        ContainerNo NVARCHAR(20) NULL,        -- empty = none
        SealNo      NVARCHAR(30) NULL
    );
    PRINT 'Created type logistics.tvp_ContainerNumber';
END
GO

/* ================================================================== 2. Auto-plan: proposal (nothing saved) */

-- Three result sets: 1 containers (Seq, ItemCount, Units, FillPct, MaxUnits, ItemSummary), 2 their lines,
-- 3 the order lines (available, planned, pieces per container and where that number comes from).
CREATE OR ALTER PROCEDURE logistics.usp_Container_PlanFromOrder
    @PurchaseOrderId INT,
    @ContainerTypeId INT,
    @MixRemainders   BIT = 1,       -- 0 = the rest of every order line gets its own container
    @Capacities      logistics.tvp_ItemCapacity READONLY     -- pieces per container typed by the user (optional)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                   WHERE d.Id = @PurchaseOrderId AND dt.Code = N'PO' AND d.Status = 2)
        THROW 69000, 'The purchase order must be approved and still open.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.ContainerTypes WHERE Id = @ContainerTypeId AND IsActive = 1)
        THROW 69000, 'Container type not found or inactive.', 1;
    IF EXISTS (SELECT 1 FROM @Capacities WHERE PcsPerContainer <= 0)
        THROW 69000, 'Pieces per container must be greater than zero.', 1;

    DECLARE @TypeCap INT = (SELECT MaxUnits FROM masterdata.ContainerTypes WHERE Id = @ContainerTypeId);
    DECLARE @Msg NVARCHAR(400);

    -- order lines: what can still be loaded (ordered - invoiced without container - loaded in other containers)
    DECLARE @Lines TABLE
    (
        PoLineId      INT          NOT NULL PRIMARY KEY,
        PoLineNumber  INT          NOT NULL,
        ItemId        INT          NOT NULL,
        OrderedBase   INT          NOT NULL,
        AvailableBase INT          NOT NULL,
        Cap           INT          NULL,
        CapSource     NVARCHAR(10) NOT NULL,     -- Entered | Item | Type | None
        OilIncluded   BIT          NOT NULL,
        Remaining     INT          NOT NULL
    );
    INSERT INTO @Lines (PoLineId, PoLineNumber, ItemId, OrderedBase, AvailableBase, Cap, CapSource, OilIncluded, Remaining)
    SELECT l.Id, l.LineNumber, l.ItemId, l.QuantityBase,
           l.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0),
           COALESCE(cap.PcsPerContainer, NULLIF(cnt.PackingFormula, 0), @TypeCap),
           CASE WHEN cap.PcsPerContainer IS NOT NULL THEN N'Entered'
                WHEN cnt.PackingFormula > 0 THEN N'Item'
                WHEN @TypeCap IS NOT NULL THEN N'Type'
                ELSE N'None' END,
           CASE WHEN i.OilQtyPerUnit > 0 THEN 1 ELSE 0 END,
           0
    FROM purchase.PurchaseDocumentLines l
    INNER JOIN inventory.Items i ON i.Id = l.ItemId
    LEFT  JOIN @Capacities cap   ON cap.ItemId = l.ItemId
    OUTER APPLY (SELECT Qty = SUM(x.QuantityBase) FROM purchase.PurchaseDocumentLines x
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
                 WHERE x.SourceLineId = l.Id AND x.ContainerLineId IS NULL AND xd.Status IN (1, 2, 4)) dir
    OUTER APPLY (SELECT Qty = SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                 INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                 WHERE cl.PoLineId = l.Id AND c.Status <> 8) oth
    OUTER APPLY (SELECT TOP (1) u.PackingFormula FROM inventory.ItemUnits u
                 INNER JOIN masterdata.UnitTypes t ON t.Id = u.UnitTypeId
                 WHERE u.ItemId = l.ItemId AND t.IsContainer = 1
                 ORDER BY u.Id) cnt
    WHERE l.DocumentId = @PurchaseOrderId;

    SELECT TOP (1) @Msg = N'Line ' + CAST(l.PoLineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): the number of pieces per container '
                        + N'is unknown. Enter it, or give the item a Container unit or the container type a capacity.'
    FROM @Lines l INNER JOIN inventory.Items i ON i.Id = l.ItemId
    WHERE l.AvailableBase > 0 AND l.Cap IS NULL
    ORDER BY l.PoLineNumber;
    IF @Msg IS NOT NULL THROW 69000, @Msg, 1;

    IF (SELECT SUM(AvailableBase / Cap) FROM @Lines WHERE AvailableBase > 0) > 200
        THROW 69000, 'The plan would need more than 200 containers. Check the pieces per container, or plan the order in parts.', 1;

    DECLARE @Plan TABLE (Seq INT NOT NULL, PoLineId INT NOT NULL, QuantityBase INT NOT NULL, PRIMARY KEY (Seq, PoLineId));
    DECLARE @Seq INT = 0, @PoLineId INT, @Avail INT, @Cap INT, @Full INT, @k INT, @Rem INT;

    -- a. whole containers of one item
    DECLARE full_cur CURSOR LOCAL STATIC READ_ONLY FORWARD_ONLY FOR
        SELECT PoLineId, AvailableBase, Cap FROM @Lines WHERE AvailableBase > 0 ORDER BY PoLineNumber;
    OPEN full_cur;
    FETCH NEXT FROM full_cur INTO @PoLineId, @Avail, @Cap;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Full = @Avail / @Cap;
        SET @k = 0;
        WHILE @k < @Full
        BEGIN
            SET @k = @k + 1;
            SET @Seq = @Seq + 1;
            INSERT INTO @Plan (Seq, PoLineId, QuantityBase) VALUES (@Seq, @PoLineId, @Cap);
        END
        UPDATE @Lines SET Remaining = @Avail - @Full * @Cap WHERE PoLineId = @PoLineId;
        FETCH NEXT FROM full_cur INTO @PoLineId, @Avail, @Cap;
    END
    CLOSE full_cur;
    DEALLOCATE full_cur;

    -- b. the rest of every line
    DECLARE @FirstRest INT = @Seq;
    IF ISNULL(@MixRemainders, 1) = 0
    BEGIN
        INSERT INTO @Plan (Seq, PoLineId, QuantityBase)
        SELECT @FirstRest + ROW_NUMBER() OVER (ORDER BY PoLineNumber), PoLineId, Remaining
        FROM @Lines WHERE Remaining > 0;
    END
    ELSE
    BEGIN
        DECLARE @Bins TABLE (Seq INT NOT NULL PRIMARY KEY, Used DECIMAL(38,20) NOT NULL);
        DECLARE @RestA TABLE (Seq INT NOT NULL, PoLineId INT NOT NULL, QuantityBase INT NOT NULL, PRIMARY KEY (Seq, PoLineId));
        DECLARE @RestB TABLE (Seq INT NOT NULL, PoLineId INT NOT NULL, QuantityBase INT NOT NULL, PRIMARY KEY (Seq, PoLineId));
        DECLARE @Frac DECIMAL(38,20), @Bin INT, @Need INT;

        -- first fit, largest first, a line is never cut
        DECLARE ffd_cur CURSOR LOCAL STATIC READ_ONLY FORWARD_ONLY FOR
            SELECT PoLineId, Remaining, Cap FROM @Lines WHERE Remaining > 0
            ORDER BY CAST(Remaining AS DECIMAL(38,20)) / Cap DESC, PoLineNumber;
        OPEN ffd_cur;
        FETCH NEXT FROM ffd_cur INTO @PoLineId, @Rem, @Cap;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @Frac = CAST(@Rem AS DECIMAL(38,20)) / @Cap;
            SET @Bin = NULL;
            SELECT TOP (1) @Bin = Seq FROM @Bins WHERE Used + @Frac <= 1.000001 ORDER BY Seq;
            IF @Bin IS NULL
            BEGIN
                SET @Bin = @FirstRest + 1 + (SELECT COUNT(*) FROM @Bins);
                INSERT INTO @Bins (Seq, Used) VALUES (@Bin, 0);
            END
            UPDATE @Bins SET Used = Used + @Frac WHERE Seq = @Bin;
            INSERT INTO @RestA (Seq, PoLineId, QuantityBase) VALUES (@Bin, @PoLineId, @Rem);
            FETCH NEXT FROM ffd_cur INTO @PoLineId, @Rem, @Cap;
        END
        CLOSE ffd_cur;
        DEALLOCATE ffd_cur;

        SET @Need = CEILING((SELECT SUM(CAST(Remaining AS DECIMAL(38,20)) / Cap) FROM @Lines WHERE Remaining > 0) - 0.000001);

        IF (SELECT COUNT(*) FROM @Bins) > @Need
        BEGIN
            -- cutting lines saves containers: fill every container to the brim, a line goes on in the next container
            DECLARE @Used DECIMAL(38,20) = 0, @Open BIT = 0, @Fits INT, @Take INT, @SeqB INT = @FirstRest;
            DECLARE nf_cur CURSOR LOCAL STATIC READ_ONLY FORWARD_ONLY FOR
                SELECT PoLineId, Remaining, Cap FROM @Lines WHERE Remaining > 0
                ORDER BY CAST(Remaining AS DECIMAL(38,20)) / Cap DESC, PoLineNumber;
            OPEN nf_cur;
            FETCH NEXT FROM nf_cur INTO @PoLineId, @Rem, @Cap;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                WHILE @Rem > 0
                BEGIN
                    IF @Open = 0
                    BEGIN
                        SET @SeqB = @SeqB + 1;
                        SET @Used = 0;
                        SET @Open = 1;
                    END
                    SET @Fits = FLOOR((1 - @Used) * @Cap + 0.000001);
                    IF @Fits <= 0
                        SET @Open = 0;
                    ELSE
                    BEGIN
                        SET @Take = CASE WHEN @Rem < @Fits THEN @Rem ELSE @Fits END;
                        INSERT INTO @RestB (Seq, PoLineId, QuantityBase) VALUES (@SeqB, @PoLineId, @Take);
                        SET @Used = @Used + CAST(@Take AS DECIMAL(38,20)) / @Cap;
                        SET @Rem = @Rem - @Take;
                        IF @Rem > 0 OR @Used >= 0.999999 SET @Open = 0;   -- a cut line goes on in the next container
                    END
                END
                FETCH NEXT FROM nf_cur INTO @PoLineId, @Rem, @Cap;
            END
            CLOSE nf_cur;
            DEALLOCATE nf_cur;
        END

        IF EXISTS (SELECT 1 FROM @RestB) AND (SELECT COUNT(DISTINCT Seq) FROM @RestB) < (SELECT COUNT(*) FROM @Bins)
            INSERT INTO @Plan (Seq, PoLineId, QuantityBase) SELECT Seq, PoLineId, QuantityBase FROM @RestB;
        ELSE
            INSERT INTO @Plan (Seq, PoLineId, QuantityBase) SELECT Seq, PoLineId, QuantityBase FROM @RestA;
    END

    IF (SELECT COUNT(DISTINCT Seq) FROM @Plan) > 200
        THROW 69000, 'The plan would need more than 200 containers. Check the pieces per container, or plan the order in parts.', 1;

    -- 1: containers. MaxUnits = equivalent capacity in pieces; a container full within 0.0001 % counts as full
    --    (the same rule as usp_Container_CreateBatch, so an unedited plan never raises the capacity warning).
    SELECT x.Seq, x.ItemCount, x.Units,
           FillPct  = CAST(ROUND(100 * x.Fill, 1) AS DECIMAL(9,1)),
           MaxUnits = CASE WHEN x.Fill <= 1.000001 AND FLOOR(x.Units / x.Fill + 0.000001) < x.Units THEN x.Units
                           ELSE CAST(FLOOR(x.Units / x.Fill + 0.000001) AS INT) END,
           ItemSummary = CASE WHEN x.ItemCount = 1 THEN x.FirstItem ELSE N'Mixed - ' + CAST(x.ItemCount AS NVARCHAR(10)) + N' items' END
    FROM (SELECT p.Seq,
                 ItemCount = COUNT(DISTINCT l.ItemId),
                 Units     = SUM(p.QuantityBase),
                 Fill      = SUM(CAST(p.QuantityBase AS DECIMAL(38,20)) / l.Cap),
                 FirstItem = MIN(i.ItemCode)
          FROM @Plan p
          INNER JOIN @Lines l          ON l.PoLineId = p.PoLineId
          INNER JOIN inventory.Items i ON i.Id = l.ItemId
          GROUP BY p.Seq) x
    ORDER BY x.Seq;

    -- 2: lines of every container
    SELECT p.Seq,
           LineNumber = ROW_NUMBER() OVER (PARTITION BY p.Seq ORDER BY l.PoLineNumber),
           p.PoLineId, l.PoLineNumber, l.ItemId, i.ItemCode, i.ItemName, i.Model, p.QuantityBase,
           PcsPerContainer = l.Cap, l.OilIncluded, i.OilQtyPerUnit
    FROM @Plan p
    INNER JOIN @Lines l          ON l.PoLineId = p.PoLineId
    INNER JOIN inventory.Items i ON i.Id = l.ItemId
    ORDER BY p.Seq, l.PoLineNumber;

    -- 3: order lines
    SELECT l.PoLineId, l.PoLineNumber, l.ItemId, i.ItemCode, i.ItemName, i.Model,
           l.OrderedBase,
           AvailableBase    = CASE WHEN l.AvailableBase > 0 THEN l.AvailableBase ELSE 0 END,
           PlannedBase      = ISNULL(pl.Qty, 0),
           PcsPerContainer  = l.Cap,
           CapacitySource   = l.CapSource,
           ContainersNeeded = CAST(CASE WHEN l.AvailableBase > 0 THEN CAST(l.AvailableBase AS DECIMAL(19,4)) / NULLIF(l.Cap, 0) ELSE 0 END AS DECIMAL(9,2)),
           l.OilIncluded
    FROM @Lines l
    INNER JOIN inventory.Items i ON i.Id = l.ItemId
    OUTER APPLY (SELECT Qty = SUM(p.QuantityBase) FROM @Plan p WHERE p.PoLineId = l.PoLineId) pl
    ORDER BY l.PoLineNumber;
END
GO

/* ================================================================== 3. Auto-plan: create the containers */

-- Creates every container of the plan in ONE transaction (all or nothing), each through usp_Container_Save.
-- Header values are the same for every container; the order's branch and warehouse by default. Send Seq 1..N in the
-- order shown to the user and the same @Capacities as for the proposal: an error names "Container <Seq> of <N>".
-- Returns the created containers (Seq, ContainerId, ContainerRef, Status, TotalLines, TotalAllocatedBase, MaxUnits,
-- UtilizationPct, RowVersion).
CREATE OR ALTER PROCEDURE logistics.usp_Container_CreateBatch
    @PurchaseOrderId     INT,
    @ContainerTypeId     INT,
    @OrderDate           DATE           = NULL,   -- NULL = today
    @BranchId            INT            = NULL,   -- NULL = the order's branch
    @WarehouseId         INT            = NULL,   -- NULL = the order's warehouse (offloading destination)
    @ShippingMethod      NVARCHAR(10)   = N'Sea',
    @CountryOfOrigin     NCHAR(2)       = NULL,
    @ForwarderId         INT            = NULL,
    @ShippingLine        NVARCHAR(100)  = NULL,
    @PortOfLoadingId     INT            = NULL,
    @PortOfDestinationId INT            = NULL,
    @FinalDestinationId  INT            = NULL,
    @Eta                 DATE           = NULL,
    @FreeDays            INT            = NULL,
    @Plan                logistics.tvp_ContainerPlanLine READONLY,
    @Capacities          logistics.tvp_ItemCapacity READONLY,     -- the same values as for the proposal
    @AllowOverCapacity   BIT            = 0,
    @Confirm             BIT            = 0,                      -- 1 = the new containers are confirmed at once
    @UserId              INT            = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @OrderDate IS NULL SET @OrderDate = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @OrderBranch INT, @OrderWarehouse INT, @OrderNo NVARCHAR(30);
    SELECT @OrderBranch = d.BranchId, @OrderWarehouse = d.WarehouseId, @OrderNo = d.DocumentNumber
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    WHERE d.Id = @PurchaseOrderId AND dt.Code = N'PO' AND d.Status = 2;
    IF @OrderBranch IS NULL THROW 69000, 'The purchase order must be approved and still open.', 1;
    SET @BranchId = ISNULL(@BranchId, @OrderBranch);
    SET @WarehouseId = ISNULL(@WarehouseId, @OrderWarehouse);

    IF NOT EXISTS (SELECT 1 FROM masterdata.ContainerTypes WHERE Id = @ContainerTypeId AND IsActive = 1)
        THROW 69000, 'Container type not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM @Plan) THROW 69009, 'The plan has no container to create.', 1;
    IF EXISTS (SELECT 1 FROM @Plan WHERE Seq < 1 OR QuantityBase <= 0)
        THROW 69000, 'Every planned quantity must be greater than zero.', 1;
    IF (SELECT COUNT(DISTINCT Seq) FROM @Plan) > 200
        THROW 69000, 'At most 200 containers can be created at once.', 1;
    IF EXISTS (SELECT 1 FROM @Capacities WHERE PcsPerContainer <= 0)
        THROW 69000, 'Pieces per container must be greater than zero.', 1;

    DECLARE @Msg NVARCHAR(400);
    IF EXISTS (SELECT 1 FROM @Plan p LEFT JOIN purchase.PurchaseDocumentLines pol ON pol.Id = p.PoLineId
               WHERE pol.Id IS NULL OR pol.DocumentId <> @PurchaseOrderId)
    BEGIN
        SET @Msg = N'A planned line is not a line of order ' + ISNULL(@OrderNo, N'(draft)') + N'. Propose the plan again.';
        THROW 69000, @Msg, 1;
    END

    -- pieces per container of every item, as in the proposal
    DECLARE @TypeCap INT = (SELECT MaxUnits FROM masterdata.ContainerTypes WHERE Id = @ContainerTypeId);
    DECLARE @Caps TABLE (ItemId INT NOT NULL PRIMARY KEY, Cap INT NULL);
    INSERT INTO @Caps (ItemId, Cap)
    SELECT x.ItemId, COALESCE(cap.PcsPerContainer, NULLIF(cnt.PackingFormula, 0), @TypeCap)
    FROM (SELECT DISTINCT pol.ItemId
          FROM @Plan p INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = p.PoLineId) x
    LEFT JOIN @Capacities cap ON cap.ItemId = x.ItemId
    OUTER APPLY (SELECT TOP (1) u.PackingFormula FROM inventory.ItemUnits u
                 INNER JOIN masterdata.UnitTypes t ON t.Id = u.UnitTypeId
                 WHERE u.ItemId = x.ItemId AND t.IsContainer = 1
                 ORDER BY u.Id) cnt;

    -- containers in plan order, each with its equivalent capacity in pieces (NULL = the type's capacity); a container
    -- full within 0.0001 % counts as full, as in usp_Container_PlanFromOrder
    DECLARE @Seqs TABLE (Seq INT NOT NULL PRIMARY KEY, Ord INT NOT NULL, MaxUnits INT NULL);
    INSERT INTO @Seqs (Seq, Ord, MaxUnits)
    SELECT x.Seq, ROW_NUMBER() OVER (ORDER BY x.Seq),
           CASE WHEN x.KnownCaps < x.LineCount THEN NULL
                WHEN x.Fill <= 1.000001 AND FLOOR(x.Units / x.Fill + 0.000001) < x.Units THEN x.Units
                ELSE CAST(FLOOR(x.Units / x.Fill + 0.000001) AS INT) END
    FROM (SELECT p.Seq, LineCount = COUNT(*), KnownCaps = COUNT(c.Cap), Units = SUM(p.QuantityBase),
                 Fill = SUM(CAST(p.QuantityBase AS DECIMAL(38,20)) / c.Cap)
          FROM @Plan p
          INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = p.PoLineId
          INNER JOIN @Caps c                            ON c.ItemId = pol.ItemId
          GROUP BY p.Seq) x;

    DECLARE @Created TABLE (Seq INT NOT NULL PRIMARY KEY, ContainerId INT NOT NULL);
    DECLARE @L logistics.tvp_ContainerLoadLine;
    DECLARE @Total INT = (SELECT COUNT(*) FROM @Seqs), @Ord INT = NULL, @Seq INT, @Max INT, @NewId INT, @Lock INT;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- one plan at a time for an order
        SELECT @Lock = Id FROM purchase.PurchaseDocuments WITH (UPDLOCK, HOLDLOCK) WHERE Id = @PurchaseOrderId;

        -- the whole plan must fit in what the order lines still allow
        SELECT TOP (1) @Msg = N'Order line ' + CAST(pol.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                            + CAST(t.Planned AS NVARCHAR(20)) + N' pieces planned but only '
                            + CAST(pol.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0) AS NVARCHAR(20))
                            + N' can still be loaded.'
        FROM (SELECT PoLineId, Planned = SUM(QuantityBase) FROM @Plan GROUP BY PoLineId) t
        INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = t.PoLineId
        INNER JOIN inventory.Items i                  ON i.Id = pol.ItemId
        OUTER APPLY (SELECT Qty = SUM(x.QuantityBase) FROM purchase.PurchaseDocumentLines x
                     INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
                     WHERE x.SourceLineId = pol.Id AND x.ContainerLineId IS NULL AND xd.Status IN (1, 2, 4)) dir
        OUTER APPLY (SELECT Qty = SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                     INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                     WHERE cl.PoLineId = pol.Id AND c.Status <> 8) oth
        WHERE t.Planned > pol.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0)
        ORDER BY pol.LineNumber;
        IF @Msg IS NOT NULL THROW 69008, @Msg, 1;

        DECLARE plan_cur CURSOR LOCAL STATIC READ_ONLY FORWARD_ONLY FOR
            SELECT Seq, Ord, MaxUnits FROM @Seqs ORDER BY Ord;
        OPEN plan_cur;
        FETCH NEXT FROM plan_cur INTO @Seq, @Ord, @Max;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            DELETE FROM @L;
            INSERT INTO @L (LineNumber, PoLineId, QuantityBase, OilIncluded, OilQtyPerUnit, Notes)
            SELECT ROW_NUMBER() OVER (ORDER BY pol.LineNumber), p.PoLineId, p.QuantityBase,
                   ISNULL(p.OilIncluded, CASE WHEN i.OilQtyPerUnit > 0 THEN 1 ELSE 0 END), NULL, NULL
            FROM @Plan p
            INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = p.PoLineId
            INNER JOIN inventory.Items i                  ON i.Id = pol.ItemId
            WHERE p.Seq = @Seq;

            SET @NewId = NULL;
            EXEC logistics.usp_Container_Save
                 @PurchaseOrderId     = @PurchaseOrderId,
                 @ContainerTypeId     = @ContainerTypeId,
                 @OrderDate           = @OrderDate,
                 @ShippingMethod      = @ShippingMethod,
                 @CountryOfOrigin     = @CountryOfOrigin,
                 @ForwarderId         = @ForwarderId,
                 @ShippingLine        = @ShippingLine,
                 @PortOfLoadingId     = @PortOfLoadingId,
                 @PortOfDestinationId = @PortOfDestinationId,
                 @FinalDestinationId  = @FinalDestinationId,
                 @Eta                 = @Eta,
                 @FreeDays            = @FreeDays,
                 @MaxUnits            = @Max,
                 @BranchId            = @BranchId,
                 @WarehouseId         = @WarehouseId,
                 @Lines               = @L,
                 @AllowOverCapacity   = @AllowOverCapacity,
                 @UserId              = @UserId,
                 @NewId               = @NewId OUTPUT;

            IF ISNULL(@Confirm, 0) = 1
                EXEC logistics.usp_Container_Confirm @Id = @NewId, @UserId = @UserId;

            INSERT INTO @Created (Seq, ContainerId) VALUES (@Seq, @NewId);
            FETCH NEXT FROM plan_cur INTO @Seq, @Ord, @Max;
        END
        CLOSE plan_cur;
        DEALLOCATE plan_cur;
        SET @Ord = NULL;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrNo INT = ERROR_NUMBER(), @ErrMsg NVARCHAR(2048) = ERROR_MESSAGE();
        IF @ErrNo >= 50000 AND @Ord IS NOT NULL
        BEGIN
            SET @ErrMsg = LEFT(N'Container ' + CAST(@Seq AS NVARCHAR(10)) + N' of ' + CAST(@Total AS NVARCHAR(10)) + N': ' + @ErrMsg, 2048);
            THROW @ErrNo, @ErrMsg, 1;
        END;
        THROW;
    END CATCH

    SELECT x.Seq, c.Id AS ContainerId, c.ContainerRef, c.Status, c.TotalLines, c.TotalAllocatedBase, c.MaxUnits, c.UtilizationPct,
           c.RowVersion
    FROM @Created x
    INNER JOIN logistics.Containers c ON c.Id = x.ContainerId
    ORDER BY x.Seq;
END
GO

/* ================================================================== 4. Bulk actions on selected containers */

-- Container no. and seal no. of several containers at once (e.g. the list sent by the forwarder after loading).
-- Both values are written: an empty one clears it. Rows that do not change are left alone.
-- Returns the containers (Id, ContainerRef, ContainerNo, SealNo, RowVersion).
CREATE OR ALTER PROCEDURE logistics.usp_Container_SetNumbers
    @Items  logistics.tvp_ContainerNumber READONLY,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @N TABLE (ContainerId INT NOT NULL PRIMARY KEY, ContainerNo NVARCHAR(20) NULL, SealNo NVARCHAR(30) NULL,
                      Changed BIT NOT NULL, IsOpen BIT NOT NULL);
    INSERT INTO @N (ContainerId, ContainerNo, SealNo, Changed, IsOpen)
    SELECT ContainerId, UPPER(NULLIF(LTRIM(RTRIM(ContainerNo)), N'')), NULLIF(LTRIM(RTRIM(SealNo)), N''), 0, 0
    FROM @Items;

    IF NOT EXISTS (SELECT 1 FROM @N) THROW 69000, 'Select at least one container.', 1;
    IF EXISTS (SELECT 1 FROM @N n WHERE NOT EXISTS (SELECT 1 FROM logistics.Containers c WHERE c.Id = n.ContainerId))
        THROW 69006, 'A selected container no longer exists.', 1;

    DECLARE @Msg NVARCHAR(400);

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE n
        SET Changed = CASE WHEN ISNULL(c.ContainerNo, N'') <> ISNULL(n.ContainerNo, N'') OR ISNULL(c.SealNo, N'') <> ISNULL(n.SealNo, N'')
                           THEN 1 ELSE 0 END,
            IsOpen  = CASE WHEN c.Status < 7 THEN 1 ELSE 0 END
        FROM @N n
        INNER JOIN logistics.Containers c WITH (UPDLOCK, HOLDLOCK) ON c.Id = n.ContainerId;

        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' is offloaded, closed or cancelled: its numbers can no longer change.'
        FROM @N n INNER JOIN logistics.Containers c ON c.Id = n.ContainerId
        WHERE n.Changed = 1 AND c.Status >= 6
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 69005, @Msg, 1;

        -- the numbers of the open containers of the list, as they will be
        SELECT TOP (1) @Msg = N'Container number ' + ContainerNo + N' is typed more than once.'
        FROM @N WHERE ContainerNo IS NOT NULL AND IsOpen = 1
        GROUP BY ContainerNo HAVING COUNT(*) > 1
        ORDER BY ContainerNo;
        IF @Msg IS NOT NULL THROW 69013, @Msg, 1;

        -- another open container keeps its number unless it is in the list too
        SELECT TOP (1) @Msg = N'Container number ' + n.ContainerNo + N' is already used by ' + o.ContainerRef + N'.'
        FROM @N n
        INNER JOIN logistics.Containers o WITH (UPDLOCK, HOLDLOCK)
                ON o.ContainerNo = n.ContainerNo AND o.Status < 7 AND o.Id <> n.ContainerId
        WHERE n.Changed = 1 AND NOT EXISTS (SELECT 1 FROM @N m WHERE m.ContainerId = o.Id)
        ORDER BY n.ContainerNo;
        IF @Msg IS NOT NULL THROW 69013, @Msg, 1;

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        SELECT n.ContainerId, N'Updated', LEFT(N'Container no. ' + ISNULL(n.ContainerNo, N'(none)') + N', seal no. ' + ISNULL(n.SealNo, N'(none)'), 500), @UserId
        FROM @N n WHERE n.Changed = 1;

        UPDATE c
        SET ContainerNo = n.ContainerNo, SealNo = n.SealNo, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        FROM logistics.Containers c
        INNER JOIN @N n ON n.ContainerId = c.Id
        WHERE n.Changed = 1;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        IF ERROR_NUMBER() IN (2601, 2627)
            THROW 69013, 'A container number was just given to another container by someone else. Reload and try again.', 1;
        THROW;
    END CATCH

    SELECT c.Id, c.ContainerRef, c.ContainerNo, c.SealNo, c.RowVersion
    FROM @N n
    INNER JOIN logistics.Containers c ON c.Id = n.ContainerId
    ORDER BY c.ContainerRef;
END
GO

-- Confirms the DRAFTS among the selected containers (the others are left as they are), all or nothing.
-- Returns the selected containers (Id, ContainerRef, Status, ConfirmedNow, RowVersion).
CREATE OR ALTER PROCEDURE logistics.usp_Container_ConfirmMany
    @Ids    logistics.tvp_IdList READONLY,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM @Ids) THROW 69000, 'Select at least one container.', 1;
    IF EXISTS (SELECT 1 FROM @Ids x WHERE NOT EXISTS (SELECT 1 FROM logistics.Containers c WHERE c.Id = x.Id))
        THROW 69006, 'A selected container no longer exists.', 1;

    DECLARE @Done TABLE (Id INT NOT NULL PRIMARY KEY);
    DECLARE @Cid INT, @Ref NVARCHAR(30) = NULL;

    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE draft_cur CURSOR LOCAL STATIC READ_ONLY FORWARD_ONLY FOR
            SELECT c.Id, c.ContainerRef FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id
            WHERE c.Status = 1 ORDER BY c.ContainerRef;
        OPEN draft_cur;
        FETCH NEXT FROM draft_cur INTO @Cid, @Ref;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC logistics.usp_Container_Confirm @Id = @Cid, @UserId = @UserId;
            INSERT INTO @Done (Id) VALUES (@Cid);
            FETCH NEXT FROM draft_cur INTO @Cid, @Ref;
        END
        CLOSE draft_cur;
        DEALLOCATE draft_cur;
        SET @Ref = NULL;
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

    SELECT c.Id, c.ContainerRef, c.Status, ConfirmedNow = CAST(CASE WHEN d.Id IS NOT NULL THEN 1 ELSE 0 END AS BIT), c.RowVersion
    FROM @Ids x
    INNER JOIN logistics.Containers c ON c.Id = x.Id
    LEFT  JOIN @Done d                ON d.Id = c.Id
    ORDER BY c.ContainerRef;
END
GO

-- Deletes several DRAFT containers (e.g. a plan created by mistake), all or nothing. Returns Deleted = the count.
CREATE OR ALTER PROCEDURE logistics.usp_Container_DeleteMany
    @Ids    logistics.tvp_IdList READONLY,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM @Ids) THROW 69000, 'Select at least one container.', 1;
    IF EXISTS (SELECT 1 FROM @Ids x WHERE NOT EXISTS (SELECT 1 FROM logistics.Containers c WHERE c.Id = x.Id))
        THROW 69006, 'A selected container no longer exists.', 1;

    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' is not a draft. Only drafts can be deleted; cancel the others.'
    FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id
    WHERE c.Status <> 1
    ORDER BY c.ContainerRef;
    IF @Msg IS NOT NULL THROW 69005, @Msg, 1;

    DECLARE @Cid INT, @Ref NVARCHAR(30) = NULL, @Count INT = 0;

    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE del_cur CURSOR LOCAL STATIC READ_ONLY FORWARD_ONLY FOR
            SELECT c.Id, c.ContainerRef FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id ORDER BY c.ContainerRef;
        OPEN del_cur;
        FETCH NEXT FROM del_cur INTO @Cid, @Ref;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC logistics.usp_Container_Delete @Id = @Cid, @UserId = @UserId;
            SET @Count = @Count + 1;
            FETCH NEXT FROM del_cur INTO @Cid, @Ref;
        END
        CLOSE del_cur;
        DEALLOCATE del_cur;
        SET @Ref = NULL;
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

    SELECT Deleted = @Count;
END
GO

/* ================================================================== 5. A shipment for the chosen containers */

-- Confirms the draft containers (@ConfirmDrafts), creates ONE movement for all of them and starts it (@StartNow),
-- in one transaction. Places by default (Sea stage only): from the common port of loading to the common port of
-- destination of the containers. @UpdateContainers copies to the containers the values that change: for a vessel leg
-- (Sea, or a transshipment between two sea ports) the vessel, voyage, shipping line (the carrier's name) and ETA; for a
-- Sea movement also the ports, only when the container has none; for a road leg (Transit, Border, Delivery) the truck;
-- the B/L no. / date when given. Each changed container gets one audit line listing what changed.
-- Returns the movement (Id, MovementNo, Status, StartDate, Eta, ContainerCount, RowVersion) and @NewId.
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

    IF @Stage = N'Sea' AND @FromPlaceId IS NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id WHERE c.PortOfLoadingId IS NULL)
           OR (SELECT COUNT(DISTINCT c.PortOfLoadingId) FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id) > 1
            THROW 70000, 'Choose the departure port: the selected containers have no port of loading, or different ones.', 1;
        SELECT TOP (1) @FromPlaceId = c.PortOfLoadingId FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id;
    END
    IF @Stage = N'Sea' AND @ToPlaceId IS NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id WHERE c.PortOfDestinationId IS NULL)
           OR (SELECT COUNT(DISTINCT c.PortOfDestinationId) FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id) > 1
            THROW 70000, 'Choose the destination port: the selected containers have no port of destination, or different ones.', 1;
        SELECT TOP (1) @ToPlaceId = c.PortOfDestinationId FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id;
    END
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

/* ================================================================== 6. A charge copied to other containers */

-- Containers that can receive a copy of the charge (not closed, not cancelled). HasThisCharge = the original container
-- or a container that already carries a (not cancelled) charge of the same group. @SameOrder = 1: only the containers
-- created from the same purchase order as the original's container.
CREATE OR ALTER PROCEDURE logistics.usp_ContainerCharge_CopyCandidates
    @ChargeId  INT,
    @Search    NVARCHAR(100) = NULL,    -- container ref / no.
    @SameOrder BIT           = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');

    DECLARE @SourceContainer INT, @GroupId UNIQUEIDENTIFIER, @SourceOrder INT;
    SELECT @SourceContainer = ch.ContainerId, @GroupId = ch.GroupId, @SourceOrder = c.PurchaseOrderId
    FROM logistics.ContainerCharges ch
    INNER JOIN logistics.Containers c ON c.Id = ch.ContainerId
    WHERE ch.Id = @ChargeId;
    IF @SourceContainer IS NULL THROW 70006, 'Charge not found.', 1;

    SELECT TOP (500)
           c.Id AS ContainerId, c.ContainerRef, c.ContainerNo, ct.TypeCode AS ContainerTypeCode, c.Status, c.CurrentLocation,
           c.PurchaseOrderId, po.DocumentNumber AS PurchaseOrderNumber, c.TotalAllocatedBase,
           ItemSummary = CASE WHEN ISNULL(ln.ItemCount, 0) = 0 THEN NULL
                              WHEN ln.ItemCount = 1 THEN ln.FirstItem
                              ELSE N'Mixed - ' + CAST(ln.ItemCount AS NVARCHAR(10)) + N' items' END,
           IsSource      = CAST(CASE WHEN c.Id = @SourceContainer THEN 1 ELSE 0 END AS BIT),
           HasThisCharge = CAST(CASE WHEN c.Id = @SourceContainer
                                       OR (@GroupId IS NOT NULL AND EXISTS (SELECT 1 FROM logistics.ContainerCharges g
                                                                            WHERE g.GroupId = @GroupId AND g.ContainerId = c.Id AND g.Status <> 3))
                                     THEN 1 ELSE 0 END AS BIT)
    FROM logistics.Containers c
    INNER JOIN masterdata.ContainerTypes ct ON ct.Id = c.ContainerTypeId
    LEFT  JOIN purchase.PurchaseDocuments po ON po.Id = c.PurchaseOrderId
    OUTER APPLY (SELECT ItemCount = COUNT(DISTINCT cl.ItemId), FirstItem = MIN(i.ItemName)
                 FROM logistics.ContainerLines cl
                 INNER JOIN inventory.Items i ON i.Id = cl.ItemId
                 WHERE cl.ContainerId = c.Id) ln
    WHERE c.Status NOT IN (7, 8)
      AND (ISNULL(@SameOrder, 1) = 0 OR c.PurchaseOrderId = @SourceOrder OR c.Id = @SourceContainer)
      AND (@Search IS NULL OR c.ContainerRef LIKE N'%' + @Search + N'%' OR c.ContainerNo LIKE N'%' + @Search + N'%')
    ORDER BY c.ContainerRef;
END
GO

-- Copies a DRAFT or POSTED charge to other containers: one draft per container, in the same group as the original
-- (the original joins a new group when it had none), same type, description, provider, reference, currency, rate
-- and landed-cost flag. Amount per container = @Amount (charge currency) or the original amount; date = @ChargeDate or
-- the original's; method = @AllocationMethod or the original's (a Manual original gives the charge type's method).
-- The movement of the original is kept for the containers that travel with it. @Post = 1 posts the copies at once.
-- Returns the created charges (Id, ContainerId, ContainerRef, ContainerNo, GroupId, Amount, AmountBase, AllocationMethod,
-- Status, RowVersion). An error while posting names the container.
CREATE OR ALTER PROCEDURE logistics.usp_ContainerCharge_CopyToContainers
    @ChargeId         INT,
    @ContainerIds     logistics.tvp_IdList READONLY,
    @Amount           DECIMAL(18,2) = NULL,
    @ChargeDate       DATE          = NULL,
    @AllocationMethod NVARCHAR(10)  = NULL,
    @Post             BIT           = 0,
    @UserId           INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @AllocationMethod = NULLIF(LTRIM(RTRIM(@AllocationMethod)), N'');

    DECLARE @SrcContainer INT, @SrcRef NVARCHAR(30), @SrcStatus TINYINT, @GroupId UNIQUEIDENTIFIER, @SrcMovement INT,
            @TypeId INT, @SrcMethod NVARCHAR(10), @SrcAmount DECIMAL(18,2), @SrcDate DATE, @CurrencyId INT, @RateType TINYINT,
            @Rate DECIMAL(18,6), @InLanded BIT, @Description NVARCHAR(200), @ProviderId INT, @Reference NVARCHAR(100),
            @Notes NVARCHAR(300);
    SELECT @SrcContainer = ch.ContainerId, @SrcRef = c.ContainerRef, @SrcStatus = ch.Status, @GroupId = ch.GroupId,
           @SrcMovement = ch.MovementId, @TypeId = ch.ChargeTypeId, @SrcMethod = ch.AllocationMethod, @SrcAmount = ch.Amount,
           @SrcDate = ch.ChargeDate, @CurrencyId = ch.CurrencyId, @RateType = ch.RateType, @Rate = ch.ExchangeRate,
           @InLanded = ch.IncludeInLandedCost, @Description = ch.Description, @ProviderId = ch.ProviderPartyId,
           @Reference = ch.Reference, @Notes = ch.Notes
    FROM logistics.ContainerCharges ch
    INNER JOIN logistics.Containers c ON c.Id = ch.ContainerId
    WHERE ch.Id = @ChargeId;

    IF @SrcContainer IS NULL THROW 70006, 'Charge not found.', 1;
    IF @SrcStatus = 3 THROW 70010, 'A cancelled charge cannot be copied.', 1;
    IF @Amount IS NOT NULL AND @Amount < 0 THROW 70000, 'The amount cannot be negative.', 1;
    IF @AllocationMethod IS NOT NULL AND @AllocationMethod NOT IN (N'Value', N'Quantity', N'Weight', N'Volume')
        THROW 70000, 'Allocation method of the copies must be Value, Quantity, Weight or Volume (a manual split can be typed on each draft afterwards).', 1;

    DECLARE @TypeMethod NVARCHAR(10), @TypeLabel NVARCHAR(120);
    SELECT @TypeMethod = AllocationMethod, @TypeLabel = ChargeCode + N' ' + ChargeName
    FROM purchase.ChargeTypes WHERE Id = @TypeId AND IsActive = 1;
    IF @TypeLabel IS NULL THROW 70000, 'The charge type of this charge is no longer active.', 1;

    DECLARE @Method NVARCHAR(10) = COALESCE(@AllocationMethod, CASE WHEN @SrcMethod = N'Manual' THEN @TypeMethod ELSE @SrcMethod END);
    IF @Method IS NULL OR @Method NOT IN (N'Value', N'Quantity', N'Weight', N'Volume') SET @Method = N'Value';
    SET @Amount = ISNULL(@Amount, @SrcAmount);
    SET @ChargeDate = ISNULL(@ChargeDate, @SrcDate);
    DECLARE @AmountBase DECIMAL(18,2) = ROUND(@Amount / @Rate, 2);
    DECLARE @CurrencyCode NVARCHAR(10) = (SELECT CurrencyCode FROM masterdata.Currencies WHERE Id = @CurrencyId);

    -- the original's container is skipped (it already has the charge)
    DECLARE @Ids TABLE (Id INT NOT NULL PRIMARY KEY);
    INSERT INTO @Ids (Id) SELECT Id FROM @ContainerIds WHERE Id <> @SrcContainer;
    IF NOT EXISTS (SELECT 1 FROM @Ids) THROW 70000, 'Select at least one other container.', 1;

    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg = CASE WHEN c.Id IS NULL THEN N'A selected container no longer exists.'
                               ELSE N'Container ' + c.ContainerRef + N' is closed or cancelled.' END
    FROM @Ids x LEFT JOIN logistics.Containers c ON c.Id = x.Id
    WHERE c.Id IS NULL OR c.Status IN (7, 8)
    ORDER BY c.ContainerRef;
    IF @Msg IS NOT NULL THROW 70010, @Msg, 1;

    IF @GroupId IS NOT NULL
    BEGIN
        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' already has this charge.'
        FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id
        WHERE EXISTS (SELECT 1 FROM logistics.ContainerCharges g WHERE g.GroupId = @GroupId AND g.ContainerId = x.Id AND g.Status <> 3)
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70001, @Msg, 1;
    END

    DECLARE @New TABLE (Id INT NOT NULL PRIMARY KEY, ContainerId INT NOT NULL);
    DECLARE @NewChargeId INT, @Ref NVARCHAR(30) = NULL;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- read again under lock: two users copying the same charge at the same moment
        SELECT @GroupId = GroupId, @SrcStatus = Status
        FROM logistics.ContainerCharges WITH (UPDLOCK, HOLDLOCK)
        WHERE Id = @ChargeId;
        IF @@ROWCOUNT = 0 THROW 70006, 'Charge not found.', 1;
        IF @SrcStatus = 3 THROW 70010, 'A cancelled charge cannot be copied.', 1;
        IF @GroupId IS NOT NULL
        BEGIN
            SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' already has this charge.'
            FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id
            WHERE EXISTS (SELECT 1 FROM logistics.ContainerCharges g WHERE g.GroupId = @GroupId AND g.ContainerId = x.Id AND g.Status <> 3)
            ORDER BY c.ContainerRef;
            IF @Msg IS NOT NULL THROW 70001, @Msg, 1;
        END
        ELSE
        BEGIN
            SET @GroupId = NEWID();
            UPDATE logistics.ContainerCharges SET GroupId = @GroupId WHERE Id = @ChargeId;
        END

        INSERT INTO logistics.ContainerCharges (ContainerId, MovementId, GroupId, ChargeTypeId, Description, ProviderPartyId, Reference, ChargeDate,
                                                CurrencyId, RateType, ExchangeRate, Amount, AmountBase, AllocationMethod, IncludeInLandedCost, Notes, CreatedBy)
        OUTPUT inserted.Id, inserted.ContainerId INTO @New (Id, ContainerId)
        SELECT x.Id,
               CASE WHEN @SrcMovement IS NOT NULL
                         AND EXISTS (SELECT 1 FROM logistics.MovementContainers mc
                                     INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
                                     WHERE mc.MovementId = @SrcMovement AND mc.ContainerId = x.Id AND m.Status <> 4)
                    THEN @SrcMovement END,
               @GroupId, @TypeId, @Description, @ProviderId, @Reference, @ChargeDate,
               @CurrencyId, @RateType, @Rate, @Amount, @AmountBase, @Method, @InLanded, @Notes, @UserId
        FROM @Ids x;

        DECLARE new_cur CURSOR LOCAL STATIC READ_ONLY FORWARD_ONLY FOR SELECT Id FROM @New ORDER BY Id;
        OPEN new_cur;
        FETCH NEXT FROM new_cur INTO @NewChargeId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC logistics.usp_ContainerCharge_Allocate @NewChargeId, 1;
            FETCH NEXT FROM new_cur INTO @NewChargeId;
        END
        CLOSE new_cur;
        DEALLOCATE new_cur;

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        SELECT n.ContainerId, N'Updated',
               LEFT(N'Charge added (draft): ' + @TypeLabel + N' ' + CAST(@Amount AS NVARCHAR(30)) + N' ' + ISNULL(@CurrencyCode, N'')
                    + N' (copied from ' + @SrcRef + N')', 500),
               @UserId
        FROM @New n;

        IF ISNULL(@Post, 0) = 1
        BEGIN
            DECLARE post_cur CURSOR LOCAL STATIC READ_ONLY FORWARD_ONLY FOR
                SELECT n.Id, c.ContainerRef FROM @New n INNER JOIN logistics.Containers c ON c.Id = n.ContainerId ORDER BY c.ContainerRef;
            OPEN post_cur;
            FETCH NEXT FROM post_cur INTO @NewChargeId, @Ref;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC logistics.usp_ContainerCharge_Post @Id = @NewChargeId, @UserId = @UserId;
                FETCH NEXT FROM post_cur INTO @NewChargeId, @Ref;
            END
            CLOSE post_cur;
            DEALLOCATE post_cur;
            SET @Ref = NULL;
        END

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

    SELECT ch.Id, ch.ContainerId, c.ContainerRef, c.ContainerNo, ch.GroupId, ch.Amount, ch.AmountBase, ch.AllocationMethod, ch.Status, ch.RowVersion
    FROM @New n
    INNER JOIN logistics.ContainerCharges ch ON ch.Id = n.Id
    INNER JOIN logistics.Containers c        ON c.Id = ch.ContainerId
    ORDER BY c.ContainerRef;
END
GO

/* ================================================================== 7. Approvers of purchase orders: Owner, Manager, administrators */

INSERT INTO security.RolePermissions (RoleId, PermissionId)
SELECT r.Id, p.Id
FROM security.Roles r
CROSS JOIN security.Permissions p
WHERE p.Code = N'purchase.orders.approve'
  AND (r.IsSystem = 1 OR r.Name IN (N'Owner', N'Manager'))
  AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);
GO

/* ================================================================== 8. Check */

SELECT ProcedureName = name FROM sys.procedures
WHERE SCHEMA_NAME(schema_id) = N'logistics'
  AND name IN (N'usp_Container_PlanFromOrder', N'usp_Container_CreateBatch', N'usp_Container_SetNumbers', N'usp_Container_ConfirmMany',
               N'usp_Container_DeleteMany', N'usp_Movement_ShipContainers', N'usp_ContainerCharge_CopyCandidates',
               N'usp_ContainerCharge_CopyToContainers')
ORDER BY name;                                                        -- expected 8

SELECT TypeName = name FROM sys.table_types
WHERE SCHEMA_NAME(schema_id) = N'logistics' AND name IN (N'tvp_ContainerPlanLine', N'tvp_ItemCapacity', N'tvp_ContainerNumber')
ORDER BY name;                                                        -- expected 3

SELECT ApproverRole = r.Name, r.IsSystem
FROM security.Roles r
INNER JOIN security.RolePermissions rp ON rp.RoleId = r.Id
INNER JOIN security.Permissions p      ON p.Id = rp.PermissionId
WHERE p.Code = N'purchase.orders.approve'
ORDER BY r.Name;                                                      -- Manager, Owner and the administrator role(s)

PRINT 'Script 28 applied: auto-plan of containers, bulk actions, shipments for chosen containers, charges copied, approvers.';
GO

SET NOEXEC OFF;
GO
