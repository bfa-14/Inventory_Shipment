/* ================================================================== 4. Bulk actions on selected containers */

-- Container no. and seal no. of several containers at once (e.g. the list sent by the forwarder after loading).
-- Both values are written: an empty one clears it. Rows that do not change are left alone.
-- Returns the containers (Id, ContainerRef, ContainerNo, SealNo, RowVersion).
CREATE   PROCEDURE logistics.usp_Container_SetNumbers
    @Items  logistics.tvp_ContainerNumber READONLY,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @N TABLE (ContainerId INT NOT NULL PRIMARY KEY, ContainerNo NVARCHAR(20) NULL, SealNo NVARCHAR(30) NULL,
                      Changed BIT NOT NULL, IsOpen BIT NOT NULL);
    INSERT INTO @N (ContainerId, ContainerNo, SealNo, Changed, IsOpen)
    SELECT ContainerId, UPPER(NULLIF(LTRIM(RTRIM(ContainerNo)), N'')), NULLIF(LTRIM(RTRIM(SealNo)), N''), 0, 0
    FROM @Items;

    IF NOT EXISTS (SELECT 1 FROM @N) THROW 69000, 'Select at least one container.', 1;
    IF EXISTS (SELECT 1 FROM @N n WHERE NOT EXISTS (SELECT 1 FROM logistics.Containers c WHERE c.Id = n.ContainerId))
        THROW 69006, 'A selected container no longer exists.', 1;

    DECLARE @Msg NVARCHAR(400);

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE n
        SET Changed = CASE WHEN ISNULL(c.ContainerNo, N'') <> ISNULL(n.ContainerNo, N'') OR ISNULL(c.SealNo, N'') <> ISNULL(n.SealNo, N'')
                           THEN 1 ELSE 0 END,
            IsOpen  = CASE WHEN c.Status < 7 THEN 1 ELSE 0 END
        FROM @N n
        INNER JOIN logistics.Containers c WITH (UPDLOCK, HOLDLOCK) ON c.Id = n.ContainerId;

        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' is offloaded, closed or cancelled: its numbers can no longer change.'
        FROM @N n INNER JOIN logistics.Containers c ON c.Id = n.ContainerId
        WHERE n.Changed = 1 AND c.Status >= 6
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 69005, @Msg, 1;

        -- the numbers of the open containers of the list, as they will be
        SELECT TOP (1) @Msg = N'Container number ' + ContainerNo + N' is typed more than once.'
        FROM @N WHERE ContainerNo IS NOT NULL AND IsOpen = 1
        GROUP BY ContainerNo HAVING COUNT(*) > 1
        ORDER BY ContainerNo;
        IF @Msg IS NOT NULL THROW 69013, @Msg, 1;

        -- another open container keeps its number unless it is in the list too
        SELECT TOP (1) @Msg = N'Container number ' + n.ContainerNo + N' is already used by ' + o.ContainerRef + N'.'
        FROM @N n
        INNER JOIN logistics.Containers o WITH (UPDLOCK, HOLDLOCK)
                ON o.ContainerNo = n.ContainerNo AND o.Status < 7 AND o.Id <> n.ContainerId
        WHERE n.Changed = 1 AND NOT EXISTS (SELECT 1 FROM @N m WHERE m.ContainerId = o.Id)
        ORDER BY n.ContainerNo;
        IF @Msg IS NOT NULL THROW 69013, @Msg, 1;

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        SELECT n.ContainerId, N'Updated', LEFT(N'Container no. ' + ISNULL(n.ContainerNo, N'(none)') + N', seal no. ' + ISNULL(n.SealNo, N'(none)'), 500), @UserId
        FROM @N n WHERE n.Changed = 1;

        UPDATE c
        SET ContainerNo = n.ContainerNo, SealNo = n.SealNo, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        FROM logistics.Containers c
        INNER JOIN @N n ON n.ContainerId = c.Id
        WHERE n.Changed = 1;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        IF ERROR_NUMBER() IN (2601, 2627)
            THROW 69013, 'A container number was just given to another container by someone else. Reload and try again.', 1;
        THROW;
    END CATCH

    SELECT c.Id, c.ContainerRef, c.ContainerNo, c.SealNo, c.RowVersion
    FROM @N n
    INNER JOIN logistics.Containers c ON c.Id = n.ContainerId
    ORDER BY c.ContainerRef;
END

GO

