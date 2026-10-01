CREATE   PROCEDURE purchase.usp_PurchaseOrder_CheckApprover
    @PurchaseDocumentId INT,
    @UserId             INT,
    @Channel            TINYINT
AS
BEGIN
    SET NOCOUNT ON;

    IF ISNULL((SELECT AllowSelfApproval FROM purchase.ApprovalSettings WHERE Id = 1), 1) = 0
       AND EXISTS (SELECT 1 FROM purchase.PurchaseDocuments d
                   WHERE d.Id = @PurchaseDocumentId
                     AND (   d.CreatedBy = @UserId
                          OR COALESCE((SELECT TOP (1) ev.UserId FROM purchase.PurchaseOrderApprovalEvents ev
                                       WHERE ev.PurchaseDocumentId = d.Id AND ev.EventType = 1
                                       ORDER BY ev.AtUtc DESC, ev.Id DESC), d.ApprovalRequestedBy) = @UserId))
        THROW 65023, 'You cannot approve an order that you created or sent for approval.', 1;

    IF @Channel = 2 AND NOT EXISTS (SELECT 1 FROM purchase.fn_PurchaseOrder_Approvers(@PurchaseDocumentId)
                                    WHERE UserId = @UserId AND CanApproveByEmail = 1)
        THROW 65017, 'You can no longer approve purchase orders by email.', 1;

    IF @Channel = 1 AND NOT EXISTS (SELECT 1 FROM purchase.fn_PurchaseOrder_Approvers(@PurchaseDocumentId)
                                    WHERE UserId = @UserId AND CanApproveInApp = 1)
        THROW 65017, 'You are not allowed to approve purchase orders in the app.', 1;
END

GO

