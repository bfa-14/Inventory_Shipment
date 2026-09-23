CREATE   PROCEDURE logistics.usp_Container_AddEvent
    @ContainerId  INT,
    @EventType    NVARCHAR(20),
    @EventDate    DATE,
    @PortId       INT           = NULL,
    @LocationText NVARCHAR(100) = NULL,
    @Notes        NVARCHAR(300) = NULL,
    @UserId       INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @EventType = NULLIF(LTRIM(RTRIM(@EventType)), N'');
    SET @LocationText = NULLIF(LTRIM(RTRIM(@LocationText)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    IF @EventType IS NULL OR @EventType NOT IN (N'Booked', N'Dispatched', N'PortArrival', N'CustomsRelease', N'BorderCrossing', N'Note')
        THROW 69000, 'Event type must be Booked, Dispatched, PortArrival, CustomsRelease, BorderCrossing or Note (the offload writes its own event).', 1;
    IF @EventDate IS NULL THROW 69000, 'The event date is required.', 1;
    IF @PortId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Ports WHERE Id = @PortId) THROW 69000, 'Port not found.', 1;

    DECLARE @Status TINYINT = (SELECT Status FROM logistics.Containers WHERE Id = @ContainerId);
    IF @Status IS NULL THROW 69006, 'Container not found.', 1;
    IF @Status = 8 THROW 69010, 'A cancelled container cannot receive events.', 1;
    IF @Status >= 6 AND @EventType <> N'Note' THROW 69010, 'The container is already offloaded; only notes can be added.', 1;
    IF @Status = 1 AND @EventType <> N'Note' THROW 69010, 'Confirm the container before recording its route.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO logistics.ContainerEvents (ContainerId, EventType, EventDate, PortId, LocationText, Notes, CreatedBy)
        VALUES (@ContainerId, @EventType, @EventDate, @PortId, @LocationText, @Notes, @UserId);

        UPDATE logistics.Containers
        SET DispatchDate       = CASE WHEN @EventType = N'Dispatched'     THEN @EventDate ELSE DispatchDate END,
            ActualPortArrival  = CASE WHEN @EventType = N'PortArrival'    THEN @EventDate ELSE ActualPortArrival END,
            CustomsReleaseDate = CASE WHEN @EventType = N'CustomsRelease' THEN @EventDate ELSE CustomsReleaseDate END,
            BorderCrossingDate = CASE WHEN @EventType = N'BorderCrossing' THEN @EventDate ELSE BorderCrossingDate END,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @ContainerId;

        EXEC logistics.usp_Container_RefreshStatus @ContainerId;

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        VALUES (@ContainerId, N'Event', @EventType + N' on ' + CONVERT(NVARCHAR(10), @EventDate, 23)
                + ISNULL(N' - ' + (SELECT PortName FROM masterdata.Ports WHERE Id = @PortId), ISNULL(N' - ' + @LocationText, N'')), @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

