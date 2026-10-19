-- planned and start date, ETA, carrier, vehicle or vessel, voyage, reference and notes, started the same day, its own MOV
-- number, SplitFromMovementId = the original), to which their rows of the movement's container list, their charges filed
-- under the movement and their documents filed under the movement move; the others stay on the original, in progress.
-- The containers' statuses and dates do not change: they travel already, with the same dates.
-- @CompleteDate: the completion that follows (the API completes the copy at once, through the movement's own Complete -
-- the only place that drafts a Delivery's goods receipts after the commit). It is checked FIRST, with Complete's rules
-- (not in the future, not before the start), so a refused date splits nothing. NULL = not checked (a split alone).
-- All the checks run under the movement's lock, in the transaction of the split: one transaction, all or nothing.
-- Audit: on both movements (logistics.MovementAudit), and on each container moved (logistics.ContainerAudit).
-- Returns one row: the new movement (NewId, MovementNo, RowVersion), the original, how many moved and how many stay -
-- BEFORE THE COMMIT, the last thing the transaction does: the API retries the call on a deadlock (SqlRetry), and a
-- deadlock can then only roll the whole split back, never hit a read after a split already committed.
CREATE   PROCEDURE logistics.usp_Movement_SplitContainers
    @MovementId   INT,
    @ContainerIds logistics.tvp_IdList READONLY,
    @RowVersion   BINARY(8) = NULL,
    @UserId       INT       = NULL,
    @CompleteDate DATE      = NULL,
    @NewId        INT       = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT, @MovementNo NVARCHAR(30), @StartDate DATE, @Count INT, @Left INT, @Msg NVARCHAR(400),
            @Number NVARCHAR(30), @Refs NVARCHAR(1000);
    DECLARE @Ids TABLE (Id INT NOT NULL PRIMARY KEY, ContainerRef NVARCHAR(30) NULL);
    SET @NewId = NULL;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- the movement, locked until the split is committed: nobody completes, cancels or edits it meanwhile
        SELECT @Status = m.Status, @MovementNo = m.MovementNo, @StartDate = m.StartDate
        FROM logistics.Movements m WITH (UPDLOCK, HOLDLOCK)
        WHERE m.Id = @MovementId;

        IF @Status IS NULL THROW 70006, 'Movement not found.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Movements WHERE Id = @MovementId AND RowVersion = @RowVersion)
            THROW 70004, 'This movement was modified by another user. Reload the page and try again.', 1;
        IF @Status <> 2
        BEGIN
            SELECT @Msg = b.Reason FROM logistics.fn_Movement_SplitBlock(@MovementId, @MovementNo, @Status, NULL, NULL, NULL) b;
            THROW 70010, @Msg, 1;
        END

        -- THE COMPLETION THAT FOLLOWS, FIRST: Complete's own rules and words (usp_Movement_SetStatus), one day of tolerance
        IF @CompleteDate IS NOT NULL AND @CompleteDate > DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE))
            THROW 70000, 'The end date cannot be in the future: complete the movement on the day it really arrives.', 1;
        IF @CompleteDate IS NOT NULL AND @CompleteDate < @StartDate
            THROW 70000, 'The end date cannot be earlier than the start date.', 1;

        INSERT INTO @Ids (Id, ContainerRef)
        SELECT x.Id, c.ContainerRef FROM @ContainerIds x LEFT JOIN logistics.Containers c ON c.Id = x.Id;
        SET @Count = (SELECT COUNT(*) FROM @Ids);
        IF @Count = 0 THROW 70000, 'Tick the containers that arrived.', 1;

        -- every one is on this movement
        SELECT TOP (1) @Msg = ISNULL(x.ContainerRef, N'Container ' + CAST(x.Id AS NVARCHAR(12))) + N' is not on ' + @MovementNo + N'.'
        FROM @Ids x
        WHERE NOT EXISTS (SELECT 1 FROM logistics.MovementContainers mc WHERE mc.MovementId = @MovementId AND mc.ContainerId = x.Id)
        ORDER BY CASE WHEN x.ContainerRef IS NULL THEN 1 ELSE 0 END, LEN(x.ContainerRef), x.ContainerRef, x.Id;
        IF @Msg IS NOT NULL THROW 70000, @Msg, 1;

        -- not all of them: then the movement itself is completed
        SET @Left = (SELECT COUNT(*) FROM logistics.MovementContainers mc
                     WHERE mc.MovementId = @MovementId AND NOT EXISTS (SELECT 1 FROM @Ids x WHERE x.Id = mc.ContainerId));
        IF @Left = 0
        BEGIN
            SET @Msg = N'Every container of ' + @MovementNo + N' is ticked: complete the movement itself.';
            THROW 70010, @Msg, 1;
        END

        -- none has a later leg (fn_Movement_SplitBlock: the travel order of "the highest Id below" stays true)
        SELECT TOP (1) @Msg = b.Reason
        FROM @Ids x
        CROSS APPLY logistics.fn_Movement_SplitBlock(@MovementId, @MovementNo, @Status, @Count + @Left, x.Id, x.ContainerRef) b
        WHERE b.Reason IS NOT NULL
        ORDER BY LEN(x.ContainerRef), x.ContainerRef;
        IF @Msg IS NOT NULL THROW 70010, @Msg, 1;

        -- 1. THE COPY: the same header and start, in progress, its own number
        EXEC inventory.usp_DocumentType_NextNumber N'MOV', @Number OUTPUT, NULL;
        INSERT INTO logistics.Movements (DocumentTypeId, MovementNo, MovementTypeId, FromPlaceId, ToPlaceId, PlannedDate, StartDate, Eta,
                                         CarrierPartyId, VehicleOrVessel, VoyageNo, Reference, Notes, Status,
                                         StartedAtUtc, StartedBy, CreatedBy, SplitFromMovementId)
        SELECT m.DocumentTypeId, @Number, m.MovementTypeId, m.FromPlaceId, m.ToPlaceId, m.PlannedDate, m.StartDate, m.Eta,
               m.CarrierPartyId, m.VehicleOrVessel, m.VoyageNo, m.Reference, m.Notes, 2,
               m.StartedAtUtc, m.StartedBy, @UserId, m.Id
        FROM logistics.Movements m
        WHERE m.Id = @MovementId;
        SET @NewId = SCOPE_IDENTITY();

        -- 2. THEIR ROWS OF THE CONTAINER LIST MOVE (each row as it is), with their charges and documents filed under the
        -- movement: a file other containers share keeps their records where they are (one record per container)
        UPDATE mc SET MovementId = @NewId
        FROM logistics.MovementContainers mc
        INNER JOIN @Ids x ON x.Id = mc.ContainerId
        WHERE mc.MovementId = @MovementId;

        UPDATE ch SET MovementId = @NewId, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        FROM logistics.ContainerCharges ch
        INNER JOIN @Ids x ON x.Id = ch.ContainerId
        WHERE ch.MovementId = @MovementId;

        UPDATE a SET MovementId = @NewId
        FROM logistics.ContainerAttachments a
        INNER JOIN @Ids x ON x.Id = a.ContainerId
        WHERE a.MovementId = @MovementId;

        -- the original changed (containers left it): its RowVersion moves, a page left open on it reloads
        UPDATE logistics.Movements SET UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @MovementId;

        -- 3. AUDIT on both movements and on each container moved (the first 20 refs, then "and N more")
        SELECT @Refs = STRING_AGG(CAST(x.ContainerRef AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY LEN(x.ContainerRef), x.ContainerRef)
        FROM (SELECT TOP (20) ContainerRef FROM @Ids ORDER BY LEN(ContainerRef), ContainerRef) x;
        IF @Count > 20 SET @Refs = @Refs + N' and ' + CAST(@Count - 20 AS NVARCHAR(12)) + N' more';

        INSERT INTO logistics.MovementAudit (MovementId, Action, Details, UserId)
        VALUES (@MovementId, N'Split off', LEFT(N'Split off into ' + @Number + N': ' + @Refs, 1000), @UserId),
               (@NewId, N'Split from', LEFT(N'Split from ' + @MovementNo + N': ' + @Refs + N' arrived on '
                                            + CASE WHEN @Count = 1 THEN N'its own.' ELSE N'their own.' END, 1000), @UserId);

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        SELECT x.Id, N'Event', LEFT(N'Moved from ' + @MovementNo + N' to ' + @Number + N': it arrived on its own (split)', 500), @UserId
        FROM @Ids x;

        -- 4. THE ANSWER, inside the transaction (see the header): nothing that can fail is left after the COMMIT
        SELECT NewId = m.Id, m.MovementNo, m.Status, m.RowVersion,
               OriginalMovementId = @MovementId, OriginalMovementNo = @MovementNo,
               ContainersMoved = @Count, ContainersLeft = @Left
        FROM logistics.Movements m
        WHERE m.Id = @NewId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @NewId = NULL;
        THROW;
    END CATCH
END

GO

