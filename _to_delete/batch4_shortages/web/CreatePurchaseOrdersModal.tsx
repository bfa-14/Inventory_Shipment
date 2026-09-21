import { useMemo, useState } from 'react'
import { Link } from 'react-router'
import { Alert, Anchor, Badge, Button, Group, Modal, NumberInput, Select, Stack, Table, Text } from '@mantine/core'
import { DateInput } from '@mantine/dates'
import { IconCheck, IconShoppingCart } from '@tabler/icons-react'
import { ApiError } from '../../api/http'
import { shortagesApi, type CreatePurchaseOrdersResult, type ShortageRowDto } from '../../api/inventory/shortages'
import type { PartyLookupDto } from '../../api/types'
import { fromIsoDate, isoDate, unitLabel } from '../../components/documents/documentKind'
import { formatMoney, formatNumber } from '../../components/format'
import { PURCHASE_ORDER, supplierLabel } from '../../components/purchase/purchaseKind'
import { notify } from '../../components/ui/notify'

interface CreatePurchaseOrdersModalProps {
  opened: boolean
  onClose: () => void
  /** The ticked report rows. */
  rows: ShortageRowDto[]
  suppliers: PartyLookupDto[]
  /** After the reader has seen the result: the page reloads the report and says what was made. */
  onCreated: (result: CreatePurchaseOrdersResult) => void
}

/** One row of the modal: the report row and what the reader decided for it. */
interface OrderLine {
  key: string
  row: ShortageRowDto
  quantity: number
  supplierId: string | null
}

/**
 * Turns the ticked shortage rows into purchase orders.
 *
 * THE GROUPING IS SHOWN BEFORE ANYTHING IS MADE. One order per supplier and warehouse is the rule,
 * and a reader who ticked six rows deserves to know they are about to get three orders, not one —
 * the preview names each, with its line count, and updates as suppliers are changed.
 *
 * THE QUANTITY IS THE SUGGESTION, EDITABLE. The report's suggested quantity brings the warehouse
 * back to its maximum in whole purchase units; the buyer may know better (a pallet, a minimum order)
 * and types over it.
 */
export function CreatePurchaseOrdersModal({ opened, onClose, rows, suppliers, onCreated }: CreatePurchaseOrdersModalProps) {
  return (
    <Modal opened={opened} onClose={onClose} title={`Create Purchase Order (${formatNumber(rows.length)})`} size="xl" centered>
      <OrderForm rows={rows} suppliers={suppliers} onClose={onClose} onCreated={onCreated} />
    </Modal>
  )
}

