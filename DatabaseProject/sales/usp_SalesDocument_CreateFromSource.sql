CREATE   PROCEDURE sales.usp_SalesDocument_CreateFromSource
    @SourceId     INT,
    @DocumentDate DATE = NULL,
    @UserId       INT  = NULL,
    @NewId        INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @DocumentDate IS NULL SET @DocumentDate = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @SrcType NVARCHAR(20), @Status TINYINT, @BranchId INT, @WarehouseId INT, @ClientId INT, @SalesmanId INT, @PriceListId INT, @RateType TINYINT, @Rate DECIMAL(18,6), @Ref NVARCHAR(100);
    SELECT @SrcType = dt.Code, @Status = d.Status, @BranchId = d.BranchId, @WarehouseId = d.WarehouseId, @ClientId = d.ClientId, @SalesmanId = d.SalesmanId,
           @PriceListId = d.PriceListId, @RateType = d.RateType, @Rate = d.ExchangeRate, @Ref = d.DocumentNumber
    FROM sales.SalesDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId WHERE d.Id = @SourceId;
    IF @SrcType IS NULL THROW 64006, 'Source invoice not found.', 1;
    IF @SrcType <> N'SINV' OR @Status <> 2 THROW 64010, 'Returns are created from POSTED sales invoices only.', 1;
    IF NOT EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Code = N'SRET' AND IsActive = 1) THROW 64008, 'Document type SRET is inactive.', 1;

    DECLARE @Lines sales.tvp_SalesDocumentLine;
    INSERT INTO @Lines (LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, UnitPrice, DiscountPercent, ImportRowNumber, Notes)
    SELECT ROW_NUMBER() OVER (ORDER BY l.LineNumber), l.ItemId, c.ItemUnitId, l.WarehouseId, l.ExpiryDate, c.Quantity, c.UnitPrice, l.DiscountPercent, NULL, l.Notes
    FROM sales.SalesDocumentLines l
    CROSS APPLY (SELECT Remaining = l.QuantityBase - l.ReturnedQuantityBase) r
    CROSS APPLY (SELECT ItemUnitId = CASE WHEN r.Remaining % l.PackingFormula = 0 THEN l.ItemUnitId
                                          ELSE (SELECT TOP (1) Id FROM inventory.ItemUnits WHERE ItemId = l.ItemId AND IsBaseUnit = 1) END,
                        Quantity   = CASE WHEN r.Remaining % l.PackingFormula = 0 THEN r.Remaining / l.PackingFormula ELSE r.Remaining END,
                        UnitPrice  = CASE WHEN r.Remaining % l.PackingFormula = 0 THEN l.UnitPrice ELSE ROUND(l.UnitPrice / l.PackingFormula, 4) END) c
    WHERE l.DocumentId = @SourceId AND r.Remaining > 0;
    IF NOT EXISTS (SELECT 1 FROM @Lines) THROW 64010, 'Everything on this invoice was already returned.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Saved with the override allowed so the invoice prices are kept as given; then linked to the source lines.
        EXEC sales.usp_SalesDocument_Save @Id = NULL, @DocumentTypeCode = N'SRET', @DocumentDate = @DocumentDate, @DueDate = NULL,
             @BranchId = @BranchId, @WarehouseId = @WarehouseId, @ClientId = @ClientId, @SalesmanId = @SalesmanId, @PriceListId = @PriceListId,
             @RateType = @RateType, @ExchangeRate = @Rate, @ReferenceNo = @Ref, @Notes = NULL, @Lines = @Lines,
             @AllowPriceOverride = 1, @MaxDiscountPercent = 100, @DraftReference = NULL, @RowVersion = NULL, @UserId = @UserId, @NewId = @NewId OUTPUT;

        UPDATE n
        SET SourceLineId = s.Id, UnitCostBase = s.UnitCostBase
        FROM sales.SalesDocumentLines n
        INNER JOIN (SELECT ROW_NUMBER() OVER (ORDER BY l.LineNumber) AS Rn, l.Id, l.UnitCostBase
                    FROM sales.SalesDocumentLines l WHERE l.DocumentId = @SourceId AND l.QuantityBase - l.ReturnedQuantityBase > 0) s ON s.Rn = n.LineNumber
        WHERE n.DocumentId = @NewId;

        UPDATE sales.SalesDocuments SET SourceDocumentId = @SourceId WHERE Id = @NewId;
        INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@NewId, N'Created', N'Return draft created from ' + @Ref, @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

