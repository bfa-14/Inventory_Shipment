/* The same for a container charge: only a POSTED charge owes anything. */
CREATE   FUNCTION logistics.fn_ContainerChargeSettlement (@ChargeId INT)
RETURNS TABLE
AS
RETURN
(
    SELECT p.PaidAmount,
           OutstandingAmount = CASE WHEN c.Status = 2 THEN c.Amount - p.PaidAmount END,
           PaymentStatus     = CASE WHEN c.Status <> 2 THEN NULL
                                    WHEN c.Amount - p.PaidAmount <= 0.005 THEN N'Paid'
                                    WHEN p.PaidAmount <= 0 THEN N'Unpaid'
                                    ELSE N'Partial' END
    FROM logistics.ContainerCharges c
    CROSS APPLY (SELECT PaidAmount = ISNULL((SELECT SUM(a.AmountDocCurrency)
                                             FROM purchase.PaymentAllocations a
                                             INNER JOIN purchase.Payments pay ON pay.Id = a.PaymentId
                                             WHERE a.ContainerChargeId = c.Id AND a.RemovedAtUtc IS NULL AND pay.Status = 2), 0)) p
    WHERE c.Id = @ChargeId
);

GO

