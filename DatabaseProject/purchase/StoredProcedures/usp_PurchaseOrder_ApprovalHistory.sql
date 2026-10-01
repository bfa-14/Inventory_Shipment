CREATE   PROCEDURE purchase.usp_PurchaseOrder_ApprovalHistory
    @PurchaseDocumentId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT e.Id, e.EventType,
           EventName = CASE e.EventType WHEN 1 THEN N'Sent for approval'       WHEN 2 THEN N'Reminder sent'
                                        WHEN 3 THEN N'Sent again'              WHEN 4 THEN N'Approved'
                                        WHEN 5 THEN N'Rejected'                WHEN 6 THEN N'Withdrawn'
                                        WHEN 7 THEN N'Posted without approval' WHEN 8 THEN N'Sent to the supplier'
                                        WHEN 9 THEN N'Not sent to the supplier' END,
           e.Channel, ChannelName = CASE e.Channel WHEN 1 THEN N'In the app' WHEN 2 THEN N'By email' END,
           e.UserId, UserName = u.FullName, e.Recipients, e.Reason, e.Note, e.AtUtc
    FROM purchase.PurchaseOrderApprovalEvents e
    LEFT JOIN security.Users u ON u.Id = e.UserId
    WHERE e.PurchaseDocumentId = @PurchaseDocumentId
    ORDER BY e.AtUtc, e.Id;
END

GO

