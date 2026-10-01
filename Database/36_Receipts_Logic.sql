/* ==================================================================================================
   36: Customer receipts - the logic (Phase 2)
   --------------------------------------------------------------------------------------------------
   Script 35 built the ground. This one builds the receipt itself: save a draft, post, reverse,
   allocate unapplied credit later, and read it all back - plus what the INVOICE learns from it.

   WHAT IT CHANGES ON THE INVOICE
     - sales.fn_InvoiceSettlement(id): paid, outstanding and payment status of ONE invoice, defined
       once so the list, the read and the receipt rules cannot disagree about what "paid" means.
       Paid is the sum of LIVE allocations on POSTED receipts - nothing is stored, so reversing a
       receipt gives the balance back with nothing to repair.
     - usp_SalesDocument_Search / _Get return PaidAmount, OutstandingAmount and PaymentStatus
       (Unpaid | Partial | Paid, posted invoices only); Search filters by @PaymentStatus.
     - usp_SalesDocument_Cancel refuses an invoice that has receipts applied to it (error 64010).

   THE RULES, enforced here and not in the page
     - Save: the customer is a client, the branch is open, every line's account holds the line's
       currency and may be used by the receipt's branch, a Free Receipt carries no allocations, and
       an allocation never exceeds what its invoice still owes.
     - Post: header base amount = payment lines base total, and (Sales Allocation) = allocations base
       total, each within 0.01. The invoices are LOCKED while their outstanding is re-read, so two
       drafts allocating the same invoice cannot both post.
     - Reverse: a posted receipt only. A Free Receipt that has since been applied to invoices must
       have those allocations removed first.
     - Allocation currency: entered in the INVOICE's currency; its base value is that amount divided
       by the invoice's own stored rate, so settling an invoice in full lands exactly on its base
       total with no exchange difference.

   ALSO: masterdata.AttachmentTypes.AppliesTo (Logistics | Receipt). The container upload modal
   reads the unfiltered lookup, so receipt types must not leak into it: the lookup defaults to
   Logistics, and receipts ask for Receipt.

   Errors 71xxx added: 71005 not editable, 71008 unbalanced, 71009 allocation above outstanding,
                       71010 invalid status, 71011 more than the unapplied credit, 71012 receipt has
                       later allocations.
   Permissions (module Sales): sales.receipts.view 700 / create 710 / post 720 / reverse 730 /
                       delete 740 / allocate 750.

   Requires script 35. Idempotent.
   ================================================================================================== */
GO

IF OBJECT_ID(N'sales.Receipts', N'U') IS NULL
BEGIN
    RAISERROR ('Run script 35 before script 36.', 16, 1);
    RETURN;
END
GO

/* ================================================================== 1. Attachment types: AppliesTo */

IF COL_LENGTH('masterdata.AttachmentTypes', 'AppliesTo') IS NULL
BEGIN
    ALTER TABLE masterdata.AttachmentTypes
        ADD AppliesTo NVARCHAR(12) NOT NULL CONSTRAINT DF_AttachmentTypes_AppliesTo DEFAULT (N'Logistics');
    PRINT 'Added masterdata.AttachmentTypes.AppliesTo';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
               WHERE name = N'CK_AttachmentTypes_AppliesTo' AND parent_object_id = OBJECT_ID(N'masterdata.AttachmentTypes'))
BEGIN
    ALTER TABLE masterdata.AttachmentTypes
        ADD CONSTRAINT CK_AttachmentTypes_AppliesTo CHECK (AppliesTo IN (N'Logistics', N'Receipt'));
END
GO

/* The mockup's Type / Sub Type pairs: Category is the Type column, SubType the Sub Type column.
   Matched on the pair, so a re-run changes nothing and a renamed row is left alone. */
MERGE masterdata.AttachmentTypes AS t
USING (VALUES
    (N'Bank',   N'Transfer Slip',          10),
    (N'Bank',   N'Bank Statement',         20),
    (N'Cheque', N'Cheque Copy',            30),
    (N'Other',  N'Customer Payment Advice', 40),
    (N'Other',  N'Correspondence',         50)
) AS s (Category, SubType, SortOrder)
ON t.Category = s.Category AND t.SubType = s.SubType
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Category, SubType, SortOrder, AppliesTo) VALUES (s.Category, s.SubType, s.SortOrder, N'Receipt');
GO

