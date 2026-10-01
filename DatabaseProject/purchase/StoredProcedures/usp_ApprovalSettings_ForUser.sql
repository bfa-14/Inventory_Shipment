CREATE   PROCEDURE purchase.usp_ApprovalSettings_ForUser
    @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT RequireApproval   = CAST(ISNULL(s.RequireApproval, 1) AS BIT),
           AllowSelfApproval = CAST(ISNULL(s.AllowSelfApproval, 1) AS BIT),
           ApprovalLimitBase = ISNULL(s.ApprovalLimitBase, 0),
           BaseCurrencyCode  = (SELECT TOP (1) CurrencyCode FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1),
           CanApproveInApp   = CAST(ISNULL(ap.CanApproveInApp, 0) AS BIT),
           CanApproveByEmail = CAST(ISNULL(ap.CanApproveByEmail, 0) AS BIT),
           PendingCount      = (SELECT COUNT(*)
                                FROM purchase.PurchaseDocuments d
                                INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId AND dt.Code = N'PO'
                                WHERE d.Status = 5
                                  AND EXISTS (SELECT 1 FROM purchase.fn_PurchaseOrder_Approvers(d.Id) a
                                              WHERE a.UserId = @UserId AND a.CanApproveInApp = 1))
    FROM (SELECT One = 1) one
    LEFT JOIN purchase.ApprovalSettings s ON s.Id = 1
    OUTER APPLY (SELECT TOP (1) a.CanApproveInApp, a.CanApproveByEmail
                 FROM purchase.fn_PurchaseOrder_Approvers(NULL) a WHERE a.UserId = @UserId) ap;
END

GO

