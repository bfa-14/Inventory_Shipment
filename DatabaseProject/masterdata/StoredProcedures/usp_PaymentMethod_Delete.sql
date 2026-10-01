CREATE   PROCEDURE masterdata.usp_PaymentMethod_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.PaymentMethods WHERE Id = @Id) THROW 71006, 'Payment method not found.', 1;
    IF EXISTS (SELECT 1 FROM sales.ReceiptLines WHERE PaymentMethodId = @Id)
        THROW 71014, 'This payment method is used by receipts and cannot be deleted. Deactivate it instead.', 1;
    DELETE FROM masterdata.PaymentMethods WHERE Id = @Id;
END

GO