CREATE OR ALTER PROCEDURE masterdata.usp_AttachmentType_Lookup
    @ActiveOnly BIT          = 1,
    @IncludeId  INT          = NULL,
    /* WHICH LIST. Logistics is the default so the container upload modal, which passes nothing,
       sees exactly what it always saw; the receipt page asks for Receipt. */
    @AppliesTo  NVARCHAR(12) = N'Logistics'
AS
BEGIN
    SET NOCOUNT ON;
    SET @AppliesTo = ISNULL(NULLIF(LTRIM(RTRIM(@AppliesTo)), N''), N'Logistics');
    SELECT Id, Category, SubType, DisplayName = Category + N' / ' + SubType, SortOrder, IsActive
    FROM masterdata.AttachmentTypes
    WHERE (@ActiveOnly = 0 OR IsActive = 1 OR Id = @IncludeId)
      AND (AppliesTo = @AppliesTo OR Id = @IncludeId)
    ORDER BY SortOrder, Category, SubType;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_AttachmentType_Search
    @Search        NVARCHAR(100) = NULL,
    @Category      NVARCHAR(30)  = NULL,
    @IsActive      BIT           = NULL,
    @SortColumn    NVARCHAR(30)  = N'SortOrder',   -- SortOrder | Category | SubType | IsActive
    @SortDirection NVARCHAR(4)   = N'ASC',
    @PageNumber    INT           = 1,
    @PageSize      INT           = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @Category = NULLIF(LTRIM(RTRIM(@Category)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'SortOrder', N'Category', N'SubType', N'IsActive') SET @SortColumn = N'SortOrder';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT a.Id, a.Category, a.SubType, a.AppliesTo, a.SortOrder, a.IsActive,
           a.CreatedAtUtc, a.CreatedBy, a.UpdatedAtUtc, a.UpdatedBy, a.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.AttachmentTypes a
    WHERE (@Search IS NULL OR a.Category LIKE N'%' + @Search + N'%' OR a.SubType LIKE N'%' + @Search + N'%')
      AND (@Category IS NULL OR a.Category = @Category)
      AND (@IsActive IS NULL OR a.IsActive = @IsActive)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'Category' THEN a.Category WHEN N'SubType' THEN a.SubType END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'Category' THEN a.Category WHEN N'SubType' THEN a.SubType END END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'SortOrder' THEN a.SortOrder END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'SortOrder' THEN a.SortOrder END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(a.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(a.IsActive AS INT) END DESC,
        a.SortOrder, a.Category, a.SubType
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_AttachmentType_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, Category, SubType, AppliesTo, SortOrder, IsActive, CreatedAtUtc, CreatedBy, UpdatedAtUtc, UpdatedBy, RowVersion
    FROM masterdata.AttachmentTypes WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_AttachmentType_Save
    @Id         INT          = NULL,
    @Category   NVARCHAR(30),
    @SubType    NVARCHAR(60),
    @SortOrder  INT          = 0,
    @IsActive   BIT          = 1,
    @RowVersion BINARY(8)    = NULL,
    @UserId     INT          = NULL,
    @NewId      INT OUTPUT,
    /* NULL = leave it alone on an update, and Logistics on an insert: every caller that predates the
       column keeps doing exactly what it did. */
    @AppliesTo  NVARCHAR(12) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Category = NULLIF(LTRIM(RTRIM(@Category)), N'');
    SET @SubType = NULLIF(LTRIM(RTRIM(@SubType)), N'');
    SET @AppliesTo = NULLIF(LTRIM(RTRIM(@AppliesTo)), N'');
    IF @Category IS NULL THROW 69000, 'Category is required.', 1;
    IF @SubType IS NULL THROW 69000, 'Sub type is required.', 1;
    IF @AppliesTo IS NOT NULL AND @AppliesTo NOT IN (N'Logistics', N'Receipt') THROW 69000, 'Applies to must be Logistics or Receipt.', 1;
    IF EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Category = @Category AND SubType = @SubType AND (@Id IS NULL OR Id <> @Id))
        THROW 69013, 'This category and sub type already exist.', 1;

    IF @Id IS NULL
    BEGIN
        INSERT INTO masterdata.AttachmentTypes (Category, SubType, SortOrder, IsActive, AppliesTo, CreatedBy)
        VALUES (@Category, @SubType, ISNULL(@SortOrder, 0), ISNULL(@IsActive, 1), ISNULL(@AppliesTo, N'Logistics'), @UserId);
        SET @NewId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Id = @Id) THROW 69006, 'Attachment type not found.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 69004, 'This attachment type was modified by another user. Reload the page and try again.', 1;
        UPDATE masterdata.AttachmentTypes
        SET Category = @Category, SubType = @SubType, SortOrder = ISNULL(@SortOrder, 0), IsActive = ISNULL(@IsActive, 1),
            AppliesTo = ISNULL(@AppliesTo, AppliesTo),
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;
        SET @NewId = @Id;
    END
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_AttachmentType_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Id = @Id) THROW 69006, 'Attachment type not found.', 1;
    IF EXISTS (SELECT 1 FROM logistics.ContainerAttachments WHERE AttachmentTypeId = @Id)
       OR EXISTS (SELECT 1 FROM sales.ReceiptFiles WHERE AttachmentTypeId = @Id)
        THROW 69014, 'This attachment type is used by documents and cannot be deleted. Deactivate it instead.', 1;
    DELETE FROM masterdata.AttachmentTypes WHERE Id = @Id;
