# Inventory & Shipment: business handoff (Katanga TVS Motor Company)

*Written on 7 October 2026 by the Claude session that has been writing the prompts with Bilal, for the Claude Code
session that takes over. It covers everything I know about the business and how we work. It comes from our
conversations, the prompt files 32–46, scripts 27–29 and the Containers User Guide.*

*How sure I am:*
- *Where I am not sure, I say so with **(unsure)** or **(check the code)**.*
- *Prompts 1–31 and Ali's scripts 29–41 were written before this session or by someone else. I only know them
  indirectly.*
- *The code in the repositories is the truth; this document explains the business behind it.*

*Status marks used in section 4:*
- ***[Implemented]***: built and verified.
- ***[Decided – prompt NN]***: a prompt is written but not run yet, as far as I know.
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
- **Also buys locally** (no container): the supplier invoice is received directly, with its own charges.
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
5. Offload into the warehouse.

DRC imports need a **FERI** (electronic cargo tracking note). The shipping line allows **free days** at the port;
after them it charges **demurrage**.

### 1.4 Branches and warehouses
- **Branches** (Master Data › Branches / Sites) have codes that appear in document numbers: `PO-BR-002-000042`,
  `PINV-BR-003-000011`.
  - **BR-003 = Likasi Branch**, whose warehouse is "Likasi Warehouse".
  - **BR-002** is another branch, probably Lubumbashi **(unsure)**.
  - Whether a BR-001 / head office exists is **(unsure)**.
