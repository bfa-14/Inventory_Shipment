# Item costing — rules implemented in SQL (script 23) and what the UI will expose later

## Rules (all costs per BASE unit, base currency USD)

| Step | Rule | Where |
|---|---|---|
| FOB cost | line total after discount ÷ base qty ÷ rate | `purchase.PurchaseDocumentLines.FobCostBase` (set at posting) |
| Purchase charges | configurable charge types (US-MD-008), entered on a draft invoice in any currency, converted at the document-date rate | `purchase.ChargeTypes`, `purchase.PurchaseCharges`, `usp_PurchaseDocument_SetCharges` |
| Allocation | Value / Quantity / Weight (item `WeightKg`) / Volume (item `VolumeCbm`) / Manual; remainder of rounding on the largest line | `usp_PurchaseCharges_Allocate`, `purchase.PurchaseChargeAllocations` |
| Landed cost | FOB + allocated charges ÷ base qty → ledger cost | `PurchaseDocumentLines.UnitCostBase` (= landed), `AllocatedChargesBase` |
| Item costs | `FobCost` = latest FOB, `LastCost` = latest **landed** (purchases only), `AverageCost` = moving weighted average (updated only by postings that add stock), `InventoryValue = OnHand × AverageCost` | `inventory.Items`, `usp_Item_ApplyReceipts`, views `vw_InventoryValuation(ByWarehouse)` |
| Inventory In / Sales return | update the average, never Last / FOB cost | `usp_StockDocument_Post`, `usp_SalesDocument_Post` |
| Sales invoice | per line frozen at posting: `UnitCostBase` (COGS = average), `FobCostAtSale`, `LastCostAtSale`, `NetSalesBase`, `CogsBase`, `GrossProfitBase`, `GrossProfitPct` (on net sales); header `TotalCostBase`, `TotalGrossProfitBase` | `sales.SalesDocumentLines` |
| Sales return | created from a posted invoice with the invoice prices and the ORIGINAL COGS; consumes `ReturnedQuantityBase` of the invoice lines | `sales.usp_SalesDocument_CreateFromSource` |
| Purchase return | removes stock at the invoice landed cost | `usp_PurchaseDocument_Post` (PRET) |
| Landed cost adjustment | charges arriving after receipt (`LCA-KLW-000001`): allocated over the invoice lines; still-in-stock quantity → inventory value (average recalculated), already-sold quantity → COGS adjustment; invoice landed cost and item last cost updated | `purchase.LandedCostAdjustments(+Lines)`, `inventory.CostAdjustments`, `usp_LandedCostAdjustment_*` |
| Cancellations | a cancelled receipt / return / LCA replays the ledger for its items | `inventory.usp_Item_RebuildCosts` |
| Profit report | Net Sales − COGS, GP % on net sales, grouped by invoice / item / family / brand / client / salesman / branch / month; LCA COGS adjustments as a separate column | `sales.usp_SalesProfit_Report` |

Approximation (documented decision): the "still in stock" quantity of an invoice line for an LCA = min(received − returned,
current on-hand of the item in that warehouse) — no FIFO layers are kept.

## Future UI (prompts to write later)
- Purchase Charge Types page (US-MD-008) — procs ready: `usp_ChargeType_Search/Lookup/Save/SetActive/Delete`, permission `purchase.chargetypes.manage`.
- Purchase invoice "Charges" tab (draft): charge lines (type, provider, reference, currency, amount, method, manual allocation grid) → `SetCharges`; posted invoice shows FOB / charges / landed per line (Get result set 6).
- Landed Cost Adjustments list + document (`purchase.landedcosts.*`), "New adjustment" from a posted invoice.
- Item Definition: FOB cost, Last cost, Average cost, Inventory value; Weight (kg) / Volume (CBM) per base unit.
- Sales invoice view: cost / profit columns for users with `sales.profit.view`; Sales Profit report page.
