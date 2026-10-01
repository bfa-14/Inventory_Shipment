/* ================================================================== 6. Cash / bank account procedures */

CREATE   PROCEDURE masterdata.usp_CashBankAccount_Search
    @Search        NVARCHAR(100) = NULL,
    @AccountType   NVARCHAR(10)  = NULL,
    @CurrencyId    INT           = NULL,
    @IsActive      BIT           = NULL,
    @SortColumn    NVARCHAR(30)  = N'AccountCode',   -- AccountCode | AccountName | AccountType | CurrencyCode | IsActive
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
    SET @AccountType = NULLIF(LTRIM(RTRIM(@AccountType)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'AccountCode', N'AccountName', N'AccountType', N'CurrencyCode', N'IsActive') SET @SortColumn = N'AccountCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT a.Id, a.AccountCode, a.AccountName, a.AccountType, a.CurrencyId, c.CurrencyCode,
           a.BranchId, BranchName = b.BranchName, a.Description, a.IsActive,
           UsedCount = (SELECT COUNT(*) FROM sales.ReceiptLines x WHERE x.CashBankAccountId = a.Id),
           a.CreatedAtUtc, a.CreatedBy, a.UpdatedAtUtc, a.UpdatedBy, a.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.CashBankAccounts a
    INNER JOIN masterdata.Currencies c ON c.Id = a.CurrencyId
    LEFT JOIN masterdata.Branches b ON b.Id = a.BranchId
    WHERE (@Search IS NULL OR a.AccountCode LIKE N'%' + @Search + N'%' OR a.AccountName LIKE N'%' + @Search + N'%')
      AND (@AccountType IS NULL OR a.AccountType = @AccountType)
      AND (@CurrencyId IS NULL OR a.CurrencyId = @CurrencyId)
      AND (@IsActive IS NULL OR a.IsActive = @IsActive)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'AccountCode' THEN a.AccountCode WHEN N'AccountName' THEN a.AccountName
                                                                 WHEN N'AccountType' THEN a.AccountType WHEN N'CurrencyCode' THEN c.CurrencyCode END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'AccountCode' THEN a.AccountCode WHEN N'AccountName' THEN a.AccountName
                                                                 WHEN N'AccountType' THEN a.AccountType WHEN N'CurrencyCode' THEN c.CurrencyCode END END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(a.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(a.IsActive AS INT) END DESC,
        a.AccountCode ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END

GO

