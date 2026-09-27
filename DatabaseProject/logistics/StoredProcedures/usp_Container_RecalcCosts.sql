-- FOB + charges / quantity received.
CREATE   PROCEDURE logistics.usp_Container_RecalcCosts
    @ContainerId INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE cl
    SET ChargesBase = ISNULL(x.Charges, 0),
        LandedCostBase = CASE WHEN cl.FobCostBase IS NULL THEN NULL
                              WHEN ISNULL(cl.ReceivedQuantityBase, 0) > 0 THEN cl.FobCostBase + ISNULL(x.Charges, 0) / cl.ReceivedQuantityBase
                              ELSE cl.FobCostBase END
    FROM logistics.ContainerLines cl
    OUTER APPLY (SELECT Charges = SUM(a.AmountBase)
                 FROM logistics.ContainerChargeAllocations a
                 INNER JOIN logistics.ContainerCharges ch ON ch.Id = a.ChargeId
                 WHERE a.ContainerLineId = cl.Id AND ch.Status = 2 AND ch.IncludeInLandedCost = 1) x
    WHERE cl.ContainerId = @ContainerId;
END

GO

