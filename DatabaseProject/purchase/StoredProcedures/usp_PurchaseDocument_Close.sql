/* ================================================================== 5. Close Order: retired */

-- Re-created (77): an order is no longer closed. Its parameters stay for an older caller; the procedure refuses.
-- Pieces that will never arrive are settled with "Nothing more will come" when goods are received.
CREATE   PROCEDURE purchase.usp_PurchaseDocument_Close
    @Id         INT,
    @Reason     NVARCHAR(300) = NULL,     -- ignored since script 77
    @RowVersion BINARY(8)     = NULL,     -- ignored since script 77
    @UserId     INT           = NULL      -- ignored since script 77
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id) THROW 65006, 'Document not found.', 1;
    THROW 65010, 'Purchase orders are no longer closed: an order shows Saved, Partially posted or Posted from its posted invoices. Use "Nothing more will come" when receiving to settle pieces that will never arrive.', 1;
END

GO

