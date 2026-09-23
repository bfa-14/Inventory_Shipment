CREATE   PROCEDURE purchase.usp_ChargeType_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM purchase.ChargeTypes WHERE Id = @Id) THROW 68006, 'Charge type not found.', 1;
    IF EXISTS (SELECT 1 FROM purchase.PurchaseCharges WHERE ChargeTypeId = @Id)
        THROW 68005, 'This charge type was used in transactions and cannot be deleted. Deactivate it instead.', 1;
    DELETE FROM purchase.ChargeTypes WHERE Id = @Id;
END

GO

