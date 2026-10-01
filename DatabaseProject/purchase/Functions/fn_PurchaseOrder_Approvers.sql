-- without a right is not returned; with AllowSelfApproval = 0, neither the creator of the order nor the user who sent
-- it for approval (its latest event 1; for an order sent before script 42: the requester stored by script 26).
CREATE   FUNCTION purchase.fn_PurchaseOrder_Approvers (@PurchaseDocumentId INT)
RETURNS TABLE
AS
RETURN
(
    SELECT a.UserId, u.FullName, e.Email, a.CanApproveInApp,
           CanApproveByEmail = CAST(CASE WHEN a.CanApproveByEmail = 1 AND e.Email IS NOT NULL THEN 1 ELSE 0 END AS BIT)
    FROM purchase.OrderApprovers a
    INNER JOIN security.Users u ON u.Id = a.UserId AND u.IsActive = 1
    CROSS APPLY (SELECT Email = NULLIF(LTRIM(RTRIM(u.Email)), N'')) e
    LEFT  JOIN purchase.ApprovalSettings s ON s.Id = 1
    LEFT  JOIN purchase.PurchaseDocuments d ON d.Id = @PurchaseDocumentId
    OUTER APPLY (SELECT TOP (1) ev.UserId FROM purchase.PurchaseOrderApprovalEvents ev
                 WHERE ev.PurchaseDocumentId = d.Id AND ev.EventType = 1
                 ORDER BY ev.AtUtc DESC, ev.Id DESC) sent
    WHERE (a.CanApproveInApp = 1 OR (a.CanApproveByEmail = 1 AND e.Email IS NOT NULL))
      AND (ISNULL(s.AllowSelfApproval, 1) = 1
           OR (    a.UserId <> ISNULL(d.CreatedBy, 0)
               AND a.UserId <> ISNULL(COALESCE(sent.UserId, d.ApprovalRequestedBy), 0)))
);

GO

