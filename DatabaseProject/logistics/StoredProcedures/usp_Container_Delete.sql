CREATE   PROCEDURE logistics.usp_Container_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Status TINYINT = (SELECT Status FROM logistics.Containers WHERE Id = @Id);
    IF @Status IS NULL THROW 69006, 'Container not found.', 1;
    IF @Status <> 1 THROW 69005, 'Only a draft container can be deleted. Cancel the others.', 1;
    IF EXISTS (SELECT 1 FROM logistics.ContainerLines cl
               INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
               INNER JOIN purchase.PurchaseDocuments d        ON d.Id = pil.DocumentId
               WHERE cl.ContainerId = @Id AND d.Status <> 3)
        THROW 69012, 'The container is invoiced. Cancel or delete its invoices first.', 1;
    IF EXISTS (SELECT 1 FROM logistics.ContainerCharges WHERE ContainerId = @Id AND Status IN (2, 3))
        THROW 70014, 'Posted or cancelled charges refer to this container. Cancel the container instead.', 1;
    IF EXISTS (SELECT 1 FROM logistics.MovementContainers mc INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
               WHERE mc.ContainerId = @Id AND m.Status IN (2, 3))
        THROW 70012, 'The container already travelled with a movement. Cancel the container instead.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE @Files TABLE (FileId INT PRIMARY KEY);
        INSERT INTO @Files (FileId) SELECT DISTINCT FileId FROM logistics.ContainerAttachments WHERE ContainerId = @Id;
        DELETE FROM logistics.ContainerAttachments WHERE ContainerId = @Id;
        DELETE f FROM logistics.Files f INNER JOIN @Files x ON x.FileId = f.Id
        WHERE NOT EXISTS (SELECT 1 FROM logistics.ContainerAttachments a WHERE a.FileId = f.Id);

        UPDATE pil SET ContainerLineId = NULL                  -- lines of cancelled invoices
        FROM purchase.PurchaseDocumentLines pil
        INNER JOIN logistics.ContainerLines cl ON cl.Id = pil.ContainerLineId
        WHERE cl.ContainerId = @Id;

        DELETE a FROM logistics.ContainerChargeAllocations a INNER JOIN logistics.ContainerCharges ch ON ch.Id = a.ChargeId WHERE ch.ContainerId = @Id;
        DELETE FROM logistics.ContainerCharges WHERE ContainerId = @Id;
        DELETE FROM logistics.MovementContainers WHERE ContainerId = @Id;
        DELETE FROM logistics.ContainerLines WHERE ContainerId = @Id;
        DELETE FROM logistics.ContainerAudit WHERE ContainerId = @Id;
        DELETE FROM logistics.Containers WHERE Id = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

