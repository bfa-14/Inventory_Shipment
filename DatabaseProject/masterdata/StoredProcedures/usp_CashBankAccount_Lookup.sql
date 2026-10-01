/* What a receipt line's account picker reads. FILTERED BY CURRENCY AND BRANCH because both are rules
   of the line: the account must hold the line's currency, and must be one the receipt's branch may
   use (an account with no branch belongs to everybody). */
CREATE   PROCEDURE masterdata.usp_CashBankAccount_Lookup
    @ActiveOnly BIT = 1,
    @CurrencyId INT = NULL,
    @BranchId   INT = NULL,
    @IncludeId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT a.Id, a.AccountCode, a.AccountName, a.AccountType, a.CurrencyId, c.CurrencyCode, a.BranchId, a.IsActive
    FROM masterdata.CashBankAccounts a
    INNER JOIN masterdata.Currencies c ON c.Id = a.CurrencyId
    WHERE (@ActiveOnly = 0 OR a.IsActive = 1 OR a.Id = @IncludeId)
      AND (@CurrencyId IS NULL OR a.CurrencyId = @CurrencyId OR a.Id = @IncludeId)
      AND (@BranchId IS NULL OR a.BranchId IS NULL OR a.BranchId = @BranchId OR a.Id = @IncludeId)
    ORDER BY a.AccountName;
END

GO

