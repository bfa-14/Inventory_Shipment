import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router'
import { Alert, Anchor, Badge, Button, Group, Paper, Select, SimpleGrid, Switch, Text, TextInput, Tooltip } from '@mantine/core'
import { IconAlertTriangle, IconFileExport, IconSearch, IconShoppingCart } from '@tabler/icons-react'
import { ApiError } from '../../api/http'
import { shortagesApi, type CreatePurchaseOrdersResult, type ShortageRowDto } from '../../api/inventory/shortages'
import { brandsApi } from '../../api/masterdata/brands'
import { branchesApi } from '../../api/masterdata/branches'
import { itemFamiliesApi } from '../../api/masterdata/itemFamilies'
import { partiesApi } from '../../api/masterdata/parties'
import { warehousesApi } from '../../api/masterdata/warehouses'
import type { BranchLookupDto, BrandLookupDto, ItemFamilyLookupDto, PartyLookupDto, WarehouseLookupDto } from '../../api/types'
import { useAuth } from '../../auth/useAuth'
import { unitLabel } from '../../components/documents/documentKind'
import { formatMoney, formatNumber } from '../../components/format'
import { PURCHASE_ORDER, supplierLabel } from '../../components/purchase/purchaseKind'
import { DataTable, type DataTableColumn } from '../../components/ui/DataTable'
import { FilterBar } from '../../components/ui/FilterBar'
import { notify } from '../../components/ui/notify'
import { PageHeader } from '../../components/ui/PageHeader'
import { useGridQuery } from '../../hooks/useGridQuery'
import { PERMISSIONS } from '../../navigation'
import { CreatePurchaseOrdersModal } from './CreatePurchaseOrdersModal'
import { brandLabel, familyOptions } from './lookups'

interface Filters {
  search: string
  branchId: string | null
  warehouseId: string | null
  itemFamilyId: string | null
  brandId: string | null
  supplierId: string | null
  onlyShortages: boolean
  daysForAverage: string
}

const NO_FILTERS: Filters = { search: '', branchId: null, warehouseId: null, itemFamilyId: null, brandId: null, supplierId: null, onlyShortages: true, daysForAverage: '30' }
const AVERAGE_WINDOWS = ['30', '60', '90']

/** A report row with the id the grid keys on: one item in one warehouse. */
type ShortageRow = ShortageRowDto & { id: string }

const EMPTY_ROWS: ShortageRow[] = []

const numberOrUndefined = (value: string | null) => (value === null ? undefined : Number(value))

/** "3 Box (x12)" — the suggestion in the unit the supplier sells. */
function suggested(row: ShortageRowDto): string {
  if (row.suggestedQty <= 0) return '—'
  const unit = row.purchaseUnitName ? unitLabel(row.purchaseUnitName, row.purchasePackingFormula ?? 1) : ''
  return `${formatNumber(row.suggestedQty)} ${unit}`.trim()
}

/**
 * What is below its minimum, and the purchase orders that fix it.
 *
 * READ WHOLE, SORTED AND PAGED HERE. The report is one flat list per set of filters; the cards
 * above the grid sum every row, and a sort on Days of Cover has to see every row too. The server
 * is asked again only when a filter changes.
 *
 * A ROW IS RED WHEN THERE IS NOTHING ON THE SHELF and orange when it is merely short; Days of Cover
 * turns red when the stock will run out before a new order could arrive (lead time). Suggested is in
 * the purchase unit, which is what "Create Purchase Order" sends.
 */
