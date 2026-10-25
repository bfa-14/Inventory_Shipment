--      comma-separated id list, as usp_User_SetRoles reads its roles), or is unrestricted; else "You have no access to
--      warehouse LKS-01: ask an administrator." / "... warehouses LKS-01 and LUB-01: ..." / "... warehouses KLW-01,
--      LKS-01 and LUB-01: ..." / "... warehouses KLW-01, LKS-01, LUB-01 and 2 more: ask an administrator." (codes
--      sorted). Ids that are not numbers or not warehouses are ignored: the families' own checks name them.
--      The rule is asked only of the warehouses named (each found by its id first, TOP (1) in an APPLY): with a plain
--      join the optimizer evaluated fn_User_CanUseWarehouse for EVERY warehouse of the table before joining (about 5
--      ms a call on 140 warehouses, against 0.1 ms), and the trigger calls this for every statement of a restricted
--      user.
CREATE   FUNCTION security.fn_User_WarehouseRefusal (@UserId INT, @WarehouseIds NVARCHAR(MAX))
RETURNS NVARCHAR(400)
AS
BEGIN
    IF @WarehouseIds IS NULL OR security.fn_User_IsUnrestricted(@UserId) = 1 RETURN NULL;
    DECLARE @Count INT, @C1 NVARCHAR(20), @C2 NVARCHAR(20), @C3 NVARCHAR(20);
    WITH refused AS
    (
        SELECT DISTINCT w.WarehouseCode
        FROM STRING_SPLIT(@WarehouseIds, N',') s
        CROSS APPLY (SELECT TOP (1) x.Id, x.WarehouseCode FROM masterdata.Warehouses x
                     WHERE x.Id = TRY_CAST(LTRIM(RTRIM(s.value)) AS INT)) w
        CROSS APPLY (SELECT CanUse = security.fn_User_CanUseWarehouse(@UserId, w.Id)) c
        WHERE c.CanUse = 0
    ),
    sorted AS
    (
        SELECT WarehouseCode, Rn = ROW_NUMBER() OVER (ORDER BY WarehouseCode), Cnt = COUNT(*) OVER ()
        FROM refused
    )
    SELECT @Count = MAX(Cnt),
           @C1 = MAX(CASE WHEN Rn = 1 THEN WarehouseCode END),
           @C2 = MAX(CASE WHEN Rn = 2 THEN WarehouseCode END),
           @C3 = MAX(CASE WHEN Rn = 3 THEN WarehouseCode END)
    FROM sorted;
    IF ISNULL(@Count, 0) = 0 RETURN NULL;
    RETURN N'You have no access to warehouse' + CASE WHEN @Count > 1 THEN N's' ELSE N'' END + N' '
         + CASE WHEN @Count = 1 THEN @C1
                WHEN @Count = 2 THEN @C1 + N' and ' + @C2
                WHEN @Count = 3 THEN @C1 + N', ' + @C2 + N' and ' + @C3
                ELSE @C1 + N', ' + @C2 + N', ' + @C3 + N' and ' + CAST(@Count - 3 AS NVARCHAR(10)) + N' more' END
         + N': ask an administrator.';
END

GO

