SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ==================================================================================================
   74: Dashboard - its own permission
   --------------------------------------------------------------------------------------------------
   The Dashboard (script 68) was open to every signed-in user; each figure on it was already hidden
   from a reader who may not open the screen it comes from. It now has its own permission, so who sees
   the Dashboard at all is decided per role on Role Permissions, like every other screen.

     security.Permissions: dashboard.view "View Dashboard" (module Dashboard, new), granted ONCE, when it
     is first created, to EVERY role - nobody loses the Dashboard on the day this runs; untick it on
     Role Permissions for the roles that should not see it. The start-up sync of the catalog keeps it
     (and gives it to the system roles) afterwards.

   Data only (no object changes). Idempotent: a role that was unticked later is never re-granted.
   ================================================================================================== */

SET XACT_ABORT ON;
BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @Changed TABLE (Action NVARCHAR(10) NOT NULL, PermissionId INT NOT NULL);

    MERGE security.Permissions AS target
    USING (VALUES (N'dashboard.view', N'View Dashboard', N'Dashboard',
                   N'Open the Dashboard. Each figure on it still shows only to who may open the screen it comes from.', 5))
          AS source (Code, Name, Module, Description, SortOrder)
    ON target.Code = source.Code
    WHEN MATCHED AND (target.Name <> source.Name OR target.Module <> source.Module
                      OR ISNULL(target.Description, N'') <> source.Description OR target.SortOrder <> source.SortOrder) THEN
        UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (Code, Name, Module, Description, SortOrder)
        VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder)
    OUTPUT $action, inserted.Id INTO @Changed (Action, PermissionId);

    -- Only on the run that creates it: every role keeps the Dashboard it already had.
    IF EXISTS (SELECT 1 FROM @Changed WHERE Action = N'INSERT')
    BEGIN
        INSERT INTO security.RolePermissions (RoleId, PermissionId)
        SELECT r.Id, c.PermissionId
        FROM security.Roles r
        CROSS JOIN @Changed c
        WHERE c.Action = N'INSERT'
          AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = c.PermissionId);

        DECLARE @Roles INT = @@ROWCOUNT;
        PRINT 'Dashboard permission created and granted once to ' + CAST(@Roles AS NVARCHAR(10)) + ' role(s).';
    END

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH
GO

-- Check: the permission and how many roles hold it.
SELECT p.Code, p.Name, Roles = (SELECT COUNT(*) FROM security.RolePermissions rp WHERE rp.PermissionId = p.Id)
FROM security.Permissions p WHERE p.Code = N'dashboard.view';
GO

PRINT 'Script 74 applied: the Dashboard has its own permission.';
GO
