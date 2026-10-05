/* ================================================================== 2. The state of the page */

-- One row (none for an unknown document). With @UserId the permissions (rule 9) are checked last: the first failing
-- rule is the reason. Turning the switch on is an edit of the invoice (purchase.invoices.create); linking needs that
-- permission, adding containers containers.create on top of it.
CREATE   PROCEDURE purchase.usp_PurchaseInvoice_ContainerState
    @Id     INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Edit BIT = 1, @Create BIT = 1;
    IF @UserId IS NOT NULL
        SELECT @Edit   = CASE WHEN EXISTS (SELECT 1 FROM security.fn_UserPermissions(@UserId) WHERE Code = N'purchase.invoices.create') THEN 1 ELSE 0 END,
               @Create = CASE WHEN EXISTS (SELECT 1 FROM security.fn_UserPermissions(@UserId) WHERE Code = N'containers.create') THEN 1 ELSE 0 END;
    DECLARE @NoEdit NVARCHAR(400) = N'This action needs the purchase.invoices.create permission.',
            @NoCreate NVARCHAR(400) = N'This action needs the containers.create permission.';

    SELECT s.InvoiceId, s.DocumentNumber, s.Status, s.ReceiptMode, s.OrderId, s.OrderNo, s.OrderStatus, s.ItemId,
           CanAddContainers = CAST(CASE WHEN s.CanAddContainers = 1 AND @Edit = 1 AND @Create = 1 THEN 1 ELSE 0 END AS BIT),
           Reason = COALESCE(s.Reason, CASE WHEN @Edit = 0 THEN @NoEdit WHEN @Create = 0 THEN @NoCreate END),
           FailedRule = COALESCE(s.FailedRule, CASE WHEN @Edit = 0 OR @Create = 0 THEN 9 END),
           CanTurnOnShipped = CAST(CASE WHEN s.CanTurnOnShipped = 1 AND @Edit = 1 THEN 1 ELSE 0 END AS BIT),
           s.NotInContainerQty, s.OrderLinesAvailableQty, s.MaxAddQty, s.PcsPerContainer,
           CanLink = CAST(CASE WHEN s.CanLink = 1 AND @Edit = 1 THEN 1 ELSE 0 END AS BIT),
           LinkReason = COALESCE(s.LinkReason, CASE WHEN @Edit = 0 THEN @NoEdit END),
           s.LinkableQty
    FROM purchase.fn_PurchaseInvoice_ContainerState(@Id) s;
END

GO

