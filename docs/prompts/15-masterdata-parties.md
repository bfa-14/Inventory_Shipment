# US-MD-007 — Parties — SQL + VS Code prompts

Run order: `Database\13_MasterData_Parties.sql` in SSMS (needs 12) → Prompt A → Prompt B.
One party master with four type flags; code auto-suggested from the first checked type
(SUP-/CLI-/SAL-/EMP-0001); optional links: branch, application user (one party per user),
one price list per role (client price list = list applied when the party buys; salesman price list = list the person sells with; sales resolution: client's → salesman's → company default), supplier default currency; a type cannot be removed while the party
is used in that role; delete only when unreferenced.

Errors 60xxx: 60000 `VALIDATION`, 60001 `DUPLICATE_CODE`, 60002 `USER_ALREADY_LINKED`,
60003 `REFERENCED`, 60004 `CONCURRENCY`, 60005 `TYPE_IN_USE`, 60006 `NOT_FOUND`,
60008 `MASTER_INACTIVE`. Permissions `masterdata.parties.*` (520–550).

## Prompt A — Backend

```text
You are working on D:\VSProjects\Inventory_Shipment (.NET 10 solution). Do not touch the Web project.
Copy the established Master Data pattern (Branches / Items): entity + DTOs, Dapper repository over stored
procedures (SqlErrors -> BusinessRuleException), service returning Result with codes, controller with
[HasPermission], PermissionCatalog, Schema.sql embedding. No new NuGet packages. 0 warnings.

Feature: Parties (US-MD-007) - ONE centralized party master with multi-type flags. Script already written:
D:\VSProjects\Inventory_Shipment\Database\13_MasterData_Parties.sql (read its header for the rules).
Table masterdata.Parties: Id, PartyCode NVARCHAR(20) unique, PartyName NVARCHAR(200), IsSupplier, IsClient,
IsSalesman, IsEmployee (at least one), BranchId?, ContactPerson NVARCHAR(150)?, Phone NVARCHAR(50)?, Mobile?,
Email NVARCHAR(150)?, Address NVARCHAR(500)?, Country NVARCHAR(2)?, TaxRegistrationNo NVARCHAR(50)?,
Notes NVARCHAR(1000)?, UserId? (security.Users, unique), ClientPriceListId?, SalesmanPriceListId?,
DefaultCurrencyId?, IsActive, audit, RowVersion. Joined read-only: BranchCode/Name, UserName, UserFullName,
ClientPriceListName, SalesmanPriceListName, DefaultCurrencyCode. The procs reject a client price list when
IsClient = 0 and a salesman price list when IsSalesman = 0 (60000).
Procedures: masterdata.usp_Party_Search(@Search code/name/phone/mobile/email, @PartyType Supplier|Client|
Salesman|Employee|NULL, @BranchId, @IsActive, @SortColumn PartyCode|PartyName|BranchName|Email|Phone|IsActive|
CreatedAtUtc, @SortDirection, @PageNumber, @PageSize) -> rows + TotalCount; usp_Party_Get;
usp_Party_Lookup(@PartyType, @Search, @ActiveOnly = 1, @IncludeId, @Top = 50); usp_Party_NextCode(@PartyType)
-> SuggestedCode; usp_Party_Create(... all columns ..., @ActorUserId, @NewId OUT); usp_Party_Update(@Id, ...,
@RowVersion, @ActorUserId); usp_Party_SetActive(@Id, @IsActive, @ActorUserId); usp_Party_Delete(@Id).
NOTE the actor parameter is @ActorUserId (the party has its own @UserId column = linked user).
THROW mapping: 60000 Validation; 60001 Conflict DUPLICATE_CODE; 60002 Conflict USER_ALREADY_LINKED;
60003 Conflict REFERENCED; 60004 Conflict CONCURRENCY; 60005 Conflict TYPE_IN_USE; 60006 NotFound;
60008 Validation MASTER_INACTIVE. Permissions masterdata.parties.view/create/edit/delete (Master Data, 520..550).

TASK
1. Run the script (sqlcmd -S . -E -d Inventory_Shipment -i "...\Database\13_MasterData_Parties.sql"), show
   the output, append it to Repository\Database\Schema.sql under "-- ===== 13: Master Data - Parties ====="
   (no USE batch, no final report batch).
2. Model: Entities/Party.cs; DTOs PartyDto (all fields + joined names), SavePartyRequest (PartyCode [Required,
   StringLength(20)], PartyName [Required, StringLength(200)], IsSupplier/IsClient/IsSalesman/IsEmployee
   (service validates at least one -> Validation), BranchId?, ContactPerson [StringLength(150)], Phone/Mobile
   [StringLength(50)], Email [EmailAddress, StringLength(150)], Address [StringLength(500)], Country
   [RegularExpression "^[A-Za-z]{2}$"]?, TaxRegistrationNo [StringLength(50)], Notes [StringLength(1000)],
   UserId?, ClientPriceListId?, SalesmanPriceListId?, DefaultCurrencyId?, IsActive = true, RowVersion?),
   SetPartyStatusRequest,
   PartyQuery (Search, PartyType? (enum Supplier|Client|Salesman|Employee as string), BranchId?, IsActive?,
   SortBy = PartyCode, SortDir, Page, PageSize), PartyLookupDto (id, partyCode, partyName, the 4 flags,
   branchId, clientPriceListId, salesmanPriceListId, defaultCurrencyId, userId, isActive), NextCodeDto;
   PermissionCatalog entries.
3. Repository IPartyRepository / PartyRepository; Service IPartyService / PartyService (+ mapper); register.
4. API PartiesController route api/masterdata/parties:
     GET ?query [view]; GET {id} [view]; GET lookup?partyType=&search=&activeOnly=&includeId=&top= [Authorize];
     GET next-code?partyType= [Authorize]; POST [create]; PUT {id} [edit]; PUT {id}/status [edit]; DELETE {id} [delete].
   Also expose GET api/security/users/lookup?search= [Authorize] (id, username, fullName, isActive) if no
   such endpoint exists yet - the Parties modal needs it for the "Linked user" dropdown.
5. Build 0 warnings; API starts with "Database schema verified".

VERIFY with curl (token admin / Admin@12345), show output: list shows seeded SUP-0001 TVS Motor Company
(isSupplier true, defaultCurrencyCode INR); next-code?partyType=Client -> "CLI-0001"; POST a client+supplier
"ABC Trading" with email "bad email" -> 400 validation; with a valid email -> 201; no types -> 400; same code
-> 409 DUPLICATE_CODE; link userId of admin -> 200, link the same user on another party -> 409
USER_ALREADY_LINKED; lookup?partyType=Supplier lists both, ?partyType=Salesman lists none; PUT removing the
Supplier type on ABC -> 200 (nothing references it yet); DELETE ABC -> 204. Report files changed + results.
```