- **Warehouses** belong to a branch. A warehouse can stand under another warehouse (a hierarchy, added by Ali).
- A container's **offloading warehouse must belong to the container's branch**.

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
| **Owner** | Approver candidate. Receives a copy of approved purchase orders (setting). **No user has this role in Bilal's local database yet.** |
| **Manager** | By default: view, create, confirm and offload containers; manage movements and documents; view and create container charges. Approver candidate. Test user `manager1` ("Manager One"). |
| Purchasing / buyer | Creates purchase orders and sends them for approval. Test user `buyer1`. The real role name is **(unsure)**. |
| Logistics | Plans containers (Auto-plan), types container and seal numbers from the forwarder's list, starts shipments, records movements, enters charges, attaches documents (B/L, packing list...). |
| Accounting | Posts supplier invoices and charges, landed cost adjustments; follows costs, stock valuation, sales profit. |
| Warehouse | Offloads containers: received quantities, with a reason when they differ. Inventory In / Inventory Out. |
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
| **PINV** | Purchase (supplier) invoice, `PINV-BR-003-000011`. The number is given **at posting**; a draft has none. |
| **PRET** | Purchase return, created from a posted PINV, `PRET-…`. |
| **SINV / SRET** | Sales invoice / sales return. The exact codes in `inventory.DocumentTypes` are **(unsure, check the code)**; I never saw a sales-return menu. |
| **Receipt** | A customer payment (Sales › Receipts), with a payment method and a cash or bank account. |
| **LCA** | Landed Cost Adjustment (script 23): late charges added to a **posted local** invoice. They adjust the item cost: the part still in stock changes the average cost, the part already sold goes to COGS. Refused on imported invoices (error 67012). |
| **FOB** | Purchase price of the goods loaded on board, before the costs of the journey. Taken from the posted supplier invoice. |
| **Landed cost** | FOB + charges: the real cost of a piece in the warehouse. Imports: **FOB per piece + posted charges on the line ÷ pieces received**. |
| **Charge** | A cost of the import or purchase (freight, insurance, clearing, port fees, transport, storage, demurrage). Imports: on **containers**. Local: on the invoice. |
| **Charge type** | Master data (Purchase › Charge Types). Gives the default **allocation method** and whether the charge enters the cost ("include in landed cost"). |
| **Split rule** | How one charge typed for several containers is divided between them: **Same** (each container gets the full amount), **Equal**, **Pieces** (default), **Value**. |
| **Allocation method** | How a container's charge is divided over its items: **Value, Quantity, Weight, Volume, Manual**. Rounded to the cent; leftover cents go to the largest remainders. |
| **Charge group** | Charges created together, or copied with "Apply to other containers", share a `GroupId`. The provider's invoice is attached once for the group. |
| **Late charge / cost adjustment** | A charge posted (or cancelled) after the offload, or on a posted local invoice. Recorded in `inventory.CostAdjustments`, SourceKind `CNTCHARGE` for containers. |
| **COGS** | Cost of goods sold. Sales take stock out at average cost. |
| **Average cost** | Weighted average cost per item, updated at every receipt and cost adjustment. Items also keep **last cost** and **FOB cost**. |
| **Container** | A shipping container, created **from a purchase order**. App reference `KTG-2026-0031` (document type CNT: prefix KTG, year, 4-digit number). |
| **Container No.** | The real box number: 4 letters + 7 digits, for example `MSKU1234565`. Typed when the forwarder sends the list. Unique among open containers (69013). |
| **Seal No.** | The number of the seal closing the doors. |
| **Container type** | Master data: 20GP (20 ft General Purpose, inactive) and **40HC** (40 ft High Cube, active), with Max Weight (kg) and Max Volume (CBM). Their "Max Units" is being removed (prompt 46). |
| **Container unit** | In Item Definition › units: the unit whose unit type is a container unit (`masterdata.UnitTypes.IsContainer = 1`). Its packing formula is the pieces of this item per container (for example 84). **The only source of container capacity** (prompt 46). |
| **Base unit / pieces** | The smallest unit of an item (`PC`). Container quantities are always in base units. Other units have a packing formula. |
| **Auto-plan** | On an approved PO: choose the container type and the app proposes all containers, filled from the order lines; edit, then create them all at once (all or nothing, at most 200). |
| **Mix the rest** | Auto-plan option: what is left of each line after full containers is packed into shared containers. Off = each rest gets its own container. |
| **Fill % / equivalent capacity** | How full a container is: the sum of quantity ÷ pieces per container of each item (prompt 46). |
| **Over capacity** | Fill above 100%: a warning that only users with "Load Above Capacity" can confirm (69007). |
| **Confirm (container)** | The loading plan is agreed: Draft → Confirmed. |
| **Movement** | One leg of the journey, `MOV-2026-000046`. Types: LOAD, SEA, TRANSHIP, PORT, INLAND, BORDER, CUSTOMS, DELIVERY. Planned → In progress → Completed, or Cancelled. |
| **Stage** | What a movement type does to its containers: Origin, Sea, Transit, Port, Border, Customs, Delivery. |
| **Start shipment** | From a selection of containers: one movement (default SEA) created and started at once. Vessel, voyage, B/L and ETA are copied to the containers. |
| **Place of a container** | The **To** of its previous movement (prompt 43). A container that never moved is at its **port of loading** (prompt 45). |
| **Offload** | Receiving a container's goods into stock at landed cost. Received quantities with a reason when they differ from the loaded quantities. Re-offload tag `KTG-…/2`. |
| **Close / Reopen (container)** | Close when every charge is posted (read-only). Reopen to add a late charge. |
| **Receipt mode** | On a purchase invoice: **1** = stock in when the invoice is posted (local); **2** = stock in at the container offload ("Shipped in containers"). |
| **Shipped in containers** | The PI switch for receipt mode 2. On by default when the order has containers; locked while lines are linked to containers (65026). |
| **Link / Unlink (containers)** | On a PI: says which pieces of the invoice travel in which container. Each invoice line points to one container line (`PurchaseDocumentLines.ContainerLineId`); linking splits the line. Only while the container hasn't moved (Draft or Confirmed). |
| **Exporter's Ref.** | The exporter's reference. Required to post an imported / shipped-in-containers invoice (65018). |
| **Commercial invoice no.** | The supplier's invoice number, typed on the PI. |
| **Supplier reference** | Free reference on the PI. |
| **B/L** | Bill of lading. One B/L can cover several containers. |
| **Booking No.** | The shipping line's reservation number. |
| **ETA** | Estimated time of arrival. A red "Late" badge appears when the ETA has passed and the movement isn't completed. |
| **Free days / last free day / free time over** | Days at the port without demurrage, counted from the actual port arrival. A red badge appears when they are over and the container isn't offloaded. |
| **Demurrage** | Shipping-line fee after the free days. |
| **Forwarder / transporter / shipping line / carrier** | Parties (Master Data › Parties) used on containers and movements. |
| **Transshipment** | Moving a container to another vessel at an intermediate port. |
| **FERI** | Electronic cargo tracking note required for DRC imports (a container field). |
| **Shortage** | Inventory › Shortages (script 25, `fn_Shortage_Live`): what is missing per item and warehouse compared with what is on the way (orders, containers in transit, invoices pending). The exact formula is **(unsure, check the code)**. |
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
- **Dashboard**
- **Inventory:** Item Definition, Price Lists, Inventory In, Inventory Out, Stock Valuation, Shortages
- **Purchase:** Purchase Orders, Approvals (with a red count), Purchase Invoices, Purchase Returns, Landed Cost
  Adjustments, Charge Types
- **Logistics:** Containers, Movements, Container Charges, Tracking
- **Sales:** Sales Invoices, Sales Profit, Receipts, Customer Statement, Out-of-Stock Sales
- **Backoffice › Master Data:** Branches / Sites, Warehouses, Currencies, Exchange Rates, Item Families, Brands,
  Parties, Unit Types, Container Types, Ports, Attachment Types, Movement Types, Payment Methods, Cash / Bank Accounts
- **Backoffice › Users & Permissions:** Users, Roles, Role Permissions, Permissions, Login audit
- **Configuration:** Document Types; Settings › General, Email, Email log, Purchase approval

Web routes seen: `/purchase/invoices/:id`, `/logistics/movements/new`, `/logistics/movements/:id`,
`/setup/master-data/container-types`, `/configuration/email`, `/purchase-approval/:token` (public).

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
  shows average cost, last cost and FOB cost.
