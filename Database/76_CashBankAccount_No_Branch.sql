SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ==================================================================================================
   76: Cash / bank accounts belong to no branch
   --------------------------------------------------------------------------------------------------
   A cash or bank account is the company's, not a branch's: any branch may receive money into it or pay
   from it. The Branch of an account is gone from Configuration › Cash / Bank Accounts, and nothing checks
   an account against a document's branch any more.

     masterdata.CashBankAccounts           BranchId emptied on every account (the column stays, unused)
     masterdata.usp_CashBankAccount_Save   @BranchId ignored (kept for older callers)
     masterdata.usp_CashBankAccount_Lookup @BranchId ignored: every account, whatever the document's branch
     sales.usp_SalesDocument_Post          no longer refuses "The account ... is not available for this
                                           invoice's branch."
     sales.usp_Receipt_Save                no longer refuses "... not available for this receipt's branch."
     purchase.usp_Payment_Save             no longer refuses "... not available for this payment's branch."

   The other account rules stay: active, and in the line's (or the invoice's) currency.
   Each procedure is re-created from its current body with only these changes. Idempotent.
   ================================================================================================== */

UPDATE masterdata.CashBankAccounts SET BranchId = NULL WHERE BranchId IS NOT NULL;
GO

CREATE OR ALTER PROCEDURE masterdata.usp_CashBankAccount_Save
    @Id          INT           = NULL,
    @AccountCode NVARCHAR(20),
    @AccountName NVARCHAR(100),
    @AccountType NVARCHAR(10),
    @CurrencyId  INT,
    @BranchId    INT           = NULL,          -- ignored since script 76: an account belongs to no branch
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
    SET @BranchId = NULL;   -- script 76: a cash / bank account belongs to no branch
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
           AND (EXISTS (SELECT 1 FROM sales.ReceiptLines WHERE CashBankAccountId = @Id)
                OR EXISTS (SELECT 1 FROM purchase.PaymentLines WHERE CashBankAccountId = @Id))
            THROW 71000, 'The currency of an account that receipts or supplier payments already use cannot be changed.', 1;

        UPDATE masterdata.CashBankAccounts
        SET AccountCode = @AccountCode, AccountName = @AccountName, AccountType = @AccountType, CurrencyId = @CurrencyId,
            BranchId = @BranchId, Description = @Description, IsActive = ISNULL(@IsActive, 1),
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;
        SET @NewId = @Id;
    END
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_CashBankAccount_Lookup
    @ActiveOnly BIT = 1,
    @CurrencyId INT = NULL,
    @BranchId   INT = NULL,     -- ignored since script 76: every account serves every branch
    @IncludeId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT a.Id, a.AccountCode, a.AccountName, a.AccountType, a.CurrencyId, c.CurrencyCode, a.BranchId, a.IsActive
    FROM masterdata.CashBankAccounts a
    INNER JOIN masterdata.Currencies c ON c.Id = a.CurrencyId
    WHERE (@ActiveOnly = 0 OR a.IsActive = 1 OR a.Id = @IncludeId)
      AND (@CurrencyId IS NULL OR a.CurrencyId = @CurrencyId OR a.Id = @IncludeId)
    ORDER BY a.AccountName;
END
GO

CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_Post
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL,
    @AcknowledgeOutOfStock BIT = 0   -- 1 = the user has seen the out-of-stock warning and chose to proceed
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Direction SMALLINT, @Number NVARCHAR(30), @DocumentDate DATE, @BranchId INT,
                @Rate DECIMAL(18,6), @SourceId INT,
                @PayType TINYINT, @MethodId INT, @AccountId INT, @PayRef NVARCHAR(100), @ClientId INT, @CurId INT, @Total DECIMAL(18,2);

        SELECT @Status = d.Status, @TypeCode = dt.Code, @Direction = dt.StockDirection, @Number = d.DocumentNumber,
               @DocumentDate = d.DocumentDate, @BranchId = d.BranchId, @Rate = d.ExchangeRate, @SourceId = d.SourceDocumentId,
               @PayType = d.PaymentType, @MethodId = d.ReceiptMethodId, @AccountId = d.ReceiptAccountId, @PayRef = d.PaymentReference,
               @ClientId = d.ClientId, @CurId = d.CurrencyId, @Total = d.TotalAmount
        FROM sales.SalesDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 64006, 'Document not found.', 1;
        IF @Status <> 1 THROW 64010, 'Only draft documents can be posted.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 64004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF NOT EXISTS (SELECT 1 FROM sales.SalesDocumentLines WHERE DocumentId = @Id)
            THROW 64009, 'The document has no lines. Add at least one item before posting.', 1;

        DECLARE @Msg NVARCHAR(400);
        SELECT TOP (1) @Msg =
            CASE WHEN i.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item ' + i.ItemCode + N' is inactive.'
                 WHEN w.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is inactive.' END
        FROM sales.SalesDocumentLines l
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id AND (i.IsActive = 0 OR w.IsActive = 0)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 64000, @Msg, 1;

        -- A parent warehouse holds no stock of its own: a line takes a warehouse at the bottom of the tree (script 70).
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' has warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree.'
        FROM sales.SalesDocumentLines l
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id AND masterdata.fn_Warehouse_IsLeaf(w.Id) = 0
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 64000, @Msg, 1;

        IF NOT EXISTS (SELECT 1 FROM sales.SalesDocuments d INNER JOIN masterdata.Parties p ON p.Id = d.ClientId WHERE d.Id = @Id AND p.IsActive = 1)
            THROW 64008, 'The client is inactive.', 1;

        /* PAYMENT TYPE IS MANDATORY, and a Cash invoice must say where the money went. Judged here, before
           anything moves, so a refusal costs nothing: the account has to hold the invoice's currency
           and be usable by its branch, exactly what the receipt will be checked for a moment later. */
        IF @TypeCode = N'SINV'
        BEGIN
            IF @PayType IS NULL THROW 64000, 'Choose a Payment Type (Cash or On Account) before posting.', 1;
            IF @PayType = 1
            BEGIN
                IF @Total <= 0 THROW 64000, 'A Cash invoice must have a total above zero.', 1;
                IF @MethodId IS NULL THROW 64000, 'A Cash invoice needs a Receipt Method.', 1;
                IF @AccountId IS NULL THROW 64000, 'A Cash invoice needs a Cash / Bank Account.', 1;
                IF NOT EXISTS (SELECT 1 FROM masterdata.PaymentMethods WHERE Id = @MethodId AND IsActive = 1)
                    THROW 64000, 'The receipt method is no longer active.', 1;
                SELECT @Msg = CASE WHEN a.IsActive = 0 THEN N'The account ' + a.AccountCode + N' is no longer active.'
                                   WHEN a.CurrencyId <> @CurId THEN N'The account ' + a.AccountCode + N' holds ' + ac.CurrencyCode
                                        + N', but this invoice is in ' + ic.CurrencyCode + N'. Choose an account in ' + ic.CurrencyCode + N'.' END
                FROM masterdata.CashBankAccounts a
                INNER JOIN masterdata.Currencies ac ON ac.Id = a.CurrencyId
                INNER JOIN masterdata.Currencies ic ON ic.Id = @CurId
                WHERE a.Id = @AccountId;
                IF @Msg IS NOT NULL THROW 64000, @Msg, 1;
            END
        END

        -- A return created from an invoice cannot exceed what that invoice line still holds.
        IF @TypeCode = N'SRET' AND @SourceId IS NOT NULL
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @SourceId AND Status = 2)
                THROW 64010, 'The original invoice is no longer posted.', 1;
            SELECT TOP (1) @Msg = N'Line ' + CAST(x.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - ' + CAST(x.Qty AS NVARCHAR(20))
                                 + N' base units returned but only ' + CAST(s.QuantityBase - s.ReturnedQuantityBase AS NVARCHAR(20)) + N' can still be returned from the invoice line.'
            FROM (SELECT SourceLineId, SUM(QuantityBase) AS Qty, MIN(LineNumber) AS LineNumber FROM sales.SalesDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x
            INNER JOIN sales.SalesDocumentLines s ON s.Id = x.SourceLineId
            INNER JOIN inventory.Items i ON i.Id = s.ItemId
            WHERE x.Qty > s.QuantityBase - s.ReturnedQuantityBase
            ORDER BY x.LineNumber;
            IF @Msg IS NOT NULL THROW 64000, @Msg, 1;
        END

        /* OUT-OF-STOCK POLICY. Every item + warehouse the invoice asks more of than the warehouse holds is a
           SHORTAGE, judged by that warehouse's policy (its own override, else the global setting):
             not allowed          -> refused outright (64007), exactly as before;
             allowed              -> refused with 64016 until the caller confirms (@AcknowledgeOutOfStock = 1),
                                     because the warning is shown even when the setting is on;
             allowed + confirmed  -> posts, stock goes negative, and each shortage is written to the audit. */
        DECLARE @Short TABLE (ItemId INT NOT NULL, WarehouseId INT NOT NULL, ItemCode NVARCHAR(30) NOT NULL, WarehouseCode NVARCHAR(20) NOT NULL,
                              Needed INT NOT NULL, OnHand INT NOT NULL, Allowed BIT NOT NULL, PolicySource NVARCHAR(10) NOT NULL);
        IF @Direction = -1
        BEGIN
            INSERT INTO @Short (ItemId, WarehouseId, ItemCode, WarehouseCode, Needed, OnHand, Allowed, PolicySource)
            SELECT x.ItemId, x.WarehouseId, i.ItemCode, w.WarehouseCode, x.Qty, inventory.fn_StockOnHand(x.ItemId, x.WarehouseId), p.Allowed, p.Source
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM sales.SalesDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            CROSS APPLY sales.fn_OutOfStockPolicy(x.WarehouseId) p
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId);

            SELECT TOP (1) @Msg = N'Insufficient stock for ' + s.ItemCode + N' in ' + s.WarehouseCode + N': available '
                                 + CAST(s.OnHand AS NVARCHAR(20)) + N', required ' + CAST(s.Needed AS NVARCHAR(20)) + N' (base units).'
            FROM @Short s WHERE s.Allowed = 0 ORDER BY s.ItemCode;
            IF @Msg IS NOT NULL THROW 64007, @Msg, 1;

            IF @AcknowledgeOutOfStock = 0 AND EXISTS (SELECT 1 FROM @Short)
            BEGIN
                DECLARE @OosMsg NVARCHAR(2000) =
                    (SELECT N'Out of stock - confirmation required: '
                            + STRING_AGG(s.ItemCode + N' in ' + s.WarehouseCode + N' (available ' + CAST(s.OnHand AS NVARCHAR(20)) + N', selling ' + CAST(s.Needed AS NVARCHAR(20)) + N')', N'; ')
                     FROM @Short s);
                THROW 64016, @OosMsg, 1;
            END
        END

        IF @Number IS NULL
            EXEC inventory.usp_DocumentType_NextNumber @TypeCode, @Number OUTPUT, @BranchId;

        -- Frozen cost snapshots: invoices take the moving average; returns keep the original invoice COGS (fallback: average).
        UPDATE l
        SET UnitCostBase = ISNULL(CASE WHEN @Direction = 1 THEN l.UnitCostBase END, ISNULL(i.AverageCost, 0)),
            FobCostAtSale = i.FobCost, LastCostAtSale = i.LastCost
        FROM sales.SalesDocumentLines l
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        WHERE l.DocumentId = @Id;

        UPDATE l
        SET NetSalesBase = ROUND(l.LineTotal / @Rate, 2),
            CogsBase = ROUND(l.QuantityBase * l.UnitCostBase, 2),
            GrossProfitBase = ROUND(l.LineTotal / @Rate, 2) - ROUND(l.QuantityBase * l.UnitCostBase, 2),
            GrossProfitPct = CASE WHEN l.LineTotal > 0 THEN ROUND(100.0 * (ROUND(l.LineTotal / @Rate, 2) - ROUND(l.QuantityBase * l.UnitCostBase, 2)) / ROUND(l.LineTotal / @Rate, 2), 2) END
        FROM sales.SalesDocumentLines l
        WHERE l.DocumentId = @Id;

        IF @Direction = 1
        BEGIN
            DECLARE @R inventory.tvp_ItemReceipt;
            INSERT INTO @R (ItemId, QuantityBase, UnitCostBase, FobCostBase)
            SELECT l.ItemId, l.QuantityBase, ISNULL(l.UnitCostBase, 0), NULL FROM sales.SalesDocumentLines l WHERE l.DocumentId = @Id;
            EXEC inventory.usp_Item_ApplyReceipts @R, NULL, @UserId, 0;
        END

        IF @Direction <> 0
        BEGIN
            DECLARE @MovementDate DATETIME2(3) =
                DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@DocumentDate AS DATETIME2(3)));

            INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                                  DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, CreatedBy)
            -- (48) the branch of the line's warehouse, which need not be the document's branch
            SELECT @MovementDate, l.ItemId, l.WarehouseId, w.BranchId, @Direction * l.QuantityBase, l.UnitCostBase,
                   N'Sales', @TypeCode, @Id, l.Id, @Number, NULL, l.ExpiryDate, @UserId
            FROM sales.SalesDocumentLines l
            INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
            WHERE l.DocumentId = @Id;
        END

        -- The confirmed out-of-stock sales, with what the warehouse holds AFTER this invoice (it may be negative).
        IF EXISTS (SELECT 1 FROM @Short)
            INSERT INTO sales.OutOfStockSaleAudit (SalesDocumentId, DocumentNumber, ItemId, ItemCode, WarehouseId, QuantitySold, StockBefore, InventoryAfter, UserId, SaleStatus, PolicySource)
            SELECT @Id, @Number, s.ItemId, s.ItemCode, s.WarehouseId, s.Needed, s.OnHand, inventory.fn_StockOnHand(s.ItemId, s.WarehouseId), @UserId, N'OutOfStockOverride', s.PolicySource
            FROM @Short s;

        IF @TypeCode = N'SRET' AND @SourceId IS NOT NULL
            UPDATE s SET ReturnedQuantityBase = s.ReturnedQuantityBase + x.Qty
            FROM sales.SalesDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM sales.SalesDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;

        UPDATE d
        SET DocumentNumber = @Number, Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId,
            TotalCostBase = ISNULL(x.Cost, 0), TotalGrossProfitBase = ISNULL(x.Gp, 0), UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        FROM sales.SalesDocuments d
        CROSS APPLY (SELECT SUM(CogsBase) AS Cost, SUM(GrossProfitBase) AS Gp FROM sales.SalesDocumentLines WHERE DocumentId = @Id) x
        WHERE d.Id = @Id;

        DECLARE @LineCount INT = (SELECT COUNT(*) FROM sales.SalesDocumentLines WHERE DocumentId = @Id);
        INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@Id, N'Posted', N'Posted as ' + @Number + N' - ' + CAST(@LineCount AS NVARCHAR(10)) + N' line(s)'
                                + CASE WHEN @Direction <> 0 THEN N' written to the stock ledger' ELSE N'' END, @UserId);

        /* A CASH INVOICE PAYS FOR ITSELF, through the receipt module and not beside it. The invoice is
           already Posted in this transaction (so it can be paid), the receipt is saved against it for
           its whole total at the invoice's own rate (so it balances to the cent) and posted, and the
           link is written. Any refusal throws, which rolls the invoice back too: both or neither. */
        IF @TypeCode = N'SINV' AND @PayType = 1
        BEGIN
            DECLARE @RcLines sales.tvp_ReceiptLine, @RcAllocs sales.tvp_ReceiptAllocation, @ReceiptId INT, @ReceiptNo NVARCHAR(30);
            DECLARE @RcNote NVARCHAR(1000) = N'Automatic receipt for invoice ' + @Number;
            INSERT INTO @RcLines (LineNumber, PaymentMethodId, CurrencyId, Amount, ExchangeRate, CashBankAccountId, Reference)
            VALUES (1, @MethodId, @CurId, @Total, @Rate, @AccountId, @PayRef);
            INSERT INTO @RcAllocs (SalesDocumentId, Amount) VALUES (@Id, @Total);

            EXEC sales.usp_Receipt_Save @Id = NULL, @ReceiptDate = @DocumentDate, @ClientId = @ClientId, @BranchId = @BranchId,
                 @PaymentType = 2, @CurrencyId = @CurId, @Amount = @Total, @ExchangeRate = @Rate, @Notes = @RcNote,
                 @Lines = @RcLines, @Allocations = @RcAllocs, @RowVersion = NULL, @UserId = @UserId, @NewId = @ReceiptId OUTPUT;

            UPDATE sales.Receipts SET SourceSalesDocumentId = @Id WHERE Id = @ReceiptId;
            SELECT @ReceiptNo = ReceiptNumber FROM sales.Receipts WHERE Id = @ReceiptId;
            INSERT INTO sales.ReceiptAudit (ReceiptId, Action, Details, UserId)
            VALUES (@ReceiptId, N'AutoCreated', N'Created automatically by posting invoice ' + @Number, @UserId);

            EXEC sales.usp_Receipt_Post @Id = @ReceiptId, @RowVersion = NULL, @UserId = @UserId;

            INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'ReceiptPosted', N'Cash sale: receipt ' + @ReceiptNo + N' posted for ' + FORMAT(@Total, N'N2', N'en-US'), @UserId);
        END

        COMMIT TRANSACTION;
        SELECT @Number AS DocumentNumber;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE sales.usp_Receipt_Save
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

