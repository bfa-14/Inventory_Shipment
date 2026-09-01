/* ------------------------------------------------------------------ 3. Procedures */

-- Upserts the permission catalog the API defines in code, and makes sure every system role
-- (Admin) holds every permission. Called by the API on start-up.
-- @CatalogJson: [{"code":"security.users.view","name":"View users","module":"Security","description":"...","sortOrder":10}, ...]
CREATE   PROCEDURE security.usp_Permission_SyncCatalog
    @CatalogJson NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        MERGE security.Permissions AS target
        USING
        (
            SELECT j.code, j.name, j.module, j.description, ISNULL(j.sortOrder, 0) AS sortOrder
            FROM OPENJSON(@CatalogJson)
            WITH
            (
                code        NVARCHAR(100) '$.code',
                name        NVARCHAR(100) '$.name',
                module      NVARCHAR(50)  '$.module',
                description NVARCHAR(250) '$.description',
                sortOrder   INT           '$.sortOrder'
            ) AS j
            WHERE j.code IS NOT NULL
        ) AS source
        ON target.Code = source.code
        WHEN MATCHED THEN
            UPDATE SET Name = source.name, Module = source.module, Description = source.description, SortOrder = source.sortOrder
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (Code, Name, Module, Description, SortOrder)
            VALUES (source.code, source.name, source.module, source.description, source.sortOrder);

        INSERT INTO security.RolePermissions (RoleId, PermissionId)
        SELECT r.Id, p.Id
        FROM security.Roles r
        CROSS JOIN security.Permissions p
        WHERE r.IsSystem = 1
          AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END