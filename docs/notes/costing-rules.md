# Item costing — rules implemented in SQL (scripts 23, 27, 64-65, 79, 89, 90) and what the UI will expose later

## Rules (all costs per BASE unit, base currency USD)

| Step | Rule | Where |
|---|---|---|
| FOB cost | line total after discount ÷ base qty ÷ rate | `purchase.PurchaseDocumentLines.FobCostBase` (set at posting) |
| Purchase charges | configurable charge types (US-MD-008), entered on a draft invoice in any currency, converted at the document-date rate | `purchase.ChargeTypes`, `purchase.PurchaseCharges`, `usp_PurchaseDocument_SetCharges` |
| Allocation | Value / Quantity / Weight (item `WeightKg`) / Volume (item `VolumeCbm`) / Manual; remainder of rounding on the largest line | `usp_PurchaseCharges_Allocate`, `purchase.PurchaseChargeAllocations` |
| Landed cost | FOB + allocated charges ÷ base qty = the **invoice cost** of a line. Since goods receipts it is no longer a ledger cost by itself: received goods are valued at it, or corrected to it (see below) | `PurchaseDocumentLines.UnitCostBase` (= landed), `AllocatedChargesBase` |
| Goods in | **only a posted goods receipt (GRN) puts goods in stock** (script 65). A supplier invoice posted since the switch moves no stock and no item cost: it makes the amount payable and sets the invoice cost | `purchase.usp_GoodsReceipt_Post`, ledger rows family `Purchase`, type `GRN` |
| Item costs | `FobCost` / `LastCost` / last supplier = the latest posted goods receipt line, after its cost adjustments (a receipt "Without an order" counts only once matched to an invoice; older goods: the old local invoices and the containers offloaded before goods receipts), `AverageCost` = moving weighted average (updated only by postings that add stock, and by cost adjustments), `InventoryValue = OnHand × AverageCost`; and replayed when a stock document or a sales document is cancelled (script 89) | `inventory.Items`, `usp_Item_ApplyReceipts`, `usp_Item_RebuildCosts`, views `vw_InventoryValuation(ByWarehouse)` |
| Inventory In / Sales return | update the average, never Last / FOB cost; cancelling one replays its items' costs (script 89), as every cancelled stock or sales document does | `usp_StockDocument_Post`, `usp_SalesDocument_Post` |
| Transfer (TRD / TRR) | **cost-neutral** (script 90): a dispatch moves pieces from the source to an On the way warehouse, a transfer receipt from there to the destination; the company's stock and every item cost (average, last, FOB) stay as they were. The rows carry the average at the dispatch, for information only. Pieces that will not arrive are written off at the average (`TRF_LOSS`), the only leg that changes the company's stock. A tracked line (script 93) writes its legs split per expiry date, each row at the same frozen cost. See "Transfers" below | `inventory.usp_TransferOrder_DispatchCore` / `_ReceiveCore`, ledger rows family `Transfer` |
| Sales invoice | per line frozen at posting: `UnitCostBase` (COGS = average), `FobCostAtSale`, `LastCostAtSale`, `NetSalesBase`, `CogsBase`, `GrossProfitBase`, `GrossProfitPct` (on net sales); header `TotalCostBase`, `TotalGrossProfitBase` | `sales.SalesDocumentLines` |
| Sales return | created from a posted invoice with the invoice prices and the ORIGINAL COGS; consumes `ReturnedQuantityBase` of the invoice lines | `sales.usp_SalesDocument_CreateFromSource` |
| Purchase return | removes stock at the invoice line's **current** cost (local: its landed cost; container: its FOB + the container line's charges ÷ received), recomputed at posting. From an invoice that uses goods receipts (or an older "Shipped in containers" one): at most received − returned, from the warehouse the goods were received into. Older local invoices: invoiced − returned | `usp_PurchaseDocument_Post` (PRET) |
| Landed cost adjustment | charges arriving after receipt (`LCA-KLW-000001`): allocated over the invoice lines. Old invoices (posted before the switch): still-in-stock quantity (per item, on the company's stock since script 89) → inventory value (average recalculated), already-sold quantity → COGS adjustment; invoice landed cost updated and the item's costs replayed. Invoices that use goods receipts: the invoice cost rises, and the goods already received follow through a true-up (`LCA` / `LCACANCEL`, below); pieces not received yet enter at that cost when they arrive. Refused on imported and "Shipped in containers" invoices (67012) | `purchase.LandedCostAdjustments(+Lines)`, `inventory.CostAdjustments`, `usp_LandedCostAdjustment_*` |
| Late container charge | a charge posted or cancelled after the container is received: per item, still-in-stock quantity = min(received, the company's stock of the item, every warehouse) → inventory value, the rest → COGS (script 89; it was the receiving warehouse's stock). A cancel takes its share from today's stock, never more out of stock than its posting put in. The rows keep the receiving warehouse and branch. Unchanged by goods receipts | `logistics.usp_ContainerCharge_ApplyCost`, SourceKind `CNTCHARGE` |
| Cancellations | a cancelled goods receipt, stock document, sales document, return, LCA or late charge replays the ledger for its items; so does a reversed transfer receipt that wrote pieces off (script 90) | `inventory.usp_Item_RebuildCosts` |
| Profit report | Net Sales − COGS, GP % on net sales, grouped by invoice / item / family / brand / client / salesman / branch / month; COGS adjustments (LCA, late charges, goods receipt cost changes) as a separate column, shown by item, family, brand, branch, month or all, not per invoice, client or salesman | `sales.usp_SalesProfit_Report` |

Approximation (documented decision): no FIFO layers are kept, so the pieces of a purchase still in stock are estimated
per item as min(pieces received − returned, the company's stock of the item in every warehouse). The goods receipt
true-up, the late container charge and the LCA of an old invoice all use it (the last two since script 89; before, the
line's or the container's receiving warehouse decided). Pieces of the same item bought elsewhere count as these pieces;
so a late charge CANCELLED after the container's pieces are sold takes its share from other purchases' stock of the
item, which can push their average down when little of it is left (before 89 only when those pieces sat in the
receiving warehouse).

## Goods receipts (scripts 64-65): the cost of received goods follows the invoices

### Cost at receipt

Posting a goods receipt matches its pieces to the pieces of posted supplier invoices, then values each line.

- **Matching** (`usp_GoodsReceipt_Rematch`), first in first out by posting time, in passes:
  1. the invoice the receipt was made from;
  2. the same container line;
  3. the same order line (any container or none);
  4. goods without an order: the same supplier and item.
- **Matched pieces** take the **invoice cost**: the invoice line's FOB per piece, plus, outside containers, the
  invoice's own charges per piece.
- **Unmatched pieces** take the **order price**: order line total ÷ the order's exchange rate ÷ order line pieces
  (`PoFobBase`, frozen at posting).
- **Container lines** keep their charges on the container line: the posted container charges are re-spread over what
  arrived and frozen, as the offload did. Landed = FOB + `ChargesBase` ÷ received. They are never copied to the
  receipt line, so a late charge counts once.
- **"Without an order" lines** take the typed cost (default: the item's last cost) until an invoice of the same
  supplier and item, without an order, is matched to them.
- The receipt line shows where its cost comes from: Order price, Invoice, Order + invoice (part matched), Typed.

### The true-up (`usp_GoodsReceipt_TrueUpCost`)

Anything that changes the matches of received pieces, or the cost of their invoices, brings every posted receipt line
of the touched order lines (or supplier + item) to its new target cost. Each event is a **cause**:

| Cause | When |
|---|---|
| `PINV` | a supplier invoice is posted: its pieces are matched to goods already received |
| `PINVCANCEL` | a supplier invoice is cancelled: its received pieces go back to the order price (or to another invoice of the same order line). Goods without an order keep the cost they were received at |
| `LCA` / `LCACANCEL` | a landed cost adjustment is posted / cancelled on an invoice that uses goods receipts |
| `GRNPOST` | a goods receipt is posted and takes invoice pieces another receipt held (for example a receipt made from that invoice): the other receipt is trued up. This runs before the new receipt's stock goes in |
| `GRNCANCEL` | a goods receipt is cancelled: the later receipts of the same order line may take over its invoice pieces |
| `NEGSTOCK` | at posting only, see "Goods sold before their receipt" |

- **Amount** per line: (new cost per piece − current cost per piece) × pieces received, rounded to the cent. On a
  container line only the **FOB** moves; its charges move only with container charges (`CNTCHARGE`).
- **Split between stock and cost of sales, per item for the whole event:**
  - net received = received − returned (pro rata over the line's matches);
  - in stock = min(Σ net received, the **company's** stock on hand of the item, all warehouses, never below 0);
  - to stock = amount × in stock ÷ Σ net received (leftover cents on the largest line). It changes the average cost;
  - to cost of sales (COGS) = amount − to stock. The company holds none of the item: everything goes to COGS.
  - Company stock, as the late container charge and the old LCA since script 89: the average is company-wide, and
    transfers move goods out of the receiving warehouse.
  - For `LCA` / `LCACANCEL` only, the share of the re-priced pieces already **returned** to the supplier goes to COGS:
    they are no longer in stock.
- **Exchange rate:** the order and the invoice each convert at their own rate. The difference is part of the cost
  adjustment (owner's decision 4): there is no exchange gain or loss account.
- **Records:**
  - one `purchase.GoodsReceiptCostChanges` row per receipt line per event (cause, invoice / LCA / receipt number, pieces,
    in-stock share, FOB and unit cost before → after, amount, to stock, to COGS);
  - `inventory.CostAdjustments` rows, Kind `Inventory` and `COGS`, **SourceKind `GRNCOST`**, SourceId = the cost change,
    SourceNumber = the GRN number. Compensating (negative) rows are written as they come;
  - dated at the **later of now and the receipt's own ledger date**, so a replay never puts an adjustment before its
    receipt;
  - then `usp_Item_RebuildCosts` per item, as the late container charge does.
- **What each record keeps:** the stock movement keeps the cost at receipt; the receipt line keeps its current cost
  (FOB, charges, landed), which feeds the last cost and the returns; the replay adds the adjustments.

### Goods sold before their receipt (`NEGSTOCK`)

With out-of-stock selling on, goods can be sold between the Delivery and the warehouse's posting. Those pieces went
out at the old average and the company stock went negative. When a receipt fills that negative stock, the moving
average starts again at the receipt's cost, so (receipt cost − average before) × the pieces filled would be in neither
the stock nor the cost of sales. Posting books it to **COGS** (cause `NEGSTOCK`, SourceKind `GRNCOST`), shared over the
receipt's lines of the item by their pieces. Cancelling the receipt reverses it. Inventory In is unchanged.

### Worked examples

- **Local purchase** (order 100 pcs at 10.00): receive 60 (stock +60 at 10.00), sell 20, then post the invoice at
  11.00. The invoice moves no stock. True-up `PINV`: 60 × 1.00 = 60.00; company stock 40 → stock 40.00, COGS 20.00.
  Receiving the last 40 then takes 11.00 at once, with no adjustment.
- **Container, late charge, then invoice** (the user-guide container): 84 pcs at the order price 950, charges 2,940
  posted → received at 985. A late charge of 840 → `CNTCHARGE` 840, landed 995. Then the invoice at 960: `PINV`
  (960 − 950) × 84 = 840 on the FOB only → landed 1,005. The late charge is counted once.
- **Short shipment:** 84 loaded and invoiced, 82 received with a reason: the 82 match the first 82 invoiced pieces and
  take the invoice cost; the 2 are settled short. Their FOB is not in the stock cost (a claim on the supplier).
- **Negative stock:** company stock −10, a receipt of 30 at a cost 5.00 above the average → `NEGSTOCK` COGS 50.00.

### An invoice that does not change item costs (script 79)

The PINV document type's **Affects item cost** (Configuration › Document Types, default on) is captured on each invoice
when it is posted (`purchase.PurchaseDocuments.AffectsCost`; every invoice posted before script 79 has 1). An invoice
posted with 0:

- **Is still matched** (`usp_GoodsReceipt_Rematch` unchanged): its invoiced / received counters, the return caps
  (65011), container Close (69016) and the payment splits need it. Only `CostSource` counts the matches to invoices
  that change costs.
- **Prices nothing** (`fn_GoodsReceiptLine_TargetCost`, the one place): its matched pieces cost as if unmatched - the
  order price; a container line keeps its container's charges (they never came from an invoice). `MatchedBase` still
  counts every match, `CostMatchedBase` the pricing ones. Every true-up, the cost at receipt and the item's last / FOB
  cost read the target, so the rule flows through; the true-up calls stay (posting it as the newest invoice changes
  nothing; cancelling it may hand its pieces to a cost-affecting invoice of the same order line, `PINVCANCEL`).
- **A line of a goods receipt made from such an invoice WITHOUT an order** has no order price: it takes a manual cost
  at posting - typed, else the item's last cost, else its average (an item with no cost at all: the invoice's price,
  once, so goods never enter at nothing). Like a "Without an order" line, it changes the item's last cost, FOB cost and
  last supplier only once matched to an invoice that changes costs.
- **Returns** (`usp_PurchaseDocument_Save` / `_Post`, PRET from it): the goods go out at the BASE cost of the receipt
  lines matched to the invoice line (`fn_GoodsReceiptLine_TargetCost`: the order price, or a manual line's cost; a
  container line adds its container's charges per piece), weighted by the matched pieces - what these pieces entered
  stock at. Not the lines' current cost: one receipt line can hold pieces of a cost-affecting invoice too, and its
  current cost blends that price in; returning at the blend would leave the difference in stock for good (the later
  true-ups work per line, on its net received pieces). The supplier credit (the return's price) stays the invoice
  price. No match: the item's average.
- **Item replays** (`usp_GoodsReceipt_TrueUpCost`): the items of the lines of an order-less non-cost invoice are
  replayed on every true-up, as manual lines are, so a match to a cost-affecting invoice gained or lost at the same
  price still moves the last cost, FOB cost and last supplier.
- **Landed cost adjustments** are refused, in Save and Post: 67013 "This invoice does not change item costs (its
  document type was set so when it was posted): a landed cost adjustment on it would change no cost. Container charges
  still enter the cost of goods received in containers." (The late charges of the invoice page are not offered.)
- **The post confirmation's estimate** (`usp_PurchaseInvoice_ReceiptCostPreview`, a draft follows the type as it is
  now): no difference, and the sentence "{n} pcs already received keep their cost: this invoice does not change item
  costs (Configuration › Document Types)."

Example: order 10 pcs at 100, received (average 100). Invoice at 120 posted with the switch off: average and last cost
stay 100, the receipt line shows CostSource Order, a return of 3 goes out at 100 (credit 3 × 120). With the switch on,
another order's 10 pcs at 100 invoiced at 120: + 200.00 to stock, average 120. Both on one order line (20 pcs at 100;
10 invoiced at 120 with the switch off, then 10 at 130 with it on): 10 at 100 + 10 at 130 = average 115, CostSource
Mixed. On that mixed line, a return of the 10 from the switch-off invoice goes out at 100 (the order price), not at the
blend: cancelling the switch-on invoice afterwards leaves 10 pcs worth 1,000.

### Cancelling a receipt

Refused once its cost was adjusted afterwards (63008): any `GRNCOST` change on its lines except the `NEGSTOCK` of its
own posting, and for a container any `CNTCHARGE` on its charges (as 69018 refused the old Cancel Offload). Also refused
when the stock it brought was used (63007) or a purchase return took its goods back (63010). Otherwise: reversal stock
rows, matches rebuilt, the other receipts trued up (`GRNCANCEL`), item costs replayed.

## Transfers (script 90): cost-neutral

The average cost is company-wide and every warehouse is valued at it, so moving goods between two of the company's
warehouses changes no cost (the owner's decision 3 of the transfer feedback).

- **Where the goods are.** A dispatch (TRD) writes, per line, the source −q and the On the way warehouse of the
  destination branch +q (reason `TRF_OUT`); a transfer receipt (TRR) writes the On the way warehouse −q and the
  destination +q (`TRF_IN`). Each posting nets to zero for the company, but a receipt's write-off (Losses, below).
  Family `Transfer`, never `Sales` (Shortages read that family as sales).
- **Split rows per expiry date (script 93) carry the same frozen cost.** A line of a tracked item (batch, serial or
  expiry rows) writes one ledger row per leg and per expiry date of its rows (`StockMovements.ExpiryDate`; the NULL
  date one group) instead of one per leg: the source −40 (31/03/2027), −20 (30/06/2027), the On the way warehouse +40,
  +20, and the receipt and its losses the same way. Every row of the posting line keeps the line's one `UnitCostBase`
  (a receipt line its dispatch line's; a loss row the average at the receipt), so the rows of a line add up to 90's
  pieces and value exactly, on hand and the valuation sum them by item and warehouse as before, and the replay below
  reads each incoming row with no cost like 90's one row: no cost moves (test p of script 93: average, last and FOB cost
  identical before the dispatch, after the receipts and losses, and after `usp_Item_RebuildCosts`). Untracked lines
  write 90's rows unchanged. No batch or serial reaches the ledger: the stock stays per item and warehouse.
- **The frozen average, for information.** Each dispatch line and its two rows carry `Items.AverageCost` at the
  dispatch (`inventory.TransferPostingLines.UnitCostBase`; the posting's `ValueBase` = Σ pieces × it); a receipt line
  and its two rows carry its dispatch line's (its write-off row the average at the receipt, below). Nothing reads them
  as a cost: no transfer calls `usp_Item_ApplyReceipts`, and
  the average, last and FOB cost never move. The values show only with `inventory.valuation.view`.
- **The replay** (`inventory.usp_Item_RebuildCosts`, re-created from script 79's body). An incoming leg of a transfer
  (family `Transfer`, quantity above 0: the On the way warehouse at a dispatch, the destination at a receipt) enters
  with no cost, so the receipt formula `ISNULL(cost, running average)` keeps the average where it is, whatever the
  running balance - also when the outgoing leg took it to zero (the feedback's "restart at the frozen cost" is not
  needed). The outgoing legs and the losses are issues, as every out. A reversed posting is left out with its reversal,
  as every family's. Every other family reads its row's cost as before: a database without transfers replays to the
  same costs. Why not the frozen cost: it goes stale as soon as anything is received, back-dated or cancelled between
  the dispatch and the receipt, and entering at it would move the average.
- **Losses** ("Nothing more will arrive" on a receipt line). The pieces leave the On the way warehouse at
  `Items.AverageCost` at the receipt (`LossUnitCostBase`; the posting's `LostValueBase`), reason `TRF_LOSS` - the only
  leg of a transfer that changes the company's stock. As every issue it leaves the average where it is: the stock
  value goes down by pieces × average, as with an Inventory Out; nothing goes to COGS or to a cost adjustment.
- **Reversing.** A reversed dispatch, or a reversed receipt without a loss, leaves the company's stock as it was: no
  replay. A receipt that wrote pieces off brings them back On the way, so the company's stock changes: its items are
  replayed, as every cancel that writes reversal rows (script 89), under the goods receipt matching lock taken first,
  giving way in a deadlock (`DEADLOCK_PRIORITY LOW`; the API runs it again). A goods receipt posted while the loss stood
  was averaged over fewer pieces; the replay averages it over the pieces the company holds again.
- **Script 19's per-start backfill** of item costs (an item with receipts and no stored average) skips transfer rows
  (`DocumentFamily <> N'Transfer'`, edited in place by script 90, as 89 edited it for reversed postings): counted as
  receipts, they gave an item replayed to a zero average a transfer's frozen cost back as its average and last cost at
  the next API start.
- **What transfers leave alone.** The goods receipt true-up, the late container charge and the LCA of an old invoice
  already split on the company's stock (script 89), so goods moved out of the receiving warehouse still count as in
  stock. The cost adjustment rows keep the receiving warehouse and branch: Sales Profit's COGS adjustments stay in the
  branch that received the goods (no per-piece tracking follows them). Stock Valuation's company total does not move
  but by a write-off; by warehouse, the On the way warehouses hold the goods on the road at the average, in the
  destination branch.

Example: 84 pcs of an item in LKS-01 at an average of 985.00. Dispatch 40 to LUB-01: LKS-01 −40 and OTW-BR-002 +40,
both at 985.00; the company still holds 84 at 985.00 (82,740.00). A goods receipt of 10 at 1,000.00 then brings the
average to (84 × 985 + 10 × 1,000) ÷ 94 = 986.60. The transfer receipt of 39 with 1 written off: OTW-BR-002 −39 and
LUB-01 +39 (rows at the frozen 985.00, which the replay reads at the running 986.60), OTW-BR-002 −1 `TRF_LOSS` at
986.60; the company holds 93 at 986.60, and the average has not moved.

## Future UI (prompts to write later)
- Purchase Charge Types page (US-MD-008) — procs ready: `usp_ChargeType_Search/Lookup/Save/SetActive/Delete`, permission `purchase.chargetypes.manage`.
- Purchase invoice "Charges" tab (draft): charge lines (type, provider, reference, currency, amount, method, manual allocation grid) → `SetCharges`; posted invoice shows FOB / charges / landed per line (Get result set 6).
- Landed Cost Adjustments list + document (`purchase.landedcosts.*`), "New adjustment" from a posted invoice.
- Item Definition: FOB cost, Last cost, Average cost, Inventory value; Weight (kg) / Volume (CBM) per base unit.
- Sales invoice view: cost / profit columns for users with `sales.profit.view`; Sales Profit report page.
