CREATE   PROCEDURE inventory.usp_ShortageDocument_Save
    @Id              INT            = NULL,   -- NULL = create (number assigned now)
    @Description     NVARCHAR(200),
    @DocumentDate    DATE,
    @BranchId        INT,
    @WarehouseId     INT,
    @SupplierId      INT,
    @LeadTimeMonths  DECIMAL(6,2),
    @MonthsOfHistory INT            = 3,
    @Notes           NVARCHAR(1000) = NULL,
    @Lines           inventory.tvp_ShortageLine READONLY,
    @RowVersion      BINARY(8)      = NULL,
    @UserId          INT            = NULL,
    @NewId           INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Description = NULLIF(LTRIM(RTRIM(@Description)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    IF @Description IS NULL THROW 66000, 'Description is required.', 1;
    IF @DocumentDate IS NULL THROW 66000, 'Date is required.', 1;
    IF @LeadTimeMonths IS NULL OR @LeadTimeMonths <= 0 THROW 66000, 'Lead Time (Month) must be greater than zero.', 1;
    IF @MonthsOfHistory IS NULL OR @MonthsOfHistory NOT BETWEEN 1 AND 36 THROW 66000, 'Months of history must be between 1 and 36.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1) THROW 66000, 'Branch not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1) THROW 66000, 'Warehouse not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SupplierId AND IsSupplier = 1 AND IsActive = 1) THROW 66000, 'Supplier not found, inactive, or not flagged as a supplier.', 1;

    IF @Id IS NOT NULL
    BEGIN
        DECLARE @Status TINYINT = (SELECT Status FROM inventory.ShortageDocuments WHERE Id = @Id);
        IF @Status IS NULL THROW 66006, 'Shortage document not found.', 1;
        IF @Status <> 1 THROW 66005, 'Only draft shortage documents can be edited.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.ShortageDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 66004, 'This document was modified by another user. Reload the page and try again.', 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Id IS NULL
        BEGIN
            DECLARE @Number NVARCHAR(30), @TypeId INT = (SELECT Id FROM inventory.DocumentTypes WHERE Code = N'SHR');
            EXEC inventory.usp_DocumentType_NextNumber N'SHR', @Number OUTPUT, @BranchId;

            INSERT INTO inventory.ShortageDocuments (DocumentTypeId, DocumentNumber, Description, DocumentDate, BranchId, WarehouseId, SupplierId,
                                                     LeadTimeMonths, MonthsOfHistory, Notes, Status, CreatedBy)
            VALUES (@TypeId, @Number, @Description, @DocumentDate, @BranchId, @WarehouseId, @SupplierId, @LeadTimeMonths, @MonthsOfHistory, @Notes, 1, @UserId);
            SET @Id = SCOPE_IDENTITY();
            INSERT INTO inventory.ShortageDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@Id, N'Created', N'Draft ' + @Number, @UserId);
        END
        ELSE
        BEGIN
            UPDATE inventory.ShortageDocuments
            SET Description = @Description, DocumentDate = @DocumentDate, BranchId = @BranchId, WarehouseId = @WarehouseId, SupplierId = @SupplierId,
                LeadTimeMonths = @LeadTimeMonths, MonthsOfHistory = @MonthsOfHistory, Notes = @Notes, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;
            INSERT INTO inventory.ShortageDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Updated', N'Header and ' + CAST((SELECT COUNT(*) FROM @Lines) AS NVARCHAR(10)) + N' line(s) saved', @UserId);
        END

        EXEC inventory.usp_ShortageDocument_WriteLines @Id, @Lines;

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

