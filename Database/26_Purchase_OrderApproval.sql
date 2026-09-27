/* =====================================================================================
   Inventory_Shipment - 26: PURCHASE ORDER APPROVAL (by email or in the app) + invoicing progress + several
                            invoices per order

   Purchase order flow:
     Draft (1) --send for approval--> Pending approval (5) --approve--> Approved (2, "posted": number assigned)
                                                          --reject---> Draft (1) with the reason
     Approved --invoices created from it, as many as needed, each a draft--> the PO closes by itself (4) once the
     POSTED invoices cover every ordered quantity ("fully invoiced").
   - A purchase order can no longer be posted directly: purchase.usp_PurchaseDocument_Post refuses it (65013) unless
     it is called by the approval (@FromApproval = 1).
   - Approvers = active users of a NON-system role holding "purchase.orders.approve" (Manager and the new Owner role),
     with an email. Each receives a personal link: a random 32-byte token, stored only as its SHA-256 hash, valid
     72 hours, single use; it opens an approval PAGE (approve / reject), never approves by itself.
     Approvers can also decide inside the app. Any one decision closes the other links.
   - After approval the API emails the supplier (masterdata.Parties.Email, required before sending) with the PO and its
     Excel export, and the users of the Owner role get a copy; after a rejection the creator is told why.
   - Emails go through messaging.EmailOutbox (sent by a background worker with retries), so an SMTP problem never
     blocks an approval.
   - Invoicing progress of an order: 0 not invoiced, 1 partially, 2 fully (from the POSTED invoices).
   - Purchase invoices: the list (usp_PurchaseDocument_Search) returns the Exporter Reference, the Commercial
     Invoice No. and the receipt mode, and the free search also matches both references.
   - Invoices from an order: several drafts may exist at the same time; a new one only offers what is not already in
     a posted or draft invoice, optionally limited to selected lines / quantities (@Selection).

   Objects:
     purchase.PurchaseDocuments: status 5, ApprovalRequestedAtUtc/By, ApprovedAtUtc/By, ApprovalChannel,
       RejectedAtUtc/By, RejectReason
     purchase.PurchaseOrderApprovals
     messaging.EmailOutbox + usp_Email_Enqueue / _Claim / _MarkSent / _MarkFailed / _Retry / _Search / _Get
     purchase.tvp_SourceLineSelection
     purchase.usp_PurchaseDocument_Post / _Get (8 result sets) / _Search / _CreateFromSource re-created
     purchase.usp_PurchaseOrder_Approvers / _RequestApproval / _GetByToken / _Decide / _Withdraw
     role Owner; permissions purchase.orders.approve (1050), messaging.emails.view (920);
     purchase.orders.post now means "send for approval"
   Errors: 65013 approval required, 65014 approval link invalid/expired/used, 65015 no approver,
           65016 supplier without email, 65017 not an approver.

   Requires scripts 21-25. Idempotent.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'purchase.PurchaseDocuments', N'U') IS NULL OR COL_LENGTH(N'purchase.PurchaseDocuments', N'ReceiptMode') IS NULL
BEGIN
    RAISERROR ('Run scripts 21 to 25 before this script.', 16, 1);
    RETURN;
END
GO

IF SCHEMA_ID(N'messaging') IS NULL
    EXEC (N'CREATE SCHEMA [messaging] AUTHORIZATION [dbo];');
GO

/* ================================================================== 1. Purchase documents: status 5 + approval columns */

IF EXISTS (SELECT 1 FROM sys.check_constraints
           WHERE name = N'CK_PurchaseDocuments_Status' AND parent_object_id = OBJECT_ID(N'purchase.PurchaseDocuments')
             AND [definition] NOT LIKE N'%5%')
BEGIN
    ALTER TABLE purchase.PurchaseDocuments DROP CONSTRAINT CK_PurchaseDocuments_Status;
    ALTER TABLE purchase.PurchaseDocuments ADD CONSTRAINT CK_PurchaseDocuments_Status CHECK (Status IN (1, 2, 3, 4, 5));
    PRINT 'PurchaseDocuments: status 5 (pending approval) allowed';
END
GO

IF COL_LENGTH(N'purchase.PurchaseDocuments', N'ApprovalRequestedAtUtc') IS NULL
BEGIN
    ALTER TABLE purchase.PurchaseDocuments ADD
        ApprovalRequestedAtUtc DATETIME2(3)  NULL,
        ApprovalRequestedBy    INT           NULL,
        ApprovedAtUtc          DATETIME2(3)  NULL,
        ApprovedBy             INT           NULL,
        ApprovalChannel        NVARCHAR(10)  NULL,      -- Email | App
        RejectedAtUtc          DATETIME2(3)  NULL,
        RejectedBy             INT           NULL,
        RejectReason           NVARCHAR(300) NULL;
    PRINT 'PurchaseDocuments: added approval columns';
END
GO

IF OBJECT_ID(N'purchase.FK_PurchaseDocuments_ApprovedBy', N'F') IS NULL
BEGIN
    ALTER TABLE purchase.PurchaseDocuments ADD CONSTRAINT FK_PurchaseDocuments_ApprovalRequestedBy FOREIGN KEY (ApprovalRequestedBy) REFERENCES security.Users (Id);
    ALTER TABLE purchase.PurchaseDocuments ADD CONSTRAINT FK_PurchaseDocuments_ApprovedBy FOREIGN KEY (ApprovedBy) REFERENCES security.Users (Id);
    ALTER TABLE purchase.PurchaseDocuments ADD CONSTRAINT FK_PurchaseDocuments_RejectedBy FOREIGN KEY (RejectedBy) REFERENCES security.Users (Id);
END
GO

/* ================================================================== 2. Approval requests */

