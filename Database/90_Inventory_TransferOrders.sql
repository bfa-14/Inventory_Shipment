SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 90: INVENTORY - TRANSFER ORDERS, DISPATCH AND RECEIPT, WITH APPROVAL (prompt 47)

   Stock moves between the company's own warehouses with a document that follows it on the road, instead of an
   Inventory Out in one warehouse and an Inventory In in the other (which changed the average cost twice and showed
   nothing while the truck was on its way).

     1. A TRANSFER ORDER (TRO) moves stock from one warehouse at the bottom of the tree (From) to another (To), of any
        branch. Stored statuses: 1 Draft, 4 Waiting for approval, 2 Released, 3 Cancelled; a released order is SHOWN
        Released, Partly dispatched, Dispatched, Partly received, Closed or Received from its counters (the pattern of
        script 77). "Nothing more will be sent" is a stamp, never a status.
     2. A DISPATCH (TRD, numbered at posting by the source branch) takes pieces out of From into the hidden "On the way"
        warehouse of the DESTINATION branch; a TRANSFER RECEIPT (TRR, numbered at posting by the destination branch)
        takes them from On the way into To. Each receipt line points at the dispatch line it receives.
     3. COST-NEUTRAL: the company's stock never changes during a transfer, except for pieces written off as lost on the
        way (reason TRF_LOSS, at the average cost). No transfer moves an item's average, last or FOB cost; the cost
        replay reads the incoming transfer legs at the running average.
     4. Partial dispatches and receipts, losses ("Nothing more will arrive" with a reason), "Nothing more will be sent",
        Cancel order (nothing dispatched), Reverse of one whole posting in place (a receipt before its dispatch),
        Dispatch and receive in one transaction, and a Return = a new order in the other direction, linked both ways.
     5. APPROVAL: the switch "Needs approval before release" on the TRO type (default OFF). Send for approval /
        Approve / Reject / Withdraw / Approve & release; the approvers are the active users holding Approve Transfer
        Orders, emailed by the API through the existing outbox (outside the system role first).
     6. LATE: released and still to dispatch after its Expected arrival, or a dispatch with pieces on the way after its
        ETA (UTC today).
     7. Every refusal of an action, and the reason of every disabled button, comes from inventory.fn_TransferOrder_Blocks
        (and fn_TransferPosting_ReverseBlock for a posting), as logistics.fn_Movement_CancelBlock (script 83).
     8. Ten permissions inventory.transfers.* (855-890), each granted once from the matching Inventory In / Out right.
     9. Around it: Stock Valuation offers the On the way warehouses, the item statement shows "TRD-... LKS-01 -> LUB-01",
        Shortages count "Transfers in", the goods receipt and Inventory In cancel refusals name the transfer that moved
        the goods.
    10. Nothing that works today changes behaviour: every new refusal concerns an On the way warehouse, a transfer
        document or a transfer document type.

   THE ON THE WAY WAREHOUSES (masterdata.Warehouses.IsTransit = 1): one per branch, created here for every branch and
   by usp_Branch_Create for a new one, healed at every start for a branch made any other way. A system bucket: never a
   parent, never a main warehouse, never deactivated, never a line's warehouse (fn_Warehouse_IsLeaf says 0 for it, so
   every other family refuses it with the leaf sentence), never an item's default; only its name and address change;
   deleted with its branch when nothing references it. The default warehouse lookup leaves them out (@IncludeTransit).

   Objects
     New tables        inventory.TransferOrders, TransferOrderLines, TransferPostings, TransferPostingLines,
                       TransferOrderAudit, TransferOrderFiles
     New columns       masterdata.Warehouses.IsTransit (+ CK_Warehouses_Transit, UX_Warehouses_TransitBranch);
                       inventory.DocumentTypes.NeedsApproval; inventory.ShortageDocumentLines.TransfersInBase (its four
                       formula columns re-added with it)
     New types         inventory.tvp_TransferOrderLine, tvp_TransferDispatchLine, tvp_TransferReceiptLine (frozen)
     New data, once    document types TRO, TRD, TRR (TRO "Used for" = Inventory Out's); stock reason TRF_LOSS
                       (inactive); one On the way warehouse per branch; ten permissions and their once-grants
     New functions     inventory.fn_TransferPosition, fn_Transfer_MovedOutNote, fn_TransferOrder_WarehouseProblem,
                       fn_TransferOrder_State, fn_TransferOrder_Blocks, fn_TransferPosting_ReverseBlock
     New procedures    masterdata.usp_Warehouse_EnsureTransit, usp_Warehouse_IsReferenced;
                       inventory.usp_TransferOrder_CheckWarehouses, _Search, _Get, _Availability, _Save,
                       _UpdateDetails, _Delete, _Release, _Approvers, _SendForApproval, _Approve, _Reject, _Withdraw,
                       _BackToDraft, _DispatchCore, _Dispatch, _ReceiveCore, _Receive, _DispatchAndReceive,
                       _NothingMoreSent, _Cancel, _CreateReturn, _WaitingCount, _File_Add / _List / _Get / _Update /
                       _Delete; inventory.usp_TransferPosting_Reverse, _SetEta
     Re-created        masterdata.fn_Warehouse_IsLeaf                 from the body of script 70: On the way is never a leaf
                       masterdata.fn_Warehouse_IsUsed                 from the body of script 72: + transfer orders
                       masterdata.fn_AttachmentDocumentKinds          from the body of script 67: + TRO
                       masterdata.usp_AttachmentType_Delete           from the body of script 67: + transfer order files
                       masterdata.usp_Warehouse_Delete                from the body of script 28: On the way refused, the scan
                                                                      moved to usp_Warehouse_IsReferenced
                       masterdata.usp_Warehouse_Lookup                from the body of script 71: + @IncludeTransit, IsTransit
                       masterdata.usp_Warehouse_Search, _Get          from the body of script 40: + IsTransit
                       masterdata.usp_Warehouse_Create, _Update       from the body of script 71: the On the way rules
                       masterdata.usp_Warehouse_SetActive             from the body of script 07: On the way stays active
                       masterdata.usp_Branch_Create, _Delete          from the body of script 06: its On the way warehouse
                       inventory.usp_Item_Create, _Update             from the body of script 11: no On the way default
                       inventory.usp_DocumentType_List, _Update       from the body of script 79: + NeedsApproval; TRD / TRR
                                                                      numbered at posting
                       inventory.usp_Item_RebuildCosts                from the body of script 79: transfer legs at the average
                       inventory.usp_Item_StockStatement              from the body of script 65: the transfer counterpart
                       inventory.fn_Shortage_Live                     from the body of script 85: + TransfersInBase
                       inventory.usp_Shortage_Calculate, usp_ShortageDocument_WriteLines  from the body of script 25,
                       inventory.usp_ShortageDocument_Get             from the body of script 77: + Transfers in
                       purchase.fn_GoodsReceipt_CancelCheck           from the body of script 64: the transfer note on 63007
                       inventory.usp_StockDocument_Cancel             from the body of script 89: the transfer note on 62007
     Edited in place   script 19's per-start backfill of item costs (Database/19_Core_DocumentEngine.sql and its copy in
                       Schema.sql, as 89 edited the same batch): it no longer counts transfer rows as receipts - it runs at
                       every start, before any later script, so an item replayed to a zero average got a transfer's frozen
                       cost back as its average and last cost at the next start

   Errors (block 62xxx, shared with the stock documents): new 62012 above To dispatch / above On the way, 62013 a later
   posting must be reversed first, 62014 release needs approval, 62015 not an approver; new 52009 an On the way
   warehouse is system-managed. Reused: 62000, 62004-62011, 52000, 52003, 52005-52007, 56008, 63007.

   Not changed: Inventory In / Out / BIVAC Out (their save, post, numbering; their cancel but the 62007 sentence's
   suffix), sales, purchase orders / invoices / returns, goods receipts (but the 63007 sentence's suffix), containers,
   movements, charges, landed cost adjustments, payments, receipts, the Dashboard procedures; every warehouse picker's
   default rows; every existing document type's settings, stock reason, attachment "Used for" row and role grant.

   Requires scripts 64, 66, 67, 71, 79, 85 and 89 (Schema.sql runs them first). Idempotent, additive: re-applied at every
   API start-up, and builds a brand-new empty database (every table and column before the objects that read it).
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'inventory.OneTimeSteps', N'U') IS NULL                                  -- 89
   OR COL_LENGTH(N'inventory.DocumentTypes', N'AffectsItemCost') IS NULL               -- 79
   OR COL_LENGTH(N'inventory.DocumentTypes', N'BivacItemsOnly') IS NULL                -- 66
   OR OBJECT_ID(N'purchase.GoodsReceiptFiles', N'U') IS NULL                           -- 64
   OR COL_LENGTH(N'inventory.ItemFiles', N'AttachmentTypeId') IS NULL                  -- 67
   OR OBJECT_ID(N'masterdata.fn_Warehouse_IsUsed', N'FN') IS NULL                      -- 71
   OR OBJECT_ID(N'inventory.fn_Shortage_Live', N'IF') IS NULL                          -- 85
    THROW 62000, 'Script 90 requires scripts 64, 66, 67, 71, 79, 85 and 89: apply them first.', 1;
GO

/* ================================================================== 2. The On the way warehouses: the column */

-- (90) 1 = THE BRANCH'S "ON THE WAY" WAREHOUSE: the goods a transfer dispatched to one of the branch's warehouses and
--      not received yet sit there, in the ledger. Every existing warehouse gets 0.
IF COL_LENGTH(N'masterdata.Warehouses', N'IsTransit') IS NULL
BEGIN
    ALTER TABLE masterdata.Warehouses ADD IsTransit BIT NOT NULL CONSTRAINT DF_Warehouses_IsTransit DEFAULT (0);
    PRINT 'Warehouses: added IsTransit';
END
GO

-- A system bucket: never a main warehouse, never under another warehouse, always active. (Its own batch: the column
-- above must exist when the constraint is compiled.)
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_Warehouses_Transit'
                                                     AND parent_object_id = OBJECT_ID(N'masterdata.Warehouses'))
BEGIN
    ALTER TABLE masterdata.Warehouses ADD CONSTRAINT CK_Warehouses_Transit
        CHECK (IsTransit = 0 OR (IsMainWarehouse = 0 AND ParentId IS NULL AND IsActive = 1));
    PRINT 'Warehouses: added CK_Warehouses_Transit';
END
GO

-- ONE ON THE WAY WAREHOUSE PER BRANCH. (UX_Warehouses_ActiveMainWarehouse, script 07, already makes every warehouse
-- writer run with QUOTED_IDENTIFIER ON, which a filtered index needs.)
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_Warehouses_TransitBranch' AND object_id = OBJECT_ID(N'masterdata.Warehouses'))
BEGIN
    CREATE UNIQUE NONCLUSTERED INDEX UX_Warehouses_TransitBranch ON masterdata.Warehouses (BranchId) WHERE IsTransit = 1;
    PRINT 'Warehouses: added UX_Warehouses_TransitBranch';
END
GO

/* ================================================================== 3. One On the way warehouse per branch */

-- (90) THE BRANCH'S ON THE WAY WAREHOUSE, created when it is missing: the dispatch to one of the branch's warehouses
--      puts its goods there. Its code is the first free of OTW-{branch code}, OTW-B{branch id}, OTW-B{id}-2, -3, ...
--      (a warehouse may already carry the first). Inserted directly, not through usp_Warehouse_Create, which refuses an
--      inactive branch: a branch closed since may still receive what was sent to it before. No transaction of its own:
--      its callers (a branch's creation, a dispatch, the start-up loop below) hold one; the branch's transit row is read
--      WITH (UPDLOCK, HOLDLOCK), so two callers never create two.
CREATE OR ALTER PROCEDURE masterdata.usp_Warehouse_EnsureTransit
    @BranchId    INT,
    @UserId      INT = NULL,
    @WarehouseId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @WarehouseId = NULL;
    SELECT @WarehouseId = w.Id
    FROM masterdata.Warehouses w WITH (UPDLOCK, HOLDLOCK)
    WHERE w.BranchId = @BranchId AND w.IsTransit = 1;
    IF @WarehouseId IS NOT NULL RETURN;

    DECLARE @BranchCode NVARCHAR(20) = (SELECT BranchCode FROM masterdata.Branches WHERE Id = @BranchId);
    IF @BranchCode IS NULL THROW 52007, 'Branch / Site not found.', 1;

    DECLARE @Code NVARCHAR(20) = UPPER(N'OTW-' + LEFT(@BranchCode, 16));
    IF EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE WarehouseCode = @Code)
        SET @Code = N'OTW-B' + CAST(@BranchId AS NVARCHAR(10));
    DECLARE @n INT = 2;
    WHILE EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE WarehouseCode = @Code)
    BEGIN
        SET @Code = N'OTW-B' + CAST(@BranchId AS NVARCHAR(10)) + N'-' + CAST(@n AS NVARCHAR(3));
        SET @n += 1;
    END

    INSERT INTO masterdata.Warehouses (WarehouseCode, WarehouseName, BranchId, Address, IsMainWarehouse, IsActive,
                                       ParentId, [Level], IsTransit, AllowOutOfStockOverride, CreatedBy)
    VALUES (@Code, N'On the way to ' + LEFT(@BranchCode, 100) + N' (transfers)', @BranchId, NULL, 0, 1,
            NULL, 1, 1, NULL, @UserId);

    SET @WarehouseId = SCOPE_IDENTITY();
END
GO

-- EVERY BRANCH HAS ITS ON THE WAY WAREHOUSE, at every start: an empty database gets the seeded branch's, an existing
-- one every branch's, and a branch made outside usp_Branch_Create (a restore, a hand insert) heals at the next start.
-- One transaction: all or none.
SET XACT_ABORT ON;
BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @TransitBranchId INT, @TransitId INT, @TransitCreated INT = 0;
    WHILE 1 = 1
    BEGIN
        SET @TransitBranchId = (SELECT TOP (1) b.Id FROM masterdata.Branches b
                                WHERE NOT EXISTS (SELECT 1 FROM masterdata.Warehouses w WHERE w.BranchId = b.Id AND w.IsTransit = 1)
                                ORDER BY b.Id);
        IF @TransitBranchId IS NULL BREAK;

        SET @TransitId = NULL;
        EXEC masterdata.usp_Warehouse_EnsureTransit @BranchId = @TransitBranchId, @UserId = NULL, @WarehouseId = @TransitId OUTPUT;
        SET @TransitCreated += 1;
    END

    COMMIT TRANSACTION;

    IF @TransitCreated > 0
        PRINT 'On the way warehouses created: ' + CAST(@TransitCreated AS NVARCHAR(10));
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
SET XACT_ABORT OFF;
GO

/* ================================================================== 4. The approval switch on the document types */

-- (90) "Needs approval before release": read on the transfer order type (TRO) only; 0 on every other type.
IF COL_LENGTH(N'inventory.DocumentTypes', N'NeedsApproval') IS NULL
BEGIN
    ALTER TABLE inventory.DocumentTypes ADD
        NeedsApproval BIT NOT NULL CONSTRAINT DF_DocumentTypes_NeedsApproval DEFAULT (0);   -- TRO: release waits for an approver
    PRINT 'DocumentTypes: added NeedsApproval';
END
GO

/* ================================================================== 5. Document types TRO, TRD, TRR */

-- INSERTED ONCE, NEVER OVERWRITTEN: whatever an administrator changes later on Configuration > Document Types stays.
-- Numbered per branch: the order at its first save by the source branch (TRO-BR-003-000012), a dispatch at posting by
-- the source branch (TRD-), a receipt at posting by the destination branch (TRR-). The number length and the year
-- segment are Inventory Out's. StockDirection 0 on all three: a type has one direction, and a dispatch writes two legs
-- (out of From, into On the way), a receipt two (out of On the way, into To). No pricing: a transfer has no cost.
-- THE FIRST INSERT OF TRO ONLY copies Inventory Out's "Used for" rows to the kind TRO, so the transfer order's upload
-- dialog offers what Inventory Out's offers. Never again: a kind an administrator takes off a type stays off.
SET XACT_ABORT ON;
BEGIN TRY
    BEGIN TRANSACTION;   -- the rows and the "Used for" rows together, or neither

    DECLARE @TransferTypes TABLE (Code NVARCHAR(20) NOT NULL);

    MERGE inventory.DocumentTypes AS t
    USING (SELECT v.Code, v.Name, Family = N'Inventory', StockDirection = CAST(0 AS SMALLINT), v.NumberPrefix,
                  NumberOnPost = CAST(v.NumberOnPost AS BIT), RequiresReason = CAST(0 AS BIT),
                  DefaultPricing = N'None', PriceEditable = CAST(0 AS BIT), NumberPerBranch = CAST(1 AS BIT),
                  YearInNumber = ISNULL((SELECT YearInNumber FROM inventory.DocumentTypes WHERE Code = N'INV_OUT'), CAST(0 AS BIT)),
                  NumberLength = ISNULL((SELECT NumberLength FROM inventory.DocumentTypes WHERE Code = N'INV_OUT'), CAST(6 AS TINYINT)),
                  IsActive = CAST(1 AS BIT), NeedsApproval = CAST(0 AS BIT)
           FROM (VALUES (N'TRO', N'Transfer Order',    N'TRO-', 0),
                        (N'TRD', N'Transfer Dispatch', N'TRD-', 1),
                        (N'TRR', N'Transfer Receipt',  N'TRR-', 1)) v (Code, Name, NumberPrefix, NumberOnPost)) AS s
    ON t.Code = s.Code
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (Code, Name, Family, StockDirection, NumberPrefix, NumberOnPost, RequiresReason,
                DefaultPricing, PriceEditable, NumberPerBranch, YearInNumber, NumberLength, IsActive, NeedsApproval)
        VALUES (s.Code, s.Name, s.Family, s.StockDirection, s.NumberPrefix, s.NumberOnPost, s.RequiresReason,
                s.DefaultPricing, s.PriceEditable, s.NumberPerBranch, s.YearInNumber, s.NumberLength, s.IsActive, s.NeedsApproval)
    OUTPUT inserted.Code INTO @TransferTypes (Code);

    DECLARE @TransferTypesCreated NVARCHAR(100) = (SELECT STRING_AGG(Code, N', ') WITHIN GROUP (ORDER BY Code) FROM @TransferTypes);
    IF @TransferTypesCreated IS NOT NULL
        PRINT 'Document types created: ' + @TransferTypesCreated;

    IF EXISTS (SELECT 1 FROM @TransferTypes WHERE Code = N'TRO')
    BEGIN
        INSERT INTO masterdata.AttachmentTypeUsages (AttachmentTypeId, DocumentKind)
        SELECT u.AttachmentTypeId, N'TRO'
        FROM masterdata.AttachmentTypeUsages u
        WHERE u.DocumentKind = N'INV_OUT'
          AND NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypeUsages x WHERE x.AttachmentTypeId = u.AttachmentTypeId AND x.DocumentKind = N'TRO');
        DECLARE @TroCopied INT = @@ROWCOUNT;

        PRINT 'Document type TRO (Transfer Order) uses the attachment types of Inventory Out ('
              + CAST(@TroCopied AS NVARCHAR(10)) + ' type(s)).';
    END

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
SET XACT_ABORT OFF;
GO

/* ================================================================== 6. Stock reason TRF_LOSS */

-- (90) THE WRITE-OFF OF PIECES THAT WILL NOT ARRIVE ("Nothing more will arrive" on a transfer receipt): the only leg of a
--      transfer that changes the company's stock, out of On the way at the average cost. INACTIVE, once: the reason
--      lookup lists active reasons only, so Inventory Out never offers it; the transfer rows still show its name.
--      TRF_IN / TRF_OUT (script 15) are unchanged and still offered.
MERGE inventory.StockReasons AS t
USING (VALUES (N'TRF_LOSS', N'Lost on the way (transfer)', N'Out')) AS s (ReasonCode, ReasonName, AppliesTo)
ON t.ReasonCode = s.ReasonCode
WHEN NOT MATCHED BY TARGET THEN
    INSERT (ReasonCode, ReasonName, AppliesTo, IsActive) VALUES (s.ReasonCode, s.ReasonName, s.AppliesTo, 0);
GO

/* ================================================================== 7. The transfer tables */

-- THE ORDER. Its warehouses are the document's (every line leaves From and goes to To), unlike the other documents,
-- whose warehouse is a line's. BranchId follows From while a draft; the number keeps the branch it got at the first save.
IF OBJECT_ID(N'inventory.TransferOrders', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.TransferOrders
    (
        Id                    INT IDENTITY(1,1) NOT NULL,
        DocumentTypeId        INT            NOT NULL,     -- TRO
        DocumentNumber        NVARCHAR(30)   NULL,         -- at the first save (TRO NumberOnPost 0) or at release (1)
        DocumentDate          DATE           NOT NULL,     -- the order date
        BranchId              INT            NOT NULL,     -- From's branch, kept up to date while a draft
        FromWarehouseId       INT            NOT NULL,
        ToWarehouseId         INT            NOT NULL,
        ExpectedArrival       DATE           NULL,
        ReferenceNo           NVARCHAR(100)  NULL,
        Notes                 NVARCHAR(1000) NULL,
        Status                TINYINT        NOT NULL CONSTRAINT DF_TransferOrders_Status DEFAULT (1),   -- 1 Draft, 2 Released, 3 Cancelled, 4 Waiting for approval
        ReturnOfOrderId       INT            NULL,         -- a return: the order it sends back
        TotalLines            INT            NOT NULL CONSTRAINT DF_TransferOrders_TotalLines DEFAULT (0),
        TotalOrderedBase      INT            NOT NULL CONSTRAINT DF_TransferOrders_TotalOrdered DEFAULT (0),
        ApprovalRequestedAtUtc DATETIME2(3)  NULL,         -- the last Send for approval
        ApprovalRequestedBy   INT            NULL,
        ApprovedAtUtc         DATETIME2(3)   NULL,         -- NULL when released without approval
        ApprovedBy            INT            NULL,
        ApprovedDirectly      BIT            NOT NULL CONSTRAINT DF_TransferOrders_ApprovedDirectly DEFAULT (0),   -- Approve & release of a draft
        RejectedAtUtc         DATETIME2(3)   NULL,         -- cleared by Send for approval, Release, Approve
        RejectedBy            INT            NULL,
        RejectReason          NVARCHAR(300)  NULL,
        ReleasedAtUtc         DATETIME2(3)   NULL,
        ReleasedBy            INT            NULL,
        NotSentAtUtc          DATETIME2(3)   NULL,         -- the "Nothing more will be sent" stamp
        NotSentBy             INT            NULL,
        NotSentReason         NVARCHAR(300)  NULL,
        CancelledAtUtc        DATETIME2(3)   NULL,
        CancelledBy           INT            NULL,
        CancelReason          NVARCHAR(300)  NULL,
        CreatedAtUtc          DATETIME2(3)   NOT NULL CONSTRAINT DF_TransferOrders_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy             INT            NULL,
        UpdatedAtUtc          DATETIME2(3)   NULL,
        UpdatedBy             INT            NULL,
        RowVersion            ROWVERSION     NOT NULL,
        CONSTRAINT PK_TransferOrders PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_TransferOrders_Status CHECK (Status IN (1, 2, 3, 4)),
        CONSTRAINT CK_TransferOrders_Warehouses CHECK (FromWarehouseId <> ToWarehouseId),
        CONSTRAINT CK_TransferOrders_Released CHECK (Status NOT IN (2, 3) OR DocumentNumber IS NOT NULL),
        CONSTRAINT CK_TransferOrders_Cancelled CHECK (Status <> 3 OR CancelledAtUtc IS NOT NULL),
        CONSTRAINT CK_TransferOrders_NotSent CHECK (NotSentAtUtc IS NULL OR Status IN (2, 3)),
        CONSTRAINT CK_TransferOrders_Return CHECK (ReturnOfOrderId IS NULL OR ReturnOfOrderId <> Id),
        CONSTRAINT FK_TransferOrders_Type          FOREIGN KEY (DocumentTypeId)      REFERENCES inventory.DocumentTypes (Id),
        CONSTRAINT FK_TransferOrders_Branch        FOREIGN KEY (BranchId)            REFERENCES masterdata.Branches (Id),
        CONSTRAINT FK_TransferOrders_From          FOREIGN KEY (FromWarehouseId)     REFERENCES masterdata.Warehouses (Id),
        CONSTRAINT FK_TransferOrders_To            FOREIGN KEY (ToWarehouseId)       REFERENCES masterdata.Warehouses (Id),
        CONSTRAINT FK_TransferOrders_ReturnOf      FOREIGN KEY (ReturnOfOrderId)     REFERENCES inventory.TransferOrders (Id),
        CONSTRAINT FK_TransferOrders_RequestedBy   FOREIGN KEY (ApprovalRequestedBy) REFERENCES security.Users (Id),
        CONSTRAINT FK_TransferOrders_ApprovedBy    FOREIGN KEY (ApprovedBy)          REFERENCES security.Users (Id),
        CONSTRAINT FK_TransferOrders_RejectedBy    FOREIGN KEY (RejectedBy)          REFERENCES security.Users (Id),
        CONSTRAINT FK_TransferOrders_ReleasedBy    FOREIGN KEY (ReleasedBy)          REFERENCES security.Users (Id),
        CONSTRAINT FK_TransferOrders_NotSentBy     FOREIGN KEY (NotSentBy)           REFERENCES security.Users (Id),
        CONSTRAINT FK_TransferOrders_CancelledBy   FOREIGN KEY (CancelledBy)         REFERENCES security.Users (Id),
        CONSTRAINT FK_TransferOrders_CreatedBy     FOREIGN KEY (CreatedBy)           REFERENCES security.Users (Id),
        CONSTRAINT FK_TransferOrders_UpdatedBy     FOREIGN KEY (UpdatedBy)           REFERENCES security.Users (Id)
    );
    CREATE UNIQUE NONCLUSTERED INDEX UX_TransferOrders_Number ON inventory.TransferOrders (DocumentNumber) WHERE DocumentNumber IS NOT NULL;
    CREATE NONCLUSTERED INDEX IX_TransferOrders_StatusDate ON inventory.TransferOrders (Status, DocumentDate DESC);
    CREATE NONCLUSTERED INDEX IX_TransferOrders_From       ON inventory.TransferOrders (FromWarehouseId, Status);
    CREATE NONCLUSTERED INDEX IX_TransferOrders_To         ON inventory.TransferOrders (ToWarehouseId, Status);
    CREATE NONCLUSTERED INDEX IX_TransferOrders_ReturnOf   ON inventory.TransferOrders (ReturnOfOrderId) WHERE ReturnOfOrderId IS NOT NULL;
    PRINT 'Created inventory.TransferOrders';
END
GO

-- THE ORDER LINES. Ordered in the line's unit (and in pcs, OrderedBase); every counter in pcs, counting only POSTED,
-- not reversed postings: maintained by the posting procedures alone, in the posting's transaction, under the order's
-- lock (the Check section compares them with the posting lines). The same item may be on two lines in two units.
IF OBJECT_ID(N'inventory.TransferOrderLines', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.TransferOrderLines
    (
        Id              INT IDENTITY(1,1) NOT NULL,
        TransferOrderId INT           NOT NULL,
        LineNumber      INT           NOT NULL,
        ItemId          INT           NOT NULL,
        ItemUnitId      INT           NOT NULL,
        Quantity        INT           NOT NULL,     -- Ordered, in the unit
        PackingFormula  INT           NOT NULL,     -- the unit's, when the line was saved
        OrderedBase     AS (Quantity * PackingFormula) PERSISTED,   -- pcs
        Notes           NVARCHAR(300) NULL,
        DispatchedBase  INT           NOT NULL CONSTRAINT DF_TransferOrderLines_Dispatched DEFAULT (0),
        ReceivedBase    INT           NOT NULL CONSTRAINT DF_TransferOrderLines_Received DEFAULT (0),
        LostBase        INT           NOT NULL CONSTRAINT DF_TransferOrderLines_Lost DEFAULT (0),
        NotSentBase     INT           NOT NULL CONSTRAINT DF_TransferOrderLines_NotSent DEFAULT (0),    -- "Nothing more will be sent"
        CONSTRAINT PK_TransferOrderLines PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_TransferOrderLines_LineNo UNIQUE (TransferOrderId, LineNumber),
        CONSTRAINT CK_TransferOrderLines_Qty CHECK (Quantity > 0),
        CONSTRAINT CK_TransferOrderLines_Formula CHECK (PackingFormula >= 1),
        CONSTRAINT CK_TransferOrderLines_Counters CHECK (DispatchedBase >= 0 AND ReceivedBase >= 0 AND LostBase >= 0 AND NotSentBase >= 0
                                                         AND ReceivedBase + LostBase <= DispatchedBase
                                                         AND DispatchedBase + NotSentBase <= Quantity * PackingFormula),
        CONSTRAINT FK_TransferOrderLines_Order FOREIGN KEY (TransferOrderId) REFERENCES inventory.TransferOrders (Id),
        CONSTRAINT FK_TransferOrderLines_Item  FOREIGN KEY (ItemId)          REFERENCES inventory.Items (Id),
        CONSTRAINT FK_TransferOrderLines_Unit  FOREIGN KEY (ItemUnitId)      REFERENCES inventory.ItemUnits (Id)
    );
    CREATE NONCLUSTERED INDEX IX_TransferOrderLines_Order ON inventory.TransferOrderLines (TransferOrderId)
        INCLUDE (ItemId, DispatchedBase, ReceivedBase, LostBase, NotSentBase);
    CREATE NONCLUSTERED INDEX IX_TransferOrderLines_Item ON inventory.TransferOrderLines (ItemId);
    PRINT 'Created inventory.TransferOrderLines';
END
GO

-- ONE ROW PER DISPATCH (TRD) OR TRANSFER RECEIPT (TRR): its Id is the ledger's DocumentId (family Transfer). Posted
-- directly (no draft posting); reversed in place, whole (Status 3, the reversal rows under its own number).
IF OBJECT_ID(N'inventory.TransferPostings', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.TransferPostings
    (
        Id                 INT IDENTITY(1,1) NOT NULL,
        TransferOrderId    INT            NOT NULL,
        DocumentTypeId     INT            NOT NULL,     -- TRD or TRR
        Kind               NVARCHAR(10)   NOT NULL,     -- Dispatch | Receipt
        DocumentNumber     NVARCHAR(30)   NOT NULL,     -- given at posting
        PostingDate        DATE           NOT NULL,
        Eta                DATE           NULL,         -- dispatches only, required
        BranchId           INT            NOT NULL,     -- numbering branch: From's (TRD), To's (TRR)
        FromWarehouseId    INT            NOT NULL,     -- the order's, as a snapshot
        ToWarehouseId      INT            NOT NULL,
        TransitWarehouseId INT            NULL,         -- dispatches: the destination branch's On the way warehouse
        ReferenceNo        NVARCHAR(100)  NULL,         -- waybill / truck (TRD), delivery note (TRR)
        Notes              NVARCHAR(1000) NULL,
        PostedWithId       INT            NULL,         -- the receipt of a "Dispatch and receive": its dispatch
        Status             TINYINT        NOT NULL CONSTRAINT DF_TransferPostings_Status DEFAULT (2),   -- 2 Posted, 3 Reversed
        TotalQuantityBase  INT            NOT NULL CONSTRAINT DF_TransferPostings_Quantity DEFAULT (0),
        TotalLostBase      INT            NOT NULL CONSTRAINT DF_TransferPostings_Lost DEFAULT (0),
        ValueBase          DECIMAL(18,2)  NOT NULL CONSTRAINT DF_TransferPostings_Value DEFAULT (0),       -- dispatch: sent x frozen cost; receipt: received x the dispatch's cost
        LostValueBase      DECIMAL(18,2)  NOT NULL CONSTRAINT DF_TransferPostings_LostValue DEFAULT (0),   -- lost x average at receipt
        PostedAtUtc        DATETIME2(3)   NOT NULL CONSTRAINT DF_TransferPostings_PostedAtUtc DEFAULT (SYSUTCDATETIME()),
        PostedBy           INT            NULL,
        ReversedAtUtc      DATETIME2(3)   NULL,
        ReversedBy         INT            NULL,
        ReverseDate        DATE           NULL,
        ReverseReason      NVARCHAR(300)  NULL,
        CONSTRAINT PK_TransferPostings PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_TransferPostings_Kind CHECK (Kind IN (N'Dispatch', N'Receipt')),
        CONSTRAINT CK_TransferPostings_Status CHECK (Status IN (2, 3)),
        CONSTRAINT CK_TransferPostings_Eta CHECK ((Kind = N'Dispatch' AND Eta IS NOT NULL AND Eta >= PostingDate)
                                                  OR (Kind = N'Receipt' AND Eta IS NULL)),
        CONSTRAINT CK_TransferPostings_Transit CHECK ((Kind = N'Dispatch' AND TransitWarehouseId IS NOT NULL) OR Kind = N'Receipt'),
        CONSTRAINT CK_TransferPostings_Reversed CHECK (Status = 2 OR (ReversedAtUtc IS NOT NULL AND ReverseDate IS NOT NULL AND ReverseReason IS NOT NULL)),
        CONSTRAINT FK_TransferPostings_Order      FOREIGN KEY (TransferOrderId)    REFERENCES inventory.TransferOrders (Id),
        CONSTRAINT FK_TransferPostings_Type       FOREIGN KEY (DocumentTypeId)     REFERENCES inventory.DocumentTypes (Id),
        CONSTRAINT FK_TransferPostings_Branch     FOREIGN KEY (BranchId)           REFERENCES masterdata.Branches (Id),
        CONSTRAINT FK_TransferPostings_From       FOREIGN KEY (FromWarehouseId)    REFERENCES masterdata.Warehouses (Id),
        CONSTRAINT FK_TransferPostings_To         FOREIGN KEY (ToWarehouseId)      REFERENCES masterdata.Warehouses (Id),
        CONSTRAINT FK_TransferPostings_Transit    FOREIGN KEY (TransitWarehouseId) REFERENCES masterdata.Warehouses (Id),
        CONSTRAINT FK_TransferPostings_PostedWith FOREIGN KEY (PostedWithId)       REFERENCES inventory.TransferPostings (Id),
        CONSTRAINT FK_TransferPostings_PostedBy   FOREIGN KEY (PostedBy)           REFERENCES security.Users (Id),
        CONSTRAINT FK_TransferPostings_ReversedBy FOREIGN KEY (ReversedBy)         REFERENCES security.Users (Id)
    );
    CREATE UNIQUE NONCLUSTERED INDEX UX_TransferPostings_Number ON inventory.TransferPostings (DocumentNumber);
    CREATE NONCLUSTERED INDEX IX_TransferPostings_Order ON inventory.TransferPostings (TransferOrderId, Kind, Status)
        INCLUDE (Eta, PostingDate, DocumentNumber);
    CREATE NONCLUSTERED INDEX IX_TransferPostings_PostedWith ON inventory.TransferPostings (PostedWithId) WHERE PostedWithId IS NOT NULL;
    PRINT 'Created inventory.TransferPostings';
END
GO

-- THE LINES OF A DISPATCH OR A RECEIPT: the ledger's DocumentLineId. A dispatch line takes its order line's number and
-- keeps the cost frozen at dispatch (information: no transfer moves a cost); a receipt line (1..n) points at the
-- dispatch line it receives. On the way of a dispatch line = QuantityBase - SettledBase while its posting is Posted,
-- 0 once it is Reversed.
IF OBJECT_ID(N'inventory.TransferPostingLines', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.TransferPostingLines
    (
        Id                  INT IDENTITY(1,1) NOT NULL,
        PostingId           INT            NOT NULL,
        LineNumber          INT            NOT NULL,
        TransferOrderLineId INT            NOT NULL,
        ItemId              INT            NOT NULL,
        DispatchLineId      INT            NULL,         -- receipt lines: the dispatch line received
        TransitWarehouseId  INT            NOT NULL,
        QuantityBase        INT            NOT NULL,     -- dispatch: sent (> 0); receipt: received (>= 0)
        LostBase            INT            NOT NULL CONSTRAINT DF_TransferPostingLines_Lost DEFAULT (0),      -- receipt lines
        LossReasonCode      NVARCHAR(20)   NULL,         -- DAMAGED | MISSING | DISPATCHCOUNT | OTHER
        LossNote            NVARCHAR(300)  NULL,
        SettledBase         INT            NOT NULL CONSTRAINT DF_TransferPostingLines_Settled DEFAULT (0),   -- dispatch lines: received + lost by posted receipts
        UnitCostBase        DECIMAL(18,6)  NULL,         -- dispatch: Items.AverageCost at dispatch; receipt: its dispatch line's
        LossUnitCostBase    DECIMAL(18,6)  NULL,         -- Items.AverageCost at receipt, lines with a loss
        CONSTRAINT PK_TransferPostingLines PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_TransferPostingLines_LineNo UNIQUE (PostingId, LineNumber),
        CONSTRAINT CK_TransferPostingLines_Qty CHECK (QuantityBase >= 0 AND (DispatchLineId IS NOT NULL OR QuantityBase > 0)),
        CONSTRAINT CK_TransferPostingLines_Lost CHECK (LostBase >= 0 AND (DispatchLineId IS NOT NULL OR LostBase = 0)
                                                       AND (LostBase = 0 OR LossReasonCode IS NOT NULL)),
        CONSTRAINT CK_TransferPostingLines_Something CHECK (DispatchLineId IS NULL OR QuantityBase + LostBase > 0),
        CONSTRAINT CK_TransferPostingLines_Reason CHECK (LossReasonCode IS NULL
                                                         OR LossReasonCode IN (N'DAMAGED', N'MISSING', N'DISPATCHCOUNT', N'OTHER')),
        CONSTRAINT CK_TransferPostingLines_Settled CHECK (SettledBase >= 0 AND SettledBase <= QuantityBase
                                                          AND (DispatchLineId IS NULL OR SettledBase = 0)),
        CONSTRAINT FK_TransferPostingLines_Posting   FOREIGN KEY (PostingId)           REFERENCES inventory.TransferPostings (Id),
        CONSTRAINT FK_TransferPostingLines_OrderLine FOREIGN KEY (TransferOrderLineId) REFERENCES inventory.TransferOrderLines (Id),
        CONSTRAINT FK_TransferPostingLines_Item      FOREIGN KEY (ItemId)              REFERENCES inventory.Items (Id),
        CONSTRAINT FK_TransferPostingLines_Dispatch  FOREIGN KEY (DispatchLineId)      REFERENCES inventory.TransferPostingLines (Id),
        CONSTRAINT FK_TransferPostingLines_Transit   FOREIGN KEY (TransitWarehouseId)  REFERENCES masterdata.Warehouses (Id)
    );
    CREATE NONCLUSTERED INDEX IX_TransferPostingLines_Posting   ON inventory.TransferPostingLines (PostingId);
    CREATE NONCLUSTERED INDEX IX_TransferPostingLines_Dispatch  ON inventory.TransferPostingLines (DispatchLineId) WHERE DispatchLineId IS NOT NULL;
    CREATE NONCLUSTERED INDEX IX_TransferPostingLines_OrderLine ON inventory.TransferPostingLines (TransferOrderLineId);
    PRINT 'Created inventory.TransferPostingLines';
END
GO

-- The common audit shape. No foreign key on the order, as purchase.GoodsReceiptAudit: deleting a draft deletes its
-- audit rows itself. PostingId names the dispatch or receipt an entry is about.
IF OBJECT_ID(N'inventory.TransferOrderAudit', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.TransferOrderAudit
    (
        Id              BIGINT IDENTITY(1,1) NOT NULL,
        TransferOrderId INT           NOT NULL,
        PostingId       INT           NULL,
        Action          NVARCHAR(30)  NOT NULL,   -- Created | Updated | DetailsUpdated | Released | SentForApproval | Approved |
                                                  -- ApprovedAndReleased | Rejected | Withdrawn | BackToDraft | Dispatched | Received |
                                                  -- DispatchedAndReceived | EtaChanged | Reversed | NothingMoreSent | Cancelled |
                                                  -- ReturnCreated | ReturnOf | FileAdded | FileUpdated | FileDeleted
        Details         NVARCHAR(500) NULL,
        UserId          INT           NULL,
        AtUtc           DATETIME2(3)  NOT NULL CONSTRAINT DF_TransferOrderAudit_AtUtc DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_TransferOrderAudit PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_TransferOrderAudit_User FOREIGN KEY (UserId) REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_TransferOrderAudit_Order ON inventory.TransferOrderAudit (TransferOrderId, AtUtc);
    PRINT 'Created inventory.TransferOrderAudit';
END
GO

-- The shape of purchase.GoodsReceiptFiles (script 64): a type (used for TRO), a document date, a note.
IF OBJECT_ID(N'inventory.TransferOrderFiles', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.TransferOrderFiles
    (
        Id               INT IDENTITY(1,1) NOT NULL,
        TransferOrderId  INT            NOT NULL,
        AttachmentTypeId INT            NOT NULL,
        DocumentDate     DATE           NULL,
        Note             NVARCHAR(500)  NULL,
        FileName         NVARCHAR(255)  NOT NULL,
        ContentType      NVARCHAR(100)  NOT NULL,
        SizeBytes        INT            NOT NULL,
        Content          VARBINARY(MAX) NOT NULL,
        CreatedAtUtc     DATETIME2(3)   NOT NULL CONSTRAINT DF_TransferOrderFiles_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy        INT            NULL,
        CONSTRAINT PK_TransferOrderFiles PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_TransferOrderFiles_Size CHECK (SizeBytes > 0),
        CONSTRAINT FK_TransferOrderFiles_Order     FOREIGN KEY (TransferOrderId)  REFERENCES inventory.TransferOrders (Id),
        CONSTRAINT FK_TransferOrderFiles_Type      FOREIGN KEY (AttachmentTypeId) REFERENCES masterdata.AttachmentTypes (Id),
        CONSTRAINT FK_TransferOrderFiles_CreatedBy FOREIGN KEY (CreatedBy)        REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_TransferOrderFiles_Order ON inventory.TransferOrderFiles (TransferOrderId);
    PRINT 'Created inventory.TransferOrderFiles';
END
GO

/* ================================================================== 8. The table types (FROZEN) */

-- FROZEN: a later change takes a new type, never alters these (a type in use by a procedure cannot be altered, and
-- Schema.sql would stop at the next start). Lists of item ids reuse logistics.tvp_IdList (script 27).
IF NOT EXISTS (SELECT 1 FROM sys.table_types WHERE name = N'tvp_TransferOrderLine' AND schema_id = SCHEMA_ID(N'inventory'))
BEGIN
    CREATE TYPE inventory.tvp_TransferOrderLine AS TABLE
    ( LineNumber INT NOT NULL PRIMARY KEY, ItemId INT NOT NULL, ItemUnitId INT NOT NULL, Quantity INT NOT NULL, Notes NVARCHAR(300) NULL );
    PRINT 'Created type inventory.tvp_TransferOrderLine';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.table_types WHERE name = N'tvp_TransferDispatchLine' AND schema_id = SCHEMA_ID(N'inventory'))
BEGIN
    CREATE TYPE inventory.tvp_TransferDispatchLine AS TABLE
    ( TransferOrderLineId INT NOT NULL PRIMARY KEY, QuantityBase INT NOT NULL );
    PRINT 'Created type inventory.tvp_TransferDispatchLine';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.table_types WHERE name = N'tvp_TransferReceiptLine' AND schema_id = SCHEMA_ID(N'inventory'))
BEGIN
    CREATE TYPE inventory.tvp_TransferReceiptLine AS TABLE
    ( DispatchLineId INT NOT NULL PRIMARY KEY, ReceivedBase INT NOT NULL, NothingMoreWillArrive BIT NOT NULL,
      LossReasonCode NVARCHAR(20) NULL, LossNote NVARCHAR(300) NULL );
    PRINT 'Created type inventory.tvp_TransferReceiptLine';
END
GO

/* ================================================================== 9. Leaf, used, attachment kinds: the On the way warehouse and the transfer orders */

-- Re-created (90) from the body of script 70: + an On the way warehouse is never a leaf. FB rule 32's safety net: every
-- family that takes a warehouse on a line (stock documents, sales, purchase, goods receipts, the imports, a container's
-- draft receipt) refuses it at save and at posting with the leaf sentence. No screen offers one, so only a typed code in
-- an import file or a crafted call reaches it; transfers name it themselves and never ask.
CREATE OR ALTER FUNCTION masterdata.fn_Warehouse_IsLeaf (@WarehouseId INT)
RETURNS BIT
AS
BEGIN
    RETURN CASE WHEN EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE ParentId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsTransit = 1) THEN 0 ELSE 1 END;   -- (90)
END
GO

-- Re-created (90) from the body of script 72: + a transfer order names it (From or To, a draft too). Its postings are
-- not tested: every posting writes ledger rows in From and in the On the way warehouse, which the ledger test already
-- covers, and To is named on the order.
CREATE OR ALTER FUNCTION masterdata.fn_Warehouse_IsUsed (@WarehouseId INT)
RETURNS BIT
AS
BEGIN
    RETURN CASE WHEN EXISTS (SELECT 1 FROM inventory.StockMovements          WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM inventory.StockDocumentLines      WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM inventory.StockDocuments          WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM sales.SalesDocumentLines          WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM sales.SalesDocuments              WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines    WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM purchase.PurchaseDocuments        WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM logistics.Containers              WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM inventory.CostAdjustments         WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM purchase.LandedCostAdjustmentLines WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM sales.OutOfStockSaleAudit         WHERE WarehouseId = @WarehouseId)
                  -- (72) a goods receipt names it: "Receive into" (a draft too) or a line's warehouse
                  OR EXISTS (SELECT 1 FROM purchase.GoodsReceipts            WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM purchase.GoodsReceiptLines        WHERE WarehouseId = @WarehouseId)
                  -- (90) a transfer order names it, as the source or the destination (a draft too)
                  OR EXISTS (SELECT 1 FROM inventory.TransferOrders          WHERE FromWarehouseId = @WarehouseId OR ToWarehouseId = @WarehouseId)
                THEN 1 ELSE 0 END;
END
GO

-- Re-created (90) from the body of script 67: + TRO (transfer orders' documents), after BIVAC Out.
CREATE OR ALTER FUNCTION masterdata.fn_AttachmentDocumentKinds ()
RETURNS TABLE
AS
RETURN
SELECT k.Code, k.Name, k.Noun, k.SortOrder
FROM (VALUES (N'CONTAINER', N'Containers',        N'containers',              10),
             (N'PO',        N'Purchase orders',   N'purchase orders',         20),
             (N'PINV',      N'Purchase invoices', N'purchase invoices',       30),
             (N'PRET',      N'Purchase returns',  N'purchase returns',        40),
             (N'GRN',       N'Goods receipts',    N'goods receipts',          45),   -- (64)
             (N'SO',        N'Sales orders',      N'sales orders',            50),
             (N'SINV',      N'Sales invoices',    N'sales invoices',          60),
             (N'SRET',      N'Sales returns',     N'sales returns',           70),
             (N'RCPT',      N'Customer receipts', N'customer receipts',       80),
             (N'PAY',       N'Supplier payments', N'supplier payments',       85),
             (N'INV_IN',    N'Inventory In',      N'Inventory In documents',  90),
             (N'INV_OUT',   N'Inventory Out',     N'Inventory Out documents', 100),
             (N'BIV_OUT',   N'BIVAC Out',         N'BIVAC Out documents',     105),   -- (66)
             (N'TRO',       N'Transfer orders',   N'transfer orders',         107),   -- (90)
             (N'ITEM',      N'Items',             N'items',                   120)) k (Code, Name, Noun, SortOrder);   -- (67)
GO

-- Re-created (90) from the body of script 67: + the transfer order files.
CREATE OR ALTER PROCEDURE masterdata.usp_AttachmentType_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Id = @Id) THROW 69006, 'Attachment type not found.', 1;
    IF EXISTS (SELECT 1 FROM logistics.ContainerAttachments WHERE AttachmentTypeId = @Id)
       OR EXISTS (SELECT 1 FROM logistics.ContainerFiles WHERE AttachmentTypeId = @Id)
       OR EXISTS (SELECT 1 FROM sales.ReceiptFiles WHERE AttachmentTypeId = @Id)
       OR EXISTS (SELECT 1 FROM sales.SalesDocumentFiles WHERE AttachmentTypeId = @Id)
       OR EXISTS (SELECT 1 FROM purchase.PurchaseDocumentFiles WHERE AttachmentTypeId = @Id)
       OR EXISTS (SELECT 1 FROM purchase.PaymentFiles WHERE AttachmentTypeId = @Id)
       OR EXISTS (SELECT 1 FROM purchase.GoodsReceiptFiles WHERE AttachmentTypeId = @Id)   -- (64)
       OR EXISTS (SELECT 1 FROM inventory.StockDocumentFiles WHERE AttachmentTypeId = @Id)
       OR EXISTS (SELECT 1 FROM inventory.ItemFiles WHERE AttachmentTypeId = @Id)          -- (67)
       OR EXISTS (SELECT 1 FROM inventory.TransferOrderFiles WHERE AttachmentTypeId = @Id) -- (90)
        THROW 69014, 'This attachment type is used by documents and cannot be deleted. Deactivate it instead.', 1;
    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE FROM masterdata.AttachmentTypeUsages WHERE AttachmentTypeId = @Id;
        DELETE FROM masterdata.AttachmentTypes WHERE Id = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 10. The transfer functions */

-- (90) THE ONE DEFINITION OF WHERE A WAREHOUSE STANDS WITH TRANSFERS (its lines' "Available at {From}" and "Stock at
--      {To}" on the order page, the availability call, Release's warnings, and the stock levels of script 91).
--      OnHandBase equals inventory.fn_StockOnHand(item, warehouse); the ledger's (ItemId, WarehouseId, MovementDate)
--      index, IX_TransferOrderLines_Item and IX_TransferOrders_To / _From serve it.
CREATE OR ALTER FUNCTION inventory.fn_TransferPosition (@ItemId INT, @WarehouseId INT, @ExcludeOrderId INT)
RETURNS TABLE
AS
RETURN
(
    -- (90) A WAREHOUSE'S POSITION WITH TRANSFERS: on hand, and what RELEASED transfer orders (Status 2) still bring to it
    --      (on the way, still to dispatch) or still take from it (to dispatch). Drafts and orders waiting for approval
    --      promise nothing; a cancelled order has nothing dispatched; a closed order has nothing left to dispatch.
    --      @ExcludeOrderId leaves one order out (the one being looked at).
    SELECT OnHandBase        = ISNULL(oh.Qty, 0),
           InOnTheWayBase    = ISNULL(ti.OnTheWay, 0),
           InToDispatchBase  = ISNULL(ti.ToDispatch, 0),
           OutToDispatchBase = ISNULL(tx.ToDispatch, 0),
           ProjectedBase     = ISNULL(oh.Qty, 0) + ISNULL(ti.OnTheWay, 0) + ISNULL(ti.ToDispatch, 0) - ISNULL(tx.ToDispatch, 0)
    FROM (SELECT Qty = SUM(m.QuantityBase) FROM inventory.StockMovements m
          WHERE m.ItemId = @ItemId AND m.WarehouseId = @WarehouseId) oh
    CROSS JOIN (SELECT OnTheWay   = SUM(l.DispatchedBase - l.ReceivedBase - l.LostBase),
                       ToDispatch = SUM(CASE WHEN o.NotSentAtUtc IS NULL AND l.OrderedBase - l.DispatchedBase - l.NotSentBase > 0
                                             THEN l.OrderedBase - l.DispatchedBase - l.NotSentBase ELSE 0 END)
                FROM inventory.TransferOrderLines l
                INNER JOIN inventory.TransferOrders o ON o.Id = l.TransferOrderId
                WHERE l.ItemId = @ItemId AND o.ToWarehouseId = @WarehouseId AND o.Status = 2
                  AND (@ExcludeOrderId IS NULL OR o.Id <> @ExcludeOrderId)) ti
    CROSS JOIN (SELECT ToDispatch = SUM(CASE WHEN o.NotSentAtUtc IS NULL AND l.OrderedBase - l.DispatchedBase - l.NotSentBase > 0
                                             THEN l.OrderedBase - l.DispatchedBase - l.NotSentBase ELSE 0 END)
                FROM inventory.TransferOrderLines l
                INNER JOIN inventory.TransferOrders o ON o.Id = l.TransferOrderId
                WHERE l.ItemId = @ItemId AND o.FromWarehouseId = @WarehouseId AND o.Status = 2
                  AND (@ExcludeOrderId IS NULL OR o.Id <> @ExcludeOrderId)) tx
);
GO

-- (90) WHICH TRANSFER MOVED THE GOODS AWAY (FB rule 39): the end of the refusal of a goods receipt cancel (63007) and an
--      Inventory In cancel (62007) when the stock that document brought is short in its warehouse. NULL when no posted,
--      not reversed dispatch took the item out of that warehouse (posted at or after @SinceUtc when given: the
--      document's own posting). Otherwise the pieces those dispatches took (@Pcs) and up to two of their numbers,
--      latest first: when they cover the shortfall (what the document brought less what is left), " 80 pcs were moved
--      by TRD-BR-003-000004: transfer them back first."; when they do not (transferring back would not be enough),
--      " (10 of them were moved by TRD-BR-003-000004.)". Read only on a refusal: no index of its own.
CREATE OR ALTER FUNCTION inventory.fn_Transfer_MovedOutNote (@ItemId INT, @WarehouseId INT, @SinceUtc DATETIME2(3), @ShortfallBase INT)
RETURNS NVARCHAR(300)
AS
BEGIN
    DECLARE @Pcs INT, @Count INT, @List NVARCHAR(200);

    SELECT @Pcs = SUM(d.Pcs), @Count = COUNT(*)
    FROM (SELECT p.Id, Pcs = SUM(pl.QuantityBase)
          FROM inventory.TransferPostings p
          INNER JOIN inventory.TransferPostingLines pl ON pl.PostingId = p.Id
          WHERE p.Kind = N'Dispatch' AND p.Status = 2 AND p.FromWarehouseId = @WarehouseId AND pl.ItemId = @ItemId
            AND (@SinceUtc IS NULL OR p.PostedAtUtc >= @SinceUtc)
          GROUP BY p.Id) d;

    IF ISNULL(@Count, 0) = 0 OR ISNULL(@Pcs, 0) <= 0 RETURN NULL;

    SELECT @List = STRING_AGG(t.DocumentNumber, N', ') WITHIN GROUP (ORDER BY t.PostedAtUtc DESC, t.Id DESC)
    FROM (SELECT TOP (2) p.Id, p.DocumentNumber, p.PostedAtUtc
          FROM inventory.TransferPostings p
          WHERE p.Kind = N'Dispatch' AND p.Status = 2 AND p.FromWarehouseId = @WarehouseId
            AND (@SinceUtc IS NULL OR p.PostedAtUtc >= @SinceUtc)
            AND EXISTS (SELECT 1 FROM inventory.TransferPostingLines pl WHERE pl.PostingId = p.Id AND pl.ItemId = @ItemId)
          ORDER BY p.PostedAtUtc DESC, p.Id DESC) t;

    SET @List = ISNULL(@List, N'a transfer')
              + CASE WHEN @Count > 2 THEN N' and ' + CAST(@Count - 2 AS NVARCHAR(10)) + N' more' ELSE N'' END;

    RETURN CASE WHEN @Pcs >= ISNULL(@ShortfallBase, 0)
                THEN N' ' + CAST(@Pcs AS NVARCHAR(20)) + N' pcs were moved by ' + @List + N': transfer them back first.'
                ELSE N' (' + CAST(@Pcs AS NVARCHAR(20)) + N' of them were moved by ' + @List + N'.)' END;
END
GO

-- (90) THE WAREHOUSES OF A TRANSFER ORDER: the only place of these rules (Save, Release, Send for approval, Approve and
--      Dispatch read them; the Receive's To-only half lives in fn_TransferOrder_Blocks, Seq 92). One row, the first
--      failing of: 1. From / To missing; 2. From = To; 3. an On the way warehouse; 4. a warehouse not found or inactive;
--      5. a warehouse with warehouses under it (the sentence of script 70). From before To within each rule. None =
--      both are fit. A transfer may join any two branches: no branch rule.
CREATE OR ALTER FUNCTION inventory.fn_TransferOrder_WarehouseProblem (@FromId INT, @ToId INT)
RETURNS TABLE
AS
RETURN
SELECT TOP (1) Message = CAST(p.Message AS NVARCHAR(400))
FROM
(
    SELECT Seq = 1, Message = CASE WHEN @FromId IS NULL THEN N'Choose the warehouse the goods leave from.' END
    UNION ALL
    SELECT 2, CASE WHEN @ToId IS NULL THEN N'Choose the warehouse the goods go to.' END
    UNION ALL
    SELECT 3, CASE WHEN @FromId = @ToId THEN N'The destination must differ from the source.' END
    UNION ALL
    -- rules 3-5, per side (1 From, 2 To): Seq 11 / 12, 21 / 22, 31 / 32
    SELECT 10 * k.Step + s.Side,
           CASE k.Step
                WHEN 1 THEN CASE WHEN w.IsTransit = 1
                                 THEN w.WarehouseCode + N' is an On the way warehouse: it holds goods travelling between warehouses and cannot be chosen.' END
                WHEN 2 THEN CASE WHEN w.Id IS NULL THEN N'The warehouse was not found.'
                                 WHEN w.IsActive = 0 THEN N'Warehouse ' + w.WarehouseCode + N' is inactive.' END
                WHEN 3 THEN CASE WHEN EXISTS (SELECT 1 FROM masterdata.Warehouses c WHERE c.ParentId = w.Id)
                                 THEN N'Warehouse ' + w.WarehouseCode + N' has warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree.' END
           END
    FROM (VALUES (1, @FromId), (2, @ToId)) s (Side, WarehouseId)
    CROSS JOIN (VALUES (1), (2), (3)) k (Step)
    LEFT JOIN masterdata.Warehouses w ON w.Id = s.WarehouseId
    WHERE s.WarehouseId IS NOT NULL
) p
WHERE p.Message IS NOT NULL
ORDER BY p.Seq;
GO

-- (90) The warehouse rules as a refusal (62000), for the procedures: the function's first row, thrown as it comes.
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_CheckWarehouses
    @FromId INT,
    @ToId   INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @m NVARCHAR(400);
    SELECT TOP (1) @m = Message FROM inventory.fn_TransferOrder_WarehouseProblem(@FromId, @ToId);
    IF @m IS NOT NULL THROW 62000, @m, 1;
END
GO

-- (90) WHERE A TRANSFER ORDER STANDS, in one row: its counters in pcs (from the order lines, which count posted, not
--      reversed postings only), the status it is SHOWN with, and Late. Shown for a released order, the first that
--      applies: Released (nothing dispatched or closed yet), Partly dispatched (something still to dispatch, not
--      closed), Dispatched (goods on the way, nothing arrived yet), Partly received (goods on the way, some arrived or
--      written off), Closed ("Nothing more will be sent", everything sent has arrived), Received. LATE (UTC today, the
--      movements' rule): a released order still to dispatch after its Expected arrival and not closed, or a posted
--      dispatch with pieces on the way after its ETA. No row for an order that does not exist.
CREATE OR ALTER FUNCTION inventory.fn_TransferOrder_State (@Id INT)
RETURNS TABLE
AS
RETURN
SELECT t.OrderedBase, t.DispatchedBase, t.ReceivedBase, t.LostBase, t.NotSentBase, t.ToDispatchBase,
       OnTheWayBase   = t.DispatchedBase - t.ReceivedBase - t.LostBase,
       t.ItemCount,
       LateDispatches = ld.N,
       IsLate         = CAST(CASE WHEN o.Status = 2
                                   AND ((t.ToDispatchBase > 0 AND o.NotSentAtUtc IS NULL AND o.ExpectedArrival < d.Today) OR ld.N > 0)
                                  THEN 1 ELSE 0 END AS BIT),
       DisplayStatus  = CAST(CASE o.Status WHEN 1 THEN N'Draft' WHEN 4 THEN N'PendingApproval' WHEN 3 THEN N'Cancelled' ELSE
                                 CASE WHEN t.DispatchedBase = 0 AND t.NotSentBase = 0                         THEN N'Released'
                                      WHEN t.ToDispatchBase > 0 AND o.NotSentAtUtc IS NULL                    THEN N'PartlyDispatched'
                                      WHEN t.DispatchedBase - t.ReceivedBase - t.LostBase > 0
                                           AND t.ReceivedBase = 0 AND t.LostBase = 0                          THEN N'Dispatched'
                                      WHEN t.DispatchedBase - t.ReceivedBase - t.LostBase > 0                 THEN N'PartlyReceived'
                                      WHEN t.NotSentBase > 0                                                  THEN N'Closed'
                                      ELSE N'Received' END END AS NVARCHAR(20))
FROM inventory.TransferOrders o
CROSS JOIN (SELECT Today = CAST(SYSUTCDATETIME() AS DATE)) d
CROSS APPLY (SELECT OrderedBase    = ISNULL(SUM(l.OrderedBase), 0),
                    DispatchedBase = ISNULL(SUM(l.DispatchedBase), 0),
                    ReceivedBase   = ISNULL(SUM(l.ReceivedBase), 0),
                    LostBase       = ISNULL(SUM(l.LostBase), 0),
                    NotSentBase    = ISNULL(SUM(l.NotSentBase), 0),
                    ToDispatchBase = ISNULL(SUM(CASE WHEN l.OrderedBase - l.DispatchedBase - l.NotSentBase > 0
                                                     THEN l.OrderedBase - l.DispatchedBase - l.NotSentBase ELSE 0 END), 0),
                    ItemCount      = COUNT(DISTINCT l.ItemId)
             FROM inventory.TransferOrderLines l
             WHERE l.TransferOrderId = o.Id) t
CROSS APPLY (SELECT N = COUNT(*)
             FROM inventory.TransferPostings p
             WHERE p.TransferOrderId = o.Id AND p.Kind = N'Dispatch' AND p.Status = 2 AND p.Eta < d.Today
               AND EXISTS (SELECT 1 FROM inventory.TransferPostingLines pl WHERE pl.PostingId = p.Id AND pl.QuantityBase > pl.SettledBase)) ld
WHERE o.Id = @Id;
GO

/* (90) WHY AN ACTION ON A TRANSFER ORDER CANNOT BE DONE NOW: one row per failed rule (Action, Seq, ErrorNumber,
   Message); the first row of an action (lowest Seq) is its reason, none = allowed. Every procedure of the order throws
   exactly that row (SELECT TOP (1) ... ORDER BY Seq, then THROW @Number, @Message), and usp_TransferOrder_Get gives it
   as the action's BlockedReason, so the page and the refusal always say the same thing (logistics.fn_Movement_CancelBlock,
   script 83). Permissions are not here - the API hides what a reader may not use - but the approval right, which is
   the decision's own rule. ChangeEta, ReverseDispatch and ReverseReceipt have only the "not found" row here: their
   rules are the posting's (usp_TransferPosting_SetEta, fn_TransferPosting_ReverseBlock); they are listed so that a
   later script (92, warehouse access) adds its rows here alone. Actions: Edit, Delete, Release, SendForApproval,
   Approve, Reject, Withdraw, BackToDraft, Dispatch, Receive, DispatchAndReceive, NothingMoreSent, Cancel,
   CreateReturn, UpdateDetails, ChangeEta, ReverseDispatch, ReverseReceipt. The order's one row is worked out once
   (the CTE), then unpivoted: a list names up to 3 numbers, oldest first, then " and {n} more". */
CREATE OR ALTER FUNCTION inventory.fn_TransferOrder_Blocks (@Id INT, @UserId INT)
RETURNS TABLE
AS
RETURN
WITH o AS
(
    SELECT tro.Id, tro.Status,
           No             = ISNULL(tro.DocumentNumber, N'this transfer order'),
           s.DispatchedBase, s.ReceivedBase, s.ToDispatchBase, s.OnTheWayBase,
           NotSentOnBy    = CASE WHEN tro.NotSentAtUtc IS NOT NULL
                                 THEN N'on ' + CONVERT(NVARCHAR(10), CAST(tro.NotSentAtUtc AS DATE), 103) + N' by ' + ISNULL(nu.FullName, N'an unknown user') END,
           NeedsApproval  = ISNULL(tt.NeedsApproval, 0),
           ap.CanApprove,
           PostingCount   = pc.N,
           TroOff         = CASE WHEN ISNULL(tt.IsActive, 0) = 0
                                 THEN N'Transfer orders are switched off: the document type TRO is inactive (Configuration ' + NCHAR(8250) + N' Document Types).' END,
           TrdOff         = CASE WHEN ISNULL(td.IsActive, 0) = 0
                                 THEN N'Transfer dispatches are switched off: the document type TRD is inactive (Configuration ' + NCHAR(8250) + N' Document Types).' END,
           TrrOff         = CASE WHEN ISNULL(tr.IsActive, 0) = 0
                                 THEN N'Transfer receipts are switched off: the document type TRR is inactive (Configuration ' + NCHAR(8250) + N' Document Types).' END,
           NoApproval     = N'Transfer orders need no approval (Configuration ' + NCHAR(8250) + N' Document Types): release it.',
           NotApprover    = CASE WHEN ap.CanApprove = 0
                                 THEN N'You may not approve transfer orders: it takes the permission Approve Transfer Orders.' END,
           NoLines        = CASE WHEN NOT EXISTS (SELECT 1 FROM inventory.TransferOrderLines l WHERE l.TransferOrderId = tro.Id)
                                 THEN N'The order has no lines. Add at least one item before releasing it.' END,
           InactiveLine   = CASE WHEN ia.LineNumber IS NOT NULL
                                 THEN N'Line ' + CAST(ia.LineNumber AS NVARCHAR(10)) + N': item ' + ia.ItemCode + N' is inactive.' END,
           WarehouseProblem = wp.Message,
           -- Dispatch: the order's warehouse rules, the To-inactive case in its own words (the goods could not be received)
           DispatchWarehouseProblem = CASE WHEN tw.IsActive = 0 AND wp.Message = N'Warehouse ' + tw.WarehouseCode + N' is inactive.'
                                           THEN N'The destination ' + tw.WarehouseCode + N' is inactive: goods sent to it could not be received. Activate it, or cancel the order.'
                                           ELSE wp.Message END,
           -- Receive: rules 3-5 of fn_TransferOrder_WarehouseProblem for To alone (From no longer matters once the
           -- goods have left it), the inactive case in its own words
           ReceiveWarehouseProblem = CASE WHEN tw.Id IS NULL THEN N'The warehouse was not found.'
                                          WHEN tw.IsTransit = 1
                                               THEN tw.WarehouseCode + N' is an On the way warehouse: it holds goods travelling between warehouses and cannot be chosen.'
                                          WHEN tw.IsActive = 0
                                               THEN N'The destination ' + tw.WarehouseCode + N' is inactive: activate it to receive these goods.'
                                          WHEN EXISTS (SELECT 1 FROM masterdata.Warehouses c WHERE c.ParentId = tw.Id)
                                               THEN N'Warehouse ' + tw.WarehouseCode + N' has warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree.' END,
           -- Seq 86: every line still to dispatch has nothing on hand at From
           NoStockAtFrom  = CASE WHEN EXISTS (SELECT 1 FROM inventory.TransferOrderLines l
                                              WHERE l.TransferOrderId = tro.Id AND l.OrderedBase - l.DispatchedBase - l.NotSentBase > 0)
                                  AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrderLines l
                                                  WHERE l.TransferOrderId = tro.Id AND l.OrderedBase - l.DispatchedBase - l.NotSentBase > 0
                                                    AND (SELECT SUM(m.QuantityBase) FROM inventory.StockMovements m
                                                         WHERE m.ItemId = l.ItemId AND m.WarehouseId = tro.FromWarehouseId) > 0)
                                 THEN fw.WarehouseCode + N' has none of the items still to dispatch.' END,
           -- every dispatch, reversed or not (Back to draft); the posted, not reversed ones (Cancel); the returns not cancelled
           DispatchList   = ISNULL(da.List, N'') + CASE WHEN da.N > 3 THEN N' and ' + CAST(da.N - 3 AS NVARCHAR(10)) + N' more' ELSE N'' END,
           PostedDispatchList = ISNULL(dp.List, N'') + CASE WHEN dp.N > 3 THEN N' and ' + CAST(dp.N - 3 AS NVARCHAR(10)) + N' more' ELSE N'' END,
           ReturnList     = ISNULL(rt.List, N'') + CASE WHEN rt.N > 3 THEN N' and ' + CAST(rt.N - 3 AS NVARCHAR(10)) + N' more' ELSE N'' END,
           -- an item whose received pieces are not all on the returns not cancelled (usp_TransferOrder_CreateReturn's
           -- ReturnableBase > 0)
           HasReturnable  = CASE WHEN EXISTS (SELECT 1
                                              FROM (SELECT l.ItemId, Received = SUM(l.ReceivedBase)
                                                    FROM inventory.TransferOrderLines l
                                                    WHERE l.TransferOrderId = tro.Id
                                                    GROUP BY l.ItemId) r
                                              WHERE r.Received - ISNULL((SELECT SUM(rl.OrderedBase)
                                                                         FROM inventory.TransferOrderLines rl
                                                                         INNER JOIN inventory.TransferOrders ro ON ro.Id = rl.TransferOrderId
                                                                         WHERE ro.ReturnOfOrderId = tro.Id AND ro.Status <> 3 AND rl.ItemId = r.ItemId), 0) > 0)
                                 THEN 1 ELSE 0 END
    FROM inventory.TransferOrders tro
    CROSS APPLY inventory.fn_TransferOrder_State(tro.Id) s
    -- the approval right is the decision's own rule (business-context 4.3 rule 3): the only permission read here
    CROSS APPLY (SELECT CanApprove = security.fn_UserHasPermission(@UserId, N'inventory.transfers.approve')) ap
    LEFT JOIN security.Users nu          ON nu.Id = tro.NotSentBy
    LEFT JOIN masterdata.Warehouses fw   ON fw.Id = tro.FromWarehouseId
    LEFT JOIN masterdata.Warehouses tw   ON tw.Id = tro.ToWarehouseId
    LEFT JOIN inventory.DocumentTypes tt ON tt.Code = N'TRO'
    LEFT JOIN inventory.DocumentTypes td ON td.Code = N'TRD'
    LEFT JOIN inventory.DocumentTypes tr ON tr.Code = N'TRR'
    OUTER APPLY (SELECT TOP (1) Message FROM inventory.fn_TransferOrder_WarehouseProblem(tro.FromWarehouseId, tro.ToWarehouseId)) wp
    OUTER APPLY (SELECT TOP (1) l.LineNumber, i.ItemCode
                 FROM inventory.TransferOrderLines l
                 INNER JOIN inventory.Items i ON i.Id = l.ItemId
                 WHERE l.TransferOrderId = tro.Id AND i.IsActive = 0
                 ORDER BY l.LineNumber) ia
    CROSS APPLY (SELECT N = COUNT(*) FROM inventory.TransferPostings p WHERE p.TransferOrderId = tro.Id) pc
    CROSS APPLY (SELECT N = (SELECT COUNT(*) FROM inventory.TransferPostings p WHERE p.TransferOrderId = tro.Id AND p.Kind = N'Dispatch'),
                        List = (SELECT STRING_AGG(x.DocumentNumber, N', ') WITHIN GROUP (ORDER BY x.PostedAtUtc, x.Id)
                                FROM (SELECT TOP (3) p.Id, p.DocumentNumber, p.PostedAtUtc FROM inventory.TransferPostings p
                                      WHERE p.TransferOrderId = tro.Id AND p.Kind = N'Dispatch'
                                      ORDER BY p.PostedAtUtc, p.Id) x)) da
    CROSS APPLY (SELECT N = (SELECT COUNT(*) FROM inventory.TransferPostings p WHERE p.TransferOrderId = tro.Id AND p.Kind = N'Dispatch' AND p.Status = 2),
                        List = (SELECT STRING_AGG(x.DocumentNumber, N', ') WITHIN GROUP (ORDER BY x.PostedAtUtc, x.Id)
                                FROM (SELECT TOP (3) p.Id, p.DocumentNumber, p.PostedAtUtc FROM inventory.TransferPostings p
                                      WHERE p.TransferOrderId = tro.Id AND p.Kind = N'Dispatch' AND p.Status = 2
                                      ORDER BY p.PostedAtUtc, p.Id) x)) dp
    CROSS APPLY (SELECT N = (SELECT COUNT(*) FROM inventory.TransferOrders r WHERE r.ReturnOfOrderId = tro.Id AND r.Status <> 3),
                        List = (SELECT STRING_AGG(x.Number, N', ') WITHIN GROUP (ORDER BY x.Id)
                                FROM (SELECT TOP (3) r.Id, Number = ISNULL(r.DocumentNumber, N'a draft') FROM inventory.TransferOrders r
                                      WHERE r.ReturnOfOrderId = tro.Id AND r.Status <> 3
                                      ORDER BY r.Id) x)) rt
    WHERE tro.Id = @Id
)
SELECT Action = CAST(b.Action AS NVARCHAR(30)), Seq = CAST(b.Seq AS INT), ErrorNumber = CAST(b.ErrorNumber AS INT),
       Message = CAST(b.Message AS NVARCHAR(400))
FROM
(
    -- Seq 1: no order, every action
    SELECT a.Action, Seq = 1, ErrorNumber = 62006, Message = N'Transfer order not found.'
    FROM (VALUES (N'Edit'), (N'Delete'), (N'Release'), (N'SendForApproval'), (N'Approve'), (N'Reject'), (N'Withdraw'),
                 (N'BackToDraft'), (N'Dispatch'), (N'Receive'), (N'DispatchAndReceive'), (N'NothingMoreSent'), (N'Cancel'),
                 (N'CreateReturn'), (N'UpdateDetails'), (N'ChangeEta'), (N'ReverseDispatch'), (N'ReverseReceipt')) a (Action)
    WHERE NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id)

    UNION ALL
    SELECT r.Action, r.Seq, r.ErrorNumber, r.Message
    FROM o
    CROSS APPLY (VALUES
        -- Edit: a draft only
        (N'Edit', 10, 62010, CASE WHEN o.Status = 4 THEN N'This transfer order is waiting for approval: withdraw it to change it.' END),
        (N'Edit', 11, 62005, CASE WHEN o.Status = 2 AND o.PostingCount = 0
                                  THEN o.No + N' is released: its lines, quantities and warehouses are locked. Use Back to draft' + NCHAR(8230) + N' to change them.' END),
        (N'Edit', 12, 62005, CASE WHEN o.Status = 2 AND o.PostingCount > 0
                                  THEN o.No + N' is released and has moved goods: its lines, quantities and warehouses can no longer change.' END),
        (N'Edit', 13, 62005, CASE WHEN o.Status = 3 THEN o.No + N' is cancelled.' END),
        -- Delete: a draft only
        (N'Delete', 20, 62005, CASE WHEN o.Status <> 1
                                    THEN N'Only a draft transfer order can be deleted. A released one is cancelled with Cancel order' + NCHAR(8230) END),
        -- Release
        (N'Release', 30, 62010, CASE WHEN o.Status = 4 THEN N'This transfer order is waiting for approval: an approver approves it, or withdraw it and release it.' END),
        (N'Release', 31, 62010, CASE WHEN o.Status = 2 THEN o.No + N' is already released.' END),
        (N'Release', 32, 62010, CASE WHEN o.Status = 3 THEN o.No + N' is cancelled.' END),
        -- Release, Send for approval, Approve: what a released order needs
        (N'Release', 33, 62008, o.TroOff), (N'SendForApproval', 33, 62008, o.TroOff), (N'Approve', 33, 62008, o.TroOff),
        (N'Release', 34, 62009, o.NoLines), (N'SendForApproval', 34, 62009, o.NoLines), (N'Approve', 34, 62009, o.NoLines),
        (N'Release', 35, 62000, o.WarehouseProblem), (N'SendForApproval', 35, 62000, o.WarehouseProblem), (N'Approve', 35, 62000, o.WarehouseProblem),
        (N'Release', 36, 62000, o.InactiveLine), (N'SendForApproval', 36, 62000, o.InactiveLine), (N'Approve', 36, 62000, o.InactiveLine),
        (N'Release', 37, 62014, CASE WHEN o.NeedsApproval = 1 AND o.CanApprove = 0
                                     THEN o.No + N' needs approval before it is released: use Send for approval' + NCHAR(8230) END),
        -- Send for approval
        (N'SendForApproval', 40, 62010, CASE WHEN o.NeedsApproval = 0 THEN o.NoApproval END),
        (N'SendForApproval', 41, 62010, CASE o.Status WHEN 4 THEN N'This transfer order is already waiting for approval.'
                                                      WHEN 2 THEN o.No + N' is already released.'
                                                      WHEN 3 THEN o.No + N' is cancelled.' END),
        -- Approve (from Waiting; Approve & release from a draft while the switch is on). From Waiting it stays allowed
        -- after the switch is turned off: turning a switch never changes an order already waiting.
        (N'Approve', 50, 62015, o.NotApprover),
        (N'Approve', 51, 62010, CASE o.Status WHEN 2 THEN o.No + N' is already released.' WHEN 3 THEN o.No + N' is cancelled.' END),
        (N'Approve', 52, 62010, CASE WHEN o.Status = 1 AND o.NeedsApproval = 0 THEN o.NoApproval END),
        -- Reject, Withdraw
        (N'Reject', 60, 62015, o.NotApprover),
        (N'Reject', 61, 62010, CASE WHEN o.Status <> 4 THEN N'Only an order waiting for approval can be rejected.' END),
        (N'Withdraw', 61, 62010, CASE WHEN o.Status <> 4 THEN N'Only an order waiting for approval can be withdrawn.' END),
        -- Back to draft: a released order that has never posted anything, reversed or not (Save replaces the lines,
        -- and posting lines must never lose their order line)
        (N'BackToDraft', 70, 62010, CASE WHEN o.Status <> 2 THEN N'Only a released order can go back to draft.' END),
        (N'BackToDraft', 71, 62010, CASE WHEN o.PostingCount > 0
                                         THEN o.No + N' has dispatches (' + o.DispatchList + N'): an order that has moved goods cannot go back to draft. Use Nothing more will be sent'
                                              + NCHAR(8230) + N' or Cancel order' + NCHAR(8230) + N' instead.' END),
        -- Dispatch, Dispatch and receive
        (N'Dispatch', 80, 62010, CASE o.Status WHEN 1 THEN N'Release the order first: goods are dispatched from a released order.'
                                               WHEN 4 THEN N'This transfer order is waiting for approval.'
                                               WHEN 3 THEN o.No + N' is cancelled.' END),
        (N'DispatchAndReceive', 80, 62010, CASE o.Status WHEN 1 THEN N'Release the order first: goods are dispatched from a released order.'
                                                         WHEN 4 THEN N'This transfer order is waiting for approval.'
                                                         WHEN 3 THEN o.No + N' is cancelled.' END),
        (N'Dispatch', 81, 62010, CASE WHEN o.NotSentOnBy IS NOT NULL THEN N'Nothing more will be sent on ' + o.No + N' (closed ' + o.NotSentOnBy + N').' END),
        (N'DispatchAndReceive', 81, 62010, CASE WHEN o.NotSentOnBy IS NOT NULL THEN N'Nothing more will be sent on ' + o.No + N' (closed ' + o.NotSentOnBy + N').' END),
        (N'Dispatch', 82, 62009, CASE WHEN o.ToDispatchBase = 0 THEN N'Everything ordered is already dispatched.' END),
        (N'DispatchAndReceive', 82, 62009, CASE WHEN o.ToDispatchBase = 0 THEN N'Everything ordered is already dispatched.' END),
        (N'Dispatch', 83, 62008, o.TrdOff), (N'DispatchAndReceive', 83, 62008, o.TrdOff),
        (N'DispatchAndReceive', 84, 62008, o.TrrOff), (N'Receive', 84, 62008, o.TrrOff),
        (N'Dispatch', 85, 62000, o.DispatchWarehouseProblem), (N'DispatchAndReceive', 85, 62000, o.DispatchWarehouseProblem),
        (N'Dispatch', 86, 62007, o.NoStockAtFrom), (N'DispatchAndReceive', 86, 62007, o.NoStockAtFrom),
        -- Receive
        (N'Receive', 90, 62010, CASE o.Status WHEN 1 THEN N'Release the order first.'
                                              WHEN 3 THEN o.No + N' is cancelled.'
                                              WHEN 4 THEN N'This transfer order is waiting for approval.' END),
        (N'Receive', 91, 62009, CASE WHEN o.OnTheWayBase = 0
                                     THEN CASE WHEN o.DispatchedBase = 0 THEN N'Nothing is on the way: dispatch goods first.'
                                               ELSE N'Everything dispatched has arrived.' END END),
        (N'Receive', 92, 62000, o.ReceiveWarehouseProblem),
        -- Nothing more will be sent
        (N'NothingMoreSent', 100, 62010, CASE WHEN o.Status <> 2 THEN N'Only a released order can be closed.' END),
        (N'NothingMoreSent', 101, 62010, CASE WHEN o.NotSentOnBy IS NOT NULL THEN N'Nothing more will be sent on ' + o.No + N' already (' + o.NotSentOnBy + N').' END),
        (N'NothingMoreSent', 102, 62010, CASE WHEN o.DispatchedBase = 0
                                              THEN N'Nothing has been dispatched on ' + o.No + N': use Cancel order' + NCHAR(8230) + N' instead.' END),
        (N'NothingMoreSent', 103, 62009, CASE WHEN o.ToDispatchBase = 0 THEN N'Everything ordered is already dispatched.' END),
        -- Cancel order: released, nothing dispatched (a reversed dispatch counts as none)
        (N'Cancel', 110, 62010, CASE o.Status WHEN 1 THEN N'A draft is deleted, not cancelled: use Delete.'
                                              WHEN 4 THEN N'Withdraw the request for approval first.'
                                              WHEN 3 THEN o.No + N' is already cancelled.' END),
        (N'Cancel', 111, 62010, CASE WHEN o.DispatchedBase > 0
                                     THEN o.No + N' has dispatched goods (' + o.PostedDispatchList + N'): reverse them first, or use Nothing more will be sent.' END),
        -- Create return: something received that no return not cancelled takes back yet
        (N'CreateReturn', 120, 62010, CASE WHEN o.ReceivedBase = 0 THEN N'Nothing was received on ' + o.No + N': there is nothing to return.' END),
        (N'CreateReturn', 121, 62010, CASE WHEN o.ReceivedBase > 0 AND o.HasReturnable = 0
                                           THEN N'Everything received on ' + o.No + N' is already on its returns (' + o.ReturnList + N'): open them.' END),
        -- Update details (Expected arrival, Reference, Notes of an order that is no longer a draft)
        (N'UpdateDetails', 140, 62010, CASE WHEN o.Status = 1 THEN N'A draft is changed with Save.' END),
        (N'UpdateDetails', 141, 62010, CASE WHEN o.Status = 4 THEN N'This transfer order is waiting for approval: withdraw it to change it.' END)
    ) r (Action, Seq, ErrorNumber, Message)
    WHERE r.Message IS NOT NULL
) b;
GO

-- (90) WHY A DISPATCH OR A TRANSFER RECEIPT CANNOT BE REVERSED NOW, the posting's own rules (the order's are the
--      ReverseDispatch / ReverseReceipt rows of fn_TransferOrder_Blocks): one row per failed rule, the first (lowest
--      Seq) is the reason, none = allowed. Read by usp_TransferPosting_Reverse (thrown as it comes) and by
--      usp_TransferOrder_Get (the posting's ReverseBlockedReason). A RECEIPT BEFORE ITS DISPATCH: a dispatch whose goods
--      a posted receipt took (received or written off) waits for that receipt's reversal; a receipt only while the
--      destination still holds what it brought.
CREATE OR ALTER FUNCTION inventory.fn_TransferPosting_ReverseBlock (@PostingId INT)
RETURNS TABLE
AS
RETURN
WITH p AS
(
    SELECT tp.Id, tp.Kind, tp.Status, tp.DocumentNumber, tp.ToWarehouseId, tp.TransitWarehouseId
    FROM inventory.TransferPostings tp
    WHERE tp.Id = @PostingId
),
r AS
(
    -- the posted receipts with a line on one of the dispatch's lines
    SELECT rp.Id, rp.DocumentNumber, rp.PostedAtUtc
    FROM inventory.TransferPostings rp
    WHERE rp.Kind = N'Receipt' AND rp.Status = 2
      AND EXISTS (SELECT 1 FROM inventory.TransferPostingLines rl
                  INNER JOIN inventory.TransferPostingLines dl ON dl.Id = rl.DispatchLineId
                  WHERE rl.PostingId = rp.Id AND dl.PostingId = @PostingId)
)
SELECT Seq = CAST(x.Seq AS INT), ErrorNumber = CAST(x.ErrorNumber AS INT), Message = CAST(x.Message AS NVARCHAR(400))
FROM
(
    SELECT Seq = 1, ErrorNumber = 62006, Message = CAST(N'Dispatch or receipt not found.' AS NVARCHAR(400))
    WHERE NOT EXISTS (SELECT 1 FROM p)

    UNION ALL
    SELECT 2, 62010, p.DocumentNumber + N' is already reversed.'
    FROM p WHERE p.Status = 3

    UNION ALL
    SELECT 3, 62013, p.DocumentNumber + N' has goods received by ' + rl.List
                     + CASE WHEN rn.N > 3 THEN N' and ' + CAST(rn.N - 3 AS NVARCHAR(10)) + N' more' ELSE N'' END
                     + N': reverse that receipt first.'
    FROM p
    CROSS APPLY (SELECT N = COUNT(*) FROM r) rn
    CROSS APPLY (SELECT List = STRING_AGG(t.DocumentNumber, N', ') WITHIN GROUP (ORDER BY t.PostedAtUtc, t.Id)
                 FROM (SELECT TOP (3) r.Id, r.DocumentNumber, r.PostedAtUtc FROM r ORDER BY r.PostedAtUtc, r.Id) t) rl
    WHERE p.Kind = N'Dispatch' AND p.Status = 2 AND rn.N > 0

    UNION ALL
    -- a receipt, per item: the destination must still hold what it brought
    SELECT * FROM (SELECT TOP (1) Seq = 4, ErrorNumber = 62007,
                          Message = N'Cannot reverse: ' + i.ItemCode + N' in ' + w.WarehouseCode + N' has only '
                                    + CAST(oh.Q AS NVARCHAR(20)) + N' left, but this receipt brought ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
                   FROM p
                   CROSS APPLY (SELECT m.ItemId, m.WarehouseId, Qty = SUM(m.QuantityBase)
                                FROM inventory.StockMovements m
                                WHERE m.DocumentFamily = N'Transfer' AND m.DocumentTypeCode = N'TRR' AND m.DocumentId = p.Id
                                  AND m.IsReversal = 0 AND m.WarehouseId = p.ToWarehouseId
                                GROUP BY m.ItemId, m.WarehouseId) x
                   CROSS APPLY (SELECT Q = ISNULL(SUM(s.QuantityBase), 0) FROM inventory.StockMovements s
                                WHERE s.ItemId = x.ItemId AND s.WarehouseId = x.WarehouseId) oh
                   INNER JOIN inventory.Items i       ON i.Id = x.ItemId
                   INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
                   WHERE p.Kind = N'Receipt' AND p.Status = 2 AND x.Qty > oh.Q
                   ORDER BY i.ItemCode) a4

    UNION ALL
    -- a dispatch, per item: the On the way warehouse must still hold what it sent (a safety net: while no posted receipt
    -- took its goods - Seq 3 - they are all still there)
    SELECT * FROM (SELECT TOP (1) Seq = 5, ErrorNumber = 62007,
                          Message = N'Cannot reverse: ' + i.ItemCode + N' in ' + w.WarehouseCode + N' has only '
                                    + CAST(oh.Q AS NVARCHAR(20)) + N' left, but this dispatch sent ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
                   FROM p
                   CROSS APPLY (SELECT m.ItemId, m.WarehouseId, Qty = SUM(m.QuantityBase)
                                FROM inventory.StockMovements m
                                WHERE m.DocumentFamily = N'Transfer' AND m.DocumentTypeCode = N'TRD' AND m.DocumentId = p.Id
                                  AND m.IsReversal = 0 AND m.WarehouseId = p.TransitWarehouseId
                                GROUP BY m.ItemId, m.WarehouseId) x
                   CROSS APPLY (SELECT Q = ISNULL(SUM(s.QuantityBase), 0) FROM inventory.StockMovements s
                                WHERE s.ItemId = x.ItemId AND s.WarehouseId = x.WarehouseId) oh
                   INNER JOIN inventory.Items i       ON i.Id = x.ItemId
                   INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
                   WHERE p.Kind = N'Dispatch' AND p.Status = 2 AND x.Qty > oh.Q
                   ORDER BY i.ItemCode) a5
) x;
GO

/* ================================================================== 11. Warehouses, branches and items: the On the way rules */

-- (90) DOES ANYTHING REFERENCE THE WAREHOUSE? The generic foreign-key scan of script 28's usp_Warehouse_Delete, held
--      once here: every foreign key to masterdata.Warehouses (so every future table is covered without changing this
--      procedure) but the warehouses' own ParentId (the delete says children in its own words) and a key that CASCADES
--      on delete (a cascading child is owned by the warehouse, not a reference to it: none exists before script 90).
--      Read by usp_Warehouse_Delete and by usp_Branch_Delete for the branch's On the way warehouse.
CREATE OR ALTER PROCEDURE masterdata.usp_Warehouse_IsReferenced
    @Id         INT,
    @Referenced BIT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @Referenced = 0;
    DECLARE @sql NVARCHAR(MAX) = N'';

    SELECT @sql = @sql
        + N'IF @Referenced = 0 AND EXISTS (SELECT 1 FROM ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name)
        + N' WHERE ' + QUOTENAME(c.name) + N' = @Id) SET @Referenced = 1;' + NCHAR(10)
    FROM sys.foreign_keys fk
    INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    INNER JOIN sys.tables t  ON t.object_id = fk.parent_object_id
    INNER JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
    WHERE fk.referenced_object_id = OBJECT_ID(N'masterdata.Warehouses')
      -- ParentId is said by the delete, in its own words.
      AND NOT (t.object_id = OBJECT_ID(N'masterdata.Warehouses') AND c.name = N'ParentId')
      -- a cascading child is owned, not a reference
      AND fk.delete_referential_action = 0;

    IF @sql <> N''
        EXEC sp_executesql @sql, N'@Id INT, @Referenced BIT OUTPUT', @Id = @Id, @Referenced = @Referenced OUTPUT;
END
GO

-- Re-created (90) from the body of script 28: + an On the way warehouse is refused (52009: it is removed with its
-- branch); the generic reference scan moved to usp_Warehouse_IsReferenced (the same keys: none cascades), with today's
-- sentence.
CREATE OR ALTER PROCEDURE masterdata.usp_Warehouse_Delete
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @Id)
        THROW 52006, 'Warehouse not found.', 1;

    -- (90) THE BRANCH'S ON THE WAY WAREHOUSE is the system's: usp_Branch_Delete removes it with its branch.
    IF EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @Id AND IsTransit = 1)
    BEGIN
        DECLARE @TransitMsg NVARCHAR(400) = (SELECT w.WarehouseCode + N' is the On the way warehouse of ' + b.BranchCode + N': it is removed with its branch.'
                                             FROM masterdata.Warehouses w INNER JOIN masterdata.Branches b ON b.Id = w.BranchId
                                             WHERE w.Id = @Id);
        THROW 52009, @TransitMsg, 1;
    END

    IF EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @Id AND IsMainWarehouse = 1)
        THROW 52005, 'The Main Warehouse cannot be deleted. Designate another warehouse as the Main Warehouse first.', 1;

    /* Said before the generic reference scan below, which would otherwise report a warehouse with
       children as "contains inventory or is referenced by other records" - true, but not the thing
       the reader has to fix. */
    IF EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE ParentId = @Id)
        THROW 52003, 'This warehouse has warehouses standing under it. Move or delete them first.', 1;

    -- (90) the generic reference scan, held once (ParentId is handled above, in its own words)
    DECLARE @Referenced BIT = 0;
    EXEC masterdata.usp_Warehouse_IsReferenced @Id, @Referenced OUTPUT;

    IF @Referenced = 1
        THROW 52003, 'This warehouse cannot be deleted because it contains inventory or is referenced by other records. You may deactivate the warehouse instead.', 1;

    DELETE FROM masterdata.Warehouses WHERE Id = @Id;
END
GO

-- Re-created (90) from the body of script 71: + @IncludeTransit (last) and the column IsTransit (last). THE ON THE WAY
-- WAREHOUSES ARE LEFT OUT unless asked (Stock Valuation's filter) or named by @IncludeId: every other picker gets
-- today's rows, and the name of an empty On the way warehouse still resolves through @IncludeId.
CREATE OR ALTER PROCEDURE masterdata.usp_Warehouse_Lookup
    @ActiveOnly BIT = 1,
    @BranchId   INT = NULL,
    @IncludeId  INT = NULL,
    @IncludeTransit BIT = 0   -- (90) 1 = the branches' On the way warehouses too
AS
BEGIN
    SET NOCOUNT ON;
    SELECT w.Id, w.WarehouseCode, w.WarehouseName, w.BranchId, b.BranchCode, b.BranchName,
           w.IsMainWarehouse, w.IsActive, w.ParentId, w.[Level], w.AllowOutOfStockOverride,
           ChildCount = (SELECT COUNT(*) FROM masterdata.Warehouses c WHERE c.ParentId = w.Id),
           IsUsed     = masterdata.fn_Warehouse_IsUsed(w.Id),
           w.IsTransit                                                     -- (90)
    FROM masterdata.Warehouses w
    INNER JOIN masterdata.Branches b ON b.Id = w.BranchId
    WHERE (@ActiveOnly = 0 OR w.IsActive = 1 OR w.Id = @IncludeId)
      AND (@BranchId IS NULL OR w.BranchId = @BranchId)
      AND (w.IsTransit = 0 OR @IncludeTransit = 1 OR w.Id = @IncludeId)   -- (90)
    ORDER BY w.IsMainWarehouse DESC, w.WarehouseName;
END
GO

-- Re-created (90) from the body of script 40: + the column IsTransit (last): the Warehouses page marks the On the way
-- rows and locks their form.
CREATE OR ALTER PROCEDURE masterdata.usp_Warehouse_Search
    @Search          NVARCHAR(150) = NULL,
    @BranchId        INT           = NULL,
    @IsActive        BIT           = NULL,
    @IsMainWarehouse BIT           = NULL,
    @SortColumn      NVARCHAR(30)  = N'WarehouseCode',
    @SortDirection   NVARCHAR(4)   = N'ASC',
    @PageNumber      INT           = 1,
    @PageSize        INT           = 10
AS
BEGIN
    SET NOCOUNT ON;

    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'WarehouseCode', N'WarehouseName', N'BranchName', N'Address', N'IsMainWarehouse', N'IsActive', N'CreatedAtUtc')
        SET @SortColumn = N'WarehouseCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC')
        SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT w.Id, w.WarehouseCode, w.WarehouseName, w.BranchId, b.BranchCode, b.BranchName, w.Address,
           w.IsMainWarehouse, w.IsActive, w.CreatedAtUtc, w.CreatedBy, w.UpdatedAtUtc, w.UpdatedBy, w.RowVersion,
           w.ParentId, w.[Level], w.AllowOutOfStockOverride,
           ParentCode = p.WarehouseCode,
           ParentName = p.WarehouseName,
           ChildCount = (SELECT COUNT(*) FROM masterdata.Warehouses c WHERE c.ParentId = w.Id),
           COUNT(*) OVER () AS TotalCount,
           w.IsTransit                                                     -- (90)
    FROM masterdata.Warehouses w
    INNER JOIN masterdata.Branches b ON b.Id = w.BranchId
    LEFT  JOIN masterdata.Warehouses p ON p.Id = w.ParentId
    WHERE (@Search IS NULL OR w.WarehouseCode LIKE N'%' + @Search + N'%' OR w.WarehouseName LIKE N'%' + @Search + N'%')
      AND (@BranchId IS NULL OR w.BranchId = @BranchId)
      AND (@IsActive IS NULL OR w.IsActive = @IsActive)
      AND (@IsMainWarehouse IS NULL OR w.IsMainWarehouse = @IsMainWarehouse)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'WarehouseCode' THEN w.WarehouseCode WHEN N'WarehouseName' THEN w.WarehouseName
                             WHEN N'BranchName' THEN b.BranchName WHEN N'Address' THEN w.Address END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'WarehouseCode' THEN w.WarehouseCode WHEN N'WarehouseName' THEN w.WarehouseName
                             WHEN N'BranchName' THEN b.BranchName WHEN N'Address' THEN w.Address END
        END DESC,
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'IsMainWarehouse' THEN CAST(w.IsMainWarehouse AS INT) WHEN N'IsActive' THEN CAST(w.IsActive AS INT) END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'IsMainWarehouse' THEN CAST(w.IsMainWarehouse AS INT) WHEN N'IsActive' THEN CAST(w.IsActive AS INT) END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN w.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN w.CreatedAtUtc END DESC,
        w.WarehouseCode ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END
GO

-- Re-created (90) from the body of script 40: + the column IsTransit (last).
CREATE OR ALTER PROCEDURE masterdata.usp_Warehouse_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT w.Id, w.WarehouseCode, w.WarehouseName, w.BranchId, b.BranchCode, b.BranchName, w.Address,
           w.IsMainWarehouse, w.IsActive, w.CreatedAtUtc, w.CreatedBy, w.UpdatedAtUtc, w.UpdatedBy, w.RowVersion,
           w.ParentId, w.[Level], w.AllowOutOfStockOverride,
           ParentCode = p.WarehouseCode,
           ParentName = p.WarehouseName,
           ChildCount = (SELECT COUNT(*) FROM masterdata.Warehouses c WHERE c.ParentId = w.Id),
           w.IsTransit                                                     -- (90)
    FROM masterdata.Warehouses w
    INNER JOIN masterdata.Branches b ON b.Id = w.BranchId
    LEFT  JOIN masterdata.Warehouses p ON p.Id = w.ParentId
    WHERE w.Id = @Id;
END
GO

-- Re-created (90) from the body of script 71: + an On the way warehouse cannot be a parent (52000), said before the
-- "used parent" test (it is used as soon as a transfer moved goods).
CREATE OR ALTER PROCEDURE masterdata.usp_Warehouse_Create
    @WarehouseCode        NVARCHAR(20),
    @WarehouseName        NVARCHAR(150),
    @BranchId             INT,
    @Address              NVARCHAR(500) = NULL,
    @IsMainWarehouse      BIT           = 0,
    @IsActive             BIT           = 1,
    @ReplaceMainWarehouse BIT           = 0,
    @ParentId             INT           = NULL,   -- NULL = a root warehouse
    @AllowOutOfStockOverride BIT        = NULL,   -- NULL = follow the global setting
    @UserId               INT           = NULL,
    @NewId                INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @WarehouseCode = LTRIM(RTRIM(@WarehouseCode));
    SET @WarehouseName = LTRIM(RTRIM(@WarehouseName));
    SET @Address       = NULLIF(LTRIM(RTRIM(@Address)), N'');
    SET @IsMainWarehouse = ISNULL(@IsMainWarehouse, 0);
    SET @IsActive        = ISNULL(@IsActive, 1);

    IF @WarehouseCode IS NULL OR @WarehouseCode = N''
        THROW 52000, 'Warehouse Code is required.', 1;

    IF @WarehouseName IS NULL OR @WarehouseName = N''
        THROW 52000, 'Warehouse Name is required.', 1;

    IF @BranchId IS NULL
        THROW 52000, 'Branch / Site is required.', 1;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 52007, 'The selected Branch / Site does not exist or is inactive. Select an active branch.', 1;

    -- The parent need not share the branch: the tree and the branch answer different questions.
    IF @ParentId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @ParentId)
        THROW 52000, 'The selected parent warehouse does not exist.', 1;
    -- (90) an On the way warehouse holds goods on the road, never other warehouses
    IF @ParentId IS NOT NULL AND EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @ParentId AND IsTransit = 1)
        THROW 52000, 'An On the way warehouse cannot hold other warehouses. Choose another parent warehouse.', 1;
    IF @ParentId IS NOT NULL AND masterdata.fn_Warehouse_IsUsed(@ParentId) = 1
    BEGIN
        DECLARE @UsedMsg NVARCHAR(400) = N'Warehouse ' + (SELECT WarehouseCode FROM masterdata.Warehouses WHERE Id = @ParentId) + N' is already used in transactions, so it cannot become a parent: stock is kept only in the warehouses at the bottom of the tree. Choose another parent warehouse.';
        THROW 52000, @UsedMsg, 1;
    END

    IF @IsMainWarehouse = 1 AND @IsActive = 0
        THROW 52005, 'The Main Warehouse must be active.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE WarehouseCode = @WarehouseCode)
        THROW 52001, 'A warehouse with this Warehouse Code already exists.', 1;

    DECLARE @Level INT = 1;
    IF @ParentId IS NOT NULL
        SET @Level = (SELECT [Level] + 1 FROM masterdata.Warehouses WHERE Id = @ParentId);

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @IsMainWarehouse = 1
        BEGIN
            DECLARE @CurrentMainId INT =
                (SELECT TOP (1) Id FROM masterdata.Warehouses WITH (UPDLOCK, HOLDLOCK) WHERE IsMainWarehouse = 1 AND IsActive = 1);

            IF @CurrentMainId IS NOT NULL
            BEGIN
                IF @ReplaceMainWarehouse = 0
                    THROW 52002, 'Another active warehouse is already designated as the Main Warehouse. Confirm to replace it.', 1;

                UPDATE masterdata.Warehouses
                SET IsMainWarehouse = 0, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
                WHERE Id = @CurrentMainId;
            END
        END

        INSERT INTO masterdata.Warehouses (WarehouseCode, WarehouseName, BranchId, Address, IsMainWarehouse, IsActive, ParentId, [Level], CreatedBy, AllowOutOfStockOverride)
        VALUES (@WarehouseCode, @WarehouseName, @BranchId, @Address, @IsMainWarehouse, @IsActive, @ParentId, @Level, @UserId, @AllowOutOfStockOverride);

        SET @NewId = SCOPE_IDENTITY();

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Re-created (90) from the body of script 71: + AN ON THE WAY WAREHOUSE CHANGES ONLY ITS NAME AND ADDRESS: any other
-- value sent (code, branch, parent, main, active, out-of-stock override) must equal the stored one, else 52009; + an On
-- the way warehouse cannot be a parent (52000), as on Create.
CREATE OR ALTER PROCEDURE masterdata.usp_Warehouse_Update
    @Id                   INT,
    @WarehouseCode        NVARCHAR(20),
    @WarehouseName        NVARCHAR(150),
    @BranchId             INT,
    @Address              NVARCHAR(500) = NULL,
    @IsMainWarehouse      BIT           = 0,
    @IsActive             BIT           = 1,
    @ReplaceMainWarehouse BIT           = 0,
    @ParentId             INT           = NULL,
    @AllowOutOfStockOverride BIT        = NULL,   -- NULL = follow the global setting
    @RowVersion           BINARY(8)     = NULL,
    @UserId               INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @WarehouseCode = LTRIM(RTRIM(@WarehouseCode));
    SET @WarehouseName = LTRIM(RTRIM(@WarehouseName));
    SET @Address       = NULLIF(LTRIM(RTRIM(@Address)), N'');
    SET @IsMainWarehouse = ISNULL(@IsMainWarehouse, 0);
    SET @IsActive        = ISNULL(@IsActive, 1);

    DECLARE @CurrentBranchId INT = (SELECT BranchId FROM masterdata.Warehouses WHERE Id = @Id);

    IF @CurrentBranchId IS NULL
        THROW 52006, 'Warehouse not found.', 1;

    IF @WarehouseCode IS NULL OR @WarehouseCode = N''
        THROW 52000, 'Warehouse Code is required.', 1;

    IF @WarehouseName IS NULL OR @WarehouseName = N''
        THROW 52000, 'Warehouse Name is required.', 1;

    IF @BranchId IS NULL
        THROW 52000, 'Branch / Site is required.', 1;

    -- (90) THE BRANCH'S ON THE WAY WAREHOUSE belongs to transfers: its name and address may change, nothing else (the
    --      code compared exactly, so not even its case changes).
    IF EXISTS (SELECT 1 FROM masterdata.Warehouses w
               WHERE w.Id = @Id AND w.IsTransit = 1
                 AND (   @WarehouseCode COLLATE Latin1_General_BIN2 <> w.WarehouseCode COLLATE Latin1_General_BIN2
                      OR @BranchId <> w.BranchId
                      OR @ParentId IS NOT NULL
                      OR @IsMainWarehouse <> w.IsMainWarehouse
                      OR @IsActive <> w.IsActive
                      OR ISNULL(CAST(@AllowOutOfStockOverride AS TINYINT), 2) <> ISNULL(CAST(w.AllowOutOfStockOverride AS TINYINT), 2)))
    BEGIN
        DECLARE @TransitMsg NVARCHAR(400) = (SELECT w.WarehouseCode + N' is the On the way warehouse of ' + b.BranchCode + N': transfers use it. Only its name and address can be changed.'
                                             FROM masterdata.Warehouses w INNER JOIN masterdata.Branches b ON b.Id = w.BranchId
                                             WHERE w.Id = @Id);
        THROW 52009, @TransitMsg, 1;
    END

    IF @BranchId <> @CurrentBranchId AND NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 52007, 'The selected Branch / Site does not exist or is inactive. Select an active branch.', 1;

    IF @IsMainWarehouse = 1 AND @IsActive = 0
        THROW 52005, 'The Main Warehouse must be active.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE WarehouseCode = @WarehouseCode AND Id <> @Id)
        THROW 52001, 'A warehouse with this Warehouse Code already exists.', 1;

    IF @ParentId IS NOT NULL
    BEGIN
        IF @ParentId = @Id
            THROW 52008, 'A warehouse cannot be its own parent.', 1;

        IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @ParentId)
            THROW 52000, 'The selected parent warehouse does not exist.', 1;

        -- The move that would swallow the mover: the chosen parent stands under this warehouse.
        IF EXISTS (SELECT 1 FROM masterdata.fn_Warehouse_Subtree(@Id) WHERE Id = @ParentId)
            THROW 52008, 'This would create a circular hierarchy: the selected parent stands under this warehouse.', 1;
        -- (90) an On the way warehouse holds goods on the road, never other warehouses
        IF EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @ParentId AND IsTransit = 1)
            THROW 52000, 'An On the way warehouse cannot hold other warehouses. Choose another parent warehouse.', 1;
        -- Only a NEW parent is checked: a warehouse already standing under a used one keeps its place.
        IF @ParentId <> ISNULL((SELECT ParentId FROM masterdata.Warehouses WHERE Id = @Id), 0)
           AND masterdata.fn_Warehouse_IsUsed(@ParentId) = 1
        BEGIN
            DECLARE @UsedMsg NVARCHAR(400) = N'Warehouse ' + (SELECT WarehouseCode FROM masterdata.Warehouses WHERE Id = @ParentId) + N' is already used in transactions, so it cannot become a parent: stock is kept only in the warehouses at the bottom of the tree. Choose another parent warehouse.';
            THROW 52000, @UsedMsg, 1;
        END
    END

    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 52004, 'This warehouse was modified by another user. Reload the page and try again.', 1;

    DECLARE @NewLevel INT = 1;
    IF @ParentId IS NOT NULL
        SET @NewLevel = (SELECT [Level] + 1 FROM masterdata.Warehouses WHERE Id = @ParentId);

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @IsMainWarehouse = 1
        BEGIN
            DECLARE @CurrentMainId INT =
                (SELECT TOP (1) Id FROM masterdata.Warehouses WITH (UPDLOCK, HOLDLOCK)
                 WHERE IsMainWarehouse = 1 AND IsActive = 1 AND Id <> @Id);

            IF @CurrentMainId IS NOT NULL
            BEGIN
                IF @ReplaceMainWarehouse = 0
                    THROW 52002, 'Another active warehouse is already designated as the Main Warehouse. Confirm to replace it.', 1;

                UPDATE masterdata.Warehouses
                SET IsMainWarehouse = 0, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
                WHERE Id = @CurrentMainId;
            END
        END

        UPDATE masterdata.Warehouses
        SET WarehouseCode   = @WarehouseCode,
            WarehouseName   = @WarehouseName,
            BranchId        = @BranchId,
            Address         = @Address,
            IsMainWarehouse = @IsMainWarehouse,
            IsActive        = @IsActive,
            ParentId        = @ParentId,
            AllowOutOfStockOverride = @AllowOutOfStockOverride,
            UpdatedAtUtc    = SYSUTCDATETIME(),
            UpdatedBy       = @UserId
        WHERE Id = @Id;

        /* THE WHOLE SUBTREE MOVES WITH IT. A warehouse carried to a new parent takes its
           children along, and their Level is their depth below it - left alone they would keep
           the depth they had under the old parent and the tree would draw at the wrong indent. */
        UPDATE w
        SET w.[Level] = @NewLevel + s.Depth
        FROM masterdata.Warehouses w
        INNER JOIN masterdata.fn_Warehouse_Subtree(@Id) s ON s.Id = w.Id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Re-created (90) from the body of script 07: + an On the way warehouse stays active (52009): inactive, it would only
-- break the next dispatch to its branch.
CREATE OR ALTER PROCEDURE masterdata.usp_Warehouse_SetActive
    @Id       INT,
    @IsActive BIT,
    @UserId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @Id)
        THROW 52006, 'Warehouse not found.', 1;

    -- (90) THE BRANCH'S ON THE WAY WAREHOUSE is never deactivated: transfers to the branch put their goods there.
    IF @IsActive = 0 AND EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @Id AND IsTransit = 1)
    BEGIN
        DECLARE @TransitMsg NVARCHAR(400) = (SELECT w.WarehouseCode + N' is the On the way warehouse of ' + b.BranchCode + N': it stays active (transfers use it).'
                                             FROM masterdata.Warehouses w INNER JOIN masterdata.Branches b ON b.Id = w.BranchId
                                             WHERE w.Id = @Id);
        THROW 52009, @TransitMsg, 1;
    END

    IF @IsActive = 0 AND EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @Id AND IsMainWarehouse = 1)
        THROW 52005, 'The Main Warehouse cannot be deactivated. Designate another warehouse as the Main Warehouse first.', 1;

    -- Re-activating a warehouse whose branch is inactive is not allowed (rule 3).
    IF @IsActive = 1 AND NOT EXISTS (SELECT 1 FROM masterdata.Warehouses w INNER JOIN masterdata.Branches b ON b.Id = w.BranchId
                                     WHERE w.Id = @Id AND b.IsActive = 1)
        THROW 52007, 'The warehouse cannot be activated because its Branch / Site is inactive.', 1;

    UPDATE masterdata.Warehouses
    SET IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
END
GO

-- Re-created (90) from the body of script 06: + THE NEW BRANCH GETS ITS ON THE WAY WAREHOUSE AT ONCE, in the same
-- transaction (a transfer to one of its warehouses can be dispatched from the first day).
CREATE OR ALTER PROCEDURE masterdata.usp_Branch_Create
    @BranchCode        NVARCHAR(20),
    @BranchName        NVARCHAR(150),
    @Address           NVARCHAR(500) = NULL,
    @IsMainBranch      BIT           = 0,
    @IsActive          BIT           = 1,
    @ReplaceMainBranch BIT           = 0,    -- 1 = the caller confirmed replacing the current Main Branch
    @UserId            INT           = NULL,
    @NewId             INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @BranchCode = LTRIM(RTRIM(@BranchCode));
    SET @BranchName = LTRIM(RTRIM(@BranchName));
    SET @Address    = NULLIF(LTRIM(RTRIM(@Address)), N'');
    SET @IsMainBranch = ISNULL(@IsMainBranch, 0);
    SET @IsActive     = ISNULL(@IsActive, 1);

    IF @BranchCode IS NULL OR @BranchCode = N''
        THROW 51000, 'Branch Code is required.', 1;

    IF @BranchName IS NULL OR @BranchName = N''
        THROW 51000, 'Branch Name is required.', 1;

    IF @IsMainBranch = 1 AND @IsActive = 0
        THROW 51005, 'The Main Branch must be active.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.Branches WHERE BranchCode = @BranchCode)
        THROW 51001, 'A branch with this Branch Code already exists.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @IsMainBranch = 1
        BEGIN
            DECLARE @CurrentMainId INT =
                (SELECT TOP (1) Id FROM masterdata.Branches WITH (UPDLOCK, HOLDLOCK) WHERE IsMainBranch = 1 AND IsActive = 1);

            IF @CurrentMainId IS NOT NULL
            BEGIN
                IF @ReplaceMainBranch = 0
                    THROW 51002, 'Another active branch is already designated as the Main Branch. Confirm to replace it.', 1;

                UPDATE masterdata.Branches
                SET IsMainBranch = 0, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
                WHERE Id = @CurrentMainId;
            END
        END

        INSERT INTO masterdata.Branches (BranchCode, BranchName, Address, IsMainBranch, IsActive, CreatedBy)
        VALUES (@BranchCode, @BranchName, @Address, @IsMainBranch, @IsActive, @UserId);

        SET @NewId = SCOPE_IDENTITY();

        -- (90) its On the way warehouse
        EXEC masterdata.usp_Warehouse_EnsureTransit @BranchId = @NewId, @UserId = @UserId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Re-created (90) from the body of script 06: + ITS ON THE WAY WAREHOUSE GOES WITH IT when nothing references it (a
-- branch that never received a transfer); one that a transfer used is kept, and then references the branch, which is
-- refused with today's sentence (51003). One transaction now: the On the way warehouse is deleted only with its branch.
-- The scan of every reference to the branch runs FIRST (its On the way warehouse not counted), and nothing is deleted
-- before it is done: a refused delete - the usual case, a branch in use - never holds a deleted warehouse row while the
-- scan reads the ledger.
CREATE OR ALTER PROCEDURE masterdata.usp_Branch_Delete
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;                                                     -- (90)

    BEGIN TRY
    BEGIN TRANSACTION;                                                     -- (90)

    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @Id)
        THROW 51006, 'Branch not found.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @Id AND IsMainBranch = 1)
        THROW 51005, 'The Main Branch cannot be deleted. Designate another branch as the Main Branch first.', 1;

    -- (90) ITS ON THE WAY WAREHOUSE: not a reference of the branch by itself (the scan below leaves it out); a reference
    --      when anything references IT (a transfer used it). Deleted with the branch, after every check.
    DECLARE @TransitId INT = (SELECT Id FROM masterdata.Warehouses WITH (UPDLOCK, HOLDLOCK) WHERE BranchId = @Id AND IsTransit = 1);

    DECLARE @sql NVARCHAR(MAX) = N'';

    SELECT @sql = @sql
        + N'IF @Referenced = 0 AND EXISTS (SELECT 1 FROM ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name)
        + N' WHERE ' + QUOTENAME(c.name) + N' = @Id'
        + CASE WHEN t.object_id = OBJECT_ID(N'masterdata.Warehouses')
               THEN N' AND (@TransitId IS NULL OR Id <> @TransitId)' ELSE N'' END                   -- (90)
        + N') SET @Referenced = 1;' + NCHAR(10)
    FROM sys.foreign_keys fk
    INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    INNER JOIN sys.tables t  ON t.object_id = fk.parent_object_id
    INNER JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
    WHERE fk.referenced_object_id = OBJECT_ID(N'masterdata.Branches');

    DECLARE @Referenced BIT = 0;

    IF @sql <> N''
        EXEC sp_executesql @sql, N'@Id INT, @TransitId INT, @Referenced BIT OUTPUT',
                           @Id = @Id, @TransitId = @TransitId, @Referenced = @Referenced OUTPUT;   -- (90) + @TransitId

    IF @Referenced = 0 AND @TransitId IS NOT NULL                          -- (90)
        EXEC masterdata.usp_Warehouse_IsReferenced @TransitId, @Referenced OUTPUT;

    IF @Referenced = 1
        THROW 51003, 'This branch cannot be deleted because it is referenced by other records. You may deactivate the branch instead.', 1;

    IF @TransitId IS NOT NULL                                              -- (90)
        DELETE FROM masterdata.Warehouses WHERE Id = @TransitId;

    DELETE FROM masterdata.Branches WHERE Id = @Id;

    COMMIT TRANSACTION;                                                    -- (90)
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Re-created (90) from the body of script 11: + an On the way warehouse cannot be the default warehouse (56008).
CREATE OR ALTER PROCEDURE inventory.usp_Item_Create
    @ItemCode           NVARCHAR(30),
    @ItemName           NVARCHAR(200),
    @BrandId            INT,
    @Model              NVARCHAR(100)  = NULL,
    @ItemFamilyId       INT,
    @CountryOfOrigin    NVARCHAR(2),
    @DefaultWarehouseId INT,
    @Description        NVARCHAR(1000) = NULL,
    @WarrantyMonths     INT            = NULL,
    @MinQuantity        INT            = 0,
    @MaxQuantity        INT            = NULL,
    @IsBivac            BIT            = 0,
    @IsActive           BIT            = 1,
    @UserId             INT            = NULL,
    @NewId              INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @ItemCode        = LTRIM(RTRIM(@ItemCode));
    SET @ItemName        = LTRIM(RTRIM(@ItemName));
    SET @Model           = NULLIF(LTRIM(RTRIM(@Model)), N'');
    SET @CountryOfOrigin = UPPER(LTRIM(RTRIM(@CountryOfOrigin)));
    SET @Description     = NULLIF(LTRIM(RTRIM(@Description)), N'');
    SET @MinQuantity     = ISNULL(@MinQuantity, 0);
    SET @IsBivac         = ISNULL(@IsBivac, 0);
    SET @IsActive        = ISNULL(@IsActive, 1);

    IF @ItemCode IS NULL OR @ItemCode = N'' THROW 56000, 'Item Code is required.', 1;
    IF @ItemName IS NULL OR @ItemName = N'' THROW 56000, 'Item Name is required.', 1;
    IF @CountryOfOrigin IS NULL OR LEN(@CountryOfOrigin) <> 2 OR @CountryOfOrigin LIKE N'%[^A-Z]%'
        THROW 56000, 'Country of Origin is required (2-letter ISO code).', 1;
    IF @WarrantyMonths IS NOT NULL AND @WarrantyMonths < 0 THROW 56000, 'Warranty cannot be negative.', 1;
    IF @MinQuantity < 0 THROW 56000, 'Minimum Quantity cannot be negative.', 1;
    IF @MaxQuantity IS NOT NULL AND @MaxQuantity < @MinQuantity
        THROW 56000, 'Minimum Quantity cannot exceed Maximum Quantity.', 1;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Brands WHERE Id = @BrandId AND IsActive = 1)
        THROW 56008, 'Brand not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.ItemFamilies WHERE Id = @ItemFamilyId AND IsActive = 1)
        THROW 56008, 'Item Family not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @DefaultWarehouseId AND IsActive = 1)
        THROW 56008, 'Default Warehouse not found or inactive.', 1;
    -- (90) an On the way warehouse holds goods on the road between warehouses: never an item's default
    IF EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @DefaultWarehouseId AND IsTransit = 1)
        THROW 56008, 'An On the way warehouse cannot be an item''s default warehouse: choose a warehouse where stock is kept.', 1;

    IF EXISTS (SELECT 1 FROM inventory.Items WHERE ItemCode = @ItemCode)
        THROW 56001, 'An item with this Item Code already exists.', 1;

    INSERT INTO inventory.Items (ItemCode, ItemName, BrandId, Model, ItemFamilyId, CountryOfOrigin,
                                 DefaultWarehouseId, Description, WarrantyMonths, MinQuantity, MaxQuantity,
                                 IsBivac, IsActive, CreatedBy)
    VALUES (@ItemCode, @ItemName, @BrandId, @Model, @ItemFamilyId, @CountryOfOrigin,
            @DefaultWarehouseId, @Description, @WarrantyMonths, @MinQuantity, @MaxQuantity,
            @IsBivac, @IsActive, @UserId);

    SET @NewId = SCOPE_IDENTITY();
END
GO

-- Re-created (90) from the body of script 11: + an On the way warehouse cannot be the default warehouse (56008).
CREATE OR ALTER PROCEDURE inventory.usp_Item_Update
    @Id                 INT,
    @ItemCode           NVARCHAR(30),
    @ItemName           NVARCHAR(200),
    @BrandId            INT,
    @Model              NVARCHAR(100)  = NULL,
    @ItemFamilyId       INT,
    @CountryOfOrigin    NVARCHAR(2),
    @DefaultWarehouseId INT,
    @Description        NVARCHAR(1000) = NULL,
    @WarrantyMonths     INT            = NULL,
    @MinQuantity        INT            = 0,
    @MaxQuantity        INT            = NULL,
    @IsBivac            BIT            = 0,
    @IsActive           BIT            = 1,
    @RowVersion         BINARY(8)      = NULL,
    @UserId             INT            = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SET @ItemCode        = LTRIM(RTRIM(@ItemCode));
    SET @ItemName        = LTRIM(RTRIM(@ItemName));
    SET @Model           = NULLIF(LTRIM(RTRIM(@Model)), N'');
    SET @CountryOfOrigin = UPPER(LTRIM(RTRIM(@CountryOfOrigin)));
    SET @Description     = NULLIF(LTRIM(RTRIM(@Description)), N'');
    SET @MinQuantity     = ISNULL(@MinQuantity, 0);
    SET @IsBivac         = ISNULL(@IsBivac, 0);
    SET @IsActive        = ISNULL(@IsActive, 1);

    IF NOT EXISTS (SELECT 1 FROM inventory.Items WHERE Id = @Id)
        THROW 56006, 'Item not found.', 1;
    IF @ItemCode IS NULL OR @ItemCode = N'' THROW 56000, 'Item Code is required.', 1;
    IF @ItemName IS NULL OR @ItemName = N'' THROW 56000, 'Item Name is required.', 1;
    IF @CountryOfOrigin IS NULL OR LEN(@CountryOfOrigin) <> 2 OR @CountryOfOrigin LIKE N'%[^A-Z]%'
        THROW 56000, 'Country of Origin is required (2-letter ISO code).', 1;
    IF @WarrantyMonths IS NOT NULL AND @WarrantyMonths < 0 THROW 56000, 'Warranty cannot be negative.', 1;
    IF @MinQuantity < 0 THROW 56000, 'Minimum Quantity cannot be negative.', 1;
    IF @MaxQuantity IS NOT NULL AND @MaxQuantity < @MinQuantity
        THROW 56000, 'Minimum Quantity cannot exceed Maximum Quantity.', 1;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Brands WHERE Id = @BrandId AND IsActive = 1)
        THROW 56008, 'Brand not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.ItemFamilies WHERE Id = @ItemFamilyId AND IsActive = 1)
        THROW 56008, 'Item Family not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @DefaultWarehouseId AND IsActive = 1)
        THROW 56008, 'Default Warehouse not found or inactive.', 1;
    -- (90) an On the way warehouse holds goods on the road between warehouses: never an item's default
    IF EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @DefaultWarehouseId AND IsTransit = 1)
        THROW 56008, 'An On the way warehouse cannot be an item''s default warehouse: choose a warehouse where stock is kept.', 1;

    IF EXISTS (SELECT 1 FROM inventory.Items WHERE ItemCode = @ItemCode AND Id <> @Id)
        THROW 56001, 'An item with this Item Code already exists.', 1;

    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.Items WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 56004, 'This item was modified by another user. Reload the page and try again.', 1;

    UPDATE inventory.Items
    SET ItemCode = @ItemCode, ItemName = @ItemName, BrandId = @BrandId, Model = @Model,
        ItemFamilyId = @ItemFamilyId, CountryOfOrigin = @CountryOfOrigin,
        DefaultWarehouseId = @DefaultWarehouseId, Description = @Description,
        WarrantyMonths = @WarrantyMonths, MinQuantity = @MinQuantity, MaxQuantity = @MaxQuantity,
        IsBivac = @IsBivac, IsActive = @IsActive,
        UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
END
GO

/* ================================================================== 12. Configuration > Document Types: the approval switch */

-- Re-created (90) from the body of script 79: + NeedsApproval (last).
CREATE OR ALTER PROCEDURE inventory.usp_DocumentType_List
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, Code, Name, Family, StockDirection, NumberPrefix, NextNumber, NumberLength, NumberOnPost,
           RequiresReason, DefaultPricing, PriceEditable, NumberPerBranch, YearInNumber, IsActive, UpdatedAtUtc, UpdatedBy, RowVersion,
           BivacItemsOnly,  -- (66) 1 = every line must be a BIVAC item
           -- (79) what the type does; each means something on one type only (the others keep the default)
           AffectsItemCost,       -- PINV: its price becomes the cost of the goods received against it
           AffectsOnHand,         -- PINV: posting it receives its goods with a goods receipt
           AutoCreateOnDelivery,  -- GRN: a completed Delivery movement drafts one per container
           NeedsApproval          -- (90) TRO: a transfer order is approved before it is released
    FROM inventory.DocumentTypes
    ORDER BY Family, Code;
END
GO

-- Re-created (90) from the body of script 79: + @NeedsApproval (NULL = unchanged, refused on a type other than TRO);
-- + A TRANSFER DISPATCH OR RECEIPT IS NUMBERED WHEN IT IS POSTED: there is no draft posting to number at a first save,
-- so Number on post stays on for TRD and TRR. Turning the switch never changes an order already waiting or released.
CREATE OR ALTER PROCEDURE inventory.usp_DocumentType_Update
    @Id              INT,
    @Name            NVARCHAR(100),
    @NumberPrefix    NVARCHAR(10),
    @NumberLength    TINYINT,
    @NumberOnPost    BIT,
    @RequiresReason  BIT,
    @DefaultPricing  NVARCHAR(10),
    @PriceEditable   BIT,
    @NumberPerBranch BIT,
    @IsActive        BIT,
    @RowVersion      BINARY(8) = NULL,
    @UserId          INT       = NULL,
    @YearInNumber    BIT       = NULL,    -- NULL = unchanged
    -- (79) NULL = unchanged (an older form never turns one off); each is refused on a type it does not apply to
    @AffectsItemCost      BIT = NULL,     -- PINV
    @AffectsOnHand        BIT = NULL,     -- PINV
    @AutoCreateOnDelivery BIT = NULL,     -- GRN
    @NeedsApproval        BIT = NULL      -- (90) TRO; NULL = unchanged
AS
BEGIN
    SET NOCOUNT ON;
    SET @Name = NULLIF(LTRIM(RTRIM(@Name)), N'');
    SET @NumberPrefix = NULLIF(LTRIM(RTRIM(@NumberPrefix)), N'');
    IF @Name IS NULL THROW 62000, 'Name is required.', 1;
    IF @NumberPrefix IS NULL THROW 62000, 'Number prefix is required.', 1;
    IF @NumberLength IS NULL OR @NumberLength NOT BETWEEN 3 AND 10 THROW 62000, 'Number length must be between 3 and 10.', 1;
    IF @DefaultPricing NOT IN (N'Cost', N'PriceList', N'None') THROW 62000, 'Default pricing must be Cost, PriceList or None.', 1;
    IF NOT EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Id = @Id) THROW 62006, 'Document type not found.', 1;
    -- (79) a switch belongs to one type: sent for another, it would be stored and read by nothing
    DECLARE @Code NVARCHAR(20) = (SELECT Code FROM inventory.DocumentTypes WHERE Id = @Id);
    IF (@AffectsItemCost IS NOT NULL OR @AffectsOnHand IS NOT NULL) AND @Code <> N'PINV'
        THROW 62000, 'Affects item cost and Affects on-hand apply to the purchase invoice type (PINV) only.', 1;
    IF @AutoCreateOnDelivery IS NOT NULL AND @Code <> N'GRN'
        THROW 62000, 'Create goods receipts on Delivery applies to the goods receipt type (GRN) only.', 1;
    IF @NeedsApproval IS NOT NULL AND @Code <> N'TRO'                                                   -- (90)
        THROW 62000, 'Needs approval before release applies to the transfer order type (TRO) only.', 1;
    IF @Code IN (N'TRD', N'TRR') AND ISNULL(@NumberOnPost, 0) = 0                                      -- (90)
        THROW 62000, 'A transfer dispatch or receipt is numbered when it is posted: Number on post stays on.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 62004, 'This document type was modified by another user. Reload the page and try again.', 1;

    UPDATE inventory.DocumentTypes
    SET Name = @Name, NumberPrefix = @NumberPrefix, NumberLength = @NumberLength, NumberOnPost = ISNULL(@NumberOnPost, 0),
        RequiresReason = ISNULL(@RequiresReason, 0), DefaultPricing = @DefaultPricing, PriceEditable = ISNULL(@PriceEditable, 1),
        NumberPerBranch = ISNULL(@NumberPerBranch, 1), YearInNumber = ISNULL(@YearInNumber, YearInNumber), IsActive = ISNULL(@IsActive, 1),
        AffectsItemCost = ISNULL(@AffectsItemCost, AffectsItemCost), AffectsOnHand = ISNULL(@AffectsOnHand, AffectsOnHand),
        AutoCreateOnDelivery = ISNULL(@AutoCreateOnDelivery, AutoCreateOnDelivery),
        NeedsApproval = ISNULL(@NeedsApproval, NeedsApproval),                                         -- (90)
        UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
END
GO

/* ================================================================== 13. Transfer orders: the list, the page, the draft, its release and its approval (2.3.8.1-2.3.8.12, 2.3.8.21, 2.3.8.22) */

/* The procedures of a transfer order that move no stock: the list, the page and its availability figures, the draft
   (save, details, delete), its release and the approval cycle (approvers, send, approve, reject, withdraw, back to
   draft), the approvers' menu count and the order's files. Dispatch, receipt, close, cancel, reverse, ETA and return
   follow in the next section.

   Every action follows one pattern: the order's header is read first WITH (UPDLOCK, HOLDLOCK) (two users acting on one
   order queue up on it), the RowVersion is checked (skipped when NULL), then the action's first row of
   inventory.fn_TransferOrder_Blocks is thrown as it comes (the page's disabled buttons read the same rows, so a
   refusal and its tooltip can never differ), then the action's own checks, the writes and one audit row.
   Permissions are not checked here (the API hides what a reader may not use), except the approval right, which is the
   decision's own rule and lives in Blocks.

   The import of lines needs no procedure of its own: sales.usp_InvoiceImport_Validate (script 72) already takes
   @DocumentTypeCode N'TRO' - family Inventory, so a blank Unit is the base unit, an exact barcode takes its unit and a
   row naming another type is an Error - with From as the default warehouse, @PriceListId NULL and @CheckStock 0; the
   API refuses the Warehouse and Unit Price columns before it (2.5.5). */

/* 13.1 THE LIST, paged, and a totals row (2 result sets).
   Filters: @Search (the order's number, its reference, From's or To's code or name, the code of an item on one of its
   lines, the number of one of its dispatches or receipts); @Status = a shown status (Draft, PendingApproval, Released,
   PartlyDispatched, Dispatched, PartlyReceived, Received, Closed, Cancelled) or Open (released, neither Received nor
   Closed); @BranchId = From's OR To's branch (a transfer concerns both); From, To; @OnTheWayOnly (pieces on the way),
   @LateOnly (Late, worked out on the server in UTC), @WaitingForApproval (stored status 4: the approvers' list, the
   menu count's); the order date; @ItemId (an order with a line of the item).
   Sort: DocumentNumber | DocumentDate | FromWarehouse | ToWarehouse | Status (in the order of the shown statuses) |
   OrderedBase | OnTheWayBase | ExpectedArrival | CreatedAtUtc.
   1: one row per order (TotalCount = all pages): its figures, shown status and Late from fn_TransferOrder_State, the
      one place they are worked out.
   2: over every order of the filter (all pages): Orders, OnTheWayBase, LateOrders, WaitingForApproval. */
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_Search
    @Search             NVARCHAR(100) = NULL,
    @Status             NVARCHAR(20)  = NULL,
    @BranchId           INT           = NULL,
    @FromWarehouseId    INT           = NULL,
    @ToWarehouseId      INT           = NULL,
    @OnTheWayOnly       BIT           = 0,
    @LateOnly           BIT           = 0,
    @WaitingForApproval BIT           = 0,
    @DateFrom           DATE          = NULL,
    @DateTo             DATE          = NULL,
    @ItemId             INT           = NULL,
    @SortColumn         NVARCHAR(30)  = N'DocumentDate',
    @SortDirection      NVARCHAR(4)   = N'DESC',
    @PageNumber         INT           = 1,
    @PageSize           INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 25;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @Status = NULLIF(LTRIM(RTRIM(@Status)), N'');
    IF @Status IS NOT NULL AND @Status NOT IN (N'Draft', N'PendingApproval', N'Released', N'PartlyDispatched', N'Dispatched',
                                               N'PartlyReceived', N'Received', N'Closed', N'Cancelled', N'Open')
        THROW 62000, 'The status filter is Draft, PendingApproval, Released, PartlyDispatched, Dispatched, PartlyReceived, Received, Closed, Cancelled or Open.', 1;
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'DocumentNumber', N'DocumentDate', N'FromWarehouse', N'ToWarehouse', N'Status',
                                                  N'OrderedBase', N'OnTheWayBase', N'ExpectedArrival', N'CreatedAtUtc')
        SET @SortColumn = N'DocumentDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);
    SELECT @OnTheWayOnly = ISNULL(@OnTheWayOnly, 0), @LateOnly = ISNULL(@LateOnly, 0), @WaitingForApproval = ISNULL(@WaitingForApproval, 0);

    -- THE FILTER ONCE, with each order's state: the shown status, Late and On the way are filters, so the state is
    -- worked out before the page, and the page and the totals both read it from here.
    DECLARE @Ids TABLE
    (
        Id             INT          NOT NULL PRIMARY KEY,
        StoredStatus   TINYINT      NOT NULL,
        DisplayStatus  NVARCHAR(20) NULL,
        StatusRank     INT          NOT NULL,
        IsLate         BIT          NOT NULL,
        ItemCount      INT          NOT NULL,
        OrderedBase    INT          NOT NULL,
        DispatchedBase INT          NOT NULL,
        ReceivedBase   INT          NOT NULL,
        OnTheWayBase   INT          NOT NULL,
        ToDispatchBase INT          NOT NULL,
        NotSentBase    INT          NOT NULL,
        LostBase       INT          NOT NULL
    );
    INSERT INTO @Ids (Id, StoredStatus, DisplayStatus, StatusRank, IsLate, ItemCount, OrderedBase, DispatchedBase, ReceivedBase,
                      OnTheWayBase, ToDispatchBase, NotSentBase, LostBase)
    SELECT o.Id, o.Status, st.DisplayStatus,
           CASE st.DisplayStatus WHEN N'Draft' THEN 1 WHEN N'PendingApproval' THEN 2 WHEN N'Released' THEN 3
                                 WHEN N'PartlyDispatched' THEN 4 WHEN N'Dispatched' THEN 5 WHEN N'PartlyReceived' THEN 6
                                 WHEN N'Received' THEN 7 WHEN N'Closed' THEN 8 ELSE 9 END,
           CAST(ISNULL(st.IsLate, 0) AS BIT), ISNULL(st.ItemCount, 0), ISNULL(st.OrderedBase, 0), ISNULL(st.DispatchedBase, 0),
           ISNULL(st.ReceivedBase, 0), ISNULL(st.OnTheWayBase, 0), ISNULL(st.ToDispatchBase, 0), ISNULL(st.NotSentBase, 0),
           ISNULL(st.LostBase, 0)
    FROM inventory.TransferOrders o
    INNER JOIN masterdata.Warehouses fw ON fw.Id = o.FromWarehouseId
    INNER JOIN masterdata.Warehouses tw ON tw.Id = o.ToWarehouseId
    OUTER APPLY inventory.fn_TransferOrder_State(o.Id) st
    WHERE (@BranchId IS NULL OR fw.BranchId = @BranchId OR tw.BranchId = @BranchId)
      AND (@FromWarehouseId IS NULL OR o.FromWarehouseId = @FromWarehouseId)
      AND (@ToWarehouseId IS NULL OR o.ToWarehouseId = @ToWarehouseId)
      AND (@DateFrom IS NULL OR o.DocumentDate >= @DateFrom)
      AND (@DateTo IS NULL OR o.DocumentDate <= @DateTo)
      AND (@WaitingForApproval = 0 OR o.Status = 4)
      AND (@ItemId IS NULL OR EXISTS (SELECT 1 FROM inventory.TransferOrderLines l WHERE l.TransferOrderId = o.Id AND l.ItemId = @ItemId))
      AND (@Status IS NULL
           OR (@Status = N'Open' AND o.Status = 2 AND ISNULL(st.DisplayStatus, N'') NOT IN (N'Received', N'Closed'))
           OR st.DisplayStatus = @Status)
      AND (@OnTheWayOnly = 0 OR st.OnTheWayBase > 0)
      AND (@LateOnly = 0 OR st.IsLate = 1)
      AND (@Search IS NULL
           OR o.DocumentNumber LIKE N'%' + @Search + N'%' OR o.ReferenceNo LIKE N'%' + @Search + N'%'
           OR fw.WarehouseCode LIKE N'%' + @Search + N'%' OR fw.WarehouseName LIKE N'%' + @Search + N'%'
           OR tw.WarehouseCode LIKE N'%' + @Search + N'%' OR tw.WarehouseName LIKE N'%' + @Search + N'%'
           OR EXISTS (SELECT 1 FROM inventory.TransferOrderLines l
                      INNER JOIN inventory.Items i ON i.Id = l.ItemId
                      WHERE l.TransferOrderId = o.Id AND i.ItemCode LIKE N'%' + @Search + N'%')
           OR EXISTS (SELECT 1 FROM inventory.TransferPostings p
                      WHERE p.TransferOrderId = o.Id AND p.DocumentNumber LIKE N'%' + @Search + N'%'));

    -- 1: the page
    SELECT o.Id, o.DocumentNumber, o.DocumentDate, o.BranchId, b.BranchCode,
           o.FromWarehouseId, FromWarehouseCode = fw.WarehouseCode, FromWarehouseName = fw.WarehouseName, FromBranchCode = fb.BranchCode,
           o.ToWarehouseId, ToWarehouseCode = tw.WarehouseCode, ToWarehouseName = tw.WarehouseName, ToBranchCode = tb.BranchCode,
           StatusCode = CASE o.Status WHEN 1 THEN N'Draft' WHEN 2 THEN N'Released' WHEN 3 THEN N'Cancelled' ELSE N'PendingApproval' END,
           x.DisplayStatus, x.IsLate, x.ItemCount, x.OrderedBase, x.DispatchedBase, x.ReceivedBase, x.OnTheWayBase,
           x.ToDispatchBase, x.NotSentBase, x.LostBase,
           o.ExpectedArrival, o.ReferenceNo, o.ReturnOfOrderId, ReturnOfNumber = ro.DocumentNumber,
           o.CreatedAtUtc, CreatedByName = cu.FullName,
           COUNT(*) OVER () AS TotalCount
    FROM @Ids x
    INNER JOIN inventory.TransferOrders o   ON o.Id = x.Id
    INNER JOIN masterdata.Branches b        ON b.Id = o.BranchId
    INNER JOIN masterdata.Warehouses fw     ON fw.Id = o.FromWarehouseId
    INNER JOIN masterdata.Branches fb       ON fb.Id = fw.BranchId
    INNER JOIN masterdata.Warehouses tw     ON tw.Id = o.ToWarehouseId
    INNER JOIN masterdata.Branches tb       ON tb.Id = tw.BranchId
    LEFT  JOIN inventory.TransferOrders ro  ON ro.Id = o.ReturnOfOrderId
    LEFT  JOIN security.Users cu            ON cu.Id = o.CreatedBy
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN o.DocumentNumber WHEN N'FromWarehouse' THEN fw.WarehouseCode
                             WHEN N'ToWarehouse' THEN tw.WarehouseCode END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN o.DocumentNumber WHEN N'FromWarehouse' THEN fw.WarehouseCode
                             WHEN N'ToWarehouse' THEN tw.WarehouseCode END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'DocumentDate' THEN o.DocumentDate END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'DocumentDate' THEN o.DocumentDate END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Status' THEN x.StatusRank END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Status' THEN x.StatusRank END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'OrderedBase' THEN x.OrderedBase END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'OrderedBase' THEN x.OrderedBase END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'OnTheWayBase' THEN x.OnTheWayBase END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'OnTheWayBase' THEN x.OnTheWayBase END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'ExpectedArrival' THEN o.ExpectedArrival END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'ExpectedArrival' THEN o.ExpectedArrival END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN o.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN o.CreatedAtUtc END DESC,
        o.DocumentDate DESC, o.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;

    -- 2: totals over the whole filter (the list's summary row)
    SELECT Orders             = COUNT(*),
           OnTheWayBase       = ISNULL(SUM(x.OnTheWayBase), 0),
           LateOrders         = ISNULL(SUM(CASE WHEN x.IsLate = 1 THEN 1 ELSE 0 END), 0),
           WaitingForApproval = ISNULL(SUM(CASE WHEN x.StoredStatus = 4 THEN 1 ELSE 0 END), 0)
    FROM @Ids x;
END
GO

/* 13.2 ONE TRANSFER ORDER, 6 result sets (none with rows when the id is unknown; the API answers 404):
     1 header: every column; the order's branch, From and To with their branches; the TRO type's NeedsApproval and
       NumberOnPost; the names behind every stamp; ReturnOfNumber; the figures, shown status and Late of
       fn_TransferOrder_State; OnTheWayValueBase (the pieces on the way at the cost frozen at their dispatch); per
       action Can{Action} and {Action}BlockedReason (the first row of fn_TransferOrder_Blocks: the reason the action
       would be refused with, NULL = allowed), and CanEditExpectedArrival / EditExpectedArrivalBlockedReason (rule T9:
       only the notes change on a received, closed or cancelled order)
     2 lines: item, unit, Ordered (in the unit and in pcs), the counters, To dispatch, On the way, and where From and To
       stand with transfers (fn_TransferPosition, this order left out): on hand at From, what the other released
       orders still take from it, available (never below 0); on hand at To, what released orders still bring to it
     3 dispatches and receipts in the order they were posted, each with its own Reverse and Change ETA answers
     4 their lines (a receipt line names the dispatch it receives)
     5 audit, newest first
     6 the returns of this order
   @UserId: the reader, for the approval right of Release / Approve / Reject (Blocks). */
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_Get
    @Id     INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Today DATE = CAST(SYSUTCDATETIME() AS DATE);

    -- THE REFUSALS OF EVERY ACTION, read once: the first row (lowest Seq) of an action is its reason.
    DECLARE @B TABLE (Action NVARCHAR(30) NOT NULL PRIMARY KEY, Message NVARCHAR(400) NOT NULL);
    INSERT INTO @B (Action, Message)
    SELECT k.Action, k.Message
    FROM (SELECT b.Action, b.Message, Rn = ROW_NUMBER() OVER (PARTITION BY b.Action ORDER BY b.Seq)
          FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
          WHERE b.Message IS NOT NULL) k
    WHERE k.Rn = 1;

    -- The three order-level answers of the postings, computed once (92 adds its access rows to them).
    DECLARE @ReverseDispatch NVARCHAR(400) = (SELECT Message FROM @B WHERE Action = N'ReverseDispatch'),
            @ReverseReceipt  NVARCHAR(400) = (SELECT Message FROM @B WHERE Action = N'ReverseReceipt'),
            @ChangeEta       NVARCHAR(400) = (SELECT Message FROM @B WHERE Action = N'ChangeEta');

    -- 1: header
    SELECT o.Id, o.DocumentTypeId, o.DocumentNumber, o.DocumentDate,
           o.BranchId, b.BranchCode, b.BranchName,
           o.FromWarehouseId, FromWarehouseCode = fw.WarehouseCode, FromWarehouseName = fw.WarehouseName,
           FromBranchId = fw.BranchId, FromBranchCode = fb.BranchCode, FromBranchName = fb.BranchName,
           o.ToWarehouseId, ToWarehouseCode = tw.WarehouseCode, ToWarehouseName = tw.WarehouseName,
           ToBranchId = tw.BranchId, ToBranchCode = tb.BranchCode, ToBranchName = tb.BranchName,
           o.ExpectedArrival, o.ReferenceNo, o.Notes,
           o.Status, StatusCode = CASE o.Status WHEN 1 THEN N'Draft' WHEN 2 THEN N'Released' WHEN 3 THEN N'Cancelled' ELSE N'PendingApproval' END,
           o.ReturnOfOrderId, ReturnOfNumber = ro.DocumentNumber,
           o.TotalLines, o.TotalOrderedBase,
           o.ApprovalRequestedAtUtc, o.ApprovalRequestedBy, ApprovalRequestedByName = rqu.FullName,
           o.ApprovedAtUtc, o.ApprovedBy, ApprovedByName = apu.FullName, o.ApprovedDirectly,
           o.RejectedAtUtc, o.RejectedBy, RejectedByName = rju.FullName, o.RejectReason,
           o.ReleasedAtUtc, o.ReleasedBy, ReleasedByName = rlu.FullName,
           o.NotSentAtUtc, o.NotSentBy, NotSentByName = nsu.FullName, o.NotSentReason,
           o.CancelledAtUtc, o.CancelledBy, CancelledByName = cxu.FullName, o.CancelReason,
           o.CreatedAtUtc, o.CreatedBy, CreatedByName = cu.FullName, o.UpdatedAtUtc, o.UpdatedBy, UpdatedByName = uu.FullName,
           NeedsApproval = dt.NeedsApproval, NumberOnPost = dt.NumberOnPost,
           OrderedBase    = ISNULL(st.OrderedBase, 0),    DispatchedBase = ISNULL(st.DispatchedBase, 0),
           ReceivedBase   = ISNULL(st.ReceivedBase, 0),   LostBase       = ISNULL(st.LostBase, 0),
           NotSentBase    = ISNULL(st.NotSentBase, 0),    ToDispatchBase = ISNULL(st.ToDispatchBase, 0),
           OnTheWayBase   = ISNULL(st.OnTheWayBase, 0),   ItemCount      = ISNULL(st.ItemCount, 0),
           LateDispatches = ISNULL(st.LateDispatches, 0), IsLate         = CAST(ISNULL(st.IsLate, 0) AS BIT),
           st.DisplayStatus,
           OnTheWayValueBase = CAST(ISNULL(v.Value, 0) AS DECIMAL(18,2)),
           CanEdit               = CAST(CASE WHEN k.EditR               IS NULL THEN 1 ELSE 0 END AS BIT), EditBlockedReason               = k.EditR,
           CanDelete             = CAST(CASE WHEN k.DeleteR             IS NULL THEN 1 ELSE 0 END AS BIT), DeleteBlockedReason             = k.DeleteR,
           CanRelease            = CAST(CASE WHEN k.ReleaseR            IS NULL THEN 1 ELSE 0 END AS BIT), ReleaseBlockedReason            = k.ReleaseR,
           CanSendForApproval    = CAST(CASE WHEN k.SendForApprovalR    IS NULL THEN 1 ELSE 0 END AS BIT), SendForApprovalBlockedReason    = k.SendForApprovalR,
           CanApprove            = CAST(CASE WHEN k.ApproveR            IS NULL THEN 1 ELSE 0 END AS BIT), ApproveBlockedReason            = k.ApproveR,
           CanReject             = CAST(CASE WHEN k.RejectR             IS NULL THEN 1 ELSE 0 END AS BIT), RejectBlockedReason             = k.RejectR,
           CanWithdraw           = CAST(CASE WHEN k.WithdrawR           IS NULL THEN 1 ELSE 0 END AS BIT), WithdrawBlockedReason           = k.WithdrawR,
           CanBackToDraft        = CAST(CASE WHEN k.BackToDraftR        IS NULL THEN 1 ELSE 0 END AS BIT), BackToDraftBlockedReason        = k.BackToDraftR,
           CanDispatch           = CAST(CASE WHEN k.DispatchR           IS NULL THEN 1 ELSE 0 END AS BIT), DispatchBlockedReason           = k.DispatchR,
           CanReceive            = CAST(CASE WHEN k.ReceiveR            IS NULL THEN 1 ELSE 0 END AS BIT), ReceiveBlockedReason            = k.ReceiveR,
           CanDispatchAndReceive = CAST(CASE WHEN k.DispatchAndReceiveR IS NULL THEN 1 ELSE 0 END AS BIT), DispatchAndReceiveBlockedReason = k.DispatchAndReceiveR,
           CanNothingMoreSent    = CAST(CASE WHEN k.NothingMoreSentR    IS NULL THEN 1 ELSE 0 END AS BIT), NothingMoreSentBlockedReason    = k.NothingMoreSentR,
           CanCancel             = CAST(CASE WHEN k.CancelR             IS NULL THEN 1 ELSE 0 END AS BIT), CancelBlockedReason             = k.CancelR,
           CanCreateReturn       = CAST(CASE WHEN k.CreateReturnR       IS NULL THEN 1 ELSE 0 END AS BIT), CreateReturnBlockedReason       = k.CreateReturnR,
           CanUpdateDetails      = CAST(CASE WHEN k.UpdateDetailsR      IS NULL THEN 1 ELSE 0 END AS BIT), UpdateDetailsBlockedReason      = k.UpdateDetailsR,
           CanEditExpectedArrival = CAST(CASE WHEN ea.Reason IS NULL THEN 1 ELSE 0 END AS BIT), EditExpectedArrivalBlockedReason = ea.Reason,
           o.RowVersion
    FROM inventory.TransferOrders o
    INNER JOIN inventory.DocumentTypes dt   ON dt.Id = o.DocumentTypeId
    INNER JOIN masterdata.Branches b        ON b.Id = o.BranchId
    INNER JOIN masterdata.Warehouses fw     ON fw.Id = o.FromWarehouseId
    INNER JOIN masterdata.Branches fb       ON fb.Id = fw.BranchId
    INNER JOIN masterdata.Warehouses tw     ON tw.Id = o.ToWarehouseId
    INNER JOIN masterdata.Branches tb       ON tb.Id = tw.BranchId
    LEFT  JOIN inventory.TransferOrders ro  ON ro.Id = o.ReturnOfOrderId
    LEFT  JOIN security.Users rqu ON rqu.Id = o.ApprovalRequestedBy
    LEFT  JOIN security.Users apu ON apu.Id = o.ApprovedBy
    LEFT  JOIN security.Users rju ON rju.Id = o.RejectedBy
    LEFT  JOIN security.Users rlu ON rlu.Id = o.ReleasedBy
    LEFT  JOIN security.Users nsu ON nsu.Id = o.NotSentBy
    LEFT  JOIN security.Users cxu ON cxu.Id = o.CancelledBy
    LEFT  JOIN security.Users cu  ON cu.Id  = o.CreatedBy
    LEFT  JOIN security.Users uu  ON uu.Id  = o.UpdatedBy
    OUTER APPLY inventory.fn_TransferOrder_State(o.Id) st
    -- the pieces on the way, at the cost frozen on their dispatch line (information: a transfer moves no cost)
    OUTER APPLY (SELECT Value = ROUND(SUM(CAST(dl.QuantityBase - dl.SettledBase AS DECIMAL(18,6)) * ISNULL(dl.UnitCostBase, 0)), 2)
                 FROM inventory.TransferPostingLines dl
                 INNER JOIN inventory.TransferPostings p ON p.Id = dl.PostingId
                 WHERE p.TransferOrderId = o.Id AND p.Kind = N'Dispatch' AND p.Status = 2 AND dl.QuantityBase > dl.SettledBase) v
    CROSS APPLY (SELECT EditR               = MAX(CASE WHEN a.Action = N'Edit'               THEN a.Message END),
                        DeleteR             = MAX(CASE WHEN a.Action = N'Delete'             THEN a.Message END),
                        ReleaseR            = MAX(CASE WHEN a.Action = N'Release'            THEN a.Message END),
                        SendForApprovalR    = MAX(CASE WHEN a.Action = N'SendForApproval'    THEN a.Message END),
                        ApproveR            = MAX(CASE WHEN a.Action = N'Approve'            THEN a.Message END),
                        RejectR             = MAX(CASE WHEN a.Action = N'Reject'             THEN a.Message END),
                        WithdrawR           = MAX(CASE WHEN a.Action = N'Withdraw'           THEN a.Message END),
                        BackToDraftR        = MAX(CASE WHEN a.Action = N'BackToDraft'        THEN a.Message END),
                        DispatchR           = MAX(CASE WHEN a.Action = N'Dispatch'           THEN a.Message END),
                        ReceiveR            = MAX(CASE WHEN a.Action = N'Receive'            THEN a.Message END),
                        DispatchAndReceiveR = MAX(CASE WHEN a.Action = N'DispatchAndReceive' THEN a.Message END),
                        NothingMoreSentR    = MAX(CASE WHEN a.Action = N'NothingMoreSent'    THEN a.Message END),
                        CancelR             = MAX(CASE WHEN a.Action = N'Cancel'             THEN a.Message END),
                        CreateReturnR       = MAX(CASE WHEN a.Action = N'CreateReturn'       THEN a.Message END),
                        UpdateDetailsR      = MAX(CASE WHEN a.Action = N'UpdateDetails'      THEN a.Message END)
                 FROM @B a) k
    -- (T9) Expected arrival and Reference No. stay editable on a released order until it is received or closed
    CROSS APPLY (SELECT Reason = CASE WHEN o.Status = 3 OR st.DisplayStatus IN (N'Received', N'Closed')
                                      THEN N'Only the notes can change on a received, closed or cancelled transfer order.'
                                      ELSE k.UpdateDetailsR END) ea
    WHERE o.Id = @Id;

    -- 2: lines, and where From and To stand with transfers (this order left out)
    SELECT l.Id, l.LineNumber, l.ItemId, i.ItemCode, i.ItemName, ItemIsActive = i.IsActive,
           l.ItemUnitId, UnitName = ut.UnitTypeName, iu.IsBaseUnit, l.Quantity, l.PackingFormula, l.OrderedBase,
           l.DispatchedBase, l.ReceivedBase, l.LostBase, l.NotSentBase,
           ToDispatchBase = CASE WHEN l.OrderedBase - l.DispatchedBase - l.NotSentBase > 0
                                 THEN l.OrderedBase - l.DispatchedBase - l.NotSentBase ELSE 0 END,
           OnTheWayBase   = l.DispatchedBase - l.ReceivedBase - l.LostBase,
           l.Notes,
           OnHandFromBase    = ISNULL(pf.OnHandBase, 0),
           CommittedFromBase = ISNULL(pf.OutToDispatchBase, 0),
           AvailableFromBase = CASE WHEN pf.OnHandBase - pf.OutToDispatchBase > 0 THEN pf.OnHandBase - pf.OutToDispatchBase ELSE 0 END,
           OnHandToBase      = ISNULL(pt.OnHandBase, 0),
           IncomingToBase    = ISNULL(pt.InOnTheWayBase + pt.InToDispatchBase, 0)
    FROM inventory.TransferOrderLines l
    INNER JOIN inventory.TransferOrders o ON o.Id = l.TransferOrderId
    INNER JOIN inventory.Items i          ON i.Id = l.ItemId
    INNER JOIN inventory.ItemUnits iu     ON iu.Id = l.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut    ON ut.Id = iu.UnitTypeId
    OUTER APPLY inventory.fn_TransferPosition(l.ItemId, o.FromWarehouseId, @Id) pf
    OUTER APPLY inventory.fn_TransferPosition(l.ItemId, o.ToWarehouseId, @Id) pt
    WHERE l.TransferOrderId = @Id
    ORDER BY l.LineNumber;

    -- 3: dispatches and receipts. Reverse: the order-level answer (Blocks) first, then the posting's own
    --    (fn_TransferPosting_ReverseBlock). Change ETA: the order-level answer, then "a dispatch with goods on the way".
    SELECT p.Id, p.Kind, DocumentTypeCode = pdt.Code, p.DocumentNumber, p.PostingDate, p.Eta, p.ReferenceNo, p.Notes,
           StatusCode = CASE p.Status WHEN 2 THEN N'Posted' ELSE N'Reversed' END,
           p.TransitWarehouseId, TransitWarehouseCode = xw.WarehouseCode, TransitWarehouseName = xw.WarehouseName,
           BranchCode = pb.BranchCode, p.PostedWithId, PostedWithNumber = pw.DocumentNumber,
           p.TotalQuantityBase, p.TotalLostBase,
           OnTheWayBase = ISNULL(w.OnTheWay, 0),
           IsLate = CAST(CASE WHEN p.Kind = N'Dispatch' AND p.Status = 2 AND ISNULL(w.OnTheWay, 0) > 0 AND p.Eta < @Today THEN 1 ELSE 0 END AS BIT),
           p.ValueBase, p.LostValueBase,
           p.PostedAtUtc, PostedByName = pu.FullName,
           p.ReverseDate, p.ReversedAtUtc, ReversedByName = ru.FullName, p.ReverseReason,
           CanReverse   = CAST(CASE WHEN r.Reason IS NULL THEN 1 ELSE 0 END AS BIT), ReverseBlockedReason   = r.Reason,
           CanChangeEta = CAST(CASE WHEN e.Reason IS NULL THEN 1 ELSE 0 END AS BIT), ChangeEtaBlockedReason = e.Reason
    FROM inventory.TransferPostings p
    INNER JOIN inventory.DocumentTypes pdt      ON pdt.Id = p.DocumentTypeId
    INNER JOIN masterdata.Branches pb           ON pb.Id = p.BranchId
    LEFT  JOIN masterdata.Warehouses xw         ON xw.Id = p.TransitWarehouseId
    LEFT  JOIN inventory.TransferPostings pw    ON pw.Id = p.PostedWithId
    LEFT  JOIN security.Users pu                ON pu.Id = p.PostedBy
    LEFT  JOIN security.Users ru                ON ru.Id = p.ReversedBy
    -- on the way of a dispatch: its lines' sent - settled while it is posted, 0 once reversed (a receipt: 0)
    OUTER APPLY (SELECT OnTheWay = SUM(dl.QuantityBase - dl.SettledBase)
                 FROM inventory.TransferPostingLines dl
                 WHERE dl.PostingId = p.Id AND p.Kind = N'Dispatch' AND p.Status = 2) w
    OUTER APPLY (SELECT TOP (1) q.Message FROM inventory.fn_TransferPosting_ReverseBlock(p.Id) q
                 WHERE q.Message IS NOT NULL ORDER BY q.Seq) rb
    CROSS APPLY (SELECT Reason = COALESCE(CASE WHEN p.Kind = N'Dispatch' THEN @ReverseDispatch ELSE @ReverseReceipt END, rb.Message)) r
    CROSS APPLY (SELECT Reason = COALESCE(@ChangeEta,
                                          CASE WHEN NOT (p.Kind = N'Dispatch' AND p.Status = 2 AND ISNULL(w.OnTheWay, 0) > 0)
                                               THEN N'Only a dispatch with goods on the way can change its ETA.' END)) e
    WHERE p.TransferOrderId = @Id
    ORDER BY p.PostedAtUtc, p.Id;

    -- 4: their lines
    SELECT pl.Id, pl.PostingId, pl.LineNumber, pl.TransferOrderLineId, OrderLineNumber = ol.LineNumber,
           pl.ItemId, i.ItemCode, i.ItemName,
           pl.QuantityBase, pl.LostBase, pl.LossReasonCode, pl.LossNote, pl.SettledBase,
           OnTheWayBase = CASE WHEN p.Kind = N'Dispatch' AND p.Status = 2 THEN pl.QuantityBase - pl.SettledBase ELSE 0 END,
           pl.DispatchLineId, DispatchNumber = dp.DocumentNumber,
           pl.UnitCostBase, pl.LossUnitCostBase
    FROM inventory.TransferPostingLines pl
    INNER JOIN inventory.TransferPostings p         ON p.Id = pl.PostingId
    INNER JOIN inventory.TransferOrderLines ol      ON ol.Id = pl.TransferOrderLineId
    INNER JOIN inventory.Items i                    ON i.Id = pl.ItemId
    LEFT  JOIN inventory.TransferPostingLines dl    ON dl.Id = pl.DispatchLineId
    LEFT  JOIN inventory.TransferPostings dp        ON dp.Id = dl.PostingId
    WHERE p.TransferOrderId = @Id
    ORDER BY p.PostedAtUtc, p.Id, pl.LineNumber;

    -- 5: audit
    SELECT a.Id, a.PostingId, a.Action, a.Details, a.UserId, UserName = u.FullName, a.AtUtc
    FROM inventory.TransferOrderAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.TransferOrderId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;

    -- 6: the returns of this order (new orders in the other direction, 2.3.8.20)
    SELECT r.Id, r.DocumentNumber, r.DocumentDate,
           StatusCode = CASE r.Status WHEN 1 THEN N'Draft' WHEN 2 THEN N'Released' WHEN 3 THEN N'Cancelled' ELSE N'PendingApproval' END,
           rs.DisplayStatus
    FROM inventory.TransferOrders r
    OUTER APPLY inventory.fn_TransferOrder_State(r.Id) rs
    WHERE r.ReturnOfOrderId = @Id
    ORDER BY r.Id;
END
GO

/* 13.3 WHAT FROM HOLDS AND TO EXPECTS, per item, for a draft's lines (re-asked by the page when an item, From or To
   changes): the five figures of the Get's lines, from the same fn_TransferPosition (one formula, M6). Information
   only: Release reserves nothing (FB rule 16), the dispatch checks the real stock. @ExcludeOrderId = the draft being
   edited, so its own lines are never counted against it. Asked for the pair a draft can hold only (62000 otherwise, in
   Save's words): two different warehouses that exist, neither an On the way warehouse - an inactive one is answered (a
   draft may still hold it). */
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_Availability
    @FromWarehouseId INT,
    @ToWarehouseId   INT,
    @ItemIds         logistics.tvp_IdList READONLY,
    @ExcludeOrderId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @m NVARCHAR(400);
    IF @FromWarehouseId = @ToWarehouseId
        THROW 62000, 'The destination must differ from the source.', 1;
    SELECT TOP (1) @m = CASE WHEN w.Id IS NULL THEN N'The warehouse was not found.'
                             ELSE w.WarehouseCode + N' is an On the way warehouse: it holds goods travelling between warehouses and cannot be chosen.' END
    FROM (VALUES (1, @FromWarehouseId), (2, @ToWarehouseId)) s (Side, WarehouseId)
    LEFT JOIN masterdata.Warehouses w ON w.Id = s.WarehouseId
    WHERE w.Id IS NULL OR w.IsTransit = 1
    ORDER BY s.Side;
    IF @m IS NOT NULL THROW 62000, @m, 1;

    SELECT ItemId            = x.Id,
           OnHandFromBase    = ISNULL(pf.OnHandBase, 0),
           CommittedFromBase = ISNULL(pf.OutToDispatchBase, 0),
           AvailableFromBase = CASE WHEN pf.OnHandBase - pf.OutToDispatchBase > 0 THEN pf.OnHandBase - pf.OutToDispatchBase ELSE 0 END,
           OnHandToBase      = ISNULL(pt.OnHandBase, 0),
           IncomingToBase    = ISNULL(pt.InOnTheWayBase + pt.InToDispatchBase, 0)
    FROM @ItemIds x
    OUTER APPLY inventory.fn_TransferPosition(x.Id, @FromWarehouseId, @ExcludeOrderId) pf
    OUTER APPLY inventory.fn_TransferPosition(x.Id, @ToWarehouseId, @ExcludeOrderId) pt
    ORDER BY x.Id;
END
GO

/* 13.4 SAVE A DRAFT: creates one, or replaces an existing draft, lines and all (the lines may be empty on a draft).
   The checks, in order (62000 unless said): the TRO type is active (62008); an existing order is still editable
   (Blocks, Edit: a draft); the order date (required, at most one day ahead: the reader's time zone); the warehouses
   (inventory.usp_TransferOrder_CheckWarehouses: the one place of those rules); Expected arrival not before the order
   date; each line by line number (item, active, its unit, Ordered above 0).
   The order's branch follows From at every save (D2); the NUMBER is given at the first save by From's branch when the
   TRO type numbers documents at their first save (NumberOnPost 0), else at release, and then keeps the branch it got.
   Each line keeps its unit's packing formula of the moment it is saved (Ordered in pcs never changes under it). No
   result set: @NewId = the order. */
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_Save
    @Id              INT            = NULL,
    @DocumentDate    DATE,
    @FromWarehouseId INT,
    @ToWarehouseId   INT,
    @ExpectedArrival DATE           = NULL,
    @ReferenceNo     NVARCHAR(100)  = NULL,
    @Notes           NVARCHAR(1000) = NULL,
    @Lines           inventory.tvp_TransferOrderLine READONLY,
    @RowVersion      BINARY(8)      = NULL,
    @UserId          INT            = NULL,
    @NewId           INT            = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @ReferenceNo = NULLIF(LTRIM(RTRIM(@ReferenceNo)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');

    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @Status TINYINT, @TypeId INT, @TypeActive BIT, @NumberOnPost BIT,
            @BranchId INT, @Number NVARCHAR(30), @LineCount INT, @Pcs INT,
            @Tomorrow DATE = DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE));

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Id IS NOT NULL
        BEGIN
            SELECT @Status = Status, @Number = DocumentNumber
            FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
            IF @Status IS NOT NULL AND @RowVersion IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id AND RowVersion = @RowVersion)
                THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;
        END

        -- 1. The type: switched off, no order is saved (the sentence of Blocks Seq 33)
        SELECT @TypeId = Id, @TypeActive = IsActive, @NumberOnPost = NumberOnPost FROM inventory.DocumentTypes WHERE Code = N'TRO';
        IF @TypeId IS NULL THROW 62008, 'The document type TRO is missing: restart the API so that script 90 creates it.', 1;
        IF @TypeActive = 0
        BEGIN
            SET @Msg = N'Transfer orders are switched off: the document type TRO is inactive (Configuration ' + NCHAR(8250) + N' Document Types).';
            THROW 62008, @Msg, 1;
        END

        -- 2. An existing order: only a draft is saved (Blocks, Edit; an unknown id is its Seq 1, "not found")
        IF @Id IS NOT NULL
        BEGIN
            SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
            FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
            WHERE b.Action = N'Edit' AND b.Message IS NOT NULL
            ORDER BY b.Seq;
            IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;
        END

        -- 3. The order date (one day of tolerance ahead: the reader's time zone)
        IF @DocumentDate IS NULL THROW 62000, 'Order date is required.', 1;
        IF @DocumentDate > @Tomorrow THROW 62000, 'The order date cannot be in the future.', 1;

        -- 4. From and To
        EXEC inventory.usp_TransferOrder_CheckWarehouses @FromWarehouseId, @ToWarehouseId;

        -- 5. Expected arrival
        IF @ExpectedArrival < @DocumentDate THROW 62000, 'Expected arrival cannot be before the order date.', 1;

        -- 6. The lines, the first failing by line number
        SET @Msg = NULL;
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' +
               CASE WHEN i.Id IS NULL       THEN N'item not found.'
                    WHEN i.IsActive = 0     THEN N'item ' + i.ItemCode + N' is inactive.'
                    WHEN iu.Id IS NULL      THEN N'the unit does not belong to item ' + i.ItemCode + N'.'
                    WHEN l.Quantity <= 0    THEN N'Ordered must be a whole number above 0.'
                    ELSE N'Ordered is too large.' END        -- Ordered in pcs above an INT (never typed in practice)
        FROM @Lines l
        LEFT JOIN inventory.Items i      ON i.Id = l.ItemId
        LEFT JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId AND iu.ItemId = l.ItemId
        WHERE i.Id IS NULL OR i.IsActive = 0 OR iu.Id IS NULL OR l.Quantity <= 0
           OR CAST(l.Quantity AS BIGINT) * iu.PackingFormula > 2147483647
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 62000, @Msg, 1;
        -- the order's total in pcs is an INT too (lines each within it can add up past it)
        IF (SELECT SUM(CAST(l.Quantity AS BIGINT) * iu.PackingFormula) FROM @Lines l
            INNER JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId AND iu.ItemId = l.ItemId) > 2147483647
            THROW 62000, 'The order is too large: its lines add up to more pieces than can be counted. Split it into several orders.', 1;

        -- The writes
        SELECT @BranchId = BranchId FROM masterdata.Warehouses WHERE Id = @FromWarehouseId;
        SELECT @LineCount = COUNT(*), @Pcs = ISNULL(SUM(l.Quantity * iu.PackingFormula), 0)
        FROM @Lines l
        INNER JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId AND iu.ItemId = l.ItemId;

        IF @Id IS NULL
        BEGIN
            IF @NumberOnPost = 0
                EXEC inventory.usp_DocumentType_NextNumber @Code = N'TRO', @DocumentNumber = @Number OUTPUT, @BranchId = @BranchId;

            INSERT INTO inventory.TransferOrders (DocumentTypeId, DocumentNumber, DocumentDate, BranchId, FromWarehouseId, ToWarehouseId,
                                                  ExpectedArrival, ReferenceNo, Notes, Status, TotalLines, TotalOrderedBase, CreatedBy)
            VALUES (@TypeId, @Number, @DocumentDate, @BranchId, @FromWarehouseId, @ToWarehouseId,
                    @ExpectedArrival, @ReferenceNo, @Notes, 1, @LineCount, @Pcs, @UserId);
            SET @Id = SCOPE_IDENTITY();

            INSERT INTO inventory.TransferOrderAudit (TransferOrderId, Action, Details, UserId)
            VALUES (@Id, N'Created', CASE WHEN @Number IS NOT NULL THEN N'Created as ' + @Number ELSE N'Created (numbered when released)' END, @UserId);
        END
        ELSE
        BEGIN
            UPDATE inventory.TransferOrders
            SET DocumentDate = @DocumentDate, BranchId = @BranchId, FromWarehouseId = @FromWarehouseId, ToWarehouseId = @ToWarehouseId,
                ExpectedArrival = @ExpectedArrival, ReferenceNo = @ReferenceNo, Notes = @Notes,
                TotalLines = @LineCount, TotalOrderedBase = @Pcs,
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;

            DELETE FROM inventory.TransferOrderLines WHERE TransferOrderId = @Id;

            INSERT INTO inventory.TransferOrderAudit (TransferOrderId, Action, Details, UserId)
            VALUES (@Id, N'Updated', CAST(@LineCount AS NVARCHAR(10)) + N' line(s), ' + CAST(@Pcs AS NVARCHAR(20)) + N' pcs', @UserId);
        END

        INSERT INTO inventory.TransferOrderLines (TransferOrderId, LineNumber, ItemId, ItemUnitId, Quantity, PackingFormula, Notes)
        SELECT @Id, l.LineNumber, l.ItemId, l.ItemUnitId, l.Quantity, iu.PackingFormula, NULLIF(LTRIM(RTRIM(l.Notes)), N'')
        FROM @Lines l
        INNER JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId AND iu.ItemId = l.ItemId;

        COMMIT TRANSACTION;
        SET @NewId = @Id;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* 13.5 "SAVE DETAILS" OF AN ORDER THAT IS NO LONGER A DRAFT (rule T9): on a released order still under way (shown
   Released, Partly dispatched, Dispatched, Partly received) Expected arrival (not before the order date), Reference
   No. and Notes; on a received, closed or cancelled one the notes only - the dates and the reference the postings were
   made against stay as they were. A draft is changed with Save, an order waiting for approval is locked (Blocks,
   UpdateDetails). Nothing changed: nothing written. Audit DetailsUpdated names what changed. */
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_UpdateDetails
    @Id              INT,
    @ExpectedArrival DATE           = NULL,
    @ReferenceNo     NVARCHAR(100)  = NULL,
    @Notes           NVARCHAR(1000) = NULL,
    @RowVersion      BINARY(8)      = NULL,
    @UserId          INT            = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @ReferenceNo = NULLIF(LTRIM(RTRIM(@ReferenceNo)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');

    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @Status TINYINT, @DocDate DATE, @OldEta DATE, @OldRef NVARCHAR(100),
            @OldNotes NVARCHAR(1000), @Shown NVARCHAR(20), @EtaChanged BIT, @RefChanged BIT, @NotesChanged BIT,
            @Details NVARCHAR(1000);

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = Status, @DocDate = DocumentDate, @OldEta = ExpectedArrival, @OldRef = ReferenceNo, @OldNotes = Notes
        FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NOT NULL AND @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;

        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
        WHERE b.Action = N'UpdateDetails' AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        SELECT @Shown = st.DisplayStatus FROM inventory.fn_TransferOrder_State(@Id) st;
        -- the comparisons are exact (a case change of the reference or the notes is a change)
        SET @EtaChanged   = CASE WHEN ISNULL(@ExpectedArrival, '19000101') <> ISNULL(@OldEta, '19000101') THEN 1 ELSE 0 END;
        SET @RefChanged   = CASE WHEN ISNULL(@ReferenceNo, N'') COLLATE Latin1_General_BIN2 <> ISNULL(@OldRef, N'') COLLATE Latin1_General_BIN2 THEN 1 ELSE 0 END;
        SET @NotesChanged = CASE WHEN ISNULL(@Notes, N'') COLLATE Latin1_General_BIN2 <> ISNULL(@OldNotes, N'') COLLATE Latin1_General_BIN2 THEN 1 ELSE 0 END;

        IF (@Status = 3 OR @Shown IN (N'Received', N'Closed')) AND (@EtaChanged = 1 OR @RefChanged = 1)
            THROW 62010, 'Only the notes can change on a received, closed or cancelled transfer order.', 1;
        IF @EtaChanged = 1 AND @ExpectedArrival < @DocDate
            THROW 62000, 'Expected arrival cannot be before the order date.', 1;

        IF @EtaChanged = 1 OR @RefChanged = 1 OR @NotesChanged = 1
        BEGIN
            SET @Details = STUFF(
                  CASE WHEN @EtaChanged = 1 THEN N'; Expected arrival ' + ISNULL(CONVERT(NVARCHAR(10), @OldEta, 103), N'none')
                                                 + N' -> ' + ISNULL(CONVERT(NVARCHAR(10), @ExpectedArrival, 103), N'none') ELSE N'' END
                + CASE WHEN @RefChanged = 1 THEN N'; Reference No. ' + ISNULL(@OldRef, N'none') + N' -> ' + ISNULL(@ReferenceNo, N'none') ELSE N'' END
                + CASE WHEN @NotesChanged = 1 THEN N'; Notes' ELSE N'' END, 1, 2, N'');

            UPDATE inventory.TransferOrders
            SET ExpectedArrival = @ExpectedArrival, ReferenceNo = @ReferenceNo, Notes = @Notes,
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;

            INSERT INTO inventory.TransferOrderAudit (TransferOrderId, Action, Details, UserId)
            VALUES (@Id, N'DetailsUpdated', LEFT(@Details, 500), @UserId);
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* 13.6 DELETE A DRAFT (Blocks, Delete): its files, lines, audit rows and the order. A number it got at its first save
   leaves a gap (FB rule 4): numbers are never reused. */
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_Delete
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @Status TINYINT;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = Status FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NOT NULL AND @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;

        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
        WHERE b.Action = N'Delete' AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        DELETE FROM inventory.TransferOrderFiles WHERE TransferOrderId = @Id;
        DELETE FROM inventory.TransferOrderLines WHERE TransferOrderId = @Id;
        DELETE FROM inventory.TransferOrderAudit WHERE TransferOrderId = @Id;
        DELETE FROM inventory.TransferOrders WHERE Id = @Id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* 13.7 WHO IS TOLD THAT A TRANSFER ORDER WAITS FOR APPROVAL (M10): the active users holding Approve Transfer Orders
   through an active role that is not a system role, the requester left out, by name. The system role (Admin) holds
   every permission (usp_Permission_SyncCatalog) and would get every request, so its holders are told only when nobody
   else qualifies. Each must also hold View Transfer Orders (any of his roles): the email's link opens the order, and
   without it the page and the waiting list answer 403. The right to decide stays the permission (Blocks), whatever
   this list says. */
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_Approvers
    @RequesterId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @A TABLE (UserId INT NOT NULL PRIMARY KEY, FullName NVARCHAR(100) NOT NULL, Email NVARCHAR(256) NULL);

    INSERT INTO @A (UserId, FullName, Email)
    SELECT u.Id, u.FullName, u.Email
    FROM security.Users u
    WHERE u.IsActive = 1
      AND (@RequesterId IS NULL OR u.Id <> @RequesterId)
      AND EXISTS (SELECT 1
                  FROM security.UserRoles ur
                  INNER JOIN security.Roles r            ON r.Id = ur.RoleId AND r.IsActive = 1 AND r.IsSystem = 0
                  INNER JOIN security.RolePermissions rp ON rp.RoleId = r.Id
                  INNER JOIN security.Permissions p      ON p.Id = rp.PermissionId AND p.Code = N'inventory.transfers.approve'
                  WHERE ur.UserId = u.Id)
      AND security.fn_UserHasPermission(u.Id, N'inventory.transfers.view') = 1;

    IF NOT EXISTS (SELECT 1 FROM @A)
        INSERT INTO @A (UserId, FullName, Email)
        SELECT u.Id, u.FullName, u.Email
        FROM security.Users u
        WHERE u.IsActive = 1
          AND (@RequesterId IS NULL OR u.Id <> @RequesterId)
          AND EXISTS (SELECT 1
                      FROM security.UserRoles ur
                      INNER JOIN security.Roles r            ON r.Id = ur.RoleId AND r.IsActive = 1 AND r.IsSystem = 1
                      INNER JOIN security.RolePermissions rp ON rp.RoleId = r.Id
                      INNER JOIN security.Permissions p      ON p.Id = rp.PermissionId AND p.Code = N'inventory.transfers.approve'
                      WHERE ur.UserId = u.Id)
          AND security.fn_UserHasPermission(u.Id, N'inventory.transfers.view') = 1;

    SELECT UserId, FullName, Email FROM @A ORDER BY FullName, UserId;
END
GO

/* 13.8 RELEASE (Blocks, Release): the order is locked and its goods can be dispatched. When the TRO type asks for
   approval, only an approver gets past Blocks (Seq 37), and his Release is an approval as well: "Approve & release",
   approved directly by him (ApprovedAndReleased). The number is given now when the draft has none (TRO numbering at
   release), by From's branch; a rejection shown on the draft is cleared.
   Result set 1 = warnings, released all the same (nothing is reserved, FB rule 16): per item of the order whose
   released orders from From, this one now included, need more than From holds - "TVS-APACHE-160: the released orders
   from LKS-01 need 120 pcs; LKS-01 holds 80.", in line order. */
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_Release
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @Status TINYINT, @Number NVARCHAR(30), @FromId INT, @ToId INT,
            @NeedsApproval BIT, @WithApproval BIT, @Now DATETIME2(3) = SYSUTCDATETIME(), @Lines INT, @Pcs INT;
    DECLARE @W TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, Message NVARCHAR(400) NOT NULL);

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = Status, @Number = DocumentNumber, @FromId = FromWarehouseId, @ToId = ToWarehouseId
        FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NOT NULL AND @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;

        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
        WHERE b.Action = N'Release' AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        SELECT @NeedsApproval = dt.NeedsApproval
        FROM inventory.TransferOrders o INNER JOIN inventory.DocumentTypes dt ON dt.Id = o.DocumentTypeId
        WHERE o.Id = @Id;
        SET @WithApproval = CASE WHEN @NeedsApproval = 1 AND security.fn_UserHasPermission(@UserId, N'inventory.transfers.approve') = 1
                                 THEN 1 ELSE 0 END;

        IF @Number IS NULL
        BEGIN
            DECLARE @FromBranchId INT = (SELECT BranchId FROM masterdata.Warehouses WHERE Id = @FromId);
            EXEC inventory.usp_DocumentType_NextNumber @Code = N'TRO', @DocumentNumber = @Number OUTPUT, @BranchId = @FromBranchId;
        END

        UPDATE inventory.TransferOrders
        SET Status = 2, DocumentNumber = @Number,
            ReleasedAtUtc = @Now, ReleasedBy = @UserId,
            ApprovedAtUtc = CASE WHEN @WithApproval = 1 THEN @Now END,
            ApprovedBy    = CASE WHEN @WithApproval = 1 THEN @UserId END,
            ApprovedDirectly = @WithApproval,
            RejectedAtUtc = NULL, RejectedBy = NULL, RejectReason = NULL,
            UpdatedAtUtc = @Now, UpdatedBy = @UserId
        WHERE Id = @Id;

        SELECT @Lines = COUNT(*), @Pcs = ISNULL(SUM(OrderedBase), 0) FROM inventory.TransferOrderLines WHERE TransferOrderId = @Id;
        INSERT INTO inventory.TransferOrderAudit (TransferOrderId, Action, Details, UserId)
        SELECT @Id, CASE WHEN @WithApproval = 1 THEN N'ApprovedAndReleased' ELSE N'Released' END,
               LEFT(@Number + CASE WHEN @WithApproval = 1 THEN N' approved and released directly: ' ELSE N' released: ' END
                    + CAST(@Lines AS NVARCHAR(10)) + N' line(s), ' + CAST(@Pcs AS NVARCHAR(20)) + N' pcs, '
                    + fw.WarehouseCode + N' -> ' + tw.WarehouseCode + N'.', 500), @UserId
        FROM masterdata.Warehouses fw CROSS JOIN masterdata.Warehouses tw
        WHERE fw.Id = @FromId AND tw.Id = @ToId;

        -- The warnings: every released order from From, this one included now
        INSERT INTO @W (Message)
        SELECT LEFT(i.ItemCode + N': the released orders from ' + fw.WarehouseCode + N' need ' + CAST(p.OutToDispatchBase AS NVARCHAR(20))
                    + N' pcs; ' + fw.WarehouseCode + N' holds ' + CAST(p.OnHandBase AS NVARCHAR(20)) + N'.', 400)
        FROM (SELECT ItemId, FirstLine = MIN(LineNumber) FROM inventory.TransferOrderLines WHERE TransferOrderId = @Id GROUP BY ItemId) x
        INNER JOIN inventory.Items i        ON i.Id = x.ItemId
        INNER JOIN masterdata.Warehouses fw ON fw.Id = @FromId
        CROSS APPLY inventory.fn_TransferPosition(x.ItemId, @FromId, NULL) p
        WHERE p.OutToDispatchBase > p.OnHandBase
        ORDER BY x.FirstLine;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT Message FROM @W ORDER BY Seq;
END
GO

/* 13.9 SEND FOR APPROVAL (Blocks, SendForApproval: the TRO type asks for approval, a draft, the Release checks): the
   order waits, locked, until an approver approves or rejects it or the requester withdraws it; a rejection shown on
   the draft is cleared. The number does not change (the email says "a transfer order" while it has none).
   Result set 1 = the approvers to tell (inventory.usp_TransferOrder_Approvers, the requester left out): the API emails
   them after this transaction; the audit names them. */
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_SendForApproval
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @Status TINYINT, @Now DATETIME2(3) = SYSUTCDATETIME(), @Told NVARCHAR(500), @Count INT;
    DECLARE @A TABLE (UserId INT NOT NULL PRIMARY KEY, FullName NVARCHAR(100) NOT NULL, Email NVARCHAR(256) NULL);

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = Status FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NOT NULL AND @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;

        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
        WHERE b.Action = N'SendForApproval' AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        UPDATE inventory.TransferOrders
        SET Status = 4, ApprovalRequestedAtUtc = @Now, ApprovalRequestedBy = @UserId,
            RejectedAtUtc = NULL, RejectedBy = NULL, RejectReason = NULL,
            UpdatedAtUtc = @Now, UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO @A (UserId, FullName, Email)
        EXEC inventory.usp_TransferOrder_Approvers @RequesterId = @UserId;

        -- "Approvers told: Manager One, Approver T90 and 2 more." (the first three by name)
        SET @Count = (SELECT COUNT(*) FROM @A);
        SET @Told = STUFF((SELECT TOP (3) N', ' + a.FullName FROM @A a ORDER BY a.FullName, a.UserId
                           FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(500)'), 1, 2, N'');
        INSERT INTO inventory.TransferOrderAudit (TransferOrderId, Action, Details, UserId)
        VALUES (@Id, N'SentForApproval',
                LEFT(CASE WHEN @Count = 0 THEN N'Nobody else may approve transfer orders: no approver was told.'
                          ELSE N'Approvers told: ' + @Told
                               + CASE WHEN @Count > 3 THEN N' and ' + CAST(@Count - 3 AS NVARCHAR(10)) + N' more' ELSE N'' END + N'.' END, 500),
                @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT UserId, FullName, Email FROM @A ORDER BY FullName, UserId;
END
GO

/* 13.10 APPROVE (Blocks, Approve: the approval right, the Release checks). An order waiting for approval is released
   with the approver's name (Approved); a draft, when the TRO type asks for approval, is approved and released at once
   by him ("Approve & release": ApprovedDirectly, as his Release would). Self-approval is allowed, there is no
   threshold (D5); an order already waiting when the switch was turned off can still be approved (D14). The number is
   given now when the order has none.
   Result set 1 = Release's warnings; 2 = the requester to tell ("Approved: transfer order ..."): RequestedById,
   RequestedByName, RequestedByEmail - no row for a direct approval. */
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_Approve
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @Status TINYINT, @Number NVARCHAR(30), @FromId INT, @ToId INT,
            @RequestedBy INT, @Waiting BIT, @Now DATETIME2(3) = SYSUTCDATETIME(), @Lines INT, @Pcs INT;
    DECLARE @W TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, Message NVARCHAR(400) NOT NULL);

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = Status, @Number = DocumentNumber, @FromId = FromWarehouseId, @ToId = ToWarehouseId,
               @RequestedBy = ApprovalRequestedBy
        FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NOT NULL AND @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;

        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
        WHERE b.Action = N'Approve' AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        SET @Waiting = CASE WHEN @Status = 4 THEN 1 ELSE 0 END;    -- else a draft: Approve & release

        IF @Number IS NULL
        BEGIN
            DECLARE @FromBranchId INT = (SELECT BranchId FROM masterdata.Warehouses WHERE Id = @FromId);
            EXEC inventory.usp_DocumentType_NextNumber @Code = N'TRO', @DocumentNumber = @Number OUTPUT, @BranchId = @FromBranchId;
        END

        UPDATE inventory.TransferOrders
        SET Status = 2, DocumentNumber = @Number,
            ApprovedAtUtc = @Now, ApprovedBy = @UserId, ApprovedDirectly = CASE WHEN @Waiting = 1 THEN 0 ELSE 1 END,
            ReleasedAtUtc = @Now, ReleasedBy = @UserId,
            RejectedAtUtc = NULL, RejectedBy = NULL, RejectReason = NULL,
            UpdatedAtUtc = @Now, UpdatedBy = @UserId
        WHERE Id = @Id;

        SELECT @Lines = COUNT(*), @Pcs = ISNULL(SUM(OrderedBase), 0) FROM inventory.TransferOrderLines WHERE TransferOrderId = @Id;
        INSERT INTO inventory.TransferOrderAudit (TransferOrderId, Action, Details, UserId)
        SELECT @Id, CASE WHEN @Waiting = 1 THEN N'Approved' ELSE N'ApprovedAndReleased' END,
               LEFT(@Number + CASE WHEN @Waiting = 1 THEN N' approved and released: ' ELSE N' approved and released directly: ' END
                    + CAST(@Lines AS NVARCHAR(10)) + N' line(s), ' + CAST(@Pcs AS NVARCHAR(20)) + N' pcs, '
                    + fw.WarehouseCode + N' -> ' + tw.WarehouseCode + N'.', 500), @UserId
        FROM masterdata.Warehouses fw CROSS JOIN masterdata.Warehouses tw
        WHERE fw.Id = @FromId AND tw.Id = @ToId;

        -- Release's warnings: every released order from From, this one included now
        INSERT INTO @W (Message)
        SELECT LEFT(i.ItemCode + N': the released orders from ' + fw.WarehouseCode + N' need ' + CAST(p.OutToDispatchBase AS NVARCHAR(20))
                    + N' pcs; ' + fw.WarehouseCode + N' holds ' + CAST(p.OnHandBase AS NVARCHAR(20)) + N'.', 400)
        FROM (SELECT ItemId, FirstLine = MIN(LineNumber) FROM inventory.TransferOrderLines WHERE TransferOrderId = @Id GROUP BY ItemId) x
        INNER JOIN inventory.Items i        ON i.Id = x.ItemId
        INNER JOIN masterdata.Warehouses fw ON fw.Id = @FromId
        CROSS APPLY inventory.fn_TransferPosition(x.ItemId, @FromId, NULL) p
        WHERE p.OutToDispatchBase > p.OnHandBase
        ORDER BY x.FirstLine;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT Message FROM @W ORDER BY Seq;

    SELECT RequestedById = u.Id, RequestedByName = u.FullName, RequestedByEmail = u.Email
    FROM security.Users u
    WHERE @Waiting = 1 AND u.Id = @RequestedBy;
END
GO

/* 13.11 REJECT (Blocks, Reject: the approval right, an order waiting for approval; then the reason): back to draft,
   showing "Rejected by {name} on {date}: {reason}" until it is sent again. Result set 1 = the requester to tell
   ("Rejected: transfer order ..."): RequestedById, RequestedByName, RequestedByEmail. */
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_Reject
    @Id         INT,
    @RowVersion BINARY(8)     = NULL,
    @Reason     NVARCHAR(300) = NULL,
    @UserId     INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @Status TINYINT, @RequestedBy INT, @Now DATETIME2(3) = SYSUTCDATETIME();

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = Status, @RequestedBy = ApprovalRequestedBy
        FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NOT NULL AND @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;

        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
        WHERE b.Action = N'Reject' AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        IF @Reason IS NULL THROW 62000, 'A reason is required to reject the order.', 1;

        UPDATE inventory.TransferOrders
        SET Status = 1, RejectedAtUtc = @Now, RejectedBy = @UserId, RejectReason = @Reason,
            UpdatedAtUtc = @Now, UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO inventory.TransferOrderAudit (TransferOrderId, Action, Details, UserId)
        VALUES (@Id, N'Rejected', LEFT(@Reason, 500), @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT RequestedById = u.Id, RequestedByName = u.FullName, RequestedByEmail = u.Email
    FROM security.Users u
    WHERE u.Id = @RequestedBy;
END
GO

/* 13.12 WITHDRAW (Blocks, Withdraw: an order waiting for approval): back to draft, to be changed and sent again, or
   released once the TRO type no longer asks for approval (D14). */
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_Withdraw
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @Status TINYINT;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = Status FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NOT NULL AND @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;

        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
        WHERE b.Action = N'Withdraw' AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        UPDATE inventory.TransferOrders
        SET Status = 1, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO inventory.TransferOrderAudit (TransferOrderId, Action, Details, UserId)
        VALUES (@Id, N'Withdrawn', N'Request for approval withdrawn: back to draft.', @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* 13.13 BACK TO DRAFT (Blocks, BackToDraft: a released order with NO posting at all, reversed or not - D3: Save
   replaces the lines and posting lines must never lose their order line; then the reason). Its approval and release
   stamps are cleared: it is released, and approved when the type asks for it, again afterwards. The number stays. */
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_BackToDraft
    @Id         INT,
    @RowVersion BINARY(8)     = NULL,
    @Reason     NVARCHAR(300) = NULL,
    @UserId     INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @Status TINYINT;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = Status FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NOT NULL AND @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;

        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
        WHERE b.Action = N'BackToDraft' AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        IF @Reason IS NULL THROW 62000, 'A reason is required to take the order back to draft.', 1;

        UPDATE inventory.TransferOrders
        SET Status = 1,
            ApprovalRequestedAtUtc = NULL, ApprovalRequestedBy = NULL,
            ApprovedAtUtc = NULL, ApprovedBy = NULL, ApprovedDirectly = 0,
            RejectedAtUtc = NULL, RejectedBy = NULL, RejectReason = NULL,
            ReleasedAtUtc = NULL, ReleasedBy = NULL,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO inventory.TransferOrderAudit (TransferOrderId, Action, Details, UserId)
        VALUES (@Id, N'BackToDraft', LEFT(@Reason, 500), @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* 13.14 THE APPROVERS' MENU COUNT: the orders waiting for approval (the API answers 0 to a reader without Approve
   Transfer Orders). Transfer orders are not limited by user yet, so every approver sees the same count; @UserId is
   kept for when they are (script 92). */
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_WaitingCount
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT WaitingForApproval = COUNT(*) FROM inventory.TransferOrders WHERE Status = 4;
END
GO

/* 13.15 Files */

-- The transfer order's files, in the shape of the goods receipts' (script 64): a type used for transfer orders (62011
-- through usp_AttachmentType_CheckForKind, kind TRO), a document date, a note. A waybill or a damage report may come
-- at any time, so every status takes files.
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_File_Add
    @TransferOrderId  INT,
    @FileName         NVARCHAR(255),
    @ContentType      NVARCHAR(100),
    @SizeBytes        INT,
    @Content          VARBINARY(MAX),
    @UserId           INT           = NULL,
    @NewId            INT           = NULL OUTPUT,
    @AttachmentTypeId INT           = NULL,
    @DocumentDate     DATE          = NULL,
    @Note             NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @TransferOrderId) THROW 62006, 'Transfer order not found.', 1;
    IF @FileName IS NULL OR LTRIM(RTRIM(@FileName)) = N'' THROW 62000, 'File name is required.', 1;
    IF @Content IS NULL OR @SizeBytes IS NULL OR @SizeBytes <= 0 THROW 62000, 'The file is empty.', 1;
    EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, N'TRO', 62011;

    BEGIN TRY
        BEGIN TRANSACTION;
        INSERT INTO inventory.TransferOrderFiles (TransferOrderId, AttachmentTypeId, DocumentDate, Note, FileName, ContentType, SizeBytes, Content, CreatedBy)
        VALUES (@TransferOrderId, @AttachmentTypeId, @DocumentDate, NULLIF(LTRIM(RTRIM(@Note)), N''), LTRIM(RTRIM(@FileName)),
                ISNULL(NULLIF(LTRIM(RTRIM(@ContentType)), N''), N'application/octet-stream'), @SizeBytes, @Content, @UserId);
        SET @NewId = SCOPE_IDENTITY();
        INSERT INTO inventory.TransferOrderAudit (TransferOrderId, Action, Details, UserId)
        VALUES (@TransferOrderId, N'FileAdded', LEFT(LTRIM(RTRIM(@FileName)), 500), @UserId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- The files of an order (one with @FileId), newest first; IsOther = still typed "Other".
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_File_List
    @TransferOrderId INT, @AttachmentTypeId INT = NULL, @FileId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT f.Id, f.TransferOrderId AS DocumentId, f.FileName, f.ContentType, f.SizeBytes, f.AttachmentTypeId, t.Category, t.SubType,
           IsOther = CAST(CASE WHEN t.SubType = N'Other' AND t.Category IN (N'Other', N'General') THEN 1 ELSE 0 END AS BIT),
           f.DocumentDate, f.Note, f.CreatedAtUtc, f.CreatedBy, u.FullName AS CreatedByName
    FROM inventory.TransferOrderFiles f
    LEFT JOIN masterdata.AttachmentTypes t ON t.Id = f.AttachmentTypeId
    LEFT JOIN security.Users u             ON u.Id = f.CreatedBy
    WHERE f.TransferOrderId = @TransferOrderId
      AND (@AttachmentTypeId IS NULL OR f.AttachmentTypeId = @AttachmentTypeId)
      AND (@FileId IS NULL OR f.Id = @FileId)
    ORDER BY f.CreatedAtUtc DESC, f.Id DESC;
END
GO

-- One file with its content (the download).
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_File_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, TransferOrderId AS DocumentId, FileName, ContentType, SizeBytes, Content, CreatedAtUtc
    FROM inventory.TransferOrderFiles WHERE Id = @Id;
END
GO

-- Type, date and note of a file, and optionally a new name or content (the checks of the upload); answers the file's
-- row (usp_TransferOrder_File_List). A type the file already has may stay though deactivated since.
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_File_Update
    @Id               INT,
    @AttachmentTypeId INT            = NULL,
    @DocumentDate     DATE           = NULL,
    @Note             NVARCHAR(500)  = NULL,
    @FileName         NVARCHAR(255)  = NULL,
    @ContentType      NVARCHAR(100)  = NULL,
    @SizeBytes        INT            = NULL,
    @Content          VARBINARY(MAX) = NULL,
    @UserId           INT            = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @OrderId INT, @Old NVARCHAR(255), @OldType INT;
    SELECT @OrderId = TransferOrderId, @Old = FileName, @OldType = AttachmentTypeId FROM inventory.TransferOrderFiles WHERE Id = @Id;
    IF @OrderId IS NULL THROW 62006, 'File not found.', 1;
    SET @FileName = ISNULL(NULLIF(LTRIM(RTRIM(@FileName)), N''), @Old);
    IF @AttachmentTypeId IS NULL OR @AttachmentTypeId <> ISNULL(@OldType, -1)
        EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, N'TRO', 62011;
    IF @Content IS NOT NULL AND (@SizeBytes IS NULL OR @SizeBytes <= 0) THROW 62000, 'The file is empty.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        UPDATE inventory.TransferOrderFiles
        SET AttachmentTypeId = @AttachmentTypeId, DocumentDate = @DocumentDate, Note = NULLIF(LTRIM(RTRIM(@Note)), N''),
            FileName    = @FileName,
            ContentType = CASE WHEN @Content IS NULL THEN ContentType ELSE ISNULL(NULLIF(LTRIM(RTRIM(@ContentType)), N''), N'application/octet-stream') END,
            SizeBytes   = CASE WHEN @Content IS NULL THEN SizeBytes ELSE @SizeBytes END,
            Content     = ISNULL(@Content, Content)
        WHERE Id = @Id;
        INSERT INTO inventory.TransferOrderAudit (TransferOrderId, Action, Details, UserId)
        VALUES (@OrderId, N'FileUpdated', LEFT(CASE WHEN @Old = @FileName THEN @FileName ELSE @Old + N' -> ' + @FileName END
                                               + CASE WHEN @Content IS NOT NULL THEN N' (new file)' ELSE N'' END, 500), @UserId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    EXEC inventory.usp_TransferOrder_File_List @TransferOrderId = @OrderId, @FileId = @Id;
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_File_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @OrderId INT, @Name NVARCHAR(255);
    SELECT @OrderId = TransferOrderId, @Name = FileName FROM inventory.TransferOrderFiles WHERE Id = @Id;
    IF @OrderId IS NULL THROW 62006, 'File not found.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE FROM inventory.TransferOrderFiles WHERE Id = @Id;
        INSERT INTO inventory.TransferOrderAudit (TransferOrderId, Action, Details, UserId) VALUES (@OrderId, N'FileDeleted', LEFT(@Name, 500), @UserId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 13 (continued). Transfer orders: dispatch, receipt, close, cancel, reverse, ETA and return (2.3.8.13-2.3.8.20) */

/* The procedures that move stock, and the ones that settle or undo what moved: a dispatch (TRD) takes pieces out of From
   into the On the way warehouse of the destination branch, a transfer receipt (TRR) takes them from there into To (and
   writes off what will not arrive), "Dispatch and receive" posts both in one transaction; "Nothing more will be sent"
   settles what is left to dispatch, Cancel order cancels an order that dispatched nothing, Reverse undoes one whole
   posting in place, Change ETA moves a dispatch's ETA, Create return makes a new draft in the other direction.

   THE LEDGER ROWS (business-context 4.13, T29): family Transfer, type TRD or TRR, the posting's id, line id and number;
   reasons TRF_OUT on the two legs of a dispatch, TRF_IN on the two legs of a receipt, TRF_LOSS on a write-off - never
   family Sales (Shortages reads that family as sales). Every row is stamped CreatedBy = the acting user (G4), never a
   value copied from another row, and no INSERT into the ledger uses OUTPUT.

   COST-NEUTRAL (FB rule 34): each row carries the item's average cost of the moment (Items.AverageCost) for information,
   frozen on the dispatch line and carried to its receipt; no posting here calls inventory.usp_Item_ApplyReceipts, so
   no transfer moves an average, last or FOB cost. The company's stock only changes by a write-off (TRF_LOSS, at the
   average at receipt); the cost replay reads the incoming transfer legs at the running average (script 90, 14).

   THE LOCKS (T31): every action reads the order's header first WITH (UPDLOCK, HOLDLOCK), so two users acting on one order
   queue up on it and its counters (TransferOrderLines.DispatchedBase, ReceivedBase, LostBase, NotSentBase and the
   dispatch lines' SettledBase) only move under that lock; a dispatch also takes the application lock of its source
   warehouse, so two dispatches from one warehouse never both pass the stock check. A dispatch and a sale from the same
   warehouse at the same instant can still both pass it, as two sales can today.

   THE CORES (DispatchCore, ReceiveCore) post without a transaction of their own: their callers (Dispatch, Receive,
   Dispatch and receive) hold one and the order's lock, have checked the RowVersion and the action's first row of
   inventory.fn_TransferOrder_Blocks, and write the order's header stamp and the one audit row of the action. */

/* 13.16 POST A DISPATCH (internal: no transaction of its own; the caller holds one, the order's lock and its checks).
   In order (62000 unless said):
     1. the dates: the dispatch date required, at most one day ahead (the reader's time zone), not before the order
        date; the ETA required, not before the dispatch date;
     2. the lines: only those with pieces count (none: 62009); a line not on the order; negative pieces;
     3. not above To dispatch (62012); 4. no inactive item;
     5. one dispatch at a time from the source warehouse (an application lock held to the end of the transaction);
     6. the source holds the pieces, per item over the lines (62007; the out-of-stock sales setting does not apply);
   then the On the way warehouse of the destination branch (created when missing), the TRD number by the source branch,
   the posting and its lines (each line keeps its order line's number and the item's average of the moment), the ledger
   (per line: From -q, then On the way +q, both TRF_OUT) and the order lines' Dispatched. */
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_DispatchCore
    @Id             INT,
    @Date           DATE,
    @Eta            DATE,
    @ReferenceNo    NVARCHAR(100)  = NULL,
    @Notes          NVARCHAR(1000) = NULL,
    @Lines          inventory.tvp_TransferDispatchLine READONLY,
    @UserId         INT            = NULL,
    @PostingId      INT            = NULL OUTPUT,
    @DocumentNumber NVARCHAR(30)   = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- The caller's transaction holds the order's lock: posting outside one would leave the counters unguarded.
    IF @@TRANCOUNT = 0
        THROW 62010, 'A transfer dispatch is posted inside its caller''s transaction.', 1;

    SET @PostingId = NULL;
    SET @DocumentNumber = NULL;

    DECLARE @Msg NVARCHAR(400), @No NVARCHAR(30), @OrderDate DATE, @FromId INT, @ToId INT, @FromCode NVARCHAR(20),
            @FromBranchId INT, @ToBranchId INT, @TransitId INT, @TransitBranchId INT, @TypeId INT, @Lock INT,
            @Resource NVARCHAR(255), @Now DATETIME2(3) = SYSUTCDATETIME(), @MovementDate DATETIME2(3);
    DECLARE @Tomorrow DATE = DATEADD(DAY, 1, CAST(@Now AS DATE));

    DECLARE @L TABLE
    (
        OrderLineId INT           NOT NULL PRIMARY KEY,
        LineNumber  INT           NOT NULL,
        ItemId      INT           NOT NULL,
        Qty         INT           NOT NULL,
        ToDispatch  INT           NOT NULL,
        Cost        DECIMAL(18,6) NULL
    );

    SELECT @No = ISNULL(o.DocumentNumber, N'this transfer order'), @OrderDate = o.DocumentDate,
           @FromId = o.FromWarehouseId, @ToId = o.ToWarehouseId,
           @FromCode = fw.WarehouseCode, @FromBranchId = fw.BranchId, @ToBranchId = tw.BranchId
    FROM inventory.TransferOrders o
    INNER JOIN masterdata.Warehouses fw ON fw.Id = o.FromWarehouseId
    INNER JOIN masterdata.Warehouses tw ON tw.Id = o.ToWarehouseId
    WHERE o.Id = @Id;
    IF @FromId IS NULL THROW 62006, 'Transfer order not found.', 1;

    -- 1. The dates (one day of tolerance ahead: the date is the reader's local one, the check is UTC)
    IF @Date IS NULL THROW 62000, 'The dispatch date is required.', 1;
    IF @Date > @Tomorrow THROW 62000, 'The dispatch date cannot be in the future.', 1;
    IF @Date < @OrderDate
    BEGIN
        SET @Msg = N'The dispatch date cannot be before the order date (' + CONVERT(NVARCHAR(10), @OrderDate, 103) + N').';
        THROW 62000, @Msg, 1;
    END
    IF @Eta IS NULL THROW 62000, 'The ETA is required.', 1;
    IF @Eta < @Date THROW 62000, 'The ETA cannot be before the dispatch date.', 1;

    -- 2. The lines: only those with pieces count; a line of another order, or pieces below 0, are refused
    IF NOT EXISTS (SELECT 1 FROM @Lines WHERE QuantityBase > 0)
        THROW 62009, 'Nothing to dispatch: type the pieces that leave.', 1;

    IF EXISTS (SELECT 1 FROM @Lines x
               WHERE x.QuantityBase <> 0
                 AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrderLines l WHERE l.Id = x.TransferOrderLineId AND l.TransferOrderId = @Id))
    BEGIN
        SET @Msg = N'A line of the dispatch is not on ' + @No + N'.';
        THROW 62000, @Msg, 1;
    END

    SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': the pieces dispatched cannot be negative.'
    FROM @Lines x
    INNER JOIN inventory.TransferOrderLines l ON l.Id = x.TransferOrderLineId AND l.TransferOrderId = @Id
    WHERE x.QuantityBase < 0
    ORDER BY l.LineNumber;
    IF @Msg IS NOT NULL THROW 62000, @Msg, 1;

    INSERT INTO @L (OrderLineId, LineNumber, ItemId, Qty, ToDispatch)
    SELECT l.Id, l.LineNumber, l.ItemId, x.QuantityBase,
           CASE WHEN l.OrderedBase - l.DispatchedBase - l.NotSentBase > 0 THEN l.OrderedBase - l.DispatchedBase - l.NotSentBase ELSE 0 END
    FROM @Lines x
    INNER JOIN inventory.TransferOrderLines l ON l.Id = x.TransferOrderLineId AND l.TransferOrderId = @Id
    WHERE x.QuantityBase > 0;

    -- 3. Not above what is left to dispatch on the line (Ordered - Dispatched - Not sent)
    SELECT TOP (1) @Msg = N'Line ' + CAST(x.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): ' + CAST(x.Qty AS NVARCHAR(20))
                          + N' pcs dispatched but only ' + CAST(x.ToDispatch AS NVARCHAR(20)) + N' are left to dispatch.'
    FROM @L x
    INNER JOIN inventory.Items i ON i.Id = x.ItemId
    WHERE x.Qty > x.ToDispatch
    ORDER BY x.LineNumber;
    IF @Msg IS NOT NULL THROW 62012, @Msg, 1;

    -- 4. An item made inactive since the release
    SELECT TOP (1) @Msg = N'Line ' + CAST(x.LineNumber AS NVARCHAR(10)) + N': item ' + i.ItemCode + N' is inactive.'
    FROM @L x
    INNER JOIN inventory.Items i ON i.Id = x.ItemId
    WHERE i.IsActive = 0
    ORDER BY x.LineNumber;
    IF @Msg IS NOT NULL THROW 62000, @Msg, 1;

    -- 5. ONE DISPATCH AT A TIME FROM A WAREHOUSE: two orders from LKS-01 would otherwise both read the same stock and
    --    both pass step 6. Held until the caller's transaction ends.
    SET @Resource = N'inventory.TransferDispatch.' + CAST(@FromId AS NVARCHAR(10));
    EXEC @Lock = sp_getapplock @Resource = @Resource, @LockMode = N'Exclusive', @LockOwner = N'Transaction', @LockTimeout = 30000;
    IF @Lock < 0
    BEGIN
        SET @Msg = N'Another dispatch from ' + ISNULL(@FromCode, N'this warehouse') + N' is being posted. Try again in a moment.';
        THROW 62010, @Msg, 1;
    END

    -- 6. The source holds the pieces, per item over the lines (the same item may be on two lines in two units)
    SELECT TOP (1) @Msg = N'Insufficient stock for ' + i.ItemCode + N' in ' + @FromCode + N': available '
                          + CAST(oh.Q AS NVARCHAR(20)) + N', required ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
    FROM (SELECT ItemId, Qty = SUM(Qty), FirstLine = MIN(LineNumber) FROM @L GROUP BY ItemId) x
    INNER JOIN inventory.Items i ON i.Id = x.ItemId
    CROSS APPLY (SELECT Q = ISNULL(SUM(m.QuantityBase), 0) FROM inventory.StockMovements m
                 WHERE m.ItemId = x.ItemId AND m.WarehouseId = @FromId) oh
    WHERE x.Qty > oh.Q
    ORDER BY x.FirstLine;
    IF @Msg IS NOT NULL THROW 62007, @Msg, 1;

    -- 7. The goods travel in the On the way warehouse of the DESTINATION branch (created when it is missing)
    EXEC masterdata.usp_Warehouse_EnsureTransit @BranchId = @ToBranchId, @UserId = @UserId, @WarehouseId = @TransitId OUTPUT;
    SELECT @TransitBranchId = BranchId FROM masterdata.Warehouses WHERE Id = @TransitId;

    -- 8. The number, by the source branch (an inactive TRD type is refused by Blocks, Seq 83, and again here: 62008)
    SELECT @TypeId = Id FROM inventory.DocumentTypes WHERE Code = N'TRD';
    EXEC inventory.usp_DocumentType_NextNumber @Code = N'TRD', @DocumentNumber = @DocumentNumber OUTPUT, @BranchId = @FromBranchId;

    -- 9. The posting and its lines. The cost is the item's average now, frozen for information: it moves nothing.
    UPDATE x SET Cost = i.AverageCost
    FROM @L x INNER JOIN inventory.Items i ON i.Id = x.ItemId;

    INSERT INTO inventory.TransferPostings (TransferOrderId, DocumentTypeId, Kind, DocumentNumber, PostingDate, Eta, BranchId,
                                           FromWarehouseId, ToWarehouseId, TransitWarehouseId, ReferenceNo, Notes, PostedWithId,
                                           Status, TotalQuantityBase, TotalLostBase, ValueBase, LostValueBase, PostedAtUtc, PostedBy)
    SELECT @Id, @TypeId, N'Dispatch', @DocumentNumber, @Date, @Eta, @FromBranchId,
           @FromId, @ToId, @TransitId, NULLIF(LTRIM(RTRIM(@ReferenceNo)), N''), NULLIF(LTRIM(RTRIM(@Notes)), N''), NULL,
           2, SUM(x.Qty), 0, CAST(ROUND(SUM(CAST(x.Qty AS DECIMAL(18,6)) * ISNULL(x.Cost, 0)), 2) AS DECIMAL(18,2)), 0, @Now, @UserId
    FROM @L x;
    SET @PostingId = SCOPE_IDENTITY();

    INSERT INTO inventory.TransferPostingLines (PostingId, LineNumber, TransferOrderLineId, ItemId, DispatchLineId, TransitWarehouseId,
                                                QuantityBase, LostBase, LossReasonCode, LossNote, SettledBase, UnitCostBase, LossUnitCostBase)
    SELECT @PostingId, x.LineNumber, x.OrderLineId, x.ItemId, NULL, @TransitId, x.Qty, 0, NULL, NULL, 0, x.Cost, NULL
    FROM @L x
    ORDER BY x.LineNumber;

    -- 10. The ledger, per posting line: the source -q, then On the way +q (each in its warehouse's branch), dated the
    --     dispatch date at the time of posting (inventory.usp_StockDocument_Post's rule)
    SET @MovementDate = DATEADD(SECOND, DATEDIFF(SECOND, CAST(@Now AS DATE), @Now), CAST(@Date AS DATETIME2(3)));

    INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                          DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber,
                                          ReasonCode, ExpiryDate, IsReversal, CreatedBy)
    SELECT @MovementDate, pl.ItemId, g.WarehouseId, g.BranchId, g.Sign * pl.QuantityBase, pl.UnitCostBase,
           N'Transfer', N'TRD', @PostingId, pl.Id, @DocumentNumber,
           N'TRF_OUT', NULL, 0, @UserId
    FROM inventory.TransferPostingLines pl
    CROSS APPLY (VALUES (1, @FromId, @FromBranchId, -1),
                        (2, @TransitId, @TransitBranchId, 1)) g (Leg, WarehouseId, BranchId, Sign)
    WHERE pl.PostingId = @PostingId
    ORDER BY pl.LineNumber, g.Leg;

    -- 11. The order lines' Dispatched (posted, not reversed postings only)
    UPDATE l SET DispatchedBase = l.DispatchedBase + x.Qty
    FROM inventory.TransferOrderLines l
    INNER JOIN @L x ON x.OrderLineId = l.Id;
END
GO

/* 13.17 DISPATCH (Blocks, Dispatch: a released order, not closed, something to dispatch, TRD active, the warehouses, some
   stock at From): the core above, the order's header stamp and the audit "{TRD}: {n} line(s), {pcs} pcs, ETA {date}.".
   Result set: PostingId, DocumentNumber (the API answers "{TRD} posted: {q} pcs left {From}."). */
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_Dispatch
    @Id             INT,
    @RowVersion     BINARY(8)      = NULL,
    @Date           DATE,
    @Eta            DATE,
    @ReferenceNo    NVARCHAR(100)  = NULL,
    @Notes          NVARCHAR(1000) = NULL,
    @Lines          inventory.tvp_TransferDispatchLine READONLY,
    @UserId         INT            = NULL,
    @PostingId      INT            = NULL OUTPUT,
    @DocumentNumber NVARCHAR(30)   = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @Status TINYINT, @Now DATETIME2(3) = SYSUTCDATETIME();

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = Status FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NOT NULL AND @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;

        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
        WHERE b.Action = N'Dispatch' AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        EXEC inventory.usp_TransferOrder_DispatchCore @Id = @Id, @Date = @Date, @Eta = @Eta, @ReferenceNo = @ReferenceNo,
             @Notes = @Notes, @Lines = @Lines, @UserId = @UserId,
             @PostingId = @PostingId OUTPUT, @DocumentNumber = @DocumentNumber OUTPUT;

        -- The order's RowVersion moves with its postings: a page opened before the dispatch must reload before it acts.
        UPDATE inventory.TransferOrders SET UpdatedAtUtc = @Now, UpdatedBy = @UserId WHERE Id = @Id;

        INSERT INTO inventory.TransferOrderAudit (TransferOrderId, PostingId, Action, Details, UserId)
        SELECT @Id, p.Id, N'Dispatched',
               LEFT(p.DocumentNumber + N': ' + CAST(n.Lines AS NVARCHAR(10)) + N' line(s), ' + CAST(p.TotalQuantityBase AS NVARCHAR(20))
                    + N' pcs, ETA ' + CONVERT(NVARCHAR(10), p.Eta, 103) + N'.', 500),
               @UserId
        FROM inventory.TransferPostings p
        CROSS APPLY (SELECT Lines = COUNT(*) FROM inventory.TransferPostingLines pl WHERE pl.PostingId = p.Id) n
        WHERE p.Id = @PostingId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT PostingId = @PostingId, DocumentNumber = @DocumentNumber;
END
GO

/* 13.18 POST A TRANSFER RECEIPT (internal: no transaction of its own; the caller holds one, the order's lock and its
   checks). Each row receives one dispatch line. In order (62000 unless said):
     1. the dispatch line is on a POSTED dispatch of this order; 2. received not below 0;
     3. received not above what is on the way on that dispatch line (62012);
     4. "Nothing more will arrive": the rest (on the way - received) is LOST and needs a reason (Damaged, Missing,
        Wrongly counted at dispatch, Other with a note);
     5. rows that receive and lose nothing are ignored; none left: 62009;
     6. the receipt date required, at most one day ahead, not before any dispatch it receives;
     7. the destination still fit (Blocks Receive, Seq 92: its sentences in one place);
     8. a safety net: the On the way warehouse holds what is received and written off (62007);
   then the TRR number by the destination branch, the posting and its lines (1..n, dispatch then line; the dispatch
   line's frozen cost; the item's average now on a line with a loss), the ledger (per line, the legs with pieces: On the
   way -received and To +received, TRF_IN, at the dispatch's cost; On the way -lost, TRF_LOSS, at the average - the only
   leg of a transfer that changes the company's stock), the dispatch lines' Settled and the order lines' Received and
   Lost. @PostedWithId: the dispatch of a "Dispatch and receive".
   THE MOVEMENT DATE is the receipt date at the time of posting, but never before the latest ledger row in the On the
   way warehouse of the dispatch lines it receives (their dispatch rows, their earlier receipts and every reversal of
   those) + 1 second: a receipt typed the next morning for yesterday, after an earlier receipt was reversed today, would
   otherwise take the pieces out of On the way before that reversal put them back, and the warehouse's running balance
   would dip below 0. */
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_ReceiveCore
    @Id             INT,
    @Date           DATE,
    @ReferenceNo    NVARCHAR(100)  = NULL,
    @Notes          NVARCHAR(1000) = NULL,
    @Lines          inventory.tvp_TransferReceiptLine READONLY,
    @UserId         INT            = NULL,
    @PostingId      INT            = NULL OUTPUT,
    @DocumentNumber NVARCHAR(30)   = NULL OUTPUT,
    @PostedWithId   INT            = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @@TRANCOUNT = 0
        THROW 62010, 'A transfer receipt is posted inside its caller''s transaction.', 1;

    SET @PostingId = NULL;
    SET @DocumentNumber = NULL;

    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @No NVARCHAR(30), @FromId INT, @ToId INT, @ToBranchId INT, @TypeId INT,
            @Now DATETIME2(3) = SYSUTCDATETIME(), @MovementDate DATETIME2(3), @Latest DATETIME2(3);
    DECLARE @Tomorrow DATE = DATEADD(DAY, 1, CAST(@Now AS DATE));

    DECLARE @R TABLE
    (
        DispatchLineId     INT           NOT NULL PRIMARY KEY,
        DispatchId         INT           NOT NULL,
        DispatchNumber     NVARCHAR(30)  NOT NULL,
        DispatchDate       DATE          NOT NULL,
        DispatchPostedAt   DATETIME2(3)  NOT NULL,
        DispatchLineNumber INT           NOT NULL,
        OrderLineId        INT           NOT NULL,
        ItemId             INT           NOT NULL,
        TransitId          INT           NOT NULL,
        UnitCost           DECIMAL(18,6) NULL,
        OnTheWay           INT           NOT NULL,
        Received           INT           NOT NULL,
        NothingMore        BIT           NOT NULL,
        Lost               INT           NOT NULL DEFAULT (0),
        ReasonCode         NVARCHAR(20)  NULL,
        Note               NVARCHAR(300) NULL,
        LossCost           DECIMAL(18,6) NULL,
        Seq                INT           NULL
    );

    SELECT @No = ISNULL(o.DocumentNumber, N'this transfer order'), @FromId = o.FromWarehouseId, @ToId = o.ToWarehouseId,
           @ToBranchId = tw.BranchId
    FROM inventory.TransferOrders o
    INNER JOIN masterdata.Warehouses tw ON tw.Id = o.ToWarehouseId
    WHERE o.Id = @Id;
    IF @ToId IS NULL THROW 62006, 'Transfer order not found.', 1;

    -- 1. Each row receives a line of a dispatch of this order that is still posted
    IF EXISTS (SELECT 1 FROM @Lines x
               WHERE NOT EXISTS (SELECT 1
                                 FROM inventory.TransferPostingLines dl
                                 INNER JOIN inventory.TransferPostings dp ON dp.Id = dl.PostingId
                                 WHERE dl.Id = x.DispatchLineId AND dl.DispatchLineId IS NULL
                                   AND dp.TransferOrderId = @Id AND dp.Kind = N'Dispatch' AND dp.Status = 2))
    BEGIN
        SET @Msg = N'A line of the receipt is not on a dispatch of ' + @No + N' that is still posted.';
        THROW 62000, @Msg, 1;
    END

    INSERT INTO @R (DispatchLineId, DispatchId, DispatchNumber, DispatchDate, DispatchPostedAt, DispatchLineNumber, OrderLineId,
                    ItemId, TransitId, UnitCost, OnTheWay, Received, NothingMore, ReasonCode, Note)
    SELECT dl.Id, dp.Id, dp.DocumentNumber, dp.PostingDate, dp.PostedAtUtc, dl.LineNumber, dl.TransferOrderLineId,
           dl.ItemId, dl.TransitWarehouseId, dl.UnitCostBase, dl.QuantityBase - dl.SettledBase, x.ReceivedBase,
           ISNULL(x.NothingMoreWillArrive, 0),
           NULLIF(UPPER(LTRIM(RTRIM(x.LossReasonCode))), N''), NULLIF(LTRIM(RTRIM(x.LossNote)), N'')
    FROM @Lines x
    INNER JOIN inventory.TransferPostingLines dl ON dl.Id = x.DispatchLineId
    INNER JOIN inventory.TransferPostings dp     ON dp.Id = dl.PostingId;

    -- dispatch then line: the receipt's line numbers, and the order every "first failing" below is looked for in
    UPDATE r SET Seq = s.Seq
    FROM @R r
    INNER JOIN (SELECT DispatchLineId, Seq = ROW_NUMBER() OVER (ORDER BY DispatchPostedAt, DispatchId, DispatchLineNumber) FROM @R) s
            ON s.DispatchLineId = r.DispatchLineId;

    -- 2. Not below 0
    SELECT TOP (1) @Msg = r.DispatchNumber + N' line ' + CAST(r.DispatchLineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode
                          + N'): the pieces received cannot be negative.'
    FROM @R r INNER JOIN inventory.Items i ON i.Id = r.ItemId
    WHERE r.Received < 0
    ORDER BY r.Seq;
    IF @Msg IS NOT NULL THROW 62000, @Msg, 1;

    -- 3. Not above what is on the way on the dispatch line
    SELECT TOP (1) @Msg = r.DispatchNumber + N' line ' + CAST(r.DispatchLineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                          + CAST(r.Received AS NVARCHAR(20)) + N' pcs received but only ' + CAST(r.OnTheWay AS NVARCHAR(20)) + N' are on the way.'
    FROM @R r INNER JOIN inventory.Items i ON i.Id = r.ItemId
    WHERE r.Received > r.OnTheWay
    ORDER BY r.Seq;
    IF @Msg IS NOT NULL THROW 62012, @Msg, 1;

    -- 4. "Nothing more will arrive": the rest is lost and says why. A reason sent with nothing lost is not kept.
    UPDATE @R SET Lost = CASE WHEN NothingMore = 1 THEN OnTheWay - Received ELSE 0 END;
    UPDATE @R SET ReasonCode = NULL, Note = NULL WHERE Lost = 0;

    SELECT TOP (1) @Msg = r.DispatchNumber + N' line ' + CAST(r.DispatchLineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                          + CASE WHEN r.ReasonCode IS NULL THEN N'choose why the rest will not arrive.'
                                 WHEN r.ReasonCode NOT IN (N'DAMAGED', N'MISSING', N'DISPATCHCOUNT', N'OTHER') THEN N'unknown reason.'
                                 ELSE N'say what happened in the note (reason Other).' END
    FROM @R r INNER JOIN inventory.Items i ON i.Id = r.ItemId
    WHERE r.Lost > 0
      AND (r.ReasonCode IS NULL OR r.ReasonCode NOT IN (N'DAMAGED', N'MISSING', N'DISPATCHCOUNT', N'OTHER')
           OR (r.ReasonCode = N'OTHER' AND r.Note IS NULL))
    ORDER BY r.Seq;
    IF @Msg IS NOT NULL THROW 62000, @Msg, 1;

    -- 5. Rows that receive and lose nothing are ignored
    DELETE FROM @R WHERE Received = 0 AND Lost = 0;
    IF NOT EXISTS (SELECT 1 FROM @R)
        THROW 62009, 'Nothing to receive: type the pieces that arrived, or tick Nothing more will arrive.', 1;

    UPDATE r SET Seq = s.Seq
    FROM @R r
    INNER JOIN (SELECT DispatchLineId, Seq = ROW_NUMBER() OVER (ORDER BY DispatchPostedAt, DispatchId, DispatchLineNumber) FROM @R) s
            ON s.DispatchLineId = r.DispatchLineId;

    -- 6. The date: not before the latest dispatch it receives
    IF @Date IS NULL THROW 62000, 'The receipt date is required.', 1;
    IF @Date > @Tomorrow THROW 62000, 'The receipt date cannot be in the future.', 1;
    SELECT TOP (1) @Msg = N'TRR cannot be dated before ' + r.DispatchNumber + N' left on ' + CONVERT(NVARCHAR(10), r.DispatchDate, 103) + N'.'
    FROM @R r
    WHERE r.DispatchDate > @Date
    ORDER BY r.DispatchDate DESC, r.DispatchPostedAt DESC, r.DispatchId DESC;
    IF @Msg IS NOT NULL THROW 62000, @Msg, 1;

    -- 7. The destination: rules 3-5 of fn_TransferOrder_WarehouseProblem for To alone, inactive in its own words
    --    (Blocks, Receive, Seq 92: the one place of these sentences)
    SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
    FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
    WHERE b.Action = N'Receive' AND b.Seq = 92 AND b.Message IS NOT NULL
    ORDER BY b.Seq;
    IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

    -- 8. A safety net: the On the way warehouse holds what this receipt takes out of it
    SELECT TOP (1) @Msg = N'Insufficient stock for ' + i.ItemCode + N' in ' + w.WarehouseCode + N': available '
                          + CAST(oh.Q AS NVARCHAR(20)) + N', required ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
    FROM (SELECT ItemId, TransitId, Qty = SUM(Received + Lost), FirstSeq = MIN(Seq) FROM @R GROUP BY ItemId, TransitId) x
    INNER JOIN inventory.Items i       ON i.Id = x.ItemId
    INNER JOIN masterdata.Warehouses w ON w.Id = x.TransitId
    CROSS APPLY (SELECT Q = ISNULL(SUM(m.QuantityBase), 0) FROM inventory.StockMovements m
                 WHERE m.ItemId = x.ItemId AND m.WarehouseId = x.TransitId) oh
    WHERE x.Qty > oh.Q
    ORDER BY x.FirstSeq;
    IF @Msg IS NOT NULL THROW 62007, @Msg, 1;

    -- 9. The number, by the destination branch (an inactive TRR type: Blocks Seq 84, and again here: 62008)
    SELECT @TypeId = Id FROM inventory.DocumentTypes WHERE Code = N'TRR';
    EXEC inventory.usp_DocumentType_NextNumber @Code = N'TRR', @DocumentNumber = @DocumentNumber OUTPUT, @BranchId = @ToBranchId;

    -- 10. The posting and its lines: received at the dispatch's frozen cost, lost at the average now
    UPDATE r SET LossCost = i.AverageCost
    FROM @R r INNER JOIN inventory.Items i ON i.Id = r.ItemId
    WHERE r.Lost > 0;

    INSERT INTO inventory.TransferPostings (TransferOrderId, DocumentTypeId, Kind, DocumentNumber, PostingDate, Eta, BranchId,
                                           FromWarehouseId, ToWarehouseId, TransitWarehouseId, ReferenceNo, Notes, PostedWithId,
                                           Status, TotalQuantityBase, TotalLostBase, ValueBase, LostValueBase, PostedAtUtc, PostedBy)
    SELECT @Id, @TypeId, N'Receipt', @DocumentNumber, @Date, NULL, @ToBranchId,
           @FromId, @ToId, NULL, NULLIF(LTRIM(RTRIM(@ReferenceNo)), N''), NULLIF(LTRIM(RTRIM(@Notes)), N''), @PostedWithId,
           2, SUM(r.Received), SUM(r.Lost),
           CAST(ROUND(SUM(CAST(r.Received AS DECIMAL(18,6)) * ISNULL(r.UnitCost, 0)), 2) AS DECIMAL(18,2)),
           CAST(ROUND(SUM(CAST(r.Lost AS DECIMAL(18,6)) * ISNULL(r.LossCost, 0)), 2) AS DECIMAL(18,2)),
           @Now, @UserId
    FROM @R r;
    SET @PostingId = SCOPE_IDENTITY();

    INSERT INTO inventory.TransferPostingLines (PostingId, LineNumber, TransferOrderLineId, ItemId, DispatchLineId, TransitWarehouseId,
                                                QuantityBase, LostBase, LossReasonCode, LossNote, SettledBase, UnitCostBase, LossUnitCostBase)
    SELECT @PostingId, r.Seq, r.OrderLineId, r.ItemId, r.DispatchLineId, r.TransitId,
           r.Received, r.Lost, r.ReasonCode, r.Note, 0, r.UnitCost, r.LossCost
    FROM @R r
    ORDER BY r.Seq;

    -- 11. The ledger. The movement date: see the header (never before what it receives, + 1 second).
    SET @MovementDate = DATEADD(SECOND, DATEDIFF(SECOND, CAST(@Now AS DATE), @Now), CAST(@Date AS DATETIME2(3)));

    ;WITH k AS
    (
        SELECT DocumentId = r.DispatchId, DocumentLineId = r.DispatchLineId, TypeCode = N'TRD', WarehouseId = r.TransitId
        FROM @R r
        UNION ALL
        SELECT rl.PostingId, rl.Id, N'TRR', r.TransitId
        FROM @R r
        INNER JOIN inventory.TransferPostingLines rl ON rl.DispatchLineId = r.DispatchLineId
        WHERE rl.PostingId <> @PostingId
    )
    SELECT @Latest = MAX(m.MovementDate)
    FROM k
    INNER JOIN inventory.StockMovements m ON m.DocumentFamily = N'Transfer' AND m.DocumentId = k.DocumentId
                                         AND m.DocumentTypeCode = k.TypeCode AND m.DocumentLineId = k.DocumentLineId
                                         AND m.WarehouseId = k.WarehouseId;
    IF @Latest IS NOT NULL AND @MovementDate < DATEADD(SECOND, 1, @Latest)
        SET @MovementDate = DATEADD(SECOND, 1, @Latest);

    INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                          DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber,
                                          ReasonCode, ExpiryDate, IsReversal, CreatedBy)
    SELECT @MovementDate, rl.ItemId, g.WarehouseId, w.BranchId, g.Qty, g.Cost,
           N'Transfer', N'TRR', @PostingId, rl.Id, @DocumentNumber,
           g.Reason, NULL, 0, @UserId
    FROM inventory.TransferPostingLines rl
    CROSS APPLY (VALUES (1, rl.TransitWarehouseId, -rl.QuantityBase, rl.UnitCostBase,     N'TRF_IN'),
                        (2, @ToId,                  rl.QuantityBase, rl.UnitCostBase,     N'TRF_IN'),
                        (3, rl.TransitWarehouseId, -rl.LostBase,     rl.LossUnitCostBase, N'TRF_LOSS')) g (Leg, WarehouseId, Qty, Cost, Reason)
    INNER JOIN masterdata.Warehouses w ON w.Id = g.WarehouseId
    WHERE rl.PostingId = @PostingId AND g.Qty <> 0
    ORDER BY rl.LineNumber, g.Leg;

    -- 12. The dispatch lines' Settled; the order lines' Received and Lost (one order line may be received from two
    --     dispatches in one receipt)
    UPDATE dl SET SettledBase = dl.SettledBase + r.Received + r.Lost
    FROM inventory.TransferPostingLines dl
    INNER JOIN @R r ON r.DispatchLineId = dl.Id;

    UPDATE l SET ReceivedBase = l.ReceivedBase + x.Received, LostBase = l.LostBase + x.Lost
    FROM inventory.TransferOrderLines l
    INNER JOIN (SELECT OrderLineId, Received = SUM(Received), Lost = SUM(Lost) FROM @R GROUP BY OrderLineId) x ON x.OrderLineId = l.Id;
END
GO

/* 13.19 RECEIVE (Blocks, Receive: a released order with goods on the way, TRR active, the destination fit): the core
   above, the order's header stamp and the audit "{TRR}: {r} pcs received from {TRD list}; {l} pc(s) written off
   ({reasons})." (the second part only with a loss). Result set: PostingId, DocumentNumber, ReceivedBase, LostBase. */
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_Receive
    @Id             INT,
    @RowVersion     BINARY(8)      = NULL,
    @Date           DATE,
    @ReferenceNo    NVARCHAR(100)  = NULL,
    @Notes          NVARCHAR(1000) = NULL,
    @Lines          inventory.tvp_TransferReceiptLine READONLY,
    @UserId         INT            = NULL,
    @PostingId      INT            = NULL OUTPUT,
    @DocumentNumber NVARCHAR(30)   = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @Status TINYINT, @Now DATETIME2(3) = SYSUTCDATETIME(),
            @Received INT, @Lost INT;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = Status FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NOT NULL AND @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;

        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
        WHERE b.Action = N'Receive' AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        EXEC inventory.usp_TransferOrder_ReceiveCore @Id = @Id, @Date = @Date, @ReferenceNo = @ReferenceNo, @Notes = @Notes,
             @Lines = @Lines, @UserId = @UserId, @PostingId = @PostingId OUTPUT, @DocumentNumber = @DocumentNumber OUTPUT,
             @PostedWithId = NULL;

        UPDATE inventory.TransferOrders SET UpdatedAtUtc = @Now, UpdatedBy = @UserId WHERE Id = @Id;

        SELECT @Received = TotalQuantityBase, @Lost = TotalLostBase FROM inventory.TransferPostings WHERE Id = @PostingId;

        INSERT INTO inventory.TransferOrderAudit (TransferOrderId, PostingId, Action, Details, UserId)
        SELECT @Id, @PostingId, N'Received',
               LEFT(@DocumentNumber + N': ' + CAST(@Received AS NVARCHAR(20)) + N' pcs received from ' + ISNULL(d.List, N'')
                    + CASE WHEN d.N > 3 THEN N' and ' + CAST(d.N - 3 AS NVARCHAR(10)) + N' more' ELSE N'' END
                    + CASE WHEN @Lost > 0 THEN N'; ' + CAST(@Lost AS NVARCHAR(20)) + N' pc(s) written off (' + ISNULL(rs.Names, N'') + N')' ELSE N'' END
                    + N'.', 500),
               @UserId
        FROM (SELECT N = COUNT(*),
                     List = (SELECT STRING_AGG(t.DocumentNumber, N', ') WITHIN GROUP (ORDER BY t.PostedAtUtc, t.Id)
                             FROM (SELECT TOP (3) dp.Id, dp.DocumentNumber, dp.PostedAtUtc
                                   FROM inventory.TransferPostings dp
                                   WHERE EXISTS (SELECT 1 FROM inventory.TransferPostingLines rl
                                                 INNER JOIN inventory.TransferPostingLines dl ON dl.Id = rl.DispatchLineId
                                                 WHERE rl.PostingId = @PostingId AND dl.PostingId = dp.Id)
                                   ORDER BY dp.PostedAtUtc, dp.Id) t)
              FROM inventory.TransferPostings dp
              WHERE EXISTS (SELECT 1 FROM inventory.TransferPostingLines rl
                            INNER JOIN inventory.TransferPostingLines dl ON dl.Id = rl.DispatchLineId
                            WHERE rl.PostingId = @PostingId AND dl.PostingId = dp.Id)) d
        CROSS APPLY (SELECT Names = STRING_AGG(n.Name, N', ') WITHIN GROUP (ORDER BY n.Sort)
                     FROM (SELECT DISTINCT v.Name, v.Sort
                           FROM inventory.TransferPostingLines rl
                           INNER JOIN (VALUES (N'DAMAGED', N'Damaged', 1), (N'MISSING', N'Missing / stolen', 2),
                                              (N'DISPATCHCOUNT', N'Wrongly counted at dispatch', 3), (N'OTHER', N'Other', 4)) v (Code, Name, Sort)
                                   ON v.Code = rl.LossReasonCode
                           WHERE rl.PostingId = @PostingId AND rl.LostBase > 0) n) rs;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT PostingId = @PostingId, DocumentNumber = @DocumentNumber, ReceivedBase = @Received, LostBase = @Lost;
END
GO

/* 13.20 DISPATCH AND RECEIVE (Blocks, DispatchAndReceive: Dispatch's rules and TRR active; FB decision 17) - one date,
   one transaction: the dispatch core with ETA = the date, then the receipt core with one row per new dispatch line
   (received = all of it, nothing lost), the same date, PostedWithId = the dispatch. Any refusal of either rolls both
   back, numbers included (the number sequences are written in this transaction). Earlier dispatches on the way are
   untouched. Dispatch's parameters; @Eta is not read. Result set: DispatchPostingId, DispatchNumber, ReceiptPostingId,
   ReceiptNumber; @PostingId / @DocumentNumber = the dispatch's. */
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_DispatchAndReceive
    @Id             INT,
    @RowVersion     BINARY(8)      = NULL,
    @Date           DATE,
    @Eta            DATE           = NULL,      -- not read: the goods arrive on @Date
    @ReferenceNo    NVARCHAR(100)  = NULL,
    @Notes          NVARCHAR(1000) = NULL,
    @Lines          inventory.tvp_TransferDispatchLine READONLY,
    @UserId         INT            = NULL,
    @PostingId      INT            = NULL OUTPUT,
    @DocumentNumber NVARCHAR(30)   = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @Status TINYINT, @Now DATETIME2(3) = SYSUTCDATETIME(),
            @ReceiptId INT, @ReceiptNumber NVARCHAR(30), @Pcs INT;
    DECLARE @Receipt inventory.tvp_TransferReceiptLine;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = Status FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NOT NULL AND @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;

        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
        WHERE b.Action = N'DispatchAndReceive' AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        EXEC inventory.usp_TransferOrder_DispatchCore @Id = @Id, @Date = @Date, @Eta = @Date, @ReferenceNo = @ReferenceNo,
             @Notes = @Notes, @Lines = @Lines, @UserId = @UserId,
             @PostingId = @PostingId OUTPUT, @DocumentNumber = @DocumentNumber OUTPUT;

        -- the receipt takes exactly what was just dispatched
        INSERT INTO @Receipt (DispatchLineId, ReceivedBase, NothingMoreWillArrive, LossReasonCode, LossNote)
        SELECT pl.Id, pl.QuantityBase, 0, NULL, NULL
        FROM inventory.TransferPostingLines pl
        WHERE pl.PostingId = @PostingId;

        EXEC inventory.usp_TransferOrder_ReceiveCore @Id = @Id, @Date = @Date, @ReferenceNo = @ReferenceNo, @Notes = @Notes,
             @Lines = @Receipt, @UserId = @UserId, @PostingId = @ReceiptId OUTPUT, @DocumentNumber = @ReceiptNumber OUTPUT,
             @PostedWithId = @PostingId;

        UPDATE inventory.TransferOrders SET UpdatedAtUtc = @Now, UpdatedBy = @UserId WHERE Id = @Id;

        SELECT @Pcs = TotalQuantityBase FROM inventory.TransferPostings WHERE Id = @PostingId;
        INSERT INTO inventory.TransferOrderAudit (TransferOrderId, PostingId, Action, Details, UserId)
        SELECT @Id, @PostingId, N'DispatchedAndReceived',
               LEFT(@DocumentNumber + N' and ' + @ReceiptNumber + N': ' + CAST(@Pcs AS NVARCHAR(20)) + N' pcs from '
                    + fw.WarehouseCode + N' to ' + tw.WarehouseCode + N' on ' + CONVERT(NVARCHAR(10), @Date, 103) + N'.', 500),
               @UserId
        FROM inventory.TransferOrders o
        INNER JOIN masterdata.Warehouses fw ON fw.Id = o.FromWarehouseId
        INNER JOIN masterdata.Warehouses tw ON tw.Id = o.ToWarehouseId
        WHERE o.Id = @Id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT DispatchPostingId = @PostingId, DispatchNumber = @DocumentNumber,
           ReceiptPostingId = @ReceiptId, ReceiptNumber = @ReceiptNumber;
END
GO

/* 13.21 NOTHING MORE WILL BE SENT (Blocks, NothingMoreSent: a released order with something dispatched and something
   left to dispatch, not closed yet; then the reason; FB decision 6). What is left to dispatch on every line becomes Not
   sent; Ordered stays as it is; goods on the way can still be received; a dispatch reversed afterwards adds its pieces
   to Not sent (usp_TransferPosting_Reverse). No reopen: a new order covers it. */
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_NothingMoreSent
    @Id         INT,
    @RowVersion BINARY(8)     = NULL,
    @Reason     NVARCHAR(300) = NULL,
    @UserId     INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @Status TINYINT, @Now DATETIME2(3) = SYSUTCDATETIME(), @NotSent INT;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = Status FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NOT NULL AND @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;

        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
        WHERE b.Action = N'NothingMoreSent' AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        IF @Reason IS NULL THROW 62000, 'A reason is required: why will nothing more be sent?', 1;

        SELECT @NotSent = ISNULL(SUM(CASE WHEN OrderedBase - DispatchedBase - NotSentBase > 0
                                          THEN OrderedBase - DispatchedBase - NotSentBase ELSE 0 END), 0)
        FROM inventory.TransferOrderLines WHERE TransferOrderId = @Id;

        UPDATE inventory.TransferOrderLines
        SET NotSentBase = NotSentBase + CASE WHEN OrderedBase - DispatchedBase - NotSentBase > 0
                                             THEN OrderedBase - DispatchedBase - NotSentBase ELSE 0 END
        WHERE TransferOrderId = @Id;

        UPDATE inventory.TransferOrders
        SET NotSentAtUtc = @Now, NotSentBy = @UserId, NotSentReason = @Reason,
            UpdatedAtUtc = @Now, UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO inventory.TransferOrderAudit (TransferOrderId, Action, Details, UserId)
        VALUES (@Id, N'NothingMoreSent', LEFT(CAST(@NotSent AS NVARCHAR(20)) + N' pcs not sent: ' + @Reason, 500), @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* 13.22 CANCEL ORDER (Blocks, Cancel: a released order with nothing dispatched - a reversed dispatch counts as none - then
   the reason; FB decision 9). No stock effect; the order keeps its number. A draft is deleted instead, an order waiting
   for approval is withdrawn first. */
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_Cancel
    @Id         INT,
    @RowVersion BINARY(8)     = NULL,
    @Reason     NVARCHAR(300) = NULL,
    @UserId     INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @Status TINYINT, @Now DATETIME2(3) = SYSUTCDATETIME();

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = Status FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NOT NULL AND @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;

        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
        WHERE b.Action = N'Cancel' AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        IF @Reason IS NULL THROW 62000, 'A cancellation reason is required.', 1;

        UPDATE inventory.TransferOrders
        SET Status = 3, CancelledAtUtc = @Now, CancelledBy = @UserId, CancelReason = @Reason,
            UpdatedAtUtc = @Now, UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO inventory.TransferOrderAudit (TransferOrderId, Action, Details, UserId)
        VALUES (@Id, N'Cancelled', LEFT(@Reason, 500), @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* 13.23 REVERSE ONE WHOLE DISPATCH OR RECEIPT, in place (FB decision 8, T23-T24). The posting's order is locked and its
   RowVersion checked (@RowVersion is the ORDER's); then the order's rule (Blocks, ReverseDispatch / ReverseReceipt) and
   the posting's (fn_TransferPosting_ReverseBlock: not reversed yet; a dispatch after the receipts of its goods; a receipt
   while the destination still holds what it brought) - a reverse that can never go through says so before it asks for a
   reason (script 83) - then the reason and the date (today by default, at most one day ahead, not before the posting).
   Every ledger row of the posting gets its opposite (every column copied, ExpiryDate included; the pieces negated;
   IsReversal 1; CreatedBy the acting user), dated the reversal date at the time it is done but never before the rows it
   undoes + 1 second - for a dispatch, never before any row of a receipt of its lines in its On the way warehouse either
   (a receipt reversed later than the dispatch's reversal date would otherwise leave the On the way warehouse below 0 in
   between). A dispatch takes its pieces off the order lines' Dispatched (and adds them to Not sent on a closed order:
   it stays closed); a receipt takes its pieces off its dispatch lines' Settled and the order lines' Received and Lost
   (its goods are back On the way, its write-off undone). The posting is marked Reversed with the date, the reason and
   who. The cost replay leaves a reversed posting out with its reversal; no partial reversal.
   A RECEIPT THAT WROTE PIECES OFF changes the company's stock when it is reversed (the lost pieces come back at the
   average frozen on the loss, which may have moved since): its items' costs are REPLAYED (inventory.usp_Item_RebuildCosts),
   as every cancel that writes reversal rows (M4, script 89), under the goods receipt matching lock taken first (89's
   order: the matcher, then the document), giving way in a deadlock (DEADLOCK_PRIORITY LOW: the API runs it again). A
   dispatch, or a receipt without a loss, leaves the company's stock as it was: no replay. A receipt's reversal takes
   pieces out of To: it holds the dispatch lock of To (inventory.TransferDispatch.{To}) before it checks To's stock,
   so a dispatch from To cannot pass its stock check on the same pieces at the same time. */
CREATE OR ALTER PROCEDURE inventory.usp_TransferPosting_Reverse
    @PostingId  INT,
    @RowVersion BINARY(8)     = NULL,     -- the ORDER's
    @Reason     NVARCHAR(300) = NULL,
    @Date       DATE          = NULL,
    @UserId     INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET DEADLOCK_PRIORITY LOW;      -- the replay of a reversed loss reads the item's ledger: the reverse gives way, the API runs it again

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @OrderId INT, @Status TINYINT, @Kind NVARCHAR(10), @TypeCode NVARCHAR(20),
            @Number NVARCHAR(30), @PostingDate DATE, @NotSentAt DATETIME2(3),
            @Now DATETIME2(3) = SYSUTCDATETIME(), @ReversalAt DATETIME2(3), @Latest DATETIME2(3), @LatestReceipts DATETIME2(3),
            @ToId INT, @Resource NVARCHAR(255), @Lock INT, @ItemId INT;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- a receipt that wrote pieces off: the matching lock first, for the replay below (89's lock order)
        IF EXISTS (SELECT 1 FROM inventory.TransferPostings
                   WHERE Id = @PostingId AND Kind = N'Receipt' AND Status = 2 AND TotalLostBase > 0)
            EXEC purchase.usp_GoodsReceipt_LockMatching;

        SELECT @OrderId = TransferOrderId FROM inventory.TransferPostings WHERE Id = @PostingId;
        IF @OrderId IS NULL
        BEGIN
            SELECT TOP (1) @ErrNo = q.ErrorNumber, @Msg = q.Message
            FROM inventory.fn_TransferPosting_ReverseBlock(@PostingId) q
            WHERE q.Message IS NOT NULL
            ORDER BY q.Seq;
            SELECT @ErrNo = ISNULL(@ErrNo, 62006), @Msg = ISNULL(@Msg, N'Dispatch or receipt not found.');
            THROW @ErrNo, @Msg, 1;
        END

        SELECT @Status = Status, @NotSentAt = NotSentAtUtc
        FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @OrderId;
        IF @Status IS NOT NULL AND @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @OrderId AND RowVersion = @RowVersion)
            THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;

        SELECT @Kind = Kind, @Number = DocumentNumber, @PostingDate = PostingDate, @ToId = ToWarehouseId,
               @TypeCode = CASE Kind WHEN N'Dispatch' THEN N'TRD' ELSE N'TRR' END
        FROM inventory.TransferPostings WITH (UPDLOCK, HOLDLOCK) WHERE Id = @PostingId;

        -- a receipt takes its pieces back out of To: one stock check at a time on To, with the dispatches from To
        -- (inventory.usp_TransferOrder_DispatchCore step 5; the same order: the order header, then the warehouse)
        IF @Kind = N'Receipt'
        BEGIN
            SET @Resource = N'inventory.TransferDispatch.' + CAST(@ToId AS NVARCHAR(10));
            EXEC @Lock = sp_getapplock @Resource = @Resource, @LockMode = N'Exclusive', @LockOwner = N'Transaction', @LockTimeout = 30000;
            IF @Lock < 0
            BEGIN
                SELECT @Msg = N'Another dispatch from ' + ISNULL((SELECT WarehouseCode FROM masterdata.Warehouses WHERE Id = @ToId), N'this warehouse')
                              + N' is being posted. Try again in a moment.';
                THROW 62010, @Msg, 1;
            END
        END

        -- the order's rule first, then the posting's own
        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@OrderId, @UserId) b
        WHERE b.Action = CASE @Kind WHEN N'Dispatch' THEN N'ReverseDispatch' ELSE N'ReverseReceipt' END AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        SELECT TOP (1) @ErrNo = q.ErrorNumber, @Msg = q.Message
        FROM inventory.fn_TransferPosting_ReverseBlock(@PostingId) q
        WHERE q.Message IS NOT NULL
        ORDER BY q.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        IF @Reason IS NULL THROW 62000, 'A reason is required to reverse it.', 1;

        IF @Date IS NULL SET @Date = CAST(@Now AS DATE);
        IF @Date > DATEADD(DAY, 1, CAST(@Now AS DATE)) THROW 62000, 'The reversal date cannot be in the future.', 1;
        IF @Date < @PostingDate
        BEGIN
            SET @Msg = N'The reversal cannot be dated before ' + @Number + N' (' + CONVERT(NVARCHAR(10), @PostingDate, 103) + N').';
            THROW 62000, @Msg, 1;
        END

        -- its own rows only; a posting without any is refused rather than marked reversed (inventory.usp_StockDocument_Cancel, 89)
        IF NOT EXISTS (SELECT 1 FROM inventory.StockMovements m
                       WHERE m.DocumentFamily = N'Transfer' AND m.DocumentTypeCode = @TypeCode AND m.DocumentId = @PostingId AND m.IsReversal = 0)
            THROW 62010, 'This dispatch or receipt has no stock movements of its own to reverse. Ask the administrator to check the stock ledger.', 1;

        -- the date of the reversal rows: see the header
        SET @ReversalAt = DATEADD(SECOND, DATEDIFF(SECOND, CAST(@Now AS DATE), @Now), CAST(@Date AS DATETIME2(3)));
        SELECT @Latest = MAX(m.MovementDate)
        FROM inventory.StockMovements m
        WHERE m.DocumentFamily = N'Transfer' AND m.DocumentTypeCode = @TypeCode AND m.DocumentId = @PostingId;
        IF @Kind = N'Dispatch'
            SELECT @LatestReceipts = MAX(m.MovementDate)
            FROM inventory.TransferPostingLines dl
            INNER JOIN inventory.TransferPostingLines rl ON rl.DispatchLineId = dl.Id
            INNER JOIN inventory.StockMovements m ON m.DocumentFamily = N'Transfer' AND m.DocumentTypeCode = N'TRR'
                                                 AND m.DocumentId = rl.PostingId AND m.DocumentLineId = rl.Id
                                                 AND m.WarehouseId = dl.TransitWarehouseId
            WHERE dl.PostingId = @PostingId;
        IF @LatestReceipts > @Latest SET @Latest = @LatestReceipts;
        IF @Latest IS NOT NULL AND @ReversalAt < DATEADD(SECOND, 1, @Latest)
            SET @ReversalAt = DATEADD(SECOND, 1, @Latest);

        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber,
                                              ReasonCode, ExpiryDate, IsReversal, CreatedBy)
        SELECT @ReversalAt, m.ItemId, m.WarehouseId, m.BranchId, -m.QuantityBase, m.UnitCostBase,
               m.DocumentFamily, m.DocumentTypeCode, m.DocumentId, m.DocumentLineId, m.DocumentNumber,
               m.ReasonCode, m.ExpiryDate, 1, @UserId
        FROM inventory.StockMovements m
        WHERE m.DocumentFamily = N'Transfer' AND m.DocumentTypeCode = @TypeCode AND m.DocumentId = @PostingId AND m.IsReversal = 0
        ORDER BY m.Id;

        IF @Kind = N'Dispatch'
        BEGIN
            -- its pieces leave the order's Dispatched; on a closed order they become Not sent (it stays closed)
            UPDATE l SET DispatchedBase = l.DispatchedBase - x.Qty,
                         NotSentBase    = l.NotSentBase + CASE WHEN @NotSentAt IS NOT NULL THEN x.Qty ELSE 0 END
            FROM inventory.TransferOrderLines l
            INNER JOIN (SELECT TransferOrderLineId, Qty = SUM(QuantityBase) FROM inventory.TransferPostingLines
                        WHERE PostingId = @PostingId GROUP BY TransferOrderLineId) x ON x.TransferOrderLineId = l.Id;
        END
        ELSE
        BEGIN
            -- its goods are back On the way, its write-off undone
            UPDATE dl SET SettledBase = dl.SettledBase - x.Qty
            FROM inventory.TransferPostingLines dl
            INNER JOIN (SELECT DispatchLineId, Qty = SUM(QuantityBase + LostBase) FROM inventory.TransferPostingLines
                        WHERE PostingId = @PostingId GROUP BY DispatchLineId) x ON x.DispatchLineId = dl.Id;

            UPDATE l SET ReceivedBase = l.ReceivedBase - x.Received, LostBase = l.LostBase - x.Lost
            FROM inventory.TransferOrderLines l
            INNER JOIN (SELECT TransferOrderLineId, Received = SUM(QuantityBase), Lost = SUM(LostBase) FROM inventory.TransferPostingLines
                        WHERE PostingId = @PostingId GROUP BY TransferOrderLineId) x ON x.TransferOrderLineId = l.Id;
        END

        UPDATE inventory.TransferPostings
        SET Status = 3, ReversedAtUtc = @Now, ReversedBy = @UserId, ReverseDate = @Date, ReverseReason = @Reason
        WHERE Id = @PostingId;

        -- a receipt's write-off undone: the company's stock changed, so its items' costs are replayed (see the header)
        IF @Kind = N'Receipt'
        BEGIN
            DECLARE items CURSOR LOCAL FAST_FORWARD FOR
                SELECT DISTINCT ItemId FROM inventory.TransferPostingLines WHERE PostingId = @PostingId AND LostBase > 0;
            OPEN items; FETCH NEXT FROM items INTO @ItemId;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC inventory.usp_Item_RebuildCosts @ItemId;
                FETCH NEXT FROM items INTO @ItemId;
            END
            CLOSE items; DEALLOCATE items;
        END

        UPDATE inventory.TransferOrders SET UpdatedAtUtc = @Now, UpdatedBy = @UserId WHERE Id = @OrderId;

        INSERT INTO inventory.TransferOrderAudit (TransferOrderId, PostingId, Action, Details, UserId)
        VALUES (@OrderId, @PostingId, N'Reversed',
                LEFT(@Number + N' reversed on ' + CONVERT(NVARCHAR(10), @Date, 103) + N': ' + @Reason, 500), @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* 13.24 CHANGE A DISPATCH'S ETA (D12: trucks are late). The posting's order is locked and its RowVersion checked
   (@RowVersion is the ORDER's); the order's rule (Blocks, ChangeEta), then: a posted dispatch with goods on the way
   (62010), the ETA required and not before the dispatch date. Nothing changed: nothing written. Audit EtaChanged
   "{TRD}: ETA {old} -> {new}". */
CREATE OR ALTER PROCEDURE inventory.usp_TransferPosting_SetEta
    @PostingId  INT,
    @RowVersion BINARY(8) = NULL,     -- the ORDER's
    @Eta        DATE      = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @OrderId INT, @Status TINYINT, @Kind NVARCHAR(10), @PStatus TINYINT,
            @Number NVARCHAR(30), @PostingDate DATE, @OldEta DATE, @OnTheWay INT, @Now DATETIME2(3) = SYSUTCDATETIME();

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @OrderId = TransferOrderId FROM inventory.TransferPostings WHERE Id = @PostingId;
        IF @OrderId IS NULL THROW 62006, 'Dispatch or receipt not found.', 1;

        SELECT @Status = Status FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @OrderId;
        IF @Status IS NOT NULL AND @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @OrderId AND RowVersion = @RowVersion)
            THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;

        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@OrderId, @UserId) b
        WHERE b.Action = N'ChangeEta' AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        SELECT @Kind = p.Kind, @PStatus = p.Status, @Number = p.DocumentNumber, @PostingDate = p.PostingDate, @OldEta = p.Eta,
               @OnTheWay = (SELECT ISNULL(SUM(pl.QuantityBase - pl.SettledBase), 0) FROM inventory.TransferPostingLines pl WHERE pl.PostingId = p.Id)
        FROM inventory.TransferPostings p WITH (UPDLOCK, HOLDLOCK)
        WHERE p.Id = @PostingId;

        IF NOT (@Kind = N'Dispatch' AND @PStatus = 2 AND @OnTheWay > 0)
            THROW 62010, 'Only a dispatch with goods on the way can change its ETA.', 1;
        IF @Eta IS NULL THROW 62000, 'The ETA is required.', 1;
        IF @Eta < @PostingDate THROW 62000, 'The ETA cannot be before the dispatch date.', 1;

        IF @Eta <> @OldEta
        BEGIN
            UPDATE inventory.TransferPostings SET Eta = @Eta WHERE Id = @PostingId;

            -- the order's RowVersion moves: Late and the page's figures follow the new ETA
            UPDATE inventory.TransferOrders SET UpdatedAtUtc = @Now, UpdatedBy = @UserId WHERE Id = @OrderId;

            INSERT INTO inventory.TransferOrderAudit (TransferOrderId, PostingId, Action, Details, UserId)
            VALUES (@OrderId, @PostingId, N'EtaChanged',
                    LEFT(@Number + N': ETA ' + ISNULL(CONVERT(NVARCHAR(10), @OldEta, 103), N'none') + N' -> '
                         + CONVERT(NVARCHAR(10), @Eta, 103), 500), @UserId);
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* 13.25 CREATE A RETURN (Blocks, CreateReturn: something received that the returns not cancelled do not already take
   back; FB decision 26, D15): a new DRAFT through Save's insert path - From = the original's To, To = its From (the
   warehouse rules apply: one made inactive since refuses), dated today, no Expected arrival, Reference "Return of
   {No}", linked to the original (ReturnOfOrderId). One line per item, in the order of its first line on the original:
   ReturnableBase = what the original received of the item - what its returns not cancelled (drafts included) already
   order of it, when above 0; in the unit of the item's first line when ReturnableBase is a whole number of that unit
   (its packing formula unchanged since: Save takes the unit's current one), else in the base unit; that line's notes.
   The original's counters never change. Audit ReturnCreated on the new order ("Return of {No}"), ReturnOf on the
   original ("Return {TRO} created"). @NewId = the new draft. */
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_CreateReturn
    @Id     INT,
    @UserId INT = NULL,
    @NewId  INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @NewId = NULL;
    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @Status TINYINT, @No NVARCHAR(30), @FromId INT, @ToId INT,
            @Today DATE = CAST(SYSUTCDATETIME() AS DATE), @Reference NVARCHAR(100), @NewNumber NVARCHAR(30);
    DECLARE @Lines inventory.tvp_TransferOrderLine;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = Status, @No = DocumentNumber, @FromId = FromWarehouseId, @ToId = ToWarehouseId
        FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;

        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
        WHERE b.Action = N'CreateReturn' AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        -- What can still be returned, per item (the rule of Blocks Seq 121)
        DECLARE @X TABLE (ItemId INT NOT NULL PRIMARY KEY, FirstLine INT NOT NULL, Returnable INT NOT NULL);
        INSERT INTO @X (ItemId, FirstLine, Returnable)
        SELECT r.ItemId, r.FirstLine,
               r.Received - ISNULL((SELECT SUM(rl.OrderedBase)
                                    FROM inventory.TransferOrderLines rl
                                    INNER JOIN inventory.TransferOrders ro ON ro.Id = rl.TransferOrderId
                                    WHERE ro.ReturnOfOrderId = @Id AND ro.Status <> 3 AND rl.ItemId = r.ItemId), 0)
        FROM (SELECT l.ItemId, FirstLine = MIN(l.LineNumber), Received = SUM(l.ReceivedBase)
              FROM inventory.TransferOrderLines l
              WHERE l.TransferOrderId = @Id
              GROUP BY l.ItemId) r;
        DELETE FROM @X WHERE Returnable <= 0;

        -- an item without a base unit cannot take a quantity that is not a whole number of its first line's unit
        SELECT TOP (1) @Msg = N'Item ' + i.ItemCode + N' has no base unit: give it one in Item Definition, then create the return.'
        FROM @X x
        INNER JOIN inventory.TransferOrderLines fl ON fl.TransferOrderId = @Id AND fl.LineNumber = x.FirstLine
        INNER JOIN inventory.ItemUnits fu          ON fu.Id = fl.ItemUnitId
        INNER JOIN inventory.Items i               ON i.Id = x.ItemId
        WHERE NOT (x.Returnable % fl.PackingFormula = 0 AND fu.PackingFormula = fl.PackingFormula)
          AND NOT EXISTS (SELECT 1 FROM inventory.ItemUnits bu WHERE bu.ItemId = x.ItemId AND bu.IsBaseUnit = 1)
        ORDER BY x.FirstLine;
        IF @Msg IS NOT NULL THROW 62000, @Msg, 1;

        INSERT INTO @Lines (LineNumber, ItemId, ItemUnitId, Quantity, Notes)
        SELECT ROW_NUMBER() OVER (ORDER BY x.FirstLine), x.ItemId,
               CASE WHEN u.WholeUnits = 1 THEN fl.ItemUnitId ELSE bu.Id END,
               CASE WHEN u.WholeUnits = 1 THEN x.Returnable / fl.PackingFormula ELSE x.Returnable END,
               fl.Notes
        FROM @X x
        INNER JOIN inventory.TransferOrderLines fl ON fl.TransferOrderId = @Id AND fl.LineNumber = x.FirstLine
        INNER JOIN inventory.ItemUnits fu          ON fu.Id = fl.ItemUnitId
        CROSS APPLY (SELECT WholeUnits = CASE WHEN x.Returnable % fl.PackingFormula = 0 AND fu.PackingFormula = fl.PackingFormula
                                              THEN 1 ELSE 0 END) u
        OUTER APPLY (SELECT TOP (1) b.Id FROM inventory.ItemUnits b WHERE b.ItemId = x.ItemId AND b.IsBaseUnit = 1) bu;

        -- The new draft: Save's own insert path (its checks, its number, its Created audit row), in this transaction
        SET @Reference = N'Return of ' + ISNULL(@No, N'a transfer order');
        EXEC inventory.usp_TransferOrder_Save @Id = NULL, @DocumentDate = @Today, @FromWarehouseId = @ToId, @ToWarehouseId = @FromId,
             @ExpectedArrival = NULL, @ReferenceNo = @Reference, @Notes = NULL, @Lines = @Lines, @RowVersion = NULL,
             @UserId = @UserId, @NewId = @NewId OUTPUT;

        UPDATE inventory.TransferOrders SET ReturnOfOrderId = @Id WHERE Id = @NewId;
        SELECT @NewNumber = DocumentNumber FROM inventory.TransferOrders WHERE Id = @NewId;

        INSERT INTO inventory.TransferOrderAudit (TransferOrderId, Action, Details, UserId)
        VALUES (@NewId, N'ReturnCreated', LEFT(@Reference, 500), @UserId),
               (@Id, N'ReturnOf', CASE WHEN @NewNumber IS NOT NULL THEN N'Return ' + @NewNumber + N' created'
                                       ELSE N'Return created (a draft, numbered when released)' END, @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 14. The cost replay: a transfer moves no cost */

-- Re-created (90) from the body of script 79: + the incoming legs of a transfer (family Transfer, quantity above 0: the
-- On the way warehouse at a dispatch, the destination at a receipt) enter at the RUNNING AVERAGE, not at the cost frozen
-- on the row (FB rule 34). The receipt branch reads ISNULL(@ECost, @Avg): a NULL cost leaves the average where it is,
-- whatever the running balance. The outgoing legs and the losses (TRF_LOSS) are issues, as every out: the average does
-- not move. A reversed posting is left out with its reversal, as every family's. Every other family reads
-- m.UnitCostBase as before, so the replay of a database without transfers gives the same costs as before.
CREATE OR ALTER PROCEDURE inventory.usp_Item_RebuildCosts
    @ItemId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Events TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, ItemId INT, Qty INT, Cost DECIMAL(18,6), Amount DECIMAL(18,2));
    INSERT INTO @Events (ItemId, Qty, Cost, Amount)
    SELECT x.ItemId, x.Qty, x.Cost, x.Amount
    FROM
    (
        SELECT m.ItemId, EventDate = m.MovementDate, Src = 1, SrcId = m.Id, Qty = m.QuantityBase,
               -- (90) A TRANSFER MOVES NO COST: its incoming legs (On the way, the destination) enter at the running average.
               Cost = CASE WHEN m.DocumentFamily = N'Transfer' AND m.QuantityBase > 0 THEN NULL ELSE m.UnitCostBase END,
               Amount = CAST(NULL AS DECIMAL(18,2))
        FROM inventory.StockMovements m
        WHERE (@ItemId IS NULL OR m.ItemId = @ItemId)
          AND NOT EXISTS (SELECT 1 FROM inventory.StockMovements r WHERE r.DocumentFamily = m.DocumentFamily AND r.DocumentTypeCode = m.DocumentTypeCode
                                                                     AND r.DocumentId = m.DocumentId AND r.IsReversal = 1
                                                                     AND (m.DocumentTypeCode <> N'CNT' OR r.DocumentNumber = m.DocumentNumber))
        UNION ALL
        SELECT c.ItemId, c.AdjustmentDate, 2, CAST(c.Id AS INT), 0, NULL, c.AmountBase
        FROM inventory.CostAdjustments c
        WHERE c.Kind = N'Inventory' AND (@ItemId IS NULL OR c.ItemId = @ItemId)
    ) x
    ORDER BY x.ItemId, x.EventDate, x.Src, x.SrcId;

    DECLARE @Result TABLE (ItemId INT PRIMARY KEY, AverageCost DECIMAL(18,6));
    DECLARE @CurItem INT = NULL, @OnHand DECIMAL(18,6) = 0, @Avg DECIMAL(18,6) = 0;
    DECLARE @EItem INT, @EQty INT, @ECost DECIMAL(18,6), @EAmount DECIMAL(18,2);

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT ItemId, Qty, Cost, Amount FROM @Events ORDER BY Seq;
    OPEN cur;
    FETCH NEXT FROM cur INTO @EItem, @EQty, @ECost, @EAmount;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @CurItem IS NULL OR @CurItem <> @EItem
        BEGIN
            IF @CurItem IS NOT NULL INSERT INTO @Result (ItemId, AverageCost) VALUES (@CurItem, @Avg);
            SELECT @CurItem = @EItem, @OnHand = 0, @Avg = 0;
        END

        IF @EAmount IS NOT NULL                                   -- inventory value adjustment (LCA)
            SET @Avg = CASE WHEN @OnHand > 0 THEN @Avg + @EAmount / @OnHand ELSE @Avg END;
        ELSE IF @EQty > 0                                         -- receipt
        BEGIN
            SET @Avg = CASE WHEN @OnHand + @EQty > 0 THEN ((CASE WHEN @OnHand > 0 THEN @OnHand ELSE 0 END) * @Avg + @EQty * ISNULL(@ECost, @Avg)) / ((CASE WHEN @OnHand > 0 THEN @OnHand ELSE 0 END) + @EQty) ELSE @Avg END;
            SET @OnHand = @OnHand + @EQty;
        END
        ELSE                                                      -- issue: average unchanged
            SET @OnHand = @OnHand + @EQty;

        FETCH NEXT FROM cur INTO @EItem, @EQty, @ECost, @EAmount;
    END
    CLOSE cur; DEALLOCATE cur;
    IF @CurItem IS NOT NULL INSERT INTO @Result (ItemId, AverageCost) VALUES (@CurItem, @Avg);

    -- Items with no remaining events (everything cancelled) fall back to 0.
    UPDATE i SET AverageCost = ISNULL(r.AverageCost, 0)
    FROM inventory.Items i
    LEFT JOIN @Result r ON r.ItemId = i.Id
    WHERE (@ItemId IS NULL OR i.Id = @ItemId);

    UPDATE i
    SET LastCost = x.Landed, FobCost = x.Fob, LastSupplierId = x.SupplierId, LastPurchaseAtUtc = x.ReceivedAtUtc
    FROM inventory.Items i
    OUTER APPLY (SELECT TOP (1) r.Landed, r.Fob, r.SupplierId, r.ReceivedAtUtc
                 FROM (-- (65) (a) a local invoice posted before goods receipts (it received its goods when posted)
                       SELECT Landed = l.UnitCostBase, Fob = l.FobCostBase, d.SupplierId, ReceivedAtUtc = d.PostedAtUtc, Tie = l.Id
                       FROM purchase.PurchaseDocumentLines l
                       INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
                       INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                       WHERE dt.Code = N'PINV' AND d.Status = 2 AND d.ReceiptMode = 1 AND d.UsesGoodsReceipts = 0 AND l.ItemId = i.Id
                       UNION ALL
                       -- (65) (b) a container offloaded before goods receipts (a container received with one is (c))
                       SELECT cl.LandedCostBase, cl.FobCostBase, po.SupplierId, c.OffloadedAtUtc, cl.Id
                       FROM logistics.ContainerLines cl
                       INNER JOIN logistics.Containers c        ON c.Id = cl.ContainerId
                       INNER JOIN purchase.PurchaseDocuments po ON po.Id = cl.PurchaseOrderId
                       CROSS APPLY logistics.fn_Container_ReceivedBy(c.Id) rb
                       WHERE rb.ReceivedBy = N'Offload' AND cl.ItemId = i.Id AND cl.ReceivedQuantityBase > 0
                       UNION ALL
                       -- (65) (c) a posted goods receipt line with pieces; a manual line only once matched to an invoice
                       SELECT CASE WHEN gl.ContainerLineId IS NOT NULL THEN gcl.LandedCostBase ELSE gl.UnitCostBase END,
                              CASE WHEN gl.ContainerLineId IS NOT NULL THEN gcl.FobCostBase ELSE gl.FobCostBase END,
                              gl.SupplierId, g.PostedAtUtc, gl.Id
                       FROM purchase.GoodsReceiptLines gl
                       INNER JOIN purchase.GoodsReceipts g      ON g.Id = gl.GoodsReceiptId AND g.Status = 2
                       LEFT  JOIN logistics.ContainerLines gcl  ON gcl.Id = gl.ContainerLineId
                       WHERE gl.ItemId = i.Id AND gl.QuantityBase > 0
                         -- (79) a line without an order - manual, or from an invoice that does not change item
                         --      costs - counts once matched to an invoice that does: its cost is not a purchase price
                         AND NOT (gl.PoLineId IS NULL
                                  AND (gl.InvoiceLineId IS NULL
                                       OR EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines p
                                                  INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = p.DocumentId
                                                  WHERE p.Id = gl.InvoiceLineId AND pd.AffectsCost = 0))
                                  AND NOT EXISTS (SELECT 1 FROM purchase.GoodsReceiptInvoiceMatches x
                                                  INNER JOIN purchase.PurchaseDocumentLines p ON p.Id = x.InvoiceLineId
                                                  INNER JOIN purchase.PurchaseDocuments pd    ON pd.Id = p.DocumentId
                                                  WHERE x.GoodsReceiptLineId = gl.Id AND pd.AffectsCost = 1))) r
                 ORDER BY r.ReceivedAtUtc DESC, r.Tie DESC) x
    WHERE (@ItemId IS NULL OR i.Id = @ItemId);
END
GO

/* ================================================================== 15. Item stock statement: the transfer rows */

-- Re-created (90) from the body of script 65: + a transfer row (family Transfer, a dispatch TRD or a receipt TRR) says
-- where the goods went, "LKS-01 -> LUB-01" (the posting's From and To, both legs of it alike) in Counterparty, the
-- transfer order's number in SourceReference, and the order's id in the new last column TransferOrderId (the page's
-- link). NULL on every other row; every other column and row unchanged.
CREATE OR ALTER PROCEDURE inventory.usp_Item_StockStatement
    @ItemId      INT,
    @DateFrom    DATE = NULL,
    @DateTo      DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Opening INT =
        CASE WHEN @DateFrom IS NULL THEN 0 ELSE
            (SELECT ISNULL(SUM(m.QuantityBase), 0) FROM inventory.StockMovements m
             WHERE m.ItemId = @ItemId AND m.MovementDate < @DateFrom) END;

    SELECT OpeningBase = @Opening;

    SELECT m.Id, m.MovementDate, m.DocumentFamily, m.DocumentTypeCode, DocumentTypeName = dt.Name,
           m.DocumentId, m.DocumentNumber, m.IsReversal, m.ReasonCode, m.ExpiryDate,
           m.WarehouseId, w.WarehouseCode, w.WarehouseName, br.BranchName,
           QuantityIn  = CASE WHEN m.QuantityBase > 0 THEN m.QuantityBase ELSE 0 END,
           QuantityOut = CASE WHEN m.QuantityBase < 0 THEN -m.QuantityBase ELSE 0 END,
           Balance     = @Opening + SUM(m.QuantityBase) OVER (ORDER BY m.MovementDate, m.Id ROWS UNBOUNDED PRECEDING),
           m.UnitCostBase,
           -- who the stock went to or came from: the client of a sale, the supplier of a purchase
           Counterparty = COALESCE(cl.PartyName, sp.PartyName,
                                   -- (90) a transfer row: where the goods went, the posting's From -> To ("LKS-01 -> LUB-01")
                                   CASE WHEN tp.Id IS NOT NULL THEN fw.WarehouseCode + N' ' + NCHAR(8594) + N' ' + tw.WarehouseCode END),
           -- (65) a goods receipt's source: its container, else its order, else its invoice
           --      (90) a transfer row's: its transfer order
           SourceReference = CASE WHEN gr.Id IS NOT NULL THEN COALESCE(gc.ContainerRef, gpo.DocumentNumber, gpi.DocumentNumber)
                                  WHEN tro.Id IS NOT NULL THEN tro.DocumentNumber END,
           CreatedByName = u.FullName,
           TransferOrderId = tro.Id                                         -- (90) a TRD / TRR row: its transfer order (the link)
    FROM inventory.StockMovements m
    INNER JOIN masterdata.Warehouses w ON w.Id = m.WarehouseId
    INNER JOIN masterdata.Branches br  ON br.Id = w.BranchId
    LEFT JOIN inventory.DocumentTypes dt ON dt.Code = m.DocumentTypeCode
    LEFT JOIN sales.SalesDocuments sd ON m.DocumentFamily = N'Sales' AND sd.Id = m.DocumentId
    LEFT JOIN masterdata.Parties cl ON cl.Id = sd.ClientId
    LEFT JOIN purchase.PurchaseDocuments pd ON m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode NOT IN (N'CNT', N'GRN') AND pd.Id = m.DocumentId
    -- (65) a goods receipt row: the receipt, its line (the stock row's line), its container, order and invoice
    LEFT JOIN purchase.GoodsReceipts gr ON m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = N'GRN' AND gr.Id = m.DocumentId
    LEFT JOIN purchase.GoodsReceiptLines grl ON grl.Id = m.DocumentLineId AND grl.GoodsReceiptId = gr.Id
    LEFT JOIN logistics.Containers gc ON gc.Id = gr.ContainerId
    LEFT JOIN purchase.PurchaseDocuments gpo ON gpo.Id = COALESCE(grl.PurchaseOrderId, gr.PurchaseOrderId)
    LEFT JOIN purchase.PurchaseDocuments gpi ON gpi.Id = gr.PurchaseInvoiceId
    LEFT JOIN masterdata.Parties sp ON sp.Id = COALESCE(pd.SupplierId, grl.SupplierId, gr.SupplierId)
    -- (90) a transfer row (family Transfer, TRD / TRR): its dispatch or receipt, the order, and the posting's From / To
    LEFT JOIN inventory.TransferPostings tp ON m.DocumentFamily = N'Transfer' AND tp.Id = m.DocumentId
    LEFT JOIN inventory.TransferOrders tro  ON tro.Id = tp.TransferOrderId
    LEFT JOIN masterdata.Warehouses fw      ON fw.Id = tp.FromWarehouseId
    LEFT JOIN masterdata.Warehouses tw      ON tw.Id = tp.ToWarehouseId
    LEFT JOIN security.Users u ON u.Id = m.CreatedBy
    WHERE m.ItemId = @ItemId
      AND (@DateFrom IS NULL OR m.MovementDate >= @DateFrom)
      AND (@DateTo IS NULL OR m.MovementDate < DATEADD(DAY, 1, @DateTo))
    ORDER BY m.MovementDate, m.Id;
END
GO

/* ================================================================== 16. Shortages: "Transfers in" */

-- (90) GOODS ON THE WAY TO A PLAN'S WAREHOUSE ARE "TRANSFERS IN" ON ITS SAVED LINES. One batch, all or nothing: the
--      column (0 on every line saved before), then the four persisted formulas that read "stock + transit + orders"
--      dropped and added again, with the same names and the new term. Dynamic SQL: a column added in this batch can only
--      be read by a statement compiled after it (as script 46 re-adds the family check). SELF-HEALING: it runs while the
--      column is missing or one of the four formulas does not read it, and is a no-op afterwards. The four columns move
--      to the end of the table: every reader names its columns, and no index, view or schema-bound object reads them
--      (the only index, IX_ShortageDocumentLines_Document, is on DocumentId). A plan saved before keeps every figure: its
--      lines get 0. The only drop of script 90 (master specification 2.3.11.2).
IF COL_LENGTH(N'inventory.ShortageDocumentLines', N'TransfersInBase') IS NULL
   OR EXISTS (SELECT 1
              FROM (VALUES (N'StockPlusTransitBase'), (N'TotalExpectedStockBase'), (N'ShortageBase'), (N'CoverageMonths')) f (Name)
              LEFT JOIN sys.computed_columns cc ON cc.object_id = OBJECT_ID(N'inventory.ShortageDocumentLines') AND cc.name = f.Name
              WHERE cc.definition IS NULL OR cc.definition NOT LIKE N'%TransfersInBase%')
BEGIN
    SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        IF COL_LENGTH(N'inventory.ShortageDocumentLines', N'TransfersInBase') IS NULL
            ALTER TABLE inventory.ShortageDocumentLines ADD TransfersInBase INT NOT NULL
                CONSTRAINT DF_ShortageDocumentLines_TransfersIn DEFAULT (0);

        IF COL_LENGTH(N'inventory.ShortageDocumentLines', N'StockPlusTransitBase') IS NOT NULL
            EXEC (N'ALTER TABLE inventory.ShortageDocumentLines DROP COLUMN StockPlusTransitBase;');
        IF COL_LENGTH(N'inventory.ShortageDocumentLines', N'TotalExpectedStockBase') IS NOT NULL
            EXEC (N'ALTER TABLE inventory.ShortageDocumentLines DROP COLUMN TotalExpectedStockBase;');
        IF COL_LENGTH(N'inventory.ShortageDocumentLines', N'ShortageBase') IS NOT NULL
            EXEC (N'ALTER TABLE inventory.ShortageDocumentLines DROP COLUMN ShortageBase;');
        IF COL_LENGTH(N'inventory.ShortageDocumentLines', N'CoverageMonths') IS NOT NULL
            EXEC (N'ALTER TABLE inventory.ShortageDocumentLines DROP COLUMN CoverageMonths;');

        EXEC (N'ALTER TABLE inventory.ShortageDocumentLines ADD
            StockPlusTransitBase   AS (CurrentInventoryBase + TransitBase + TransfersInBase) PERSISTED,
            TotalExpectedStockBase AS (CurrentInventoryBase + TransitBase + TransfersInBase + OutstandingOrderBase) PERSISTED,
            ShortageBase           AS (CASE WHEN ISNULL(ExpectedMonthlySalesManual, ExpectedMonthlySalesBase) * LeadTimeMonths
                                                 - (CurrentInventoryBase + TransitBase + TransfersInBase + OutstandingOrderBase) > 0
                                            THEN CONVERT(INT, CEILING(ISNULL(ExpectedMonthlySalesManual, ExpectedMonthlySalesBase) * LeadTimeMonths
                                                 - (CurrentInventoryBase + TransitBase + TransfersInBase + OutstandingOrderBase))) ELSE 0 END) PERSISTED,
            CoverageMonths         AS (CASE WHEN ISNULL(ExpectedMonthlySalesManual, ExpectedMonthlySalesBase) > 0
                                            THEN CONVERT(DECIMAL(9,2), (CurrentInventoryBase + TransitBase + TransfersInBase + OutstandingOrderBase)
                                                 / ISNULL(ExpectedMonthlySalesManual, ExpectedMonthlySalesBase)) END) PERSISTED;');

        COMMIT TRANSACTION;
        PRINT 'ShortageDocumentLines: TransfersInBase added, and to the four stock + transit + orders formulas';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Re-created (90) from the body of script 85: + TransfersInBase (after TransitBase), the pieces dispatched by released
-- transfer orders to the plan's warehouse or a warehouse under it and neither received nor written off yet: they sit in
-- an On the way warehouse, which no tree holds, so CurrentInventoryBase does not count them. Transfers OUT of the tree
-- are not demand (decision D8). Every other column unchanged.
CREATE OR ALTER FUNCTION inventory.fn_Shortage_Live (@WarehouseId INT, @MonthsOfHistory INT)
RETURNS TABLE
AS
RETURN
(
    /* (62) THE WAREHOUSE AND EVERY WAREHOUSE UNDER IT. A plan for a parent counts the stock, sales,
       orders and containers of its whole tree; a warehouse with nothing under it is just itself.
       The depth guard stops a cycle left by older data instead of recursing for ever. */
    WITH tree AS
    (
        SELECT w.Id, 0 AS Depth FROM masterdata.Warehouses w WHERE w.Id = @WarehouseId
        UNION ALL
        SELECT w.Id, t.Depth + 1 FROM masterdata.Warehouses w INNER JOIN tree t ON w.ParentId = t.Id WHERE t.Depth < 20
    )
    SELECT i.Id AS ItemId, i.ItemCode, i.ItemName, i.BrandId, i.ItemFamilyId, i.IsBivac,
           i.DefaultSupplierId, i.LastSupplierId, i.MinQuantity, i.MaxQuantity, i.LastCost, i.AverageCost, i.LeadTimeDays,
           ItemPcPerContainer = cnt.PackingFormula,                         -- the item's Container unit, NULL when none
           PcPerContainerFromUnit = CAST(CASE WHEN cnt.PackingFormula IS NOT NULL THEN 1 ELSE 0 END AS BIT),
           CurrentInventoryBase     = ISNULL((SELECT SUM(m.QuantityBase) FROM inventory.StockMovements m
                                              WHERE m.ItemId = i.Id AND m.WarehouseId IN (SELECT t.Id FROM tree t)), 0),
           TransitBase              = ISNULL(tr.Transit, 0),
           TransfersInBase          = ISNULL(ti.TransfersIn, 0),            -- (90) goods on the way to the tree by transfers
           OutstandingOrderBase     = CASE WHEN ISNULL(po.PoOpen, 0) + ISNULL(po.InvPending, 0) - ISNULL(tr.Transit, 0) > 0
                                           THEN ISNULL(po.PoOpen, 0) + ISNULL(po.InvPending, 0) - ISNULL(tr.Transit, 0) ELSE 0 END,
           -- (85) the HIGHEST month of the history, not the average: plan for the busiest month seen.
           ExpectedMonthlySalesBase = CONVERT(DECIMAL(18,2), ISNULL(mx.MaxMonthSold, 0)),
           SoldInPeriodBase         = ISNULL(s.Sold, 0),
           PurchaseItemUnitId       = pu.ItemUnitId,
           PurchaseUnitName         = pu.UnitTypeName,
           PurchasePackingFormula   = pu.PackingFormula
    FROM inventory.Items i
    OUTER APPLY
    (
        -- (65) rule 25: open and closed orders still to receive + invoices without an order not received yet
        SELECT PoOpen     = SUM(CASE WHEN dt.Code = N'PO'   THEN ISNULL(pp.OutstandingBase, 0) ELSE 0 END),
               InvPending = SUM(CASE WHEN dt.Code = N'PINV' THEN l.QuantityBase - l.ReceivedQuantityBase ELSE 0 END)
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
        INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId
        OUTER APPLY (SELECT p.OutstandingBase FROM purchase.fn_PoLine_Progress(d.Id) p WHERE p.PoLineId = l.Id) pp
        WHERE l.ItemId = i.Id AND l.WarehouseId IN (SELECT t.Id FROM tree t)
          AND ((dt.Code = N'PO'   AND d.Status IN (2, 4))
            OR (dt.Code = N'PINV' AND d.Status IN (2, 4) AND d.UsesGoodsReceipts = 1 AND l.SourceLineId IS NULL
                AND l.QuantityBase > l.ReceivedQuantityBase))
    ) po
    OUTER APPLY
    (
        -- loaded into a container that has left the supplier and is not offloaded yet
        SELECT Transit = SUM(cl.QuantityBase - ISNULL(cl.ReceivedQuantityBase, 0))
        FROM logistics.ContainerLines cl
        INNER JOIN logistics.Containers c             ON c.Id = cl.ContainerId
        INNER JOIN purchase.PurchaseDocumentLines pl  ON pl.Id = cl.PoLineId
        WHERE cl.ItemId = i.Id AND c.Status IN (3, 4, 5)
          AND pl.WarehouseId IN (SELECT t.Id FROM tree t)                  -- the order's warehouse, like the open order / invoice quantities
          AND cl.QuantityBase > ISNULL(cl.ReceivedQuantityBase, 0)
    ) tr
    OUTER APPLY
    (
        -- (90) GOODS ON THE WAY TO THE PLAN'S WAREHOUSE (its tree): dispatched by released transfer orders to it, not
        --      received or written off yet. They sit in an On the way warehouse, which no tree holds. Transfers OUT
        --      are not demand: the owner has not said the main warehouse buys for the branches (it would buy twice).
        SELECT TransfersIn = SUM(l.DispatchedBase - l.ReceivedBase - l.LostBase)
        FROM inventory.TransferOrderLines l
        INNER JOIN inventory.TransferOrders o ON o.Id = l.TransferOrderId
        WHERE l.ItemId = i.Id AND o.Status = 2 AND o.ToWarehouseId IN (SELECT t.Id FROM tree t)
          AND l.DispatchedBase > l.ReceivedBase + l.LostBase
    ) ti
    OUTER APPLY
    (
        SELECT Sold = SUM(-m.QuantityBase)
        FROM inventory.StockMovements m
        WHERE m.ItemId = i.Id AND m.WarehouseId IN (SELECT t.Id FROM tree t) AND m.DocumentFamily = N'Sales'
          AND m.MovementDate >= DATEADD(MONTH, -@MonthsOfHistory, CAST(SYSUTCDATETIME() AS DATE))
    ) s
    OUTER APPLY
    (
        /* (85) THE BUSIEST MONTH. The same history, cut into @MonthsOfHistory blocks of one month counted
           back from tonight (block 0 = the last month up to today included, block 1 = the month before it...),
           each up to the same day of the next one, so no day counts twice; the
           net sales of each (sales less returns), and the highest of them. A month without sales counts 0. */
        SELECT MaxMonthSold = MAX(b.Sold)
        FROM (SELECT k.n, Sold = ISNULL((SELECT SUM(-m.QuantityBase)
                                         FROM inventory.StockMovements m
                                         WHERE m.ItemId = i.Id AND m.WarehouseId IN (SELECT t.Id FROM tree t)
                                           AND m.DocumentFamily = N'Sales'
                                           AND m.MovementDate >= DATEADD(MONTH, -(k.n + 1), DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE)))
                                           AND m.MovementDate <  DATEADD(MONTH, -k.n, DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE)))), 0)
              FROM (SELECT TOP (CASE WHEN @MonthsOfHistory > 0 THEN @MonthsOfHistory ELSE 1 END)
                           n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1
                    FROM (VALUES (0),(0),(0),(0),(0),(0)) a (x) CROSS JOIN (VALUES (0),(0),(0),(0),(0),(0)) b (x)) k
        ) b
    ) mx
    OUTER APPLY
    (
        SELECT TOP (1) u.Id AS ItemUnitId, u.PackingFormula, t.UnitTypeName
        FROM inventory.ItemUnits u INNER JOIN masterdata.UnitTypes t ON t.Id = u.UnitTypeId
        WHERE u.ItemId = i.Id ORDER BY u.IsPurchaseUnit DESC, u.IsBaseUnit DESC
    ) pu
    OUTER APPLY
    (
        SELECT TOP (1) u.PackingFormula
        FROM inventory.ItemUnits u INNER JOIN masterdata.UnitTypes t ON t.Id = u.UnitTypeId
        WHERE u.ItemId = i.Id AND t.IsContainer = 1
    ) cnt
    WHERE i.IsActive = 1
);
GO

-- Re-created (90) from the body of script 25: + x.TransfersInBase in every "stock + transit + orders" sum
-- (StockPlusTransitBase, TotalExpectedStockBase, ShortageBase, CoverageMonths, and through ShortageBase the
-- SuggestedRequiredQty and ContainerRequirement), and TransfersInBase returned after TransitBase. Nothing else.
CREATE OR ALTER PROCEDURE inventory.usp_Shortage_Calculate
    @WarehouseId     INT,
    @SupplierId      INT           = NULL,
    @LeadTimeMonths  DECIMAL(6,2)  = 6,
    @MonthsOfHistory INT           = 3,
    @ItemFamilyId    INT           = NULL,
    @BrandId         INT           = NULL,
    @Search          NVARCHAR(200) = NULL,
    @OnlyShortages   BIT           = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @LeadTimeMonths IS NULL OR @LeadTimeMonths <= 0 SET @LeadTimeMonths = 6;
    IF @MonthsOfHistory IS NULL OR @MonthsOfHistory < 1 SET @MonthsOfHistory = 3;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1) THROW 66000, 'Warehouse not found or inactive.', 1;

    SELECT x.ItemId, x.ItemCode, x.ItemName, b.BrandName, f.FamilyName, x.IsBivac,
           x.CurrentInventoryBase, x.TransitBase, x.TransfersInBase, x.OutstandingOrderBase,      -- (90) + TransfersInBase
           StockPlusTransitBase   = x.CurrentInventoryBase + x.TransitBase + x.TransfersInBase,
           TotalExpectedStockBase = x.CurrentInventoryBase + x.TransitBase + x.TransfersInBase + x.OutstandingOrderBase,
           x.ExpectedMonthlySalesBase, x.SoldInPeriodBase, MonthsOfHistory = @MonthsOfHistory, LeadTimeMonths = @LeadTimeMonths,
           ExpectedRequirementBase = CONVERT(DECIMAL(18,2), x.ExpectedMonthlySalesBase * @LeadTimeMonths),
           ShortageBase = c.ShortageBase,
           CoverageMonths = CASE WHEN x.ExpectedMonthlySalesBase > 0
                                 THEN CONVERT(DECIMAL(9,2), (x.CurrentInventoryBase + x.TransitBase + x.TransfersInBase + x.OutstandingOrderBase) / x.ExpectedMonthlySalesBase) END,
           x.PurchaseItemUnitId, x.PurchaseUnitName, x.PurchasePackingFormula,
           SuggestedRequiredQty = CASE WHEN c.ShortageBase > 0 THEN CEILING(CAST(c.ShortageBase AS DECIMAL(18,4)) / x.PurchasePackingFormula) ELSE 0 END,
           PcPerContainer = x.ItemPcPerContainer, PcPerContainerFromUnit = x.PcPerContainerFromUnit,
           ContainerRequirement = CASE WHEN x.ItemPcPerContainer > 0 AND c.ShortageBase > 0
                                       THEN CONVERT(DECIMAL(9,2), CEILING(CAST(c.ShortageBase AS DECIMAL(18,4)) / x.PurchasePackingFormula) * x.PurchasePackingFormula * 1.0 / x.ItemPcPerContainer) END,
           x.MinQuantity, x.MaxQuantity, x.LastCost, x.AverageCost, x.LeadTimeDays,
           SupplierId = COALESCE(x.DefaultSupplierId, x.LastSupplierId), SupplierName = COALESCE(ds.PartyName, ls.PartyName),
           SupplierIsDefault = CASE WHEN x.DefaultSupplierId IS NOT NULL THEN 1 ELSE 0 END
    FROM inventory.fn_Shortage_Live(@WarehouseId, @MonthsOfHistory) x
    CROSS APPLY (SELECT ShortageBase = CASE WHEN x.ExpectedMonthlySalesBase * @LeadTimeMonths - (x.CurrentInventoryBase + x.TransitBase + x.TransfersInBase + x.OutstandingOrderBase) > 0
                                            THEN CONVERT(INT, CEILING(x.ExpectedMonthlySalesBase * @LeadTimeMonths - (x.CurrentInventoryBase + x.TransitBase + x.TransfersInBase + x.OutstandingOrderBase))) ELSE 0 END) c
    INNER JOIN masterdata.Brands b ON b.Id = x.BrandId
    INNER JOIN masterdata.ItemFamilies f ON f.Id = x.ItemFamilyId
    LEFT  JOIN masterdata.Parties ds ON ds.Id = x.DefaultSupplierId
    LEFT  JOIN masterdata.Parties ls ON ls.Id = x.LastSupplierId
    WHERE x.PurchaseItemUnitId IS NOT NULL
      AND (@SupplierId IS NULL OR COALESCE(x.DefaultSupplierId, x.LastSupplierId) = @SupplierId)
      AND (@ItemFamilyId IS NULL OR x.ItemFamilyId IN (SELECT Id FROM masterdata.fn_ItemFamily_Subtree(@ItemFamilyId)))
      AND (@BrandId IS NULL OR x.BrandId = @BrandId)
      AND (@Search IS NULL OR x.ItemCode LIKE N'%' + @Search + N'%' OR x.ItemName LIKE N'%' + @Search + N'%')
      AND (@OnlyShortages = 0 OR c.ShortageBase > 0)
    ORDER BY CASE WHEN c.ShortageBase > 0 THEN 0 ELSE 1 END, c.ShortageBase DESC, x.ItemCode;
END
GO

-- Re-created (90) from the body of script 25: + TransfersInBase in the INSERT (the saved line's snapshot, read by the
-- four formulas of the table) and in the sum of the suggested RequiredQty. Nothing else.
CREATE OR ALTER PROCEDURE inventory.usp_ShortageDocument_WriteLines
    @Id     INT,
    @Lines  inventory.tvp_ShortageLine READONLY
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @WarehouseId INT, @Months INT, @LeadTime DECIMAL(6,2);
    SELECT @WarehouseId = WarehouseId, @Months = MonthsOfHistory, @LeadTime = LeadTimeMonths FROM inventory.ShortageDocuments WHERE Id = @Id;

    DECLARE @Msg NVARCHAR(300);
    SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' +
                          CASE WHEN i.Id IS NULL THEN N'item not found.' WHEN i.IsActive = 0 THEN N'item ' + i.ItemCode + N' is inactive.'
                               WHEN l.RequiredQty < 0 THEN N'required quantity cannot be negative.'
                               WHEN l.ExpectedMonthlySalesManual < 0 THEN N'expected monthly sales cannot be negative.'
                               WHEN l.PcPerContainer <= 0 THEN N'PC per container must be greater than zero.' END
    FROM @Lines l LEFT JOIN inventory.Items i ON i.Id = l.ItemId
    WHERE i.Id IS NULL OR i.IsActive = 0 OR l.RequiredQty < 0 OR l.ExpectedMonthlySalesManual < 0 OR l.PcPerContainer <= 0
    ORDER BY l.LineNumber;
    IF @Msg IS NOT NULL THROW 66000, @Msg, 1;
    IF EXISTS (SELECT ItemId FROM @Lines GROUP BY ItemId HAVING COUNT(*) > 1) THROW 66000, 'An item appears more than once.', 1;

    DELETE FROM inventory.ShortageDocumentLines WHERE DocumentId = @Id;

    INSERT INTO inventory.ShortageDocumentLines (DocumentId, LineNumber, ItemId, CurrentInventoryBase, TransitBase, TransfersInBase, OutstandingOrderBase,
                                                 ExpectedMonthlySalesBase, ExpectedMonthlySalesManual, LeadTimeMonths,
                                                 PurchaseItemUnitId, PurchasePackingFormula, RequiredQty, PcPerContainer, PcPerContainerFromUnit,
                                                 MinQuantity, MaxQuantity, LastCost, Notes)
    SELECT @Id, l.LineNumber, l.ItemId, x.CurrentInventoryBase, x.TransitBase, x.TransfersInBase, x.OutstandingOrderBase,   -- (90)
           x.ExpectedMonthlySalesBase, l.ExpectedMonthlySalesManual, @LeadTime,
           x.PurchaseItemUnitId, x.PurchasePackingFormula,
           RequiredQty = ISNULL(l.RequiredQty,
                                CASE WHEN s.ShortageBase > 0 THEN CEILING(CAST(s.ShortageBase AS DECIMAL(18,4)) / x.PurchasePackingFormula) ELSE 0 END),
           COALESCE(x.ItemPcPerContainer, l.PcPerContainer),            -- the Container unit always wins; else what the user typed
           CAST(CASE WHEN x.ItemPcPerContainer IS NOT NULL THEN 1 ELSE 0 END AS BIT),
           x.MinQuantity, x.MaxQuantity, x.LastCost, NULLIF(LTRIM(RTRIM(l.Notes)), N'')
    FROM @Lines l
    INNER JOIN inventory.fn_Shortage_Live(@WarehouseId, @Months) x ON x.ItemId = l.ItemId
    CROSS APPLY (SELECT ShortageBase = CASE WHEN ISNULL(l.ExpectedMonthlySalesManual, x.ExpectedMonthlySalesBase) * @LeadTime - (x.CurrentInventoryBase + x.TransitBase + x.TransfersInBase + x.OutstandingOrderBase) > 0
                                            THEN CONVERT(INT, CEILING(ISNULL(l.ExpectedMonthlySalesManual, x.ExpectedMonthlySalesBase) * @LeadTime - (x.CurrentInventoryBase + x.TransitBase + x.TransfersInBase + x.OutstandingOrderBase)))
                                            ELSE 0 END) s
    WHERE x.PurchaseItemUnitId IS NOT NULL;

    IF EXISTS (SELECT 1 FROM @Lines l WHERE NOT EXISTS (SELECT 1 FROM inventory.ShortageDocumentLines s WHERE s.DocumentId = @Id AND s.ItemId = l.ItemId))
        THROW 66000, 'An item has no units configured and cannot be planned.', 1;

    UPDATE d
    SET TotalLines = x.Lines, TotalShortageBase = x.Shortage, TotalRequiredBase = x.Required,
        TotalContainers = x.Containers, ContainersRounded = CEILING(x.Containers),
        ContainerUtilizationPct = CASE WHEN x.Containers > 0 THEN CONVERT(DECIMAL(5,2), 100.0 * x.Containers / CEILING(x.Containers)) END,
        CalculatedAtUtc = SYSUTCDATETIME()
    FROM inventory.ShortageDocuments d
    CROSS APPLY (SELECT COUNT(*) AS Lines, ISNULL(SUM(ShortageBase), 0) AS Shortage, ISNULL(SUM(RequiredBase), 0) AS Required,
                        ISNULL(SUM(ContainerRequirement), 0) AS Containers
                 FROM inventory.ShortageDocumentLines WHERE DocumentId = @Id) x
    WHERE d.Id = @Id;
END
GO

-- Re-created (90) from the body of script 77: the lines + TransfersInBase after TransitBase. Nothing else.
CREATE OR ALTER PROCEDURE inventory.usp_ShortageDocument_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.Id, d.DocumentNumber, d.Description, d.DocumentDate,
           d.BranchId, b.BranchCode, b.BranchName, d.WarehouseId, w.WarehouseCode, w.WarehouseName,
           d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName,
           d.LeadTimeMonths, d.MonthsOfHistory, d.Notes, d.Status,
           d.TotalLines, d.TotalShortageBase, d.TotalRequiredBase, d.TotalContainers, d.ContainersRounded, d.ContainerUtilizationPct,
           d.CalculatedAtUtc, d.PostedAtUtc, d.PostedBy, pu.FullName AS PostedByName,
           d.CreatedAtUtc, d.CreatedBy, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.UpdatedBy, uu.FullName AS UpdatedByName, d.RowVersion
    FROM inventory.ShortageDocuments d
    INNER JOIN masterdata.Branches b ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Parties sp ON sp.Id = d.SupplierId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = d.UpdatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    WHERE d.Id = @Id;

    SELECT l.Id, l.DocumentId, l.LineNumber, l.ItemId, i.ItemCode, i.ItemName, br.BrandName, f.FamilyName, i.IsBivac,
           l.CurrentInventoryBase, l.TransitBase, l.TransfersInBase, l.OutstandingOrderBase, l.StockPlusTransitBase, l.TotalExpectedStockBase,   -- (90)
           l.ExpectedMonthlySalesBase, l.ExpectedMonthlySalesManual, l.EffectiveMonthlySales, l.LeadTimeMonths,
           l.ExpectedRequirementBase, l.ShortageBase, l.CoverageMonths,
           l.PurchaseItemUnitId, ut.UnitTypeName AS PurchaseUnitName, l.PurchasePackingFormula,
           l.RequiredQty, l.RequiredBase, l.PcPerContainer, l.PcPerContainerFromUnit, l.ContainerRequirement,
           l.MinQuantity, l.MaxQuantity, l.LastCost, l.Notes
    FROM inventory.ShortageDocumentLines l
    INNER JOIN inventory.Items i ON i.Id = l.ItemId
    INNER JOIN masterdata.Brands br ON br.Id = i.BrandId
    INNER JOIN masterdata.ItemFamilies f ON f.Id = i.ItemFamilyId
    INNER JOIN inventory.ItemUnits iu ON iu.Id = l.PurchaseItemUnitId
    INNER JOIN masterdata.UnitTypes ut ON ut.Id = iu.UnitTypeId
    WHERE l.DocumentId = @Id
    ORDER BY l.LineNumber;

    -- (77) + InvoicingStatus (0 / 1 / 2: Saved, Partially posted, Posted on an approved order)
    SELECT p.Id, p.DocumentNumber, p.DocumentDate, p.Status, p.TotalAmount, c.CurrencyCode, p.CreatedAtUtc,
           inv.InvoicingStatus
    FROM purchase.PurchaseDocuments p
    INNER JOIN masterdata.Currencies c ON c.Id = p.CurrencyId
    OUTER APPLY purchase.fn_PurchaseOrder_Invoicing(p.Id) inv
    WHERE p.SourceShortageId = @Id
    ORDER BY p.CreatedAtUtc;

    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM inventory.ShortageDocumentAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.DocumentId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;
END
GO

/* ================================================================== 17. Undoing a receipt names the transfer that moved its goods (FB rule 39) */

/* (90) A GOODS RECEIPT OR AN INVENTORY IN CANNOT BE UNDONE ONCE ITS STOCK HAS LEFT ITS WAREHOUSE, and a transfer may be
   what took it: the refusal now says so, and what to do. No logic changes - each refusal keeps its number, its test and
   its first sentence, and gains inventory.fn_Transfer_MovedOutNote at its end: the posted, not reversed dispatches that
   took the item out of that warehouse since the document was posted, " 80 pcs were moved by TRD-BR-003-000004: transfer
   them back first." (they cover the shortfall) or " (10 of them were moved by TRD-BR-003-000004.)" (they do not); nothing
   when no transfer moved it. Unchanged on purpose (M9): the purchase return 65007, Cancel Offload, the sales return
   cancel, the cancel of a purchase invoice posted before goods receipts. */

-- Re-created (90) from the body of script 64: + the transfer note on Seq 5 (63007), since the receipt's PostedAtUtc.
-- fn_GoodsReceipt_Blocks reads it, so the receipt page's disabled Cancel says it too.
/* THE REFUSALS OF usp_GoodsReceipt_Cancel that can be told before it runs (Get shows the first as
   CancelBlockedReason). The reason, the RowVersion and the purchase returns (63010, known only once the matches are
   rebuilt without this receipt) are checked by the procedure itself.
     63008  its cost was adjusted afterwards: a GRNCOST change of its lines other than the NEGSTOCK of its own posting,
            or, for a container, a late charge (CNTCHARGE) - as 69018 for the offload
     63007  per item and warehouse: the stock on hand is less than what it brought (90: and the transfers that moved it) */
CREATE OR ALTER FUNCTION purchase.fn_GoodsReceipt_CancelCheck (@Id INT)
RETURNS TABLE
AS
RETURN
WITH h AS
(
    SELECT g.Id, g.Status, g.ContainerId, c.ContainerRef, CtStatus = c.Status,
           g.PostedAtUtc                                                    -- (90) since when a transfer moved its goods away
    FROM purchase.GoodsReceipts g
    LEFT JOIN logistics.Containers c ON c.Id = g.ContainerId
    WHERE g.Id = @Id
)
SELECT x.Seq, x.ErrorNumber, x.Message
FROM
(
    SELECT Seq = 1, ErrorNumber = 63006, Message = CAST(N'Goods receipt not found.' AS NVARCHAR(400))
    WHERE NOT EXISTS (SELECT 1 FROM h)

    UNION ALL
    SELECT 2, 63010, N'Only a posted goods receipt can be cancelled.' FROM h WHERE h.Status <> 2

    UNION ALL
    SELECT 3, 63010, N'Container ' + h.ContainerRef + N' is closed. Reopen it before cancelling its goods receipt.'
    FROM h WHERE h.CtStatus = 7

    UNION ALL
    SELECT 4, 63008, N'The cost of these goods was adjusted after they were received (invoice price, landed cost or a late container charge). This goods receipt can no longer be cancelled.'
    FROM h
    WHERE EXISTS (SELECT 1 FROM purchase.GoodsReceiptCostChanges cc
                  INNER JOIN purchase.GoodsReceiptLines gl ON gl.Id = cc.GoodsReceiptLineId
                  WHERE gl.GoodsReceiptId = h.Id AND cc.CauseKind <> N'NEGSTOCK')
       OR EXISTS (SELECT 1 FROM inventory.CostAdjustments ca
                  INNER JOIN logistics.ContainerCharges ch ON ch.Id = ca.SourceId
                  WHERE ca.SourceKind = N'CNTCHARGE' AND ch.ContainerId = h.ContainerId)

    UNION ALL
    SELECT * FROM (SELECT TOP (1) Seq = 5, ErrorNumber = 63007,
                          -- (90) + the dispatches that moved the goods away since the receipt was posted (FB rule 39). The
                          --      message keeps its type, NVARCHAR(400), which fn_GoodsReceipt_Blocks and the cancel read.
                          Message = CAST(N'Cannot cancel: ' + i.ItemCode + N' in ' + w.WarehouseCode + N' has only '
                                    + CAST(oh.Q AS NVARCHAR(20)) + N' left, but this goods receipt brought ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
                                    + ISNULL(inventory.fn_Transfer_MovedOutNote(x.ItemId, x.WarehouseId, h.PostedAtUtc, x.Qty - oh.Q), N'')
                                    AS NVARCHAR(400))
                   FROM h
                   CROSS APPLY (SELECT m.ItemId, m.WarehouseId, Qty = SUM(m.QuantityBase)
                                FROM inventory.StockMovements m
                                WHERE m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = N'GRN' AND m.DocumentId = h.Id AND m.IsReversal = 0
                                GROUP BY m.ItemId, m.WarehouseId) x
                   CROSS APPLY (SELECT Q = inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)) oh
                   INNER JOIN inventory.Items i       ON i.Id = x.ItemId
                   INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
                   WHERE h.Status = 2 AND x.Qty > oh.Q
                   ORDER BY i.ItemCode, w.WarehouseCode) a
) x;
GO

-- Re-created (90) from the body of script 89: + the transfer note on the 62007 sentence of an incoming document (Inventory
-- In), since the document's PostedAtUtc. Everything of 89 kept word for word: the matching lock first, the document's
-- own rows only, the refusal when it has none, the cost replay of its items, DEADLOCK_PRIORITY LOW (the API retries).
CREATE OR ALTER PROCEDURE inventory.usp_StockDocument_Cancel
    @Id         INT,
    @Reason     NVARCHAR(300),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET DEADLOCK_PRIORITY LOW;                                                           -- (89) 4

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 62000, 'A cancellation reason is required.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        EXEC purchase.usp_GoodsReceipt_LockMatching;                                     -- (89) 1

        DECLARE @Status TINYINT, @Direction SMALLINT, @Number NVARCHAR(30), @TypeCode NVARCHAR(20), @BranchId INT, @ReasonCode NVARCHAR(20);
        SELECT @Status = d.Status, @Direction = dt.StockDirection, @Number = d.DocumentNumber, @TypeCode = dt.Code, @BranchId = d.BranchId, @ReasonCode = r.ReasonCode
        FROM inventory.StockDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        LEFT  JOIN inventory.StockReasons r ON r.Id = d.ReasonId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 62006, 'Document not found.', 1;
        IF @Status <> 2 THROW 62010, 'Only posted documents can be cancelled (delete drafts instead).', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.StockDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This document was modified by another user. Reload the page and try again.', 1;

        -- Cancelling an incoming document removes stock again: it must still be there.
        IF @Direction = 1
        BEGIN
            DECLARE @Msg NVARCHAR(400);
            -- (90) + the dispatches that moved the goods away since this document was posted (FB rule 39)
            DECLARE @PostedAtUtc DATETIME2(3) = (SELECT PostedAtUtc FROM inventory.StockDocuments WHERE Id = @Id);
            SELECT TOP (1) @Msg = N'Cannot cancel: ' + i.ItemCode + N' in ' + w.WarehouseCode + N' has only '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N' left, but this document added ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
                                 + ISNULL(inventory.fn_Transfer_MovedOutNote(x.ItemId, x.WarehouseId, @PostedAtUtc,
                                                                             x.Qty - inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)), N'')   -- (90)
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM inventory.StockDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 62007, @Msg, 1;
        END

        -- (89) 2. its own rows only; none is refused (a posted document has one row per line: inventory.usp_StockDocument_Post)
        IF NOT EXISTS (SELECT 1 FROM inventory.StockMovements m
                       WHERE m.DocumentFamily = N'Inventory' AND m.DocumentTypeCode = @TypeCode AND m.DocumentId = @Id AND m.IsReversal = 0)
            THROW 62010, 'This document has no stock movements of its own to reverse. Ask the administrator to check the stock ledger.', 1;

        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, IsReversal, CreatedBy)
        SELECT SYSUTCDATETIME(), m.ItemId, m.WarehouseId, m.BranchId, -m.QuantityBase, m.UnitCostBase,
               m.DocumentFamily, m.DocumentTypeCode, m.DocumentId, m.DocumentLineId, m.DocumentNumber, m.ReasonCode, m.ExpiryDate, 1, @UserId
        FROM inventory.StockMovements m
        WHERE m.DocumentFamily = N'Inventory' AND m.DocumentTypeCode = @TypeCode AND m.DocumentId = @Id AND m.IsReversal = 0;

        UPDATE inventory.StockDocuments
        SET Status = 3, CancelledAtUtc = SYSUTCDATETIME(), CancelledBy = @UserId, CancelReason = @Reason,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO inventory.StockDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@Id, N'Cancelled', @Reason, @UserId);

        -- (89) 3. every cancelled stock document: replay the cost history of its items
        DECLARE @ItemId INT;
        DECLARE items CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT ItemId FROM inventory.StockDocumentLines WHERE DocumentId = @Id;
        OPEN items; FETCH NEXT FROM items INTO @ItemId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC inventory.usp_Item_RebuildCosts @ItemId;
            FETCH NEXT FROM items INTO @ItemId;
        END
        CLOSE items; DEALLOCATE items;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 18. Permissions: the ten transfer rights */

/* (90) TEN PERMISSIONS inventory.transfers.* (SortOrder 855-890, module Inventory), with the texts of
   PermissionCatalog.cs. GRANTED ONCE, when each is first created (script 75's pattern: the MERGE's OUTPUT says which
   rows it inserted), to the system roles and to the roles holding the matching Inventory In / Out right (FB table K):
     view      Inventory In view OR Inventory Out view; and the roles named Manager and Owner
     create    Inventory Out create          delete   Inventory Out delete
     release   Inventory Out post            approve  the roles named Manager and Owner (decision D7)
     dispatch  Inventory Out post            receive  Inventory In post
     close     Inventory Out cancel          cancel   Inventory Out cancel
     reverse   Inventory Out cancel AND Inventory In cancel (a reversal undoes an out and an in)
   A role unticked afterwards on Role Permissions is never re-granted; the start-up sync of the catalog keeps the texts
   and gives every permission to the system roles. The value figures of a transfer need inventory.valuation.view until
   script 94. */
SET XACT_ABORT ON;
BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @Changed TABLE (Action NVARCHAR(10) NOT NULL, PermissionId INT NOT NULL, Code NVARCHAR(100) NOT NULL);

    MERGE security.Permissions AS target
    USING
    (
        VALUES
            (N'inventory.transfers.view',     N'View Transfer Orders',     N'Inventory', N'See transfer orders, their dispatches and receipts.', 855),
            (N'inventory.transfers.create',   N'Create Transfer Orders',   N'Inventory', N'Create and edit draft transfer orders (lines, scan, import, Fill to Max), their documents, and returns.', 860),
            (N'inventory.transfers.delete',   N'Delete Transfer Orders',   N'Inventory', N'Delete draft transfer orders.', 862),
            (N'inventory.transfers.release',  N'Release Transfer Orders',  N'Inventory', N'Release a transfer order, send it for approval, withdraw it, or take it back to draft.', 870),
            (N'inventory.transfers.approve',  N'Approve Transfer Orders',  N'Inventory', N'Approve or reject transfer orders waiting for approval, or approve and release a draft (when Document Types asks for approval).', 872),
            (N'inventory.transfers.dispatch', N'Dispatch Transfers',       N'Inventory', N'Dispatch goods of a released transfer order (stock leaves the source) and change a dispatch''s ETA.', 875),
            (N'inventory.transfers.receive',  N'Receive Transfers',        N'Inventory', N'Receive transferred goods into the destination, and write off what will not arrive.', 880),
            (N'inventory.transfers.close',    N'Close Transfer Orders',    N'Inventory', N'Nothing more will be sent: settle what is left to dispatch.', 885),
            (N'inventory.transfers.cancel',   N'Cancel Transfer Orders',   N'Inventory', N'Cancel a released transfer order with nothing dispatched.', 888),
            (N'inventory.transfers.reverse',  N'Reverse Transfers',        N'Inventory', N'Reverse a posted dispatch or transfer receipt (stock reversal).', 890)
    ) AS source (Code, Name, Module, Description, SortOrder)
    ON target.Code = source.Code
    WHEN MATCHED AND (target.Name <> source.Name OR target.Module <> source.Module
                      OR ISNULL(target.Description, N'') <> source.Description OR target.SortOrder <> source.SortOrder) THEN
        UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (Code, Name, Module, Description, SortOrder)
        VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder)
    OUTPUT $action, inserted.Id, inserted.Code INTO @Changed (Action, PermissionId, Code);

    IF EXISTS (SELECT 1 FROM @Changed WHERE Action = N'INSERT')
    BEGIN
        -- Who gets each new permission once: a role holding FromCode (and AlsoCode when given), or the role named
        -- RoleName. Every rule names at least one of them; the system roles get every one.
        DECLARE @From TABLE (Code NVARCHAR(100) NOT NULL, FromCode NVARCHAR(100) NULL, AlsoCode NVARCHAR(100) NULL, RoleName NVARCHAR(50) NULL,
                             CHECK (FromCode IS NOT NULL OR RoleName IS NOT NULL));
        INSERT INTO @From (Code, FromCode, AlsoCode, RoleName) VALUES
            (N'inventory.transfers.view',     N'inventory.stockin.view',    NULL,                        NULL),
            (N'inventory.transfers.view',     N'inventory.stockout.view',   NULL,                        NULL),
            (N'inventory.transfers.view',     NULL,                         NULL,                        N'Manager'),
            (N'inventory.transfers.view',     NULL,                         NULL,                        N'Owner'),
            (N'inventory.transfers.create',   N'inventory.stockout.create', NULL,                        NULL),
            (N'inventory.transfers.delete',   N'inventory.stockout.delete', NULL,                        NULL),
            (N'inventory.transfers.release',  N'inventory.stockout.post',   NULL,                        NULL),
            (N'inventory.transfers.approve',  NULL,                         NULL,                        N'Manager'),
            (N'inventory.transfers.approve',  NULL,                         NULL,                        N'Owner'),
            (N'inventory.transfers.dispatch', N'inventory.stockout.post',   NULL,                        NULL),
            (N'inventory.transfers.receive',  N'inventory.stockin.post',    NULL,                        NULL),
            (N'inventory.transfers.close',    N'inventory.stockout.cancel', NULL,                        NULL),
            (N'inventory.transfers.cancel',   N'inventory.stockout.cancel', NULL,                        NULL),
            (N'inventory.transfers.reverse',  N'inventory.stockout.cancel', N'inventory.stockin.cancel', NULL);

        INSERT INTO security.RolePermissions (RoleId, PermissionId)
        SELECT DISTINCT r.Id, c.PermissionId
        FROM @Changed c
        CROSS JOIN security.Roles r
        WHERE c.Action = N'INSERT'
          AND (r.IsSystem = 1
               OR EXISTS (SELECT 1 FROM @From f
                          WHERE f.Code = c.Code
                            AND (f.RoleName IS NULL OR r.Name = f.RoleName)
                            AND (f.FromCode IS NULL
                                 OR EXISTS (SELECT 1 FROM security.RolePermissions rp INNER JOIN security.Permissions p ON p.Id = rp.PermissionId
                                            WHERE rp.RoleId = r.Id AND p.Code = f.FromCode))
                            AND (f.AlsoCode IS NULL
                                 OR EXISTS (SELECT 1 FROM security.RolePermissions rp INNER JOIN security.Permissions p ON p.Id = rp.PermissionId
                                            WHERE rp.RoleId = r.Id AND p.Code = f.AlsoCode))))
          AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = c.PermissionId);

        DECLARE @Grants INT = @@ROWCOUNT;
        DECLARE @Created INT = (SELECT COUNT(*) FROM @Changed WHERE Action = N'INSERT');
        PRINT 'Transfer permissions created: ' + CAST(@Created AS NVARCHAR(10))
              + ', granted once: ' + CAST(@Grants AS NVARCHAR(10)) + ' role grant(s).';
    END

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH
GO

/* ================================================================== 19. Check */

-- 1. The objects of script 90 (expected: none MISSING): the six tables, the three table types, every function and
--    procedure of 2.3.6-2.3.8, masterdata.usp_Warehouse_EnsureTransit and usp_Warehouse_IsReferenced.
SELECT o.ObjectName,
       ObjectType = ISNULL(so.type_desc, CASE WHEN TYPE_ID(o.ObjectName) IS NOT NULL THEN N'TABLE_TYPE' ELSE N'MISSING' END)
FROM (VALUES (N'inventory.TransferOrders'), (N'inventory.TransferOrderLines'), (N'inventory.TransferPostings'),
             (N'inventory.TransferPostingLines'), (N'inventory.TransferOrderAudit'), (N'inventory.TransferOrderFiles'),
             (N'inventory.tvp_TransferOrderLine'), (N'inventory.tvp_TransferDispatchLine'), (N'inventory.tvp_TransferReceiptLine'),
             (N'masterdata.fn_Warehouse_IsLeaf'), (N'masterdata.fn_Warehouse_IsUsed'), (N'masterdata.fn_AttachmentDocumentKinds'),
             (N'masterdata.usp_AttachmentType_Delete'),
             (N'inventory.fn_TransferPosition'), (N'inventory.fn_Transfer_MovedOutNote'), (N'inventory.fn_TransferOrder_WarehouseProblem'),
             (N'inventory.usp_TransferOrder_CheckWarehouses'), (N'inventory.fn_TransferOrder_State'), (N'inventory.fn_TransferOrder_Blocks'),
             (N'inventory.fn_TransferPosting_ReverseBlock'),
             (N'masterdata.usp_Warehouse_EnsureTransit'), (N'masterdata.usp_Warehouse_IsReferenced'),
             (N'masterdata.usp_Warehouse_Delete'), (N'masterdata.usp_Warehouse_Lookup'), (N'masterdata.usp_Warehouse_Search'),
             (N'masterdata.usp_Warehouse_Get'), (N'masterdata.usp_Warehouse_Create'), (N'masterdata.usp_Warehouse_Update'),
             (N'masterdata.usp_Warehouse_SetActive'), (N'masterdata.usp_Branch_Create'), (N'masterdata.usp_Branch_Delete'),
             (N'inventory.usp_Item_Create'), (N'inventory.usp_Item_Update'),
             (N'inventory.usp_TransferOrder_Search'), (N'inventory.usp_TransferOrder_Get'), (N'inventory.usp_TransferOrder_Availability'),
             (N'inventory.usp_TransferOrder_Save'), (N'inventory.usp_TransferOrder_UpdateDetails'), (N'inventory.usp_TransferOrder_Delete'),
             (N'inventory.usp_TransferOrder_Release'), (N'inventory.usp_TransferOrder_Approvers'), (N'inventory.usp_TransferOrder_SendForApproval'),
             (N'inventory.usp_TransferOrder_Approve'), (N'inventory.usp_TransferOrder_Reject'), (N'inventory.usp_TransferOrder_Withdraw'),
             (N'inventory.usp_TransferOrder_BackToDraft'), (N'inventory.usp_TransferOrder_DispatchCore'), (N'inventory.usp_TransferOrder_Dispatch'),
             (N'inventory.usp_TransferOrder_ReceiveCore'), (N'inventory.usp_TransferOrder_Receive'), (N'inventory.usp_TransferOrder_DispatchAndReceive'),
             (N'inventory.usp_TransferOrder_NothingMoreSent'), (N'inventory.usp_TransferOrder_Cancel'), (N'inventory.usp_TransferPosting_Reverse'),
             (N'inventory.usp_TransferPosting_SetEta'), (N'inventory.usp_TransferOrder_CreateReturn'), (N'inventory.usp_TransferOrder_WaitingCount'),
             (N'inventory.usp_TransferOrder_File_Add'), (N'inventory.usp_TransferOrder_File_List'), (N'inventory.usp_TransferOrder_File_Get'),
             (N'inventory.usp_TransferOrder_File_Update'), (N'inventory.usp_TransferOrder_File_Delete')) o (ObjectName)
LEFT JOIN sys.objects so ON so.object_id = OBJECT_ID(o.ObjectName);

-- 2. One On the way warehouse per branch (expected: 0 rows)
SELECT b.BranchCode FROM masterdata.Branches b
WHERE (SELECT COUNT(*) FROM masterdata.Warehouses w WHERE w.BranchId = b.Id AND w.IsTransit = 1) <> 1;

-- 3. The document types (expected: 3 rows) and the permissions (expected: 10 rows, with their role counts)
SELECT dt.Code, dt.Name, dt.Family, dt.StockDirection, dt.NumberPrefix, dt.NumberOnPost, dt.NumberPerBranch, dt.NeedsApproval, dt.IsActive
FROM inventory.DocumentTypes dt
WHERE dt.Code IN (N'TRO', N'TRD', N'TRR')
ORDER BY dt.Code;
SELECT p.Code, p.Name, p.SortOrder, Roles = (SELECT COUNT(*) FROM security.RolePermissions rp WHERE rp.PermissionId = p.Id)
FROM security.Permissions p
WHERE p.Code LIKE N'inventory.transfers.%'
ORDER BY p.SortOrder;

-- 4. The counters of the order lines agree with the posted, not reversed postings (expected: 0 rows)
SELECT l.Id FROM inventory.TransferOrderLines l
OUTER APPLY (SELECT D = SUM(CASE WHEN p.Kind = N'Dispatch' THEN pl.QuantityBase END),
                    R = SUM(CASE WHEN p.Kind = N'Receipt' THEN pl.QuantityBase END),
                    L = SUM(CASE WHEN p.Kind = N'Receipt' THEN pl.LostBase END)
             FROM inventory.TransferPostingLines pl INNER JOIN inventory.TransferPostings p ON p.Id = pl.PostingId
             WHERE pl.TransferOrderLineId = l.Id AND p.Status = 2) x
WHERE l.DispatchedBase <> ISNULL(x.D, 0) OR l.ReceivedBase <> ISNULL(x.R, 0) OR l.LostBase <> ISNULL(x.L, 0);

-- 5. Each On the way warehouse holds exactly what its posted dispatches have on the way, never below 0 (expected: 0 rows)
SELECT w.WarehouseCode, b.ItemId, b.OnHandBase, OnTheWay = ISNULL(x.Q, 0)
FROM inventory.vw_StockBalance b
INNER JOIN masterdata.Warehouses w ON w.Id = b.WarehouseId AND w.IsTransit = 1
OUTER APPLY (SELECT Q = SUM(dl.QuantityBase - dl.SettledBase) FROM inventory.TransferPostingLines dl
             INNER JOIN inventory.TransferPostings p ON p.Id = dl.PostingId AND p.Kind = N'Dispatch' AND p.Status = 2
             WHERE dl.TransitWarehouseId = b.WarehouseId AND dl.ItemId = b.ItemId) x
WHERE b.OnHandBase < 0 OR b.OnHandBase <> ISNULL(x.Q, 0);

-- 6. Every transfer posting nets to zero in the ledger, its losses aside (expected: 0 rows)
SELECT p.Id FROM inventory.TransferPostings p
CROSS APPLY (SELECT Net = SUM(m.QuantityBase) FROM inventory.StockMovements m
             WHERE m.DocumentFamily = N'Transfer' AND m.DocumentTypeCode = CASE p.Kind WHEN N'Dispatch' THEN N'TRD' ELSE N'TRR' END
               AND m.DocumentId = p.Id AND ISNULL(m.ReasonCode, N'') <> N'TRF_LOSS') x
WHERE x.Net <> 0;

-- 7. Nothing points at an On the way warehouse but transfers (expected: 0 rows): items' defaults, containers, shortage
--    plans, stock / sales / purchase / goods receipt lines. Reachable only by a crafted call or data of before 90
--    (every save and posting refuses one with the leaf sentence; a shortage plan's order is refused with 66000 by 89).
SELECT N'Item' AS Kind, i.ItemCode AS Ref FROM inventory.Items i INNER JOIN masterdata.Warehouses w ON w.Id = i.DefaultWarehouseId AND w.IsTransit = 1
UNION ALL SELECT N'Container', c.ContainerRef FROM logistics.Containers c INNER JOIN masterdata.Warehouses w ON w.Id = c.WarehouseId AND w.IsTransit = 1
UNION ALL SELECT N'Shortage plan', s.DocumentNumber FROM inventory.ShortageDocuments s INNER JOIN masterdata.Warehouses w ON w.Id = s.WarehouseId AND w.IsTransit = 1
UNION ALL SELECT N'Stock document line', ISNULL(d.DocumentNumber, N'draft ' + CAST(d.Id AS NVARCHAR(10)))
          FROM inventory.StockDocumentLines l INNER JOIN inventory.StockDocuments d ON d.Id = l.DocumentId
          INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId AND w.IsTransit = 1
UNION ALL SELECT N'Sales line', ISNULL(d.DocumentNumber, N'draft ' + CAST(d.Id AS NVARCHAR(10)))
          FROM sales.SalesDocumentLines l INNER JOIN sales.SalesDocuments d ON d.Id = l.DocumentId
          INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId AND w.IsTransit = 1
UNION ALL SELECT N'Purchase line', ISNULL(d.DocumentNumber, N'draft ' + CAST(d.Id AS NVARCHAR(10)))
          FROM purchase.PurchaseDocumentLines l INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
          INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId AND w.IsTransit = 1
UNION ALL SELECT N'Goods receipt line', ISNULL(g.DocumentNumber, N'draft ' + CAST(g.Id AS NVARCHAR(10)))
          FROM purchase.GoodsReceiptLines l INNER JOIN purchase.GoodsReceipts g ON g.Id = l.GoodsReceiptId
          INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId AND w.IsTransit = 1;

PRINT 'Script 90 applied: transfer orders with dispatch, receipt, approval and the On the way warehouses.';
GO
