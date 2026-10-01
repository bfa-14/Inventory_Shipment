/* ================================================================== 5. Helpers */

-- 1 when the purchase order must be approved before it is posted. No settings row = 1 (as in script 26).
CREATE   FUNCTION purchase.fn_PurchaseOrder_NeedsApproval (@PurchaseDocumentId INT)
RETURNS BIT
AS
BEGIN
    DECLARE @Require BIT, @Limit DECIMAL(19, 4), @Total DECIMAL(19, 4);
    SELECT @Require = RequireApproval, @Limit = ApprovalLimitBase FROM purchase.ApprovalSettings WHERE Id = 1;

    IF @Require IS NULL RETURN 1;
    IF @Require = 0 RETURN 0;
    IF @Limit = 0 RETURN 1;

    SELECT @Total = TotalAmountBase FROM purchase.PurchaseDocuments WHERE Id = @PurchaseDocumentId;
    RETURN CASE WHEN @Total IS NULL OR @Total > @Limit THEN 1 ELSE 0 END;
END

GO