END
GO

/* ================================================================== 2. What an invoice has been paid */

/* ONE DEFINITION OF "PAID". An inline table function, so the optimizer folds it into the calling
   query (it is applied per invoice row in the list) rather than running it row by row.

   Only a POSTED SALES INVOICE has a payment status: a draft owes nothing yet, a cancelled one owes
   nothing any more, and a return is not a debt. 0.005 is half the smallest unit of a two-decimal
   amount: a balance that small is rounding, not money. */
CREATE OR ALTER FUNCTION sales.fn_InvoiceSettlement (@DocumentId INT)
RETURNS TABLE
AS
RETURN
(
    SELECT p.PaidAmount,
           OutstandingAmount = CASE WHEN d.Status = 2 AND d.DocumentTypeId = t.Id THEN d.TotalAmount - p.PaidAmount END,
           PaymentStatus     = CASE WHEN d.Status <> 2 OR d.DocumentTypeId <> t.Id THEN NULL
                                    WHEN p.PaidAmount <= 0 THEN N'Unpaid'
                                    WHEN d.TotalAmount - p.PaidAmount <= 0.005 THEN N'Paid'
                                    ELSE N'Partial' END
    FROM sales.SalesDocuments d
    CROSS APPLY (SELECT Id FROM inventory.DocumentTypes WHERE Code = N'SINV') t
    CROSS APPLY (SELECT PaidAmount = ISNULL((SELECT SUM(a.AmountInvoiceCurrency)
                                             FROM sales.ReceiptAllocations a
                                             INNER JOIN sales.Receipts r ON r.Id = a.ReceiptId
                                             WHERE a.SalesDocumentId = d.Id AND a.RemovedAtUtc IS NULL AND r.Status = 2), 0)) p
    WHERE d.Id = @DocumentId
);
GO

/* ================================================================== 3. The invoice procedures that learn it */

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
        IF EXISTS (SELECT 1 FROM sales.ReceiptAllocations a
                   INNER JOIN sales.Receipts r ON r.Id = a.ReceiptId
                   WHERE a.SalesDocumentId = @Id AND a.RemovedAtUtc IS NULL AND r.Status = 2)
            THROW 64010, 'This invoice cannot be cancelled: receipts have been applied to it. Reverse those receipts first.', 1;

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


/* ================================================================== 4. Table types */

IF TYPE_ID(N'sales.tvp_ReceiptLine') IS NULL
BEGIN
    CREATE TYPE sales.tvp_ReceiptLine AS TABLE
    (
        LineNumber        INT           NOT NULL PRIMARY KEY,
        PaymentMethodId   INT           NOT NULL,
        CurrencyId        INT           NOT NULL,
        Amount            DECIMAL(18,2) NOT NULL,
        ExchangeRate      DECIMAL(18,6) NULL,       -- NULL = the official rate on the receipt date (1 for the base currency)
        CashBankAccountId INT           NOT NULL,
        Reference         NVARCHAR(100) NULL
    );
    PRINT 'Created type sales.tvp_ReceiptLine';
END
GO

