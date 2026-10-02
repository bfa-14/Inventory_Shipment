/* ================================================================== 6. Order lines that can still be loaded */

-- Re-created (43) from the body of script 27: the lines of an invoice shipped in containers are not "invoiced directly".
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
           PcPerContainer = cnt.PackingFormula,
           i.WeightKg, i.VolumeCbm
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
    OUTER APPLY (SELECT Qty = SUM(x.QuantityBase) FROM purchase.PurchaseDocumentLines x
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
                 WHERE x.SourceLineId = l.Id AND x.ContainerLineId IS NULL AND xd.Status IN (1, 2, 4) AND xd.ReceiptMode <> 2) dir
    OUTER APPLY (SELECT Qty = SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                 INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                 WHERE cl.PoLineId = l.Id AND c.Status <> 8 AND (@ContainerId IS NULL OR cl.ContainerId <> @ContainerId)) oth
    OUTER APPLY (SELECT Qty = SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                 WHERE cl.PoLineId = l.Id AND cl.ContainerId = @ContainerId) here
    OUTER APPLY (SELECT TOP (1) u.PackingFormula FROM inventory.ItemUnits u
                 INNER JOIN masterdata.UnitTypes t ON t.Id = u.UnitTypeId
                 WHERE u.ItemId = l.ItemId AND t.IsContainer = 1) cnt
    WHERE dt.Code = N'PO' AND d.Status = 2
      AND (@PurchaseOrderId IS NULL OR d.Id = @PurchaseOrderId)
      AND (@SupplierId IS NULL OR d.SupplierId = @SupplierId)
      AND (@Search IS NULL OR d.DocumentNumber LIKE N'%' + @Search + N'%' OR i.ItemCode LIKE N'%' + @Search + N'%'
           OR i.ItemName LIKE N'%' + @Search + N'%' OR sp.PartyName LIKE N'%' + @Search + N'%')
      AND (l.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0) - ISNULL(here.Qty, 0) > 0 OR ISNULL(here.Qty, 0) > 0)
    ORDER BY d.DocumentDate DESC, d.Id DESC, l.LineNumber;
END

GO

