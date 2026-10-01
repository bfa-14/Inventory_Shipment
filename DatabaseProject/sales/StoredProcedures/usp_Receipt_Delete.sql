/* ================================================================== 8. Delete (a draft) */

CREATE   PROCEDURE sales.usp_Receipt_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT;
        SELECT @Status = Status FROM sales.Receipts WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NULL THROW 71006, 'Receipt not found.', 1;
        -- A posted receipt moved money and a reversed one proves it did: neither is ever deleted.
        IF @Status <> 1 THROW 71010, 'Only a draft receipt can be deleted. A posted receipt is corrected by reversing it.', 1;

        DELETE FROM sales.ReceiptFiles WHERE ReceiptId = @Id;
        DELETE FROM sales.ReceiptAllocations WHERE ReceiptId = @Id;
        DELETE FROM sales.ReceiptLines WHERE ReceiptId = @Id;
        DELETE FROM sales.ReceiptAudit WHERE ReceiptId = @Id;
        DELETE FROM sales.Receipts WHERE Id = @Id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

