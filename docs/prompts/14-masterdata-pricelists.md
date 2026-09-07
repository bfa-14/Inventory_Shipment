# US-MD-005 — Price Lists — VS Code prompts

Database: already created by `Database\12_MasterData_PriceLists.sql` (table `masterdata.PriceLists` +
`usp_PriceList_Search / _Get / _Lookup / _Create / _Update / _SetActive / _Delete`). Run 12 in SSMS if
not done yet, then Prompt A → Prompt B.

Errors 58xxx: 58000 `VALIDATION`, 58001 `DUPLICATE_CODE` (code or name), 58003 `REFERENCED`,
58004 `CONCURRENCY`, 58006 `NOT_FOUND`, 58008 `CURRENCY_INACTIVE`, 58009 `CURRENCY_LOCKED`
(currency cannot change once the list has prices). Permissions `masterdata.pricelists.*` (440–470).
Menu: **Inventory → Price Lists** (after Item Definition), as in the customer figure.

## Prompt A — Backend

```text
You are working on D:\VSProjects\Inventory_Shipment (.NET 10 solution). Do not touch the Web project.
Feature: Price Lists (US-MD-005) - flat master data, copy the BRANDS implementation (entity, DTOs, Dapper
repository over stored procedures, service with Result codes, controller with [HasPermission],
PermissionCatalog, Schema.sql embedding). Fields: PriceListCode (NVARCHAR(20), unique), PriceListName
(NVARCHAR(100), unique), CurrencyId (FK masterdata.Currencies, required), Description (NVARCHAR(500),
optional), IsActive. Read-only extras returned by the procs: CurrencyCode, CurrencyName, DecimalPlaces,
PriceCount.

Database is already written in D:\VSProjects\Inventory_Shipment\Database\12_MasterData_PriceLists.sql
(read its header; it also contains the Unit Price objects - IGNORE those for this task, they come next).
Procedures: masterdata.usp_PriceList_Search(@Search, @CurrencyId, @IsActive, @SortColumn PriceListCode|
PriceListName|CurrencyCode|IsActive|CreatedAtUtc, @SortDirection, @PageNumber, @PageSize) -> rows + TotalCount;
usp_PriceList_Get; usp_PriceList_Lookup(@ActiveOnly = 1, @IncludeId) -> Id, PriceListCode, PriceListName,
CurrencyId, CurrencyCode, Symbol, DecimalPlaces, IsActive; usp_PriceList_Create(@PriceListCode,
@PriceListName, @CurrencyId, @Description, @IsActive, @UserId, @NewId OUT); usp_PriceList_Update(@Id, ...,
@RowVersion, @UserId); usp_PriceList_SetActive; usp_PriceList_Delete.
THROW mapping: 58000 Validation VALIDATION; 58001 Conflict DUPLICATE_CODE; 58003 Conflict REFERENCED;
58004 Conflict CONCURRENCY; 58006 NotFound; 58008 Validation CURRENCY_INACTIVE; 58009 Validation
CURRENCY_LOCKED. Permissions masterdata.pricelists.view/create/edit/delete, module "Master Data", sort 440..470.

TASK
1. Run the script if the objects do not exist yet (sqlcmd -S . -E -d Inventory_Shipment -i
   "...\Database\12_MasterData_PriceLists.sql"), show the output, and append the WHOLE script to
   Repository\Database\Schema.sql under "-- ===== 12: Price Lists + Unit Prices =====" (no USE batch, no
   final report batch) - the unit-price objects are harmless there and will be used by the next story.
2. Model: Entities/PriceList.cs; DTOs PriceListDto (id, priceListCode, priceListName, currencyId, currencyCode,
   currencyName, decimalPlaces, description, isActive, priceCount, createdAtUtc, updatedAtUtc, rowVersion),
   SavePriceListRequest (PriceListCode [Required, StringLength(20)], PriceListName [Required,
   StringLength(100)], CurrencyId [Required, Range(1, int.Max)], Description [StringLength(500)],
   bool IsActive = true, string? RowVersion), SetPriceListStatusRequest, PriceListQuery (Search, CurrencyId?,
   IsActive?, SortBy = PriceListCode, SortDir, Page, PageSize), PriceListLookupDto; PermissionCatalog entries.
3. Repository IPriceListRepository / PriceListRepository; Service IPriceListService / PriceListService (+ mapper);
   register both.
4. API PriceListsController route api/masterdata/price-lists: GET ?query [view], GET {id} [view],
   GET lookup?activeOnly=&includeId= [Authorize only], POST [create], PUT {id} [edit], PUT {id}/status [edit],
   DELETE {id} [delete].
5. Build 0 warnings; API starts with "Database schema verified".

VERIFY with curl (token from /api/auth/login admin / Admin@12345), show output: list shows seeded PL-001
Retail USD with currencyCode USD and priceCount (1 if the demo price exists); create "WHO-USD Wholesale USD"
(currency USD) -> 201; same code -> 409 DUPLICATE_CODE; inactive currency id -> 400 CURRENCY_INACTIVE;
change PL-001's currency to EUR -> 400 CURRENCY_LOCKED when it has prices (else 200 - then set it back);
DELETE PL-001 -> 409 REFERENCED when it has prices; DELETE WHO-USD -> 204; lookup returns active lists.
Report files changed + results.
```

