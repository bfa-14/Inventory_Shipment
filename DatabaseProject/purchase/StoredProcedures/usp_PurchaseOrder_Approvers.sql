/* ================================================================== 6. Procedures of script 26, changed */

-- 6.1 Approvers from Settings > Purchase approval: of one order, or (NULL) every active approver.
CREATE   PROCEDURE purchase.usp_PurchaseOrder_Approvers
    @PurchaseDocumentId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT a.UserId, a.FullName, a.Email, a.CanApproveInApp, a.CanApproveByEmail
    FROM purchase.fn_PurchaseOrder_Approvers(@PurchaseDocumentId) a
    ORDER BY a.FullName;
END

GO

