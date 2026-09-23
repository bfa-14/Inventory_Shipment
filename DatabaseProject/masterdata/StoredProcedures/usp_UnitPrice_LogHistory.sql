/* ================================================================== 2. Helpers */

-- Writes one history row for a price (snapshots names so the log stays readable after deletions).
CREATE   PROCEDURE masterdata.usp_UnitPrice_LogHistory
    @UnitPriceId INT,
    @ChangeType  TINYINT,          -- 1 Created, 2 PriceChanged, 3 Activated, 4 Deactivated, 5 Deleted
    @OldPrice    DECIMAL(18,4) = NULL,
    @NewPrice    DECIMAL(18,4) = NULL,
    @UserId      INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO masterdata.UnitPriceHistory
        (UnitPriceId, BranchId, BranchName, ItemId, ItemCode, ItemName, ItemUnitId, UnitTypeName,
         PriceListId, PriceListName, CurrencyCode, OldPrice, NewPrice, ChangeType, ChangedBy, ChangedByName)
    SELECT up.Id, up.BranchId, ISNULL(b.BranchName, N'All Branches'), up.ItemId, i.ItemCode, i.ItemName,
           up.ItemUnitId, ut.UnitTypeName, up.PriceListId, pl.PriceListName, c.CurrencyCode,
           @OldPrice, @NewPrice, @ChangeType, @UserId, ISNULL(u.FullName, N'System')
    FROM masterdata.UnitPrices up
    INNER JOIN inventory.Items i        ON i.Id  = up.ItemId
    INNER JOIN inventory.ItemUnits iu   ON iu.Id = up.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut  ON ut.Id = iu.UnitTypeId
    INNER JOIN masterdata.PriceLists pl ON pl.Id = up.PriceListId
    INNER JOIN masterdata.Currencies c  ON c.Id  = pl.CurrencyId
    LEFT  JOIN masterdata.Branches b    ON b.Id  = up.BranchId
    LEFT  JOIN security.Users u         ON u.Id  = @UserId
    WHERE up.Id = @UnitPriceId;
END

GO

