/* =====================================================================================
   Inventory_Shipment - 51: CONTAINERS FROM A PURCHASE INVOICE - the rules in one place (prompt 44 A1)

   Bilal could not create containers from a purchase invoice. Prompt 41 (script 43) built the path - containers created
   on the invoice's order and linked to the invoice in one transaction - but its rules were spread over the API, the
   page and four procedures, and the page hid the buttons without saying why. This script puts the rules in ONE
   function, gives the page one state to read, and has every procedure of the path check the same rules first.

   The rules (an invoice takes containers when ALL hold; the first one that fails is the reason)
     1. A purchase invoice, draft or posted (not cancelled).
     2. Created from a purchase order: every line comes from the order (its containers are the order's).
     3. One item (script 45): an older DRAFT holding several items is split by item first. A posted invoice made
        before script 45 cannot be split: it keeps taking containers item by item (the API asks for the item), or its
        pieces outside containers would never enter the stock.
     4. Shipped in containers (receipt mode 2). A draft with the switch off can turn it on (CanTurnOnShipped); a
        posted one was received on posting and never takes containers.
     5. The order is approved and open, or closed: a closed order still takes a container made from its invoice.
     6. The invoice has pieces not in a container yet.
     7. The order lines still allow pieces: ordered - invoiced outside containers - loaded in other containers.
     8. A new container holds at most MaxAddQty pieces = per order line the lesser of 6 and 7.
     9. Permissions (purchase.invoices.create and containers.create): the API's; the state checks them for @UserId.
   Linking existing containers of the order follows 1-6, and needs a container line with pieces left to link.
   (docs/prompts/44-containers-from-the-invoice-check-and-fix.md, which numbers the rules, was not found: they are
   numbered here after the cases of the prompt - no order = 2, two items = 3, switch off = 4, order closed = 5.)

   Objects
     purchase.fn_PurchaseInvoice_ContainerState (new): the rules and the figures, one row per invoice.
     purchase.usp_PurchaseInvoice_ContainerState (new, @Id, @UserId): the state of the page - CanAddContainers, Reason,
       CanTurnOnShipped, NotInContainerQty, OrderLinesAvailableQty, MaxAddQty, PcsPerContainer, CanLink, LinkReason.
     purchase.usp_PurchaseInvoice_CheckContainers (new): THROWs the first failing rule - Add (1-8), Plan (1-7), Link (1-6).
     logistics.usp_Container_Save, _PlanFromOrder, _CreateBatch, purchase.usp_PurchaseInvoice_LinkContainers:
       re-created from their current bodies (script 43) + that check first, when called for an invoice. A draft still
       received on posting is no longer switched to "shipped in containers" by a link (rule 4): it is turned on first.

   Errors: 65030 (new) the invoice cannot take containers - the message is the rule's; 65031 (new) more pieces than the
           invoice and its order allow (rule 8, both figures in the message); 65006 not found (as before).

   Requires script 43. Idempotent, additive: re-applied at every API start-up through Schema.sql.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'purchase.fn_PurchaseInvoice_Unlinked', N'IF') IS NULL
   OR OBJECT_ID(N'purchase.fn_PurchaseInvoice_ItemContainers', N'IF') IS NULL
   OR OBJECT_ID(N'purchase.usp_PurchaseInvoice_LinkContainers', N'P') IS NULL
   OR OBJECT_ID(N'security.fn_UserPermissions', N'IF') IS NULL
BEGIN
    RAISERROR ('Run script 43 before this script.', 16, 1);
    SET NOEXEC ON;
END
GO

/* ================================================================== 1. The rules, in one place */

