SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 78: CONTAINERS - ANY NUMBER OF CONTAINERS (and the Auto-plan defaults)

   The owner's words: "in the auto-plan for containers the supplier must be automatic, and I have a problem when the
   number of containers is big, it returns an error; the system and the purchase orders and invoices must accept any
   number of containers".

   What refused or broke a big order, and what this script does about it:
     1. Auto-plan refused an order needing more than 200 containers TWICE in usp_Container_PlanFromOrder (before and
        after packing: the proposal itself, so the dialog never even showed the order's lines) and once more in
        usp_Container_CreateBatch. The three THROWs go (the C# copy, ContainerService.MaxContainersPerPlan, goes too).
        Measured in the sandbox (SQL Server 2025, one item of 10 pcs per container): proposing 2,000 containers
        0.8 s; creating 300 / 1,000 / 2,000 (confirmed) 1.4 / 4.5 / 12.6 s; confirming 1,000 0.5 s; numbers for 2,000
        0.15 s; Start shipment of 3,000 1.4 s; a Delivery of 3,000 completed 0.7 s and its 3,000 draft goods receipts
        8.7 s; one invoice of 2,000 containers created 1.0 s and posted 6.0 s. The cursors stay: none of these comes
        near the server's 90 s, and the API now gives the batch calls a longer timeout of their own (600 s).
     2. Error 9829 ("STRING_AGG aggregation result exceeded the limit of 8000 bytes"): STRING_AGG over a non-MAX text
        returns NVARCHAR(4000), and a LEFT() around it comes too late. Three lists grew with the containers:
          - purchase.fn_PayableDocument's ContainerRef (Supplier Payments: every open invoice of the supplier, and the
            payment itself, failed once one invoice had about 267 containers): now the refs when there are at most 5,
            else the first 3 and "+N more" (the per-container split of script 73 lists them all);
          - purchase.usp_PurchaseInvoice_LinkContainers' audit row (Link containers / Add container / Auto-plan from
            an invoice failed from about 190 containers): at most 20 containers named, then "and N more";
          - purchase.usp_PurchaseInvoice_ReceiptCostPreview's Receipts (an invoice line matched to more than about 210
            goods receipts broke its post confirmation): at most 10 numbers, else the first 5 and "+N more".
        Every other STRING_AGG of the last definitions was checked: they list per container, per item or per approver.
     3. Numbering: inventory.usp_DocumentType_NextNumber cut the sequence to NumberLength (RIGHT(...)): container
        10,000 of a year became KTG-2026-0000 and the next one a duplicate (UQ_Containers_Ref, error 2627), for the rest
        of the year. A sequence longer than the length now keeps all its digits (KTG-2026-10000); shorter ones are
        padded as before, so every number given so far reads the same. CNT keeps NumberLength 4. The CHG- numbers of
        container charges in Supplier Payments keep all their digits above 999,999 the same way.
     4. logistics.usp_ContainerCharge_CopyCandidates ("Apply to other containers...") listed at most 500 containers,
        without saying so (the newest were the ones missing): it lists them all.
     5. usp_Container_Search and usp_Movement_ContainerCandidates take pages of up to 5,000 (200 before): each page
        costs about the whole search, so the 2,000 containers of one order were ten calls of 2 s; the order's Containers
        card, a movement's containers and its candidates now come in one call.
     6. NEW logistics.usp_Container_OrderDefaults: what the Auto-plan and Add container dialogs fill in by themselves
        for an order - its supplier (shown, read-only: a container's goods come from its order lines), the forwarder
        (the forwarder of the order's most recent container that has an active one, else the order's supplier) and
        the country of origin (the supplier's country). The dialogs keep the forwarder editable and clearable.
     7. NEW logistics.usp_Container_Lookup: the container pickers (New charge, the Container Charges filter) search the
        server and read a preset selection in one call, where they held the 200 newest containers.
     8. usp_Movement_MatchContainers (a movement's import of container numbers) takes 10,000 numbers a call (500).

   Procedures re-created from their current bodies: inventory.usp_DocumentType_NextNumber (22),
   logistics.usp_Container_PlanFromOrder (65), logistics.usp_Container_CreateBatch (65),
   purchase.usp_PurchaseInvoice_LinkContainers (65), purchase.fn_PayableDocument (47),
   purchase.usp_PurchaseInvoice_ReceiptCostPreview (64), logistics.usp_ContainerCharge_CopyCandidates (28),
   logistics.usp_Container_Search (65), logistics.usp_Movement_ContainerCandidates (53),
   logistics.usp_Movement_MatchContainers (53).
   New: logistics.usp_Container_OrderDefaults, logistics.usp_Container_Lookup.

   Errors: no new number; 69000 "The plan would need more than 200 containers..." and "At most 200 containers can be
   created at once." are no longer raised; 70000 "At most 500 container numbers at a time." says 10,000.

   Requires scripts 47, 64, 65 and 73 (Schema.sql runs them first). Idempotent, additive: re-applied at every API
   start-up, and builds a brand-new empty database (no data step).
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'logistics.usp_Container_CreateBatch', N'P') IS NULL                    -- 28 / 65
   OR OBJECT_ID(N'purchase.usp_PurchaseInvoice_ReceiptCostPreview', N'P') IS NULL      -- 64
   OR OBJECT_ID(N'purchase.fn_InvoiceSettlement') IS NULL                             -- 47
   OR OBJECT_ID(N'purchase.fn_PoLine_CommittedOutside') IS NULL                       -- 65
   OR OBJECT_ID(N'purchase.fn_InvoiceContainerSettlement') IS NULL                    -- 73
    THROW 69000, 'Script 78 requires scripts 47, 64, 65 and 73: apply them first.', 1;
GO

/* ================================================================== 1. Numbers never cut */

-- Re-created (78) from the body of script 22: a sequence longer than the type's NumberLength keeps all its digits
-- (the numbers given so far, padded to the length, read the same).
CREATE OR ALTER PROCEDURE inventory.usp_DocumentType_NextNumber
    @Code           NVARCHAR(20),
    @DocumentNumber NVARCHAR(30) OUTPUT,
    @BranchId       INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TypeId INT, @Prefix NVARCHAR(10), @Len TINYINT, @PerBranch BIT, @YearIn BIT;
    SELECT @TypeId = Id, @Prefix = NumberPrefix, @Len = NumberLength, @PerBranch = NumberPerBranch, @YearIn = YearInNumber
    FROM inventory.DocumentTypes WHERE Code = @Code AND IsActive = 1;
    IF @TypeId IS NULL THROW 62008, 'Document type not found or inactive.', 1;

    DECLARE @Year INT = YEAR(SYSUTCDATETIME());
    DECLARE @SeqYear INT = CASE WHEN @YearIn = 1 THEN @Year ELSE 0 END;
    DECLARE @Taken TABLE (Number INT);
    DECLARE @Middle NVARCHAR(20) = N'';

    IF @PerBranch = 1 AND @BranchId IS NOT NULL
    BEGIN
        DECLARE @BranchCode NVARCHAR(20) = (SELECT BranchCode FROM masterdata.Branches WHERE Id = @BranchId);
        IF @BranchCode IS NULL THROW 62008, 'Branch not found.', 1;

        MERGE inventory.DocumentSequences WITH (HOLDLOCK) AS t
        USING (SELECT @TypeId AS DocumentTypeId, @BranchId AS BranchId, @SeqYear AS [Year]) AS s
            ON t.DocumentTypeId = s.DocumentTypeId AND t.BranchId = s.BranchId AND t.[Year] = s.[Year]
        WHEN MATCHED THEN UPDATE SET NextNumber = t.NextNumber + 1
        WHEN NOT MATCHED THEN INSERT (DocumentTypeId, BranchId, [Year], NextNumber) VALUES (s.DocumentTypeId, s.BranchId, s.[Year], 2)
        OUTPUT ISNULL(deleted.NextNumber, 1) INTO @Taken (Number);

        SET @Middle = UPPER(LEFT(@BranchCode, 8)) + N'-';
    END
    ELSE
    BEGIN
        UPDATE inventory.DocumentTypes WITH (UPDLOCK, ROWLOCK)
        SET NextNumber     = CASE WHEN @YearIn = 1 AND ISNULL(NextNumberYear, 0) <> @Year THEN 2 ELSE NextNumber + 1 END,
            NextNumberYear = CASE WHEN @YearIn = 1 THEN @Year ELSE NextNumberYear END
        OUTPUT CASE WHEN @YearIn = 1 AND ISNULL(deleted.NextNumberYear, 0) <> @Year THEN 1 ELSE deleted.NextNumber END INTO @Taken (Number)
        WHERE Id = @TypeId;
    END

    IF @YearIn = 1 SET @Middle = @Middle + CAST(@Year AS NVARCHAR(4)) + N'-';

    -- (78) NEVER CUT THE SEQUENCE: padded to the type's length, but a sequence that has outgrown the length keeps all its
    -- digits (KTG-2026-10000). RIGHT(..., @Len) alone gave container 10,000 of a year KTG-2026-0000 and the next one a
    -- duplicate of KTG-2026-0001 (UQ_Containers_Ref), refusing every new container for the rest of the year.
    SELECT @DocumentNumber = @Prefix + @Middle
                           + CASE WHEN LEN(CAST(Number AS NVARCHAR(10))) >= @Len THEN CAST(Number AS NVARCHAR(10))
                                  ELSE RIGHT(REPLICATE(N'0', @Len) + CAST(Number AS NVARCHAR(10)), @Len) END
    FROM @Taken;
END
GO

/* ================================================================== 2. Auto-plan: any number of containers */

-- Re-created (78) from the body of script 65: (78) NO CEILING ON THE NUMBER OF CONTAINERS. The two refusals above 200
-- (before packing and after) are gone: an order needing 2,000 containers is proposed in under a second. Nothing else
-- changes.
CREATE OR ALTER PROCEDURE logistics.usp_Container_PlanFromOrder
    @PurchaseOrderId INT,
    @ContainerTypeId INT,
    @MixRemainders   BIT = 1,       -- 0 = the rest of every order line gets its own container
    @Capacities      logistics.tvp_ItemCapacity READONLY,    -- (54) ignored: the items' Container units only
    @ForInvoiceId    INT = NULL      -- (43) only what this invoice of the order has outside containers
AS
BEGIN
    SET NOCOUNT ON;

    -- (51) a proposal for an invoice: the invoice's rules 1-7 first
    IF @ForInvoiceId IS NOT NULL EXEC purchase.usp_PurchaseInvoice_CheckContainers @InvoiceId = @ForInvoiceId, @Action = N'Plan';

    IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                   WHERE d.Id = @PurchaseOrderId AND dt.Code = N'PO'
                     AND (d.Status = 2 OR (d.Status = 4 AND purchase.fn_PurchaseInvoice_TakesContainers(d.Id, @ForInvoiceId) = 1)))
        THROW 69000, 'The purchase order must be approved and still open.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.ContainerTypes WHERE Id = @ContainerTypeId AND IsActive = 1)
        THROW 69000, 'Container type not found or inactive.', 1;
    DECLARE @Msg NVARCHAR(400);

    -- order lines: what can still be loaded (ordered - committed outside containers - loaded in other containers).
    -- (65) Committed outside = MAX(invoiced outside containers, received + on draft receipts outside containers): an
    -- invoiced piece and a received piece outside containers are the same goods (they are matched), never added up.
    DECLARE @Lines TABLE
    (
        PoLineId      INT          NOT NULL PRIMARY KEY,
        PoLineNumber  INT          NOT NULL,
        ItemId        INT          NOT NULL,
        OrderedBase   INT          NOT NULL,
        AvailableBase INT          NOT NULL,
        Cap           INT          NULL,
        CapSource     NVARCHAR(20) NOT NULL,     -- (54) Item Definition | None
        OilIncluded   BIT          NOT NULL,
        Remaining     INT          NOT NULL
    );
    INSERT INTO @Lines (PoLineId, PoLineNumber, ItemId, OrderedBase, AvailableBase, Cap, CapSource, OilIncluded, Remaining)
    SELECT l.Id, l.LineNumber, l.ItemId, l.QuantityBase,
           CASE WHEN @ForInvoiceId IS NOT NULL AND inv.UnlinkedBase < l.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0)
                THEN inv.UnlinkedBase
                ELSE l.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0) END,
           cnt.PcsPerContainer,
           CASE WHEN cnt.PcsPerContainer IS NOT NULL THEN N'Item Definition' ELSE N'None' END,
           CASE WHEN i.OilQtyPerUnit > 0 THEN 1 ELSE 0 END,
           0
    FROM purchase.PurchaseDocumentLines l
    INNER JOIN inventory.Items i ON i.Id = l.ItemId
    LEFT  JOIN purchase.fn_PurchaseInvoice_Unlinked(@ForInvoiceId) inv ON inv.PoLineId = l.Id
    OUTER APPLY purchase.fn_PoLine_CommittedOutside(l.Id, NULL) dir
    OUTER APPLY (SELECT Qty = SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                 INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                 WHERE cl.PoLineId = l.Id AND c.Status <> 8) oth
    CROSS APPLY logistics.fn_ItemPcsPerContainer(l.ItemId) cnt
    WHERE l.DocumentId = @PurchaseOrderId AND (@ForInvoiceId IS NULL OR inv.UnlinkedBase > 0);

    SELECT TOP (1) @Msg = N'Line ' + CAST(l.PoLineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): set its Container unit in Item Definition first.'
    FROM @Lines l INNER JOIN inventory.Items i ON i.Id = l.ItemId
    WHERE l.AvailableBase > 0 AND l.Cap IS NULL
    ORDER BY l.PoLineNumber;
    IF @Msg IS NOT NULL THROW 69000, @Msg, 1;

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

    -- 1: containers, with their fill from the items' Container units (no MaxUnits any more, script 54).
    SELECT x.Seq, x.ItemCount, x.Units,
           FillPct  = CAST(ROUND(100 * x.Fill, 1) AS DECIMAL(9,1)),
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