CREATE OR ALTER PROCEDURE purchase.usp_Payment_Save
    @Id           INT            = NULL,           -- NULL = create
    @PaymentDate  DATE,
    @PayeeId      INT,
    @BranchId     INT,
    @PaymentType  TINYINT        = 1,              -- 1 Free Payment, 2 Purchase Invoice Payment, 3 Container Charge Payment
    @CurrencyId   INT,
    @Amount       DECIMAL(18,2),
    @ExchangeRate DECIMAL(18,6)  = NULL,           -- NULL = the official rate on the payment date
    @Reference    NVARCHAR(100)  = NULL,
    @Notes        NVARCHAR(500)  = NULL,
    @Lines        purchase.tvp_PaymentLine READONLY,
    @Allocations  purchase.tvp_PaymentAllocation READONLY,
    @AllocationContainers purchase.tvp_PaymentAllocationContainer READONLY,   -- script 73: the container split of the invoice allocations
    @RowVersion   BINARY(8)      = NULL,
    @UserId       INT            = NULL,
    @NewId        INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    SET @Reference = NULLIF(LTRIM(RTRIM(@Reference)), N'');
    SET @PaymentType = ISNULL(@PaymentType, 1);

    IF @PaymentDate IS NULL THROW 73000, 'Payment Date is required.', 1;
    -- A day of tolerance, as on the invoices: the date is the reader's local one, the check is UTC.
    IF @PaymentDate > DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE)) THROW 73000, 'Payment Date cannot be in the future.', 1;
    IF @PayeeId IS NULL OR NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @PayeeId AND IsSupplier = 1 AND IsActive = 1)
        THROW 73000, 'Payee not found, inactive, or not a supplier.', 1;
    IF @BranchId IS NULL OR NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 73000, 'Branch not found or inactive.', 1;
    IF @PaymentType NOT IN (1, 2, 3) THROW 73000, 'Payment Type must be Free Payment, Purchase Invoice Payment or Container Charge Payment.', 1;
    IF @CurrencyId IS NULL OR NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsActive = 1)
        THROW 73000, 'Payment Currency not found or inactive.', 1;
    IF @Amount IS NULL OR @Amount <= 0 THROW 73000, 'Payment Amount must be greater than zero.', 1;
    IF @ExchangeRate IS NOT NULL AND @ExchangeRate <= 0 THROW 73000, 'Exchange rate must be greater than zero.', 1;

    /* THE HEADER RATE. The base currency is always 1, whatever was typed; any other takes what was typed,
       else the official rate on the payment date, else it is an error the reader can fix. */
    IF EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsBaseCurrency = 1) SET @ExchangeRate = 1;
    SET @ExchangeRate = COALESCE(@ExchangeRate, masterdata.fn_GetRate(@CurrencyId, 1, @PaymentDate));
    IF @ExchangeRate IS NULL
    BEGIN
        DECLARE @RateMsg NVARCHAR(300) = N'No official exchange rate is defined for ' + (SELECT CurrencyCode FROM masterdata.Currencies WHERE Id = @CurrencyId)
            + N' on or before ' + CONVERT(NVARCHAR(10), @PaymentDate, 120) + N'. Add one in Master Data > Exchange Rates or enter the rate manually.';
        THROW 73000, @RateMsg, 1;
    END

    /* EVERY LINE IS JUDGED, and the first failing one is named. */
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
             WHEN l.RateToPayment IS NOT NULL AND l.RateToPayment <= 0 THEN N'exchange rate must be greater than zero.'
             WHEN a.Id IS NULL OR a.IsActive = 0 THEN N'cash / bank account not found or inactive.'
             WHEN a.CurrencyId <> l.CurrencyId THEN N'account ' + a.AccountCode + N' holds ' + ac.CurrencyCode + N', not ' + cu.CurrencyCode + N'.'
             WHEN pm.MethodCode = N'CHQ' AND NULLIF(LTRIM(RTRIM(l.ChequeNo)), N'') IS NULL THEN N'a cheque needs its Cheque No.'
             WHEN pm.MethodCode = N'CHQ' AND l.ChequeDate IS NULL THEN N'a cheque needs its Cheque Date.'
             WHEN pm.MethodCode = N'CHQ' AND l.ChequeDueDate IS NOT NULL AND l.ChequeDueDate < l.ChequeDate THEN N'the cheque''s due date is before its date.'
             WHEN l.RateToPayment IS NULL AND purchase.fn_RateToPayment(l.CurrencyId, @CurrencyId, @ExchangeRate, @PaymentDate) IS NULL
                  THEN N'no official exchange rate is defined for ' + cu.CurrencyCode + N' on or before ' + CONVERT(NVARCHAR(10), @PaymentDate, 120) + N'.'
        END) x
    WHERE x.Problem IS NOT NULL
    ORDER BY l.LineNumber;
    IF @Msg IS NOT NULL THROW 73000, @Msg, 1;

    /* ALLOCATIONS: none on a Free payment; only the type's own kind of document otherwise - a payment never
       mixes invoices and charges. Only POSTED documents of THIS payee, never above what they still owe
       (posted payments only: a competing draft is settled under a lock when one of them posts). */
    IF @PaymentType = 1 AND EXISTS (SELECT 1 FROM @Allocations)
        THROW 73000, 'A Free Payment cannot be allocated to documents. Choose Purchase Invoice or Container Charge Payment, or allocate it after posting.', 1;
    IF @PaymentType = 2 AND EXISTS (SELECT 1 FROM @Allocations WHERE DocumentKind <> N'PINV')
        THROW 73000, 'A Purchase Invoice Payment can only be allocated to purchase invoices.', 1;
    IF @PaymentType = 3 AND EXISTS (SELECT 1 FROM @Allocations WHERE DocumentKind <> N'CHARGE')
        THROW 73000, 'A Container Charge Payment can only be allocated to container charges.', 1;

    SELECT TOP (1) @Msg = CASE a.DocumentKind WHEN N'PINV' THEN N'Purchase invoice ' ELSE N'Charge ' END
                          + ISNULL(pd.DocumentNumber, N'#' + CAST(a.DocumentId AS NVARCHAR(10))) + N': ' + x.Problem
    FROM @Allocations a
    OUTER APPLY purchase.fn_PayableDocument(a.DocumentKind, a.DocumentId) pd
    CROSS APPLY (SELECT Problem =
        CASE WHEN pd.DocumentId IS NULL THEN N'not found.'
             WHEN pd.PaymentStatus IS NULL THEN N'only a posted document can be paid.'
             WHEN ISNULL(pd.PayeeId, -1) <> @PayeeId THEN N'it does not belong to this payee.'
             WHEN a.Amount IS NULL OR a.Amount <= 0 THEN N'the allocated amount must be greater than zero.'
             WHEN a.RateToPayment IS NOT NULL AND a.RateToPayment <= 0 THEN N'exchange rate must be greater than zero.'
             WHEN a.RateToPayment IS NULL AND purchase.fn_RateToPayment(pd.CurrencyId, @CurrencyId, @ExchangeRate, @PaymentDate) IS NULL
                  THEN N'no official exchange rate is defined for ' + pd.CurrencyCode + N' on or before ' + CONVERT(NVARCHAR(10), @PaymentDate, 120) + N'.'
        END) x
    WHERE x.Problem IS NOT NULL
    ORDER BY a.DocumentKind, a.DocumentId;
    IF @Msg IS NOT NULL THROW 73000, @Msg, 1;

    SELECT TOP (1) @Msg = CASE a.DocumentKind WHEN N'PINV' THEN N'Purchase invoice ' ELSE N'Charge ' END + pd.DocumentNumber + N': '
                          + FORMAT(a.Amount, N'N2', N'en-US') + N' is more than its outstanding ' + FORMAT(pd.OutstandingAmount, N'N2', N'en-US') + N' ' + pd.CurrencyCode + N'.'
    FROM @Allocations a
    CROSS APPLY purchase.fn_PayableDocument(a.DocumentKind, a.DocumentId) pd
    WHERE a.Amount > pd.OutstandingAmount + 0.005
    ORDER BY a.DocumentKind, a.DocumentId;
    IF @Msg IS NOT NULL THROW 73009, @Msg, 1;

    -- Script 73: the container split may be incomplete on a draft, never wrong.
    -- One container and nothing else: the whole amount is that container's, without a split typed by hand.
    DECLARE @Split purchase.tvp_PaymentAllocationContainer;
    INSERT INTO @Split (DocumentId, ContainerId, Amount) SELECT DocumentId, ContainerId, Amount FROM @AllocationContainers;
    INSERT INTO @Split (DocumentId, ContainerId, Amount)
    SELECT a.DocumentId, s.ContainerKey, a.Amount
    FROM @Allocations a
    CROSS APPLY purchase.fn_InvoiceContainerSettlement(a.DocumentId) s
    WHERE a.DocumentKind = N'PINV' AND s.HasContainers = 1 AND s.NeedsSplit = 0 AND a.Amount > 0
      AND NOT EXISTS (SELECT 1 FROM @AllocationContainers c WHERE c.DocumentId = a.DocumentId);
    EXEC purchase.usp_Payment_CheckContainerSplit @Allocations, @Split, 0;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Id IS NULL
        BEGIN
            -- Numbered at the FIRST SAVE, inside this transaction: a save that fails gives the number back.
            DECLARE @Number NVARCHAR(30);
            EXEC inventory.usp_DocumentType_NextNumber @Code = N'PAY', @DocumentNumber = @Number OUTPUT;

            INSERT INTO purchase.Payments (PaymentNumber, PaymentDate, PayeeId, BranchId, PaymentType, CurrencyId, Amount, ExchangeRate, Reference, Notes, Status, CreatedBy)
            VALUES (@Number, @PaymentDate, @PayeeId, @BranchId, @PaymentType, @CurrencyId, @Amount, @ExchangeRate, @Reference, @Notes, 1, @UserId);
            SET @Id = SCOPE_IDENTITY();

            INSERT INTO purchase.PaymentAudit (PaymentId, Action, Details, UserId) VALUES (@Id, N'Created', N'Draft ' + @Number, @UserId);
        END
        ELSE
        BEGIN
            DECLARE @Status TINYINT;
            SELECT @Status = Status FROM purchase.Payments WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
            IF @Status IS NULL THROW 73006, 'Payment not found.', 1;
            IF @Status <> 1 THROW 73005, 'Only a draft payment can be edited.', 1;
            IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.Payments WHERE Id = @Id AND RowVersion = @RowVersion)
                THROW 73004, 'This payment was modified by another user. Reload the page and try again.', 1;

            UPDATE purchase.Payments
            SET PaymentDate = @PaymentDate, PayeeId = @PayeeId, BranchId = @BranchId, PaymentType = @PaymentType,
                CurrencyId = @CurrencyId, Amount = @Amount, ExchangeRate = @ExchangeRate, Reference = @Reference, Notes = @Notes,
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;

            DELETE FROM purchase.PaymentAllocations WHERE PaymentId = @Id;
            DELETE FROM purchase.PaymentLines WHERE PaymentId = @Id;

            INSERT INTO purchase.PaymentAudit (PaymentId, Action, Details, UserId)
            VALUES (@Id, N'Updated', N'Header, ' + CAST((SELECT COUNT(*) FROM @Lines) AS NVARCHAR(10)) + N' payment line(s) and '
                    + CAST((SELECT COUNT(*) FROM @Allocations) AS NVARCHAR(10)) + N' allocation(s) saved', @UserId);
        END

        -- A cheque line starts Pending; any other line carries no cheque fields, whatever was sent.
        INSERT INTO purchase.PaymentLines (PaymentId, LineNumber, PaymentMethodId, CurrencyId, Amount, RateToPayment, CashBankAccountId, Reference,
                                           ChequeNo, ChequeDate, ChequeDueDate, ClearanceStatus)
        SELECT @Id, l.LineNumber, l.PaymentMethodId, l.CurrencyId, l.Amount,
               CASE WHEN l.CurrencyId = @CurrencyId THEN 1 ELSE COALESCE(l.RateToPayment, purchase.fn_RateToPayment(l.CurrencyId, @CurrencyId, @ExchangeRate, @PaymentDate)) END,
               l.CashBankAccountId, NULLIF(LTRIM(RTRIM(l.Reference)), N''),
               CASE WHEN pm.MethodCode = N'CHQ' THEN NULLIF(LTRIM(RTRIM(l.ChequeNo)), N'') END,
               CASE WHEN pm.MethodCode = N'CHQ' THEN l.ChequeDate END,
               CASE WHEN pm.MethodCode = N'CHQ' THEN l.ChequeDueDate END,
               CASE WHEN pm.MethodCode = N'CHQ' THEN 1 END
        FROM @Lines l
        INNER JOIN masterdata.PaymentMethods pm ON pm.Id = l.PaymentMethodId;

        -- The base value of each line, at the header's rate.
        UPDATE purchase.PaymentLines SET AmountBase = CONVERT(DECIMAL(18,2), ROUND(AmountPaymentCurrency / @ExchangeRate, 2)) WHERE PaymentId = @Id;

        -- THE DOCUMENT'S OWN RATE IS SNAPSHOTTED, so the base value of an allocation can never move.
        INSERT INTO purchase.PaymentAllocations (PaymentId, DocumentKind, PurchaseDocumentId, ContainerChargeId, AmountDocCurrency, DocExchangeRate, RateToPayment, AllocatedBy)
        SELECT @Id, a.DocumentKind,
               CASE WHEN a.DocumentKind = N'PINV' THEN a.DocumentId END,
               CASE WHEN a.DocumentKind = N'CHARGE' THEN a.DocumentId END,
               a.Amount, pd.ExchangeRate,
               CASE WHEN pd.CurrencyId = @CurrencyId THEN 1 ELSE COALESCE(a.RateToPayment, purchase.fn_RateToPayment(pd.CurrencyId, @CurrencyId, @ExchangeRate, @PaymentDate)) END,
               @UserId
        FROM @Allocations a
        CROSS APPLY purchase.fn_PayableDocument(a.DocumentKind, a.DocumentId) pd;

        -- Script 73: the container split, under the allocation of its invoice (zero amounts are not kept).
        INSERT INTO purchase.PaymentAllocationContainers (PaymentAllocationId, ContainerId, AmountDocCurrency)
        SELECT al.Id, NULLIF(c.ContainerId, 0), c.Amount
        FROM @Split c
        INNER JOIN purchase.PaymentAllocations al ON al.PaymentId = @Id AND al.PurchaseDocumentId = c.DocumentId AND al.RemovedAtUtc IS NULL
        WHERE c.Amount > 0;

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

PRINT 'Script 76 applied: cash / bank accounts belong to no branch.';
GO
