/* ================================================================== 3. The check of every procedure of the path */

-- THROWs the first rule the invoice fails: Add (1-8: a new container of @QuantityBase pieces), Plan (1-7: a proposal),
-- Link (1-6: containers already on the order).
CREATE   PROCEDURE purchase.usp_PurchaseInvoice_CheckContainers
    @InvoiceId    INT,
    @Action       NVARCHAR(10) = N'Add',
    @QuantityBase INT          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Found BIT = 0, @Rule TINYINT, @Reason NVARCHAR(400), @NotIn INT, @Allowed INT, @Max INT;
    SELECT @Found = 1, @Rule = FailedRule, @Reason = Reason, @NotIn = NotInContainerQty, @Allowed = OrderLinesAvailableQty,
           @Max = MaxAddQty
    FROM purchase.fn_PurchaseInvoice_ContainerState(@InvoiceId);

    IF @Found = 0 THROW 65006, 'Document not found.', 1;
    IF @Rule IS NOT NULL AND @Rule <= CASE @Action WHEN N'Link' THEN 6 ELSE 7 END THROW 65030, @Reason, 1;
    IF @Action = N'Add' AND @QuantityBase > @Max
    BEGIN
        DECLARE @Msg NVARCHAR(400) = CAST(@QuantityBase AS NVARCHAR(12)) + N' pieces asked. At most '
            + CAST(@Max AS NVARCHAR(12)) + N' pcs: ' + CAST(@NotIn AS NVARCHAR(12)) + N' not in a container on this invoice, the order allows '
            + CAST(@Allowed AS NVARCHAR(12)) + N' more.';
        THROW 65031, @Msg, 1;
    END
END

GO

