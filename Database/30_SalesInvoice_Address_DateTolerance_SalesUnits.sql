/* ==================================================================================================
   30: Sales invoice - client address, a day of date tolerance, sales-only units
   --------------------------------------------------------------------------------------------------
   Three fixes, all reached from the sales invoice:

   1. masterdata.usp_Party_Lookup returns Address, so the invoice header can show the client's
      address as the Parties page holds it. Every other caller simply gets one more column.

   2. sales.usp_SalesDocument_ValidateInput allows the document date to be one day ahead. The check
      compared a LOCAL date against a UTC one: at 00:20 in Beirut (UTC+3) it is still yesterday in
      UTC, so saving a draft dated today was refused as being in the future.

   3. inventory.usp_Item_Lookup takes @SalesOnly. With 1 it returns only items that have at least
      one unit flagged IsSalesUnit, and reports that unit as the base one so the picker offers a
      sellable unit first. The default is 0, so inventory and purchase are unchanged.
   ================================================================================================== */

/* ---------------------------------------------------------------- 1. Party lookup: Address */
CREATE OR ALTER PROCEDURE masterdata.usp_Party_Lookup
    @Search     NVARCHAR(200) = NULL,
    @PartyType  NVARCHAR(20)  = NULL,
    @ActiveOnly BIT           = 1,
    @IncludeId  INT           = NULL,
    @Top        INT           = 50
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @PartyType = NULLIF(LTRIM(RTRIM(@PartyType)), N'');
    IF @Top IS NULL OR @Top < 1 SET @Top = 50;
    IF @Top > 500 SET @Top = 500;

    SELECT TOP (@Top) p.Id, p.PartyCode, p.PartyName, p.IsSupplier, p.IsClient, p.IsSalesman, p.IsEmployee,
           p.BranchId, p.DefaultPriceListId, p.DefaultCurrencyId, p.UserId, p.IsActive,
           p.Address
    FROM masterdata.Parties p
    WHERE (@ActiveOnly = 0 OR p.IsActive = 1 OR p.Id = @IncludeId)
      AND (@PartyType IS NULL
           OR (@PartyType = N'Supplier' AND p.IsSupplier = 1)
           OR (@PartyType = N'Client'   AND p.IsClient   = 1)
           OR (@PartyType = N'Salesman' AND p.IsSalesman = 1)
           OR (@PartyType = N'Employee' AND p.IsEmployee = 1)
           OR p.Id = @IncludeId)
      AND (@Search IS NULL OR p.PartyCode LIKE N'%' + @Search + N'%' OR p.PartyName LIKE N'%' + @Search + N'%')
    ORDER BY CASE WHEN p.PartyCode LIKE @Search + N'%' THEN 0 ELSE 1 END, p.PartyName;
END
GO

