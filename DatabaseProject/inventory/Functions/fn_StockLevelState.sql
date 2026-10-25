/* ================================================================== 5. Where a warehouse stands, Fill to Max, the import's judgement */

/* (91) THE STATUS OF A LEVEL, from where its warehouse stands (S8, S9; M6: one formula, read by every reader below):
     Projected  = On hand + On the way in + To come in - To go out
     Status     = the first that applies: NoLevel (no Min); BelowMin (Projected < Min); Covered (On hand < Min <=
                  Projected, L4); AboveMax (Max set and Projected > Max); Ok
     ToReachMax = (Max, else Min) - Projected when Below Min, else 0 - worked out in BIGINT and capped at the INT
                  ceiling, so no stored figure can make a reader fail (a level is at most 1,000,000,000 pcs anyway). */
CREATE   FUNCTION inventory.fn_StockLevelState
(
    @OnHandBase        INT,
    @InOnTheWayBase    INT,
    @InToDispatchBase  INT,
    @OutToDispatchBase INT,
    @MinBase           INT,
    @MaxBase           INT
)
RETURNS TABLE
AS
RETURN
(
    SELECT p.ProjectedBase,
           Status         = CAST(CASE WHEN @MinBase IS NULL                                  THEN N'NoLevel'
                                      WHEN p.ProjectedBase < @MinBase                        THEN N'BelowMin'
                                      WHEN @OnHandBase < @MinBase                            THEN N'Covered'
                                      WHEN @MaxBase IS NOT NULL AND p.ProjectedBase > @MaxBase THEN N'AboveMax'
                                      ELSE N'Ok' END AS NVARCHAR(10)),
           ToReachMaxBase = CAST(CASE WHEN @MinBase IS NULL OR p.ProjectedBase >= @MinBase THEN 0
                                      WHEN CAST(ISNULL(@MaxBase, @MinBase) AS BIGINT) - p.ProjectedBase > 2147483647 THEN 2147483647
                                      ELSE CAST(ISNULL(@MaxBase, @MinBase) AS BIGINT) - p.ProjectedBase END AS INT)
    FROM (SELECT ProjectedBase = @OnHandBase + @InOnTheWayBase + @InToDispatchBase - @OutToDispatchBase) p
);

GO

