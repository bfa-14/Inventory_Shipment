CREATE   PROCEDURE masterdata.usp_UnitPrice_Create
    @BranchId    INT           = NULL,   -- NULL = All Branches
    @ItemId      INT,
    @ItemUnitId  INT,
    @PriceListId INT,
    @Price       DECIMAL(18,4),
    @IsActive    BIT           = 1,
    @UserId      INT           = NULL,
    @NewId       INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @IsActive = ISNULL(@IsActive, 1);

    IF @BranchId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 59008, 'Branch not found or inactive.', 1;
    IF @ItemId IS NULL THROW 59000, 'Item is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM inventory.Items WHERE Id = @ItemId AND IsActive = 1)
        THROW 59008, 'Item not found or inactive.', 1;
    IF @ItemUnitId IS NULL THROW 59000, 'Unit is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM inventory.ItemUnits WHERE Id = @ItemUnitId AND ItemId = @ItemId)
        THROW 59007, 'The selected unit does not belong to the selected item.', 1;
    IF @PriceListId IS NULL THROW 59000, 'Price List is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE Id = @PriceListId AND IsActive = 1)
        THROW 59008, 'Price list not found or inactive.', 1;
    IF @Price IS NULL THROW 59000, 'Price is required.', 1;
    IF @Price < 0 THROW 59000, 'Price cannot be negative.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.UnitPrices
               WHERE ItemUnitId = @ItemUnitId AND PriceListId = @PriceListId
                 AND ((BranchId IS NULL AND @BranchId IS NULL) OR BranchId = @BranchId))
        THROW 59001, 'A price already exists for this branch, item, unit, and price list. Please edit the existing record instead.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO masterdata.UnitPrices (BranchId, ItemId, ItemUnitId, PriceListId, Price, IsActive, CreatedBy)
        VALUES (@BranchId, @ItemId, @ItemUnitId, @PriceListId, @Price, @IsActive, @UserId);

        SET @NewId = SCOPE_IDENTITY();

        EXEC masterdata.usp_UnitPrice_LogHistory @UnitPriceId = @NewId, @ChangeType = 1, @OldPrice = NULL, @NewPrice = @Price, @UserId = @UserId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END