/* ================================================================== 1. The procedures re-created */

-- Re-created (114) from the body of script 37: COLLATE DATABASE_DEFAULT on the text columns of its #tables (3).
CREATE   PROCEDURE sales.usp_Customer_Statement
    @ClientId INT,
    @DateFrom DATE = NULL,
    @DateTo   DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @ClientId AND IsClient = 1)
        THROW 71006, 'Customer not found.', 1;

    DECLARE @Base NVARCHAR(10) = (SELECT TOP (1) CurrencyCode FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1);

    CREATE TABLE #E (
        EntryDate DATE NOT NULL, SortGroup TINYINT NOT NULL, DocumentId INT NOT NULL, EntryType NVARCHAR(30) COLLATE DATABASE_DEFAULT NOT NULL,
        DocumentNumber NVARCHAR(50) COLLATE DATABASE_DEFAULT NULL, CurrencyCode NVARCHAR(10) COLLATE DATABASE_DEFAULT NULL, DecimalPlaces TINYINT NULL, DocAmount DECIMAL(18,2) NOT NULL,
        Debit DECIMAL(18,2) NOT NULL, Credit DECIMAL(18,2) NOT NULL, Balance DECIMAL(18,2) NULL);

    DECLARE @SINV INT = (SELECT Id FROM inventory.DocumentTypes WHERE Code = N'SINV');
    DECLARE @SRET INT = (SELECT Id FROM inventory.DocumentTypes WHERE Code = N'SRET');

    -- Invoices (posted, or cancelled after posting)
    INSERT #E (EntryDate, SortGroup, DocumentId, EntryType, DocumentNumber, CurrencyCode, DecimalPlaces, DocAmount, Debit, Credit)
    SELECT CAST(d.DocumentDate AS DATE), 1, d.Id, N'Invoice', d.DocumentNumber, c.CurrencyCode, c.DecimalPlaces, d.TotalAmount, d.TotalAmountBase, 0
    FROM sales.SalesDocuments d INNER JOIN masterdata.Currencies c ON c.Id = d.CurrencyId
    WHERE d.ClientId = @ClientId AND d.DocumentTypeId = @SINV AND d.PostedAtUtc IS NOT NULL AND d.Status IN (2, 3);

    INSERT #E (EntryDate, SortGroup, DocumentId, EntryType, DocumentNumber, CurrencyCode, DecimalPlaces, DocAmount, Debit, Credit)
    SELECT CAST(d.CancelledAtUtc AS DATE), 2, d.Id, N'Invoice cancelled', d.DocumentNumber, c.CurrencyCode, c.DecimalPlaces, d.TotalAmount, 0, d.TotalAmountBase
    FROM sales.SalesDocuments d INNER JOIN masterdata.Currencies c ON c.Id = d.CurrencyId
    WHERE d.ClientId = @ClientId AND d.DocumentTypeId = @SINV AND d.Status = 3 AND d.PostedAtUtc IS NOT NULL AND d.CancelledAtUtc IS NOT NULL;

    -- Sales returns
    INSERT #E (EntryDate, SortGroup, DocumentId, EntryType, DocumentNumber, CurrencyCode, DecimalPlaces, DocAmount, Debit, Credit)
    SELECT CAST(d.DocumentDate AS DATE), 3, d.Id, N'Sales return', d.DocumentNumber, c.CurrencyCode, c.DecimalPlaces, d.TotalAmount, 0, d.TotalAmountBase
    FROM sales.SalesDocuments d INNER JOIN masterdata.Currencies c ON c.Id = d.CurrencyId
    WHERE d.ClientId = @ClientId AND d.DocumentTypeId = @SRET AND d.Status = 2;

    -- Receipts (posted, or reversed after posting) and their reversals
    INSERT #E (EntryDate, SortGroup, DocumentId, EntryType, DocumentNumber, CurrencyCode, DecimalPlaces, DocAmount, Debit, Credit)
    SELECT r.ReceiptDate, 4, r.Id, N'Receipt', r.ReceiptNumber, c.CurrencyCode, c.DecimalPlaces, r.Amount, 0, r.AmountBase
    FROM sales.Receipts r INNER JOIN masterdata.Currencies c ON c.Id = r.CurrencyId
    WHERE r.ClientId = @ClientId AND r.PostedAtUtc IS NOT NULL AND r.Status IN (2, 3);

    INSERT #E (EntryDate, SortGroup, DocumentId, EntryType, DocumentNumber, CurrencyCode, DecimalPlaces, DocAmount, Debit, Credit)
    SELECT CAST(r.ReversedAtUtc AS DATE), 5, r.Id, N'Receipt reversed', r.ReceiptNumber, c.CurrencyCode, c.DecimalPlaces, r.Amount, r.AmountBase, 0
    FROM sales.Receipts r INNER JOIN masterdata.Currencies c ON c.Id = r.CurrencyId
    WHERE r.ClientId = @ClientId AND r.Status = 3 AND r.ReversedAtUtc IS NOT NULL;

    -- Running balance over the whole history, so a period starts from the true balance brought forward.
    ;WITH R AS (
        SELECT EntryDate, SortGroup, DocumentId, Balance,
               NewBalance = SUM(Debit - Credit) OVER (ORDER BY EntryDate, SortGroup, DocumentId ROWS UNBOUNDED PRECEDING)
        FROM #E)
    UPDATE R SET Balance = NewBalance;

    DECLARE @Opening DECIMAL(18,2) = ISNULL((SELECT SUM(Debit - Credit) FROM #E WHERE @DateFrom IS NOT NULL AND EntryDate < @DateFrom), 0);

    SELECT p.Id AS ClientId, p.PartyCode AS ClientCode, p.PartyName AS ClientName, @Base AS BaseCurrencyCode,
           OpeningBalance = @Opening
    FROM masterdata.Parties p WHERE p.Id = @ClientId;

    SELECT EntryDate, EntryType, DocumentId, DocumentNumber, CurrencyCode, DecimalPlaces, DocAmount, Debit, Credit, Balance
    FROM #E
    WHERE (@DateFrom IS NULL OR EntryDate >= @DateFrom) AND (@DateTo IS NULL OR EntryDate <= @DateTo)
    ORDER BY EntryDate, SortGroup, DocumentId;
END

GO

