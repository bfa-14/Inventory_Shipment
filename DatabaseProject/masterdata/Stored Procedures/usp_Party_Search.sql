
/* ------------------------------------------------------------------ 2. Procedures */

CREATE   PROCEDURE masterdata.usp_Party_Search
    @Search        NVARCHAR(200) = NULL,   -- code, name, phone, mobile or email
    @PartyType     NVARCHAR(20)  = NULL,   -- Supplier | Client | Salesman | Employee | NULL = all
    @BranchId      INT           = NULL,
    @IsActive      BIT           = NULL,
    @SortColumn    NVARCHAR(30)  = N'PartyCode', -- PartyCode | PartyName | BranchName | Email | Phone | IsActive | CreatedAtUtc
    @SortDirection NVARCHAR(4)   = N'ASC',
    @PageNumber    INT           = 1,
    @PageSize      INT           = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @PartyType = NULLIF(LTRIM(RTRIM(@PartyType)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'PartyCode', N'PartyName', N'BranchName', N'Email', N'Phone', N'IsActive', N'CreatedAtUtc')
        SET @SortColumn = N'PartyCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT p.Id, p.PartyCode, p.PartyName, p.IsSupplier, p.IsClient, p.IsSalesman, p.IsEmployee,
           p.BranchId, b.BranchCode, b.BranchName, p.ContactPerson, p.Phone, p.Mobile, p.Email,
           p.Address, p.Country, p.TaxRegistrationNo, p.Notes,
           p.UserId, u.Username AS UserName, u.FullName AS UserFullName,
           p.DefaultPriceListId, pl.PriceListName AS DefaultPriceListName,
           p.DefaultCurrencyId, c.CurrencyCode AS DefaultCurrencyCode,
           p.IsActive, p.CreatedAtUtc, p.CreatedBy, p.UpdatedAtUtc, p.UpdatedBy, p.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.Parties p
    LEFT JOIN masterdata.Branches b    ON b.Id  = p.BranchId
    LEFT JOIN security.Users u         ON u.Id  = p.UserId
    LEFT JOIN masterdata.PriceLists pl ON pl.Id = p.DefaultPriceListId
    LEFT JOIN masterdata.Currencies c  ON c.Id  = p.DefaultCurrencyId
    WHERE (@Search IS NULL OR p.PartyCode LIKE N'%' + @Search + N'%' OR p.PartyName LIKE N'%' + @Search + N'%'
           OR p.Phone LIKE N'%' + @Search + N'%' OR p.Mobile LIKE N'%' + @Search + N'%' OR p.Email LIKE N'%' + @Search + N'%')
      AND (@PartyType IS NULL
           OR (@PartyType = N'Supplier' AND p.IsSupplier = 1)
           OR (@PartyType = N'Client'   AND p.IsClient   = 1)
           OR (@PartyType = N'Salesman' AND p.IsSalesman = 1)
           OR (@PartyType = N'Employee' AND p.IsEmployee = 1))
      AND (@BranchId IS NULL OR p.BranchId = @BranchId)
      AND (@IsActive IS NULL OR p.IsActive = @IsActive)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'PartyCode' THEN p.PartyCode WHEN N'PartyName' THEN p.PartyName
                             WHEN N'BranchName' THEN b.BranchName WHEN N'Email' THEN p.Email WHEN N'Phone' THEN p.Phone END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'PartyCode' THEN p.PartyCode WHEN N'PartyName' THEN p.PartyName
                             WHEN N'BranchName' THEN b.BranchName WHEN N'Email' THEN p.Email WHEN N'Phone' THEN p.Phone END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(p.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(p.IsActive AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN p.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN p.CreatedAtUtc END DESC,
        p.PartyCode ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END