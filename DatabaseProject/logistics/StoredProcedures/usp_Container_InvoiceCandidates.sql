CREATE   PROCEDURE logistics.usp_Container_InvoiceCandidates
    @PurchaseOrderId INT = NULL,
    @ContainerId     INT = NULL,
    @IncludeAll      BIT = 0      -- 1 = also the lines already fully invoiced
AS
BEGIN
    SET NOCOUNT ON;
    IF @PurchaseOrderId IS NULL AND @ContainerId IS NULL THROW 69000, 'Give a purchase order or a container.', 1;

    SELECT cl.Id AS ContainerLineId, cl.ContainerId, c.ContainerRef, c.ContainerNo, c.Status AS ContainerStatus, cl.LineNumber,
           cl.PurchaseOrderId, d.DocumentNumber AS PurchaseOrderNumber, d.Status AS OrderStatus,
           d.SupplierId, sp.PartyName AS SupplierName, d.CurrencyId, cur.CurrencyCode,
           cl.PoLineId, pol.LineNumber AS PoLineNumber, cl.ItemId, i.ItemCode, i.ItemName,
           PoItemUnitId = pol.ItemUnitId, PoUnitTypeName = ut.UnitTypeName, PoPackingFormula = pol.PackingFormula,
           pol.UnitPrice, pol.DiscountPercent,
           LoadedBase         = cl.QuantityBase,
           InvoicedPostedBase = ISNULL(q.Posted, 0),
           InvoicedDraftBase  = ISNULL(q.Draft, 0),
           AvailableBase      = cl.QuantityBase - ISNULL(q.Posted, 0) - ISNULL(q.Draft, 0),
           OrderLineRemainingBase = pol.QuantityBase - pol.ReceivedQuantityBase - ISNULL(od.Draft, 0)
    FROM logistics.ContainerLines cl
    INNER JOIN logistics.Containers c             ON c.Id = cl.ContainerId
    INNER JOIN purchase.PurchaseDocuments d       ON d.Id = cl.PurchaseOrderId
    INNER JOIN masterdata.Parties sp              ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies cur          ON cur.Id = d.CurrencyId
    INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = cl.PoLineId
    INNER JOIN inventory.ItemUnits iu             ON iu.Id = pol.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut            ON ut.Id = iu.UnitTypeId
    INNER JOIN inventory.Items i                  ON i.Id = cl.ItemId
    OUTER APPLY (SELECT Posted = SUM(CASE WHEN x.Status IN (2, 4) THEN pil.QuantityBase END),
                        Draft  = SUM(CASE WHEN x.Status = 1 THEN pil.QuantityBase END)
                 FROM purchase.PurchaseDocumentLines pil
                 INNER JOIN purchase.PurchaseDocuments x ON x.Id = pil.DocumentId
                 WHERE pil.ContainerLineId = cl.Id) q
    OUTER APPLY (SELECT Draft = SUM(pil.QuantityBase)
                 FROM purchase.PurchaseDocumentLines pil
                 INNER JOIN purchase.PurchaseDocuments x ON x.Id = pil.DocumentId
                 WHERE pil.SourceLineId = pol.Id AND x.Status = 1) od
    WHERE c.Status NOT IN (6, 7, 8)
      AND (@PurchaseOrderId IS NULL OR cl.PurchaseOrderId = @PurchaseOrderId)
      AND (@ContainerId IS NULL OR cl.ContainerId = @ContainerId)
      AND (@IncludeAll = 1 OR cl.QuantityBase - ISNULL(q.Posted, 0) - ISNULL(q.Draft, 0) > 0)
    ORDER BY d.DocumentNumber, c.ContainerRef, cl.LineNumber;
END

GO

