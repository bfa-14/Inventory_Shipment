# Grids: remove the Filter button — filters apply automatically on change

Frontend-only convention change: no more "Filter" button in any list page; filters apply as the user edits them
(debounced for typing, immediate for dropdowns/toggles). "Clear Filters" stays.

```text
You are working on D:\VSProjects\Inventory_Shipment.Web (React 19 + Vite 8 + TypeScript, Mantine 9 +
mantine-datatable, shared components in src/components/ui, conventions in docs/frontend-conventions.md).
Frontend only - do not change D:\VSProjects\Inventory_Shipment. Dev: npm run dev, sign in admin / Admin@12345.

CHANGE REQUEST: in every grid/list page (Branches / Sites, Warehouses, Users, Login audit, and any other page
with a FilterBar - and as the rule for all future pages), REMOVE the "Filter" button. Filters must apply
automatically whenever a filter value changes ("filter on edit"):

1. Behaviour
   - Text inputs (search boxes): debounce 350 ms after the last keystroke, and apply immediately on Enter or on
     clearing the input (X). While a debounce is pending and a fetch runs, show it only through the table's
     fetching state - no layout jumps.
   - Selects, segmented controls, switches, checkboxes, date pickers used as filters: apply immediately on change.
   - Any filter change resets the page to 1 (keep the page size); sorting behaviour unchanged.
   - "Clear Filters" stays: resets every filter to its default AND applies immediately; disable it when all
     filters are already at their defaults.
   - Stale responses must never win: guard server-side fetches with an AbortController (abort the in-flight
     request when a new one starts) or a monotonically increasing request id checked before setState - typing
     "wh" then quickly "wh-0" must always end with the "wh-0" results, never flicker back.
   - Avoid double fetches (e.g. debounce firing + Enter, or clear + debounce): coalesce so exactly one request
     lands per settled filter state.
2. Implementation
   - Prefer one shared hook (e.g. src/hooks/useGridQuery.ts or an extension of the existing list-page hook):
     holds the filter state, debounces text fields, exposes { filters, setFilter, clearFilters, page, setPage,
     sortStatus, ... } and triggers the fetch; all grid pages use it so the behaviour is identical everywhere.
   - Update FilterBar usage on every page: remove the Filter button and any onSubmit/apply plumbing; keep the
     layout tidy (search grows, dropdowns fixed width, Clear Filters at the end as it is now).
   - Client-side lists that already filter instantly (e.g. the Roles table, the Role Permissions filter box)
     just need the button removed if they have one - behaviour already matches.
   - Update docs/frontend-conventions.md: FilterBar section now says "no Apply/Filter button; auto-apply on
     change, 350 ms debounce for text, immediate for everything else, Clear Filters resets + applies, page
     resets to 1" and points to the shared hook.
3. Quality: npm run typecheck, npm run lint, npm run build all clean; no leftover onApply props or dead code.

VERIFY (API running) and report each:
  a. No "Filter" button remains anywhere (search the codebase for the button label to prove it).
  b. Warehouses: typing in search updates the grid ~0.35 s after the last keystroke; picking a Branch in the
     dropdown updates immediately; setting Status to Inactive updates immediately; page resets to 1 each time.
  c. Type fast ("wh" then "wh-0" without pausing): exactly the final result shows, and the Network tab shows the
     earlier request aborted or its response ignored - no flicker of wrong rows.
  d. Clear Filters restores defaults and refreshes at once; it is disabled when nothing is filtered.
  e. Users and Login audit behave the same; Branches too.
  f. Paging and sorting still work with active filters; sorting does not reset filters.
Report: files changed, the shared hook's API, and every verification result.
```
