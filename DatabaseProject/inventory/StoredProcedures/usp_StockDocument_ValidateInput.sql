/* ==================================================================================================
   31: Inventory and purchase - the same day of date tolerance the sales invoice got
   --------------------------------------------------------------------------------------------------
   Script 30 gave sales.usp_SalesDocument_ValidateInput a day of tolerance on the document date,
   because the check compared a LOCAL date against a UTC one: at 00:20 in Beirut (UTC+3) it is still
   yesterday in UTC, so a document dated today was refused as being in the future.

   The same line sat in the inventory and purchase validators, so the same thing happened on an
   Inventory In and on a purchase invoice after midnight. They now match the sales rule.

   Nothing else in either procedure changes.
   ================================================================================================== */

CREATE   PROCEDURE inventory.usp_StockDocument_ValidateInput
    @DocumentTypeCode NVARCHAR(20),
    @DocumentDate     DATE,
    @BranchId         INT,
    @WarehouseId      INT = NULL,
    @ReasonId         INT,
    @Lines            inventory.tvp_StockDocumentLine READONLY,
    @DocumentTypeId   INT OUTPUT,
    @StockDirection   SMALLINT OUTPUT,
    @CurrencyId       INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RequiresReason BIT;
    SELECT @DocumentTypeId = Id, @StockDirection = StockDirection, @RequiresReason = RequiresReason
    FROM inventory.DocumentTypes WHERE Code = @DocumentTypeCode AND Family = N'Inventory' AND IsActive = 1;
    IF @DocumentTypeId IS NULL
        THROW 62008, 'Document type not found, inactive, or not an inventory document.', 1;

    IF @DocumentDate IS NULL THROW 62000, 'Document Date is required.', 1;
    /* ONE DAY OF TOLERANCE, because this compares a LOCAL date against a UTC one. The date on the
       document is the one the reader sees on their own clock; SYSUTCDATETIME() is the server's in
       UTC. East of Greenwich the two disagree for the first hours after midnight - at 00:20 in
       Beirut (UTC+3) it is still yesterday in UTC, so a document dated today was refused as being
       in the future. A day covers every offset without letting a genuinely future date through by
       more than one. */
    IF @DocumentDate > DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE))
        THROW 62000, 'Document Date cannot be in the future.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 62008, 'Branch not found or inactive.', 1;
    IF @WarehouseId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1 AND BranchId = @BranchId)
        THROW 62008, 'The default warehouse must be an active warehouse of the selected branch.', 1;
    IF @RequiresReason = 1 AND @ReasonId IS NULL THROW 62000, 'Reason is required.', 1;
    IF @ReasonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.StockReasons
                                             WHERE Id = @ReasonId AND IsActive = 1
                                               AND (AppliesTo = N'Both' OR (AppliesTo = N'In' AND @StockDirection = 1) OR (AppliesTo = N'Out' AND @StockDirection = -1)))
        THROW 62008, 'Reason not found, inactive, or not applicable to this document type.', 1;

    SELECT @CurrencyId = Id FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1;
    IF @CurrencyId IS NULL THROW 62008, 'No active base currency is configured.', 1;

    -- Per-line checks: the first failing line produces the message.
    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg =
        CASE WHEN i.Id IS NULL THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item not found.'
             WHEN i.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item ' + i.ItemCode + N' is inactive.'
             WHEN iu.Id IS NULL THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': the unit does not belong to item ' + i.ItemCode + N'.'
             WHEN w.Id IS NULL OR w.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse not found or inactive.'
             WHEN w.BranchId <> @BranchId THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is not available for the selected branch.'
             WHEN l.Quantity IS NULL OR l.Quantity <= 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': quantity must be greater than zero.'
             WHEN l.UnitCost IS NOT NULL AND l.UnitCost < 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': unit cost cannot be negative.'
        END
    FROM @Lines l
    LEFT JOIN inventory.Items i       ON i.Id = l.ItemId
    LEFT JOIN inventory.ItemUnits iu  ON iu.Id = l.ItemUnitId AND iu.ItemId = l.ItemId
    LEFT JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
    WHERE i.Id IS NULL OR i.IsActive = 0 OR iu.Id IS NULL OR w.Id IS NULL OR w.IsActive = 0 OR w.BranchId <> @BranchId
       OR l.Quantity IS NULL OR l.Quantity <= 0 OR (l.UnitCost IS NOT NULL AND l.UnitCost < 0)
    ORDER BY l.LineNumber;

    IF @Msg IS NOT NULL THROW 62000, @Msg, 1;
END

GO