IF TYPE_ID(N'sales.tvp_ReceiptAllocation') IS NULL
BEGIN
    CREATE TYPE sales.tvp_ReceiptAllocation AS TABLE
    (
        SalesDocumentId INT           NOT NULL PRIMARY KEY,
        Amount          DECIMAL(18,2) NOT NULL        -- in the INVOICE's currency
    );
    PRINT 'Created type sales.tvp_ReceiptAllocation';
END
GO

/* ================================================================== 5. Save (a draft) */

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

/* ================================================================== 6. Post */

CREATE OR ALTER PROCEDURE sales.usp_Receipt_Post
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @Type TINYINT, @ClientId INT, @HeaderBase DECIMAL(18,2), @Number NVARCHAR(30);
        SELECT @Status = Status, @Type = PaymentType, @ClientId = ClientId, @HeaderBase = AmountBase, @Number = ReceiptNumber
        FROM sales.Receipts WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;

        IF @Status IS NULL THROW 71006, 'Receipt not found.', 1;
        IF @Status <> 1 THROW 71010, 'Only a draft receipt can be posted.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sales.Receipts WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 71004, 'This receipt was modified by another user. Reload the page and try again.', 1;

        DECLARE @Base NVARCHAR(3) = (SELECT TOP (1) CurrencyCode FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1);
        DECLARE @Msg NVARCHAR(400);

        IF NOT EXISTS (SELECT 1 FROM sales.ReceiptLines WHERE ReceiptId = @Id)
            THROW 71000, 'A receipt needs at least one payment line before it can be posted.', 1;

        /* A LIST ENTRY CAN BE DEACTIVATED BETWEEN THE SAVE AND THE POST. The draft was valid when it was
           saved; it must still be valid when it moves money. */
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': '
                              + CASE WHEN pm.IsActive = 0 THEN N'the payment method ' + pm.MethodCode + N' is no longer active.'
                                     ELSE N'the account ' + a.AccountCode + N' is no longer active.' END
        FROM sales.ReceiptLines l
        INNER JOIN masterdata.PaymentMethods pm ON pm.Id = l.PaymentMethodId
        INNER JOIN masterdata.CashBankAccounts a ON a.Id = l.CashBankAccountId
        WHERE l.ReceiptId = @Id AND (pm.IsActive = 0 OR a.IsActive = 0)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 71000, @Msg, 1;

        /* THE KEY CONTROL: header = payment lines (= allocations, when there are any). Compared in the
           BASE currency, within 0.01 - converting several currencies rounds each line, and an exact
           match would refuse receipts that are right to the cent. */
        DECLARE @LinesBase DECIMAL(18,2) = (SELECT ISNULL(SUM(AmountBase), 0) FROM sales.ReceiptLines WHERE ReceiptId = @Id);
        IF ABS(@HeaderBase - @LinesBase) > 0.01
        BEGIN
            SET @Msg = N'Unbalanced Receipt: Payment Details Total (' + @Base + N') ' + FORMAT(@LinesBase, N'N2', N'en-US')
                     + N' does not match the Receipt Amount (' + @Base + N') ' + FORMAT(@HeaderBase, N'N2', N'en-US') + N'.';
            THROW 71008, @Msg, 1;
        END

        IF @Type = 2
        BEGIN
            DECLARE @AllocBase DECIMAL(18,2) = (SELECT ISNULL(SUM(AmountBase), 0) FROM sales.ReceiptAllocations WHERE ReceiptId = @Id);
            IF ABS(@HeaderBase - @AllocBase) > 0.01
            BEGIN
                SET @Msg = N'Unbalanced Allocation: Total Allocated (' + @Base + N') ' + FORMAT(@AllocBase, N'N2', N'en-US')
                         + N' does not match the Receipt Amount (' + @Base + N') ' + FORMAT(@HeaderBase, N'N2', N'en-US') + N'.';
                THROW 71008, @Msg, 1;
            END

            /* LOCK THE INVOICES, THEN READ WHAT THEY OWE. Two drafts that allocate the same invoice
               each looked fine when they were saved. Whichever posts second must see the first one's
               money, and it can only do that if the read happens after the other transaction has
               finished - which the lock on the invoice rows guarantees. */
            DECLARE @Locked TABLE (Id INT PRIMARY KEY);
            INSERT INTO @Locked (Id)
            SELECT d.Id
            FROM sales.SalesDocuments d WITH (UPDLOCK, HOLDLOCK)
            WHERE d.Id IN (SELECT SalesDocumentId FROM sales.ReceiptAllocations WHERE ReceiptId = @Id);

            SET @Msg = NULL;
            SELECT TOP (1) @Msg = N'Invoice ' + d.DocumentNumber + N': '
                                  + CASE WHEN st.PaymentStatus IS NULL THEN N'it is no longer a posted invoice, so it cannot be paid.'
                                         WHEN d.ClientId <> @ClientId THEN N'it belongs to another customer.' END
            FROM sales.ReceiptAllocations a
            INNER JOIN sales.SalesDocuments d ON d.Id = a.SalesDocumentId
            OUTER APPLY sales.fn_InvoiceSettlement(a.SalesDocumentId) st
            WHERE a.ReceiptId = @Id AND (st.PaymentStatus IS NULL OR d.ClientId <> @ClientId)
            ORDER BY d.DocumentNumber;
            IF @Msg IS NOT NULL THROW 71000, @Msg, 1;

            SELECT TOP (1) @Msg = N'Invoice ' + d.DocumentNumber + N': ' + FORMAT(a.AmountInvoiceCurrency, N'N2', N'en-US')
                                  + N' is more than its outstanding ' + FORMAT(st.OutstandingAmount, N'N2', N'en-US') + N' ' + c.CurrencyCode
                                  + N' - another receipt may have been posted against it since this draft was saved.'
            FROM sales.ReceiptAllocations a
            INNER JOIN sales.SalesDocuments d ON d.Id = a.SalesDocumentId
            INNER JOIN masterdata.Currencies c ON c.Id = d.CurrencyId
            CROSS APPLY sales.fn_InvoiceSettlement(a.SalesDocumentId) st
            WHERE a.ReceiptId = @Id AND a.AmountInvoiceCurrency > st.OutstandingAmount + 0.005
            ORDER BY d.DocumentNumber;
            IF @Msg IS NOT NULL THROW 71009, @Msg, 1;
        END

        UPDATE sales.Receipts
        SET Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO sales.ReceiptAudit (ReceiptId, Action, Details, UserId)
        VALUES (@Id, N'Posted', @Number + N' - ' + FORMAT(@HeaderBase, N'N2', N'en-US') + N' ' + @Base, @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 7. Reverse */

CREATE OR ALTER PROCEDURE sales.usp_Receipt_Reverse
    @Id         INT,
    @Reason     NVARCHAR(500),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
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

/* ================================================================== 8. Delete (a draft) */

CREATE OR ALTER PROCEDURE sales.usp_Receipt_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT;
        SELECT @Status = Status FROM sales.Receipts WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NULL THROW 71006, 'Receipt not found.', 1;
        -- A posted receipt moved money and a reversed one proves it did: neither is ever deleted.
        IF @Status <> 1 THROW 71010, 'Only a draft receipt can be deleted. A posted receipt is corrected by reversing it.', 1;

        DELETE FROM sales.ReceiptFiles WHERE ReceiptId = @Id;
        DELETE FROM sales.ReceiptAllocations WHERE ReceiptId = @Id;
        DELETE FROM sales.ReceiptLines WHERE ReceiptId = @Id;
        DELETE FROM sales.ReceiptAudit WHERE ReceiptId = @Id;
        DELETE FROM sales.Receipts WHERE Id = @Id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 9. Allocate unapplied credit later */

CREATE OR ALTER PROCEDURE sales.usp_Receipt_Allocate
    @ReceiptId   INT,
    @Allocations sales.tvp_ReceiptAllocation READONLY,
    @RowVersion  BINARY(8) = NULL,
    @UserId      INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM @Allocations) THROW 71000, 'Choose at least one invoice to allocate to.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @Type TINYINT, @ClientId INT, @HeaderBase DECIMAL(18,2);
        SELECT @Status = Status, @Type = PaymentType, @ClientId = ClientId, @HeaderBase = AmountBase
        FROM sales.Receipts WITH (UPDLOCK, HOLDLOCK) WHERE Id = @ReceiptId;

        IF @Status IS NULL THROW 71006, 'Receipt not found.', 1;
        IF @Status <> 2 THROW 71010, 'Only a posted receipt can be allocated.', 1;
        IF @Type <> 1 THROW 71010, 'Only a Free Receipt can be allocated later; a Sales Allocation receipt is already allocated.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sales.Receipts WHERE Id = @ReceiptId AND RowVersion = @RowVersion)
            THROW 71004, 'This receipt was modified by another user. Reload the page and try again.', 1;

        DECLARE @Base NVARCHAR(3) = (SELECT TOP (1) CurrencyCode FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1);
        DECLARE @Msg NVARCHAR(400);

        DECLARE @Locked TABLE (Id INT PRIMARY KEY);
        INSERT INTO @Locked (Id)
        SELECT d.Id FROM sales.SalesDocuments d WITH (UPDLOCK, HOLDLOCK)
        WHERE d.Id IN (SELECT SalesDocumentId FROM @Allocations);

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

        /* WHAT IS LEFT TO ALLOCATE: the receipt's base amount less its live allocations. */
        DECLARE @Applied DECIMAL(18,2) = (SELECT ISNULL(SUM(AmountBase), 0) FROM sales.ReceiptAllocations WHERE ReceiptId = @ReceiptId AND RemovedAtUtc IS NULL);
        DECLARE @Unapplied DECIMAL(18,2) = @HeaderBase - @Applied;
        DECLARE @NewBase DECIMAL(18,2) = (SELECT ISNULL(SUM(CONVERT(DECIMAL(18,2), a.Amount / d.ExchangeRate)), 0)
                                          FROM @Allocations a INNER JOIN sales.SalesDocuments d ON d.Id = a.SalesDocumentId);
        IF @NewBase > @Unapplied + 0.01
        BEGIN
            SET @Msg = N'This receipt has only ' + FORMAT(@Unapplied, N'N2', N'en-US') + N' ' + @Base + N' unapplied, but '
                     + FORMAT(@NewBase, N'N2', N'en-US') + N' ' + @Base + N' was allocated.';
            THROW 71011, @Msg, 1;
        END

        INSERT INTO sales.ReceiptAllocations (ReceiptId, SalesDocumentId, AmountInvoiceCurrency, InvoiceExchangeRate, AllocatedBy)
        SELECT @ReceiptId, a.SalesDocumentId, a.Amount, d.ExchangeRate, @UserId
        FROM @Allocations a INNER JOIN sales.SalesDocuments d ON d.Id = a.SalesDocumentId;

        INSERT INTO sales.ReceiptAudit (ReceiptId, Action, Details, UserId)
        VALUES (@ReceiptId, N'Allocated', CAST((SELECT COUNT(*) FROM @Allocations) AS NVARCHAR(10)) + N' invoice(s), '
                + FORMAT(@NewBase, N'N2', N'en-US') + N' ' + @Base, @UserId);

        UPDATE sales.Receipts SET UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @ReceiptId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE sales.usp_Receipt_Deallocate
    @AllocationId INT,
    @UserId       INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @ReceiptId INT, @Removed DATETIME2(3), @Amount DECIMAL(18,2), @InvoiceId INT;
        SELECT @ReceiptId = ReceiptId, @Removed = RemovedAtUtc, @Amount = AmountInvoiceCurrency, @InvoiceId = SalesDocumentId
        FROM sales.ReceiptAllocations WHERE Id = @AllocationId;
        IF @ReceiptId IS NULL THROW 71006, 'Allocation not found.', 1;

        DECLARE @Status TINYINT, @Type TINYINT;
        SELECT @Status = Status, @Type = PaymentType FROM sales.Receipts WITH (UPDLOCK, HOLDLOCK) WHERE Id = @ReceiptId;
        IF @Removed IS NOT NULL THROW 71010, 'This allocation has already been removed.', 1;
        IF @Status <> 2 THROW 71010, 'Only an allocation of a posted receipt can be removed.', 1;
        -- A Sales Allocation receipt's allocations ARE the receipt: taking one away would unbalance it.
        IF @Type <> 1 THROW 71010, 'The allocations of a Sales Allocation receipt are part of it. Reverse the receipt instead.', 1;

        UPDATE sales.ReceiptAllocations SET RemovedAtUtc = SYSUTCDATETIME(), RemovedBy = @UserId WHERE Id = @AllocationId;

        INSERT INTO sales.ReceiptAudit (ReceiptId, Action, Details, UserId)
        VALUES (@ReceiptId, N'Deallocated',
                N'Invoice ' + ISNULL((SELECT DocumentNumber FROM sales.SalesDocuments WHERE Id = @InvoiceId), N'#' + CAST(@InvoiceId AS NVARCHAR(10)))
                + N', ' + FORMAT(@Amount, N'N2', N'en-US'), @UserId);

        UPDATE sales.Receipts SET UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @ReceiptId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO


/* ================================================================== 10. Get */

/* FIVE RESULT SETS, in this order: the header, the payment lines, the allocations, the files (no
   bytes), the audit. The header carries what the page balances against so it never recomputes it:
   what the payment lines add up to, what is allocated, and what is still unapplied. */
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

/* ================================================================== 11. Search */

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

/* ================================================================== 12. What a customer still owes */

/* The invoices the allocation panel lists: this customer's POSTED sales invoices with something
   left to pay, oldest first. Outstanding is in the invoice's currency, and OutstandingBase is what
   it is worth in the base currency at the invoice's own rate - the figure the receipt's allocation
   total is balanced against. */
CREATE OR ALTER PROCEDURE sales.usp_Receipt_OpenInvoices
    @ClientId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT d.Id, d.DocumentNumber, d.DocumentDate, d.DueDate, d.CurrencyId, c.CurrencyCode, c.DecimalPlaces, d.ExchangeRate,
           InvoiceTotal = d.TotalAmount, st.PaidAmount, st.OutstandingAmount, st.PaymentStatus,
           OutstandingBase = CONVERT(DECIMAL(18,2), st.OutstandingAmount / d.ExchangeRate)
    FROM sales.SalesDocuments d
    INNER JOIN masterdata.Currencies c ON c.Id = d.CurrencyId
    CROSS APPLY sales.fn_InvoiceSettlement(d.Id) st
    WHERE d.ClientId = @ClientId AND st.PaymentStatus IN (N'Unpaid', N'Partial')
    ORDER BY d.DocumentDate, d.Id;
