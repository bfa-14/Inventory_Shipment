-- supplier has no email address).
CREATE   PROCEDURE purchase.usp_PurchaseOrder_SupplierEmailLogged
    @PurchaseDocumentId INT,
    @Sent               BIT,
    @Recipients         NVARCHAR(1000) = NULL,
    @UserId             INT            = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @PurchaseDocumentId) THROW 65006, 'Document not found.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        INSERT INTO purchase.PurchaseOrderApprovalEvents (PurchaseDocumentId, EventType, UserId, Recipients, Note)
        VALUES (@PurchaseDocumentId, CASE WHEN @Sent = 1 THEN 8 ELSE 9 END, @UserId, NULLIF(LTRIM(RTRIM(@Recipients)), N''),
                CASE WHEN ISNULL(@Sent, 0) = 0 THEN N'The supplier has no email address' END);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