IF OBJECT_ID(N'purchase.PurchaseOrderApprovals', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.PurchaseOrderApprovals
    (
        Id             INT IDENTITY(1,1) NOT NULL,
        DocumentId     INT           NOT NULL,
        RequestNo      INT           NOT NULL,                  -- 1st, 2nd ... submission of the order
        ApproverUserId INT           NOT NULL,
        TokenHash      VARBINARY(32) NOT NULL,                  -- SHA2_256 of the emailed token (the token is never stored)
        ExpiresAtUtc   DATETIME2(3)  NOT NULL,
        Status         TINYINT       NOT NULL CONSTRAINT DF_PurchaseOrderApprovals_Status DEFAULT (1),  -- 1 Pending, 2 Approved, 3 Rejected, 4 Closed
        DecidedAtUtc   DATETIME2(3)  NULL,
        DecisionNote   NVARCHAR(300) NULL,
        Channel        NVARCHAR(10)  NULL,                      -- Email | App
        RequestedBy    INT           NULL,
        RequestedAtUtc DATETIME2(3)  NOT NULL CONSTRAINT DF_PurchaseOrderApprovals_RequestedAt DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_PurchaseOrderApprovals PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_PurchaseOrderApprovals_Token UNIQUE (TokenHash),
        CONSTRAINT CK_PurchaseOrderApprovals_Status CHECK (Status BETWEEN 1 AND 4),
        CONSTRAINT FK_PurchaseOrderApprovals_Document  FOREIGN KEY (DocumentId)     REFERENCES purchase.PurchaseDocuments (Id),
        CONSTRAINT FK_PurchaseOrderApprovals_Approver  FOREIGN KEY (ApproverUserId) REFERENCES security.Users (Id),
        CONSTRAINT FK_PurchaseOrderApprovals_Requested FOREIGN KEY (RequestedBy)    REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_PurchaseOrderApprovals_Document ON purchase.PurchaseOrderApprovals (DocumentId, Status);
    PRINT 'Created purchase.PurchaseOrderApprovals';
END
GO

/* ================================================================== 3. Email outbox */

IF OBJECT_ID(N'messaging.EmailOutbox', N'U') IS NULL
BEGIN
    CREATE TABLE messaging.EmailOutbox
    (
        Id                    BIGINT IDENTITY(1,1) NOT NULL,
        ToAddresses           NVARCHAR(1000) NOT NULL,          -- ; separated
        CcAddresses           NVARCHAR(1000) NULL,
        Subject               NVARCHAR(300)  NOT NULL,
        BodyHtml              NVARCHAR(MAX)  NOT NULL,
        AttachmentName        NVARCHAR(255)  NULL,
        AttachmentContentType NVARCHAR(100)  NULL,
        AttachmentContent     VARBINARY(MAX) NULL,
        Category              NVARCHAR(40)   NOT NULL,          -- PO_APPROVAL_REQUEST | PO_APPROVED_SUPPLIER | PO_APPROVED_OWNER | PO_REJECTED
        RelatedDocumentId     INT            NULL,
        Status                TINYINT        NOT NULL CONSTRAINT DF_EmailOutbox_Status DEFAULT (1),    -- 1 Pending, 2 Sent, 3 Failed
        Attempts              INT            NOT NULL CONSTRAINT DF_EmailOutbox_Attempts DEFAULT (0),
        NextAttemptAtUtc      DATETIME2(3)   NOT NULL CONSTRAINT DF_EmailOutbox_Next DEFAULT (SYSUTCDATETIME()),
        LastError             NVARCHAR(1000) NULL,
        CreatedAtUtc          DATETIME2(3)   NOT NULL CONSTRAINT DF_EmailOutbox_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy             INT            NULL,
        SentAtUtc             DATETIME2(3)   NULL,
        CONSTRAINT PK_EmailOutbox PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_EmailOutbox_Status CHECK (Status IN (1, 2, 3)),
        CONSTRAINT FK_EmailOutbox_CreatedBy FOREIGN KEY (CreatedBy) REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_EmailOutbox_Due      ON messaging.EmailOutbox (Status, NextAttemptAtUtc);
    CREATE NONCLUSTERED INDEX IX_EmailOutbox_Document ON messaging.EmailOutbox (RelatedDocumentId);
    PRINT 'Created messaging.EmailOutbox';
END
GO

CREATE OR ALTER PROCEDURE messaging.usp_Email_Enqueue
    @ToAddresses           NVARCHAR(1000),
    @CcAddresses           NVARCHAR(1000) = NULL,
    @Subject               NVARCHAR(300),
    @BodyHtml              NVARCHAR(MAX),
    @AttachmentName        NVARCHAR(255)  = NULL,
    @AttachmentContentType NVARCHAR(100)  = NULL,
    @AttachmentContent     VARBINARY(MAX) = NULL,
    @Category              NVARCHAR(40),
    @RelatedDocumentId     INT            = NULL,
    @UserId                INT            = NULL,
    @NewId                 BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @ToAddresses = NULLIF(LTRIM(RTRIM(@ToAddresses)), N'');
    SET @CcAddresses = NULLIF(LTRIM(RTRIM(@CcAddresses)), N'');
    IF @ToAddresses IS NULL THROW 65000, 'An email needs at least one recipient.', 1;
    IF NULLIF(LTRIM(RTRIM(@Subject)), N'') IS NULL THROW 65000, 'An email needs a subject.', 1;

    INSERT INTO messaging.EmailOutbox (ToAddresses, CcAddresses, Subject, BodyHtml, AttachmentName, AttachmentContentType,
                                       AttachmentContent, Category, RelatedDocumentId, CreatedBy)
    VALUES (@ToAddresses, @CcAddresses, @Subject, @BodyHtml, @AttachmentName, @AttachmentContentType,
            @AttachmentContent, @Category, @RelatedDocumentId, @UserId);
    SET @NewId = SCOPE_IDENTITY();
END
GO

-- Takes the next due emails for the background sender (safe with several API instances: READPAST + lease).
CREATE OR ALTER PROCEDURE messaging.usp_Email_Claim
    @BatchSize    INT = 10,
    @LeaseMinutes INT = 5
AS
BEGIN
    SET NOCOUNT ON;
    IF @BatchSize IS NULL OR @BatchSize < 1 SET @BatchSize = 10;
    ;WITH due AS
    (
        SELECT TOP (@BatchSize) Id, Attempts, NextAttemptAtUtc
        FROM messaging.EmailOutbox WITH (UPDLOCK, READPAST, ROWLOCK)
        WHERE Status = 1 AND NextAttemptAtUtc <= SYSUTCDATETIME()
        ORDER BY Id
    )
    UPDATE due
    SET Attempts = Attempts + 1, NextAttemptAtUtc = DATEADD(MINUTE, @LeaseMinutes, SYSUTCDATETIME())
    OUTPUT inserted.Id;          -- the worker then reads each claimed email with usp_Email_Get
END
GO

CREATE OR ALTER PROCEDURE messaging.usp_Email_Get
    @Id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, ToAddresses, CcAddresses, Subject, BodyHtml, AttachmentName, AttachmentContentType, AttachmentContent,
           Category, RelatedDocumentId, Status, Attempts, NextAttemptAtUtc, LastError, CreatedAtUtc, SentAtUtc
    FROM messaging.EmailOutbox WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE messaging.usp_Email_MarkSent
    @Id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE messaging.EmailOutbox SET Status = 2, SentAtUtc = SYSUTCDATETIME(), LastError = NULL WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE messaging.usp_Email_MarkFailed
    @Id          BIGINT,
    @Error       NVARCHAR(1000),
    @MaxAttempts INT = 5
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE messaging.EmailOutbox
    SET LastError = LEFT(@Error, 1000),
        Status = CASE WHEN Attempts >= @MaxAttempts THEN 3 ELSE 1 END,
        NextAttemptAtUtc = DATEADD(MINUTE, 5 * Attempts, SYSUTCDATETIME())
    WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE messaging.usp_Email_Retry
    @Id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM messaging.EmailOutbox WHERE Id = @Id) THROW 65006, 'Email not found.', 1;
    UPDATE messaging.EmailOutbox SET Status = 1, Attempts = 0, NextAttemptAtUtc = SYSUTCDATETIME() WHERE Id = @Id AND Status <> 2;
END
GO

CREATE OR ALTER PROCEDURE messaging.usp_Email_Search
    @Search            NVARCHAR(200) = NULL,    -- recipient or subject
    @Status            TINYINT       = NULL,
    @Category          NVARCHAR(40)  = NULL,
    @RelatedDocumentId INT           = NULL,
    @DateFrom          DATE          = NULL,
    @DateTo            DATE          = NULL,
    @PageNumber        INT           = 1,
    @PageSize          INT           = 20
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 20;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');

    SELECT e.Id, e.ToAddresses, e.CcAddresses, e.Subject, e.Category, e.RelatedDocumentId, e.Status, e.Attempts,
           e.NextAttemptAtUtc, e.LastError, e.CreatedAtUtc, e.SentAtUtc, e.AttachmentName,
           AttachmentSize = DATALENGTH(e.AttachmentContent),
           COUNT(*) OVER () AS TotalCount
    FROM messaging.EmailOutbox e
    WHERE (@Search IS NULL OR e.ToAddresses LIKE N'%' + @Search + N'%' OR e.Subject LIKE N'%' + @Search + N'%')
      AND (@Status IS NULL OR e.Status = @Status)
      AND (@Category IS NULL OR e.Category = @Category)
      AND (@RelatedDocumentId IS NULL OR e.RelatedDocumentId = @RelatedDocumentId)
      AND (@DateFrom IS NULL OR e.CreatedAtUtc >= @DateFrom)
      AND (@DateTo IS NULL OR e.CreatedAtUtc < DATEADD(DAY, 1, @DateTo))
    ORDER BY e.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

/* ================================================================== 4. Selection of lines when creating an invoice / return from a source */

IF TYPE_ID(N'purchase.tvp_SourceLineSelection') IS NULL
BEGIN
    CREATE TYPE purchase.tvp_SourceLineSelection AS TABLE
    (
        SourceLineId INT NOT NULL PRIMARY KEY,
        QuantityBase INT NOT NULL              -- base units to take from that source line
    );
    PRINT 'Created type purchase.tvp_SourceLineSelection';
END
GO

/* ================================================================== 5. Re-created purchase procedures */

-- Re-created: purchase orders are posted only by their approval (@FromApproval = 1); no result set in that case.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Post
    @Id         INT,
    @RowVersion   BINARY(8) = NULL,
    @UserId       INT       = NULL,
    @FromApproval BIT       = 0      -- 1 = called by the approval: purchase orders are only posted that way
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Direction SMALLINT, @Number NVARCHAR(30), @DocumentDate DATE,
                @BranchId INT, @SupplierId INT, @Rate DECIMAL(18,6), @SourceId INT, @ReceiptMode TINYINT;

        SELECT @Status = d.Status, @TypeCode = dt.Code, @Direction = dt.StockDirection, @Number = d.DocumentNumber,
               @DocumentDate = d.DocumentDate, @BranchId = d.BranchId, @SupplierId = d.SupplierId, @Rate = d.ExchangeRate,
               @SourceId = d.SourceDocumentId, @ReceiptMode = d.ReceiptMode
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @TypeCode = N'PO' AND ISNULL(@FromApproval, 0) = 0
            THROW 65013, 'A purchase order is posted by its approval. Send it for approval instead.', 1;
        IF @TypeCode = N'PO' AND @Status <> 5 THROW 65010, 'Only a purchase order waiting for approval can be approved.', 1;
        IF @TypeCode <> N'PO' AND @Status <> 1 THROW 65010, 'Only draft documents can be posted.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id)
            THROW 65009, 'The document has no lines. Add at least one item before posting.', 1;
        IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SupplierId AND IsActive = 1)
            THROW 65008, 'The supplier is inactive.', 1;

        -- Imports: the goods are received by the container, not by this posting.
        DECLARE @ReceiveNow BIT = CASE WHEN @TypeCode = N'PINV' AND @ReceiptMode = 2 THEN 0 ELSE 1 END;

        DECLARE @Msg NVARCHAR(400);
        SELECT TOP (1) @Msg =
            CASE WHEN i.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item ' + i.ItemCode + N' is inactive.'
                 WHEN w.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is inactive.'
                 WHEN w.BranchId <> @BranchId THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is not in the document branch.' END
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id AND (i.IsActive = 0 OR w.IsActive = 0 OR w.BranchId <> @BranchId)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 65000, @Msg, 1;

        IF @SourceId IS NOT NULL
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @SourceId AND Status = 2)
                THROW 65011, 'The source document is no longer open (cancelled or closed).', 1;

            IF @TypeCode = N'PINV'
            BEGIN
                SELECT TOP (1) @Msg = N'Line ' + CAST(x.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - ' + CAST(x.Qty AS NVARCHAR(20))
                                     + N' base units invoiced but only ' + CAST(s.QuantityBase - s.ReceivedQuantityBase AS NVARCHAR(20)) + N' remain on the order line.'
                FROM (SELECT SourceLineId, SUM(QuantityBase) AS Qty, MIN(LineNumber) AS LineNumber FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x
                INNER JOIN purchase.PurchaseDocumentLines s ON s.Id = x.SourceLineId
                INNER JOIN inventory.Items i ON i.Id = s.ItemId
                WHERE x.Qty > s.QuantityBase - s.ReceivedQuantityBase
                ORDER BY x.LineNumber;
                IF @Msg IS NOT NULL THROW 65011, @Msg, 1;
            END
            IF @TypeCode = N'PRET'
            BEGIN
                SELECT TOP (1) @Msg = N'Line ' + CAST(x.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - ' + CAST(x.Qty AS NVARCHAR(20))
                                     + N' base units returned but only ' + CAST(s.QuantityBase - s.ReturnedQuantityBase AS NVARCHAR(20)) + N' can still be returned from the invoice line.'
                FROM (SELECT SourceLineId, SUM(QuantityBase) AS Qty, MIN(LineNumber) AS LineNumber FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x
                INNER JOIN purchase.PurchaseDocumentLines s ON s.Id = x.SourceLineId
                INNER JOIN inventory.Items i ON i.Id = s.ItemId
                WHERE x.Qty > s.QuantityBase - s.ReturnedQuantityBase
                ORDER BY x.LineNumber;
                IF @Msg IS NOT NULL THROW 65011, @Msg, 1;
            END
        END

        IF @Direction = -1
        BEGIN
            SELECT TOP (1) @Msg = N'Insufficient stock for ' + i.ItemCode + N' in ' + w.WarehouseCode + N': available '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N', required ' + CAST(x.Qty AS NVARCHAR(20)) + N' (base units).'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 65007, @Msg, 1;
        END

        IF @Number IS NULL
            EXEC inventory.usp_DocumentType_NextNumber @TypeCode, @Number OUTPUT, @BranchId;

        IF @TypeCode = N'PINV'
        BEGIN
            -- FOB per base unit, then charges allocated over the lines, then landed cost per base unit.
            EXEC purchase.usp_PurchaseCharges_Allocate N'PINV', @Id, @Id;

            UPDATE l
            SET FobCostBase = (l.LineTotal / @Rate) / l.QuantityBase,
                AllocatedChargesBase = ISNULL(a.Total, 0),
                UnitCostBase = ((l.LineTotal / @Rate) + ISNULL(a.Total, 0)) / l.QuantityBase
            FROM purchase.PurchaseDocumentLines l
            OUTER APPLY (SELECT SUM(x.AmountBase) AS Total
                         FROM purchase.PurchaseChargeAllocations x
                         INNER JOIN purchase.PurchaseCharges c ON c.Id = x.ChargeId
                         WHERE x.PurchaseLineId = l.Id AND c.DocumentKind = N'PINV' AND c.DocumentId = @Id AND c.IncludeInLandedCost = 1) a
            WHERE l.DocumentId = @Id;

            UPDATE d
            SET TotalChargesBase = ISNULL(x.Charges, 0), TotalLandedCostBase = d.TotalAmountBase + ISNULL(x.Charges, 0)
            FROM purchase.PurchaseDocuments d
            CROSS APPLY (SELECT SUM(AllocatedChargesBase) AS Charges FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id) x
            WHERE d.Id = @Id;
        END
        ELSE IF @TypeCode = N'PRET'
            UPDATE l SET UnitCostBase = ISNULL(l.UnitCostBase, ISNULL(inventory.fn_AverageCost(l.ItemId), 0))
            FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = @Id;

        IF @Direction = 1 AND @ReceiveNow = 1
        BEGIN
            DECLARE @R inventory.tvp_ItemReceipt;
            INSERT INTO @R (ItemId, QuantityBase, UnitCostBase, FobCostBase)
            SELECT l.ItemId, l.QuantityBase, ISNULL(l.UnitCostBase, 0), l.FobCostBase FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = @Id;
            EXEC inventory.usp_Item_ApplyReceipts @R, @SupplierId, @UserId, 1;
        END

        IF @Direction <> 0 AND @ReceiveNow = 1
        BEGIN
            DECLARE @MovementDate DATETIME2(3) =
                DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@DocumentDate AS DATETIME2(3)));

            INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                                  DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, CreatedBy)
            SELECT @MovementDate, l.ItemId, l.WarehouseId, @BranchId, @Direction * l.QuantityBase, l.UnitCostBase,
                   N'Purchase', @TypeCode, @Id, l.Id, @Number, NULL, l.ExpiryDate, @UserId
            FROM purchase.PurchaseDocumentLines l
            WHERE l.DocumentId = @Id;

            IF @Direction = 1
                UPDATE purchase.PurchaseDocumentLines SET ReceivedQuantityBase = QuantityBase WHERE DocumentId = @Id;
        END

        IF @SourceId IS NOT NULL AND @TypeCode = N'PINV'
        BEGIN
            UPDATE s SET ReceivedQuantityBase = s.ReceivedQuantityBase + x.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;

            IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines WHERE DocumentId = @SourceId AND ReceivedQuantityBase < QuantityBase)
            BEGIN
                UPDATE purchase.PurchaseDocuments SET Status = 4, ClosedAtUtc = SYSUTCDATETIME(), ClosedBy = @UserId, CloseReason = N'Fully received' WHERE Id = @SourceId;
                INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@SourceId, N'Closed', N'Fully received by ' + @Number, @UserId);
            END
        END
        IF @SourceId IS NOT NULL AND @TypeCode = N'PRET'
        BEGIN
            UPDATE s SET ReturnedQuantityBase = s.ReturnedQuantityBase + x.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;
        END

        UPDATE purchase.PurchaseDocuments
        SET DocumentNumber = @Number, Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        DECLARE @LineCount INT = (SELECT COUNT(*) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id);
        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@Id, N'Posted', N'Posted as ' + @Number + N' - ' + CAST(@LineCount AS NVARCHAR(10)) + N' line(s)'
                                + CASE WHEN @Direction <> 0 AND @ReceiveNow = 1 THEN N' written to the stock ledger'
                                       WHEN @ReceiveNow = 0 THEN N'; stock will be received when the container is offloaded'
                                       ELSE N' (order approved)' END
                                + CASE WHEN @TypeCode = N'PINV' THEN N'; landed charges ' + CAST((SELECT TotalChargesBase FROM purchase.PurchaseDocuments WHERE Id = @Id) AS NVARCHAR(30)) ELSE N'' END, @UserId);

        COMMIT TRANSACTION;
        IF ISNULL(@FromApproval, 0) = 0 SELECT @Number AS DocumentNumber;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Re-created: approval fields, invoicing progress, per-line draft quantities, 8th result set = approvals.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.Id, d.DocumentTypeId, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, dt.StockDirection, dt.NumberOnPost,
           d.DocumentNumber, d.DocumentDate, d.ExpectedDate,
           d.BranchId, b.BranchCode, b.BranchName, d.WarehouseId, w.WarehouseCode, w.WarehouseName,
           d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName, sp.Phone AS SupplierPhone, sp.Email AS SupplierEmail, sp.Address AS SupplierAddress,
           d.CurrencyId, c.CurrencyCode, c.CurrencyName, c.Symbol AS CurrencySymbol, c.DecimalPlaces, c.IsBaseCurrency,
           d.RateType, d.ExchangeRate, bc.CurrencyCode AS BaseCurrencyCode,
           d.SupplierReference, d.ExporterReference, d.CommercialInvoiceNo, d.ReceiptMode, d.Notes, d.Status,
           d.ApprovalRequestedAtUtc, d.ApprovalRequestedBy, rqu.FullName AS ApprovalRequestedByName,
           d.ApprovedAtUtc, d.ApprovedBy, apu.FullName AS ApprovedByName, d.ApprovalChannel,
           d.RejectedAtUtc, d.RejectedBy, rju.FullName AS RejectedByName, d.RejectReason,
           OrderedBase = prog.Ordered, InvoicedBase = prog.Invoiced, InDraftInvoicesBase = ISNULL(drf.InDraft, 0),
           InvoicingStatus = CASE WHEN dt.Code <> N'PO' THEN NULL WHEN ISNULL(prog.Invoiced, 0) = 0 THEN 0
                                  WHEN prog.Invoiced >= prog.Ordered THEN 2 ELSE 1 END,      -- 0 not, 1 partially, 2 fully invoiced
           d.TotalItems, d.TotalQuantity, d.Subtotal, d.TotalDiscount, d.TotalAmount, d.TotalAmountBase, d.TotalChargesBase, d.TotalLandedCostBase,
           d.SourceDocumentId, src.DocumentNumber AS SourceDocumentNumber, sdt.Code AS SourceDocumentTypeCode,
           d.SourceShortageId, sh.DocumentNumber AS SourceShortageNumber,
           d.PostedAtUtc, d.PostedBy, pu.FullName AS PostedByName,
           d.CancelledAtUtc, d.CancelledBy, xu.FullName AS CancelledByName, d.CancelReason,
           d.ClosedAtUtc, d.ClosedBy, ku.FullName AS ClosedByName, d.CloseReason,
           d.CreatedAtUtc, d.CreatedBy, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.UpdatedBy, uu.FullName AS UpdatedByName,
           d.RowVersion
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Branches b      ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w    ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Parties sp      ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    LEFT  JOIN masterdata.Currencies bc   ON bc.IsBaseCurrency = 1 AND bc.IsActive = 1
    LEFT  JOIN purchase.PurchaseDocuments src ON src.Id = d.SourceDocumentId
    LEFT  JOIN inventory.DocumentTypes sdt ON sdt.Id = src.DocumentTypeId
    LEFT  JOIN inventory.ShortageDocuments sh ON sh.Id = d.SourceShortageId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = d.UpdatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    LEFT  JOIN security.Users xu ON xu.Id = d.CancelledBy
    LEFT  JOIN security.Users ku ON ku.Id = d.ClosedBy
    LEFT  JOIN security.Users rqu ON rqu.Id = d.ApprovalRequestedBy
    LEFT  JOIN security.Users apu ON apu.Id = d.ApprovedBy
    LEFT  JOIN security.Users rju ON rju.Id = d.RejectedBy
    OUTER APPLY (SELECT Ordered = SUM(pl.QuantityBase), Invoiced = SUM(pl.ReceivedQuantityBase)
                 FROM purchase.PurchaseDocumentLines pl WHERE pl.DocumentId = d.Id) prog
    OUTER APPLY (SELECT InDraft = SUM(x.QuantityBase)
                 FROM purchase.PurchaseDocumentLines pl
                 INNER JOIN purchase.PurchaseDocumentLines x ON x.SourceLineId = pl.Id
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId AND xd.Status = 1
                 WHERE pl.DocumentId = d.Id) drf
    WHERE d.Id = @Id;

    SELECT l.Id, l.DocumentId, l.LineNumber, l.ItemId, i.ItemCode, i.ItemName,
           l.ItemUnitId, ut.UnitTypeName, iu.SkuCode, iu.Barcode, l.PackingFormula,
           l.WarehouseId, w.WarehouseCode, w.WarehouseName, l.ExpiryDate,
           l.Quantity, l.QuantityBase, l.UnitPrice, l.DiscountPercent, l.LineDiscount, l.LineTotal,
           l.UnitCostBase, LandedCostBase = l.UnitCostBase, l.FobCostBase, l.AllocatedChargesBase,
           l.ReceivedQuantityBase, l.ReturnedQuantityBase, l.ShippedQuantityBase,
           AllocatedToContainersBase = ISNULL(ct.Allocated, 0),
           TransitBase = ISNULL(ct.Transit, 0),
           RemainingBase = CASE WHEN dt.Code = N'PO' THEN l.QuantityBase - l.ReceivedQuantityBase
                                WHEN dt.Code = N'PINV' THEN l.QuantityBase - l.ReturnedQuantityBase END,
           AvailableForContainerBase = CASE WHEN dt.Code = N'PINV' THEN l.QuantityBase - ISNULL(ct.Allocated, 0) END,
           InDraftDocumentsBase = ISNULL(dr.Qty, 0),
           AvailableToInvoiceBase = CASE WHEN dt.Code = N'PO' THEN l.QuantityBase - l.ReceivedQuantityBase - ISNULL(dr.Qty, 0) END,
           l.ImportRowNumber, l.Notes, l.SourceLineId,
           OnHandBase  = inventory.fn_StockOnHand(l.ItemId, l.WarehouseId),
           ItemLastCost = i.LastCost, ItemAverageCost = i.AverageCost, ItemFobCost = i.FobCost
    FROM purchase.PurchaseDocumentLines l
    INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
    INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId
    INNER JOIN inventory.Items i            ON i.Id = l.ItemId
    INNER JOIN inventory.ItemUnits iu       ON iu.Id = l.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut      ON ut.Id = iu.UnitTypeId
    INNER JOIN masterdata.Warehouses w      ON w.Id = l.WarehouseId
    OUTER APPLY (SELECT Allocated = SUM(cl.QuantityBase),
                        Transit   = SUM(CASE WHEN c.Status IN (3, 4, 5) THEN cl.QuantityBase - ISNULL(cl.ReceivedQuantityBase, 0) ELSE 0 END)
                 FROM logistics.ContainerLines cl
                 INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                 WHERE cl.PurchaseLineId = l.Id AND c.Status <> 8) ct
    OUTER APPLY (SELECT Qty = SUM(x.QuantityBase) FROM purchase.PurchaseDocumentLines x
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
                 WHERE x.SourceLineId = l.Id AND xd.Status = 1) dr
    WHERE l.DocumentId = @Id
    ORDER BY l.LineNumber;

    SELECT f.Id, f.DocumentId, f.FileName, f.ContentType, f.SizeBytes, f.CreatedAtUtc, u.FullName AS CreatedByName
    FROM purchase.PurchaseDocumentFiles f
    LEFT JOIN security.Users u ON u.Id = f.CreatedBy
    WHERE f.DocumentId = @Id
    ORDER BY f.CreatedAtUtc DESC;

    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM purchase.PurchaseDocumentAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.DocumentId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;

    SELECT Relation = N'Source', x.Id, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, x.DocumentNumber, x.DocumentDate, x.Status, x.TotalAmount, c.CurrencyCode
    FROM purchase.PurchaseDocuments d
    INNER JOIN purchase.PurchaseDocuments x ON x.Id = d.SourceDocumentId
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = x.DocumentTypeId
    INNER JOIN masterdata.Currencies c ON c.Id = x.CurrencyId
    WHERE d.Id = @Id
    UNION ALL
    SELECT N'Child', x.Id, dt.Code, dt.Name, x.DocumentNumber, x.DocumentDate, x.Status, x.TotalAmount, c.CurrencyCode
    FROM purchase.PurchaseDocuments x
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = x.DocumentTypeId
    INNER JOIN masterdata.Currencies c ON c.Id = x.CurrencyId
    WHERE x.SourceDocumentId = @Id
    ORDER BY Relation DESC, DocumentDate, Id;

    -- 6: charges of the invoice (kind PINV) and of its posted / draft adjustments (kind LCA), with the allocated total.
    SELECT c.Id, c.DocumentKind, c.DocumentId, SourceNumber = CASE WHEN c.DocumentKind = N'LCA' THEN lca.DocumentNumber ELSE d.DocumentNumber END,
           c.LineNumber, c.ChargeTypeId, ct.ChargeCode, ct.ChargeName, c.Description, c.ProviderPartyId, pp.PartyName AS ProviderName, c.Reference,
           c.CurrencyId, cur.CurrencyCode, c.RateType, c.ExchangeRate, c.Amount, c.AmountBase, c.AllocationMethod, c.IncludeInLandedCost, c.IncludedInSupplierInvoice, c.Notes,
           AllocatedBase = (SELECT SUM(AmountBase) FROM purchase.PurchaseChargeAllocations x WHERE x.ChargeId = c.Id),
           AdjustmentStatus = lca.Status
    FROM purchase.PurchaseCharges c
    INNER JOIN purchase.ChargeTypes ct ON ct.Id = c.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = c.CurrencyId
    LEFT  JOIN masterdata.Parties pp ON pp.Id = c.ProviderPartyId
    LEFT  JOIN purchase.PurchaseDocuments d ON d.Id = c.DocumentId AND c.DocumentKind = N'PINV'
    LEFT  JOIN purchase.LandedCostAdjustments lca ON lca.Id = c.DocumentId AND c.DocumentKind = N'LCA'
    WHERE (c.DocumentKind = N'PINV' AND c.DocumentId = @Id)
       OR (c.DocumentKind = N'LCA' AND lca.SourceInvoiceId = @Id)
    ORDER BY c.DocumentKind, c.DocumentId, c.LineNumber;

    -- 7: containers carrying this invoice.
    SELECT ct.Id, ct.ContainerRef, ct.ContainerNo, ct.Status, ct.DispatchDate, ct.Eta, ct.OffloadedDate,
           ct.CurrentLocation, w.WarehouseCode, w.WarehouseName,
           AllocatedBase = ISNULL(x.Allocated, 0), ReceivedBase = ISNULL(x.Received, 0)
    FROM logistics.ContainerInvoices ci
    INNER JOIN logistics.Containers ct ON ct.Id = ci.ContainerId
    LEFT  JOIN masterdata.Warehouses w ON w.Id = ct.WarehouseId
    OUTER APPLY (SELECT Allocated = SUM(cl.QuantityBase), Received = SUM(ISNULL(cl.ReceivedQuantityBase, 0))
                 FROM logistics.ContainerLines cl
                 WHERE cl.ContainerId = ct.Id AND cl.PurchaseDocumentId = @Id) x
    WHERE ci.PurchaseDocumentId = @Id
    ORDER BY ct.ContainerRef;

    -- 8: approval requests and decisions (purchase orders).
    SELECT a.Id, a.RequestNo, a.ApproverUserId, u.FullName AS ApproverName, u.Email AS ApproverEmail,
           a.Status, a.ExpiresAtUtc, a.DecidedAtUtc, a.DecisionNote, a.Channel, a.RequestedAtUtc, ru.FullName AS RequestedByName
    FROM purchase.PurchaseOrderApprovals a
    INNER JOIN security.Users u ON u.Id = a.ApproverUserId
    LEFT  JOIN security.Users ru ON ru.Id = a.RequestedBy
    WHERE a.DocumentId = @Id
    ORDER BY a.RequestNo DESC, a.Id;