END
GO

/* The rate a receipt line pre-fills: the official rate on a date, 1 for the base currency, NULL when
   none is defined (a warning on the page, never an error here). */
CREATE OR ALTER PROCEDURE sales.usp_Receipt_ResolveRate
    @CurrencyId INT,
    @AsOfDate   DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @AsOfDate IS NULL SET @AsOfDate = CAST(SYSUTCDATETIME() AS DATE);

    SELECT c.Id AS CurrencyId, c.CurrencyCode, c.Symbol, c.DecimalPlaces, c.IsBaseCurrency,
           Rate     = masterdata.fn_GetRate(c.Id, 1, @AsOfDate),
           RateDate = CASE WHEN c.IsBaseCurrency = 1 THEN @AsOfDate
                           ELSE (SELECT TOP (1) RateDate FROM masterdata.ExchangeRates
                                 WHERE CurrencyId = c.Id AND RateType = 1 AND RateDate <= @AsOfDate ORDER BY RateDate DESC) END,
           BaseCurrencyCode = (SELECT TOP (1) CurrencyCode FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1)
    FROM masterdata.Currencies c
    WHERE c.Id = @CurrencyId;
END
GO

/* ================================================================== 13. Files */

CREATE OR ALTER PROCEDURE sales.usp_ReceiptFile_Add
    @ReceiptId        INT,
    @AttachmentTypeId INT            = NULL,
    @Note             NVARCHAR(300)  = NULL,
    @FileName         NVARCHAR(255),
    @ContentType      NVARCHAR(100),
    @SizeBytes        INT,
    @Content          VARBINARY(MAX),
    @UserId           INT            = NULL,
    @NewId            INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Note = NULLIF(LTRIM(RTRIM(@Note)), N'');

    DECLARE @Status TINYINT = (SELECT Status FROM sales.Receipts WHERE Id = @ReceiptId);
    IF @Status IS NULL THROW 71006, 'Receipt not found.', 1;
    -- Evidence keeps arriving after a receipt is posted (a bank statement, a payment advice), so a
    -- posted receipt takes files. A reversed one is closed.
    IF @Status = 3 THROW 71005, 'A reversed receipt is closed; files can no longer be added.', 1;
    IF @AttachmentTypeId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Id = @AttachmentTypeId AND AppliesTo = N'Receipt' AND IsActive = 1)
        THROW 71000, 'Attachment type not found, inactive, or not one for receipts.', 1;
    IF @SizeBytes IS NULL OR @SizeBytes <= 0 THROW 71000, 'The file is empty.', 1;

    INSERT INTO sales.ReceiptFiles (ReceiptId, AttachmentTypeId, Note, FileName, ContentType, SizeBytes, Content, CreatedBy)
    VALUES (@ReceiptId, @AttachmentTypeId, @Note, @FileName, @ContentType, @SizeBytes, @Content, @UserId);
    SET @NewId = SCOPE_IDENTITY();

    INSERT INTO sales.ReceiptAudit (ReceiptId, Action, Details, UserId) VALUES (@ReceiptId, N'FileAdded', @FileName, @UserId);
