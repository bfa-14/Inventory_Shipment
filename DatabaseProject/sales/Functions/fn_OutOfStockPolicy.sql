/* -- the policy: warehouse override, else global, else off ------------------------------------ */
CREATE   FUNCTION sales.fn_OutOfStockPolicy (@WarehouseId INT)
RETURNS TABLE
AS
RETURN
(
    SELECT Allowed = CAST(ISNULL(w.AllowOutOfStockOverride, configuration.fn_SettingBool(N'Sales.AllowOutOfStock')) AS BIT),
           Source  = CAST(CASE WHEN w.AllowOutOfStockOverride IS NOT NULL THEN N'Warehouse' ELSE N'Global' END AS NVARCHAR(10))
    FROM masterdata.Warehouses w
    WHERE w.Id = @WarehouseId
);

GO

