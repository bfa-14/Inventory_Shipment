CREATE   PROCEDURE logistics.usp_Container_DeleteMany
    @Ids    logistics.tvp_IdList READONLY,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM @Ids) THROW 69000, 'Select at least one container.', 1;
    IF EXISTS (SELECT 1 FROM @Ids x WHERE NOT EXISTS (SELECT 1 FROM logistics.Containers c WHERE c.Id = x.Id))
        THROW 69006, 'A selected container no longer exists.', 1;

    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' is not a draft. Only drafts can be deleted; cancel the others.'
    FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id
    WHERE c.Status <> 1
    ORDER BY c.ContainerRef;
    IF @Msg IS NOT NULL THROW 69005, @Msg, 1;

    DECLARE @Cid INT, @Ref NVARCHAR(30) = NULL, @Count INT = 0;

    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE del_cur CURSOR LOCAL STATIC READ_ONLY FORWARD_ONLY FOR
            SELECT c.Id, c.ContainerRef FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id ORDER BY c.ContainerRef;
        OPEN del_cur;
        FETCH NEXT FROM del_cur INTO @Cid, @Ref;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC logistics.usp_Container_Delete @Id = @Cid, @UserId = @UserId;
            SET @Count = @Count + 1;
            FETCH NEXT FROM del_cur INTO @Cid, @Ref;
        END
        CLOSE del_cur;
        DEALLOCATE del_cur;
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

    SELECT Deleted = @Count;
END

GO

