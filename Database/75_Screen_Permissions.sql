SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ==================================================================================================
   75: Four screens get their own permission
   --------------------------------------------------------------------------------------------------
   Four menu screens borrowed another screen's permission, so they could not be given or taken on
   their own. Each now has its own:

     inventory.valuation.view   "View Stock Valuation"     Inventory › Stock Valuation   (borrowed View Items)
     sales.statement.view       "View Customer Statement"  Sales › Customer Statement    (borrowed View Receipts)
     containers.movements.view  "View Movements"           Logistics › Movements         (borrowed View Containers)
     containers.tracking.view   "View Tracking"            Logistics › Tracking          (borrowed View Containers)

   Granted ONCE, when each is first created, to every role holding the permission the screen borrowed
   (Movements also to the roles that manage movements), so nobody loses a screen on the day this runs;
   untick them on Role Permissions afterwards. A role unticked later is never re-granted. The start-up
   sync of the catalog keeps them (and gives them to the system roles).

   What stays as it was: a container's own page still shows its movements and its route to anyone who
   may view containers; editing movements still needs "Manage Shipment Movements".

   Data only (no object changes). Idempotent.
   ================================================================================================== */

SET XACT_ABORT ON;
BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @Changed TABLE (Action NVARCHAR(10) NOT NULL, PermissionId INT NOT NULL, Code NVARCHAR(100) NOT NULL);

    MERGE security.Permissions AS target
    USING
    (
        VALUES
            (N'inventory.valuation.view',  N'View Stock Valuation',    N'Inventory',  N'Open Stock Valuation: the stock of every item and warehouse at its average cost.', 405),
            (N'sales.statement.view',      N'View Customer Statement', N'Sales',      N'Open the Customer Statement: a customer''s invoices, receipts and balance.',    705),
            (N'containers.movements.view', N'View Movements',          N'Containers', N'Open the Movements list and a movement''s page (a container''s own page shows its movements with View Containers).', 1405),
            (N'containers.tracking.view',  N'View Tracking',           N'Containers', N'Open the Tracking board (a container''s own page shows its route with View Containers).', 1407)
    ) AS source (Code, Name, Module, Description, SortOrder)
    ON target.Code = source.Code
    WHEN MATCHED AND (target.Name <> source.Name OR target.Module <> source.Module
                      OR ISNULL(target.Description, N'') <> source.Description OR target.SortOrder <> source.SortOrder) THEN
        UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (Code, Name, Module, Description, SortOrder)
        VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder)
    OUTPUT $action, inserted.Id, inserted.Code INTO @Changed (Action, PermissionId, Code);

    IF EXISTS (SELECT 1 FROM @Changed WHERE Action = N'INSERT')
    BEGIN
        -- Each new permission goes to the roles that hold what its screen borrowed until today.
        DECLARE @From TABLE (Code NVARCHAR(100) NOT NULL, FromCode NVARCHAR(100) NOT NULL);
        INSERT INTO @From (Code, FromCode) VALUES
            (N'inventory.valuation.view',  N'inventory.items.view'),
            (N'sales.statement.view',      N'sales.receipts.view'),
            (N'containers.movements.view', N'containers.view'),
            (N'containers.movements.view', N'containers.movements.manage'),
            (N'containers.tracking.view',  N'containers.view');

        INSERT INTO security.RolePermissions (RoleId, PermissionId)
        SELECT DISTINCT r.Id, c.PermissionId
        FROM @Changed c
        INNER JOIN @From f ON f.Code = c.Code
        CROSS JOIN security.Roles r
        WHERE c.Action = N'INSERT'
          AND (r.IsSystem = 1
               OR EXISTS (SELECT 1 FROM security.RolePermissions rp INNER JOIN security.Permissions p ON p.Id = rp.PermissionId
                          WHERE rp.RoleId = r.Id AND p.Code = f.FromCode))
          AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = c.PermissionId);

        DECLARE @Grants INT = @@ROWCOUNT;
        DECLARE @Created INT = (SELECT COUNT(*) FROM @Changed WHERE Action = N'INSERT');
        PRINT 'Screen permissions created: ' + CAST(@Created AS NVARCHAR(10))
              + ', granted once: ' + CAST(@Grants AS NVARCHAR(10)) + ' role grant(s).';
    END

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH
GO

-- Check: each new permission and how many roles hold it.
SELECT p.Code, p.Name, Roles = (SELECT COUNT(*) FROM security.RolePermissions rp WHERE rp.PermissionId = p.Id)
FROM security.Permissions p
WHERE p.Code IN (N'inventory.valuation.view', N'sales.statement.view', N'containers.movements.view', N'containers.tracking.view')
ORDER BY p.SortOrder;
GO

PRINT 'Script 75 applied: Stock Valuation, Customer Statement, Movements and Tracking have their own permissions.';
GO
