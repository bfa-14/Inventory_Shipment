CREATE   PROCEDURE logistics.usp_ContainerAttachment_Delete
    @Id        INT,
    @AllShared BIT = 0,
    @UserId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @FileId INT, @FileName NVARCHAR(255);
    SELECT @FileId = a.FileId, @FileName = f.FileName
    FROM logistics.ContainerAttachments a INNER JOIN logistics.Files f ON f.Id = a.FileId
    WHERE a.Id = @Id;
    IF @FileId IS NULL THROW 70006, 'Attachment not found.', 1;

    DECLARE @Gone TABLE (ContainerId INT);
    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE FROM logistics.ContainerAttachments
        OUTPUT deleted.ContainerId INTO @Gone (ContainerId)
        WHERE Id = @Id OR (ISNULL(@AllShared, 0) = 1 AND FileId = @FileId);

        IF NOT EXISTS (SELECT 1 FROM logistics.ContainerAttachments WHERE FileId = @FileId)
            DELETE FROM logistics.Files WHERE Id = @FileId;

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        SELECT DISTINCT g.ContainerId, N'Updated', LEFT(N'Attachment removed: ' + @FileName, 500), @UserId FROM @Gone g;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

