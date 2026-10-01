CREATE   PROCEDURE masterdata.usp_CashBankAccount_SetActive
    @Id INT, @IsActive BIT, @RowVersion BINARY(8) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.CashBankAccounts WHERE Id = @Id) THROW 71006, 'Cash / bank account not found.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.CashBankAccounts WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 71004, 'This account was modified by another user. Reload the page and try again.', 1;
    UPDATE masterdata.CashBankAccounts SET IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;
END

GO