END
GO

-- Re-created: status 5, invoicing progress and filter.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Search
    @DocumentTypeCode NVARCHAR(20) = NULL,     -- PO | PINV | PRET | NULL = whole family
    @Search           NVARCHAR(100) = NULL,    -- number, supplier / exporter reference, commercial invoice no., supplier code/name, notes
    @BranchId         INT          = NULL,
    @WarehouseId      INT          = NULL,
    @SupplierId       INT          = NULL,
    @Status           TINYINT      = NULL,     -- 1 Draft | 2 Posted (PO: approved) | 3 Cancelled | 4 Closed | 5 Pending approval
    @InvoicingStatus  TINYINT      = NULL,     -- purchase orders: 0 not invoiced | 1 partially | 2 fully
    @DateFrom         DATE         = NULL,
    @DateTo           DATE         = NULL,
    @SortColumn       NVARCHAR(30) = N'DocumentDate',  -- DocumentNumber | DocumentDate | SupplierName | Status | TotalAmount | CreatedAtUtc
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
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'DocumentNumber', N'DocumentDate', N'SupplierName', N'Status', N'TotalAmount', N'CreatedAtUtc')
        SET @SortColumn = N'DocumentDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT d.Id, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, dt.StockDirection,
           d.DocumentNumber, d.DocumentDate, d.ExpectedDate, d.BranchId, b.BranchName, d.WarehouseId, w.WarehouseName,
           d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName,
           d.CurrencyId, c.CurrencyCode, c.Symbol AS CurrencySymbol, c.DecimalPlaces, d.ExchangeRate,
           d.SupplierReference, d.ExporterReference, d.CommercialInvoiceNo, d.ReceiptMode,
           d.Status, d.TotalItems, d.TotalQuantity, d.Subtotal, d.TotalDiscount, d.TotalAmount, d.TotalAmountBase,
           d.SourceDocumentId, src.DocumentNumber AS SourceDocumentNumber,
           ReceivedPercent = CASE WHEN dt.Code = N'PO' AND ISNULL(prog.Ordered, 0) > 0 THEN CAST(100.0 * prog.Invoiced / prog.Ordered AS DECIMAL(5,1)) END,
           InvoicedPercent = CASE WHEN dt.Code = N'PO' AND ISNULL(prog.Ordered, 0) > 0 THEN CAST(100.0 * prog.Invoiced / prog.Ordered AS DECIMAL(5,1)) END,
           InvoicingStatus = CASE WHEN dt.Code <> N'PO' THEN NULL WHEN ISNULL(prog.Invoiced, 0) = 0 THEN 0
                                  WHEN prog.Invoiced >= prog.Ordered THEN 2 ELSE 1 END,
           DraftInvoiceCount = CASE WHEN dt.Code = N'PO' THEN (SELECT COUNT(*) FROM purchase.PurchaseDocuments x WHERE x.SourceDocumentId = d.Id AND x.Status = 1) END,
           d.ApprovalRequestedAtUtc, d.ApprovedAtUtc, apu.FullName AS ApprovedByName,
           d.PostedAtUtc, pu.FullName AS PostedByName, d.CancelledAtUtc, d.ClosedAtUtc,
           d.CreatedAtUtc, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Branches b      ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w    ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Parties sp      ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    LEFT  JOIN purchase.PurchaseDocuments src ON src.Id = d.SourceDocumentId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    LEFT  JOIN security.Users apu ON apu.Id = d.ApprovedBy
    OUTER APPLY (SELECT Ordered = SUM(QuantityBase), Invoiced = SUM(ReceivedQuantityBase)
                 FROM purchase.PurchaseDocumentLines WHERE DocumentId = d.Id) prog
    WHERE dt.Family = N'Purchase'
      AND (@DocumentTypeCode IS NULL OR dt.Code = @DocumentTypeCode)
      AND (@Search IS NULL OR d.DocumentNumber LIKE N'%' + @Search + N'%' OR d.SupplierReference LIKE N'%' + @Search + N'%'
           OR d.ExporterReference LIKE N'%' + @Search + N'%' OR d.CommercialInvoiceNo LIKE N'%' + @Search + N'%'
           OR sp.PartyCode LIKE N'%' + @Search + N'%' OR sp.PartyName LIKE N'%' + @Search + N'%' OR d.Notes LIKE N'%' + @Search + N'%')
      AND (@BranchId IS NULL OR d.BranchId = @BranchId)
      AND (@WarehouseId IS NULL OR d.WarehouseId = @WarehouseId)
      AND (@SupplierId IS NULL OR d.SupplierId = @SupplierId)
      AND (@Status IS NULL OR d.Status = @Status)
      AND (@InvoicingStatus IS NULL OR (dt.Code = N'PO' AND
           CASE WHEN ISNULL(prog.Invoiced, 0) = 0 THEN 0 WHEN prog.Invoiced >= prog.Ordered THEN 2 ELSE 1 END = @InvoicingStatus))
      AND (@DateFrom IS NULL OR d.DocumentDate >= @DateFrom)
      AND (@DateTo IS NULL OR d.DocumentDate <= @DateTo)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN d.DocumentNumber WHEN N'SupplierName' THEN sp.PartyName END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN d.DocumentNumber WHEN N'SupplierName' THEN sp.PartyName END
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

