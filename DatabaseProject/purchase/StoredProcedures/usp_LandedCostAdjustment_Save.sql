CREATE   PROCEDURE purchase.usp_LandedCostAdjustment_Save
    @Id                INT            = NULL,
    @SourceInvoiceId   INT,
    @DocumentDate      DATE,
    @Notes             NVARCHAR(1000) = NULL,
    @Charges           purchase.tvp_PurchaseCharge READONLY,
    @ManualAllocations purchase.tvp_ManualAllocation READONLY,
    @RowVersion        BINARY(8)      = NULL,
    @UserId            INT            = NULL,
    @NewId             INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    IF @DocumentDate IS NULL THROW 67000, 'Date is required.', 1;
    IF @DocumentDate > CAST(SYSUTCDATETIME() AS DATE) THROW 67000, 'Date cannot be in the future.', 1;

    DECLARE @InvStatus TINYINT, @InvType NVARCHAR(20), @BranchId INT, @BaseCurrency INT = (SELECT TOP (1) Id FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1);
    SELECT @InvStatus = d.Status, @InvType = dt.Code, @BranchId = d.BranchId
    FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId WHERE d.Id = @SourceInvoiceId;
    IF @InvStatus IS NULL THROW 67011, 'Purchase invoice not found.', 1;
    IF @InvType <> N'PINV' OR @InvStatus <> 2 THROW 67011, 'Landed cost adjustments apply to POSTED purchase invoices only.', 1;
    IF NOT EXISTS (SELECT 1 FROM @Charges) THROW 67000, 'At least one charge is required.', 1;

    IF @Id IS NOT NULL
    BEGIN
        DECLARE @Status TINYINT = (SELECT Status FROM purchase.LandedCostAdjustments WHERE Id = @Id);
        IF @Status IS NULL THROW 67006, 'Adjustment not found.', 1;
        IF @Status <> 1 THROW 67005, 'Only draft adjustments can be edited.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.LandedCostAdjustments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 67004, 'This adjustment was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM purchase.LandedCostAdjustments WHERE Id = @Id AND SourceInvoiceId <> @SourceInvoiceId)
            THROW 67000, 'The invoice of an adjustment cannot be changed.', 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;
        IF @Id IS NULL
        BEGIN
            DECLARE @Number NVARCHAR(30), @TypeId INT = (SELECT Id FROM inventory.DocumentTypes WHERE Code = N'LCA');
            EXEC inventory.usp_DocumentType_NextNumber N'LCA', @Number OUTPUT, @BranchId;
            INSERT INTO purchase.LandedCostAdjustments (DocumentTypeId, DocumentNumber, DocumentDate, BranchId, SourceInvoiceId, Notes, Status, CreatedBy)
            VALUES (@TypeId, @Number, @DocumentDate, @BranchId, @SourceInvoiceId, @Notes, 1, @UserId);
            SET @Id = SCOPE_IDENTITY();
        END
        ELSE
            UPDATE purchase.LandedCostAdjustments SET DocumentDate = @DocumentDate, Notes = @Notes, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;

        EXEC purchase.usp_PurchaseCharges_Write N'LCA', @Id, @DocumentDate, @BaseCurrency, @SourceInvoiceId, @Charges, @ManualAllocations, @UserId;

        UPDATE a SET TotalChargesBase = ISNULL((SELECT SUM(AmountBase) FROM purchase.PurchaseCharges WHERE DocumentKind = N'LCA' AND DocumentId = @Id AND IncludeInLandedCost = 1), 0)
        FROM purchase.LandedCostAdjustments a WHERE a.Id = @Id;

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

