/* ================================================================== 2. The fill of a container */

-- One row per container (an empty one: 0 %, known). FillPct and IsOverCapacity only when every line's item has a
-- Container unit; RemainingPcs only for a container of one item. No aggregate ever meets a NULL: "Null value is
-- eliminated by an aggregate" would otherwise be appended to the message of a THROW in the same batch (Container_Save).
CREATE   FUNCTION logistics.fn_ContainerFill (@ContainerId INT)
RETURNS TABLE
AS
RETURN
WITH q AS
(
    SELECT cl.ItemId, i.ItemCode, Qty = SUM(cl.QuantityBase), Pcs = p.PcsPerContainer
    FROM logistics.ContainerLines cl
    INNER JOIN inventory.Items i ON i.Id = cl.ItemId
    CROSS APPLY logistics.fn_ItemPcsPerContainer(cl.ItemId) p
    WHERE cl.ContainerId = @ContainerId
    GROUP BY cl.ItemId, i.ItemCode, p.PcsPerContainer
)
SELECT FillFraction              = CAST(x.Fraction AS DECIMAL(19,6)),
       CapacityKnown             = CAST(CASE WHEN x.Missing = 0 THEN 1 ELSE 0 END AS BIT),
       MissingContainerUnitItems = (SELECT STRING_AGG(m.ItemCode, N', ') WITHIN GROUP (ORDER BY m.ItemCode) FROM q m WHERE m.Pcs IS NULL),
       FillPct                   = CAST(CASE WHEN x.Missing = 0 THEN ROUND(100 * x.Fraction, 2) END AS DECIMAL(9,2)),
       RemainingPcs              = CASE WHEN x.Missing = 0 AND x.ItemCount = 1 THEN x.FirstPcs - x.Qty END,
       IsOverCapacity            = CAST(CASE WHEN x.Missing = 0 AND x.Fraction > 1.000001 THEN 1 ELSE 0 END AS BIT)
FROM (SELECT Fraction  = ISNULL(SUM(CASE WHEN q.Pcs IS NOT NULL THEN CAST(q.Qty AS DECIMAL(38,20)) / q.Pcs ELSE 0 END), 0),
             Missing   = ISNULL(SUM(CASE WHEN q.Pcs IS NULL THEN 1 ELSE 0 END), 0),
             ItemCount = COUNT(*),
             Qty       = ISNULL(SUM(q.Qty), 0),
             FirstPcs  = MAX(ISNULL(q.Pcs, 0))
      FROM q) x;

GO

