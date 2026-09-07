# Frontend enhancements batch 1 — menu search, modal autofocus, selected-row colour

```text
You are working on D:\VSProjects\Inventory_Shipment.Web (Mantine 9 stack, docs/frontend-conventions.md,
shared components in src/components/ui). Frontend only. Apply these four enhancements as CONVENTIONS (shared
components), not page-by-page hacks, and document each in docs/frontend-conventions.md.

1. MENU SEARCH
   - Add a search box at the top of the sidebar (below the logo, TextInput with IconSearch, placeholder
     "Search menu...", Esc clears). Typing filters the menu items from src/navigation.ts live: sections/groups
     that contain a match expand automatically, non-matching items are hidden, the matched text is bold.
     Enter opens the first visible item. Respects permissions (hidden items never appear). In the collapsed
     (icon-only) sidebar, clicking the search icon expands the sidebar and focuses the box.
   - Make the header "Search anything..." box real: install @mantine/spotlight (same 9.5.x version as the other
     @mantine packages, import its styles.css in main.tsx) and open a Spotlight (also on Ctrl+K / Cmd+K)
     listing every page the user may access (label, section path as description, icon) - selecting navigates.
     Same data source as the sidebar (navigation.ts), same permission filtering.

2. AUTOFOCUS ON THE FIRST FIELD (all modals, explicitly required on Users and Roles)
   - In FormModal, focus the first focusable input automatically when the modal opens (Mantine: put
     data-autofocus on the first input, or use a ref + useEffect on `opened`), for create AND edit.
   - New user modal -> Username (or the first field) focused; New role modal -> Name focused.
   - When the modal closes, return focus to the button that opened it. Enter in the last field submits.

3. SELECTED-ROW COLOUR (all grids)
   - In the shared DataTable wrapper track a selectedId; clicking a row (or any of its action icons) selects
     it; the selected row gets the brand light background (#EEF3FF) with a 3 px brand-blue left border, on top
     of the hover style; selection persists across refreshes of the same list while the row still exists, and
     clears when filters change page. Optional: ArrowUp/ArrowDown move the selection, Enter triggers the
     row's primary action (View/Edit) when the grid has focus.
   - Apply automatically to every page using the wrapper (Users, Roles, Branches, Warehouses, Currencies,
     Exchange Rates, Item Families tree, Brands, Unit Types, Items, Price Lists, Parties...).

4. Quality: npm run typecheck, lint, build clean; verify at 1440 and 390 px.

VERIFY and report: menu search filters and expands correctly, Ctrl+K opens Spotlight and navigates, a user
without a permission never sees that page in either search; opening New User / New Role puts the cursor in the
first field immediately (also in Edit); clicking a row on Items and on Users colours it and the colour stays
after the toast refresh; typecheck/lint/build clean.
```
