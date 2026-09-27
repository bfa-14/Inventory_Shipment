CREATE   PROCEDURE purchase.usp_PurchaseOrder_GetByToken
    @Token VARCHAR(64)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Raw VARBINARY(32) = CASE WHEN LEN(@Token) = 64 THEN TRY_CONVERT(VARBINARY(32), @Token, 2) END;
    IF @Raw IS NULL THROW 65014, 'This approval link is not valid.', 1;

    DECLARE @ApprovalId INT, @DocumentId INT, @Status TINYINT, @Expires DATETIME2(3), @DocStatus TINYINT;
    SELECT @ApprovalId = a.Id, @DocumentId = a.DocumentId, @Status = a.Status, @Expires = a.ExpiresAtUtc, @DocStatus = d.Status
    FROM purchase.PurchaseOrderApprovals a
    INNER JOIN purchase.PurchaseDocuments d ON d.Id = a.DocumentId
    WHERE a.TokenHash = HASHBYTES('SHA2_256', @Raw);

    IF @ApprovalId IS NULL THROW 65014, 'This approval link is not valid.', 1;
    IF @Status <> 1 THROW 65014, 'This approval link was already used, or the order was decided by another approver.', 1;
    IF @Expires < SYSUTCDATETIME() THROW 65014, 'This approval link has expired. Ask for the purchase order to be sent for approval again.', 1;
    IF @DocStatus <> 5 THROW 65014, 'This purchase order is no longer waiting for approval.', 1;

    SELECT a.Id AS ApprovalId, a.DocumentId, a.RequestNo, a.ApproverUserId, u.FullName AS ApproverName, a.ExpiresAtUtc,
           a.RequestedAtUtc, ru.FullName AS RequestedByName
    FROM purchase.PurchaseOrderApprovals a
    INNER JOIN security.Users u ON u.Id = a.ApproverUserId
    LEFT  JOIN security.Users ru ON ru.Id = a.RequestedBy
    WHERE a.Id = @ApprovalId;
END

GO