-- Re-created (78) from the body of script 65: (78) @ForInvoiceChecked = 1 skips the invoice's rules for a container of a
-- plan, which usp_Container_CreateBatch checked for the whole plan. A last, optional parameter: every other caller is
-- unchanged. Nothing else changes.
CREATE OR ALTER PROCEDURE logistics.usp_Container_Save
    @Id                  INT            = NULL,   -- NULL = create (ContainerRef assigned now)
    @PurchaseOrderId     INT            = NULL,   -- required on create: the order the container is created from
    @ContainerNo         NVARCHAR(20)   = NULL,
    @ContainerTypeId     INT,
    @SealNo              NVARCHAR(30)   = NULL,
    @CustomsSealNo       NVARCHAR(30)   = NULL,
    @Description         NVARCHAR(500)  = NULL,
    @OrderDate           DATE,
    @ShippingMethod      NVARCHAR(10)   = N'Sea',
    @CountryOfOrigin     NCHAR(2)       = NULL,
    @ForwarderId         INT            = NULL,
    @TransporterId       INT            = NULL,
    @ShippingLine        NVARCHAR(100)  = NULL,
    @VesselName          NVARCHAR(100)  = NULL,
    @VoyageNo            NVARCHAR(30)   = NULL,
    @BookingNo           NVARCHAR(30)   = NULL,
    @PortOfLoadingId     INT            = NULL,
    @PortOfDestinationId INT            = NULL,
    @FinalDestinationId  INT            = NULL,
    @DispatchDate        DATE           = NULL,   -- the four milestone dates are replaced by the movements when there are some
    @Eta                 DATE           = NULL,
    @FreeDays            INT            = NULL,
    @GrossWeightKg       DECIMAL(18,3)  = NULL,
    @VolumeCbm           DECIMAL(18,3)  = NULL,
    @Packages            INT            = NULL,
    @BlNo                NVARCHAR(30)   = NULL,
    @BlDate              DATE           = NULL,
    @BlNotes             NVARCHAR(500)  = NULL,
    @MaxUnits            INT            = NULL,   -- (54) ignored: the capacity is the items' Container units
    @BranchId            INT,
    @WarehouseId         INT            = NULL,
    @TruckNo             NVARCHAR(30)   = NULL,
    @WaybillNo           NVARCHAR(30)   = NULL,
    @DeclarationNo       NVARCHAR(30)   = NULL,
    @FeriNo              NVARCHAR(30)   = NULL,
    @ActualPortArrival   DATE           = NULL,
    @BorderCrossingDate  DATE           = NULL,
    @CustomsReleaseDate  DATE           = NULL,
    @StatusNote          NVARCHAR(200)  = NULL,
    @Notes               NVARCHAR(1000) = NULL,
    @Lines               logistics.tvp_ContainerLoadLine READONLY,
    @AllowOverCapacity   BIT            = 0,
    @RowVersion          BINARY(8)      = NULL,
    @UserId              INT            = NULL,
    @ForInvoiceId        INT            = NULL,   -- (43) for this invoice of the order: the order may be closed by it
    @NewId               INT OUTPUT,
    @ForInvoiceChecked   BIT            = 0       -- (78) 1 = the caller checked the invoice's rules for the whole plan
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @ContainerNo = UPPER(NULLIF(LTRIM(RTRIM(@ContainerNo)), N''));
    SET @SealNo = NULLIF(LTRIM(RTRIM(@SealNo)), N'');
    SET @CustomsSealNo = NULLIF(LTRIM(RTRIM(@CustomsSealNo)), N'');
    SET @Description = NULLIF(LTRIM(RTRIM(@Description)), N'');
    SET @ShippingMethod = NULLIF(LTRIM(RTRIM(@ShippingMethod)), N'');
    SET @BlNo = NULLIF(LTRIM(RTRIM(@BlNo)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    SET @StatusNote = NULLIF(LTRIM(RTRIM(@StatusNote)), N'');
    IF @ShippingMethod IS NULL SET @ShippingMethod = N'Sea';

    -- (51) a container created for an invoice: the invoice's rules 1-8 first, before anything is created. (78) Not again
    -- for each container of a plan: usp_Container_CreateBatch checks them once for the whole plan (@ForInvoiceChecked),
    -- and checking each container against an invoice state that grows with every container made it quadratic - 2,205
    -- containers from one invoice took 42 s, most of it here.
    IF @ForInvoiceId IS NOT NULL AND @Id IS NULL AND ISNULL(@ForInvoiceChecked, 0) = 0
    BEGIN
        DECLARE @ForInvoiceQty INT = (SELECT SUM(QuantityBase) FROM @Lines);
        EXEC purchase.usp_PurchaseInvoice_CheckContainers @InvoiceId = @ForInvoiceId, @Action = N'Add', @QuantityBase = @ForInvoiceQty;
    END

    IF @OrderDate IS NULL THROW 69000, 'Order date is required.', 1;
    IF @ShippingMethod NOT IN (N'Sea', N'Air', N'Road') THROW 69000, 'Shipping method must be Sea, Air or Road.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.ContainerTypes WHERE Id = @ContainerTypeId AND IsActive = 1)
        THROW 69000, 'Container type not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 69000, 'Branch not found or inactive.', 1;
    IF @WarehouseId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1)
        THROW 69000, 'Offloading warehouse not found or inactive.', 1;
    IF @FreeDays IS NOT NULL AND @FreeDays < 0 THROW 69000, 'Free days cannot be negative.', 1;
    IF @DispatchDate IS NOT NULL AND @Eta IS NOT NULL AND @Eta < @DispatchDate
        THROW 69000, 'The ETA cannot be earlier than the dispatch date.', 1;
    IF @ContainerNo IS NOT NULL AND EXISTS (SELECT 1 FROM logistics.Containers
                                            WHERE ContainerNo = @ContainerNo AND Status < 7 AND (@Id IS NULL OR Id <> @Id))
        THROW 69013, 'Another open container already uses this container number.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT = NULL;
        IF @Id IS NOT NULL
        BEGIN
            SELECT @Status = Status, @PurchaseOrderId = ISNULL(PurchaseOrderId, @PurchaseOrderId)
            FROM logistics.Containers WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
            IF @Status IS NULL THROW 69006, 'Container not found.', 1;
            IF @Status >= 6 THROW 69005, 'An offloaded, closed or cancelled container can no longer be changed.', 1;
            IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @Id AND RowVersion = @RowVersion)
                THROW 69004, 'This container was modified by another user. Reload the page and try again.', 1;

            -- (65) RULE 21: A CONTAINER WITH AN OPEN GOODS RECEIPT KEEPS ITS LOAD LINES AND ITS BRANCH (the draft
            -- mirrors the lines, order line by order line, with the loaded pieces; its warehouse must be of the
            -- branch). A posted receipt made the container Offloaded, refused above. The header stays editable (truck,
            -- waybill, declaration, FERI, B/L, free days, notes, warehouse: the draft keeps its own "Receive into"),
            -- and so do a line's oil and notes.
            DECLARE @GrnMsg NVARCHAR(400);
            SELECT @GrnMsg = N'Container ' + c.ContainerRef + N' has ' + ISNULL(N'goods receipt ' + r.GoodsReceiptNumber, N'a draft goods receipt')
                             + N'. Delete the draft (or cancel the receipt) first.'
            FROM logistics.Containers c
            CROSS APPLY logistics.fn_Container_ReceivedBy(c.Id) r
            WHERE c.Id = @Id AND r.GoodsReceiptId IS NOT NULL
              AND (c.BranchId <> @BranchId
                   OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                              WHERE cl.ContainerId = @Id
                                AND NOT EXISTS (SELECT 1 FROM @Lines l WHERE l.PoLineId = cl.PoLineId AND l.QuantityBase = cl.QuantityBase))
                   OR EXISTS (SELECT 1 FROM @Lines l
                              WHERE NOT EXISTS (SELECT 1 FROM logistics.ContainerLines cl WHERE cl.ContainerId = @Id AND cl.PoLineId = l.PoLineId)));
            IF @GrnMsg IS NOT NULL THROW 69019, @GrnMsg, 1;
        END
        ELSE
        BEGIN
            IF @PurchaseOrderId IS NULL THROW 69000, 'The purchase order is required: a container is created from a purchase order.', 1;
            IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                           WHERE d.Id = @PurchaseOrderId AND dt.Code = N'PO'
                             AND (d.Status = 2 OR (d.Status = 4 AND purchase.fn_PurchaseInvoice_TakesContainers(d.Id, @ForInvoiceId) = 1)))
                THROW 69000, 'The purchase order must be approved and still open.', 1;
        END

        DECLARE @Msg NVARCHAR(400);

        IF EXISTS (SELECT PoLineId FROM @Lines GROUP BY PoLineId HAVING COUNT(*) > 1)
            THROW 69000, 'The same order line appears twice in the container.', 1;

        -- Lines: order line of an approved order (lines already loaded may belong to an order closed since), quantity, oil.
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' +
            CASE WHEN pol.Id IS NULL OR dt.Code <> N'PO' THEN N'the purchase order line no longer exists.'
                 WHEN l.QuantityBase <= 0 THEN N'the quantity must be greater than zero.'
                 WHEN l.OilQtyPerUnit < 0 THEN N'the oil quantity cannot be negative.'
                 WHEN ex.Id IS NULL AND d.Status <> 2 AND NOT (d.Status = 4 AND purchase.fn_PurchaseInvoice_TakesContainers(d.Id, @ForInvoiceId) = 1) THEN N'order ' + ISNULL(d.DocumentNumber, N'(draft)') + N' is not approved or no longer open.'
                 WHEN ex.Id IS NOT NULL AND d.Status NOT IN (2, 4) THEN N'order ' + ISNULL(d.DocumentNumber, N'(draft)') + N' was cancelled.'
                 ELSE N'item ' + i.ItemCode + N' has no base unit.' END
        FROM @Lines l
        LEFT JOIN purchase.PurchaseDocumentLines pol ON pol.Id = l.PoLineId
        LEFT JOIN purchase.PurchaseDocuments d       ON d.Id = pol.DocumentId
        LEFT JOIN inventory.DocumentTypes dt         ON dt.Id = d.DocumentTypeId
        LEFT JOIN inventory.Items i                  ON i.Id = pol.ItemId
        LEFT JOIN logistics.ContainerLines ex        ON ex.ContainerId = @Id AND ex.PoLineId = l.PoLineId
        WHERE pol.Id IS NULL OR dt.Code <> N'PO' OR l.QuantityBase <= 0 OR l.OilQtyPerUnit < 0
           OR (ex.Id IS NULL AND d.Status <> 2 AND NOT (d.Status = 4 AND purchase.fn_PurchaseInvoice_TakesContainers(d.Id, @ForInvoiceId) = 1)) OR (ex.Id IS NOT NULL AND d.Status NOT IN (2, 4))
           OR NOT EXISTS (SELECT 1 FROM inventory.ItemUnits u WHERE u.ItemId = pol.ItemId AND u.IsBaseUnit = 1)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 69000, @Msg, 1;

        -- Quantity still loadable on the order line. (65) What the order line committed outside containers is the larger of
        -- what is invoiced and what is received (or on draft receipts) outside containers: the same goods, matched.
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - '
                              + CAST(l.QuantityBase AS NVARCHAR(20)) + N' loaded but only '
                              + CAST(pol.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0) AS NVARCHAR(20))
                              + N' remain on order ' + ISNULL(d.DocumentNumber, N'(draft)') + N' line ' + CAST(pol.LineNumber AS NVARCHAR(10)) + N'.'
        FROM @Lines l
        INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = l.PoLineId
        INNER JOIN purchase.PurchaseDocuments d       ON d.Id = pol.DocumentId
        INNER JOIN inventory.Items i                  ON i.Id = pol.ItemId
        OUTER APPLY purchase.fn_PoLine_CommittedOutside(pol.Id, NULL) dir
        OUTER APPLY (SELECT Qty = SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                     INNER JOIN logistics.Containers c2 ON c2.Id = cl.ContainerId
                     WHERE cl.PoLineId = pol.Id AND c2.Status <> 8 AND (@Id IS NULL OR cl.ContainerId <> @Id)) oth
        WHERE l.QuantityBase > pol.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 69008, @Msg, 1;

        IF @Id IS NOT NULL
        BEGIN
            -- Invoiced lines cannot be removed, nor loaded below what is invoiced.
            SELECT TOP (1) @Msg = N'Line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - '
                                  + CAST(q.Invoiced AS NVARCHAR(20)) + N' already invoiced (' + ISNULL(q.Numbers, N'') + N'); '
                                  + CASE WHEN l.PoLineId IS NULL THEN N'the line cannot be removed.' ELSE N'the quantity cannot be lower.' END
            FROM logistics.ContainerLines cl
            INNER JOIN inventory.Items i ON i.Id = cl.ItemId
            CROSS APPLY (SELECT Invoiced = ISNULL(SUM(pil.QuantityBase), 0), Numbers = STRING_AGG(pd.DocumentNumber, N', ')
                         FROM purchase.PurchaseDocumentLines pil
                         INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                         WHERE pil.ContainerLineId = cl.Id AND pd.Status <> 3) q
            LEFT JOIN @Lines l ON l.PoLineId = cl.PoLineId
            WHERE cl.ContainerId = @Id AND q.Invoiced > 0 AND (l.PoLineId IS NULL OR l.QuantityBase < q.Invoiced)
            ORDER BY cl.LineNumber;
            IF @Msg IS NOT NULL THROW 69017, @Msg, 1;

            -- A removed line cannot carry a manual share of a posted charge.
            SELECT TOP (1) @Msg = N'Line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N' carries a manual share of the posted charge '
                                  + t.ChargeName + N'. Cancel that charge before removing the line.'
            FROM logistics.ContainerLines cl
            INNER JOIN logistics.ContainerChargeAllocations a ON a.ContainerLineId = cl.Id AND a.IsManual = 1
            INNER JOIN logistics.ContainerCharges ch          ON ch.Id = a.ChargeId AND ch.Status = 2
            INNER JOIN purchase.ChargeTypes t                 ON t.Id = ch.ChargeTypeId
            WHERE cl.ContainerId = @Id AND NOT EXISTS (SELECT 1 FROM @Lines l WHERE l.PoLineId = cl.PoLineId)
            ORDER BY cl.LineNumber;
            IF @Msg IS NOT NULL THROW 70014, @Msg, 1;
        END

        IF @Id IS NULL
        BEGIN
            DECLARE @Ref NVARCHAR(30), @TypeId INT = (SELECT Id FROM inventory.DocumentTypes WHERE Code = N'CNT');
            EXEC inventory.usp_DocumentType_NextNumber N'CNT', @Ref OUTPUT, @BranchId;

            INSERT INTO logistics.Containers (DocumentTypeId, ContainerRef, PurchaseOrderId, ContainerNo, ContainerTypeId, SealNo, CustomsSealNo, Description,
                                              OrderDate, ShippingMethod, CountryOfOrigin, ForwarderId, TransporterId,
                                              ShippingLine, VesselName, VoyageNo, BookingNo, PortOfLoadingId, PortOfDestinationId, FinalDestinationId,
                                              DispatchDate, Eta, FreeDays, GrossWeightKg, VolumeCbm, Packages, BlNo, BlDate, BlNotes,
                                              MaxUnits, BranchId, WarehouseId, TruckNo, WaybillNo, DeclarationNo, FeriNo,
                                              ActualPortArrival, BorderCrossingDate, CustomsReleaseDate, StatusNote, Notes, Status, CreatedBy)
            VALUES (@TypeId, @Ref, @PurchaseOrderId, @ContainerNo, @ContainerTypeId, @SealNo, @CustomsSealNo, @Description,
                    @OrderDate, @ShippingMethod, @CountryOfOrigin, @ForwarderId, @TransporterId,
                    @ShippingLine, @VesselName, @VoyageNo, @BookingNo, @PortOfLoadingId, @PortOfDestinationId, @FinalDestinationId,
                    @DispatchDate, @Eta, @FreeDays, @GrossWeightKg, @VolumeCbm, @Packages, @BlNo, @BlDate, @BlNotes,
                    NULL, @BranchId, @WarehouseId, @TruckNo, @WaybillNo, @DeclarationNo, @FeriNo,
                    @ActualPortArrival, @BorderCrossingDate, @CustomsReleaseDate, @StatusNote, @Notes, 1, @UserId);
            SET @Id = SCOPE_IDENTITY();
            INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
            VALUES (@Id, N'Created', N'Draft ' + @Ref + ISNULL(N' from order ' + (SELECT DocumentNumber FROM purchase.PurchaseDocuments WHERE Id = @PurchaseOrderId), N''), @UserId);
        END
        ELSE
        BEGIN
            UPDATE logistics.Containers
            SET ContainerNo = @ContainerNo, ContainerTypeId = @ContainerTypeId, SealNo = @SealNo, CustomsSealNo = @CustomsSealNo,
                Description = @Description, OrderDate = @OrderDate, ShippingMethod = @ShippingMethod, CountryOfOrigin = @CountryOfOrigin,
                ForwarderId = @ForwarderId, TransporterId = @TransporterId, ShippingLine = @ShippingLine, VesselName = @VesselName,
                VoyageNo = @VoyageNo, BookingNo = @BookingNo, PortOfLoadingId = @PortOfLoadingId, PortOfDestinationId = @PortOfDestinationId,
                FinalDestinationId = @FinalDestinationId, DispatchDate = @DispatchDate, Eta = @Eta, FreeDays = @FreeDays,
                GrossWeightKg = @GrossWeightKg, VolumeCbm = @VolumeCbm, Packages = @Packages, BlNo = @BlNo, BlDate = @BlDate, BlNotes = @BlNotes,
                BranchId = @BranchId, WarehouseId = @WarehouseId, TruckNo = @TruckNo, WaybillNo = @WaybillNo,
                DeclarationNo = @DeclarationNo, FeriNo = @FeriNo, ActualPortArrival = @ActualPortArrival,
                BorderCrossingDate = @BorderCrossingDate, CustomsReleaseDate = @CustomsReleaseDate, StatusNote = @StatusNote, Notes = @Notes,
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;
            INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
            VALUES (@Id, N'Updated', N'Header and ' + CAST((SELECT COUNT(*) FROM @Lines) AS NVARCHAR(10)) + N' line(s) saved', @UserId);
        END

        -- Lines are kept per order line: removed ones go (with their charge shares), the others are updated, new ones added.
        -- Lines of CANCELLED invoices let go of the removed container lines.
        UPDATE pil SET ContainerLineId = NULL
        FROM purchase.PurchaseDocumentLines pil
        INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId AND pd.Status = 3
        INNER JOIN logistics.ContainerLines cl   ON cl.Id = pil.ContainerLineId
        WHERE cl.ContainerId = @Id AND NOT EXISTS (SELECT 1 FROM @Lines l WHERE l.PoLineId = cl.PoLineId);

        -- (65) LINES OF CANCELLED GOODS RECEIPTS LET GO OF THE REMOVED CONTAINER LINES too (FK_GoodsReceiptLines_ContainerLine):
        -- an open receipt refused the change above (69019); a cancelled one only keeps its history, which still reads in
        -- full (its order line, item, quantities and reason stay on the receipt line).
        UPDATE gl SET ContainerLineId = NULL
        FROM purchase.GoodsReceiptLines gl
        INNER JOIN purchase.GoodsReceipts g    ON g.Id = gl.GoodsReceiptId AND g.Status = 3
        INNER JOIN logistics.ContainerLines cl ON cl.Id = gl.ContainerLineId
        WHERE cl.ContainerId = @Id AND NOT EXISTS (SELECT 1 FROM @Lines l WHERE l.PoLineId = cl.PoLineId);

        DELETE a FROM logistics.ContainerChargeAllocations a
        INNER JOIN logistics.ContainerLines cl ON cl.Id = a.ContainerLineId
        WHERE cl.ContainerId = @Id AND NOT EXISTS (SELECT 1 FROM @Lines l WHERE l.PoLineId = cl.PoLineId);

        DELETE cl FROM logistics.ContainerLines cl
        WHERE cl.ContainerId = @Id AND NOT EXISTS (SELECT 1 FROM @Lines l WHERE l.PoLineId = cl.PoLineId);

        UPDATE cl
        SET LineNumber = l.LineNumber, Quantity = l.QuantityBase, OilIncluded = ISNULL(l.OilIncluded, 0),
            OilQtyPerUnit = CASE WHEN ISNULL(l.OilIncluded, 0) = 1 THEN ISNULL(l.OilQtyPerUnit, i.OilQtyPerUnit) END,
            Notes = NULLIF(LTRIM(RTRIM(l.Notes)), N'')
        FROM logistics.ContainerLines cl
        INNER JOIN @Lines l          ON l.PoLineId = cl.PoLineId
        INNER JOIN inventory.Items i ON i.Id = cl.ItemId
        WHERE cl.ContainerId = @Id;

        INSERT INTO logistics.ContainerLines (ContainerId, LineNumber, PurchaseOrderId, PoLineId, ItemId, ItemUnitId, PackingFormula,
                                              Quantity, OilIncluded, OilQtyPerUnit, Notes)
        SELECT @Id, l.LineNumber, pol.DocumentId, pol.Id, pol.ItemId, bu.Id, 1, l.QuantityBase, ISNULL(l.OilIncluded, 0),
               CASE WHEN ISNULL(l.OilIncluded, 0) = 1 THEN ISNULL(l.OilQtyPerUnit, i.OilQtyPerUnit) END,
               NULLIF(LTRIM(RTRIM(l.Notes)), N'')
        FROM @Lines l
        INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = l.PoLineId
        INNER JOIN inventory.Items i                  ON i.Id = pol.ItemId
        CROSS APPLY (SELECT TOP (1) u.Id FROM inventory.ItemUnits u WHERE u.ItemId = pol.ItemId AND u.IsBaseUnit = 1 ORDER BY u.Id) bu
        WHERE NOT EXISTS (SELECT 1 FROM logistics.ContainerLines cl WHERE cl.ContainerId = @Id AND cl.PoLineId = l.PoLineId);

        -- (54) Capacity from the items' Container units (logistics.fn_ContainerFill): a warning the caller can override,
        -- never a hard block; unknown (an item without a Container unit) = no warning. Checked on the lines just written,
        -- so the refusal rolls the whole save back.
        IF ISNULL(@AllowOverCapacity, 0) = 0 AND EXISTS (SELECT 1 FROM logistics.fn_ContainerFill(@Id) f WHERE f.IsOverCapacity = 1)
        BEGIN
            -- %% : THROW reads a single % as a format specification ("% f" would swallow the sign and the f).
            SELECT @Msg = LEFT(N'This container would be ' + CAST(CAST(ROUND(f.FillPct, 0) AS INT) AS NVARCHAR(10)) + N' %% full: '
                               + x.Parts + N'. Confirm to load it above its capacity.', 400)
            FROM logistics.fn_ContainerFill(@Id) f
            CROSS APPLY (SELECT Parts = STRING_AGG(CAST(q.Qty AS NVARCHAR(20)) + N' pcs of ' + q.ItemCode + N' ('
                                                   + CAST(q.Pcs AS NVARCHAR(20)) + N' per container)', N', ')
                                        WITHIN GROUP (ORDER BY q.ItemCode)
                         FROM (SELECT i.ItemCode, Qty = SUM(cl.QuantityBase), Pcs = p.PcsPerContainer
                               FROM logistics.ContainerLines cl
                               INNER JOIN inventory.Items i ON i.Id = cl.ItemId
                               CROSS APPLY logistics.fn_ItemPcsPerContainer(cl.ItemId) p
                               WHERE cl.ContainerId = @Id
                               GROUP BY i.ItemCode, p.PcsPerContainer) q) x;
            THROW 69007, @Msg, 1;
        END

        EXEC logistics.usp_Container_ReallocateCharges @Id;
        EXEC logistics.usp_Container_RefreshStatus @Id;

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Re-created (78) from the body of script 65: (78) NO CEILING ON THE NUMBER OF CONTAINERS created at once (the
-- refusal above 200 is gone), and the invoice's rules are checked once for the whole plan, not again for each container
-- (usp_Container_Save @ForInvoiceChecked). Still all or nothing, one container after the other: 2,000 confirmed containers take
-- about 13 s in the sandbox, and the API gives this call a timeout of its own (Database:BatchCommandTimeoutSeconds).
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
    @Capacities          logistics.tvp_ItemCapacity READONLY,     -- (54) ignored: the items' Container units only
    @AllowOverCapacity   BIT            = 0,
    @Confirm             BIT            = 0,                      -- 1 = the new containers are confirmed at once
    @UserId              INT            = NULL,
    @ForInvoiceId        INT            = NULL                    -- (43) for this invoice: its pieces outside containers at most
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @OrderDate IS NULL SET @OrderDate = CAST(SYSUTCDATETIME() AS DATE);

    -- (51) containers created for an invoice: the invoice's rules 1-8 first, for the whole plan
    IF @ForInvoiceId IS NOT NULL
    BEGIN
        DECLARE @ForInvoiceQty INT = (SELECT SUM(QuantityBase) FROM @Plan);
        EXEC purchase.usp_PurchaseInvoice_CheckContainers @InvoiceId = @ForInvoiceId, @Action = N'Add', @QuantityBase = @ForInvoiceQty;
    END

    DECLARE @OrderBranch INT, @OrderWarehouse INT, @OrderNo NVARCHAR(30);
    SELECT @OrderBranch = d.BranchId, @OrderWarehouse = d.WarehouseId, @OrderNo = d.DocumentNumber
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    WHERE d.Id = @PurchaseOrderId AND dt.Code = N'PO' AND (d.Status = 2 OR (d.Status = 4 AND purchase.fn_PurchaseInvoice_TakesContainers(d.Id, @ForInvoiceId) = 1));
    IF @OrderBranch IS NULL THROW 69000, 'The purchase order must be approved and still open.', 1;
    SET @BranchId = ISNULL(@BranchId, @OrderBranch);
    SET @WarehouseId = ISNULL(@WarehouseId, @OrderWarehouse);

    IF NOT EXISTS (SELECT 1 FROM masterdata.ContainerTypes WHERE Id = @ContainerTypeId AND IsActive = 1)
        THROW 69000, 'Container type not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM @Plan) THROW 69009, 'The plan has no container to create.', 1;
    IF EXISTS (SELECT 1 FROM @Plan WHERE Seq < 1 OR QuantityBase <= 0)
        THROW 69000, 'Every planned quantity must be greater than zero.', 1;

    DECLARE @Msg NVARCHAR(400);
    IF EXISTS (SELECT 1 FROM @Plan p LEFT JOIN purchase.PurchaseDocumentLines pol ON pol.Id = p.PoLineId
               WHERE pol.Id IS NULL OR pol.DocumentId <> @PurchaseOrderId)
    BEGIN
        SET @Msg = N'A planned line is not a line of order ' + ISNULL(@OrderNo, N'(draft)') + N'. Propose the plan again.';
        THROW 69000, @Msg, 1;
    END

    -- (54) every planned item has a Container unit, as the proposal requires
    SELECT TOP (1) @Msg = N'Line ' + CAST(pol.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): set its Container unit in Item Definition first.'
    FROM @Plan p
    INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = p.PoLineId
    INNER JOIN inventory.Items i                  ON i.Id = pol.ItemId
    CROSS APPLY logistics.fn_ItemPcsPerContainer(pol.ItemId) cnt
    WHERE cnt.PcsPerContainer IS NULL
    ORDER BY pol.LineNumber;
    IF @Msg IS NOT NULL THROW 69000, @Msg, 1;

    -- containers in plan order
    DECLARE @Seqs TABLE (Seq INT NOT NULL PRIMARY KEY, Ord INT NOT NULL);
    INSERT INTO @Seqs (Seq, Ord)
    SELECT x.Seq, ROW_NUMBER() OVER (ORDER BY x.Seq) FROM (SELECT DISTINCT Seq FROM @Plan) x;

    DECLARE @Created TABLE (Seq INT NOT NULL PRIMARY KEY, ContainerId INT NOT NULL);
    DECLARE @L logistics.tvp_ContainerLoadLine;
    DECLARE @Total INT = (SELECT COUNT(*) FROM @Seqs), @Ord INT = NULL, @Seq INT, @NewId INT, @Lock INT;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- one plan at a time for an order
        SELECT @Lock = Id FROM purchase.PurchaseDocuments WITH (UPDLOCK, HOLDLOCK) WHERE Id = @PurchaseOrderId;

        -- the whole plan must fit in what the order lines still allow. (65) Committed outside containers = the larger of
        -- invoiced and received (or on draft goods receipts) outside containers.
        SELECT TOP (1) @Msg = N'Order line ' + CAST(pol.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                            + CAST(t.Planned AS NVARCHAR(20)) + N' pieces planned but only '
                            + CAST(pol.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0) AS NVARCHAR(20))
                            + N' can still be loaded.'
        FROM (SELECT PoLineId, Planned = SUM(QuantityBase) FROM @Plan GROUP BY PoLineId) t
        INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = t.PoLineId
        INNER JOIN inventory.Items i                  ON i.Id = pol.ItemId
        OUTER APPLY purchase.fn_PoLine_CommittedOutside(pol.Id, NULL) dir
        OUTER APPLY (SELECT Qty = SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                     INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                     WHERE cl.PoLineId = pol.Id AND c.Status <> 8) oth
        WHERE t.Planned > pol.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0)
        ORDER BY pol.LineNumber;
        IF @Msg IS NOT NULL THROW 69008, @Msg, 1;

        -- (43) for an invoice: no more than its pieces of every order line outside containers
        IF @ForInvoiceId IS NOT NULL
        BEGIN
            SELECT TOP (1) @Msg = N'Order line ' + CAST(pol.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                                + CAST(t.Planned AS NVARCHAR(20)) + N' pieces planned but the invoice has only '
                                + CAST(ISNULL(inv.UnlinkedBase, 0) AS NVARCHAR(20)) + N' outside containers.'
            FROM (SELECT PoLineId, Planned = SUM(QuantityBase) FROM @Plan GROUP BY PoLineId) t
            INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = t.PoLineId
            INNER JOIN inventory.Items i                  ON i.Id = pol.ItemId
            LEFT  JOIN purchase.fn_PurchaseInvoice_Unlinked(@ForInvoiceId) inv ON inv.PoLineId = t.PoLineId
            WHERE t.Planned > ISNULL(inv.UnlinkedBase, 0)
            ORDER BY pol.LineNumber;
            IF @Msg IS NOT NULL THROW 69008, @Msg, 1;
        END

        DECLARE plan_cur CURSOR LOCAL STATIC READ_ONLY FORWARD_ONLY FOR
            SELECT Seq, Ord FROM @Seqs ORDER BY Ord;
        OPEN plan_cur;
        FETCH NEXT FROM plan_cur INTO @Seq, @Ord;
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
                 @BranchId            = @BranchId,
                 @WarehouseId         = @WarehouseId,
                 @Lines               = @L,
                 @AllowOverCapacity   = @AllowOverCapacity,
                 @UserId              = @UserId,
                 @ForInvoiceId        = @ForInvoiceId,
                 @ForInvoiceChecked   = 1,               -- (78) checked above for the whole plan
                 @NewId               = @NewId OUTPUT;

            IF ISNULL(@Confirm, 0) = 1
                EXEC logistics.usp_Container_Confirm @Id = @NewId, @UserId = @UserId;

            INSERT INTO @Created (Seq, ContainerId) VALUES (@Seq, @NewId);
            FETCH NEXT FROM plan_cur INTO @Seq, @Ord;
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

    SELECT x.Seq, c.Id AS ContainerId, c.ContainerRef, c.Status, c.TotalLines, c.TotalAllocatedBase,
           fl.FillPct, fl.CapacityKnown, fl.IsOverCapacity,
           c.RowVersion
    FROM @Created x
    INNER JOIN logistics.Containers c ON c.Id = x.ContainerId
    CROSS APPLY logistics.fn_ContainerFill(c.Id) fl
    ORDER BY x.Seq;
END
GO

/* ================================================================== 3. Lists that grew with the containers (9829) */

-- Re-created (78) from the body of script 65: the audit row of the invoice names at most 20 containers (9829 above
-- about 190 before). Nothing else changes.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseInvoice_LinkContainers
    @InvoiceId  INT,
    @RowVersion BINARY(8) = NULL,
    @Links      logistics.tvp_ContainerLineQty READONLY,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @TypeCode NVARCHAR(20), @Status TINYINT, @OrderId INT, @Mode TINYINT, @Number NVARCHAR(30), @UsesGrn BIT;
        SELECT @TypeCode = dt.Code, @Status = d.Status, @OrderId = d.SourceDocumentId, @Mode = d.ReceiptMode,
               @Number = ISNULL(d.DocumentNumber, N'draft #' + CAST(d.Id AS NVARCHAR(10))), @UsesGrn = d.UsesGoodsReceipts
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @InvoiceId;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;

        -- (65) RULE 28: AN INVOICE LINE A GOODS RECEIPT REFERS TO STAYS OUTSIDE CONTAINERS (65028, as Unlink answers it).
        -- Linking moves or splits the invoice's lines outside containers: none of them may be the line a draft or posted
        -- receipt was made from (Receive goods... on the invoice), or a line a posted receipt's pieces are matched to, or
        -- carry pieces received or returned. Rule 6 of purchase.fn_PurchaseInvoice_ContainerState fails for the same
        -- lines - the card's reason, and the 65030 of Add container and Auto-plan from the invoice - so this is checked
        -- before usp_PurchaseInvoice_CheckContainers raises it: a Link refused for them names the line and its receipt
        -- (65028). The invoice's rules 1-5 still come first, with their 65030. Document-wide, as rule 6 is: a receipt on
        -- any line outside containers stops the link (a posted one is named first, as the card does).
        DECLARE @Msg NVARCHAR(400), @Rule TINYINT;
        SELECT @Rule = s.FailedRule FROM purchase.fn_PurchaseInvoice_ContainerState(@InvoiceId) s;
        IF @Rule IS NULL OR @Rule >= 6
        BEGIN
            SELECT TOP (1) @Msg = N'Line ' + CAST(pil.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                                  + CASE WHEN g.Status = 2 THEN N'goods receipt ' + g.DocumentNumber ELSE N'a draft goods receipt' END
                                  + N' refers to this invoice line: delete or cancel it first.'
            FROM purchase.PurchaseDocumentLines pil
            INNER JOIN inventory.Items i ON i.Id = pil.ItemId
            CROSS APPLY (SELECT TOP (1) r.Status, r.DocumentNumber
                         FROM (SELECT gr.Id, gr.Status, gr.DocumentNumber          -- a receipt made from the line, draft or posted
                               FROM purchase.GoodsReceiptLines gl
                               INNER JOIN purchase.GoodsReceipts gr ON gr.Id = gl.GoodsReceiptId
                               WHERE gl.InvoiceLineId = pil.Id AND gr.Status < 3
                               UNION ALL
                               SELECT gr.Id, gr.Status, gr.DocumentNumber          -- a posted receipt whose pieces are matched to it
                               FROM purchase.GoodsReceiptInvoiceMatches m
                               INNER JOIN purchase.GoodsReceiptLines gl ON gl.Id = m.GoodsReceiptLineId
                               INNER JOIN purchase.GoodsReceipts gr     ON gr.Id = gl.GoodsReceiptId
                               WHERE m.InvoiceLineId = pil.Id AND gr.Status = 2) r
                         ORDER BY r.Status DESC, r.Id) g
            WHERE pil.DocumentId = @InvoiceId AND pil.ContainerLineId IS NULL
            ORDER BY CASE WHEN g.Status = 2 THEN 0 ELSE 1 END, pil.LineNumber;
            IF @Msg IS NOT NULL THROW 65028, @Msg, 1;

            IF EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines
                       WHERE DocumentId = @InvoiceId AND ContainerLineId IS NULL AND (ReceivedQuantityBase > 0 OR ReturnedQuantityBase > 0))
                THROW 65028, 'Goods of this invoice outside containers were already received or returned: it can no longer be linked.', 1;
        END

        -- (51) the invoice's rules 1-6: the same sentences as the state of the page
        EXEC purchase.usp_PurchaseInvoice_CheckContainers @InvoiceId = @InvoiceId, @Action = N'Link';
        IF @TypeCode <> N'PINV' OR @OrderId IS NULL
            THROW 65028, 'Only a purchase invoice created from a purchase order can be linked to containers.', 1;
        IF @Status NOT IN (1, 2) THROW 65010, 'A cancelled invoice cannot be linked to containers.', 1;
        IF @Status = 2 AND @Mode <> 2 AND @UsesGrn = 1      -- (65) posted after the switch: its goods come with goods receipts
        BEGIN
            SET @Msg = N'This invoice was posted without "Shipped in containers": its goods are received with Receive goods' + NCHAR(8230) + N', not with containers.';
            THROW 65028, @Msg, 1;
        END
        IF @Status = 2 AND @Mode <> 2
            THROW 65028, 'This invoice was received when it was posted: it cannot be linked to containers.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @InvoiceId AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF NOT EXISTS (SELECT 1 FROM @Links) THROW 65000, 'Choose at least one container line to link.', 1;
        IF EXISTS (SELECT 1 FROM purchase.PurchaseCharges WHERE DocumentKind = N'PINV' AND DocumentId = @InvoiceId)
            THROW 65020, 'This invoice has its own charges. Remove them: the charges of an import are entered on its containers.', 1;
        IF EXISTS (SELECT 1 FROM purchase.LandedCostAdjustments WHERE SourceInvoiceId = @InvoiceId AND Status <> 3)
            THROW 65028, 'This invoice has a landed cost adjustment: cancel or delete it before linking the invoice to containers.', 1;
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments r WHERE r.SourceDocumentId = @InvoiceId AND r.Status <> 3)
            THROW 65028, 'This invoice has purchase returns: it can no longer be linked to containers.', 1;

        -- the containers: still Draft or Confirmed
        SELECT TOP (1) @Msg = CASE WHEN c.Status = 8 THEN N'Container ' + c.ContainerRef + N' is cancelled.'
                                   ELSE N'Container ' + c.ContainerRef + N' has started moving: it can no longer be linked.' END
        FROM @Links k
        INNER JOIN logistics.ContainerLines cl ON cl.Id = k.ContainerLineId
        INNER JOIN logistics.Containers c      ON c.Id = cl.ContainerId
        WHERE c.Status NOT IN (1, 2)
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 65027, @Msg, 1;

        -- the lines: of this order, a quantity, within what is loaded and not yet invoiced
        SELECT TOP (1) @Msg =
            CASE WHEN cl.Id IS NULL THEN N'A container line to link no longer exists.'
                 WHEN cl.PurchaseOrderId <> @OrderId THEN N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10))
                      + N' belongs to another purchase order.'
                 WHEN k.QuantityBase <= 0 THEN N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10))
                      + N': the quantity must be greater than zero.'
                 ELSE N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                      + CAST(k.QuantityBase AS NVARCHAR(20)) + N' to link but only ' + CAST(cl.QuantityBase - ISNULL(q.Qty, 0) AS NVARCHAR(20))
                      + N' are loaded and not yet invoiced.' END
        FROM @Links k
        LEFT JOIN logistics.ContainerLines cl ON cl.Id = k.ContainerLineId
        LEFT JOIN logistics.Containers c      ON c.Id = cl.ContainerId
        LEFT JOIN inventory.Items i           ON i.Id = cl.ItemId
        OUTER APPLY (SELECT Qty = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                     INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                     WHERE pil.ContainerLineId = cl.Id AND pd.Status <> 3) q
        WHERE cl.Id IS NULL OR cl.PurchaseOrderId <> @OrderId OR k.QuantityBase <= 0
           OR k.QuantityBase > cl.QuantityBase - ISNULL(q.Qty, 0)
        ORDER BY c.ContainerRef, cl.LineNumber;
        IF @Msg IS NOT NULL THROW 65019, @Msg, 1;

        -- the invoice: within its pieces of that order line outside containers
        SELECT TOP (1) @Msg = i.ItemCode + N': ' + CAST(t.Qty AS NVARCHAR(20)) + N' pieces to link but only '
                              + CAST(ISNULL(u.UnlinkedBase, 0) AS NVARCHAR(20)) + N' of this invoice (order line '
                              + CAST(pol.LineNumber AS NVARCHAR(10)) + N') are not in a container yet.'
        FROM (SELECT cl.PoLineId, Qty = SUM(k.QuantityBase) FROM @Links k
              INNER JOIN logistics.ContainerLines cl ON cl.Id = k.ContainerLineId GROUP BY cl.PoLineId) t
        INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = t.PoLineId
        INNER JOIN inventory.Items i                  ON i.Id = pol.ItemId
        LEFT  JOIN purchase.fn_PurchaseInvoice_Unlinked(@InvoiceId) u ON u.PoLineId = t.PoLineId
        WHERE t.Qty > ISNULL(u.UnlinkedBase, 0)
        ORDER BY pol.LineNumber;
        IF @Msg IS NOT NULL THROW 65019, @Msg, 1;

        DECLARE @OldTotal DECIMAL(18,2) = (SELECT ISNULL(SUM(LineTotal), 0) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId);
        DECLARE @NextNo INT = (SELECT ISNULL(MAX(LineNumber), 0) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId);
        DECLARE @Cl INT, @PoLineId INT, @Need INT, @LineId INT, @Have INT, @Pf INT, @ItemId INT, @BaseUnit INT, @LastLine INT;

        DECLARE links CURSOR LOCAL STATIC READ_ONLY FORWARD_ONLY FOR
            SELECT k.ContainerLineId, cl.PoLineId, k.QuantityBase
            FROM @Links k
            INNER JOIN logistics.ContainerLines cl ON cl.Id = k.ContainerLineId
            INNER JOIN logistics.Containers c      ON c.Id = cl.ContainerId
            ORDER BY c.ContainerRef, cl.LineNumber;
        OPEN links;
        FETCH NEXT FROM links INTO @Cl, @PoLineId, @Need;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            WHILE @Need > 0
            BEGIN
                SET @LineId = NULL;
                SELECT TOP (1) @LineId = Id, @Have = QuantityBase, @Pf = PackingFormula, @ItemId = ItemId
                FROM purchase.PurchaseDocumentLines
                WHERE DocumentId = @InvoiceId AND ContainerLineId IS NULL AND SourceLineId = @PoLineId AND QuantityBase > 0
                ORDER BY LineNumber;
                IF @LineId IS NULL THROW 65019, 'The invoice has no more pieces of that order line outside containers.', 1;

                IF @Have <= @Need
                BEGIN
                    -- the whole line goes into the container
                    UPDATE purchase.PurchaseDocumentLines SET ContainerLineId = @Cl WHERE Id = @LineId;
                    SET @Need -= @Have;
                    SET @LastLine = @LineId;
                END
                ELSE
                BEGIN
                    SET @BaseUnit = (SELECT TOP (1) Id FROM inventory.ItemUnits WHERE ItemId = @ItemId AND IsBaseUnit = 1 ORDER BY Id);
                    IF @BaseUnit IS NULL AND (@Need % @Pf <> 0 OR (@Have - @Need) % @Pf <> 0)
                        THROW 65028, 'The item of a line to split has no base unit.', 1;

                    -- the linked part: a new line
                    SET @NextNo += 1;
                    INSERT INTO purchase.PurchaseDocumentLines (DocumentId, LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, PackingFormula,
                                                                UnitPrice, DiscountPercent, UnitCostBase, ReceivedQuantityBase, ReturnedQuantityBase,
                                                                ImportRowNumber, Notes, SourceLineId, ShippedQuantityBase, FobCostBase, AllocatedChargesBase,
                                                                ContainerLineId)
                    SELECT @InvoiceId, @NextNo, l.ItemId,
                           CASE WHEN @Need % l.PackingFormula = 0 THEN l.ItemUnitId ELSE @BaseUnit END,
                           l.WarehouseId, l.ExpiryDate,
                           CASE WHEN @Need % l.PackingFormula = 0 THEN @Need / l.PackingFormula ELSE @Need END,
                           CASE WHEN @Need % l.PackingFormula = 0 THEN l.PackingFormula ELSE 1 END,
                           CASE WHEN @Need % l.PackingFormula = 0 THEN l.UnitPrice ELSE ROUND(l.UnitPrice / l.PackingFormula, 4) END,
                           l.DiscountPercent, l.UnitCostBase, 0, 0, l.ImportRowNumber, l.Notes, l.SourceLineId, 0, l.FobCostBase, 0, @Cl
                    FROM purchase.PurchaseDocumentLines l
                    WHERE l.Id = @LineId;

                    -- the rest stays where it was, unlinked (it keeps its id: what refers to the line still finds it)
                    UPDATE purchase.PurchaseDocumentLines
                    SET ItemUnitId     = CASE WHEN (@Have - @Need) % PackingFormula = 0 THEN ItemUnitId ELSE @BaseUnit END,
                        Quantity       = CASE WHEN (@Have - @Need) % PackingFormula = 0 THEN (@Have - @Need) / PackingFormula ELSE @Have - @Need END,
                        UnitPrice      = CASE WHEN (@Have - @Need) % PackingFormula = 0 THEN UnitPrice ELSE ROUND(UnitPrice / PackingFormula, 4) END,
                        PackingFormula = CASE WHEN (@Have - @Need) % PackingFormula = 0 THEN PackingFormula ELSE 1 END
                    WHERE Id = @LineId;

                    SET @Need = 0;
                    SET @LastLine = @LineId;
                END
            END
            FETCH NEXT FROM links INTO @Cl, @PoLineId, @Need;
        END
        CLOSE links;
        DEALLOCATE links;

        -- the lines of every container first, by container, then what is not in a container yet
        UPDATE l SET LineNumber = x.Seq
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN (SELECT pl.Id, Seq = ROW_NUMBER() OVER (ORDER BY CASE WHEN pl.ContainerLineId IS NULL THEN 1 ELSE 0 END,
                                                                    c.ContainerRef, cl.LineNumber, pl.LineNumber, pl.Id)
                    FROM purchase.PurchaseDocumentLines pl
                    LEFT JOIN logistics.ContainerLines cl ON cl.Id = pl.ContainerLineId
                    LEFT JOIN logistics.Containers c      ON c.Id = cl.ContainerId
                    WHERE pl.DocumentId = @InvoiceId) x ON x.Id = l.Id
        WHERE l.LineNumber <> x.Seq;

        -- the document total does not change: a rounding difference goes on the last line split
        DECLARE @Diff DECIMAL(18,2) = @OldTotal - (SELECT ISNULL(SUM(LineTotal), 0) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId);
        IF @Diff <> 0 AND @LastLine IS NOT NULL
            UPDATE purchase.PurchaseDocumentLines
            SET UnitPrice = ROUND(UnitPrice + @Diff / NULLIF(Quantity * (1 - DiscountPercent / 100.0), 0), 4)
            WHERE Id = @LastLine;

        UPDATE d
        SET ReceiptMode = 2,
            TotalItems = x.Items, TotalQuantity = x.Qty, Subtotal = x.Sub, TotalAmount = x.Amt, TotalDiscount = x.Sub - x.Amt,
            TotalAmountBase = ROUND(x.Amt / d.ExchangeRate, 2), TotalLandedCostBase = ROUND(x.Amt / d.ExchangeRate, 2) + d.TotalChargesBase,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        FROM purchase.PurchaseDocuments d
        CROSS APPLY (SELECT COUNT(*) AS Items, ISNULL(SUM(QuantityBase), 0) AS Qty,
                            ISNULL(SUM(CONVERT(DECIMAL(18,2), Quantity * UnitPrice)), 0) AS Sub, ISNULL(SUM(LineTotal), 0) AS Amt
                     FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId) x
        WHERE d.Id = @InvoiceId;

        -- the value basis of the container charges follows the invoice, and both sides keep the history
        DECLARE @Cid INT, @Ref NVARCHAR(30), @Qty INT;
        DECLARE cts CURSOR LOCAL STATIC READ_ONLY FORWARD_ONLY FOR
            SELECT cl.ContainerId, c.ContainerRef, SUM(k.QuantityBase)
            FROM @Links k
            INNER JOIN logistics.ContainerLines cl ON cl.Id = k.ContainerLineId
            INNER JOIN logistics.Containers c      ON c.Id = cl.ContainerId
            GROUP BY cl.ContainerId, c.ContainerRef
            ORDER BY c.ContainerRef;
        OPEN cts;
        FETCH NEXT FROM cts INTO @Cid, @Ref, @Qty;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC logistics.usp_Container_ReallocateCharges @Cid, 1, 1;
            INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
            VALUES (@Cid, N'Updated', N'Linked to purchase invoice ' + @Number + N': ' + CAST(@Qty AS NVARCHAR(20)) + N' pieces', @UserId);
            FETCH NEXT FROM cts INTO @Cid, @Ref, @Qty;
        END
        CLOSE cts;
        DEALLOCATE cts;

        -- (78) THE AUDIT NAMES AT MOST 20 CONTAINERS, THEN "and N more"; aggregated as NVARCHAR(MAX). Over NVARCHAR(30)
        -- refs STRING_AGG returned NVARCHAR(4000) and failed (9829) from about 190 containers - the LEFT came too late -
        -- rolling back the whole link (Link containers, Add container and Auto-plan from the invoice).
        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        SELECT @InvoiceId, N'Updated',
               LEFT(CASE WHEN MAX(x.N) <= 20 THEN N'Linked to containers '
                         ELSE N'Linked to ' + CAST(MAX(x.N) AS NVARCHAR(10)) + N' containers: ' END
                    + STRING_AGG(CASE WHEN x.Rn <= 20 THEN CAST(x.Ref AS NVARCHAR(MAX)) + N' (' + CAST(x.Qty AS NVARCHAR(20)) + N')' END, N', ')
                      WITHIN GROUP (ORDER BY x.Ref)
                    + CASE WHEN MAX(x.N) > 20 THEN N' and ' + CAST(MAX(x.N) - 20 AS NVARCHAR(10)) + N' more' ELSE N'' END, 1000), @UserId
        FROM (SELECT g.Ref, g.Qty, Rn = ROW_NUMBER() OVER (ORDER BY g.Ref), N = COUNT(*) OVER ()
              FROM (SELECT Ref = c.ContainerRef, Qty = SUM(k.QuantityBase)
                    FROM @Links k
                    INNER JOIN logistics.ContainerLines cl ON cl.Id = k.ContainerLineId
                    INNER JOIN logistics.Containers c      ON c.Id = cl.ContainerId
                    GROUP BY c.ContainerRef) g) x;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    EXEC purchase.usp_PurchaseInvoice_ContainerSummary @InvoiceId;
