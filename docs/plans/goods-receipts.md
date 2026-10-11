# Goods Receipts (GRN): stock enters only through a goods receipt (FINAL specification)

**Status: approved and built (October 2026).** Database scripts 64 (new objects) and 65 (the switch), then the API
and the web. The business owner chose the recommended (A) option for every decision listed under "Decisions still
needed" below. This file is the design the code was built from; the code is the truth where they differ.
- Posting a supplier invoice no longer moves stock: goods enter only through a goods receipt (GRN).
- A draft receipt is created for each container when its Delivery movement is completed; local goods are received
  with "Receive goods…".
- Goods are valued at the order price until the invoice arrives, then their cost is adjusted automatically.
- It applies "from now": the switch (script 65) is one-way; see section 7.

## 0. Review notes (draft → final)

Three critiques were checked against the code: costing, upgrade safety, and usability. What the final spec takes from
them:

- **Matching:**
  - received and invoiced pieces are now matched per **order line** in passes: container line first, then the order
    line, then supplier + item for goods without an order;
  - an invoice not linked to its container still reaches the container's goods.
- **Double receipts closed:**
  - what can still be loaded into containers now counts goods received outside containers;
  - the receipt's own container no longer blocks its own posting.
- **Container cost has one source:**
  - a container receipt line reads its charges and landed cost from the container line;
  - a late charge then enters the cost once.
- **Cost adjustment:**
  - the in-stock share is worked out per item, on company stock;
  - adjustments are never dated before their receipt;
  - goods sold before their receipt get their cost difference in cost of sales.
- **Cut-over marker:**
  - an invoice is marked as using goods receipts **when it is posted**, not while it is a draft;
  - a one-time switch marker runs the recompute once.
- **Delivery hook:** the drafts are created **after** the movement's transaction commits. Each container is reported
  as created or skipped, with a reason.
- **Short shipments:** a short line posted with a reason settles the difference. The order can close, and Shortages
  stops counting the missing pieces.
- **People:**
  - grants also go to the roles that post invoices today;
  - a waiting-drafts count in the menu;
  - "Delivered, not received" and "Not received" filters;
  - a printable receipt for signing at the gate;
  - "Receive goods…" dialogs that do not propose goods still at the supplier;
  - the container header stays editable.

The rejected points and their reasons are in the summary returned with this file. In short:
- a mode-1 invoice cannot cover containerised pieces: the 65026 guard of Save exists;
- the +1 day date tolerance stays;
- ledger rows keep the document date;
- the average is still replayed on adjustments, not updated incrementally;
- "received − returned" is not applied to invoices posted before script 24;
- the typed cost of a manual line defaults to the last cost;
- manual receipts are not restricted to goods without a supplier.

---

## 1. Business rules

Error block **63xxx** is for goods receipts. It is unused today and below the `LastBusinessRule` ceiling (73999,
`SqlErrors.cs`).
- The container side uses 69019 (new) and re-uses 69016 for Close.
- The purchase side re-uses 65011 and 65028.
- SQL messages are shown as they come.

### 1.1 What changes, from now on

1. **A supplier invoice posted after the switch does not change stock or item cost.** This holds for every receipt
   mode, local or "Shipped in containers".
   - The new `usp_PurchaseDocument_Post` marks such an invoice `UsesGoodsReceipts = 1` when it posts it.
   - Posting still:
     - assigns the number and makes the amount payable;
     - works out per line the FOB, the allocated invoice charges and the landed cost per base unit (`FobCostBase`,
       `AllocatedChargesBase`, `UnitCostBase`). This is the **invoice cost** that received goods are valued at or
       corrected to;
     - counts the order line as invoiced (`ReceivedQuantityBase` on PO lines, which has always meant *invoiced*).
   - The only cost effect left is rule 10: goods already received get their cost corrected.
2. **Goods enter stock only through a posted goods receipt (GRN).**
   - Document type `GRN`, "Goods Receipt", family Purchase.
   - Numbered per branch at posting, like the other purchase documents: `GRN-BR-002-000001`. A draft shows "Assigned
     on posting".
3. **Statuses:** 1 Draft → 2 Posted → 3 Cancelled.
   - A draft can be edited or deleted.
   - A posted receipt can only be cancelled, with a reason.
4. **A receipt has one source:**
   - **Container**: created automatically (rule 5), or with "Receive goods…" on the container.
   - **Order**: "Receive goods…" on a purchase order, or "+ New › From a purchase order…".
   - **Invoice**: "Receive goods…" on a posted purchase invoice.
   - **Manual**: "+ New › Without an order" (rule 16).

### 1.2 Imports (containers)

5. **When a movement whose type has the stage Delivery is completed**, a **draft** goods receipt is created for each
   eligible container on it.
   - The movement type's code does not matter: a user-made type with the Delivery stage counts too.
   - **Eligible:** status Confirmed, In Transit, At Port or Cleared (2–5), and no draft or posted goods receipt.
   - **The draft takes:**
     - lines = the container lines, expected = received = the loaded pieces;
     - date = the movement's end date;
     - warehouse = the container's "Warehouse (offloading destination)" when it is active and belongs to the
       container's branch, otherwise empty (chosen on the draft).
   - **Completing the movement never fails because of the receipts.**
     - The drafts are created in a second step, after the completion is committed (section 3.2 #10).
     - A container that gets no draft is reported with a reason. It shows in the Containers filter "Delivered, not
       received".
   - **The notification names both kinds of container:** "Draft goods receipts created: KTG-2026-0031,
     KTG-2026-0032 (warehouse to choose). Not created: KTG-2026-0033 already has GRN-BR-002-000004."
6. **"Receive goods…" on the container** creates the same draft by hand.
   - It covers containers followed without movements, containers whose last leg is not a Delivery, and containers
     whose Delivery was completed before the switch.
   - Allowed for status 2–5 with no open receipt. **(Decision 6.)**
   - Refused when a receipt exists (63013): "Container KTG-2026-0031 already has goods receipt {GRN-… | a draft}. Open
     it instead."
   - A container in status 2 (never dispatched) gets an orange Alert: "KTG-… has not left the supplier: no dispatch
     date or movement. Receive it only if the goods are really here."
7. **A container's receipt:**
   - **Lines:** they are the container's lines; lines cannot be added or removed.
   - **Received:** from 0 to the loaded quantity.
     - Above the loaded quantity (63000): "Line {n} ({item}): received {r} but only {l} were loaded."
     - When received ≠ loaded, a **reason** is required: a code (Short-shipped, Damaged, Missing, Wrongly counted at
       loading, Other) plus a free note. 63000: "Line {n} ({item}): choose a reason when the received quantity differs
       from the loaded quantity."
     - **The difference is settled** (rule 17): nothing more is expected for those pieces.
   - **Warehouse:** one for the whole container, which must belong to the container's branch (as the offload today).
     - Missing (63000): "Choose the warehouse the goods are received into."
     - Wrong (63000): "The warehouse {code} is inactive or does not belong to the branch of container KTG-…."
   - **Date received:**
     - Not in the future: the usual one-day tolerance for local against UTC dates, as `usp_PurchaseDocument_ValidateInput`
       allows.
     - Not before the end date of the container's latest completed Delivery-stage movement. 63000: "The goods cannot be
       received before MOV-… reached {place} on {date}."
   - **Posting is refused while a movement of the container is in progress** (63010): "Container KTG-… is travelling
     with movement MOV-…. Complete it before receiving the goods."
   - **The manual-share rule of the offload stays** (70013): "The posted charge {name} has a manual share on line {n}
     ({item}), which receives nothing. Cancel that charge and enter it again on the received lines."
   - **No longer required:** that every container line is invoiced by posted invoices (69016). Goods may be received
     before they are invoiced.
8. **Posting a container's receipt does what the offload did**, with the receipt as the stock document:
   - stock in at landed cost;
   - posted charges re-spread over what arrived, then frozen;
   - average, last and FOB costs updated;
   - the container becomes **Offloaded** (status 6), at the warehouse, read-only. The name stays "Offloaded"
     **(Decision 8)**;
   - the matched invoice lines are marked received.

### 1.3 Cost

9. **Cost at receipt, per line:**
   - **Matching** (section 2.4): the received pieces are matched to the pieces of posted invoices:
     - first the invoice the receipt was made from;
     - then, first in first out by posting time:
       - the container line;
       - the order line (any container or none);
       - for goods without an order, the same supplier and item.
   - **Matched pieces** take the **invoice cost**: the invoice line's FOB per piece, plus, for goods received outside a
     container, the invoice's own charges per piece.
   - **Unmatched pieces** take the **order price**: order line total ÷ the order's exchange rate ÷ order line pieces.
     This is the formula `usp_Container_Get` already uses for its estimate (44108-44114).
   - **Container lines:**
     - the charges are the container's posted charges spread over what arrived (`ChargesBase ÷ received`), as the
       offload did;
     - a container line's charges and landed cost are **always read from the container line**. They are never copied,
       so late charges (rule 11) stay counted once.
   - **Manual lines** (no order, no invoice) take the typed cost per piece. It defaults to the item's last cost.

   9a. **Goods sold before their receipt is posted** happens when out-of-stock selling is allowed, between the Delivery
   and the warehouse's posting.
   - When a receipt fills a negative company stock, the sold pieces went out at the old average.
   - Today `usp_Item_ApplyReceipts` clamps the negative stock to 0 (11723), so that cost is in neither stock nor cost of
     sales.
   - **At posting, the difference (receipt cost − average before) × the pieces that fill the negative stock goes to
     cost of sales**, as a `GRNCOST` adjustment with cause `NEGSTOCK`.
   - This applies to goods receipts only. Inventory In is unchanged.
10. **The cost of received goods follows the invoices automatically.** The trigger is anything that changes the
    matches of received pieces:
    - an invoice posted or cancelled;
    - a landed cost adjustment posted or cancelled;
    - a goods receipt posted or cancelled.

    After each one, every posted receipt line of the touched order lines (or supplier + item) is brought to its new
    target cost:
    - **Amount** = (new cost per piece − current cost per piece) × pieces received.
      - For container lines only the **FOB** part moves.
      - The adjustment runs when the FOB or the landed cost differs by at least 0.000001.
    - **The part still in stock** is worked out **per item for the whole event**: remaining = min(Σ pieces received net
      of pieces returned, company stock on hand). That part goes to the stock value, so the average cost changes.
      **The rest** goes to cost of sales (COGS).
      - When the company has none of the item left, everything goes to COGS.
      - This is a deliberate difference from the container late charge and the LCA, which cap by the warehouse's stock.
        The average is company-wide, and transfers move goods out of the receiving warehouse.
    - **Where it is recorded:** in `inventory.CostAdjustments` with `SourceKind 'GRNCOST'`, the mechanism of a late
      container charge.
      - **Dated** at the later of now and the receipt's own ledger date, so it is never replayed before its receipt.
      - Item costs are then replayed per item (`usp_Item_RebuildCosts`), as `usp_ContainerCharge_ApplyCost` does today.
    - **Exchange rate:** the difference includes the exchange-rate difference between the order and the invoice. It is
      a cost, not an exchange gain or loss **(Decision 4)**.
    - **What each record keeps:**
      - the receipt line: its current cost (FOB, charges, landed), which feeds last cost and returns;
      - the stock movement: the cost at receipt;
      - the ledger replay adds the adjustments.
11. **Charges after the receipt:**
    - **Container charges** posted or cancelled after the container is received keep **today's late-charge mechanism**,
      unchanged (`usp_ContainerCharge_ApplyCost`, `CNTCHARGE`).
    - **Local invoice charges** are part of the invoice cost (rule 9). When the invoice is posted after the goods
      arrived, rule 10 brings them in.
    - **A landed cost adjustment (LCA)** on a posted local invoice adjusts the received pieces through rule 10. The part
      not received yet enters the cost when it is received.
    - **Invoiced pieces that never arrive** carry their share of the **invoice's own** charges out of the cost, as their
      FOB. The supplier claim covers both.
      - Container charges are different: they keep being spread over what arrived.

### 1.4 Cancelling

12. **Cancel a goods receipt.** Only a posted one, with a reason (63000 "A cancellation reason is required.").
    - **Refusals:**
      - The container is Closed (63010): "Container {ref} is closed. Reopen it before cancelling its goods receipt."
      - The stock it brought was used (63007): "Cannot cancel: {item} in {warehouse} has only {n} left, but this goods
        receipt brought {m}."
      - Its cost was adjusted afterwards (63008): "The cost of these goods was adjusted after they were received
        (invoice price, landed cost or a late container charge). This goods receipt can no longer be cancelled."
        - This covers any `GRNCOST` row on its lines except `NEGSTOCK` at its own posting.
        - For a container, it also covers any `CNTCHARGE` on its charges, as 69018 does today.
      - Returned goods would be left without a receipt (63010): "Purchase return {PRET-…} took back goods of this receipt.
        Cancel the return first."
        - Checked after the rematch, inside the transaction: no invoice line may end with returned > received.
    - **Effects:**
      - reversal stock movements;
      - matches rebuilt;
      - order received and settled counters reduced, and the order reopens if it had closed automatically;
      - the other receipts of the same order lines brought to their new cost (rule 10, cause `GRNCANCEL`);
      - item costs replayed.
    - **For a container, also:**
      - its received quantities are cleared and its charges are no longer frozen; they are re-spread;
      - it goes back to its movement status (for example Cleared), and a new receipt can be made.
13. **Cancel an invoice whose goods were received.**
    - Allowed **(Decision 3)**. It has no stock effect.
    - The received pieces go back to the order price through rule 10. Goods without an order keep their cost at receipt.
    - The old refusal 69012 ("container … was already offloaded with it") stays only for containers offloaded **before**
      goods receipts (`fn_Container_ReceivedBy = 'Offload'`).
    - The existing refusals stay: returns or LCAs posted, payments allocated.

### 1.5 Local purchases

14. **"Receive goods…" on a purchase order**, Posted or Closed.
    - **Disabled reasons:**
      - Draft: "Approve the order first: goods are received against an approved order."
      - Waiting: "This order is waiting for approval."
      - Cancelled: "This order is cancelled."
      - "Everything ordered is already received."
      - "Everything still to receive travels in containers: it is received with its containers."
    - **The dialog proposes every order line**, with **To receive** = ordered − received − settled short − in containers
      not received − in draft receipts.
      - On an order that has containers, **Receive now starts at 0** on every line, with an orange Alert: "This order is
        shipped in containers: its goods are received with their containers. Receive pieces here only if they arrived
        without a container."
    - **Partial receipts** are allowed, into any active warehouse. The default is the order line's warehouse.
    - **Per line, "Nothing more will come"** (reason required) settles the rest of the line (rule 17).
    - **Posting refuses more than what remains outside containers** (63011): "Line {n}: {item} - {r} pcs received but
      only {x} remain to receive on the order line outside containers."
15. **"Receive goods…" on a posted purchase invoice.**
    - **What it proposes:** the invoice lines **not linked to a container**, with to receive = invoiced − received − in
      draft receipts.
      - The lines keep their order line, so matching works. This receipt's pieces match this invoice first.
      - On a "Shipped in containers" invoice, Receive now starts at 0, with the same kind of Alert.
    - **Disabled reasons:**
      - "Post the invoice first: goods are received against a posted invoice, or from the order."
      - "Every piece of this invoice is already received."
      - "This invoice's goods travel in containers: they are received with their containers."
      - On invoices posted before the switch: "Posted before goods receipts: its stock entered when it was posted (or when
        its container was offloaded)."

    15a. **"Receive the goods now" when an invoice is posted (Decision 7).**
    - **Shown** in the post confirmation of a local invoice that uses goods receipts, to a user who can create and post
      goods receipts.
    - **The checkbox:** "Receive the goods now into {warehouse of the lines}", **off by default**.
    - **When ticked:** the API posts the invoice, then creates and posts the receipt of rule 15, in two transactions.
      - When the receipt fails, the invoice stays posted and the message says "Invoice posted; the goods receipt was not:
        {reason}. Use Receive goods…".