-- One row per invoice: its figures and the first rule (1-7) it fails. Rule 8 needs a quantity: the check compares it
-- with MaxAddQty. The figures leave the invoice's own lines out of "invoiced outside containers", so a draft with the
-- switch off already shows what it could take once turned on.
CREATE OR ALTER FUNCTION purchase.fn_PurchaseInvoice_ContainerState (@InvoiceId INT)
RETURNS TABLE
AS
RETURN
SELECT d.Id AS InvoiceId, d.DocumentNumber, d.Status, d.ReceiptMode,
       OrderId = o.Id, OrderNo = o.DocumentNumber, OrderStatus = o.Status,
       ln.ItemCount, ItemId = CASE WHEN ln.ItemCount = 1 THEN ln.FirstItemId END,
       NotInContainerQty      = ISNULL(u.NotInContainer, 0),
       OrderLinesAvailableQty = ISNULL(u.Available, 0),
       MaxAddQty              = ISNULL(u.MaxAdd, 0),
       pc.PcsPerContainer,
       LinkableQty            = ISNULL(k.Qty, 0),
       r.FailedRule, r.Reason,
       CanAddContainers = CAST(CASE WHEN r.FailedRule IS NULL THEN 1 ELSE 0 END AS BIT),
       CanTurnOnShipped = CAST(CASE WHEN r.FailedRule = 4 AND d.Status = 1 THEN 1 ELSE 0 END AS BIT),
       CanLink          = CAST(CASE WHEN ISNULL(r.FailedRule, 7) = 7 AND ISNULL(k.Qty, 0) > 0 THEN 1 ELSE 0 END AS BIT),
       LinkReason       = CAST(CASE WHEN ISNULL(r.FailedRule, 7) <> 7 THEN r.Reason
                                    WHEN ISNULL(k.Qty, 0) = 0
                                        THEN N'No container of order ' + ISNULL(o.DocumentNumber, N'(draft)')
                                             + N' has pieces left to link: add a container.' END AS NVARCHAR(400))
FROM purchase.PurchaseDocuments d
INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
LEFT  JOIN purchase.PurchaseDocuments o ON o.Id = d.SourceDocumentId
LEFT  JOIN inventory.DocumentTypes ot   ON ot.Id = o.DocumentTypeId
CROSS APPLY (SELECT Lines = COUNT(*), ItemCount = COUNT(DISTINCT l.ItemId), FirstItemId = MIN(l.ItemId),
                    Typed = SUM(CASE WHEN l.SourceLineId IS NULL THEN 1 ELSE 0 END)
             FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = d.Id) ln
-- per order line the invoice has pieces of outside containers: those pieces, and what the order line still allows
OUTER APPLY (SELECT NotInContainer = SUM(x.Unlinked), Available = SUM(x.Allowed),
                    MaxAdd = SUM(CASE WHEN x.Unlinked < x.Allowed THEN x.Unlinked ELSE x.Allowed END)
             FROM (SELECT Unlinked = un.UnlinkedBase,
                          Allowed = CASE WHEN a.Qty > 0 THEN a.Qty ELSE 0 END
                   FROM purchase.fn_PurchaseInvoice_Unlinked(d.Id) un
                   INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = un.PoLineId
                   CROSS APPLY (SELECT Qty = pol.QuantityBase
                                    - ISNULL((SELECT SUM(dl.QuantityBase) FROM purchase.PurchaseDocumentLines dl
                                              INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = dl.DocumentId
                                              WHERE dl.SourceLineId = pol.Id AND dl.ContainerLineId IS NULL AND dl.DocumentId <> d.Id
                                                AND xd.Status IN (1, 2, 4) AND xd.ReceiptMode <> 2), 0)
                                    - ISNULL((SELECT SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                                              INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                                              WHERE cl.PoLineId = pol.Id AND c.Status <> 8), 0)) a) x) u