END
GO

-- Re-created (78) from the body of script 47: ContainerRef names at most 5 containers ("KTG-2026-0001, KTG-2026-0002,
-- KTG-2026-0003 +1996 more" above), so Supplier Payments opens an invoice of any number of containers (the
-- per-container split, purchase.fn_InvoiceContainerSettlement, lists them all); a CHG- number above 999,999 keeps all
-- its digits. Nothing else changes.
CREATE OR ALTER FUNCTION purchase.fn_PayableDocument (@Kind NVARCHAR(10), @DocumentId INT)
RETURNS TABLE
AS
RETURN
(
    SELECT DocumentKind = N'PINV', DocumentId = d.Id, d.DocumentNumber, d.DocumentDate, PayeeId = d.SupplierId,
           d.CurrencyId, c.CurrencyCode, c.DecimalPlaces, d.ExchangeRate,
           DocumentTotal = d.TotalAmount, st.ReturnedAmount, st.PaidAmount, st.OutstandingAmount, st.PaymentStatus,
           -- (78) at most 5 refs, else the first 3 and "+N more" (aggregated as NVARCHAR(MAX): 9829 above about 267)
           ContainerRef = (SELECT CAST(STRING_AGG(CASE WHEN r.N <= 5 OR r.Rn <= 3 THEN CAST(r.ContainerRef AS NVARCHAR(MAX)) END, N', ')
                                           WITHIN GROUP (ORDER BY r.ContainerRef)
                                       + CASE WHEN MAX(r.N) > 5 THEN N' +' + CAST(MAX(r.N) - 3 AS NVARCHAR(10)) + N' more' ELSE N'' END
                                       AS NVARCHAR(200))
                           FROM (SELECT q.ContainerRef, Rn = ROW_NUMBER() OVER (ORDER BY q.ContainerRef), N = COUNT(*) OVER ()
                                 FROM (SELECT DISTINCT k.ContainerRef
                                       FROM purchase.PurchaseDocumentLines l
                                       INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
                                       INNER JOIN logistics.Containers k      ON k.Id = cl.ContainerId
                                       WHERE l.DocumentId = d.Id) q) r),
           ChargeTypeName = CAST(NULL AS NVARCHAR(100)), Reference = d.SupplierReference
    FROM purchase.PurchaseDocuments d
    INNER JOIN masterdata.Currencies c ON c.Id = d.CurrencyId
    CROSS APPLY purchase.fn_InvoiceSettlement(d.Id) st
    WHERE @Kind = N'PINV' AND d.Id = @DocumentId
    UNION ALL
    SELECT N'CHARGE', ch.Id, N'CHG-' + CASE WHEN ch.Id > 999999 THEN CAST(ch.Id AS NVARCHAR(10)) ELSE RIGHT(N'000000' + CAST(ch.Id AS NVARCHAR(10)), 6) END, ch.ChargeDate, ch.ProviderPartyId,
           ch.CurrencyId, c.CurrencyCode, c.DecimalPlaces, ch.ExchangeRate,
           ch.Amount, CAST(0 AS DECIMAL(18,2)), st.PaidAmount, st.OutstandingAmount, st.PaymentStatus,
           k.ContainerRef, t.ChargeName, ch.Reference
    FROM logistics.ContainerCharges ch
    INNER JOIN masterdata.Currencies c ON c.Id = ch.CurrencyId
    INNER JOIN logistics.Containers k  ON k.Id = ch.ContainerId
    INNER JOIN purchase.ChargeTypes t  ON t.Id = ch.ChargeTypeId
    CROSS APPLY logistics.fn_ContainerChargeSettlement(ch.Id) st
    WHERE @Kind = N'CHARGE' AND ch.Id = @DocumentId
);
GO

