/* ================================================================== 5. Candidates of a movement */

-- Re-created (49) from the body of script 46: + @ToPlaceId and @MovementTypeId (the page's, saved or not; NULL = the
-- saved movement's) for the place rules of an Origin-stage movement.
-- The containers that can join a movement (@MovementId NULL = a new one) leaving from @FromPlaceId (the From on the
-- page, saved or not): not on the movement, not offloaded / closed / cancelled. @IncludeBlocked = 1 also lists the
-- ones the checks of Save refuse (CanAdd 0, Reason). At most 200 rows a page; TotalCount for the paging.
CREATE   PROCEDURE logistics.usp_Movement_ContainerCandidates
    @MovementId      INT           = NULL,
    @FromPlaceId     INT,
    @Search          NVARCHAR(100) = NULL,   -- ref, container no., B/L, vessel, order no., supplier
    @PurchaseOrderId INT           = NULL,
    @SupplierId      INT           = NULL,
    @Status          TINYINT       = NULL,
    @IncludeBlocked  BIT           = 0,
    @PageNumber      INT           = 1,
    @PageSize        INT           = 200,
    @ToPlaceId       INT           = NULL,   -- (49) the To on the page
    @MovementTypeId  INT           = NULL    -- (49) the type on the page
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 OR @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @IncludeBlocked = ISNULL(@IncludeBlocked, 0);

    IF @FromPlaceId IS NULL THROW 70000, 'Choose the From first.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Ports WHERE Id = @FromPlaceId AND IsActive = 1)
        THROW 70000, 'The departure place is not found or inactive.', 1;
    IF @MovementId IS NOT NULL
    BEGIN
        DECLARE @MovementStatus TINYINT = (SELECT Status FROM logistics.Movements WHERE Id = @MovementId);
        IF @MovementStatus IS NULL THROW 70006, 'Movement not found.', 1;
        IF @MovementStatus NOT IN (1, 2) THROW 70005, 'A completed or cancelled movement can no longer be changed.', 1;
        SELECT @ToPlaceId = ISNULL(@ToPlaceId, ToPlaceId), @MovementTypeId = ISNULL(@MovementTypeId, MovementTypeId)
        FROM logistics.Movements WHERE Id = @MovementId;
    END

    SELECT f.ContainerId AS Id, f.ContainerRef, f.ContainerNo, f.SealNo, f.ContainerTypeCode, f.OrderNumbers, f.SupplierNames,
           f.ItemSummary, f.Pieces, f.Status, f.Eta, f.PlaceName, f.PreviousMovementNo, f.PortOfLoadingName,
           f.CanAdd, f.Reason, f.Note,
           COUNT(*) OVER () AS TotalCount
    FROM logistics.fn_Movement_ContainerCheck(@MovementId, @FromPlaceId, @ToPlaceId, @MovementTypeId) f
    WHERE f.OnMovement = 0 AND f.Status < 6
      AND (@IncludeBlocked = 1 OR f.CanAdd = 1)
      AND (@Status IS NULL OR f.Status = @Status)
      AND (@Search IS NULL OR f.ContainerRef LIKE N'%' + @Search + N'%' OR f.ContainerNo LIKE N'%' + @Search + N'%'
           OR f.BlNo LIKE N'%' + @Search + N'%' OR f.VesselName LIKE N'%' + @Search + N'%'
           OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                      INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                      INNER JOIN masterdata.Parties sp        ON sp.Id = d.SupplierId
                      WHERE cl.ContainerId = f.ContainerId
                        AND (d.DocumentNumber LIKE N'%' + @Search + N'%' OR sp.PartyName LIKE N'%' + @Search + N'%')))
      AND (@SupplierId IS NULL OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                                          INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                                          WHERE cl.ContainerId = f.ContainerId AND d.SupplierId = @SupplierId))
      AND (@PurchaseOrderId IS NULL OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                                               WHERE cl.ContainerId = f.ContainerId AND cl.PurchaseOrderId = @PurchaseOrderId))
    ORDER BY f.CanAdd DESC, f.OrderDate DESC, f.ContainerRef
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END

GO