## Prompt B — Frontend

```text
You are working on D:\VSProjects\Inventory_Shipment.Web (Mantine 9 stack, docs/frontend-conventions.md,
shared ui components, auto-apply filters - no Filter button). Frontend only. Backend exists:
api/masterdata/price-lists (search/get/lookup/create/update/status/delete) and api/masterdata/currencies/lookup.
Error codes: DUPLICATE_CODE, REFERENCED, CONCURRENCY, NOT_FOUND, CURRENCY_INACTIVE, CURRENCY_LOCKED.
Dev: npm run dev, admin / Admin@12345.

TASK: Price Lists page (US-MD-005) - a copy of the Brands page plus a Currency dropdown.
1. src/api/masterdata/priceLists.ts (typed, reuse request<T>).
2. Navigation: section Inventory -> "Price Lists" right after "Item Definition" (masterdata.pricelists.view),
   breadcrumb "Setup › Inventory › Price Lists" (matches the customer figure).
3. Page: PageHeader ("Price Lists", "View and manage price lists.", "+ New Price List"); FilterBar
   (search code/name debounced, Currency Select from the currencies lookup showing "USD - US Dollar",
   Status All/Active/Inactive, Clear Filters); DataTable server-side: #, Price List Code (bold), Price List
   Name, Currency ("USD - US Dollar"), Prices (priceCount, dimmed), Status, RowActions edit / activate-
   deactivate / delete.
4. Modal "New Price List" / "Edit Price List" (@mantine/form): Price List Code* (max 20), Price List Name*
   (max 100), Currency* (searchable Select, active currencies, base first; when editing a list that already
   has prices show it disabled with the hint "Currency is locked because this list contains prices"),
   Description (Textarea 0/500), Active switch (default on, label "Yes, this price list is active"),
   buttons Cancel / Save Price List. Errors: DUPLICATE_CODE -> under Code (or Name if the message says name);
   CURRENCY_LOCKED / CURRENCY_INACTIVE -> under Currency; REFERENCED on delete -> dialog "This price list
   cannot be deleted because it contains prices or is referenced. You may deactivate it instead." with a
   "Deactivate instead" action; CONCURRENCY -> notify + refresh. Success toasts "Price list created
   successfully." / updated / deleted.
5. typecheck / lint / build clean; responsive at 390 px; permission gating (view-only user: no actions).

VERIFY (API running), screenshots 1440 + 390: seeded Retail USD shown with its price count; create
"WHO-USD Wholesale USD"; duplicate code shows under the field; currency filter + status filter auto-apply;
editing Retail USD shows the locked currency hint (if it has prices); delete WHO-USD works; delete Retail USD
shows the deactivate-instead dialog; view-only user sees no action buttons. Report files changed + results.
```