-- Re-created (78) from the body of script 64: Receipts names at most 10 goods receipts per invoice line, else the first 5
-- and "+N more". Nothing else changes.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseInvoice_ReceiptCostPreview
    @InvoiceId INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Status TINYINT, @Rate DECIMAL(18,6), @SupplierId INT, @Code NVARCHAR(20);
    SELECT @Status = d.Status, @Rate = d.ExchangeRate, @SupplierId = d.SupplierId, @Code = dt.Code
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    WHERE d.Id = @InvoiceId;
    IF @Status IS NULL OR @Code <> N'PINV' THROW 65006, 'Purchase invoice not found.', 1;

    -- the draft's own charges per line: as allocated, else shared by value (an estimate until it is posted)
    DECLARE @ChargesTotal DECIMAL(18,2) = ISNULL((SELECT SUM(AmountBase) FROM purchase.PurchaseCharges
                                                  WHERE DocumentKind = N'PINV' AND DocumentId = @InvoiceId AND IncludeInLandedCost = 1), 0);
    DECLARE @HasAllocations BIT = CASE WHEN EXISTS (SELECT 1 FROM purchase.PurchaseChargeAllocations x
                                                    INNER JOIN purchase.PurchaseCharges c ON c.Id = x.ChargeId
                                                    WHERE c.DocumentKind = N'PINV' AND c.DocumentId = @InvoiceId AND c.IncludeInLandedCost = 1)
                                       THEN 1 ELSE 0 END;
    DECLARE @ValueTotal DECIMAL(18,6) = (SELECT SUM(LineTotal / @Rate) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId);

    DECLARE @L TABLE (LineId INT NOT NULL PRIMARY KEY, LineNumber INT NOT NULL, ItemId INT NOT NULL, GroupKey NVARCHAR(40) NOT NULL,
                      ContainerLineId INT NULL, QuantityBase INT NOT NULL, FobBase DECIMAL(18,6) NOT NULL, ChargesBase DECIMAL(18,6) NOT NULL,
                      Rem INT NOT NULL);
    INSERT INTO @L (LineId, LineNumber, ItemId, GroupKey, ContainerLineId, QuantityBase, FobBase, ChargesBase, Rem)
    SELECT l.Id, l.LineNumber, l.ItemId,
           CASE WHEN l.SourceLineId IS NOT NULL THEN N'P' + CAST(l.SourceLineId AS NVARCHAR(12))
                ELSE N'S' + CAST(@SupplierId AS NVARCHAR(12)) + N'.' + CAST(l.ItemId AS NVARCHAR(12)) END,
           l.ContainerLineId, l.QuantityBase,
           CAST(l.LineTotal / @Rate / l.QuantityBase AS DECIMAL(18,6)),
           CAST(CASE WHEN @HasAllocations = 1
                     THEN ISNULL((SELECT SUM(x.AmountBase) FROM purchase.PurchaseChargeAllocations x
                                  INNER JOIN purchase.PurchaseCharges c ON c.Id = x.ChargeId
                                  WHERE x.PurchaseLineId = l.Id AND c.DocumentKind = N'PINV' AND c.DocumentId = @InvoiceId
                                    AND c.IncludeInLandedCost = 1), 0)
                     WHEN @ValueTotal > 0 THEN @ChargesTotal * (l.LineTotal / @Rate) / @ValueTotal
                     ELSE 0 END / l.QuantityBase AS DECIMAL(18,6)),
           -- a line of a container offloaded before goods receipts takes nothing: its goods are received already
           CASE WHEN rb.ReceivedBy = N'Offload' THEN 0 ELSE l.QuantityBase END
    FROM purchase.PurchaseDocumentLines l
    LEFT JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
    OUTER APPLY logistics.fn_Container_ReceivedBy(cl.ContainerId) rb
    WHERE l.DocumentId = @InvoiceId AND @Status = 1;

    -- received pieces of those groups not matched to an invoice yet, with what they cost now
    DECLARE @U TABLE (LineId INT NOT NULL PRIMARY KEY, GoodsReceiptId INT NOT NULL, GroupKey NVARCHAR(40) NOT NULL, ContainerLineId INT NULL,
                      ItemId INT NOT NULL, T DATETIME2(3) NOT NULL, Rem INT NOT NULL, IsContainer BIT NOT NULL,
                      BaseFob DECIMAL(18,6) NOT NULL, BaseCharges DECIMAL(18,6) NOT NULL, ContainerCharges DECIMAL(18,6) NOT NULL,
                      RNet DECIMAL(18,6) NOT NULL);
    INSERT INTO @U (LineId, GoodsReceiptId, GroupKey, ContainerLineId, ItemId, T, Rem, IsContainer, BaseFob, BaseCharges, ContainerCharges, RNet)
    SELECT t.GoodsReceiptLineId, t.GoodsReceiptId,
           CASE WHEN t.PoLineId IS NOT NULL THEN N'P' + CAST(t.PoLineId AS NVARCHAR(12))
                ELSE N'S' + CAST(t.SupplierId AS NVARCHAR(12)) + N'.' + CAST(t.ItemId AS NVARCHAR(12)) END,
           t.ContainerLineId, t.ItemId, ISNULL(g.PostedAtUtc, g.CreatedAtUtc), t.ReceivedBase - t.MatchedBase, t.IsContainerLine,
           t.BaseFobBase, t.BaseChargesBase, CASE WHEN t.IsContainerLine = 1 THEN t.TargetChargesBase ELSE 0 END, t.NetReceivedBase
    FROM (SELECT DISTINCT gl.GoodsReceiptId
          FROM purchase.GoodsReceiptLines gl
          INNER JOIN purchase.GoodsReceipts gr ON gr.Id = gl.GoodsReceiptId AND gr.Status = 2
          WHERE gl.PoLineId IN (SELECT l.SourceLineId FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = @InvoiceId)
             OR (gl.PoLineId IS NULL AND gl.SupplierId = @SupplierId
                 AND gl.ItemId IN (SELECT l.ItemId FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = @InvoiceId AND l.SourceLineId IS NULL))) r
    CROSS APPLY purchase.fn_GoodsReceiptLine_TargetCost(r.GoodsReceiptId) t
    INNER JOIN purchase.GoodsReceipts g ON g.Id = t.GoodsReceiptId
    WHERE t.ReceivedBase > t.MatchedBase;

    DELETE FROM @U WHERE GroupKey NOT IN (SELECT GroupKey FROM @L);

    -- first in first out, as the rematch would: the container line first, then the group
    DECLARE @Take TABLE (ULineId INT NOT NULL, LLineId INT NOT NULL, Qty INT NOT NULL);
    DECLARE @Pass TABLE (ULineId INT NOT NULL, LLineId INT NOT NULL, Qty INT NOT NULL);

    WITH u AS (SELECT LineId, K = ContainerLineId, Rem,
                      E = SUM(Rem) OVER (PARTITION BY ContainerLineId ORDER BY T, LineId ROWS UNBOUNDED PRECEDING)
               FROM @U WHERE Rem > 0 AND ContainerLineId IS NOT NULL),
         l AS (SELECT LineId, K = ContainerLineId, Rem,
                      E = SUM(Rem) OVER (PARTITION BY ContainerLineId ORDER BY LineNumber ROWS UNBOUNDED PRECEDING)
               FROM @L WHERE Rem > 0 AND ContainerLineId IS NOT NULL)
    INSERT INTO @Pass (ULineId, LLineId, Qty)
    SELECT u.LineId, l.LineId,
           (CASE WHEN u.E < l.E THEN u.E ELSE l.E END) - (CASE WHEN u.E - u.Rem > l.E - l.Rem THEN u.E - u.Rem ELSE l.E - l.Rem END)
    FROM u INNER JOIN l ON l.K = u.K
    WHERE u.E - u.Rem < l.E AND l.E - l.Rem < u.E;

    UPDATE u SET Rem = u.Rem - p.Qty FROM @U u INNER JOIN (SELECT ULineId, Qty = SUM(Qty) FROM @Pass GROUP BY ULineId) p ON p.ULineId = u.LineId;
    UPDATE l SET Rem = l.Rem - p.Qty FROM @L l INNER JOIN (SELECT LLineId, Qty = SUM(Qty) FROM @Pass GROUP BY LLineId) p ON p.LLineId = l.LineId;
    INSERT INTO @Take (ULineId, LLineId, Qty) SELECT ULineId, LLineId, Qty FROM @Pass;
    DELETE FROM @Pass;

    WITH u AS (SELECT LineId, K = GroupKey, Rem,
                      E = SUM(Rem) OVER (PARTITION BY GroupKey ORDER BY T, LineId ROWS UNBOUNDED PRECEDING)
               FROM @U WHERE Rem > 0),
         l AS (SELECT LineId, K = GroupKey, Rem,
                      E = SUM(Rem) OVER (PARTITION BY GroupKey ORDER BY LineNumber ROWS UNBOUNDED PRECEDING)
               FROM @L WHERE Rem > 0)
    INSERT INTO @Take (ULineId, LLineId, Qty)
    SELECT u.LineId, l.LineId,
           (CASE WHEN u.E < l.E THEN u.E ELSE l.E END) - (CASE WHEN u.E - u.Rem > l.E - l.Rem THEN u.E - u.Rem ELSE l.E - l.Rem END)
    FROM u INNER JOIN l ON l.K = u.K
    WHERE u.E - u.Rem < l.E AND l.E - l.Rem < u.E;

    -- per piece taken: now = its base cost (+ its container's charges); with the invoice = the invoice FOB + the invoice's
    -- own charges (+ the same container charges for container pieces: fn_GoodsReceiptLine_TargetCost)
    DECLARE @T TABLE (LLineId INT NOT NULL, ULineId INT NOT NULL, ItemId INT NOT NULL, Qty INT NOT NULL,
                      CostNow DECIMAL(18,6) NOT NULL, CostNew DECIMAL(18,6) NOT NULL, PRIMARY KEY (LLineId, ULineId));
    INSERT INTO @T (LLineId, ULineId, ItemId, Qty, CostNow, CostNew)
    SELECT k.LLineId, k.ULineId, u.ItemId, SUM(k.Qty),
           MAX(CASE WHEN u.IsContainer = 1 THEN u.BaseFob + u.ContainerCharges ELSE u.BaseFob + u.BaseCharges END),
           MAX(CASE WHEN u.IsContainer = 1 THEN l.FobBase + l.ChargesBase + u.ContainerCharges ELSE l.FobBase + l.ChargesBase END)
    FROM @Take k
    INNER JOIN @U u ON u.LineId = k.ULineId
    INNER JOIN @L l ON l.LineId = k.LLineId
    GROUP BY k.LLineId, k.ULineId, u.ItemId;

    -- the stock share per item, on today's company stock, over the receipt lines involved (as the true-up)
    DECLARE @Items TABLE (ItemId INT NOT NULL PRIMARY KEY, NetReceived DECIMAL(18,6) NOT NULL, OnHand DECIMAL(18,6) NOT NULL, Ratio DECIMAL(18,10) NOT NULL);
    INSERT INTO @Items (ItemId, NetReceived, OnHand, Ratio)
    SELECT x.ItemId, x.NetReceived, oh.Q,
           CASE WHEN oh.Q <= 0 OR x.NetReceived <= 0 THEN 0 WHEN oh.Q < x.NetReceived THEN oh.Q / x.NetReceived ELSE 1 END
    FROM (SELECT u.ItemId, NetReceived = SUM(CASE WHEN u.RNet > 0 THEN u.RNet ELSE 0 END)
          FROM @U u WHERE u.LineId IN (SELECT ULineId FROM @T) GROUP BY u.ItemId) x
    CROSS APPLY (SELECT Q = CAST(inventory.fn_StockOnHand(x.ItemId, NULL) AS DECIMAL(18,6))) oh;

    SELECT InvoiceLineId           = l.Id,
           l.LineNumber, l.ItemId, i.ItemCode, i.ItemName,
           InvoicedBase            = l.QuantityBase,
           ReceivedNotInvoicedBase = ISNULL(x.Qty, 0),
           CurrentCostBase         = CAST(x.Now / NULLIF(x.Qty, 0) AS DECIMAL(18,6)),
           InvoiceCostBase         = CAST(x.New / NULLIF(x.Qty, 0) AS DECIMAL(18,6)),
           DifferenceBase          = CAST(ISNULL(x.Diff, 0) AS DECIMAL(18,2)),
           EstimatedInventoryBase  = CAST(ROUND(ISNULL(x.Diff, 0) * ISNULL(it.Ratio, 0), 2) AS DECIMAL(18,2)),
           EstimatedCogsBase       = CAST(ISNULL(x.Diff, 0) - ROUND(ISNULL(x.Diff, 0) * ISNULL(it.Ratio, 0), 2) AS DECIMAL(18,2)),
           CompanyOnHandBase       = CAST(inventory.fn_StockOnHand(l.ItemId, NULL) AS INT),
           Receipts                = x.Receipts,
           IsEstimate              = CAST(1 AS BIT)
    FROM purchase.PurchaseDocumentLines l
    INNER JOIN inventory.Items i ON i.Id = l.ItemId
    OUTER APPLY (SELECT Qty  = SUM(t.Qty),
                        Now  = SUM(t.Qty * t.CostNow),
                        New  = SUM(t.Qty * t.CostNew),
                        Diff = SUM(ROUND((t.CostNew - t.CostNow) * t.Qty, 2)),
                        -- (78) at most 10 numbers, else the first 5 and "+N more" (NVARCHAR(MAX): 9829 above about 210)
                        Receipts = (SELECT CAST(STRING_AGG(CASE WHEN z.N <= 10 OR z.Rn <= 5 THEN CAST(z.DocumentNumber AS NVARCHAR(MAX)) END, N', ')
                                                    WITHIN GROUP (ORDER BY z.DocumentNumber)
                                                + CASE WHEN MAX(z.N) > 10 THEN N' +' + CAST(MAX(z.N) - 5 AS NVARCHAR(10)) + N' more' ELSE N'' END
                                                AS NVARCHAR(400))
                                    FROM (SELECT y.DocumentNumber, Rn = ROW_NUMBER() OVER (ORDER BY y.DocumentNumber), N = COUNT(*) OVER ()
                                          FROM (SELECT DISTINCT g.DocumentNumber FROM @T t2
                                                INNER JOIN @U u2 ON u2.LineId = t2.ULineId
                                                INNER JOIN purchase.GoodsReceipts g ON g.Id = u2.GoodsReceiptId
                                                WHERE t2.LLineId = l.Id) y) z)
                 FROM @T t WHERE t.LLineId = l.Id) x
    LEFT JOIN @Items it ON it.ItemId = l.ItemId
    WHERE l.DocumentId = @InvoiceId AND @Status = 1
    ORDER BY l.LineNumber;
END
GO

/* ================================================================== 4. Apply to other containers: every candidate */

-- Re-created (78) from the body of script 28: no TOP (500) any more. Nothing else changes.
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

    -- (78) every candidate: TOP (500) cut the list silently, and the newest containers were the ones missing
    SELECT c.Id AS ContainerId, c.ContainerRef, c.ContainerNo, ct.TypeCode AS ContainerTypeCode, c.Status, c.CurrentLocation,
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

/* ================================================================== 5. Bigger pages for the lists of one order or movement */

-- Re-created (78) from the body of script 65: a page holds up to 5,000 containers (200 before). Nothing else changes.
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
           CloseBlockedReason = cb.Reason
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

-- Re-created (78) from the body of script 53: a page holds up to 5,000 candidates (200 before). Nothing else changes.
CREATE OR ALTER PROCEDURE logistics.usp_Movement_ContainerCandidates
    @MovementId      INT           = NULL,
    @FromPlaceId     INT,
    @Search          NVARCHAR(100) = NULL,   -- ref, container no., B/L, vessel, order no., supplier
    @PurchaseOrderId INT           = NULL,
    @SupplierId      INT           = NULL,
    @Status          TINYINT       = NULL,
    @IncludeBlocked  BIT           = 0,
    @PageNumber      INT           = 1,
    @PageSize        INT           = 200,
    @ToPlaceId       INT           = NULL,   -- (53) the To on the page
    @MovementTypeId  INT           = NULL    -- (53) the type on the page
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    -- (78) up to 5,000 a page (200 before): the movement's list holds every candidate at its From, and like the search
    -- every page costs the whole check (logistics.fn_Movement_ContainerCheck).
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 200;
    IF @PageSize > 5000 SET @PageSize = 5000;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @IncludeBlocked = ISNULL(@IncludeBlocked, 0);

    IF @FromPlaceId IS NULL THROW 70000, 'Choose the From first.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Ports WHERE Id = @FromPlaceId AND IsActive = 1)
        THROW 70000, 'The departure place is not found or inactive.', 1;
    IF @MovementId IS NOT NULL
    BEGIN
        DECLARE @MovementStatus TINYINT = (SELECT Status FROM logistics.Movements WHERE Id = @MovementId);
        IF @MovementStatus IS NULL THROW 70006, 'Movement not found.', 1;
        IF @MovementStatus NOT IN (1, 2) THROW 70005, 'A completed or cancelled movement can no longer be changed.', 1;
        SELECT @ToPlaceId = ISNULL(@ToPlaceId, ToPlaceId), @MovementTypeId = ISNULL(@MovementTypeId, MovementTypeId)
        FROM logistics.Movements WHERE Id = @MovementId;
    END

    SELECT f.ContainerId AS Id, f.ContainerRef, f.ContainerNo, f.SealNo, f.ContainerTypeCode, f.OrderNumbers, f.SupplierNames,
           f.ItemSummary, f.Pieces, f.Status, f.Eta, f.PlaceName, f.PreviousMovementNo, f.PortOfLoadingName,
           f.CanAdd, f.Reason, f.Note,
           COUNT(*) OVER () AS TotalCount
    FROM logistics.fn_Movement_ContainerCheck(@MovementId, @FromPlaceId, @ToPlaceId, @MovementTypeId) f
    WHERE f.OnMovement = 0 AND f.Status < 6
      AND (@IncludeBlocked = 1 OR f.CanAdd = 1)
      AND (@Status IS NULL OR f.Status = @Status)
      AND (@Search IS NULL OR f.ContainerRef LIKE N'%' + @Search + N'%' OR f.ContainerNo LIKE N'%' + @Search + N'%'
           OR f.BlNo LIKE N'%' + @Search + N'%' OR f.VesselName LIKE N'%' + @Search + N'%'
           OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                      INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                      INNER JOIN masterdata.Parties sp        ON sp.Id = d.SupplierId
                      WHERE cl.ContainerId = f.ContainerId
                        AND (d.DocumentNumber LIKE N'%' + @Search + N'%' OR sp.PartyName LIKE N'%' + @Search + N'%')))
      AND (@SupplierId IS NULL OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                                          INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                                          WHERE cl.ContainerId = f.ContainerId AND d.SupplierId = @SupplierId))
      AND (@PurchaseOrderId IS NULL OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                                               WHERE cl.ContainerId = f.ContainerId AND cl.PurchaseOrderId = @PurchaseOrderId))
    ORDER BY f.CanAdd DESC, f.OrderDate DESC, f.ContainerRef
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