OUTER APPLY (SELECT PcsPerContainer = MAX(s.PcsPerContainer) FROM purchase.fn_PurchaseInvoice_ItemContainers(d.Id) s) pc
-- what the order's Draft / Confirmed containers have loaded and not invoiced yet, on the order lines the invoice has outside
OUTER APPLY (SELECT Qty = SUM(cl.QuantityBase - ISNULL(q.Qty, 0))
             FROM logistics.ContainerLines cl
             INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
             OUTER APPLY (SELECT Qty = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                          INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                          WHERE pil.ContainerLineId = cl.Id AND pd.Status <> 3) q
             WHERE cl.PurchaseOrderId = o.Id AND c.Status IN (1, 2) AND cl.QuantityBase - ISNULL(q.Qty, 0) > 0
               AND cl.PoLineId IN (SELECT PoLineId FROM purchase.fn_PurchaseInvoice_Unlinked(d.Id))) k
CROSS APPLY (SELECT FailedRule = CAST(CASE
                        WHEN dt.Code <> N'PINV' OR d.Status NOT IN (1, 2) THEN 1
                        WHEN o.Id IS NULL OR ot.Code <> N'PO' OR ln.Typed > 0 THEN 2
                        WHEN ln.ItemCount > 1 AND d.Status = 1 THEN 3
                        WHEN d.ReceiptMode <> 2 THEN 4
                        WHEN o.Status NOT IN (2, 4) THEN 5
                        WHEN ISNULL(u.NotInContainer, 0) = 0 THEN 6
                        WHEN ISNULL(u.Available, 0) = 0 THEN 7 END AS TINYINT),
                    Reason = CAST(CASE
                        WHEN dt.Code <> N'PINV' THEN N'Only a purchase invoice can take containers.'
                        WHEN d.Status NOT IN (1, 2) THEN N'A cancelled invoice cannot be linked to containers.'
                        WHEN o.Id IS NULL OR ot.Code <> N'PO' OR ln.Typed > 0
                            THEN N'Only a purchase invoice created from a purchase order can be linked to containers.'
                        WHEN ln.ItemCount > 1 AND d.Status = 1
                            THEN N'This invoice holds ' + CAST(ln.ItemCount AS NVARCHAR(10))
                                 + N' items and a supplier invoice holds one: split it by item first.'
                        WHEN d.ReceiptMode <> 2 AND d.Status = 1
                            THEN N'Turn on "Shipped in containers" first: the goods will then enter the stock at the container offload.'
                        WHEN d.ReceiptMode <> 2 THEN N'This invoice was received when it was posted: it cannot be linked to containers.'
                        WHEN o.Status NOT IN (2, 4)
                            THEN N'Order ' + ISNULL(o.DocumentNumber, N'(draft)') + N' is '
                                 + CASE o.Status WHEN 1 THEN N'a draft' WHEN 3 THEN N'cancelled' ELSE N'waiting for approval' END
                                 + N': containers are made from an approved order.'
                        WHEN ln.Lines = 0 THEN N'This invoice has no lines yet.'
                        WHEN ISNULL(u.NotInContainer, 0) = 0 THEN N'Every piece of this invoice is already in a container.'
                        WHEN ISNULL(u.Available, 0) = 0
                            THEN N'Order ' + o.DocumentNumber + N' allows no more pieces: its lines are already loaded in containers'
                                 + N' or invoiced outside containers.' END AS NVARCHAR(400))) r
WHERE d.Id = @InvoiceId;
GO

/* ================================================================== 2. The state of the page */

