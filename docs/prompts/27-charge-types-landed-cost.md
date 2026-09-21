# Batch 6 — Purchase Charge Types (US-MD-008), invoice charges tab, landed cost adjustments, item costs, sales profit

SQL: `23_Inventory_Costing.sql` (run after 19–22). Requires batch 4 (purchase pages) applied. Prompt A (API), then Prompt B (Web).

What the user gets: **Purchase → Charge Types** page (popup add/edit, filters, activate/deactivate, delete only when
unused); **Charges tab** on a draft purchase invoice (any currency, allocation per charge type, manual allocation
grid) and FOB / charges / landed columns once posted; **Landed Cost Adjustments** (charges arriving after receipt);
**Item Definition** cost box (FOB, Last, Average, Inventory value) + Weight / Volume fields; **Sales Profit** report
and cost / profit columns on posted sales invoices for users with the profit permission.

## Prompt A — Backend

```text
You are working on /home/bilal/VSProjects/InventoryShipment-Project/Inventory_Shipment (.NET 10 solution). Do not touch the Web project.
Established pattern as in the purchase documents (repository over procedures + TVP, service, controller, export).

Script already written: /home/bilal/VSProjects/InventoryShipment-Project/Inventory_Shipment/Database/23_Inventory_Costing.sql
- read its header and docs/notes/costing-rules.md. Summary of what the API must expose:
- purchase.ChargeTypes: usp_ChargeType_Search(@Search, @AllocationMethod Value|Quantity|Weight|Volume|Manual,
  @IncludeInLandedCost, @IsActive, sort ChargeCode|ChargeName|AllocationMethod|IsActive|CreatedAtUtc, page) (+ UsageCount),
  usp_ChargeType_Lookup(@ActiveOnly, @IncludeId), usp_ChargeType_Save(@Id NULL = create, @ChargeCode, @ChargeName,
  @AllocationMethod, @IncludeInLandedCost, @IsRecoverableTax, @Description, @IsActive, @RowVersion, @UserId, @NewId OUT),
  usp_ChargeType_SetActive, usp_ChargeType_Delete. Errors 68xxx: 68000 VALIDATION, 68001 DUPLICATE_CODE, 68002
  DUPLICATE_NAME (409), 68004 CONCURRENCY, 68005 IN_USE (409), 68006 NOT_FOUND.
- Purchase invoice charges: purchase.tvp_PurchaseCharge (LineNumber, ChargeTypeId, Description, ProviderPartyId,
  Reference, CurrencyId NULL = document currency, RateType NULL, ExchangeRate NULL, Amount, AllocationMethod NULL =
  type default, IncludedInSupplierInvoice, Notes) and purchase.tvp_ManualAllocation (ChargeLineNumber, PurchaseLineId,
  AmountBase); usp_PurchaseDocument_SetCharges(@DocumentId, @Charges, @ManualAllocations, @RowVersion, @UserId) - draft
  PINV only; charges are allocated at posting (usp_PurchaseCharges_Allocate). usp_PurchaseDocument_Get now returns
  6 result sets - the 6th = charges of the invoice and of its adjustments (Id, DocumentKind PINV|LCA, DocumentId,
  SourceNumber, LineNumber, ChargeTypeId, ChargeCode, ChargeName, Description, ProviderPartyId, ProviderName,
  Reference, CurrencyId, CurrencyCode, RateType, ExchangeRate, Amount, AmountBase, AllocationMethod,
  IncludeInLandedCost, IncludedInSupplierInvoice, Notes, AllocatedBase, AdjustmentStatus); lines carry FobCostBase,
  AllocatedChargesBase, LandedCostBase (= UnitCostBase), ItemFobCost; header carries TotalChargesBase,
  TotalLandedCostBase. Error 65012 CHARGE_ALLOCATION (400) for allocation problems ("Charge N: ...").
- Landed cost adjustments (purchase.LandedCostAdjustments, type LCA, number LCA-KLW-000001 at creation):
  usp_LandedCostAdjustment_Search(@Search, @SourceInvoiceId, @BranchId, @Status 1|2|3, @DateFrom, @DateTo, page),
  usp_LandedCostAdjustment_Get(@Id) -> 3 result sets (header, charges, lines = the inventory / COGS split filled at
  posting), usp_LandedCostAdjustment_Save(@Id, @SourceInvoiceId, @DocumentDate, @Notes, @Charges, @ManualAllocations,
  @RowVersion, @UserId, @NewId OUT), _Post, _Cancel(@Reason), _Delete. Errors 67xxx: 67000 VALIDATION, 67004
  CONCURRENCY, 67005 NOT_DRAFT, 67006 NOT_FOUND, 67010 INVALID_STATUS, 67011 SOURCE_INVALID (409).
- Items: usp_Item_Get / _Search return FobCost, LastCost, AverageCost, InventoryValue, WeightKg, VolumeCbm;
  usp_Item_SetPurchasing has new optional last parameters @WeightKg, @VolumeCbm (after @PcPerContainer).
- Sales: usp_SalesDocument_Get lines carry FobCostAtSale, LastCostAtSale, NetSalesBase, CogsBase, GrossProfitBase,
  GrossProfitPct, ReturnedQuantityBase, RemainingBase; header TotalCostBase, TotalGrossProfitBase, TotalGrossProfitPct,
  SourceDocumentNumber. sales.usp_SalesDocument_CreateFromSource(@SourceId, @DocumentDate, @UserId, @NewId OUT) ->
  SRET draft (keep for the future returns page; expose the endpoint now). sales.usp_SalesProfit_Report(@DateFrom,
  @DateTo, @BranchId, @ClientId, @SalesmanId, @ItemFamilyId, @BrandId, @ItemId, @GroupBy Invoice|Item|Family|Brand|
  Client|Salesman|Branch|Month|All) -> GroupKey, GroupLabel, InvoiceCount, ReturnCount, QuantityBase, GrossSalesBase,
  DiscountBase, NetSalesBase, CogsBase, GrossProfitBase, GrossProfitPct, CogsAdjustmentsBase.
- Views inventory.vw_InventoryValuation / vw_InventoryValuationByWarehouse.
Permissions: purchase.chargetypes.manage (Configuration 910), purchase.landedcosts.view/create/post/cancel/delete
(1180-1220), sales.profit.view (680).

TASK
1. Run the script, show its output, append it to Repository/Database/Schema.sql under "-- ===== 23 =====" (no USE,
   no report batch; keep the guarded type drop/re-create block exactly - it drops and re-creates
   inventory.tvp_ItemReceipt and four posting procedures, all re-created inside the script).
2. Charge types: ChargeTypeDto (+ usageCount), ChargeTypeQuery, SaveChargeTypeRequest (ChargeCode [Required,
   StringLength(10)], ChargeName [Required, 100], AllocationMethod [Required, one of the 5], IncludeInLandedCost,
   IsRecoverableTax, Description [500], IsActive, RowVersion?) with a model rule "IsRecoverableTax = true requires
   IncludeInLandedCost = false"; ChargeTypesController api/purchase/charge-types: GET ?query, GET lookup?activeOnly=,
   GET {id}, POST -> 201, PUT {id}, PATCH {id}/active { isActive, rowVersion }, DELETE {id} (409 IN_USE when used) -
   all [HasPermission(purchase.chargetypes.manage)] except lookup [Authorize].
3. Purchase invoice charges: PurchaseChargeDto (the 6th result set) added to PurchaseDocumentDto.charges[]; line DTO +
   fobCostBase, allocatedChargesBase, landedCostBase, itemFobCost; header + totalChargesBase, totalLandedCostBase.
   SetPurchaseChargesRequest { charges[] { lineNumber, chargeTypeId, description?, providerPartyId?, reference?,
   currencyId?, rateType?, exchangeRate?, amount, allocationMethod?, includedInSupplierInvoice, notes? },
   manualAllocations[] { chargeLineNumber, purchaseLineId, amountBase }, rowVersion? } -> PUT
   api/purchase/documents/{id}/charges [purchase.invoices.create] -> PurchaseDocumentDto. Build the two DataTables in
   the exact column order of the types. Map 65012 -> 400 CHARGE_ALLOCATION.
4. Landed cost adjustments: DTOs (list, document with charges[] + lines[] + can* flags), SaveLandedCostAdjustmentRequest
   (SourceInvoiceId, DocumentDate, Notes?, charges[], manualAllocations[], RowVersion?), controller
   api/purchase/landed-cost-adjustments: GET ?query [view], GET {id} [view], POST [create] -> 201, PUT {id} [create],
   POST {id}/post [post], POST {id}/cancel [cancel] (reason), DELETE {id} [delete], GET {id}/export [view] (xlsx:
   header, charges, lines with the split). Map 67xxx codes as listed.
5. Items: ItemDto + fobCost, lastCost, averageCost, inventoryValue, weightKg, volumeCbm; Create/Update requests +
   WeightKg?, VolumeCbm? (through usp_Item_SetPurchasing). Item list DTO + fobCost, averageCost, inventoryValue.
6. Sales: SalesInvoiceDto lines + the snapshot fields, header + totalCostBase, totalGrossProfitBase,
   totalGrossProfitPct, sourceDocumentNumber - cost / profit fields are returned ONLY when the caller holds
   sales.profit.view (null otherwise). POST api/sales/invoices/{id}/create-return [sales.invoices.create] -> the SRET
   draft as SalesInvoiceDto (no page yet). SalesProfitController api/sales/profit: GET ?dateFrom&dateTo&branchId&
   clientId&salesmanId&itemFamilyId&brandId&itemId&groupBy [sales.profit.view] -> rows; GET export -> xlsx.
7. GET api/inventory/valuation?warehouseId= [inventory.items.view] -> rows of the valuation views (+ totals).
8. PermissionCatalog: the 7 new codes. Build 0 warnings; "Database schema verified".

VERIFY (token admin / Admin@12345) with curl, show output. Preparation: item TVS-AP160 on-hand 0 (or note the
current figures), weight 130 kg, volume 1.2 CBM; supplier SUP-0001 currency USD.
  a. Charge types: GET list -> 10 seeded rows with usageCount 0; POST a new type "TEST" (Manual) -> 201; POST a type
     with IsRecoverableTax true and IncludeInLandedCost true -> 400; DELETE TEST -> 204; DELETE FRE after it is used
     in step b -> 409 IN_USE.
  b. PINV draft: 100 PC TVS-AP160 at 10 USD with 10 % discount (net 900) + PUT charges: FRE 600 USD (Weight), CUS 900
     (Value), INS 100 (Value), ADM 50 (not in landed cost) -> GET shows charges[] with allocatedBase null (draft).
     POST post -> line fobCostBase 9.00, allocatedChargesBase 1600, landedCostBase 25.00; header totalChargesBase 1600,
     totalLandedCostBase 2500; item fobCost 9.00, lastCost 25.00, averageCost 25.00 (on a 0 starting stock),
     inventoryValue 2500; StockMovements row UnitCostBase 25.00.
  c. Weight allocation guard: an invoice with two items where one has no weight + a FRE charge -> POST post -> 400
     CHARGE_ALLOCATION "Charge 1: item X has no weight (kg) ...".
  d. Manual allocation: a charge with method Manual and manualAllocations summing to a different amount -> 400
     CHARGE_ALLOCATION; correct sum -> posted with those amounts.
  e. Sales: post a sales invoice of 20 PC at 40 USD -> line cogsBase 500 (20 x 25), netSalesBase 800, grossProfitBase
     300, grossProfitPct 37.50; GET api/sales/profit?groupBy=Invoice shows the same; a user without sales.profit.view
     gets null cost fields and 403 on the profit endpoint.
  f. LCA: POST an adjustment on the posted PINV with FRE 400 (Weight) -> post -> lines: allocated 400, extra per unit
     4.00, remaining 80 -> inventoryPortionBase 320, cogsPortionBase 80; item averageCost 29.00 (2000 + 320) / 80,
     lastCost 29.00; invoice line landedCostBase 29.00; inventory.CostAdjustments has an Inventory row 320 and a COGS
     row 80; GET profit groupBy=Month shows cogsAdjustmentsBase 80. Cancel the LCA -> averageCost back to 25.00,
     negative rows written.
  g. Cancel the PINV while the LCA is posted -> 409 SOURCE_INVALID; after cancelling the LCA, cancel the PINV ->
     item costs rebuilt (averageCost from the remaining ledger).
  h. POST api/sales/invoices/{id}/create-return -> SRET draft with the invoice prices and unitCostBase 25.00 per line.
  i. Valuation endpoint returns TVS-AP160 with onHand, averageCost, inventoryValue.
Report: script output, files changed, every verification result.
```

