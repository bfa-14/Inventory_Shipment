/* ==================================================================================================
   34: Specification suggestions come from the invoices, not from the item
   --------------------------------------------------------------------------------------------------
   The line's Specification is free text. What the dropdown offers is the DISTINCT text already used
   for that item on other sales invoice lines, so the second invoice for an item can pick what the
   first one typed without anybody maintaining a list.

   An earlier draft of this feature kept a Specification on inventory.ItemUnits. Nothing reads it any
   more - the suggestions come from history - so it is dropped here. The guard makes that safe to run
   on a database that never had it.
   ================================================================================================== */

IF COL_LENGTH('inventory.ItemUnits', 'Specification') IS NOT NULL
BEGIN
    ALTER TABLE inventory.ItemUnits DROP COLUMN Specification;
    PRINT 'Dropped inventory.ItemUnits.Specification - suggestions come from the invoices now';
END
GO

/* The specifications used for one item, most recently used first, for the line's dropdown. */
CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_ItemSpecifications
    @ItemId INT,
    @Top    INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    IF @Top IS NULL OR @Top < 1 SET @Top = 50;
    IF @Top > 200 SET @Top = 200;

    /* GROUPED, NOT DISTINCT-ORDERED-BY-ID: the same text may sit on many lines, and the newest line
       carrying it decides where it sits in the list. Blank and whitespace-only values never made it
       into the column, but NULL lines are simply absent. */
    SELECT TOP (@Top) l.Specification
    FROM sales.SalesDocumentLines l
    WHERE l.ItemId = @ItemId
      AND l.Specification IS NOT NULL
    GROUP BY l.Specification
    ORDER BY MAX(l.Id) DESC;
END
GO
