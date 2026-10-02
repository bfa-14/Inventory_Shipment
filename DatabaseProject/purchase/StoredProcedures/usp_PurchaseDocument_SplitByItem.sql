/* ================================================================== 6. Split a draft invoice by item */

-- A draft purchase invoice saved with several items (before this script): the item of its first line stays on it, every
-- other item gets a new draft with the same header (not the number, the status and its dates, the totals), its lines
-- moved there and numbered from 1. A moved line keeps every column, its ContainerLineId included: that IS the
-- container link, and the new drafts keep the receipt mode ("Shipped in containers"). The files and the charges stay on
-- the original; a manual allocation of one of its charges on a line that leaves it is dropped (it would point at
-- another invoice), as a save of the lines drops them. Returns the rows of the invoices: the original first.
CREATE   PROCEDURE purchase.usp_PurchaseDocument_SplitByItem
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Created TABLE (Seq INT PRIMARY KEY, InvoiceId INT NOT NULL, ItemId INT NOT NULL);

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @TypeId INT, @BranchId INT;
        SELECT @Status = d.Status, @TypeCode = dt.Code, @TypeId = d.DocumentTypeId, @BranchId = d.BranchId
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @TypeCode <> N'PINV' OR @Status <> 1 THROW 65010, 'Only a draft purchase invoice can be split by item.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF (SELECT COUNT(DISTINCT ItemId) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id) <= 1
            THROW 65000, 'This invoice already holds one item.', 1;

        -- the items in the order of their first line: the first one stays
        DECLARE @Items TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, ItemId INT NOT NULL UNIQUE);
        INSERT INTO @Items (ItemId)
        SELECT ItemId FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id GROUP BY ItemId ORDER BY MIN(LineNumber), MIN(Id);
        INSERT INTO @Created (Seq, InvoiceId, ItemId) SELECT 1, @Id, ItemId FROM @Items WHERE Seq = 1;

        DELETE a
        FROM purchase.PurchaseChargeAllocations a
        INNER JOIN purchase.PurchaseCharges c       ON c.Id = a.ChargeId AND c.DocumentKind = N'PINV' AND c.DocumentId = @Id
        INNER JOIN purchase.PurchaseDocumentLines l ON l.Id = a.PurchaseLineId
        WHERE l.ItemId <> (SELECT ItemId FROM @Items WHERE Seq = 1);

        DECLARE @Seq INT = 2, @Last INT = (SELECT MAX(Seq) FROM @Items), @Item INT, @NewId INT, @Number NVARCHAR(30);
        WHILE @Seq <= @Last
        BEGIN
            SET @Item = (SELECT ItemId FROM @Items WHERE Seq = @Seq);

            -- numbered now only when the type numbers its drafts (a purchase invoice is numbered on posting)
            SET @Number = NULL;
            IF EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Id = @TypeId AND NumberOnPost = 0)
                EXEC inventory.usp_DocumentType_NextNumber @TypeCode, @Number OUTPUT, @BranchId;

            INSERT INTO purchase.PurchaseDocuments (DocumentTypeId, DocumentNumber, DocumentDate, ExpectedDate, BranchId, WarehouseId, SupplierId,
                                                    CurrencyId, RateType, ExchangeRate, SupplierReference, Notes, Status, SourceDocumentId,
                                                    SourceShortageId, ReceiptMode, ExporterReference, CommercialInvoiceNo,
                                                    ApprovalRequestedAtUtc, ApprovalRequestedBy, ApprovedAtUtc, ApprovedBy, ApprovalChannel,
                                                    RejectedAtUtc, RejectedBy, RejectReason, CreatedBy)
            SELECT DocumentTypeId, @Number, DocumentDate, ExpectedDate, BranchId, WarehouseId, SupplierId,
                   CurrencyId, RateType, ExchangeRate, SupplierReference, Notes, 1, SourceDocumentId,
                   SourceShortageId, ReceiptMode, ExporterReference, CommercialInvoiceNo,
                   ApprovalRequestedAtUtc, ApprovalRequestedBy, ApprovedAtUtc, ApprovedBy, ApprovalChannel,
                   RejectedAtUtc, RejectedBy, RejectReason, @UserId
            FROM purchase.PurchaseDocuments
            WHERE Id = @Id;
            SET @NewId = SCOPE_IDENTITY();

            -- the lines of the item move, every column kept, numbered from 1
            UPDATE l SET DocumentId = @NewId, LineNumber = x.Seq
            FROM purchase.PurchaseDocumentLines l
            INNER JOIN (SELECT Id, Seq = ROW_NUMBER() OVER (ORDER BY LineNumber, Id)
                        FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND ItemId = @Item) x ON x.Id = l.Id;

            INSERT INTO @Created (Seq, InvoiceId, ItemId) VALUES (@Seq, @NewId, @Item);
            SET @Seq += 1;
        END

        -- what stays on the original, numbered from 1
        UPDATE l SET LineNumber = x.Seq
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN (SELECT Id, Seq = ROW_NUMBER() OVER (ORDER BY LineNumber, Id)
                    FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id) x ON x.Id = l.Id
        WHERE l.LineNumber <> x.Seq;

        -- the totals of every invoice, as usp_PurchaseDocument_Save computes them
        UPDATE d
        SET TotalItems = x.Items, TotalQuantity = x.Qty, Subtotal = x.Sub, TotalAmount = x.Amt, TotalDiscount = x.Sub - x.Amt,
            TotalAmountBase = ROUND(x.Amt / d.ExchangeRate, 2), TotalLandedCostBase = ROUND(x.Amt / d.ExchangeRate, 2) + d.TotalChargesBase,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        FROM purchase.PurchaseDocuments d
        INNER JOIN @Created c ON c.InvoiceId = d.Id
        CROSS APPLY (SELECT COUNT(*) AS Items, ISNULL(SUM(QuantityBase), 0) AS Qty,
                            ISNULL(SUM(CONVERT(DECIMAL(18,2), Quantity * UnitPrice)), 0) AS Sub, ISNULL(SUM(LineTotal), 0) AS Amt
                     FROM purchase.PurchaseDocumentLines WHERE DocumentId = d.Id) x;

        DECLARE @Into NVARCHAR(MAX) =
            (SELECT STRING_AGG(N'draft #' + CAST(c.InvoiceId AS NVARCHAR(10)) + N' (' + i.ItemCode + N')', N', ') WITHIN GROUP (ORDER BY c.Seq)
             FROM @Created c INNER JOIN inventory.Items i ON i.Id = c.ItemId);
        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        SELECT c.InvoiceId, CASE WHEN c.Seq = 1 THEN N'Updated' ELSE N'Created' END, LEFT(N'Split by item into ' + @Into, 500), @UserId
        FROM @Created c;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT r.Id, r.ItemId, r.ItemCode, r.ItemName, r.LineCount, r.QuantityBase, r.TotalAmount, r.RowVersion
    FROM @Created c CROSS APPLY purchase.fn_PurchaseInvoice_Row(c.InvoiceId) r
    ORDER BY c.Seq;
END

GO

