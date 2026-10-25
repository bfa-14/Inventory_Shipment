--      without a number "draft #{Id}"}{ and n more}): Fill to Max does not count them." - one row, or none.
CREATE   FUNCTION inventory.fn_TransferFill_OtherOrdersWarning
(
    @ToWarehouseId  INT,
    @ToCode         NVARCHAR(20),
    @ExcludeOrderId INT,
    @ItemIds        logistics.tvp_IdList READONLY
)
RETURNS TABLE
AS
RETURN
(
    WITH other AS
    (
        SELECT o.Id, Label = ISNULL(o.DocumentNumber, N'draft #' + CAST(o.Id AS NVARCHAR(12)))
        FROM inventory.TransferOrders o
        WHERE o.ToWarehouseId = @ToWarehouseId AND o.Status IN (1, 4)
          AND (@ExcludeOrderId IS NULL OR o.Id <> @ExcludeOrderId)
          AND EXISTS (SELECT 1 FROM inventory.TransferOrderLines l
                      WHERE l.TransferOrderId = o.Id AND l.ItemId IN (SELECT x.Id FROM @ItemIds x))
    )
    SELECT Message = N'Other draft or waiting transfer orders to ' + ISNULL(@ToCode, N'the destination')
                     + N' hold some of these items too (' + ISNULL(f.List, N'')
                     + CASE WHEN c.N > 3 THEN N' and ' + CAST(c.N - 3 AS NVARCHAR(10)) + N' more' ELSE N'' END
                     + N'): Fill to Max does not count them.'
    FROM (SELECT N = COUNT(*) FROM other) c
    CROSS APPLY (SELECT List = STRING_AGG(t.Label, N', ') WITHIN GROUP (ORDER BY t.Id)
                 FROM (SELECT TOP (3) other.Id, other.Label FROM other ORDER BY other.Id) t) f
    WHERE c.N > 0
);

GO

