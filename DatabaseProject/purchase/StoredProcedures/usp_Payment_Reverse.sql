/* ================================================================== 5. Reverse */

CREATE   PROCEDURE purchase.usp_Payment_Reverse
    @Id         INT,
    @Reason     NVARCHAR(500),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 73000, 'A reason is required to reverse a payment.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @Type TINYINT;
        SELECT @Status = Status, @Type = PaymentType FROM purchase.Payments WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;

        IF @Status IS NULL THROW 73006, 'Payment not found.', 1;
        IF @Status <> 2 THROW 73010, 'Only a posted payment can be reversed.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.Payments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 73004, 'This payment was modified by another user. Reload the page and try again.', 1;

        /* A FREE PAYMENT THAT HAS SINCE PAID DOCUMENTS CANNOT JUST VANISH: they would go back to owing money
           nobody told them about. Its allocations are removed first, so somebody decides about each one. An
           allocated payment's own allocations are part of it: reversing it simply stops them counting. */
        IF @Type = 1 AND EXISTS (SELECT 1 FROM purchase.PaymentAllocations WHERE PaymentId = @Id AND RemovedAtUtc IS NULL)
            THROW 73012, 'This payment has been applied to documents since it was posted. Remove those allocations before reversing it.', 1;

        UPDATE purchase.Payments
        SET Status = 3, ReversedAtUtc = SYSUTCDATETIME(), ReversedBy = @UserId, ReverseReason = @Reason,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO purchase.PaymentAudit (PaymentId, Action, Details, UserId) VALUES (@Id, N'Reversed', @Reason, @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

