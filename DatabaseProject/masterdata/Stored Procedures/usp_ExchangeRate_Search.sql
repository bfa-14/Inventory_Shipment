/* ------------------------------------------------------------------ 4. Exchange rate procedures */

CREATE   PROCEDURE masterdata.usp_ExchangeRate_Search
    @CurrencyId    INT          = NULL,          -- NULL = all currencies
    @RateType      TINYINT      = NULL,          -- NULL = all types (1 Official | 2 NonOfficial | 3 Market)
    @DateFrom      DATE         = NULL,
    @DateTo        DATE         = NULL,
    @SortColumn    NVARCHAR(30) = N'RateDate',   -- RateDate | CurrencyCode | RateType | Rate | CreatedAtUtc
    @SortDirection NVARCHAR(4)  = N'DESC',
    @PageNumber    INT          = 1,
    @PageSize      INT          = 10
AS
BEGIN
    SET NOCOUNT ON;

    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'RateDate', N'CurrencyCode', N'RateType', N'Rate', N'CreatedAtUtc')
        SET @SortColumn = N'RateDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC')
        SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT er.Id, er.CurrencyId, c.CurrencyCode, c.CurrencyName, c.Symbol, c.DecimalPlaces,
           er.RateType, er.RateDate, er.Rate, er.Notes,
           er.CreatedAtUtc, er.CreatedBy, er.UpdatedAtUtc, er.UpdatedBy, er.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.ExchangeRates er
    INNER JOIN masterdata.Currencies c ON c.Id = er.CurrencyId
    WHERE (@CurrencyId IS NULL OR er.CurrencyId = @CurrencyId)
      AND (@RateType   IS NULL OR er.RateType = @RateType)
      AND (@DateFrom   IS NULL OR er.RateDate >= @DateFrom)
      AND (@DateTo     IS NULL OR er.RateDate <= @DateTo)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'RateDate' THEN er.RateDate END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'RateDate' THEN er.RateDate END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CurrencyCode' THEN c.CurrencyCode END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CurrencyCode' THEN c.CurrencyCode END DESC,
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'RateType' THEN CAST(er.RateType AS INT) END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'RateType' THEN CAST(er.RateType AS INT) END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Rate' THEN er.Rate END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Rate' THEN er.Rate END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN er.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN er.CreatedAtUtc END DESC,
        er.RateDate DESC, c.CurrencyCode ASC, er.RateType ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END