- **Price Lists:** selling prices **(details unsure)**. Document types carry `DefaultPricing` and `PriceEditable`,
  which suggests each document type says where its default price comes from and whether it can be changed
  **(check the code)**.
- **Inventory In / Inventory Out:** manual stock documents; a document type can require a reason (`RequiresReason`).
- **Stock Valuation:** stock × average cost per item and warehouse; the export calls it "Total Cost".
- **Shortages:** see the glossary.
- **Stock ledger:** `inventory.StockMovements` (DocumentFamily, DocumentTypeCode, DocumentNumber; container offloads
  use the container ref, and a re-offload gets `/N`). `inventory.usp_Item_RebuildCosts` recomputes costs.

### 3.4 Purchase
**Documents:**
- **PO** → approval → posted (= approved). It then auto-closes (status 4) when fully invoiced.
- **PINV:**
  - created from a PO with "Create Invoice", or from containers with "Create Invoice from Containers…";
  - **one item per invoice**: several items give several drafts at once;
  - each line may take at most what remains on its source line.
- **PRET** from a posted PINV.

**Charges on purchases:**
- **Local invoice** (receipt mode 1): its own charges while it is a draft (`usp_PurchaseDocument_SetCharges`). After
  posting, late charges go through an **LCA**. Prompt 38 puts one "+ Add charge" in every status.
- **Imported invoice** (from containers, mode 2): **no charges of its own**. The charges belong to the containers; the
  invoice page shows them read-only.

**Approval:** see 3.9 A and 4.3. Purchase › Approvals lists "Waiting for my approval".

**Excel:**
- **Import:** Ali's import of invoice lines (`ImportInvoiceItemsWizard.tsx`). It now creates one invoice per item.
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
   - "Start shipment…" on the selected containers (for example the 5 of 30 still waiting).
   - Then each leg is a **movement**: Logistics › Movements, where the containers are ticked in a list at the
     movement's From (prompt 45).
   - Start / Complete move the containers' status, dates and current location forward, never back.
6. **Charges:**
   - Entered from the container, a movement ("Add charge for these containers"), the selection bar or Logistics ›
     Container Charges.
   - Split over containers, allocated over items, Draft → Posted → Cancelled.
   - "Apply to other containers…" copies a charge.
7. **Documents:** attachments per container, optionally linked to a movement and/or a charge, with an attachment type.
   One upload can go to several containers; the file is stored once.
8. **Offload** at the warehouse:
   - Preconditions: the container is confirmed; every line is invoiced by **posted** invoices; no movement in
     progress; the warehouse belongs to the branch.
   - The goods enter stock at landed cost, the charges are re-divided over what arrived, then frozen.
   - Average, last and FOB costs are updated; the container becomes Offloaded.
   - **Cancel Offload** is refused after cost adjustments or when the stock has been consumed.
9. **Close** when all charges are posted; **Reopen** for late charges.
10. **Tracking:** an animated board (sea legs with a ship, road legs with a truck, stops, late legs in red) that
    refreshes every minute; it shows containers travelling and those offloaded in the last 30 days.
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
- **DELIVERY**: started = Cleared.

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
  RequiresReason, DefaultPricing, PriceEditable, NumberPerBranch, YearInNumber, NumberLength. This drives numbering
  (4.1).
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
  - Purchase: `purchase.orders.approve` (now "(not used)"), `purchase.orders.post`, `purchase.approval.manage`.
  - Settings and email: `settings.email.manage`, `messaging.emails.view` (920).

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
   - Exporter's Ref. required. **Post: no stock yet.**
5. **Shipment:** Start shipment (SEA Chennai → Dar es Salaam), then INLAND → Kasumbalesa, CUSTOMS, DELIVERY →
   Lubumbashi. Each movement is started and completed.
6. **Charges** (freight, clearing, transport, port fees, demurrage) entered on containers, split and allocated,
   **posted**. Documents attached (B/L, packing list, FERI).
7. **Offload** at the warehouse: stock in at **landed cost**; average cost updated.
8. **Close** the container. Late charges: reopen, post, and the cost is adjusted (in stock → average cost; sold →
   COGS).
9. **Sale** (SINV): stock out at average cost, which gives COGS and the Sales Profit.
10. **Receipt** of the customer's payment; the Customer Statement updates.

**B. Local purchase**
1. PO, then approval.
2. **Create Invoice** from the PO, one per item, with "Shipped in containers" off.
3. The invoice's own charges, then **post**: stock in at FOB + charges (receipt mode 1).
4. Late charges: LCA (later "+ Add charge" on the posted invoice, prompt 38).
5. Return: **PRET** from the posted invoice.

**C. Sale and payment:** sales invoice (currency, payment type, client address, date tolerance; out-of-stock only if
allowed), then receipt, customer statement and sales profit [Ali – details unknown].

### 3.10 Document types and statuses (codes confirmed in the SQL unless marked)