-- One row (none for an unknown document). With @UserId the permissions (rule 9) are checked last: the first failing
-- rule is the reason. Turning the switch on is an edit of the invoice (purchase.invoices.create); linking needs that
-- permission, adding containers containers.create on top of it.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseInvoice_ContainerState
    @Id     INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Edit BIT = 1, @Create BIT = 1;
    IF @UserId IS NOT NULL
        SELECT @Edit   = CASE WHEN EXISTS (SELECT 1 FROM security.fn_UserPermissions(@UserId) WHERE Code = N'purchase.invoices.create') THEN 1 ELSE 0 END,
               @Create = CASE WHEN EXISTS (SELECT 1 FROM security.fn_UserPermissions(@UserId) WHERE Code = N'containers.create') THEN 1 ELSE 0 END;
    DECLARE @NoEdit NVARCHAR(400) = N'This action needs the purchase.invoices.create permission.',
            @NoCreate NVARCHAR(400) = N'This action needs the containers.create permission.';

    SELECT s.InvoiceId, s.DocumentNumber, s.Status, s.ReceiptMode, s.OrderId, s.OrderNo, s.OrderStatus, s.ItemId,
           CanAddContainers = CAST(CASE WHEN s.CanAddContainers = 1 AND @Edit = 1 AND @Create = 1 THEN 1 ELSE 0 END AS BIT),
           Reason = COALESCE(s.Reason, CASE WHEN @Edit = 0 THEN @NoEdit WHEN @Create = 0 THEN @NoCreate END),
           FailedRule = COALESCE(s.FailedRule, CASE WHEN @Edit = 0 OR @Create = 0 THEN 9 END),
           CanTurnOnShipped = CAST(CASE WHEN s.CanTurnOnShipped = 1 AND @Edit = 1 THEN 1 ELSE 0 END AS BIT),
           s.NotInContainerQty, s.OrderLinesAvailableQty, s.MaxAddQty, s.PcsPerContainer,
           CanLink = CAST(CASE WHEN s.CanLink = 1 AND @Edit = 1 THEN 1 ELSE 0 END AS BIT),
           LinkReason = COALESCE(s.LinkReason, CASE WHEN @Edit = 0 THEN @NoEdit END),
           s.LinkableQty
    FROM purchase.fn_PurchaseInvoice_ContainerState(@Id) s;
END
GO

/* ================================================================== 3. The check of every procedure of the path */

-- THROWs the first rule the invoice fails: Add (1-8: a new container of @QuantityBase pieces), Plan (1-7: a proposal),
-- Link (1-6: containers already on the order).
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseInvoice_CheckContainers
    @InvoiceId    INT,
    @Action       NVARCHAR(10) = N'Add',
    @QuantityBase INT          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Found BIT = 0, @Rule TINYINT, @Reason NVARCHAR(400), @NotIn INT, @Allowed INT, @Max INT;
    SELECT @Found = 1, @Rule = FailedRule, @Reason = Reason, @NotIn = NotInContainerQty, @Allowed = OrderLinesAvailableQty,
           @Max = MaxAddQty
    FROM purchase.fn_PurchaseInvoice_ContainerState(@InvoiceId);

    IF @Found = 0 THROW 65006, 'Document not found.', 1;
    IF @Rule IS NOT NULL AND @Rule <= CASE @Action WHEN N'Link' THEN 6 ELSE 7 END THROW 65030, @Reason, 1;
    IF @Action = N'Add' AND @QuantityBase > @Max
    BEGIN
        DECLARE @Msg NVARCHAR(400) = CAST(@QuantityBase AS NVARCHAR(12)) + N' pieces asked. At most '
            + CAST(@Max AS NVARCHAR(12)) + N' pcs: ' + CAST(@NotIn AS NVARCHAR(12)) + N' not in a container on this invoice, the order allows '
            + CAST(@Allowed AS NVARCHAR(12)) + N' more.';
        THROW 65031, @Msg, 1;
    END
END
GO

/* ================================================================== 4. Container_Save: the check first, for an invoice */

