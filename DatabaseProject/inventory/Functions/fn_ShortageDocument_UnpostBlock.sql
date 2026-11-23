
/* ================================================================== 1. Why a plan cannot go back to draft */

CREATE   FUNCTION inventory.fn_ShortageDocument_UnpostBlock (@Id INT)
RETURNS NVARCHAR(400)
AS
BEGIN
    DECLARE @Status TINYINT, @Number NVARCHAR(30);
    SELECT @Status = Status, @Number = DocumentNumber FROM inventory.ShortageDocuments WHERE Id = @Id;
    IF @Status IS NULL RETURN N'Shortage document not found.';
    IF @Status <> 2 RETURN @Number + N' is a draft already.';

    -- The purchase orders made from the plan that are not cancelled (3): the oldest names the refusal.
    DECLARE @Orders INT, @OrderNumber NVARCHAR(30), @OrderStatus TINYINT;
    SELECT @Orders = COUNT(*) FROM purchase.PurchaseDocuments p WHERE p.SourceShortageId = @Id AND p.Status <> 3;
    IF @Orders = 0 RETURN NULL;

    SELECT TOP (1) @OrderNumber = p.DocumentNumber, @OrderStatus = p.Status
    FROM purchase.PurchaseDocuments p
    WHERE p.SourceShortageId = @Id AND p.Status <> 3
    ORDER BY p.CreatedAtUtc, p.Id;

    RETURN @Number + N' has '
         + CASE WHEN @OrderStatus = 1 THEN N'a draft purchase order' + ISNULL(N' (' + NULLIF(@OrderNumber, N'') + N')', N'')
                WHEN @OrderStatus = 5 THEN N'a purchase order waiting for approval' + ISNULL(N' (' + NULLIF(@OrderNumber, N'') + N')', N'')
                ELSE N'purchase order ' + ISNULL(NULLIF(@OrderNumber, N''), N'(not numbered)') END
         + CASE WHEN @Orders > 1 THEN N' and ' + CAST(@Orders - 1 AS NVARCHAR(10)) + N' more' ELSE N'' END
         + N' made from it: '
         + CASE WHEN @OrderStatus = 1 AND @Orders = 1 THEN N'delete that draft first'
                WHEN @OrderStatus = 5 AND @Orders = 1 THEN N'withdraw and delete it first'
                ELSE N'cancel ' + CASE WHEN @Orders > 1 THEN N'them' ELSE N'it' END + N' first' END
         + N', then bring the plan back to draft.';
END

GO

