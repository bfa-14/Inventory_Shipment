/* =====================================================================================
   Inventory_Shipment - 53: MOVEMENTS - THE PLACE RULES OF A CONTAINER (prompt 45 A1)

   Why: MOV-2026-000046 (LOAD, Dar es Salaam -> Chennai) started with KTG-2026-0018, a container that never moved. The
   place rule of script 50 only looked at containers that HAD moved (never moved = no place = any From), and Start
   only checked containers with a previous movement. A container that never moved now starts from its port of loading.

   The rules (one place: logistics.fn_ContainerFitForMovement, used by Save, Start, the candidates and the matching)
     - Moved before (a previous movement, not cancelled, with a lower Id): its place is that movement's To; it fits when
       the movement's From is that place. Reason: 'At {place} (end of {MOV}), not at {From}.'
     - Never moved: its place is its port of loading; it fits when the movement's From is that port, or when the
       movement type's stage is Origin (loading at the supplier) and the movement's To is that port. Reason: 'Not moved
       yet: it starts from its port of loading {port}.' No port of loading: it fits any From, with the Note 'No port of
       loading on this container: check it.'
     - An Origin-stage movement only takes containers that never moved. Reason: 'Loading at the supplier is only for
       containers that have not moved yet.'
     - Start, as before (script 50): the previous movement of every container is completed (70016), checked first.
     - Start of a movement without containers: 'Tick at least one container before starting.' (70000; SetStatus said
       'The movement has no containers.', which Complete keeps). Save already refused it ('Select at least one
       container.').

   Objects
     logistics.fn_ContainerFitForMovement (new): per container for a movement (@MovementId NULL = a new one), its From,
       To and type: the place (PlaceName = the port of loading of a container that never moved), Fits, Reason, Note.
       logistics.fn_ContainerPlaceForMovement (script 50) stays as it is: the previous movement of a container.
     logistics.fn_Movement_ContainerCheck: + @ToPlaceId, @MovementTypeId (re-created from the body of script 50).
     logistics.usp_Movement_Save, usp_Movement_SetStatus: the rules above (re-created from the bodies of script 50).
     logistics.usp_Movement_ContainerCandidates, usp_Movement_MatchContainers: + @ToPlaceId, @MovementTypeId at the end
       (NULL = the saved movement's; a new movement without a type is not of the Origin stage); same result sets.

   Errors: 70015 the container does not fit the From (Save and Start; the message carries the reason), 70016 previous
           movement not completed (Start), 70000 validation - no new number.

   Requires script 50. Idempotent, additive: re-applied at every API start-up through Schema.sql.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'logistics.fn_ContainerPlaceForMovement', N'IF') IS NULL
   OR OBJECT_ID(N'logistics.usp_Movement_MatchContainers', N'P') IS NULL
   OR COL_LENGTH(N'masterdata.MovementTypes', N'Stage') IS NULL
BEGIN
    RAISERROR ('Run script 50 before this script.', 16, 1);
    SET NOEXEC ON;
END
GO

/* ================================================================== 1. The place rules, in one place */