-- Re-created (51) from the body of script 43: + the rules of the invoice first (usp_PurchaseInvoice_CheckContainers).
-- Re-created (43) from the body of script 27: + @ForInvoiceId (default NULL = as before); invoices shipped in containers are not "invoiced directly".
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
    @Lines               logistics.tvp_ContainerLoadLine READONLY,
    @AllowOverCapacity   BIT            = 0,
    @RowVersion          BINARY(8)      = NULL,
    @UserId              INT            = NULL,
    @ForInvoiceId        INT            = NULL,   -- (43) for this invoice of the order: the order may be closed by it
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

    -- (51) a container created for an invoice: the invoice's rules 1-8 first, before anything is created
    IF @ForInvoiceId IS NOT NULL AND @Id IS NULL
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
    IF @MaxUnits IS NOT NULL AND @MaxUnits <= 0 THROW 69000, 'Maximum units must be greater than zero.', 1;
    IF @DispatchDate IS NOT NULL AND @Eta IS NOT NULL AND @Eta < @DispatchDate
        THROW 69000, 'The ETA cannot be earlier than the dispatch date.', 1;
    IF @ContainerNo IS NOT NULL AND EXISTS (SELECT 1 FROM logistics.Containers
                                            WHERE ContainerNo = @ContainerNo AND Status < 7 AND (@Id IS NULL OR Id <> @Id))
        THROW 69013, 'Another open container already uses this container number.', 1;

    DECLARE @Status TINYINT = NULL;
    IF @Id IS NOT NULL
    BEGIN
        SELECT @Status = Status, @PurchaseOrderId = ISNULL(PurchaseOrderId, @PurchaseOrderId) FROM logistics.Containers WHERE Id = @Id;
        IF @Status IS NULL THROW 69006, 'Container not found.', 1;
        IF @Status >= 6 THROW 69005, 'An offloaded, closed or cancelled container can no longer be changed.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 69004, 'This container was modified by another user. Reload the page and try again.', 1;
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

    -- Quantity still loadable on the order line.
    SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - '
                          + CAST(l.QuantityBase AS NVARCHAR(20)) + N' loaded but only '
                          + CAST(pol.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0) AS NVARCHAR(20))
                          + N' remain on order ' + ISNULL(d.DocumentNumber, N'(draft)') + N' line ' + CAST(pol.LineNumber AS NVARCHAR(10)) + N'.'
    FROM @Lines l
    INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = l.PoLineId
    INNER JOIN purchase.PurchaseDocuments d       ON d.Id = pol.DocumentId
    INNER JOIN inventory.Items i                  ON i.Id = pol.ItemId
    OUTER APPLY (SELECT Qty = SUM(x.QuantityBase) FROM purchase.PurchaseDocumentLines x
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
                 WHERE x.SourceLineId = pol.Id AND x.ContainerLineId IS NULL AND xd.Status IN (1, 2, 4) AND xd.ReceiptMode <> 2) dir
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

    -- Capacity: a warning that the caller can override, never a hard block.
    DECLARE @Capacity INT = @MaxUnits;
    IF @Capacity IS NULL AND @Id IS NOT NULL SELECT @Capacity = MaxUnits FROM logistics.Containers WHERE Id = @Id;
    IF @Capacity IS NULL SELECT @Capacity = MaxUnits FROM masterdata.ContainerTypes WHERE Id = @ContainerTypeId;

    DECLARE @Allocated INT = ISNULL((SELECT SUM(QuantityBase) FROM @Lines), 0);
    IF @Capacity IS NOT NULL AND @Allocated > @Capacity AND ISNULL(@AllowOverCapacity, 0) = 0
    BEGIN
        SET @Msg = N'The container holds ' + CAST(@Capacity AS NVARCHAR(10)) + N' units and ' + CAST(@Allocated AS NVARCHAR(10))
                 + N' are loaded. Confirm to load it above its capacity.';
        THROW 69007, @Msg, 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

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
                    @Capacity, @BranchId, @WarehouseId, @TruckNo, @WaybillNo, @DeclarationNo, @FeriNo,
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
                MaxUnits = @Capacity, BranchId = @BranchId, WarehouseId = @WarehouseId, TruckNo = @TruckNo, WaybillNo = @WaybillNo,
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

/* ================================================================== 5. PlanFromOrder: the check first, for an invoice */

