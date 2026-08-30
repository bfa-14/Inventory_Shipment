namespace Inventory_Shipment.Model.Common;

public static class DateTimeExtensions
{
    /// <summary>
    /// SQL Server DATETIME2 values come back with Kind = Unspecified. All timestamps in this
    /// system are UTC, so mark them as such before they are serialized (adds the trailing "Z").
    /// </summary>
    public static DateTime AsUtc(this DateTime value)
        => value.Kind == DateTimeKind.Utc ? value : DateTime.SpecifyKind(value, DateTimeKind.Utc);

    public static DateTime? AsUtc(this DateTime? value) => value?.AsUtc();
}
