-- the approval requests of a draft order are deleted with it.
CREATE   PROCEDURE purchase.usp_PurchaseDocument_Delete
    @Id     INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT = (SELECT Status FROM purchase.PurchaseDocuments WHERE Id = @Id);
    IF @Status IS NULL THROW 65006, 'Document not found.', 1;
    IF @Status <> 1 THROW 65005, 'Only draft documents can be deleted. Posted documents must be cancelled.', 1;

    DECLARE @Containers TABLE (ContainerId INT PRIMARY KEY);
    INSERT INTO @Containers (ContainerId)
    SELECT DISTINCT cl.ContainerId FROM purchase.PurchaseDocumentLines l
    INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
    WHERE l.DocumentId = @Id;

    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE a FROM purchase.PurchaseChargeAllocations a INNER JOIN purchase.PurchaseCharges c ON c.Id = a.ChargeId WHERE c.DocumentKind = N'PINV' AND c.DocumentId = @Id;
        DELETE FROM purchase.PurchaseCharges WHERE DocumentKind = N'PINV' AND DocumentId = @Id;
        DELETE FROM purchase.PurchaseDocumentFiles WHERE DocumentId = @Id;
        DELETE FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id;
        DELETE FROM purchase.PurchaseOrderApprovals WHERE DocumentId = @Id;
        DELETE FROM purchase.PurchaseDocumentAudit WHERE DocumentId = @Id;
        DELETE FROM purchase.PurchaseDocuments WHERE Id = @Id;

        DECLARE @Cid INT;
        DECLARE cts CURSOR LOCAL FAST_FORWARD FOR SELECT ContainerId FROM @Containers;
        OPEN cts;
        FETCH NEXT FROM cts INTO @Cid;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC logistics.usp_Container_ReallocateCharges @Cid, 1, 1;
            FETCH NEXT FROM cts INTO @Cid;
        END
        CLOSE cts;
        DEALLOCATE cts;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