-- Re-created: several drafts per source; optional selection of lines / quantities.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_CreateFromSource
    @SourceId       INT,
    @TargetTypeCode NVARCHAR(20),        -- PINV (from PO) | PRET (from PINV)
    @DocumentDate   DATE = NULL,         -- default today
    @Selection      purchase.tvp_SourceLineSelection READONLY,   -- lines + base quantities to take; empty = everything still available
    @UserId         INT  = NULL,
    @NewId          INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF @DocumentDate IS NULL SET @DocumentDate = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @SrcType NVARCHAR(20), @Status TINYINT, @BranchId INT, @WarehouseId INT, @SupplierId INT, @CurrencyId INT, @RateType TINYINT, @SupplierRef NVARCHAR(100);
    SELECT @SrcType = dt.Code, @Status = d.Status, @BranchId = d.BranchId, @WarehouseId = d.WarehouseId, @SupplierId = d.SupplierId,
           @CurrencyId = d.CurrencyId, @RateType = d.RateType, @SupplierRef = d.SupplierReference
    FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId WHERE d.Id = @SourceId;

    IF @SrcType IS NULL THROW 65006, 'Source document not found.', 1;
    IF @Status <> 2 THROW 65011, 'The source document must be approved / posted and still open.', 1;
    IF NOT ((@TargetTypeCode = N'PINV' AND @SrcType = N'PO') OR (@TargetTypeCode = N'PRET' AND @SrcType = N'PINV'))
        THROW 65011, 'Purchase orders become purchase invoices; purchase invoices become purchase returns.', 1;

    -- Several drafts may be created from the same document: what is already in another DRAFT of the target type is not
    -- offered again. A selection takes only the given lines / base quantities.
    DECLARE @HasSelection BIT = CASE WHEN EXISTS (SELECT 1 FROM @Selection) THEN 1 ELSE 0 END;
    IF @HasSelection = 1
    BEGIN
        DECLARE @Msg NVARCHAR(400);
        SELECT TOP (1) @Msg = CASE WHEN l.Id IS NULL THEN N'A selected line does not belong to the source document.'
                                   WHEN sel.QuantityBase <= 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': the quantity must be greater than zero.'
                                   ELSE N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' + CAST(sel.QuantityBase AS NVARCHAR(20))
                                        + N' base units selected but only ' + CAST(av.Available AS NVARCHAR(20))
                                        + N' are still available (the rest is in posted or draft documents).' END
        FROM @Selection sel
        LEFT JOIN purchase.PurchaseDocumentLines l ON l.Id = sel.SourceLineId AND l.DocumentId = @SourceId
    OUTER APPLY (SELECT Qty = SUM(x.QuantityBase) FROM purchase.PurchaseDocumentLines x
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
                 INNER JOIN inventory.DocumentTypes xt ON xt.Id = xd.DocumentTypeId
                 WHERE x.SourceLineId = l.Id AND xd.Status = 1 AND xt.Code = @TargetTypeCode) dr
    CROSS APPLY (SELECT Available = CASE WHEN @SrcType = N'PO' THEN l.QuantityBase - l.ReceivedQuantityBase
                                         ELSE l.QuantityBase - l.ReturnedQuantityBase END - ISNULL(dr.Qty, 0)) av
        WHERE l.Id IS NULL OR sel.QuantityBase <= 0 OR sel.QuantityBase > av.Available
        ORDER BY sel.SourceLineId;
        IF @Msg IS NOT NULL THROW 65011, @Msg, 1;
    END

    -- Remaining quantity per line; when it is not a whole number of the line's unit, the new line uses the BASE unit
    -- (price converted per base unit) so nothing is over-received or over-returned.
    DECLARE @Lines purchase.tvp_PurchaseDocumentLine;
    INSERT INTO @Lines (LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, UnitPrice, DiscountPercent, ImportRowNumber, Notes, SourceLineId)
    SELECT ROW_NUMBER() OVER (ORDER BY l.LineNumber), l.ItemId, c.ItemUnitId, l.WarehouseId, l.ExpiryDate,
           c.Quantity, c.UnitPrice, l.DiscountPercent, NULL, l.Notes, l.Id
    FROM purchase.PurchaseDocumentLines l
    OUTER APPLY (SELECT Qty = SUM(x.QuantityBase) FROM purchase.PurchaseDocumentLines x
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
                 INNER JOIN inventory.DocumentTypes xt ON xt.Id = xd.DocumentTypeId
                 WHERE x.SourceLineId = l.Id AND xd.Status = 1 AND xt.Code = @TargetTypeCode) dr
    CROSS APPLY (SELECT Available = CASE WHEN @SrcType = N'PO' THEN l.QuantityBase - l.ReceivedQuantityBase
                                         ELSE l.QuantityBase - l.ReturnedQuantityBase END - ISNULL(dr.Qty, 0)) av
    LEFT JOIN @Selection sel ON sel.SourceLineId = l.Id
    CROSS APPLY (SELECT Remaining = CASE WHEN @HasSelection = 1 THEN ISNULL(sel.QuantityBase, 0) ELSE av.Available END) r
    CROSS APPLY (SELECT ItemUnitId = CASE WHEN r.Remaining % l.PackingFormula = 0 THEN l.ItemUnitId
                                          ELSE (SELECT TOP (1) Id FROM inventory.ItemUnits WHERE ItemId = l.ItemId AND IsBaseUnit = 1) END,
                        Quantity   = CASE WHEN r.Remaining % l.PackingFormula = 0 THEN r.Remaining / l.PackingFormula ELSE r.Remaining END,
                        UnitPrice  = CASE WHEN r.Remaining % l.PackingFormula = 0 THEN l.UnitPrice ELSE ROUND(l.UnitPrice / l.PackingFormula, 4) END) c
    WHERE l.DocumentId = @SourceId AND r.Remaining > 0;

    IF NOT EXISTS (SELECT 1 FROM @Lines) THROW 65011, 'Nothing is left on the source document: everything is already in posted or draft documents.', 1;

    EXEC purchase.usp_PurchaseDocument_Save
         @Id = NULL, @DocumentTypeCode = @TargetTypeCode, @DocumentDate = @DocumentDate, @ExpectedDate = NULL,
         @BranchId = @BranchId, @WarehouseId = @WarehouseId, @SupplierId = @SupplierId, @CurrencyId = @CurrencyId,
         @RateType = @RateType, @ExchangeRate = NULL, @SupplierReference = @SupplierRef, @Notes = NULL,
         @Lines = @Lines, @MaxDiscountPercent = 100, @SourceDocumentId = @SourceId, @RowVersion = NULL, @UserId = @UserId, @NewId = @NewId OUTPUT;
