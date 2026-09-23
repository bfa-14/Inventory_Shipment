/* ================================================================== 9. Containers: save, confirm, events */

CREATE   PROCEDURE logistics.usp_Container_Save
    @Id                  INT            = NULL,   -- NULL = create (ContainerRef assigned now)
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
    @DispatchDate        DATE           = NULL,
    @Eta                 DATE           = NULL,
    @FreeDays            INT            = NULL,
    @GrossWeightKg       DECIMAL(18,3)  = NULL,
    @VolumeCbm           DECIMAL(18,3)  = NULL,
    @Packages            INT            = NULL,
    @BlNo                NVARCHAR(30)   = NULL,
    @BlDate              DATE           = NULL,
    @BlNotes             NVARCHAR(500)  = NULL,
    @MaxUnits            INT            = NULL,   -- NULL = the container type's capacity
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
    @Invoices            logistics.tvp_ContainerInvoice READONLY,
    @Lines               logistics.tvp_ContainerLine READONLY,
    @AllowOverCapacity   BIT            = 0,
    @RowVersion          BINARY(8)      = NULL,
    @UserId              INT            = NULL,
    @NewId               INT OUTPUT
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

    IF @OrderDate IS NULL THROW 69000, 'Order date is required.', 1;
    IF @ShippingMethod NOT IN (N'Sea', N'Air', N'Road') THROW 69000, 'Shipping method must be Sea, Air or Road.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.ContainerTypes WHERE Id = @ContainerTypeId AND IsActive = 1)
        THROW 69000, 'Container type not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 69000, 'Branch not found or inactive.', 1;
    IF @WarehouseId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1)
        THROW 69000, 'Offloading warehouse not found or inactive.', 1;
    IF @FreeDays IS NOT NULL AND @FreeDays < 0 THROW 69000, 'Free days cannot be negative.', 1;
    IF @MaxUnits IS NOT NULL AND @MaxUnits <= 0 THROW 69000, 'Maximum units must be greater than zero.', 1;
    IF @DispatchDate IS NOT NULL AND @Eta IS NOT NULL AND @Eta < @DispatchDate
        THROW 69000, 'The ETA cannot be earlier than the dispatch date.', 1;
    IF @ContainerNo IS NOT NULL AND EXISTS (SELECT 1 FROM logistics.Containers
                                            WHERE ContainerNo = @ContainerNo AND Status < 7 AND (@Id IS NULL OR Id <> @Id))
        THROW 69013, 'Another open container already uses this container number.', 1;

    DECLARE @Status TINYINT = NULL;
    IF @Id IS NOT NULL
    BEGIN
        SELECT @Status = Status FROM logistics.Containers WHERE Id = @Id;
        IF @Status IS NULL THROW 69006, 'Container not found.', 1;
        IF @Status >= 6 THROW 69005, 'An offloaded, closed or cancelled container can no longer be changed.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 69004, 'This container was modified by another user. Reload the page and try again.', 1;
    END

    -- Invoices: every line's invoice is linked, even when the caller forgot it.
    DECLARE @Inv TABLE (PurchaseDocumentId INT PRIMARY KEY);
    INSERT INTO @Inv (PurchaseDocumentId) SELECT PurchaseDocumentId FROM @Invoices;
    INSERT INTO @Inv (PurchaseDocumentId)
    SELECT DISTINCT pl.DocumentId FROM @Lines l
    INNER JOIN purchase.PurchaseDocumentLines pl ON pl.Id = l.PurchaseLineId
    WHERE pl.DocumentId NOT IN (SELECT PurchaseDocumentId FROM @Inv);

    DECLARE @Msg NVARCHAR(400);

    SELECT TOP (1) @Msg =
        CASE WHEN d.Id IS NULL THEN N'A purchase invoice of the container no longer exists.'
             WHEN dt.Code <> N'PINV' THEN N'Document ' + d.DocumentNumber + N' is not a purchase invoice.'
             WHEN d.Status = 3 THEN N'Invoice ' + d.DocumentNumber + N' is cancelled.'
             WHEN d.Status = 2 AND d.ReceiptMode = 1 THEN N'Invoice ' + d.DocumentNumber + N' was already received into stock when it was posted, so it cannot be loaded into a container.'
             END
    FROM @Inv v
    LEFT JOIN purchase.PurchaseDocuments d ON d.Id = v.PurchaseDocumentId
    LEFT JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId
    WHERE d.Id IS NULL OR dt.Code <> N'PINV' OR d.Status = 3 OR (d.Status = 2 AND d.ReceiptMode = 1);
    IF @Msg IS NOT NULL THROW 69012, @Msg, 1;

    -- Lines: quantity, ownership and the quantity still available on the invoice line.
    SELECT TOP (1) @Msg =
        CASE WHEN pl.Id IS NULL THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': the invoice line no longer exists.'
             WHEN l.Quantity <= 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': the quantity must be greater than zero.'
             WHEN pl.DocumentId NOT IN (SELECT PurchaseDocumentId FROM @Inv)
                  THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': the invoice of this line is not linked to the container.'
             WHEN l.OilQtyPerUnit < 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': the oil quantity cannot be negative.'
             END
    FROM @Lines l
    LEFT JOIN purchase.PurchaseDocumentLines pl ON pl.Id = l.PurchaseLineId
    WHERE pl.Id IS NULL OR l.Quantity <= 0 OR l.OilQtyPerUnit < 0 OR pl.DocumentId NOT IN (SELECT PurchaseDocumentId FROM @Inv)
    ORDER BY l.LineNumber;
    IF @Msg IS NOT NULL THROW 69000, @Msg, 1;

    IF EXISTS (SELECT PurchaseLineId FROM @Lines GROUP BY PurchaseLineId HAVING COUNT(*) > 1)
        THROW 69000, 'The same invoice line appears twice in the container.', 1;

    SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - '
                          + CAST(l.Quantity * pl.PackingFormula AS NVARCHAR(20)) + N' base units allocated but only '
                          + CAST(pl.QuantityBase - ISNULL(o.Qty, 0) AS NVARCHAR(20)) + N' remain on invoice line '
                          + CAST(pl.LineNumber AS NVARCHAR(10)) + N' of ' + d.DocumentNumber + N'.'
    FROM @Lines l
    INNER JOIN purchase.PurchaseDocumentLines pl ON pl.Id = l.PurchaseLineId
    INNER JOIN purchase.PurchaseDocuments d      ON d.Id = pl.DocumentId
    INNER JOIN inventory.Items i                 ON i.Id = pl.ItemId
    OUTER APPLY (SELECT Qty = SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                 INNER JOIN logistics.Containers c2 ON c2.Id = cl.ContainerId
                 WHERE cl.PurchaseLineId = l.PurchaseLineId AND c2.Status <> 8 AND (@Id IS NULL OR cl.ContainerId <> @Id)) o
    WHERE l.Quantity * pl.PackingFormula > pl.QuantityBase - ISNULL(o.Qty, 0)
    ORDER BY l.LineNumber;
    IF @Msg IS NOT NULL THROW 69008, @Msg, 1;

    -- Capacity: a warning that the caller can override, never a hard block.
    DECLARE @Capacity INT = @MaxUnits;
    IF @Capacity IS NULL AND @Id IS NOT NULL SELECT @Capacity = MaxUnits FROM logistics.Containers WHERE Id = @Id;
    IF @Capacity IS NULL SELECT @Capacity = MaxUnits FROM masterdata.ContainerTypes WHERE Id = @ContainerTypeId;

    DECLARE @Allocated INT = ISNULL((SELECT SUM(l.Quantity * pl.PackingFormula) FROM @Lines l
                                     INNER JOIN purchase.PurchaseDocumentLines pl ON pl.Id = l.PurchaseLineId), 0);
    IF @Capacity IS NOT NULL AND @Allocated > @Capacity AND ISNULL(@AllowOverCapacity, 0) = 0
    BEGIN
        SET @Msg = N'The container holds ' + CAST(@Capacity AS NVARCHAR(10)) + N' units and ' + CAST(@Allocated AS NVARCHAR(10))
                 + N' are allocated. Confirm to load it above its capacity.';
        THROW 69007, @Msg, 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Id IS NULL
        BEGIN
            DECLARE @Ref NVARCHAR(30), @TypeId INT = (SELECT Id FROM inventory.DocumentTypes WHERE Code = N'CNT');
            EXEC inventory.usp_DocumentType_NextNumber N'CNT', @Ref OUTPUT, @BranchId;

            INSERT INTO logistics.Containers (DocumentTypeId, ContainerRef, ContainerNo, ContainerTypeId, SealNo, CustomsSealNo, Description,
                                              OrderDate, ShippingMethod, CountryOfOrigin, ForwarderId, TransporterId,
                                              ShippingLine, VesselName, VoyageNo, BookingNo, PortOfLoadingId, PortOfDestinationId, FinalDestinationId,
                                              DispatchDate, Eta, FreeDays, GrossWeightKg, VolumeCbm, Packages, BlNo, BlDate, BlNotes,
                                              MaxUnits, BranchId, WarehouseId, TruckNo, WaybillNo, DeclarationNo, FeriNo,
                                              ActualPortArrival, BorderCrossingDate, CustomsReleaseDate, StatusNote, Notes, Status, CreatedBy)
            VALUES (@TypeId, @Ref, @ContainerNo, @ContainerTypeId, @SealNo, @CustomsSealNo, @Description,
                    @OrderDate, @ShippingMethod, @CountryOfOrigin, @ForwarderId, @TransporterId,
                    @ShippingLine, @VesselName, @VoyageNo, @BookingNo, @PortOfLoadingId, @PortOfDestinationId, @FinalDestinationId,
                    @DispatchDate, @Eta, @FreeDays, @GrossWeightKg, @VolumeCbm, @Packages, @BlNo, @BlDate, @BlNotes,
                    @Capacity, @BranchId, @WarehouseId, @TruckNo, @WaybillNo, @DeclarationNo, @FeriNo,
                    @ActualPortArrival, @BorderCrossingDate, @CustomsReleaseDate, @StatusNote, @Notes, 1, @UserId);
            SET @Id = SCOPE_IDENTITY();
            INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId) VALUES (@Id, N'Created', N'Draft ' + @Ref, @UserId);
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
                MaxUnits = @Capacity, BranchId = @BranchId, WarehouseId = @WarehouseId, TruckNo = @TruckNo, WaybillNo = @WaybillNo,
                DeclarationNo = @DeclarationNo, FeriNo = @FeriNo, ActualPortArrival = @ActualPortArrival,
                BorderCrossingDate = @BorderCrossingDate, CustomsReleaseDate = @CustomsReleaseDate, StatusNote = @StatusNote, Notes = @Notes,
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;
            INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
            VALUES (@Id, N'Updated', N'Header and ' + CAST((SELECT COUNT(*) FROM @Lines) AS NVARCHAR(10)) + N' line(s) saved', @UserId);
        END

        DELETE FROM logistics.ContainerLines WHERE ContainerId = @Id;
        DELETE FROM logistics.ContainerInvoices WHERE ContainerId = @Id AND PurchaseDocumentId NOT IN (SELECT PurchaseDocumentId FROM @Inv);
        INSERT INTO logistics.ContainerInvoices (ContainerId, PurchaseDocumentId)
        SELECT @Id, v.PurchaseDocumentId FROM @Inv v
        WHERE NOT EXISTS (SELECT 1 FROM logistics.ContainerInvoices ci WHERE ci.ContainerId = @Id AND ci.PurchaseDocumentId = v.PurchaseDocumentId);

        INSERT INTO logistics.ContainerLines (ContainerId, LineNumber, PurchaseDocumentId, PurchaseLineId, ItemId, ItemUnitId,
                                              PackingFormula, Quantity, OilIncluded, OilQtyPerUnit, Notes)
        SELECT @Id, l.LineNumber, pl.DocumentId, l.PurchaseLineId, pl.ItemId, pl.ItemUnitId,
               pl.PackingFormula, l.Quantity, ISNULL(l.OilIncluded, 0),
               CASE WHEN ISNULL(l.OilIncluded, 0) = 1 THEN ISNULL(l.OilQtyPerUnit, i.OilQtyPerUnit) END,
               NULLIF(LTRIM(RTRIM(l.Notes)), N'')
        FROM @Lines l
        INNER JOIN purchase.PurchaseDocumentLines pl ON pl.Id = l.PurchaseLineId
        INNER JOIN inventory.Items i ON i.Id = pl.ItemId;

        -- Draft invoices loaded into a container are received at offload from now on.
        UPDATE d SET ReceiptMode = 2, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        FROM purchase.PurchaseDocuments d
        INNER JOIN @Inv v ON v.PurchaseDocumentId = d.Id
        WHERE d.ReceiptMode = 1;

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