## Prompt B — Frontend

```text
You are working on /home/bilal/VSProjects/InventoryShipment-Project/Inventory_Shipment.Web (Mantine 9 stack, docs/frontend-conventions.md, shared ui
components, document-page skeleton, DocumentListPage, FormModal). Frontend only. Backend: api/purchase/charge-types
(list/lookup/get/create/update/active/delete), PUT api/purchase/documents/{id}/charges, purchase documents now carry
charges[] + FOB / charges / landed per line + totals, api/purchase/landed-cost-adjustments (list/get/create/update/
post/cancel/delete/export), items with fobCost/lastCost/averageCost/inventoryValue/weightKg/volumeCbm,
api/sales/profit (+ export), sales invoices with cost / profit fields (null without permission),
api/inventory/valuation. Error codes: VALIDATION, DUPLICATE_CODE, DUPLICATE_NAME, IN_USE, CONCURRENCY, NOT_FOUND,
CHARGE_ALLOCATION ("Charge N: ..."), NOT_DRAFT, INVALID_STATUS, SOURCE_INVALID. Permissions:
purchase.chargetypes.manage, purchase.invoices.create, purchase.landedcosts.*, sales.profit.view. Dev: npm run dev,
admin / Admin@12345.

TASK
1. PURCHASE > Charge Types (/purchase/charge-types, permission purchase.chargetypes.manage) - US-MD-008:
   PageHeader "Charge Types - Maintain purchase related charge types and allocation rules", "+ New Charge Type".
   FilterBar (auto-apply): Charge Code, Charge Name, Allocation Method (All + 5), Cost impact (All / Included in
   landed cost / Not included), Status (All / Active / Inactive). DataTable (server paging): #, Charge Code, Charge
   Name, Allocation Method (label: By Item Value / By Quantity / By Weight / By Volume (CBM) / Manual), Include in
   Landed Cost (Yes/No switch-like badge), Recoverable Tax, Status badge, Description, Actions: Edit, Activate /
   Deactivate (confirm), Delete - shown ONLY when usageCount = 0 (used types show a tooltip "Used in N transactions -
   deactivate instead").
   Popup "New Charge Type" / "Edit Charge Type" (FormModal, autofocus on Charge Code): Charge Code* (max 10, forced
   uppercase), Charge Name* (max 100), Allocation Method* (Select; the Weight and Volume options show a small
   warning icon with tooltip "Items need Weight (kg) / Volume (CBM) in Item Definition"), Include in Landed Cost
   (Switch, default on), Recoverable Tax (Switch, default off - when turned ON, "Include in Landed Cost" is switched
   off and disabled with the hint "A recoverable tax is never part of the item cost"), Description (Textarea), Active
   (Switch, default on); buttons Cancel / Save Charge Type. Errors: DUPLICATE_CODE / DUPLICATE_NAME on the field,
   IN_USE and others as notify.
2. Purchase invoice page - "Charges" tab (draft: editable; posted: read-only):
   Charge lines grid: #, Charge Type (Select from charge-types/lookup; picking one fills the allocation method and
   the "in landed cost" flag), Description, Provider (searchable Select parties/lookup?type=Supplier, optional),
   Reference, Currency (Select, default = invoice currency), Rate (auto from api/purchase/rate for the invoice date,
   editable; "1" for USD), Amount, Amount (USD) read-only, Allocation Method (Select, default = type's; Manual opens
   the allocation grid below the line: one row per invoice line with an editable USD amount and a running "remaining
   to allocate" indicator that must reach 0), Billed by supplier (checkbox "Included in supplier invoice"), Notes,
   Delete. Charges whose type is not in landed cost are shown greyed with the badge "not in cost". Footer: Total
   charges (USD) / of which landed. Save: PUT charges (separately from the lines; "Save Draft" saves lines then
   charges). Posted invoice: the lines grid gets FOB (USD/base unit), Charges (USD), Landed cost (USD/base unit)
   columns and the summary shows Total charges + Total landed cost; the Charges tab lists invoice charges and the
   adjustments' charges (with the LCA number + status).
3. PURCHASE > Landed Cost Adjustments (/purchase/landed-cost-adjustments, permissions purchase.landedcosts.*):
   list (filters: search, Branch, Status Draft/Posted/Cancelled, Date from/to; columns: Number, Date, Invoice
   (link), Supplier, Total charges, Inventory portion, COGS portion, Status, Posted by/at; actions View / Edit /
   Post / Cancel / Delete gated by status + permission) and document page: header (Number, Date*, Purchase Invoice*
   (searchable Select of POSTED purchase invoices: number - supplier - date; read-only once saved), Notes), the same
   Charges grid as the invoice tab (currency default USD; manual allocation grid over the INVOICE lines), a
   read-only "Invoice lines" preview (item, received, returned, on hand now, current landed cost) and, once posted,
   the "Split" table (allocated, extra per unit, remaining, inventory portion, COGS portion, landed before / after)
   with a banner "Posted by X on Y - item average costs updated". Actions: Save Draft, Save & Post (confirm "Post
   this adjustment? Item costs will be updated."), Cancel (reason), Delete, Export. Also a "New landed cost
   adjustment" button on a POSTED purchase invoice page (pre-selects the invoice).
4. Item Definition: "Costs" box now shows FOB Purchase Cost, Last Cost (landed), Average Cost, On Hand, Inventory
   Value (USD, 2 decimals) with tooltips defining each; Purchasing section + Weight (kg, 3 decimals) and Volume
   (CBM, 4 decimals) per base unit. Items list: replace the "Avg. Cost" column by Avg. Cost + Inventory Value
   (hidden below 1200 px).
5. Sales invoice page (view mode) for users with sales.profit.view: line columns COGS (USD), Gross Profit (USD),
   GP % and a summary block Net Sales / COGS / Gross Profit / GP % - hidden entirely for other users. "Create
   Return" button (posted invoice, sales.invoices.create) -> POST create-return -> notify "Return draft SRET
   created" (no returns page yet: just show the number and leave).
6. SALES > Sales Profit (/sales/profit, sales.profit.view): FilterBar (Date from/to default current month, Branch,
   Client, Salesman, Family, Brand, Item, Group by: Invoice / Item / Family / Brand / Client / Salesman / Branch /
   Month / All); summary cards (Net Sales, COGS, Gross Profit, GP %); DataTable (client-side sort): Group,
   Invoices, Returns, Qty, Gross Sales, Discount, Net Sales, COGS, Gross Profit, GP % (red < 0), COGS adjustments
   (shown for Month / Branch / Item / Family / Brand / All); totals row; Export to Excel.
7. INVENTORY > Stock Valuation (/inventory/valuation, inventory.items.view): warehouse filter, table (item, on hand,
   average cost, inventory value), totals card, Export.
8. docs/frontend-conventions.md: "Charge types & landed cost", "Sales profit" sections.
9. Quality: typecheck / lint / build clean; all breakpoints; permission gating as described.

VERIFY (API running) with screenshots at 1440 and 390:
  a. Charge Types: 10 rows, filters auto-apply, popup validation (duplicate code message, tax toggle disables
     landed cost), Delete hidden for used types, activate/deactivate works.
  b. Purchase invoice draft: add FRE 600 (Weight), CUS 900, INS 100, ADM 50 (greyed) -> Save -> Save & Post ->
     lines show FOB 9.00 / Charges / Landed 25.00; summary Total landed cost 2500.
  c. Manual allocation grid blocks saving until the remaining is 0; weight allocation on an item without weight
     shows the API's CHARGE_ALLOCATION message with the charge highlighted.
  d. Landed Cost Adjustment from the posted invoice: FRE 400 -> Save & Post -> split table (inventory 320 / COGS 80),
     item Average Cost 29.00 on the item page; cancel -> back to 25.00.
  e. Sales invoice view (admin): COGS / GP columns and summary; a user without sales.profit.view sees none of it.
  f. Sales Profit page: group by Item shows TVS-AP160 with GP % 37.50; export works; Stock Valuation totals match
     on hand x average cost.
Report: files added/changed, navigation changes, every verification result.
```
