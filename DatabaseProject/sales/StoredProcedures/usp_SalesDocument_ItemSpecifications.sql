/* The specifications used for one item, most recently used first, for the line's dropdown. */
CREATE   PROCEDURE sales.usp_SalesDocument_ItemSpecifications
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

