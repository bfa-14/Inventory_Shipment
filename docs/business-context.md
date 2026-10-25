# Inventory & Shipment: business handoff (Katanga TVS Motor Company)

*Written on 7 October 2026 by the Claude session that has been writing the prompts with Bilal, for the Claude Code
session that takes over. It covers everything I know about the business and how we work. It comes from our
conversations, the prompt files 32–46, scripts 27–29 and the Containers User Guide.*

*Updated on 11 October 2026 for **goods receipts** (scripts 64 and 65): goods now enter the stock only through a goods
receipt, and a supplier invoice no longer moves stock (glossary, 3.3–3.10, 4.12).*

*Updated on 12 October 2026 for the merge with Ali's GitLab work (scripts 68–72): the new Dashboard, lines in a
warehouse at the bottom of the tree of any branch, goods receipts included (1.4, 3.1, 4.9, 4.12, 5.4).*

*Updated on 17 October 2026 for **purchase order statuses** (script 77): an approved order shows Saved, Partially
posted or Posted from its posted invoices, and Closed is gone (glossary, 3.4, 3.9, 3.10, 4.2, 4.12).*

*Updated on 17 October 2026 for **any number of containers** (script 78): Auto-plan, the invoices and the lists take
any number of containers (no 200 ceiling), and Auto-plan / Add Container fill in the supplier and the forwarder by
themselves (glossary, 4.1, 4.5, 4.6).*

*Updated on 17 October 2026 for **what a document type does** (script 79): in Configuration › Document Types a
purchase invoice may change item costs or not, may receive its goods when it is posted, and goods receipts may be
drafted on a Delivery or made by hand (glossary, 3.7, 4.7, 4.12, 5.4).*

*Updated on 17 October 2026 for **shipping from the container** (script 80, shipment phase 1): every container shows
its next step in one button - "Start shipment…", "Start Inland transport…", "Arrived at Dar es Salaam…", "Next leg…" -
on its page and in its row's "…" menu; a leg leaves from where the container is (From locked); the Movements list
starts and completes movements on the row; a start or arrival date in the future is refused (glossary, 3.5, 4.6, 5.4).*

