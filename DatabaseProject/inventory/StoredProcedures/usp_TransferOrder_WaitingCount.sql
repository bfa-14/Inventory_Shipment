/* 13.14 THE APPROVERS' MENU COUNT: the orders waiting for approval (the API answers 0 to a reader without Approve
   Transfer Orders). Transfer orders are not limited by user yet, so every approver sees the same count; @UserId is
   kept for when they are (script 92). */
CREATE   PROCEDURE inventory.usp_TransferOrder_WaitingCount
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT WaitingForApproval = COUNT(*) FROM inventory.TransferOrders WHERE Status = 4;
END

GO

