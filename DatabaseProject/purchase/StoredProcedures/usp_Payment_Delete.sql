/* ================================================================== 6. Delete (a draft) */

CREATE   PROCEDURE purchase.usp_Payment_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT;
        SELECT @Status = Status FROM purchase.Payments WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NULL THROW 73006, 'Payment not found.', 1;
        -- A posted payment moved money and a reversed one proves it did: neither is ever deleted.
        IF @Status <> 1 THROW 73010, 'Only a draft payment can be deleted. A posted payment is corrected by reversing it.', 1;

        DELETE FROM purchase.PaymentFiles WHERE PaymentId = @Id;
        DELETE FROM purchase.PaymentAllocations WHERE PaymentId = @Id;
        DELETE FROM purchase.PaymentLines WHERE PaymentId = @Id;
        DELETE FROM purchase.PaymentAudit WHERE PaymentId = @Id;
        DELETE FROM purchase.Payments WHERE Id = @Id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

