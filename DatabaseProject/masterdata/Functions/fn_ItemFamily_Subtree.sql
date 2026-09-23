/* ------------------------------------------------------------------ 2. Subtree function (loop-based, no depth limit) */

-- A family plus every descendant. Iterative, so it works at ANY depth.
CREATE   FUNCTION masterdata.fn_ItemFamily_Subtree (@Id INT)
RETURNS @Result TABLE (Id INT PRIMARY KEY, ParentId INT NULL, [Level] INT NOT NULL)
AS
BEGIN
    INSERT INTO @Result (Id, ParentId, [Level])
    SELECT Id, ParentId, [Level] FROM masterdata.ItemFamilies WHERE Id = @Id;

    WHILE @@ROWCOUNT > 0
    BEGIN
        INSERT INTO @Result (Id, ParentId, [Level])
        SELECT f.Id, f.ParentId, f.[Level]
        FROM masterdata.ItemFamilies f
        INNER JOIN @Result r ON r.Id = f.ParentId
        WHERE NOT EXISTS (SELECT 1 FROM @Result x WHERE x.Id = f.Id);
    END

    RETURN;
END

GO

