/* ================================================================== 8. Cheque clearance (decision 5) */

/* THE ONE FIELD OF A POSTED PAYMENT THAT STILL MOVES: a cheque is Pending until the bank clears or returns
   it. Changing it moves no money - a returned cheque is dealt with by reversing the payment. */
CREATE   PROCEDURE purchase.usp_Payment_SetChequeStatus
    @LineId          INT,
    @ClearanceStatus TINYINT,        -- 1 Pending, 2 Cleared, 3 Returned
    @UserId          INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @ClearanceStatus NOT IN (1, 2, 3) THROW 73000, 'Clearance status must be Pending, Cleared or Returned.', 1;

    DECLARE @PaymentId INT, @Status TINYINT, @Old TINYINT, @IsCheque BIT, @ChequeNo NVARCHAR(50);
    SELECT @PaymentId = l.PaymentId, @Status = p.Status, @Old = l.ClearanceStatus, @ChequeNo = l.ChequeNo,
           @IsCheque = CASE WHEN pm.MethodCode = N'CHQ' THEN 1 ELSE 0 END
    FROM purchase.PaymentLines l
    INNER JOIN purchase.Payments p ON p.Id = l.PaymentId
    INNER JOIN masterdata.PaymentMethods pm ON pm.Id = l.PaymentMethodId
    WHERE l.Id = @LineId;

    IF @PaymentId IS NULL THROW 73006, 'Payment line not found.', 1;
    IF @IsCheque = 0 THROW 73000, 'Only a cheque line has a clearance status.', 1;
    IF @Status <> 2 THROW 73010, 'The clearance status is kept for a posted payment only.', 1;
    IF @Old = @ClearanceStatus RETURN;

    BEGIN TRY
        BEGIN TRANSACTION;
        UPDATE purchase.PaymentLines
        SET ClearanceStatus = @ClearanceStatus, ClearanceUpdatedAtUtc = SYSUTCDATETIME(), ClearanceUpdatedBy = @UserId
        WHERE Id = @LineId;

        INSERT INTO purchase.PaymentAudit (PaymentId, Action, Details, UserId)
        VALUES (@PaymentId, N'ChequeStatus', N'Cheque ' + ISNULL(@ChequeNo, N'') + N': '
                + CASE ISNULL(@Old, 1) WHEN 1 THEN N'Pending' WHEN 2 THEN N'Cleared' ELSE N'Returned' END + N' -> '
                + CASE @ClearanceStatus WHEN 1 THEN N'Pending' WHEN 2 THEN N'Cleared' ELSE N'Returned' END, @UserId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