16. **"+ New"** opens a chooser:
    - **"From a purchase order…"**: supplier, then its posted or closed orders with something to receive. The lines
      behave as rule 14, including the 0 default on orders in containers. It needs only the goods receipt create
      permission.
    - **"From a container…"**: containers in status 2–5 with no receipt (rule 6).
    - **"Without an order"** **(Decision 5)**:
      - **Fields:** branch, date, warehouse, a **required** supplier, and free lines with a typed cost.
        - Hint: "For stock that does not come from a supplier (opening balance, correction, found goods), use
          Inventory › Inventory In."
      - **Refused at posting** (63011) when the supplier has posted or closed order lines, or posted invoice lines
        without an order, of the same item with pieces still to receive: "SUP-0001 has PO-BR-002-000042 with 100 pcs of
        {item} still to receive: receive them from the order."
      - **Last cost:** these lines do not change the item's last cost, FOB cost or last supplier until they are matched
        to an invoice.
      - **Matching:** they are matched to the same supplier's later invoices **without an order** for the same item, so
        "Receive goods…" on such an invoice does not offer them again, and their cost follows the invoice (rule 10).

### 1.6 Orders, containers, returns, reports

17. **Purchase order counters:**
    - **Invoiced** = `ReceivedQuantityBase` (meaning unchanged).
    - **Received** = `GoodsReceivedBase` (new). It counts every posted goods receipt line, plus the receipts made before
      goods receipts (local invoices posted with stock, containers offloaded).
    - **Settled short** = `GoodsShortBase` (new):
      - expected − received on posted container receipt lines (always, since a reason is required);
      - the rest of a local line marked "Nothing more will come".
    - **Outstanding** = max(0, ordered − received − settled short) on an open order, and max(0, invoiced − received −
      settled short) on a closed one. Shortages and the item card's "On order" use this one formula (rule 25).
    - **The order list** shows a "Received" progress (received ÷ ordered) and an "Invoiced" progress. The lines show
      Received, Invoiced and Short.
18. **An order closes automatically** when every line is fully invoiced **and** received or settled short:
    invoiced ≥ ordered and received + settled ≥ ordered. **(Decision 2.)**
    - Close reason: "Fully invoiced and received".
    - It reopens when an invoice or a goods receipt that closed it is cancelled. The close reasons "Fully received" (old)
      and "Fully invoiced and received" (new) both count.
    - Orders already closed as "Fully received" stay closed. Goods can still be received against them.
    - **Cancelling an order** is refused while it has posted goods receipts (65011): "This purchase order has posted
      goods receipts. Cancel those first." It is also refused while it has draft goods receipts: "This purchase order has
      draft goods receipts. Delete them first."
19. **Invoicing received containers** is allowed (goods may arrive first).
    - "Create Invoice from Containers…" also lists containers received by a goods receipt (Offloaded or Closed).
    - Posting an invoice on such a container is allowed.
    - 65019 stays for a cancelled container, for a container offloaded before goods receipts, and for more than the
      loaded quantity.
20. **Close a container:**
    - Status Offloaded, no draft charge (as today).
    - **Every received piece matched to a posted invoice:** Σ matches on the container's receipt lines ≥ received,
      re-using 69016: "Line {n} ({item}): {r} received but {i} invoiced by posted invoices. Post the supplier invoices
      before closing the container."
    - Reopen is unchanged.
21. **A container with a draft or posted goods receipt** cannot have its load lines or branch changed, and cannot be
    cancelled or deleted (69019): "Container KTG-… has goods receipt {GRN-… | a draft}. Delete the draft (or cancel the
    receipt) first."
    - **Header fields stay editable** until the receipt is posted: truck, waybill, declaration, FERI, B/L, free days,
      notes, warehouse.
    - A warehouse changed on the container does not change an existing draft, which has its own "Receive into". The
      container page says so.
    - Movements still accept the container. Posting the receipt is refused while a movement is in progress (rule 7).
22. **Cancelling a completed Delivery movement** deletes the **automatic draft** receipts it created.
    - The cancel dialog lists them and names the ones edited since: "GRN draft of KTG-2026-0031 was edited by {user} on
      {date}: the received quantities and reasons typed there are lost."
    - Each container's history says "Draft goods receipt removed: movement MOV-… cancelled".
    - A draft made by hand is kept.
    - A posted receipt makes the container Offloaded, and the existing refusal applies: "Container … is already
      offloaded: its route can no longer change."
23. **Purchase returns** stay "from a posted invoice". For an invoice that uses goods receipts, **and for an older
    "Shipped in containers" invoice**:
    - **Pieces** ≤ received − returned (65011): "Line {n}: {item} - {q} base units returned but only {x} were received
      and not returned on the invoice line."
    - **Cost** = the invoice line's own current cost:
      - local: its landed cost;
      - container: its FOB + the container line's charges ÷ received.
      - It is recomputed when the return is posted.
    - **Warehouse** defaults to the receipt's.
    - **Goods received but not invoiced** cannot be returned with a PRET. Receive fewer, cancel the receipt, or use
      Inventory Out.
    - Old local invoices, posted before the switch, keep the limit invoiced − returned. Invoices posted before script
      24 never had their own received quantity set.
24. **Last cost, FOB cost, last supplier** come from the latest posted goods receipt line, after its cost adjustments.
    Manual lines count only once matched. For older goods they still come from the old receipts.
25. **Shortages and the item's purchase orders** use one formula:
    - incoming = outstanding of rule 17 on open and closed orders;
    - plus posted invoices without an order that use goods receipts: invoiced − received;
    - minus what travels in containers (Transit, Shortages only).
26. **The old Offload is retired.** `usp_Container_Offload` refuses (69010): "Containers are received with a goods
    receipt now. Use Receive goods… on the container."
    - **Cancel Offload** stays for containers offloaded before goods receipts. It also lowers the order's received
      counter.
    - For a container received by a goods receipt it refuses (69010): "This container was received with goods receipt
      {GRN-…}: cancel that goods receipt instead."
27. **From now:**
    - documents posted before the switch keep their stock and cost;
    - draft invoices follow the new rule when they are posted;
    - containers still travelling are received with goods receipts.

    Details are in section 7.
28. **Invoice lines that a goods receipt points to** cannot be linked to or unlinked from containers (65028): "Goods
    receipt {GRN-… | a draft} refers to this invoice line: delete or cancel it first."

### 1.7 Error numbers (new block 63xxx)

| No. | Meaning | HTTP | Example message |
|---|---|---|---|
| 63000 | validation | 400 | "Choose the warehouse the goods are received into." |
| 63004 | concurrency | 409 | "This goods receipt was modified by another user. Reload the page and try again." |
| 63005 | not a draft | 409 | "Only a draft goods receipt can be changed or deleted." |
| 63006 | not found | 404 | "Goods receipt not found." |
| 63007 | stock consumed (cancel) | 409 | "Cannot cancel: … has only N left, but this goods receipt brought M." |
| 63008 | cost adjusted (cancel) | 409 | rule 12 |
| 63009 | nothing to receive / no lines | 400 | "Nothing is left to receive on this order." / "The goods receipt has no lines." |
| 63010 | invalid status / source state | 409 | "Only a draft goods receipt can be posted." / movement in progress / container closed / returns |
| 63011 | more than remains / receive from the order | 400 | rules 14–16 |
| 63012 | attachment type not for goods receipts | 400 | (CheckForKind) |
| 63013 | the container already has a receipt | 409 | rule 6 |
| 69019 | container has a goods receipt | 409 | rule 21 |
| 69016 | (re-used) container not fully invoiced at Close | 409 | rule 20 |
| 69010 | (re-used) Offload retired / Cancel Offload of a GRN container | 409 | rule 26 |
| 65011 | (re-used) PO with goods receipts; return above received | 409 / 400 | rules 18, 23 |
| 65028 | (re-used) invoice line referred to by a goods receipt | 409 | rule 28 |

---

## 2. Data model

### 2.1 Where the GRN lives, and why

The GRN gets **its own tables**:
- `purchase.GoodsReceipts`, `GoodsReceiptLines`, `GoodsReceiptInvoiceMatches`, `GoodsReceiptCostChanges`,
  `GoodsReceiptFiles` and `GoodsReceiptAudit`;
- plus a one-row `GoodsReceiptSwitch`.

This is the pattern of the LCA and the supplier payments. It is **not** `purchase.PurchaseDocuments`:
- About 30 queries in about 19 current procedures read every `PurchaseDocumentLines` row with a `ContainerLineId` or
  `SourceLineId` as an invoice line, with no type filter. Among them: the `dir` subqueries (43437, 43638, 43904, 44453,
  46606, 47551, 47713), the offload, charge allocation, and the link procedures.
- `PurchaseDocument_Cancel` refuses while any posted child exists. `CreateFromSource` knows only PO→PINV and PINV→PRET.
- A GRN has no prices, currency, rate or approval.
- `usp_PurchaseDocument_ValidateInput` (38524) accepts **any** purchase-family type code. Script 65 makes it refuse codes
  other than PO, PINV and PRET (65008), so a `PurchaseDocuments` row of type GRN can never exist and clash with the ledger
  key family + type + id.

The ledger rows use `DocumentFamily 'Purchase'` and `DocumentTypeCode 'GRN'`:
- `RebuildCosts`' reversal rule (family + type + id, 23026-23028) then works.
- The PINV cancel (filters by type) and the `CNT` offload rows are untouched.

### 2.2 New tables (script 64)

All foreign keys are real constraints: the master-data deletes are driven by them. The supplier column is named
`SupplierId`, which the party check matches with `LIKE 'Supplier%'`.

**`purchase.GoodsReceipts`**

| Column | Type | Notes |
|---|---|---|
| Id | INT IDENTITY PK | |
| DocumentTypeId | INT NOT NULL FK `inventory.DocumentTypes` | the GRN row |
| DocumentNumber | NVARCHAR(30) NULL | at posting; `UX_GoodsReceipts_Number` filtered NOT NULL |
| DocumentDate | DATE NOT NULL | date received |
| BranchId | INT NOT NULL FK | container's, order's, invoice's, or chosen; numbering branch |
| WarehouseId | INT NULL FK | "Receive into". Required to post a container receipt (every line booked there) |
| SupplierId | INT NULL FK `masterdata.Parties` | NULL only on a mixed container ("Several suppliers"); required on Manual |
| SourceKind | NVARCHAR(10) NOT NULL | CHECK IN ('Container','Order','Invoice','Manual') |
| ContainerId | INT NULL FK `logistics.Containers` | |
| PurchaseOrderId | INT NULL FK `purchase.PurchaseDocuments` | the order (Order source; single-order container) |
| PurchaseInvoiceId | INT NULL FK `purchase.PurchaseDocuments` | Invoice source |
| MovementId | INT NULL FK `logistics.Movements` | the Delivery movement that created it |
| IsAuto | BIT NOT NULL DF 0 | created by a Delivery completion |
| SupplierReference | NVARCHAR(100) NULL | "Delivery note no." |
| Notes | NVARCHAR(1000) NULL | |
| Status | TINYINT NOT NULL DF 1 | CHECK IN (1,2,3) |
| TotalExpectedBase, TotalReceivedBase | INT NOT NULL DF 0 | |
| ValueAtReceiptBase | DECIMAL(18,2) NOT NULL DF 0 | Σ received × cost at receipt (fixed at posting). The current value is computed in Get / Search |
| PostedAtUtc / PostedBy, CancelledAtUtc / CancelledBy / CancelReason NVARCHAR(300) | | |
| CreatedAtUtc / CreatedBy, UpdatedAtUtc / UpdatedBy, RowVersion | | |

Indexes:
- `UX_GoodsReceipts_OpenContainer (ContainerId) WHERE ContainerId IS NOT NULL AND Status < 3`: one open receipt per
  container;
- `IX_GoodsReceipts_Order (PurchaseOrderId)` and `IX_GoodsReceipts_Invoice (PurchaseInvoiceId)`, filtered NOT NULL;
- `IX_GoodsReceipts_StatusDate (Status, DocumentDate DESC)`.

**`purchase.GoodsReceiptLines`**

| Column | Type | Notes |
|---|---|---|
| Id | INT IDENTITY PK | |
| GoodsReceiptId | INT NOT NULL FK | UNIQUE (GoodsReceiptId, LineNumber) |
| LineNumber | INT NOT NULL | |
| ItemId, ItemUnitId | INT NOT NULL FK | container lines: the base unit |
| Quantity | INT NOT NULL | received, in the unit; CHECK ≥ 0 (0 allowed on container lines only) |
| PackingFormula | INT NOT NULL | |
| QuantityBase | AS (Quantity * PackingFormula) PERSISTED | received pieces |
| ExpectedQuantityBase | INT NULL | container: loaded; order or invoice: to receive when created |
| VarianceReasonCode | NVARCHAR(20) NULL | CHECK IN ('SHORT','DAMAGED','MISSING','LOADCOUNT','OTHER') |
| VarianceReason | NVARCHAR(300) NULL | the free note |
| CloseShort | BIT NOT NULL DF 0 | local lines: "Nothing more will come" (container lines settle always) |
| SettledShortBase | INT NOT NULL DF 0 | set at posting: expected − received when settled, else 0 |
| WarehouseId | INT NULL FK | container lines = header warehouse |
| SupplierId | INT NULL FK | from the line's order (or invoice, or the manual header) |
| PurchaseOrderId, PoLineId | INT NULL FK | the order line |
| InvoiceLineId | INT NULL FK `purchase.PurchaseDocumentLines` | the invoice line it was received from (Invoice source) |
| ContainerLineId | INT NULL FK `logistics.ContainerLines` | |
| ExpiryDate | DATE NULL | default: the order line's, else the invoice line's |
| PoFobBase | DECIMAL(18,6) NULL | order price per piece in base currency, frozen at posting |
| ManualUnitCostBase | DECIMAL(18,6) NULL | typed cost (manual lines) |
| FobCostBase, ChargesBase, UnitCostBase | DECIMAL(18,6) NULL | **current** cost per piece of **non-container** lines. NULL on container lines: their cost is the container line's (`cl.FobCostBase`, `cl.ChargesBase ÷ cl.ReceivedQuantityBase`, `cl.LandedCostBase`) |
| CostAtReceiptBase | DECIMAL(18,6) NULL | the cost written on the stock movement |
| CostSource | NVARCHAR(10) NULL | 'Order' / 'Invoice' / 'Mixed' / 'Manual' (current) |
| InvoicedBase | INT NOT NULL DF 0 | pieces matched to posted invoices |
| Notes | NVARCHAR(300) NULL | |

