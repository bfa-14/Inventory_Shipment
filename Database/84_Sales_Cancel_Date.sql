SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ==================================================================================================
   84: Sales - the date a document is cancelled
   --------------------------------------------------------------------------------------------------
   Cancelling a posted sales invoice (or return) asks for a date next to the reason: today unless the
   user types another. It is the day the cancellation counts on:
     - stored on the document (SalesDocuments.CancelDate) and shown with it;
     - the date of the reversal stock movements (until now: the moment of the click);
     - never in the future (one day of tolerance, as on the documents), never before the document date.

     sales.SalesDocuments.CancelDate          new column (DATE NULL; NULL on documents cancelled before)
     sales.usp_SalesDocument_Cancel           new parameter @CancelDate (default today), the checks, the dates
     sales.usp_SalesDocument_Get              returns CancelDate

   Each procedure is re-created from its current body with only these changes. Idempotent.
   ================================================================================================== */

IF COL_LENGTH(N'sales.SalesDocuments', N'CancelDate') IS NULL
BEGIN
    ALTER TABLE sales.SalesDocuments ADD CancelDate DATE NULL;
    PRINT 'Added sales.SalesDocuments.CancelDate';
END
GO

CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_Cancel
    @Id         INT,
    @Reason     NVARCHAR(300),
    @CancelDate DATE      = NULL,   -- script 84: the day it is cancelled (default today)
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 64000, 'A cancellation reason is required.', 1;

    /* THE CANCELLATION DATE (script 84): the day the reversal counts on, today unless typed. A day of
       tolerance as everywhere else (the date is the reader's local one, the check is UTC); never before
       the invoice it cancels. */
    IF @CancelDate IS NULL SET @CancelDate = CAST(SYSUTCDATETIME() AS DATE);
    IF @CancelDate > DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE))
        THROW 64000, 'The cancellation date cannot be in the future.', 1;
    DECLARE @InvoiceDate DATE = (SELECT DocumentDate FROM sales.SalesDocuments WHERE Id = @Id);
    IF @InvoiceDate IS NOT NULL AND @CancelDate < @InvoiceDate
    BEGIN
        DECLARE @DateMsg NVARCHAR(200) = N'The cancellation date cannot be before the document date ('
                                         + CONVERT(NVARCHAR(10), @InvoiceDate, 120) + N').';
        THROW 64000, @DateMsg, 1;
    END
    -- The reversal movements are dated on that day, at the time it is done (as a posting dates its own).
    DECLARE @ReversalAt DATETIME2(3) =
        DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@CancelDate AS DATETIME2(3)));

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
        SELECT @ReversalAt, m.ItemId, m.WarehouseId, m.BranchId, -m.QuantityBase, m.UnitCostBase,
               m.DocumentFamily, m.DocumentTypeCode, m.DocumentId, m.DocumentLineId, m.DocumentNumber, m.ReasonCode, m.ExpiryDate, 1, @UserId
        FROM inventory.StockMovements m
        WHERE m.DocumentFamily = N'Sales' AND m.DocumentId = @Id AND m.IsReversal = 0;

        IF @TypeCode = N'SRET' AND @SourceId IS NOT NULL
            UPDATE s SET ReturnedQuantityBase = s.ReturnedQuantityBase - x.Qty
            FROM sales.SalesDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM sales.SalesDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;

        UPDATE sales.SalesDocuments
        SET Status = 3, CancelledAtUtc = SYSUTCDATETIME(), CancelledBy = @UserId, CancelReason = @Reason, CancelDate = @CancelDate,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@Id, N'Cancelled', N'On ' + CONVERT(NVARCHAR(10), @CancelDate, 120) + N': ' + @Reason, @UserId);

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
           d.RateType, d.ExchangeRate, d.PriceListRate, bc.CurrencyCode AS BaseCurrencyCode,
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
           d.CancelledAtUtc, d.CancelledBy, xu.FullName AS CancelledByName, d.CancelReason, d.CancelDate,
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

PRINT 'Script 84 applied: a sales document is cancelled on a date.';
GO
