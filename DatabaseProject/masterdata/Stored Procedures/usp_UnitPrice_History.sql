-- row, or the key columns directly (works even after the row was deleted).
CREATE   PROCEDURE masterdata.usp_UnitPrice_History
    @UnitPriceId INT = NULL,
    @ItemUnitId  INT = NULL,
    @PriceListId INT = NULL,
    @BranchId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @UnitPriceId IS NOT NULL
        SELECT @ItemUnitId = ItemUnitId, @PriceListId = PriceListId, @BranchId = BranchId
        FROM masterdata.UnitPrices WHERE Id = @UnitPriceId;

    IF @ItemUnitId IS NULL OR @PriceListId IS NULL
        THROW 59000, 'Item unit and price list are required to read the price history.', 1;

    SELECT h.Id, h.UnitPriceId, h.BranchId, h.BranchName, h.ItemId, h.ItemCode, h.ItemName,
           h.ItemUnitId, h.UnitTypeName, h.PriceListId, h.PriceListName, h.CurrencyCode,
           h.OldPrice, h.NewPrice, h.ChangeType,
           CASE h.ChangeType WHEN 1 THEN N'Created' WHEN 2 THEN N'Price Changed' WHEN 3 THEN N'Activated'
                             WHEN 4 THEN N'Deactivated' WHEN 5 THEN N'Deleted' END AS ChangeTypeName,
           h.ChangedBy, h.ChangedByName, h.ChangedAtUtc
    FROM masterdata.UnitPriceHistory h
    WHERE h.ItemUnitId = @ItemUnitId AND h.PriceListId = @PriceListId
      AND ((h.BranchId IS NULL AND @BranchId IS NULL) OR h.BranchId = @BranchId)
    ORDER BY h.ChangedAtUtc DESC, h.Id DESC;
END