/* ================================================================== 9. Containers (CONTAINER) */

-- Re-created (48) from the body of script 27: the type required and used for containers (it was optional); the note
-- takes 500 characters.
CREATE   PROCEDURE logistics.usp_ContainerAttachment_Add
    @ContainerIds     logistics.tvp_IdList READONLY,
    @MovementId       INT            = NULL,
    @ChargeId         INT            = NULL,
    @AttachmentTypeId INT            = NULL,
    @FileName         NVARCHAR(255),
    @ContentType      NVARCHAR(100),
    @SizeBytes        INT,
    @Content          VARBINARY(MAX),
    @Note             NVARCHAR(500)  = NULL,
    @DocumentDate     DATE           = NULL,
    @UserId           INT            = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @FileName = NULLIF(LTRIM(RTRIM(@FileName)), N'');
    SET @Note = NULLIF(LTRIM(RTRIM(@Note)), N'');

    DECLARE @Ids TABLE (Id INT PRIMARY KEY);
    INSERT INTO @Ids (Id) SELECT Id FROM @ContainerIds;
    -- a charge alone is enough: its container is taken
    IF NOT EXISTS (SELECT 1 FROM @Ids) AND @ChargeId IS NOT NULL
        INSERT INTO @Ids (Id) SELECT ContainerId FROM logistics.ContainerCharges WHERE Id = @ChargeId;

    IF NOT EXISTS (SELECT 1 FROM @Ids) THROW 70000, 'Select at least one container.', 1;
    IF @FileName IS NULL THROW 70000, 'The file name is required.', 1;
    IF @SizeBytes IS NULL OR @SizeBytes <= 0 OR @Content IS NULL THROW 70000, 'The file is empty.', 1;
    -- (48) the type is required, active and used for containers
    EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, N'CONTAINER', 70017;
    IF EXISTS (SELECT 1 FROM @Ids x WHERE NOT EXISTS (SELECT 1 FROM logistics.Containers c WHERE c.Id = x.Id))
        THROW 70006, 'A selected container no longer exists.', 1;
    IF @MovementId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Movements WHERE Id = @MovementId)
        THROW 70006, 'Movement not found.', 1;

    DECLARE @Msg NVARCHAR(400);
    IF @MovementId IS NOT NULL
    BEGIN
        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' is not part of this movement.'
        FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id
        WHERE NOT EXISTS (SELECT 1 FROM logistics.MovementContainers mc WHERE mc.MovementId = @MovementId AND mc.ContainerId = x.Id)
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70000, @Msg, 1;
    END

    DECLARE @GroupOfCharge UNIQUEIDENTIFIER = NULL;
    IF @ChargeId IS NOT NULL
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM logistics.ContainerCharges WHERE Id = @ChargeId) THROW 70006, 'Charge not found.', 1;
        SELECT @GroupOfCharge = GroupId FROM logistics.ContainerCharges WHERE Id = @ChargeId;
        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' has no charge of this group.'
        FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id
        WHERE NOT EXISTS (SELECT 1 FROM logistics.ContainerCharges ch
                          WHERE ch.ContainerId = x.Id AND (ch.Id = @ChargeId OR (@GroupOfCharge IS NOT NULL AND ch.GroupId = @GroupOfCharge)))
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70000, @Msg, 1;
    END

    DECLARE @Group UNIQUEIDENTIFIER = CASE WHEN (SELECT COUNT(*) FROM @Ids) > 1 THEN NEWID() END;
    DECLARE @FileId INT;

    BEGIN TRY
        BEGIN TRANSACTION;
        INSERT INTO logistics.Files (FileName, ContentType, SizeBytes, Content, CreatedBy)
        VALUES (@FileName, ISNULL(NULLIF(LTRIM(RTRIM(@ContentType)), N''), N'application/octet-stream'), @SizeBytes, @Content, @UserId);
        SET @FileId = SCOPE_IDENTITY();

        INSERT INTO logistics.ContainerAttachments (ContainerId, MovementId, ChargeId, AttachmentTypeId, FileId, Note, DocumentDate, GroupId, CreatedBy)
        SELECT x.Id, @MovementId,
               (SELECT TOP (1) ch.Id FROM logistics.ContainerCharges ch
                WHERE ch.ContainerId = x.Id AND (ch.Id = @ChargeId OR (@GroupOfCharge IS NOT NULL AND ch.GroupId = @GroupOfCharge))
                ORDER BY CASE WHEN ch.Id = @ChargeId THEN 0 ELSE 1 END, ch.Id),
               @AttachmentTypeId, @FileId, @Note, @DocumentDate, @Group, @UserId
        FROM @Ids x;

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        SELECT x.Id, N'Updated', LEFT(N'Attachment added: ' + @FileName
                                      + ISNULL(N' (movement ' + (SELECT MovementNo FROM logistics.Movements WHERE Id = @MovementId) + N')', N''), 500), @UserId
        FROM @Ids x;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT a.Id, a.ContainerId, c.ContainerRef, a.FileId, a.MovementId, a.ChargeId
    FROM logistics.ContainerAttachments a
    INNER JOIN logistics.Containers c ON c.Id = a.ContainerId
    WHERE a.FileId = @FileId
    ORDER BY c.ContainerRef;
END

GO

