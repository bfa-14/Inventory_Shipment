# Frontend — migrate to Mantine and continue with it

UI library decision: **Mantine v9** (`@mantine/core` 9.5.x) with **mantine-datatable** for grids,
`@mantine/form` for forms, `@mantine/notifications` for toasts, `@mantine/modals` for confirmations,
`@mantine/dates` for date pickers, `@tabler/icons-react` for icons. From this point every page is built with
these; the Branches (04) and Warehouses (05) frontend prompts are implemented with Mantine controls.

```text
You are working on D:\VSProjects\Inventory_Shipment.Web (React 19 + Vite 8 + TypeScript strict, react-router v7
package "react-router", currently plain CSS with hand-made components). You may read the API project at
D:\VSProjects\Inventory_Shipment for reference but must not change it. Dev API through the Vite proxy (/api),
sign in admin / Admin@12345. The machine has internet access for npm.

GOAL: adopt Mantine as the UI library for the whole application, rebuild the shell, the shared components and
every existing page on it, and leave conventions so all future pages use it. Behaviour must not change: same
routes, same API calls, same permission gating, same messages. The LOGIN PAGE IS THE EXCEPTION: it is a
customer-approved design (src/pages/LoginPage.tsx + its CSS + the images in src/assets) - keep it exactly as it
is, only make sure it still renders identically inside MantineProvider (scope its CSS if Mantine's global styles
change anything about it).

Reference design (customer figures already used for the Branches page): white 240 px sidebar with the company
logo (src/assets/katanga-logo.png), menu with sections and expandable groups, "BACKOFFICE" section label,
active item light-blue background #EEF3FF with blue text #2563EB, "Collapse Menu" at the bottom; white top bar
with breadcrumb + page title on the left and a global search box, a bell with a red badge and a user chip
(avatar, name, role, dropdown) on the right; content background #F5F7FB; white cards radius 12 px; primary
buttons blue #2563EB; status pills (Active green #DCFCE7/#15803D, Inactive grey #E5E7EB/#374151); footer line
"© 2026 Katanga TVS Motor Company. All rights reserved." / "Powered by MAY solutions" / "Inspired by Mr. Issa
Awada". Fonts "Segoe UI", Inter, system-ui.

TASK

1. Install and configure
   npm install @mantine/core @mantine/hooks @mantine/form @mantine/notifications @mantine/modals @mantine/dates dayjs mantine-datatable @tabler/icons-react
   npm install --save-dev postcss postcss-preset-mantine postcss-simple-vars
   - postcss.config.cjs at the project root with postcss-preset-mantine and postcss-simple-vars (the standard
     mantine-breakpoint-xs..xl variables: 36em, 48em, 62em, 75em, 88em).
   - src/main.tsx imports, in this order: '@mantine/core/styles.css', '@mantine/notifications/styles.css',
     '@mantine/dates/styles.css', 'mantine-datatable/styles.layer.css', then the app's own CSS.
   - index.html: add <ColorSchemeScript /> equivalent via the React entry if needed; the app is light-only
     (MantineProvider defaultColorScheme="light", forceColorScheme="light").
   - src/theme.ts: createTheme with a custom "brand" color (10 shades built around #2563EB, e.g.
     ['#EEF3FF','#DCE6FF','#B9CCFF','#93AEFF','#6E8FFF','#4F74F5','#2563EB','#1D4FD0','#1741AD','#12358C']),
     primaryColor 'brand', primaryShade 6, defaultRadius 'md', fontFamily '"Segoe UI", Inter, system-ui, sans-serif',
     headings { fontWeight: '700' }, and component defaults: Button (radius md), TextInput/Textarea/Select/
     NumberInput (radius md), Paper (radius lg), Modal (radius lg, overlay blur 2, centered), Badge (radius xl),
     Table (highlightOnHover). Export the theme and wrap the app: MantineProvider > Notifications (position
     top-right) > ModalsProvider > the router.
   - Remove the old global component CSS that Mantine now covers; keep only layout/brand CSS and the login page CSS.

2. Shared building blocks (src/components/ui/ - replace the hand-made ones, keep the same export names where
   pages import them so the change is mechanical):
   - notify.success(message) / notify.error(message) / notify.info(message) using @mantine/notifications
     (green check icon for success, red for error, auto-close 4 s).
   - confirm({ title, message, confirmLabel, cancelLabel, danger }) : Promise<boolean> using
     modals.openConfirmModal from @mantine/modals (danger => red confirm button).
   - DataTable: a wrapper around mantine-datatable configured for server-side data: records, columns
     (accessor, title, sortable, width, render), totalRecords, page, recordsPerPage, recordsPerPageOptions
     [10, 25, 50] (from src/config.ts), onPageChange, onRecordsPerPageChange, sortStatus/onSortStatusChange,
     fetching (loading), minHeight, noRecordsText, striped false, highlightOnHover, withTableBorder false,
     paginationText "Showing {from} to {to} of {totalRecords} entries", rowNumber column helper ("#").
   - StatusBadge({ active }) -> Badge variant "light" color green/gray with "Active"/"Inactive".
   - PageHeader({ title, subtitle, breadcrumbs, actions }) -> Group/Stack with Title order 2, Text c dimmed,
     Breadcrumbs, and the right-hand actions slot.
   - FilterBar: Paper (radius lg, p md, withBorder) with a responsive Grid for the filter controls.
   - RowActions: Group of ActionIcon (variant subtle) with Tooltip: edit (IconPencil, blue), activate/deactivate
     (IconPower, gray/green), delete (IconTrash, red); each accepts disabled + disabledReason.
   - MoreActionsMenu: Button variant default with IconDotsVertical + Menu items.
   - FormModal: Modal with title, size 'lg', trapFocus, closeOnClickOutside false while saving, footer Group with
     Cancel (variant default) and Save (primary, loading).
   Delete the old implementations once nothing references them.

3. Application shell on Mantine AppShell: navbar width 240 (collapsed 72 - icon only, remembered in localStorage
   inside try/catch), header height 64, padding md, navbar collapsed on mobile with a Burger in the header
   (breakpoint sm). Sidebar: logo block, ScrollArea with NavLink components built from src/navigation.ts (sections
   as labels, groups with nested NavLinks, active state from the router, comingSoon items disabled with a small
   "Soon" Badge, items hidden when the user lacks the permission, group containing the active route opened on
   load), "Collapse Menu" NavLink at the bottom. Header: Breadcrumbs + title text (from the navigation model),
   TextInput with IconSearch placeholder "Search anything..." (visual only), Indicator+ActionIcon bell (0 for
   now), Menu on the user chip (Avatar initials + name + roles) with Change password / Sign out everywhere /
   Sign out. Footer text as in the reference. Content area background #F5F7FB.

4. Rebuild the existing pages on Mantine, same behaviour and API calls:
   - Dashboard (welcome, cards linking to allowed sections; Mantine Card/SimpleGrid).
   - Security > Users, Roles, Permissions, Login audit: tables via DataTable, forms via @mantine/form
     (TextInput, PasswordInput with policy hint, Checkbox.Group for roles / permissions matrix in Roles,
     Switch for status), confirmations via confirm(), toasts via notify. Keep every existing action and
     permission check (RequirePermission / hasPermission).
   - Account > Change password (PasswordInput x3, @mantine/form validation).
   - Forbidden page (Center + Title + Button link).
   - If src/pages/masterdata/BranchesPage.tsx / WarehousesPage.tsx already exist: rebuild them on Mantine with
     the identical behaviour described in docs/prompts/04-masterdata-branches.md and 05-masterdata-warehouses.md
     (Prompt B of each): filters applied on Filter/Enter, Clear Filters, server-side sort + paging, New/Edit modal
     (TextInput, Textarea autosize minRows 3, searchable Select for Branch / Site with "(inactive)" suffix,
     Checkbox "Yes, this is the main …", Switch "Active"), the "replace main" confirmation on
     MAIN_BRANCH_EXISTS / MAIN_WAREHOUSE_EXISTS, DUPLICATE_CODE under the code field, REFERENCED error with
     "Deactivate instead", concurrency reload, permission-gated buttons. If they do not exist yet, build them now
     from those two prompts using the Mantine components (skip their own "shared components" instructions - the
     ones in step 2 replace them).
   Control mapping for all forms from now on: text -> TextInput, multiline -> Textarea, dropdown -> Select
   (searchable, clearable when optional, nothing-found text), yes/no -> Switch (status) or Checkbox (flags),
   numbers -> NumberInput, dates -> DateInput/DatePickerInput, required fields marked with withAsterisk,
   validation messages from @mantine/form + API field errors via form.setErrors.

5. Documentation: create D:\VSProjects\Inventory_Shipment.Web\docs\frontend-conventions.md describing the stack
   (Mantine + mantine-datatable + @mantine/form + notifications + modals + tabler icons), the theme tokens, the
   shared components with their props, the control mapping above, the page skeleton (PageHeader + FilterBar +
   DataTable + FormModal), the error-code handling pattern (ApiError.code -> field error / confirm dialog /
   notify), and the checklist every new page must pass. Future prompts will reference this file.

6. Quality: npm run typecheck, npm run lint, npm run build all clean; no leftover imports of deleted components;
   no unused CSS files; bundle builds; no TODOs; no behaviour regressions.

VERIFY (API running, npm run dev)
  a. Login page pixel-identical to before (compare with design/login-reference.png).
  b. After sign-in: Mantine shell matches the reference (white sidebar, breadcrumb, header controls, footer),
     collapse/expand works and is remembered, mobile drawer at 390 px.
  c. Security pages: list/create/edit/roles/permissions/status/reset/login audit all work with toasts and
     confirmation dialogs; a user without a permission does not see the item and gets the Forbidden page.
  d. Branches and Warehouses pages (if present): the full verification lists of prompts 04 and 05 pass.
  e. Screenshots at 1440 px and 390 px of: dashboard, Users, Roles, Branches, the Branch modal, a confirm dialog,
     a toast.
Report: packages added, files added/changed/deleted, the conventions file, screenshots, and every verification
result.
```
