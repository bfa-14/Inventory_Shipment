SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 104: LOGISTICS - A CONTAINER NO. OF UP TO 30 CHARACTERS

   A container no. held at most 20 characters, enough for one box (4 letters + 7 digits, MSKU1234567). The owner keeps
   a container that travelled as two boxes under one ref with both numbers, comma delimited: "MRSU8190808 , CAAU9368456"
   (25 characters), the way the purchasing sheet writes it. The limit becomes 30 everywhere the number is kept or passed:

     1. logistics.Containers.ContainerNo NVARCHAR(30); its unique index of the open containers (UX_Containers_ContainerNo)
        and the statistics on the column re-created around the change.
     2. logistics.tvp_ContainerNumber.ContainerNo NVARCHAR(30) (bulk "Container numbers..."): the type is re-created, its
        one user usp_Container_SetNumbers dropped first and re-created after with its table variable at 30.
     3. usp_Container_Save (@ContainerNo), usp_Container_Search (@ContainerNo) and usp_Container_NextStepPreview (its
        #Ctr.ContainerNo) take 30.
     4. The functions and views that read the column are refreshed, so the ones returning it return 30.

   The number is still kept in capitals and unique among the open containers, compared as a whole ("MRSU8190808 ,
   CAAU9368456" is one value). No new permission, no new error number. Each procedure re-created from its current body
   (scripts 27, 28, 43, 53, 78, 81, 82, 95) plus only this change. Idempotent: the column and the type change once.
   ===================================================================================== */

IF OBJECT_ID(N'logistics.Containers', N'U') IS NULL OR TYPE_ID(N'logistics.tvp_ContainerNumber') IS NULL
    THROW 70000, 'Script 104 requires scripts 24 and 28: apply them first.', 1;
GO

/* ================================================================== 1. The column, its index and statistics */

IF COL_LENGTH(N'logistics.Containers', N'ContainerNo') < 60
BEGIN
    IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'logistics.Containers') AND name = N'UX_Containers_ContainerNo')
        DROP INDEX UX_Containers_ContainerNo ON logistics.Containers;

    -- Statistics on the column (made by the server or by hand) would stop the ALTER COLUMN.
    DECLARE @Sql NVARCHAR(MAX) = (
        SELECT STRING_AGG(CAST(N'DROP STATISTICS logistics.Containers.' + QUOTENAME(st.name) AS NVARCHAR(MAX)), N'; ')
        FROM sys.stats st
        JOIN sys.stats_columns sc ON sc.object_id = st.object_id AND sc.stats_id = st.stats_id
        JOIN sys.columns c ON c.object_id = sc.object_id AND c.column_id = sc.column_id
        WHERE st.object_id = OBJECT_ID(N'logistics.Containers') AND c.name = N'ContainerNo'
          AND NOT EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = st.object_id AND i.index_id = st.stats_id));
    IF @Sql IS NOT NULL EXEC sys.sp_executesql @Sql;

    ALTER TABLE logistics.Containers ALTER COLUMN ContainerNo NVARCHAR(30) NULL;
    PRINT 'logistics.Containers.ContainerNo is now NVARCHAR(30).';
END
GO

-- The same box number comes back years later: unique only while the container is still open.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'logistics.Containers') AND name = N'UX_Containers_ContainerNo')
    CREATE UNIQUE NONCLUSTERED INDEX UX_Containers_ContainerNo ON logistics.Containers (ContainerNo)
        WHERE ContainerNo IS NOT NULL AND Status < 7;
GO

/* ================================================================== 2. tvp_ContainerNumber at 30 */

IF EXISTS (SELECT 1 FROM sys.table_types tt JOIN sys.columns c ON c.object_id = tt.type_table_object_id
           WHERE tt.user_type_id = TYPE_ID(N'logistics.tvp_ContainerNumber') AND c.name = N'ContainerNo' AND c.max_length < 60)
