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
    IF EXISTS (SELECT 1 FROM logistics.ContainerInvoices ci INNER JOIN logistics.Containers c ON c.Id = ci.ContainerId
               WHERE ci.PurchaseDocumentId = @Id AND c.Status <> 8)
        THROW 69012, 'This invoice is linked to a container. Remove it from the container first.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE cl FROM logistics.ContainerLines cl
        INNER JOIN logistics.Containers c2 ON c2.Id = cl.ContainerId
        WHERE cl.PurchaseDocumentId = @Id AND c2.Status = 8;
        DELETE ci FROM logistics.ContainerInvoices ci
        INNER JOIN logistics.Containers c3 ON c3.Id = ci.ContainerId
        WHERE ci.PurchaseDocumentId = @Id AND c3.Status = 8;
        DELETE a FROM purchase.PurchaseChargeAllocations a INNER JOIN purchase.PurchaseCharges c ON c.Id = a.ChargeId WHERE c.DocumentKind = N'PINV' AND c.DocumentId = @Id;
        DELETE FROM purchase.PurchaseCharges WHERE DocumentKind = N'PINV' AND DocumentId = @Id;
        DELETE FROM purchase.PurchaseDocumentFiles WHERE DocumentId = @Id;
        DELETE FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id;
        DELETE FROM purchase.PurchaseDocumentAudit WHERE DocumentId = @Id;
        DELETE FROM purchase.PurchaseDocuments WHERE Id = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END