
/* ------------------------------------------------------------------ 4. Commit (all non-error rows, one transaction) */

CREATE   PROCEDURE inventory.usp_ItemImport_Commit
    @Rows     inventory.tvp_ItemImportRow READONLY,
    @FileName NVARCHAR(255),
    @UserId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @FileName IS NULL OR LTRIM(RTRIM(@FileName)) = N'' THROW 63000, 'File name is required.', 1;

    CREATE TABLE #v
    (
        RowNumber INT PRIMARY KEY, Status NVARCHAR(10), Message NVARCHAR(2000),
        ItemCode NVARCHAR(50), ItemName NVARCHAR(200), BrandId INT, BrandName NVARCHAR(150), Model NVARCHAR(100),
        ItemFamilyId INT, FamilyName NVARCHAR(150), Country NVARCHAR(10), WarehouseId INT, WarehouseName NVARCHAR(150),
        Description NVARCHAR(1000), WarrantyMonths INT, MinQuantity INT, MaxQuantity INT, IsBivac BIT,
        BaseUnitTypeId INT, BaseUnitName NVARCHAR(50), BaseSku NVARCHAR(50), BaseBarcode NVARCHAR(50),
        Unit2TypeId INT, Unit2Name NVARCHAR(50), Unit2Formula INT, Unit2Sku NVARCHAR(50), Unit2Barcode NVARCHAR(50)
    );
    CREATE TABLE #ids (RowNumber INT PRIMARY KEY, ItemId INT NOT NULL);

    INSERT INTO #v (RowNumber, Status, Message, ItemCode, ItemName, BrandId, BrandName, Model, ItemFamilyId, FamilyName, Country,
                    WarehouseId, WarehouseName, Description, WarrantyMonths, MinQuantity, MaxQuantity, IsBivac,
                    BaseUnitTypeId, BaseUnitName, BaseSku, BaseBarcode, Unit2TypeId, Unit2Name, Unit2Formula, Unit2Sku, Unit2Barcode)
    EXEC inventory.usp_ItemImport_Validate @Rows;

    DECLARE @Total    INT = (SELECT COUNT(*) FROM #v),
            @Errors   INT = (SELECT COUNT(*) FROM #v WHERE Status = N'Error'),
            @Warnings INT = (SELECT COUNT(*) FROM #v WHERE Status = N'Warning');
    IF @Total = 0 THROW 63000, 'The file contains no rows to import.', 1;
    IF @Total = @Errors THROW 63001, 'Every row contains an error - nothing was imported. Download the error report, fix the file and try again.', 1;

    DECLARE @LogId INT;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Items (MERGE + OUTPUT captures the new identity per source row).
        MERGE inventory.Items AS t
        USING (SELECT * FROM #v WHERE Status <> N'Error') AS s ON 1 = 0
        WHEN NOT MATCHED THEN
            INSERT (ItemCode, ItemName, BrandId, Model, ItemFamilyId, CountryOfOrigin, DefaultWarehouseId, Description,
                    WarrantyMonths, MinQuantity, MaxQuantity, IsBivac, IsActive, CreatedBy)
            VALUES (s.ItemCode, s.ItemName, s.BrandId, s.Model, s.ItemFamilyId, s.Country, s.WarehouseId, s.Description,
                    s.WarrantyMonths, s.MinQuantity, s.MaxQuantity, s.IsBivac, 1, @UserId)
        OUTPUT s.RowNumber, inserted.Id INTO #ids (RowNumber, ItemId);

        -- Base units: formula 1, Sales unit; also Purchase unit when the row has no Unit 2.
        INSERT INTO inventory.ItemUnits (ItemId, UnitTypeId, PackingFormula, SkuCode, Barcode, IsSalesUnit, IsPurchaseUnit, IsBaseUnit, CreatedBy)
        SELECT i.ItemId, v.BaseUnitTypeId, 1, v.BaseSku, v.BaseBarcode, 1, CASE WHEN v.Unit2TypeId IS NULL THEN 1 ELSE 0 END, 1, @UserId
        FROM #v v JOIN #ids i ON i.RowNumber = v.RowNumber;

        -- Unit 2: Purchase unit.
        INSERT INTO inventory.ItemUnits (ItemId, UnitTypeId, PackingFormula, SkuCode, Barcode, IsSalesUnit, IsPurchaseUnit, IsBaseUnit, CreatedBy)
        SELECT i.ItemId, v.Unit2TypeId, v.Unit2Formula, v.Unit2Sku, v.Unit2Barcode, 0, 1, 0, @UserId
        FROM #v v JOIN #ids i ON i.RowNumber = v.RowNumber
        WHERE v.Unit2TypeId IS NOT NULL;

        INSERT INTO inventory.ItemImportLogs (FileName, TotalRows, ImportedRows, WarningRows, RejectedRows, ImportedBy)
        VALUES (LTRIM(RTRIM(@FileName)), @Total, @Total - @Errors, @Warnings, @Errors, @UserId);
        SET @LogId = SCOPE_IDENTITY();

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    -- Result set 1: summary.  Result set 2: created items.
    SELECT LogId = @LogId, TotalRows = @Total, ImportedRows = @Total - @Errors, WarningRows = @Warnings, RejectedRows = @Errors;

    SELECT i.ItemId AS Id, v.RowNumber, v.ItemCode, v.ItemName, v.BrandName, v.FamilyName, v.WarehouseName,
           UnitCount = CASE WHEN v.Unit2TypeId IS NULL THEN 1 ELSE 2 END
    FROM #v v JOIN #ids i ON i.RowNumber = v.RowNumber
    ORDER BY v.RowNumber;
END