/* ------------------------------------------------------------------ 4. Audit procedures */

CREATE   PROCEDURE sales.usp_InvoiceImport_Log
    @BranchId       INT,
    @WarehouseId    INT,
    @PriceListId    INT,
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

    INSERT INTO sales.InvoiceImportLogs (InvoiceId, DraftReference, BranchId, WarehouseId, PriceListId, FileName,
                                         TotalRows, ImportedRows, WarningRows, RejectedRows, ImportedBy)
    VALUES (@InvoiceId, @DraftReference, @BranchId, @WarehouseId, @PriceListId, LTRIM(RTRIM(@FileName)),
            ISNULL(@TotalRows, 0), ISNULL(@ImportedRows, 0), ISNULL(@WarningRows, 0), ISNULL(@RejectedRows, 0), @ImportedBy);
    SET @NewId = SCOPE_IDENTITY();
END