END
GO

/* ================================================================== 6. Approval procedures */

-- Who receives approval requests: active users of a NON-system role holding purchase.orders.approve, with an email.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_Approvers
AS
BEGIN
    SET NOCOUNT ON;
    SELECT DISTINCT u.Id AS UserId, u.FullName, u.Email
    FROM security.Users u
    INNER JOIN security.UserRoles ur      ON ur.UserId = u.Id
    INNER JOIN security.Roles r           ON r.Id = ur.RoleId AND r.IsSystem = 0
    INNER JOIN security.RolePermissions rp ON rp.RoleId = r.Id
    INNER JOIN security.Permissions p     ON p.Id = rp.PermissionId AND p.Code = N'purchase.orders.approve'
    WHERE u.IsActive = 1 AND NULLIF(LTRIM(RTRIM(u.Email)), N'') IS NOT NULL
    ORDER BY u.FullName;
END
GO

-- Draft PO -> Pending approval. Returns one row per approver with the personal token (shown ONCE, only its hash is kept).
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_RequestApproval
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL,
    @ValidHours INT       = 72
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @ValidHours IS NULL OR @ValidHours < 1 SET @ValidHours = 72;

    DECLARE @TypeCode NVARCHAR(20), @Status TINYINT, @SupplierId INT;
    SELECT @TypeCode = dt.Code, @Status = d.Status, @SupplierId = d.SupplierId
    FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    WHERE d.Id = @Id;

    IF @TypeCode IS NULL THROW 65006, 'Document not found.', 1;
    IF @TypeCode <> N'PO' THROW 65010, 'Only purchase orders go through approval.', 1;
    IF @Status <> 1 THROW 65010, 'Only a draft purchase order can be sent for approval.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
    IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id)
        THROW 65009, 'The purchase order has no lines. Add at least one item before sending it for approval.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SupplierId AND IsActive = 1)
        THROW 65008, 'The supplier is inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SupplierId AND NULLIF(LTRIM(RTRIM(Email)), N'') IS NOT NULL)
        THROW 65016, 'The supplier has no email in Parties. Add it first: the approved order is emailed to the supplier.', 1;

    DECLARE @Approvers TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, UserId INT, FullName NVARCHAR(100), Email NVARCHAR(256), Token VARBINARY(32) NULL);
    INSERT INTO @Approvers (UserId, FullName, Email)
    SELECT DISTINCT u.Id, u.FullName, u.Email
    FROM security.Users u
    INNER JOIN security.UserRoles ur      ON ur.UserId = u.Id
    INNER JOIN security.Roles r           ON r.Id = ur.RoleId AND r.IsSystem = 0
    INNER JOIN security.RolePermissions rp ON rp.RoleId = r.Id
    INNER JOIN security.Permissions p     ON p.Id = rp.PermissionId AND p.Code = N'purchase.orders.approve'
    WHERE u.IsActive = 1 AND NULLIF(LTRIM(RTRIM(u.Email)), N'') IS NOT NULL;
    IF NOT EXISTS (SELECT 1 FROM @Approvers)
        THROW 65015, 'Nobody can approve: give the permission "Approve Purchase Orders" to a role (Manager / Owner) whose users have an email.', 1;

    -- One cryptographic token per approver (generated row by row).
    DECLARE @Seq INT = 1, @Max INT = (SELECT MAX(Seq) FROM @Approvers);
    WHILE @Seq <= @Max
    BEGIN
        UPDATE @Approvers SET Token = CRYPT_GEN_RANDOM(32) WHERE Seq = @Seq;
        SET @Seq += 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @RequestNo INT = ISNULL((SELECT MAX(RequestNo) FROM purchase.PurchaseOrderApprovals WHERE DocumentId = @Id), 0) + 1;
        DECLARE @Expires DATETIME2(3) = DATEADD(HOUR, @ValidHours, SYSUTCDATETIME());

        UPDATE purchase.PurchaseOrderApprovals SET Status = 4, DecidedAtUtc = SYSUTCDATETIME()
        WHERE DocumentId = @Id AND Status = 1;

        INSERT INTO purchase.PurchaseOrderApprovals (DocumentId, RequestNo, ApproverUserId, TokenHash, ExpiresAtUtc, RequestedBy)
        SELECT @Id, @RequestNo, a.UserId, HASHBYTES('SHA2_256', a.Token), @Expires, @UserId FROM @Approvers a;

        UPDATE purchase.PurchaseDocuments
        SET Status = 5, ApprovalRequestedAtUtc = SYSUTCDATETIME(), ApprovalRequestedBy = @UserId,
            RejectedAtUtc = NULL, RejectedBy = NULL, RejectReason = NULL,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@Id, N'Updated', N'Sent for approval to ' + CAST((SELECT COUNT(*) FROM @Approvers) AS NVARCHAR(10)) + N' approver(s)', @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT a.UserId, a.FullName, a.Email, Token = CONVERT(VARCHAR(64), a.Token, 2), ExpiresAtUtc = @Expires, RequestNo = @RequestNo
    FROM @Approvers a ORDER BY a.FullName;
