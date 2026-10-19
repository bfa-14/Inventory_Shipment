/* ================================================================== 22. Matching received pieces to invoiced pieces */

/* ONE MATCHER AT A TIME, AND TAKEN FIRST. Every procedure that rematches or trues up the cost of received goods - goods
   receipt Post and Cancel, supplier invoice and return Post and Cancel, landed cost adjustment Post and Cancel - calls
   this as its FIRST statement after BEGIN TRANSACTION, before any row lock or write. Lock order: the matcher first,
   then rows, or two postings deadlock - taken later (as usp_GoodsReceipt_Rematch takes it, after its caller locked and
   wrote its own rows), one posting holds the lock and waits to read rows the other wrote, while the other holds those
   rows and waits for the lock, even for unrelated suppliers and items. Held until the caller's transaction ends, and
   re-entrant: Rematch and TrueUpCost take it again and go straight through, so a caller that forgets the early call
   still gets one matcher at a time. */
CREATE   PROCEDURE purchase.usp_GoodsReceipt_LockMatching
AS
BEGIN
    SET NOCOUNT ON;

    IF @@TRANCOUNT = 0
        THROW 63010, 'The goods receipt matching lock is taken inside a transaction.', 1;

    DECLARE @Lock INT;
    EXEC @Lock = sp_getapplock @Resource = N'purchase.GoodsReceiptMatching', @LockMode = N'Exclusive',
                               @LockOwner = N'Transaction', @LockTimeout = 60000;
    IF @Lock < 0
        THROW 63010, 'Goods receipts and invoices are being matched for another user. Try again in a moment.', 1;
END

GO