*Updated on 18 October 2026 for **Next step everywhere** (script 81, shipment phase 2): the container's button opens
one dialog for every step, already filled in with the usual next leg from where it is ("Inland transport to
Kasumbalesa…", "Cleared customs at Kasumbalesa…", "Then start Customs clearance on the same day"); "Next step…" in the
selection bar moves 300 containers at once, grouped by step; the Containers list has a Next step column and filter (the
logistics to-do list); only the last leg of a container can be cancelled (glossary, 3.5, 4.6, 5.4).*

*Updated on 18 October 2026 for **the Shipments board and a movement that arrives in parts** (script 82, shipment
phase 3): Logistics › Shipments puts every container on its way in one column by stage (At supplier, At sea, At port, On
the road, At border / customs, Delivered, to receive; the received ones of 30 days on a switch), grouped by ship, leg or
place, each card with its next step, a whole ship or column ticked at once into the Containers list's selection bar, a
List view for hundreds, one column at a time on a phone; a movement in progress can be completed for only some of its
containers ("Which containers?", "Only the 20 ticked", "Only some containers arrived"), which get their own movement with
the same start - cancelling that movement undoes the split, its containers back on the movement they came from; the
order's and the invoice's Containers cards got a row "…" menu with the next step; the container page's estimated cost
follows the cost rule and the matching of the goods receipt (glossary, 3.1, 3.5, 3.8, 4.6, 4.7, 5.4).*

*Updated on 19 October 2026: the prompt statuses were checked against the code - prompts 35, 38, 39, 42, 44, 45
and 46 are built (4.2, 4.3, 4.5, 4.6, 4.10, 5.1, 5.2, 6.1, 6.4); an environment is deployed only when someone
presses the **Deploy to server** button, on GitHub, in VS Code or in Visual Studio - a push deploys nothing (8.2;
`deploy/README.md`, "Deploying with a button"); and a movement that cannot be cancelled says why before the click
(script 83: "Cancel…" disabled with the reason, 4.6, 5.4).*

*Updated on 19 October 2026 for **Create Purchase Invoice line by line** (script 86, the owner: "the same way must be
when creating the purchase invoice from purchase order"): on an approved order the dialog works like Create Invoice from
Containers - the date, the exporter's ref. and the commercial invoice no., and the order's lines still to invoice with
Ordered, Invoiced, In drafts and Available, each ticked with its available quantity, which the user may lower or untick
(3.4, 4.2, 5.4).*

*Updated on 21 October 2026 for **a charge on a container of one item** (script 88, reported on testing: a Customs
charge allocated By Item Value on KTG-2026-0151 was refused at Post, "the allocation basis (Value) is zero for every line
of the container", its price being 0): a container line that is the only one with pieces takes the whole charge,
whatever the allocation method - no price, weight or volume is needed for it; on a container of several lines all at
price 0 a charge by value is still refused, and the refusal names each line, where its price comes from and the way
out; every refusal of the allocation names the container (glossary, 4.7, 5.4).*

*Updated on 21 October 2026 for **one SQL Server for both environments**: testing's database can live in production's
SQL Server, `Inventory_Shipment_Test` next to production's `Inventory_Shipment`, reached by testing's own login
`inventory_test` (which owns it and has no access to production's), so one SSMS connection shows both. Moved once
with `share-sql-server.sh` on the server; `copy-testing-to-production.sh` takes testing's data into production when it
goes live (8.2; `deploy/README.md`, "One SQL Server for both environments").*

*Updated on 24 October 2026 for **script 89 (fixes)**: a late container charge, and a landed cost adjustment of an
invoice posted before goods receipts, split on the company's stock in every warehouse, as the goods receipt true-up
does, and a cancel never takes more out of stock than its posting put in; cancelling a stock document reverses only its
own rows, and every cancelled stock or sales document replays its items' average cost (those cancelled before were
replayed once); a shortage plan for a parent warehouse creates its purchase order again; Configuration › Document
Types keeps what is saved (five seeds reset it at every start); an item whose every receipt was cancelled keeps a zero
average and no last cost (script 19's per-start backfill counted the cancelled postings); stale lines about closed
orders and Expected Monthly Sales corrected (glossary, 3.3, 3.7, 4.5, 4.7, 4.12, 5.4).*

*Updated on 25 October 2026 for **transfer orders** (script 90, prompt 47): Inventory › Transfer Orders moves stock
between two warehouses of any branch without changing its cost - a dispatch (TRD) puts it on the destination branch's
hidden On the way warehouse, a transfer receipt (TRR) into the destination - with partial postings, losses ("Nothing
more will arrive"), "Nothing more will be sent", Cancel order, Reverse (receipt first), Dispatch and receive, returns,
Late, and an approval switch on the TRO type with its emails; Shortages count "Transfers in" (glossary, 1.4, 1.6,
3.1, 3.3, 3.7, 3.8, 3.10, 4.1, 4.11, 4.13, 5.1, 5.2, 5.4, 6.1, 8.2; `docs/notes/costing-rules.md`, "Transfers").*

*Updated on 15 October 2026: the team moved from GitLab to **GitHub**. Both repositories live on GitHub under
`bfa-14`, everyone pushes and merges there, and GitLab is no longer used (6.3, 8.2; `deploy/README.md`).*

*How sure I am:*
- *Where I am not sure, I say so with **(unsure)** or **(check the code)**.*
- *Prompts 1–31 and Ali's scripts 29–41 were written before this session or by someone else. I only know them
  indirectly.*
- *The code in the repositories is the truth; this document explains the business behind it.*

*Status marks used in section 4:*
- ***[Implemented]***: built and verified.
- ***[Decided – prompt NN]***: a prompt is written but not run yet, as far as I know (none left on 19 October 2026:
  every written prompt is built).
- ***[Ali – details unknown]***: built by Ali; I only know the commit title.

**Contents:** 1. The business · 2. Glossary · 3. Modules and workflows · 4. Business rules · 5. The prompts so far ·
6. What's next · 7. How we write prompts (with a complete example) · 8. Anything else

---

## 1. The business

### 1.1 The company
- **Katanga TVS Motor Company**, a distributor of **TVS motorcycles** in the **Democratic Republic of Congo** (country
  code CD), in the former Katanga region (Lubumbashi, Likasi, Kolwezi).
- The sign-in page says "Sign in to continue to Katanga TVS System" and "Katanga TVS is committed to delivering
  reliable, stylish and high-performance motorcycles that move lives forward."
- Footer: "© 2026 Katanga TVS Motor Company · Powered by MAY solutions · Inspired by Mr. Issa Awada".
- The application is called **Inventory & Shipment**. It is an ERP for purchasing, imports in containers, stock and
  costing, sales and customer payments.

### 1.2 What it buys and sells
- **Buys** motorcycles mainly from **TVS Motor Company, India** (supplier code `SUP-0001` in the data).
  - Imports come by sea in containers, mostly **40HC** (40 ft High Cube). One container holds a fixed number of one
    model, for example 84 pieces. That number is the item's **Container unit** in Item Definition.
  - Motorcycles may travel **with oil**: the container line has "Oil included" and "oil quantity per unit", for
    information only.
- **Also buys locally** (no container): the goods are received with a goods receipt, from the order or the invoice;
  the supplier invoice, with its own charges, sets their cost.
- **Sells** to customers through sales invoices and collects payments through **Receipts** (cash or bank). Who the
  customers are (dealers, retail) is **(unsure)**.
- **Items:** motorcycle models for sure; spare parts and oil are likely **(unsure)**. Invoice lines can carry an expiry
  date (several lines of the same item can differ by warehouse or expiry date); how expiry is used is **(unsure)**.

### 1.3 Countries, ports and routes
Ports master data (`masterdata.Ports`: PortCode, PortName, CountryCode, Kind = Sea / Border / Inland), seeded:

| Code | Place | Country | Kind |
|---|---|---|---|
| INMAA | Chennai | India | Sea (port of loading for TVS) |
| INNSA | Nhava Sheva | India | Sea |
| CNSHA | Shanghai | China | Sea |
| TZDAR | Dar es Salaam | Tanzania | Sea (arrival port) |
| ZADUR | Durban | South Africa | Sea (arrival port) |
| MZBEW | Beira | Mozambique | Sea (arrival port) |
| ZMKAS | Kasumbalesa | Zambia (DRC border post) | Border |
| CDLUB | Lubumbashi | DR Congo | Inland |
| CDKLW | Kolwezi | DR Congo | Inland |

**Typical import route** (the worked example in the user guide):
1. Sea freight: Chennai → Dar es Salaam.
2. Inland transport by truck: Dar es Salaam → Kasumbalesa.
3. Customs clearance at Kasumbalesa.
4. Warehouse delivery: Kasumbalesa → Lubumbashi.
5. Receive the goods into the warehouse: a **goods receipt**, drafted when the Delivery movement is completed.

DRC imports need a **FERI** (electronic cargo tracking note). The shipping line allows **free days** at the port;
after them it charges **demurrage**.

### 1.4 Branches and warehouses
- **Branches** (Master Data › Branches / Sites) have codes that appear in document numbers: `PO-BR-002-000042`,
  `PINV-BR-003-000011`.
  - **BR-003 = Likasi Branch**, whose warehouse is "Likasi Warehouse".
  - **BR-002** is another branch, probably Lubumbashi **(unsure)**.
  - Whether a BR-001 / head office exists is **(unsure)**.
- **Warehouses** belong to a branch. A warehouse can stand under another warehouse (a hierarchy, added by Ali).
- **Stock is kept only at the bottom of the tree** (Ali, scripts 69–71, and 72 for goods receipts): a warehouse with
  warehouses under it is a group, not a place. Every line that moves stock (sales, purchase and stock documents, the
  Excel imports, goods receipts) takes a warehouse **without warehouses under it, of any branch**: the header's branch
  numbers the document, it does not limit its lines; each stock movement is counted in the branch of its own warehouse.
  A parent is refused on save and again at posting: "Line 2: warehouse LUB has warehouses under it. Choose one of
  those: stock is kept only in the warehouses at the bottom of the tree." A warehouse already used (stock moved, or
  named by a document or a goods receipt, a draft too) cannot become a parent.
- The warehouse a container's goods are received into **must belong to the container's branch** (and be at the bottom
  of the tree).
- **Each branch also has one hidden "On the way" warehouse** (script 90, `OTW-BR-002` "On the way to BR-002
  (transfers)"): the goods a transfer order dispatched to one of the branch's warehouses sit there until they are
  received or written off. It is made and kept by the system, never a line's warehouse, and offered only by Stock
  Valuation's filter (4.13).

### 1.5 Currencies
- **Base currency: USD.** A USD document shows "Exchange Rate 1 (base currency)".
- Documents can be in another currency, with a **Rate Type** (for example "Official") and an exchange rate taken from
  Master Data › Exchange Rates for the date, which the user can change.
- Every amount is also stored in base currency (columns `…Base`).
- Other currencies: CDF (Congolese franc) is very likely defined; others **(unsure)**.
- A sales invoice can have its own currency (Ali).

### 1.6 Who uses the system (roles)

| Role | What it does (as designed) |
|---|---|
| **System administrator** (system role, `IsSystem = 1`; user "Admin", shown "System Administrator") | Holds every permission. Sets up master data, users, roles, settings (email, purchase approval), document types. |
| **Owner** | Approver candidate. Receives a copy of approved purchase orders (setting). Views and approves transfer orders by default (script 90). **No user has this role in Bilal's local database yet.** |
| **Manager** | By default: view, create and confirm containers; view, create and post goods receipts (it offloaded containers before them); manage movements and documents; view and create container charges; view and approve transfer orders (script 90). Approver candidate. Test user `manager1` ("Manager One"). |
| Purchasing / buyer | Creates purchase orders and sends them for approval. Test user `buyer1`. The real role name is **(unsure)**. |
| Logistics | Plans containers (Auto-plan), types container and seal numbers from the forwarder's list, starts shipments, records movements (completing the Delivery drafts the goods receipts), enters charges, attaches documents (B/L, packing list...). |
| Accounting | Posts supplier invoices (payable; they adjust the cost of goods already received) and charges, landed cost adjustments; follows costs, stock valuation, sales profit. |
| Warehouse | Receives the goods: counts them on the goods receipt (containers, and local purchases with Receive goods…), with a reason when they differ, and posts it. Inventory In / Inventory Out. |
| Sales / cashier | Sales invoices, receipts, customer statements, out-of-stock sales. |

Real job titles and the other roles in `security.Roles` are **(unsure, check the code)**. Permissions are given to
roles (Users & Permissions › Roles / Role Permissions). **Approvers are no longer taken from a role**: they are ticked
per user in Settings › Purchase approval (see 4.3).

### 1.7 The people and tools on the project
- **Bilal**: the developer I work with, and the one who talks to the business. He is on Ubuntu and uses VS Code with
  the Claude Code extension, which I call "VS Code Claude". Folders:
  - `~/VSProjects/InventoryShipment-Project/Inventory_Shipment` (API)
  - `…/Inventory_Shipment.Web` (frontend)
- **Ali ("AJ")**: colleague on Windows, with Visual Studio and IIS Express, in `C:\GitProjects\Inventory_Shipment`.
  He wrote the Sales / Receipts / Settings parts and SQL scripts 29–41.
- **The prompt writer** (me, now you): writes the business specification as prompt files.
- **VS Code Claude** implements the prompts in Bilal's repositories, writes the SQL scripts from our specifications
  (it has the real current procedure bodies), applies and tests them, and reports back. Bilal pastes its reports
  here; we review and adjust.

---

## 2. Glossary

| Term | Meaning here |
|---|---|
| **PO** | Purchase order. Document type code `PO`, number like `PO-BR-002-000042` (prefix, branch, sequence). |
| **Saved / Partially posted / Posted (order)** | What an approved order shows (script 77, the owner's words), from its **posted** supplier invoices: **Saved** no posted invoice yet, **Partially posted** invoiced less than ordered, **Posted** everything ordered invoiced. Draft invoices do not count; purchase returns do not lower it; goods receipts never change it. Stored as status 2 (approved) with the invoicing status 0 / 1 / 2 beside it. There is no **Closed** any more. |
| **PINV** | Purchase (supplier) invoice, `PINV-BR-003-000011`. The number is given **at posting**; a draft has none. Since the switch to goods receipts, posting it makes the amount payable and moves **no stock**. |
| **PRET** | Purchase return, created from a posted PINV, `PRET-…`. |
| **GRN / goods receipt** | Purchase › Goods Receipts (scripts 64–65, document type `GRN`, `GRN-BR-002-000001` given at posting): the goods that arrived, counted and put in a warehouse. **The only way supplier goods enter the stock.** Draft → Posted → Cancelled. One source each: a container, an order, an invoice, or "Without an order". |
| **Receive goods…** | The button that creates a draft goods receipt: on a container (status Confirmed to Cleared), an approved order (Saved, Partially posted or Posted) or a posted invoice; "+ New" on the Goods Receipts list does the same. "Create draft" or "Create and post". |
| **Automatic draft** | The draft goods receipt made for each container when a movement of the **Delivery** stage is completed (badge "Auto"). Cancelling that movement deletes it. Made only while the GRN type's "Create goods receipts when a Delivery is completed" is on (script 79, default on); off, goods receipts are made by hand with Receive goods…. |
| **Affects item cost / Affects on-hand** | The two switches of the purchase invoice type (PINV) in Configuration › Document Types (script 79). *Affects item cost* (default on): the invoice's price and its own charges become the cost of the goods received against it; off, those goods keep the order price (plus their container's charges). *Affects on-hand* (default off): posting an invoice also receives its goods with a goods receipt made and posted at once. Each invoice keeps the values it was posted with (`PurchaseDocuments.AffectsCost` / `ReceiveOnPost`). |
| **Delivered, not received** | A container whose Delivery is completed (or with a draft goods receipt) and whose goods receipt is not posted: a filter of the Containers list. |
| **Settled short** | Pieces that will never come: on a container receipt, loaded − received (a reason is required); on a local receipt line, the rest of the order line when "Nothing more will come" is ticked. The order counts them as done. |
| **Received / Invoiced / Short** | The three counters of an order line: received by goods receipts (`GoodsReceivedBase`), invoiced by posted invoices (`ReceivedQuantityBase`, an old name that has always meant invoiced), settled short (`GoodsShortBase`). |
| **Order price / invoice cost** | The two costs of received goods: the order line's price in base currency until a posted invoice covers the pieces, then the invoice's FOB (+ its own charges outside containers). |
| **Cost true-up / GRNCOST** | When an invoice (or LCA, or another receipt) changes the cost of goods already received, the difference is booked automatically: the part still in stock changes the average cost, the part sold goes to COGS. `inventory.CostAdjustments` rows with SourceKind `GRNCOST`; see `docs/notes/costing-rules.md`. |
| **The switch (goods receipts)** | The moment script 65 first ran on a database, kept in `purchase.GoodsReceiptSwitch` (one row; each database has its own date). Documents posted before keep their stock and cost ("Posted before goods receipts"). **One-way**: see 4.12. |
| **SINV / SRET** | Sales invoice / sales return. The exact codes in `inventory.DocumentTypes` are **(unsure, check the code)**; I never saw a sales-return menu. |
| **Receipt** | A customer payment (Sales › Receipts), with a payment method and a cash or bank account. |
| **LCA** | Landed Cost Adjustment (script 23): late charges added to a **posted local** invoice. They adjust the item cost: the part still in stock changes the average cost, the part already sold goes to COGS. Refused on imported invoices (error 67012). |
| **FOB** | Purchase price of the goods loaded on board, before the costs of the journey. Taken from the posted supplier invoice; goods received before their invoice carry the order price until it is posted. |
| **Landed cost** | FOB + charges: the real cost of a piece in the warehouse. Imports: **FOB per piece (the invoice's, else the order price) + posted charges on the container line ÷ pieces received**. |
| **Charge** | A cost of the import or purchase (freight, insurance, clearing, port fees, transport, storage, demurrage). Imports: on **containers**. Local: on the invoice. |
| **Charge type** | Master data (Purchase › Charge Types). Gives the default **allocation method** and whether the charge enters the cost ("include in landed cost"). |
| **Split rule** | How one charge typed for several containers is divided between them: **Same** (each container gets the full amount), **Equal**, **Pieces** (default), **Value**. |
| **Allocation method** | How a container's charge is divided over its items: **Value, Quantity, Weight, Volume, Manual**. Rounded to the cent; leftover cents go to the largest remainders. A container with one line (with pieces) puts the whole charge on it, whatever the method (script 88). |
| **Charge group** | Charges created together, or copied with "Apply to other containers", share a `GroupId`. The provider's invoice is attached once for the group. |
| **Late charge / cost adjustment** | A charge posted (or cancelled) after the container's goods are received (badge "after receipt"), or on a posted local invoice (LCA). Recorded in `inventory.CostAdjustments`, SourceKind `CNTCHARGE` for containers. The cost of received goods following their invoices is a cost adjustment too (`GRNCOST`). The part the company still holds (every warehouse, script 89) changes the average cost; the rest goes to COGS. |
| **COGS** | Cost of goods sold. Sales take stock out at average cost. |
| **Average cost** | Weighted average cost per item, updated at every receipt and cost adjustment. Items also keep **last cost** and **FOB cost**. |
| **Container** | A shipping container, created **from a purchase order**. App reference `KTG-2026-0031` (document type CNT: prefix KTG, year, 4-digit number). |
| **Container No.** | The real box number: 4 letters + 7 digits, for example `MSKU1234565`. Typed when the forwarder sends the list. Unique among open containers (69013). |
| **Seal No.** | The number of the seal closing the doors. |
| **Container type** | Master data: 20GP (20 ft General Purpose, inactive) and **40HC** (40 ft High Cube, active), with Max Weight (kg) and Max Volume (CBM). Their "Max Units" is no longer used (script 54, prompt 46): capacity comes from the item's Container unit. |
| **Container unit** | In Item Definition › units: the unit whose unit type is a container unit (`masterdata.UnitTypes.IsContainer = 1`). Its packing formula is the pieces of this item per container (for example 84). **The only source of container capacity** (prompt 46). |
| **Base unit / pieces** | The smallest unit of an item (`PC`). Container quantities are always in base units. Other units have a packing formula. |
| **Auto-plan** | On an approved PO: choose the container type and the app proposes all containers, filled from the order lines; edit, then create them all at once (all or nothing, **any number of containers** since script 78; 200 at most before). The supplier is shown from the order and the forwarder filled in (4.5). |
| **Mix the rest** | Auto-plan option: what is left of each line after full containers is packed into shared containers. Off = each rest gets its own container. |
| **Fill % / equivalent capacity** | How full a container is: the sum of quantity ÷ pieces per container of each item (prompt 46). |
| **Over capacity** | Fill above 100%: a warning that only users with "Load Above Capacity" can confirm (69007). |
| **Confirm (container)** | The loading plan is agreed: Draft → Confirmed. |
| **Movement** | One leg of the journey, `MOV-2026-000046`. Types: LOAD, SEA, TRANSHIP, PORT, INLAND, BORDER, CUSTOMS, DELIVERY. Planned → In progress → Completed, or Cancelled. |
| **Stage** | What a movement type does to its containers: Origin, Sea, Transit, Port, Border, Customs, Delivery. |
| **Start shipment** | The first leg of a container that never moved (default SEA, port of loading → port of destination), from its Next step: created and started at once ("Plan only" to plan it), leaving from where the container is. Vessel, voyage, B/L and ETA are copied to the container. |
| **Next step (of a container)** | Scripts 80–81: the one button of a container's page (and the first entry of its row's "…" menu, "Next step: …") whose label says what happens next, and the one dialog it opens, already filled in: "Start shipment…" (never moved), "Start {type}…" (its next planned movement), "Arrived at {To}…" / "Cleared customs at {place}…" / "Crossed the border at {place}…" / "Left the port of {place}…" / "Loaded at the supplier…" / "Delivered to {To}…" (a movement in progress carries it, by the stage of its type), the proposed next leg "{Type} to {To}…" / "{Type} at {place}…" / "Next leg from {place}…" (its last leg is completed), "Receive goods…" / "Open goods receipt (draft)" (delivered, not received). "Next step…" in the selection bar does it for many containers, grouped by step. |
| **Proposed next leg** | Script 81: what Next step proposes from where a container is: the usual next leg from that place (the most frequent of the last 365 days, after a leg of the same stage, seen at least twice - a voyage split in two counts once, script 82: "Suggested: the usual next leg from Dar es Salaam (5 earlier legs)"), else the container's own ports (never moved: Sea freight to its port of destination; a Delivery to its final destination), else the stage order (after Sea or Port: Inland transport, To to choose; at a border or inland place: Customs there; cleared: Warehouse delivery). Only active types are proposed; when the next stage has none the type is left to choose ("Choose the type") and the container still moves on. There are no route templates: history and stages only (the owner's choice). |
| **Then leg** | Script 81: "Then start Customs clearance at Kasumbalesa on the same day" in the arrival dialog: the proposed next leg started right after the arrival is recorded, as a second step - refused, the arrival stays ("Arrival recorded; Customs clearance was not started: {reason}. Use Next step…"). Ticked by default for a stay at the arrival place or the leg after Customs / Border, unticked for a leg that moves; never after a Delivery, nor when the container's next leg is already planned (that planned movement is its next step; planned by someone else while the dialog was open, the warning names it: "…its next leg MOV-2026-000058 (Customs clearance) is already planned. Start it with Next step…"). |
| **Shipments board** | Script 82: Logistics › Shipments, every container on its way in one column by stage, decided in the database (`logistics.fn_Container_BoardPhase`) from the same movements as its next step: **At supplier** (never moved, or Loading at the supplier in progress), **At sea** (a Sea leg, or a transshipment between two sea ports, in progress), **At port** (a Port stay in progress, or its last leg ends at a sea port), **On the road** (inland transport, a border crossing or a delivery in progress), **At border / customs** (customs in progress, or its last leg ends at a border post or an inland place), **Delivered, to receive** (its Delivery is done or a draft goods receipt waits) and, with "Show received (30 days)", **Received**; a container followed by typed dates (no leg yet, 3.5 item 11) stands in the column of its status ("Followed by typed dates"). Grouped by ship, by leg, by place, by warehouse. No drag-and-drop: every move is a movement, through Next step. Permission `containers.shipments.view`. |
| **Split (of a movement)** | Script 82: only part of a movement in progress arrived. The ticked containers leave it for their own movement - a copy (type, From, To, dates, ETA, carrier, vessel, voyage, reference, notes), with its own MOV number and "Split from MOV-…" - taking their rows, charges and documents filed under the movement; it is completed (a Delivery drafts their goods receipts) while the others stay on the original, in progress. Refused when every container is ticked ("complete the movement itself"), when a ticked one has a later leg, or when the movement is not in progress; the date is checked before anything is split. A container taken off a planned later leg to be split travels on with a new leg of its own: the split-off movement comes after that planned leg in the travel order. **Cancelling the split-off movement undoes the split**: its containers go back onto the movement they were split from, whatever its status - in progress they travel on with it, completed they arrived with it (its end date and To; a completed Delivery leaves them delivered, not received, without a draft goods receipt), cancelled they are where they were before it, like its other containers (4.6). |
| **Place of a container** | The **To** of its previous movement (prompt 43). A container that never moved is at its **port of loading** (prompt 45). |
| **Offload** | **Retired by goods receipts** (69010: "Use Receive goods… on the container"). It received a container's goods into stock at landed cost, with a reason when received ≠ loaded (stock rows of type `CNT`, re-offload tag `KTG-…/2`). A container is now received with a goods receipt, whose posting makes it **Offloaded**: the status kept its name. Containers offloaded before keep their Cancel Offload. |
| **Close / Reopen (container)** | Close when every charge is posted and every received piece is invoiced (read-only). Reopen to add a late charge. |
| **Receipt mode** | On a purchase invoice: **1** = local; **2** = "Shipped in containers". Before goods receipts, 1 put the stock in when the invoice was posted and 2 at the container offload. Since the switch no invoice moves stock: mode 2 says the goods travel in containers and come in with their goods receipts; mode 1 goods come in with Receive goods…. |
| **Shipped in containers** | The PI switch for receipt mode 2: "Its goods travel in containers and are received with them." On by default when the order has containers; locked while lines are linked to containers (65026). |
| **Link / Unlink (containers)** | On a PI: says which pieces of the invoice travel in which container. Each invoice line points to one container line (`PurchaseDocumentLines.ContainerLineId`); linking splits the line. Only while the container hasn't moved (Draft or Confirmed). |
| **Exporter's Ref.** | The exporter's reference. Required to post an imported / shipped-in-containers invoice (65018). |
| **Commercial invoice no.** | The supplier's invoice number, typed on the PI. |
| **Supplier reference** | Free reference on the PI. |
| **B/L** | Bill of lading. One B/L can cover several containers. |
| **Booking No.** | The shipping line's reservation number. |
| **ETA** | Estimated time of arrival. A red "Late" badge appears when the ETA has passed and the movement isn't completed. |
| **Free days / last free day / free time over** | Days at the port without demurrage, counted from the actual port arrival. A red badge appears when they are over and the container isn't received; the count stops at the end of its Delivery. |
| **Demurrage** | Shipping-line fee after the free days. |
| **Forwarder / transporter / shipping line / carrier** | Parties (Master Data › Parties) used on containers and movements. |
| **Transshipment** | Moving a container to another vessel at an intermediate port. |
| **FERI** | Electronic cargo tracking note required for DRC imports (a container field). |
| **BIVAC Out** | Inventory › BIVAC Out (script 66, document type `BIV_OUT`, numbers like `BIV-BR-002-000001`): units of **BIVAC items** (items with "BIVAC Item" ticked in Item Definition) taken out of stock at average cost, like an Inventory Out, with its own list and permissions. The user chooses the item (model) and a quantity; other items are refused. No link to a shipment: the BIVAC certificate or container number goes in Reference No. Not the BIVAC fee, which is the charge type `BIV` "BIVAC / Inspection". |
| **Shortage** | Inventory › Shortages (script 25, `fn_Shortage_Live`, last changed by script 85: Expected Monthly Sales is the busiest month): what is missing per item and warehouse (and the warehouses under it) compared with what is on the way. **Transit** = pieces loaded in containers that left the supplier (In Transit, At Port, Cleared) and are not received. **Outstanding order** = what approved orders still bring (ordered − received − settled short, never below 0; no order closes since script 77), plus posted invoices without an order not received yet, minus Transit, never below 0. The item's "On order (still to come)" (Item Definition › Purchase orders) counts the orders' part only, before Transit is taken off: the invoices without an order are not on its list. The Dashboard's "On the way" adds the three parts (script 72). **Transfers in** (script 90) = goods on the way to the warehouse by transfer orders: added to the stock, as Transit is. |
| **Transfer order / TRO** | Inventory › Transfer Orders (script 90, `TRO-BR-003-000012`): stock moved from one warehouse (From) to another (To), both at the bottom of the tree, of any branch. The warehouses are the order's, not its lines'. Lines: item, unit, Ordered. Stored Draft, Waiting for approval, Released or Cancelled; a released order is shown Released, Partly dispatched, Dispatched, Partly received, Closed or Received from its counters. The order moves no stock: its dispatches and receipts do, without changing any cost (4.13). |
| **Dispatch / TRD** | "Dispatch…" on a released transfer order (`TRD-BR-003-000004`, numbered at posting by the source branch): pieces leave From for the On the way warehouse of the destination branch, with a required ETA. Several partial dispatches per order. Printed as a dispatch note (no costs). |
| **Transfer receipt / TRR** | "Receive…" (`TRR-BR-002-000007`, numbered at posting by the destination branch): pieces of one or more dispatches arrive from On the way into To. Each receipt line receives one dispatch line, at most what is on the way on it. |
| **On the way (warehouse)** | One hidden warehouse per branch (`masterdata.Warehouses.IsTransit = 1`, `OTW-BR-002` "On the way to BR-002 (transfers)") where dispatched goods sit, in the ledger, until they are received or written off. Made and kept by the system: never a parent, a main warehouse, a line's warehouse or an item's default, never deactivated, never negative; only its name and address change; offered only by Stock Valuation's filter. On a transfer, "On the way" is also the pieces dispatched and not yet received or lost. Not the Dashboard's "On the way" (supplier goods still to come, script 72). |
| **Transfers in** | Shortages' column (script 90): pieces on the way to the plan's warehouse (and the warehouses under it) by released transfer orders, not received or written off yet. Transfers out are not demand. |
| **Nothing more will be sent** | "Nothing more will be sent…" on a released transfer order that has dispatched something (a reason): what is left to dispatch becomes **Not sent**, Ordered stays as it is, goods on the way can still be received; the order is shown Closed once they have. A stamp, not a status; no reopen. The transfer's "Nothing more will come". |
| **Nothing more will arrive / Lost** | On a transfer receipt line that receives less than is on the way: "Still coming" (the rest stays on the way) or "Nothing more will arrive" with a reason (Damaged, Missing / stolen, Wrongly counted at dispatch, Other + a note). The rest is **Lost**: written off from the On the way warehouse at the item's average cost (stock reason `TRF_LOSS`), the only part of a transfer that changes the company's stock. An orange "{n} lost" badge on the order. |
| **Reverse (a transfer posting)** | "Reverse…" on a dispatch or a transfer receipt: undoes the whole posting in place, with a reason and a "Reversal date" - opposite rows (`IsReversal = 1`) under its own number, status Reversed, "Reversed on {date} by {name}: {reason}". The receipt first: a dispatch whose goods were received or written off waits for that receipt's reversal (62013). No partial reversal. |
| **Return (of a transfer order)** | "Create return…": a new draft transfer order the other way (From = the original's To), "Return of TRO-…", linked both ways, proposing what was received less what its returns not cancelled (drafts included) already order. The original never changes. |
| **Needs approval before release** | The TRO type's switch in Configuration › Document Types (script 90, default off). On: a transfer order is sent for approval and released when a user holding Approve Transfer Orders approves it (an approver may Approve & release a draft at once). Off: Release releases it. |
| **Out-of-stock sale** | A sale of more than the stock, allowed only when the setting "Allow selling out-of-stock items" is on; listed in Sales › Out-of-Stock Sales [Ali – details unknown]. |
| **Date tolerance** | A sales-invoice rule by Ali ("client address, date tolerance"): how far a document date may be from today **(unsure)**. |
| **Payment type** | On sales invoices (Ali: "Payment Type and auto…"), probably cash / credit **(unsure)**. |
| **Approver (in the app / by email)** | Users ticked in Settings › Purchase approval. In the app = Approve / Reject on the order or the Approvals page. By email = a personal link to the public approval page. |
| **Requester** | The person who sent the order for approval. |
| **Create & send / Create & approve / Approve & post** | New-order buttons: save as draft and send for approval / approve at once (in-app approver) / approve an existing draft at once. |
| **Send again / Withdraw** | Resend the request with new links / take the order back to draft. |
| **Approval link (token)** | Personal, single use, valid N hours (default 72). Opening it never decides; the decision is one click on the page `/purchase-approval/:token`. |
| **Email outbox / Email log** | `messaging.EmailOutbox`, a queue sent by a background worker; read it in Settings › Email log (Pending / Sent / Failed). |
| **Schema.sql** | `Inventory_Shipment.Repository/Database/Schema.sql`: every SQL script appended in order, re-applied at **every API start**. |
| **Batch** | A group of prompt steps. Batch 8 = prompt 32, 9 = 33, 10 = 34/36, 11 = 37. |
| **A / B steps** | A1, A2… run in the API project; B1, B2… in the Web project. |
| **TEST-NN data** | Test data created by VS Code Claude while verifying prompt NN (notes / refs start with "TEST-NN"); it reports what is left. |

---

## 3. Modules and workflows

### 3.1 Menu map (as seen on Bilal's screen)
- **Home** (the first landing page, renamed when Ali's new Dashboard came) and **Dashboard** (Ali, script 68: key
  figures, "needs attention" lists and charts per branch and period; each part shown only to who may open its screen)
- **Inventory:** Item Definition, Price Lists, Inventory In, Inventory Out, BIVAC Out, **Transfer Orders** (script 90:
  with a red count of the orders waiting for approval, shown to approvers), Stock Valuation, Shortages
- **Purchase:** Purchase Orders, Approvals (with a red count), **Goods Receipts** (with the count of drafts waiting to
  be posted), Purchase Invoices, Purchase Returns, Supplier Payments, Landed Cost Adjustments
- **Logistics:** Shipments (script 82: first in the menu), Containers, Movements, Container Charges, Tracking
- **Sales:** Sales Invoices, Sales Profit, Receipts, Customer Statement, Out-of-Stock Sales
- **Backoffice › Master Data:** Branches / Sites, Warehouses, Currencies, Exchange Rates, Item Families, Brands,
  Parties, Unit Types, Ports, Attachment Types, Movement Types, Payment Methods, Cash / Bank Accounts
- **Backoffice › Users & Permissions:** Users, Roles, Role Permissions, Permissions, Login audit
- **Configuration:** Document Types, Charge Types, Container Types; Settings › General, Email, Email log, Purchase
  approval

Web routes seen: `/purchase/invoices/:id`, `/purchase/goods-receipts`, `/purchase/goods-receipts/:id` (and `/new`,
`/:id/print`), `/logistics/movements/new`, `/logistics/movements/:id`, `/setup/master-data/container-types`,
`/configuration/email`, `/purchase-approval/:token` (public), `/inventory/transfers`, `/inventory/transfers/:id` (and
`/new`, `/:id/dispatches/:postingId/print`, the dispatch note).

### 3.2 Master Data
Reference lists used everywhere:
- **Parties:** suppliers, customers, forwarders, carriers, providers of charges. Codes like `SUP-0001`.
- **Item Families, Brands.**
- **Unit Types:** some flagged as container units.
- **Container Types, Ports** (with Kind), **Movement Types** (each with a Stage), **Attachment Types** (category +
  sub type; prompt 40 adds "Used for").
- **Currencies, Exchange Rates** (by date and rate type).
- **Payment Methods, Cash / Bank Accounts** (for receipts).
- **Branches / Sites, Warehouses** (hierarchy).

Each list has its own permission, for example `masterdata.movementtypes.manage`.

### 3.3 Inventory
- **Item Definition:** code, name, family, brand, units with packing formulas (base unit PC; packaging units; the
  **Container unit**), weight (kg) and volume (CBM), which charge allocation by weight or volume needs. The item also
  shows average cost, last cost and FOB cost (last and FOB from the latest goods receipt, after its cost adjustments).
- **Price Lists:** selling prices **(details unsure)**. Document types carry `DefaultPricing` and `PriceEditable`,
  which suggests each document type says where its default price comes from and whether it can be changed
  **(check the code)**.
- **Inventory In / Inventory Out:** manual stock documents; a document type can require a reason (`RequiresReason`).
  Cancelling a posted one writes the opposite of its own rows and replays its items' average cost (script 89).
- **BIVAC Out:** an Inventory Out of BIVAC items only, with its own list, numbers and permissions (see 4.9).
- **Transfer Orders** (script 90): stock moved from one warehouse to another, of any branch, without changing its
  cost. A dispatch (TRD) takes it out of From onto the destination branch's On the way warehouse, a transfer receipt
  (TRR) puts it into To; partial postings, losses, Nothing more will be sent, Cancel order, Reverse, Dispatch and
  receive, returns, Late and an optional approval (see 4.13). It replaces an Inventory Out in one warehouse and an
  Inventory In in the other, which moved the average cost twice and showed nothing while the truck was on its way.
- **Stock Valuation:** stock × average cost per item and warehouse; the export calls it "Total Cost". Its warehouse
  filter also offers the On the way warehouses (script 90).
- **Shortages:** see the glossary.
- **Stock ledger:** `inventory.StockMovements` (DocumentFamily, DocumentTypeCode, DocumentNumber). Goods receipts
  write family Purchase, type `GRN`, the receipt's number; the item's stock statement shows them with their source,
  "GRN-BR-002-000001 · KTG-2026-0031". Before goods receipts, local invoices wrote `PINV` rows and container offloads
  `CNT` rows with the container ref (a re-offload `/N`). Transfers (script 90) write family `Transfer`, types `TRD` /
  `TRR`, the posting's number, reasons `TRF_OUT`, `TRF_IN` and `TRF_LOSS`; the statement shows them with "LKS-01 →
  LUB-01" and their transfer order. `inventory.usp_Item_RebuildCosts` recomputes costs.

### 3.4 Purchase
**Documents:**
- **PO** → approval → approved, shown **Saved**; then **Partially posted** while its posted invoices cover less than
  ordered, and **Posted** once they cover everything (script 77). An order is never closed: goods may still be
  received on a Posted order, and pieces that will never come are settled with "Nothing more will come".
- **GRN** (goods receipt, Purchase › Goods Receipts, scripts 64–65): **the only way goods enter the stock.** Made from
  a container (automatically when its Delivery is completed, or Receive goods…), from an order, from a posted invoice,
  or without an order. See 4.12.
- **PINV:**
  - created from a PO with "Create Invoice", or from containers with "Create Invoice from Containers…" (received
    containers too: goods may arrive before their invoice); both dialogs list what is still to invoice line by line,
    each ticked with its available quantity, which may be lowered or unticked (the order's since script 86);
  - **one item per invoice**: several items give several drafts at once (optional since script 63, see 4.2);
  - each line may take at most what remains on its source line;
  - posting makes it payable and moves no stock; it sets the cost of the goods received against it.
- **PRET** from a posted PINV: at most what was received and not returned.

**Charges on purchases:**
- **Local invoice** (not "Shipped in containers"): its own charges while it is a draft
  (`usp_PurchaseDocument_SetCharges`); they are part of the invoice cost the received goods take. After posting, late
  charges go through an **LCA**, which adjusts the goods already received. Prompt 38 puts one "+ Add charge" in every
  status.
- **Imported invoice** (from containers, mode 2): **no charges of its own**. The charges belong to the containers; the
  invoice page shows them read-only.

**Approval:** see 3.9 A and 4.3. Purchase › Approvals lists "Waiting for my approval".

**Excel:**
- **Import:** Ali's import of invoice lines (`ImportInvoiceItemsWizard.tsx`). It now creates one invoice per item,
  or one invoice of every item when the open invoice is of several items, or the setting is off (script 63).
- **Export:** "Export to Excel" on documents; the supplier email attaches `PO-{number}.xlsx`.

### 3.5 Logistics (containers): built by scripts 24 (first version, "batch 6"), 27, 28, 43, the prompt 43 script, and later prompts 44–46

1. **Create containers from an approved, open PO:** "Add Container…" one by one, or "Auto-plan containers…". Lines of
   other approved POs, even from other suppliers, can be added to a container. Quantities are in pieces.
2. **Container numbers and seals:** bulk "Container numbers…" with "Paste list", for example `MSKU1234565 SL-001`.
3. **Confirm** (bulk possible). Starting a shipment confirms drafts automatically.
4. **Supplier invoice:**
   - **Containers first:** "Create Invoice from Containers…" lists the container lines still to invoice; one draft per
     item.
   - **Invoice first** (prompt 41): on the PI, "Shipped in containers" on, then **Add container… / Auto-plan… / Link
     containers…**.
   - Type the Exporter's Ref. and the Commercial invoice no., then post. No stock goes in at posting.
5. **Shipment:**
   - **Next step** on the container's own page (the button next to Save, scripts 80–81) or in its row's "…" menu:
     "Start shipment…", "Arrived at Dar es Salaam…", "Inland transport to Kasumbalesa…", "Cleared customs at
     Kasumbalesa…", "Delivered to Lubumbashi…" - one dialog, already filled in with the usual next leg from where the
     container is, the From locked. The arrival dialog can start the next leg on the same day ("Then start …").
   - **"Next step…" on the selected containers** (for example the 5 of 30 still waiting, or 300 at once): the containers
     are grouped by what they do next (same step, movement, type, From and To), each group applied on its own; a truck
     leg goes one movement per container by default.
   - Each leg is still a **movement** (Logistics › Movements, where the containers are ticked in a list at the
     movement's From, prompt 45). Start / Complete move the containers' status, dates and current location forward,
     never back. They are on the movement page, on each row of the Movements list ("Start…", "Complete…") and in the
     container's Next step; after a Complete the movement page offers "Continue: Next step…" for its containers.
   - **The Containers list's Next step column** and its filter ("Start shipment", "Start planned leg", "Arrival due",
     "Next leg to plan", "Receive goods") are the logistics to-do list.
   - **Logistics › Shipments** (script 82): every container on its way by stage, grouped by ship, leg or place, each
     card with its next step (4.6).
   - **Only part of a movement arrived** (script 82): the containers that arrived are completed on their own movement,
     the others stay on it, in progress (glossary "Split").
6. **Charges:**
   - Entered from the container, a movement ("Add charge for these containers"), the selection bar or Logistics ›
     Container Charges.
   - Split over containers, allocated over items, Draft → Posted → Cancelled.
   - "Apply to other containers…" copies a charge.
7. **Documents:** attachments per container, optionally linked to a movement and/or a charge, with an attachment type.
   One upload can go to several containers; the file is stored once.
8. **Goods receipt** at the warehouse (replaces the Offload, scripts 64–65; see 4.12):
   - Completing a **Delivery** movement creates a **draft goods receipt** per container; "Receive goods…" on the
     container does it by hand (any container from Confirmed to Cleared).
   - The warehouse counts: received 0 to loaded per line, a reason when it differs, one warehouse of the container's
     branch at the bottom of the tree (script 72). The goods need not be invoiced yet.
   - Posting it: the goods enter stock at landed cost (the invoice FOB, or the order price for pieces not invoiced
     yet, + the charges re-divided over what arrived, then frozen); average, last and FOB costs are updated; the
     container becomes **Offloaded**. Refused while a movement of the container is in progress.
   - **Cancel goods receipt…** is refused after cost adjustments or when the stock has been consumed. Containers
     offloaded before goods receipts keep **Cancel Offload**.
9. **Close** when all charges are posted and every received piece is invoiced; **Reopen** for late charges.
10. **Tracking:** an animated board (sea legs with a ship, road legs with a truck, stops, late legs in red) that
    refreshes every minute; it shows containers travelling and those received in the last 30 days.
11. **Without movements**, a container can be followed by typing its Dispatch Date, Actual Port Arrival and Customs
    Release Date. Once it has a movement, the dates come only from movements (`DatesFromMovements`).

**Movement types and their effect:**
- **LOAD**: Origin, no status change.
- **SEA**: started = In Transit (dispatch date); completed = At Port (port arrival).
- **TRANSHIP**: started = In Transit.
- **PORT**: started = At Port.
- **INLAND**: started = In Transit (a container already At Port stays At Port).
- **BORDER**: started = In Transit; sets the border crossing date.
- **CUSTOMS**: completed = Cleared (customs release date).
- **DELIVERY**: started = Cleared; completed = a draft goods receipt for each of its containers (any movement type of
  the Delivery stage). The container stays Cleared until the goods receipt is posted.

### 3.6 Sales and Receipts (Ali; I know them only by Ali's commit titles)
- **Sales Invoices:** "Sales invoice: its own currency, and a Spec…", "client address, date tolerance…", "Add sales
  invoice Payment Type and auto…". Stock goes out at average cost, giving COGS.
- **Sales Profit:** sales minus COGS **(details unsure)**.
- **Receipts:** "Add customer receipt management (phas…": customer payments with payment methods and cash or bank
  accounts.
- **Customer Statement:** invoices and receipts per customer.
- **Out-of-Stock Sales:** "Add out-of-stock sales …" and the setting "Allow selling out-of-stock items" in Settings ›
  General.
- Other commits: "Import: one document, whatever warehouse…", "Move the document warehouse from the …", "Carry the
  warehouse parent through the …", "Let a warehouse stand under another warehouse", "Take Expiry Date out of the
  import template", "Call it Total Cost in the inventory export…".

**Read Ali's scripts 29–41 and these commits for the real rules.**

### 3.7 Configuration
- **Document Types** (`inventory.DocumentTypes`): Code, Name, Family, StockDirection, NumberPrefix, NumberOnPost,
  RequiresReason, DefaultPricing, PriceEditable, NumberPerBranch, YearInNumber, NumberLength, BivacItemsOnly
  (script 66, read-only on the page). This drives numbering (4.1).
  - **What a type does** (script 79, permission `inventory.documenttypes.manage`; the defaults are what the system did
    before, so nothing changes until someone turns one):

    | Type | Switch | Default | On | Off |
    |---|---|---|---|---|
    | PINV | Affects item cost | on | the invoice's price + its own charges become the cost of the goods received against it (4.12 rule 14) | the goods keep the order price (+ their container's charges); landed cost adjustments refused (67013) |
    | PINV | Affects on-hand | off | posting the invoice also receives its goods: a goods receipt made and posted at once, for its lines not travelling in containers, into each line's warehouse | the goods come with goods receipts made apart (Receive goods…) |
    | GRN | Create goods receipts when a Delivery is completed | on | a completed Delivery drafts one per container (4.6) | none is drafted: Receive goods… on each container ("Delivered, not received" lists them) |
    | TRO | Needs approval before release (script 90) | off | Release by a user without Approve Transfer Orders is refused (62014) and "Send for approval…" takes its place; the order waits, locked, until an approver approves it (4.13) | Release releases it |

  - The Stock column tells the truth for PINV: "None (goods receipts)", or "In, through a goods receipt at posting" with
    Affects on-hand. Its stored StockDirection stays +1: the invoices posted before goods receipts still read it.
  - The transfer types (script 90, family Inventory, no pricing) are stored with StockDirection 0, because a dispatch
    and a receipt each write two legs: the Stock column reads TRO "None (an order)", TRD "Out of the source, onto On the
    way", TRR "From On the way into the destination". TRD and TRR are numbered when they are posted: "A transfer
    dispatch or receipt is numbered when it is posted: Number on post stays on." (62000). The TRO switch is refused on
    any other type ("Needs approval before release applies to the transfer order type (TRO) only."), and turning it
    never changes an order already waiting or released.
  - An invoice **captures** its two switches when it is posted: changing them never re-prices or re-receives an
    invoice already posted; a draft follows the type as it is when it is posted.
  - A saved setting is kept (script 89): the seed values apply only to a type nobody has saved.
- **Settings › General** (Ali's global settings, for example "Allow selling out-of-stock items").
- **Settings › Email:**
  - sender, mail server and app password (encrypted), the "Address of the application" used in links, and a test
    button;
  - a **"Send emails" switch**: when off, emails stay in the Email log and nothing leaves.
- **Settings › Email log.**
- **Settings › Purchase approval:** rules and approvers.

### 3.8 Security
- JWT sign-in: `POST api/auth/login`; the user "Admin" is the system administrator.
- Users, Roles, Role Permissions, Permissions (code, name, module, description, SortOrder), Login audit.
- The administrator role holds every permission.
- Permission codes I know:
  - Containers: `containers.movements.manage` (1410), `containers.charges.view/create/post/cancel` (1420–1450),
    `containers.attachments.manage` (1460), `masterdata.movementtypes.manage` (1470), plus the container permissions
    named in the guide (View, Create, Confirm, Load Above Capacity / `containers.overcapacity`, Offload, Cancel, Close,
    Delete Containers).
  - Shipments board: `containers.shipments.view` (1406, "View Shipments", script 82), granted once, when it was first
    created, to the roles holding View Movements, View Tracking or Manage Shipment Movements.
  - Purchase: `purchase.orders.approve` (now "(not used)"), `purchase.orders.post`, `purchase.approval.manage`;
    `purchase.invoices.post` is now "payable; adjusts the cost of goods already received".
  - Goods receipts: `purchase.goodsreceipts.view / create / post / cancel / delete` (1102–1110, script 64). Granted
    once, when first created: view, create and post to the Manager role and to the roles that held
    `containers.offload` or `purchase.invoices.post`; cancel to the roles holding `containers.cancel` or
    `purchase.invoices.cancel`; view to the roles that see orders or invoices; delete to the roles with create.
    `containers.offload` is now "Offload Containers (not used)". Completing a Delivery movement needs only
    `containers.movements.manage`.
  - Settings and email: `settings.email.manage`, `messaging.emails.view` (920).
  - BIVAC Out: `inventory.bivacout.view / create / post / cancel / delete` (810–850, script 66), administrator only
    by default; other roles through Role Permissions.
  - Transfer orders (script 90, module Inventory):

    | Code | Sort | What it allows | Granted once, when first created, to the roles holding |
    |---|---|---|---|
    | `inventory.transfers.view` | 855 | see transfer orders, their dispatches and receipts | `inventory.stockin.view` or `inventory.stockout.view`; and the roles named Manager and Owner |
    | `inventory.transfers.create` | 860 | drafts (lines, scan, import), Save details once released, the orders' documents, returns | `inventory.stockout.create` |
    | `inventory.transfers.delete` | 862 | delete drafts | `inventory.stockout.delete` |
    | `inventory.transfers.release` | 870 | Release, Send for approval, Withdraw, Back to draft | `inventory.stockout.post` |
    | `inventory.transfers.approve` | 872 | Approve, Reject, Approve & release (when the TRO type asks for approval) | the roles named Manager and Owner |
    | `inventory.transfers.dispatch` | 875 | Dispatch, Change ETA | `inventory.stockout.post` |
    | `inventory.transfers.receive` | 880 | Receive, and write off what will not arrive | `inventory.stockin.post` |
    | `inventory.transfers.close` | 885 | Nothing more will be sent | `inventory.stockout.cancel` |
    | `inventory.transfers.cancel` | 888 | Cancel order (nothing dispatched) | `inventory.stockout.cancel` |
    | `inventory.transfers.reverse` | 890 | Reverse a dispatch or a transfer receipt | `inventory.stockout.cancel` and `inventory.stockin.cancel` |

    The system role gets all ten. A role unticked afterwards is never re-granted. Dispatch and receive needs dispatch
    and receive. The values on a transfer (on the way, a posting's value, a loss's value, the frozen costs) need
    `inventory.valuation.view`: the server sends them empty to others. Adding lines also needs View Items
    (`inventory.items.view`) for the item search and the item's units, as on Inventory In / Out.

### 3.9 End-to-end flows

**A. Import (the main flow)**
1. **PO draft:** created by a buyer (supplier, branch, currency, lines with warehouse, quantity, unit price,
   discount %).
2. **Approval:**
   - **Create & send** or **Send for approval**: status 5, locked.
   - Approvers get the request: in the app (Approvals page and badge) and/or by email (Approve / Reject buttons open
     the confirm page).
   - **Approved = posted:** the number is assigned, the supplier gets the order by email with `PO-{number}.xlsx`,
     copies go to the Owner role and the typed addresses, and the requester is told.
   - **Rejected:** back to draft, with the reason shown.
   - Orders under the approval limit, or when approval is off, are posted directly ("Posted without approval").
3. **Containers:** Auto-plan, or Add Container; numbers and seals; confirm.
4. **Supplier invoice(s):**
   - Created from the containers, one per item.
   - Or invoice first, then add or link containers.
   - Exporter's Ref. required. **Post: no stock.** It may also be posted after the goods arrive (step 8).
5. **Shipment:** Start shipment (SEA Chennai → Dar es Salaam), then INLAND → Kasumbalesa, CUSTOMS, DELIVERY →
   Lubumbashi. Each movement is started and completed. **Completing the DELIVERY creates a draft goods receipt for
   each container**, into the container's warehouse when it is active, belongs to the container's branch and has no
   warehouses under it (else "warehouse to choose", and the notification says why). The notification names the drafts
   made and the containers left out, with the reason.
6. **Charges** (freight, clearing, transport, port fees, demurrage) entered on containers, split and allocated,
   **posted**. Documents attached (B/L, packing list, FERI).
7. **Goods receipt** at the warehouse: open the draft (Purchase › Goods Receipts; the menu counts the drafts), check
   the warehouse, type the pieces received and a reason on each line that differs (Short-shipped, Damaged, Missing,
   Wrongly counted at loading, Other), print the count sheet if wanted, then **post**. Stock in at **landed cost**
   (invoice FOB, or the order price for pieces not invoiced yet, + charges); average cost updated; the container
   becomes Offloaded; the missing pieces are settled short. A container followed without movements: Receive goods…
   on the container.
8. **Invoice after the goods:** posting it brings the received pieces to the invoice cost automatically (in stock →
   average cost; sold → COGS; an exchange-rate difference is part of it).
9. **Close** the container (every charge posted, every received piece invoiced). Late charges: reopen, post, and the
   cost is adjusted (in stock → average cost; sold → COGS).
10. **Sale** (SINV): stock out at average cost, which gives COGS and the Sales Profit.
11. **Receipt** of the customer's payment; the Customer Statement updates.

**B. Local purchase**
1. PO, then approval.
2. **Goods arrive:** "Receive goods…" on the order (or Goods Receipts › "+ New › From a purchase order…"): per line the
   pieces received, the warehouse, and "Nothing more will come" (with a reason) when the rest will never arrive.
   Partial receipts are allowed. **Post**: stock in at the order price.
3. **Create Invoice** from the PO, one per item, with "Shipped in containers" off; its own charges; **post**: the
   amount is payable, no stock moves, and the received pieces are brought to the invoice cost (FOB + charges).
   - Invoice first instead: post it, then "Receive goods…" on the invoice, or tick "Receive the goods now" in its post
     confirmation (off by default): the goods then take the invoice cost at once.
4. The order shows Partially posted, then Posted once its posted invoices cover everything ordered (script 77).
5. Late charges: LCA (later "+ Add charge" on the posted invoice, prompt 38); it adjusts the goods already received.
6. Return: **PRET** from the posted invoice, at most what was received and not returned.

Goods of a supplier without any order: Goods Receipts › "+ New › Without an order" (supplier required, typed cost).
Stock that is not a supplier's (opening balance, correction, found goods) goes through Inventory In.

**C. Sale and payment:** sales invoice (currency, payment type, client address, date tolerance; out-of-stock only if
allowed), then receipt, customer statement and sales profit [Ali – details unknown].

### 3.10 Document types and statuses (codes confirmed in the SQL unless marked)

| Object | Statuses |
|---|---|
| **Purchase documents** (PO, PINV, PRET; `purchase.PurchaseDocuments.Status`) | 1 Draft · 2 Posted (for a PO = approved, shown **Saved** / **Partially posted** / **Posted** from its posted invoices, script 77) · 3 Cancelled · 4 Closed (**no longer used**: script 77 brought every closed order back to 2, settling short what a close by hand gave up) · 5 Waiting for approval (PO only, locked) |
| **Goods receipts** (GRN; `purchase.GoodsReceipts.Status`) | 1 Draft (no stock yet; editable, deletable) · 2 Posted (stock in, number given) · 3 Cancelled (posted only, with a reason; the stock goes back out) |
| **Containers** (`logistics.Containers.Status`) | 1 Draft · 2 Confirmed · 3 In Transit · 4 At Port · 5 Cleared · 6 Offloaded (received: by a posted goods receipt, or by an offload before goods receipts) · 7 Closed · 8 Cancelled (3 inferred, the others confirmed) |
| **Movements** | 1 Planned · 2 In progress · 3 Completed · 4 Cancelled (4 inferred) |
| **Container charges** | 1 Draft · 2 Posted · 3 Cancelled |
| **Emails** (outbox) | Pending · Sent · Failed (at most 5 attempts) |
| **Approval history events** | Sent for approval · Sent again · Reminder sent · Approved (in the app / by email, by whom) · Approved directly · Rejected (with reason) · Withdrawn · Posted without approval · Sent to the supplier · Not sent to the supplier |
| **Invoice line ↔ container** | linked (`ContainerLineId`) / not linked; "Not linked" is only a warning on shipped-in-containers invoices |
| **Transfer orders** (TRO; `inventory.TransferOrders.Status`, script 90) | 1 Draft · 4 Waiting for approval (locked) · 2 Released, **shown** from its counters, the first that applies: Released · Partly dispatched · Dispatched · Partly received · Closed · Received · 3 Cancelled. "Nothing more will be sent" is a stamp, not a status. The API's names: `Draft`, `PendingApproval`, `Released`, `PartlyDispatched`, `Dispatched`, `PartlyReceived`, `Received`, `Closed`, `Cancelled` |
| **Transfer dispatches and receipts** (TRD, TRR; `inventory.TransferPostings.Status`) | 2 Posted · 3 Reversed. No draft: the dialogs post directly |

Numbers: `PO-BR-002-000042`, `PINV-BR-003-000011`, `PRET-…`, `GRN-BR-002-000001`, `KTG-2026-0031` (CNT),
`MOV-2026-000046`, `TRO-BR-003-000012`, `TRD-BR-003-000004`, `TRR-BR-002-000007`. LCA numbers and sales numbers
**(check DocumentTypes)**.

---
## 4. Business rules

Marks: **[Implemented]** built and verified · **[Decided – prompt NN]** written, not run yet as far as I know ·
**[Ali – details unknown]** · **(unsure)** / **(check the code)**.

### 4.1 Numbering
- Numbers are defined per document type in **Configuration › Document Types** (`inventory.DocumentTypes`:
  NumberPrefix, NumberPerBranch, YearInNumber, NumberLength, NumberOnPost). **[Implemented]**
- **Purchase documents** are numbered prefix + branch code + sequence: `PO-BR-002-000042`, `PINV-BR-003-000011`,
  `PRET-…` (exact PRET pattern **unsure**). The number is assigned **when the document is posted** (for a PO: when it
  is approved / posted). Drafts have no number ("Assigned on posting"). **[Implemented]**
- **Goods receipts:** `GRN-BR-002-000001` (type GRN: prefix GRN-, branch code, 6 digits), given **at posting**; a
  draft shows "Assigned on posting". Posting is refused while the GRN type is inactive (63010). An automatic draft
  needs no number, so it is still created. **[Implemented – scripts 64, 65]**
- **Containers:** `KTG-2026-0031` (type CNT: prefix KTG, year, 4 digits). **[Implemented]**
  - **A number never gets cut** (script 78): once a sequence has more digits than the type's length it keeps them all
    (container 10,000 of a year is `KTG-2026-10000`, not a duplicate `KTG-2026-0000` that refused every container
    after it). This holds for every document type (`inventory.usp_DocumentType_NextNumber`); CNT keeps its length 4,
    so the refs given so far read the same. **[Implemented – script 78]**
  - The container **number** (box no.) must be unique among open containers (69013). **[Implemented]**
  - Before goods receipts, a second offload of the same container got its own stock-ledger number,
    `KTG-2026-0031/2`. Now a container received again (after its goods receipt was cancelled) gets a new goods
    receipt and its own GRN number. **[Implemented]**
- **Movements:** `MOV-2026-000046` (prefix MOV-, year, 6 digits, not per branch). The number is assigned **at the
  first save**. **[Implemented]**
- **Transfers** (script 90), per branch, the prefix TRO- / TRD- / TRR-, the length and the year segment Inventory Out's
  when the types were made: **[Implemented – script 90]**
  - the order `TRO-BR-003-000012` **at its first save**, by From's branch then (it keeps that number when From changes
    on the draft); when the TRO type's Number on post is turned on, at Release (or Approve) instead ("Assigned on
    release");
  - a dispatch `TRD-BR-003-000004` **at posting**, by the source branch;
  - a transfer receipt `TRR-BR-002-000007` **at posting**, by the destination branch, as a goods receipt is numbered by
    the branch that receives;
  - a deleted draft leaves a gap; a refused Dispatch and receive takes no number (both postings or neither).
- **SQL scripts:** `Database/NN_Module_Description.sql`, next free number. **Prompts:** `docs/prompts/NN-title.md`,
  a separate numbering ("prompt 42" is not "script 42"). Before numbering a new script, pull first: Ali writes scripts
  too. **[Convention]**

### 4.2 Purchase orders and supplier invoices
- **PO statuses:** Draft → (Waiting for approval) → approved → Cancelled. Posting a PO = approving it (when approval
  applies). An approved order **shows how far its posted invoices cover it** (the owner's words): **Saved** (none),
  **Partially posted** (the invoiced pieces are fewer than the ordered ones), **Posted** (equal; each line is capped at
  what it ordered). **[Implemented – script 77]**
  - Draft invoices do not count; cancelling a posted invoice brings the order back to Partially posted or Saved.
  - Purchase returns do not lower it (they never touched the order's counters): an order whose goods went back
    partly still shows Posted.
  - Goods receipts never change it: a Posted order may still have goods to receive.
  - **There is no Closed any more.** Close Order is gone (the procedure refuses with 65010 "Purchase orders are no
    longer closed: …"), and neither an invoice nor a goods receipt closes an order. Pieces that will never come are
    settled with "Nothing more will come" when receiving. The orders closed before (by themselves or by hand) went
    back to approved at script 77, with "Closed status removed (was: …)" in their history; on an order closed by hand
    the pieces the close gave up were settled short, so what it still expects (Shortages, On order, To receive) did
    not change. Those pieces are also kept apart (`ClosedShortBase` on the order line): unlike other pieces settled
    short they cannot be received if they turn up, nor loaded into containers again, while they are not invoiced.
    They can still be invoiced, like any piece settled short (the supplier claim covers what never arrives); once
    invoiced they are received like any invoiced piece.
  - The order's history says "Fully invoiced by PINV-…" when an invoice completes it.
  - Before script 77 the PO auto-closed (4) when fully invoiced and received ("Fully invoiced and received"; before
    goods receipts: when fully invoiced), or was closed by hand.
- **An invoice made from a PO** takes the PO's supplier and branch; each line may take at most what remains on its
  source line. **[Implemented]**
  - **Line by line** (script 86, the owner: "this is when creating purchase invoice from container, the same way must
    be when creating the purchase invoice from purchase order"): "Create Purchase Invoice" (the order page and the order
    list's row action) shows the Document Date, the Exporter's ref. and the Commercial invoice no. ("copied to every
    invoice"), then the order's lines still to invoice - #, Item, Warehouse, Ordered, Invoiced (posted invoices), In
    drafts (draft invoices made from the line, from the order or its containers), Available = ordered − invoiced − in
    drafts - each ticked with its available quantity in pcs, which may be lowered ("Max 60" above it, Create disabled)
    or unticked; then "One invoice per item" and its line ("One invoice per item: 2 invoices will be created (TEST86-A,
    TEST86-B)" / "One invoice with 2 items"). Lines with nothing available are left out; none left: "Everything ordered
    is already invoiced." or "The rest of this order is already in draft invoices: post or delete them first."
    (`purchase.usp_PurchaseOrder_InvoiceCandidates`, `GET api/purchase/documents/{id}/invoice-candidates`; Create sends
    the ticked lines as `lines`, which `usp_PurchaseDocument_CreateFromSource` already took as its selection - more than
    a line has is refused 65011 "Line 2: 61 base units selected but only 60 are still available (the rest is in posted
    or draft documents)."). **[Implemented – script 86]**
- **One item per supplier invoice:** **[Implemented – prompt 37, script 45]**
  - A PINV holds one item. It may have several lines of that item (several containers, warehouses or expiry dates),
    never two different items. Purchase orders and returns are not concerned; posted invoices are unchanged.
  - Create Invoice, Create Invoice from Containers and the Excel import create **one draft per item**. The exporter's
    reference and commercial invoice no. typed once are copied to every invoice.
  - Saving or posting a one-item PINV with two items is refused (65029): "A supplier invoice holds one item. This one
    has {n}: … Create one invoice per item, or use Split by item."
  - Older drafts: **Split by item**. Several drafts of an order: **Post selected**.
  - The invoice list shows the item (or "3 items" for an invoice of several items).
  - **Optional:** the setting "One item per supplier invoice" (Configuration › Settings › General,
    `Purchase.OneItemPerInvoice`, on by default) decides; each PINV keeps the mode it was created with (`OneItemOnly`:
    one item, with the 65029 refusal, or several items; invoices made before follow the setting), and the Create Invoice
    dialogs have a switch "One invoice per item" (off = one invoice with every item). **[Implemented – script 63]**
- **Imported invoices** (from containers / shipped in containers): **[Implemented]**
  - The **Exporter's Ref.** is required to post (65018).
  - They have **no charges of their own** (65020) and **no LCA** (67012; since script 65 also refused on any
    "Shipped in containers" invoice, linked or not). Their charges belong to the containers and are shown read-only.
- **Invoice first, containers after:** a PI can be created directly from an order that has containers. Prompt 32 had
  refused this (65021); prompt 41 removed the refusal. **[Implemented – script 43]**
- **"Shipped in containers"** (receipt mode 2): **[Implemented – script 43]**
  - Ticked by default when the order has containers, always for a PI made from containers.
  - Its goods travel in containers and are received with their containers' goods receipts. (Before goods receipts:
    posting put no goods in stock and the container offload did. Since the switch no invoice puts goods in stock.)
  - It cannot be unticked while a line is linked (65026).
- **Link / Unlink containers on a PI:** **[Implemented – script 43]**
  - Allowed on a draft or posted PI (the amounts don't change).
  - Only containers in Draft or Confirmed (65027), never a line already received.
  - Linking splits the PI line per container line; unlinking merges it back.
  - A PI not created from a PO cannot have containers. A container line can never be invoiced twice.
- **Add container / Auto-plan from the PI:** creates containers on the PI's order, linked at once, holding the PI's
  item only. Mixed containers are planned on the order. **[Implemented – script 43]**
- **The PI's Containers card always explains itself:** **[Implemented – script 51, prompt 44]**
  - Shown on every PI.
  - Disabled buttons give the reason, for example "Every piece of this invoice is already in a container." or "This
    invoice was posted without 'Shipped in containers': its goods are already in stock." (since goods receipts: "…its
    goods are received with Receive goods…, not with containers.").
  - A draft with the switch off gets "Turn on 'Shipped in containers'".
  - Quantity ≤ min(pieces not in a container, what the order lines still allow); the order must be approved (no
    order is closed since script 77).
  - No orange "Not linked" on invoices not shipped in containers.
- **"+ Add charge" on an invoice in every status:** **[Implemented – prompt 38]** (`PostedInvoiceChargesCard`,
  `InvoiceContainerChargesCard`)
  - **Local draft:** the invoice's own charges, as before.
  - **Local posted:** a late charge in a draft adjustment. "Post late charges" adjusts the cost (stock on hand →
    average cost; already sold → COGS); it is stored as the invoice's LCA.
  - **Imported (draft or posted):** the container charge dialog, with the invoice's containers preselected.
- **Purchase returns:** PRET from a posted PINV. **[Implemented]** Other detailed rules **(unsure)**.
  - From an invoice that uses goods receipts, or an older "Shipped in containers" one: at most received − returned
    (65011: "Line {n}: {item} - {q} base units returned but only {x} were received and not returned on the invoice
    line."), at the invoice line's current cost, from the warehouse the goods were received into.
    **[Implemented – script 65]**
  - Goods received but not invoiced cannot be returned with a PRET: receive fewer, cancel the goods receipt, or use
    Inventory Out.
  - Older local invoices keep the limit invoiced − returned.
- **Discounts:** "Disc %" per purchase line. **[Implemented]** Sales discounts **[Ali – details unknown]**.
- **"The request field is required." on PINV / PRET save** (prompt 35): gone. The API no longer adds an implicit
  [Required] to non-nullable properties (`Program.cs`, `SuppressImplicitRequiredAttributeForNonNullableReferenceTypes`),
  so a body that cannot be read gets only its real error. **[Implemented – prompt 35]**
- **One purchase-order page wherever it is opened from:** **[Implemented – prompt 39]**
  (`src/components/purchase/orderAbilities.ts`)
  - The page decides from the order itself, never from the route.
  - The Containers card is on every PO.
  - Buttons are visible but disabled with a tooltip:
    - Draft: "Approve the order first: containers are created from an approved order."
    - Waiting: "This order is waiting for approval."
    - "This order is cancelled."
  - Buttons are hidden only without the permission.

### 4.3 Purchase order approval **[Implemented – script 42 + prompt 36, unless marked]**

**Who approves and when**
1. **Approvers are chosen per user** in Settings › Purchase approval: "In the app", "By email" (needs an email
   address), or both. The role permission `purchase.orders.approve` no longer has any effect (shown "(not used)").
2. **When approval is needed:** an order needs approval when "Purchase orders need approval before they are posted"
   is on **and** its total in base currency is above "Orders up to this amount are posted without approval" (0 = every
   order). Otherwise the normal Post posts it ("Posted without approval" in its history).
3. **Rights are checked in SQL** at the moment of the decision, whatever the channel.
4. **Self-approval:** "The person who sends an order may approve it" (default on). When off, the creator and the
   requester can neither approve (65023) nor receive the request.
5. **Approve & post / Create & approve:** an in-app approver approves his own draft or new order at once, when rule 4
   allows it ("Approved directly"). No request is sent.

**Links, reminders and actions**

6. **Approval links:** personal, single use, valid N hours (default 72, range 1–720).
   - One decision closes every link of the order; the other links then say who decided.
   - **Opening a link never decides**: mail scanners open links automatically, so the decision is one click on
     `/purchase-approval/:token`.
7. **Reminders** every N hours (default 24, 0 = never, max 168), each with new links; older links work until they
   expire.
8. **Withdraw** (back to draft) and **Send again** (new links).

**After the decision**

9. **After approval:**
   - The supplier gets the order by email with `PO-{number}.xlsx` ("Email the approved order to the supplier",
     default on).
   - Copies go to the Owner role ("Send a copy to the Owner role") and to "Also send a copy to" addresses.
   - The requester is told.
   - Without a supplier address the order shows "Not sent to the supplier: no email address. Add it to the supplier,
     then use Send to supplier."
10. **After rejection:** the requester is told and the draft shows a red alert "Rejected by {name} on {date}:
    {reason}".
11. **In-app approvers by email:** "Tell the in-app approvers by email (with a link to the order)". They get
    "Approval needed in the application: purchase order for {supplier} - {total} {currency}".

**Error numbers**

12. **Errors:**
    - 65004 changed by another user
    - 65013 needs approval
    - 65014 link not usable (says why)
    - 65015 nobody can approve
    - 65016 supplier has no email
    - 65017 not allowed
    - 65022 approval not needed
    - 65023 self-approval refused
    - 65024 approval settings
    - 65025 email settings

**Follow-ups** **[Implemented – script 44, prompt 42]**
- 65016 only while "Email the approved order to the supplier" is on.
- The withdraw reason is stored and shown in the history.
- Create-and-approve returns the same warnings as approve-now.
- Every `*Utc` timestamp leaves the API with "Z"; dates without time are unchanged. The web formats a "Z" time in
  local time once, without double corrections.
- The ~40 Pending test emails of the first tests were to be marked failed ("Test email - not sent"): a one-off
  clean-up of a local Email log, in no script (nothing to do on the servers).
- Approve on the order page asks "Approve this order? It will be posted and sent to the supplier."

### 4.4 Email **[Implemented – prompt 36]**
- **One sender mailbox** for the whole application (Settings › Email):
  - From address, From name "Katanga TVS - Purchasing", Reply-to.
  - Provider presets: Gmail = smtp.gmail.com 587 STARTTLS; Microsoft 365 = smtp.office365.com 587 STARTTLS; Other.
  - User name and password. The password is encrypted with ASP.NET Core Data Protection (keys in `App_Data/keys`,
    never committed), never returned, never logged.
  - The configured mailbox is a Gmail account created for the system, **inventory.shipment.2026@gmail.com**. Gmail
    needs an **app password** (2-Step Verification on) with the Gmail address as user name. Changing that Google
    account's password cancels the app password.
- **Every email is sent FROM this mailbox.** Suppliers and approvers only receive. Replies and bounces come back to
  it (or to Reply-to).
- **"Send emails" switch:**
  - Off: emails stay **Pending** in the Email log.
  - On: the outbox worker sends every 30 s, up to 10 at a time, at most 5 attempts, then **Failed** with a readable
    error.
  - The **Send test email** button sends one email at once, with the values on the screen, even while sending is off.
- **Links in emails** use "Address of the application", else `App:PublicBaseUrl` in appsettings. With
  `http://localhost:5174` they only open on the PC running the app; production needs the server's real address.
- **Emails and recipients:**
  - "Approval needed: …" (by-email approvers; buttons "Review and approve" / "Reject…").
  - "Approval needed in the application: …" (in-app approvers).
  - "Reminder: …".
  - "Purchase order {number} - Katanga TVS Motor Company" to the supplier, with `PO-{number}.xlsx`, plus copies.
  - "Approved: purchase order {number} for {supplier}" / "Rejected: purchase order for {supplier}" to the requester.
  - Test.

### 4.5 Containers **[Implemented unless marked]**
- **Creation:** only from an **approved** PO (status 2): "The purchase order must be approved and still open."
  ("still open" is older than script 77: no order closes now; the same words in
  `usp_PurchaseDocument_CreateFromContainers` S:53667 and `usp_PurchaseDocument_ValidateInput` S:61855)
  Lines of other approved POs, from other suppliers too, can be added.
- **Quantities** are in pieces. Loadable per PO line = ordered − the larger of invoiced and received outside
  containers − loaded in other containers (69008). **[Implemented – script 65]**
- **Status** only moves forward with movements. Two exceptions on purpose: cancelling the goods receipt (or an old
  offload) returns the movement status; Reopen returns Closed → Offloaded.
- **Free days:** last free day = actual port arrival + free days; a red "free time over" badge after it if the
  container is not received. The count stops at the end of its Delivery.
- **Receiving: a goods receipt** (see 4.12). **[Implemented – scripts 64, 65]**
  - Any container from Confirmed to Cleared (2–5) with no open receipt; the goods need not be invoiced (69016 no longer
    applies here). Posting is refused while a movement of the container is in progress.
  - Received ≤ loaded; a **reason is required** when they differ, and the difference is settled short.
  - Effects of posting: landed cost = FOB + posted charges ÷ pieces received; charges re-divided over what arrived and
    frozen; average, last and FOB costs updated; status **Offloaded** (the name stays); location = the warehouse.
  - **The Offload is retired** (69010): "Containers are received with a goods receipt now. Use Receive goods… on the
    container."
- **Cancel Offload** stays for containers offloaded before goods receipts (refused after a cost adjustment, 69018, or
  when the stock brought is gone: "Cannot reverse: … has only N left, but this container brought M."). On a container
  received by a goods receipt it refuses (69010): "…cancel that goods receipt instead."
- **Close** when every charge is posted and every received piece is invoiced by posted invoices (69016: "Line {n}
  ({item}): {r} received but {i} invoiced by posted invoices. Post the supplier invoices before closing the
  container."); **Reopen** for a late charge.
- **Delete** drafts only; cancel the others with a reason. An invoiced container's invoices must be cancelled or
  deleted first.
- **A container with a goods receipt** (draft or posted) cannot have its lines or branch changed, nor be cancelled or
  deleted (69019: "Container KTG-… has {goods receipt GRN-… | a draft goods receipt}. Delete the draft (or cancel the
  receipt) first."). Its header (truck, waybill, declaration, FERI, B/L, free days, notes, warehouse) stays editable until the
  receipt is posted; a warehouse changed then does not change the draft. **[Implemented – script 65]**
- **Invoicing a received container** is allowed: "Create Invoice from Containers…" also lists containers received by a
  goods receipt. 65019 still refuses a cancelled container, one offloaded before goods receipts, and more than the
  loaded quantity. **[Implemented – script 65]**
- **Auto-plan:** **[Implemented – script 28]**
  - Every order line first fills whole containers of its own item.
  - The rest is packed without cutting a line (first fit, largest first), unless cutting lines needs fewer containers
    (then fill to the brim).
  - "Mix the rest" on/off. **Any number of containers** (script 78; at most 200 before, refused in the proposal
    itself). All or nothing ("Container 3 of 30: …"). Optionally "Confirm the containers after creating them".
  - Measured in the sandbox: proposing 2,000 containers under 1 s, 5,000 in 3.7 s; creating 3,000 / 5,000 / 10,000
    (confirmed) 5.5 / 9.5 / 18 s on a database of up to 50,000 containers (each container of a plan is no longer
    re-checked against the order lines, and the container numbers are taken at the end of the plan, so another
    user's Add Container no longer waits on the numbering); through the API 1,201 containers in 4.3 s, and 2,205 from
    an invoice (created, confirmed and linked) in about 30 s. A plan is one transaction: while it runs, pages that
    read containers (the Containers list, another order's containers) wait for it, about 2 s per 1,000 containers. The pages draw long lists 200 rows at a time ("Show more"): a draft invoice of 2,205 lines opens in
    under 7 s. The API gives the batch calls (plan, create, invoices from containers and their posting, Link, Confirm,
    numbers, Delete, Start shipment, movements, the goods receipts of a Delivery) a timeout of 10 minutes of their own
    (`Database:BatchCommandTimeoutSeconds`), above the ordinary 90 s. **[Implemented – script 78]**
- **The supplier is automatic in Auto-plan and Add Container** (script 78, the owner's words: "in the auto-plan for
  containers the supplier must be automatic"): **[Implemented – script 78]**
  - The dialogs show "Supplier: SUP-0001 - TVS Motor Company (from the order)", read-only: a container's goods come
    from its order lines, so its supplier was never typed (containers have no supplier column).
  - **Forwarder** (the company that ships the containers, a Supplier party) starts as the forwarder of the order's most
    recent container that has an active one, else **the order's supplier**; it stays editable and clearable, and is
    searched on the server as it is typed (it listed the first 50 suppliers only).
  - **Country of origin** starts as the supplier's country (`masterdata.Parties.Country`, e.g. IN for TVS).
  - Add Container… got the same Forwarder and Country fields (it always sent no forwarder).
- **Lists of any number of containers** (script 78): the order's Containers card, a movement's containers and its
  candidates hold every container (one page of 200 before), so their bulk actions reach all of them; "Apply to other
  containers…" lists every candidate (500 before); the container pickers (New charge, Container Charges, the Containers
  page's order and invoice filters) search the server; a movement's document goes to any number of containers (the
  form limit of 1,024 values is raised); the container charges import takes 5,000 rows (500); an invoice's container
  list in Supplier Payments reads "KTG-2026-0001, KTG-2026-0002, KTG-2026-0003 +1996 more" (it failed with SQL error
  9829 from about 267 containers, as Link containers did from about 190). **[Implemented – script 78]**
- **Bulk actions:** Confirm, Container numbers (paste list), Start shipment, Add charge, Delete drafts.
  **[Implemented – script 28]**
- **Capacity:** **[Implemented – script 54, prompt 46]**
  - **One source: the item's Container unit.** (Before script 54: typed in the Auto-plan dialog, else the item's
    Container unit, else the container type's Max Units.)
  - Over capacity = warning 69007, confirmable with "Load Above Capacity".
  - Fill % = Σ quantity ÷ pieces per container. A 40HC with 84 motorcycles of an 84-piece item = 100% (it showed
    70% before).
  - An item without a Container unit: fill unknown ("—", with a link to set it), no warning, Auto-plan refuses it.
  - Max Units is gone from Container Types and every container form (the database column and the procedures'
    parameters stay, unread). Max Weight and Max Volume stay.
  - The over-capacity message names the item: "This container would be 112 % full: 94 pcs of TEST38-A (84 per
    container)."

### 4.6 Movements **[Implemented unless marked]**
- **Lifecycle:** Planned → In progress (Start) → Completed (Complete); Cancelled with a reason. One movement carries
  one or more containers.
- **One movement at a time:** a container cannot travel with two movements in progress (70012): "Container … is
  already travelling with movement MOV-… Complete it first."
- **Delivery and goods receipts:** **[Implemented – scripts 64, 65]**
  - Completing a movement whose type has the **Delivery** stage creates a draft goods receipt for each eligible
    container (Confirmed to Cleared, no draft or posted receipt), dated the movement's end date. The drafts are made
    after the completion is saved: **completing never fails because of them**; a container left out is reported.
  - The Complete dialog lists what will happen per container; the notification after it says, for example: "Draft
    goods receipts created: KTG-2026-0031, KTG-2026-0032 (warehouse to choose). Not created: KTG-2026-0033 already has
    GRN-BR-002-000004."
  - **Cancelling a completed Delivery** deletes the automatic drafts it created (the dialog names the ones edited
    since; a draft made by hand is kept). A posted receipt makes the container Offloaded, and its route can no longer
    change.
- **Start shipment:** **[Implemented – script 28]**
  - Default SEA, from the containers' common port of loading to their common port of destination; the user chooses
    when they differ.
  - Drafts are confirmed first. It starts today unless "Plan only".
  - Vessel, voyage, shipping line, B/L and ETA are copied to the containers; ports only when empty.
- **Ship from the container** **[Implemented – script 80, shipment phase 1]** (the owner: "I cannot start the shipment
  of a specific container in the containers page or any other place"):
  - **One button per container**, next to Save on its page and first in its row's "…" menu on the Containers list,
    labelled by its next step: "Start shipment…" (never moved: the Start shipment dialog for it alone), "Start Inland
    transport…" (its next planned movement waits: that movement's Start dialog), "Arrived at Dar es Salaam…" /
    "Complete Customs clearance…" (a movement in progress carries it: its Complete dialog), "Next leg…" (its last
    movement is completed: the movement form). Hidden without `containers.movements.manage`; disabled with the reason
    on a received, closed or cancelled container ("This container is received: its journey is over."), on a draft
    with a planned movement, or when the planned movement cannot start yet (the refusal Start would give).
  - **A leg leaves from where the container is**: the To of its latest movement, else its port of loading. The Start
    shipment dialog and the movement form opened from a container fill the From with it and lock it ("A container
    leaves from where it is."); Loading at the supplier is the exception (its To is the port of loading). A stay
    (Port, Customs, Border) takes To = From by default. Places are grouped Sea ports / Border posts / Inland places.
  - **A movement carrying other containers says so**: the Complete dialog opened from one container reads "All 12
    containers of MOV-2026-000046 arrive too: …". Completing it moves every container on it.
  - **Planned movements are visible**: the Movement column of the Containers list shows "Planned: MOV-…" under the
    current one; the route card (now at the top of the right column, the top of the page on a phone) says where the
    container is ("At Dar es Salaam since 12/10/2026.") and its planned next movement.
  - **"Start shipment…" in the selection bar** is disabled when none of the ticked containers can ship ("None of the
    ticked containers can ship: KTG-… is travelling with MOV-…: complete it first."), and its dialog lists those it
    leaves out (received, travelling, a next movement already planned, a draft the reader may not confirm, at another
    place) instead of failing after the click. With an empty From, the server takes the place the containers are all
    at; the "empty = the containers' ports" default is kept for containers that never moved.
  - **"Add to a movement…"** lists only the planned movements the container can really join: created after its
    latest movement and at its place (`usp_Movement_JoinCandidates`).
  - **Dates are facts** (the owner's decision): a start or end date in the future is refused, in the dialogs and on
    the server (70000, "The start date cannot be in the future: start the movement on the day it really leaves.");
    a start before the previous leg of one of its containers ended is refused (70018): "Container KTG-2026-0031
    cannot start MOV-2026-000051 before MOV-2026-000046 reached Dar es Salaam on 12/10/2026." Both rules hold too for
    the start date of a movement in progress changed on the movement page and saved.
  - **Legs follow the travel order**: a container that already travelled with a later movement (in progress or
    completed) cannot be added to, saved on or started with an older planned movement (70015, "Already travelled
    further with MOV-2026-000005 (Dar es Salaam → Kasumbalesa), a later movement: take it off this one."), and such an
    older movement is never its next step. A later movement that is only planned stays allowed (planning ahead).
  - **Every completion still goes through the API's Complete**, so a Delivery still drafts the goods receipts (or not,
    when Document Types makes them by hand).
  - Not yet: route master data (the owner's choice: suggestions stay history and stages). The Shipments board and the
    split came with script 82 (below).
- **Next step everywhere** **[Implemented – script 81, shipment phase 2]** (the owner: "make shipment more user friendly
  and flexible"):
  - **One button, one dialog**: the container's next step opens the same dialog from its page, its row's "…" menu
    ("Next step: Inland transport to Kasumbalesa…") and the selection bar for one container. Its label follows the step:
    "Start shipment…" (never moved), "Start {type}…" (a planned leg), by the stage of a leg in progress "Arrived at
    {To}…" (Sea, Transit), "Cleared customs at {place}…", "Crossed the border at {place}…", "Left the port of
    {place}…", "Loaded at the supplier…", "Delivered to {To}…", and once a leg is completed the proposed one "{Type} to
    {To}…" / "{Type} at {place}…" / "Next leg from {place}…"; delivered: "Receive goods…" / "Open goods receipt
    (draft)" (unchanged rules); received, closed or cancelled: disabled with the reason ("Received into {warehouse}: the
    journey is over.", "This container is cancelled."). Hidden without `containers.movements.manage`.
  - **The proposal** (`logistics.fn_Container_NextLegProposal`, `fn_Movement_NextLegHistory`, worked out once per place
    and last stage): the usual next leg from the place (last 365 days, seen at least twice; a voyage split in two counts
    once, script 82), else the container's own ports, else the stage order; never a leg Save or Start would refuse. The
    dialog says where it came from: "Suggested: the usual next leg from Dar es Salaam (5 earlier legs)", "Suggested from
    the container's ports", "Suggested from the stages", "Choose the To".
  - **The new-leg dialog**: "Now at Dar es Salaam since 12/10/2026 (end of MOV-2026-000046)." / "Not moved yet: leaves
    from its port of loading Chennai."; type grouped by stage (changing it proposes the To again); From locked; no To
    for a stay ("at Kasumbalesa"); "Start now" / "Plan only"; the date not before the previous leg ended, not in the
    future; the sea details prefilled from the container and copied back ("Copy vessel, voyage, B/L and ETA to the
    container"); alerts for a draft (confirmed first, only planned by a reader who may not confirm), no container number
    and typed dates ("The dispatch and arrival dates typed on this container will be replaced by the movements' dates.").
  - **The arrival dialog**: "MOV-2026-000046 Sea freight: Chennai → Dar es Salaam, started 20/09/2026, ETA
    12/10/2026."; the date named by the stage ("Arrival date", "Clearance date", "Crossing date", "Departure date",
    "Delivery date"); "All 12 containers of MOV-… arrive too: …" (no split in phase 2); the **Then leg** (glossary);
    "Record arrival" / "Record clearance" / "Record crossing" / "Record departure" / "Record delivery" / "Record
    loading"; a Delivery shows its draft goods receipts and "Then open the draft goods receipt". The notification is the
    server's: "KTG-2026-0031: arrived at Dar es Salaam on 17/10/2026 (MOV-2026-000046). Now At Port."
  - **Many containers** ("Next step…" in the selection bar, `logistics.usp_Container_NextStepPreview`): "Next step - 300
    containers", one row per group (same step, movement, type, From and To) with its count, orders and suppliers, for a
    new leg "One movement for the group" / "One per container" (default one per container for road legs: Transit,
    Border, Customs, Delivery - "each truck arrives on its own day", "each container is cleared on its own day") and "Edit…" (type, To, carrier, vehicle / vessel,
    voyage, B/L, ETA, notes, a truck no. and ETA per container); a Complete of only part of a movement says the others
    arrive too; one date for every group; "Cannot move on" by reason ("Received, closed or cancelled (12)", "Draft - you
    may not confirm containers (3)", "A draft goods receipt waits: Open goods receipt (draft) (2)"; a missing proposal
    is never a reason: the group's type is chosen with Edit…); a group says how many have no container number ("the
    shipment can start without it"); "Apply to 285 containers (4 steps)". Each group runs alone and is all or nothing
    inside; a group of one movement per container goes in parts of 50 ("Moving on: 150 of 300"). The results name the
    MOV numbers made, refused groups stay ticked.
  - **The to-do list**: the Containers list's Next step column and filter, worked out on the server: "Start shipment",
    "Start planned leg", "Arrival due", "Next leg to plan", "Receive goods".
  - **On a phone** the step is repeated in the Route card at the top of the container's page (the action bar is at its
    bottom).
  - **The movement page** offers "Continue: Next step…" after a Complete (not a Delivery) for its containers.
  - **Only the last leg is cancelled** (`usp_Movement_SetStatus`, 70010): "MOV-… is not the last leg of KTG-…: cancel
    MOV-… first." Cancelling an older leg silently broke the chain of places. A planned leg that a later leg already
    passed (started or completed after it, data of before script 80) never happened and may be cancelled. (Script 82:
    cancelling a movement split off another undoes the split, below. Script 83: the movement page disables "Cancel…"
    with this reason before the click, below.)
  - **No port of loading**: a container that never moved and has none leaves from any From (prompt 45): its dialog asks
    for the From ("Not moved yet, and no port of loading: choose where it leaves from."); the bulk dialog lists it under
    "No port of loading: open the container to choose where it leaves from".
  - **Applying never goes around a movement** (`POST api/logistics/containers/next-step`): a Complete or a Start is the
    movement's own (a Delivery still drafts its goods receipts after the commit, script 79's switch included), a new
    leg is saved and started with the movement procedures (`logistics.usp_Movement_AddLeg`), so 70012, 70015, 70016,
    70018 and the future-date rule hold. The step is checked again first: a dialog left open while someone else moved
    the containers gets "…: open Next step… again." (a new leg too when they are at another place now: "KTG-… is now at
    Kasumbalesa: open Next step… again."), and a vessel or truck leg from a place to itself is refused (70000, "The
    departure and destination are the same place: choose the To."). The Tracking board has no row menu, so no entry
    there: its rows open the container. (The order's and the invoice's Containers cards got their row menu with script
    82, below.)
- **Shipments board and partial arrival** **[Implemented – script 82, shipment phase 3]** (the owner: "make shipment
  more user friendly and flexible"):
  - **The board** (`logistics.usp_Shipment_Board`, `GET api/logistics/shipments/board`, `containers.shipments.view`):
    every container from Draft to Cleared, and with "Show received (30 days)" the ones received since; never a
    cancelled one. Its column is decided in one place (`logistics.fn_Container_BoardPhase`) from the ship state of its
    next step: a leg in progress first (Origin → At supplier; Sea, or a transshipment between two sea ports → At sea;
    Port → At port; Customs → At border / customs; any other → On the road), then a draft goods receipt (Delivered),
    then its last completed leg (none → At supplier; a Delivery → Delivered; ending at a sea port → At port; else At
    border / customs). A container **followed by typed dates** (no leg started or completed, 3.5 item 11) stands where
    its status puts it: In Transit → At sea, in a group of its own "Followed by typed dates"; At Port → At port, at its
    port of destination; Cleared → At border / customs ("Cleared"), at its port of destination, else its final
    destination (where its Current location says it is); its card reads "Followed by typed dates" instead of "Not moved
    yet", and its next step stays phase 2's "Start shipment…" (Sea freight from its port of loading, with the alert that
    the movements' dates will replace the typed ones; Receive goods… stays on its page, 4.12 rule 6). Groups: At sea by
    movement ("MOV-2026-000046 · MSC Aurora V.123 · Chennai → Dar es Salaam · ETA 20/10/2026", the movement number a
    link), On the road by leg ("Dar es Salaam → Kasumbalesa"; "Border crossing at Kasumbalesa"), the others by place
    ("No port of loading" last), Received by warehouse. Each card has its next step and proposed leg in the words
    of phase 2, "Late" (the leg's ETA has passed), "Free time over" (the container page's rule), the planned next leg.
    Filters on the server: search (ref, container no., B/L, vessel or truck, order number), supplier, order, branch,
    place (where it stands, or its leg's From or To), late only, with a planned leg. No paging. Measured: 5,000 open
    containers in a database of 50,000 in about 1.6 s (1.0–1.2 s when the received journeys spread over five years);
    two thirds of it is the usual next leg of phase 2 (`fn_Movement_NextLegHistory`, once per place and last stage,
    which counts a voyage split in two once: `logistics.fn_Movement_Voyage`).
    The answer carries only what the page reads, without its empty fields: 3.6 MB of JSON for 5,000 cards (11.9 MB
    before, 45% of it nulls; 0.06 MB compressed instead of 0.16 MB).
  - **The page**: each column says its containers and pieces and has "Select all (n)"; each group folds and has its own
    "Select all" (one tick takes a whole ship); a card shows its ref and container no., type, items ("84 pcs
    TVS-APACHE-160"), supplier and order, where it is (the leg and its ETA, the stay, since when), the badges (Late,
    Free time over, Draft, No container no., Cleared, GRN draft) and "Next step: …" - phase 2's dialog, offered to a
    reader who may also view containers (the dialogs read the container and the movement types: without View Containers
    the card, the List and the drawer leave the step out, and the selection bar's "Next step…" says "Next step… needs
    the View Containers permission."). Clicking a card opens a drawer with its route, its next step and "Open
    container"; every movement link from the board keeps the way back (`?from=shipments`). The ticked cards go into the
    Containers list's own selection bar ("Next step…", "Container numbers…", "Add charge…"), kept across the reloads. 50
    cards a column, then "Show 50 more"; "Board" / "List" shows the same rows as one table for hundreds; a phone shows
    one column at a time from a row of tabs with the counts. The board reads itself again after every action, with
    Refresh, and a minute after its last answer while the tab is visible and no dialog is open. No drag-and-drop: every
    move is a movement with its dates, through Next step.
  - **Where to split**: a container's Next step dialog asks "Which containers?" when its movement carries others ("All
    12 containers of MOV-2026-000046" by default, or "Only KTG-2026-0031: it leaves MOV-2026-000046 and gets its own
    movement"); the bulk dialog offers "Complete MOV-… for all its 30 containers" / "Only the 20 ticked (they get their
    own movement)"; the movement page's Complete has "Only some containers arrived" with a checklist of its containers,
    each that cannot leave said why. The new movement shows "Split from MOV-…" and both movements' history the split.
  - **Row menus**: each container row of the order's and the invoice's Containers cards has a "…" menu with "Next step:
    {label}" (phase 2's dialog) and "Open container".
  - **Only part of a movement arrived** (`logistics.usp_Movement_SplitContainers`; `splitOff` on a Complete group of
    `POST api/logistics/containers/next-step`; `POST api/logistics/movements/{id}/complete-some` for the movement
    page): see the glossary "Split". The completion is the movement's own Complete (`MovementService.SetStatusAsync`):
    a Delivery drafts goods receipts for the split-off containers only (none with the GRN switch off), and the Then leg
    works as after any arrival. The date is checked first, with Complete's own rule and words (one day of tolerance
    for the reader's time zone, never before the start), so a refused date splits nothing. Refusals, nothing changed:
    70010 "Only a movement in progress can be split: MOV-2026-000046 is completed.", "Every container of
    MOV-2026-000046 is ticked: complete the movement itself.", "KTG-2026-0031 already has the next leg MOV-2026-000051
    planned: complete MOV-2026-000046 for every container, or take it off MOV-2026-000051 first (it then gets a leg of
    its own once it has arrived)." - the place rule stays as it is: the split-off movement comes after that planned leg
    in the travel order, so a container taken off it and split cannot rejoin it and travels on with a new leg of its own
    (its Next step proposes it); 70000 "KTG-2026-0031 is not on MOV-2026-000046.", "Tick the containers that
    arrived."; 70004 changed by another user (a row version sent that cannot be one is refused, 400 "The row version is
    not valid. Reload the page and try again.", never read as "not sent"); 70006 not found. Should the completion be
    refused after the split, the answer says exactly that: "MOV-2026-000052 was split off MOV-2026-000046 but not
    completed: {reason}. Complete it on its page." - so does any other failure after the split (a deadlock, a timeout, a
    lost connection: "…but not completed: the database did not answer (see the API log). Complete it on its page.", code
    UNEXPECTED), on both entry points, with the new movement and the containers left; when the movement reads back
    completed (the failure came after the completion), it is answered completed, a Delivery saying what is missing of
    its draft goods receipts. The split's own answer is read before its commit, so a retried deadlock never runs a split
    twice. Both movements' history says it ("Split off into MOV-2026-000052: KTG-2026-0031", "Split from
    MOV-2026-000046: KTG-2026-0031 arrived on its own."), and so does each container moved.
  - **Cancelling a split-off movement undoes the split** (the recommended option, taken under the owner's standing rule;
    before it, the containers of a split done by mistake stayed stranded "Not moved yet" at the start of the voyage while
    their ship sailed on): in the Cancel's own transaction (`usp_Movement_SetStatus`) its containers go back onto the movement they were
    split from, whatever that movement's status, as if they had never been split off - **still in progress**, they travel
    on with it; **completed**, they arrived with it (its end date, its To; put back onto a completed Delivery they have
    no draft goods receipt: Delivered, not received, Receive goods… on each container); **cancelled**, its cancellation
    applies to them too (they are where they were before it, like its other containers). Their rows of the movement's
    container list, their charges filed under it and their documents filed under it go back with them (a file shared
    with containers elsewhere keeps their records where they are); the cancelled movement stays as an empty record
    ("Split undone: KTG-2026-0030, KTG-2026-0031 back on MOV-2026-000044" in its history, "Back from MOV-2026-000073
    (split undone): KTG-2026-0030, KTG-2026-0031" in the other's, and a line on each container). A copy of a copy goes
    back to its own original, the movement it was split from - and when that one was cancelled itself (its own split
    undone, its containers back on its original), they follow them there (`logistics.fn_Movement_SplitUndoTarget`).
    Every rule of the Cancel stays: the reason, only the last leg of each container (a split-off container that went on
    with a Then leg is refused "MOV-2026-000074 is not the last leg of KTG-2026-0046: cancel MOV-2026-000075 first."),
    never an offloaded container, a completed Delivery's automatic draft goods receipts deleted as for any cancelled
    Delivery. The Cancel dialog says it first, from the movement it reads (`splitUndo…`: that movement's number,
    status, end date, To and stage): "Cancelling MOV-2026-000073 puts KTG-2026-0030 and KTG-2026-0031 back on
    MOV-2026-000044, which is still in progress." / "…, which arrived at Dar es Salaam on 17/10/2026: they arrive with
    it." / "…, which reached Lubumbashi on 18/10/2026: KTG-2026-0044 is delivered with it, without a draft goods
    receipt. Use Receive goods… on it." / "…, which is cancelled: they go back to where they were before it." The
    notification after it is the server's (`splitUndone` on the answer, from the procedure's one row, read in its
    transaction): "MOV-2026-000073 cancelled, the split undone: KTG-2026-0030 and KTG-2026-0031 are back on
    MOV-2026-000044, still in progress." / "…are back on MOV-2026-000044, arrived at Dar es Salaam on 17/10/2026 with
    it." (a Delivery adds "Delivered, not received: use Receive goods… on each container.") / "…, which is cancelled:
    they are back where they were before it."
- **A movement that cannot be cancelled says why before the click** **[Implemented – script 83]** (the end-to-end test
  of shipment phase 3: the Cancel dialog opened, and even said where a split-off movement's containers would go back,
  when the Cancel was then refused):
  - **One place for the refusals of a movement's Cancel** (`logistics.fn_Movement_CancelBlock`), in the Cancel's own
    order and words, all 70010: "The movement is already cancelled."; "Container KTG-2026-0041 is already offloaded: its
    route can no longer change." (a container received or closed on a movement in progress or completed; a planned
    movement goes through); "MOV-2026-000091 is not the last leg of KTG-2026-0133: cancel MOV-2026-000092 first." (the
    last-leg rule of script 81, with its exception for a planned leg a later leg already passed). The Cancel
    (`usp_Movement_SetStatus`) throws the function's answer; the movement's GET carries it (`canCancel` false,
    `cancelBlockedReason`).
  - **The movement page keeps "Cancel…" on every movement that is not cancelled, disabled with that reason**: a tooltip
    on a wide screen; on a phone the entry of the "More actions" menu, the reason under its label (a completed
    movement's bar is then Back, with Cancel… in the menu). Its dialog - the reason, the split-undo sentence, a
    Delivery's drafts - opens only when the Cancel will go through; a refusal that still comes (someone changed the
    movement meanwhile) is shown as it comes.
  - The Cancel still needs a reason (70000 "A cancellation reason is required.", asked by the dialog and checked by the
    API first); a Cancel that can never go through says so before it asks for one. The Movements list offers no Cancel
    and is unchanged.
- **Place rule:** **[Implemented – prompt 43; errors 70015 / 70016 as planned, check the numbers]**
  - A movement only takes containers **at its From** = the To of each container's previous movement (cancelled
    movements don't count; previous = the latest one created before this one).
  - Save refuses others (70015): "Container KTG-… is at Dar es Salaam (end of MOV-…); this movement starts from
    Beira. Change the From, or record the movement that brings it here first."
  - Start refuses while a container's previous movement is not completed, or no longer ends at the From (70016).
  - Planning ahead is allowed: a container still on its way to Beira can go on a planned movement from Beira.
- **Never-moved containers:** **[Implemented – script 53, prompt 45]**
  - Prompt 43 let them start anywhere.
  - Prompt 45: they are at their **port of loading**. They can start from there, or go on an Origin-stage ("Loading
    at the supplier") movement whose To is their port of loading.
  - No port of loading → any From, with a note.
  - An Origin-stage movement takes only containers that have never moved.
- **The Containers card is the list:** **[Implemented – script 53, prompt 45]**
  - Checkboxes, ticked = on this movement. It reloads at once when the From changes; containers not at the new From
    are unticked, with a message.
  - No "Add containers…" dialog.
  - Save needs ≥ 1 ticked. Start and Complete are disabled while there are unsaved changes ("Save your changes
    first."). Start re-checks everything in SQL and refuses a movement without containers.
- **Import of container numbers** (Excel or paste):
  - **[Implemented – prompt 43, basic]**: matches the container number, then the ref; capitals, spaces, dashes, dots
    and slashes are ignored; never creates containers.
  - Results: Will be added / Already on this movement / Not found / Cannot be added (reason) / Found twice /
    Duplicate. At most 10,000 numbers a call (500 before script 78); the page sends a longer file in parts.
  - **[Implemented – prompt 45]:**
    - Only valid numbers can be ticked, with no forcing.
    - "Download the result" gives sheets Result and Summary.
    - The template `Movement_Containers_Import_Template.xlsx` (sheet Containers with "Container no." in A1, sheet
      Instructions, sheet Example result) is served from the Web's `public/templates/`.

### 4.7 Charges and costing **[Implemented]**
- **Costing method:** weighted **average cost** per item, plus last cost and FOB cost. Sales go out at average cost
  (COGS). `inventory.usp_Item_RebuildCosts` recomputes.
- **Import landed cost** = FOB per piece + posted charges on the line ÷ pieces received. The FOB is the posted
  invoice's for the pieces it covers, else the order price; an invoice posted after the goods corrects it (4.12).
- **An invoice that does not change item costs** (the PINV type's "Affects item cost" off when it was posted,
  script 79) **[Implemented]**: the pieces matched to it cost as if unmatched - the order price, plus the container's
  charges on container goods. It is still matched (invoiced counters, return caps, container Close, payments). A return
  from it takes its goods out at what they entered stock at (the matched receipt lines' order price, plus container
  charges; never a cost blended with another invoice's price), the supplier credit staying the invoice price; a landed cost adjustment on it is refused (67013: "This invoice does not change item
  costs (its document type was set so when it was posted): a landed cost adjustment on it would change no cost.
  Container charges still enter the cost of goods received in containers."). Goods of an order-less invoice of that
  kind take a typed cost, else the item's last cost, else its average (an item with no cost yet: the invoice's price
  once), and set the item's last cost only once matched to an invoice that does change costs.
  - Before the goods receipt the screens show an estimate ("est."), for the pieces loaded, of the cost its goods receipt
    will give them (script 82, `logistics.fn_ContainerLine_FobEstimate`): the cost rule over the invoice pieces the
    receipt's matching will give the line - first the invoices linked to the container line, then the order line's
    posted invoice pieces no receipt takes by its own invoice or container line (not linked to a container, or left over
    by a container received short), first in first out by posting over the order line's receipts in the order the
    matching takes them (its posted goods receipts first, then its containers still on their way in the order they were
    created, as they usually arrive). The pieces of invoices that change item costs count at their price, every other
    piece (not invoiced yet, or invoiced by an invoice that does not change item costs) at the order price. Examples: 84
    pcs ordered at 100, 30 invoiced at 120 by an invoice that changes costs and 20 at 130 by one that does not: est. (30
    × 120 + 54 × 100) ÷ 84 = 107.14 per piece (the screen said 114.29 before script 82); 168 pcs at 100 in two containers
    of 84 and an invoice of 84 at 120 not linked to either: the first container est. 120, the second 100 - what their
    goods receipts then give them. It stays an estimate: another order of arrival, a later invoice or a receipt from the
    order moves it; a received line shows its final cost.
- **Container charges:**
  - Draft → Posted → Cancelled. Only posted charges that "enter the landed cost" count.
  - Any currency, at the rate of the charge date (editable): "No exchange rate for this currency on the charge date.
    Add one or enter the rate."
- **Split over containers:** Same / Equal / Pieces (default) / Value; "Same" is the default from the selection bar.
  - Example, 3,000 USD on containers of 120 and 60 pcs: Same = 3,000 each; Equal = 1,500 / 1,500; Pieces = 2,000 /
    1,000; Value = by FOB value.
- **Allocation over items:**
  - Value: order price → invoice price → final FOB.
  - Quantity: pieces, received after the goods receipt.
  - Weight / Volume: needs the item's weight / volume, else "…: item … has no weight (kg)" (on a container of several
    lines, below).
  - Manual: the amounts must add up exactly.
  - Rounded to cents; the leftover cents go to the largest remainders.
  - **One line takes the whole charge** (script 88): a container whose only line with pieces is one item - the usual
    container, 84 pcs of one model - gets the whole charge on that line, whatever the method: there is nothing to
    divide, so no price, weight or volume is needed, the way a charge on one container needs no split basis. Its basis
    is shown as computed (0.00 without a price, "—" without a weight). Before, by value with the price at 0 (an order
    line at 0 or 100% discount, or an invoice line linked to the container line at 0 - a draft too, which then hides
    the order price) refused at Post "Customs: the allocation basis (Value) is zero for every line of the container.
    Use another method or a manual allocation.", and by weight or volume without the item's figure refused too; a goods
    receipt re-spreading the posted charges refused the same way. **[Implemented – script 88]**
  - **Several lines, every one at price 0, by value**: still refused - there is no value to divide by - with each line
    named and where its price comes from: "Customs on KTG-2026-0151: By Item Value needs a price, and every line is at
    0 - line 1 TVS-APACHE-160 on the order PO-BR-002-000042, line 2 TVS-XL100 on a draft invoice. Type the price on the
    supplier invoice, or allocate the charge By Quantity or Manual." (three lines at most, then "and n more"; a received
    line "as received (GRN-…)", a posted invoice "on PINV-…"). Typing the price on the draft invoice is enough: the
    value reads draft invoices too. Every refusal of the allocation names the container ("Customs on KTG-2026-0151:
    item TVS-XL100 has no weight (kg). …"): Post posts the ticked charges together, all or nothing, so the message says
    which container stops them. **[Implemented – script 88]**
- **Import from Excel:** Logistics › Containers › "Import charges from Excel…" (template with the charge types and
  currencies, `Import_Container_Charges_Template.xlsx`). One row = one charge on one container (found by container
  number or ref), divided over its items by the row's allocation method (Manual refused). Every row is checked first
  (Valid / Warning / Error, with an error report to download); rows of one provider invoice become one charge group;
  "Post the charges" (with the post permission) posts them, else they stay drafts. An item without weight or volume is
  warned about only on a container of several lines (script 88: one line takes the whole charge). **[Implemented]**
- **Copy to other containers:** drafts of the same group, or posted at once with the permission. A container that
  already has a charge of the group is refused. Manual allocation is copied with the charge type's method.
- **Late charge after the goods receipt** (or cancelled after it): a cost adjustment (`CNTCHARGE`), badge "after
  receipt", unchanged by goods receipts. The part the **company** still holds - min(pieces received, the company's
  stock of the item in every warehouse) ÷ pieces received - changes the average cost; the rest goes to COGS. Before
  script 89 the receiving warehouse's stock decided, so goods moved to another warehouse sent their share to COGS (84
  received, 80 moved: 140 of a 2,940 charge to stock instead of 2,940). The rows keep the receiving warehouse and
  branch for the reports. A cancel takes its share again from today's stock, never more out of stock than its posting
  put in. The goods receipt can no longer be cancelled (63008). **[Implemented – script 89]**
- **Local purchases:** the invoice's charges while it is a draft, part of the invoice cost the received goods take;
  after posting, an LCA (67011 the invoice must be posted; 67012 refused on imported and "Shipped in containers"
  invoices). On an invoice that uses goods receipts, the LCA raises the invoice cost and the goods already received
  follow (4.12); pieces not received yet enter at that cost. On an invoice posted before goods receipts the LCA's stock
  part is worked out per item on the company's stock (script 89).
- **The cost of received goods follows the invoices** (scripts 64–65): see 4.12 and `docs/notes/costing-rules.md`
  (causes PINV, PINVCANCEL, LCA, GRNPOST, GRNCANCEL, NEGSTOCK; the company stock share).
- **Worked examples (user guide):**
  - KTG-2026-0031: 84 pcs of Model A at 950 USD FOB; charges 2,100 + 840 = 2,940 USD → 35 USD/pc → landed 985 USD.
    If only 82 arrive → 35.85 → 985.85. Received at the order price 950 and invoiced later at 960: + (960 − 950) × the
    pieces received, on the FOB only.
  - Mixed container: 42 pcs A at 950 (39,900) + 60 pcs B at 700 (42,000), freight 1,000 USD.
    - By value: A 487.18 (11.60/pc), B 512.82 (8.55/pc).
    - By quantity: A 411.76, B 588.24 (9.80/pc each).

### 4.8 Attachments **[Implemented – scripts 52, 55, 67]**
- **The same way on every page, like Containers** (prompt 40): purchase orders, invoices and returns, sales invoices
  and returns, Inventory In / Out / BIVAC Out, customer receipts, supplier payments, containers (their movements and
  charges too) and item definitions.
  - The files are a **"Documents" list on the page**: on purchase, sales and stock documents a "Documents" card below
    the lines (no more side drawer), with "Documents (n)" and "Add document…" in the action bar.
  - **One "Add document" popup and one "Edit document" popup** everywhere: File, Attachment type, Document date,
    Note. "Add document…", dropping a file or picking one all open the popup; nothing is uploaded without a type.
  - The attachment type is **required**; the types offered are those "Used for" the kind (Master Data › Attachment
    Types). Kinds: CONTAINER, ITEM, PO, PINV, PRET, SO, SINV, SRET, RCPT, PAY, INV_IN, INV_OUT, BIV_OUT, and GRN
    (built with the goods receipts).
  - "PDF, image or Office file, up to 20 MB" everywhere.
  - Files from before types existed are typed **"Other › Other"**: an orange badge and a "Choose a type" button ask
    for a real type.
  - Attachments are **never required to post**. Each module keeps its own storage.
  - Who may add, edit or delete:
    - purchase, sales and stock documents: the family's create permission, in any status;
    - receipts and payments: the same, but not once Reversed;
    - containers, movements and charges: `containers.attachments.manage` (a movement needs containers; no new file on
      a cancelled charge);
    - items: `inventory.items.edit`.

    Without the permission, files can only be downloaded.
- **Containers:**
  - General, or linked to a movement and/or a charge.
  - One upload → several containers; the file is stored once.
  - The edit can file a document under another movement, or back under General (script 67); refused when one of its
    containers is not on that movement (70000). A charge's file stays with its charge.
- **Item definitions** (script 67, kind ITEM): Item Definition › Documents, with the types Data Sheet, Specification,
  Certificate / Homologation, User Manual and Picture (category Item); error 56009 for a missing or wrong type. The old
  item files became "Other". Added with `inventory.items.edit`, in view mode too. The item's **picture** stays apart:
  JPEG, PNG or WebP, up to 5 MB, no type.
- **Landed cost adjustments:** no documents of their own; the provider's invoice goes on the purchase invoice.

### 4.9 Inventory and sales (mostly Ali's)
- Setting **"Allow selling out-of-stock items"** + the Out-of-Stock Sales page. **[Ali – details unknown]**
- **Sales invoice:** its own currency; client address; **date tolerance**; **payment type**; "auto…".
  **[Ali – details unknown]**
- **Customer receipts** with payment methods and cash / bank accounts. **[Ali – details unknown]**
- **Warehouses** can stand under another warehouse. **[Ali]**
  - **Lines take a warehouse at the bottom of the tree, of any branch** (Ali, scripts 69–70; goods receipts too,
    script 72; see 1.4). A warehouse already used cannot become a parent (script 71; goods receipts count, 72).
    **[Implemented]**
- **Document import:** one document whatever the warehouse; no Expiry Date in the import template. **[Ali]**
  - On Sales Invoice and Inventory In, a file naming several warehouses can instead become **one document per
    warehouse**: the import's switch "One invoice per warehouse" (Sales Invoice page) / "One document per
    warehouse" (Inventory In page), off by default; same header on each, each posted on its own. **[Implemented]**
- **Price lists:** per document type `DefaultPricing` / `PriceEditable`. **(unsure, check the code)**
- **Stock check on sales** (refused unless out-of-stock selling is allowed). **(unsure)** When a draft goods receipt
  holds an item that is short, the warning adds "A goods receipt is waiting to be posted: GRN draft of KTG-2026-0031."
  (readers who may see goods receipts). **[Implemented]**
- **Inventory Out** may require a reason (`RequiresReason`). **(unsure)**
- **BIVAC Out** (Inventory › BIVAC Out, document type `BIV_OUT`): **[Implemented – script 66]**
  - The units really leave stock at the average cost, like an Inventory Out: refused when the stock is short
    (62007); cancelling needs a reason and reverses the movements.
  - Its own list, numbers (`BIV-BR-002-000001`, given at the first save) and permissions
    (`inventory.bivacout.*`). No reason is required.
  - **Every line must be a BIVAC item** (an item with "BIVAC Item" ticked). The rule belongs to the document type
    (`BivacItemsOnly`, shown read-only in Configuration › Document Types):
    - the line Item dropdown and the quick search offer only BIVAC items, with the hint "Only BIVAC items. Tick
      "BIVAC Item" in Inventory › Item Definition to add one.";
    - Save and Post refuse any other item (62000): "Line 2: BAT-12V is not a BIVAC item. A BIVAC Out holds BIVAC
      items only.";
    - the Excel import marks such a row as an Error: "BAT-12V is not a BIVAC item."
  - No link to a shipment: the BIVAC certificate or the container number goes in Reference No., and the certificate
    can be attached (attachment types start with the same "Used for" as Inventory Out; an administrator can add a
    "BIVAC certificate" type).
  - Unchanged: Inventory In / Out, their numbers and reasons; the average cost method; the `BIV` charge type (the
    BIVAC fee on containers); what the "BIVAC Item" flag means.
- **Item dropdowns on documents** list every matching item; they used to stop at the first 20.
  **[Implemented – script 66]**

### 4.10 Dates and times
- Timestamps are stored in `*Utc` columns; dates without time (document date, order date, ETA) have no time zone.
  **[Implemented]**
- The API sends `*Utc` values with "Z" and the web shows local time once. **[Implemented – prompt 42]**
  (`Inventory_Shipment.API/Extensions/UtcDateTimeJson.cs`)
- Date tolerance on sales invoices. **[Ali – details unknown]**

### 4.11 Security and data
- **Permissions per role:** the administrator has all. Manager defaults: containers view, create, confirm (offload,
  now unused); goods receipts view, create, post; movements; documents; view and create charges; transfer orders view
  and approve (script 90, the Owner role too). New sensitive
  permissions (`settings.email.manage`, `purchase.approval.manage`) are administrator-only by default. **[Implemented]**
- **Secrets:** approval links never decide on GET; tokens never appear in logs or API responses; the SMTP password is
  never returned or logged. **[Implemented]**
- **Concurrency:** RowVersion on documents: "This … was modified by another user. Reload the page and try again."
  (65004 / 70004 → 409). **[Implemented]**

### 4.12 Goods receipts (GRN) **[Implemented – scripts 64, 65]**

The owner chose the recommended option of every decision: containers **and** local purchases; an order closed when
fully invoiced and received (or settled short) - until script 77, which removed Closed; an invoice whose goods were
received may be cancelled; the exchange-rate difference is part of the cost adjustment; "Without an order" needs a
supplier; any confirmed container can be received; "Receive the goods now" when an invoice is posted, off by default;
status 6 keeps the name "Offloaded".

**What changed**
1. **Goods enter the stock only through a posted goods receipt.** A supplier invoice posted after the switch moves no
   stock and no item cost, whatever its receipt mode. Posting it still gives the number, makes the amount payable,
   counts the order line as invoiced and works out each line's **invoice cost** (FOB, its own charges, landed).
2. **Document type GRN**, "Goods Receipt", family Purchase, numbered per branch at posting (4.1).
3. **Draft → Posted → Cancelled.** A draft can be edited or deleted; a posted receipt can only be cancelled, with a
   reason. The goods are not in stock until the receipt is posted; the menu counts the drafts.
4. **One source per receipt:** a container, an order, an invoice, or "Without an order".

**Containers**
5. **Completing a Delivery-stage movement** creates a draft for each container in status 2–5 with no draft or posted
   receipt: lines = the container lines (expected = received = loaded), date = the movement's end date, warehouse =
   the container's when it is active, of its branch and at the bottom of the tree (script 72), else to choose. The
   completion never fails because of them (4.6).
6. **"Receive goods…" on the container** makes the same draft by hand: containers followed without movements, those
   whose last leg is not a Delivery, those delivered before the switch. Status 2–5 only; refused when a receipt exists
   (63013: "Container KTG-2026-0031 already has {goods receipt GRN-… | a draft goods receipt}. Open it instead."). A
   container still Confirmed gets an orange warning: "KTG-… has not left the supplier: no dispatch date or movement.
   Receive it only if the goods are really here."
7. **A container's receipt:** its lines only (none added or removed); received 0 to loaded ("Line {n} ({item}):
   received {r} but only {l} were loaded."); a reason code (Short-shipped, Damaged, Missing, Wrongly counted at loading,
   Other) and a note when received ≠ loaded, and the difference is **settled short**; one warehouse of the container's
   branch, at the bottom of the tree (script 72) ("Choose the warehouse the goods are received into."); dated not in the future and not before the Delivery
   ("The goods cannot be received before MOV-… reached {place} on {date}."). Posting is refused while a movement of
   the container is in progress (63010). The goods need not be invoiced.
8. **Posting it does what the offload did:** stock in at landed cost; the posted charges re-spread over what arrived,
   then frozen; average, last and FOB costs updated; the container **Offloaded** at the warehouse, read-only.

**Local purchases**
9. **"Receive goods…" on an approved purchase order** (Saved, Partially posted or Posted). Disabled with a reason: "Approve the order first: goods
   are received against an approved order.", "This order is waiting for approval.", "This order is cancelled.",
   "Everything ordered is already received.", "Everything still to receive travels in containers: it is received with
   its containers."
   - It proposes every line with **To receive** = ordered − received − settled short − in containers − in draft
     receipts. On an order that has containers, **Receive now starts at 0**, with an orange alert: goods in containers
     are received with their containers.
   - Partial receipts, into any active warehouse of any branch at the bottom of the tree (default: the order line's).
     Per line, **"Nothing more will come"**
     (reason required) settles the rest.
   - Posting refuses more than what remains outside containers (63011: "Line {n}: {item} - {r} pcs received but only
     {x} remain to receive on the order line outside containers.").
10. **"Receive goods…" on a posted invoice:** its lines not in a container, to receive = invoiced − received − in
    draft receipts; this receipt's pieces match this invoice first. Disabled: "Post the invoice first: goods are
    received against a posted invoice, or from the order.", "Every piece of this invoice is already received.", "This
    invoice's goods travel in containers: they are received with their containers.", and on an invoice posted before
    the switch "Posted before goods receipts: its stock entered when it was posted (or when its container was
    offloaded)."
11. **"Receive the goods now"** in the post confirmation of a local invoice, for users who may create and post goods
    receipts, off by default. Ticked: the invoice is posted, then its goods are received and posted. When the receipt
    fails, the invoice stays posted: "Invoice posted; the goods receipt was not: {reason}. Use Receive goods…".
12. **"+ New"** on the Goods Receipts list: "From a purchase order…" (supplier, then its orders with something to
    receive), "From a container…", "Without an order" (supplier required, free lines at a typed cost). A receipt
    without an order is refused at posting when the supplier has the item to receive on an order or an invoice
    (63011: "SUP-0001 has PO-BR-002-000042 with 100 pcs of {item} still to receive: receive them from the order.");
    its lines change the item's last cost only once matched to an invoice.

**Warehouses** (script 72: Ali's rule of 1.4 applied to goods receipts) **[Implemented]**
- Every warehouse a goods receipt puts stock into is **at the bottom of the tree**: "Receive into" and each line, on
  save and again at posting (63000: "The warehouse LUB has warehouses under it. Choose one of those: stock is kept only
  in the warehouses at the bottom of the tree."). An order's, an invoice's or a receipt without an order: any branch. A
  container's: the container's branch as well.
- A container whose own warehouse has warehouses under it (or is inactive, or of another branch) gets its draft with
  the warehouse to choose. The Complete dialog of the Delivery says it first ("KTG-2026-0031 → draft, warehouse to
  choose (LUB, the container's, has warehouses under it)"), and the notification after it says why, once per reason:
  "KTG-2026-0031: choose the warehouse (LUB, the container's, has warehouses under it: …)."
- A warehouse named by a goods receipt (a draft too) counts as used: it cannot become a parent.

**Cost** (the details and examples: `docs/notes/costing-rules.md`)
13. **At receipt** the pieces are matched to posted invoice pieces: the receipt's own invoice, then the container
    line, the order line, and for goods without an order the same supplier and item, first in first out. Matched pieces
    take the invoice cost; the others the **order price**; a manual line its typed cost. A container line's charges
    stay on the container line.
14. **Afterwards the cost follows the invoices automatically:** an invoice or LCA posted or cancelled, a goods receipt
    posted or cancelled, brings every received piece concerned to its new cost. The part still in the **company's**
    stock changes the average cost; the rest goes to COGS. The exchange-rate difference is part of it. Recorded as
    `GRNCOST` cost adjustments, never dated before the receipt, and shown on the receipt ("Cost adjustments") and on the
    invoice ("Cost of received goods"). The invoice's post confirmation estimates it first: "60 pcs already received
    will have their cost adjusted by +60.00 USD (estimate: stock 40.00, cost of sales 20.00)."
15. **Goods sold before their receipt is posted** (out-of-stock selling on): the cost difference of the pieces that
    fill the negative stock goes to COGS at posting (`NEGSTOCK`).
16. Late **container** charges keep the late-charge mechanism (`CNTCHARGE`). Invoiced pieces that never arrive carry
    their share of the invoice's own charges out of the cost, as their FOB: the supplier claim covers both.
16a. **The three switches of script 79** (Configuration › Document Types, 3.7), defaults = rules 5-16 as written:
    - **PINV "Affects item cost" off**: rules 13-14 skip that invoice for the cost - its matched pieces keep the order
      price (+ container charges), its post confirmation says "{n} pcs already received keep their cost: this invoice
      does not change item costs (Configuration › Document Types).", its page's "Cost of received goods" says why it is
      empty, and its late charges are refused (67013). Cancelling it still re-matches: its pieces may go to another
      invoice that does change costs, and take that one's price.
    - **PINV "Affects on-hand" on**: posting the invoice is followed, in its own transaction, by the receipt of rule 11
      ("Receive the goods now") without the tick - from the invoice page, Post selected or an import that posts, and
      **whoever posts: no goods receipt right is needed**, the rule is the document type's. Lines in containers, a
      "Shipped in containers" invoice and goods already received are left alone and nothing is said; a receipt the
      database refuses leaves the invoice posted: "Invoice posted; the goods receipt was not: {reason}. Use Receive
      goods…" - on the invoice page as a warning, in the Post selected and bulk post results and in the import result
      beside that invoice (a receipt made is named there too: "Goods received: GRN-…"). The post confirmation shows "Its goods are received at once into {warehouse}: a goods receipt is made and
      posted with the invoice (Configuration › Document Types)." instead of the tick.
    - **GRN "Create goods receipts when a Delivery is completed" off**: rule 5 makes no draft; the Complete dialog and
      the notification say "Goods receipts are made by hand: use Receive goods… on each container."; rule 6 (Receive
      goods… on the container) and the "Delivered, not received" filter work as before. Cancelling a Delivery still
      deletes the automatic drafts it made while the switch was on.

**Cancelling**
17. **Cancel a goods receipt** (posted only, reason required). Refused: the container is Closed (63010: "Container
    {ref} is closed. Reopen it before cancelling its goods receipt."); the stock it brought was used (63007: "Cannot
    cancel: {item} in {warehouse} has only {n} left, but this goods receipt brought {m}."); its cost was adjusted
    afterwards (63008: "The cost of these goods was adjusted after they were received (invoice price, landed cost or a
    late container charge). This goods receipt can no longer be cancelled."); a purchase return took its goods back
    (63010: "Purchase return {PRET-…} took back goods of this receipt. Cancel the return first."). Effects: the stock
    goes back out, the matches are rebuilt and the other receipts trued up, the order's counters go down, a container
    goes back to its movement status and can be received again.
18. **Cancel an invoice whose goods were received:** allowed, no stock effect; the received pieces go back to the
    order price (goods without an order keep their cost at receipt). 69012 stays only for containers offloaded before
    goods receipts; the other refusals (returns or LCAs posted, payments allocated) stay.

**Orders, reports**
19. **Order line counters:** Received (goods receipts, plus the receipts made before them), Invoiced, Settled short.
    Outstanding = ordered − received − short on an approved order, never below 0 (before script 77 a closed order
    counted invoiced − received − short): what Shortages, the item's "On order" and the dialogs use. The order list shows a "Received" and an
    "Invoiced" progress; filters "To receive" (orders), "Not fully received" (invoices); the Goods Receipts list has
    "With differences" and "Received not invoiced", with a line "Received not invoiced: {n} pcs, {value} at the order
    price." for month-end.
    - **The Dashboard's "On the way"** (script 72) is what Shortages count, company-wide or per branch: the orders'
      outstanding less the pieces in containers that left the supplier (shown to who may see orders), the posted
      invoices without an order not received yet (who may see invoices), and those containers' pieces (who may see
      containers; a reader who may not gets them in the orders' figure). Its free-time alarms stop at the end of the
      Delivery, as on the container's page and the Tracking board: a delivered container waits Cleared for its goods
      receipt and is "Free time over" only if the free days ran out before it left. **[Implemented]**
20. **No closing (script 77):** an order is never closed; it shows Saved, Partially posted or Posted from its posted
    invoices, and goods receipts do not change that. Cancelling an order is refused while it has goods receipts (65011:
    "This purchase order has posted goods receipts. Cancel those first." / "…draft goods receipts. Delete them
    first."). (Before 77 it closed automatically "Fully invoiced and received", reopened when an invoice or goods
    receipt that closed it was cancelled, and could be closed by hand.)
21. **Last cost, FOB cost, last supplier** come from the latest posted goods receipt line, after its adjustments.
22. **Invoice lines a goods receipt refers to** cannot be linked to or unlinked from containers (65028: "Line {n}
    ({item}): {goods receipt GRN-… | a draft goods receipt} refers to this invoice line: delete or cancel it first.").

**The switch ("from now") and why it is one-way**
23. **The switch** is script 65's first run on a database (each API start applies Schema.sql). In one transaction it
    counts, once, what every order line already received (the stock of old local invoices, old offloads) and settled
    short (what old offloads recorded short), and writes the one row of `purchase.GoodsReceiptSwitch` with its date.
    Nothing else changes: no draft is flipped, no cost is replayed. Each database has its own switch date (Bilal's PC,
    Ali's, testing, production).
    - Documents posted before keep their stock and cost. Old invoices show "Posted before goods receipts: …"; their
      cancel, return and LCA follow the old rules (cancelling one lowers the order's received counter).
    - Draft invoices follow the new rule when they are posted.
    - Containers still travelling are received with goods receipts. Those whose Delivery was completed before the
      switch got no automatic draft: Containers › "Delivered, not received", then Receive goods….
    - Orders closed "Fully received" with goods still to come stayed closed; the goods could still be received.
      (Script 77 brought every closed order back.)
    - The invoice list tells the people who post invoices: "Since {switch date}, posting a supplier invoice no longer
      adds stock: receive the goods with Receive goods…".
24. **One-way.** Once a goods receipt, or an invoice posted the new way, exists, the code before script 65 would
    receive goods twice (its Post moves stock for invoices; its Cancel Offload finds no `CNT` rows for a GRN
    container). The only way back is the backup `update.sh` takes just before it pulls; data entered after it is lost.
    So scripts 64 and 65 reach `main` together with the web, are rehearsed on testing on a copy of production first,
    and production follows at a quiet moment: `deploy/README.md`, "Goods receipts go-live", which also holds a
    read-only check of what the switch will do. Ali's database switches at his next API start after he pulls: his
    purchase invoices then stop moving stock.

**Errors (block 63xxx, goods receipts)**

| No. | Meaning | HTTP |
|---|---|---|
| 63000 | validation ("Choose the warehouse the goods are received into.") | 400 |
| 63004 | changed by another user | 409 |
| 63005 | not a draft: only a draft can be changed or deleted | 409 |
| 63006 | not found | 404 |
| 63007 | stock consumed: cannot cancel | 409 |
| 63008 | cost adjusted: cannot cancel | 409 |
| 63009 | nothing to receive / no lines ("Nothing is left to receive on this order.") | 400 |
| 63010 | invalid status or source state (not a draft, movement in progress, container closed, return, GRN type inactive, matching lock not obtained in 60 s) | 409 |
| 63011 | more than remains / receive from the order | 400 |
| 63012 | attachment type not used for goods receipts | 400 |
| 63013 | the container already has a goods receipt | 409 |

Re-used or new outside the block: 69019 (new) a container with a goods receipt; 69016 Close with received pieces not
invoiced; 69010 the Offload retired / Cancel Offload of a GRN container; 65011 an order with goods receipts / a return
above what was received; 65021 (until script 77) an order closed by hand with received goods not invoiced; 65028 an invoice line a goods
receipt refers to (65030 for Add container / Auto-plan from that invoice); 65008 a purchase document type other than
PO, PINV, PRET; 67012 an LCA on a "Shipped in containers" invoice; 67013 (script 79) an LCA on an invoice that does
not change item costs.

### 4.13 Inventory transfers **[Implemented – script 90, prompt 47]**

Stock used to move between the company's own warehouses with an Inventory Out in one and an Inventory In in the other:
the average cost moved twice and nothing showed the goods on the road. A **transfer order** follows them from one
warehouse to the other, through the hidden **On the way** warehouse of the destination branch, without changing any
cost. The owner approved the feedback's recommended option of every decision, then put approval in scope. Quantities
are pcs unless said; only posted, not reversed dispatches and receipts count.

**The order**
1. **Header:** Order date (required, today by default: "The order date cannot be in the future."), From, To, Expected
   arrival (optional: "Expected arrival cannot be before the order date."), Reference No., Notes. **The warehouses are
   the order's, not its lines'** (the exception to 1.4): every line leaves From and goes to To - one journey, one truck,
   one dispatch note.
2. **From and To** are active warehouses at the bottom of the tree, of any branch, never an On the way warehouse, and
   different (62000, the first that fails): "Choose the warehouse the goods leave from." / "Choose the warehouse the
   goods go to." / "The destination must differ from the source." / "{code} is an On the way warehouse: it holds goods
   travelling between warehouses and cannot be chosen." / "Warehouse {code} is inactive." / "Warehouse {code} has
   warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree." The
   order's branch is From's, kept up to date while it is a draft; its number keeps the branch it was given (4.1).
3. **A line:** item, unit, Ordered (a whole number above 0 in the unit, also kept in pcs), notes; the same item may be
   on two lines in different units ("Line 2: item {code} is inactive.", "Line 2: the unit does not belong to item
   {code}.", "Line 2: Ordered must be a whole number above 0."). Lines come from the item search - a scanned box
   barcode takes its unit, else the base unit, and a second scan of the same item and unit adds 1 - or from "Import
   lines from Excel…" (`Transfer_Order_Lines_Template.xlsx`: Item Code / Barcode, Unit, Quantity, Notes; a blank unit
   is the base unit; a row with a Warehouse or a Unit Price is an Error: "A transfer takes its warehouses from the
   order: leave Warehouse empty." / "A transfer has no cost: leave Unit Price empty.").
4. **Where each item stands**, beside its line: "Available at {From}" = on hand less what the other released orders
   still have to dispatch from it, never below 0, red when below the line's To dispatch (hover: "{n} on hand · {c}
   promised to other orders"); "Stock at {To}" = on hand there. Information only: nothing is reserved.
5. **A draft** moves no stock and may be deleted ("Delete draft {No}? Its number is not reused."): its number leaves a
   gap. Documents (attachment kind TRO, whose "Used for" types were copied once from Inventory Out) in every status.

**Statuses**
6. **Stored:** Draft, Waiting for approval, Released, Cancelled. A released order is **shown**, the first that applies:
   **Released** (nothing dispatched or closed yet), **Partly dispatched** (something still to dispatch, not closed),
   **Dispatched** (goods on the way, nothing arrived yet), **Partly received** (goods on the way, some arrived or
   written off), **Closed** (Nothing more will be sent, and everything sent has arrived or was written off),
   **Received**. Dispatches, receipts, their reversals and the Not sent stamp never change the stored status. Beside
   it a red filled "Late" badge (rule 24) and an orange "{n} lost" badge. Colours: Draft gray, Waiting for approval
   yellow, Released blue, Partly dispatched and Partly received orange, Dispatched indigo, Received green, Closed teal,
   Cancelled red; a reversed dispatch or receipt orange.
7. **Moves:** Draft → Released (Release, or Approve & release); Draft → Waiting (Send for approval…); Waiting →
   Released (Approve); Waiting → Draft (Reject… with a reason, or Withdraw); Released → Draft ("Back to draft…", a
   reason) **only while the order has no dispatch or receipt at all, reversed or not**; Released → Cancelled ("Cancel
   order…", a reason) while nothing is dispatched.
8. **What can change:** a draft everything; a waiting order only its documents ("This transfer order is waiting for
   approval: withdraw it to change it."); a released order its Expected arrival, Reference and Notes ("Save details")
   and documents - "{No} is released: its lines, quantities and warehouses are locked. Use Back to draft… to change
   them." / "{No} is released and has moved goods: its lines, quantities and warehouses can no longer change."; a
   received, closed or cancelled order its Notes and documents ("Only the notes can change on a received, closed or
   cancelled transfer order.").
9. **Counters:** To dispatch = Ordered − Dispatched − Not sent, never below 0; On the way of a dispatch line =
   Dispatched − Received − Lost, of an order line the sum. The lines grid shows Dispatched, Received and To dispatch;
   **On the way is never a grid column**: the totals row (Ordered, Dispatched, Received, On the way, Not sent, Lost), the
   list and each dispatch show it.
10. **The list** (Inventory › Transfer Orders): Number, Date, From, To (each with its branch), Status, Items, Ordered,
    Dispatched and Received (progress bars), On the way, Expected arrival (red and bold when late to dispatch),
    Reference, Created by; filters Search (number, reference, warehouse, item, or a dispatch or receipt number),
    Branch (From's or To's), From, To, Status (every shown status, and Open = released, neither Received nor Closed),
    "On the way only", "Late only", "Waiting for approval" (approvers), dates; under it "Orders · On the way · Late
    orders". "Export to Excel" of an order: sheets Order, Lines, Dispatches and receipts.

**Dispatch** ("Dispatch…", the dispatch permission)
11. On a released order that is not closed and has something to dispatch. The dialog proposes the lines ticked in the
    grid, else every line with To dispatch above 0, each at the smaller of To dispatch and what From still holds after
    the lines above it of the same item; a line with no stock is unticked, "No stock in {From}.". Dispatch date ("The
    dispatch date cannot be before the order date ({date})."), **ETA required** (default the Expected arrival; "The ETA
    cannot be before the dispatch date."), Waybill / truck, Notes.
12. Refused above To dispatch (62012 "Line {n} ({item}): {q} pcs dispatched but only {t} are left to dispatch.") and
    above From's stock, per item over its lines, checked again at posting (62007 "Insufficient stock for {item} in
    {From}: available {a}, required {r}."); "Allow selling out-of-stock items" does not apply. One dispatch at a time
    from a warehouse ("Another dispatch from {From} is being posted. Try again in a moment.", 62010); a dispatch and a
    sale from the same warehouse at the same instant can still both pass the stock check, as before.
13. Posting: number TRD by the source branch; From −q, the destination branch's On the way +q (reason TRF_OUT): "{TRD}
    posted: {q} pcs left {From}." A dispatch with goods on the way may change its ETA ("Change ETA…", the dispatch
    permission; "Only a dispatch with goods on the way can change its ETA."). "Print dispatch note": the TRD and its
    order, From → To, the dates, Waybill / truck, the lines in pcs and their total, boxes "Dispatched by", "Driver",
    "Received by"; never a cost.
14. **Release warns** when the released orders from From, this one included, need more than From holds - "{item}: the
    released orders from {From} need {n} pcs; {From} holds {m}." - and releases all the same: Release reserves
    nothing, the dispatch checks the real stock.

**Receive** ("Receive…", the receive permission)
15. The dialog lists each dispatch with goods on the way ("{TRD} · dispatched {date} · ETA {date}", red "Late" when
    late); each line starts at its On the way and may be lowered. One receipt may take lines of several dispatches (one
    truck bringing two), dated not before the latest of them ("TRR cannot be dated before {TRD} left on {date}.").
    Date received, Delivery note no., Notes.
16. Received ≤ On the way of that dispatch line, checked at posting under the order's lock (62012 "{TRD} line {n}
    ({item}): {r} pcs received but only {w} are on the way."). When fewer arrive: **"Still coming"** (the default: the
    rest stays on the way) or **"Nothing more will arrive"** with a reason - Damaged, Missing / stolen, Wrongly counted at
    dispatch, Other with a note ("{TRD} line {n} ({item}): choose why the rest will not arrive." / "… say what happened
    in the note (reason Other)."). Nothing typed: 62009 "Nothing to receive: type the pieces that arrived, or tick
    Nothing more will arrive."
17. Posting: number TRR by the destination branch; On the way −q, To +q (TRF_IN); the pieces that will not arrive
    leave On the way at the item's average cost (TRF_LOSS) and never reach To: "{TRR} posted: {r} pcs received into
    {To}; {l} pcs written off." Damaged goods that did arrive are received, then taken out with an Inventory Out. To
    made inactive since: "The destination {code} is inactive: activate it to receive these goods."

**Dispatch and receive** ("Dispatch and receive…", needs dispatch **and** receive)
18. One date, no ETA: the dispatch and a receipt of exactly what it sends, in one transaction, both or neither (no
    number is taken by a refusal; To inactive: "The destination {code} is inactive: goods sent to it could not be
    received. Activate it, or cancel the order."). Earlier dispatches still on the way are not touched, and the dialog
    names them: "{w} pcs of {TRD list} are still on the way: receive them with Receive…". "{TRD} and {TRR} posted: {q}
    pcs moved from {From} to {To}."; the receipt shows "Posted together with {TRD}".

**Close, cancel, reverse, return**
19. **"Nothing more will be sent…"** (the close permission, a reason): on a released order that has dispatched
    something and still has something to dispatch ("Nothing has been dispatched on {No}: use Cancel order…
    instead."). Not sent = To dispatch on every line; Ordered unchanged; goods on the way can still be received; a
    dispatch reversed afterwards adds to Not sent (the order stays closed); no reopen - a new order covers it. It is
    shown Dispatched or Partly received while goods are still on the way, then Closed. Dispatch is then refused:
    "Nothing more will be sent on {No} (closed on {date} by {name})."
20. **"Cancel order…"** (the cancel permission, a reason): only while nothing is dispatched - a reversed dispatch counts
    as none; no stock effect; the number is kept. Otherwise disabled with "{No} has dispatched goods ({TRD list}):
    reverse them first, or use Nothing more will be sent." A draft is deleted, not cancelled; a waiting order is
    withdrawn first.
21. **"Reverse…"** (the reverse permission) one whole dispatch or receipt, with a reason and a "Reversal date" (today by
    default; "The reversal cannot be dated before {number} ({date})."): opposite rows (`IsReversal = 1`) under its own
    number, the counters back down, status Reversed with "Reversed on {date} by {name}: {reason}". No partial reversal:
    reverse, then post again. A reversed dispatch's pieces go back to From.
22. **The receipt first.** A dispatch whose goods were received or written off waits (62013 "{TRD} has goods received
    by {TRR}: reverse that receipt first."); a receipt only while To still holds what it brought (62007 "Cannot
    reverse: {item} in {To} has only {n} left, but this receipt brought {m}."). A reversed receipt's goods go back On
    the way, not to From, and its write-off is undone. Every Reverse… is disabled with its reason before the click.
23. **"Create return…"** (the create permission): a new draft from the original's To to its From, dated today, "Return
    of {TRO}", linked both ways ("Return of …" on it, "Returns: …" on the original); one line per item with what was
    received less what its returns not cancelled (drafts included) already order, in the unit of the item's first line
    when it is a whole number of it, else in pcs. The original never changes. Refused: "Nothing was received on {No}:
    there is nothing to return." / "Everything received on {No} is already on its returns ({TRO list}): open them."
    Goods turned back before they arrive: reverse their dispatch.

**Dates and Late**
24. Any past date, at most one day ahead (the reader's time zone): a dispatch not before the order date, a receipt not
    before its dispatches, a reversal not before its posting. **Late**, worked out on the server in UTC: a dispatch with
    pieces on the way after its ETA, or a released order, not closed, with something to dispatch after its Expected
    arrival. A red filled "Late" badge, the list's "Late only"; never "Overdue".

**Approval** (Configuration › Document Types, TRO, "Needs approval before release", off by default)
25. **Off:** Release releases. **On:** Release by a user without Approve Transfer Orders is refused (62014 "{No} needs
    approval before it is released: use Send for approval…") and "Send for approval…" (the release permission) takes
    its place: the order waits, locked. An approver **Approves** it (→ Released, the approver's name kept: "{No} approved
    and released."), **Rejects** it with a reason (→ Draft, showing "Rejected by {name} on {date}: {reason}" until it is
    sent again), or the order is **withdrawn** (→ Draft). An approver may **Approve & release** a draft at once
    (recorded as approved and released directly); self-approval is allowed; there is no amount threshold; Back to draft
    means approving again.
26. **Turning the switch** never changes an order already waiting or released: switched off, an order waiting stays
    waiting - an approver approves it, or it is withdrawn and released (Release says "This transfer order is waiting for
    approval: an approver approves it, or withdraw it and release it."); a draft's Approve & release then says
    "Transfer orders need no approval (Configuration › Document Types): release it."
27. **Approvers** are the active users holding Approve Transfer Orders, checked in SQL at the decision (62015 "You may
    not approve transfer orders: it takes the permission Approve Transfer Orders.", for a right removed after sign-in).
    They see the red count beside Inventory › Transfer Orders and the list's "Waiting for approval" switch.
28. **Emails**, through the outbox of 4.4 (categories `TransferApproval`, `TransferApproved`, `TransferRejected`, each
    linked to its order in the Email log): Send for approval emails each approver who also holds View Transfer Orders
    (the link opens the order), through a role that is not the system role - the Admin role's holders only when nobody
    else qualifies - the requester left out: "Approval needed: transfer order {No} ({From} → {To})", the lines and
    "Open the transfer order". Approve tells the requester "Approved: …" ("It is released: the goods can be
    dispatched."), Reject "Rejected: …" with the reason ("It is a draft again: change it and send it for approval
    again."); a requester who decided themselves is not emailed. They are queued only when there is an address of the
    application (Settings › Email "Address of the application", else `App:PublicBaseUrl`, as in 4.4; without either the
    action is done and says "The approvers were not emailed: the address of the application is not set in Settings ›
    Email."; a queue failure: "The approvers could not be emailed: see the API log."), and leave only while "Send
    emails" is on.

**Stock and cost**
29. **One On the way warehouse per branch** (`OTW-{branch code}`, "On the way to {branch} (transfers)"; another free code
    when that one is taken), made by the script for every branch, by the creation of a new branch, and again at the next
    start for a branch that has none. The goods on the road sit there, in the ledger, in the **destination** branch. It
    is never a parent ("An On the way warehouse cannot hold other warehouses. Choose another parent warehouse."), a main
    warehouse, a line's warehouse of any other document (the leaf rule refuses it at save and at posting), an item's
    default (56008 "An On the way warehouse cannot be an item's default warehouse: choose a warehouse where stock is
    kept."), never deactivated, never negative; only its name and address change (52009 "{code} is the On the way
    warehouse of {branch}: transfers use it. Only its name and address can be changed." / "…: it stays active
    (transfers use it)." / "…: it is removed with its branch."). It is deleted with its branch when nothing references
    it. A warehouse named by a transfer order counts as used: it cannot become a parent.
30. **Cost-neutral.** The company's stock never changes during a transfer, except the pieces written off. No transfer
    moves an item's average, last or FOB cost: the rows carry the average at the dispatch for information (the receipt's
    rows the dispatch's), and the cost replay reads the incoming legs at the running average (`docs/notes/costing-rules.md`,
    "Transfers"). A loss goes out at the average; reversing a receipt that wrote pieces off replays its items' costs.
31. **The ledger:** family `Transfer`, types TRD / TRR, the posting's id and number; reasons TRF_OUT (dispatch legs),
    TRF_IN (receipt legs), TRF_LOSS (losses; inactive, so Inventory Out never offers it). Never family Sales, which
    Shortages read as sales. An Inventory In / Out cancel never touches a transfer row.
32. **Elsewhere:** Stock Valuation's company total never changes during a transfer, but by a write-off, and its
    filter offers "OTW-BR-002 - On the way to BR-002 (transfers)"; the item card's stock per warehouse lists the On the
    way warehouse and its statement the TRD / TRR rows ("LKS-01 → LUB-01", linked to the order); sales and Inventory
    Out cannot use goods on the way; the Dashboard of the destination branch counts them in its inventory value ("Includes goods on the way to
    this branch's warehouses (transfer orders)."; the source branch's drops at the dispatch) and its "Stock value by
    warehouse" shows an On the way slice; Inventory In / Out show a hint under the reasons Transfer In / Transfer Out:
    "Moving stock between your own warehouses? Inventory › Transfer Orders moves it without changing its cost and
    follows it on the way."
33. **Shortages** count goods on the way to the plan's warehouse (its tree) as **Transfers in**, a column after Transit,
    added to stock + transit in every formula ("Stock + Transit + Transfers in"). Transfers OUT are not demand, and what
    released orders have not dispatched yet is not counted: the owner has not said the main warehouse buys for the
    branches, and counting either would buy twice. A plan saved before script 90 keeps its figures (Transfers in 0).
34. **Undoing a receipt after a transfer** is still refused per warehouse, and the sentence names the dispatch that
    moved the goods: "Cannot cancel: TVS-APACHE-160 in LKS-01 has only 4 left, but this goods receipt brought 84. 80 pcs
    were moved by TRD-BR-003-000004: transfer them back first." (63007; an Inventory In's 62007 reads "… but this
    document added 84."); when the transfers do not cover the shortfall: "… (10 of them were moved by
    TRD-BR-003-000004.)". Late container charges, LCAs and the goods receipt true-up already split on the company's
    stock (script 89), so a transfer changes none of them. Sales Profit's COGS adjustments stay in the branch that
    received the goods (its header says so on hover): no module keeps per-piece tracking.
35. **Values** (on the way, a posting's value and loss, the frozen costs) only with `inventory.valuation.view`: the
    server sends them empty to others, never 0, and the export leaves them out. The dispatch note never shows a cost.

**Changed from the feedback, and why**
- **Back to draft** (feedback decision 13: while nothing is dispatched) is refused once the order has any dispatch or
  receipt, reversed or not ("{No} has dispatches ({list}): an order that has moved goods cannot go back to draft. Use
  Nothing more will be sent… or Cancel order… instead."): a draft's Save replaces its lines, and a posting's lines must
  never lose their order line.
- **Approval** (feedback decision 18 recommended Release behind a permission only, for now): the owner asked for
  approval now; built as the TRO type's switch, off by default, so nothing changes until someone turns it on.
- **The On the way warehouse is never deactivated** (feedback rule 32: not while it holds stock): inactive, it would
  only break the next dispatch to its branch.
- **The cost replay** (feedback rule 35) needs no restart at the frozen cost when the stock reaches zero: an incoming
  leg with no cost leaves the average where it is, whatever the running balance.
- **Purchase returns keep their stock refusal** (feedback rule 39 named them too): only the goods receipt and
  Inventory In cancels name the transfer; the purchase posting (orders, invoices and returns in one procedure) was not
  re-created for one sentence. Cancel Offload, the sales return cancel and the old invoice cancel keep theirs.
- **The approvers emailed** hold Approve and View Transfer Orders and are outside the Admin role first: Admin holds
  every permission and would get every request.

**What does not change:** Inventory In / Out / BIVAC Out (their save, post, numbering, and their cancel but the end of
the 62007 sentence), sales, purchase orders, invoices and returns, goods receipts (but the end of the 63007 sentence),
containers, movements, charges, LCAs, payments and receipts; every warehouse picker's usual list; every existing
document type's settings, stock reason, attachment "Used for" row and role grant. The import templates' list of
document types gains TRO, TRD and TRR.

**Errors (block 62xxx, shared with the stock documents)**

| No. | Meaning | HTTP |
|---|---|---|
| 62000 | validation (warehouses, lines, dates, reasons; "The order is too large: its lines add up to more pieces than can be counted. Split it into several orders.") | 400 |
| 62004 | changed by another user ("This transfer order was modified by another user. Reload the page and try again.") | 409 |
| 62005 | locked: not a draft | 409 |
| 62006 | not found ("Transfer order not found.", "Dispatch or receipt not found.") | 404 |
| 62007 | not enough stock (dispatch; a receipt's reversal) | 409 |
| 62008 | a transfer type switched off ("Transfer dispatches are switched off: the document type TRD is inactive (Configuration › Document Types).", and the same for TRO and TRR) | 400 |
| 62009 | nothing to post, no lines, everything already dispatched or arrived | 400 |
| 62010 | the status forbids it; another dispatch from the same warehouse is being posted | 409 |
| 62011 | attachment type not used for transfer orders | 400 |
| 62012 (new) | above To dispatch, above On the way | 400 |
| 62013 (new) | a later posting must be reversed first | 409 |
| 62014 (new) | release needs approval | 409 |
| 62015 (new) | not an approver | 403 |
| 52009 (new) | an On the way warehouse is managed by the system | 409 |

What an action is refused for in the order's present state, and every disabled button's reason, comes from one place,
`inventory.fn_TransferOrder_Blocks` (and `fn_TransferPosting_ReverseBlock` for a posting), as the movement's Cancel
(script 83); what a dialog sends (dates, pieces, loss reasons, a reason) is checked by the action's own procedure
after it. The API also refuses a row version that cannot be one ("The row version is not valid. Reload the page and
try again.") and an empty line of a request ("Line {n} of the request is empty."), 400.

---

## 5. The prompts so far

Prompts (`docs/prompts/NN-*.md`) and SQL scripts (`Database/NN_*.sql`) have **separate numbers**. Each prompt has
steps A1, A2… (API project) and B1, B2… (Web project), run in order, each verified before the next.

### 5.1 Prompts 1–31 (before this session; I only know fragments)

**What I know**
- **Script 23:** the Landed Cost Adjustment (LCA) of posted local invoices.
- **Script 24:** the first containers module, "batch 6" (its screens were replaced by batch 8).
- **Script 25:** Shortages and the item's Container unit.
- **Script 26:** purchase-order approval by email (`messaging.EmailOutbox`, `usp_Email_*`, approval tables and
  procedures).
- **Prompt 30:** the approval UI / email outbox worker for script 26. **Replaced by prompt 36** ("Do not run prompt
  30").

**The prompt files in `docs/prompts/`** (checked on 19 October 2026): 02 security-rbac, 03 schema-security, 04
masterdata-branches, 05 masterdata-warehouses, 06 mantine-migration, 07 dev-startup-502, 08 roles-permissions-split,
09 auto-apply-filters, 10 masterdata-currencies, 11 masterdata-itemfamilies, 14 masterdata-pricelists, 15
masterdata-parties, 16 frontend-enhancements-1, 17 sales-invoice-import, 18 inventory-stock-in, 19
inventory-item-import, 20 sales-invoice, 21 sales-import-post, 22 fixes-inventory-docs, 23 document-engine, 24
sales-invoice-full, 25 purchase-shortages, 26 shortage-documents, 27 charge-types-landed-cost. Prompts 1, 12, 13 and
28–31 have no file there; prompts 32–47 were given outside the repositories (5.2 and section 4 say what they asked).

### 5.2 Prompts 32–47

| Prompt | Title / what it does | Status |
|---|---|---|
| **32** | Batch 8 — Containers at the centre (script 27): containers from the PO, invoices from containers, movements, container charges and per-item cost, documents, tracking board (A1–A4, B1–B5) | Done |
| **33** | Batch 9 — Many containers per order (script 28): Auto-plan, bulk actions, Start shipment for the chosen containers, charge copied to other containers, "Create & send" | Done, except its approval steps A4 / B3 (replaced by 36) |
| **34** | Batch 10 — Purchase approval: who approves (in the app / by email), email settings, the whole cycle | A1 done: VS Code wrote the spec as **script 42** (not 29). A2–B3 replaced by 36 |
| **35** | Fix "The request field is required." when saving / posting PINV and PRET | Done: the API no longer adds the implicit [Required] (`Program.cs`); invoices and returns save and post in every test since |
| **36** | Batch 10 final — Email and approval layer: email core (encrypted password, queue, worker, Email log, test), approval endpoints, approval emails, reminders, Settings › Email / Email log / Purchase approval, approval on the PO, Approvals page and badge, public approval page (A1–A3, B1–B4) | Done (leftovers → 42) |
| **37** | Batch 11 — One item per supplier invoice (script 44, error 65029): auto split, refusal, Split by item, Post selected, import | Done (A1, A2, B1 verified 2 Oct) |
| **38** | Charges on a purchase invoice, draft or posted: one "+ Add charge" | Done (`PostedInvoiceChargesCard`: the late charges of a posted local invoice, posted as its LCA; `InvoiceContainerChargesCard` on an imported one) |
| **39** | One purchase-order page from everywhere; disabled buttons with reasons | Done (`orderAbilities.ts`: the order itself decides, a disabled button says why) |
| **40** | Attachment types on every document (updated 4 Oct: one dialog, no direct upload, 20 MB); then documents on every page like Containers (script 67): Documents cards, item documents, a container file re-linked to a movement | Done |
| **41** | Containers from the purchase invoice (script 43): "Shipped in containers", Link / Unlink, Add container / Auto-plan from the PI, container counts | Done. It ran **before** 37, so 37 was adapted |
| **42** | Approval follow-ups after 36: 65016 rule, withdraw reason, create-and-approve warnings, UTC "Z", test emails, Approve confirmation | Done: script 44 (the 65016 rule, the withdraw reason), UTC "Z" (`UtcDateTimeJson.cs`), the create-and-approve warnings, the Approve confirmation. "Prompt 42" ≠ "script 42" |
| **43** | Movement: add containers with checkboxes, Excel / paste list, the place rule (Save / Start checks) | Done, partly superseded by 45. Bilal then saw 404 / 405 (stale API: restart) and a movement started with a never-moved container |
| **44** | Create containers from a purchase invoice: CHECK what exists, then make it work with every validation; Containers card on every PI with reasons | Done: script 51 and the PI's Containers card with its reasons ("Turn on 'Shipped in containers'"). The "missing button" reported earlier was explained: invoice 1227 fully linked; invoice 1322 posted without the switch |
| **45** | Movement: one list with checkboxes that follows the From; Save / Start guards; never-moved rule; validated Excel import, result download, template file | Done: script 53; the movement's container list, the never-moved rule, the validated import ("Tick the {n} valid containers", "Download the result") and the template in `public/templates/` |
| **46** | Container capacity from one place, the item's Container unit; Max Units removed | Done: script 54; capacity from the item's Container unit only, Max Units gone from the screens |
| **47** | Inventory transfer orders (script 90): Inventory › Transfer Orders, a dispatch (TRD) and a transfer receipt (TRR) through each branch's On the way warehouse, cost-neutral; losses, Nothing more will be sent, Cancel order, Reverse (receipt first), Dispatch and receive, returns, Late, the TRO approval switch and its emails, Transfers in on Shortages, the dispatch note (A1, A2, B1) | Done: 4.13 |

### 5.3 Skipped, merged or redone
- **Script 29 (mine):** a standalone version of the approval / email script. Delivered, but **not used**: Bilal chose
  to keep script 42.
- **Script numbers 29–41** are Ali's (sales, receipts, settings, out-of-stock sales, warehouses, import…).
- **Replaced by prompt 36:** prompt 30, prompt 33 A4 / B3, prompt 34 A2–B3.
- **Prompt 41 before 37:** 37 was rewritten to keep what 41 built.
- **Prompt 43's "Add containers…" dialog** is replaced by prompt 45's list; its never-moved rule is tightened by 45.
- **Prompt 44** was written because adding containers from a PI seemed missing. It exists since 41; 44 adds the
  validations and the "why not" reasons.
- **Prompts 40 and 44** were updated after screenshots, on 4 October.

### 5.4 SQL script numbers

| Script | Content |
|---|---|
| 23 | Landed Cost Adjustment |
| 24 | First containers module |
| 25 | Shortages + Container unit |
| 26 | Purchase-order approval and email outbox |
| 27 | Container-centric model (prompt 32) |
| 28 | Bulk containers (prompt 33) |
| 29–41 | Ali |
| 42 | Approval and email settings (prompt 34 A1) |
| 43 | Invoice containers (prompt 41) |

From 42 on, as they are in `Database/` on 11 October 2026:

| File | Content |
|---|---|
| `42_Purchase_ApprovalAndEmailSettings.sql` | Approval rules and approvers, email settings (prompt 34 A1) |
| `43_Purchase_InvoiceContainers.sql` | A purchase invoice and its containers: "Shipped in containers", link / unlink (prompt 41) |
| `44_Purchase_ApprovalFixes.sql` | Approval: the supplier email check (65016) and the withdraw reason (prompt 42 A1) |
| `45_Purchase_OneItemPerInvoice.sql` | One item per supplier invoice (prompt 37; planned as 44) |
| `46_Purchase_Payments_Foundation.sql` | Supplier payments: the tables (US-PAY-001, phase 1) |
| `47_Purchase_Payments_Logic.sql` | Supplier payments: save, post, reverse, allocate (phase 2) |
| `48_Invoice_Lines_Any_Branch_Warehouse.sql` | Sales and purchase lines may take a warehouse of any branch |
| `49_Attachments_Edit_Delete.sql` | Attachments: edit and delete everywhere |
| `50_Logistics_MovementContainers.sql` | Movements: the place rule, the container picker, numbers matched from a list (prompt 43) |
| `51_Purchase_InvoiceContainersFix.sql` | Containers from a purchase invoice: the rules in one place (prompt 44 A1) |
| `52_Attachments_TypesEverywhere.sql` | Attachment types on every document (prompt 40 A1) |
| `53_Logistics_MovementPlaceRules.sql` | Movements: the place rules, never-moved containers (prompt 45 A1) |
| `54_Logistics_CapacityFromItemUnits.sql` | Container capacity from the items' Container units (prompt 46 A1) |
| `55_Attachments_OneEditEverywhere.sql` | Attachments: scripts 49 and 52 merged, one edit for every file |
| `56_Sales_Invoice_Price_List_Rate.sql` | Sales invoice: the price list's rate |
| `57_Item_Stock_Balance.sql` | Item card: stock balance per warehouse |
| `58_Item_Stock_Statement.sql` | Item card: stock statement |
| `59_Item_Purchase_Orders.sql` | Item card: purchase orders |
| `60_Item_Containers.sql` | Item card: containers |
| `61_Item_Unit_Dimensions.sql` | Item units: dimensions and weight |
| `62_Shortage_Warehouse_Tree.sql` | Shortage plan: a parent warehouse counts its whole tree |
| `63_Purchase_OneItemOptional.sql` | One item per supplier invoice becomes optional (setting) |
| `64_Purchase_GoodsReceipts.sql` | Goods receipts: the new objects (tables, procedures, permissions, error block 63xxx) |
| `65_Purchase_GoodsReceiptsSwitch.sql` | Goods receipts: the switch (invoices, containers, movements, costs; one-way) |
| `66_Inventory_BivacOut.sql` | BIVAC Out |
| `67_Attachments_ItemsAndLinks.sql` | Attachments: items and links (prompt 40) |
| `68_Dashboard_Summary.sql` | Ali: the new Dashboard (key figures, "needs attention", charts; schema `reporting`) |
| `69_Stock_Document_Any_Branch_Warehouse.sql` | Ali: Inventory In / Out lines may take a warehouse of any branch |
| `70_Line_Warehouse_Leaf_Any_Branch.sql` | Ali: document lines take a warehouse at the bottom of the tree, of any branch |
| `71_Warehouse_Used_Not_Parent.sql` | Ali: a warehouse already used in transactions cannot become a parent |
| `72_Merge_GoodsReceipts_LeafWarehouses.sql` | The merge of the two lines of work: the procedures both changed hold both changes; goods receipts take the leaf-warehouse rule; the dashboard counts what is still to receive |
| `73_Payment_Allocation_By_Container.sql` | Supplier payments: a purchase invoice linked to two containers or more (or a container and unlinked items) is paid container by container ("Unlinked items" names its items); posting refused until the split adds up; one container alone is recorded by itself |
| `74_Dashboard_Permission.sql` | The Dashboard gets its own permission `dashboard.view` (granted once to every role) |
| `75_Screen_Permissions.sql` | Stock Valuation, Customer Statement, Movements and Tracking get their own view permissions (granted once to the roles holding what each screen borrowed); a container's page keeps its movements and route with View Containers |
| `76_CashBankAccount_No_Branch.sql` | Cash / bank accounts belong to no branch: the Branch is gone from the account, and sales invoices, receipts and supplier payments no longer refuse an account of another branch |
| `77_Purchase_OrderStatusesByInvoicing.sql` | Purchase order statuses: an approved order shows Saved, Partially posted or Posted from its posted invoices (`purchase.fn_PurchaseOrder_Invoicing`); Closed is gone (no auto-close on invoice or goods receipt posting, Close Order refused 65010); the closed orders brought back once, what a close by hand gave up settled short |
| `78_Logistics_AnyNumberOfContainers.sql` | Any number of containers: the 200 ceilings of Auto-plan gone, no SQL error 9829 on long container lists (Supplier Payments, Link containers, the receipt cost preview), numbers never cut, bigger pages for one order's or movement's containers, every "Apply to other containers" candidate, the movement import's 10,000 numbers; new `logistics.usp_Container_OrderDefaults` (supplier, forwarder, country of origin for the dialogs) and `logistics.usp_Container_Lookup` (the container pickers) |
| `79_Configuration_DocumentTypeEffects.sql` | What a document type does: PINV "Affects item cost" (default on) and "Affects on-hand" (default off), GRN "Create goods receipts when a Delivery is completed" (default on), edited in Configuration › Document Types; each invoice captures its two at posting (`AffectsCost`, `ReceiveOnPost`); the cost rule in `purchase.fn_GoodsReceiptLine_TargetCost`; returns from a non-cost invoice at the receipt cost; LCA refused 67013; the Delivery hook and `usp_Movement_Get` read the GRN switch |
| `80_Logistics_ShipFromTheContainer.sql` | Shipment phase 1, ship from the container: `logistics.fn_Container_ShipState` (where a container is, its movement in progress, its next planned one, its last completed one) on `usp_Container_Search` / `_Get`; `logistics.fn_Movement_StartBlock` (why a planned movement cannot start yet, its earliest start) on `usp_Movement_Search` / `_Get`; `usp_Movement_SetStatus` refuses a date in the future (70000) and a start before the previous leg ended (70018), and `usp_Movement_Save` the same for the start date of a movement in progress; `fn_ContainerFitForMovement` refuses a container on a movement older than a leg it already made; `usp_Movement_ShipContainers` leaves from where moved containers are; new `usp_Movement_JoinCandidates` |
| `81_Logistics_NextStep.sql` | Shipment phase 2, Next step everywhere: `logistics.fn_Container_NextStepKind`, `fn_Movement_NextLegHistory` (the usual next leg from a place), `fn_Container_NextLegProposal` (history, else the container's ports, else the stages), `fn_Container_NextStep`, `fn_Container_PreviousMovement`; `usp_Container_NextStepPreview` (the ticked containers grouped by step, the blocked ones by reason); `usp_Movement_AddLeg` (a new leg for a group, one movement or one per container, with `tvp_LegContainer`); `usp_Container_Search` (the next step of the page's rows and the `@NextStep` filter; the page found first, then its rows worked out) and `usp_Container_Get`; `usp_Movement_SetStatus` refuses cancelling a leg that is not a container's last (70010; a planned leg already passed by a later one may be cancelled); `usp_Movement_AddLeg` refuses a vessel or truck leg from a place to itself (70000); `fn_Movement_StartBlock` and the 70016 / 70018 checks read each container's previous leg for itself (a list and a Start were slow on 50,000 containers) |
| `82_Logistics_ShipmentsBoard.sql` | Shipment phase 3: `logistics.fn_Container_BoardPhase` (a container's column on the Shipments board) and `usp_Shipment_Board` (the board, set-based for its rows, the usual next leg once per place and last stage); the permission `containers.shipments.view` (granted once); only part of a movement arriving: `logistics.Movements.SplitFromMovementId`, `logistics.MovementAudit`, `fn_Movement_SplitBlock`, `usp_Movement_SplitContainers`; `usp_Container_NextStepPreview` and `usp_Movement_Get` say whether a container can be split off and why not (`usp_Movement_Get` also gives the movement's history and the movement it was split from); the container page's estimated FOB follows the cost rule and the matching of the goods receipt (`fn_ContainerLine_FobEstimate`, read by `usp_Container_Get`); a container followed by typed dates in the column of its status; a voyage split in two counted once in the usual next leg (`fn_Movement_Voyage`; `fn_Movement_NextLegHistory` re-created from 81); cancelling a split-off movement undoes the split, its containers back on the movement they came from with their charges and documents (`usp_Movement_SetStatus` re-created from 81, `fn_Movement_SplitUndoTarget`; `usp_Movement_Get` says where they go back, for the Cancel dialog) |
| `83_Logistics_CancelBlock.sql` | A movement that cannot be cancelled says why before the click: new `logistics.fn_Movement_CancelBlock` (whether a movement can be cancelled now and the first refusal of its Cancel, its number and words: already cancelled, a container received or closed, not the last leg of a container); `usp_Movement_SetStatus` re-created from 82, its Cancel refusals the function's answer, said before "A cancellation reason is required."; `usp_Movement_Get` re-created from 82, + `CanCancel` and `CancelBlockedReason` (the movement page disables "Cancel…" with the reason) |
| `84_Sales_Cancel_Date.sql` | Cancelling a posted sales invoice or return asks for a date next to the reason (today by default, not in the future, not before the document date): stored as `CancelDate`, the date of its reversal stock movements |
| `85_Shortage_Max_Monthly_Sales.sql` | Shortages: Expected Monthly Sales is the busiest month of the months of history (net sales per one-month block counted back from today), no longer the average |
| `86_Purchase_InvoiceFromOrderLines.sql` | Create Purchase Invoice on an order, line by line like Create Invoice from Containers: new `purchase.usp_PurchaseOrder_InvoiceCandidates` (per order line ordered, invoiced, in draft invoices, available - the rule of `usp_PurchaseDocument_CreateFromSource`'s selection, which the API now sends) |
| `87_Item_Note_Link.sql` | Item Definition: a Note (several lines, 2,000 characters) and a Link (an http/https address opened in a new tab) on the item: columns `inventory.Items.Note` / `Link`, `usp_Item_Get` re-created from 61 with both, new `inventory.usp_Item_SetNotes` (called after create / update, like `usp_Item_SetPurchasing`; refuses a link that is not http/https or has a space, 56000). The item page also gets a sticky header with Previous / Next through the Items list as filtered |
| `88_Logistics_ChargeOneLine.sql` | A charge on a container of one line takes it whole: `logistics.usp_ContainerCharge_Allocate` re-created from 27 - the only line with pieces gets the whole charge whatever the method (no price, weight or volume needed); several lines all at price 0 by value are refused naming each line and the source of its price (order, draft or posted invoice, goods receipt); every refusal names the container (70013 as before). The charge import warns about a missing weight or volume only on a container of several lines |
| `89_Fixes_CostsCancelsShortageDocumentTypes.sql` | Fixes: `logistics.usp_ContainerCharge_ApplyCost` (from 27) and `purchase.usp_LandedCostAdjustment_Post` (from 79) split a late charge on the company's stock, per item, as GRNCOST (a cancel never takes more out of stock than its posting put in); `inventory.usp_StockDocument_Cancel` (from 15) reverses only its own type and, like `sales.usp_SalesDocument_Cancel` (from 84), replays its items under the matching lock (the items of documents cancelled before replayed once, `inventory.OneTimeSteps`); `inventory.usp_ShortageDocument_CreatePurchaseOrder` (from 22): a plan for a parent warehouse puts each line in a leaf of its tree, in one transaction (66000 when there is none); the five per-start seeds of Document Types narrowed to types nobody saved; script 19's per-start backfill of item costs no longer counts a posting that was reversed (edited in place, like the seeds); the two cancels give way in a deadlock (`DEADLOCK_PRIORITY LOW`: the API runs them again, a posting has no retry) |
| `90_Inventory_TransferOrders.sql` | Transfer orders, dispatch and receipt, with approval (prompt 47): new tables `inventory.TransferOrders`, `TransferOrderLines`, `TransferPostings`, `TransferPostingLines`, `TransferOrderAudit`, `TransferOrderFiles`; `masterdata.Warehouses.IsTransit` and one On the way warehouse per branch (`masterdata.usp_Warehouse_EnsureTransit`, run at each start for every branch that has none, and by a new branch); document types TRO, TRD, TRR and `inventory.DocumentTypes.NeedsApproval`; stock reason TRF_LOSS (inactive); `inventory.fn_TransferPosition`, `fn_TransferOrder_State` (the shown status, Late), `fn_TransferOrder_Blocks` (an action's refusal in the order's state, every disabled reason), `fn_TransferPosting_ReverseBlock`, `fn_Transfer_MovedOutNote`; the procedures of the order, its approval (`usp_TransferOrder_Approvers`), dispatch, receipt, Dispatch and receive, Nothing more will be sent, cancel, reverse, ETA, return and files; ten permissions `inventory.transfers.*` (855-890) granted once; re-created: the warehouse, branch and item procedures (the On the way rules), `masterdata.fn_Warehouse_IsLeaf` / `_IsUsed`, `inventory.usp_DocumentType_List` / `_Update`, `usp_Item_RebuildCosts` (incoming transfer legs at the running average), `usp_Item_StockStatement`, `fn_Shortage_Live` and the three shortage procedures (Transfers in; `ShortageDocumentLines.TransfersInBase`, its four formula columns re-added), `purchase.fn_GoodsReceipt_CancelCheck` and `inventory.usp_StockDocument_Cancel` (the refusal names the transfer). Script 19's per-start backfill of item costs no longer counts transfer rows (edited in place, as 89 did) |

**Two lines of work, one numbering (12 October 2026).** After script 62 the work on GitHub (63–67) and Ali's work on
GitLab both numbered their next scripts from 63. At the merge Ali's 63–66 became **68–71**, with only the numbers they
give themselves changed (they had already run on his database), and run after 63–67. Scripts 69 and 70 re-create six
procedures from bodies written before 63–67 (`inventory.usp_StockDocument_ValidateInput` / `_Post`,
`purchase.usp_PurchaseDocument_ValidateInput` / `_Post`, `sales.usp_InvoiceImport_Validate`,
`logistics.usp_Container_Offload`); **script 72** re-creates each from Ali's body plus our change (BIVAC check, goods
receipts, the retired offload), so every start-up ends with both. Ali's database had run his 63–66 under those numbers:
at its next start Schema.sql runs 63–67 (ours, the switch included), then 68–71 again (idempotent) and 72.
`DatabaseProject` is Ali's refresh (scripts 46–66 in his numbering); it is refreshed on Bilal's PC after the merge.

Scripts 44, 50, 51, 53 and 54 show that prompts 42, 43, 44, 45 and 46 ran at least their A1 step: check the code
before trusting the statuses of 5.2. The next script takes the next free number after a pull (Ali writes scripts too).

---
## 6. What's next

### 6.1 What's next (19 October 2026; the developer decides)
Every written prompt (32–47) is built, and so is every script up to the last one in 5.4. What is left:
1. **Release the scripts after 72 to production** (production runs up to 72): on testing first (the Deploy to
   server button, or `sudo ./update.sh`; `copy-production-to-testing.sh` to rehearse on production's data), then a
   pull request `main` → `production` in both repositories, and the button with production. Script 77 changes data
   once (closed orders back to approved); script 90 adds an On the way warehouse to every branch, the TRO / TRD / TRR
   document types and the ten transfer permissions with their one-time grants (3.8); `update.sh` backs the database
   up first.
2. **The Containers User Guide** (6.2): rewrite it for goods receipts and the three shipment phases.
3. **The Deploy to server button's one-time setup** (`deploy/README.md`, "Deploying with a button"):
   `enable-github-deploy.sh` on the server and its secrets in both repositories.
4. **Optional:** let the movement-types lookup accept Manage Shipment Movements, so a reader without View Containers
   could use Next step… from the Shipments board (today the board leaves the step out for such a reader, 4.6).

### 6.2 Open requirements not yet in a prompt
- Update the **Containers User Guide** (Word, 31 pages, v1.0, September 2026, delivered to Bilal outside the repos).
  It is outdated in chapters 5 (Max Units, Auto-plan's typed pieces), 7 (one item per invoice, invoice-first
  containers) and 8 (movement containers list, place rule). **Goods receipts** change it again, in those chapters and
  wherever it shows the Offload: posting the invoice adds no stock, a Delivery completed drafts the goods receipt, the
  warehouse posts it with Receive goods…, Cancel goods receipt replaces Cancel Offload, and Close needs every received
  piece invoiced.
- **Goods receipts go-live:** rehearse on testing, then production (`deploy/README.md`, "Goods receipts go-live").
  The switch is one-way (4.12).
- `tools/check-repo.sh` now exists (refused names on Windows, capitals, cache files, the .sqlproj list), with a
  pre-commit hook: `git config core.hooksPath .githooks` once per clone. **[Done]**
- **Production:** the "Address of the application" for email links (a real URL), and possibly a company mailbox
  (Microsoft 365 / Google Workspace) instead of the Gmail account. Not discussed yet.

### 6.3 Known problems and things to remember
- **A stale API after new code** shows 404 / 405 on new endpoints, or "Not found" on new pages. `npm run dev` reuses
  an API already running on 7089. Fix:
  `fuser -k 7089/tcp 5174/tcp && cd …/Inventory_Shipment.Web && npm run dev`.
- **API start fails with SQL error 18456** (login failed): the API's connection string doesn't hold Bilal's sa
  password. After the merge ff3f905, `appsettings.json` holds AJ's connection string or a placeholder.
  - Fix given: add, as line 2 of `~/.bashrc`, `export ConnectionStrings__<Key>="Server=localhost;Database=Inventory_Shipment;User Id=sa;Password=$SQLCMDPASSWORD;TrustServerCertificate=True"`.
  - The key name comes from appsettings; DefaultConnection was assumed. Whether Bilal applied it is unknown.
- **Ali's PC:** IIS Express locks the DLLs; port 5174 can stay busy; he starts with `npm run dev`.
- **GitHub is the team repository**: `origin` = `github.com/bfa-14/Inventory_Shipment` for the API and
  `github.com/bfa-14/Inventory_Shipment_Frontend` for the Web. A clone pointing anywhere else is out of date: switch it
  with `git remote set-url origin <the GitHub address>` (`deploy/README.md`, "The repositories: GitHub").
- **Commit status:** at the last check the work of prompts 36 (rest), 41 and 37 was uncommitted. I gave a commit
  plan: by feature; never commit `appsettings.Development.json`, `App_Data/` or screenshots; `git pull --no-rebase
  origin main`; push. Whether it was done is unknown, and 43 came after.
- **Test data in Bilal's database:**
  - orders 1136–1146; KTG-2026-0022; PO-BR-002-000048; PINV-BR-002-000033; KTG-2026-0031..0033; TEST41-A with stock;
  - posted invoices **1076 and 1078** (mode 2) with pieces outside containers: link them or cancel them;
  - item **TEST38-A Container unit = 1** (should be 120);
  - **MOV-2026-000046** in progress with never-moved container KTG-2026-0018.
- **Test users with `@example.com` emails** (manager1@example.com) bounce back to the system mailbox. Use real
  addresses or Gmail "+" aliases (`name+manager1@gmail.com`).
- **Email links** point to `http://localhost:5174`, so they work only on Bilal's PC.
- **The Owner role has no users**, so no Owner copies are sent.
- **Ali's database** will get scripts 42+ at his next API start after he pulls. His purchase orders will then need
  approval (Settings › Purchase approval). With scripts 64–65 his database also **switches to goods receipts**: his
  supplier invoices stop moving stock. He should save his work before that pull (`git pull --no-rebase`).

### 6.4 Decisions still pending (with the options considered)
- **Never-moved containers on a movement:** settled - (b), built by script 53 (prompt 45): from their port of
  loading, or on an Origin movement ending at it; a container without a port of loading leaves from any From.
- **Container units per container type,** if 20GP comes back into use:
  - (a) one Container unit per item (decided for now);
  - (b) container unit types linked to a container type.
  - Not needed while only 40HC is active.
- **"Create Invoice" preview count** when the order already has draft invoices (it can announce one invoice too
  many; the result is right):
  - (a) leave it;
  - (b) an API preview that excludes quantities in drafts **(check the code: prompt 39 is built; whether this came
    with it is not checked)**.
- **Script numbering with Ali:**
  - (a) pull before numbering, and tell each other (advised);
  - (b) separate number ranges.
- **The production mailbox and links:** see 6.2.

---

## 7. How we write prompts

### 7.1 The way we work
1. **Bilal describes a need,** often in short English with screenshots. Read the screenshots carefully.
   - If the need is unclear, ask 1–4 multiple-choice questions, each with the recommended option first, marked
     "(Recommended)".
   - Otherwise decide sensible defaults and state them.
2. **Check what already exists** before designing: earlier prompts and scripts, and the code. Several "missing"
   features already existed and only needed explaining (adding containers from an invoice; the email settings page
   on a stale API).
3. **Write `docs/prompts/NN-short-title.md`** and give it to Bilal. He saves it, then pastes each step into VS Code
   Claude in order: A steps in the API project, B steps in the Web project.
4. **VS Code Claude writes the SQL** from our specification (it has the real current procedure bodies), applies it,
   codes the API and the web, tests, and **reports**. Bilal pastes the report.
5. **Review the report:**
   - say whether it is done;
   - judge the deviations;
   - update the upcoming prompts if something changed (for example 41 before 37);
   - give the next steps (commit, restart, next prompt).
6. **Answer Bilal briefly** in plain English: short paragraphs, a few bullets, commands in code blocks. Explain the
   cause first, then the fix.

### 7.2 The layout of a prompt file
- **Title:** `# <What it does> (prompt NN)`; big ones start with "Batch N —".
- **Opening:** "What it does", or "Reported:" + "Wanted:", in business words.
- **"Rules decided":** numbered rules in plain words, with the exact user messages in quotes and the error numbers.
- **Order note:** "Run after prompt 35", "Independent of prompts 38–42", "Replaces prompt 34 steps A2–B3".
- **Steps table:** `| Step | Project to open in VS Code | Deliverable |`.
  - A1 = SQL script (sqlcmd verification); A2 = API C# (curl verification); B1 = Web (full UI check with
    screenshots).
  - Bigger work adds A3, B2… and may put C# in A1 when the SQL is small.
- **The SQL line, always present:** "How the assistant runs SQL (never print the password):
  `eval "$(grep '^export SQLCMDPASSWORD=' ~/.bashrc)" && sqlcmd -S localhost -U sa -C -I -d Inventory_Shipment ...`
  in ONE command; never run that grep on its own."
- **Each step is one ```text block** that VS Code Claude receives as is. It starts with:
  - API: "You are working on /home/bilal/VSProjects/InventoryShipment-Project/Inventory_Shipment (.NET 10
    solution)."
  - Web: "…/Inventory_Shipment.Web (React 19, Vite, TypeScript, Mantine 9, mantine-datatable). Read
    docs/frontend-conventions.md first. Frontend only."
  - Then the boundaries: "Do not touch the Web project and write no C# in this step."
- **SQL steps:**
  - **READ FIRST:** the CURRENT definitions, i.e. the last ones in `Schema.sql`; the C# callers (`grep -rn …`); the
    free error numbers (`grep -o "THROW 650[0-9][0-9]" … | sort -u`).
  - **PART 1 CHECK** (a report table, changing nothing) when the current state is uncertain, as in prompts 44 and 46.
  - **WRITE** `Database/NN_Module_Name.sql`, NN = the next free number, "in the style of scripts 27, 28 and 42":
    - header: the rules, the procedures changed, the new errors;
    - `USE` batch;
    - guard: "requires script X";
    - numbered sections;
    - every changed procedure **re-created with CREATE OR ALTER from its CURRENT body plus the change**;
    - a Check section;
    - **idempotent** and **additive only**: never drop or rename; keep legacy columns and parameters, ignored.
  - **APPLY:** sqlcmd `-I` twice (the second run clean); append to `Schema.sql` after the last script "the usual
    way"; restart the API twice ("Database schema verified"); `tools/refresh-dbproject.sh`; git status.
  - **VERIFY:** lettered cases (a, b, c…) on test data "TEST-NN"; show every result; delete or cancel the test data at
    the end and report what is left. "Stop here and report; do not start the C# work."
- **API steps:**
  - TASK: routes, bodies and responses in camelCase, permissions, error mapping (SQL number → 400 / 404 / 409 with the
    SQL message), build with 0 warnings, the API starts.
  - VERIFY with curl ("token from POST api/auth/login", admin test login), showing every response.
- **Web steps:**
  - TASK numbered, with **exact UI texts in quotes**: labels, hints, tooltips, notifications, confirmations, empty
    states.
  - Quality: "typecheck / lint / build clean, no console errors, 1440 and 390 px".
  - **FULL CHECK through the UI, a screenshot of each step**, then "Report the files changed and every step that did
    not behave as described."

### 7.3 Conventions
- **SQL:**
  - Schemas `security`, `masterdata`, `inventory`, `sales`, `purchase`, `logistics`, `messaging` (never dbo).
  - **Stored procedures only** (Dapper); names `schema.usp_Entity_Action`, table types `tvp_*`, functions `fn_*`.
  - RowVersion checks.
  - `THROW` with the module's error numbers and plain-English messages that say what to do.
  - A data step that must run once per database records itself in `inventory.OneTimeSteps` (script 89); never use a
    procedure body as a marker: Schema.sql re-creates the older bodies first at every start.
- **`Schema.sql`** is re-applied at every API start and stops at the first error. So:
  - never edit an older script;
  - keep older batches compilable;
  - use `sqlcmd -I` (QUOTED_IDENTIFIER ON), needed because of filtered indexes.
- **Error ranges:**
  - 65xxx purchase (65000 validation, 65004 concurrency, 65006 not found, 65010 not draft, 65013–65029 as listed in
    section 4);
  - 67xxx landed cost adjustments;
  - 69xxx containers (69000 validation, 69005 not editable, 69006 not found, 69007 over capacity, 69008 more than the
    order line allows, 69009 nothing to create, 69013 container number used, 69016 not fully invoiced, 69017 line
    invoiced, 69018 cost adjusted);
  - 70xxx logistics (70000 validation, 70001 duplicate, 70004 concurrency, 70005 not editable, 70006 not found, 70010
    invalid status, 70012 container busy, 70013 allocation data missing, 70014 in use, 70015 / 70016 place rules);
  - Ali's ranges for sales **(unknown)**.
  - HTTP: validation → 400, not found → 404, the rest → 409.
- **Permissions:** code `module.entity.action` with Name, Module, Description and SortOrder. Seeded to the system
  administrator role; sensitive ones administrator-only by default.
- **API:** .NET 10, controllers → services → repositories (Dapper); JSON camelCase; routes `api/purchase/documents/…`,
  `api/logistics/…`, `api/settings/…`.
- **Web:**
  - React 19, Vite, TS, Mantine 9, mantine-datatable; `docs/frontend-conventions.md` (VS Code adds rules to it, for
    example "One item per supplier invoice").
  - Lists: FilterBar + table. Details: Drawer. Actions: Modals.
  - Status badges by color; orange Alert for warnings, red for errors, gray hints.
  - **Buttons stay visible but disabled, with a tooltip saying why**; hidden only without the permission.
  - Confirmation before impactful actions; a notification after actions ("Approved: {number}"); an unsaved-changes
    warning.
  - 409 shows "Someone else changed … Reload the page."
  - **API messages are shown as they come.** Pages work at 1440 and 390 px.
- **Words:**
  - Buttons that open a dialog end with "…"; menu paths use "›"; quantities in "pcs".
  - Examples use realistic references (KTG-2026-0031, MOV-2026-000012, PO-BR-002-000042, Chennai → Dar es Salaam →
    Kasumbalesa → Lubumbashi).
  - Messages say what happened and what to do.
- **Every feature prompt covers database → API → web,** verified at each step. Frontend-only prompts say "if the API
  does not return something the page needs, report it instead of working around it."
- **Never put passwords, keys or tokens** in prompts, chat or logs.

### 7.4 A complete prompt we used (prompt 37, done and verified)
*Copied in full. Only the admin test password is replaced by `<admin password>`.*

````markdown
# Batch 11 — One item per supplier invoice: automatic split, and refused otherwise (prompt 37)

**Rule:** a supplier invoice (PINV) holds **one item**. It may have several lines of that item (several containers,
warehouses or expiry dates), never two different items. It applies to every supplier invoice. Purchase orders and
purchase returns are not concerned; invoices already posted stay as they are.

- **Automatic split:** "Create Invoice from Containers…" (order and container pages), "Create Invoice" from an order
  and the Excel import of invoices create **one draft invoice per item**, all at once. The exporter's reference and the
  commercial invoice number can be typed once in the dialog and are copied to every invoice.
- **Refused otherwise:** saving or posting an invoice with two different items is refused with a clear message. A
  draft made before this change can be fixed with **Split by item**.
- **Less typing:** "Post selected" posts several draft invoices of an order at once; the invoice list shows the item.

Run prompt 35 (the "request field" bug of invoices) before this one. **Prompt 41 is already done (script 43):** this
prompt keeps everything it added - the "Shipped in containers" switch (receipt mode 2), the links between invoice
lines and container lines, Link / Add / Auto-plan from the invoice. Steps in order, verify each one:

| Step | Project to open in VS Code | Deliverable |
|---|---|---|
| A1 | `Inventory_Shipment` (API) | script 44 written from the specification, applied twice, in Schema.sql — sqlcmd |
| A2 | `Inventory_Shipment` (API) | endpoints: several invoices created, split by item, post selected, import — curl |
| B1 | `Inventory_Shipment.Web` | dialogs, invoice page, order page, invoice list, import result — full check |

How the assistant runs SQL (never print the password): `eval "$(grep '^export SQLCMDPASSWORD=' ~/.bashrc)" && sqlcmd -S localhost -U sa -C -I -d Inventory_Shipment ...`
in ONE command; never run that grep on its own.

---

## A1 — API project: write and apply script 44

```text
You are working on /home/bilal/VSProjects/InventoryShipment-Project/Inventory_Shipment (.NET 10 solution).
Do not touch the Web project and write no C# in this step. This step writes ONE SQL script and applies it.

RULE: a supplier invoice (document type PINV) holds ONE item: any number of lines, all with the same ItemId. Purchase
orders and returns are not concerned. Posted invoices are not changed.

READ FIRST (do not change these files)
- The CURRENT definitions (the last ones in Inventory_Shipment.Repository/Database/Schema.sql) of
  purchase.usp_PurchaseDocument_Save, _Post, _CreateFromContainers and _CreateFromSource; how Save computes the totals
  of a document (items, quantity, subtotal, discount, amount, amount in base currency) and writes the audit; how
  invoices are linked to containers: only the ContainerLineId of each invoice line (logistics.ContainerInvoices is an
  unused leftover: never write it). Script 43 (prompt 41): receipt mode 2 = "Shipped in containers",
  usp_PurchaseInvoice_LinkContainers / _UnlinkContainer / _LinkCandidates / _ContainerSummary, the @ForInvoiceId
  parameter of the container procedures.
- Every C# caller of these procedures: grep -rn "usp_PurchaseDocument_" --include=*.cs
- The free error numbers: grep -o "THROW 650[0-9][0-9]" Inventory_Shipment.Repository/Database/Schema.sql | sort -u
  (65026-65028 are taken by script 43: 65029 is expected to be free; otherwise take the next free one and report it).

WRITE Database/44_Purchase_OneItemPerInvoice.sql (the next free number if 44 is taken), in the style of scripts
27, 28 and 42: header (the rule, the procedures changed, the new error), USE batch, guard (requires script 42), numbered
sections, each changed procedure re-created with CREATE OR ALTER from its CURRENT body plus the change, a Check
section, idempotent (re-applied at every start-up).

1. usp_PurchaseDocument_Save: for a PINV whose lines hold more than one ItemId -> THROW 65029
   'A supplier invoice holds one item. This one has {n}: {code1}, {code2}... Create one invoice per item, or use
   Split by item.' (item codes in line order, at most 5, then "..."). Nothing else changes.
2. usp_PurchaseDocument_Post: the same check before posting a PINV (drafts saved before this script).
3. usp_PurchaseDocument_CreateFromContainers: creates ONE DRAFT PER ITEM of the selection (items in the order of their
   first line), each exactly the way one invoice is created today (header, lines, container links, totals, audit), all
   in one transaction (all or nothing). New optional parameters @ExporterReference NVARCHAR(50) = NULL and
   @CommercialInvoiceNo NVARCHAR(50) = NULL (use the column sizes of the table), copied to every created invoice.
   @NewId OUTPUT = the first created invoice, so the existing callers keep working. Returns one row per created
   invoice: Id, ItemId, ItemCode, ItemName, LineCount, QuantityBase, TotalAmount, RowVersion.
4. usp_PurchaseDocument_CreateFromSource: when it creates invoices from a purchase order (PO -> PINV), the same split,
   the same optional parameters and the same rows (@NewId = the first); each invoice gets the receipt mode script 43
   gives (2 when the order has containers). Other pairs (e.g. PINV -> PRET) unchanged.
4b. The procedures of script 43 stay valid with one item per invoice: LinkCandidates / LinkContainers only deal
   with the invoice's item; splitting a line per container line keeps one item. Check it in VERIFY.
5. NEW purchase.usp_PurchaseDocument_SplitByItem(@Id INT, @RowVersion BINARY(8) = NULL, @UserId INT):
   - a DRAFT PINV only (65010), RowVersion check (65004), 65000 'This invoice already holds one item.' when it does;
   - the item of the first line stays on the invoice; for every other item a new draft with the same header (every
     header column except the identity, the number, the status / posting / cancel / close columns, the totals and
     RowVersion), its lines moved there (LineNumber from 1 in each invoice, every other column kept);
   - the moved lines keep their ContainerLineId (that is the container link) and the new invoices keep the receipt
     mode ("Shipped in containers") of the original: nothing else to update for containers; the files and charges of
     the original stay on it;
   - the totals of every invoice recalculated the way Save does; audit "Split by item into ..." on each invoice;
   - one transaction; returns the rows of 3 for the original then the new invoices.
6. Check section: the DRAFT PINVs that hold more than one item (Id, number, supplier, item count): they must be split
   before they can be posted. PRINT 'Script 44 applied: ...'.

APPLY
1. sqlcmd -I, show the whole output; run it a SECOND time: clean.
2. Append it to Inventory_Shipment.Repository/Database/Schema.sql after script 42, the usual way.
3. Restart the API twice: "Database schema verified", clean start. Existing calls still work (@NewId).
4. tools/refresh-dbproject.sh; show git status.

VERIFY with sqlcmd on test data (notes start with "TEST-44"; cancel or delete them at the end and report what is left):
 a. An approved PO of 3 items loaded into 2 containers: CreateFromContainers with an empty selection -> 3 drafts, one
    item each, totals = their lines, container links right; with @ExporterReference 'EXP-44' -> on all 3.
 b. CreateFromSource PO -> PINV on an order that is not in containers, 2 items -> 2 drafts.
 c. Save of a PINV with 2 items -> 65029 with its message; 1 item over 2 lines -> saved.
 d. A draft PINV with 3 items inserted directly (as made before the script): Post -> 65029; SplitByItem -> 3 drafts,
    lines renumbered, totals and container links right; each one then posts.
 e. A return from a posted invoice and a PO save still work.
 f. Script 43 still works on the new invoices: a per-item invoice created from an order with containers is
    "Shipped in containers"; Link containers / Add container / Auto-plan from it work as in prompt 41.
Stop here and report; do not start the C# work.
```

---

## A2 — API project: several invoices created, split by item, post selected, import

```text
You are working on /home/bilal/VSProjects/InventoryShipment-Project/Inventory_Shipment (.NET 10 solution).
Do not touch the Web project. Script 44 (one item per invoice) is applied: read its header. Follow the style of
the purchase module.

TASK
1. The endpoints that create invoices from containers and from an order (find them: create-from-containers / invoice
   candidates of batch 8, and the "create invoice" of an order): new optional body fields exporterReference and
   commercialInvoiceNo; the response becomes { firstId, invoices: [{ id, itemId, itemCode, itemName, lineCount,
   quantityBase, totalAmount }], message } with message "3 invoices created, one per item" (or "Invoice created").
   Keep the field the page uses today for the id (= firstId) so the current page keeps working until B1.
2. POST api/purchase/documents/{id}/split-by-item { rowVersion } (the edit permission of invoices) -> { invoices: [...] }.
3. POST api/purchase/documents/post-many { ids: [] } (the post permission of invoices): posts each draft with the
   existing post logic, one after the other and independently (one refusal does not stop the others) ->
   [{ id, ok, documentNumber, message }].
4. Excel import of supplier invoices (the import that came with Ali's commits): rows of several items -> one invoice
   per item with the same header values; the result lists every invoice created.
5. Error mapping: 65029 -> 400 VALIDATION with the SQL message.
6. Build with 0 warnings; the API starts.

VERIFY with curl (token from POST api/auth/login, admin / <admin password>), test data "TEST-44", show every response:
  a. create from containers on an order of 3 items -> 3 invoices in the response; with exporterReference -> on all.
  b. create from an order of 2 items (not in containers) -> 2 invoices.
  c. PUT of an invoice with a second item -> 400 with the 65029 message.
  d. split-by-item of a 3-item draft (insert it with sqlcmd) -> 3 invoices; post-many of the 3 -> 3 ok with numbers;
     post-many with one invoice that cannot be posted (e.g. no exporter's reference) -> that one ok false with its
     message, the others posted.
  e. Excel import of a 2-item invoice file -> 2 invoices.
Report the files changed, each result, and the test data left.
```

---

## B1 — Web project: dialogs, invoice page, order page, invoice list, import

```text
You are working on /home/bilal/VSProjects/InventoryShipment-Project/Inventory_Shipment.Web (React 19, Vite, TypeScript,
Mantine 9, mantine-datatable). Read docs/frontend-conventions.md first. Frontend only. The API has the endpoints of
prompt 37 A2.

TASK
1. "Create Invoice from Containers…" (order page and container page) and "Create Invoice" (from an order): a line under
   the selection "One invoice per item: {n} invoices will be created ({code1}, {code2}...)" from the ticked lines;
   optional "Exporter's ref." and "Commercial invoice no." with the hint "copied to every invoice". After creating:
   one invoice -> open it as today; several -> a modal "{n} invoices created, one per item" listing them (invoice,
   item, quantity, total, an Open link) with "Go to the order's invoices".
2. Purchase invoice page: once a line exists, the item of the other lines can only be the same item (other items
   disabled in the picker, hint "A supplier invoice holds one item: create another invoice for other items."). A draft
   that holds several items (made before) shows an orange Alert "This invoice holds {n} items: split it before posting"
   and a "Split by item" button (confirm) -> the modal of 1. The 65029 message is shown as it comes.
3. Purchase order page, its invoices card: checkboxes on the draft invoices and "Post selected" -> post-many -> a result
   list (posted with its number / refused with the message), then the card refreshes.
4. Purchase invoice list: an "Item" column (code - name); the search also matches the item code.
5. Excel import of invoices: the result shows every invoice created, with Open links.
6. Quality: typecheck / lint / build clean, no console errors, 1440 and 390 px.

FULL CHECK through the UI, a screenshot of each step: an approved order of 3 items in 2 containers -> Create Invoice
from Containers with an exporter's ref. -> the modal lists 3 invoices -> each holds one item and the ref. -> the order
page: tick the 3 drafts -> Post selected -> 3 numbers; a second item on a draft invoice is not possible; a 3-item draft
made before the change (ask the API step's data) -> Split by item -> 3 invoices; the invoice list shows the items; an
Excel import of 2 items -> 2 invoices; a return from one of the invoices still works. Report the files changed and
every step that did not behave as described.
```
````

---

## 8. Anything else you need to continue without asking Bilal again

### 8.1 Environment
- **Bilal's machine (Ubuntu):**
  - API `https://localhost:7089`, Web `http://localhost:5174` (Vite).
  - `npm run dev` in `Inventory_Shipment.Web` runs `scripts/dev.mjs`: it starts the API (unless one already answers
    on 7089), waits until it is ready, then starts Vite.
  - SQL Server on localhost, database **Inventory_Shipment**, sign-in user `sa`.
  - The password is in `~/.bashrc` (first line, `export SQLCMDPASSWORD=…`, chmod 600) and is loaded only with the
    eval line in section 7.2. Never print it, never run that grep alone.
- **VS Code Claude** tests on its own ports (7189 / 5175, then 7289 / 5275), stops them after, and tells Bilal to
  restart his own session.
- **API start-up:**
  - `DatabaseInitializer` creates the database if it is missing, then applies `Schema.sql` batch by batch:
    "Database schema verified (N batches)".
  - The connection string comes from `appsettings.Development.json`. That file is **skip-worktree**: never edit,
    print or commit it. An environment variable can override it (6.3).
- **Database project:**
  - `DatabaseProject` (SSDT .sqlproj) mirrors the database. It is refreshed only by `tools/refresh-dbproject.sh`,
    which stops when the branch is behind the remote.
  - `tools/compare-dbproject.sh` compares read-only.
  - **Refreshed from a clean database built by the API** (since 25 October 2026): the Claude Code session that pushes
    a new script to `main` starts that commit's API on an empty database (the server's way: `DatabaseInitializer`
    applies Schema.sql), runs `refresh-dbproject.sh` on it and pushes "DatabaseProject refreshed (up to script NN)".
    The project then holds exactly what testing and production get. Before, it was refreshed from a developer's local
    database, which also held 4 objects of `Database/16_Inventory_ItemImport.sql` never in Schema.sql nor used by the
    code (`usp_ItemImport_Commit` / `_Validate`, `ItemImportLogs`, `tvp_ItemImportRow`) and listed some indexes in
    another order. **The PCs only pull**: a refresh from a PC puts those back (`git checkout -- DatabaseProject` before
    pulling if it was changed; on any PC `tools/compare-dbproject.sh` shows how the local database differs).
- **Other files in the API repo:** `docs/notes/container-costing-rules.md`, `docs/notes/database-project-workflow.md`,
  `.githooks` (pre-commit check).
- **`CLAUDE.md`** sits in `InventoryShipment-Project/`, the parent folder **outside both repositories**. It holds the
  SQL / password routine. Ask Bilal for it if needed.

### 8.2 Repositories and collaboration
- **GitHub** (`origin`, `bfa-14/Inventory_Shipment` for the API and `bfa-14/Inventory_Shipment_Frontend` for the
  Web) is shared by the whole team. The repositories stay **Private**; a new member is added in each repository's
  **Settings > Collaborators**. Rules:
  - pull with `git pull --no-rebase`;
  - **never force-push `main`** without warning (the others' commits);
  - save your work before any `git reset --hard`;
  - `main` is what **testing** runs, `production` what **production** runs; a release is a pull request `main` →
    `production` in both repositories. An environment changes only when someone presses the **Deploy to server**
    button (GitHub, VS Code or Visual Studio; production asks to type "production") or runs `update.sh` on the
    server: a push deploys nothing (`deploy/README.md`, "Deploying with a button").
  - testing's database can live in **production's SQL Server** (`Inventory_Shipment_Test`, login `inventory_test`,
    which owns it and nothing else): `share-sql-server.sh` moves it there once, `--undo` moves it back, and
    `copy-testing-to-production.sh` copies testing's data into production for the go-live (`deploy/README.md`, "One
    SQL Server for both environments"). The scripts of `Database/` say `USE [Inventory_Shipment];`: the API points
    that line at its own database.
- **After a push**, Ali pulls and restarts his API (new scripts apply by themselves). He keeps his own
  `appsettings.Development.json`.
- **Files delivered outside the repos:**
  - `Containers_User_Guide.docx`;
  - `Movement_Containers_Import_Template.xlsx` (now in the Web project's `public/templates/`);
  - prompt files 32–47: not in `docs/prompts/` (it holds prompts 02–27, 5.1); what they asked is in 5.2 and
    section 4.

### 8.3 Security rules to keep
- Never print or commit passwords: the sa password, the SMTP or app password, the test logins.
- Never commit `appsettings.Development.json` or `App_Data/` (Data Protection keys, uploaded files).
- Approval links must never decide on a GET; tokens never appear in logs or API responses.
- The SMTP password is stored encrypted and never returned.
- Don't put customers' personal data in prompts or test data; use `TEST-NN` data and `@example.com` or "+" aliases.

### 8.4 How Bilal works and what he expects
- **Brief, clear answers.** He often asks "is this done?", "why?", "how?". Answer first, then the minimum steps.
- **He reports symptoms with screenshots.** First check for a stale API or web build (restart), wrong data (for
  example a Container unit of 1, an invoice posted without the switch) or a feature that exists elsewhere, before
  calling it a bug.
- **He wants control and consistency:**
  - one place for each rule (capacity from the item; one upload dialog everywhere);
  - the same page whatever the entry point;
  - buttons that explain why they are disabled;
  - validations in SQL that the screens mirror;
  - imports that only accept correct data and report the rest.
- **He likes downloadable files** (prompts, templates, guides) and tables.
- **He sometimes sends a new message while you are still working.** Fold it into the current answer.
- **Remote access:** the session's link to his computer is usually not connected, so give commands for him to run
  rather than running them.

### 8.5 Working names to reuse
- **Settings and pages:** Settings › Email, Settings › Email log, Settings › Purchase approval, Purchase › Approvals,
  Logistics › Movements, Logistics › Container Charges, Logistics › Tracking.
- **Purchase invoice:**
  - Buttons: "Create Invoice from Containers…", "Create Invoice", "Split by item", "Post selected".
  - Containers card: "Shipped in containers", "Link containers…", "Add container…", "Auto-plan…".
- **Containers:** "Start shipment…", "Start {type}…", "Arrived at {place}…", "Complete {type}…", "Next leg…" (the
  container's next step, script 80), "Add to a movement…", "Container numbers…", "Apply to other containers…", "Receive goods…", "Open goods
  receipt (draft)", "Cancel goods receipt…", "Cancel Offload" (containers offloaded before goods receipts), "Close",
  "Reopen"; the filter "Delivered, not received".
- **Goods receipts:** Purchase › Goods Receipts; "+ New" with "From a purchase order…", "From a container…", "Without
  an order"; "Receive goods…" on the order and the invoice; "Create draft", "Create and post"; "Date received",
  "Receive into", "Delivery note no.", "Nothing more will come"; the cards "Cost adjustments" (receipt) and "Cost of
  received goods" (invoice); "Receive the goods now" in the invoice's post confirmation; filters "With differences",
  "Received not invoiced", "To receive" (orders), "Not fully received" (invoices).
- **Movement page:** "Import from Excel…", "Download a template", "Check", "Tick the {n} valid containers",
  "Download the result".
- **Purchase order:** "Create & send", "Create & approve", "Approve & post", "Send again", "Withdraw", "Send to
  supplier…".

*End of the handoff.*