END
GO

-- Resolves an emailed token (for the public approval page). Throws 65014 when it cannot be used.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_GetByToken
    @Token VARCHAR(64)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Raw VARBINARY(32) = CASE WHEN LEN(@Token) = 64 THEN TRY_CONVERT(VARBINARY(32), @Token, 2) END;
    IF @Raw IS NULL THROW 65014, 'This approval link is not valid.', 1;

    DECLARE @ApprovalId INT, @DocumentId INT, @Status TINYINT, @Expires DATETIME2(3), @DocStatus TINYINT;
    SELECT @ApprovalId = a.Id, @DocumentId = a.DocumentId, @Status = a.Status, @Expires = a.ExpiresAtUtc, @DocStatus = d.Status
    FROM purchase.PurchaseOrderApprovals a
    INNER JOIN purchase.PurchaseDocuments d ON d.Id = a.DocumentId
    WHERE a.TokenHash = HASHBYTES('SHA2_256', @Raw);

    IF @ApprovalId IS NULL THROW 65014, 'This approval link is not valid.', 1;
    IF @Status <> 1 THROW 65014, 'This approval link was already used, or the order was decided by another approver.', 1;
    IF @Expires < SYSUTCDATETIME() THROW 65014, 'This approval link has expired. Ask for the purchase order to be sent for approval again.', 1;
    IF @DocStatus <> 5 THROW 65014, 'This purchase order is no longer waiting for approval.', 1;

    SELECT a.Id AS ApprovalId, a.DocumentId, a.RequestNo, a.ApproverUserId, u.FullName AS ApproverName, a.ExpiresAtUtc,
           a.RequestedAtUtc, ru.FullName AS RequestedByName
    FROM purchase.PurchaseOrderApprovals a
    INNER JOIN security.Users u ON u.Id = a.ApproverUserId
    LEFT  JOIN security.Users ru ON ru.Id = a.RequestedBy
    WHERE a.Id = @ApprovalId;
