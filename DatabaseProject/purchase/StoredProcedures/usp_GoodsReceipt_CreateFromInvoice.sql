/* ================================================================== 14. Receive goods... on a posted purchase invoice */

/* A DRAFT FROM A POSTED (OR CLOSED) SUPPLIER INVOICE, for its lines NOT linked to a container (those are received with
   their containers). Refused (63010) for a draft or cancelled invoice and for one posted before goods receipts
   without "Shipped in containers" (its stock entered when it was posted), or with every line in a container offloaded
   the old way (its stock entered at that offload). @Lines empty = every such line with
   something to receive (fn_InvoiceLine_ToReceive: invoiced - received - in draft receipts); nothing (63009). Otherwise
   one row per invoice line (InvoiceLineId; ItemId = the line's item; Quantity in the row's ItemUnitId; WarehouseId
   NULL = @WarehouseId, else the invoice line's; CloseShort + reason on a line of an order; ExpiryDate NULL = the
   invoice line's, else the order line's). Each line keeps its order line (PoLineId), so the matching works; this
   receipt's pieces match this invoice first. Made by usp_GoodsReceipt_Save (source Invoice). */
CREATE   PROCEDURE purchase.usp_GoodsReceipt_CreateFromInvoice
    @InvoiceId         INT,
    @Lines             purchase.tvp_GoodsReceiptLine READONLY,
    @DocumentDate      DATE           = NULL,
    @SupplierReference NVARCHAR(100)  = NULL,
    @UserId            INT            = NULL,
    @NewId             INT            = NULL OUTPUT,
    @WarehouseId       INT            = NULL,
    @Notes             NVARCHAR(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- POSTED BEFORE GOODS RECEIPTS (@Old): an invoice received when it was posted, or a "Shipped in containers" one
    -- whose lines are all in containers offloaded the old way (fn_Container_ReceivedBy 'Offload') - its goods are in
    -- stock already, they do not "travel in containers" (the reason usp_PurchaseDocument_Get gives, rule 15)
    DECLARE @Status TINYINT, @No NVARCHAR(30), @Old BIT, @Msg NVARCHAR(400);
    SELECT @Status = d.Status, @No = ISNULL(d.DocumentNumber, N'#' + CAST(d.Id AS NVARCHAR(10))),
           @Old = CASE WHEN d.UsesGoodsReceipts = 0 AND d.ReceiptMode = 1 THEN 1
                       WHEN d.UsesGoodsReceipts = 0
                            AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines x WHERE x.DocumentId = d.Id AND x.ContainerLineId IS NULL)
                            AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines x
                                            INNER JOIN logistics.ContainerLines cl ON cl.Id = x.ContainerLineId
                                            CROSS APPLY logistics.fn_Container_ReceivedBy(cl.ContainerId) rb
                                            WHERE x.DocumentId = d.Id AND ISNULL(rb.ReceivedBy, N'') <> N'Offload')
                       THEN 1 ELSE 0 END
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId AND dt.Code = N'PINV'
    WHERE d.Id = @InvoiceId;
    IF @Status IS NULL THROW 63006, 'Purchase invoice not found.', 1;
    IF @Status = 3 THROW 63010, 'The purchase invoice is cancelled.', 1;
    IF @Status NOT IN (2, 4) THROW 63010, 'Post the invoice first: goods are received against a posted invoice, or from the order.', 1;
    IF @Old = 1 THROW 63010, 'Posted before goods receipts: its stock entered when it was posted (or when its container was offloaded).', 1;

    DECLARE @Pick TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, InvoiceLineId INT NOT NULL, QuantityBase INT NOT NULL, WarehouseId INT NULL,
                         CloseShort BIT NOT NULL, ReasonCode NVARCHAR(20) NULL, Reason NVARCHAR(300) NULL, ExpiryDate DATE NULL,
                         Notes NVARCHAR(300) NULL);

    IF EXISTS (SELECT 1 FROM @Lines)
    BEGIN
        SELECT TOP (1) @Msg = N'Line ' + CAST(r.LineNumber AS NVARCHAR(10)) + N': ' +
            CASE WHEN pil.Id IS NULL THEN N'it is not a line of invoice ' + @No + N'.'
                 WHEN pil.ContainerLineId IS NOT NULL THEN N'this invoice line travels in a container: it is received with its container.'
                 WHEN pil.ItemId <> r.ItemId THEN N'the item differs from the invoice line.'
                 WHEN iu.Id IS NULL THEN N'the unit does not belong to the item of the invoice line.'
                 ELSE N'the received quantity cannot be negative.' END
        FROM @Lines r
        LEFT JOIN purchase.PurchaseDocumentLines pil ON pil.Id = r.InvoiceLineId AND pil.DocumentId = @InvoiceId
        LEFT JOIN inventory.ItemUnits iu             ON iu.Id = r.ItemUnitId AND iu.ItemId = r.ItemId
        WHERE pil.Id IS NULL OR pil.ContainerLineId IS NOT NULL OR pil.ItemId <> r.ItemId OR iu.Id IS NULL OR r.Quantity < 0
        ORDER BY r.LineNumber;
        IF @Msg IS NOT NULL THROW 63000, @Msg, 1;

        INSERT INTO @Pick (InvoiceLineId, QuantityBase, WarehouseId, CloseShort, ReasonCode, Reason, ExpiryDate, Notes)
        SELECT r.InvoiceLineId, r.Quantity * iu.PackingFormula, r.WarehouseId, ISNULL(r.CloseShort, 0), r.VarianceReasonCode, r.VarianceReason,
               r.ExpiryDate, r.Notes
        FROM @Lines r
        INNER JOIN purchase.PurchaseDocumentLines pil ON pil.Id = r.InvoiceLineId
        INNER JOIN inventory.ItemUnits iu             ON iu.Id = r.ItemUnitId
        WHERE r.Quantity > 0 OR ISNULL(r.CloseShort, 0) = 1
        ORDER BY pil.LineNumber, r.LineNumber;
        IF NOT EXISTS (SELECT 1 FROM @Pick) THROW 63009, 'Enter the pieces received on at least one line.', 1;
    END
    ELSE
    BEGIN
        INSERT INTO @Pick (InvoiceLineId, QuantityBase, CloseShort)
        SELECT t.InvoiceLineId, t.ToReceiveBase, 0
        FROM purchase.fn_InvoiceLine_ToReceive(@InvoiceId) t
        WHERE t.ToReceiveBase > 0
        ORDER BY t.LineNumber;
        IF NOT EXISTS (SELECT 1 FROM @Pick)
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM purchase.fn_InvoiceLine_ToReceive(@InvoiceId))
                THROW 63009, 'This invoice''s goods travel in containers: they are received with their containers.', 1;
            IF EXISTS (SELECT 1 FROM purchase.fn_InvoiceLine_ToReceive(@InvoiceId) t
                       WHERE t.InDraftReceiptsBase > 0 AND t.InvoicedBase - t.ReceivedBase > 0)
                THROW 63009, 'The rest of this invoice is on draft goods receipts: post or delete them first.', 1;
            THROW 63009, 'Every piece of this invoice is already received.', 1;
        END
    END

    DECLARE @T purchase.tvp_GoodsReceiptLine;
    INSERT INTO @T (LineNumber, ItemId, ItemUnitId, Quantity, WarehouseId, PoLineId, InvoiceLineId, VarianceReasonCode, VarianceReason,
                    CloseShort, ExpiryDate, Notes)
    SELECT k.Seq, pil.ItemId,
           CASE WHEN k.QuantityBase % pil.PackingFormula = 0 OR bu.Id IS NULL THEN pil.ItemUnitId ELSE bu.Id END,
           CASE WHEN k.QuantityBase % pil.PackingFormula = 0 OR bu.Id IS NULL THEN k.QuantityBase / pil.PackingFormula ELSE k.QuantityBase END,
           COALESCE(k.WarehouseId, @WarehouseId, pil.WarehouseId), pil.SourceLineId, k.InvoiceLineId, k.ReasonCode, k.Reason, k.CloseShort,
           COALESCE(k.ExpiryDate, pil.ExpiryDate, pol.ExpiryDate), k.Notes
    FROM @Pick k
    INNER JOIN purchase.PurchaseDocumentLines pil ON pil.Id = k.InvoiceLineId
    LEFT  JOIN purchase.PurchaseDocumentLines pol ON pol.Id = pil.SourceLineId
    OUTER APPLY (SELECT TOP (1) u.Id FROM inventory.ItemUnits u WHERE u.ItemId = pil.ItemId AND u.IsBaseUnit = 1 ORDER BY u.Id) bu;

    IF @WarehouseId IS NULL SELECT TOP (1) @WarehouseId = WarehouseId FROM @T ORDER BY LineNumber;

    EXEC purchase.usp_GoodsReceipt_Save @SourceKind = N'Invoice', @DocumentDate = @DocumentDate, @WarehouseId = @WarehouseId,
         @PurchaseInvoiceId = @InvoiceId, @SupplierReference = @SupplierReference, @Notes = @Notes, @Lines = @T,
         @UserId = @UserId, @NewId = @NewId OUTPUT;
END

GO