Indexes: on `PoLineId`, `InvoiceLineId` and `ContainerLineId` (filtered NOT NULL), `(SupplierId, ItemId)` and `(ItemId)`.

**`purchase.GoodsReceiptInvoiceMatches`**: which received pieces each posted invoice line pays for.
- Columns:
  - GoodsReceiptLineId INT FK;
  - InvoiceLineId INT FK `purchase.PurchaseDocumentLines`;
  - QuantityBase INT CHECK > 0;
  - MatchedAtUtc DATETIME2(3) DF now.
- Keys: PK `(GoodsReceiptLineId, InvoiceLineId)`, plus IX `(InvoiceLineId)`.

**`purchase.GoodsReceiptCostChanges`**: the history of rules 9a and 10, one row per receipt line per event.

| Column | Type | Notes |
|---|---|---|
| Id | INT IDENTITY PK | = `CostAdjustments.SourceId` |
| GoodsReceiptLineId | INT NOT NULL FK | |
| ChangedAtUtc | DATETIME2(3) | |
| CauseKind | NVARCHAR(12) | CHECK IN ('PINV','PINVCANCEL','LCA','LCACANCEL','GRNPOST','GRNCANCEL','NEGSTOCK') |
| CauseId, CauseNumber | INT, NVARCHAR(30) | the invoice, LCA or receipt that caused it |
| ReceivedBase, InStockBase | INT, DECIMAL(18,6) | the share used for the split |
| FobBefore / FobAfter, UnitCostBefore / UnitCostAfter | DECIMAL(18,6) | |
| AmountBase, InventoryBase, CogsBase | DECIMAL(18,2) | Amount = Inventory + COGS |
| CreatedBy | INT NULL | |

**`purchase.GoodsReceiptFiles`** has the shape of the purchase files after scripts 52 and 55: AttachmentTypeId NOT
NULL, DocumentDate, Note, FileName, ContentType, SizeBytes, Content, CreatedAtUtc, CreatedBy.

**`purchase.GoodsReceiptAudit`** has the common shape: Id BIGINT, GoodsReceiptId, Action NVARCHAR(20) (Created | Updated
| Posted | Cancelled | Deleted | CostAdjusted | FileAdded | FileDeleted), Details NVARCHAR(500), UserId, AtUtc.

