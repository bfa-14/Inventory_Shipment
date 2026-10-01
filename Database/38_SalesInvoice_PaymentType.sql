/* ==================================================================================================
   38: Sales invoice - Payment Type and the automatic cash receipt (US-SAL-002)
   --------------------------------------------------------------------------------------------------
   A sales invoice is paid either in CASH or ON ACCOUNT.

     Cash        Posting the invoice also creates and posts a RECEIPT for its whole total, through the
                 receipt module (usp_Receipt_Save + usp_Receipt_Post), links it to the invoice and so
                 leaves it Paid. It happens inside the invoice's own transaction: if the receipt is
                 refused, the invoice is not posted either.
     On Account  Posted with no receipt; Unpaid until receipts are allocated to it, as before.

   WHAT IT CHANGES
     - sales.SalesDocuments: PaymentType (1 Cash, 2 On Account), ReceiptMethodId, ReceiptAccountId,
       PaymentReference. Existing posted / cancelled invoices are backfilled to On Account, which is
       what they always were. Existing DRAFTS stay empty: the user must choose before posting.
     - sales.Receipts.SourceSalesDocumentId: the invoice an automatic receipt was created for. Unique,
       so a receipt is created ONCE per invoice; the invoice finds its receipt through it, nothing
       is stored twice.
     - usp_SalesDocument_Save   keeps the four payment fields (a save never creates a receipt).
     - usp_SalesDocument_Post   refuses a missing Payment Type / incomplete Cash details, and creates
                                the receipt for Cash.
     - usp_SalesDocument_Cancel reverses the automatic receipt together with the invoice (reason is
                                carried to the receipt); receipts from anywhere else still block it.
     - usp_Receipt_Reverse      refuses to reverse an automatic receipt on its own (71015): cancel the
                                invoice instead. Only the invoice cancellation can pass the flag.
     - Get / Search of invoices and receipts expose the link both ways; invoice search filters by
       @PaymentType.

   Requires scripts 17-36. Idempotent.
   ================================================================================================== */

/* ================================================================== 1. Columns */

IF COL_LENGTH('sales.SalesDocuments', 'PaymentType') IS NULL
BEGIN
    ALTER TABLE sales.SalesDocuments ADD PaymentType TINYINT NULL;
    PRINT 'Added sales.SalesDocuments.PaymentType';
END
GO
IF COL_LENGTH('sales.SalesDocuments', 'ReceiptMethodId') IS NULL
    ALTER TABLE sales.SalesDocuments ADD ReceiptMethodId INT NULL;
GO
IF COL_LENGTH('sales.SalesDocuments', 'ReceiptAccountId') IS NULL
    ALTER TABLE sales.SalesDocuments ADD ReceiptAccountId INT NULL;
GO
IF COL_LENGTH('sales.SalesDocuments', 'PaymentReference') IS NULL
    ALTER TABLE sales.SalesDocuments ADD PaymentReference NVARCHAR(100) NULL;