END
GO

-- Approve or reject, either with an emailed token (public page) or as a logged-in approver (@Id + @UserId).
-- Approve posts the order (number assigned). Returns the data the API needs for the follow-up emails.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_Decide
    @Token   VARCHAR(64)   = NULL,
    @Id      INT           = NULL,
    @UserId  INT           = NULL,
    @Approve BIT,
    @Note    NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Note = NULLIF(LTRIM(RTRIM(@Note)), N'');
    IF ISNULL(@Approve, 0) = 0 AND @Note IS NULL THROW 65000, 'A reason is required to reject a purchase order.', 1;

    DECLARE @ApprovalId INT = NULL, @DocumentId INT = NULL, @DeciderId INT = NULL, @Channel NVARCHAR(10);

    IF @Token IS NOT NULL
    BEGIN
        DECLARE @Raw VARBINARY(32) = CASE WHEN LEN(@Token) = 64 THEN TRY_CONVERT(VARBINARY(32), @Token, 2) END;
        IF @Raw IS NULL THROW 65014, 'This approval link is not valid.', 1;
        DECLARE @AStatus TINYINT, @Expires DATETIME2(3);
        SELECT @ApprovalId = Id, @DocumentId = DocumentId, @DeciderId = ApproverUserId, @AStatus = Status, @Expires = ExpiresAtUtc
        FROM purchase.PurchaseOrderApprovals WHERE TokenHash = HASHBYTES('SHA2_256', @Raw);
        IF @ApprovalId IS NULL THROW 65014, 'This approval link is not valid.', 1;
        IF @AStatus <> 1 THROW 65014, 'This approval link was already used, or the order was decided by another approver.', 1;
        IF @Expires < SYSUTCDATETIME() THROW 65014, 'This approval link has expired. Ask for the purchase order to be sent for approval again.', 1;
        SET @Channel = N'Email';
    END
    ELSE
    BEGIN
        IF @Id IS NULL OR @UserId IS NULL THROW 65000, 'The purchase order and the user are required.', 1;
        IF NOT EXISTS (SELECT 1 FROM security.UserRoles ur
                       INNER JOIN security.RolePermissions rp ON rp.RoleId = ur.RoleId
                       INNER JOIN security.Permissions p ON p.Id = rp.PermissionId
                       WHERE ur.UserId = @UserId AND p.Code = N'purchase.orders.approve')
           AND NOT EXISTS (SELECT 1 FROM security.UserRoles ur INNER JOIN security.Roles r ON r.Id = ur.RoleId
                           WHERE ur.UserId = @UserId AND r.IsSystem = 1)
            THROW 65017, 'You are not allowed to approve purchase orders.', 1;
        SELECT @DocumentId = @Id, @DeciderId = @UserId, @Channel = N'App';
        SELECT TOP (1) @ApprovalId = Id FROM purchase.PurchaseOrderApprovals
        WHERE DocumentId = @Id AND Status = 1 AND ApproverUserId = @UserId ORDER BY RequestNo DESC;
    END

    DECLARE @DocStatus TINYINT, @TypeCode NVARCHAR(20);
    SELECT @DocStatus = d.Status, @TypeCode = dt.Code
    FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId WHERE d.Id = @DocumentId;
    IF @DocStatus IS NULL THROW 65006, 'Document not found.', 1;
    IF @TypeCode <> N'PO' OR @DocStatus <> 5 THROW 65014, 'This purchase order is no longer waiting for approval.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Approve = 1
        BEGIN
            EXEC purchase.usp_PurchaseDocument_Post @Id = @DocumentId, @RowVersion = NULL, @UserId = @DeciderId, @FromApproval = 1;

            UPDATE purchase.PurchaseDocuments
            SET ApprovedAtUtc = SYSUTCDATETIME(), ApprovedBy = @DeciderId, ApprovalChannel = @Channel
            WHERE Id = @DocumentId;
        END
        ELSE
        BEGIN
            UPDATE purchase.PurchaseDocuments
            SET Status = 1, RejectedAtUtc = SYSUTCDATETIME(), RejectedBy = @DeciderId, RejectReason = @Note,
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @DeciderId
            WHERE Id = @DocumentId;
        END

        -- the decision closes every other open link of the order
        UPDATE purchase.PurchaseOrderApprovals
        SET Status = CASE WHEN Id = @ApprovalId THEN CASE WHEN @Approve = 1 THEN 2 ELSE 3 END ELSE 4 END,
            DecidedAtUtc = SYSUTCDATETIME(),
            DecisionNote = CASE WHEN Id = @ApprovalId THEN @Note ELSE DecisionNote END,
            Channel = CASE WHEN Id = @ApprovalId THEN @Channel ELSE Channel END
        WHERE DocumentId = @DocumentId AND Status = 1;

        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@DocumentId, CASE WHEN @Approve = 1 THEN N'Approved' ELSE N'Rejected' END,
                CASE WHEN @Approve = 1 THEN N'Approved' ELSE N'Rejected' END + N' by '
                + ISNULL((SELECT FullName FROM security.Users WHERE Id = @DeciderId), N'?')
                + CASE WHEN @Channel = N'Email' THEN N' from the email link' ELSE N' in the application' END
                + ISNULL(N': ' + @Note, N''), @DeciderId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    -- For the follow-up emails.
    SELECT d.Id AS DocumentId, d.DocumentNumber,
           Decision = CASE WHEN @Approve = 1 THEN N'Approved' ELSE N'Rejected' END,
           DecidedByName = (SELECT FullName FROM security.Users WHERE Id = @DeciderId), DecisionNote = @Note, Channel = @Channel,
           sp.PartyName AS SupplierName, sp.Email AS SupplierEmail,
           cu.FullName AS CreatorName, cu.Email AS CreatorEmail,
           rq.FullName AS RequestedByName, rq.Email AS RequestedByEmail,
           OwnerEmails = STUFF((SELECT N';' + u.Email
                                FROM security.Users u
                                INNER JOIN security.UserRoles ur ON ur.UserId = u.Id
                                INNER JOIN security.Roles r ON r.Id = ur.RoleId AND r.Name = N'Owner'
                                WHERE u.IsActive = 1 AND NULLIF(LTRIM(RTRIM(u.Email)), N'') IS NOT NULL
                                FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, N'')
    FROM purchase.PurchaseDocuments d
    INNER JOIN masterdata.Parties sp ON sp.Id = d.SupplierId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users rq ON rq.Id = d.ApprovalRequestedBy
    WHERE d.Id = @DocumentId;
END
GO

-- Pending approval -> Draft again (the requester changed their mind); the emailed links stop working.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_Withdraw
    @Id     INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Status TINYINT = (SELECT Status FROM purchase.PurchaseDocuments WHERE Id = @Id);
    IF @Status IS NULL THROW 65006, 'Document not found.', 1;
    IF @Status <> 5 THROW 65010, 'Only a purchase order waiting for approval can be withdrawn.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        UPDATE purchase.PurchaseOrderApprovals SET Status = 4, DecidedAtUtc = SYSUTCDATETIME() WHERE DocumentId = @Id AND Status = 1;
        UPDATE purchase.PurchaseDocuments SET Status = 1, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;
        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@Id, N'Updated', N'Approval request withdrawn', @UserId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 7. Role Owner + permissions */

IF NOT EXISTS (SELECT 1 FROM security.Roles WHERE Name = N'Owner')
    INSERT INTO security.Roles (Name, Description, IsSystem)
    VALUES (N'Owner', N'Business owner: approves purchase orders and receives the copy of every approved order.', 0);
GO

MERGE security.Permissions AS target
USING
(
    VALUES
        (N'purchase.orders.approve', N'Approve Purchase Orders', N'Purchase',      N'Approve or reject purchase orders (approval posts them) and receive the approval requests by email.', 1050),
        (N'messaging.emails.view',   N'View Email Log',          N'Configuration', N'See the emails sent by the application and retry the failed ones.',                               920)
) AS source (Code, Name, Module, Description, SortOrder)
ON target.Code = source.Code
WHEN MATCHED THEN
    UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Module, Description, SortOrder)
    VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder);
