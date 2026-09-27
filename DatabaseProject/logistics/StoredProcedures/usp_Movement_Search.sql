/* ================================================================== 12. Shipment movements */

CREATE   PROCEDURE logistics.usp_Movement_Search
    @Search         NVARCHAR(100) = NULL,   -- movement no., vessel / truck, voyage, reference, container ref / no.
    @Status         TINYINT       = NULL,
    @MovementTypeId INT           = NULL,
    @PlaceId        INT           = NULL,   -- from or to
    @ContainerId    INT           = NULL,
    @CarrierPartyId INT           = NULL,
    @DateFrom       DATE          = NULL,   -- start date, else planned date
    @DateTo         DATE          = NULL,
    @SortColumn     NVARCHAR(30)  = N'StartDate',   -- MovementNo | StartDate | Eta | EndDate | Status | CreatedAtUtc
    @SortDirection  NVARCHAR(4)   = N'DESC',
    @PageNumber     INT           = 1,
    @PageSize       INT           = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'MovementNo', N'StartDate', N'Eta', N'EndDate', N'Status', N'CreatedAtUtc') SET @SortColumn = N'StartDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);
    DECLARE @Today DATE = CAST(SYSUTCDATETIME() AS DATE);

    SELECT m.Id, m.MovementNo, m.MovementTypeId, mt.TypeCode, mt.TypeName, mt.Stage,
           m.FromPlaceId, fp.PortCode AS FromCode, fp.PortName AS FromName, fp.Kind AS FromKind,
           m.ToPlaceId, tp.PortCode AS ToCode, tp.PortName AS ToName, tp.Kind AS ToKind,
           m.PlannedDate, m.StartDate, m.Eta, m.EndDate, m.Status,
           m.CarrierPartyId, cp.PartyName AS CarrierName, m.VehicleOrVessel, m.VoyageNo, m.Reference,
           ContainerCount = ISNULL(ctn.Cnt, 0),
           ContainerRefs = CASE WHEN ISNULL(ctn.Cnt, 0) = 0 THEN NULL WHEN ctn.Cnt = 1 THEN ctn.FirstRef
                                ELSE ctn.FirstRef + N' +' + CAST(ctn.Cnt - 1 AS NVARCHAR(10)) END,
           ChargesPostedBase = (SELECT SUM(ch.AmountBase) FROM logistics.ContainerCharges ch WHERE ch.MovementId = m.Id AND ch.Status = 2),
           AttachmentCount = (SELECT COUNT(*) FROM logistics.ContainerAttachments a WHERE a.MovementId = m.Id),
           DurationDays = CASE WHEN m.StartDate IS NOT NULL THEN DATEDIFF(DAY, m.StartDate, ISNULL(m.EndDate, @Today)) END,
           IsLate = CAST(CASE WHEN m.Status IN (1, 2) AND m.Eta < @Today THEN 1 ELSE 0 END AS BIT),
           m.CreatedAtUtc, cu.FullName AS CreatedByName, m.UpdatedAtUtc, m.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM logistics.Movements m
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    INNER JOIN masterdata.Ports fp         ON fp.Id = m.FromPlaceId
    INNER JOIN masterdata.Ports tp         ON tp.Id = m.ToPlaceId
    LEFT  JOIN masterdata.Parties cp       ON cp.Id = m.CarrierPartyId
    LEFT  JOIN security.Users cu           ON cu.Id = m.CreatedBy
    OUTER APPLY (SELECT Cnt = COUNT(*), FirstRef = MIN(c.ContainerRef)
                 FROM logistics.MovementContainers mc INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
                 WHERE mc.MovementId = m.Id) ctn
    WHERE (@Search IS NULL OR m.MovementNo LIKE N'%' + @Search + N'%' OR m.VehicleOrVessel LIKE N'%' + @Search + N'%'
           OR m.VoyageNo LIKE N'%' + @Search + N'%' OR m.Reference LIKE N'%' + @Search + N'%'
           OR EXISTS (SELECT 1 FROM logistics.MovementContainers mc INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
                      WHERE mc.MovementId = m.Id AND (c.ContainerRef LIKE N'%' + @Search + N'%' OR c.ContainerNo LIKE N'%' + @Search + N'%')))
      AND (@Status IS NULL OR m.Status = @Status)
      AND (@MovementTypeId IS NULL OR m.MovementTypeId = @MovementTypeId)
      AND (@PlaceId IS NULL OR m.FromPlaceId = @PlaceId OR m.ToPlaceId = @PlaceId)
      AND (@CarrierPartyId IS NULL OR m.CarrierPartyId = @CarrierPartyId)
      AND (@ContainerId IS NULL OR EXISTS (SELECT 1 FROM logistics.MovementContainers mc WHERE mc.MovementId = m.Id AND mc.ContainerId = @ContainerId))
      AND (@DateFrom IS NULL OR COALESCE(m.StartDate, m.PlannedDate) >= @DateFrom)
      AND (@DateTo IS NULL OR COALESCE(m.StartDate, m.PlannedDate) <= @DateTo)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'MovementNo' THEN m.MovementNo END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'MovementNo' THEN m.MovementNo END DESC,
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'StartDate' THEN COALESCE(m.StartDate, m.PlannedDate) WHEN N'Eta' THEN m.Eta WHEN N'EndDate' THEN m.EndDate END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'StartDate' THEN COALESCE(m.StartDate, m.PlannedDate) WHEN N'Eta' THEN m.Eta WHEN N'EndDate' THEN m.EndDate END END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Status' THEN CAST(m.Status AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Status' THEN CAST(m.Status AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN m.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN m.CreatedAtUtc END DESC,
        m.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END

GO

