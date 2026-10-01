CREATE   PROCEDURE masterdata.usp_CashBankAccount_Save
    @Id          INT           = NULL,
    @AccountCode NVARCHAR(20),
    @AccountName NVARCHAR(100),
    @AccountType NVARCHAR(10),
    @CurrencyId  INT,
    @BranchId    INT           = NULL,
    @Description NVARCHAR(500) = NULL,
    @IsActive    BIT           = 1,
    @RowVersion  BINARY(8)     = NULL,
    @UserId      INT           = NULL,
    @NewId       INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @AccountCode = UPPER(NULLIF(LTRIM(RTRIM(@AccountCode)), N''));
    SET @AccountName = NULLIF(LTRIM(RTRIM(@AccountName)), N'');
    SET @AccountType = NULLIF(LTRIM(RTRIM(@AccountType)), N'');
    SET @Description = NULLIF(LTRIM(RTRIM(@Description)), N'');
    IF @AccountCode IS NULL THROW 71000, 'Account code is required.', 1;
    IF @AccountName IS NULL THROW 71000, 'Account name is required.', 1;
    IF @AccountType IS NULL OR @AccountType NOT IN (N'Cash', N'Bank') THROW 71000, 'Account type must be Cash or Bank.', 1;
    IF @CurrencyId IS NULL OR NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsActive = 1)
        THROW 71000, 'Currency not found or inactive.', 1;
    IF @BranchId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 71000, 'Branch not found or inactive.', 1;
    IF EXISTS (SELECT 1 FROM masterdata.CashBankAccounts WHERE AccountCode = @AccountCode AND (@Id IS NULL OR Id <> @Id))
        THROW 71013, 'This account code already exists.', 1;

    IF @Id IS NULL
    BEGIN
        INSERT INTO masterdata.CashBankAccounts (AccountCode, AccountName, AccountType, CurrencyId, BranchId, Description, IsActive, CreatedBy)
        VALUES (@AccountCode, @AccountName, @AccountType, @CurrencyId, @BranchId, @Description, ISNULL(@IsActive, 1), @UserId);
        SET @NewId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM masterdata.CashBankAccounts WHERE Id = @Id) THROW 71006, 'Cash / bank account not found.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.CashBankAccounts WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 71004, 'This account was modified by another user. Reload the page and try again.', 1;

        /* A used account keeps its currency. Receipt lines were checked against it when they were
           saved, and changing it afterwards would leave posted money sitting in the wrong one. */
        IF EXISTS (SELECT 1 FROM masterdata.CashBankAccounts WHERE Id = @Id AND CurrencyId <> @CurrencyId)
           AND EXISTS (SELECT 1 FROM sales.ReceiptLines WHERE CashBankAccountId = @Id)
            THROW 71000, 'The currency of an account that receipts already use cannot be changed.', 1;

        UPDATE masterdata.CashBankAccounts
        SET AccountCode = @AccountCode, AccountName = @AccountName, AccountType = @AccountType, CurrencyId = @CurrencyId,
            BranchId = @BranchId, Description = @Description, IsActive = ISNULL(@IsActive, 1),
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;
        SET @NewId = @Id;
    END
END

GO