GO

-- Posting a purchase order now happens through approval; "post" is the right to SEND it for approval.
UPDATE security.Permissions
SET Name = N'Send Purchase Orders for Approval', Description = N'Send draft purchase orders to the approvers (Manager / Owner).'
WHERE Code = N'purchase.orders.post';
GO

INSERT INTO security.RolePermissions (RoleId, PermissionId)
SELECT r.Id, p.Id
FROM security.Roles r
CROSS JOIN security.Permissions p
WHERE (   (r.IsSystem = 1 AND p.Code IN (N'purchase.orders.approve', N'messaging.emails.view'))
       OR (r.Name = N'Manager' AND p.Code = N'purchase.orders.approve')
       OR (r.Name = N'Owner'   AND p.Code IN (N'purchase.orders.approve', N'purchase.orders.view', N'purchase.invoices.view')))
  AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);
GO

/* ================================================================== 8. Check */

SELECT r.Name AS RoleName, p.Code
FROM security.RolePermissions rp
INNER JOIN security.Roles r ON r.Id = rp.RoleId
INNER JOIN security.Permissions p ON p.Id = rp.PermissionId
WHERE p.Code IN (N'purchase.orders.approve', N'messaging.emails.view')
ORDER BY p.Code, r.Name;
EXEC purchase.usp_PurchaseOrder_Approvers;
PRINT 'Script 26 applied: purchase order approval, invoicing progress, several invoices per order, email outbox.';
GO
