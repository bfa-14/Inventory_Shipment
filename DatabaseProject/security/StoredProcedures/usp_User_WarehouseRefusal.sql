/* ================================================================== 6. The security procedures */

-- (92) MAY THE USER USE THESE WAREHOUSES? (the API's early check, IWarehouseAccessService; read-only, no cache).
--      1: one row - IsUnrestricted (fn_User_IsUnrestricted), Message (the sentence for every id of @WarehouseIds the user
--         may not use, NULL when none).
--      2: one row per id the user may NOT use - WarehouseId, Message (its own one-warehouse sentence): the import's
--         per-row answer. Always returned; empty for an unrestricted user or without ids.
--      For an unrestricted user: one primary-key seek.
CREATE   PROCEDURE security.usp_User_WarehouseRefusal
    @UserId       INT,
    @WarehouseIds NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Unrestricted BIT = security.fn_User_IsUnrestricted(@UserId);
    SET @WarehouseIds = NULLIF(LTRIM(RTRIM(@WarehouseIds)), N'');

    SELECT IsUnrestricted = @Unrestricted,
           Message        = CAST(CASE WHEN @Unrestricted = 1 OR @WarehouseIds IS NULL THEN NULL
                                      ELSE security.fn_User_WarehouseRefusal(@UserId, @WarehouseIds) END AS NVARCHAR(400));

    IF @Unrestricted = 1 OR @WarehouseIds IS NULL
        SELECT WarehouseId = CAST(NULL AS INT), Message = CAST(NULL AS NVARCHAR(400)) WHERE 1 = 0;
    ELSE
        -- each id found first, then the rule (see fn_User_WarehouseRefusal: never the rule for the whole table)
        SELECT x.WarehouseId,
               Message = CAST(security.fn_User_WarehouseRefusal(@UserId, CAST(x.WarehouseId AS NVARCHAR(12))) AS NVARCHAR(400))
        FROM (SELECT DISTINCT WarehouseId = w.Id
              FROM STRING_SPLIT(@WarehouseIds, N',') s
              CROSS APPLY (SELECT TOP (1) v.Id FROM masterdata.Warehouses v WHERE v.Id = TRY_CAST(LTRIM(RTRIM(s.value)) AS INT)) w) x
        CROSS APPLY (SELECT CanUse = security.fn_User_CanUseWarehouse(@UserId, x.WarehouseId)) c
        WHERE c.CanUse = 0
        ORDER BY x.WarehouseId;
END

GO

