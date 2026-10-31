/* ================================================================== 6b. Save: the start date of a movement in progress */

-- Re-created (80) from the body of script 53: + while the movement is in progress (the page lets its start date be
-- changed after Start), the start date is refused in the future (70000) and before the previous leg of one of its
-- containers ended (70018), in the words of usp_Movement_SetStatus. A planned movement has no start date: unchanged.
-- Planned movements: everything editable. In progress: header and containers editable (start date too), no end date.
CREATE   PROCEDURE logistics.usp_Movement_Save
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

    DECLARE @Status TINYINT = 1, @MovementNo NVARCHAR(30);
    IF @Id IS NOT NULL
    BEGIN
        SELECT @Status = Status, @MovementNo = MovementNo FROM logistics.Movements WHERE Id = @Id;
        IF @Status IS NULL THROW 70006, 'Movement not found.', 1;
        IF @Status NOT IN (1, 2) THROW 70005, 'A completed or cancelled movement can no longer be changed.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Movements WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 70004, 'This movement was modified by another user. Reload the page and try again.', 1;
        IF @Status = 2 AND @StartDate IS NULL THROW 70000, 'The start date of a movement in progress is required.', 1;
    END
    IF @Status = 1 SET @StartDate = NULL;
    IF @StartDate IS NOT NULL AND @Eta IS NOT NULL AND @Eta < @StartDate THROW 70000, 'The ETA cannot be earlier than the start date.', 1;
    IF @PlannedDate IS NOT NULL AND @Eta IS NOT NULL AND @Eta < @PlannedDate THROW 70000, 'The ETA cannot be earlier than the planned date.', 1;
    -- (80) THE START DATE OF A MOVEMENT IN PROGRESS STAYS A FACT: the rule of its Start (usp_Movement_SetStatus), with the
    -- same day of tolerance (the reader's date against the server's UTC date). Otherwise a start made today could be
    -- moved to next month with a plain Save.
    IF @Status = 2 AND @StartDate > DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE))
        THROW 70000, 'The start date cannot be in the future: start the movement on the day it really leaves.', 1;

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

    -- (80) NOT BEFORE THE PREVIOUS LEG ENDED (70018), as at Start: an edited start date, or a container added to a
    -- movement in progress, cannot make a container set off from a place before it got there.
    IF @Status = 2
    BEGIN
        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' cannot start ' + @MovementNo + N' before ' + pm.MovementNo
                              + N' reached ' + tp.PortName + N' on ' + CONVERT(NVARCHAR(10), pm.EndDate, 103) + N'.'
        FROM @ContainerIds x
        INNER JOIN logistics.Containers c ON c.Id = x.Id
        INNER JOIN logistics.fn_ContainerPlaceForMovement(@Id) p ON p.ContainerId = x.Id
        INNER JOIN logistics.Movements pm ON pm.Id = p.PreviousMovementId
        INNER JOIN masterdata.Ports tp    ON tp.Id = pm.ToPlaceId
        WHERE pm.Status = 3 AND pm.EndDate > @StartDate
        ORDER BY pm.EndDate DESC, c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70018, @Msg, 1;
    END

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

