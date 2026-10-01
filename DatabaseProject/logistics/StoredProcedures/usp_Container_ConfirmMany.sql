-- Returns the selected containers (Id, ContainerRef, Status, ConfirmedNow, RowVersion).
CREATE   PROCEDURE logistics.usp_Container_ConfirmMany
    @Ids    logistics.tvp_IdList READONLY,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM @Ids) THROW 69000, 'Select at least one container.', 1;
    IF EXISTS (SELECT 1 FROM @Ids x WHERE NOT EXISTS (SELECT 1 FROM logistics.Containers c WHERE c.Id = x.Id))
        THROW 69006, 'A selected container no longer exists.', 1;

    DECLARE @Done TABLE (Id INT NOT NULL PRIMARY KEY);
    DECLARE @Cid INT, @Ref NVARCHAR(30) = NULL;

    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE draft_cur CURSOR LOCAL STATIC READ_ONLY FORWARD_ONLY FOR
            SELECT c.Id, c.ContainerRef FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id
            WHERE c.Status = 1 ORDER BY c.ContainerRef;
        OPEN draft_cur;
        FETCH NEXT FROM draft_cur INTO @Cid, @Ref;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC logistics.usp_Container_Confirm @Id = @Cid, @UserId = @UserId;
            INSERT INTO @Done (Id) VALUES (@Cid);
            FETCH NEXT FROM draft_cur INTO @Cid, @Ref;
        END
        CLOSE draft_cur;
        DEALLOCATE draft_cur;
        SET @Ref = NULL;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrNo INT = ERROR_NUMBER(), @ErrMsg NVARCHAR(2048) = ERROR_MESSAGE();
        IF @ErrNo >= 50000 AND @Ref IS NOT NULL
        BEGIN
            SET @ErrMsg = LEFT(@Ref + N': ' + @ErrMsg, 2048);
            THROW @ErrNo, @ErrMsg, 1;
        END;
        THROW;
    END CATCH

    SELECT c.Id, c.ContainerRef, c.Status, ConfirmedNow = CAST(CASE WHEN d.Id IS NOT NULL THEN 1 ELSE 0 END AS BIT), c.RowVersion
    FROM @Ids x
    INNER JOIN logistics.Containers c ON c.Id = x.Id
    LEFT  JOIN @Done d                ON d.Id = c.Id
    ORDER BY c.ContainerRef;
END

GO

