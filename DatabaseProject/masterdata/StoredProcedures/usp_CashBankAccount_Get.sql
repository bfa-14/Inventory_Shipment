CREATE   PROCEDURE masterdata.usp_CashBankAccount_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT a.Id, a.AccountCode, a.AccountName, a.AccountType, a.CurrencyId, c.CurrencyCode,
           a.BranchId, BranchName = b.BranchName, a.Description, a.IsActive,
           a.CreatedAtUtc, a.CreatedBy, a.UpdatedAtUtc, a.UpdatedBy, a.RowVersion
    FROM masterdata.CashBankAccounts a
    INNER JOIN masterdata.Currencies c ON c.Id = a.CurrencyId
    LEFT JOIN masterdata.Branches b ON b.Id = a.BranchId
    WHERE a.Id = @Id;
END

GO

