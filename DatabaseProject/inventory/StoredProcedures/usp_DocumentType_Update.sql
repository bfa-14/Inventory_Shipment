-- unchanged, like @YearInNumber). Changing them changes no document already posted: an invoice captured its values.
CREATE   PROCEDURE inventory.usp_DocumentType_Update
    @Id              INT,
    @Name            NVARCHAR(100),
    @NumberPrefix    NVARCHAR(10),
    @NumberLength    TINYINT,
    @NumberOnPost    BIT,
    @RequiresReason  BIT,
    @DefaultPricing  NVARCHAR(10),
    @PriceEditable   BIT,
    @NumberPerBranch BIT,
    @IsActive        BIT,
    @RowVersion      BINARY(8) = NULL,
    @UserId          INT       = NULL,
    @YearInNumber    BIT       = NULL,    -- NULL = unchanged
    -- (79) NULL = unchanged (an older form never turns one off); each is refused on a type it does not apply to
    @AffectsItemCost      BIT = NULL,     -- PINV
    @AffectsOnHand        BIT = NULL,     -- PINV
    @AutoCreateOnDelivery BIT = NULL      -- GRN
AS
BEGIN
    SET NOCOUNT ON;
    SET @Name = NULLIF(LTRIM(RTRIM(@Name)), N'');
    SET @NumberPrefix = NULLIF(LTRIM(RTRIM(@NumberPrefix)), N'');
    IF @Name IS NULL THROW 62000, 'Name is required.', 1;
    IF @NumberPrefix IS NULL THROW 62000, 'Number prefix is required.', 1;
    IF @NumberLength IS NULL OR @NumberLength NOT BETWEEN 3 AND 10 THROW 62000, 'Number length must be between 3 and 10.', 1;
    IF @DefaultPricing NOT IN (N'Cost', N'PriceList', N'None') THROW 62000, 'Default pricing must be Cost, PriceList or None.', 1;
    IF NOT EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Id = @Id) THROW 62006, 'Document type not found.', 1;
    -- (79) a switch belongs to one type: sent for another, it would be stored and read by nothing
    DECLARE @Code NVARCHAR(20) = (SELECT Code FROM inventory.DocumentTypes WHERE Id = @Id);
    IF (@AffectsItemCost IS NOT NULL OR @AffectsOnHand IS NOT NULL) AND @Code <> N'PINV'
        THROW 62000, 'Affects item cost and Affects on-hand apply to the purchase invoice type (PINV) only.', 1;
    IF @AutoCreateOnDelivery IS NOT NULL AND @Code <> N'GRN'
        THROW 62000, 'Create goods receipts on Delivery applies to the goods receipt type (GRN) only.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 62004, 'This document type was modified by another user. Reload the page and try again.', 1;

    UPDATE inventory.DocumentTypes
    SET Name = @Name, NumberPrefix = @NumberPrefix, NumberLength = @NumberLength, NumberOnPost = ISNULL(@NumberOnPost, 0),
        RequiresReason = ISNULL(@RequiresReason, 0), DefaultPricing = @DefaultPricing, PriceEditable = ISNULL(@PriceEditable, 1),
        NumberPerBranch = ISNULL(@NumberPerBranch, 1), YearInNumber = ISNULL(@YearInNumber, YearInNumber), IsActive = ISNULL(@IsActive, 1),
        AffectsItemCost = ISNULL(@AffectsItemCost, AffectsItemCost), AffectsOnHand = ISNULL(@AffectsOnHand, AffectsOnHand),
        AutoCreateOnDelivery = ISNULL(@AutoCreateOnDelivery, AutoCreateOnDelivery),
        UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
END

GO

