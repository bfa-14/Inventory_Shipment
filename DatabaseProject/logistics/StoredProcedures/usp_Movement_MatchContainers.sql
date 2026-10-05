/* ================================================================== 6. Container numbers matched for a movement */

-- Re-created (49) from the body of script 46: + @ToPlaceId and @MovementTypeId, as the candidates.
-- One row per number (empty ones ignored), in the input order. Result: Ready | AlreadyOnMovement | NotFound |
-- Ambiguous | Blocked | Duplicate; Reason and Note are the texts of the candidates (fn_Movement_ContainerCheck).
CREATE   PROCEDURE logistics.usp_Movement_MatchContainers
    @MovementId  INT = NULL,
    @FromPlaceId INT,
    @Numbers     logistics.tvp_TextList READONLY,
    @ToPlaceId      INT = NULL,   -- (49) the To on the page
    @MovementTypeId INT = NULL    -- (49) the type on the page
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Rows TABLE (RowNo INT NOT NULL PRIMARY KEY, InputNumber NVARCHAR(100) NOT NULL, NumberKey NVARCHAR(100) NOT NULL,
                         Hits INT NULL, OpenHits INT NULL, ContainerId INT NULL);
    INSERT INTO @Rows (RowNo, InputNumber, NumberKey)
    SELECT n.RowNo, LTRIM(RTRIM(n.Value)), k.NumberKey
    FROM @Numbers n
    CROSS APPLY logistics.fn_ContainerNumberKey(n.Value) k
    WHERE k.NumberKey <> N'';
    IF (SELECT COUNT(*) FROM @Rows) > 500 THROW 70000, 'At most 500 container numbers at a time.', 1;

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

    -- the containers of every number: the container number first, then the ref
    DECLARE @Hits TABLE (RowNo INT NOT NULL, ContainerId INT NOT NULL, ContainerRef NVARCHAR(30) NOT NULL, IsOpen BIT NOT NULL,
                         PRIMARY KEY (RowNo, ContainerId));
    INSERT INTO @Hits (RowNo, ContainerId, ContainerRef, IsOpen)
    SELECT r.RowNo, c.Id, c.ContainerRef, CASE WHEN c.Status < 6 THEN 1 ELSE 0 END
    FROM logistics.Containers c
    CROSS APPLY logistics.fn_ContainerNumberKey(c.ContainerNo) k
    INNER JOIN @Rows r ON r.NumberKey = k.NumberKey;

    INSERT INTO @Hits (RowNo, ContainerId, ContainerRef, IsOpen)
    SELECT r.RowNo, c.Id, c.ContainerRef, CASE WHEN c.Status < 6 THEN 1 ELSE 0 END
    FROM logistics.Containers c
    CROSS APPLY logistics.fn_ContainerNumberKey(c.ContainerRef) k
    INNER JOIN @Rows r ON r.NumberKey = k.NumberKey
    WHERE NOT EXISTS (SELECT 1 FROM @Hits h WHERE h.RowNo = r.RowNo);

    -- one container per number: an open one wins over offloaded / closed / cancelled ones, two open ones are ambiguous
    UPDATE r
    SET Hits = h.Hits, OpenHits = h.OpenHits, ContainerId = CASE WHEN h.OpenHits > 1 THEN NULL ELSE pick.ContainerId END
    FROM @Rows r
    CROSS APPLY (SELECT Hits = COUNT(*), OpenHits = ISNULL(SUM(CAST(x.IsOpen AS INT)), 0) FROM @Hits x WHERE x.RowNo = r.RowNo) h
    OUTER APPLY (SELECT TOP (1) x.ContainerId FROM @Hits x WHERE x.RowNo = r.RowNo ORDER BY x.IsOpen DESC, x.ContainerId DESC) pick;

    WITH d AS
    (
        SELECT r.RowNo, r.InputNumber, r.Hits, r.OpenHits, r.ContainerId,
               FirstRowNo = MIN(r.RowNo) OVER (PARTITION BY CASE WHEN r.ContainerId IS NOT NULL
                                                                 THEN N'C' + CAST(r.ContainerId AS NVARCHAR(12))
                                                                 ELSE N'N' + r.NumberKey END)
        FROM @Rows r
    )
    SELECT d.RowNo, d.InputNumber, x.Result,
           f.ContainerId, f.ContainerRef, f.ContainerNo, f.ContainerTypeCode, f.Status, f.OrderNumbers, f.SupplierNames,
           f.ItemSummary, f.Pieces, f.PlaceName, f.PreviousMovementNo, f.PortOfLoadingName,
           Reason = CAST(CASE x.Result
                         WHEN N'Duplicate' THEN N'Already in the list, row ' + CAST(d.FirstRowNo AS NVARCHAR(12)) + N'.'
                         WHEN N'NotFound'  THEN N'No container with this number or ref. The number may not be typed on its container yet.'
                         WHEN N'Ambiguous' THEN LEFT(N'Found on ' + CAST(d.OpenHits AS NVARCHAR(12)) + N' containers: '
                                                     + (SELECT STRING_AGG(h.ContainerRef, N', ') WITHIN GROUP (ORDER BY h.ContainerRef)
                                                        FROM @Hits h WHERE h.RowNo = d.RowNo AND h.IsOpen = 1) + N'.', 300)
                         ELSE f.Reason END AS NVARCHAR(300)),
           Note = CASE WHEN x.Result IN (N'Ready', N'AlreadyOnMovement') THEN f.Note END
    FROM d
    LEFT JOIN logistics.fn_Movement_ContainerCheck(@MovementId, @FromPlaceId, @ToPlaceId, @MovementTypeId) f ON f.ContainerId = d.ContainerId
    CROSS APPLY (SELECT Result = CAST(CASE WHEN d.RowNo > d.FirstRowNo THEN N'Duplicate'
                                           WHEN d.Hits = 0 THEN N'NotFound'
                                           WHEN d.OpenHits > 1 THEN N'Ambiguous'
                                           WHEN f.OnMovement = 1 THEN N'AlreadyOnMovement'
                                           WHEN f.CanAdd = 0 THEN N'Blocked'
                                           ELSE N'Ready' END AS NVARCHAR(20))) x
    ORDER BY d.RowNo;
END

GO

