CREATE   PROCEDURE sales.usp_SalesDocument_Post
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
            SELECT @MovementDate, l.ItemId, l.WarehouseId, @BranchId, @Direction * l.QuantityBase, l.UnitCostBase,
                   N'Sales', @TypeCode, @Id, l.Id, @Number, NULL, l.ExpiryDate, @UserId
            FROM sales.SalesDocumentLines l
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

