# Batch 1 — Inventory In / Out fixes, item links, hide the sales import page

Points covered: **1** (Inventory In unit cost editable and saved), **2** (Inventory Out cost read-only),
**3** (link from document lines to Item Definition), **6** (hide "Import Sales from Excel"), **12** (the cost
entered on Inventory In is not saved). No SQL needed — `inventory.usp_StockDocument_Save` already stores the cost of
Inventory In lines (`UnitCost` per unit, base currency) and applies the average cost to Inventory Out lines.

Run: Prompt A with the API folder open (5 minutes), then Prompt B with the Web folder open.

## Prompt A — Backend check (API)

```text
You are working on /home/bilal/VSProjects/InventoryShipment-Project/Inventory_Shipment (.NET 10 solution). Do not touch the Web project.

Bug: the unit cost typed on an Inventory In line is not saved (after Save Draft / reload the line shows 0 or the
old value). Find where it is lost on the API side and fix it:
1. SaveStockDocumentLineRequest must carry UnitCost (decimal?, [Range(0, ..)]) and the repository must copy it into
   the inventory.tvp_StockDocumentLine DataTable column "UnitCost" (DECIMAL(18,4)) in the exact column order of the
   type (LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, UnitCost, Notes). A NULL is allowed only
   for INV_OUT (the procedure applies the average cost); for INV_IN a missing value must be sent as 0, not dropped.
2. StockDocumentLineDto.UnitCost / LineTotal must be mapped from the Get result (UnitCost, LineTotal columns).
3. The export (xlsx) shows the saved cost.
VERIFY with curl (token admin / Admin@12345): POST an INV_IN draft with one line TVS-AP160 PC qty 2 unitCost 2150
-> GET {id} returns unitCost 2150 and lineTotal 4300, totalCost 4300; PUT the same draft with unitCost 2200 ->
GET shows 2200; POST an INV_OUT draft with unitCost 999 -> the line shows the item's average cost, not 999.
Report the root cause and the files changed.
```

## Prompt B — Frontend

```text
You are working on /home/bilal/VSProjects/InventoryShipment-Project/Inventory_Shipment.Web (Mantine 9 stack, docs/frontend-conventions.md, shared ui
components, document-page skeleton: DocumentHeaderCard, QuickItemSearch, DocumentLinesGrid, DocumentSummary,
DocumentActionBar, AttachmentsDrawer, AuditTrail). Frontend only. Dev: npm run dev, admin / Admin@12345.

TASK
1. Inventory In - Unit Cost column: an editable NumberInput (2 decimals, min 0, USD) for INV_IN in create/edit
   mode; its value must be part of the line state, recalculated into Amount and totals on every change, SENT to the
   API as unitCost on Save Draft / Save & Post, and shown back after reload (read the value from the API line, do not
   recompute it client-side). When a line is added by Quick Item Search or "+ Add Item", default the cost to the
   item's last cost (item details: lastCost) else 0, and focus the Qty field. Import from File in stock mode fills
   the cost from the file's Unit Price column.
2. Inventory Out - Unit Cost column read-only (text, tooltip "Average cost is applied automatically") in every
   mode; the value shown is the API's (average cost); never send unitCost for INV_OUT.
3. Item links (shared, so every document family gets them): in DocumentLinesGrid the Item Code cell becomes a link
   (Anchor + IconExternalLink on hover) that opens /inventory/items/:id in a NEW tab, and the row actions menu gets
   "View item details" (same target). Also in the Item Definition list, no change. Keep keyboard flow unaffected
   (the link must not steal focus from the inline inputs).
4. Hide the "Import Sales from Excel" page: navigation entry visible: false (keep the route, the page and the
   wizard code - the sales invoice page will use the wizard); Spotlight/menu search must not list it either.
5. Bug: opening an existing Inventory In draft shows the saved cost (regression check after 1).
6. Quality: typecheck / lint / build clean; responsive; no console errors.

VERIFY (API running) with screenshots at 1440 and 390:
  a. New Inventory In: add TVS-AP160, type cost 2150, qty 2 -> Amount 4300; Save Draft -> reload the page -> cost
     2150 still there; Save & Post -> Items page Last Cost / Average Cost updated.
  b. New Inventory Out: cost column read-only showing the average cost; posting works.
  c. Item Code link opens Item Definition in a new tab; "View item details" action does the same.
  d. The Sales menu no longer shows "Import Sales from Excel" (route still opens when typed).
Report: root cause of the lost cost (if it was on the frontend), files changed, every verification result.
```
