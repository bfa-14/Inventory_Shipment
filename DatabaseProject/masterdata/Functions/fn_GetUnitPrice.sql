/* ================================================================== 5. Price resolution (for sales / invoices later) */

-- Selling price for a unit on a price list at a branch:
-- 1. active branch-specific price  2. active "All Branches" price  3. NULL (no price defined).
CREATE   FUNCTION masterdata.fn_GetUnitPrice
(
    @ItemUnitId  INT,
    @PriceListId INT,
    @BranchId    INT      -- NULL = look only at the "All Branches" price
)
RETURNS DECIMAL(18,4)
AS
BEGIN
    DECLARE @Price DECIMAL(18,4);

    IF @BranchId IS NOT NULL
        SELECT @Price = Price FROM masterdata.UnitPrices
        WHERE ItemUnitId = @ItemUnitId AND PriceListId = @PriceListId AND BranchId = @BranchId AND IsActive = 1;

    IF @Price IS NULL
        SELECT @Price = Price FROM masterdata.UnitPrices
        WHERE ItemUnitId = @ItemUnitId AND PriceListId = @PriceListId AND BranchId IS NULL AND IsActive = 1;

    RETURN @Price;
END

GO

