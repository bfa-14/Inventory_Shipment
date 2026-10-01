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
CREATE   PROCEDURE masterdata.usp_Party_Lookup
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

