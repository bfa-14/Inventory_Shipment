/* (91) THE RESULT SENTENCE OF FILL TO MAX, ADD ITEMS BELOW MIN AND CREATE TRANSFER ORDER (3.4.4), built in one place:
     {Head}{F} {unit}{s} {verb}[ ({C} capped by what {From} has available)][, {S} skipped ({parts})]
     [, {N} not {verb} (nothing available at {From})].[ No quantity changed.]
   Fill: "Fill to Max: ", line, filled; Add: "Add items below Min: ", item, added. {s} = s unless 1; S = every skip
   outcome; {parts} in this order, each when above 0: at or above Min, without a Min at {To}, covered by other lines of
   the item, inactive, already on the order. @NoQuantityChanged: an apply that filled lines and changed none. */
CREATE   FUNCTION inventory.fn_TransferFill_Message
(
    @Mode              NVARCHAR(10),    -- Fill | Add
    @FromCode          NVARCHAR(20),
    @ToCode            NVARCHAR(20),
    @Filled            INT,
    @Capped            INT,
    @AtOrAboveMin      INT,
    @NoLevel           INT,
    @Covered           INT,
    @Inactive          INT,
    @OnOrder           INT,
    @NotFilled         INT,
    @NoQuantityChanged BIT
)
RETURNS NVARCHAR(500)
AS
BEGIN
    DECLARE @Add  BIT = CASE WHEN @Mode = N'Add' THEN 1 ELSE 0 END,
            @From NVARCHAR(20) = ISNULL(@FromCode, N'the source'),
            @To   NVARCHAR(20) = ISNULL(@ToCode, N'the destination');
    DECLARE @Verb NVARCHAR(10) = CASE WHEN @Add = 1 THEN N'added' ELSE N'filled' END;

    SELECT @Filled = ISNULL(@Filled, 0), @Capped = ISNULL(@Capped, 0), @AtOrAboveMin = ISNULL(@AtOrAboveMin, 0),
           @NoLevel = ISNULL(@NoLevel, 0), @Covered = ISNULL(@Covered, 0), @Inactive = ISNULL(@Inactive, 0),
           @OnOrder = ISNULL(@OnOrder, 0), @NotFilled = ISNULL(@NotFilled, 0);

    DECLARE @Skipped INT = @AtOrAboveMin + @NoLevel + @Covered + @Inactive + @OnOrder;
    DECLARE @Parts NVARCHAR(300) =
          CASE WHEN @AtOrAboveMin > 0 THEN N', ' + CAST(@AtOrAboveMin AS NVARCHAR(10)) + N' at or above Min' ELSE N'' END
        + CASE WHEN @NoLevel > 0      THEN N', ' + CAST(@NoLevel AS NVARCHAR(10)) + N' without a Min at ' + @To ELSE N'' END
        + CASE WHEN @Covered > 0      THEN N', ' + CAST(@Covered AS NVARCHAR(10)) + N' covered by other lines of the item' ELSE N'' END
        + CASE WHEN @Inactive > 0     THEN N', ' + CAST(@Inactive AS NVARCHAR(10)) + N' inactive' ELSE N'' END
        + CASE WHEN @OnOrder > 0      THEN N', ' + CAST(@OnOrder AS NVARCHAR(10)) + N' already on the order' ELSE N'' END;

    RETURN CASE WHEN @Add = 1 THEN N'Add items below Min: ' ELSE N'Fill to Max: ' END
         + CAST(@Filled AS NVARCHAR(10)) + N' ' + CASE WHEN @Add = 1 THEN N'item' ELSE N'line' END
         + CASE WHEN @Filled = 1 THEN N'' ELSE N's' END + N' ' + @Verb
         + CASE WHEN @Capped > 0 THEN N' (' + CAST(@Capped AS NVARCHAR(10)) + N' capped by what ' + @From + N' has available)' ELSE N'' END
         + CASE WHEN @Skipped > 0 THEN N', ' + CAST(@Skipped AS NVARCHAR(10)) + N' skipped (' + STUFF(@Parts, 1, 2, N'') + N')' ELSE N'' END
         + CASE WHEN @NotFilled > 0 THEN N', ' + CAST(@NotFilled AS NVARCHAR(10)) + N' not ' + @Verb + N' (nothing available at ' + @From + N')' ELSE N'' END
         + N'.'
         + CASE WHEN @NoQuantityChanged = 1 THEN N' No quantity changed.' ELSE N'' END;
END

GO

