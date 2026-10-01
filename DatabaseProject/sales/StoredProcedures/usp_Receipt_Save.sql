/* ================================================================== 5. Save (a draft) */

CREATE   PROCEDURE sales.usp_Receipt_Save
    @Id           INT            = NULL,           -- NULL = create
    @ReceiptDate  DATE,
    @ClientId     INT,
    @BranchId     INT,
    @PaymentType  TINYINT        = 1,              -- 1 Free Receipt, 2 Sales Allocation
    @CurrencyId   INT,
    @Amount       DECIMAL(18,2),
    @ExchangeRate DECIMAL(18,6)  = NULL,           -- NULL = the official rate on the receipt date
    @Notes        NVARCHAR(1000) = NULL,
    @Lines        sales.tvp_ReceiptLine READONLY,
    @Allocations  sales.tvp_ReceiptAllocation READONLY,
    @RowVersion   BINARY(8)      = NULL,
    @UserId       INT            = NULL,
    @NewId        INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    SET @PaymentType = ISNULL(@PaymentType, 1);

    IF @ReceiptDate IS NULL THROW 71000, 'Receipt Date is required.', 1;
    -- A day of tolerance, as on the invoices: the date is the reader's local one, the check is UTC.
    IF @ReceiptDate > DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE)) THROW 71000, 'Receipt Date cannot be in the future.', 1;
    IF @ClientId IS NULL OR NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @ClientId AND IsClient = 1 AND IsActive = 1)
        THROW 71000, 'Customer not found, inactive, or not a client.', 1;
    IF @BranchId IS NULL OR NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 71000, 'Branch not found or inactive.', 1;
    IF @PaymentType NOT IN (1, 2) THROW 71000, 'Payment Type must be Free Receipt or Sales Allocation.', 1;
    IF @CurrencyId IS NULL OR NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsActive = 1)
        THROW 71000, 'Currency not found or inactive.', 1;
    IF @Amount IS NULL OR @Amount <= 0 THROW 71000, 'Receipt Amount must be greater than zero.', 1;
    IF @ExchangeRate IS NOT NULL AND @ExchangeRate <= 0 THROW 71000, 'Exchange rate must be greater than zero.', 1;

    /* THE HEADER RATE. The base currency is always 1, whatever was typed; any other takes what was
       typed, else the official rate on the receipt date, else it is an error the reader can fix. */
    IF EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsBaseCurrency = 1) SET @ExchangeRate = 1;
    SET @ExchangeRate = COALESCE(@ExchangeRate, masterdata.fn_GetRate(@CurrencyId, 1, @ReceiptDate));
    IF @ExchangeRate IS NULL
    BEGIN
        DECLARE @RateCur NVARCHAR(3) = (SELECT CurrencyCode FROM masterdata.Currencies WHERE Id = @CurrencyId);
        DECLARE @RateMsg NVARCHAR(300) = N'No official exchange rate is defined for ' + @RateCur + N' on or before '
            + CONVERT(NVARCHAR(10), @ReceiptDate, 120) + N'. Add one in Master Data > Exchange Rates or enter the rate manually.';
        THROW 71000, @RateMsg, 1;
    END

    /* EVERY LINE IS JUDGED, and the first failing one is named. The account is the interesting rule:
       it must hold the line's currency, because that is how a receipt line can be believed - the
       money it records went into an account that really keeps that currency. */
    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' + x.Problem
    FROM @Lines l
    LEFT JOIN masterdata.PaymentMethods pm   ON pm.Id = l.PaymentMethodId
    LEFT JOIN masterdata.Currencies cu       ON cu.Id = l.CurrencyId
    LEFT JOIN masterdata.CashBankAccounts a  ON a.Id = l.CashBankAccountId
    LEFT JOIN masterdata.Currencies ac       ON ac.Id = a.CurrencyId
    CROSS APPLY (SELECT Problem =
        CASE WHEN pm.Id IS NULL OR pm.IsActive = 0 THEN N'payment method not found or inactive.'
             WHEN cu.Id IS NULL OR cu.IsActive = 0 THEN N'currency not found or inactive.'
             WHEN l.Amount IS NULL OR l.Amount <= 0 THEN N'amount must be greater than zero.'
             WHEN l.ExchangeRate IS NOT NULL AND l.ExchangeRate <= 0 THEN N'exchange rate must be greater than zero.'
             WHEN a.Id IS NULL OR a.IsActive = 0 THEN N'cash / bank account not found or inactive.'
             WHEN a.CurrencyId <> l.CurrencyId THEN N'account ' + a.AccountCode + N' holds ' + ac.CurrencyCode + N', not ' + cu.CurrencyCode + N'.'
             WHEN a.BranchId IS NOT NULL AND a.BranchId <> @BranchId THEN N'account ' + a.AccountCode + N' is not available for this receipt''s branch.'
             WHEN l.ExchangeRate IS NULL AND cu.IsBaseCurrency = 0 AND masterdata.fn_GetRate(l.CurrencyId, 1, @ReceiptDate) IS NULL
                  THEN N'no official exchange rate is defined for ' + cu.CurrencyCode + N' on or before ' + CONVERT(NVARCHAR(10), @ReceiptDate, 120) + N'.'
        END) x
    WHERE x.Problem IS NOT NULL
    ORDER BY l.LineNumber;
    IF @Msg IS NOT NULL THROW 71000, @Msg, 1;

    /* ALLOCATIONS. A Free Receipt carries none - the page hides the panel - and a Sales Allocation
       one only to posted invoices of THIS customer, never above what the invoice still owes. What it
       still owes counts POSTED receipts only: another draft allocating the same invoice is settled
       when one of them posts, under a lock, not here. */
    IF @PaymentType = 1 AND EXISTS (SELECT 1 FROM @Allocations)
        THROW 71000, 'A Free Receipt cannot be allocated to invoices. Choose Sales Allocation, or allocate it after posting.', 1;

    SET @Msg = NULL;
    SELECT TOP (1) @Msg = N'Invoice ' + ISNULL(d.DocumentNumber, N'#' + CAST(a.SalesDocumentId AS NVARCHAR(10))) + N': ' + x.Problem
    FROM @Allocations a
    LEFT JOIN sales.SalesDocuments d ON d.Id = a.SalesDocumentId
    OUTER APPLY sales.fn_InvoiceSettlement(a.SalesDocumentId) st
    CROSS APPLY (SELECT Problem =
        CASE WHEN d.Id IS NULL THEN N'not found.'
             WHEN st.PaymentStatus IS NULL THEN N'only a posted sales invoice can be paid.'
             WHEN d.ClientId <> @ClientId THEN N'it belongs to another customer.'
             WHEN a.Amount IS NULL OR a.Amount <= 0 THEN N'the allocated amount must be greater than zero.'
        END) x
    WHERE x.Problem IS NOT NULL
    ORDER BY a.SalesDocumentId;
    IF @Msg IS NOT NULL THROW 71000, @Msg, 1;

    SELECT TOP (1) @Msg = N'Invoice ' + d.DocumentNumber + N': ' + FORMAT(a.Amount, N'N2', N'en-US') + N' is more than its outstanding '
                          + FORMAT(st.OutstandingAmount, N'N2', N'en-US') + N' ' + c.CurrencyCode + N'.'
    FROM @Allocations a
    INNER JOIN sales.SalesDocuments d ON d.Id = a.SalesDocumentId
    INNER JOIN masterdata.Currencies c ON c.Id = d.CurrencyId
    CROSS APPLY sales.fn_InvoiceSettlement(a.SalesDocumentId) st
    WHERE a.Amount > st.OutstandingAmount + 0.005
    ORDER BY a.SalesDocumentId;
    IF @Msg IS NOT NULL THROW 71009, @Msg, 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Id IS NULL
        BEGIN
            -- Numbered at the FIRST SAVE, inside this transaction: a save that fails gives the number back.
            DECLARE @Number NVARCHAR(30);
            EXEC inventory.usp_DocumentType_NextNumber @Code = N'RCPT', @DocumentNumber = @Number OUTPUT;

            INSERT INTO sales.Receipts (ReceiptNumber, ReceiptDate, ClientId, BranchId, PaymentType, CurrencyId, Amount, ExchangeRate, Notes, Status, CreatedBy)
            VALUES (@Number, @ReceiptDate, @ClientId, @BranchId, @PaymentType, @CurrencyId, @Amount, @ExchangeRate, @Notes, 1, @UserId);
            SET @Id = SCOPE_IDENTITY();

            INSERT INTO sales.ReceiptAudit (ReceiptId, Action, Details, UserId)
            VALUES (@Id, N'Created', N'Draft ' + @Number, @UserId);
        END
        ELSE
        BEGIN
            DECLARE @Status TINYINT;
            SELECT @Status = Status FROM sales.Receipts WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
            IF @Status IS NULL THROW 71006, 'Receipt not found.', 1;
            IF @Status <> 1 THROW 71005, 'Only a draft receipt can be edited.', 1;
            IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sales.Receipts WHERE Id = @Id AND RowVersion = @RowVersion)
                THROW 71004, 'This receipt was modified by another user. Reload the page and try again.', 1;

            UPDATE sales.Receipts
            SET ReceiptDate = @ReceiptDate, ClientId = @ClientId, BranchId = @BranchId, PaymentType = @PaymentType,
                CurrencyId = @CurrencyId, Amount = @Amount, ExchangeRate = @ExchangeRate, Notes = @Notes,
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;

            DELETE FROM sales.ReceiptAllocations WHERE ReceiptId = @Id;
            DELETE FROM sales.ReceiptLines WHERE ReceiptId = @Id;

            INSERT INTO sales.ReceiptAudit (ReceiptId, Action, Details, UserId)
            VALUES (@Id, N'Updated', N'Header, ' + CAST((SELECT COUNT(*) FROM @Lines) AS NVARCHAR(10)) + N' payment line(s) and '
                    + CAST((SELECT COUNT(*) FROM @Allocations) AS NVARCHAR(10)) + N' allocation(s) saved', @UserId);
        END

        INSERT INTO sales.ReceiptLines (ReceiptId, LineNumber, PaymentMethodId, CurrencyId, Amount, ExchangeRate, CashBankAccountId, Reference)
        SELECT @Id, l.LineNumber, l.PaymentMethodId, l.CurrencyId, l.Amount,
               CASE WHEN cu.IsBaseCurrency = 1 THEN 1 ELSE COALESCE(l.ExchangeRate, masterdata.fn_GetRate(l.CurrencyId, 1, @ReceiptDate)) END,
               l.CashBankAccountId, NULLIF(LTRIM(RTRIM(l.Reference)), N'')
        FROM @Lines l
        INNER JOIN masterdata.Currencies cu ON cu.Id = l.CurrencyId;

        -- THE INVOICE'S OWN RATE IS SNAPSHOTTED, so the base value of an allocation can never move.
        INSERT INTO sales.ReceiptAllocations (ReceiptId, SalesDocumentId, AmountInvoiceCurrency, InvoiceExchangeRate, AllocatedBy)
        SELECT @Id, a.SalesDocumentId, a.Amount, d.ExchangeRate, @UserId
        FROM @Allocations a
        INNER JOIN sales.SalesDocuments d ON d.Id = a.SalesDocumentId;

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

