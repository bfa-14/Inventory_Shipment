CREATE   PROCEDURE masterdata.usp_CashBankAccount_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.CashBankAccounts WHERE Id = @Id) THROW 71006, 'Cash / bank account not found.', 1;
    IF EXISTS (SELECT 1 FROM sales.ReceiptLines WHERE CashBankAccountId = @Id)
        THROW 71014, 'This account is used by receipts and cannot be deleted. Deactivate it instead.', 1;
    DELETE FROM masterdata.CashBankAccounts WHERE Id = @Id;
END

GO

