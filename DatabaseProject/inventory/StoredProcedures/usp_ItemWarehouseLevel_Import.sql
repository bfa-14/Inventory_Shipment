/* (91) THE IMPORT (S13): every Valid and Warning row in ONE transaction, judged again by the same function; Error and
   Unchanged rows skipped. The levels the file sets or removes are read again WITH (UPDLOCK, HOLDLOCK) inside the
   transaction (the judgement read them without a lock), so a level added, changed or removed meanwhile is counted as
   it stands now. Audit Source Import with the file name. Result 1, per row: RowNumber, Outcome (Added | Changed |
   Removed | Unchanged | Skipped), Message (the judgement's; a Skipped row's error). Result 2: the counts and the
   sentence. A 20,000-row import holds its locks until it commits: readers of the levels wait a few seconds. */
CREATE   PROCEDURE inventory.usp_ItemWarehouseLevel_Import
    @Rows     inventory.tvp_ItemWarehouseLevelImport READONLY,
    @FileName NVARCHAR(260) = NULL,
    @UserId   INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @FileName = NULLIF(LTRIM(RTRIM(@FileName)), N'');

    CREATE TABLE #j
    (
        RowNumber INT NOT NULL PRIMARY KEY, Status NVARCHAR(10) NOT NULL, Action NVARCHAR(10) NOT NULL, Message NVARCHAR(500) NULL,
        ItemId INT NULL, WarehouseId INT NULL, MinQuantityBase INT NULL, MaxQuantityBase INT NULL, Outcome NVARCHAR(10) NULL
    );
    CREATE TABLE #cur
    (
        ItemId INT NOT NULL, WarehouseId INT NOT NULL, MinQuantityBase INT NOT NULL, MaxQuantityBase INT NULL,
        PRIMARY KEY (ItemId, WarehouseId)
    );

    DECLARE @Added INT, @Changed INT, @Removed INT, @Unchanged INT, @Skipped INT, @Message NVARCHAR(400), @Done NVARCHAR(200), @Left NVARCHAR(200);

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO #j (RowNumber, Status, Action, Message, ItemId, WarehouseId, MinQuantityBase, MaxQuantityBase)
        SELECT j.RowNumber, j.Status, j.Action, j.Message, j.ItemId, j.WarehouseId, j.MinQuantityBase, j.MaxQuantityBase
        FROM inventory.fn_ItemWarehouseLevel_ImportJudge(@Rows) j;

        INSERT INTO #cur (ItemId, WarehouseId, MinQuantityBase, MaxQuantityBase)
        SELECT lv.ItemId, lv.WarehouseId, lv.MinQuantityBase, lv.MaxQuantityBase
        FROM inventory.ItemWarehouseLevels lv WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN #j j ON j.ItemId = lv.ItemId AND j.WarehouseId = lv.WarehouseId
        WHERE j.Status IN (N'Valid', N'Warning') AND j.Action IN (N'Set', N'Remove');

        UPDATE j
        SET Outcome = CASE WHEN j.Status = N'Error'                                   THEN N'Skipped'
                           WHEN j.Status NOT IN (N'Valid', N'Warning')                THEN N'Unchanged'
                           WHEN j.Action = N'Set' AND c.ItemId IS NULL                THEN N'Added'
                           WHEN j.Action = N'Set' AND (c.MinQuantityBase <> j.MinQuantityBase
                                                      OR ISNULL(c.MaxQuantityBase, -1) <> ISNULL(j.MaxQuantityBase, -1)) THEN N'Changed'
                           WHEN j.Action = N'Remove' AND c.ItemId IS NOT NULL         THEN N'Removed'
                           ELSE N'Unchanged' END
        FROM #j j
        LEFT JOIN #cur c ON c.ItemId = j.ItemId AND c.WarehouseId = j.WarehouseId;

        INSERT INTO inventory.ItemWarehouseLevelAudit (ItemId, WarehouseId, Action, OldMinBase, OldMaxBase, NewMinBase, NewMaxBase, Source, FileName, UserId)
        SELECT j.ItemId, j.WarehouseId, j.Outcome, c.MinQuantityBase, c.MaxQuantityBase,
               CASE WHEN j.Outcome = N'Removed' THEN NULL ELSE j.MinQuantityBase END,
               CASE WHEN j.Outcome = N'Removed' THEN NULL ELSE j.MaxQuantityBase END,
               N'Import', @FileName, @UserId
        FROM #j j
        LEFT JOIN #cur c ON c.ItemId = j.ItemId AND c.WarehouseId = j.WarehouseId
        WHERE j.Outcome IN (N'Added', N'Changed', N'Removed')
        ORDER BY j.RowNumber;

        MERGE inventory.ItemWarehouseLevels WITH (HOLDLOCK) AS t
        USING (SELECT j.ItemId, j.WarehouseId, j.MinQuantityBase, j.MaxQuantityBase FROM #j j WHERE j.Outcome IN (N'Added', N'Changed')) AS s
        ON t.ItemId = s.ItemId AND t.WarehouseId = s.WarehouseId
        WHEN MATCHED THEN
            UPDATE SET MinQuantityBase = s.MinQuantityBase, MaxQuantityBase = s.MaxQuantityBase,
                       UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (ItemId, WarehouseId, MinQuantityBase, MaxQuantityBase, CreatedBy, UpdatedBy)
            VALUES (s.ItemId, s.WarehouseId, s.MinQuantityBase, s.MaxQuantityBase, @UserId, @UserId);

        DELETE lv
        FROM inventory.ItemWarehouseLevels lv
        INNER JOIN #j j ON j.ItemId = lv.ItemId AND j.WarehouseId = lv.WarehouseId
        WHERE j.Outcome = N'Removed';

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT @Added     = ISNULL(SUM(CASE WHEN Outcome = N'Added'     THEN 1 ELSE 0 END), 0),
           @Changed   = ISNULL(SUM(CASE WHEN Outcome = N'Changed'   THEN 1 ELSE 0 END), 0),
           @Removed   = ISNULL(SUM(CASE WHEN Outcome = N'Removed'   THEN 1 ELSE 0 END), 0),
           @Unchanged = ISNULL(SUM(CASE WHEN Outcome = N'Unchanged' THEN 1 ELSE 0 END), 0),
           @Skipped   = ISNULL(SUM(CASE WHEN Outcome = N'Skipped'   THEN 1 ELSE 0 END), 0)
    FROM #j;

    -- "Stock levels imported: {a} added, {c} changed, {r} removed; {u} rows without a change and {e} rows with errors
    -- skipped." A part at 0 is left out; nothing imported: "Nothing was imported: ..."
    SET @Done = STUFF(  CASE WHEN @Added   > 0 THEN N', ' + CAST(@Added   AS NVARCHAR(10)) + N' added'   ELSE N'' END
                      + CASE WHEN @Changed > 0 THEN N', ' + CAST(@Changed AS NVARCHAR(10)) + N' changed' ELSE N'' END
                      + CASE WHEN @Removed > 0 THEN N', ' + CAST(@Removed AS NVARCHAR(10)) + N' removed' ELSE N'' END, 1, 2, N'');
    SET @Left = STUFF(  CASE WHEN @Unchanged > 0 THEN N' and ' + CAST(@Unchanged AS NVARCHAR(10))
                                                      + CASE WHEN @Unchanged = 1 THEN N' row' ELSE N' rows' END + N' without a change' ELSE N'' END
                      + CASE WHEN @Skipped   > 0 THEN N' and ' + CAST(@Skipped AS NVARCHAR(10))
                                                      + CASE WHEN @Skipped = 1 THEN N' row' ELSE N' rows' END + N' with errors' ELSE N'' END, 1, 5, N'');
    SET @Message = CASE WHEN @Done IS NULL THEN N'Nothing was imported: every row is unchanged or has an error.'
                        ELSE N'Stock levels imported: ' + @Done + ISNULL(N'; ' + @Left + N' skipped', N'') + N'.' END;

    -- 1: per row
    SELECT j.RowNumber, j.Outcome, j.Message
    FROM #j j
    ORDER BY j.RowNumber;

    -- 2: the counts and the sentence
    SELECT Added = @Added, Changed = @Changed, Removed = @Removed, Unchanged = @Unchanged, Skipped = @Skipped, Message = @Message;
END

GO

