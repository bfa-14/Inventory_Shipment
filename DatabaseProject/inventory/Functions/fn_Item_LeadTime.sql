CREATE   FUNCTION inventory.fn_Item_LeadTime (@ItemId INT, @PlanMonths DECIMAL(6,2))
RETURNS TABLE
AS
RETURN
SELECT LeadTimeMonths = CAST(COALESCE(h.Months, NULLIF(i.LeadTimeMonths, 0), @PlanMonths) AS DECIMAL(6,2)),
       Source = CAST(CASE WHEN h.Months IS NOT NULL THEN N'History' WHEN NULLIF(i.LeadTimeMonths, 0) IS NOT NULL THEN N'Item' ELSE N'Plan' END AS NVARCHAR(10)),
       HistoryMonths = h.Months, Receipts = h.Receipts
FROM inventory.Items i
OUTER APPLY inventory.fn_Item_LeadTimeHistory(i.Id) h
WHERE i.Id = @ItemId;

GO