GO
IF COL_LENGTH('sales.Receipts', 'SourceSalesDocumentId') IS NULL
BEGIN
    ALTER TABLE sales.Receipts ADD SourceSalesDocumentId INT NULL;
    PRINT 'Added sales.Receipts.SourceSalesDocumentId';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_SalesDocuments_PaymentType' AND parent_object_id = OBJECT_ID(N'sales.SalesDocuments'))
    ALTER TABLE sales.SalesDocuments ADD CONSTRAINT CK_SalesDocuments_PaymentType CHECK (PaymentType IS NULL OR PaymentType IN (1, 2));
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_SalesDocuments_ReceiptMethod')
    ALTER TABLE sales.SalesDocuments ADD CONSTRAINT FK_SalesDocuments_ReceiptMethod FOREIGN KEY (ReceiptMethodId) REFERENCES masterdata.PaymentMethods (Id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_SalesDocuments_ReceiptAccount')
    ALTER TABLE sales.SalesDocuments ADD CONSTRAINT FK_SalesDocuments_ReceiptAccount FOREIGN KEY (ReceiptAccountId) REFERENCES masterdata.CashBankAccounts (Id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_Receipts_SourceSalesDocument')
    ALTER TABLE sales.Receipts ADD CONSTRAINT FK_Receipts_SourceSalesDocument FOREIGN KEY (SourceSalesDocumentId) REFERENCES sales.SalesDocuments (Id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_Receipts_SourceSalesDocument' AND object_id = OBJECT_ID(N'sales.Receipts'))
    CREATE UNIQUE INDEX UX_Receipts_SourceSalesDocument ON sales.Receipts (SourceSalesDocumentId) WHERE SourceSalesDocumentId IS NOT NULL;
GO

/* Backfill: every invoice that was ever posted was, in effect, On Account. */
UPDATE d SET PaymentType = 2
FROM sales.SalesDocuments d
INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId AND dt.Code = N'SINV'
WHERE d.PaymentType IS NULL AND d.Status IN (2, 3);
GO

/* ================================================================== 2. Procedures */


CREATE OR ALTER PROCEDURE sales.usp_Receipt_Reverse
    @Id         INT,
    @Reason     NVARCHAR(500),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL,
    /* ONLY THE INVOICE CANCELLATION PASSES 1. Nothing the API sends can set it, so a receipt that an
       invoice created cannot be reversed from the receipt screen - see the guard below. */
    @FromInvoiceCancel BIT    = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 71000, 'A reason is required to reverse a receipt.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @Type TINYINT;
        SELECT @Status = Status, @Type = PaymentType FROM sales.Receipts WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;

        IF @Status IS NULL THROW 71006, 'Receipt not found.', 1;
        IF @Status <> 2 THROW 71010, 'Only a posted receipt can be reversed.', 1;

        /* A CASH INVOICE'S RECEIPT IS PART OF THE INVOICE. Reversing it alone would leave an invoice
           that says "Cash" and owes the whole amount. The way to undo it is to cancel the invoice,
           which reverses this receipt in the same transaction and says why. */
        DECLARE @SourceInvoiceId INT = (SELECT SourceSalesDocumentId FROM sales.Receipts WHERE Id = @Id);
        IF @SourceInvoiceId IS NOT NULL AND ISNULL(@FromInvoiceCancel, 0) = 0
        BEGIN
            DECLARE @AutoMsg NVARCHAR(300) = N'This receipt was created automatically when invoice '
                + ISNULL((SELECT DocumentNumber FROM sales.SalesDocuments WHERE Id = @SourceInvoiceId), N'#' + CAST(@SourceInvoiceId AS NVARCHAR(10)))
                + N' was posted. Cancel that invoice to reverse it.';
            THROW 71015, @AutoMsg, 1;
        END
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sales.Receipts WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 71004, 'This receipt was modified by another user. Reload the page and try again.', 1;

        /* A FREE RECEIPT THAT HAS SINCE PAID INVOICES CANNOT JUST VANISH. Those invoices would go back
           to owing money nobody told them about. The allocations have to be removed first, so somebody
           chooses what happens to each invoice. A Sales Allocation receipt's own allocations are part
           of it: reversing it simply stops them counting. */
        IF @Type = 1 AND EXISTS (SELECT 1 FROM sales.ReceiptAllocations WHERE ReceiptId = @Id AND RemovedAtUtc IS NULL)
            THROW 71012, 'This receipt has been applied to invoices since it was posted. Remove those allocations before reversing it.', 1;

        UPDATE sales.Receipts
        SET Status = 3, ReversedAtUtc = SYSUTCDATETIME(), ReversedBy = @UserId, ReverseReason = @Reason,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO sales.ReceiptAudit (ReceiptId, Action, Details, UserId) VALUES (@Id, N'Reversed', @Reason, @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE sales.usp_Receipt_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT r.Id, r.ReceiptNumber, r.ReceiptDate, r.ClientId, cl.PartyCode AS ClientCode, cl.PartyName AS ClientName, cl.Address AS ClientAddress,
           r.BranchId, b.BranchCode, b.BranchName, r.PaymentType,
           r.CurrencyId, c.CurrencyCode, c.CurrencyName, c.Symbol AS CurrencySymbol, c.DecimalPlaces, c.IsBaseCurrency,
           r.Amount, r.ExchangeRate, r.AmountBase, bc.CurrencyCode AS BaseCurrencyCode,
           r.Notes, r.Status,
           r.SourceSalesDocumentId, SourceInvoiceNumber = sd.DocumentNumber,
           LinesBase = ISNULL(ln.Base, 0),
           AllocatedBase = ISNULL(al.Base, 0),
           -- Only a posted FREE receipt holds credit; a Sales Allocation one is spent by definition.
           UnappliedBase = CASE WHEN r.Status = 2 AND r.PaymentType = 1 THEN r.AmountBase - ISNULL(al.Base, 0) ELSE 0 END,
           r.PostedAtUtc, r.PostedBy, pu.FullName AS PostedByName,
           r.ReversedAtUtc, r.ReversedBy, ru.FullName AS ReversedByName, r.ReverseReason,
           r.CreatedAtUtc, r.CreatedBy, cu.FullName AS CreatedByName, r.UpdatedAtUtc, r.UpdatedBy, uu.FullName AS UpdatedByName,
           r.RowVersion
    FROM sales.Receipts r
    INNER JOIN masterdata.Parties cl    ON cl.Id = r.ClientId
    INNER JOIN masterdata.Branches b    ON b.Id = r.BranchId
    INNER JOIN masterdata.Currencies c  ON c.Id = r.CurrencyId
    LEFT  JOIN masterdata.Currencies bc ON bc.IsBaseCurrency = 1 AND bc.IsActive = 1
    OUTER APPLY (SELECT Base = SUM(AmountBase) FROM sales.ReceiptLines WHERE ReceiptId = r.Id) ln
    OUTER APPLY (SELECT Base = SUM(AmountBase) FROM sales.ReceiptAllocations WHERE ReceiptId = r.Id AND RemovedAtUtc IS NULL) al
    LEFT  JOIN security.Users pu ON pu.Id = r.PostedBy
    LEFT  JOIN security.Users ru ON ru.Id = r.ReversedBy
    LEFT  JOIN security.Users cu ON cu.Id = r.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = r.UpdatedBy
    LEFT  JOIN sales.SalesDocuments sd ON sd.Id = r.SourceSalesDocumentId
    WHERE r.Id = @Id;

    SELECT l.Id, l.ReceiptId, l.LineNumber, l.PaymentMethodId, pm.MethodCode, pm.MethodName,
           l.CurrencyId, cu.CurrencyCode, cu.DecimalPlaces, l.Amount, l.ExchangeRate, l.AmountBase,
           l.CashBankAccountId, a.AccountCode, a.AccountName, l.Reference
    FROM sales.ReceiptLines l
    INNER JOIN masterdata.PaymentMethods pm  ON pm.Id = l.PaymentMethodId
    INNER JOIN masterdata.Currencies cu      ON cu.Id = l.CurrencyId
    INNER JOIN masterdata.CashBankAccounts a ON a.Id = l.CashBankAccountId
    WHERE l.ReceiptId = @Id
    ORDER BY l.LineNumber;

    SELECT al.Id, al.ReceiptId, al.SalesDocumentId, d.DocumentNumber AS InvoiceNumber, d.DocumentDate AS InvoiceDate,
           d.CurrencyId AS InvoiceCurrencyId, ic.CurrencyCode AS InvoiceCurrencyCode, ic.DecimalPlaces AS InvoiceDecimalPlaces,
           InvoiceTotal = d.TotalAmount,
           al.AmountInvoiceCurrency, al.InvoiceExchangeRate, al.AmountBase,
           al.AllocatedAtUtc, au.FullName AS AllocatedByName, al.RemovedAtUtc, xu.FullName AS RemovedByName
    FROM sales.ReceiptAllocations al
    INNER JOIN sales.SalesDocuments d ON d.Id = al.SalesDocumentId
    INNER JOIN masterdata.Currencies ic ON ic.Id = d.CurrencyId
    LEFT  JOIN security.Users au ON au.Id = al.AllocatedBy
    LEFT  JOIN security.Users xu ON xu.Id = al.RemovedBy
    WHERE al.ReceiptId = @Id
    ORDER BY al.AllocatedAtUtc, al.Id;

    SELECT f.Id, f.ReceiptId, f.AttachmentTypeId, t.Category, t.SubType, f.Note, f.FileName, f.ContentType, f.SizeBytes,
           f.CreatedAtUtc, u.FullName AS CreatedByName
    FROM sales.ReceiptFiles f
    LEFT JOIN masterdata.AttachmentTypes t ON t.Id = f.AttachmentTypeId
    LEFT JOIN security.Users u ON u.Id = f.CreatedBy
    WHERE f.ReceiptId = @Id
    ORDER BY f.CreatedAtUtc, f.Id;

    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM sales.ReceiptAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.ReceiptId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;
END
GO

CREATE OR ALTER PROCEDURE sales.usp_Receipt_Search
    @Search        NVARCHAR(100) = NULL,           -- number, customer code / name, notes
    @ClientId      INT           = NULL,
    @BranchId      INT           = NULL,
    @Status        TINYINT       = NULL,           -- 1 Draft | 2 Posted | 3 Reversed
    @PaymentType   TINYINT       = NULL,           -- 1 Free Receipt | 2 Sales Allocation
    @CurrencyId    INT           = NULL,
    @DateFrom      DATE          = NULL,
    @DateTo        DATE          = NULL,
    @SortColumn    NVARCHAR(30)  = N'ReceiptDate', -- ReceiptNumber | ReceiptDate | ClientName | Status | AmountBase | CreatedAtUtc
    @SortDirection NVARCHAR(4)   = N'DESC',
    @PageNumber    INT           = 1,
    @PageSize      INT           = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'ReceiptNumber', N'ReceiptDate', N'ClientName', N'Status', N'AmountBase', N'CreatedAtUtc')
        SET @SortColumn = N'ReceiptDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT r.Id, r.ReceiptNumber, r.ReceiptDate, r.ClientId, cl.PartyCode AS ClientCode, cl.PartyName AS ClientName,
           r.BranchId, b.BranchName, r.PaymentType, r.CurrencyId, c.CurrencyCode, c.DecimalPlaces,
           r.Amount, r.ExchangeRate, r.AmountBase, r.Status,
           r.SourceSalesDocumentId, SourceInvoiceNumber = sd.DocumentNumber,
           AllocatedBase = ISNULL(al.Base, 0),
           UnappliedBase = CASE WHEN r.Status = 2 AND r.PaymentType = 1 THEN r.AmountBase - ISNULL(al.Base, 0) ELSE 0 END,
           r.PostedAtUtc, pu.FullName AS PostedByName, r.ReversedAtUtc,
           r.CreatedAtUtc, cu.FullName AS CreatedByName, r.UpdatedAtUtc, r.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM sales.Receipts r
    INNER JOIN masterdata.Parties cl   ON cl.Id = r.ClientId
    INNER JOIN masterdata.Branches b   ON b.Id = r.BranchId
    INNER JOIN masterdata.Currencies c ON c.Id = r.CurrencyId
    OUTER APPLY (SELECT Base = SUM(AmountBase) FROM sales.ReceiptAllocations WHERE ReceiptId = r.Id AND RemovedAtUtc IS NULL) al
    LEFT  JOIN security.Users cu ON cu.Id = r.CreatedBy
    LEFT  JOIN security.Users pu ON pu.Id = r.PostedBy
    LEFT  JOIN sales.SalesDocuments sd ON sd.Id = r.SourceSalesDocumentId
    WHERE (@Search IS NULL OR r.ReceiptNumber LIKE N'%' + @Search + N'%' OR cl.PartyCode LIKE N'%' + @Search + N'%'
           OR cl.PartyName LIKE N'%' + @Search + N'%' OR r.Notes LIKE N'%' + @Search + N'%')
      AND (@ClientId IS NULL OR r.ClientId = @ClientId)
      AND (@BranchId IS NULL OR r.BranchId = @BranchId)
      AND (@Status IS NULL OR r.Status = @Status)
      AND (@PaymentType IS NULL OR r.PaymentType = @PaymentType)
      AND (@CurrencyId IS NULL OR r.CurrencyId = @CurrencyId)
      AND (@DateFrom IS NULL OR r.ReceiptDate >= @DateFrom)
      AND (@DateTo IS NULL OR r.ReceiptDate <= @DateTo)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'ReceiptNumber' THEN r.ReceiptNumber WHEN N'ClientName' THEN cl.PartyName END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'ReceiptNumber' THEN r.ReceiptNumber WHEN N'ClientName' THEN cl.PartyName END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'ReceiptDate' THEN r.ReceiptDate END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'ReceiptDate' THEN r.ReceiptDate END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Status' THEN CAST(r.Status AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Status' THEN CAST(r.Status AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'AmountBase' THEN r.AmountBase END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'AmountBase' THEN r.AmountBase END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN r.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN r.CreatedAtUtc END DESC,
        r.ReceiptDate DESC, r.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_Save
    @Id                 INT            = NULL,
    @DocumentTypeCode   NVARCHAR(20)   = N'SINV',
    @DocumentDate       DATE,
    @DueDate            DATE           = NULL,
    @BranchId           INT,
    @WarehouseId        INT = NULL,
    @ClientId           INT,
    @SalesmanId         INT            = NULL,
    @PriceListId        INT,
    /* The currency the customer is billed in. NULL = the price list's, which is how it has always
       worked; a different one converts every list price with the two rates. */
    @CurrencyId         INT            = NULL,
    @RateType           TINYINT        = 1,
    @ExchangeRate       DECIMAL(18,6)  = NULL,
    @ReferenceNo        NVARCHAR(100)  = NULL,
    @Notes              NVARCHAR(1000) = NULL,
    @Lines              sales.tvp_SalesDocumentLine READONLY,
    @AllowPriceOverride BIT            = 0,
    @MaxDiscountPercent DECIMAL(9,4)   = 100,
    @DraftReference     NVARCHAR(50)   = NULL,
    /* HOW THE CUSTOMER PAYS: 1 Cash (a receipt is created and posted with the invoice), 2 On Account
       (paid later by receipts). The method, account and reference only mean something for Cash. */
    @PaymentType        TINYINT        = NULL,
    @ReceiptMethodId    INT            = NULL,
    @ReceiptAccountId   INT            = NULL,
    @PaymentReference   NVARCHAR(100)  = NULL,
    @RowVersion         BINARY(8)      = NULL,
    @UserId             INT            = NULL,
    @NewId              INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* The warehouse lives on the LINES. The header keeps one so that document lists, filters,
       reports and exports still have a warehouse to show; when the caller does not send one it is
       taken from the first line. */
    IF @WarehouseId IS NULL
        SELECT TOP (1) @WarehouseId = WarehouseId FROM @Lines ORDER BY LineNumber;

    SET @ReferenceNo = NULLIF(LTRIM(RTRIM(@ReferenceNo)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    SET @DraftReference = NULLIF(LTRIM(RTRIM(@DraftReference)), N'');

    DECLARE @TypeId INT, @Direction SMALLINT, @ResolvedCurrencyId INT, @Rate DECIMAL(18,6), @PriceRate DECIMAL(18,6);
    /* NAMED ARGUMENTS: the validator has grown two parameters and a positional call would quietly
       hand them the wrong values. */
    EXEC sales.usp_SalesDocument_ValidateInput
         @DocumentTypeCode = @DocumentTypeCode, @DocumentDate = @DocumentDate, @DueDate = @DueDate,
         @BranchId = @BranchId, @WarehouseId = @WarehouseId, @ClientId = @ClientId, @SalesmanId = @SalesmanId,
         @PriceListId = @PriceListId, @RateType = @RateType, @ExchangeRate = @ExchangeRate,
         @MaxDiscountPercent = @MaxDiscountPercent, @Lines = @Lines,
         @InvoiceCurrencyId = @CurrencyId,
         @DocumentTypeId = @TypeId OUTPUT, @StockDirection = @Direction OUTPUT,
         @CurrencyId = @ResolvedCurrencyId OUTPUT, @ResolvedRate = @Rate OUTPUT, @PriceRate = @PriceRate OUTPUT;

    -- From here on the invoice's currency is the resolved one.
    SET @CurrencyId = @ResolvedCurrencyId;

    /* PAYMENT TYPE. Only a sales invoice has one - a return is not paid for. Saving a draft only keeps
       what was chosen (and refuses nonsense); whether the choice is COMPLETE is judged on posting, so
       a draft can be saved half-filled like everything else here. Nothing is created by a save. */
    IF @DocumentTypeCode <> N'SINV' SET @PaymentType = NULL;
    IF @PaymentType IS NOT NULL AND @PaymentType NOT IN (1, 2) THROW 64000, 'Payment Type must be Cash or On Account.', 1;
    SET @PaymentReference = NULLIF(LTRIM(RTRIM(@PaymentReference)), N'');
    IF ISNULL(@PaymentType, 0) <> 1
        SELECT @ReceiptMethodId = NULL, @ReceiptAccountId = NULL, @PaymentReference = NULL;
    ELSE
    BEGIN
        IF @ReceiptMethodId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.PaymentMethods WHERE Id = @ReceiptMethodId AND IsActive = 1)
            THROW 64000, 'The receipt method was not found or is inactive.', 1;
        IF @ReceiptAccountId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.CashBankAccounts WHERE Id = @ReceiptAccountId AND IsActive = 1)
            THROW 64000, 'The cash / bank account was not found or is inactive.', 1;
    END

    -- Source links of a return draft (SINV -> SRET) survive a re-save: kept by line number + item.
    DECLARE @Kept TABLE (LineNumber INT PRIMARY KEY, ItemId INT, SourceLineId INT, UnitCostBase DECIMAL(18,6));

    IF @Id IS NOT NULL
    BEGIN
        DECLARE @Status TINYINT = (SELECT Status FROM sales.SalesDocuments WHERE Id = @Id);
        IF @Status IS NULL THROW 64006, 'Document not found.', 1;
        IF @Status <> 1 THROW 64005, 'Only draft documents can be edited.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 64004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @Id AND DocumentTypeId <> @TypeId)
            THROW 64000, 'The document type cannot be changed.', 1;
        INSERT INTO @Kept (LineNumber, ItemId, SourceLineId, UnitCostBase)
        SELECT LineNumber, ItemId, SourceLineId, UnitCostBase FROM sales.SalesDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL;
    END

    DECLARE @Priced TABLE
    (
        LineNumber INT PRIMARY KEY, ItemId INT, ItemUnitId INT, WarehouseId INT, Specification NVARCHAR(100) NULL, ExpiryDate DATE, Quantity INT, PackingFormula INT,
        UnitPrice DECIMAL(18,4) NULL, SystemPrice DECIMAL(18,4) NULL, DiscountPercent DECIMAL(9,4), ImportRowNumber INT, Notes NVARCHAR(300)
    );
    INSERT INTO @Priced (LineNumber, ItemId, ItemUnitId, WarehouseId, Specification, ExpiryDate, Quantity, PackingFormula, UnitPrice, SystemPrice, DiscountPercent, ImportRowNumber, Notes)
    SELECT l.LineNumber, l.ItemId, l.ItemUnitId, l.WarehouseId, NULLIF(LTRIM(RTRIM(l.Specification)), N''), l.ExpiryDate, l.Quantity, iu.PackingFormula,
           CASE WHEN @AllowPriceOverride = 1 AND l.UnitPrice IS NOT NULL THEN l.UnitPrice ELSE sp.Price END,
           sp.Price, ISNULL(l.DiscountPercent, 0), l.ImportRowNumber, NULLIF(LTRIM(RTRIM(l.Notes)), N'')
    FROM @Lines l
    INNER JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId
    /* THE LIST PRICE, CONVERTED INTO THE INVOICE CURRENCY. fn_GetUnitPrice answers in the price
       list's currency; dividing by its rate gives the base currency and multiplying by the
       invoice's gives what the customer is billed. Both rates are 1 on a base-currency invoice
       priced from a base-currency list, so the ordinary case multiplies by 1. */
    CROSS APPLY (SELECT ROUND(masterdata.fn_GetUnitPrice(l.ItemUnitId, @PriceListId, @BranchId) * @Rate / @PriceRate, 4) AS Price) sp;

    -- Return lines created from an invoice keep the invoice price and discount (the customer is refunded what was paid).
    UPDATE p SET UnitPrice = s.UnitPrice, DiscountPercent = s.DiscountPercent, SystemPrice = s.UnitPrice
    FROM @Priced p
    INNER JOIN @Kept k ON k.LineNumber = p.LineNumber AND k.ItemId = p.ItemId
    INNER JOIN sales.SalesDocumentLines s ON s.Id = k.SourceLineId;

    DECLARE @NoPrice NVARCHAR(400);
    SELECT TOP (1) @NoPrice = N'Line ' + CAST(p.LineNumber AS NVARCHAR(10)) + N': no selling price for ' + i.ItemCode + N' (' + ut.UnitTypeName
                              + N') in price list ' + pl.PriceListName + N'. Add the price or enter a manual price (requires the price override permission).'
    FROM @Priced p
    INNER JOIN inventory.Items i       ON i.Id = p.ItemId
    INNER JOIN inventory.ItemUnits iu  ON iu.Id = p.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut ON ut.Id = iu.UnitTypeId
    INNER JOIN masterdata.PriceLists pl ON pl.Id = @PriceListId
    WHERE p.UnitPrice IS NULL
    ORDER BY p.LineNumber;
    IF @NoPrice IS NOT NULL THROW 64011, @NoPrice, 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Id IS NULL
        BEGIN
            DECLARE @Number NVARCHAR(30) = NULL;
            IF EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Id = @TypeId AND NumberOnPost = 0)
                EXEC inventory.usp_DocumentType_NextNumber @DocumentTypeCode, @Number OUTPUT, @BranchId;

            INSERT INTO sales.SalesDocuments (DocumentTypeId, DocumentNumber, DocumentDate, DueDate, BranchId, WarehouseId, ClientId, SalesmanId,
                                              PriceListId, CurrencyId, RateType, ExchangeRate, ReferenceNo, Notes, Status, CreatedBy,
                                              PaymentType, ReceiptMethodId, ReceiptAccountId, PaymentReference)
            VALUES (@TypeId, @Number, @DocumentDate, @DueDate, @BranchId, @WarehouseId, @ClientId, @SalesmanId,
                    @PriceListId, @CurrencyId, @RateType, @Rate, @ReferenceNo, @Notes, 1, @UserId,
                    @PaymentType, @ReceiptMethodId, @ReceiptAccountId, @PaymentReference);
            SET @Id = SCOPE_IDENTITY();

            INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Created', ISNULL(N'Draft ' + @Number, N'Draft (number assigned on posting)'), @UserId);
        END
        ELSE
        BEGIN
            UPDATE sales.SalesDocuments
            SET DocumentDate = @DocumentDate, DueDate = @DueDate, BranchId = @BranchId, WarehouseId = @WarehouseId,
                ClientId = @ClientId, SalesmanId = @SalesmanId, PriceListId = @PriceListId, CurrencyId = @CurrencyId,
                RateType = @RateType, ExchangeRate = @Rate, ReferenceNo = @ReferenceNo, Notes = @Notes,
                PaymentType = @PaymentType, ReceiptMethodId = @ReceiptMethodId, ReceiptAccountId = @ReceiptAccountId, PaymentReference = @PaymentReference,
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;

            DELETE FROM sales.SalesDocumentLines WHERE DocumentId = @Id;

            INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Updated', N'Header and ' + CAST((SELECT COUNT(*) FROM @Lines) AS NVARCHAR(10)) + N' line(s) saved', @UserId);
        END

        INSERT INTO sales.SalesDocumentLines (DocumentId, LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, PackingFormula, Specification,
                                              UnitPrice, DiscountPercent, PriceSource, UnitCostBase, ImportRowNumber, Notes, SourceLineId)
        SELECT @Id, p.LineNumber, p.ItemId, p.ItemUnitId, p.WarehouseId, p.ExpiryDate, p.Quantity, p.PackingFormula, p.Specification,
               p.UnitPrice, p.DiscountPercent,
               CASE WHEN p.SystemPrice IS NULL OR p.UnitPrice <> p.SystemPrice THEN N'Manual' ELSE N'PriceList' END,
               k.UnitCostBase, p.ImportRowNumber, p.Notes, k.SourceLineId
        FROM @Priced p
        LEFT JOIN @Kept k ON k.LineNumber = p.LineNumber AND k.ItemId = p.ItemId;

        UPDATE d
        SET TotalItems = x.Items, TotalQuantity = x.Qty, Subtotal = x.Sub, TotalAmount = x.Amt, TotalDiscount = x.Sub - x.Amt,
            TotalAmountBase = ROUND(x.Amt / @Rate, 2)
        FROM sales.SalesDocuments d
        CROSS APPLY (SELECT COUNT(*) AS Items, ISNULL(SUM(QuantityBase), 0) AS Qty,
                            ISNULL(SUM(CONVERT(DECIMAL(18,2), Quantity * UnitPrice)), 0) AS Sub, ISNULL(SUM(LineTotal), 0) AS Amt
                     FROM sales.SalesDocumentLines WHERE DocumentId = @Id) x
        WHERE d.Id = @Id;

        IF @DraftReference IS NOT NULL
        BEGIN
            DECLARE @NewLogs TABLE (Id INT PRIMARY KEY, FileName NVARCHAR(255), ImportedRows INT);
            INSERT INTO @NewLogs (Id, FileName, ImportedRows)
            SELECT Id, FileName, ImportedRows FROM sales.InvoiceImportLogs WHERE DraftReference = @DraftReference AND InvoiceId IS NULL;

            EXEC sales.usp_InvoiceImport_AttachInvoice @DraftReference, @Id;

            INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
            SELECT @Id, N'Imported', N'Excel import: ' + FileName + N' (' + CAST(ImportedRows AS NVARCHAR(10)) + N' row(s))', @UserId
            FROM @NewLogs ORDER BY Id;
        END

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_Post
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
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
                 WHEN w.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is inactive.'
                 WHEN w.BranchId <> @BranchId THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is not in the document branch.' END
        FROM sales.SalesDocumentLines l
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id AND (i.IsActive = 0 OR w.IsActive = 0 OR w.BranchId <> @BranchId)
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
                                        + N', but this invoice is in ' + ic.CurrencyCode + N'. Choose an account in ' + ic.CurrencyCode + N'.'
                                   WHEN a.BranchId IS NOT NULL AND a.BranchId <> @BranchId THEN N'The account ' + a.AccountCode + N' is not available for this invoice''s branch.' END
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

        IF @Direction = -1
        BEGIN
            SELECT TOP (1) @Msg = N'Insufficient stock for ' + i.ItemCode + N' in ' + w.WarehouseCode + N': available '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N', required ' + CAST(x.Qty AS NVARCHAR(20)) + N' (base units).'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM sales.SalesDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 64007, @Msg, 1;
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
            SELECT @MovementDate, l.ItemId, l.WarehouseId, @BranchId, @Direction * l.QuantityBase, l.UnitCostBase,
                   N'Sales', @TypeCode, @Id, l.Id, @Number, NULL, l.ExpiryDate, @UserId
            FROM sales.SalesDocumentLines l
            WHERE l.DocumentId = @Id;
        END

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

CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_Cancel
    @Id         INT,
    @Reason     NVARCHAR(300),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 64000, 'A cancellation reason is required.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @Direction SMALLINT, @TypeCode NVARCHAR(20), @SourceId INT;
        SELECT @Status = d.Status, @Direction = dt.StockDirection, @TypeCode = dt.Code, @SourceId = d.SourceDocumentId
        FROM sales.SalesDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 64006, 'Document not found.', 1;
        IF @Status <> 2 THROW 64010, 'Only posted documents can be cancelled (delete drafts instead).', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 64004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE SourceDocumentId = @Id AND Status = 2)
            THROW 64010, 'This invoice cannot be cancelled: posted returns refer to it. Cancel those first.', 1;

        /* A CANCELLED INVOICE CANNOT KEEP MONEY APPLIED TO IT. Receipts allocated to it would be paying
           an invoice that no longer exists, and the customer's balance would quietly be wrong. The
           receipt has to be reversed (or its allocation removed) first, so somebody decides what
           happens to the money. Only receipts that are POSTED count: a draft allocates nothing yet. */
        /* THE AUTOMATIC RECEIPT OF A CASH INVOICE IS THE ONE EXCEPTION: it was made with the invoice,
           so it is undone with it - reversed here, in this transaction, with the reason. Money any
           OTHER receipt has put on the invoice is still somebody's decision and still blocks. */
        DECLARE @AutoReceiptId INT = (SELECT TOP (1) Id FROM sales.Receipts WHERE SourceSalesDocumentId = @Id AND Status = 2);
        IF EXISTS (SELECT 1 FROM sales.ReceiptAllocations a
                   INNER JOIN sales.Receipts r ON r.Id = a.ReceiptId
                   WHERE a.SalesDocumentId = @Id AND a.RemovedAtUtc IS NULL AND r.Status = 2
                     AND r.Id <> ISNULL(@AutoReceiptId, 0))
            THROW 64010, 'This invoice cannot be cancelled: receipts have been applied to it. Reverse those receipts first.', 1;

        IF @AutoReceiptId IS NOT NULL
        BEGIN
            DECLARE @RcReason NVARCHAR(500) = N'Invoice cancelled: ' + @Reason;
            EXEC sales.usp_Receipt_Reverse @Id = @AutoReceiptId, @Reason = @RcReason, @RowVersion = NULL, @UserId = @UserId, @FromInvoiceCancel = 1;
            INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'ReceiptReversed', N'Cash sale: receipt ' + (SELECT ReceiptNumber FROM sales.Receipts WHERE Id = @AutoReceiptId) + N' reversed', @UserId);
        END

        IF @Direction = 1
        BEGIN
            DECLARE @Msg NVARCHAR(400);
            SELECT TOP (1) @Msg = N'Cannot cancel: ' + i.ItemCode + N' in ' + w.WarehouseCode + N' has only '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N' left, but this document added ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM sales.SalesDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 64007, @Msg, 1;
        END

        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, IsReversal, CreatedBy)
        SELECT SYSUTCDATETIME(), m.ItemId, m.WarehouseId, m.BranchId, -m.QuantityBase, m.UnitCostBase,
               m.DocumentFamily, m.DocumentTypeCode, m.DocumentId, m.DocumentLineId, m.DocumentNumber, m.ReasonCode, m.ExpiryDate, 1, @UserId
        FROM inventory.StockMovements m
        WHERE m.DocumentFamily = N'Sales' AND m.DocumentId = @Id AND m.IsReversal = 0;

        IF @TypeCode = N'SRET' AND @SourceId IS NOT NULL
            UPDATE s SET ReturnedQuantityBase = s.ReturnedQuantityBase - x.Qty
            FROM sales.SalesDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM sales.SalesDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;

        UPDATE sales.SalesDocuments
        SET Status = 3, CancelledAtUtc = SYSUTCDATETIME(), CancelledBy = @UserId, CancelReason = @Reason,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@Id, N'Cancelled', @Reason, @UserId);

        -- A cancelled return was a receipt: replay the cost history of its items.
        IF @Direction = 1
        BEGIN
            DECLARE @ItemId INT;
            DECLARE items CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT ItemId FROM sales.SalesDocumentLines WHERE DocumentId = @Id;
            OPEN items; FETCH NEXT FROM items INTO @ItemId;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC inventory.usp_Item_RebuildCosts @ItemId;
                FETCH NEXT FROM items INTO @ItemId;
            END
            CLOSE items; DEALLOCATE items;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.Id, d.DocumentTypeId, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, dt.StockDirection, dt.NumberOnPost,
           d.DocumentNumber, d.DocumentDate, d.DueDate,
           d.BranchId, b.BranchCode, b.BranchName, d.WarehouseId, w.WarehouseCode, w.WarehouseName,
           d.ClientId, cl.PartyCode AS ClientCode, cl.PartyName AS ClientName, cl.Phone AS ClientPhone, cl.Email AS ClientEmail, cl.Address AS ClientAddress,
           d.SalesmanId, sm.PartyCode AS SalesmanCode, sm.PartyName AS SalesmanName,
           d.PriceListId, pl.PriceListCode, pl.PriceListName,
           d.CurrencyId, c.CurrencyCode, c.CurrencyName, c.Symbol AS CurrencySymbol, c.DecimalPlaces, c.IsBaseCurrency,
           d.RateType, d.ExchangeRate, bc.CurrencyCode AS BaseCurrencyCode,
           d.ReferenceNo, d.Notes, d.Status,
           d.TotalItems, d.TotalQuantity, d.Subtotal, d.TotalDiscount, d.TotalAmount, d.TotalAmountBase, d.TotalCostBase, d.TotalGrossProfitBase,
           st.PaidAmount, st.OutstandingAmount, st.PaymentStatus,
           d.PaymentType, d.ReceiptMethodId, ReceiptMethodName = rm.MethodName,
           d.ReceiptAccountId, ReceiptAccountCode = ra.AccountCode, ReceiptAccountName = ra.AccountName, d.PaymentReference,
           ReceiptId = rc.Id, rc.ReceiptNumber,
           ReceiptStatus = CASE rc.Status WHEN 1 THEN N'Draft' WHEN 2 THEN N'Posted' WHEN 3 THEN N'Reversed' END,
           TotalGrossProfitPct = CASE WHEN d.TotalAmountBase > 0 THEN ROUND(100.0 * d.TotalGrossProfitBase / d.TotalAmountBase, 2) END,
           d.SourceDocumentId, src.DocumentNumber AS SourceDocumentNumber,
           d.PostedAtUtc, d.PostedBy, pu.FullName AS PostedByName,
           d.CancelledAtUtc, d.CancelledBy, xu.FullName AS CancelledByName, d.CancelReason,
           d.CreatedAtUtc, d.CreatedBy, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.UpdatedBy, uu.FullName AS UpdatedByName,
           d.RowVersion
    FROM sales.SalesDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Branches b      ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w    ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Parties cl      ON cl.Id = d.ClientId
    LEFT  JOIN masterdata.Parties sm      ON sm.Id = d.SalesmanId
    INNER JOIN masterdata.PriceLists pl   ON pl.Id = d.PriceListId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    LEFT  JOIN masterdata.Currencies bc   ON bc.IsBaseCurrency = 1 AND bc.IsActive = 1
    LEFT  JOIN sales.SalesDocuments src   ON src.Id = d.SourceDocumentId
    OUTER APPLY sales.fn_InvoiceSettlement(d.Id) st
    LEFT  JOIN masterdata.PaymentMethods rm   ON rm.Id = d.ReceiptMethodId
    LEFT  JOIN masterdata.CashBankAccounts ra ON ra.Id = d.ReceiptAccountId
    LEFT  JOIN sales.Receipts rc              ON rc.SourceSalesDocumentId = d.Id
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = d.UpdatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    LEFT  JOIN security.Users xu ON xu.Id = d.CancelledBy
    WHERE d.Id = @Id;

    SELECT l.Id, l.DocumentId, l.LineNumber, l.ItemId, i.ItemCode, i.ItemName,
           l.ItemUnitId, ut.UnitTypeName, iu.SkuCode, iu.Barcode, l.PackingFormula,
           l.WarehouseId, w.WarehouseCode, w.WarehouseName, l.ExpiryDate,
           l.Quantity, l.QuantityBase, l.Specification, l.UnitPrice, l.DiscountPercent, l.LineDiscount, l.LineTotal, l.PriceSource,
           l.UnitCostBase, l.FobCostAtSale, l.LastCostAtSale, l.NetSalesBase, l.CogsBase, l.GrossProfitBase, l.GrossProfitPct,
           l.ReturnedQuantityBase, RemainingBase = l.QuantityBase - l.ReturnedQuantityBase,
           l.ImportRowNumber, l.Notes, l.SourceLineId,
           OnHandBase  = inventory.fn_StockOnHand(l.ItemId, l.WarehouseId),
           SystemPrice = masterdata.fn_GetUnitPrice(l.ItemUnitId, d.PriceListId, d.BranchId),
           ItemAverageCost = i.AverageCost
    FROM sales.SalesDocumentLines l
    INNER JOIN sales.SalesDocuments d   ON d.Id = l.DocumentId
    INNER JOIN inventory.Items i        ON i.Id = l.ItemId
    INNER JOIN inventory.ItemUnits iu   ON iu.Id = l.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut  ON ut.Id = iu.UnitTypeId
    INNER JOIN masterdata.Warehouses w  ON w.Id = l.WarehouseId
    WHERE l.DocumentId = @Id
    ORDER BY l.LineNumber;

    SELECT f.Id, f.DocumentId, f.FileName, f.ContentType, f.SizeBytes, f.CreatedAtUtc, u.FullName AS CreatedByName
    FROM sales.SalesDocumentFiles f
    LEFT JOIN security.Users u ON u.Id = f.CreatedBy
    WHERE f.DocumentId = @Id
    ORDER BY f.CreatedAtUtc DESC;

    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM sales.SalesDocumentAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.DocumentId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;
