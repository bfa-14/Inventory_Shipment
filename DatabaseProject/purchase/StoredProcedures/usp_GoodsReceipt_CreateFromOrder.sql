/* ================================================================== 13. Receive goods... on a purchase order */

/* A DRAFT FROM A PURCHASE ORDER, posted or closed (63010 otherwise). @Lines empty = every line with something to
   receive (fn_PoLine_Progress.ToReceiveBase: ordered - received - settled short - in containers - in draft receipts);
   nothing (63009): "Everything still to receive on this order travels in containers..." or "Nothing is left...".
   Otherwise one row per order line (PoLineId; ItemId = the order line's item; Quantity in the row's ItemUnitId, the
   base unit for pieces; WarehouseId NULL = @WarehouseId, else the order line's; CloseShort with VarianceReasonCode /
   VarianceReason = "Nothing more will come"; ExpiryDate NULL = the order line's). Rows of 0 are dropped unless
   CloseShort. A line is written in the order line's unit when its pieces divide by its packing, else in pieces. The
   draft is made by usp_GoodsReceipt_Save (source Order): its checks and caps apply. */
CREATE   PROCEDURE purchase.usp_GoodsReceipt_CreateFromOrder
    @PurchaseOrderId   INT,
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

    DECLARE @Status TINYINT, @No NVARCHAR(30), @BranchId INT, @SupplierId INT, @Msg NVARCHAR(400);
    SELECT @Status = d.Status, @No = ISNULL(d.DocumentNumber, N'#' + CAST(d.Id AS NVARCHAR(10))), @BranchId = d.BranchId, @SupplierId = d.SupplierId
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId AND dt.Code = N'PO'
    WHERE d.Id = @PurchaseOrderId;
    IF @Status IS NULL THROW 63006, 'Purchase order not found.', 1;
    IF @Status = 3 THROW 63010, 'The purchase order is cancelled.', 1;
    IF @Status NOT IN (2, 4) THROW 63010, 'Only an approved order can be received.', 1;

    DECLARE @Pick TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, PoLineId INT NOT NULL, QuantityBase INT NOT NULL, WarehouseId INT NULL,
                         CloseShort BIT NOT NULL, ReasonCode NVARCHAR(20) NULL, Reason NVARCHAR(300) NULL, ExpiryDate DATE NULL,
                         Notes NVARCHAR(300) NULL);

    IF EXISTS (SELECT 1 FROM @Lines)
    BEGIN
        SELECT TOP (1) @Msg = N'Line ' + CAST(r.LineNumber AS NVARCHAR(10)) + N': ' +
            CASE WHEN pol.Id IS NULL THEN N'it is not a line of order ' + @No + N'.'
                 WHEN pol.ItemId <> r.ItemId THEN N'the item differs from the order line.'
                 WHEN iu.Id IS NULL THEN N'the unit does not belong to the item of the order line.'
                 ELSE N'the received quantity cannot be negative.' END
        FROM @Lines r
        LEFT JOIN purchase.PurchaseDocumentLines pol ON pol.Id = r.PoLineId AND pol.DocumentId = @PurchaseOrderId
        LEFT JOIN inventory.ItemUnits iu             ON iu.Id = r.ItemUnitId AND iu.ItemId = r.ItemId
        WHERE pol.Id IS NULL OR pol.ItemId <> r.ItemId OR iu.Id IS NULL OR r.Quantity < 0
        ORDER BY r.LineNumber;
        IF @Msg IS NOT NULL THROW 63000, @Msg, 1;

        INSERT INTO @Pick (PoLineId, QuantityBase, WarehouseId, CloseShort, ReasonCode, Reason, ExpiryDate, Notes)
        SELECT r.PoLineId, r.Quantity * iu.PackingFormula, r.WarehouseId, ISNULL(r.CloseShort, 0), r.VarianceReasonCode, r.VarianceReason,
               r.ExpiryDate, r.Notes
        FROM @Lines r
        INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = r.PoLineId
        INNER JOIN inventory.ItemUnits iu             ON iu.Id = r.ItemUnitId
        WHERE r.Quantity > 0 OR ISNULL(r.CloseShort, 0) = 1
        ORDER BY pol.LineNumber, r.LineNumber;
        IF NOT EXISTS (SELECT 1 FROM @Pick) THROW 63009, 'Enter the pieces received on at least one line.', 1;
    END
    ELSE
    BEGIN
        INSERT INTO @Pick (PoLineId, QuantityBase, CloseShort)
        SELECT p.PoLineId, p.ToReceiveBase, 0
        FROM purchase.fn_PoLine_Progress(@PurchaseOrderId) p
        WHERE p.ToReceiveBase > 0
        ORDER BY p.LineNumber;
        IF NOT EXISTS (SELECT 1 FROM @Pick)
        BEGIN
            IF EXISTS (SELECT 1 FROM purchase.fn_PoLine_Progress(@PurchaseOrderId) p
                       WHERE p.InContainersBase > 0 AND p.OrderedBase - p.GoodsReceivedBase - p.GoodsShortBase - p.InDraftReceiptsBase > 0)
                THROW 63009, 'Everything still to receive on this order travels in containers: it is received with its containers.', 1;
            THROW 63009, 'Nothing is left to receive on this order.', 1;
        END
    END

    -- in the order line's unit when the pieces divide by its packing, else in pieces
    DECLARE @T purchase.tvp_GoodsReceiptLine;
    INSERT INTO @T (LineNumber, ItemId, ItemUnitId, Quantity, WarehouseId, PoLineId, VarianceReasonCode, VarianceReason, CloseShort,
                    ExpiryDate, Notes)
    SELECT k.Seq, pol.ItemId,
           CASE WHEN k.QuantityBase % pol.PackingFormula = 0 OR bu.Id IS NULL THEN pol.ItemUnitId ELSE bu.Id END,
           CASE WHEN k.QuantityBase % pol.PackingFormula = 0 OR bu.Id IS NULL THEN k.QuantityBase / pol.PackingFormula ELSE k.QuantityBase END,
           COALESCE(k.WarehouseId, @WarehouseId, pol.WarehouseId), k.PoLineId, k.ReasonCode, k.Reason, k.CloseShort,
           COALESCE(k.ExpiryDate, pol.ExpiryDate), k.Notes
    FROM @Pick k
    INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = k.PoLineId
    OUTER APPLY (SELECT TOP (1) u.Id FROM inventory.ItemUnits u WHERE u.ItemId = pol.ItemId AND u.IsBaseUnit = 1 ORDER BY u.Id) bu;

    IF @WarehouseId IS NULL SELECT TOP (1) @WarehouseId = WarehouseId FROM @T ORDER BY LineNumber;

    EXEC purchase.usp_GoodsReceipt_Save @SourceKind = N'Order', @DocumentDate = @DocumentDate, @BranchId = @BranchId,
         @WarehouseId = @WarehouseId, @SupplierId = @SupplierId, @PurchaseOrderId = @PurchaseOrderId,
         @SupplierReference = @SupplierReference, @Notes = @Notes, @Lines = @T, @UserId = @UserId, @NewId = @NewId OUTPUT;
END

GO