/* ---------------------------------------------------------------- 3. Item lookup: sales units only */
CREATE OR ALTER PROCEDURE inventory.usp_Item_Lookup
    @Search     NVARCHAR(200) = NULL,
    @ActiveOnly BIT           = 1,
    @IncludeId  INT           = NULL,
    @Top        INT           = 20,
    /* 1 = only items with a unit that may be sold. The sales invoice passes it; everything else
       leaves it 0 and sees every item, because an inventory count or a purchase is not a sale. */
    @SalesOnly  BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @SalesOnly = ISNULL(@SalesOnly, 0);
    IF @Top IS NULL OR @Top < 1 SET @Top = 20;
    IF @Top > 200 SET @Top = 200;

    /* THE REPORTED UNIT FOLLOWS THE FILTER. With @SalesOnly the picker should land on a unit it is
       allowed to sell, so the sales unit is preferred over the base one; the base unit is still the
       fallback, and is what every other caller gets. */
    SELECT TOP (@Top) i.Id, i.ItemCode, i.ItemName, i.IsActive,
           ut.UnitTypeName AS BaseUnitName, bu.Id AS BaseUnitId
    FROM inventory.Items i
    OUTER APPLY (
        SELECT TOP (1) u.Id, u.UnitTypeId
        FROM inventory.ItemUnits u
        WHERE u.ItemId = i.Id
          AND (@SalesOnly = 0 OR u.IsSalesUnit = 1)
        ORDER BY CASE WHEN @SalesOnly = 1 AND u.IsSalesUnit = 1 THEN 0
                      WHEN u.IsBaseUnit = 1 THEN 1
                      ELSE 2 END, u.Id
    ) bu
    LEFT JOIN masterdata.UnitTypes ut ON ut.Id = bu.UnitTypeId
    WHERE (@ActiveOnly = 0 OR i.IsActive = 1 OR i.Id = @IncludeId)
      AND (@Search IS NULL OR i.ItemCode LIKE N'%' + @Search + N'%' OR i.ItemName LIKE N'%' + @Search + N'%')
      /* AN ITEM WITH NO SELLABLE UNIT IS NOT OFFERED - except the one the caller names with
         @IncludeId, so a saved line whose item was since taken off sale still resolves. */
      AND (@SalesOnly = 0 OR i.Id = @IncludeId
           OR EXISTS (SELECT 1 FROM inventory.ItemUnits su WHERE su.ItemId = i.Id AND su.IsSalesUnit = 1))
    ORDER BY CASE WHEN i.ItemCode LIKE @Search + N'%' THEN 0 ELSE 1 END, i.ItemCode;
END
GO