END
GO

CREATE OR ALTER PROCEDURE sales.usp_ReceiptFile_Get
    @ReceiptId INT, @FileId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, ReceiptId, FileName, ContentType, SizeBytes, Content
    FROM sales.ReceiptFiles WHERE Id = @FileId AND ReceiptId = @ReceiptId;
END
GO

CREATE OR ALTER PROCEDURE sales.usp_ReceiptFile_Delete
    @ReceiptId INT, @FileId INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT = (SELECT Status FROM sales.Receipts WHERE Id = @ReceiptId);
    IF @Status IS NULL THROW 71006, 'Receipt not found.', 1;
    -- Evidence of a posted payment is not removable: that is what it is evidence of.
    IF @Status <> 1 THROW 71005, 'Files can only be removed from a draft receipt.', 1;

    DECLARE @Name NVARCHAR(255) = (SELECT FileName FROM sales.ReceiptFiles WHERE Id = @FileId AND ReceiptId = @ReceiptId);
    IF @Name IS NULL THROW 71006, 'File not found.', 1;

    DELETE FROM sales.ReceiptFiles WHERE Id = @FileId AND ReceiptId = @ReceiptId;
    INSERT INTO sales.ReceiptAudit (ReceiptId, Action, Details, UserId) VALUES (@ReceiptId, N'FileDeleted', @Name, @UserId);
