CREATE   FUNCTION logistics.fn_ContainerChargeSettlement (@ChargeId INT)
RETURNS TABLE
AS
RETURN
(
    SELECT p.PaidAmount,
           -- (102) a deduction is not paid: nothing outstanding, and its own status
           OutstandingAmount = CASE WHEN c.Status = 2 THEN CASE WHEN c.Amount < 0 THEN 0 ELSE c.Amount - p.PaidAmount END END,
           PaymentStatus     = CASE WHEN c.Status <> 2 THEN NULL
                                    WHEN c.Amount < 0 THEN N'Deduction'
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

