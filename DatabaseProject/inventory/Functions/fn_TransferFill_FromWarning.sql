/* (91) THE TWO WARNINGS OF FILL TO MAX, ADD ITEMS BELOW MIN AND CREATE TRANSFER ORDER (3.3.6.3 step 5), each built in
   one place: From goes below its own Min for a filled item; other drafts or orders waiting for approval to the same To
   hold some of the same items (L10: Fill to Max does not count them, so a second draft for the same shortage is said). */
CREATE   FUNCTION inventory.fn_TransferFill_FromWarning
(
    @FromCode  NVARCHAR(20),
    @ItemCode  NVARCHAR(30),
    @AfterBase INT,
    @MinBase   INT
)
RETURNS NVARCHAR(500)
AS
BEGIN
    RETURN ISNULL(@FromCode, N'The source') + N' goes below its own Min for ' + ISNULL(@ItemCode, N'the item') + N': '
           + CAST(@AfterBase AS NVARCHAR(12)) + N' pcs left after this order, Min ' + CAST(@MinBase AS NVARCHAR(12)) + N'.';
END

GO

