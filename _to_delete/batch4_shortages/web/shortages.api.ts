import { fetchBlob, request } from '../http'
import type { SalesRateType } from '../sales/invoices'

/**
 * The shortage report: one row per item and warehouse, and the purchase orders it turns into.
 *
 * NOT PAGED. The report is read whole and the page filters, sorts and sums it itself — the cards
 * above the grid ("Items short", "Total suggested cost") need every row, not the current page.
 */
const BASE = '/api/inventory/shortages'

export interface ShortageRowDto {
  itemId: number
  itemCode: string
  itemName: string
  brandId: number
  brandName: string
  itemFamilyId: number
  familyName: string
  isBivac: boolean
  warehouseId: number
  warehouseCode: string
  warehouseName: string
  branchId: number
  branchName: string
  onHandBase: number
  /** On posted, still open purchase orders. */
  incomingBase: number
  /** On hand + incoming: what is compared with the minimum. */
  availableBase: number
  minQuantity: number
  maxQuantity: number | null
  shortageBase: number
  suggestedBase: number
  purchaseItemUnitId: number | null
  purchaseUnitName: string | null
  purchasePackingFormula: number | null
  /** Whole purchase units that bring Available up to the maximum (0 when nothing is short). */
  suggestedQty: number
  avgDailySalesBase: number
  /** Days the stock on hand lasts at the average sales rate; null when nothing was sold. */
  daysOfCover: number | null
  /** The default supplier, else the last one the item was bought from. */
  supplierId: number | null
  supplierName: string | null
  supplierIsDefault: boolean
  lastCost: number | null
  averageCost: number | null
  leadTimeDays: number | null
  lastPurchaseAtUtc: string | null
}

export interface ShortageQuery {
  branchId?: number
  warehouseId?: number
  itemFamilyId?: number
  brandId?: number
  supplierId?: number
  search?: string
  /** True = rows where Available is below the minimum; false = every evaluated item and warehouse. */
  onlyShortages: boolean
  /** The window the average daily sales is taken over: 30, 60 or 90 days. */
  daysForAverage: number
}

export interface ShortageOrderLine {
  itemId: number
  warehouseId: number
  supplierId: number
  /** The unit ordered in — the item's purchase unit from the report unless the reader chose another. */
  itemUnitId: number
  quantity: number
  /** Null = the item's last cost, converted to the order's currency. */
  unitPrice?: number | null
  notes?: string | null
}

export interface CreatePurchaseOrdersRequest {
  /** Null = today. */
  documentDate?: string | null
  expectedDate?: string | null
  rateType?: SalesRateType
  notes?: string | null
  lines: ShortageOrderLine[]
}

export interface CreatedPurchaseOrderDto {
  id: number
  documentNumber: string | null
  supplierId: number
  supplierName: string
  warehouseId: number
  warehouseName: string
  branchId: number
  branchName: string
  currencyCode: string
  exchangeRate: number
  lineCount: number
  totalAmount: number
  status: string
}

export interface ShortageOrderFailure {
  supplierId: number
  warehouseId: number
  code: string
  message: string
}

export interface CreatePurchaseOrdersResult {
  orders: CreatedPurchaseOrderDto[]
  created: number
  failed: ShortageOrderFailure[]
}

function toParams(query: ShortageQuery): URLSearchParams {
  const params = new URLSearchParams({ onlyShortages: String(query.onlyShortages), daysForAverage: String(query.daysForAverage) })
  if (query.branchId !== undefined) params.set('branchId', String(query.branchId))
  if (query.warehouseId !== undefined) params.set('warehouseId', String(query.warehouseId))
  if (query.itemFamilyId !== undefined) params.set('itemFamilyId', String(query.itemFamilyId))
  if (query.brandId !== undefined) params.set('brandId', String(query.brandId))
  if (query.supplierId !== undefined) params.set('supplierId', String(query.supplierId))
  if (query.search?.trim()) params.set('search', query.search.trim())
  return params
}

export const shortagesApi = {
  report: (query: ShortageQuery, signal?: AbortSignal) =>
    request<ShortageRowDto[]>(`${BASE}?${toParams(query).toString()}`, { signal }),

  exportToExcel: async (query: ShortageQuery, fileName: string) => {
    const blob = await fetchBlob(`${BASE}/export?${toParams(query).toString()}`)
    const url = URL.createObjectURL(blob)
    const link = document.createElement('a')
    link.href = url
    link.download = fileName
    document.body.appendChild(link)
    link.click()
    link.remove()
    setTimeout(() => URL.revokeObjectURL(url), 0)
  },

  /** One draft purchase order per supplier and warehouse. Needs purchase.orders.create. */
  createOrders: (payload: CreatePurchaseOrdersRequest) =>
    request<CreatePurchaseOrdersResult>(`${BASE}/create-orders`, { method: 'POST', body: payload }),
}