| Object | Statuses |
|---|---|
| **Purchase documents** (PO, PINV, PRET; `purchase.PurchaseDocuments.Status`) | 1 Draft · 2 Posted (for a PO = approved) · 3 Cancelled · 4 Closed (a PO auto-closes when fully invoiced, or is closed by hand) · 5 Waiting for approval (PO only, locked) |
| **Containers** (`logistics.Containers.Status`) | 1 Draft · 2 Confirmed · 3 In Transit · 4 At Port · 5 Cleared · 6 Offloaded · 7 Closed · 8 Cancelled (3 inferred, the others confirmed) |
| **Movements** | 1 Planned · 2 In progress · 3 Completed · 4 Cancelled (4 inferred) |
| **Container charges** | 1 Draft · 2 Posted · 3 Cancelled |
| **Emails** (outbox) | Pending · Sent · Failed (at most 5 attempts) |
| **Approval history events** | Sent for approval · Sent again · Reminder sent · Approved (in the app / by email, by whom) · Approved directly · Rejected (with reason) · Withdrawn · Posted without approval · Sent to the supplier · Not sent to the supplier |
| **Invoice line ↔ container** | linked (`ContainerLineId`) / not linked; "Not linked" is only a warning on shipped-in-containers invoices |

Numbers: `PO-BR-002-000042`, `PINV-BR-003-000011`, `PRET-…`, `KTG-2026-0031` (CNT), `MOV-2026-000046`. LCA numbers
and sales numbers **(check DocumentTypes)**.

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
- **Containers:** `KTG-2026-0031` (type CNT: prefix KTG, year, 4 digits). **[Implemented]**
  - The container **number** (box no.) must be unique among open containers (69013). **[Implemented]**
  - A second offload of the same container gets its own stock-ledger number, `KTG-2026-0031/2`. **[Implemented]**
- **Movements:** `MOV-2026-000046` (prefix MOV-, year, 6 digits, not per branch). The number is assigned **at the
  first save**. **[Implemented]**
- **SQL scripts:** `Database/NN_Module_Description.sql`, next free number. **Prompts:** `docs/prompts/NN-title.md`,
  a separate numbering ("prompt 42" is not "script 42"). Before numbering a new script, pull first: Ali writes scripts
  too. **[Convention]**

### 4.2 Purchase orders and supplier invoices
- **PO statuses and closing:** a PO is a draft until posted; posting a PO = approving it (when approval applies). Each
  PO line tracks what is invoiced, and the PO **auto-closes (4) when fully invoiced**. **[Implemented]**
- **An invoice made from a PO** takes the PO's supplier and branch; each line may take at most what remains on its
  source line. **[Implemented]**
- **One item per supplier invoice:** **[Implemented – prompt 37, script 44]**
  - A PINV holds one item. It may have several lines of that item (several containers, warehouses or expiry dates),
    never two different items. Purchase orders and returns are not concerned; posted invoices are unchanged.
  - Create Invoice, Create Invoice from Containers and the Excel import create **one draft per item**. The exporter's
    reference and commercial invoice no. typed once are copied to every invoice.
  - Saving or posting a PINV with two items is refused (65029): "A supplier invoice holds one item. This one has
    {n}: … Create one invoice per item, or use Split by item."
  - Older drafts: **Split by item**. Several drafts of an order: **Post selected**.
  - The invoice list shows the item.
- **Imported invoices** (from containers / shipped in containers): **[Implemented]**
  - The **Exporter's Ref.** is required to post (65018).
  - They have **no charges of their own** (65020) and **no LCA** (67012). Their charges belong to the containers and
    are shown read-only.
- **Invoice first, containers after:** a PI can be created directly from an order that has containers. Prompt 32 had
  refused this (65021); prompt 41 removed the refusal. **[Implemented – script 43]**
- **"Shipped in containers"** (receipt mode 2): **[Implemented – script 43]**
  - Ticked by default when the order has containers, always for a PI made from containers.
  - Posting then puts no goods in stock; the container offload does.
  - It cannot be unticked while a line is linked (65026).
