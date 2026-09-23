CREATE   PROCEDURE purchase.usp_LandedCostAdjustment_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT a.Id, a.DocumentNumber, a.DocumentDate, a.BranchId, b.BranchName, a.SourceInvoiceId, inv.DocumentNumber AS SourceInvoiceNumber,
           inv.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName, inv.WarehouseId, w.WarehouseName,
           a.Notes, a.Status, a.TotalChargesBase, a.InventoryPortionBase, a.CogsPortionBase,
           a.PostedAtUtc, a.PostedBy, pu.FullName AS PostedByName, a.CancelledAtUtc, a.CancelReason,
           a.CreatedAtUtc, a.CreatedBy, cu.FullName AS CreatedByName, a.UpdatedAtUtc, a.RowVersion
    FROM purchase.LandedCostAdjustments a
    INNER JOIN masterdata.Branches b ON b.Id = a.BranchId
    INNER JOIN purchase.PurchaseDocuments inv ON inv.Id = a.SourceInvoiceId
    INNER JOIN masterdata.Warehouses w ON w.Id = inv.WarehouseId
    INNER JOIN masterdata.Parties sp ON sp.Id = inv.SupplierId
    LEFT  JOIN security.Users cu ON cu.Id = a.CreatedBy
    LEFT  JOIN security.Users pu ON pu.Id = a.PostedBy
    WHERE a.Id = @Id;

    SELECT c.Id, c.LineNumber, c.ChargeTypeId, ct.ChargeCode, ct.ChargeName, c.Description, c.ProviderPartyId, pp.PartyName AS ProviderName, c.Reference,
           c.CurrencyId, cur.CurrencyCode, c.RateType, c.ExchangeRate, c.Amount, c.AmountBase, c.AllocationMethod, c.IncludeInLandedCost, c.IncludedInSupplierInvoice, c.Notes,
           AllocatedBase = (SELECT SUM(AmountBase) FROM purchase.PurchaseChargeAllocations x WHERE x.ChargeId = c.Id)
    FROM purchase.PurchaseCharges c
    INNER JOIN purchase.ChargeTypes ct ON ct.Id = c.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = c.CurrencyId
    LEFT  JOIN masterdata.Parties pp ON pp.Id = c.ProviderPartyId
    WHERE c.DocumentKind = N'LCA' AND c.DocumentId = @Id
    ORDER BY c.LineNumber;

    SELECT l.Id, l.PurchaseLineId, pl.LineNumber, l.ItemId, i.ItemCode, i.ItemName, l.WarehouseId, w.WarehouseCode,
           l.ReceivedBase, l.NetReceivedBase, l.RemainingBase, l.AllocatedBase, l.ExtraPerBaseUnit, l.InventoryPortionBase, l.CogsPortionBase,
           l.LandedCostBefore, l.LandedCostAfter
    FROM purchase.LandedCostAdjustmentLines l
    INNER JOIN purchase.PurchaseDocumentLines pl ON pl.Id = l.PurchaseLineId
    INNER JOIN inventory.Items i ON i.Id = l.ItemId
    INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
    WHERE l.AdjustmentId = @Id
    ORDER BY pl.LineNumber;
END

GO

