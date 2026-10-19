/* ================================================================== 19. Search */

/* THE LIST, paged, and a totals row (2 result sets).
   Filters: @Search (number, container ref or no., order and invoice numbers - the source's and the lines' -, item
   code, delivery note no., supplier code or name, movement no.); status, source kind, branch, supplier (the header's or
   a line's: mixed containers), warehouse (the header's or a line's), dates; @ContainerId, @PurchaseOrderId (the
   header's or a line's), @InvoiceId (the source invoice, or an invoice its pieces are matched to), @MovementId,
   @IsAuto;
     @WithDifferences      a line received differently from what was expected and settled (container lines that
                           differ from the loaded pieces, "Nothing more will come", a reason given, pieces settled short)
     @ReceivedNotInvoiced  posted, with pieces received and not matched to posted invoices yet
     @DeliveredNotReceived the goods are at the warehouse but not in stock: draft container receipts whose container's
                           Delivery is completed
     @NotReceived          drafts of any source: nothing of them is in stock yet (the menu count's list)
   Sort: DocumentNumber | DocumentDate | SupplierName | Status | ReceivedBase | ValueBase | CreatedAtUtc | PostedAtUtc.
   1: one row per receipt (TotalCount = all pages); value = current value of the lines (an estimate on a draft).
   2: totals over every receipt of the filter (all pages): ReceivedNotInvoicedBase / ReceivedNotInvoicedValueBase (at
      the order price, for month-end; manual lines at their cost at receipt), ReceiptCount, DraftCount. */