-- Re-created (78) from the body of script 53: 10,000 numbers a call (500 before). Nothing else changes.
CREATE OR ALTER PROCEDURE logistics.usp_Movement_MatchContainers
    @MovementId  INT = NULL,
    @FromPlaceId INT,
    @Numbers     logistics.tvp_TextList READONLY,
    @ToPlaceId      INT = NULL,   -- (53) the To on the page
    @MovementTypeId INT = NULL    -- (53) the type on the page
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Rows TABLE (RowNo INT NOT NULL PRIMARY KEY, InputNumber NVARCHAR(100) NOT NULL, NumberKey NVARCHAR(100) NOT NULL,
                         Hits INT NULL, OpenHits INT NULL, ContainerId INT NULL);
    INSERT INTO @Rows (RowNo, InputNumber, NumberKey)
    SELECT n.RowNo, LTRIM(RTRIM(n.Value)), k.NumberKey
    FROM @Numbers n
    CROSS APPLY logistics.fn_ContainerNumberKey(n.Value) k
    WHERE k.NumberKey <> N'';
    -- (78) 10,000 numbers a call (500 before): a movement's file may list any number of containers, and a file cut in
    -- calls of 500 could no longer say "Already in the list, row N" for a number repeated in two parts.
    IF (SELECT COUNT(*) FROM @Rows) > 10000 THROW 70000, 'At most 10,000 container numbers at a time.', 1;

    IF @FromPlaceId IS NULL THROW 70000, 'Choose the From first.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Ports WHERE Id = @FromPlaceId AND IsActive = 1)
        THROW 70000, 'The departure place is not found or inactive.', 1;
    IF @MovementId IS NOT NULL
    BEGIN
        DECLARE @MovementStatus TINYINT = (SELECT Status FROM logistics.Movements WHERE Id = @MovementId);
        IF @MovementStatus IS NULL THROW 70006, 'Movement not found.', 1;
        IF @MovementStatus NOT IN (1, 2) THROW 70005, 'A completed or cancelled movement can no longer be changed.', 1;
        SELECT @ToPlaceId = ISNULL(@ToPlaceId, ToPlaceId), @MovementTypeId = ISNULL(@MovementTypeId, MovementTypeId)
        FROM logistics.Movements WHERE Id = @MovementId;
    END

    -- the containers of every number: the container number first, then the ref
    DECLARE @Hits TABLE (RowNo INT NOT NULL, ContainerId INT NOT NULL, ContainerRef NVARCHAR(30) NOT NULL, IsOpen BIT NOT NULL,
                         PRIMARY KEY (RowNo, ContainerId));
    INSERT INTO @Hits (RowNo, ContainerId, ContainerRef, IsOpen)
    SELECT r.RowNo, c.Id, c.ContainerRef, CASE WHEN c.Status < 6 THEN 1 ELSE 0 END
    FROM logistics.Containers c
    CROSS APPLY logistics.fn_ContainerNumberKey(c.ContainerNo) k
    INNER JOIN @Rows r ON r.NumberKey = k.NumberKey;

    INSERT INTO @Hits (RowNo, ContainerId, ContainerRef, IsOpen)
    SELECT r.RowNo, c.Id, c.ContainerRef, CASE WHEN c.Status < 6 THEN 1 ELSE 0 END
    FROM logistics.Containers c
    CROSS APPLY logistics.fn_ContainerNumberKey(c.ContainerRef) k
    INNER JOIN @Rows r ON r.NumberKey = k.NumberKey
    WHERE NOT EXISTS (SELECT 1 FROM @Hits h WHERE h.RowNo = r.RowNo);

    -- one container per number: an open one wins over offloaded / closed / cancelled ones, two open ones are ambiguous
    UPDATE r
    SET Hits = h.Hits, OpenHits = h.OpenHits, ContainerId = CASE WHEN h.OpenHits > 1 THEN NULL ELSE pick.ContainerId END
    FROM @Rows r
    CROSS APPLY (SELECT Hits = COUNT(*), OpenHits = ISNULL(SUM(CAST(x.IsOpen AS INT)), 0) FROM @Hits x WHERE x.RowNo = r.RowNo) h
    OUTER APPLY (SELECT TOP (1) x.ContainerId FROM @Hits x WHERE x.RowNo = r.RowNo ORDER BY x.IsOpen DESC, x.ContainerId DESC) pick;

    WITH d AS
    (
        SELECT r.RowNo, r.InputNumber, r.Hits, r.OpenHits, r.ContainerId,
               FirstRowNo = MIN(r.RowNo) OVER (PARTITION BY CASE WHEN r.ContainerId IS NOT NULL
                                                                 THEN N'C' + CAST(r.ContainerId AS NVARCHAR(12))
                                                                 ELSE N'N' + r.NumberKey END)
        FROM @Rows r
    )
    SELECT d.RowNo, d.InputNumber, x.Result,
           f.ContainerId, f.ContainerRef, f.ContainerNo, f.ContainerTypeCode, f.Status, f.OrderNumbers, f.SupplierNames,
           f.ItemSummary, f.Pieces, f.PlaceName, f.PreviousMovementNo, f.PortOfLoadingName,
           Reason = CAST(CASE x.Result
                         WHEN N'Duplicate' THEN N'Already in the list, row ' + CAST(d.FirstRowNo AS NVARCHAR(12)) + N'.'
                         WHEN N'NotFound'  THEN N'No container with this number or ref. The number may not be typed on its container yet.'
                         WHEN N'Ambiguous' THEN LEFT(N'Found on ' + CAST(d.OpenHits AS NVARCHAR(12)) + N' containers: '
                                                     + (SELECT STRING_AGG(h.ContainerRef, N', ') WITHIN GROUP (ORDER BY h.ContainerRef)
                                                        FROM @Hits h WHERE h.RowNo = d.RowNo AND h.IsOpen = 1) + N'.', 300)
                         ELSE f.Reason END AS NVARCHAR(300)),
           Note = CASE WHEN x.Result IN (N'Ready', N'AlreadyOnMovement') THEN f.Note END
    FROM d
    LEFT JOIN logistics.fn_Movement_ContainerCheck(@MovementId, @FromPlaceId, @ToPlaceId, @MovementTypeId) f ON f.ContainerId = d.ContainerId
    CROSS APPLY (SELECT Result = CAST(CASE WHEN d.RowNo > d.FirstRowNo THEN N'Duplicate'
                                           WHEN d.Hits = 0 THEN N'NotFound'
                                           WHEN d.OpenHits > 1 THEN N'Ambiguous'
                                           WHEN f.OnMovement = 1 THEN N'AlreadyOnMovement'
                                           WHEN f.CanAdd = 0 THEN N'Blocked'
                                           ELSE N'Ready' END AS NVARCHAR(20))) x
    ORDER BY d.RowNo;