export function ShortagesPage() {
  const { hasPermission } = useAuth()
  const canOrder = hasPermission(PERMISSIONS.purchaseOrdersCreate)

  const [branches, setBranches] = useState<BranchLookupDto[]>([])
  const [warehouses, setWarehouses] = useState<WarehouseLookupDto[]>([])
  const [families, setFamilies] = useState<ItemFamilyLookupDto[]>([])
  const [brands, setBrands] = useState<BrandLookupDto[]>([])
  const [suppliers, setSuppliers] = useState<PartyLookupDto[]>([])

  const [selected, setSelected] = useState<ShortageRow[]>([])
  const [ordering, setOrdering] = useState(false)
  const [created, setCreated] = useState<CreatePurchaseOrdersResult | null>(null)

  const grid = useGridQuery<Filters, ShortageRow, ShortageRow[]>({
    initialFilters: NO_FILTERS,
    debounced: ['search'],
    initialSort: { columnAccessor: 'shortageBase', direction: 'desc' },
    paging: 'client',
    pageSize: 25,
    errorMessage: 'The shortage report could not be loaded.',
    fetcher: useCallback(async ({ filters, signal }) => {
      const rows = await shortagesApi.report(
        {
          search: filters.search.trim() || undefined,
          branchId: numberOrUndefined(filters.branchId),
          warehouseId: numberOrUndefined(filters.warehouseId),
          itemFamilyId: numberOrUndefined(filters.itemFamilyId),
          brandId: numberOrUndefined(filters.brandId),
          supplierId: numberOrUndefined(filters.supplierId),
          onlyShortages: filters.onlyShortages,
          daysForAverage: Number(filters.daysForAverage) || 30,
        },
        signal,
      )
      return rows.map((row) => ({ ...row, id: `${row.itemId}:${row.warehouseId}` }))
    }, []),
  })

  const { filters, setFilter, data, loading, error, page, pageSize, sortStatus } = grid

  useEffect(() => {
    branchesApi.lookup().then(setBranches).catch(() => {})
    itemFamiliesApi.lookup().then(setFamilies).catch(() => {})
    brandsApi.lookup().then(setBrands).catch(() => {})
    partiesApi.lookup({ partyType: 'Supplier' }).then(setSuppliers).catch(() => {})
  }, [])

  useEffect(() => {
    warehousesApi
      .lookup(true, filters.branchId === null ? undefined : Number(filters.branchId))
      .then(setWarehouses)
      .catch(() => {})
  }, [filters.branchId])

  const rows = useMemo(() => data ?? EMPTY_ROWS, [data])

  // The ticked rows belong to the report they came from: a reload that dropped a row drops its tick
  // too, derived here rather than in an effect so no render ever shows a tick on a row that is gone.
  const ticked = useMemo(() => {
    const ids = new Set(rows.map((r) => r.id))
    return selected.filter((r) => ids.has(r.id))
  }, [rows, selected])

  const summary = useMemo(() => {
    const short = rows.filter((r) => r.shortageBase > 0)
    return {
      itemsShort: new Set(short.map((r) => r.itemId)).size,
      suggestedCost: short.reduce((sum, r) => sum + r.suggestedBase * (r.lastCost ?? r.averageCost ?? 0), 0),
      warehouses: new Set(short.map((r) => r.warehouseId)).size,
    }
  }, [rows])

  const records = useMemo(() => {
    const key = sortStatus.columnAccessor as keyof ShortageRow
    const sorted = [...rows].sort((a, b) => {
      const x = a[key], y = b[key]
      if (x === y) return 0
      if (x === null || x === undefined) return 1
      if (y === null || y === undefined) return -1
      return typeof x === 'number' && typeof y === 'number' ? x - y : String(x).localeCompare(String(y))
    })
    if (sortStatus.direction === 'desc') sorted.reverse()
    return sorted.slice((page - 1) * pageSize, page * pageSize)
  }, [rows, sortStatus, page, pageSize])

  async function exportToExcel() {
    try {
      await shortagesApi.exportToExcel(
        {
          search: filters.search.trim() || undefined,
          branchId: numberOrUndefined(filters.branchId),
          warehouseId: numberOrUndefined(filters.warehouseId),
          itemFamilyId: numberOrUndefined(filters.itemFamilyId),
          brandId: numberOrUndefined(filters.brandId),
          supplierId: numberOrUndefined(filters.supplierId),
          onlyShortages: filters.onlyShortages,
          daysForAverage: Number(filters.daysForAverage) || 30,
        },
        `Shortages_${new Date().toISOString().slice(0, 10)}.xlsx`,
      )
    } catch (err) {
      notify.error(err instanceof ApiError ? err.message : 'The report could not be exported.')
    }
  }

  function ordersCreated(result: CreatePurchaseOrdersResult) {
    setOrdering(false)
    setSelected([])
    setCreated(result)
    grid.reload()
  }

  const columns: DataTableColumn<ShortageRow>[] = [
    {
      accessor: 'itemCode',
      title: 'Item',
      sortable: true,
      render: (row) => (
        <div>
          <Anchor component={Link} to={`/inventory/items/${row.itemId}`} fz="sm" fw={500} onClick={(event) => event.stopPropagation()}>
            {row.itemCode}
          </Anchor>
          <Text fz="xs" c="dimmed">{row.itemName}</Text>
        </div>
      ),
    },
    { accessor: 'warehouseCode', title: 'Warehouse', sortable: true, render: (row) => <Text fz="sm">{row.warehouseCode}<Text span fz="xs" c="dimmed"> · {row.branchName}</Text></Text> },
    { accessor: 'onHandBase', title: 'On Hand', sortable: true, textAlign: 'right', width: 90, render: (row) => <Text fz="sm" c={row.onHandBase <= 0 ? 'red' : undefined} fw={row.onHandBase <= 0 ? 700 : 400}>{formatNumber(row.onHandBase)}</Text> },
    { accessor: 'incomingBase', title: 'Incoming', sortable: true, textAlign: 'right', width: 90, render: (row) => formatNumber(row.incomingBase) },
    { accessor: 'availableBase', title: 'Available', sortable: true, textAlign: 'right', width: 90, render: (row) => <Text fz="sm" fw={500}>{formatNumber(row.availableBase)}</Text> },
    { accessor: 'minQuantity', title: 'Min', sortable: true, textAlign: 'right', width: 70, render: (row) => formatNumber(row.minQuantity) },
    { accessor: 'maxQuantity', title: 'Max', sortable: true, textAlign: 'right', width: 80, render: (row) => (row.maxQuantity === null ? '—' : formatNumber(row.maxQuantity)) },
    { accessor: 'shortageBase', title: 'Shortage', sortable: true, textAlign: 'right', width: 90, render: (row) => <Text fz="sm" c={row.shortageBase > 0 ? 'orange' : 'dimmed'} fw={row.shortageBase > 0 ? 600 : 400}>{formatNumber(row.shortageBase)}</Text> },
    { accessor: 'suggestedQty', title: 'Suggested', sortable: true, textAlign: 'right', width: 120, render: (row) => <Text fz="sm" fw={500} style={{ whiteSpace: 'nowrap' }}>{suggested(row)}</Text> },
    { accessor: 'avgDailySalesBase', title: 'Avg daily sales', sortable: true, textAlign: 'right', width: 110, render: (row) => formatNumber(row.avgDailySalesBase, 2) },
    {
      accessor: 'daysOfCover',
      title: 'Days of cover',
      sortable: true,
      textAlign: 'right',
      width: 100,
      render: (row) => {
        if (row.daysOfCover === null) return <Text fz="sm" c="dimmed">—</Text>
        const late = row.leadTimeDays !== null && row.daysOfCover < row.leadTimeDays
        return (
          <Tooltip label={late ? `Runs out before the ${formatNumber(row.leadTimeDays ?? 0)}-day lead time` : 'At the average sales rate'} withArrow>
            <Text fz="sm" c={late ? 'red' : undefined} fw={late ? 700 : 400}>{formatNumber(row.daysOfCover, 1)}</Text>
          </Tooltip>
        )
      },
    },
    {
      accessor: 'supplierName',
      title: 'Supplier',
      sortable: true,
      render: (row) =>
        row.supplierId === null ? (
          <Tooltip label="No supplier: set a default supplier on the item, or buy it once" withArrow>
            <Group gap={4} wrap="nowrap">
              <IconAlertTriangle size={15} color="var(--mantine-color-orange-6)" />
              <Text fz="sm" c="dimmed">None</Text>
            </Group>
          </Tooltip>
        ) : (
          <Group gap={6} wrap="nowrap">
            <Text fz="sm">{row.supplierName}</Text>
            {row.supplierIsDefault ? <Badge size="xs" variant="light" color="blue">default</Badge> : <Badge size="xs" variant="light" color="gray">last</Badge>}
          </Group>
        ),
    },
    { accessor: 'lastCost', title: 'Last cost', sortable: true, textAlign: 'right', width: 120, render: (row) => (row.lastCost === null ? '—' : formatMoney(row.lastCost, 'USD')) },
    { accessor: 'leadTimeDays', title: 'Lead time', sortable: true, textAlign: 'right', width: 90, render: (row) => (row.leadTimeDays === null ? '—' : `${formatNumber(row.leadTimeDays)} d`) },
  ]

  return (
    <div>
      <PageHeader
        title="Shortages"
        subtitle="Items whose available stock (on hand + incoming) is below their minimum."
        actions={
          <Group gap="xs">
            <Button variant="default" leftSection={<IconFileExport size={16} />} onClick={() => void exportToExcel()}>
              Export
            </Button>
            {canOrder && (
              <Button leftSection={<IconShoppingCart size={16} />} disabled={ticked.length === 0} onClick={() => setOrdering(true)}>
                Create Purchase Order ({formatNumber(ticked.length)})
              </Button>
            )}
          </Group>
        }
      />

      <FilterBar>
        <FilterBar.Col span={2}>
          <Select label="Branch" placeholder="All branches" data={branches.map((b) => ({ value: String(b.id), label: b.branchName }))} value={filters.branchId} onChange={(next) => { setFilter('branchId', next); setFilter('warehouseId', null) }} clearable searchable />
        </FilterBar.Col>
        <FilterBar.Col span={2}>
          <Select label="Warehouse" placeholder="All warehouses" data={warehouses.map((w) => ({ value: String(w.id), label: w.warehouseName }))} value={filters.warehouseId} onChange={(next) => setFilter('warehouseId', next)} clearable searchable />
        </FilterBar.Col>
        <FilterBar.Col span={2}>
          <Select label="Family" placeholder="All families" description="Includes every sub-family" data={familyOptions(families)} value={filters.itemFamilyId} onChange={(next) => setFilter('itemFamilyId', next)} clearable searchable />
        </FilterBar.Col>
        <FilterBar.Col span={2}>
          <Select label="Brand" placeholder="All brands" data={brands.map((b) => ({ value: String(b.id), label: brandLabel(b) }))} value={filters.brandId} onChange={(next) => setFilter('brandId', next)} clearable searchable />
        </FilterBar.Col>
        <FilterBar.Col span={2}>
          <Select label="Supplier" placeholder="All suppliers" data={suppliers.map((s) => ({ value: String(s.id), label: supplierLabel(s) }))} value={filters.supplierId} onChange={(next) => setFilter('supplierId', next)} clearable searchable />
        </FilterBar.Col>
        <FilterBar.Col span={2}>
          <TextInput label="Search" placeholder="Item code or name" leftSection={<IconSearch size={16} />} value={filters.search} onChange={(event) => setFilter('search', event.currentTarget.value)} />
        </FilterBar.Col>
        <FilterBar.Col span={2}>
          <Select label="Average over" data={AVERAGE_WINDOWS.map((d) => ({ value: d, label: `${d} days` }))} value={filters.daysForAverage} onChange={(next) => next && setFilter('daysForAverage', next)} allowDeselect={false} />
        </FilterBar.Col>
        <FilterBar.Col span={2}>
          <Switch label="Only shortages" checked={filters.onlyShortages} onChange={(event) => setFilter('onlyShortages', event.currentTarget.checked)} mt="xl" />
        </FilterBar.Col>
      </FilterBar>

      <SimpleGrid cols={{ base: 1, sm: 3 }} mb="md">
        <Paper radius="lg" p="md" withBorder data-summary="items-short">
          <Text fz="sm" c="dimmed">Items short</Text>
          <Text fz="xl" fw={700} c={summary.itemsShort > 0 ? 'orange' : undefined}>{formatNumber(summary.itemsShort)}</Text>
        </Paper>
        <Paper radius="lg" p="md" withBorder data-summary="suggested-cost">
          <Text fz="sm" c="dimmed">Total suggested cost</Text>
          <Text fz="xl" fw={700}>{formatMoney(summary.suggestedCost, 'USD')}</Text>
          <Text fz="xs" c="dimmed">At the last cost (else the average) of each item</Text>
        </Paper>
        <Paper radius="lg" p="md" withBorder data-summary="warehouses">
          <Text fz="sm" c="dimmed">Warehouses affected</Text>
          <Text fz="xl" fw={700}>{formatNumber(summary.warehouses)}</Text>
        </Paper>
      </SimpleGrid>

      {created && (
        <Alert color="green" mb="md" withCloseButton onClose={() => setCreated(null)} title={`${formatNumber(created.created)} purchase order(s) created`}>
          <Group gap="xs" wrap="wrap">
            {created.orders.map((o) => (
              <Anchor key={o.id} component={Link} to={`${PURCHASE_ORDER.route}/${o.id}`} fz="sm" fw={500}>
                {o.documentNumber ?? `draft #${o.id}`}
              </Anchor>
            ))}
            <Text fz="sm" c="dimmed">— the report now counts their quantities as incoming once they are confirmed.</Text>
          </Group>
        </Alert>
      )}

      {error && (
        <Alert color="red" mb="md">
          {error}
        </Alert>
      )}

      <Paper radius="lg" withBorder>
        <DataTable
          records={records}
          columns={columns}
          idAccessor="id"
          selectedRecords={ticked}
          onSelectedRecordsChange={setSelected}
          isRecordSelectable={(row) => canOrder && row.purchaseItemUnitId !== null}
          rowClassName={(row) => (row.shortageBase > 0 ? (row.onHandBase <= 0 ? 'app-grid__row--danger' : 'app-grid__row--warning') : undefined)}
          totalRecords={rows.length}
          page={page}
          recordsPerPage={pageSize}
          onPageChange={grid.setPage}
          onRecordsPerPageChange={grid.setPageSize}
          sortStatus={sortStatus}
          onSortStatusChange={grid.setSortStatus}
          fetching={loading}
          noRecordsText={filters.onlyShortages ? 'Nothing is short. Turn "Only shortages" off to see every item.' : 'No items match the filters.'}
        />
      </Paper>

      {ordering && (
        <CreatePurchaseOrdersModal opened={ordering} onClose={() => setOrdering(false)} rows={ticked} suppliers={suppliers} onCreated={ordersCreated} />
      )}
    </div>
  )
}
