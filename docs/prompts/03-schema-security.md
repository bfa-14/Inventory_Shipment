# Move the existing security objects from `dbo` to the `security` schema — VS Code prompt

Convention from now on: **one SQL schema per module** — `security` (users, roles, permissions, sessions),
`inventory` (stock), `shipment` (dispatch). Nothing new is ever created in `dbo`.

The scripts in `Database\` have been rewritten for this: `01` (tables), `02` (seed admin), `03` (roles &
permissions), `04` (drop the legacy Role column) all create their objects in `security`, and the new
`05_Migrate_dbo_To_Security.sql` moves an existing database's objects from `dbo` to `security` with all data.
This prompt applies the change to the code on your machine, whatever state it is in.

```text
You are working on two folders and may read and modify files in both:
- API:  D:\VSProjects\Inventory_Shipment (Inventory_Shipment.slnx, .NET 10; Dapper repositories in
        Inventory_Shipment.Repository; the embedded Inventory_Shipment.Repository\Database\Schema.sql is applied at
        start-up, split on GO, every batch idempotent)
- Web:  D:\VSProjects\Inventory_Shipment.Web (not changed by this task)
Database: SQL Server default instance (Server=.), database Inventory_Shipment, Windows Authentication.
Dev sign-in: admin / Admin@12345.

Rule: every database object belongs to a schema per module - security (users, refresh tokens, login audit, roles,
permissions, user roles and their functions/procedures), later inventory and shipment. Nothing lives in dbo.

The SQL scripts in D:\VSProjects\Inventory_Shipment\Database\ already follow the rule:
  01_Create_Schema.sql               security.Users / RefreshTokens / LoginAudit (creates the schema)
  02_Seed_Admin.sql                  first admin in security.Users
  03_Security_RBAC.sql               security.Roles / Permissions / RolePermissions / UserRoles, functions
                                     security.fn_UserRoles / fn_UserPermissions / fn_UserHasPermission, procedures
                                     security.usp_Permission_SyncCatalog / usp_User_GetAccess / usp_User_SetRoles /
                                     usp_Role_SetPermissions / usp_Role_Delete, seed data
  04_Security_DropLegacyRoleColumn.sql  drops security.Users.Role (only after the code stops reading it)
  05_Migrate_dbo_To_Security.sql     moves existing dbo objects to security, keeping every row; drops the old dbo
                                     routines (03 re-creates them in security). Idempotent.

Task:
1. Detect the current state and show me the output:
   SELECT SCHEMA_NAME(schema_id) AS [schema], name, type_desc FROM sys.objects
   WHERE name IN ('Users','RefreshTokens','LoginAudit','Roles','Permissions','RolePermissions','UserRoles',
                  'fn_UserRoles','fn_UserPermissions','fn_UserHasPermission','usp_Permission_SyncCatalog',
                  'usp_User_GetAccess','usp_User_SetRoles','usp_Role_SetPermissions','usp_Role_Delete')
   ORDER BY [schema], type_desc, name;
   Also tell me whether the code still uses the single-role column (search the solution for "Users.Role" /
   "Role = user.Role" / a UserRole enum) or already uses security.UserRoles - it decides step 4.
2. Run, in this order, with sqlcmd -S . -E -d Inventory_Shipment -i "<file>" (or Invoke-Sqlcmd):
   Database\05_Migrate_dbo_To_Security.sql   then   Database\03_Security_RBAC.sql
   Show the output of both. 03 keeps the Users.Role column, so it is safe even if the roles/permissions code
   has not been written yet.
3. Code: in Inventory_Shipment.Repository replace every "dbo." inside SQL strings and stored-procedure names with
   "security." (UserRepository, RefreshTokenRepository, LoginAuditRepository and, if they exist, RoleRepository,
   PermissionRepository). Then search the whole solution (*.cs, *.sql, *.json) for "dbo." and report anything left;
   the only allowed occurrences are inside 05 (the migration itself) and "AUTHORIZATION [dbo]".
4. Rebuild Inventory_Shipment.Repository\Database\Schema.sql from the scripts, in this order, each without its
   "USE [Inventory_Shipment];" batch and without final report SELECTs:
     05_Migrate_dbo_To_Security.sql, 01_Create_Schema.sql (without the CREATE DATABASE batch), 03_Security_RBAC.sql,
     and 04_Security_DropLegacyRoleColumn.sql ONLY if step 1 showed the code no longer reads Users.Role.
5. dotnet build D:\VSProjects\Inventory_Shipment\Inventory_Shipment.slnx (0 warnings), then start the API
   (dotnet run --project D:\VSProjects\Inventory_Shipment\Inventory_Shipment.API --launch-profile https) and verify:
   - start-up log shows "Database schema verified" and no error;
   - curl -k -X POST https://localhost:7089/api/auth/login -H "Content-Type: application/json"
       -d "{\"username\":\"admin\",\"password\":\"Admin@12345\"}"  -> 200 with accessToken;
   - GET https://localhost:7089/api/auth/me with the token -> 200;
   - the query from step 1 now shows every object in schema security and none in dbo;
   - SELECT COUNT(*) FROM security.Users returns the same number of users as before the migration.
6. Report: the outputs of steps 1, 2 and 5, and every file you changed.
```

After this, the Security module prompts in `02-security-rbac.md` (already updated to `security.*` names) and
the inventory plan (`inventory.*`) continue from here.
