CREATE   PROCEDURE sales.usp_InvoiceImport_Log
    @BranchId       INT,
    @WarehouseId    INT,
    @PriceListId    INT          = NULL,
    @FileName       NVARCHAR(255),
    @TotalRows      INT,
    @ImportedRows   INT,
    @WarningRows    INT,
    @RejectedRows   INT,
    @DraftReference NVARCHAR(50) = NULL,
    @InvoiceId      INT          = NULL,
    @ImportedBy     INT          = NULL,
    @NewId          INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF @FileName IS NULL OR LTRIM(RTRIM(@FileName)) = N'' THROW 61000, 'File name is required.', 1;
    IF @InvoiceId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @InvoiceId)
        THROW 61000, 'Invoice not found.', 1;

    INSERT INTO sales.InvoiceImportLogs (InvoiceId, DraftReference, BranchId, WarehouseId, PriceListId, FileName,
                                         TotalRows, ImportedRows, WarningRows, RejectedRows, ImportedBy)
    VALUES (@InvoiceId, NULLIF(LTRIM(RTRIM(@DraftReference)), N''), @BranchId, @WarehouseId, @PriceListId, LTRIM(RTRIM(@FileName)),
            ISNULL(@TotalRows, 0), ISNULL(@ImportedRows, 0), ISNULL(@WarningRows, 0), ISNULL(@RejectedRows, 0), @ImportedBy);
    SET @NewId = SCOPE_IDENTITY();

    IF @InvoiceId IS NOT NULL
        INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@InvoiceId, N'Imported', N'Excel import: ' + LTRIM(RTRIM(@FileName)) + N' (' + CAST(ISNULL(@ImportedRows, 0) AS NVARCHAR(10)) + N' row(s))', @ImportedBy);
END

GO