END
GO

/* ================================================================== 6. What the container dialogs fill in by themselves */

-- (78) NEW. One row for a purchase order: what Auto-plan containers... and Add Container... start with.
--   Supplier*        the order's supplier, shown read-only: a container's goods come from its order lines, so its
--                    supplier is never typed.
--   Forwarder*       the forwarder of the order's most recent container (not cancelled) that has an active one, else
--                    the order's supplier (ForwarderSource LastContainer | Supplier). The dialog keeps it editable.
--   CountryOfOrigin  the supplier's country (ISO 3166-1 alpha-2), NULL when the supplier has none.
-- No row when the id is not a purchase order.
CREATE OR ALTER PROCEDURE logistics.usp_Container_OrderDefaults
    @PurchaseOrderId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT PurchaseOrderId     = d.Id,
           PurchaseOrderNumber = d.DocumentNumber,
           SupplierId          = s.Id,
           SupplierCode        = s.PartyCode,
           SupplierName        = s.PartyName,
           CountryOfOrigin     = CAST(NULLIF(UPPER(LTRIM(RTRIM(s.Country))), N'') AS NCHAR(2)),
           ForwarderId         = f.Id,
           ForwarderCode       = f.PartyCode,
           ForwarderName       = f.PartyName,
           ForwarderSource     = CAST(CASE WHEN lc.ForwarderId IS NOT NULL THEN N'LastContainer' ELSE N'Supplier' END AS NVARCHAR(20)),
           LastContainerRef    = lc.ContainerRef
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId AND dt.Code = N'PO'
    INNER JOIN masterdata.Parties s       ON s.Id = d.SupplierId
    OUTER APPLY (SELECT TOP (1) c.ForwarderId, c.ContainerRef
                 FROM logistics.Containers c
                 INNER JOIN masterdata.Parties p ON p.Id = c.ForwarderId AND p.IsActive = 1
                 WHERE c.PurchaseOrderId = d.Id AND c.Status <> 8
                 ORDER BY c.Id DESC) lc
    INNER JOIN masterdata.Parties f       ON f.Id = ISNULL(lc.ForwarderId, s.Id)
    WHERE d.Id = @PurchaseOrderId;
