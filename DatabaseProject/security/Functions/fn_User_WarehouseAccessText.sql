--      codes sorted, comma-separated, or "Only: none"; at most 1,000 characters (the longest head that fits, then
--      " and {n} more"). NULL for an unknown user.
CREATE   FUNCTION security.fn_User_WarehouseAccessText (@UserId INT)
RETURNS NVARCHAR(1000)
AS
BEGIN
    DECLARE @All BIT = (SELECT AllWarehouses FROM security.Users WHERE Id = @UserId);
    IF @All IS NULL RETURN NULL;
    IF @All = 1 RETURN N'All warehouses';

    DECLARE @Codes TABLE (Seq INT NOT NULL PRIMARY KEY, Code NVARCHAR(20) NOT NULL);
    INSERT INTO @Codes (Seq, Code)
    SELECT ROW_NUMBER() OVER (ORDER BY w.WarehouseCode), w.WarehouseCode
    FROM security.UserWarehouses uw
    INNER JOIN masterdata.Warehouses w ON w.Id = uw.WarehouseId
    WHERE uw.UserId = @UserId;

    DECLARE @N INT = (SELECT COUNT(*) FROM @Codes);
    IF @N = 0 RETURN N'Only: none';

    DECLARE @Full NVARCHAR(MAX) = (SELECT STRING_AGG(CAST(Code AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY Seq) FROM @Codes);
    IF LEN(@Full) + 6 <= 1000 RETURN N'Only: ' + @Full;

    -- the first K codes that fit with " and {N - K} more" ("Only: " is 6 characters, each ", " 2)
    DECLARE @K INT = (SELECT MAX(c.Seq)
                      FROM (SELECT Seq, Running = SUM(LEN(Code) + 2) OVER (ORDER BY Seq ROWS UNBOUNDED PRECEDING) - 2
                            FROM @Codes) c
                      WHERE 6 + c.Running + LEN(N' and ' + CAST(@N - c.Seq AS NVARCHAR(10)) + N' more') <= 1000);
    RETURN N'Only: ' + (SELECT STRING_AGG(Code, N', ') WITHIN GROUP (ORDER BY Seq) FROM @Codes WHERE Seq <= @K)
         + N' and ' + CAST(@N - @K AS NVARCHAR(10)) + N' more';
END

GO

