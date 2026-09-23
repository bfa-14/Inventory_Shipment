CREATE   PROCEDURE inventory.usp_DocumentType_List
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, Code, Name, Family, StockDirection, NumberPrefix, NextNumber, NumberLength, NumberOnPost,
           RequiresReason, DefaultPricing, PriceEditable, NumberPerBranch, YearInNumber, IsActive, UpdatedAtUtc, UpdatedBy, RowVersion
    FROM inventory.DocumentTypes
    ORDER BY Family, Code;
END

GO

