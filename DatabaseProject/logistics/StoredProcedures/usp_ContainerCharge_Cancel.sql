-- the transaction, without a lock, so a cancel decided "not in the goods' cost" while a goods receipt was freezing the
-- charge (AppliedAtOffload) - the cost stayed in the received goods with the charge cancelled. Now, inside the
-- transaction, the container is read WITH (UPDLOCK, HOLDLOCK) first (the order goods receipt Post and Cancel lock in),
-- then the charge: the cancel waits for a receipt in progress and decides on what it committed. The refusals are
-- unchanged (same numbers and words), only made inside the transaction.
-- Cancels a POSTED charge. When it is already in the cost of offloaded goods, the cost is reversed the same way.
CREATE   PROCEDURE logistics.usp_ContainerCharge_Cancel
    @Id         INT,
    @Reason     NVARCHAR(300),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 70000, 'A cancellation reason is required.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- (65) under lock: the container first, then the charge (a charge never changes container)
        DECLARE @ContainerId INT = (SELECT ContainerId FROM logistics.ContainerCharges WHERE Id = @Id);
        DECLARE @Status TINYINT, @CtStatus TINYINT, @InCost BIT, @Label NVARCHAR(200);
        SELECT @CtStatus = c.Status FROM logistics.Containers c WITH (UPDLOCK, HOLDLOCK) WHERE c.Id = @ContainerId;
        SELECT @Status = ch.Status,
               @InCost = CASE WHEN @CtStatus = 6 AND ch.IncludeInLandedCost = 1 AND (ch.AppliedAtOffload = 1 OR ch.AdjustedAfterOffload = 1) THEN 1 ELSE 0 END,
               @Label = t.ChargeCode + N' ' + t.ChargeName + N' ' + CAST(ch.Amount AS NVARCHAR(30)) + N' ' + cur.CurrencyCode
        FROM logistics.ContainerCharges ch WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN purchase.ChargeTypes t    ON t.Id = ch.ChargeTypeId
        INNER JOIN masterdata.Currencies cur ON cur.Id = ch.CurrencyId
        WHERE ch.Id = @Id AND ch.ContainerId = @ContainerId;

        IF @Status IS NULL THROW 70006, 'Charge not found.', 1;
        IF @Status <> 2 THROW 70010, 'Only a posted charge can be cancelled (delete a draft instead).', 1;
        -- (47) Money paid against it would be left pointing at nothing: the payments are reversed (or de-allocated) first.
        IF EXISTS (SELECT 1 FROM purchase.PaymentAllocations a INNER JOIN purchase.Payments p ON p.Id = a.PaymentId
                   WHERE a.ContainerChargeId = @Id AND a.RemovedAtUtc IS NULL AND p.Status = 2)
            THROW 70010, 'This charge cannot be cancelled: supplier payments are allocated to it. Reverse those payments (or remove the allocations) first.', 1;
        IF @CtStatus = 7 THROW 70010, 'The container is closed. Reopen it first.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.ContainerCharges WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 70004, 'This charge was modified by another user. Reload the page and try again.', 1;

        UPDATE logistics.ContainerCharges
        SET Status = 3, CancelledAtUtc = SYSUTCDATETIME(), CancelledBy = @UserId, CancelReason = @Reason,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        EXEC logistics.usp_Container_RecalcCosts @ContainerId;
        IF @InCost = 1 EXEC logistics.usp_ContainerCharge_ApplyCost @Id, -1, @UserId;

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        VALUES (@ContainerId, N'Updated', LEFT(N'Charge cancelled: ' + @Label + N' - ' + @Reason
                                               + CASE WHEN @InCost = 1 THEN N' (item costs adjusted back)' ELSE N'' END, 500), @UserId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

