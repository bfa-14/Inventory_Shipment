/* ================================================================== 1. fn_ContainerCharge_StockShare */

-- WHAT A CHARGE DOES TO THE COST OF GOODS ALREADY RECEIVED, line by line (@Sign 1 = it enters, -1 = it leaves): Delta =
-- the line's share of the charge (its allocation), Inv = the part of it that goes to the stock the company still holds,
-- the rest (Delta - Inv) to cost of sales. Per item of the container: Received = the pieces its lines brought,
-- CompanyOnHand = the item's stock in every warehouse (89: was the receiving warehouse's), Remaining = the smaller of the
-- two, never below 0; Inv = Delta x Remaining / Received rounded to the cent, 0 when nothing is held or nothing came.
-- Moved here (118) unchanged from usp_ContainerCharge_ApplyCost (89), with the same types, so both give the same cents.
-- The cancel's caps (89, 102) are applied by ApplyCost on top; a preview of a post needs none.
CREATE   FUNCTION logistics.fn_ContainerCharge_StockShare (@ChargeId INT, @Sign SMALLINT)
RETURNS TABLE
AS
RETURN
    SELECT LineId = cl.Id, cl.ItemId,
           Delta = CAST(@Sign * a.AmountBase AS DECIMAL(18,2)),
           Inv = CAST(CASE WHEN q.CompanyOnHand <= 0 OR q.Received <= 0 THEN 0
                           ELSE ROUND(CAST(@Sign * a.AmountBase AS DECIMAL(18,2)) * q.Remaining / q.Received, 2) END AS DECIMAL(18,2)),
           q.Received, q.Remaining, q.CompanyOnHand
    FROM logistics.ContainerChargeAllocations a
    INNER JOIN logistics.ContainerLines cl ON cl.Id = a.ContainerLineId
    CROSS APPLY (SELECT Received = SUM(ISNULL(x.ReceivedQuantityBase, 0))
                 FROM logistics.ContainerLines x
                 WHERE x.ContainerId = cl.ContainerId AND x.ItemId = cl.ItemId) r
    CROSS APPLY (SELECT Q = inventory.fn_StockOnHand(cl.ItemId, NULL)) oh               -- NULL: every warehouse
    CROSS APPLY (SELECT Received      = CAST(r.Received AS DECIMAL(18,6)),
                        Remaining     = CAST(CASE WHEN oh.Q < r.Received THEN CASE WHEN oh.Q > 0 THEN oh.Q ELSE 0 END
                                                  ELSE r.Received END AS DECIMAL(18,6)),
                        CompanyOnHand = CAST(oh.Q AS DECIMAL(18,6))) q
    WHERE a.ChargeId = @ChargeId AND a.AmountBase <> 0;

GO