- **Link / Unlink containers on a PI:** **[Implemented – script 43]**
  - Allowed on a draft or posted PI (the amounts don't change).
  - Only containers in Draft or Confirmed (65027), never a line already received.
  - Linking splits the PI line per container line; unlinking merges it back.
  - A PI not created from a PO cannot have containers. A container line can never be invoiced twice.
- **Add container / Auto-plan from the PI:** creates containers on the PI's order, linked at once, holding the PI's
  item only. Mixed containers are planned on the order. **[Implemented – script 43]**
- **The PI's Containers card always explains itself:** **[Decided – prompt 44]**
  - Shown on every PI.
  - Disabled buttons give the reason, for example "Every piece of this invoice is already in a container." or "This
    invoice was posted without 'Shipped in containers': its goods are already in stock."
  - A draft with the switch off gets "Turn it on".
  - Quantity ≤ min(pieces not in a container, what the order lines still allow); the order may be approved or closed.
  - No orange "Not linked" on invoices not shipped in containers.
- **"+ Add charge" on an invoice in every status:** **[Decided – prompt 38]**
  - **Local draft:** the invoice's own charges, as today.
  - **Local posted:** a late charge in a draft adjustment. "Post late charges" adjusts the cost (stock on hand →
    average cost; already sold → COGS); it is stored as the invoice's LCA.
  - **Imported (draft or posted):** the container charge dialog, with the invoice's containers preselected.
- **Purchase returns:** PRET from a posted PINV. **[Implemented]** Detailed rules **(unsure)**.
- **Discounts:** "Disc %" per purchase line. **[Implemented]** Sales discounts **[Ali – details unknown]**.
- **"The request field is required." on PINV / PRET save:** prompt 35. **(status unknown)**
- **One purchase-order page wherever it is opened from:** **[Decided – prompt 39]**
  - The page decides from the order itself, never from the route.
  - The Containers card is on every PO.
  - Buttons are visible but disabled with a tooltip:
    - Draft: "Approve the order first: containers are created from an approved order."
    - Waiting: "This order is waiting for approval."
    - "This order is closed." / "This order is cancelled."
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

**Follow-ups** **[Decided – prompt 42]**
- 65016 only while "Email the approved order to the supplier" is on.
- The withdraw reason is stored and shown in the history.
- Create-and-approve returns the same warnings as approve-now.
- Every `*Utc` timestamp leaves the API with "Z"; dates without time are unchanged. The web formats a "Z" time in
  local time once, without double corrections.
- The ~40 Pending test emails are marked failed ("Test email - not sent").
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
- **Creation:** only from an **approved and open** PO (status 2): "The purchase order must be approved and still open."
  Lines of other approved POs, from other suppliers too, can be added.
- **Quantities** are in pieces. Loadable per PO line = ordered − invoiced without container − loaded in other
  containers (69008).
- **Status** only moves forward with movements. Two exceptions on purpose: Cancel Offload returns the previous status;
  Reopen returns Closed → Offloaded.
- **Free days:** last free day = actual port arrival + free days; a red "free time over" badge after it if the
  container is not offloaded.
- **Offload:**
  - Preconditions: confirmed ("Confirm the container before offloading it."); every line invoiced by **posted**
    invoices (69016); no movement in progress; warehouse of the container's branch.
  - Received ≤ loaded; a **reason is required** when they differ.
  - Effects: landed cost = FOB + posted charges ÷ pieces received; charges re-divided over what arrived and frozen;
    invoice lines marked received; average, last and FOB costs updated; status Offloaded; location = the warehouse.
- **Cancel Offload** is refused after a cost adjustment (69018) or when the stock brought is gone: "Cannot reverse:
  … has only N left, but this container brought M."
- **Close** when every charge is posted; **Reopen** for a late charge.
- **Delete** drafts only; cancel the others with a reason. An invoiced container's invoices must be cancelled or
  deleted first.
- **Auto-plan:** **[Implemented – script 28]**
  - Every order line first fills whole containers of its own item.
  - The rest is packed without cutting a line (first fit, largest first), unless cutting lines needs fewer containers
    (then fill to the brim).
  - "Mix the rest" on/off. At most 200 containers. All or nothing ("Container 3 of 30: …"). Optionally "Confirm the
    containers after creating them".
- **Bulk actions:** Confirm, Container numbers (paste list), Start shipment, Add charge, Delete drafts.
  **[Implemented – script 28]**
- **Capacity today:**
  - Pieces per container = typed in the Auto-plan dialog, else the item's Container unit, else the container type's
    Max Units.
  - A container's Max Units = typed, else the type's.
  - Over capacity = warning 69007, confirmable with "Load Above Capacity".
- **Capacity decided:** **[Decided – prompt 46]**
  - **One source: the item's Container unit.**
  - Fill % = Σ quantity ÷ pieces per container. A 40HC with 84 motorcycles of an 84-piece item = 100% (today it
    shows 70%).
  - An item without a Container unit: fill unknown ("—", with a link to set it), no warning, Auto-plan refuses it.
  - Max Units goes from Container Types and every container form (the database column stays, unread). Max Weight and
    Max Volume stay.
  - The over-capacity message names the item: "This container would be 112 % full: 94 pcs of TEST38-A (84 per
    container)."

### 4.6 Movements **[Implemented unless marked]**
- **Lifecycle:** Planned → In progress (Start) → Completed (Complete); Cancelled with a reason. One movement carries
  one or more containers.
- **One movement at a time:** a container cannot travel with two movements in progress (70012): "Container … is
  already travelling with movement MOV-… Complete it first."
- **Start shipment:** **[Implemented – script 28]**
  - Default SEA, from the containers' common port of loading to their common port of destination; the user chooses
    when they differ.
  - Drafts are confirmed first. It starts today unless "Plan only".
  - Vessel, voyage, shipping line, B/L and ETA are copied to the containers; ports only when empty.