END
GO

/* ================================================================== 7. A light container lookup for the pickers */

-- (78) NEW. The container pickers (New charge, the Container Charges filter) searched a preloaded page of the 200 newest
-- containers, and a preset selection outside it was read one container at a time (GET per container: 400 calls for a
-- selection of 600). This answers both in one call:
--   @Ids given     those containers, whatever their number (the preset selection);
--   else           at most @Top (1-200, default 50) matching @Search on the ref or the container no., newest first.
-- @MaxStatus keeps the containers up to that status (6 = Offloaded: the ones a charge can still be typed for).
CREATE OR ALTER PROCEDURE logistics.usp_Container_Lookup
    @Ids       logistics.tvp_IdList READONLY,
    @Search    NVARCHAR(100) = NULL,
    @MaxStatus TINYINT       = NULL,
    @Top       INT           = 50
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @Top IS NULL OR @Top < 1 OR @Top > 200 SET @Top = 50;

    IF EXISTS (SELECT 1 FROM @Ids)
        SELECT c.Id, c.ContainerRef, c.ContainerNo, c.Status, Pieces = c.TotalAllocatedBase, c.PurchaseOrderId
        FROM logistics.Containers c
        INNER JOIN @Ids i ON i.Id = c.Id
        WHERE @MaxStatus IS NULL OR c.Status <= @MaxStatus
        ORDER BY c.ContainerRef;
    ELSE
        SELECT TOP (@Top) c.Id, c.ContainerRef, c.ContainerNo, c.Status, Pieces = c.TotalAllocatedBase, c.PurchaseOrderId
        FROM logistics.Containers c
        WHERE (@MaxStatus IS NULL OR c.Status <= @MaxStatus)
          AND (@Search IS NULL OR c.ContainerRef LIKE N'%' + @Search + N'%' OR c.ContainerNo LIKE N'%' + @Search + N'%')
        ORDER BY c.Id DESC;
