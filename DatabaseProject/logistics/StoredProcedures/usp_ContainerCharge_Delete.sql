CREATE   PROCEDURE logistics.usp_ContainerCharge_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @ContainerId INT, @Status TINYINT, @Label NVARCHAR(200);
    SELECT @ContainerId = ch.ContainerId, @Status = ch.Status,
           @Label = t.ChargeCode + N' ' + t.ChargeName + N' ' + CAST(ch.Amount AS NVARCHAR(30))
    FROM logistics.ContainerCharges ch INNER JOIN purchase.ChargeTypes t ON t.Id = ch.ChargeTypeId
    WHERE ch.Id = @Id;
    IF @ContainerId IS NULL THROW 70006, 'Charge not found.', 1;
    IF @Status <> 1 THROW 70005, 'Only a draft charge can be deleted. Cancel a posted one.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        UPDATE logistics.ContainerAttachments SET ChargeId = NULL WHERE ChargeId = @Id;
        DELETE FROM logistics.ContainerChargeAllocations WHERE ChargeId = @Id;
        DELETE FROM logistics.ContainerCharges WHERE Id = @Id;
        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        VALUES (@ContainerId, N'Updated', LEFT(N'Draft charge deleted: ' + @Label, 500), @UserId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