END
GO

CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_Search
    @DocumentTypeCode NVARCHAR(20) = N'SINV',  -- SO | SINV | SRET | NULL = whole family
    @Search           NVARCHAR(100) = NULL,    -- number, reference, client code/name, notes
    @BranchId         INT          = NULL,
    @WarehouseId      INT          = NULL,
    @ClientId         INT          = NULL,
    @SalesmanId       INT          = NULL,
    @Status           TINYINT      = NULL,     -- 1 Draft | 2 Posted | 3 Cancelled
    @DateFrom         DATE         = NULL,
    @DateTo           DATE         = NULL,
    @PaymentStatus    NVARCHAR(10) = NULL,     -- Unpaid | Partial | Paid (posted invoices only)
    @PaymentType      TINYINT      = NULL,     -- 1 Cash | 2 On Account
    @SortColumn       NVARCHAR(30) = N'DocumentDate',  -- DocumentNumber | DocumentDate | ClientName | Status | TotalAmount | CreatedAtUtc
    @SortDirection    NVARCHAR(4)  = N'DESC',
    @PageNumber       INT          = 1,
    @PageSize         INT          = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @DocumentTypeCode = NULLIF(LTRIM(RTRIM(@DocumentTypeCode)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'DocumentNumber', N'DocumentDate', N'ClientName', N'Status', N'TotalAmount', N'CreatedAtUtc')
        SET @SortColumn = N'DocumentDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT d.Id, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, dt.StockDirection,
           d.DocumentNumber, d.DocumentDate, d.DueDate, d.BranchId, b.BranchName, d.WarehouseId, w.WarehouseName,
           d.ClientId, cl.PartyCode AS ClientCode, cl.PartyName AS ClientName,
           d.SalesmanId, sm.PartyName AS SalesmanName,
           d.PriceListId, pl.PriceListName, d.CurrencyId, c.CurrencyCode, c.Symbol AS CurrencySymbol, c.DecimalPlaces, d.ExchangeRate,
           d.ReferenceNo, d.Status, d.TotalItems, d.TotalQuantity, d.Subtotal, d.TotalDiscount, d.TotalAmount, d.TotalAmountBase,
           st.PaidAmount, st.OutstandingAmount, st.PaymentStatus,
           d.PaymentType, ReceiptId = rc.Id, rc.ReceiptNumber,
           d.PostedAtUtc, pu.FullName AS PostedByName, d.CancelledAtUtc,
           d.CreatedAtUtc, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM sales.SalesDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Branches b      ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w    ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Parties cl      ON cl.Id = d.ClientId
    LEFT  JOIN masterdata.Parties sm      ON sm.Id = d.SalesmanId
    INNER JOIN masterdata.PriceLists pl   ON pl.Id = d.PriceListId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    OUTER APPLY sales.fn_InvoiceSettlement(d.Id) st
    LEFT  JOIN sales.Receipts rc ON rc.SourceSalesDocumentId = d.Id
    WHERE dt.Family = N'Sales'
      AND (@DocumentTypeCode IS NULL OR dt.Code = @DocumentTypeCode)
      AND (@Search IS NULL OR d.DocumentNumber LIKE N'%' + @Search + N'%' OR d.ReferenceNo LIKE N'%' + @Search + N'%'
           OR cl.PartyCode LIKE N'%' + @Search + N'%' OR cl.PartyName LIKE N'%' + @Search + N'%' OR d.Notes LIKE N'%' + @Search + N'%')
      AND (@BranchId IS NULL OR d.BranchId = @BranchId)
      AND (@WarehouseId IS NULL OR d.WarehouseId = @WarehouseId)
      AND (@ClientId IS NULL OR d.ClientId = @ClientId)
      AND (@SalesmanId IS NULL OR d.SalesmanId = @SalesmanId)
      AND (@Status IS NULL OR d.Status = @Status)
      AND (@DateFrom IS NULL OR d.DocumentDate >= @DateFrom)
      AND (@DateTo IS NULL OR d.DocumentDate <= @DateTo)
      AND (@PaymentStatus IS NULL OR st.PaymentStatus = @PaymentStatus)
      AND (@PaymentType IS NULL OR d.PaymentType = @PaymentType)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN d.DocumentNumber WHEN N'ClientName' THEN cl.PartyName END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN d.DocumentNumber WHEN N'ClientName' THEN cl.PartyName END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'DocumentDate' THEN d.DocumentDate END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'DocumentDate' THEN d.DocumentDate END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Status' THEN CAST(d.Status AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Status' THEN CAST(d.Status AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'TotalAmount' THEN d.TotalAmount END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'TotalAmount' THEN d.TotalAmount END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN d.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN d.CreatedAtUtc END DESC,
        d.DocumentDate DESC, d.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO


PRINT 'Script 38 applied: sales invoice payment type and automatic cash receipt.';
GO
