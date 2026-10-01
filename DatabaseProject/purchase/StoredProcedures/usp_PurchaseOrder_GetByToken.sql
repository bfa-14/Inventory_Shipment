-- 65023 / 65017 when its approver may not decide, so the page shows the reason before any click.
CREATE   PROCEDURE purchase.usp_PurchaseOrder_GetByToken
    @Token VARCHAR(64)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ApprovalId INT, @DocumentId INT, @ApproverId INT;
    EXEC purchase.usp_PurchaseOrder_CheckToken @Token = @Token, @ApprovalId = @ApprovalId OUTPUT,
         @DocumentId = @DocumentId OUTPUT, @ApproverId = @ApproverId OUTPUT;

    SELECT a.Id AS ApprovalId, a.DocumentId, a.RequestNo, a.ApproverUserId, u.FullName AS ApproverName, a.ExpiresAtUtc,
           a.RequestedAtUtc, ru.FullName AS RequestedByName
    FROM purchase.PurchaseOrderApprovals a
    INNER JOIN security.Users u ON u.Id = a.ApproverUserId
    LEFT  JOIN security.Users ru ON ru.Id = a.RequestedBy
    WHERE a.Id = @ApprovalId;
END

GO