**`purchase.GoodsReceiptSwitch`**:
- Columns: `Id TINYINT PK CHECK (Id = 1)`, `SwitchedAtUtc DATETIME2(3)`.
- Inserted once, by script 65 (section 3.2 #1).
- Its date is shown as "Posted before goods receipts ({date})".

**Type `purchase.tvp_GoodsReceiptLine`**:
- Columns: LineNumber, ItemId, ItemUnitId, Quantity, WarehouseId, PoLineId, InvoiceLineId, ContainerLineId,
  ExpectedQuantityBase, VarianceReasonCode, VarianceReason, CloseShort, ManualUnitCostBase, ExpiryDate, Notes.
- **Frozen in A1.** `IF TYPE_ID … IS NULL CREATE TYPE` never alters a type. A later change uses a new name
  (`tvp_GoodsReceiptLine2`). During development, recreate it by hand, never from Schema.sql.

**Type `purchase.tvp_GoodsReceiptAnchor`**: Kind CHAR(1) ('P' order line | 'S' supplier + item), PoLineId, SupplierId,
ItemId.

### 2.3 New columns on existing tables

| Column | Script | Meaning |
|---|---|---|
| `purchase.PurchaseDocuments.UsesGoodsReceipts` BIT NOT NULL DF 0 | 64 adds it | Set to 1 **by the new Post when it posts a PINV** (script 65). 0 = posted before the switch (old behaviour, ReceiptMode decides), or not a PINV. Drafts are never flipped; the default never changes. Every reader tests `dt.Code = 'PINV' AND d.UsesGoodsReceipts = 1` |
| `purchase.PurchaseDocumentLines.GoodsReceivedBase` INT NOT NULL DF 0 | 64 adds it; 65 fills it once (section 7) | PO lines: pieces **received** |
| `purchase.PurchaseDocumentLines.GoodsShortBase` INT NOT NULL DF 0 | 64 | PO lines: pieces **settled short** (rule 17) |

`inventory.DocumentTypes` gets a new row through a MERGE: `GRN`, "Goods Receipt", Family `Purchase`, StockDirection 1,
prefix `GRN-`, NumberOnPost 1, RequiresReason 0.
- In the same batch, guarded by `UpdatedAtUtc IS NULL` (the PAY model, 36429-36433): NumberPerBranch 1, YearInNumber 0,
  NumberLength 6, DefaultPricing `None`, PriceEditable 0.

### 2.4 Quantities and links

| Where | Column | Meaning |
|---|---|---|
| PO line | `QuantityBase` | ordered |
| PO line | `ReceivedQuantityBase` | **invoiced** (unchanged; name kept) |
| PO line | `GoodsReceivedBase` / `GoodsShortBase` (new) | **received** / **settled short** |
| PINV line | `QuantityBase` / `ReturnedQuantityBase` | invoiced / returned (unchanged) |
| PINV line | `ReceivedQuantityBase` | received = Σ matches for GRN-using and mode-2 invoices; unchanged for old mode-1 invoices |
| Container line | `QuantityBase` / `ReceivedQuantityBase` | loaded / received (set by the GRN post, as by the offload) |
| GRN line | `ExpectedQuantityBase` / `QuantityBase` / `SettledShortBase` / `InvoicedBase` | expected / received / settled / matched |

**Links of a GRN line:**
- its container line (`ContainerLineId`);
- its order line (`PoLineId`), always set when the goods come from an order, including container lines through
  `ContainerLines.PoLineId`;
- its invoice line (`InvoiceLineId`), Invoice source only;
- its supplier.

**Matching (`usp_GoodsReceipt_Rematch`).** A group is either **an order line** Y (with all its container lines) or **a
supplier + item** for goods without an order.
- **Inside a group:** matches are rebuilt from nothing, in passes. Each pass takes only what earlier passes left. Order
  is **first in, first out** by `ISNULL(PostedAtUtc, CreatedAtUtc), Id` on both sides.

| Pass | Receipt side (posted GRN lines) | Invoice side (posted or closed PINV lines) |
|---|---|---|
| 0 (chosen invoice) | lines with `InvoiceLineId = Z` | line Z |
| 1 (container line X of Y) | `ContainerLineId = X` | `ContainerLineId = X` |
| 2 (order line Y) | `PoLineId = Y`, any container or none | `SourceLineId = Y`, linked or not |
| 3 (supplier S + item I, no order) | `PoLineId IS NULL`, Manual or Invoice source, supplier S, item I | `SourceLineId IS NULL`, supplier S, item I |

**Never matched:**
- invoice lines of old mode-1 invoices (`UsesGoodsReceipts = 0 AND ReceiptMode = 1`): they received their own goods;
- container lines of containers offloaded before goods receipts (`fn_Container_ReceivedBy = 'Offload'`), and their
  invoice lines.

**After a rematch:**
- `grl.InvoicedBase` and `grl.CostSource` are set;
- `pil.ReceivedQuantityBase` = Σ matches for the group's invoice-side lines;
- every posted receipt line of the group is trued up (rule 10). Zero deltas are skipped.

### 2.5 Who received a container

`logistics.fn_Container_ReceivedBy(@ContainerId)` (inline TVF, one row):
- `'GRN'` when a posted goods receipt of the container exists;
- `'Offload'` when the status is 6 or 7 and no posted GRN exists;
- NULL otherwise.

It is the **only** test for "offloaded before goods receipts". It is used in:
- Rematch;
- 69012 on invoice cancel;
- 65019 on invoice post;
- the CancelOffload guard;
- RebuildCosts (b);
- the recompute (b);
- Container Get (`CanCancelOffload`, FobSource).

---

## 3. Procedures

Every changed object is re-created with **CREATE OR ALTER from its current body plus the change**.
- Tables, columns and types come first in each script (the empty-database rule).
- Both scripts are idempotent and additive: nothing is dropped or renamed.
- Every script ends with `SET NOEXEC OFF`.
- The guard at the top of each script uses `RAISERROR` 16 + `SET NOEXEC ON` (requires script 63; 65 requires 64).

### 3.1 Script 64: Goods Receipts (new objects; nothing that runs today changes)

1. **Tables, types and columns** of sections 2.2 and 2.3.
2. **Document type GRN**: the MERGE, then the guarded UPDATE.
3. **Permissions and one-time grants** (section 6), in **one batch and one transaction**:
   - MERGE into `security.Permissions` with the names, descriptions and sort orders of `PermissionCatalog.cs`;
   - `OUTPUT` the inserted codes into a table variable;
   - make the grants only for those codes, before the batch ends.

   An OUTPUT table does not survive `GO`. Do not use script 24's every-start grant pattern (16682-16688), which gives
   back rights an administrator removed.
4. **Attachments:**
   - re-create `masterdata.fn_AttachmentDocumentKinds` from its script 55 body, + `('GRN', 'Goods receipts', …)`;
   - re-create `masterdata.usp_AttachmentType_Delete` (script 55) to also look in `purchase.GoodsReceiptFiles`;
   - the usage seed for `GRN` (Other, plus the delivery-note, packing-list and bill-of-lading types when they exist) runs
     **only in the batch that first inserts the GRN document type** (OUTPUT of the MERGE in 2). So it is never re-seeded
     after an administrator changes it.
5. **`logistics.fn_Container_ReceivedBy`** (section 2.5).
6. **`purchase.fn_PoLine_Progress(@PurchaseOrderId)`** (inline TVF), per order line:
   - OrderedBase, InvoicedBase, GoodsReceivedBase, GoodsShortBase;
   - InContainersBase = Σ `cl.QuantityBase` of containers in status 1–5 holding the line;
   - InDraftReceiptsBase = Σ draft GRN lines with this `PoLineId` and no container line;
   - ToReceiveBase = max(0, ordered − received − short − in containers − in drafts): what the dialogs propose;
   - MaxOutsideBase = max(0, ordered − received − in containers): the posting cap of local lines;
   - OutstandingBase = rule 17 (open: ordered − received − short; closed: invoiced − received − short; ≥ 0).
7. **`purchase.fn_PoLine_CommittedOutside(@PoLineId)`** (scalar or inline TVF) =
   MAX(invoiced outside containers, received outside containers + in draft receipts outside containers).
   - **Invoiced outside containers** = today's `dir`: invoice lines with `ContainerLineId NULL` of documents in status
     1, 2 or 4 with `ReceiptMode <> 2`.
   - **Received outside containers** = posted GRN lines with `PoLineId = Y AND ContainerLineId IS NULL`.
   - **In draft receipts outside containers** = the same for draft GRN lines.
   - It is a maximum, not a sum: an invoiced piece and a received piece outside containers are the same goods (they are
     matched).
   - Script 65 uses it in place of `dir`.
8. **`purchase.fn_InvoiceLine_ToReceive(@InvoiceId)`**: per invoice line not linked to a container, ToReceiveBase =
   max(0, invoiced − received − in draft GRNs referencing it).
   - 0 for an old mode-1 invoice (`UsesGoodsReceipts = 0 AND ReceiptMode = 1`), whose goods are already in stock.
9. **`purchase.usp_GoodsReceipt_Rematch @Anchors tvp_GoodsReceiptAnchor`**: the passes of section 2.4. It returns the
   GRN line ids of the groups.
10. **`purchase.fn_GoodsReceiptLine_TargetCost(@GoodsReceiptId)`** (inline TVF, read-only; used by Post, TrueUp and the
    invoice preview). Per posted GRN line with received R > 0:

    | Line | Target FOB per piece | Target charges per piece |
    |---|---|---|
    | container | (Σ match × (`pil.FobCostBase` + `pil.AllocatedChargesBase ÷ pil.QuantityBase`) + (R − matched) × base) ÷ R | `cl.ChargesBase ÷ cl.ReceivedQuantityBase` (moved only by CNTCHARGE) |
    | local (order or invoice) | (Σ match × `pil.FobCostBase` + (R − matched) × base) ÷ R | (Σ match × `pil.AllocatedChargesBase ÷ pil.QuantityBase` + (R − matched) × baseCharges) ÷ R |
    | manual | matched as local; unmatched at `ManualUnitCostBase` | as local |

    - **Container line matched to an invoice with its own charges** (a local, mode-1 invoice matched by pass 2; added
      in round 3): the invoice line's own charges per piece ride on the container line's target FOB, because TrueUp
      only moves a container line's FOB. No charge is lost; the line's FOB (and the item's FOB cost) then includes them.
    - **Unmatched base:**
      - `PoFobBase` when the line has an order line, with no charges;
      - else the cost at receipt, landed: an invoice without an order, or a manual line, keeps the price it was
        received at.
    - **`PoFobBase`** = `pol.LineTotal / po.ExchangeRate / pol.QuantityBase`. LineTotal is after the line discount
      (9330); there is no header discount.
11. **`purchase.usp_GoodsReceipt_TrueUpCost @LineIds, @CauseKind, @CauseId, @CauseNumber, @UserId`** acts on the lines
    whose target FOB or target landed differs from the current one by ≥ 0.000001.
    1. **Amount** per line:
       - container: ROUND((target FOB − `cl.FobCostBase`) × R, 2);
       - other lines: ROUND((target landed − `grl.UnitCostBase`) × R, 2).
    2. **In-stock share, per item over all the event's lines:**
       - R_net = R − pieces returned from its matched invoice lines (pro rata over its matches);
       - Remaining = min(Σ R_net, max(company on hand, 0));
       - Inventory per line = ROUND(Amount × (1 − returned share of the re-priced pieces) × Remaining ÷ Σ R_net, 2),
         the leftover cents on the largest line; the returned share is non-zero only for LCA / LCACANCEL (the line's
         pieces matched to the adjustment's invoice lines, weighted by what it adds per piece, and of those the
         share returned from each invoice line): a returned piece is no longer in stock, as the old LCA's Allocated /
         Qty × Remaining had it;
       - everything goes to COGS when the company holds none of the item;
       - COGS = Amount − Inventory.
    3. **Records:**
       - a `GoodsReceiptCostChanges` row;
       - the `inventory.CostAdjustments` rows: Kind Inventory and COGS, `SourceKind 'GRNCOST'`, SourceId = the
         cost-change Id, SourceNumber = the GRN number, the line's warehouse and its branch, PurchaseLineId NULL;
       - **AdjustmentDate = MAX(SYSUTCDATETIME(), the receipt's MovementDate)**;
       - never a filter on `AmountBase > 0`. That filter, used by the LCA cancel (13050), must not be copied: GRNCOST
         writes compensating rows.
    4. **Updates:**
       - container lines: `ContainerLines.FobCostBase` = target, then `logistics.usp_Container_RecalcCosts`;
       - other lines: `grl.FobCostBase / ChargesBase / UnitCostBase / CostSource`.
    5. GRN audit "Cost adjusted by {cause}: {amount} (stock {inv}, cost of sales {cogs})". Then
       `inventory.usp_Item_RebuildCosts` per item, the replay `ApplyCost` also uses.
    6. Returns the totals, for the invoice audit, the API message and the preview.
12. **`purchase.usp_GoodsReceipt_Save`**: creates or updates a draft from `@Lines tvp_GoodsReceiptLine`, with RowVersion
    (63004).
    - **Draft only** (63005).
    - **Lines:** the item is active, the unit belongs to the item, the warehouse is active.
    - **Local and manual lines:** Quantity > 0, "Line {n}: the received quantity must be more than 0." The API drops
      zero lines.
    - **Container receipts:** the line set equals the container lines; Quantity ≥ 0; base unit; warehouse = header.
    - **Order and invoice lines:** they belong to the receipt's source order or invoice, or to the chosen supplier's
      posted or closed orders ("From a purchase order…").
    - **Manual:** the supplier is required, and `ManualUnitCostBase ≥ 0`.
    - **Date:** not in the future (+1 day tolerance). For a container, not before its latest completed Delivery end.
    - **Totals**, and the audit "Created" / "Updated".
13. **`purchase.usp_GoodsReceipt_CreateFromOrder @PurchaseOrderId, @Lines (PoLineId, QuantityBase, WarehouseId, CloseShort)?,
    @DocumentDate, @SupplierReference, @UserId, @NewId OUTPUT`**:
    - **The order** must be Posted or Closed (63010): "Only an approved order can be received." / "The purchase order is
      cancelled."
    - **An empty `@Lines`** means every line with ToReceive > 0 (fn 6). When there is nothing, 63009: "Nothing is left
      to receive on this order." or "Everything still to receive on this order travels in containers: it is received
      with its containers."
    - **Header:** the order's branch and supplier; the warehouse = the first line's.
    - **Units:** a line is in the order line's unit when the quantity divides by its packing formula, otherwise in the
      base unit.
14. **`purchase.usp_GoodsReceipt_CreateFromInvoice @InvoiceId, …`**:
    - **The invoice** must be a posted or closed PINV (63010): "Post the invoice first: goods are received against a
      posted invoice, or from the order."
    - **Lines** = the invoice lines not linked to a container, with ToReceive > 0 (fn 8). `InvoiceLineId` is set, and
      `PoLineId = pil.SourceLineId`.
    - **Nothing left** (63009): "Every piece of this invoice is already received." / "This invoice's goods travel in
      containers: they are received with their containers."
15. **`purchase.usp_GoodsReceipt_CreateForContainer @ContainerId, @DocumentDate = NULL, @MovementId = NULL, @UserId,
    @Silent BIT = 0, @NewId OUTPUT, @SkipReason NVARCHAR(20) OUTPUT`**:
    - **Status:** the container must be in status 2–5. Otherwise 63010: "Only a confirmed container that is not
      received yet can be received."
    - **No open receipt** (63013).
    - **Lines:** = the container lines. Base unit, expected = received = `cl.QuantityBase`, `PoLineId`,
      `PurchaseOrderId`, the line's supplier, and expiry = the order line's.
    - **Header:**
      - the container's branch;
      - SupplierId = the single supplier of its orders, else NULL;
      - PurchaseOrderId when it holds a single order;
      - the warehouse rule of rule 5;
      - IsAuto = 1 and MovementId when called for a movement.
    - **`@Silent = 1`:** no THROW for eligibility. `@SkipReason` = 'Received', 'HasDraft', 'NotConfirmed', 'Cancelled' or
      'NoLines'.
      - It locks the container row with `UPDLOCK, HOLDLOCK` and inserts with `WHERE NOT EXISTS`.
      - Only OUTPUT parameters are used, no SELECT.
16. **`purchase.usp_GoodsReceipt_CreateForMovement @MovementId, @UserId`** (new; called by the API **after**
    `usp_Movement_SetStatus` has committed a Complete of a Delivery-stage movement):
    - `SET XACT_ABORT OFF`. Each container goes through its own transaction and TRY/CATCH, calling #15 with
      `@Silent = 1`.
    - Returns one row per container: ContainerId, ContainerRef, GoodsReceiptId, WarehouseCode, Created (bit),
      SkipReason. A runtime error gives `SkipReason = 'Error'` with the message.
    - It refuses (70010) a movement that is not completed or not Delivery-stage.
17. **`purchase.usp_GoodsReceipt_Delete`**: draft only (63005), with RowVersion.
    - It deletes the files, lines and audit.
    - When `IsAuto`, it writes the container audit line "Draft goods receipt deleted".
18. **`purchase.usp_GoodsReceipt_Post @Id, @RowVersion, @UserId`**: one transaction, with locks on the receipt, its
    container and its order lines.
    1. **Checks:**
       - draft (63010);
       - lines > 0 (63009);
       - header warehouse set for container receipts (63000);
       - every line's warehouse active, and a container's warehouse in its branch (63000);
       - the date rule (63000);
       - container status 2–5 and no movement in progress (63010);
       - container lines unchanged since the draft (63000): "The container's lines changed after this goods receipt was
         created. Delete it and receive the container again.";
       - received ≤ expected, and a reason code when different on container lines (63000);
       - the 70013 manual-share check.
       - **Order cap, local lines only.** These are lines with `PoLineId` and no `ContainerLineId`. Per `PoLineId`, Σ
         received ≤ MaxOutsideBase (fn 6) (63011). **Container lines are bounded by the loaded quantity alone.** Their own
         container must never count as "in containers" against them.
       - Invoice lines without an order: ≤ invoiced − received (63011).
       - Manual lines: the supplier rule of rule 16 (63011).
       - The order is not cancelled (63010).
    2. **Number:** `inventory.usp_DocumentType_NextNumber 'GRN', @Number OUTPUT, @BranchId`.
       - A GRN type that is inactive gives 63010: "The document type GRN is inactive: activate it in Configuration ›
         Document Types."
       - Then Status = 2, and PostedAtUtc = now, **before** the rematch.
    3. **Prices and matches:**
       - `PoFobBase` per line;
       - `SettledShortBase` (container lines: expected − received; local lines with CloseShort: expected − received;
         else 0);
       - `usp_GoodsReceipt_Rematch` for the groups of its lines.
    4. **Cost at receipt:**
       - **Container:**
         - set `ContainerLines.ReceivedQuantityBase` and `VarianceReason` (code + note);
         - `ContainerLines.FobCostBase` = target FOB (#10);
         - `usp_Container_ReallocateCharges @Id, 0`, then `AppliedAtOffload = 1` on the posted landed charges, then
           `usp_Container_RecalcCosts`;
         - `CostAtReceiptBase = cl.LandedCostBase`.
       - **Local and manual:** the target of #10 into `FobCostBase / ChargesBase / UnitCostBase`, and `CostAtReceiptBase
         = UnitCostBase`.
    5. **Stock:**
       - **Negative stock (rule 9a):** per item, F = min(max(−company on hand before posting, 0), R). When F > 0, write a
         `NEGSTOCK` cost change and a COGS `GRNCOST` row of ROUND((receipt cost − AverageCost before) × F, 2), pro rata
         over the item's lines.
       - **Average, last and FOB cost:** per supplier of the lines, `inventory.usp_Item_ApplyReceipts @R, @SupplierId,
         @UserId, @UpdateLastCost`, called **before** inserting that supplier's movements.
         - `@UpdateLastCost = 0` for manual lines not matched.
       - **The movements:** `inventory.StockMovements` rows:
         - MovementDate = DocumentDate + the current UTC time of day, as every stock document;
         - the line's warehouse, and BranchId = the warehouse's branch;
         - +QuantityBase, `UnitCostBase = CostAtReceiptBase`;
         - Family `Purchase`, TypeCode `GRN`, the receipt's DocumentId and DocumentLineId, its DocumentNumber and the
           line's ExpiryDate.
       - Lines with QuantityBase = 0 write nothing.
    6. **True-up (`'GRNPOST'`)** of the **other** posted receipt lines of the touched groups: this receipt may have taken
       invoice pieces they held.
    7. **Order lines:**
       - `GoodsReceivedBase += received`, `GoodsShortBase += SettledShortBase`;
       - the auto-close of rule 18 for each order touched;
       - audit on the order: "Goods received by GRN-…", and when closed, "Closed: fully invoiced and received".
    8. **Container:**
       - `OffloadedDate = DocumentDate`, `OffloadedAtUtc`, `OffloadedBy`, `WarehouseId`;
       - `usp_Container_RefreshStatus` (gives 6, location = the warehouse; 19180);
       - ContainerAudit `Offloaded`: "GRN-…: received {n} pcs into {code} at a landed value of {v}; {k} line(s)
         short-shipped".
    9. **Totals**, the GRN audit "Posted as GRN-… - {n} pcs into {warehouse}", and the audit "Goods received by GRN-…" on
       each matched invoice.
    10. Returns `DocumentNumber`.
19. **`purchase.usp_GoodsReceipt_Cancel @Id, @Reason, @RowVersion, @UserId`**:
    1. **Checks:**
       - posted (63010);
       - reason (63000);
       - RowVersion (63004);
       - container not Closed (63010);
       - 63008 (rule 12);
       - 63007, per item and warehouse: on hand ≥ what this receipt brought.
    2. **Stock:**
       - reversal movements: copies with −QuantityBase, `IsReversal = 1`, date = now;
       - Status 3 and the cancel stamps.
    3. **Matches and costs:**
       - rematch the groups of its lines (it is now Cancelled, so it drops out);
       - **then refuse (63010) when any invoice line of those groups has ReturnedQuantityBase > ReceivedQuantityBase**
         (rule 12);
       - then `TrueUpCost` (`'GRNCANCEL'`) for the other receipt lines of the groups.
    4. **Order lines:**
       - `GoodsReceivedBase −= received`, `GoodsShortBase −= SettledShortBase`;
       - reopen the order when its CloseReason is "Fully received" or "Fully invoiced and received", with the audit
         "Re-opened: GRN-… was cancelled".
    5. **Container:**
       - container lines received / variance / FOB / landed = NULL;
       - `AppliedAtOffload = 0`, then `usp_Container_ReallocateCharges @Id`;
       - `Offloaded*` = NULL;
       - StatusNote "Goods receipt GRN-… cancelled: {reason}";
       - `RefreshStatus`;
       - ContainerAudit `OffloadCancelled`.
    6. `usp_Item_RebuildCosts` per item, and the GRN audit "Cancelled".
20. **`purchase.usp_GoodsReceipt_Get`**, result sets in this order:
    1. **Header:** + names, source numbers, movement no. and end date, the latest Delivery place;
       - `Can*` flags, and **`PostBlockedReason` / `CancelBlockedReason` / `DeleteBlockedReason`**, with the same
         sentences as the SQL refusals;
       - current value.
    2. **Lines:** + item, unit, warehouse, supplier, order and invoice numbers, container line no.;
       - current cost (the container line's for container lines);
       - value; SettledShort.
    3. **Matches:** invoice number, quantity, invoice FOB.
    4. **Cost changes.**
    5. **Files** (no content).
    6. **Audit.**
21. **`purchase.usp_GoodsReceipt_Search`**: paged.
    - **Filters:**
      - search (number, container ref or no., order and invoice numbers, item code);
      - status, source kind, branch, supplier, warehouse, date range;
      - ContainerId, PurchaseOrderId, InvoiceId;
      - **WithDifferences**;
      - **ReceivedNotInvoiced** (posted lines with QuantityBase − InvoicedBase > 0).
    - **Totals row:** received not invoiced, in pieces and at the order price, for month-end.
22. **`purchase.usp_GoodsReceipt_WaitingCount @UserId`**: the drafts, for the menu count.
23. **`purchase.usp_PurchaseInvoice_ReceiptCostPreview @InvoiceId`** (read-only): for a **draft** PINV, per line:
    - the received pieces of its group not matched yet, up to the line's quantity, taken first in first out;
    - their current cost, the invoice cost, the difference;
    - the estimated stock / cost-of-sales split, on today's company stock.

    It is labelled an estimate.
24. **Files:** `usp_GoodsReceipt_File_Add / _List / _Get / _Update / _Delete`. They follow the purchase file procedures
    of script 55, and call `usp_AttachmentType_CheckForKind (…, 'GRN', 63012)`.

### 3.2 Script 65: the switch (changes to existing procedures)

1. **The one-time switch batch**: `IF NOT EXISTS (SELECT 1 FROM purchase.GoodsReceiptSwitch)`, in one transaction:
   - recompute `GoodsReceivedBase` for every PO line (section 7.2). `GoodsShortBase` stays 0;
   - insert the marker row.

   On later starts this batch does nothing. **No drafts are flipped, and no default changes.**
2. **`purchase.usp_PurchaseDocument_ValidateInput`** (38503 body): refuse type codes other than PO, PINV and PRET
   (65008).
3. **`purchase.usp_PurchaseDocument_Save`** (script 63 body):
   - **The 65026 guard** (46591-46611): `dir` → `fn_PoLine_CommittedOutside` (for this invoice's lines: max(other
     invoiced outside + this, received outside + drafts)).
   - **PRET lines:** the cost of rule 23.
   - **Save no longer sets `UsesGoodsReceipts`.**
4. **`purchase.usp_PurchaseDocument_Post`** (46714 body):
   - **A PINV posts with `@ReceiveNow = 0` and `UsesGoodsReceipts = 1`, whatever the receipt mode:**
     - no `ApplyReceipts`, no `StockMovements`, no "lines received = QuantityBase";
     - the FOB / charges / landed step stays.
   - **65019:**
     - a container in status 6 or 7 is refused only when `fn_Container_ReceivedBy = 'Offload'`;
     - cancelled containers are still refused;
     - quantities above the loaded quantity are still refused.
   - **PRET from a source with `UsesGoodsReceipts = 1 OR ReceiptMode = 2`:**
     - Σ per source line ≤ `ReceivedQuantityBase − ReturnedQuantityBase`, with the 65011 message of rule 23;
     - `UnitCostBase / FobCostBase` recomputed (rule 23).

     Older mode-1 sources keep QuantityBase − ReturnedQuantityBase (46837-46847).
   - **PO progress:** invoiced += as today.
     - The auto-close needs every order line ReceivedQuantityBase ≥ QuantityBase AND GoodsReceivedBase + GoodsShortBase
       ≥ QuantityBase.
     - CloseReason "Fully invoiced and received".
   - **After the final UPDATE** that sets Status and PostedAtUtc (46936):
     - rematch the groups of its lines: their order lines, and supplier + item for lines without an order;
     - then `TrueUpCost` (`'PINV'`, the invoice id and number).
   - **Audit text:** "Posted as PINV-… - n line(s); goods are received with goods receipts". Add "; cost of received
     goods adjusted by {amount}" when the true-up moved something.
5. **`purchase.usp_PurchaseDocument_Cancel`** (38147 body):
   - **69012** only when `fn_Container_ReceivedBy` of the line's container is 'Offload'.
   - **The 65007 stock check** only for `dt.Code = 'PINV' AND UsesGoodsReceipts = 0 AND ReceiptMode = 1` (old).
     - **Also for those old invoices:** the order lines' `GoodsReceivedBase −= x.Qty`, because the recompute counted them
       as received.
   - **A PO** with posted goods receipts, or draft ones, is refused (rule 18).
   - **A PINV with `UsesGoodsReceipts = 1` or mode 2 (not old offload):**
     - its lines' `ReceivedQuantityBase` = 0;
     - rematch its groups;
     - `TrueUpCost` (`'PINVCANCEL'`).
   - **Reopen the order** when CloseReason is "Fully received" or "Fully invoiced and received".
6. **`purchase.usp_PurchaseDocument_CreateFromSource`** (script 63 body), PINV → PRET from a source with
   `UsesGoodsReceipts = 1` or mode 2:
   - availability per line = `ReceivedQuantityBase − ReturnedQuantityBase − drafts`;
   - warehouse = the warehouse of the matched GRN line with the most pieces.
7. **`purchase.usp_PurchaseDocument_CreateFromContainers`** (script 63 body) and
   **`logistics.usp_Container_InvoiceCandidates`** (script 27):
   - accept containers whose `fn_Container_ReceivedBy` is 'GRN' (status 6 and 7);
   - still refused when cancelled or old-offloaded;
   - any line already fully invoiced is still excluded;
   - the 65019 text becomes "… the container is cancelled or was offloaded before goods receipts.".
8. **`purchase.usp_PurchaseDocument_Get`** (script 63 body):
   - **PO lines:** + the columns of `fn_PoLine_Progress`; `dir` (47551) → `fn_PoLine_CommittedOutside`.
   - **PINV lines:** + `ToReceiveBase` (fn 8).
   - **Header:** + `UsesGoodsReceipts`, `CanReceive`, `ReceiveBlockedReason`.
   - **NEW LAST result sets,** so the existing readers keep their order:
     - "goods receipts" (Id, number, date, status, source kind, received pcs, value);
     - for a PINV, "cost adjustments" (its `GoodsReceiptCostChanges` with CauseId = the invoice).
9. **`purchase.usp_PurchaseDocument_Search`** (script 63 body):
   - `ReceivedPercent` = Σ GoodsReceivedBase ÷ Σ ordered. `InvoicedPercent` stays (47803).
   - For a PINV, + `ReceivedBase` / `QuantityBase` totals for the list's "Received" progress.
   - Filters: "To receive" (orders) and "Not fully received" (invoices).
10. **`logistics.usp_Movement_SetStatus`** (42853 body):
    - **Complete: unchanged.** The drafts are made after the commit by the API (3.1 #16).
    - **Cancel of a completed Delivery-stage movement**, inside its transaction:
      - delete the **automatic** draft receipts with `MovementId = @Id`, with plain DELETEs (files, lines, audit,
        header);
      - ContainerAudit "Draft goods receipt removed: movement MOV-… cancelled".
    - **No new result set.**
11. **`logistics.usp_Container_Offload`** (21447 body): re-created as a refusal only (69010, rule 26). Its parameters are
    kept.
12. **`logistics.usp_Container_CancelOffload`** (21642 body):
    - refuses (69010) unless `fn_Container_ReceivedBy = 'Offload'`;
    - otherwise unchanged, **plus**: the PO lines' `GoodsReceivedBase −= cl.ReceivedQuantityBase` reversed, and an order
      closed "Fully invoiced and received" is reopened.
13. **`logistics.usp_Container_Close`** (20071 body): + the 69016 check of rule 20 (Σ matches ≥ received, per container
    line) for containers received by a GRN.
14. **`logistics.usp_Container_Save`** (43299 body): + 69019 when an open receipt exists **and** the lines or the branch
    change. Header-only saves pass. In the same object, `dir` (43437) → `fn_PoLine_CommittedOutside`.
    **`logistics.usp_Container_Cancel`** and **`usp_Container_Delete`**: + 69019.
15. **`logistics.usp_Container_PlanFromOrder`** (43638), **`usp_Container_CreateBatch`** (43904),
    **`usp_Container_AvailablePoLines`** (44453) and **`purchase.fn_PurchaseInvoice_ContainerState`** (47713): `dir` →
    `fn_PoLine_CommittedOutside`.
    - In `fn_PurchaseInvoice_ContainerState` (47733-47747) and `usp_PurchaseInvoice_LinkContainers` (41402), for
      `UsesGoodsReceipts = 1` invoices, the reason "This invoice was received when it was posted…" becomes "This invoice
      was posted without 'Shipped in containers': its goods are received with Receive goods…, not with containers.".
16. **`purchase.usp_PurchaseInvoice_LinkContainers`** (41377) and **`_UnlinkContainer`** (34685): + 65028 of rule 28.
17. **`logistics.usp_Container_Get` / `_Search`** (script 54):
    - + `GoodsReceiptId`, `GoodsReceiptNumber`, `GoodsReceiptStatus` (the open or posted one), and `ReceivedBy`;
    - + `DeliveredDate` = the latest completed Delivery-stage movement's EndDate;
    - Search filter "Delivered, not received": status 2–5, no posted GRN, a completed Delivery or an open draft;
    - FobSource 'Offload' becomes 'Received';
    - `CanCancelOffload` only for `ReceivedBy = 'Offload'`.
18. **`logistics.usp_Container_Tracking`** (around 20660): DaysAtPort ends at `COALESCE(OffloadedDate, DeliveredDate,
    today)`. The free-time badge stops at the Delivery.
19. **`logistics.usp_Movement_Get`** (script 27): the container set gets `GoodsReceiptId / Number / Status`, the
    container's warehouse code, and whether its warehouse belongs to its branch (for the Complete dialog).
20. **`inventory.usp_Item_RebuildCosts`** (23012 body). LastCost / FobCost / LastSupplier / LastPurchaseAt come from the
    latest of:
    - (a) posted PINV lines with `ReceiptMode = 1 AND UsesGoodsReceipts = 0`;
    - (b) container lines of containers with `fn_Container_ReceivedBy = 'Offload'`;
    - (c) posted GRN lines with QuantityBase > 0, except manual lines not matched. They give:
      - the cost: `cl.LandedCostBase / cl.FobCostBase` for container lines, else `grl.UnitCostBase / FobCostBase`;
      - the line's `SupplierId` and the receipt's `PostedAtUtc`.

    The replay part is unchanged.
21. **`inventory.usp_Item_StockStatement`** (45803 body):
    - the `purchase.PurchaseDocuments` join (45834) excludes `'GRN'`;
    - + LEFT JOIN the GRN header and line for the supplier and the **source reference** (container ref, else order
      number).
22. **`inventory.fn_Shortage_Live`** (46241 body) and **`inventory.usp_Item_PurchaseOrders`** (45874 body): the `po`
    apply and OutstandingBase use the formula of rule 25.
    - `fn_PoLine_Progress.OutstandingBase` on PO lines of status 2 and 4.
    - Invoices without an order that use goods receipts: QuantityBase − ReceivedQuantityBase.
    - The old mode-2 "pending invoice" term is replaced by the order's outstanding; it was counted on the order already.
    - Transit unchanged.
    - `usp_Item_PurchaseOrders`: `ReceivedBase` = GoodsReceivedBase, + `InvoicedBase` = ReceivedQuantityBase, +
      `ShortBase`.
23. **`purchase.usp_LandedCostAdjustment_Post / _Cancel`** (12923 / 13025 bodies), for an invoice with
    `UsesGoodsReceipts = 1`:
    - allocate and update the invoice lines' `AllocatedChargesBase / UnitCostBase` as today, **first**;
    - **do not** change `Items.AverageCost`, write `'LCA'` cost adjustments, or touch `LastCost`;
    - then rematch is not needed. Call `TrueUpCost` for the GRN lines matched to its lines (`'LCA'` / `'LCACANCEL'`, the
      LCA id and number);
    - store the resulting inventory and COGS portions on the LCA lines, with `ReceivedBase` = matched pieces.

    Old invoices keep the current logic.
24. **Check section** (report only; it never overwrites). `PRINT` and `SELECT` output is discarded at API start, because
    `DatabaseInitializer` has no InfoMessage handler. These lists are for sqlcmd runs. The in-app filters of section 5
    serve users.
    - **Drift:** PO lines whose `GoodsReceivedBase` differs from the recompute formula.
    - Containers in status 2–5 whose Delivery is already completed (they need "Receive goods…").
    - Posted mode-2 invoice lines not linked and not received.
    - Orders closed "Fully received" with goods still to receive.
    - `PRINT 'Script 65 applied: …'`.

Refresh `DatabaseProject` **once after 65**, not after 64 alone.

### 3.3 Objects re-created by 64 and 65

These must be re-based on their **last** definition when the work starts. Diff each re-created body against it, and
show the diff in the step report.

- **Purchase:**
  - `usp_PurchaseDocument_ValidateInput / _Save / _Post / _Cancel / _Get / _Search / _CreateFromSource /
    _CreateFromContainers`;
  - `usp_PurchaseInvoice_LinkContainers / _UnlinkContainer`;
  - `fn_PurchaseInvoice_ContainerState`;
  - `usp_LandedCostAdjustment_Post / _Cancel`.
- **Logistics:**
  - `usp_Container_Save / _Cancel / _Delete / _PlanFromOrder / _CreateBatch / _AvailablePoLines / _InvoiceCandidates /
    _Offload / _CancelOffload / _Close / _Get / _Search / _Tracking`;
  - `usp_Movement_SetStatus / _Get`.
- **Inventory:** `usp_Item_RebuildCosts / _StockStatement / _PurchaseOrders`, `fn_Shortage_Live`.
- **Master data:** `fn_AttachmentDocumentKinds`, `usp_AttachmentType_Delete`.

---

## 4. API

**Model** (`Inventory_Shipment.Model/DTOs/Purchase/GoodsReceipts.cs`):
- `GoodsReceiptListItemDto`:
  - id, documentNumber, documentDate, status, statusName, sourceKind;
  - branch, supplier ("Several suppliers" when null on a container receipt), warehouse;
  - containerId / containerRef, purchaseOrderId / number, purchaseInvoiceId / number, movementNo, isAuto;
  - lineCount, expectedBase, receivedBase, shortBase, valueBase, postedAtUtc.
- `GoodsReceiptDto`:
  - the header, `lines[]`, `matches[]`, `costChanges[]`, `files[]`, `audit[]`;
  - `canEdit / canPost / canCancel / canDelete` and their `…BlockedReason`;
  - rowVersion.
- `GoodsReceiptLineDto`:
  - item, unit, packingFormula, quantity, quantityBase, expectedQuantityBase;
  - varianceReasonCode, varianceReason, closeShort, settledShortBase;
  - warehouse, supplier, poLineId / orderNumber, invoiceLineId / invoiceNumber, containerLineId / containerLineNumber,
    expiryDate;
  - poFobBase, fobCostBase, chargesBase, unitCostBase, costAtReceiptBase, costSource, invoicedBase, valueBase.
- `GoodsReceiptSaveRequest`:
  - documentDate, branchId, warehouseId, supplierId, supplierReference, notes, rowVersion;
  - `lines[]` {lineNumber, itemId, itemUnitId, quantity, warehouseId, poLineId, invoiceLineId, containerLineId,
    expectedQuantityBase, varianceReasonCode, varianceReason, closeShort, manualUnitCostBase, expiryDate, notes}.
- Requests:
  - `ReceiveFromOrderRequest` {purchaseOrderId, documentDate, supplierReference, lines?: [{poLineId, quantityBase,
    warehouseId, closeShort, reason}], post};
  - `ReceiveFromInvoiceRequest` {invoiceId, …, post};
  - `ReceiveContainerRequest` {containerId, documentDate?, warehouseId?, lines?: [{containerLineId, quantityBase,
    varianceReasonCode, varianceReason}], post}.
- `ReceivableLineDto` (the dialog preview), `MovementReceiptResultDto` {containerId, containerRef, goodsReceiptId,
  warehouseCode, created, skipReason, message}, and `ReceiptCostPreviewDto`.

**Controller** `GoodsReceiptsController`, route `api/purchase/goods-receipts`, `[HasPermission]` per action:

| Verb / path | Permission | Does |
|---|---|---|
| GET `/` | goodsreceipts.view | search, paged, with the totals row |
| GET `/waiting` | view | the count of drafts, for the menu |
| GET `/{id}` | view | the document |
| GET `/{id}/print` data = GET `/{id}` | view | (the page prints) |
| POST `/` | create | draft (any source) |
| PUT `/{id}` | create | save draft |
| DELETE `/{id}?rowVersion=` | delete | draft only |
| POST `/{id}/post` {rowVersion} | post | returns the number and the document |
| POST `/post-many` {ids} | post | one by one, independent: `[{id, ok, documentNumber, message}]` |
| POST `/{id}/cancel` {reason, rowVersion} | cancel | |
| GET `/receivable?purchaseOrderId=` / `?invoiceId=` / `?supplierId=` | create | lines and to-receive figures for the dialogs and "From a purchase order…" |
| POST `/from-order`, `/from-invoice`, `/from-container` | create (+ post when `post`) | {id, documentNumber?, status} |
| GET `/{id}/export` | view | `GRN-{number}.xlsx` (header + lines: expected, received, difference, reason, cost, value, source) |
| files: GET `/{id}/files`, POST `/{id}/files`, GET / PUT / DELETE `/files/{fileId}` | view / create | as the purchase documents |

**Errors:**
- Add `SqlErrors` constants 63000–63013 (69016, 69010, 65011 and 65028 exist), and a `Describe()` in
  `GoodsReceiptService`.
- Update the `SqlErrors` header comment (63xxx goods receipts).
- HTTP mapping: 400 for 63000, 63009, 63011 and 63012; 404 for 63006; 409 for the others.

**Changes to existing endpoints and DTOs:**
- **Movements:**
  - `MovementService.SetStatusAsync`, when the action is Complete and the type's stage is Delivery, calls
    `usp_GoodsReceipt_CreateForMovement` **after** `SetStatus` returned. A failure there becomes a warning in the
    response; it never fails the completion.
  - The response carries `goodsReceipts: MovementReceiptResultDto[]`.
  - `MovementDto.containers` + `goodsReceiptId / Number / Status`, warehouse code and `warehouseInBranch`.
  - `MovementRepository.SetStatusAsync` is unchanged (`ExecuteAsync`).
  - The hook needs no goods-receipt permission (`containers.movements.manage` is enough).
- **Purchase documents:**
  - PO lines + `goodsReceivedBase, goodsShortBase, inContainersBase, inDraftReceiptsBase, toReceiveBase, outstandingBase`;
  - PINV lines + `toReceiveBase`;
  - header + `usesGoodsReceipts, canReceive, receiveBlockedReason, goodsReceipts[], costAdjustments[]`;
  - list + `invoicedPercent` and `receivedPercent`. **`InvoicedPercent` exists in SQL but is not mapped in C# today**
    (`PurchaseDocumentRepository.cs`, `PurchaseDocuments.cs`): add it to the DTO and the web type;
  - invoice list + `receivedBase / quantityBase`, and the filters;
  - the post request + optional `receiveNow` (rule 15a);
  - the post response `message` + "cost of received goods adjusted by …" and the receipt result;
  - GET `api/purchase/documents/{id}/receipt-cost-preview` (`purchase.invoices.post`).
- **Containers:**
  - `ContainerDto`: `canOffload` is always false (kept for old clients);
  - new: `canReceive` (status 2–5, no open receipt), `goodsReceiptId / Number / Status`, `receivedBy`, `deliveredDate`;
  - `canCancelOffload` only for old offloads;
  - `POST …/offload` stays, but SQL refuses (rule 26);
  - list filter `deliveredNotReceived`.
- **Item stock statement:** + `sourceReference`.
- **PermissionCatalog** (section 6). The class comments that say an invoice or the offload moves stock in are rewritten.
- **Container charges Excel import** (task #10): no change. Status 6 keeps the name "Offloaded", so its texts ("is
  offloaded: posting this charge adjusts the cost of its items (a late charge)") stay true.

Build with 0 warnings; the API starts ("Database schema verified").

---

## 5. Web

Shared pieces, as Inventory In / Out: `DocumentHeaderCard`, `DocumentLinesGrid`, `DocumentSummary`, `AuditTrail`,
`DocumentActionBar`, `AttachmentsDrawer`, `CancelReasonModal`, `useBulkSelection`, `BulkActionsBar`,
`BulkResultsModal`.
- **A separate family page**, not a fourth `PurchaseKind`: there are no prices, currency or approval.
- **Quality:** typecheck, lint and build clean; no console errors; 1440 and 390 px.
  - At 390 px the receipt lines show Item, Expected, Received and Reason first; the cost columns drop below them.

### 5.1 Menu, routes, links
- **`navigation.ts`:**
  - Purchase › **Goods Receipts**, placed after Approvals and before Purchase Invoices (the order of flow B);
  - permission `goodsReceiptsView`, icon: add `inbox` to `NavIcon.tsx` (for example `IconPackageImport`). Today it has
    no such icon (`box` is the warehouse);
  - **`countOf: 'draftGoodsReceipts'`** (hidden at 0), served by `GET …/waiting` with the approvals facts (`NavFacts`).
- **The menu comment** becomes "an order is confirmed, the goods are received (stock in, costs set) and invoiced…".
- **`App.tsx` routes:**
  - `/purchase/goods-receipts` (view);
  - `/purchase/goods-receipts/new` (create);
  - `/purchase/goods-receipts/:id` (view);
  - `/purchase/goods-receipts/:id/print` (view).
- **Links:**
  - `routes.ts`: `goodsReceipts`, `goodsReceipt(id)`, `goodsReceiptPrint(id)`;
  - `ItemStockMovementsPage.documentRoute`: `case 'GRN'` goes to the receipt, shown "GRN-BR-002-000001 · KTG-2026-0031"
    with both links. `CNT` and `PINV` rows keep their links.
- **Clients:**
  - `api/purchase/goodsReceipts.ts`: the typed client;
  - `documentFiles.ts`: `AttachmentDocumentKind` + `'GRN'`;
  - `PERMISSIONS`: `goodsReceiptsView / Create / Post / Cancel / Delete`. Avoid the word "receipts" alone:
    `sales.receipts.*` is customer payments.

### 5.2 Purchase › Goods Receipts (list)
- **Title** "Goods Receipts", subtitle "Goods entering the stock: from containers, orders and invoices." "+ New" (create
  permission) opens the chooser of rule 16.
- **FilterBar:**
  - search ("Number, container, order, invoice or item");
  - Status, Source (Container / Order / Invoice / Manual), Branch, Supplier, Warehouse, dates;
  - "With differences", "Received not invoiced".
  - Filters apply automatically. When drafts exist, the list opens on Status = Draft (remembered per viewer in
    `localStorage`, guarded).
- **Columns:**
  - Number ("Assigned on posting" in gray for drafts);
  - Date;
  - Status badge (Draft gray, Posted green, Cancelled red);
  - Source ("Container KTG-2026-0031", "Order PO-BR-002-000042", "Invoice PINV-BR-003-000011", "Manual"), with an "Auto"
    badge when created by a movement;
  - Supplier ("Several suppliers");
  - Warehouse (an orange "to choose" on a draft without one);
  - Received (pcs);
  - Short (pcs, red when > 0);
  - Value.
- **Totals line under the table:** "Received not invoiced: {n} pcs, {value} at the order price."
- **Row actions:** View, Print, Post (draft), Delete (draft), Cancel… (posted), each by permission.
- **Bulk:** "Post selected", "Delete selected", with the results modal.
- **Empty state:** "No goods receipts yet. They are created when a container's delivery is completed, with Receive
  goods… on an order, an invoice or a container, or with + New."

### 5.3 Goods receipt page
- **Header:**
  - Number ("Assigned on posting"), "Date received", Branch;
  - "Receive into" (warehouse);
  - Supplier ("Several suppliers"), "Delivery note no.", Notes;
  - source chips: "Container KTG-…", "Order PO-…", "Invoice PINV-…", "Movement MOV-…". They are plain text when the
    reader lacks the view permission of the target.
- **Alerts:**
  - **Auto draft (blue):** "Created automatically when MOV-2026-000046 (Delivery, Kasumbalesa → Kolwezi) was completed
    on {date}. Proposed warehouse: LUB-WH (from the container). Check the warehouse and the received quantities, then
    post."
  - **No warehouse (orange):** "Choose the warehouse the goods are received into: the container's warehouse is not set
    or does not belong to branch {branch}."
  - **Draft (gray hint):** "The goods are not in stock until this receipt is posted."
- **Lines:**
  - Item;
  - Warehouse (local lines);
  - Expected (pcs);
  - Received (pcs, editable);
  - Difference (red when short);
  - Reason (a select + note; required when different on container lines);
  - "Nothing more will come" (local lines);
  - "Unit cost" with a badge "Order price" / "Invoice" / "Order + invoice" / "Typed";
  - Value.

  The rules for editing them:
  - container receipts: no add or remove;
  - manual receipts: "+ Add line" and "Unit cost" editable;
  - line errors are placed on their line ("Line N:").
- **Summary:** Expected, Received, Short, "Value at cost".
- **Actions:** Save, "Post", Delete, "Cancel…" (posted), "Print", "Attachments", "Export", Back.
  - They are disabled with the reason the API returns (`…BlockedReason`), for example "Choose the warehouse first." or
    "Container KTG-… is travelling with MOV-…: complete it first.".
  - **Delete of an auto draft** confirms: "KTG-… then waits without a receipt: create it again with Receive goods… on the
    container."
- **Post confirm:** "Post this goods receipt? {n} pcs enter {warehouse} at {value} {USD}, the item costs are updated and
  the number is assigned. Pieces not invoiced yet are valued at the order price; their cost is adjusted when the
  invoice is posted."
- **Notification:** "Posted: GRN-BR-002-000001".
- **Posted banner:** "Received into {warehouse} on {date} by {user}. The stock and the item costs were updated; this
  receipt can no longer be edited."
- **Card "Cost adjustments"** (posted, when any):
  - columns: Date, Cause ("Invoice PINV-… posted", "Invoice PINV-… cancelled", "Landed cost adjustment LCA-…", "Goods
    receipt GRN-… posted", "Goods receipt GRN-… cancelled", "Sold before receipt"), Item, Received, "Unit cost before →
    after", Amount, "To stock", "To cost of sales";
  - hint: "The part still in stock changes the average cost; the part already sold goes to the cost of sales. A
    difference of exchange rate between the order and the invoice is part of the cost."
- **Cancel dialog:** "Cancel goods receipt {number}? The stock it brought is taken out again and the item costs are
  replayed." For a container, add: "Container {ref} goes back to its delivery status and can be received again." The
  reason is required.

### 5.4 Print page
- `/purchase/goods-receipts/:id/print`, in the style of `ReceiptPrintPage`. Drafts print as the count sheet.
- **Content:**
  - company header;
  - GRN number, or "DRAFT - not posted";
  - date received, warehouse, supplier;
  - for a container: container ref and no., seal no., truck no. and waybill no.;
  - order and invoice numbers;
  - the lines: item, expected, received, difference, reason. No costs.
- **Two signature boxes:** "Received by", "Delivered by / driver".

### 5.5 "Receive goods…" on the purchase order and invoice
- **Order page:**
  - `receiveGoods: OrderAbility` in `orderAbilities.ts`, with its own reasons (rule 14). Do not reuse `notOpenReason`,
    which refuses Closed orders;
  - visible with `goodsReceiptsCreate`;
  - also a row action on the order list.
- **Invoice page:** posted invoices. Invoices posted before the switch show the button **disabled** with their reason
  (rule 15).
- **Dialog "Receive goods - {document no.}":**
  - **Table:** Item | Ordered (or Invoiced) | Received | Short | In containers | In draft receipts | To receive |
    **Receive now** (input) | "Nothing more will come" (+ reason) | Warehouse;
    - Receive now defaults to To receive, or **0 with the orange Alert** of rule 14 / 15 on orders in containers and
      shipped-in-containers invoices.
  - **Fields:** "Date received", "Delivery note no.".
  - **Hints:** "Goods in containers are received with their container." and "Pieces not invoiced yet are valued at the
    order price; the invoice adjusts their cost when it is posted."
  - **Buttons:** "Create draft" and "Create and post" (post permission).
  - **Then** the receipt opens, with the notification "Draft goods receipt created" or "Posted: GRN-…".
- **Order page, other changes:**
  - lines grid + "Received", "Invoiced", "Short";
  - list columns:
    - "Received", tooltip "% of the ordered quantity received (goods receipts)";
    - "Invoiced", tooltip "% of the ordered quantity invoiced";
    - export columns for both;
  - filter "To receive";
  - Linked documents list the goods receipts.
- **Invoice page, posting** (`purchaseKind.ts`):
  - **Post confirm:** "Post this purchase invoice? The number is assigned and the amount becomes payable to the supplier.
    The stock does not change: goods enter with goods receipts."
    - **The preview** (`receipt-cost-preview`) adds, when goods were received: "{n} pcs already received will have their
      cost adjusted by {+60.00} USD (estimate: stock {40.00}, cost of sales {20.00})."
    - **When nothing is received yet:** "No goods received yet: their cost will be this invoice's when they arrive."
    - **Rule 15a:** the checkbox "Receive the goods now into {warehouse}" (local invoices, create + post permissions).
  - **postedBanner:** "Posted. Received so far: {r} of {q} pcs."
  - The mode-2 banner ("…the stock enters when the containers carrying it are offloaded.", `PurchaseDocumentPage.tsx`
    1320) is replaced by the same banner.
  - **Old invoices** keep their texts, plus a gray hint "Posted before goods receipts: its stock entered when it was
    posted (or when its container was offloaded)."
- **Invoice page, other changes:**
  - "Shipped in containers" read-only text (`PurchaseHeaderCard.tsx` 349, 356): "Yes - received with its containers" /
    "No - received with Receive goods…"; the switch description becomes "Its goods travel in containers and are received
    with them.";
  - lines + "Received";
  - card "Cost of received goods": the true-ups this invoice caused, for example "Cost of received goods adjusted: +120.00
    USD (stock 80.00, cost of sales 40.00)";
  - Linked documents list the goods receipts.
- **Invoice list:**
  - a "Received" progress column (received ÷ invoiced pieces);
  - the filter "Not fully received";
  - a blue banner, once per viewer, for users with `purchase.invoices.post`: "Since {switch date}, posting a supplier
    invoice no longer adds stock: receive the goods with Receive goods…".

### 5.6 Container page and list (replaces Offload)
- **No receipt** (status 2–5): "**Receive goods…**" (create permission) opens a dialog.
  - It re-uses `OffloadModal`, renamed `ReceiveContainerModal`:
    - title "Receive goods - KTG-2026-0031";
    - warehouse, "Date received", received and reason per line;
    - "Create draft" / "Create and post".
  - Disabled for a draft container: "Confirm the container first.".
  - The orange Alert of rule 6 for status 2.
  - `?offload=1` becomes `?receive=1`.
- **Draft receipt:**
  - the button "Open goods receipt (draft)";
  - a blue Alert: "Goods receipt draft created on {date}. The goods are not in stock until it is posted. Changing the
    container's warehouse does not change the draft."
- **Posted receipt:**
  - the banner "Received by {GRN-…} into {warehouse} on {date} by {user}. The container is read-only…" with a link. It
    replaces "Offloaded into …" (`ContainerPage.tsx` 595);
  - "Cancel Offload" is replaced by "Cancel goods receipt…", which opens the receipt's cancel dialog;
  - containers offloaded before keep "Cancel Offload".
- **"Delivered" date** shown when set.
- **Containers list:**
  - a "Goods receipt" column (draft or GRN number, linked);
  - the filter "Delivered, not received";
  - the row action "Offload" becomes "Receive goods" (status 2–5, no receipt) or "Goods receipt" (open).
- **Wording** (every text that becomes false after script 65):
  - `ChargeDrawer`, `ContainerChargesCard`, `ContainerChargesPage.tsx` (220, 327): "after offload" → "after receipt";
    "The container is offloaded: the item costs will be adjusted" → "The goods are received: the item costs will be
    adjusted";
  - `LoadedItemsSection` FobSource "Offload" → "Received";
  - `PurchaseLinesGrid`: "final once the container is offloaded" → "final once the goods are received";
  - `ShippedInvoiceContainersCard.tsx` (98, 171): "enter the stock at the container offload" → "…when their containers'
    goods receipts are posted";
  - `OrderContainersCard.tsx` 167: "Offloaded {date} into {warehouse}" → "Received {date} into {warehouse} (GRN-…)";
  - `TrackingPage.tsx` 154 fact "Offloaded" → "Received";
  - `ShortageLinesGrid.tsx` 117: "not yet offloaded" → "not yet received";
  - `purchaseKind.ts` 49-50 (order):
    - "…count as incoming stock until they are invoiced or the order is closed" → "…until they are received or the order
      is closed";
    - "…a purchase invoice can be created from it" → "…goods can be received and invoiced against it";
  - `ItemSideCards.tsx` 73-83:
    - FOB: "on the last goods receipt (the order price until the invoice is posted)";
    - Last Cost: "The last goods receipt…";
    - Average Cost: "…and by cost adjustments (late charges, invoice price differences)";
  - `SalesProfitPage.tsx` 341: the comment and the COGS-adjustments hint name invoice price differences. The "by invoice"
    view says "Cost adjustments after the sale are shown by item, month or branch.";
  - Stock Valuation: a hint under the totals, "Goods received but not invoiced yet are valued at the order price; their
    cost moves when the invoice is posted.";
  - "Offloading warehouse" labels (`AutoPlanModal.tsx` 452, `ContainerPage.tsx` 733) stay, with the hint "the goods
    receipt proposes this warehouse".
- `OffloadModal.tsx` is renamed (above), not deleted.

### 5.7 Movement page
- **The Complete dialog** (`StatusDateModal`) gets the movement type's **stage**. For a Delivery it adds:
  - "The containers arrive at the warehouse: a draft goods receipt is created for each of them. The stock changes only
    when the warehouse posts it.";
  - a list built from the movement's container data:
    - "KTG-2026-0031 → draft goods receipt into LUB-WH";
    - "KTG-2026-0032 → draft, warehouse to choose";
    - "KTG-2026-0033 → no receipt: it already has GRN-BR-002-000004".
- **After Complete,** the notification of rule 5 names the created drafts (links when the reader has
  `goodsReceiptsView`) and the containers not created, with the reason.
- **Cancel of a completed Delivery:** the dialog lists the automatic drafts it will delete and names the edited ones
  (rule 22).
- **Containers card:** a "Receipt" column (draft or GRN number, linked).
- **`movementTypes.ts` Delivery explanation:** "Cleared - on its way to the warehouse; completing it creates the draft
  goods receipts."

### 5.8 Sales invoice (small)
- When an open draft receipt holds an item that goes out of stock on a sales invoice, the existing out-of-stock warning
  adds: "A goods receipt is waiting to be posted: {GRN draft of KTG-2026-0031}."

### 5.9 Conventions doc
- Add a section **"Goods receipts"** to `docs/frontend-conventions.md`:
  - the list, the page, the print page;
  - Receive goods…, and the 0 default on goods in containers;
  - the automatic drafts on Delivery completion, and the created / not-created message;
  - how cost adjustments are shown;
  - the menu count.
- Rewrite "Purchase documents": the posting wording, the meaning of "Shipped in containers", Received vs Invoiced vs
  Short.
- Update the Shortages formula.

---

## 6. Permissions

New in `PermissionCatalog.Purchase` (module Purchase), with the same values in the SQL MERGE:

| Code | Name | Description | Sort |
|---|---|---|---|
| `purchase.goodsreceipts.view` | View Goods Receipts | See goods receipts. | 1102 |
| `purchase.goodsreceipts.create` | Create Goods Receipts | Create and edit draft goods receipts, from containers, orders, invoices or by hand. | 1104 |
| `purchase.goodsreceipts.post` | Post Goods Receipts | Post goods receipts: the goods enter stock and the item costs are set. | 1106 |
| `purchase.goodsreceipts.cancel` | Cancel Goods Receipts | Cancel posted goods receipts (stock reversal). | 1108 |
| `purchase.goodsreceipts.delete` | Delete Goods Receipts | Delete draft goods receipts. | 1110 |

The sort orders 1102-1110 are free.

**Grants:**
- The administrator gets them through the start-up sync. `SyncCatalogAsync` runs after Schema.sql and never deletes
  codes. It overwrites names and descriptions, so the texts must be in `PermissionCatalog.cs` too.
- **One time, only when the codes are first inserted (one batch, one transaction, section 3.1 #3):**
  - every role holding `containers.offload` gets view, create and post;
  - every role holding `purchase.invoices.post` gets view, create and post, so the people who bring local goods into
    stock today can still do it;
  - every role holding `containers.cancel` or `purchase.invoices.cancel` gets cancel;
  - every role holding `purchase.invoices.view` or `purchase.orders.view` gets view;
  - every role holding create gets delete;
  - the **Manager** role gets view, create and post (it offloads today, and holds `containers.offload` since script
    24).

**Changed descriptions:**
- `containers.offload` becomes "Offload Containers (not used)": "No effect since script 65: containers are received
  with goods receipts." It is kept so roles still show it, as `purchase.orders.approve` is.
- `purchase.invoices.post` (PermissionCatalog.cs 430, today "Post purchase invoices (adds stock, sets costs).") becomes
  "Post purchase invoices (payable; adjusts the cost of goods already received)."
- `purchase.invoices.cancel`: "Cancel posted purchase invoices."
- `PermissionCatalog`'s comments are rewritten: the Containers class comment ("OFFLOAD IS ITS OWN PERMISSION…"), and the
  ones saying an invoice moves stock in.

**Not needed:**
- Completing a Delivery movement creates the drafts with `containers.movements.manage` alone.
- The container page's "Receive goods…" needs `purchase.goodsreceipts.create`.

---

## 7. Migration ("from now") and going live

### 7.1 Situations at the switch

| Situation at the switch | What happens |
|---|---|
| Posted local invoices (mode 1) | Unchanged: their stock and cost stay. `UsesGoodsReceipts = 0`. Cancel, PRET and LCA follow the old rules. Their order lines count them as received (7.2). Cancelling one after the switch lowers `GoodsReceivedBase` (3.2 #5). |
| Posted mode-2 invoices whose containers are **offloaded** | Unchanged: CNT ledger rows, Cancel Offload (which now also lowers `GoodsReceivedBase`), late charges. |
| Posted mode-2 invoices whose containers are **not offloaded** | The container is received with a goods receipt: automatically at its next Delivery completion, or with "Receive goods…". The invoice is matched (passes 1–2), so the cost is the invoice cost, with no adjustment. Returns are limited to received − returned. |
| Posted mode-2 invoice lines **not linked** to a container | Matched to the container's goods by pass 2 when the container is received. If the goods came without a container: "Receive goods…" on the invoice. |
| **Draft** invoices (any mode) | Not flagged. When posted after the switch, they move no stock and get `UsesGoodsReceipts = 1`. |
| Containers status 2–5 whose Delivery is **already completed** | No automatic draft. Listed by the Containers filter "Delivered, not received". Use "Receive goods…" on the container. |
| Orders closed "Fully received" with goods not yet received | Stay closed. Goods can still be received against them. |
| Open orders | `GoodsReceivedBase` filled once. They close automatically on the next event when fully invoiced and received (or settled). |
| Draft LCAs on old invoices | Old logic. |

### 7.2 One-time fill of `GoodsReceivedBase` (script 65, switch batch only)

Per PO line, the sum of:
- (a) the pieces of **non-reversed `'PINV'` stock movements** of invoice lines with `SourceLineId` = it. This reads the
  old local receipts from the ledger, so it is right whatever the flags say;
- (b) `cl.ReceivedQuantityBase` of container lines with `PoLineId` = it, whose container has `fn_Container_ReceivedBy =
  'Offload'` (old offloads);
- (c) `grl.QuantityBase` of posted GRN lines with `PoLineId` = it. This is 0 at the switch; it is written for
  completeness.

After the switch the counters are maintained by every event: GRN post and cancel, old PINV cancel, old Cancel Offload.
The Check section reports drift and never overwrites.

**Item costs:** nothing is replayed at the switch. `RebuildCosts` runs on the next event of each item, with the new
LastCost sources.

### 7.3 Going live (the switch is one-way)

1. **Say it plainly to Bilal.** Once a goods receipt, or an invoice posted the new way, exists, going back to the old
   code would receive goods twice:
   - the old Post moves stock for invoices;
   - the old CancelOffload finds no CNT rows for a GRN container.

   The only rollback is `deploy/restore.sh` with the backup `update.sh` takes just before it pulls. Data entered after
   that is lost.
2. **Branches.**
   - All the work, A1 to C1 in both repositories, is done on a feature branch (`grn`).
   - Never push script 64 or 65 to `main`, to GitLab `origin`, or to the GitHub `github` remote before the web is ready.
     A push to `main` deploys testing. GitLab reaches Ali's database at his next start.
3. **Rehearse on testing.**
   - On the server, in the testing folder: `sudo ./copy-production-to-testing.sh`.
   - Merge `grn` into `main`, **Web first, then API**, so the deploy started by the API push finds the new web.
   - Check the switch with the in-app lists: Containers "Delivered, not received", invoices "Not fully received", orders
     "To receive". Also run the read-only query of the deploy notes, run on the server with
     `sudo docker compose exec db /opt/mssql-tools18/bin/sqlcmd …`; it holds no password.
   - Run the A2 flows through the UI on the copy: local, import, invoice cancel, PRET, short shipment.
4. **Production.**
   - At a quiet moment, after checking that the nightly and pre-update backups exist, merge `main` into `production`,
     Web first.
   - Tell the users: warehouse, logistics and accounting. Local purchases now need "Receive goods…", or the checkbox of
     rule 15a.
5. **Ali.** Before he pulls: his own purchase invoices will stop moving stock when he next starts his API. He should
   save his work first. `git pull --no-rebase`.

---

## 8. Edge cases

1. **Short shipment.**
   - Loaded 84, invoiced 84, received 82 with a reason:
     - the 82 match the first 82 invoiced and take the invoice cost;
     - the 2 are settled short.
   - Then:
     - the order closes "Fully invoiced and received";
     - Shortages and the item's "On order" show 0 for the line;
     - the container can be closed (82 matched ≥ 82 received).
   - The 2 invoiced, unreceived pieces are a supplier claim. Their FOB is not in stock cost, as today.
2. **Pieces recorded short that turn up later.**
   - "Receive goods…" on the order proposes 0 for them (they are settled), but accepts up to what remains outside
     containers (MaxOutsideBase).
   - Pass 2 then matches them to the 2 unmatched invoiced pieces, so they take the invoice cost.
   - The outstanding formula never goes below 0.
3. **Partial invoice before receipt.** A container line of 84, with 40 invoiced and posted.
   - At receipt: 40 pieces at the invoice price and 44 at the order price ("Order + invoice").
   - The second invoice, of 44, adjusts the 44.
4. **Invoice first, not linked, container moves.**
   - The mode-2 invoice cannot be linked any more (65027).
   - At receipt, pass 2 matches it to the container's goods, so the cost reaches the invoice price. The container can
     close.
5. **Over-invoicing.** Invoiced more than received (after a short shipment): the extra invoiced pieces stay unmatched;
   no adjustment, no error.
6. **Receipt before invoice, then the invoice is cancelled and re-entered.**
   - The cost goes back to the order price, then to the new price.
   - That makes two `GRNCOST` adjustments, and the receipt becomes non-cancellable.
7. **Exchange rate.** The order at rate 1.10, the invoice at 1.12: the difference is part of the adjustment.
8. **Value-method container charges** are frozen at receipt, on values that included order prices. They are not
   re-spread when the invoice price arrives: frozen charges never move (today's rule).
9. **Late charge, then invoice.** The user-guide container: 84 pcs at order price 950, charges 2,940 posted, received at
   985.
   - A late charge of 840 gives CNTCHARGE 840 and landed 995.
   - Then the invoice at 960: the adjustment is (960 − 950) × 84 = 840 on the **FOB only**. Landed becomes 1,005. The
     late charge is counted once.
10. **Mixed container (several orders and suppliers):**
    - one receipt, with the supplier per line;
    - `ApplyReceipts` per supplier, giving the last supplier per item, as the offload did;
    - the header shows "Several suppliers".
11. **Container without warehouse, or with one of another branch:** the auto draft has no warehouse; posting is refused
    until one of the container's branch is chosen.
12. **Container with two Delivery-stage movements:**
    - the second completion finds an open receipt; it is reported "already has a receipt";
    - after a receipt is cancelled, the next Delivery completion (or "Receive goods…") creates a new draft.
13. **Completed Delivery cancelled:**
    - its automatic drafts are deleted, even edited ones, and the dialog names them first;
    - a draft made by hand is kept.
14. **A container on a new movement while a draft exists:** allowed. Posting is refused while that movement is in
    progress.
15. **Container lines changed after the draft:** prevented by 69019. Posting also re-checks (63000).
16. **Two drafts for the same order line:**
    - each is ≤ the remaining when created;
    - the second post is refused (63011) when together they exceed it.
17. **Goods received from the order, then loaded into a container:**
    - loadable = ordered − max(invoiced outside, received outside) − other containers, so a 100-piece line with 60
      received outside can take 40 in containers;
    - the other way round, 100 loaded leaves 0 to receive outside ("travels in containers").
18. **Received but not invoiced, then damaged or returned:** a PRET is not possible without an invoice. Receive fewer
    with a reason, cancel the receipt if nothing was used, or use Inventory Out.
19. **LCA on an invoice not received yet:** no adjustment now. The charges enter the cost at receipt, as part of the
    invoice cost.
20. **Returns after an adjustment:** the PRET takes the invoice line's current cost. A receipt whose goods were partly
    returned cannot be cancelled (rule 12).
21. **Stock sold before the invoice arrives:** the price difference of the sold part goes to COGS. The Sales Profit
    report shows it in the item, month, branch, family and brand groupings (13932-13946), not per invoice.
22. **Stock sold before the receipt is posted** (out-of-stock selling on):
    - the receipt's cost difference on the pieces that fill the negative stock goes to COGS (`NEGSTOCK`);
    - the menu count, the "Delivered, not received" filter and the sales warning make this window short.
23. **The company has none of the item:** the whole adjustment goes to COGS, as `ApplyCost` does.
24. **GRN document type deactivated:** automatic drafts are still created (no number is needed). Posting is refused
    (63010, rule 3.1 #18).
25. **A receipt cancelled after a later one of the same order line:** the later one may take over the earlier invoice
    match. Its cost is adjusted (`GRNCANCEL`), and it becomes non-cancellable.
26. **Invoice without an order:**
    - its receipts match it first, then the same supplier's manual receipts of the item;
    - if it is cancelled, the received pieces keep the cost they were received at.
27. **Manual receipt "Without an order":**
    - refused when the supplier has that item to receive on an order or an invoice without order;
    - it does not set last cost until matched.
28. **Old offloaded container:**
    - a late charge: CNTCHARGE as today;
    - its Cancel Offload follows the old rules and lowers the order's received counter.
29. **Tracking board / free time:** between Delivery completion and the receipt's posting, the container stays "Cleared"
    at the Delivery's To place. DaysAtPort and the free-time badge stop at the Delivery end date.
30. **Concurrency:** every receipt action checks RowVersion (63004 → 409 "Someone else changed this goods receipt.
    Reload the page."). Posting locks the receipt, its container and its order lines. The Delivery hook locks each
    container row.
31. **Back-dated receipts:** the receipt's stock rows carry its date received, as every stock document does. When a
    later adjustment replays the item, the average is re-based on the dated ledger, as late container charges already
    do today.

---

## Decisions still needed from the business owner

1. **Scope and timing.** The request relayed for this run was the container charges import. Should the Goods Receipt
   change be built?
   - **(A) Yes, as specified, after the open work is merged** (one item per invoice / script 63, one document per
     warehouse, container charges import). **(Recommended)**
   - (B) Yes, but only for containers. Local purchase invoices keep adding stock when posted.
   - (C) Not now.
2. **When does an order close by itself?**
   - **(A) When fully invoiced and every piece is received or recorded short on a goods receipt.** "Short" means a
     container line received with a reason, or a local line marked "Nothing more will come". **(Recommended)**
   - (B) When fully invoiced, as today. Goods can still be received on closed orders.
   - (C) Only when fully invoiced and fully received. Short pieces keep the order open until it is closed by hand.
3. **Cancelling a supplier invoice whose goods were already received:**
   - **(A) Allowed. The received goods go back to the order price, and the difference is booked automatically.**
     **(Recommended)**
   - (B) Refused while goods matched to it are received. Cancel the goods receipt first.
4. **The exchange-rate difference between the order and the invoice:**
   - **(A) Part of the cost adjustment: stock value and cost of sales. The system has no exchange gain or loss
     account.** **(Recommended)**
   - (B) Only the price difference, at the order's rate. The rate difference is ignored.
5. **"+ New › Without an order" goods receipts:**
   - **(A) Supplier required.** Refused when that supplier has the item to receive on an order or invoice. Matched to
     its later invoices. Stock that is not from a supplier goes through Inventory In. **(Recommended)**
   - (B) Any stock, supplier optional. Then the same goods could be received twice, through the order and by hand.
6. **Receiving a container that has no completed Delivery movement:**
   - **(A) Allowed with "Receive goods…" on any confirmed container.** This covers containers followed without
     movements, and those delivered before the switch. **(Recommended)**
   - (B) Only after a Delivery movement is completed.
7. **A shortcut for local purchases:**
   - **(A) Offer "Receive the goods now" when an invoice is posted, off by default, for users who may also post goods
     receipts.** **(Recommended)**
   - (B) No shortcut. The goods receipt is always a separate step, by the warehouse.
8. **The container status after its goods are received:**
   - **(A) Keep "Offloaded"**, the warehouse's and the user guide's word. **(Recommended)**
   - (B) Rename it "Received". All the screens, the charges import texts and the user guide change.

---

## Implementation plan

Prompt format as usual: A steps in the API project, B steps in the Web project, each verified before the next.
- **Test data:** "TEST-64" / "TEST-65", cancelled or deleted at the end, with a report of what is left.
- **SQL** is run with the usual
  `eval "$(grep '^export SQLCMDPASSWORD=' ~/.bashrc)" && sqlcmd -S localhost -U sa -C -I -d Inventory_Shipment …` in ONE
  command. Never print the password, and never run that grep alone.

| Step | Project | Deliverable |
|---|---|---|
| P0 | both | Preconditions, no GRN code. Then branch `grn` in both repositories |
| A1 | API | **Script 64** (3.1): applied twice, appended to Schema.sql, API restarted twice. No C#. Committed on `grn` only |
| A2 | API | **Script 65** (3.2): same routine; then `refresh-dbproject.sh` once. No C# |
| A3 | API | Model, repository, service and controller for goods receipts; the movement after-commit call; DTO changes; SqlErrors; PermissionCatalog; invoice post `receiveNow` and preview. curl |
| B1 | Web | Goods Receipts list, page, print, menu (count), routes, permissions, stock statement link, export, files |
| B2 | Web | Receive goods… (order, invoice, container, + New chooser); movement Complete / Cancel dialogs; invoice post texts, preview and checkbox; list filters and columns; every wording of 5.6; sales warning; conventions doc |
| C1 | API docs | `docs/business-context.md` (rules, glossary GRN, flows A and B, statuses, error block 63xxx), `docs/notes/costing-rules.md` (GRNCOST, NEGSTOCK, company stock share), deploy notes (the switch query); the Containers User Guide chapters to update (5, 7, 8) |
| D1 | server | Rehearsal on testing (7.3 step 3) |
| D2 | server | Production go-live (7.3 step 4) |

**P0 verification:**
- tasks #8, #9 (script 63) and #10 are merged;
- `git pull --no-rebase` in both repositories, and the next free script numbers are noted;
- `tools/check-repo.sh` exists (it is missing today: `refresh-dbproject.sh` calls it at line 105), or the call is
  removed;
- `DatabaseProject` is refreshed at script 63 and committed. It is about 18 scripts behind;
- Schema.sql applies to an **empty** database and to the existing one.

**A1 verification (sqlcmd, script 64 alone; nothing existing changes):**
- a. **Apply and seed:**
  - applied twice, with the second run clean, and `Database schema verified` twice;
  - the GRN document type and the five permissions exist;
  - Manager and the roles holding `purchase.invoices.post` have view, create and post;
  - removing a grant and restarting does not bring it back;
  - an **empty database** also applies cleanly.
- b. **A local order receipt:** CreateFromOrder on a TEST-64 order of 2 lines (100 and 50 pcs @ 10.00 USD) gives a draft
  with 2 lines and the right ToReceive. Save 60 + 50, then Post:
  - the number is `GRN-<branch>-000001`;
  - stock +60 / +50 at 10.00, with average and last cost updated;
  - GoodsReceivedBase is 60 / 50.
- c. **The cap and settling:**
  - a second draft of 50 on line 1 is refused at post (63011, 40 remain); 40 is posted;
  - a draft with CloseShort on a line of 10 receiving 6 gives SettledShortBase 4 and GoodsShortBase 4.
- d. **Cancel:**
  - cancel the receipt of c (stock still there): it is reversed and the counters come back;
  - sell 10 of line 2, then try to cancel the receipt of b: refused 63007.
- e. **Container draft:** CreateForContainer on a TEST-64 container (status 4, warehouse of its branch) gives a draft
  mirroring the loaded lines.
  - A second call gives 63013.
  - With `@Silent = 1` there is no error, `@SkipReason = 'HasDraft'`, and no second draft.
  - **CreateForMovement** on a completed Delivery gives one row per container: created or skipped.
- f. **Posting a container receipt:**
  - one line short with no reason gives 63000;
  - with a reason code:
    - the container is in status 6, location = the warehouse, charges frozen;
    - cost = order price + charges, and the GRN line has no own charges (read from `cl`);
    - GRN ledger rows, CNT not used;
    - SettledShortBase on the short line;
  - a receipt posted against its own container's order line is **not** refused by the order cap.
- g. **Cost true-up:** Rematch and TrueUp are called directly after inserting a posted TEST-64 invoice for the container
  (+10.00 a piece):
  - delta = 10.00 × received, FOB only;
  - the split uses company stock;
  - `GRNCOST` rows dated ≥ the receipt's movement date;
  - RebuildCosts gives the same average as a manual replay;
  - then a late charge: CNTCHARGE only, and no second count at the next true-up;
  - cancelling that receipt gives 63008.
- h. **Negative stock:** make an item's company stock −10 (an out-of-stock sale), then post a receipt of 30 at a cost 5.00
  above the average. A `NEGSTOCK` COGS row of 50.00 is written.
- i. **Files:** a file with a type not used for goods receipts gives 63012.

Stop and report.

**A2 verification (script 65):**
- a. **Apply:**
  - applied twice, clean, and the switch marker inserted once;
  - `GoodsReceivedBase` filled: spot-check 3 orders against their invoices' PINV ledger rows and their offloads;
  - a restart leaves the counters alone;
  - the Check section shows no drift.
- b. **Local flow:** PO 100 @ 10, receive 60 (posted), sell 20, then post an invoice of 100 @ 11.
  - **No stock movement** comes from the invoice.
  - True-up 60 × 1.00 = 60.00: stock 40.00, COGS 20.00.
  - The invoice line's received = 60, and the order stays open.
  - Receive 40: the cost is 11.00 with no adjustment, and the order closes "Fully invoiced and received".
- c. **Cancel that invoice:** refused only for the existing reasons. Otherwise:
  - the received pieces go back to 10.00 (`PINVCANCEL`) and the order reopens;
  - post it again and the cost is back to 11.00.
- d. **PRET from the invoice:**
  - max = received − returned, cost = 11.00, warehouse = the receipt's;
  - then cancel a receipt whose goods were returned: refused 63010.
- e. **Import flow:** container KTG-TEST-65 (84 pcs @ 950 on the order, 2 charges posted) goes SEA, INLAND, CUSTOMS, then
  **DELIVERY completed**.
  - CreateForMovement gives one auto draft (IsAuto, MovementId, warehouse = the container's).
  - Post 82 with a reason: status 6, settled 2.
  - Post the invoice of 84 @ 960: the adjustment is 82 × 10.00 = 820.00.
  - The order closes, and Shortages and the item's "On order" show 0.
  - A late charge posted: CNTCHARGE as today.
  - Cancel the receipt: 63008.
- f. **Unlinked invoice:** a mode-2 invoice **not linked** is posted for the container's order line, and the container is
  received. Pass 2 matches it, the cost is the invoice's, and the container can be closed.
- g. **No warehouse and Delivery cancel:**
  - a container with no warehouse gets an auto draft without warehouse; posting gives 63000;
  - the completed Delivery cancelled before posting: the auto draft is deleted, with a container audit line.
- h. **Old offload procedures:**
  - `usp_Container_Offload` gives 69010;
  - Cancel Offload on an **old** offloaded test container still works and lowers `GoodsReceivedBase` without a restart;
  - on a GRN-received container it gives 69010.
- i. **Invoicing a received container:** an invoice on a GRN-received container is allowed (65019 not raised). Container
  Close with unmatched received pieces gives 69016; after the invoice, it closes.
- j. **Double receipts:** receive 60 from the order, then Auto-plan proposes 40, and Save of a 100-piece container gives
  69008. Load 100, then "Receive goods…" on the order proposes 0 ("travels in containers").
- k. **Container edits:**
  - a container with a draft receipt: a header-only save (truck no.) passes; a line change gives 69019;
  - Link / Unlink of an invoice line referred to by a GRN line gives 65028.
- l. **Old invoices:**
  - an old posted mode-1 invoice cancel still reverses its stock, replays costs, and lowers `GoodsReceivedBase`;
  - a return on an invoice posted before script 24 still works.
- m. **Shortages:** Shortages and the item's purchase orders give the same outstanding number. RebuildCosts of the test
  items = the running average.
- n. **Manual receipt:** "Without an order" for a supplier with the item on an open order gives 63011. For another
  supplier, it posts with no LastCost change. That supplier's later invoice without an order matches it, and LastCost
  follows.

Stop and report.

**A3 verification (curl, admin login):**
- every endpoint of section 4, with each refusal mapped: 63000 → 400 with the SQL message, 63006 → 404, 63008 → 409;
- `post-many` with one refused;
- the Complete of a Delivery movement returns `goodsReceipts` with created and skipped rows;
- forcing an error in the hook leaves the movement completed, with a warning;
- the container DTO has `canReceive`, `goodsReceiptNumber` and `deliveredDate`; the PO DTO has `toReceiveBase` and
  `outstandingBase`; the list has `invoicedPercent`;
- invoice post with `receiveNow` gives the invoice posted and the receipt posted. With a receipt that fails, the invoice
  is posted and a warning returned;
- `receipt-cost-preview` matches the A2 b figures;
- the export opens in Excel;
- build with 0 warnings.

Report the files changed.

**B1 / B2 verification:** a full check through the UI, with a screenshot of each step, at 1440 and 390 px:
- the list, its filters, its totals line and the menu count;
- + New › From a purchase order… → post; + New › Without an order → post; the print page (draft and posted);
- Receive goods… on a TEST order (partial) → post → the order shows Received 60 % / Invoiced 0 %;
- an order in containers → the dialog opens at 0 with the Alert;
- post the invoice → the confirm shows the preview → its "Cost of received goods" card and the receipt's "Cost
  adjustments" card;
- the local invoice post with "Receive the goods now";
- container:
  - the Complete dialog lists what will happen;
  - complete a Delivery → the notification "Draft goods receipts created: … Not created: …" with links;
  - open → set reasons → post → the container banner;
- the container header edited while a draft exists;
- the Delivery cancel dialog naming an edited draft;
- Cancel goods receipt disabled with its reason;
- the stock statement shows "GRN-… · KTG-…";
- old invoices show their old texts and the disabled Receive goods… with its reason;
- every wording of 5.6 is changed.

Report every step that did not behave as described.

**C1 verification:** the business doc and the costing notes describe GRN, the new statuses and errors, flows A and B
step by step, and the switch date. The deploy notes hold the read-only switch query, with no password.

**D1 / D2 verification:**
- the rehearsal's switch lists are reviewed with Bilal before production;
- after the production deploy: the API log says "Database schema verified", the switch marker date is shown on an old
  invoice, and one real local purchase and one real container are received end to end.
