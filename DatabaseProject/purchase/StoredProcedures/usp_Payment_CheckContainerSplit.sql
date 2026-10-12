
/* ================================================================== 3. The split rules, in one place */

/* THE CONTAINER SPLIT OF THE INVOICE ALLOCATIONS, judged in one place for Save, Post and Allocate. THROWs
   the first problem, naming the invoice and the container.
     - an invoice with containers: its amount is split over its containers (and "Unlinked items" when some
       of its lines are in no container); @RequireBalanced = 1 (post, allocate) demands the split, and that
       it adds up to the invoice amount;
     - an invoice without containers is allocated as before: no split;
     - a container amount is never negative, never above what that container still owes. */
CREATE   PROCEDURE purchase.usp_Payment_CheckContainerSplit
    @Allocations     purchase.tvp_PaymentAllocation READONLY,
    @Containers      purchase.tvp_PaymentAllocationContainer READONLY,
    @RequireBalanced BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Msg NVARCHAR(400);

    SELECT TOP (1) @Msg = N'Purchase invoice ' + ISNULL(d.DocumentNumber, N'#' + CAST(c.DocumentId AS NVARCHAR(10))) + N': '
                          + CASE WHEN a.DocumentId IS NULL THEN N'a container amount was given, but the invoice is not allocated.'
                                 WHEN c.Amount < 0 THEN N'a container amount cannot be negative.'
                                 WHEN s.ContainerKey IS NULL AND c.ContainerId = 0 THEN N'every line of this invoice is in a container: there are no unlinked items.'
                                 WHEN s.ContainerKey IS NULL THEN N'container #' + CAST(c.ContainerId AS NVARCHAR(10)) + N' is not one of its containers.'
                                 ELSE N'it has no containers: allocate it directly, without a container split.' END
    FROM @Containers c
    LEFT JOIN @Allocations a ON a.DocumentKind = N'PINV' AND a.DocumentId = c.DocumentId
    LEFT JOIN purchase.PurchaseDocuments d ON d.Id = c.DocumentId
    OUTER APPLY (SELECT TOP (1) HasContainers FROM purchase.fn_InvoiceContainerSettlement(c.DocumentId)) h
    OUTER APPLY (SELECT ContainerKey FROM purchase.fn_InvoiceContainerSettlement(c.DocumentId) WHERE ContainerKey = c.ContainerId) s
    WHERE a.DocumentId IS NULL OR c.Amount < 0 OR s.ContainerKey IS NULL OR ISNULL(h.HasContainers, 0) = 0
    ORDER BY c.DocumentId, c.ContainerId;
    IF @Msg IS NOT NULL THROW 73000, @Msg, 1;

    SELECT TOP (1) @Msg = N'Purchase invoice ' + d.DocumentNumber + N', ' + s.ContainerRef + N': '
                          + FORMAT(c.Amount, N'N2', N'en-US') + N' is more than its outstanding '
                          + FORMAT(s.OutstandingAmount, N'N2', N'en-US') + N' ' + cu.CurrencyCode + N'.'
    FROM @Containers c
    INNER JOIN purchase.PurchaseDocuments d ON d.Id = c.DocumentId
    INNER JOIN masterdata.Currencies cu ON cu.Id = d.CurrencyId
    CROSS APPLY (SELECT ContainerRef, OutstandingAmount FROM purchase.fn_InvoiceContainerSettlement(c.DocumentId) WHERE ContainerKey = c.ContainerId) s
    WHERE c.Amount > s.OutstandingAmount + 0.005
    ORDER BY c.DocumentId, c.ContainerId;
    IF @Msg IS NOT NULL THROW 73009, @Msg, 1;

    IF @RequireBalanced = 1
    BEGIN
        SELECT TOP (1) @Msg = N'Purchase invoice ' + d.DocumentNumber + N': the container amounts ('
                              + FORMAT(ISNULL(t.Total, 0), N'N2', N'en-US') + N') must add up to the invoice amount ('
                              + FORMAT(a.Amount, N'N2', N'en-US') + N' ' + cu.CurrencyCode + N'). Split the amount over its containers.'
        FROM @Allocations a
        INNER JOIN purchase.PurchaseDocuments d ON d.Id = a.DocumentId
        INNER JOIN masterdata.Currencies cu ON cu.Id = d.CurrencyId
        OUTER APPLY (SELECT Total = SUM(Amount) FROM @Containers WHERE DocumentId = a.DocumentId) t
        WHERE a.DocumentKind = N'PINV'
          AND EXISTS (SELECT 1 FROM purchase.fn_InvoiceContainerSettlement(a.DocumentId) WHERE HasContainers = 1)
          AND ABS(a.Amount - ISNULL(t.Total, 0)) > 0.005
        ORDER BY d.DocumentNumber;
        IF @Msg IS NOT NULL THROW 73008, @Msg, 1;
    END
END

GO