- **Place rule:** **[Implemented – prompt 43; errors 70015 / 70016 as planned, check the numbers]**
  - A movement only takes containers **at its From** = the To of each container's previous movement (cancelled
    movements don't count; previous = the latest one created before this one).
  - Save refuses others (70015): "Container KTG-… is at Dar es Salaam (end of MOV-…); this movement starts from
    Beira. Change the From, or record the movement that brings it here first."
  - Start refuses while a container's previous movement is not completed, or no longer ends at the From (70016).
  - Planning ahead is allowed: a container still on its way to Beira can go on a planned movement from Beira.
- **Never-moved containers:** **[Decided – prompt 45; not explicitly confirmed by Bilal]**
  - Prompt 43 let them start anywhere.
  - Prompt 45: they are at their **port of loading**. They can start from there, or go on an Origin-stage ("Loading
    at the supplier") movement whose To is their port of loading.
  - No port of loading → any From, with a note.
  - An Origin-stage movement takes only containers that have never moved.
- **The Containers card is the list:** **[Decided – prompt 45]**
  - Checkboxes, ticked = on this movement. It reloads at once when the From changes; containers not at the new From
    are unticked, with a message.
  - No "Add containers…" dialog.
  - Save needs ≥ 1 ticked. Start and Complete are disabled while there are unsaved changes ("Save your changes
    first."). Start re-checks everything in SQL and refuses a movement without containers.
- **Import of container numbers** (Excel or paste):
  - **[Implemented – prompt 43, basic]**: matches the container number, then the ref; capitals, spaces, dashes, dots
    and slashes are ignored; never creates containers.
  - Results: Will be added / Already on this movement / Not found / Cannot be added (reason) / Found twice /
    Duplicate. At most 500 numbers.
  - **[Decided – prompt 45]:**
    - Only valid numbers can be ticked, with no forcing.
    - "Download the result" gives sheets Result and Summary.
    - The template `Movement_Containers_Import_Template.xlsx` (sheet Containers with "Container no." in A1, sheet
      Instructions, sheet Example result) is served from the Web's `public/templates/`.

### 4.7 Charges and costing **[Implemented]**
- **Costing method:** weighted **average cost** per item, plus last cost and FOB cost. Sales go out at average cost
  (COGS). `inventory.usp_Item_RebuildCosts` recomputes.
- **Import landed cost** = FOB per piece (posted invoice) + posted charges on the line ÷ pieces received.
  - Before the offload the screens show an estimate ("est."): the order price until invoiced, and the pieces loaded.
- **Container charges:**
  - Draft → Posted → Cancelled. Only posted charges that "enter the landed cost" count.
  - Any currency, at the rate of the charge date (editable): "No exchange rate for this currency on the charge date.
    Add one or enter the rate."
- **Split over containers:** Same / Equal / Pieces (default) / Value; "Same" is the default from the selection bar.
  - Example, 3,000 USD on containers of 120 and 60 pcs: Same = 3,000 each; Equal = 1,500 / 1,500; Pieces = 2,000 /
    1,000; Value = by FOB value.
- **Allocation over items:**
  - Value: order price → invoice price → final FOB.
  - Quantity: pieces, received after the offload.
  - Weight / Volume: needs the item's weight / volume, else "…: item … has no weight (kg)".
  - Manual: the amounts must add up exactly.
  - Rounded to cents; the leftover cents go to the largest remainders.
- **Copy to other containers:** drafts of the same group, or posted at once with the permission. A container that
  already has a charge of the group is refused. Manual allocation is copied with the charge type's method.
- **Late charge after the offload** (or cancelled after it): a cost adjustment (in stock → average cost; sold →
  COGS), badge "after offload". The offload can no longer be reversed.
- **Local purchases:** the invoice's charges while it is a draft; after posting, an LCA (67011 the invoice must be
  posted; 67012 refused on imported invoices).
- **Worked examples (user guide):**
  - KTG-2026-0031: 84 pcs of Model A at 950 USD FOB; charges 2,100 + 840 = 2,940 USD → 35 USD/pc → landed 985 USD.
    If only 82 arrive → 35.85 → 985.85.
  - Mixed container: 42 pcs A at 950 (39,900) + 60 pcs B at 700 (42,000), freight 1,000 USD.
    - By value: A 487.18 (11.60/pc), B 512.82 (8.55/pc).
    - By quantity: A 411.76, B 588.24 (9.80/pc each).

### 4.8 Attachments
- **Containers:** **[Implemented]**
  - Attachment type, document date, note.
  - General, or linked to a movement and/or a charge.
  - One upload → several containers; the file is stored once.
- **Every document** (PO, PINV, PRET, sales documents, receipts): **[Decided – prompt 40, updated 4 Oct]**
  - The attachment type is **required**; the types are filtered per document ("Used for").
  - Attachments are **never required to post**.
  - Files from before get the type "Other" (category "General").
  - Each module keeps its own storage.
  - **One shared upload dialog** (File, Attachment type, Document date, Note) everywhere. The drop zone only opens the
    dialog; no direct upload.
  - "PDF, image or Office file, up to 20 MB" everywhere; the purchase documents say 10 MB today.

### 4.9 Inventory and sales (mostly Ali's)
- Setting **"Allow selling out-of-stock items"** + the Out-of-Stock Sales page. **[Ali – details unknown]**
- **Sales invoice:** its own currency; client address; **date tolerance**; **payment type**; "auto…".
  **[Ali – details unknown]**
- **Customer receipts** with payment methods and cash / bank accounts. **[Ali – details unknown]**
- **Warehouses** can stand under another warehouse. **[Ali]**
- **Document import:** one document whatever the warehouse; no Expiry Date in the import template. **[Ali]**
- **Price lists:** per document type `DefaultPricing` / `PriceEditable`. **(unsure, check the code)**
- **Stock check on sales** (refused unless out-of-stock selling is allowed). **(unsure)**
- **Inventory Out** may require a reason (`RequiresReason`). **(unsure)**

### 4.10 Dates and times
- Timestamps are stored in `*Utc` columns; dates without time (document date, order date, ETA) have no time zone.
  **[Implemented]**
- The API sends `*Utc` values with "Z" and the web shows local time once. **[Decided – prompt 42]**
- Date tolerance on sales invoices. **[Ali – details unknown]**

### 4.11 Security and data
- **Permissions per role:** the administrator has all. Manager defaults: containers view, create, confirm, offload;
  movements; documents; view and create charges. New sensitive permissions (`settings.email.manage`,
  `purchase.approval.manage`) are administrator-only by default. **[Implemented]**
- **Secrets:** approval links never decide on GET; tokens never appear in logs or API responses; the SMTP password is
  never returned or logged. **[Implemented]**
- **Concurrency:** RowVersion on documents: "This … was modified by another user. Reload the page and try again."
  (65004 / 70004 → 409). **[Implemented]**

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

**What I don't know**
- The titles of prompts 1–29 and 31 **(unsure)**.
- The files should be in the API repository under `docs/prompts/`. List them there.

### 5.2 Prompts 32–46

| Prompt | Title / what it does | Status |
|---|---|---|
| **32** | Batch 8 — Containers at the centre (script 27): containers from the PO, invoices from containers, movements, container charges and per-item cost, documents, tracking board (A1–A4, B1–B5) | Done |
| **33** | Batch 9 — Many containers per order (script 28): Auto-plan, bulk actions, Start shipment for the chosen containers, charge copied to other containers, "Create & send" | Done, except its approval steps A4 / B3 (replaced by 36) |
| **34** | Batch 10 — Purchase approval: who approves (in the app / by email), email settings, the whole cycle | A1 done: VS Code wrote the spec as **script 42** (not 29). A2–B3 replaced by 36 |
| **35** | Fix "The request field is required." when saving / posting PINV and PRET | Unknown. The 37 checks saved and posted invoices and a return without it, so probably done or no longer needed. Check by saving a draft PRET |
| **36** | Batch 10 final — Email and approval layer: email core (encrypted password, queue, worker, Email log, test), approval endpoints, approval emails, reminders, Settings › Email / Email log / Purchase approval, approval on the PO, Approvals page and badge, public approval page (A1–A3, B1–B4) | Done (leftovers → 42) |
| **37** | Batch 11 — One item per supplier invoice (script 44, error 65029): auto split, refusal, Split by item, Post selected, import | Done (A1, A2, B1 verified 2 Oct) |
| **38** | Charges on a purchase invoice, draft or posted: one "+ Add charge" | Not started |
| **39** | One purchase-order page from everywhere; disabled buttons with reasons | Not started |
| **40** | Attachment types on every document (updated 4 Oct: one dialog, no direct upload, 20 MB) | Not started |
| **41** | Containers from the purchase invoice (script 43): "Shipped in containers", Link / Unlink, Add container / Auto-plan from the PI, container counts | Done. It ran **before** 37, so 37 was adapted |
| **42** | Approval follow-ups after 36: 65016 rule, withdraw reason, create-and-approve warnings, UTC "Z", test emails, Approve confirmation | Not started. "Prompt 42" ≠ "script 42" |
| **43** | Movement: add containers with checkboxes, Excel / paste list, the place rule (Save / Start checks) | Done, partly superseded by 45. Bilal then saw 404 / 405 (stale API: restart) and a movement started with a never-moved container |
| **44** | Create containers from a purchase invoice: CHECK what exists, then make it work with every validation; Containers card on every PI with reasons | Not started (or unknown). The "missing button" Bilal reported was explained: invoice 1227 fully linked; invoice 1322 posted without the switch |
| **45** | Movement: one list with checkboxes that follows the From; Save / Start guards; never-moved rule; validated Excel import, result download, template file | Not started |
| **46** | Container capacity from one place, the item's Container unit; Max Units removed | Not started |

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

### 5.4 SQL script numbers I know

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
| 44 | One item per invoice (prompt 37) |
| next | Probably 45 = the movement picker of prompt 43 **(check)** |

Prompts 42, 44, 45, 46 (and 38 or 40 if they need SQL) will take the next free numbers.

---
## 6. What's next

### 6.1 Planned prompts, in the order I recommend (Bilal decides)
1. **45 — the movement's container list, Save / Start guards, the validated import.** Bilal's latest complaints:
   - he could start MOV-2026-000046 (LOAD, Dar es Salaam → Chennai) with a container that had never moved;
   - he wants the list itself with checkboxes, reloading when the From changes;
   - he wants a template and a validated import.
   - Before running it, save `Movement_Containers_Import_Template.xlsx` in the Web project's `public/templates/`.
2. **46 — capacity from the item's Container unit only.** It removes wrong percentages and messages like "321
   containers needed" (item TEST38-A has Container unit 1).
3. **44 — the PI Containers card with reasons and all validations.** Bilal was confused on invoices 1227 and 1322.
   When VS Code asks which invoice, give it 1227 (fully linked) and 1322 (posted without the switch).
4. **40 — attachment types everywhere.** Bilal asked again on 4 October: the invoice upload must look like the
   container one.
5. **42 — approval follow-ups:** UTC "Z" times, the 65016 rule, the withdraw reason, the Approve confirmation.
   Sending is already switched on, so its test-email cleaning may find nothing left.
6. **38 — "+ Add charge" on posted invoices.**
7. **39 — one purchase-order page.** Optionally add the "Create Invoice" count fix (6.4).
- **35**, only if it was never run: save a draft purchase return; no "request field" error means skip it.

### 6.2 Open requirements not yet in a prompt
- Update the **Containers User Guide** (Word, 31 pages, v1.0, September 2026, delivered to Bilal outside the repos).
  It is outdated in chapters 5 (Max Units, Auto-plan's typed pieces), 7 (one item per invoice, invoice-first
  containers) and 8 (movement containers list, place rule).
- Write `tools/check-repo.sh`: `tools/refresh-dbproject.sh` stops because it is missing.
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
- **GitHub vs GitLab:**
  - **GitLab `origin` is the team repository**: `gitlab.com/InventoryShipment/inventory_shipment_web` for the Web;
    the API project's exact name is **(unsure)**.
  - The **GitHub copies** (`bfa-14/Inventory_Shipment`, `bfa-14/Inventory_Shipment_Frontend`, remote `github`) change
    only when Bilal pushes to `github`. **They may be behind GitLab: check before trusting them.**
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
  approval (Settings › Purchase approval).

### 6.4 Decisions still pending (with the options considered)
- **Never-moved containers on a movement:**
  - (a) any From (prompt 43);
  - (b) **default in prompt 45**: from their port of loading, or on an Origin movement ending at their port of
    loading;
  - (c) port of loading only.
  - I stated (b) twice; Bilal didn't object but didn't confirm.
- **Container units per container type,** if 20GP comes back into use:
  - (a) one Container unit per item (decided for now);
  - (b) container unit types linked to a container type.
  - Not needed while only 40HC is active.
- **"Create Invoice" preview count** when the order already has draft invoices (it can announce one invoice too
  many; the result is right):
  - (a) leave it;
  - (b) an API preview that excludes quantities in drafts (fold into 39).
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
  - Bilal refreshes, commits and pushes; Ali runs `git checkout -- DatabaseProject` before pulling.
- **Other files in the API repo:** `docs/notes/container-costing-rules.md`, `docs/notes/database-project-workflow.md`,
  `.githooks` (pre-commit check).
- **`CLAUDE.md`** sits in `InventoryShipment-Project/`, the parent folder **outside both repositories**. It holds the
  SQL / password routine. Ask Bilal for it if needed.

### 8.2 Repositories and collaboration
- **GitLab** (`origin`, branch `main`) is shared with Ali. Rules:
  - pull with `git pull --no-rebase`;
  - **never force-push `main`** without warning (Ali's commits);
  - Ali must save his work before any `git reset --hard`.
- **GitHub** copies (`bfa-14/Inventory_Shipment` for the API, `bfa-14/Inventory_Shipment_Frontend` for the Web,
  remote `github`) must stay **Private** and are updated only by `git push github main`.
- **After a push**, Ali pulls and restarts his API (new scripts apply by themselves). He keeps his own
  `appsettings.Development.json`.
- **Files delivered outside the repos:**
  - `Containers_User_Guide.docx`;
  - `Movement_Containers_Import_Template.xlsx` (to put in the Web project's `public/templates/`);
  - prompt files 32–46: they should be in `docs/prompts/`, but whether all are committed is **unknown**.

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
- **Containers:** "Start shipment…", "Container numbers…", "Apply to other containers…", "Offload", "Cancel Offload",
  "Close", "Reopen".
- **Movement page:** "Import from Excel…", "Download a template", "Check", "Tick the {n} valid containers",
  "Download the result".
- **Purchase order:** "Create & send", "Create & approve", "Approve & post", "Send again", "Withdraw", "Send to
  supplier…".

*End of the handoff.*
