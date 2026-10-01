CREATE   PROCEDURE purchase.usp_PurchaseOrder_ApprovalState
    @PurchaseDocumentId INT,
    @UserId             INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TypeCode NVARCHAR(20) = (SELECT dt.Code FROM purchase.PurchaseDocuments d
                                      INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                                      WHERE d.Id = @PurchaseDocumentId);
    IF @TypeCode IS NULL THROW 65006, 'Document not found.', 1;
    IF @TypeCode <> N'PO' THROW 65010, 'Only purchase orders go through approval.', 1;

    DECLARE @NeedsApproval BIT = purchase.fn_PurchaseOrder_NeedsApproval(@PurchaseDocumentId);
    DECLARE @InAppApprover BIT = CASE WHEN EXISTS (SELECT 1 FROM purchase.fn_PurchaseOrder_Approvers(@PurchaseDocumentId)
                                                   WHERE UserId = @UserId AND CanApproveInApp = 1) THEN 1 ELSE 0 END;

    SELECT d.Status,
           NeedsApproval       = @NeedsApproval,
           RequireApproval     = CAST(ISNULL(s.RequireApproval, 1) AS BIT),
           ApprovalLimitBase   = ISNULL(s.ApprovalLimitBase, 0),
           BaseCurrencyCode    = bc.CurrencyCode,
           TotalBase           = d.TotalAmountBase,
           AllowSelfApproval   = CAST(ISNULL(s.AllowSelfApproval, 1) AS BIT),
           UserCanApproveInApp = @InAppApprover,
           CanApproveDirect    = CAST(CASE WHEN d.Status = 1 AND @NeedsApproval = 1 AND ISNULL(s.AllowSelfApproval, 1) = 1
                                                AND @InAppApprover = 1 THEN 1 ELSE 0 END AS BIT),
           RequestedBy         = CASE WHEN d.Status = 5 THEN rq.UserId END,
           RequestedByName     = CASE WHEN d.Status = 5 THEN ru.FullName END,
           RequestedAtUtc      = CASE WHEN d.Status = 5 THEN rq.AtUtc END,
           LinksValidUntilUtc  = CASE WHEN d.Status = 5 THEN lk.ValidUntilUtc END,
           NextReminderAtUtc   = CASE WHEN d.Status = 5 AND s.ReminderHours > 0 THEN DATEADD(HOUR, s.ReminderHours, ls.LastSentUtc) END,
           LastRejectedByName  = CASE WHEN d.Status = 1 AND d.RejectedAtUtc IS NOT NULL THEN rju.FullName END,
           LastRejectedAtUtc   = CASE WHEN d.Status = 1 THEN d.RejectedAtUtc END,
           LastRejectReason    = CASE WHEN d.Status = 1 AND d.RejectedAtUtc IS NOT NULL THEN COALESCE(rj.Reason, d.RejectReason) END,
           SupplierEmail       = NULLIF(LTRIM(RTRIM(sp.Email)), N''),
           SentToSupplierAtUtc = se.SentAtUtc,
           SupplierNotEmailed  = CAST(CASE WHEN ne.AtUtc IS NOT NULL
                                                AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseOrderApprovalEvents x
                                                                WHERE x.PurchaseDocumentId = d.Id AND x.EventType = 8 AND x.AtUtc >= ne.AtUtc)
                                           THEN 1 ELSE 0 END AS BIT)
    FROM purchase.PurchaseDocuments d
    INNER JOIN masterdata.Parties sp ON sp.Id = d.SupplierId
    LEFT  JOIN purchase.ApprovalSettings s ON s.Id = 1
    LEFT  JOIN masterdata.Currencies bc ON bc.IsBaseCurrency = 1 AND bc.IsActive = 1
    OUTER APPLY (SELECT TOP (1) e.UserId, e.AtUtc FROM purchase.PurchaseOrderApprovalEvents e
                 WHERE e.PurchaseDocumentId = d.Id AND e.EventType = 1 ORDER BY e.AtUtc DESC, e.Id DESC) e1
    CROSS APPLY (SELECT UserId = COALESCE(e1.UserId, d.ApprovalRequestedBy),
                        AtUtc = COALESCE(CAST(e1.AtUtc AS DATETIME2(3)), d.ApprovalRequestedAtUtc)) rq
    LEFT  JOIN security.Users ru  ON ru.Id = rq.UserId
    LEFT  JOIN security.Users rju ON rju.Id = d.RejectedBy
    OUTER APPLY (SELECT ValidUntilUtc = MAX(a.ExpiresAtUtc) FROM purchase.PurchaseOrderApprovals a
                 WHERE a.DocumentId = d.Id AND a.Status = 1) lk
    OUTER APPLY (SELECT LastSentUtc = COALESCE(MAX(CAST(e.AtUtc AS DATETIME2(3))), d.ApprovalRequestedAtUtc)
                 FROM purchase.PurchaseOrderApprovalEvents e
                 WHERE e.PurchaseDocumentId = d.Id AND e.EventType IN (1, 2, 3)) ls
    OUTER APPLY (SELECT TOP (1) e.Reason FROM purchase.PurchaseOrderApprovalEvents e
                 WHERE e.PurchaseDocumentId = d.Id AND e.EventType = 5 ORDER BY e.AtUtc DESC, e.Id DESC) rj
    OUTER APPLY (SELECT SentAtUtc = MAX(e.AtUtc) FROM purchase.PurchaseOrderApprovalEvents e
                 WHERE e.PurchaseDocumentId = d.Id AND e.EventType = 8) se
    OUTER APPLY (SELECT AtUtc = MAX(e.AtUtc) FROM purchase.PurchaseOrderApprovalEvents e
                 WHERE e.PurchaseDocumentId = d.Id AND e.EventType = 9
                   AND e.AtUtc >= CAST(d.ApprovedAtUtc AS DATETIME2(0))) ne
    WHERE d.Id = @PurchaseDocumentId;

    SELECT a.UserId, a.FullName, a.Email, a.CanApproveInApp, a.CanApproveByEmail,
           LinkExpiresAtUtc = (SELECT MAX(p.ExpiresAtUtc) FROM purchase.PurchaseOrderApprovals p
                               WHERE p.DocumentId = @PurchaseDocumentId AND p.ApproverUserId = a.UserId AND p.Status = 1)
    FROM purchase.fn_PurchaseOrder_Approvers(@PurchaseDocumentId) a
    ORDER BY a.FullName;
END

GO