END
GO

/* ================================================================== 14. Permissions */

MERGE security.Permissions AS target
USING
(
    VALUES
        (N'sales.receipts.view',     N'View Receipts',     N'Sales', N'See customer receipts and the invoices they paid.',                                 700),
        (N'sales.receipts.create',   N'Create Receipts',   N'Sales', N'Create and edit draft customer receipts, and attach files to them.',                710),
        (N'sales.receipts.post',     N'Post Receipts',     N'Sales', N'Post a customer receipt: it starts paying the invoices it is allocated to.',        720),
        (N'sales.receipts.reverse',  N'Reverse Receipts',  N'Sales', N'Reverse a posted receipt; the invoices it paid owe the money again.',               730),
        (N'sales.receipts.delete',   N'Delete Receipts',   N'Sales', N'Delete draft customer receipts.',                                                   740),
        (N'sales.receipts.allocate', N'Allocate Receipts', N'Sales', N'Apply the unapplied credit of a posted receipt to invoices, or take an allocation back.', 750)
) AS source (Code, Name, Module, Description, SortOrder)
ON target.Code = source.Code
WHEN MATCHED THEN
    UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Module, Description, SortOrder)
    VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder);
GO

INSERT INTO security.RolePermissions (RoleId, PermissionId)
SELECT r.Id, p.Id
FROM security.Roles r
CROSS JOIN security.Permissions p
WHERE p.Code LIKE N'sales.receipts.%'
  AND (r.IsSystem = 1
       OR (r.Name = N'Manager' AND p.Code IN (N'sales.receipts.view', N'sales.receipts.create', N'sales.receipts.post', N'sales.receipts.allocate')))
  AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);
GO

/* ================================================================== 15. Check */

SELECT Code, Name, Module, SortOrder FROM security.Permissions WHERE Code LIKE N'sales.receipts.%' ORDER BY SortOrder;
SELECT Category, SubType, AppliesTo FROM masterdata.AttachmentTypes WHERE AppliesTo = N'Receipt' ORDER BY SortOrder;
PRINT 'Script 36 applied: receipt logic, invoice settlement, attachment types AppliesTo.';
GO
