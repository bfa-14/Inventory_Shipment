CREATE   PROCEDURE logistics.usp_ContainerCharge_Search
    @Search          NVARCHAR(100) = NULL,   -- container ref / no., reference, description, provider
    @ContainerId     INT           = NULL,
    @MovementId      INT           = NULL,
    @ChargeTypeId    INT           = NULL,
    @ProviderPartyId INT           = NULL,
    @Status          TINYINT       = NULL,
    @DateFrom        DATE          = NULL,
    @DateTo          DATE          = NULL,
    @SortColumn      NVARCHAR(30)  = N'ChargeDate',   -- ChargeDate | ContainerRef | ChargeName | AmountBase | Status | CreatedAtUtc
    @SortDirection   NVARCHAR(4)   = N'DESC',
    @PageNumber      INT           = 1,
    @PageSize        INT           = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'ChargeDate', N'ContainerRef', N'ChargeName', N'AmountBase', N'Status', N'CreatedAtUtc') SET @SortColumn = N'ChargeDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT ch.Id, ch.ContainerId, c.ContainerRef, c.ContainerNo, c.Status AS ContainerStatus,
           ch.MovementId, m.MovementNo, ch.GroupId,
           GroupSize = CASE WHEN ch.GroupId IS NULL THEN 1 ELSE (SELECT COUNT(*) FROM logistics.ContainerCharges g WHERE g.GroupId = ch.GroupId) END,
           ch.ChargeTypeId, t.ChargeCode, t.ChargeName, ch.Description, ch.ProviderPartyId, pp.PartyName AS ProviderName, ch.Reference,
           ch.ChargeDate, ch.CurrencyId, cur.CurrencyCode, ch.RateType, ch.ExchangeRate, ch.Amount, ch.AmountBase,
           ch.AllocationMethod, ch.IncludeInLandedCost, ch.Status, ch.AppliedAtOffload, ch.AdjustedAfterOffload,
           AttachmentCount = (SELECT COUNT(*) FROM logistics.ContainerAttachments a WHERE a.ChargeId = ch.Id),
           ch.PostedAtUtc, ch.CreatedAtUtc, cu.FullName AS CreatedByName, ch.RowVersion,
           TotalAmountBase = SUM(ch.AmountBase) OVER (),
           COUNT(*) OVER () AS TotalCount
    FROM logistics.ContainerCharges ch
    INNER JOIN logistics.Containers c    ON c.Id = ch.ContainerId
    INNER JOIN purchase.ChargeTypes t    ON t.Id = ch.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = ch.CurrencyId
    LEFT  JOIN masterdata.Parties pp     ON pp.Id = ch.ProviderPartyId
    LEFT  JOIN logistics.Movements m     ON m.Id = ch.MovementId
    LEFT  JOIN security.Users cu         ON cu.Id = ch.CreatedBy
    WHERE (@Search IS NULL OR c.ContainerRef LIKE N'%' + @Search + N'%' OR c.ContainerNo LIKE N'%' + @Search + N'%'
           OR ch.Reference LIKE N'%' + @Search + N'%' OR ch.Description LIKE N'%' + @Search + N'%' OR pp.PartyName LIKE N'%' + @Search + N'%')
      AND (@ContainerId IS NULL OR ch.ContainerId = @ContainerId)
      AND (@MovementId IS NULL OR ch.MovementId = @MovementId)
      AND (@ChargeTypeId IS NULL OR ch.ChargeTypeId = @ChargeTypeId)
      AND (@ProviderPartyId IS NULL OR ch.ProviderPartyId = @ProviderPartyId)
      AND (@Status IS NULL OR ch.Status = @Status)
      AND (@DateFrom IS NULL OR ch.ChargeDate >= @DateFrom)
      AND (@DateTo IS NULL OR ch.ChargeDate <= @DateTo)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'ContainerRef' THEN c.ContainerRef WHEN N'ChargeName' THEN t.ChargeName END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'ContainerRef' THEN c.ContainerRef WHEN N'ChargeName' THEN t.ChargeName END END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'ChargeDate' THEN ch.ChargeDate END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'ChargeDate' THEN ch.ChargeDate END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'AmountBase' THEN ch.AmountBase END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'AmountBase' THEN ch.AmountBase END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Status' THEN CAST(ch.Status AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Status' THEN CAST(ch.Status AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN ch.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN ch.CreatedAtUtc END DESC,
        ch.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END

GO

