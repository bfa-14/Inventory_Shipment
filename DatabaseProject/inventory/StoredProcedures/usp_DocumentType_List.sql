/* ================================================================== 2. Configuration > Document Types: the switches */

-- Re-created (79) from the body of script 66: + the three switches.
CREATE   PROCEDURE inventory.usp_DocumentType_List
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, Code, Name, Family, StockDirection, NumberPrefix, NextNumber, NumberLength, NumberOnPost,
           RequiresReason, DefaultPricing, PriceEditable, NumberPerBranch, YearInNumber, IsActive, UpdatedAtUtc, UpdatedBy, RowVersion,
           BivacItemsOnly,  -- (66) 1 = every line must be a BIVAC item
           -- (79) what the type does; each means something on one type only (the others keep the default)
           AffectsItemCost,       -- PINV: its price becomes the cost of the goods received against it
           AffectsOnHand,         -- PINV: posting it receives its goods with a goods receipt
           AutoCreateOnDelivery   -- GRN: a completed Delivery movement drafts one per container
    FROM inventory.DocumentTypes
    ORDER BY Family, Code;
END

GO

