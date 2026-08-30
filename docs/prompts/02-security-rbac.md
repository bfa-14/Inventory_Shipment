# Security module (Users · Roles · Permissions) — VS Code prompts

Feature: after sign-in the app gets a real shell (left navigation menu + content container) and a
**Security** section with **Users**, **Roles**, **Permissions** (and a read-only **Login audit**).
Access is role-based: users hold roles, roles hold permissions, every API endpoint and every menu
item is guarded by a permission code such as `security.users.view`.

## Run order

| Step | What | Who runs it |
|------|------|-------------|
| 1 | `Database\05_Migrate_dbo_To_Security.sql` (only if your tables are still in dbo), then `Database\03_Security_RBAC.sql`, in SSMS on **Inventory_Shipment** | you (or the assistant with sqlcmd) |
| 2 | **Prompt 1** — database check + embed the script in the API | VS Code assistant |
| 3 | **Prompt 2** — Model / Repository / Service | VS Code assistant |
| 4 | **Prompt 3** — API (permission-based authorization, controllers) | VS Code assistant |
| 5 | `Database\04_Security_DropLegacyRoleColumn.sql` in SSMS (optional — the API does it on start-up) | you |
| 6 | **Prompt 4** — React shell + Security pages | VS Code assistant |

Send me the assistant's report after each prompt (especially anything that failed) before moving to
the next one. Each prompt is self-contained — copy the whole block.

---

## Prompt 1 — Database + embedded schema

```text
Context:
- Backend solution: D:\VSProjects\Inventory_Shipment (Inventory_Shipment.slnx, .NET 10). Projects:
  Inventory_Shipment.API (ASP.NET Core Web API, JWT auth, Scalar docs at /scalar),
  Inventory_Shipment.Service, Inventory_Shipment.Repository (Dapper + Microsoft.Data.SqlClient),
  Inventory_Shipment.Model. SQL scripts live in D:\VSProjects\Inventory_Shipment\Database\.
- Database objects live in one schema per module: security (this module), later inventory and shipment. Never create objects in dbo.
- The API applies Inventory_Shipment.Repository\Database\Schema.sql on every start-up: it is an
  embedded resource, split into batches on lines that contain only GO, and every batch must be
  idempotent (see DatabaseInitializer.cs).
- Database: SQL Server default instance (Server=.), database Inventory_Shipment, Windows Authentication.
- Frontend (not touched in this prompt): D:\VSProjects\Inventory_Shipment.Web.

We are adding a Security module (roles, permissions, user-role assignments). The SQL is already
written: D:\VSProjects\Inventory_Shipment\Database\03_Security_RBAC.sql (tables security.Roles,
security.Permissions, security.RolePermissions, security.UserRoles; functions security.fn_UserRoles, security.fn_UserPermissions,
security.fn_UserHasPermission; procedures security.usp_Permission_SyncCatalog, security.usp_User_GetAccess,
security.usp_User_SetRoles, security.usp_Role_SetPermissions, security.usp_Role_Delete; seed data; migration of the
legacy single-role column security.Users.Role into security.UserRoles). It deliberately KEEPS security.Users.Role so
the currently deployed code keeps working; 04_Security_DropLegacyRoleColumn.sql removes it later.

Task:
1. If the tables Users / RefreshTokens / LoginAudit are still in the dbo schema (SELECT SCHEMA_NAME(schema_id), name
   FROM sys.tables WHERE name = 'Users'), first run Database\05_Migrate_dbo_To_Security.sql the same way; it moves
   them to the security schema with their data. Then run Database\03_Security_RBAC.sql against Inventory_Shipment
   (sqlcmd -S . -E -d Inventory_Shipment -i "D:\VSProjects\Inventory_Shipment\Database\03_Security_RBAC.sql")
   and show me its output, including the two result sets at the end (roles with counts, users with roles).
   If it fails, show the exact error and line, do not modify the script, stop and report.
2. Verify the objects exist and show the output:
   SELECT SCHEMA_NAME(schema_id) AS [schema], name, type_desc FROM sys.objects
   WHERE name IN ('Users','RefreshTokens','LoginAudit','Roles','Permissions','RolePermissions','UserRoles',
                  'fn_UserRoles','fn_UserPermissions','fn_UserHasPermission','usp_Permission_SyncCatalog',
                  'usp_User_GetAccess','usp_User_SetRoles','usp_Role_SetPermissions','usp_Role_Delete')
   ORDER BY type_desc, name;   -- every row must show schema = security
   SELECT * FROM security.fn_UserPermissions((SELECT Id FROM security.Users WHERE Username = N'admin'));
   (expect the 7 security.* codes)
3. Rebuild Inventory_Shipment.Repository\Database\Schema.sql (the embedded schema the API applies on start-up)
   from the scripts in Database\, in this order, each under a comment banner and WITHOUT its
   "USE [Inventory_Shipment];" batch:
     05_Migrate_dbo_To_Security.sql  (without the final report SELECT)
     01_Create_Schema.sql            (without the CREATE DATABASE batch)
     03_Security_RBAC.sql            (without the final report batch: the two SELECTs and the PRINT)
   Keep every GO separator and the compatibility-level check batch. Do NOT include
   04_Security_DropLegacyRoleColumn.sql yet (the current code still reads security.Users.Role).
   Then make sure every SQL string in Inventory_Shipment.Repository (UserRepository, RefreshTokenRepository,
   LoginAuditRepository) references security.Users / security.RefreshTokens / security.LoginAudit - no "dbo." left.
4. Build the solution (dotnet build D:\VSProjects\Inventory_Shipment\Inventory_Shipment.slnx), start the API
   (dotnet run --project D:\VSProjects\Inventory_Shipment\Inventory_Shipment.API --launch-profile https)
   and confirm the start-up log still shows "Database schema verified" with no error, then stop it.
5. Report: script output, verification output, and the files you changed.
```