## Prompt B — Frontend

```text
You are working on D:\VSProjects\Inventory_Shipment.Web (Mantine 9 stack, docs/frontend-conventions.md,
shared ui components, auto-apply filters - no Filter button, responsive at 390/768/1024/1440). Frontend only.
Backend exists: api/masterdata/parties (search/get/lookup/next-code/create/update/status/delete) and lookups:
api/masterdata/branches/lookup, price-lists/lookup, currencies/lookup, api/security/users/lookup?search=.
Error codes: DUPLICATE_CODE, USER_ALREADY_LINKED, REFERENCED, CONCURRENCY, TYPE_IN_USE, NOT_FOUND,
MASTER_INACTIVE. Dev: npm run dev, admin / Admin@12345.

TASK: Parties page (US-MD-007).
1. src/api/masterdata/parties.ts (typed, reuse request<T>).
2. Navigation: Master Data -> "Parties" after Brands (masterdata.parties.view); breadcrumb
   "Setup › Master Data › Parties"; subtitle "View and manage suppliers, clients, salesmen and employees."
3. List: FilterBar (search "Search by party code, name, phone or email..." debounced, Party Type
   All/Supplier/Client/Salesman/Employee, Branch (lookup), Status, Clear Filters); DataTable server-side:
   #, Party Code (bold), Party Name, Party Type (one small Badge per flag: Supplier blue, Client green,
   Salesman orange, Employee violet), Phone, Email, Branch (or -), Status, RowActions View (IconEye) / Edit /
   Activate-Deactivate / Delete. "+ New Party" (create permission). Hide Phone/Branch columns <= 768 px.
4. Modal (FormModal size xl, two columns >= 768 px, one column below), title "New Party" / "Edit Party" /
   "Party details" (VIEW = same modal, every control read-only, only a Close button):
   - Party Code* (auto-suggested from GET next-code?partyType=<first checked type> when creating and the user
     has not typed a code; re-suggest when the first checked type changes; editable), Party Name*.
   - Party Type* as Checkbox.Group with the four types in one row (wraps on mobile); inline error "Select at
     least one party type" if none.
   - Branch (Select, active branches, clearable), Contact Person, Phone, Mobile, Email (validated on blur),
     Address (Textarea autosize), Country (searchable Select from src/data/countries.ts, clearable),
     Tax / Registration No., Notes (Textarea).
   - CONDITIONAL fields (shown only when the related type is checked, cleared when unchecked):
     Client price list (Client) - Select from active price lists showing "Name (USD)", helper "Applied when
     this party buys"; Salesman price list (Salesman) - same Select, helper "Used when this person sells;
     a client's own list takes precedence"; Default Currency (Supplier) - Select from active currencies;
     Linked user (Salesman or Employee) - searchable Select from users lookup showing "Full name (username)",
     clearable, helper "Lets the system recognise this person when they sign in".
   - Active switch "Yes, this party is active" (default on). Buttons Cancel / Save Party.
   - Errors: DUPLICATE_CODE under Code; USER_ALREADY_LINKED under Linked user; TYPE_IN_USE under Party Type
     with the API message; MASTER_INACTIVE notify; CONCURRENCY notify + refresh; API validation via
     form.setErrors. Toasts "Party created successfully." / updated / deleted.
   - Delete: confirm danger; REFERENCED -> dialog "This party cannot be deleted because it is referenced by
     existing transactions. You may deactivate the party instead." with "Deactivate instead".
5. Quality: typecheck / lint / build clean; all breakpoints; permission gating (view-only user: View only).

VERIFY (API running), screenshots 1440 + 390: seeded TVS Motor Company shown with the Supplier badge and
INR default currency in View; create "ABC Trading" as Supplier + Client -> code suggested CLI-/SUP- per the
first checked type, both badges shown; conditional fields appear/disappear with the checkboxes; create a
Salesman linked to a user; linking the same user again shows the error under the field; invalid email
blocked; filters (type/branch/status) auto-apply; View opens read-only; delete ABC works; view-only user sees
only View. Report files changed + results.
```
