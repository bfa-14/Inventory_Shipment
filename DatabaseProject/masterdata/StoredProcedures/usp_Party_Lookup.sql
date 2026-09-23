CREATE   PROCEDURE masterdata.usp_Party_Lookup
    @PartyType  NVARCHAR(20)  = NULL,   -- Supplier | Client | Salesman | Employee | NULL = any
    @Search     NVARCHAR(200) = NULL,
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
           p.BranchId, p.DefaultPriceListId, p.DefaultCurrencyId, p.UserId, p.IsActive
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

