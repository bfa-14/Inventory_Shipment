# Split the Roles page: role definition vs. permission assignment

Frontend-only change: the current Roles page (role list + edit form + permissions checklist on one screen)
becomes two pages under Users & Permissions — **Roles** (define roles) and **Role Permissions** (assign
permissions to a role). The API already has everything needed (roles CRUD + set-permissions endpoint).

```text
You are working on D:\VSProjects\Inventory_Shipment.Web (React 19 + Vite 8 + TypeScript, Mantine 9 +
mantine-datatable + @mantine/form + @mantine/modals + @mantine/notifications + @tabler/icons-react - follow
docs/frontend-conventions.md and the shared components in src/components/ui). You may read
D:\VSProjects\Inventory_Shipment (the API) for reference but do not change it - this task is frontend only.
Dev: npm run dev, sign in admin / Admin@12345.

CURRENT STATE: the Roles page shows everything at once: the "All roles" list, the selected role's Name /
Description / Active / Save / Delete form, and the permissions checklist grouped by module. The customer wants
this DIVIDED INTO 2 PAGES: one for the ROLE DEFINITION, one for ASSIGNING PERMISSIONS to a role. Reuse the
existing role/permission API modules (src/api/roles.ts, permissions.ts) - only reorganize the UI. Keep every
permission check that guards the current page (view vs manage) exactly as it is; do not invent new permission
codes.

TASK

1. Navigation and routes (src/navigation.ts + the router):
   Users & Permissions -> Users, Roles, Role Permissions, Permissions, Login audit (in that order).
   - Roles keeps its current route.
   - Role Permissions: a sibling route following the existing pattern (e.g. .../role-permissions), breadcrumb
     "Setup › Users & Permissions › Role Permissions", guarded by the same permission that currently guards
     viewing roles; the save action guarded by the same permission that currently guards editing them.
   - Old links/redirects must not break; if the old page had internal anchors/state, drop them cleanly.

2. Page 1 - Roles (definition only):
   - Page skeleton per conventions: PageHeader ("Roles", subtitle "A role is a named bundle of permissions.
     Assign roles to users on the Users page; assign permissions on the Role Permissions page.", action button
     "+ New role") + a DataTable of all roles (client-side is fine - the list is small): columns # , Role name
     (with a small "System" badge when IsSystem), Description, Users (count), Permissions (count), Status
     (StatusBadge Active/Inactive where applicable), actions.
   - Row actions: Edit (opens the modal), Assign permissions (IconShieldCheck - navigates to Role Permissions
     with this role preselected), Delete (danger confirm; disabled with a tooltip for system roles and roles
     with users, mirroring the current rules and API errors).
   - New/Edit via FormModal + @mantine/form: Name (required), Description (Textarea), Active (Switch) - only the
     fields the current form has; system roles keep their current restrictions (name/active locked as today).
   - After create: toast + refresh; offer a quick link in the success toast or modal footer "Assign permissions"
     -> Role Permissions page with the new role selected.

3. Page 2 - Role Permissions (assignment only):
   - Layout: left card "Roles" - a compact selectable list (name + "x users · y permissions", System badge),
     preselect from the route/query param when navigated from the Roles page, else the first role; right card
     "Permissions of <role>".
   - Right card content:
     - a small summary row: total selected / total, and a TextInput filter that filters permissions by name/code;
     - permissions grouped by Module (as today: Security, Master Data, ...), each group with a group checkbox
       (checked / indeterminate / unchecked) that toggles the whole module, and under it the permission rows:
       Checkbox + name + code (code styled as it is today) + description;
     - system role selected -> the blue info banner "System roles always hold every permission.", all checkboxes
       checked and disabled, Save hidden;
     - footer: Save (primary, loading state) and Reset (revert to the last loaded state), both disabled while
       nothing changed; Save calls the existing set-permissions API, then toast + reload the role list counts.
   - Unsaved changes guard: switching to another role (or leaving the page) with unsaved changes asks for
     confirmation via confirm() ("Discard the permission changes for <role>?").
   - A user with view-only permission sees everything read-only (checkboxes disabled, no Save).

4. Cleanup: remove the permissions panel and its code from the Roles page; delete now-unused components/hooks;
   update docs/frontend-conventions.md if a new reusable piece (e.g. the grouped permission checklist) was
   extracted into src/components.

5. Quality: npm run typecheck, npm run lint, npm run build all clean; no leftover imports; responsive - the two
   cards stack on small screens (390 px), the DataTable scrolls horizontally if needed.

VERIFY (API running, admin / Admin@12345) and report each:
  a. Roles page: table with counts; create "Warehouse Clerk" -> appears with 0 users / 0 permissions; edit its
     description; delete blocked/allowed exactly as before (system role delete disabled with tooltip).
  b. Role Permissions: preselected role when coming from the row action; check 2 Master Data permissions on
     "Warehouse Clerk", Save -> toast, counts update on the Roles page; Reset reverts; module checkbox toggles
     the whole group and shows indeterminate for partial selection; filter narrows the list.
  c. Admin (system) role: banner shown, all checked and disabled, no Save.
  d. Unsaved-changes confirm appears when switching roles after a change; choosing Cancel keeps the edits.
  e. Sign in as a user with view-only role permission: both pages visible read-only, no Save/New/Delete.
  f. Screenshots at 1440 px and 390 px of both pages.
Report: routes added, files added/changed/deleted, and every verification result.
```
