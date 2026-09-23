CREATE   PROCEDURE sales.usp_InvoiceImport_AttachInvoice
    @DraftReference NVARCHAR(50),
    @InvoiceId      INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE sales.InvoiceImportLogs SET InvoiceId = @InvoiceId
    WHERE DraftReference = @DraftReference AND InvoiceId IS NULL;
END

GO

