--      Inventory In cancel (62007) when the stock that document brought is short in its warehouse. NULL when no posted,
--      not reversed dispatch took the item out of that warehouse (posted at or after @SinceUtc when given: the
--      document's own posting). Otherwise the pieces those dispatches took (@Pcs) and up to two of their numbers,
--      latest first: when they cover the shortfall (what the document brought less what is left), " 80 pcs were moved
--      by TRD-BR-003-000004: transfer them back first."; when they do not (transferring back would not be enough),
--      " (10 of them were moved by TRD-BR-003-000004.)". Read only on a refusal: no index of its own.
CREATE   FUNCTION inventory.fn_Transfer_MovedOutNote (@ItemId INT, @WarehouseId INT, @SinceUtc DATETIME2(3), @ShortfallBase INT)
RETURNS NVARCHAR(300)
AS
BEGIN
    DECLARE @Pcs INT, @Count INT, @List NVARCHAR(200);

    SELECT @Pcs = SUM(d.Pcs), @Count = COUNT(*)
    FROM (SELECT p.Id, Pcs = SUM(pl.QuantityBase)
          FROM inventory.TransferPostings p
          INNER JOIN inventory.TransferPostingLines pl ON pl.PostingId = p.Id
          WHERE p.Kind = N'Dispatch' AND p.Status = 2 AND p.FromWarehouseId = @WarehouseId AND pl.ItemId = @ItemId
            AND (@SinceUtc IS NULL OR p.PostedAtUtc >= @SinceUtc)
          GROUP BY p.Id) d;

    IF ISNULL(@Count, 0) = 0 OR ISNULL(@Pcs, 0) <= 0 RETURN NULL;

    SELECT @List = STRING_AGG(t.DocumentNumber, N', ') WITHIN GROUP (ORDER BY t.PostedAtUtc DESC, t.Id DESC)
    FROM (SELECT TOP (2) p.Id, p.DocumentNumber, p.PostedAtUtc
          FROM inventory.TransferPostings p
          WHERE p.Kind = N'Dispatch' AND p.Status = 2 AND p.FromWarehouseId = @WarehouseId
            AND (@SinceUtc IS NULL OR p.PostedAtUtc >= @SinceUtc)
            AND EXISTS (SELECT 1 FROM inventory.TransferPostingLines pl WHERE pl.PostingId = p.Id AND pl.ItemId = @ItemId)
          ORDER BY p.PostedAtUtc DESC, p.Id DESC) t;

    SET @List = ISNULL(@List, N'a transfer')
              + CASE WHEN @Count > 2 THEN N' and ' + CAST(@Count - 2 AS NVARCHAR(10)) + N' more' ELSE N'' END;

    RETURN CASE WHEN @Pcs >= ISNULL(@ShortfallBase, 0)
                THEN N' ' + CAST(@Pcs AS NVARCHAR(20)) + N' pcs were moved by ' + @List + N': transfer them back first.'
                ELSE N' (' + CAST(@Pcs AS NVARCHAR(20)) + N' of them were moved by ' + @List + N'.)' END;
END

GO