BEGIN
    -- A table type cannot be altered: its procedures go first, then it is made again.
    IF OBJECT_ID(N'logistics.usp_Container_SetNumbers', N'P') IS NOT NULL DROP PROCEDURE logistics.usp_Container_SetNumbers;
    DROP TYPE logistics.tvp_ContainerNumber;
    CREATE TYPE logistics.tvp_ContainerNumber AS TABLE
    (
        ContainerId INT          NOT NULL PRIMARY KEY,
        ContainerNo NVARCHAR(30) NULL,        -- empty = none
        SealNo      NVARCHAR(30) NULL
    );
    PRINT 'Re-created type logistics.tvp_ContainerNumber (ContainerNo NVARCHAR(30)).';
END
GO

/* ================================================================== 3. The procedures, from their current bodies */

CREATE OR ALTER PROCEDURE logistics.usp_Container_SetNumbers
    @Items  logistics.tvp_ContainerNumber READONLY,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @N TABLE (ContainerId INT NOT NULL PRIMARY KEY, ContainerNo NVARCHAR(30) NULL, SealNo NVARCHAR(30) NULL,
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

CREATE OR ALTER PROCEDURE logistics.usp_Container_Save
    @Id                  INT            = NULL,   -- NULL = create (ContainerRef assigned now)
    @PurchaseOrderId     INT            = NULL,   -- required on create: the order the container is created from
    @ContainerNo         NVARCHAR(30)   = NULL,
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
    @PlanChecked         BIT            = 0,      -- (78) 1 = the caller checked the whole plan (invoice rules, order lines' room)
    @ContainerRef        NVARCHAR(30)   = NULL    -- (78) on create: this ref instead of the next CNT number
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
    -- for each container of a plan: usp_Container_CreateBatch checks them once for the whole plan (@PlanChecked),
    -- and checking each container against an invoice state that grows with every container made it quadratic - 2,205
    -- containers from one invoice took 42 s, most of it here.
    IF @ForInvoiceId IS NOT NULL AND @Id IS NULL AND ISNULL(@PlanChecked, 0) = 0
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

        DECLARE @Msg NVARCHAR(400), @IsNew BIT = 0;

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
        -- (78) Not for a container of a plan: CreateBatch checked the whole plan under a lock on the order (@PlanChecked).
        IF ISNULL(@PlanChecked, 0) = 0
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
            DECLARE @Ref NVARCHAR(30) = NULLIF(LTRIM(RTRIM(@ContainerRef)), N''), @TypeId INT = (SELECT Id FROM inventory.DocumentTypes WHERE Code = N'CNT');
            IF @Ref IS NULL EXEC inventory.usp_DocumentType_NextNumber N'CNT', @Ref OUTPUT, @BranchId;

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
            SET @IsNew = 1;
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

        -- (78) Only on a container that already had lines: on a new one there is nothing to update, and the join read
        -- every container line of the order line (one more for each container of a plan).
        IF @IsNew = 0
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

CREATE OR ALTER PROCEDURE logistics.usp_Container_Search
    @Search              NVARCHAR(100) = NULL,   -- ref, container no., B/L, vessel, PO / PI no., commercial invoice, supplier
    @ContainerRef        NVARCHAR(30)  = NULL,
    @ContainerNo         NVARCHAR(30)  = NULL,
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

CREATE OR ALTER PROCEDURE logistics.usp_Container_NextStepPreview
    @ContainerIds logistics.tvp_IdList READONLY,
    @CanConfirm   BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET @CanConfirm = ISNULL(@CanConfirm, 1);

    -- A PROPOSAL MISSING IS NOT A BLOCK: when the usual type of the next stage is inactive the container still moves on,
    -- its type to choose ("Choose the type"). It cannot move on only when no movement type is active at all.
    DECLARE @AnyActiveType BIT = CASE WHEN EXISTS (SELECT 1 FROM masterdata.MovementTypes WHERE IsActive = 1 AND Stage <> N'Origin')
                                      THEN 1 ELSE 0 END;

    -- 1. the step of each container (the reads of fn_Container_NextStep, without its suggestion)
    CREATE TABLE #Step
    (
        ContainerId INT NOT NULL PRIMARY KEY, Found BIT NOT NULL, ContainerRef NVARCHAR(30) NULL, ContainerNo NVARCHAR(30) NULL,
        Status TINYINT NULL, Kind NVARCHAR(12) NULL, BlockedReason NVARCHAR(400) NULL,
        MovementCount INT NULL, PlaceId INT NULL, PlaceName NVARCHAR(100) NULL, PlaceKind NVARCHAR(10) NULL, PlaceSince DATE NULL,
        LastStage NVARCHAR(10) NULL, LastMovementId INT NULL, LastMovementNo NVARCHAR(30) NULL, LastMovementEndDate DATE NULL,
        MovementId INT NULL, PlannedNotBefore DATE NULL,
        ActiveMovementId INT NULL, PlannedMovementId INT NULL, LastDeliveryMovementId INT NULL,
        GoodsReceiptId INT NULL, GoodsReceiptNumber NVARCHAR(30) NULL, GoodsReceiptStatus TINYINT NULL,
        HistPlaceId INT NULL, HistStage NVARCHAR(10) NULL      -- the (place, last stage) of its suggestion
    );

    INSERT INTO #Step (ContainerId, Found, ContainerRef, ContainerNo, Status, Kind, BlockedReason, MovementCount, PlaceId, PlaceName,
                       PlaceKind, PlaceSince, LastStage, LastMovementId, LastMovementNo, LastMovementEndDate, MovementId,
                       PlannedNotBefore, ActiveMovementId, PlannedMovementId, LastDeliveryMovementId,
                       GoodsReceiptId, GoodsReceiptNumber, GoodsReceiptStatus, HistPlaceId, HistStage)
    SELECT x.Id, CASE WHEN c.Id IS NULL THEN 0 ELSE 1 END, c.ContainerRef, c.ContainerNo, c.Status, k.Kind, k.BlockedReason,
           ss.MovementCount, ss.PlaceId, ss.PlaceName, pk.Kind, ss.PlaceSince, ls.Stage, ss.LastMovementId, ss.LastMovementNo,
           ss.LastMovementEndDate,
           CASE k.Kind WHEN N'Complete' THEN ss.ActiveMovementId WHEN N'StartPlanned' THEN ss.PlannedMovementId END,
           NULL, ss.ActiveMovementId, ss.PlannedMovementId, dl.MovementId,
           rb.GoodsReceiptId, rb.GoodsReceiptNumber, rb.GoodsReceiptStatus,
           CASE WHEN k.Kind IN (N'Ship', N'NextLeg') THEN ss.PlaceId END,
           CASE WHEN k.Kind = N'NextLeg' THEN ls.Stage END
    FROM @ContainerIds x
    LEFT JOIN logistics.Containers c ON c.Id = x.Id
    OUTER APPLY logistics.fn_Container_ShipState(c.Id) ss
    OUTER APPLY logistics.fn_Container_ReceivedBy(c.Id) rb
    OUTER APPLY logistics.fn_Container_LastDelivery(c.Id) dl
    OUTER APPLY logistics.fn_Container_NextStepKind(c.Id, c.Status, ss.MovementCount, ss.ActiveMovementId, ss.PlannedMovementId,
                                                    NULL, ss.LastMovementId, dl.MovementId, rb.GoodsReceiptStatus) k
    LEFT JOIN masterdata.Ports pk ON pk.Id = ss.PlaceId
    OUTER APPLY (SELECT lt.Stage
                 FROM logistics.Movements lm
                 INNER JOIN masterdata.MovementTypes lt ON lt.Id = lm.MovementTypeId
                 WHERE lm.Id = ss.LastMovementId) ls;

    -- the movement each step concerns (Complete, StartPlanned), once per movement
    SELECT m.Id, m.MovementNo, m.RowVersion, m.Status, m.MovementTypeId, mt.TypeCode, mt.TypeName, mt.Stage,
           m.FromPlaceId, FromName = fp.PortName, m.ToPlaceId, ToName = tp.PortName, m.PlannedDate, m.StartDate, m.Eta,
           Cnt = (SELECT COUNT(*) FROM logistics.MovementContainers x WHERE x.MovementId = m.Id)
    INTO #Mov
    FROM logistics.Movements m
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    INNER JOIN masterdata.Ports fp         ON fp.Id = m.FromPlaceId
    INNER JOIN masterdata.Ports tp         ON tp.Id = m.ToPlaceId
    WHERE m.Id IN (SELECT MovementId FROM #Step WHERE MovementId IS NOT NULL);

    -- why a planned movement cannot start yet, once per movement (read through each container it cost seconds), and
    -- the step's refusal with it (fn_Container_NextStepKind: a draft, or the movement's own refusal)
    SELECT b.MovementId, b.Reason, b.StartNotBefore
    INTO #Sb
    FROM (SELECT DISTINCT MovementId FROM #Step WHERE Kind = N'StartPlanned') p
    CROSS APPLY logistics.fn_Movement_StartBlock(p.MovementId) b;

    UPDATE s
    SET PlannedNotBefore = b.StartNotBefore,
        BlockedReason = k.BlockedReason
    FROM #Step s
    INNER JOIN #Sb b ON b.MovementId = s.MovementId
    CROSS APPLY logistics.fn_Container_NextStepKind(s.ContainerId, s.Status, s.MovementCount, s.ActiveMovementId,
                                                    s.PlannedMovementId, b.Reason, s.LastMovementId, s.LastDeliveryMovementId,
                                                    s.GoodsReceiptStatus) k
    WHERE s.Kind = N'StartPlanned';

    -- 2. THE SUGGESTION, ONCE PER (place, last stage): the next leg of a container from where it is, and the leg after a
    -- movement to complete from that movement's To (the "Then" box)
    SELECT g.PlaceId, g.LastStage, h.MovementTypeId, h.ToPlaceId, h.Legs
    INTO #Hist
    FROM (SELECT DISTINCT PlaceId = HistPlaceId, LastStage = HistStage FROM #Step WHERE HistPlaceId IS NOT NULL
          UNION
          SELECT DISTINCT mv.ToPlaceId, mv.Stage
          FROM #Step s INNER JOIN #Mov mv ON mv.Id = s.MovementId
          WHERE s.Kind = N'Complete' AND mv.Stage <> N'Delivery') g
    CROSS APPLY logistics.fn_Movement_NextLegHistory(g.PlaceId, g.LastStage) h;

    -- 3. every container with its proposal, its group and why it cannot move on
    SELECT s.ContainerId, s.Found, s.ContainerRef, s.ContainerNo, s.Status, s.Kind, s.BlockedReason,
           IsDraft = CAST(CASE WHEN s.Status = 1 THEN 1 ELSE 0 END AS BIT),
           HasContainerNo = CAST(CASE WHEN NULLIF(LTRIM(RTRIM(s.ContainerNo)), N'') IS NULL THEN 0 ELSE 1 END AS BIT),
           HasTypedDates = CAST(CASE WHEN s.MovementCount = 0 AND (c.DispatchDate IS NOT NULL OR c.ActualPortArrival IS NOT NULL
                                                                    OR c.BorderCrossingDate IS NOT NULL OR c.CustomsReleaseDate IS NOT NULL)
                                     THEN 1 ELSE 0 END AS BIT),
           s.MovementCount, s.PlaceId, s.PlaceName, s.PlaceKind, s.PlaceSince,
           s.LastStage, s.LastMovementId, s.LastMovementNo, s.LastMovementEndDate,
           MovementId = mv.Id, MovementNo = mv.MovementNo, MovementRowVersion = mv.RowVersion, MovementStatus = mv.Status,
           MovementTypeId = mv.MovementTypeId, MovementTypeCode = mv.TypeCode, MovementTypeName = mv.TypeName,
           MovementStage = mv.Stage, MovementFromPlaceId = mv.FromPlaceId, MovementFromName = mv.FromName,
           MovementToPlaceId = mv.ToPlaceId, MovementToName = mv.ToName,
           MovementPlannedDate = mv.PlannedDate, MovementStartDate = mv.StartDate, MovementEta = mv.Eta,
           MovementContainerCount = mv.Cnt,
           MovementNotBefore = CASE s.Kind WHEN N'Complete' THEN mv.StartDate WHEN N'StartPlanned' THEN s.PlannedNotBefore END,
           s.GoodsReceiptId, s.GoodsReceiptNumber, s.GoodsReceiptStatus,
           ProposedTypeId = pr.TypeId, ProposedTypeCode = pr.TypeCode, ProposedTypeName = pr.TypeName, ProposedStage = pr.Stage,
           ProposedFromPlaceId = pr.FromPlaceId, ProposedFromName = pr.FromName,
           ProposedToPlaceId = pr.ToPlaceId, ProposedToName = pr.ToName,
           ProposalSource = pr.Source, ProposalLegs = pr.Legs, ProposedIsStay = pr.IsStay,
           ProposedOnePerContainer = pr.OnePerContainer,
           ThenTypeId = tn.TypeId, ThenTypeCode = tn.TypeCode, ThenTypeName = tn.TypeName, ThenStage = tn.Stage,
           ThenFromPlaceId = tn.FromPlaceId, ThenFromName = tn.FromName, ThenToPlaceId = tn.ToPlaceId, ThenToName = tn.ToName,
           ThenSource = tn.Source, ThenLegs = tn.Legs, ThenIsStay = tn.IsStay,
           ThenDefault = CAST(CASE WHEN tn.TypeId IS NOT NULL AND (tn.IsStay = 1 OR mv.Stage IN (N'Customs', N'Border'))
                                   THEN 1 ELSE 0 END AS BIT),
           -- the shipping details a new leg starts from (Sea: vessel, voyage, B/L; a truck leg: the truck)
           c.VesselName, c.VoyageNo, c.ShippingLine, c.BlNo, c.BlDate, c.TruckNo, ContainerEta = c.Eta,
           OrderNumbers = CASE WHEN ISNULL(po.OrderCount, 0) = 0 THEN NULL
                               WHEN po.OrderCount = 1 THEN po.FirstOrder
                               ELSE po.FirstOrder + N' +' + CAST(po.OrderCount - 1 AS NVARCHAR(10)) END,
           SupplierNames = CASE WHEN ISNULL(po.SupplierCount, 0) = 0 THEN NULL
                                WHEN po.SupplierCount = 1 THEN po.FirstSupplier
                                ELSE po.FirstSupplier + N' +' + CAST(po.SupplierCount - 1 AS NVARCHAR(10)) END,
           b.BlockGroup,
           CanMove = CAST(CASE WHEN b.BlockGroup IS NULL THEN 1 ELSE 0 END AS BIT),
           -- (step, movement, type, From, To): containers at different places or bound elsewhere fall apart by themselves
           GroupKey = CASE WHEN b.BlockGroup IS NULL
                           THEN CONCAT(s.Kind, N'|', mv.Id, N'|', COALESCE(mv.MovementTypeId, pr.TypeId), N'|',
                                       COALESCE(mv.FromPlaceId, pr.FromPlaceId), N'|', COALESCE(mv.ToPlaceId, pr.ToPlaceId)) END,
           -- (82) only part of its movement arrived: can it be split off the movement in progress, and why not
           CanSplitOff = CAST(CASE WHEN s.Kind = N'Complete' AND sp.Reason IS NULL THEN 1 ELSE 0 END AS BIT),
           SplitOffBlockedReason = sp.Reason
    INTO #Row
    FROM #Step s
    LEFT JOIN logistics.Containers c ON c.Id = s.ContainerId
    LEFT JOIN #Mov mv                ON mv.Id = s.MovementId
    LEFT JOIN #Hist h                ON s.Kind IN (N'Ship', N'NextLeg') AND h.PlaceId = s.HistPlaceId
                                    AND ISNULL(h.LastStage, N'') = ISNULL(s.HistStage, N'')
    LEFT JOIN #Hist th               ON s.Kind = N'Complete' AND s.PlannedMovementId IS NULL
                                    AND th.PlaceId = mv.ToPlaceId AND th.LastStage = mv.Stage
    OUTER APPLY (SELECT p.*
                 FROM logistics.fn_Container_NextLegProposal(s.ContainerId, s.PlaceId,
                                                             CASE WHEN s.MovementCount = 0 THEN NULL ELSE s.LastStage END,
                                                             CASE WHEN s.Status = 5 THEN 1 ELSE 0 END,
                                                             h.MovementTypeId, h.ToPlaceId, h.Legs) p
                 WHERE s.Kind IN (N'Ship', N'NextLeg')) pr
    OUTER APPLY (SELECT p.*
                 FROM logistics.fn_Container_NextLegProposal(s.ContainerId, mv.ToPlaceId, mv.Stage,
                                                             CASE WHEN s.Status = 5 OR mv.Stage = N'Customs' THEN 1 ELSE 0 END,
                                                             th.MovementTypeId, th.ToPlaceId, th.Legs) p
                 -- no "Then" when its next leg is already planned (fn_Container_NextStep)
                 WHERE s.Kind = N'Complete' AND s.PlannedMovementId IS NULL) tn
    OUTER APPLY (SELECT OrderCount = COUNT(DISTINCT cl.PurchaseOrderId), SupplierCount = COUNT(DISTINCT d.SupplierId),
                        FirstOrder = MIN(d.DocumentNumber), FirstSupplier = MIN(sp.PartyName)
                 FROM logistics.ContainerLines cl
                 INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                 INNER JOIN masterdata.Parties sp        ON sp.Id = d.SupplierId
                 WHERE cl.ContainerId = s.ContainerId) po
    -- (82) why it cannot be split off its movement (fn_Movement_SplitBlock), for a movement to complete only
    OUTER APPLY (SELECT x.Reason
                 FROM logistics.fn_Movement_SplitBlock(mv.Id, mv.MovementNo, mv.Status, mv.Cnt, s.ContainerId, s.ContainerRef) x
                 WHERE s.Kind = N'Complete') sp
    CROSS APPLY (SELECT BlockGroup = CAST(CASE
                     WHEN s.Found = 0 THEN N'Not found'
                     WHEN s.Kind = N'Done' THEN N'Received, closed or cancelled'
                     -- a draft goods receipt waits: it is opened, not made again (Receive goods... refuses it, 63013)
                     WHEN s.Kind = N'OpenReceipt'
                         THEN N'A draft goods receipt waits: Open goods receipt (draft)'
                     WHEN s.Kind = N'Receive'
                         THEN N'Delivered: its goods are received next (Receive goods' + NCHAR(8230) + N')'
                     WHEN s.Kind = N'Ship' AND s.Status = 1 AND @CanConfirm = 0 THEN N'Draft - you may not confirm containers'
                     WHEN s.Kind IN (N'Ship', N'NextLeg') AND s.PlaceId IS NULL
                         THEN N'No port of loading: open the container to choose where it leaves from'
                     WHEN s.Kind IN (N'Ship', N'NextLeg') AND @AnyActiveType = 0
                         THEN N'No movement type is active: activate one in Master Data ' + NCHAR(8250) + N' Movement Types'
                     ELSE s.BlockedReason END AS NVARCHAR(400))) b;

    SELECT * FROM #Row ORDER BY CanMove DESC, GroupKey, LEN(ContainerRef), ContainerRef, ContainerId;

    -- 4. the groups (set 2), with the orders and suppliers of each, for information
    SELECT g.GroupKey, OrderCount = COUNT(DISTINCT cl.PurchaseOrderId), SupplierCount = COUNT(DISTINCT d.SupplierId),
           FirstOrder = MIN(d.DocumentNumber), FirstSupplier = MIN(sp.PartyName)
    INTO #GroupOrders
    FROM #Row g
    INNER JOIN logistics.ContainerLines cl  ON cl.ContainerId = g.ContainerId
    INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
    INNER JOIN masterdata.Parties sp        ON sp.Id = d.SupplierId
    WHERE g.CanMove = 1
    GROUP BY g.GroupKey;

    SELECT r.GroupKey, Kind = MIN(r.Kind),
           MovementId = MIN(r.MovementId), MovementNo = MIN(r.MovementNo), MovementRowVersion = MAX(r.MovementRowVersion),
           MovementTypeId = MIN(COALESCE(r.MovementTypeId, r.ProposedTypeId)),
           MovementTypeCode = MIN(COALESCE(r.MovementTypeCode, r.ProposedTypeCode)),
           MovementTypeName = MIN(COALESCE(r.MovementTypeName, r.ProposedTypeName)),
           MovementStage = MIN(COALESCE(r.MovementStage, r.ProposedStage)),
           FromPlaceId = MIN(COALESCE(r.MovementFromPlaceId, r.ProposedFromPlaceId)),
           FromName = MIN(COALESCE(r.MovementFromName, r.ProposedFromName)),
           ToPlaceId = MIN(COALESCE(r.MovementToPlaceId, r.ProposedToPlaceId)),
           ToName = MIN(COALESCE(r.MovementToName, r.ProposedToName)),
           IsNewLeg = CAST(MAX(CASE WHEN r.Kind IN (N'Ship', N'NextLeg') THEN 1 ELSE 0 END) AS BIT),
           IsStay = CAST(MAX(CASE WHEN COALESCE(r.MovementStage, r.ProposedStage) IN (N'Port', N'Customs', N'Border') THEN 1 ELSE 0 END) AS BIT),
           MovementStartDate = MIN(r.MovementStartDate), MovementPlannedDate = MIN(r.MovementPlannedDate), MovementEta = MIN(r.MovementEta),
           Containers = COUNT(*), MovementContainerCount = MAX(r.MovementContainerCount),
           -- the earliest date of the step for every container of the group: a new leg leaves once the last one arrived
           NotBefore = MAX(CASE WHEN r.Kind IN (N'Ship', N'NextLeg') THEN r.PlaceSince ELSE r.MovementNotBefore END),
           PlaceName = MIN(r.PlaceName),
           ProposalSource = MIN(r.ProposalSource), ProposalLegs = MAX(r.ProposalLegs),
           OnePerContainer = CAST(MAX(CAST(ISNULL(r.ProposedOnePerContainer, 0) AS INT)) AS BIT),
           Drafts = SUM(CAST(r.IsDraft AS INT)), WithoutContainerNo = SUM(1 - CAST(r.HasContainerNo AS INT)),
           WithTypedDates = SUM(CAST(r.HasTypedDates AS INT)),
           OrderCount = MAX(o.OrderCount), SupplierCount = MAX(o.SupplierCount),
           OrderNumbers = MAX(CASE WHEN o.OrderCount = 1 THEN o.FirstOrder
                                   WHEN o.OrderCount > 1 THEN o.FirstOrder + N' +' + CAST(o.OrderCount - 1 AS NVARCHAR(10)) END),
           SupplierNames = MAX(CASE WHEN o.SupplierCount = 1 THEN o.FirstSupplier
                                    WHEN o.SupplierCount > 1 THEN o.FirstSupplier + N' +' + CAST(o.SupplierCount - 1 AS NVARCHAR(10)) END),
           -- "Then": offered when the containers of the group get a next leg after it; its fields when they all get the same
           ThenContainers = SUM(CASE WHEN r.ThenTypeId IS NOT NULL THEN 1 ELSE 0 END),
           ThenSame = CAST(CASE WHEN COUNT(DISTINCT CONCAT(r.ThenTypeId, N'|', r.ThenToPlaceId)) = 1
                                 AND COUNT(r.ThenTypeId) = COUNT(*) THEN 1 ELSE 0 END AS BIT),
           ThenTypeId = MIN(r.ThenTypeId), ThenTypeName = MIN(r.ThenTypeName), ThenStage = MIN(r.ThenStage),
           ThenFromPlaceId = MIN(r.ThenFromPlaceId), ThenFromName = MIN(r.ThenFromName),
           ThenToPlaceId = MIN(r.ThenToPlaceId), ThenToName = MIN(r.ThenToName), ThenIsStay = CAST(MIN(CAST(r.ThenIsStay AS INT)) AS BIT),
           ThenSource = MIN(r.ThenSource), ThenLegs = MAX(r.ThenLegs),
           ThenDefault = CAST(MIN(CAST(r.ThenDefault AS INT)) AS BIT),
           -- (82) a Complete group of only part of its movement: the ticked ones can complete alone (they get their own
           -- movement), else why not - every container of the movement is ticked, or one of them has a later leg
           SplitPossible = CAST(CASE WHEN MIN(r.Kind) = N'Complete' AND COUNT(*) < MAX(r.MovementContainerCount)
                                          AND MIN(CAST(r.CanSplitOff AS INT)) = 1 THEN 1 ELSE 0 END AS BIT),
           SplitBlockedReason = CAST(CASE WHEN MIN(r.Kind) <> N'Complete' THEN NULL
                                          WHEN COUNT(*) >= MAX(r.MovementContainerCount)
                                              THEN N'Every container of ' + MIN(r.MovementNo) + N' is ticked: complete the movement itself.'
                                          ELSE MIN(r.SplitOffBlockedReason) END AS NVARCHAR(400))
    FROM #Row r
    LEFT JOIN #GroupOrders o ON o.GroupKey = r.GroupKey
    WHERE r.CanMove = 1
    GROUP BY r.GroupKey
    ORDER BY CASE MIN(r.Kind) WHEN N'Complete' THEN 1 WHEN N'StartPlanned' THEN 2 ELSE 3 END,
             MIN(COALESCE(r.MovementFromName, r.ProposedFromName)), r.GroupKey;

    -- 5. the containers that cannot move on, by reason (set 3)
    SELECT BlockGroup, Containers = COUNT(*),
           ContainerRefs = STRING_AGG(CAST(CASE WHEN rn <= 5 THEN ISNULL(ContainerRef, CAST(ContainerId AS NVARCHAR(12))) END AS NVARCHAR(MAX)), N', ')
                           WITHIN GROUP (ORDER BY rn)
    FROM (SELECT BlockGroup, ContainerRef, ContainerId,
                 rn = ROW_NUMBER() OVER (PARTITION BY BlockGroup ORDER BY LEN(ContainerRef), ContainerRef, ContainerId)
          FROM #Row WHERE CanMove = 0) z
    GROUP BY BlockGroup
    ORDER BY COUNT(*) DESC, BlockGroup;
END
GO

/* ================================================================== 4. Refresh what reads the column */

DECLARE @Name NVARCHAR(300);
DECLARE rf CURSOR LOCAL FAST_FORWARD FOR
    SELECT DISTINCT QUOTENAME(OBJECT_SCHEMA_NAME(d.referencing_id)) + N'.' + QUOTENAME(OBJECT_NAME(d.referencing_id))
    FROM sys.sql_expression_dependencies d
    JOIN sys.objects o ON o.object_id = d.referencing_id
    WHERE d.referenced_id = OBJECT_ID(N'logistics.Containers') AND o.type IN (N'V', N'IF', N'TF', N'FN')
      AND OBJECTPROPERTY(d.referencing_id, N'IsSchemaBound') = 0;
OPEN rf; FETCH NEXT FROM rf INTO @Name;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC sys.sp_refreshsqlmodule @Name;
    FETCH NEXT FROM rf INTO @Name;
END
CLOSE rf; DEALLOCATE rf;
GO

/* ================================================================== 5. Check */

SELECT N'logistics.Containers.ContainerNo' AS Name, COL_LENGTH(N'logistics.Containers', N'ContainerNo') / 2 AS Characters
UNION ALL
SELECT N'logistics.tvp_ContainerNumber.ContainerNo', c.max_length / 2
FROM sys.table_types tt JOIN sys.columns c ON c.object_id = tt.type_table_object_id
WHERE tt.user_type_id = TYPE_ID(N'logistics.tvp_ContainerNumber') AND c.name = N'ContainerNo'
UNION ALL
SELECT OBJECT_SCHEMA_NAME(p.object_id) + N'.' + OBJECT_NAME(p.object_id) + N' ' + p.name, p.max_length / 2
FROM sys.parameters p WHERE p.name = N'@ContainerNo';

PRINT 'Script 104 applied: a container no. of up to 30 characters ("MRSU8190808 , CAAU9368456").';
GO