-- Re-created (51) from the body of script 43: + the rules of the invoice first (usp_PurchaseInvoice_CheckContainers).
-- Re-created (43) from the body of script 28: + @ForInvoiceId (default NULL = as before) plans only what that invoice has outside containers.
CREATE OR ALTER PROCEDURE logistics.usp_Container_PlanFromOrder
    @PurchaseOrderId INT,
    @ContainerTypeId INT,
    @MixRemainders   BIT = 1,       -- 0 = the rest of every order line gets its own container
    @Capacities      logistics.tvp_ItemCapacity READONLY,    -- pieces per container typed by the user (optional)
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
           CASE WHEN @ForInvoiceId IS NOT NULL AND inv.UnlinkedBase < l.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0)
                THEN inv.UnlinkedBase
                ELSE l.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0) END,
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
    LEFT  JOIN purchase.fn_PurchaseInvoice_Unlinked(@ForInvoiceId) inv ON inv.PoLineId = l.Id
    OUTER APPLY (SELECT Qty = SUM(x.QuantityBase) FROM purchase.PurchaseDocumentLines x
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
                 WHERE x.SourceLineId = l.Id AND x.ContainerLineId IS NULL AND xd.Status IN (1, 2, 4) AND xd.ReceiptMode <> 2) dir
    OUTER APPLY (SELECT Qty = SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                 INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                 WHERE cl.PoLineId = l.Id AND c.Status <> 8) oth
    OUTER APPLY (SELECT TOP (1) u.PackingFormula FROM inventory.ItemUnits u
                 INNER JOIN masterdata.UnitTypes t ON t.Id = u.UnitTypeId
                 WHERE u.ItemId = l.ItemId AND t.IsContainer = 1
                 ORDER BY u.Id) cnt
    WHERE l.DocumentId = @PurchaseOrderId AND (@ForInvoiceId IS NULL OR inv.UnlinkedBase > 0);

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

/* ================================================================== 6. CreateBatch: the check first, for an invoice */

-- Re-created (51) from the body of script 43: + the rules of the invoice first (usp_PurchaseInvoice_CheckContainers).
-- Re-created (43) from the body of script 28: + @ForInvoiceId (default NULL = as before), passed to usp_Container_Save.
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
                     WHERE x.SourceLineId = pol.Id AND x.ContainerLineId IS NULL AND xd.Status IN (1, 2, 4) AND xd.ReceiptMode <> 2) dir
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
                 @ForInvoiceId        = @ForInvoiceId,
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

/* ================================================================== 7. LinkContainers: the check first */

-- Re-created (51) from the body of script 43: + the rules of the invoice first (usp_PurchaseInvoice_CheckContainers);
-- a draft is no longer switched to "shipped in containers" here: rule 4 has it turned on first.
-- A draft, or a posted invoice shipped in containers (receipt mode 2), takes container lines of its own order. Its
-- lines of that order line outside containers are SPLIT: the linked part becomes a line of its own (same item, unit,
-- price, discount, warehouse), the rest stays unlinked. A part that is not a whole number of the line's unit is put in
-- the base unit (price per base unit), as usp_PurchaseDocument_CreateFromSource does. The document total is kept: a
-- rounding difference goes on the last line split. A draft still received on posting becomes "shipped in containers".
-- Nothing else needs writing: the order lines count invoiced quantities by the invoice lines, and
-- logistics.ContainerInvoices is the unused table of the old model (script 27).
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

        DECLARE @TypeCode NVARCHAR(20), @Status TINYINT, @OrderId INT, @Mode TINYINT, @Number NVARCHAR(30);
        SELECT @TypeCode = dt.Code, @Status = d.Status, @OrderId = d.SourceDocumentId, @Mode = d.ReceiptMode,
               @Number = ISNULL(d.DocumentNumber, N'draft #' + CAST(d.Id AS NVARCHAR(10)))
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @InvoiceId;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        -- (51) the invoice's rules 1-6 first: the same sentences as the state of the page
        EXEC purchase.usp_PurchaseInvoice_CheckContainers @InvoiceId = @InvoiceId, @Action = N'Link';
        IF @TypeCode <> N'PINV' OR @OrderId IS NULL
            THROW 65028, 'Only a purchase invoice created from a purchase order can be linked to containers.', 1;
        IF @Status NOT IN (1, 2) THROW 65010, 'A cancelled invoice cannot be linked to containers.', 1;
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

        DECLARE @Msg NVARCHAR(400);

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

        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines
                   WHERE DocumentId = @InvoiceId AND ContainerLineId IS NULL AND (ReceivedQuantityBase > 0 OR ReturnedQuantityBase > 0))
            THROW 65028, 'Goods of this invoice outside containers were already received or returned: it can no longer be linked.', 1;

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

        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        SELECT @InvoiceId, N'Updated',
               LEFT(N'Linked to containers ' + STRING_AGG(x.Ref + N' (' + CAST(x.Qty AS NVARCHAR(20)) + N')', N', ')
                    WITHIN GROUP (ORDER BY x.Ref), 1000), @UserId
        FROM (SELECT Ref = c.ContainerRef, Qty = SUM(k.QuantityBase)
              FROM @Links k
              INNER JOIN logistics.ContainerLines cl ON cl.Id = k.ContainerLineId
              INNER JOIN logistics.Containers c      ON c.Id = cl.ContainerId
              GROUP BY c.ContainerRef) x;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    EXEC purchase.usp_PurchaseInvoice_ContainerSummary @InvoiceId;
