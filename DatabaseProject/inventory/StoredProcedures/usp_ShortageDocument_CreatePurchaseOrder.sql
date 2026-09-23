CREATE   PROCEDURE inventory.usp_ShortageDocument_CreatePurchaseOrder
    @Id           INT,
    @DocumentDate DATE = NULL,
    @ExpectedDate DATE = NULL,
    @UserId       INT  = NULL,
    @NewId        INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF @DocumentDate IS NULL SET @DocumentDate = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @Status TINYINT, @BranchId INT, @WarehouseId INT, @SupplierId INT, @Number NVARCHAR(30), @Description NVARCHAR(200);
    SELECT @Status = Status, @BranchId = BranchId, @WarehouseId = WarehouseId, @SupplierId = SupplierId, @Number = DocumentNumber, @Description = Description
    FROM inventory.ShortageDocuments WHERE Id = @Id;
    IF @Status IS NULL THROW 66006, 'Shortage document not found.', 1;
    IF @Status <> 2 THROW 66010, 'Post the shortage document before creating a purchase order from it.', 1;

    DECLARE @Lines purchase.tvp_PurchaseDocumentLine;
    INSERT INTO @Lines (LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, UnitPrice, DiscountPercent, ImportRowNumber, Notes, SourceLineId)
    SELECT ROW_NUMBER() OVER (ORDER BY l.LineNumber), l.ItemId, l.PurchaseItemUnitId, @WarehouseId, NULL, l.RequiredQty, NULL, NULL, NULL,
           LEFT(N'Shortage ' + @Number + ISNULL(N' - ' + l.Notes, N''), 300), NULL
    FROM inventory.ShortageDocumentLines l
    WHERE l.DocumentId = @Id AND l.RequiredQty > 0;
    IF NOT EXISTS (SELECT 1 FROM @Lines) THROW 66011, 'No line has a required quantity greater than zero.', 1;

    DECLARE @Notes NVARCHAR(1000) = N'Created from shortage plan ' + @Number + N' - ' + @Description;
    EXEC purchase.usp_PurchaseDocument_Save
         @Id = NULL, @DocumentTypeCode = N'PO', @DocumentDate = @DocumentDate, @ExpectedDate = @ExpectedDate,
         @BranchId = @BranchId, @WarehouseId = @WarehouseId, @SupplierId = @SupplierId, @CurrencyId = NULL,
         @RateType = 1, @ExchangeRate = NULL, @SupplierReference = NULL, @Notes = @Notes,
         @Lines = @Lines, @MaxDiscountPercent = 100, @SourceDocumentId = NULL, @RowVersion = NULL, @UserId = @UserId, @NewId = @NewId OUTPUT;

    UPDATE purchase.PurchaseDocuments SET SourceShortageId = @Id WHERE Id = @NewId;
    INSERT INTO inventory.ShortageDocumentAudit (DocumentId, Action, Details, UserId)
    VALUES (@Id, N'POCreated', N'Purchase order draft created (' + CAST((SELECT COUNT(*) FROM @Lines) AS NVARCHAR(10)) + N' line(s))', @UserId);
END

GO

