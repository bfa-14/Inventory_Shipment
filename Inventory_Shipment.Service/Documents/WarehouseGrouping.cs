namespace Inventory_Shipment.Service.Documents;

/// <summary>
/// One document = one warehouse, applied to an imported file: the rows are sorted into one group per
/// warehouse, and each group becomes a document.
///
/// FIRST-SEEN ORDER, INSIDE AND OUT. The groups come out in the order their warehouses first appear
/// in the file, and the lines inside a group keep the file's order — so the documents read the way
/// the spreadsheet did, and "row 12" is still the twelfth row somebody can find.
/// </summary>
public static class WarehouseGrouping
{
    public static IReadOnlyList<(int WarehouseId, IReadOnlyList<TLine> Lines)> GroupLinesByWarehouse<TLine>(
        IEnumerable<TLine> lines, Func<TLine, int> warehouseOf)
    {
        var order = new List<int>();
        var groups = new Dictionary<int, List<TLine>>();

        foreach (var line in lines)
        {
            var warehouseId = warehouseOf(line);
            if (!groups.TryGetValue(warehouseId, out var group))
            {
                group = [];
                groups.Add(warehouseId, group);
                order.Add(warehouseId);
            }

            group.Add(line);
        }

        return order.Select(id => (id, (IReadOnlyList<TLine>)groups[id])).ToList();
    }
}
