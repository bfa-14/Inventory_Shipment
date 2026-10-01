CREATE   PROCEDURE masterdata.usp_AttachmentType_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Id = @Id) THROW 69006, 'Attachment type not found.', 1;
    IF EXISTS (SELECT 1 FROM logistics.ContainerAttachments WHERE AttachmentTypeId = @Id)
       OR EXISTS (SELECT 1 FROM sales.ReceiptFiles WHERE AttachmentTypeId = @Id)
        THROW 69014, 'This attachment type is used by documents and cannot be deleted. Deactivate it instead.', 1;
    DELETE FROM masterdata.AttachmentTypes WHERE Id = @Id;
END

GO