/* ---------------------------------------------------------------- 2. Sales date tolerance */
CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_ValidateInput
    @DocumentTypeCode   NVARCHAR(20),
    @DocumentDate       DATE,
    @DueDate            DATE,
    @BranchId           INT,
    @WarehouseId        INT = NULL,
    @ClientId           INT,
    @SalesmanId         INT,
    @PriceListId        INT,
    @RateType           TINYINT,
    @ExchangeRate       DECIMAL(18,6),
    @MaxDiscountPercent DECIMAL(9,4),
    @Lines              sales.tvp_SalesDocumentLine READONLY,
    @DocumentTypeId     INT OUTPUT,
    @StockDirection     SMALLINT OUTPUT,
    @CurrencyId         INT OUTPUT,
    @ResolvedRate       DECIMAL(18,6) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT @DocumentTypeId = Id, @StockDirection = StockDirection
    FROM inventory.DocumentTypes WHERE Code = @DocumentTypeCode AND Family = N'Sales' AND IsActive = 1;
    IF @DocumentTypeId IS NULL THROW 64008, 'Document type not found, inactive, or not a sales document.', 1;

    IF @DocumentDate IS NULL THROW 64000, 'Document Date is required.', 1;
    /* ONE DAY OF TOLERANCE, because this compares a LOCAL date against a UTC one. The date on the
       document is the one the reader sees on their own clock; SYSUTCDATETIME() is the server's in
       UTC. East of Greenwich the two disagree for the first hours after midnight - at 00:20 in
       Beirut (UTC+3) it is still yesterday in UTC, so a document dated today was refused as being
       in the future. A day covers every offset without letting a genuinely future date through by
       more than one. */
    IF @DocumentDate > DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE))
        THROW 64000, 'Document Date cannot be in the future.', 1;
    IF @DueDate IS NOT NULL AND @DueDate < @DocumentDate THROW 64000, 'Due Date cannot be before the Document Date.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 64008, 'Branch not found or inactive.', 1;
    IF @WarehouseId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1 AND BranchId = @BranchId)
        THROW 64008, 'The default warehouse must be an active warehouse of the selected branch.', 1;
    IF @ClientId IS NULL THROW 64000, 'Client is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @ClientId AND IsClient = 1 AND IsActive = 1)
        THROW 64008, 'Client not found, inactive, or not flagged as a client.', 1;
    IF @SalesmanId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SalesmanId AND IsSalesman = 1 AND IsActive = 1)
        THROW 64008, 'Salesman not found, inactive, or not flagged as a salesman.', 1;
    IF @PriceListId IS NULL THROW 64000, 'Price List is required.', 1;

    SELECT @CurrencyId = CurrencyId FROM masterdata.PriceLists WHERE Id = @PriceListId AND IsActive = 1;
    IF @CurrencyId IS NULL THROW 64008, 'Price list not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsActive = 1)
        THROW 64008, 'The price list currency is inactive.', 1;

    IF @RateType IS NULL OR @RateType NOT IN (1, 2, 3) THROW 64000, 'Rate type must be Official, Non-official or Market.', 1;
    IF @ExchangeRate IS NOT NULL AND @ExchangeRate <= 0 THROW 64000, 'Exchange rate must be greater than zero.', 1;

    SET @ResolvedRate = COALESCE(@ExchangeRate, masterdata.fn_GetRate(@CurrencyId, @RateType, @DocumentDate));
    IF EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsBaseCurrency = 1) SET @ResolvedRate = 1;
    IF @ResolvedRate IS NULL
    BEGIN
        DECLARE @Cur NVARCHAR(3) = (SELECT CurrencyCode FROM masterdata.Currencies WHERE Id = @CurrencyId);
        DECLARE @RateMsg NVARCHAR(300) = N'No ' + CASE @RateType WHEN 1 THEN N'official' WHEN 2 THEN N'non-official' ELSE N'market' END
                                       + N' exchange rate is defined for ' + @Cur + N' on or before ' + CONVERT(NVARCHAR(10), @DocumentDate, 120)
                                       + N'. Add one in Master Data > Exchange Rates or enter the rate manually.';
        THROW 64008, @RateMsg, 1;
    END

    IF @MaxDiscountPercent IS NULL OR @MaxDiscountPercent < 0 SET @MaxDiscountPercent = 0;
    IF @MaxDiscountPercent > 100 SET @MaxDiscountPercent = 100;

    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg =
        N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' +
        CASE WHEN i.Id IS NULL THEN N'item not found.'
             WHEN i.IsActive = 0 THEN N'item ' + i.ItemCode + N' is inactive.'
             WHEN iu.Id IS NULL THEN N'the unit does not belong to item ' + i.ItemCode + N'.'
             WHEN w.Id IS NULL OR w.IsActive = 0 THEN N'warehouse not found or inactive.'
             WHEN w.BranchId <> @BranchId THEN N'warehouse ' + w.WarehouseCode + N' is not available for the selected branch.'
             WHEN l.Quantity IS NULL OR l.Quantity <= 0 THEN N'quantity must be greater than zero.'
             WHEN l.UnitPrice IS NOT NULL AND l.UnitPrice < 0 THEN N'unit price cannot be negative.'
             WHEN l.DiscountPercent IS NOT NULL AND (l.DiscountPercent < 0 OR l.DiscountPercent > @MaxDiscountPercent)
                  THEN N'discount must be between 0 and ' + CAST(CAST(@MaxDiscountPercent AS DECIMAL(9,2)) AS NVARCHAR(12)) + N'%.'
        END
    FROM @Lines l
    LEFT JOIN inventory.Items i      ON i.Id = l.ItemId
    LEFT JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId AND iu.ItemId = l.ItemId
    LEFT JOIN masterdata.Warehouses w  ON w.Id = l.WarehouseId
    WHERE i.Id IS NULL OR i.IsActive = 0 OR iu.Id IS NULL OR w.Id IS NULL OR w.IsActive = 0 OR w.BranchId <> @BranchId
       OR l.Quantity IS NULL OR l.Quantity <= 0 OR (l.UnitPrice IS NOT NULL AND l.UnitPrice < 0)
       OR (l.DiscountPercent IS NOT NULL AND (l.DiscountPercent < 0 OR l.DiscountPercent > @MaxDiscountPercent))
    ORDER BY l.LineNumber;

    IF @Msg IS NOT NULL THROW 64000, @Msg, 1;
END

GO
