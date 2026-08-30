# Inventory & Stock module — build plan (before Shipment)

## Guiding decisions

1. **Motorcycles are serialized stock.** One row per physical unit (`inventory.Units`: VIN/chassis, engine number,
   product, color, model year, status, current location, cost). Quantities are counts over units.
   Spare parts / accessories (later) are quantity-based and share locations and the movement ledger:
   a movement line references either a unit or a product + quantity.
2. **Stock is never edited in place.** Every change is a document (receipt, transfer, adjustment, count,
   later shipment) with a Draft -> Posted workflow. Posting writes immutable rows to `inventory.StockMovements`;
   stock on hand is derived from them. Posted documents are corrected by reversing documents.
3. **Inventory ends at reservation.** Inventory owns master data, locations, receiving, the ledger,
   transfers, adjustments, counts, unit status, reservations/availability. Shipment owns dispatch orders,
   packing, vehicles/drivers, delivery notes, proof of delivery, and consumes inventory through
   reserve -> issue.
4. **One schema per module.** Security objects live in `security`; everything in this plan goes in the
   `inventory` schema (later `shipment`). Nothing is created in `dbo`.
5. Same technical pattern as the Security module: SQL script (tables, functions, procedures) ->
   Model/Repository/Service -> API with `[HasPermission]` -> React pages under an **Inventory** menu section.
   New permission codes are added to `PermissionCatalog.cs` and synced automatically.

## Phases

### Phase 1 — Master data and locations
- Tables: `inventory.Brands`, `inventory.Products` (model/variant, category Motorcycle/Scooter/Tricycle, engine cc,
  fuel type, IsActive), `inventory.Colors`, `inventory.Locations` (type Warehouse / Showroom / Bonded / Damaged / Transit,
  address, IsActive), `inventory.Suppliers`, `inventory.UnitsOfMeasure` (for future parts).
- Permissions: inventory.masterdata.view, inventory.masterdata.manage, inventory.locations.manage,
  inventory.suppliers.manage.
- Pages: Products (with colors per product), Locations, Suppliers. Sidebar section "Inventory".

### Phase 2 — Receiving and the ledger (core)
- Tables: `inventory.GoodsReceipts` (number, supplier, location, references: invoice / BL / container,
  currency, received date, status Draft/Posted/Cancelled, notes), `inventory.GoodsReceiptLines`
  (product, color, model year, qty expected, qty received, unit cost), `inventory.Units`, `inventory.StockMovements`
  (type Receipt/Transfer/Adjustment/CountVariance/Issue/Return, UnitId or ProductId+Qty, from/to location,
  reference type + id, performed by, at, notes), `inventory.DocumentSequences` (GRN-2026-00012 numbering).
- Procedures: `inventory.usp_GoodsReceipt_Post` (creates units InStock, writes movements, stamps costs, atomic),
  `inventory.usp_GoodsReceipt_Cancel`, `inventory.usp_Sequence_Next`.
- Views: `inventory.vw_StockOnHand` (product x color x location counts), `inventory.vw_UnitHistory`.
- Unit capture: VIN + engine number typed or scanned (barcode scanner = keyboard input), validated for
  format (17 characters for TVS chassis numbers) and uniqueness across the system.
- Permissions: inventory.receipts.view / create / post / cancel, inventory.stock.view, inventory.units.view.
- Pages: Goods receipts (list, create/edit draft with lines and unit capture, post), Stock on hand (grid with
  drill-down to units), Units (search by VIN / engine number, unit card with full history).

### Phase 3 — Moving and correcting stock
- Tables: `inventory.StockTransfers` + lines (with optional in-transit state), `inventory.StockAdjustments` + lines with
  reason codes (Damage, Theft, WriteOff, Correction, Demo), `inventory.StockCounts` + lines (scanned vs expected,
  variances posted as adjustments), `inventory.UnitStatusHistory`.
- Unit statuses: InStock, Reserved, Shipped, Sold, Damaged, Quarantine, Demo, WrittenOff.
- Procedures: `inventory.usp_StockTransfer_Post`, `inventory.usp_StockAdjustment_Post`, `inventory.usp_StockCount_Post`,
  `inventory.usp_Unit_SetStatus`.
- Permissions: inventory.transfers.*, inventory.adjustments.*, inventory.counts.*, inventory.units.edit.
- Pages: Transfers, Adjustments, Stock counts, Unit status actions on the unit card.

### Phase 4 — Availability, valuation, reporting (then start Shipment)
- Tables: `inventory.Reservations` (unit, reserved for reference type/id, expires at, status), `inventory.ReorderLevels`
  (product/color/location minimum), `inventory.LandedCosts` (freight, duty, clearing allocated per receipt).
- Procedures: `inventory.usp_Reservation_Reserve / Release / Expire`, `inventory.usp_Units_Issue` (used by Shipment).
- Views/reports: availability (on hand - reserved) per model/color/location, aging (days in stock per unit),
  movement register, stock valuation, low-stock alerts. Excel/PDF exports (ClosedXML / QuestPDF).
- Pages: Availability, Reservations, Reports, dashboard cards (stock by model, aging, alerts).

## Cross-cutting
- Document numbering, audit columns (CreatedBy/At, UpdatedBy/At), rowversion for concurrency on documents.
- Every document: Draft (editable) -> Posted (immutable) -> Cancelled/Reversed by a new document.
- Every list page: search, filters, paging, export; every document page: header + lines + post/cancel actions
  gated by permissions.

## Decide before Phase 1
- Customers: dealers, end customers, or both? (reservation target and later shipment parties)
- CKD assembly in scope, or all units arrive complete (CBU)?
- Spare parts / accessories in scope this year?
- Costing currency: USD, CDF, or both (exchange rate per receipt)?
- One company with several locations, or separate branches with separated stock and permissions?