END
GO

/* ================================================================== 8. Check */

-- No 200 ceiling left in the plan procedures. Expected: none.
SELECT ObjectName = OBJECT_SCHEMA_NAME(m.object_id) + N'.' + OBJECT_NAME(m.object_id)
FROM sys.sql_modules m
WHERE m.object_id IN (OBJECT_ID(N'logistics.usp_Container_PlanFromOrder'), OBJECT_ID(N'logistics.usp_Container_CreateBatch'))
  AND (m.definition LIKE N'%more than 200 containers%' OR m.definition LIKE N'%At most 200 containers%');

-- The counters already past their length (their next numbers keep every digit). Expected on most databases: none.
SELECT dt.Code, dt.NumberLength, dt.NextNumber
FROM inventory.DocumentTypes dt
WHERE LEN(CAST(dt.NextNumber AS NVARCHAR(10))) > dt.NumberLength
UNION ALL
SELECT dt.Code + N' (' + ISNULL(b.BranchCode, N'-') + N', ' + CAST(s.[Year] AS NVARCHAR(4)) + N')', dt.NumberLength, s.NextNumber
FROM inventory.DocumentSequences s
INNER JOIN inventory.DocumentTypes dt ON dt.Id = s.DocumentTypeId
LEFT  JOIN masterdata.Branches b      ON b.Id = s.BranchId
WHERE LEN(CAST(s.NextNumber AS NVARCHAR(10))) > dt.NumberLength;

PRINT 'Script 78 applied: containers - any number per plan, no 9829 on long container lists, numbers never cut.';
GO