-- One row per container for a movement (@MovementId NULL = a new one) leaving @FromPlaceId for @ToPlaceId with the
-- type @MovementTypeId: where the container is (its previous movement's To, else its port of loading), whether it
-- fits the movement and why not. Note only on a container that never moved and fits.
CREATE OR ALTER FUNCTION logistics.fn_ContainerFitForMovement (@MovementId INT, @FromPlaceId INT, @ToPlaceId INT, @MovementTypeId INT)
RETURNS TABLE
AS
RETURN
SELECT p.ContainerId, p.PreviousMovementId, p.PreviousMovementNo, p.PreviousStatus,
       PlaceId   = CASE WHEN p.PreviousMovementId IS NULL THEN p.PortOfLoadingId ELSE p.PlaceId END,
       PlaceName = CASE WHEN p.PreviousMovementId IS NULL THEN p.PortOfLoadingName ELSE p.PlaceName END,
       p.PortOfLoadingId, p.PortOfLoadingName, s.IsOrigin,
       Fits = CAST(CASE WHEN r.Reason IS NULL THEN 1 ELSE 0 END AS BIT),
       r.Reason,
       Note = CAST(CASE WHEN r.Reason IS NULL AND p.PreviousMovementId IS NULL
                        THEN ISNULL(N'Not moved yet - port of loading: ' + p.PortOfLoadingName + N'.',
                                    N'No port of loading on this container: check it.') END AS NVARCHAR(200))
FROM logistics.fn_ContainerPlaceForMovement(@MovementId) p
CROSS JOIN (SELECT IsOrigin = CAST(CASE WHEN EXISTS (SELECT 1 FROM masterdata.MovementTypes t
                                                     WHERE t.Id = @MovementTypeId AND t.Stage = N'Origin') THEN 1 ELSE 0 END AS BIT),
                   FromName = (SELECT f.PortName FROM masterdata.Ports f WHERE f.Id = @FromPlaceId)) s
CROSS APPLY (SELECT Reason = CAST(CASE
                 WHEN p.PreviousMovementId IS NOT NULL AND s.IsOrigin = 1
                     THEN N'Loading at the supplier is only for containers that have not moved yet.'
                 WHEN p.PreviousMovementId IS NOT NULL AND p.PlaceId <> @FromPlaceId
                     THEN N'At ' + p.PlaceName + N' (end of ' + p.PreviousMovementNo + N'), not at ' + s.FromName + N'.'
                 WHEN p.PreviousMovementId IS NULL AND p.PortOfLoadingId <> @FromPlaceId
                      AND NOT (s.IsOrigin = 1 AND p.PortOfLoadingId = ISNULL(@ToPlaceId, 0))
                     THEN N'Not moved yet: it starts from its port of loading ' + p.PortOfLoadingName + N'.' END
             AS NVARCHAR(300))) r;
GO

/* ================================================================== 2. The checks of a movement's Save, per container */

-- Re-created (53) from the body of script 50: + @ToPlaceId and @MovementTypeId, the place rules of
-- fn_ContainerFitForMovement (PlaceName is the port of loading of a container that never moved).
-- Every container with the columns of the picker and the checks of usp_Movement_Save for @MovementId (NULL = a new,
-- planned movement) leaving from @FromPlaceId for @ToPlaceId with the type @MovementTypeId. For a container not on the movement: offloaded / closed / cancelled,
-- in progress: not confirmed, travelling with another movement, then the place rule (the order of Save). For a
-- container on the movement (OnMovement = 1): the checks that apply to a kept one (travelling, place).
-- CanAdd = no Reason. Note (only without a Reason): never moved (or no port of loading), on its way here, draft of a
-- planned movement.
CREATE OR ALTER FUNCTION logistics.fn_Movement_ContainerCheck (@MovementId INT, @FromPlaceId INT, @ToPlaceId INT, @MovementTypeId INT)
RETURNS TABLE
AS
RETURN
SELECT c.Id AS ContainerId, c.ContainerRef, c.ContainerNo, c.SealNo, ct.TypeCode AS ContainerTypeCode,
       OrderNumbers = CASE WHEN ISNULL(po.OrderCount, 0) = 0 THEN NULL
                           WHEN po.OrderCount = 1 THEN po.FirstOrder
                           ELSE po.FirstOrder + N' +' + CAST(po.OrderCount - 1 AS NVARCHAR(10)) END,
       SupplierNames = CASE WHEN ISNULL(po.SupplierCount, 0) = 0 THEN NULL
                            WHEN po.SupplierCount = 1 THEN po.FirstSupplier
                            ELSE po.FirstSupplier + N' +' + CAST(po.SupplierCount - 1 AS NVARCHAR(10)) END,
       ItemSummary = CASE WHEN ISNULL(ln.ItemCount, 0) = 0 THEN NULL
                          WHEN ln.ItemCount = 1 THEN ln.FirstItem
                          ELSE N'Mixed - ' + CAST(ln.ItemCount AS NVARCHAR(10)) + N' items' END,
       Pieces = ISNULL(ln.Qty, 0),
       c.Status, c.Eta, c.OrderDate, c.BlNo, c.VesselName,
       p.PlaceId, p.PlaceName, p.PreviousMovementId, p.PreviousMovementNo, p.PreviousStatus, p.PortOfLoadingName,
       OnMovement = CAST(CASE WHEN mc.Id IS NULL THEN 0 ELSE 1 END AS BIT),
       CanAdd = CAST(CASE WHEN r.Reason IS NULL THEN 1 ELSE 0 END AS BIT),
       r.Reason,
       Note = CAST(CASE WHEN r.Reason IS NULL THEN NULLIF(CONCAT_WS(N' ',
                  p.Note,
                  CASE WHEN p.PreviousStatus IN (1, 2)
                       THEN N'On its way here with ' + p.PreviousMovementNo + N': this movement can start once it is completed.' END,
                  CASE WHEN mv.MovementStatus = 1 AND c.Status = 1 THEN N'Draft: confirm it before the movement starts.' END), N'') END
              AS NVARCHAR(300))
FROM logistics.Containers c
INNER JOIN masterdata.ContainerTypes ct ON ct.Id = c.ContainerTypeId
INNER JOIN logistics.fn_ContainerFitForMovement(@MovementId, @FromPlaceId, @ToPlaceId, @MovementTypeId) p ON p.ContainerId = c.Id
CROSS JOIN (SELECT MovementStatus = ISNULL((SELECT m.Status FROM logistics.Movements m WHERE m.Id = @MovementId), 1)) mv
LEFT JOIN logistics.MovementContainers mc ON mc.MovementId = @MovementId AND mc.ContainerId = c.Id
OUTER APPLY (SELECT OrderCount = COUNT(DISTINCT cl.PurchaseOrderId), SupplierCount = COUNT(DISTINCT d.SupplierId),
                    FirstOrder = MIN(d.DocumentNumber), FirstSupplier = MIN(sp.PartyName)
             FROM logistics.ContainerLines cl
             INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
             INNER JOIN masterdata.Parties sp        ON sp.Id = d.SupplierId
             WHERE cl.ContainerId = c.Id) po
OUTER APPLY (SELECT ItemCount = COUNT(DISTINCT cl.ItemId), Qty = SUM(cl.QuantityBase), FirstItem = MIN(i.ItemName)
             FROM logistics.ContainerLines cl
             INNER JOIN inventory.Items i ON i.Id = cl.ItemId
             WHERE cl.ContainerId = c.Id) ln
OUTER APPLY (SELECT TOP (1) m.MovementNo
             FROM logistics.MovementContainers o
             INNER JOIN logistics.Movements m ON m.Id = o.MovementId AND m.Status = 2
             WHERE o.ContainerId = c.Id AND (@MovementId IS NULL OR o.MovementId <> @MovementId)
             ORDER BY m.Id DESC) tr
CROSS APPLY (SELECT Reason = CAST(CASE
                 WHEN mc.Id IS NULL AND c.Status >= 6 THEN N'Already offloaded, closed or cancelled.'
                 WHEN mc.Id IS NULL AND mv.MovementStatus = 2 AND c.Status = 1 THEN N'Not confirmed yet.'
                 WHEN mv.MovementStatus = 2 AND tr.MovementNo IS NOT NULL THEN N'Travelling with movement ' + tr.MovementNo + N'.'
                 WHEN p.Fits = 0 THEN p.Reason END
             AS NVARCHAR(300))) r;
GO

/* ================================================================== 3. Save: every container fits the movement */

-- Re-created (53) from the body of script 50: the place rules of fn_ContainerFitForMovement (70015 with the reason).
-- Planned movements: everything editable. In progress: header and containers editable (start date too), no end date.
CREATE OR ALTER PROCEDURE logistics.usp_Movement_Save
    @Id              INT            = NULL,
    @MovementTypeId  INT,
    @FromPlaceId     INT,
    @ToPlaceId       INT,
    @PlannedDate     DATE           = NULL,
    @StartDate       DATE           = NULL,   -- used only while in progress (Start sets it)
    @Eta             DATE           = NULL,
    @CarrierPartyId  INT            = NULL,
    @VehicleOrVessel NVARCHAR(100)  = NULL,
    @VoyageNo        NVARCHAR(30)   = NULL,
    @Reference       NVARCHAR(50)   = NULL,
    @Notes           NVARCHAR(1000) = NULL,
    @ContainerIds    logistics.tvp_IdList READONLY,
    @RowVersion      BINARY(8)      = NULL,
    @UserId          INT            = NULL,
    @NewId           INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @VehicleOrVessel = NULLIF(LTRIM(RTRIM(@VehicleOrVessel)), N'');
    SET @VoyageNo = NULLIF(LTRIM(RTRIM(@VoyageNo)), N'');
    SET @Reference = NULLIF(LTRIM(RTRIM(@Reference)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');

    IF NOT EXISTS (SELECT 1 FROM masterdata.MovementTypes WHERE Id = @MovementTypeId AND IsActive = 1)
        THROW 70000, 'Movement type not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Ports WHERE Id = @FromPlaceId AND IsActive = 1)
        THROW 70000, 'The departure place is not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Ports WHERE Id = @ToPlaceId AND IsActive = 1)
        THROW 70000, 'The destination place is not found or inactive.', 1;
    IF @CarrierPartyId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @CarrierPartyId AND IsActive = 1)
        THROW 70000, 'The carrier is not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM @ContainerIds) THROW 70000, 'Select at least one container.', 1;

    DECLARE @Status TINYINT = 1;
    IF @Id IS NOT NULL
    BEGIN
        SELECT @Status = Status FROM logistics.Movements WHERE Id = @Id;
        IF @Status IS NULL THROW 70006, 'Movement not found.', 1;
        IF @Status NOT IN (1, 2) THROW 70005, 'A completed or cancelled movement can no longer be changed.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Movements WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 70004, 'This movement was modified by another user. Reload the page and try again.', 1;
        IF @Status = 2 AND @StartDate IS NULL THROW 70000, 'The start date of a movement in progress is required.', 1;
    END
    IF @Status = 1 SET @StartDate = NULL;
    IF @StartDate IS NOT NULL AND @Eta IS NOT NULL AND @Eta < @StartDate THROW 70000, 'The ETA cannot be earlier than the start date.', 1;
    IF @PlannedDate IS NOT NULL AND @Eta IS NOT NULL AND @Eta < @PlannedDate THROW 70000, 'The ETA cannot be earlier than the planned date.', 1;

    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg = CASE WHEN c.Id IS NULL THEN N'A selected container no longer exists.'
                               WHEN c.Status >= 6 THEN N'Container ' + c.ContainerRef + N' is already offloaded, closed or cancelled.'
                               WHEN @Status = 2 AND c.Status = 1 THEN N'Container ' + c.ContainerRef + N' is not confirmed yet.' END
    FROM @ContainerIds x
    LEFT JOIN logistics.Containers c ON c.Id = x.Id
    WHERE (c.Id IS NULL OR c.Status >= 6 OR (@Status = 2 AND c.Status = 1))
      AND (@Id IS NULL OR NOT EXISTS (SELECT 1 FROM logistics.MovementContainers mc WHERE mc.MovementId = @Id AND mc.ContainerId = x.Id))
    ORDER BY c.ContainerRef;
    IF @Msg IS NOT NULL THROW 70000, @Msg, 1;

    IF @Status = 2
    BEGIN
        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' is already travelling with movement ' + m.MovementNo + N'.'
        FROM @ContainerIds x
        INNER JOIN logistics.Containers c         ON c.Id = x.Id
        INNER JOIN logistics.MovementContainers o ON o.ContainerId = x.Id AND o.MovementId <> @Id
        INNER JOIN logistics.Movements m          ON m.Id = o.MovementId AND m.Status = 2
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70012, @Msg, 1;
    END

    -- the place rules (script 53): every container of the movement, added or kept, fits its From, To and stage
    SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' cannot leave from ' + f.PortName + N'. ' + p.Reason
    FROM @ContainerIds x
    INNER JOIN logistics.Containers c ON c.Id = x.Id
    INNER JOIN logistics.fn_ContainerFitForMovement(@Id, @FromPlaceId, @ToPlaceId, @MovementTypeId) p ON p.ContainerId = x.Id
    INNER JOIN masterdata.Ports f ON f.Id = @FromPlaceId
    WHERE p.Fits = 0
    ORDER BY c.ContainerRef;
    IF @Msg IS NOT NULL THROW 70015, @Msg, 1;

    DECLARE @Affected TABLE (ContainerId INT PRIMARY KEY);

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Label NVARCHAR(300);
        IF @Id IS NULL
        BEGIN
            DECLARE @Number NVARCHAR(30), @TypeId INT = (SELECT Id FROM inventory.DocumentTypes WHERE Code = N'MOV');
            EXEC inventory.usp_DocumentType_NextNumber N'MOV', @Number OUTPUT, NULL;
            INSERT INTO logistics.Movements (DocumentTypeId, MovementNo, MovementTypeId, FromPlaceId, ToPlaceId, PlannedDate, Eta,
                                             CarrierPartyId, VehicleOrVessel, VoyageNo, Reference, Notes, Status, CreatedBy)
            VALUES (@TypeId, @Number, @MovementTypeId, @FromPlaceId, @ToPlaceId, @PlannedDate, @Eta,
                    @CarrierPartyId, @VehicleOrVessel, @VoyageNo, @Reference, @Notes, 1, @UserId);
            SET @Id = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            UPDATE logistics.Movements
            SET MovementTypeId = @MovementTypeId, FromPlaceId = @FromPlaceId, ToPlaceId = @ToPlaceId, PlannedDate = @PlannedDate,
                StartDate = CASE WHEN Status = 2 THEN @StartDate ELSE NULL END, Eta = @Eta,
                CarrierPartyId = @CarrierPartyId, VehicleOrVessel = @VehicleOrVessel, VoyageNo = @VoyageNo, Reference = @Reference,
                Notes = @Notes, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;
        END

        SELECT @Label = m.MovementNo + N' ' + mt.TypeName + N': ' + fp.PortName + N' ' + NCHAR(8594) + N' ' + tp.PortName
        FROM logistics.Movements m
        INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
        INNER JOIN masterdata.Ports fp ON fp.Id = m.FromPlaceId
        INNER JOIN masterdata.Ports tp ON tp.Id = m.ToPlaceId
        WHERE m.Id = @Id;

        INSERT INTO @Affected (ContainerId)
        SELECT mc.ContainerId FROM logistics.MovementContainers mc
        WHERE mc.MovementId = @Id AND NOT EXISTS (SELECT 1 FROM @ContainerIds x WHERE x.Id = mc.ContainerId)
        UNION
        SELECT x.Id FROM @ContainerIds x
        WHERE NOT EXISTS (SELECT 1 FROM logistics.MovementContainers mc WHERE mc.MovementId = @Id AND mc.ContainerId = x.Id);

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        SELECT a.ContainerId, N'Updated',
               LEFT(CASE WHEN EXISTS (SELECT 1 FROM @ContainerIds x WHERE x.Id = a.ContainerId) THEN N'Added to movement ' ELSE N'Removed from movement ' END + @Label, 500),
               @UserId
        FROM @Affected a;

        DELETE mc FROM logistics.MovementContainers mc
        WHERE mc.MovementId = @Id AND NOT EXISTS (SELECT 1 FROM @ContainerIds x WHERE x.Id = mc.ContainerId);
        INSERT INTO logistics.MovementContainers (MovementId, ContainerId)
        SELECT @Id, x.Id FROM @ContainerIds x
        WHERE NOT EXISTS (SELECT 1 FROM logistics.MovementContainers mc WHERE mc.MovementId = @Id AND mc.ContainerId = x.Id);

        -- in progress: the containers' status follows (all of them, the dates may have changed)
        IF @Status = 2
        BEGIN
            INSERT INTO @Affected (ContainerId)
            SELECT x.Id FROM @ContainerIds x WHERE NOT EXISTS (SELECT 1 FROM @Affected a WHERE a.ContainerId = x.Id);
            DECLARE @Cid INT;
            DECLARE ctn CURSOR LOCAL FAST_FORWARD FOR SELECT ContainerId FROM @Affected;
            OPEN ctn;
            FETCH NEXT FROM ctn INTO @Cid;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC logistics.usp_Container_RefreshStatus @Cid;
                FETCH NEXT FROM ctn INTO @Cid;
            END
            CLOSE ctn;
            DEALLOCATE ctn;
        END

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 4. Start: previous movements completed, every container fits */

-- Re-created (53) from the body of script 50: Start checks the place rules of fn_ContainerFitForMovement (70015) after
-- the previous movements (70016), and refuses a movement without containers in the words of the page.
-- Status changes of a movement. @Action: Start | Complete | Cancel. The containers' status and dates follow.
CREATE OR ALTER PROCEDURE logistics.usp_Movement_SetStatus
    @Id         INT,
    @Action     NVARCHAR(10),
    @Date       DATE          = NULL,    -- Start: start date; Complete: end date (default today)
    @Reason     NVARCHAR(300) = NULL,    -- Cancel
    @RowVersion BINARY(8)     = NULL,
    @UserId     INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Action = NULLIF(LTRIM(RTRIM(@Action)), N'');
    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Date IS NULL SET @Date = CAST(SYSUTCDATETIME() AS DATE);
    IF @Action IS NULL OR @Action NOT IN (N'Start', N'Complete', N'Cancel') THROW 70000, 'Action must be Start, Complete or Cancel.', 1;

    DECLARE @Status TINYINT, @StartDate DATE, @Label NVARCHAR(300), @FromPlaceId INT, @ToPlaceId INT, @MovementTypeId INT;
    SELECT @Status = m.Status, @StartDate = m.StartDate,
           @FromPlaceId = m.FromPlaceId, @ToPlaceId = m.ToPlaceId, @MovementTypeId = m.MovementTypeId,
           @Label = m.MovementNo + N' ' + mt.TypeName + N': ' + fp.PortName + N' ' + NCHAR(8594) + N' ' + tp.PortName
    FROM logistics.Movements m WITH (UPDLOCK, HOLDLOCK)
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    INNER JOIN masterdata.Ports fp ON fp.Id = m.FromPlaceId
    INNER JOIN masterdata.Ports tp ON tp.Id = m.ToPlaceId
    WHERE m.Id = @Id;

    IF @Status IS NULL THROW 70006, 'Movement not found.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Movements WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 70004, 'This movement was modified by another user. Reload the page and try again.', 1;
    IF @Action = N'Start' AND @Status <> 1 THROW 70010, 'Only a planned movement can be started.', 1;
    IF @Action = N'Complete' AND @Status <> 2 THROW 70010, 'Only a movement in progress can be completed.', 1;
    IF @Action = N'Complete' AND @Date < @StartDate THROW 70000, 'The end date cannot be earlier than the start date.', 1;
    IF @Action = N'Cancel' AND @Status = 4 THROW 70010, 'The movement is already cancelled.', 1;
    IF @Action = N'Cancel' AND @Reason IS NULL THROW 70000, 'A cancellation reason is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM logistics.MovementContainers WHERE MovementId = @Id) AND @Action = N'Start'
        THROW 70000, 'Tick at least one container before starting.', 1;
    IF NOT EXISTS (SELECT 1 FROM logistics.MovementContainers WHERE MovementId = @Id) AND @Action = N'Complete'
        THROW 70000, 'The movement has no containers.', 1;

    DECLARE @Msg NVARCHAR(400);
    IF @Action = N'Start'
    BEGIN
        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + CASE WHEN c.Status = 1 THEN N' is not confirmed yet.'
                                                                    ELSE N' is already offloaded, closed or cancelled.' END
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
        WHERE mc.MovementId = @Id AND (c.Status = 1 OR c.Status >= 6)
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70010, @Msg, 1;

        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' is already travelling with movement ' + m.MovementNo + N'. Complete it first.'
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Containers c         ON c.Id = mc.ContainerId
        INNER JOIN logistics.MovementContainers o ON o.ContainerId = mc.ContainerId AND o.MovementId <> @Id
        INNER JOIN logistics.Movements m          ON m.Id = o.MovementId AND m.Status = 2
        WHERE mc.MovementId = @Id
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70012, @Msg, 1;

        -- the place rules (script 53): the previous movement of every container is completed (70016), then every
        -- container fits the movement's From, To and stage (70015) - the rules of Save, fn_ContainerFitForMovement
        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N': the previous movement ' + p.PreviousMovementNo + N' (' + pf.PortName
                              + N' ' + NCHAR(8594) + N' ' + p.PlaceName + N') is not completed yet.'
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
        INNER JOIN logistics.fn_ContainerPlaceForMovement(@Id) p ON p.ContainerId = mc.ContainerId
        INNER JOIN logistics.Movements pm ON pm.Id = p.PreviousMovementId
        INNER JOIN masterdata.Ports pf    ON pf.Id = pm.FromPlaceId
        WHERE mc.MovementId = @Id AND p.PreviousStatus <> 3
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70016, @Msg, 1;

        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' cannot leave from ' + f.PortName + N'. ' + p.Reason
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
        INNER JOIN logistics.fn_ContainerFitForMovement(@Id, @FromPlaceId, @ToPlaceId, @MovementTypeId) p ON p.ContainerId = mc.ContainerId
        INNER JOIN masterdata.Ports f     ON f.Id = @FromPlaceId
        WHERE mc.MovementId = @Id AND p.Fits = 0
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70015, @Msg, 1;
    END
    IF @Action = N'Cancel'
    BEGIN
        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' is already offloaded: its route can no longer change.'
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
        WHERE mc.MovementId = @Id AND c.Status IN (6, 7) AND @Status IN (2, 3)
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70010, @Msg, 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE logistics.Movements
        SET Status = CASE @Action WHEN N'Start' THEN 2 WHEN N'Complete' THEN 3 ELSE 4 END,
            StartDate = CASE WHEN @Action = N'Start' THEN @Date ELSE StartDate END,
            EndDate = CASE WHEN @Action = N'Complete' THEN @Date ELSE EndDate END,
            StartedAtUtc = CASE WHEN @Action = N'Start' THEN SYSUTCDATETIME() ELSE StartedAtUtc END,
            StartedBy = CASE WHEN @Action = N'Start' THEN @UserId ELSE StartedBy END,
            CompletedAtUtc = CASE WHEN @Action = N'Complete' THEN SYSUTCDATETIME() ELSE CompletedAtUtc END,
            CompletedBy = CASE WHEN @Action = N'Complete' THEN @UserId ELSE CompletedBy END,
            CancelledAtUtc = CASE WHEN @Action = N'Cancel' THEN SYSUTCDATETIME() ELSE CancelledAtUtc END,
            CancelledBy = CASE WHEN @Action = N'Cancel' THEN @UserId ELSE CancelledBy END,
            CancelReason = CASE WHEN @Action = N'Cancel' THEN @Reason ELSE CancelReason END,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        SELECT mc.ContainerId, N'Event',
               LEFT(CASE @Action WHEN N'Start' THEN N'Started ' WHEN N'Complete' THEN N'Arrived / completed ' ELSE N'Cancelled ' END
                    + @Label + N' on ' + CONVERT(NVARCHAR(10), @Date, 23) + ISNULL(N' - ' + @Reason, N''), 500),
               @UserId
        FROM logistics.MovementContainers mc WHERE mc.MovementId = @Id;

        DECLARE @Cid INT;
        DECLARE ctn CURSOR LOCAL FAST_FORWARD FOR SELECT ContainerId FROM logistics.MovementContainers WHERE MovementId = @Id;
        OPEN ctn;
        FETCH NEXT FROM ctn INTO @Cid;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC logistics.usp_Container_RefreshStatus @Cid;
            FETCH NEXT FROM ctn INTO @Cid;
        END
        CLOSE ctn;
        DEALLOCATE ctn;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 5. Candidates of a movement */

-- Re-created (53) from the body of script 50: + @ToPlaceId and @MovementTypeId (the page's, saved or not; NULL = the
-- saved movement's) for the place rules of an Origin-stage movement.
-- The containers that can join a movement (@MovementId NULL = a new one) leaving from @FromPlaceId (the From on the
-- page, saved or not): not on the movement, not offloaded / closed / cancelled. @IncludeBlocked = 1 also lists the
-- ones the checks of Save refuse (CanAdd 0, Reason). At most 200 rows a page; TotalCount for the paging.
CREATE OR ALTER PROCEDURE logistics.usp_Movement_ContainerCandidates
    @MovementId      INT           = NULL,
    @FromPlaceId     INT,
    @Search          NVARCHAR(100) = NULL,   -- ref, container no., B/L, vessel, order no., supplier
    @PurchaseOrderId INT           = NULL,
    @SupplierId      INT           = NULL,
    @Status          TINYINT       = NULL,
    @IncludeBlocked  BIT           = 0,
    @PageNumber      INT           = 1,
    @PageSize        INT           = 200,
    @ToPlaceId       INT           = NULL,   -- (53) the To on the page
    @MovementTypeId  INT           = NULL    -- (53) the type on the page
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

/* ================================================================== 6. Container numbers matched for a movement */

-- Re-created (53) from the body of script 50: + @ToPlaceId and @MovementTypeId, as the candidates.
-- One row per number (empty ones ignored), in the input order. Result: Ready | AlreadyOnMovement | NotFound |
-- Ambiguous | Blocked | Duplicate; Reason and Note are the texts of the candidates (fn_Movement_ContainerCheck).
CREATE OR ALTER PROCEDURE logistics.usp_Movement_MatchContainers
    @MovementId  INT = NULL,
    @FromPlaceId INT,
    @Numbers     logistics.tvp_TextList READONLY,
    @ToPlaceId      INT = NULL,   -- (53) the To on the page
    @MovementTypeId INT = NULL    -- (53) the type on the page
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

/* ================================================================== 7. Check */

SELECT o.ObjectName, ObjectType = ISNULL(so.type_desc, N'MISSING')
FROM (VALUES (N'logistics.fn_ContainerFitForMovement'), (N'logistics.fn_ContainerPlaceForMovement'),
             (N'logistics.fn_Movement_ContainerCheck'), (N'logistics.usp_Movement_Save'), (N'logistics.usp_Movement_SetStatus'),
             (N'logistics.usp_Movement_ContainerCandidates'), (N'logistics.usp_Movement_MatchContainers')) o (ObjectName)
LEFT JOIN sys.objects so ON so.object_id = OBJECT_ID(o.ObjectName)
ORDER BY ObjectType, o.ObjectName;                                    -- expected 7: 3 functions, 4 procedures, none MISSING

-- Planned or in-progress movements holding a container that breaks the rules: their next Save or Start refuses it
-- (change the From, remove the container, set its port of loading, or record the movement that brings it there).
SELECT m.MovementNo, MovementStatus = CASE m.Status WHEN 1 THEN N'Planned' ELSE N'In progress' END,
       MovementType = mt.TypeCode, MovementFrom = f.PortName, MovementTo = t.PortName, c.ContainerRef, p.Reason
FROM logistics.Movements m
INNER JOIN masterdata.MovementTypes mt     ON mt.Id = m.MovementTypeId
INNER JOIN masterdata.Ports f              ON f.Id = m.FromPlaceId
INNER JOIN masterdata.Ports t              ON t.Id = m.ToPlaceId
INNER JOIN logistics.MovementContainers mc ON mc.MovementId = m.Id
INNER JOIN logistics.Containers c          ON c.Id = mc.ContainerId
CROSS APPLY logistics.fn_ContainerFitForMovement(m.Id, m.FromPlaceId, m.ToPlaceId, m.MovementTypeId) p
WHERE m.Status IN (1, 2) AND p.ContainerId = mc.ContainerId AND p.Fits = 0
ORDER BY m.MovementNo, c.ContainerRef;

-- Containers on planned or in-progress movements without a port of loading (they fit any From: check them).
SELECT m.MovementNo, c.ContainerRef, c.ContainerNo
FROM logistics.Movements m
INNER JOIN logistics.MovementContainers mc ON mc.MovementId = m.Id
INNER JOIN logistics.Containers c          ON c.Id = mc.ContainerId
CROSS APPLY logistics.fn_ContainerFitForMovement(m.Id, m.FromPlaceId, m.ToPlaceId, m.MovementTypeId) p
WHERE m.Status IN (1, 2) AND p.ContainerId = mc.ContainerId AND p.PreviousMovementId IS NULL AND c.PortOfLoadingId IS NULL
ORDER BY m.MovementNo, c.ContainerRef;

PRINT 'Script 53 applied: the place rules of movements in one function - a container that never moved starts from its port of loading, an Origin-stage movement takes only containers that never moved.';
GO

SET NOEXEC OFF;
GO