---

## Prompt 2 — Model, Repository and Service layers

```text
Context:
- Backend solution: D:\VSProjects\Inventory_Shipment (Inventory_Shipment.slnx, .NET 10, C# 13, nullable enabled).
  Layers: Inventory_Shipment.Model (entities, DTOs, Options, Common/Result.cs), Inventory_Shipment.Repository
  (Dapper repositories over ISqlConnectionFactory, interfaces in Interfaces/, implementations in
  Implementations/, DependencyInjection.AddRepositoryLayer), Inventory_Shipment.Service (business logic,
  interfaces in Interfaces/, implementations in Implementations/, Security/, Seeding/, Mapping/UserMapper.cs,
  DependencyInjection.AddServiceLayer), Inventory_Shipment.API (controllers - NOT part of this prompt).
- Conventions to keep: services return Result / Result<T> (Model/Common/Result.cs, ErrorType.Validation |
  Unauthorized | Forbidden | NotFound | Conflict | Locked) instead of throwing for expected failures;
  repositories use Dapper with parameterized SQL and "await using var connection = _connectionFactory.Create()";
  timestamps are UTC (use .AsUtc() when mapping); no new NuGet packages (the machine restores offline).
- The database already has the Security schema (script Database\03_Security_RBAC.sql, also embedded in
  Repository\Database\Schema.sql). Relevant objects:
    security.Roles (Id, Name, Description, IsSystem, IsActive, CreatedAtUtc, UpdatedAtUtc)
    security.Permissions (Id, Code, Name, Module, Description, SortOrder)
    security.RolePermissions (RoleId, PermissionId, GrantedAtUtc)
    security.UserRoles (UserId, RoleId, AssignedAtUtc, AssignedBy)
    security.usp_User_GetAccess @UserId            -> result set 1: Id, Name (roles); result set 2: Code (permissions)
    security.usp_User_SetRoles @UserId, @RoleIds NVARCHAR(MAX) comma-separated, @AssignedBy INT = NULL
    security.usp_Role_SetPermissions @RoleId, @PermissionIds NVARCHAR(MAX) comma-separated
    security.usp_Role_Delete @RoleId
    security.usp_Permission_SyncCatalog @CatalogJson NVARCHAR(MAX)
        JSON array of {"code","name","module","description","sortOrder"}; upserts the catalog and gives
        every system role every permission.
    Business rules are enforced in the procedures with THROW and these error numbers (SqlException.Number):
        50001 role not found, 50002 permissions of a system role cannot be changed, 50003 user not found,
        50004 would remove the last active administrator, 50005 system role cannot be deleted,
        50006 role still assigned to users.
- The legacy column security.Users.Role still exists in the database but must no longer be used by the code
  (it will be dropped by the next step). Users now have zero or more roles through security.UserRoles.

Task: implement roles and permissions in Model, Repository and Service. Do not touch the API project
(that is the next prompt) except where a compile error forces a minimal change - list any such change.

MODEL (Inventory_Shipment.Model)
1. Delete the UserRole enum. Keep a static class Roles with string constants Admin = "Admin",
   Manager = "Manager", User = "User" (the system role is Admin).
2. Add Security/PermissionCatalog.cs:
     public sealed record PermissionDefinition(string Code, string Name, string Module, string Description, int SortOrder);
     public static class Permissions
     {
         public static class Security
         {
             public const string UsersView = "security.users.view";
             public const string UsersCreate = "security.users.create";
             public const string UsersEdit = "security.users.edit";
             public const string RolesView = "security.roles.view";
             public const string RolesManage = "security.roles.manage";
             public const string PermissionsView = "security.permissions.view";
             public const string AuditView = "security.audit.view";
         }
         public static IReadOnlyList<PermissionDefinition> All { get; }  // the 7 above, module "Security",
             // names: View users / Create users / Edit users / View roles / Manage roles / View permissions /
             // View login audit, sort order 10..70, one-sentence descriptions.
         public const string ClaimType = "permission";   // JWT claim type
     }
3. Entities: remove User.Role. Add Role (Id, Name, Description?, IsSystem, IsActive, CreatedAtUtc,
   UpdatedAtUtc?) and Permission (Id, Code, Name, Module, Description?, SortOrder).
   Add Security/UserAccess.cs: sealed record RoleRef(int Id, string Name); sealed class UserAccess
   { IReadOnlyList<RoleRef> Roles; IReadOnlyList<string> Permissions; static UserAccess Empty }.
4. DTOs (keep existing ones working):
   - UserDto: add string[] Roles (names), int[] RoleIds, string[] Permissions. Remove the string Role.
   - CreateUserRequest: replace Role with int[] RoleIds (default empty).
   - New: UpdateUserRequest (FullName [Required, StringLength(100)], Email [Required, EmailAddress, StringLength(256)]),
     SetUserRolesRequest (int[] RoleIds [Required]),
     RoleDto (Id, Name, Description, IsSystem, IsActive, UserCount, PermissionCount, CreatedAtUtc),
     RoleDetailDto : RoleDto + int[] PermissionIds + PermissionDto[] Permissions,
     CreateRoleRequest (Name [Required, StringLength(50, MinimumLength = 2)], Description [StringLength(250)], int[] PermissionIds),
     UpdateRoleRequest (Name, Description, bool IsActive),
     SetRolePermissionsRequest (int[] PermissionIds [Required]),
     PermissionDto (Id, Code, Name, Module, Description, SortOrder, string[] Roles = names of roles holding it),
     PermissionModuleDto (Module, PermissionDto[] Permissions),
     LoginAuditDto (Id, Username, UserId, Succeeded, FailureReason, IpAddress, UserAgent, AttemptedAtUtc),
     LoginAuditQuery (string? Username, bool OnlyFailed = false, int Take = 200 [Range(1, 1000)]).

REPOSITORY (Inventory_Shipment.Repository)
5. Add Exceptions/SecurityRuleException.cs: sealed class SecurityRuleException(int Code, string Message) : Exception.
   Add a helper (e.g. Database/SqlErrors.cs) with constants for 50001..50006 and a method that turns a
   SqlException with Number between 50001 and 50999 into a SecurityRuleException; use it in every repository
   method that calls one of the procedures ("catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))").
6. UserRepository: remove Role from every SELECT and the INSERT (security.Users.Role still exists in the DB
   and has a default, so simply do not mention it). Add to IUserRepository/UserRepository:
   - Task<UserAccess> GetAccessAsync(int userId, CancellationToken) - calls security.usp_User_GetAccess with
     CommandType.StoredProcedure and QueryMultipleAsync; result set 1 -> RoleRef list, 2 -> string list.
   - Task SetRolesAsync(int userId, IEnumerable<int> roleIds, int? assignedBy, CancellationToken) -
     security.usp_User_SetRoles with @RoleIds = string.Join(",", roleIds).
   - Task<bool> UpdateProfileAsync(int userId, string fullName, string email, CancellationToken)
     (also sets UpdatedAtUtc = SYSUTCDATETIME()).
   - Task<bool> EmailExistsForOtherUserAsync(string email, int excludeUserId, CancellationToken).
   - Task<IReadOnlyList<(int UserId, int RoleId, string RoleName)>> GetRolesForUsersAsync(IEnumerable<int> userIds, CancellationToken)
     - one query over security.UserRoles JOIN security.Roles WHERE UserId IN @UserIds (Dapper list expansion).
   - Task<int> CountActiveSystemAdminsAsync(int? excludeUserId, CancellationToken) - active users holding
     a role with IsSystem = 1, excluding the given user.
7. Add IRoleRepository/RoleRepository:
   GetAllAsync() -> Role + UserCount + PermissionCount (use a small internal row type or RoleDto-shaped
   projection), GetByIdAsync(id), GetByNameAsync(name), NameExistsAsync(name, excludeId?),
   GetPermissionIdsAsync(roleId), CreateAsync(Role) -> id (OUTPUT INSERTED.Id), UpdateAsync(Role) -> bool,
   DeleteAsync(id) -> security.usp_Role_Delete, SetPermissionsAsync(roleId, IEnumerable<int>) -> security.usp_Role_SetPermissions.
8. Add IPermissionRepository/PermissionRepository:
   GetAllAsync() -> permissions ordered by Module, SortOrder;
   GetRoleNamesByPermissionAsync() -> IReadOnlyList<(int PermissionId, string RoleName)>;
   SyncCatalogAsync(IEnumerable<PermissionDefinition>) -> serialize with System.Text.Json
   (JsonNamingPolicy.CamelCase) and call security.usp_Permission_SyncCatalog.
9. ILoginAuditRepository: add QueryAsync(LoginAuditQuery) -> newest first, TOP (@Take), optional
   Username filter (exact match, case-insensitive per collation) and Succeeded = 0 when OnlyFailed.
10. Register the new repositories in DependencyInjection.AddRepositoryLayer.

SERVICE (Inventory_Shipment.Service)
11. ITokenService.CreateAccessToken(User user, UserAccess access): emit one "role" claim per role name and
    one Permissions.ClaimType ("permission") claim per permission code (SecurityTokenDescriptor.Claims
    accepts a collection value for a claim type). Remove the old single role claim. Keep RoleClaimType = "role".
12. UserMapper.ToDto(User user, UserAccess access) fills Roles/RoleIds/Permissions; keep a ToDto(User)
    overload that uses UserAccess.Empty for list views that fill roles separately.
13. AuthService: after a successful password check load access = await _users.GetAccessAsync(user.Id) and
    use it for the token and the UserDto; do the same in RefreshAsync and GetCurrentUserAsync.
14. IUserService / UserService:
    - GetAllAsync: one query for users + one GetRolesForUsersAsync call; fill Roles and RoleIds per user.
    - GetByIdAsync: include roles and permissions (GetAccessAsync).
    - CreateAsync(CreateUserRequest, int actingUserId): create, then SetRolesAsync(id, request.RoleIds, actingUserId).
    - UpdateAsync(int id, UpdateUserRequest): email uniqueness -> Conflict; NotFound when missing.
    - SetRolesAsync(int id, IEnumerable<int> roleIds, int actingUserId): map SecurityRuleException 50004 ->
      ErrorType.Validation with the SQL message, 50003 -> NotFound.
    - SetActiveAsync: keep "cannot deactivate yourself"; additionally, when deactivating a user who holds a
      system role and CountActiveSystemAdminsAsync(excludeUserId: id) == 0 -> Validation
      "Cannot deactivate the last active administrator."
    - ResetPasswordAsync unchanged.
15. Add IRoleService / RoleService:
    GetAllAsync -> RoleDto list; GetByIdAsync -> RoleDetailDto (with PermissionDto list of the role's
    permissions) or NotFound; CreateAsync(CreateRoleRequest) -> Conflict when the name exists, creates with
    IsSystem = false, then SetPermissionsAsync; UpdateAsync(id, UpdateRoleRequest) -> a system role cannot be
    renamed or deactivated (Validation), name uniqueness -> Conflict; DeleteAsync(id) -> map 50001 NotFound,
    50005 Validation, 50006 Conflict; SetPermissionsAsync(id, permissionIds) -> map 50001 NotFound, 50002 Validation.
16. Add IPermissionService / PermissionService: GetCatalogAsync() -> PermissionModuleDto[] grouped by Module,
    permissions ordered by SortOrder, each with the names of the roles that hold it.
17. Add ILoginAuditService / LoginAuditService: GetAsync(LoginAuditQuery) -> LoginAuditDto[].
18. Add ISecurityBootstrapper / SecurityBootstrapper in Seeding/: SyncPermissionCatalogAsync() calls
    IPermissionRepository.SyncCatalogAsync(Permissions.All). AdminSeeder: after creating the admin user,
    look up the "Admin" role (IRoleRepository.GetByNameAsync) and call SetRolesAsync(adminId, [roleId], null);
    log an error if the role does not exist. Also, when users already exist but none holds a system role
    (CountActiveSystemAdminsAsync(null) == 0) and a user named admin exists, give that user the Admin role
    and log a warning.
19. Register everything in DependencyInjection.AddServiceLayer.

VERIFY
20. dotnet build D:\VSProjects\Inventory_Shipment\Inventory_Shipment.slnx must succeed with 0 warnings.
    The API project will not compile until the controllers are updated in the next prompt only if you changed
    a signature it uses (e.g. CreateAccessToken, UserService.CreateAsync): make the minimal edit in the API
    that keeps it compiling and list it, or leave a clear TODO and tell me.
21. Report: every file added/changed, and any place where you deviated from this specification and why.
```

