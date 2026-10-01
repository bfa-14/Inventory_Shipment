/* ------------------------------------------------------------------ 2. Subtree */

-- A warehouse plus every descendant, with its depth below the one asked for (0 = itself).
-- Iterative rather than recursive, so it works at ANY depth without a MAXRECURSION hint.
CREATE   FUNCTION masterdata.fn_Warehouse_Subtree (@Id INT)
RETURNS @Subtree TABLE (Id INT PRIMARY KEY, Depth INT NOT NULL)
AS
BEGIN
    INSERT INTO @Subtree (Id, Depth) VALUES (@Id, 0);

    DECLARE @Depth INT = 0;

    WHILE EXISTS (SELECT 1 FROM @Subtree WHERE Depth = @Depth)
    BEGIN
        INSERT INTO @Subtree (Id, Depth)
        SELECT w.Id, @Depth + 1
        FROM masterdata.Warehouses w
        INNER JOIN @Subtree s ON s.Id = w.ParentId AND s.Depth = @Depth
        -- A row already seen cannot be added twice, so a cycle left by older data stops here
        -- instead of spinning forever.
        WHERE NOT EXISTS (SELECT 1 FROM @Subtree x WHERE x.Id = w.Id);

        SET @Depth = @Depth + 1;
    END

    RETURN;
END

GO

