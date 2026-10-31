-- purchase.fn_PoLine_CommittedOutside (invoiced, or received / on draft goods receipts, outside containers: the larger)
-- in place of the "dir" subquery (invoiced only). InvoicedDirectBase keeps its name and its place in the sums
-- (Ordered - InvoicedDirect - LoadedElsewhere = MaxHere) and now holds that larger figure; its parts follow at the end:
-- InvoicedOutsideBase (the old meaning), ReceivedOutsideBase, InDraftReceiptsOutsideBase.
-- (54) PcPerContainer from logistics.fn_ItemPcsPerContainer (the one place).
CREATE   PROCEDURE logistics.usp_Container_AvailablePoLines
    @PurchaseOrderId INT           = NULL,
    @SupplierId      INT           = NULL,
    @Search          NVARCHAR(100) = NULL,    -- order number, item code or name
    @ContainerId     INT           = NULL,
    @Top             INT           = 200
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @Top IS NULL OR @Top < 1 SET @Top = 200;

    SELECT TOP (@Top)
           d.Id AS PurchaseOrderId, d.DocumentNumber AS PurchaseOrderNumber, d.DocumentDate AS OrderDate, d.Status AS OrderStatus,
           d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName,
           d.CurrencyId, cur.CurrencyCode, d.WarehouseId, w.WarehouseCode, w.WarehouseName,
           l.Id AS PoLineId, l.LineNumber AS PoLineNumber, l.ItemId, i.ItemCode, i.ItemName, i.Model, br.BrandName,
           l.ItemUnitId, ut.UnitTypeName, l.PackingFormula, l.Quantity AS OrderedQuantity,
           OrderedBase         = l.QuantityBase,
           InvoicedDirectBase  = ISNULL(dir.Qty, 0),
           LoadedElsewhereBase = ISNULL(oth.Qty, 0),
           LoadedHereBase      = ISNULL(here.Qty, 0),
           MaxHereBase         = l.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0),
           AvailableBase       = l.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0) - ISNULL(here.Qty, 0),
           l.UnitPrice, l.DiscountPercent,
           UnitValueBase = l.LineTotal / d.ExchangeRate / NULLIF(l.QuantityBase, 0),
           ItemOilQtyPerUnit = i.OilQtyPerUnit,
           PcPerContainer = cnt.PcsPerContainer,
           i.WeightKg, i.VolumeCbm,
           -- (65) the parts of InvoicedDirectBase (= the larger of invoiced, and received + on draft receipts, outside containers)
           InvoicedOutsideBase        = ISNULL(dir.InvoicedOutsideBase, 0),
           ReceivedOutsideBase        = ISNULL(dir.ReceivedOutsideBase, 0),
           InDraftReceiptsOutsideBase = ISNULL(dir.InDraftReceiptsOutsideBase, 0)
    FROM purchase.PurchaseDocumentLines l
    INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
    INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Parties sp        ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies cur    ON cur.Id = d.CurrencyId
    INNER JOIN masterdata.Warehouses w      ON w.Id = d.WarehouseId
    INNER JOIN inventory.Items i            ON i.Id = l.ItemId
    INNER JOIN masterdata.Brands br         ON br.Id = i.BrandId
    INNER JOIN inventory.ItemUnits iu       ON iu.Id = l.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut      ON ut.Id = iu.UnitTypeId
    OUTER APPLY purchase.fn_PoLine_CommittedOutside(l.Id, NULL) dir
    OUTER APPLY (SELECT Qty = SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                 INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                 WHERE cl.PoLineId = l.Id AND c.Status <> 8 AND (@ContainerId IS NULL OR cl.ContainerId <> @ContainerId)) oth
    OUTER APPLY (SELECT Qty = SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                 WHERE cl.PoLineId = l.Id AND cl.ContainerId = @ContainerId) here
    CROSS APPLY logistics.fn_ItemPcsPerContainer(l.ItemId) cnt
    WHERE dt.Code = N'PO' AND d.Status = 2
      AND (@PurchaseOrderId IS NULL OR d.Id = @PurchaseOrderId)
      AND (@SupplierId IS NULL OR d.SupplierId = @SupplierId)
      AND (@Search IS NULL OR d.DocumentNumber LIKE N'%' + @Search + N'%' OR i.ItemCode LIKE N'%' + @Search + N'%'
           OR i.ItemName LIKE N'%' + @Search + N'%' OR sp.PartyName LIKE N'%' + @Search + N'%')
      AND (l.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0) - ISNULL(here.Qty, 0) > 0 OR ISNULL(here.Qty, 0) > 0)
    ORDER BY d.DocumentDate DESC, d.Id DESC, l.LineNumber;
END

GO