---

## Prompt 3 — API: permission-based authorization and controllers

```text
Context:
- Backend solution: D:\VSProjects\Inventory_Shipment (Inventory_Shipment.slnx, .NET 10). The Model, Repository
  and Service layers already implement roles and permissions (see Inventory_Shipment.Model/Security/
  PermissionCatalog.cs: static class Permissions with Permissions.Security.* code constants,
  Permissions.All catalog and Permissions.ClaimType = "permission"; services IUserService, IRoleService,
  IPermissionService, ILoginAuditService, ISecurityBootstrapper; access tokens now carry one "role" claim per
  role and one "permission" claim per permission code).
- Inventory_Shipment.API today: JWT bearer auth configured in Extensions/AuthenticationExtensions.cs with
  RoleClaimType "role" and a FallbackPolicy that requires an authenticated user; Extensions/ResultExtensions.cs
  maps Result/Result<T> to ActionResults and problem details; controllers AuthController (api/auth) and
  UsersController (api/users, currently [Authorize(Policy = Policies.AdminOnly)]); OpenApi/
  BearerSecuritySchemeTransformer.cs; Program.cs runs IDatabaseInitializer then IDataSeeder at start-up;
  Repository\Database\Schema.sql is embedded and applied on start-up (batches split on GO).
- Database: SQL Server (Server=.), database Inventory_Shipment. Script Database\04_Security_DropLegacyRoleColumn.sql
  drops the now-unused column security.Users.Role (idempotent).
- Dev sign-in: admin / Admin@12345 (holds the system role Admin, which always has every permission).

Task: enforce permissions in the API and expose the Security endpoints.

AUTHORIZATION
1. Add Authorization/HasPermissionAttribute.cs: sealed class HasPermissionAttribute : AuthorizeAttribute with
   constructor (string permission) that sets Policy = $"{PermissionPolicyProvider.Prefix}{permission}".
2. Add Authorization/PermissionRequirement.cs (IAuthorizationRequirement with string Permission),
   Authorization/PermissionAuthorizationHandler.cs (succeeds when context.User.HasClaim(Permissions.ClaimType, requirement.Permission)),
   Authorization/PermissionPolicyProvider.cs implementing IAuthorizationPolicyProvider: for policy names starting
   with Prefix = "Permission:" build a policy RequireAuthenticatedUser + the PermissionRequirement (cache the
   built policies in a ConcurrentDictionary); delegate everything else, GetDefaultPolicyAsync and
   GetFallbackPolicyAsync to an inner DefaultAuthorizationPolicyProvider so the existing fallback policy keeps
   working. Register: services.AddSingleton<IAuthorizationPolicyProvider, PermissionPolicyProvider>() and
   services.AddSingleton<IAuthorizationHandler, PermissionAuthorizationHandler>() in AddJwtAuthentication.
   Remove the AdminOnly / ManagerOrAdmin policies and the Policies class if nothing else uses them.

START-UP (Program.cs)
3. After IDatabaseInitializer.InitializeAsync(): await ISecurityBootstrapper.SyncPermissionCatalogAsync(),
   then IDataSeeder.SeedAsync() (order matters: catalog, then seed).
4. Append the content of Database\04_Security_DropLegacyRoleColumn.sql to
   Inventory_Shipment.Repository\Database\Schema.sql under a banner "-- ===== 04: drop legacy security.Users.Role =====",
   without its "USE [Inventory_Shipment];" batch. The code no longer references that column, so it is now safe.

CONTROLLERS (all under [ApiController], [Produces("application/json")], use ResultExtensions, add
ProducesResponseType attributes like the existing controllers; the current user id comes from User.GetUserId())
5. UsersController (route api/users) - remove the class-level Authorize; per action:
   GET /              [HasPermission(Permissions.Security.UsersView)]   -> UserDto[]
   GET /{id:int}      [HasPermission(UsersView)]                        -> UserDto (with roles/permissions)
   POST /             [HasPermission(UsersCreate)]                      -> 201 CreatedAtAction
   PUT /{id:int}      [HasPermission(UsersEdit)]  body UpdateUserRequest -> 204
   PATCH /{id:int}/status [HasPermission(UsersEdit)]                    -> 204
   POST /{id:int}/reset-password [HasPermission(UsersEdit)]             -> 204
   PUT /{id:int}/roles [HasPermission(UsersEdit)] body SetUserRolesRequest -> 204
6. RolesController (route api/roles):
   GET /              [HasPermission(RolesView)]    -> RoleDto[]
   GET /{id:int}      [HasPermission(RolesView)]    -> RoleDetailDto
   POST /             [HasPermission(RolesManage)]  body CreateRoleRequest -> 201 with RoleDetailDto
   PUT /{id:int}      [HasPermission(RolesManage)]  body UpdateRoleRequest -> 204
   DELETE /{id:int}   [HasPermission(RolesManage)]  -> 204
   PUT /{id:int}/permissions [HasPermission(RolesManage)] body SetRolePermissionsRequest -> 204
7. PermissionsController (route api/permissions): GET / [HasPermission(PermissionsView)] -> PermissionModuleDto[].
8. SecurityController (route api/security): GET /login-audit [HasPermission(AuditView)] with query parameters
   username, onlyFailed, take (bind to LoginAuditQuery) -> LoginAuditDto[].
9. AuthController: GET /api/auth/me must return the UserDto with roles, roleIds and permissions.
   Everything else in AuthController stays as it is.

VERIFY (run the API with dotnet run --project D:\VSProjects\Inventory_Shipment\Inventory_Shipment.API --launch-profile https;
use curl -k or Invoke-RestMethod -SkipCertificateCheck; show me the commands and responses)
10. Start-up log shows the schema applied (including the 04 step the first time: "Dropped legacy column
    security.Users.Role"), the catalog synced and no errors. Confirm with SQL that security.Users no longer has a Role column.
11. POST /api/auth/login as admin -> decode the JWT payload (base64url of the middle segment) and show that it
    contains "role":"Admin" and 7 "permission" values; GET /api/auth/me shows roles ["Admin"] and 7 permissions.
12. GET /api/permissions -> one module "Security" with 7 permissions, each listing the roles that hold it.
13. GET /api/roles -> Admin (IsSystem true, 7 permissions), Manager (4), User (0).
14. PUT /api/roles/{adminRoleId}/permissions -> 400 with the "system role" message.
15. POST /api/roles {"name":"Warehouse Clerk","description":"Test role","permissionIds":[<id of security.users.view>]} -> 201.
16. POST /api/users {"username":"clerk1","email":"clerk1@example.com","fullName":"Clerk One",
    "password":"Clerk#2026!","roleIds":[<Warehouse Clerk id>]} -> 201 with roles ["Warehouse Clerk"].
17. Login as clerk1: token has exactly one permission (security.users.view). With clerk1's token:
    GET /api/users -> 200, GET /api/roles -> 403, GET /api/permissions -> 403, POST /api/users -> 403.
18. DELETE /api/roles/{Warehouse Clerk id} while clerk1 still has it -> 409. PUT /api/users/{clerk1 id}/roles
    {"roleIds":[]} -> 204, then DELETE the role -> 204.
19. PUT /api/users/{admin id}/roles {"roleIds":[]} -> 400 "last active administrator".
20. dotnet build with 0 warnings. Report: files added/changed and the output of each verification step.
```