CREATE   PROCEDURE purchase.usp_GoodsReceipt_Search
    @Search               NVARCHAR(100) = NULL,
    @Status               TINYINT       = NULL,     -- 1 Draft | 2 Posted | 3 Cancelled
    @SourceKind           NVARCHAR(10)  = NULL,     -- Container | Order | Invoice | Manual
    @BranchId             INT           = NULL,
    @SupplierId           INT           = NULL,
    @WarehouseId          INT           = NULL,
    @DateFrom             DATE          = NULL,
    @DateTo               DATE          = NULL,
    @ContainerId          INT           = NULL,
    @PurchaseOrderId      INT           = NULL,
    @InvoiceId            INT           = NULL,
    @MovementId           INT           = NULL,
    @IsAuto               BIT           = NULL,
    @WithDifferences      BIT           = 0,
    @ReceivedNotInvoiced  BIT           = 0,
    @DeliveredNotReceived BIT           = 0,
    @NotReceived          BIT           = 0,
    @SortColumn           NVARCHAR(30)  = N'DocumentDate',
    @SortDirection        NVARCHAR(4)   = N'DESC',
    @PageNumber           INT           = 1,
    @PageSize             INT           = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @SourceKind = NULLIF(LTRIM(RTRIM(@SourceKind)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'DocumentNumber', N'DocumentDate', N'SupplierName', N'Status', N'ReceivedBase',
                                                  N'ValueBase', N'CreatedAtUtc', N'PostedAtUtc')
        SET @SortColumn = N'DocumentDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);
    SELECT @WithDifferences = ISNULL(@WithDifferences, 0), @ReceivedNotInvoiced = ISNULL(@ReceivedNotInvoiced, 0),
           @DeliveredNotReceived = ISNULL(@DeliveredNotReceived, 0), @NotReceived = ISNULL(@NotReceived, 0);

    -- the filter once; the page and the totals read it
    DECLARE @Ids TABLE (Id INT NOT NULL PRIMARY KEY);
    INSERT INTO @Ids (Id)
    SELECT g.Id
    FROM purchase.GoodsReceipts g
    LEFT JOIN logistics.Containers c         ON c.Id = g.ContainerId
    LEFT JOIN purchase.PurchaseDocuments po  ON po.Id = g.PurchaseOrderId
    LEFT JOIN purchase.PurchaseDocuments pi  ON pi.Id = g.PurchaseInvoiceId
    LEFT JOIN masterdata.Parties sp          ON sp.Id = g.SupplierId
    LEFT JOIN logistics.Movements mv         ON mv.Id = g.MovementId
    WHERE (@Status IS NULL OR g.Status = @Status)
      AND (@SourceKind IS NULL OR g.SourceKind = @SourceKind)
      AND (@BranchId IS NULL OR g.BranchId = @BranchId)
      AND (@DateFrom IS NULL OR g.DocumentDate >= @DateFrom)
      AND (@DateTo IS NULL OR g.DocumentDate <= @DateTo)
      AND (@ContainerId IS NULL OR g.ContainerId = @ContainerId)
      AND (@MovementId IS NULL OR g.MovementId = @MovementId)
      AND (@IsAuto IS NULL OR g.IsAuto = @IsAuto)
      AND (@SupplierId IS NULL OR g.SupplierId = @SupplierId
           OR EXISTS (SELECT 1 FROM purchase.GoodsReceiptLines l WHERE l.GoodsReceiptId = g.Id AND l.SupplierId = @SupplierId))
      AND (@WarehouseId IS NULL OR g.WarehouseId = @WarehouseId
           OR EXISTS (SELECT 1 FROM purchase.GoodsReceiptLines l WHERE l.GoodsReceiptId = g.Id AND l.WarehouseId = @WarehouseId))
      AND (@PurchaseOrderId IS NULL OR g.PurchaseOrderId = @PurchaseOrderId
           OR EXISTS (SELECT 1 FROM purchase.GoodsReceiptLines l WHERE l.GoodsReceiptId = g.Id AND l.PurchaseOrderId = @PurchaseOrderId))
      AND (@InvoiceId IS NULL OR g.PurchaseInvoiceId = @InvoiceId
           OR EXISTS (SELECT 1 FROM purchase.GoodsReceiptLines l
                      INNER JOIN purchase.GoodsReceiptInvoiceMatches m ON m.GoodsReceiptLineId = l.Id
                      INNER JOIN purchase.PurchaseDocumentLines pil    ON pil.Id = m.InvoiceLineId AND pil.DocumentId = @InvoiceId
                      WHERE l.GoodsReceiptId = g.Id))
      AND (@WithDifferences = 0
           OR EXISTS (SELECT 1 FROM purchase.GoodsReceiptLines l
                      WHERE l.GoodsReceiptId = g.Id
                        AND ((l.ContainerLineId IS NOT NULL AND l.QuantityBase <> ISNULL(l.ExpectedQuantityBase, l.QuantityBase))
                             OR l.CloseShort = 1 OR l.SettledShortBase > 0 OR l.VarianceReasonCode IS NOT NULL)))
      AND (@ReceivedNotInvoiced = 0
           OR (g.Status = 2 AND EXISTS (SELECT 1 FROM purchase.GoodsReceiptLines l WHERE l.GoodsReceiptId = g.Id AND l.QuantityBase > l.InvoicedBase)))
      AND (@DeliveredNotReceived = 0
           OR (g.Status = 1 AND g.SourceKind = N'Container' AND EXISTS (SELECT 1 FROM logistics.fn_Container_LastDelivery(g.ContainerId))))
      AND (@NotReceived = 0 OR g.Status = 1)
      AND (@Search IS NULL
           OR g.DocumentNumber LIKE N'%' + @Search + N'%' OR g.SupplierReference LIKE N'%' + @Search + N'%'
           OR c.ContainerRef LIKE N'%' + @Search + N'%' OR c.ContainerNo LIKE N'%' + @Search + N'%'
           OR po.DocumentNumber LIKE N'%' + @Search + N'%' OR pi.DocumentNumber LIKE N'%' + @Search + N'%'
           OR mv.MovementNo LIKE N'%' + @Search + N'%'
           OR sp.PartyCode LIKE N'%' + @Search + N'%' OR sp.PartyName LIKE N'%' + @Search + N'%'
           OR EXISTS (SELECT 1 FROM purchase.GoodsReceiptLines l
                      INNER JOIN inventory.Items i               ON i.Id = l.ItemId
                      LEFT  JOIN purchase.PurchaseDocuments lpo  ON lpo.Id = l.PurchaseOrderId
                      LEFT  JOIN purchase.PurchaseDocumentLines lil ON lil.Id = l.InvoiceLineId
                      LEFT  JOIN purchase.PurchaseDocuments lpi  ON lpi.Id = lil.DocumentId
                      WHERE l.GoodsReceiptId = g.Id
                        AND (i.ItemCode LIKE N'%' + @Search + N'%' OR lpo.DocumentNumber LIKE N'%' + @Search + N'%'
                             OR lpi.DocumentNumber LIKE N'%' + @Search + N'%')));

    -- 1: the page
    SELECT g.Id, g.DocumentNumber, g.DocumentDate, g.Status,
           StatusName = CASE g.Status WHEN 1 THEN N'Draft' WHEN 2 THEN N'Posted' ELSE N'Cancelled' END,
           g.SourceKind, g.IsAuto,
           g.BranchId, b.BranchCode, b.BranchName,
           g.WarehouseId, w.WarehouseCode, w.WarehouseName,
           g.SupplierId, sp.PartyCode AS SupplierCode,
           SupplierName = ISNULL(sp.PartyName, CASE WHEN g.SourceKind = N'Container' THEN N'Several suppliers' END),
           g.ContainerId, c.ContainerRef, c.ContainerNo,
           g.PurchaseOrderId, po.DocumentNumber AS PurchaseOrderNumber,
           g.PurchaseInvoiceId, pi.DocumentNumber AS PurchaseInvoiceNumber,
           g.MovementId, mv.MovementNo, g.SupplierReference,
           LineCount = ISNULL(t.Lines, 0), ExpectedBase = g.TotalExpectedBase, ReceivedBase = g.TotalReceivedBase,
           ShortBase = ISNULL(CASE WHEN g.Status = 1 THEN t.ShortDraft ELSE t.Settled END, 0), InvoicedBase = ISNULL(t.Invoiced, 0),
           ValueBase = ISNULL(v.Value, 0), IsValueEstimate = CAST(CASE WHEN g.Status = 1 THEN 1 ELSE 0 END AS BIT),
           g.PostedAtUtc, pu.FullName AS PostedByName, g.CreatedAtUtc, cu.FullName AS CreatedByName, g.UpdatedAtUtc,
           g.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM @Ids x
    INNER JOIN purchase.GoodsReceipts g       ON g.Id = x.Id
    INNER JOIN masterdata.Branches b          ON b.Id = g.BranchId
    LEFT  JOIN masterdata.Warehouses w        ON w.Id = g.WarehouseId
    LEFT  JOIN masterdata.Parties sp          ON sp.Id = g.SupplierId
    LEFT  JOIN logistics.Containers c         ON c.Id = g.ContainerId
    LEFT  JOIN purchase.PurchaseDocuments po  ON po.Id = g.PurchaseOrderId
    LEFT  JOIN purchase.PurchaseDocuments pi  ON pi.Id = g.PurchaseInvoiceId
    LEFT  JOIN logistics.Movements mv         ON mv.Id = g.MovementId
    LEFT  JOIN security.Users pu              ON pu.Id = g.PostedBy
    LEFT  JOIN security.Users cu              ON cu.Id = g.CreatedBy
    OUTER APPLY (SELECT Lines = COUNT(*), Invoiced = SUM(l.InvoicedBase),
                        Settled = SUM(l.SettledShortBase),
                        ShortDraft = SUM(CASE WHEN (l.ContainerLineId IS NOT NULL OR l.CloseShort = 1) AND l.ExpectedQuantityBase > l.QuantityBase
                                              THEN l.ExpectedQuantityBase - l.QuantityBase ELSE 0 END)
                 FROM purchase.GoodsReceiptLines l WHERE l.GoodsReceiptId = g.Id) t
    OUTER APPLY (SELECT Value = SUM(k.ValueBase) FROM purchase.fn_GoodsReceiptLine_Cost(g.Id) k) v
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN g.DocumentNumber WHEN N'SupplierName' THEN ISNULL(sp.PartyName, N'') END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN g.DocumentNumber WHEN N'SupplierName' THEN ISNULL(sp.PartyName, N'') END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'DocumentDate' THEN g.DocumentDate END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'DocumentDate' THEN g.DocumentDate END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Status' THEN CAST(g.Status AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Status' THEN CAST(g.Status AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'ReceivedBase' THEN g.TotalReceivedBase END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'ReceivedBase' THEN g.TotalReceivedBase END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'ValueBase' THEN v.Value END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'ValueBase' THEN v.Value END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN g.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN g.CreatedAtUtc END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'PostedAtUtc' THEN g.PostedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'PostedAtUtc' THEN g.PostedAtUtc END DESC,
        g.DocumentDate DESC, g.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;

    -- 2: totals over the whole filter: received and not invoiced yet, at the order price (month-end)
    SELECT ReceivedNotInvoicedBase = ISNULL(SUM(CASE WHEN g.Status = 2 AND l.QuantityBase > l.InvoicedBase
                                                     THEN l.QuantityBase - l.InvoicedBase END), 0),
           ReceivedNotInvoicedValueBase = CAST(ISNULL(SUM(CASE WHEN g.Status = 2 AND l.QuantityBase > l.InvoicedBase
                                                               THEN (l.QuantityBase - l.InvoicedBase)
                                                                    * COALESCE(l.PoFobBase, pol.LineTotal / NULLIF(po.ExchangeRate, 0) / NULLIF(pol.QuantityBase, 0),
                                                                               l.CostAtReceiptBase, 0) END), 0) AS DECIMAL(18,2)),
           ReceiptCount = (SELECT COUNT(*) FROM @Ids),
           DraftCount   = (SELECT COUNT(*) FROM @Ids i INNER JOIN purchase.GoodsReceipts d ON d.Id = i.Id AND d.Status = 1)
    FROM @Ids x
    INNER JOIN purchase.GoodsReceipts g           ON g.Id = x.Id
    INNER JOIN purchase.GoodsReceiptLines l       ON l.GoodsReceiptId = g.Id
    LEFT  JOIN purchase.PurchaseDocumentLines pol ON pol.Id = l.PoLineId
    LEFT  JOIN purchase.PurchaseDocuments po      ON po.Id = pol.DocumentId;
END

GO

