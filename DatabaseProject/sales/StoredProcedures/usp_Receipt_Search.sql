CREATE   PROCEDURE sales.usp_Receipt_Search
    @Search        NVARCHAR(100) = NULL,           -- number, customer code / name, notes
    @ClientId      INT           = NULL,
    @BranchId      INT           = NULL,
    @Status        TINYINT       = NULL,           -- 1 Draft | 2 Posted | 3 Reversed
    @PaymentType   TINYINT       = NULL,           -- 1 Free Receipt | 2 Sales Allocation
    @CurrencyId    INT           = NULL,
    @DateFrom      DATE          = NULL,
    @DateTo        DATE          = NULL,
    @SortColumn    NVARCHAR(30)  = N'ReceiptDate', -- ReceiptNumber | ReceiptDate | ClientName | Status | AmountBase | CreatedAtUtc
    @SortDirection NVARCHAR(4)   = N'DESC',
    @PageNumber    INT           = 1,
    @PageSize      INT           = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'ReceiptNumber', N'ReceiptDate', N'ClientName', N'Status', N'AmountBase', N'CreatedAtUtc')
        SET @SortColumn = N'ReceiptDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT r.Id, r.ReceiptNumber, r.ReceiptDate, r.ClientId, cl.PartyCode AS ClientCode, cl.PartyName AS ClientName,
           r.BranchId, b.BranchName, r.PaymentType, r.CurrencyId, c.CurrencyCode, c.DecimalPlaces,
           r.Amount, r.ExchangeRate, r.AmountBase, r.Status,
           r.SourceSalesDocumentId, SourceInvoiceNumber = sd.DocumentNumber,
           AllocatedBase = ISNULL(al.Base, 0),
           UnappliedBase = CASE WHEN r.Status = 2 AND r.PaymentType = 1 THEN r.AmountBase - ISNULL(al.Base, 0) ELSE 0 END,
           r.PostedAtUtc, pu.FullName AS PostedByName, r.ReversedAtUtc,
           r.CreatedAtUtc, cu.FullName AS CreatedByName, r.UpdatedAtUtc, r.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM sales.Receipts r
    INNER JOIN masterdata.Parties cl   ON cl.Id = r.ClientId
    INNER JOIN masterdata.Branches b   ON b.Id = r.BranchId
    INNER JOIN masterdata.Currencies c ON c.Id = r.CurrencyId
    OUTER APPLY (SELECT Base = SUM(AmountBase) FROM sales.ReceiptAllocations WHERE ReceiptId = r.Id AND RemovedAtUtc IS NULL) al
    LEFT  JOIN security.Users cu ON cu.Id = r.CreatedBy
    LEFT  JOIN security.Users pu ON pu.Id = r.PostedBy
    LEFT  JOIN sales.SalesDocuments sd ON sd.Id = r.SourceSalesDocumentId
    WHERE (@Search IS NULL OR r.ReceiptNumber LIKE N'%' + @Search + N'%' OR cl.PartyCode LIKE N'%' + @Search + N'%'
           OR cl.PartyName LIKE N'%' + @Search + N'%' OR r.Notes LIKE N'%' + @Search + N'%')
      AND (@ClientId IS NULL OR r.ClientId = @ClientId)
      AND (@BranchId IS NULL OR r.BranchId = @BranchId)
      AND (@Status IS NULL OR r.Status = @Status)
      AND (@PaymentType IS NULL OR r.PaymentType = @PaymentType)
      AND (@CurrencyId IS NULL OR r.CurrencyId = @CurrencyId)
      AND (@DateFrom IS NULL OR r.ReceiptDate >= @DateFrom)
      AND (@DateTo IS NULL OR r.ReceiptDate <= @DateTo)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'ReceiptNumber' THEN r.ReceiptNumber WHEN N'ClientName' THEN cl.PartyName END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'ReceiptNumber' THEN r.ReceiptNumber WHEN N'ClientName' THEN cl.PartyName END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'ReceiptDate' THEN r.ReceiptDate END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'ReceiptDate' THEN r.ReceiptDate END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Status' THEN CAST(r.Status AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Status' THEN CAST(r.Status AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'AmountBase' THEN r.AmountBase END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'AmountBase' THEN r.AmountBase END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN r.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN r.CreatedAtUtc END DESC,
        r.ReceiptDate DESC, r.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END

GO