END
GO

/* ================================================================== 8. Check */

SELECT o.ObjectName, ObjectType = ISNULL(so.type_desc, N'MISSING')
FROM (VALUES (N'purchase.fn_PurchaseInvoice_ContainerState'), (N'purchase.usp_PurchaseInvoice_ContainerState'),
             (N'purchase.usp_PurchaseInvoice_CheckContainers'), (N'logistics.usp_Container_Save'),
             (N'logistics.usp_Container_PlanFromOrder'), (N'logistics.usp_Container_CreateBatch'),
             (N'purchase.usp_PurchaseInvoice_LinkContainers')) o (ObjectName)
LEFT JOIN sys.objects so ON so.object_id = OBJECT_ID(o.ObjectName)
ORDER BY ObjectType, o.ObjectName;                                    -- expected 7: 1 function, 6 procedures, none MISSING

-- Invoices shipped in containers with pieces not in a container yet: add or link containers from the invoice.
SELECT d.DocumentNumber, Draft = CASE WHEN d.Status = 1 THEN N'draft #' + CAST(d.Id AS NVARCHAR(10)) END, i.ItemCode,
       NotInContainer = s.NotInContainerQty, s.MaxAddQty, s.Reason
FROM purchase.PurchaseDocuments d
INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
CROSS APPLY purchase.fn_PurchaseInvoice_ContainerState(d.Id) s
LEFT  JOIN inventory.Items i ON i.Id = s.ItemId
WHERE dt.Code = N'PINV' AND d.Status IN (1, 2) AND d.ReceiptMode = 2 AND s.NotInContainerQty > 0
ORDER BY d.Id;

-- Invoices whose order is closed: they still take a container made from them (rule 5).
SELECT d.DocumentNumber, Draft = CASE WHEN d.Status = 1 THEN N'draft #' + CAST(d.Id AS NVARCHAR(10)) END,
       Shipped = CASE WHEN d.ReceiptMode = 2 THEN N'yes' ELSE N'no' END, OrderNo = o.DocumentNumber, s.Reason
FROM purchase.PurchaseDocuments d
INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId
INNER JOIN purchase.PurchaseDocuments o ON o.Id = d.SourceDocumentId AND o.Status = 4
CROSS APPLY purchase.fn_PurchaseInvoice_ContainerState(d.Id) s
WHERE dt.Code = N'PINV' AND d.Status IN (1, 2)
ORDER BY d.Id;

PRINT 'Script 51 applied: one place for the rules of a purchase invoice taking containers (state, check; 65030, 65031).';
GO

SET NOEXEC OFF;
GO