function OrderForm({ rows, suppliers, onClose, onCreated }: Omit<CreatePurchaseOrdersModalProps, 'opened'>) {
  const [lines, setLines] = useState<OrderLine[]>(() =>
    rows.map((row) => ({
      key: `${row.itemId}:${row.warehouseId}`,
      row,
      quantity: row.suggestedQty > 0 ? row.suggestedQty : 1,
      supplierId: row.supplierId === null ? null : String(row.supplierId),
    })),
  )
  const [orderDate, setOrderDate] = useState(isoDate(new Date()))
  const [expectedDate, setExpectedDate] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [result, setResult] = useState<CreatePurchaseOrdersResult | null>(null)

  const supplierOptions = suppliers.map((s) => ({ value: String(s.id), label: supplierLabel(s) }))

  const groups = useMemo(() => {
    const map = new Map<string, { supplier: string; warehouse: string; count: number }>()
    for (const line of lines) {
      if (line.supplierId === null) continue
      const key = `${line.supplierId}|${line.row.warehouseId}`
      const supplier = suppliers.find((s) => String(s.id) === line.supplierId)
      const entry = map.get(key) ?? { supplier: supplier ? supplierLabel(supplier) : `Supplier ${line.supplierId}`, warehouse: `${line.row.warehouseCode} - ${line.row.warehouseName}`, count: 0 }
      entry.count += 1
      map.set(key, entry)
    }
    return [...map.values()]
  }, [lines, suppliers])

  const missingSupplier = lines.filter((l) => l.supplierId === null).length
  const badQuantity = lines.filter((l) => l.quantity < 1 || l.row.purchaseItemUnitId === null).length
  const ready = lines.length > 0 && missingSupplier === 0 && badQuantity === 0 && orderDate !== ''

  const patch = (key: string, change: Partial<OrderLine>) => setLines((current) => current.map((l) => (l.key === key ? { ...l, ...change } : l)))

  async function create() {
    setBusy(true)
    try {
      const answer = await shortagesApi.createOrders({
        documentDate: orderDate,
        expectedDate,
        lines: lines.map((l) => ({
          itemId: l.row.itemId,
          warehouseId: l.row.warehouseId,
          supplierId: Number(l.supplierId),
          itemUnitId: l.row.purchaseItemUnitId as number,
          quantity: l.quantity,
        })),
      })
      setResult(answer)
    } catch (error) {
      notify.error(error instanceof ApiError ? error.message : 'The purchase orders could not be created.')
    } finally {
      setBusy(false)
    }
  }

  if (result) {
    return (
      <Stack data-orders-result>
        <Alert color={result.failed.length === 0 ? 'green' : 'orange'} icon={<IconCheck size={18} />} title={`${formatNumber(result.created)} purchase order(s) created`}>
          Each is a draft: open it to check the lines and confirm it.
        </Alert>

        <Stack gap="xs">
          {result.orders.map((order) => (
            <Group key={order.id} justify="space-between" wrap="nowrap">
              <div>
                <Anchor component={Link} to={`${PURCHASE_ORDER.route}/${order.id}`} fw={500}>
                  {order.documentNumber ?? `draft #${order.id}`}
                </Anchor>
                <Text fz="xs" c="dimmed">
                  {order.supplierName} · {order.warehouseName} · {formatNumber(order.lineCount)} line(s)
                </Text>
              </div>
              <Text fz="sm" fw={500} style={{ whiteSpace: 'nowrap' }}>
                {formatMoney(order.totalAmount, order.currencyCode)}
              </Text>
            </Group>
          ))}
        </Stack>

        {result.failed.length > 0 && (
          <Alert color="red" title={`${formatNumber(result.failed.length)} group(s) refused`}>
            <Stack gap={4}>
              {result.failed.map((f, i) => (
                <Text key={i} fz="sm">
                  Supplier {f.supplierId}, warehouse {f.warehouseId}: {f.message}
                </Text>
              ))}
            </Stack>
          </Alert>
        )}

        <Group justify="flex-end">
          <Button onClick={() => onCreated(result)}>Done</Button>
        </Group>
      </Stack>
    )
  }

  return (
    <Stack>
      <Group grow align="flex-start">
        <DateInput label="Order date" withAsterisk value={fromIsoDate(orderDate)} maxDate={new Date()} valueFormat="DD/MM/YYYY" onChange={(next) => setOrderDate(next ? isoDate(new Date(next)) : '')} />
        <DateInput label="Expected date" placeholder="Optional" value={fromIsoDate(expectedDate)} valueFormat="DD/MM/YYYY" clearable onChange={(next) => setExpectedDate(next ? isoDate(new Date(next)) : null)} />
      </Group>

      <Table.ScrollContainer minWidth={760}>
        <Table verticalSpacing="xs" striped>
          <Table.Thead>
            <Table.Tr>
              <Table.Th>Item</Table.Th>
              <Table.Th>Warehouse</Table.Th>
              <Table.Th ta="right">Available</Table.Th>
              <Table.Th ta="right">Min / Max</Table.Th>
              <Table.Th w={150}>Quantity</Table.Th>
              <Table.Th w={260}>Supplier</Table.Th>
            </Table.Tr>
          </Table.Thead>
          <Table.Tbody>
            {lines.map((line) => (
              <Table.Tr key={line.key}>
                <Table.Td>
                  <Text fz="sm" fw={500}>{line.row.itemCode}</Text>
                  <Text fz="xs" c="dimmed">{line.row.itemName}</Text>
                </Table.Td>
                <Table.Td>
                  <Text fz="sm">{line.row.warehouseCode}</Text>
                  <Text fz="xs" c="dimmed">{line.row.branchName}</Text>
                </Table.Td>
                <Table.Td ta="right">
                  <Text fz="sm" c={line.row.availableBase < line.row.minQuantity ? 'red' : undefined}>{formatNumber(line.row.availableBase)}</Text>
                </Table.Td>
                <Table.Td ta="right">
                  <Text fz="sm">{formatNumber(line.row.minQuantity)} / {line.row.maxQuantity === null ? '—' : formatNumber(line.row.maxQuantity)}</Text>
                </Table.Td>
                <Table.Td>
                  <NumberInput
                    value={line.quantity}
                    min={1}
                    step={1}
                    allowDecimal={false}
                    allowNegative={false}
                    thousandSeparator=","
                    onChange={(next) => patch(line.key, { quantity: typeof next === 'number' ? next : Number(next) || 0 })}
                    rightSection={<Text fz="xs" c="dimmed" pr="sm" style={{ whiteSpace: 'nowrap' }}>{line.row.purchaseUnitName ? unitLabel(line.row.purchaseUnitName, line.row.purchasePackingFormula ?? 1) : ''}</Text>}
                    rightSectionWidth={line.row.purchasePackingFormula && line.row.purchasePackingFormula > 1 ? 90 : 56}
                    error={line.row.purchaseItemUnitId === null ? 'No unit' : undefined}
                    aria-label={`Quantity of ${line.row.itemCode}`}
                  />
                </Table.Td>
                <Table.Td>
                  <Select
                    data={supplierOptions}
                    value={line.supplierId}
                    placeholder="Choose a supplier"
                    onChange={(next) => patch(line.key, { supplierId: next })}
                    searchable
                    error={line.supplierId === null ? 'Required' : undefined}
                    comboboxProps={{ withinPortal: true }}
                    aria-label={`Supplier of ${line.row.itemCode}`}
                  />
                </Table.Td>
              </Table.Tr>
            ))}
          </Table.Tbody>
        </Table>
      </Table.ScrollContainer>

      <Alert color="blue" variant="light" icon={<IconShoppingCart size={18} />} title={`${formatNumber(groups.length)} purchase order(s) will be created`} data-grouping-preview>
        <Stack gap={2}>
          {groups.map((g, i) => (
            <Group key={i} gap="xs" wrap="nowrap">
              <Badge variant="light" color="blue">{formatNumber(g.count)} line(s)</Badge>
              <Text fz="sm">{g.supplier} → {g.warehouse}</Text>
            </Group>
          ))}
          {missingSupplier > 0 && (
            <Text fz="sm" c="red">
              {formatNumber(missingSupplier)} line(s) have no supplier yet.
            </Text>
          )}
        </Stack>
      </Alert>

      <Group justify="flex-end">
        <Button variant="default" onClick={onClose} disabled={busy}>
          Cancel
        </Button>
        <Button leftSection={<IconShoppingCart size={16} />} disabled={!ready} loading={busy} onClick={() => void create()}>
          Create
        </Button>
      </Group>
    </Stack>
  )
}
