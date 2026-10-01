CREATE   PROCEDURE purchase.usp_PurchaseOrder_PendingForUser
    @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT d.Id,
           Reference = ISNULL(d.DocumentNumber, N'draft #' + CAST(d.Id AS NVARCHAR(10))),
           d.SupplierId, SupplierName = sp.PartyName, OrderDate = d.DocumentDate, c.CurrencyCode,
           Total = d.TotalAmount, TotalBase = d.TotalAmountBase,
           LineCount = (SELECT COUNT(*) FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = d.Id),
           RequestedByName = ru.FullName, RequestedAtUtc = rq.AtUtc,
           WaitingHours = DATEDIFF(MINUTE, rq.AtUtc, SYSUTCDATETIME()) / 60,
           d.RowVersion
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId AND dt.Code = N'PO'
    INNER JOIN masterdata.Parties sp      ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    OUTER APPLY (SELECT TOP (1) e.UserId, e.AtUtc FROM purchase.PurchaseOrderApprovalEvents e
                 WHERE e.PurchaseDocumentId = d.Id AND e.EventType = 1 ORDER BY e.AtUtc DESC, e.Id DESC) e1
    CROSS APPLY (SELECT UserId = COALESCE(e1.UserId, d.ApprovalRequestedBy),
                        AtUtc = COALESCE(CAST(e1.AtUtc AS DATETIME2(3)), d.ApprovalRequestedAtUtc)) rq
    LEFT  JOIN security.Users ru ON ru.Id = rq.UserId
    WHERE d.Status = 5
      AND EXISTS (SELECT 1 FROM purchase.fn_PurchaseOrder_Approvers(d.Id) a WHERE a.UserId = @UserId AND a.CanApproveInApp = 1)
    ORDER BY rq.AtUtc, d.Id;
END

GO