---

## Prompt 4 — Frontend: app shell + Security pages (React)

```text
Context:
- Frontend: D:\VSProjects\Inventory_Shipment.Web - React 19 + Vite + TypeScript (strict), react-router v7
  (package "react-router"), plain CSS in src/index.css (no UI framework). Existing structure:
  src/api/http.ts (request<T>() with bearer token, automatic refresh on 401, ApiError with .messages and
  .status), src/api/auth.ts, src/api/users.ts, src/api/types.ts (DTOs), src/auth/AuthProvider.tsx +
  useAuth() (status, user, login, logout, logoutEverywhere, refresh, reloadUser), src/auth/ProtectedRoute.tsx,
  src/components/{Layout.tsx, Alert.tsx, format.ts}, src/pages/{LoginPage.tsx, DashboardPage.tsx, UsersPage.tsx},
  src/App.tsx (routes). The login page carries the customer's branding (Katanga TVS Motor Company: dark navy,
  red accent, logo); reuse those colors/assets for the whole app. The dev server proxies /api to the API.
- Backend (running at https://localhost:7089, docs at /scalar):
  GET /api/auth/me -> UserDto { id, username, email, fullName, roles: string[], roleIds: number[],
                       permissions: string[], isActive, lastLoginAtUtc, createdAtUtc }
  (the same UserDto is inside the login/refresh response as "user")
  Users     GET /api/users | GET /api/users/{id} | POST /api/users {username,email,fullName,password,roleIds}
            | PUT /api/users/{id} {fullName,email} | PATCH /api/users/{id}/status {isActive}
            | POST /api/users/{id}/reset-password {newPassword} | PUT /api/users/{id}/roles {roleIds}
  Roles     GET /api/roles -> RoleDto { id,name,description,isSystem,isActive,userCount,permissionCount,createdAtUtc }
            | GET /api/roles/{id} -> RoleDetailDto (+ permissionIds: number[], permissions: PermissionDto[])
            | POST /api/roles {name,description,permissionIds} | PUT /api/roles/{id} {name,description,isActive}
            | DELETE /api/roles/{id} | PUT /api/roles/{id}/permissions {permissionIds}
  Permissions GET /api/permissions -> PermissionModuleDto[] { module, permissions: PermissionDto[] }
            PermissionDto { id, code, name, module, description, sortOrder, roles: string[] }
  Audit     GET /api/security/login-audit?username=&onlyFailed=&take= -> LoginAuditDto[]
            { id, username, userId, succeeded, failureReason, ipAddress, userAgent, attemptedAtUtc }
  Errors are RFC 9457 problem details (400 validation with "errors", 401, 403, 404, 409, 423, 429); ApiError.messages
  already flattens them.
  Permission codes: security.users.view, security.users.create, security.users.edit, security.roles.view,
  security.roles.manage, security.permissions.view, security.audit.view. The Admin role has all of them.
- Dev sign-in: admin / Admin@12345.

Task: after sign-in, replace the current simple layout with a real application shell and add the Security section.
Keep the existing login page, http client and AuthProvider mechanics; extend them, do not rewrite them.
No new UI framework; you may add lucide-react for icons if it is not already installed. TypeScript must stay
strict; npm run typecheck, npm run lint and npm run build must be clean.

AUTH / TYPES
1. src/api/types.ts: UserDto gets roles: string[], roleIds: number[], permissions: string[]; remove the old
   role field and UserRole type; add the Role/Permission/LoginAudit DTOs and request types listed above.
2. useAuth(): add hasPermission(code: string): boolean and hasAnyPermission(...codes: string[]): boolean
   (based on user.permissions). ProtectedRoute: add an optional permission prop; when the user lacks it,
   render a Forbidden page (route /forbidden: "You don't have access to this page", link back to the dashboard)
   instead of redirecting to login.
3. Add src/components/RequirePermission.tsx: renders children only when hasPermission(code) (used for buttons).
4. API modules: src/api/users.ts (add update, setRoles), src/api/roles.ts, src/api/permissions.ts, src/api/security.ts (loginAudit).

SHELL
5. Replace Layout.tsx with an application shell in src/components/layout/: AppShell.tsx (grid: sidebar + main),
   Sidebar.tsx, Topbar.tsx, PageHeader.tsx (title + subtitle + right-side actions slot), all styled in index.css
   (or a new src/styles/shell.css imported from main.tsx) with the login page's brand colors.
   - Sidebar: brand block at the top (logo + "Katanga TVS" / "Inventory & Shipment"), navigation sections from
     src/navigation.ts, active item highlighted (NavLink), collapsible to icon-only mode (button at the bottom,
     remembered in localStorage inside try/catch), on screens < 900px it becomes an overlay drawer opened from a
     menu button in the top bar.
   - src/navigation.ts exports the menu model:
       Dashboard (/, always visible)
       Section "Security": Users (/security/users, security.users.view), Roles (/security/roles, security.roles.view),
         Permissions (/security/permissions, security.permissions.view), Login audit (/security/login-audit, security.audit.view)
       Section "Inventory" and Section "Shipments": items marked comingSoon: true (rendered disabled with a
         "Soon" tag, no route). Items/sections the user has no permission for are hidden entirely.
   - Topbar: page title (from the current route's navigation item), user menu on the right (avatar with
     initials, full name, roles as small chips, "Change password", "Sign out everywhere", "Sign out").
   - Main: content container with padding that renders <Outlet />; pages start with <PageHeader>.
6. Routes in App.tsx: /login; protected: / (DashboardPage), /account/password (the existing change-password
   form moved to its own page), /security/users (permission security.users.view), /security/roles (security.roles.view),
   /security/permissions (security.permissions.view), /security/login-audit (security.audit.view), /forbidden, * -> /.
   DashboardPage becomes a welcome page: greeting, the user's roles, and cards linking to the sections they can
   access (no change-password card any more).

SHARED COMPONENTS (src/components/ui/)
7. Modal (title, children, footer; closes on Escape/backdrop; traps focus reasonably), ConfirmDialog
   (message, confirm/cancel, danger variant), Badge, DataTable (columns config, rows, empty message,
   optional row actions), SearchInput, Toast/notification hook (useToast) for success messages - or reuse Alert
   for inline errors. Keep them small and typed.

PAGES (src/pages/security/)
8. UsersPage: PageHeader "Users" with "New user" button (RequirePermission security.users.create).
   Search box filtering by username / name / email. Table columns: Username, Full name, E-mail, Roles (chips),
   Status (Active/Deactivated badge), Last sign-in. Row actions (only with security.users.edit): Edit (modal:
   full name, e-mail), Roles (modal with a checkbox per role from GET /api/roles, save -> PUT roles),
   Activate/Deactivate (ConfirmDialog; disabled for the current user), Reset password (modal: new password +
   confirm, policy hint). "New user" modal: username, full name, e-mail, password + confirm, roles checkboxes.
   Show ApiError.messages inline in each modal; refresh the table after every successful change; toast on success.
9. RolesPage: master-detail. Left: list of roles (name, "System" badge when isSystem, "Inactive" badge,
   users count, permissions count) + "New role" button (security.roles.manage). Right: selected role - form with
   name (read-only for system roles), description, active toggle (disabled for system roles), Save (security.roles.manage);
   then the permission matrix from GET /api/permissions grouped by module: one checkbox per permission
   (checked from the role's permissionIds), "Select all" per module, Save permissions button; for a system role all
   checkboxes are checked and disabled with the note "System roles always hold every permission". Delete button
   (danger) disabled with a tooltip when the role is a system role or userCount > 0; ConfirmDialog before deleting.
10. PermissionsPage: read-only catalog grouped by module: table with Code (monospace), Name, Description, Roles
    (chips). Filter box. Intro text: "Permissions are defined by the application; assign them to roles on the Roles page."
11. LoginAuditPage: filters (username, only failed, rows 50/200/500) + Refresh; table: Time (local), Username,
    Result (Success/Failed badge), Reason, IP address, User agent (truncated with title tooltip).

VERIFY (API running; npm run dev; sign in as admin / Admin@12345)
12. Sidebar shows Dashboard and Security (Users, Roles, Permissions, Login audit); Inventory/Shipments show as "Soon".
13. Roles page: create role "Warehouse Clerk" with security.users.view only; Admin role shows every permission
    checked and disabled.
14. Users page: create user clerk1 (Clerk#2026!) with the Warehouse Clerk role; it appears with the role chip.
15. Sign in as clerk1 in a private/incognito window: sidebar shows Dashboard and Security > Users only; typing
    http://localhost:5173/security/roles in the address bar shows the Forbidden page; the Users page shows no
    New user / edit actions.
16. Back as admin: remove the role from clerk1, delete the role; login audit lists the sign-ins including the
    clerk1 ones. Everything responsive at 1366px and 390px widths (drawer works).
17. npm run typecheck, npm run lint, npm run build are clean.
18. Report: files added/changed, anything not implemented exactly as specified and why, and screenshots or a
    description of what each page looks like.
```

---

## After all four prompts

- Run `Database\04_Security_DropLegacyRoleColumn.sql` in SSMS if you prefer to do it by hand — the API also
  applies it on start-up once Prompt 3 is deployed, so it may already report "already gone".
- Change the admin password from the user menu ("Change password").
- Next modules (Inventory, Shipments) follow the same pattern: permission codes in `PermissionCatalog.cs`
  (synced to the database automatically), `[HasPermission(...)]` on the endpoints, a navigation section and
  pages gated by the same codes. Tell me what the first inventory screens should contain and I will write the
  SQL and the prompts the same way.
