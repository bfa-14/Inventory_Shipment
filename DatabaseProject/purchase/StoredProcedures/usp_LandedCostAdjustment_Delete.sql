CREATE   PROCEDURE purchase.usp_LandedCostAdjustment_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Status TINYINT = (SELECT Status FROM purchase.LandedCostAdjustments WHERE Id = @Id);
    IF @Status IS NULL THROW 67006, 'Adjustment not found.', 1;
    IF @Status <> 1 THROW 67005, 'Only draft adjustments can be deleted.', 1;
    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE a FROM purchase.PurchaseChargeAllocations a INNER JOIN purchase.PurchaseCharges c ON c.Id = a.ChargeId WHERE c.DocumentKind = N'LCA' AND c.DocumentId = @Id;
        DELETE FROM purchase.PurchaseCharges WHERE DocumentKind = N'LCA' AND DocumentId = @Id;
        DELETE FROM purchase.LandedCostAdjustmentLines WHERE AdjustmentId = @Id;
        DELETE FROM purchase.LandedCostAdjustments WHERE Id = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

