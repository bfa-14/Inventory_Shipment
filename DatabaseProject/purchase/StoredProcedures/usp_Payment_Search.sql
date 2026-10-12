/* ================================================================== 10. Search */

CREATE   PROCEDURE purchase.usp_Payment_Search
    @Search        NVARCHAR(100) = NULL,           -- number, reference, payee code / name, notes
    @PayeeId       INT           = NULL,
    @BranchId      INT           = NULL,
    @Status        TINYINT       = NULL,           -- 1 Draft | 2 Posted | 3 Reversed
    @PaymentType   TINYINT       = NULL,           -- 1 Free | 2 Purchase Invoice | 3 Container Charge
    @CurrencyId    INT           = NULL,
    @DateFrom      DATE          = NULL,
    @DateTo        DATE          = NULL,
    @SortColumn    NVARCHAR(30)  = N'PaymentDate', -- PaymentNumber | PaymentDate | PayeeName | Status | AmountBase | CreatedAtUtc
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
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'PaymentNumber', N'PaymentDate', N'PayeeName', N'Status', N'AmountBase', N'CreatedAtUtc')
        SET @SortColumn = N'PaymentDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT p.Id, p.PaymentNumber, p.PaymentDate, p.PayeeId, py.PartyCode AS PayeeCode, py.PartyName AS PayeeName,
           p.BranchId, b.BranchName, p.PaymentType, p.CurrencyId, c.CurrencyCode, c.DecimalPlaces,
           p.Amount, p.ExchangeRate, p.AmountBase, p.Reference, p.Status,
           Methods = (SELECT STRING_AGG(m.MethodName, N', ') WITHIN GROUP (ORDER BY m.MethodName)
                      FROM (SELECT DISTINCT pm.MethodName FROM purchase.PaymentLines l
                            INNER JOIN masterdata.PaymentMethods pm ON pm.Id = l.PaymentMethodId WHERE l.PaymentId = p.Id) m),
           AllocatedAmount = ISNULL(al.Total, 0),
           UnappliedAmount = CASE WHEN p.Status = 2 AND p.PaymentType = 1 THEN p.Amount - ISNULL(al.Total, 0) ELSE 0 END,
           DocumentCount   = ISNULL(al.Docs, 0),
           p.PostedAtUtc, pu.FullName AS PostedByName, p.ReversedAtUtc,
           p.CreatedAtUtc, cu.FullName AS CreatedByName, p.UpdatedAtUtc, p.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM purchase.Payments p
    INNER JOIN masterdata.Parties py   ON py.Id = p.PayeeId
    INNER JOIN masterdata.Branches b   ON b.Id = p.BranchId
    INNER JOIN masterdata.Currencies c ON c.Id = p.CurrencyId
    OUTER APPLY (SELECT Total = SUM(AmountPaymentCurrency), Docs = COUNT(*)
                 FROM purchase.PaymentAllocations WHERE PaymentId = p.Id AND RemovedAtUtc IS NULL) al
    LEFT  JOIN security.Users cu ON cu.Id = p.CreatedBy
    LEFT  JOIN security.Users pu ON pu.Id = p.PostedBy
    WHERE (@Search IS NULL OR p.PaymentNumber LIKE N'%' + @Search + N'%' OR p.Reference LIKE N'%' + @Search + N'%'
           OR py.PartyCode LIKE N'%' + @Search + N'%' OR py.PartyName LIKE N'%' + @Search + N'%' OR p.Notes LIKE N'%' + @Search + N'%')
      AND (@PayeeId IS NULL OR p.PayeeId = @PayeeId)
      AND (@BranchId IS NULL OR p.BranchId = @BranchId)
      AND (@Status IS NULL OR p.Status = @Status)
      AND (@PaymentType IS NULL OR p.PaymentType = @PaymentType)
      AND (@CurrencyId IS NULL OR p.CurrencyId = @CurrencyId)
      AND (@DateFrom IS NULL OR p.PaymentDate >= @DateFrom)
      AND (@DateTo IS NULL OR p.PaymentDate <= @DateTo)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'PaymentNumber' THEN p.PaymentNumber WHEN N'PayeeName' THEN py.PartyName END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'PaymentNumber' THEN p.PaymentNumber WHEN N'PayeeName' THEN py.PartyName END END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'PaymentDate' THEN p.PaymentDate END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'PaymentDate' THEN p.PaymentDate END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Status' THEN CAST(p.Status AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Status' THEN CAST(p.Status AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'AmountBase' THEN p.AmountBase END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'AmountBase' THEN p.AmountBase END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN p.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN p.CreatedAtUtc END DESC,
        p.PaymentDate DESC, p.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END

GO

