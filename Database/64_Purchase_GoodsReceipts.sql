SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 64: GOODS RECEIPTS (GRN) - THE NEW OBJECTS

   From script 65 on, goods enter stock only through a posted GOODS RECEIPT (document type GRN, "Goods Receipt",
   family Purchase, numbered per branch at posting: GRN-BR-002-000001). A supplier invoice posted after the switch
   moves no stock: it makes the amount payable and sets the INVOICE COST that received goods are valued at or
   corrected to. THIS SCRIPT ONLY ADDS OBJECTS: no existing procedure calls them yet, and nothing that runs today
   changes (the two attachment objects re-created here only learn the new document kind). Script 65 is the switch
   (the existing procedures); 64 and 65 reach main together, because the switch is one-way.

   Rules held by these objects
     - ONE SOURCE PER RECEIPT (GoodsReceipts.SourceKind): Container (a draft made when a Delivery-stage movement is
       completed, IsAuto = 1, or by "Receive goods..." on any confirmed container, status 2-5), Order, Invoice (the
       lines of a posted invoice not linked to a container), or Manual ("Without an order": a supplier is required).
       Statuses 1 Draft -> 2 Posted -> 3 Cancelled; the number is given at posting.
     - ONE OPEN RECEIPT PER CONTAINER, draft or posted: 63013, and the unique index UX_GoodsReceipts_OpenContainer.
     - A CONTAINER RECEIPT holds every container line, in pieces, received 0 to the loaded pieces, with a reason code
       when they differ (the difference is SETTLED SHORT); one warehouse of the container's branch; dated on or after
       the end of its latest completed Delivery; refused while a movement of the container is in progress. Posting
       it does what the offload did - the posted charges re-spread over what arrived and frozen, the container
       Offloaded at the warehouse - with GRN stock rows. Its charges and landed cost stay on the CONTAINER LINE and are
       never copied: a late container charge counts once.
     - LOCAL LINES (order, invoice, manual) receive more than 0 into an active warehouse - or 0 with "Nothing more will
       come" on a line of an order, when the supplier says the rest will never arrive; an order line no more than what
       remains outside containers, an invoice line without an order no more than invoiced - received (63011);
       "Nothing more will come" settles the rest of an order line, with a reason. A receipt without an order is
       refused at posting while its supplier has the item to receive on an order or an invoice (63011).
     - COST: received pieces are MATCHED to the pieces of posted invoice lines (usp_GoodsReceipt_Rematch: the receipt's
       own invoice, then the container line, the order line, the supplier + item; first in first out). Matched pieces
       take the invoice cost, the others the order price (or the typed cost of a manual line). Every later change of
       that cost (an invoice or an LCA posted or cancelled, a receipt posted or cancelled) is trued up: one
       GoodsReceiptCostChanges row and inventory.CostAdjustments rows (SourceKind GRNCOST), the part still in COMPANY
       stock to the stock value, the rest to cost of sales, never dated before the receipt. Pieces that fill a
       negative stock at posting take the cost difference to cost of sales (NEGSTOCK).
     - CANCEL reverses the stock; refused when the stock was used (63007), the cost was adjusted afterwards (63008),
       the container is closed or a purchase return took the goods back (63010).
     - ORDER LINES count what is RECEIVED (GoodsReceivedBase) and SETTLED SHORT (GoodsShortBase) next to what is
       INVOICED (ReceivedQuantityBase, unchanged); an order fully invoiced and received closes ("Fully invoiced and
       received") and reopens when the receipt that closed it is cancelled.
     - THE REFUSALS OF POST AND CANCEL ARE WRITTEN ONCE (fn_GoodsReceipt_PostCheck / _CancelCheck): the receipt page
       shows the same sentences (fn_GoodsReceipt_Blocks, usp_GoodsReceipt_Get).
     - An invoice is marked UsesGoodsReceipts = 1 when script 65's Post posts it; GoodsReceiptSwitch gets its one row
       from script 65. Until then GoodsReceivedBase is 0 everywhere: this script never ships without 65.
     - A received container line keeps "reason code: note" in logistics.ContainerLines.VarianceReason, widened from 200
       to 400 characters.

   Objects
     purchase.PurchaseDocuments.UsesGoodsReceipts; purchase.PurchaseDocumentLines.GoodsReceivedBase, GoodsShortBase
       (new columns, default 0); logistics.ContainerLines.VarianceReason (widened)
     purchase.GoodsReceipts, GoodsReceiptLines, GoodsReceiptInvoiceMatches, GoodsReceiptCostChanges, GoodsReceiptFiles,
       GoodsReceiptAudit, GoodsReceiptSwitch (new tables)
     purchase.tvp_GoodsReceiptLine, tvp_GoodsReceiptAnchor (new table types - FROZEN: a later change takes a new name)
     inventory.DocumentTypes: GRN (new row; on its first insert only, the attachment types goods receipts use)
     security.Permissions: purchase.goodsreceipts.view / create / post / cancel / delete (new), granted ONCE, when
       first inserted, to the roles that bring goods into stock today
     masterdata.fn_AttachmentDocumentKinds, masterdata.usp_AttachmentType_Delete (re-created from their current
       bodies, script 55: + GRN, + the goods receipt files)
     Functions (new): logistics.fn_Container_ReceivedBy, logistics.fn_Container_LastDelivery,
       purchase.fn_PoLine_Progress, fn_PoLine_CommittedOutside, fn_InvoiceLine_ToReceive, fn_GoodsReceipt_GroupLines,
       fn_GoodsReceiptLine_TargetCost, fn_GoodsReceiptLine_Cost, fn_GoodsReceipt_PostCheck, fn_GoodsReceipt_CancelCheck,
       fn_GoodsReceipt_Blocks
     Document procedures (new): purchase.usp_GoodsReceipt_Save, _CreateFromOrder, _CreateFromInvoice,
       _CreateForContainer, _CreateForMovement, _Delete, _Get, _Search, _WaitingCount, _File_Add / _List / _Get /
       _Update / _Delete
     Cost procedures (new): purchase.usp_GoodsReceipt_LockMatching, _Rematch, _TrueUpCost, _Post, _Cancel,
       purchase.usp_PurchaseInvoice_ReceiptCostPreview

   Errors (new block 63xxx, goods receipts)
     63000 validation (400) - 63004 changed by another user (409) - 63005 not a draft (409) - 63006 not found (404) -
     63007 stock consumed, cannot cancel (409) - 63008 cost adjusted, cannot cancel (409) - 63009 nothing to receive /
     no lines (400) - 63010 invalid status or source state (409) - 63011 more than remains / receive from the order
     (400) - 63012 attachment type not used for goods receipts (400) - 63013 the container already has a receipt (409).
     Also raised here: 65006 (the invoice of the cost preview not found), 70006 / 70010 (CreateForMovement: the movement
     not found / not a completed Delivery), 70013 (a manual charge share on a container line receiving nothing).
     Reserved for script 65: 69019 (new) a container with a goods receipt, 69016 a container not fully invoiced at
     Close, 69010 the Offload retired, 65011 an order with goods receipts / a return above received, 65028 an invoice
     line a goods receipt refers to.

   Requires scripts 23, 27, 46, 52, 55 and 63. Idempotent, additive: re-applied at every API start-up through
   Schema.sql, and builds a brand-new empty database (every table and column before the code that reads it).
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF COL_LENGTH(N'purchase.PurchaseDocuments', N'OneItemOnly') IS NULL
   OR COL_LENGTH(N'logistics.ContainerLines', N'PoLineId') IS NULL
   OR OBJECT_ID(N'logistics.Movements', N'U') IS NULL
   OR TYPE_ID(N'logistics.tvp_IdList') IS NULL
   OR OBJECT_ID(N'logistics.usp_Container_ReallocateCharges', N'P') IS NULL
   OR OBJECT_ID(N'inventory.usp_Item_ApplyReceipts', N'P') IS NULL
   OR OBJECT_ID(N'inventory.CostAdjustments', N'U') IS NULL
   OR OBJECT_ID(N'purchase.PaymentFiles', N'U') IS NULL
   OR OBJECT_ID(N'masterdata.AttachmentTypeUsages', N'U') IS NULL
   OR OBJECT_ID(N'masterdata.usp_AttachmentType_CheckForKind', N'P') IS NULL
BEGIN
    RAISERROR ('Run scripts 23, 27, 46, 52, 55 and 63 before this script.', 16, 1);
    SET NOEXEC ON;
END
GO

/* ================================================================== 1. New columns on existing tables */

-- Before any procedure reads them. Existing rows get the default: every invoice posted so far is "posted before
-- goods receipts" (0), and every order line has received / settled nothing yet - script 65 fills GoodsReceivedBase
-- once, from the ledger and the offloads (its switch batch). Drafts are never flipped and the defaults never change.
IF COL_LENGTH(N'purchase.PurchaseDocuments', N'UsesGoodsReceipts') IS NULL
BEGIN
    ALTER TABLE purchase.PurchaseDocuments ADD
        UsesGoodsReceipts BIT NOT NULL CONSTRAINT DF_PurchaseDocuments_UsesGoodsReceipts DEFAULT (0);   -- PINV posted by script 65's Post: stock through goods receipts
    PRINT 'PurchaseDocuments: added UsesGoodsReceipts';
END
GO

IF COL_LENGTH(N'purchase.PurchaseDocumentLines', N'GoodsReceivedBase') IS NULL
BEGIN
    ALTER TABLE purchase.PurchaseDocumentLines ADD
        GoodsReceivedBase INT NOT NULL CONSTRAINT DF_PurchaseDocumentLines_GoodsReceived DEFAULT (0),   -- PO lines: pieces RECEIVED (goods receipts, and the receipts made before them)
        GoodsShortBase    INT NOT NULL CONSTRAINT DF_PurchaseDocumentLines_GoodsShort DEFAULT (0);      -- PO lines: pieces SETTLED SHORT (nothing more will come)
    PRINT 'PurchaseDocumentLines: added GoodsReceivedBase, GoodsShortBase';
END
GO

-- A container receipt writes "reason code: note" on the container line; the receipt's note alone takes 300.
IF COL_LENGTH(N'logistics.ContainerLines', N'VarianceReason') < 800
BEGIN
    ALTER TABLE logistics.ContainerLines ALTER COLUMN VarianceReason NVARCHAR(400) NULL;
    PRINT 'ContainerLines: VarianceReason widened to 400 characters';
END
GO

/* ================================================================== 2. The goods receipt tables */

-- Its own tables, not purchase.PurchaseDocuments: some 30 queries read every PurchaseDocumentLines row that has a
-- ContainerLineId or SourceLineId as an INVOICE line, and a receipt has no price, currency, rate or approval.
-- Every foreign key is real: the master-data deletes (branch, warehouse, party, item) are driven by them, and the
-- party check finds the supplier columns by their name (SupplierId).
IF OBJECT_ID(N'purchase.GoodsReceipts', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.GoodsReceipts
    (
        Id                 INT IDENTITY(1,1) NOT NULL,
        DocumentTypeId     INT            NOT NULL,     -- GRN
        DocumentNumber     NVARCHAR(30)   NULL,         -- assigned on posting: GRN-BR-002-000001
        DocumentDate       DATE           NOT NULL,     -- date received
        BranchId           INT            NOT NULL,     -- the container's, order's or invoice's, or chosen; numbering branch
        WarehouseId        INT            NULL,         -- "Receive into"; required to post a container receipt (every line there)
        SupplierId         INT            NULL,         -- NULL only on a container of several suppliers; required on Manual
        SourceKind         NVARCHAR(10)   NOT NULL,     -- Container | Order | Invoice | Manual
        ContainerId        INT            NULL,         -- Container source only
        PurchaseOrderId    INT            NULL,         -- the order (Order source; a container of one order)
        PurchaseInvoiceId  INT            NULL,         -- Invoice source
        MovementId         INT            NULL,         -- the Delivery-stage movement whose completion created it
        IsAuto             BIT            NOT NULL CONSTRAINT DF_GoodsReceipts_IsAuto DEFAULT (0),   -- created by a Delivery completion
        SupplierReference  NVARCHAR(100)  NULL,         -- delivery note no.
        Notes              NVARCHAR(1000) NULL,
        Status             TINYINT        NOT NULL CONSTRAINT DF_GoodsReceipts_Status DEFAULT (1),   -- 1 Draft, 2 Posted, 3 Cancelled
        TotalExpectedBase  INT            NOT NULL CONSTRAINT DF_GoodsReceipts_Expected DEFAULT (0),
        TotalReceivedBase  INT            NOT NULL CONSTRAINT DF_GoodsReceipts_Received DEFAULT (0),
        ValueAtReceiptBase DECIMAL(18,2)  NOT NULL CONSTRAINT DF_GoodsReceipts_Value DEFAULT (0),    -- sum of received x cost at receipt, fixed at posting
        PostedAtUtc        DATETIME2(3)   NULL,
        PostedBy           INT            NULL,
        CancelledAtUtc     DATETIME2(3)   NULL,
        CancelledBy        INT            NULL,
        CancelReason       NVARCHAR(300)  NULL,
        CreatedAtUtc       DATETIME2(3)   NOT NULL CONSTRAINT DF_GoodsReceipts_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy          INT            NULL,
        UpdatedAtUtc       DATETIME2(3)   NULL,
        UpdatedBy          INT            NULL,
        RowVersion         ROWVERSION     NOT NULL,
        CONSTRAINT PK_GoodsReceipts PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_GoodsReceipts_Status CHECK (Status IN (1, 2, 3)),
        CONSTRAINT CK_GoodsReceipts_Source CHECK (SourceKind IN (N'Container', N'Order', N'Invoice', N'Manual')),
        -- the container is the source of a container receipt and of nothing else (the one-open-receipt index counts on it)
        CONSTRAINT CK_GoodsReceipts_Container CHECK ((SourceKind = N'Container' AND ContainerId IS NOT NULL)
                                                     OR (SourceKind <> N'Container' AND ContainerId IS NULL)),
        CONSTRAINT CK_GoodsReceipts_Invoice CHECK (SourceKind <> N'Invoice' OR PurchaseInvoiceId IS NOT NULL),
        CONSTRAINT CK_GoodsReceipts_Manual CHECK (SourceKind <> N'Manual' OR SupplierId IS NOT NULL),
        -- an automatic draft belongs to the Delivery movement that made it (cancelling that movement deletes it)
        CONSTRAINT CK_GoodsReceipts_Auto CHECK (IsAuto = 0 OR (SourceKind = N'Container' AND MovementId IS NOT NULL)),
        CONSTRAINT CK_GoodsReceipts_Posted CHECK (Status = 1 OR (DocumentNumber IS NOT NULL AND PostedAtUtc IS NOT NULL)),
        CONSTRAINT CK_GoodsReceipts_Cancelled CHECK (Status <> 3 OR CancelledAtUtc IS NOT NULL),
        CONSTRAINT FK_GoodsReceipts_Type        FOREIGN KEY (DocumentTypeId)    REFERENCES inventory.DocumentTypes (Id),
        CONSTRAINT FK_GoodsReceipts_Branch      FOREIGN KEY (BranchId)          REFERENCES masterdata.Branches (Id),
        CONSTRAINT FK_GoodsReceipts_Warehouse   FOREIGN KEY (WarehouseId)       REFERENCES masterdata.Warehouses (Id),
        CONSTRAINT FK_GoodsReceipts_Supplier    FOREIGN KEY (SupplierId)        REFERENCES masterdata.Parties (Id),
        CONSTRAINT FK_GoodsReceipts_Container   FOREIGN KEY (ContainerId)       REFERENCES logistics.Containers (Id),
        CONSTRAINT FK_GoodsReceipts_Order       FOREIGN KEY (PurchaseOrderId)   REFERENCES purchase.PurchaseDocuments (Id),
        CONSTRAINT FK_GoodsReceipts_Invoice     FOREIGN KEY (PurchaseInvoiceId) REFERENCES purchase.PurchaseDocuments (Id),
        CONSTRAINT FK_GoodsReceipts_Movement    FOREIGN KEY (MovementId)        REFERENCES logistics.Movements (Id),
        CONSTRAINT FK_GoodsReceipts_PostedBy    FOREIGN KEY (PostedBy)          REFERENCES security.Users (Id),
        CONSTRAINT FK_GoodsReceipts_CancelledBy FOREIGN KEY (CancelledBy)       REFERENCES security.Users (Id),
        CONSTRAINT FK_GoodsReceipts_CreatedBy   FOREIGN KEY (CreatedBy)         REFERENCES security.Users (Id),
        CONSTRAINT FK_GoodsReceipts_UpdatedBy   FOREIGN KEY (UpdatedBy)         REFERENCES security.Users (Id)
    );
    CREATE UNIQUE NONCLUSTERED INDEX UX_GoodsReceipts_Number ON purchase.GoodsReceipts (DocumentNumber) WHERE DocumentNumber IS NOT NULL;
    -- ONE OPEN RECEIPT PER CONTAINER: a draft or a posted one; a cancelled receipt frees the container.
    CREATE UNIQUE NONCLUSTERED INDEX UX_GoodsReceipts_OpenContainer ON purchase.GoodsReceipts (ContainerId) WHERE ContainerId IS NOT NULL AND Status < 3;
    CREATE NONCLUSTERED INDEX IX_GoodsReceipts_Order      ON purchase.GoodsReceipts (PurchaseOrderId)   WHERE PurchaseOrderId IS NOT NULL;
    CREATE NONCLUSTERED INDEX IX_GoodsReceipts_Invoice    ON purchase.GoodsReceipts (PurchaseInvoiceId) WHERE PurchaseInvoiceId IS NOT NULL;
    CREATE NONCLUSTERED INDEX IX_GoodsReceipts_Movement   ON purchase.GoodsReceipts (MovementId)        WHERE MovementId IS NOT NULL;
    CREATE NONCLUSTERED INDEX IX_GoodsReceipts_StatusDate ON purchase.GoodsReceipts (Status, DocumentDate DESC);
    CREATE NONCLUSTERED INDEX IX_GoodsReceipts_Supplier   ON purchase.GoodsReceipts (SupplierId, DocumentDate DESC);
    PRINT 'Created purchase.GoodsReceipts';
END
GO

-- A container line's cost lives on the CONTAINER LINE (FobCostBase, ChargesBase / ReceivedQuantityBase,
-- LandedCostBase): it is never copied here, so a late container charge is counted once. Fob / Charges / UnitCost
-- below are the CURRENT cost per piece of the other lines (order, invoice, manual), NULL on container lines.
IF OBJECT_ID(N'purchase.GoodsReceiptLines', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.GoodsReceiptLines
    (
        Id                   INT IDENTITY(1,1) NOT NULL,
        GoodsReceiptId       INT           NOT NULL,
        LineNumber           INT           NOT NULL,
        ItemId               INT           NOT NULL,
        ItemUnitId           INT           NOT NULL,     -- container lines: the base unit
        Quantity             INT           NOT NULL,     -- received, in the unit (0: a container line, or a local order line with "Nothing more will come")
        PackingFormula       INT           NOT NULL,
        QuantityBase         AS (Quantity * PackingFormula) PERSISTED,   -- received pieces
        ExpectedQuantityBase INT           NULL,         -- container: loaded; order or invoice: to receive when created
        VarianceReasonCode   NVARCHAR(20)  NULL,         -- SHORT | DAMAGED | MISSING | LOADCOUNT | OTHER
        VarianceReason       NVARCHAR(300) NULL,         -- the free note
        CloseShort           BIT           NOT NULL CONSTRAINT DF_GoodsReceiptLines_CloseShort DEFAULT (0),   -- local lines: "Nothing more will come"
        SettledShortBase     INT           NOT NULL CONSTRAINT DF_GoodsReceiptLines_Settled DEFAULT (0),      -- set at posting: expected - received when settled
        WarehouseId          INT           NULL,         -- container lines: the header's
        SupplierId           INT           NULL,         -- the line's order (or invoice, or the manual header)
        PurchaseOrderId      INT           NULL,
        PoLineId             INT           NULL,         -- the order line; set on every line that comes from an order
        InvoiceLineId        INT           NULL,         -- the invoice line it was received from (Invoice source)
        ContainerLineId      INT           NULL,
        ExpiryDate           DATE          NULL,
        PoFobBase            DECIMAL(18,6) NULL,         -- order price per piece in base currency, frozen at posting
        ManualUnitCostBase   DECIMAL(18,6) NULL,         -- typed cost per piece (manual lines)
        FobCostBase          DECIMAL(18,6) NULL,         -- current, per piece (not on container lines)
        ChargesBase          DECIMAL(18,6) NULL,         -- current, per piece (not on container lines)
        UnitCostBase         DECIMAL(18,6) NULL,         -- current landed, per piece (not on container lines)
        CostAtReceiptBase    DECIMAL(18,6) NULL,         -- the cost written on the stock movement
        CostSource           NVARCHAR(10)  NULL,         -- Order | Invoice | Mixed | Manual (current)
        InvoicedBase         INT           NOT NULL CONSTRAINT DF_GoodsReceiptLines_Invoiced DEFAULT (0),     -- pieces matched to posted invoices
        Notes                NVARCHAR(300) NULL,
        CONSTRAINT PK_GoodsReceiptLines PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_GoodsReceiptLines_LineNo UNIQUE (GoodsReceiptId, LineNumber),
        CONSTRAINT CK_GoodsReceiptLines_Qty CHECK (Quantity >= 0),
        CONSTRAINT CK_GoodsReceiptLines_Formula CHECK (PackingFormula >= 1),
        CONSTRAINT CK_GoodsReceiptLines_Expected CHECK (ExpectedQuantityBase IS NULL OR ExpectedQuantityBase >= 0),
        CONSTRAINT CK_GoodsReceiptLines_Reason CHECK (VarianceReasonCode IS NULL
                                                      OR VarianceReasonCode IN (N'SHORT', N'DAMAGED', N'MISSING', N'LOADCOUNT', N'OTHER')),
        CONSTRAINT CK_GoodsReceiptLines_Settled CHECK (SettledShortBase >= 0),
        CONSTRAINT CK_GoodsReceiptLines_Invoiced CHECK (InvoicedBase >= 0 AND InvoicedBase <= Quantity * PackingFormula),
        CONSTRAINT CK_GoodsReceiptLines_ManualCost CHECK (ManualUnitCostBase IS NULL OR ManualUnitCostBase >= 0),
        CONSTRAINT CK_GoodsReceiptLines_CostSource CHECK (CostSource IS NULL OR CostSource IN (N'Order', N'Invoice', N'Mixed', N'Manual')),
        -- an order line and its order go together; a container line always comes from an order line
        CONSTRAINT CK_GoodsReceiptLines_Order CHECK ((PoLineId IS NULL AND PurchaseOrderId IS NULL) OR (PoLineId IS NOT NULL AND PurchaseOrderId IS NOT NULL)),
        CONSTRAINT CK_GoodsReceiptLines_Container CHECK (ContainerLineId IS NULL OR PoLineId IS NOT NULL),
        CONSTRAINT FK_GoodsReceiptLines_Receipt       FOREIGN KEY (GoodsReceiptId)  REFERENCES purchase.GoodsReceipts (Id),
        CONSTRAINT FK_GoodsReceiptLines_Item          FOREIGN KEY (ItemId)          REFERENCES inventory.Items (Id),
        CONSTRAINT FK_GoodsReceiptLines_Unit          FOREIGN KEY (ItemUnitId)      REFERENCES inventory.ItemUnits (Id),
        CONSTRAINT FK_GoodsReceiptLines_Warehouse     FOREIGN KEY (WarehouseId)     REFERENCES masterdata.Warehouses (Id),
        CONSTRAINT FK_GoodsReceiptLines_Supplier      FOREIGN KEY (SupplierId)      REFERENCES masterdata.Parties (Id),
        CONSTRAINT FK_GoodsReceiptLines_Order         FOREIGN KEY (PurchaseOrderId) REFERENCES purchase.PurchaseDocuments (Id),
        CONSTRAINT FK_GoodsReceiptLines_PoLine        FOREIGN KEY (PoLineId)        REFERENCES purchase.PurchaseDocumentLines (Id),
        CONSTRAINT FK_GoodsReceiptLines_InvoiceLine   FOREIGN KEY (InvoiceLineId)   REFERENCES purchase.PurchaseDocumentLines (Id),
        CONSTRAINT FK_GoodsReceiptLines_ContainerLine FOREIGN KEY (ContainerLineId) REFERENCES logistics.ContainerLines (Id)
    );
    CREATE NONCLUSTERED INDEX IX_GoodsReceiptLines_PoLine ON purchase.GoodsReceiptLines (PoLineId)
        INCLUDE (GoodsReceiptId, ContainerLineId, QuantityBase) WHERE PoLineId IS NOT NULL;
    CREATE NONCLUSTERED INDEX IX_GoodsReceiptLines_InvoiceLine ON purchase.GoodsReceiptLines (InvoiceLineId)
        INCLUDE (GoodsReceiptId, QuantityBase) WHERE InvoiceLineId IS NOT NULL;
    CREATE NONCLUSTERED INDEX IX_GoodsReceiptLines_ContainerLine ON purchase.GoodsReceiptLines (ContainerLineId)
        INCLUDE (GoodsReceiptId) WHERE ContainerLineId IS NOT NULL;
    CREATE NONCLUSTERED INDEX IX_GoodsReceiptLines_SupplierItem ON purchase.GoodsReceiptLines (SupplierId, ItemId);
    CREATE NONCLUSTERED INDEX IX_GoodsReceiptLines_Item         ON purchase.GoodsReceiptLines (ItemId);
    PRINT 'Created purchase.GoodsReceiptLines';
END
GO

-- THE QUANTITY CHECK IS ONLY "NOT NEGATIVE". Which lines may receive 0 pieces is usp_GoodsReceipt_Save's rule: a
-- container line (the difference is settled), or a local line of an order with "Nothing more will come" (it settles
-- the rest of the order line when nothing more arrives). A table check cannot hold it: a CANCELLED receipt keeps its
-- lines, and a line whose container line is removed afterwards (usp_Container_Save) lets go of it whatever it
-- received. Re-created by name when a database holds another definition (a draft of this script required a container
-- line on a 0-piece line), so every database ends with this one.
IF OBJECT_ID(N'purchase.GoodsReceiptLines', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.check_constraints
                   WHERE parent_object_id = OBJECT_ID(N'purchase.GoodsReceiptLines') AND name = N'CK_GoodsReceiptLines_Qty'
                     AND definition = N'([Quantity]>=(0))')
BEGIN
    IF EXISTS (SELECT 1 FROM sys.check_constraints
               WHERE parent_object_id = OBJECT_ID(N'purchase.GoodsReceiptLines') AND name = N'CK_GoodsReceiptLines_Qty')
        ALTER TABLE purchase.GoodsReceiptLines DROP CONSTRAINT CK_GoodsReceiptLines_Qty;
    ALTER TABLE purchase.GoodsReceiptLines ADD CONSTRAINT CK_GoodsReceiptLines_Qty CHECK (Quantity >= 0);
    PRINT 'Re-created purchase.GoodsReceiptLines check CK_GoodsReceiptLines_Qty (Quantity >= 0)';
END
GO

-- Which received pieces each posted invoice line pays for. Rebuilt per group (an order line, or a supplier + item
-- for goods without an order) by usp_GoodsReceipt_Rematch, first in first out.
IF OBJECT_ID(N'purchase.GoodsReceiptInvoiceMatches', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.GoodsReceiptInvoiceMatches
    (
        GoodsReceiptLineId INT          NOT NULL,
        InvoiceLineId      INT          NOT NULL,     -- a line of a posted (or closed) PINV
        QuantityBase       INT          NOT NULL,
        MatchedAtUtc       DATETIME2(3) NOT NULL CONSTRAINT DF_GoodsReceiptInvoiceMatches_At DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_GoodsReceiptInvoiceMatches PRIMARY KEY CLUSTERED (GoodsReceiptLineId, InvoiceLineId),
        CONSTRAINT CK_GoodsReceiptInvoiceMatches_Qty CHECK (QuantityBase > 0),
        CONSTRAINT FK_GoodsReceiptInvoiceMatches_Line        FOREIGN KEY (GoodsReceiptLineId) REFERENCES purchase.GoodsReceiptLines (Id),
        CONSTRAINT FK_GoodsReceiptInvoiceMatches_InvoiceLine FOREIGN KEY (InvoiceLineId)      REFERENCES purchase.PurchaseDocumentLines (Id)
    );
    CREATE NONCLUSTERED INDEX IX_GoodsReceiptInvoiceMatches_InvoiceLine ON purchase.GoodsReceiptInvoiceMatches (InvoiceLineId) INCLUDE (QuantityBase);
    PRINT 'Created purchase.GoodsReceiptInvoiceMatches';
END
GO

-- The history of the cost of received goods: one row per receipt line per event (an invoice or an LCA posted or
-- cancelled, a receipt posted or cancelled, negative stock filled at posting). Id = inventory.CostAdjustments.SourceId
-- of its GRNCOST rows.
IF OBJECT_ID(N'purchase.GoodsReceiptCostChanges', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.GoodsReceiptCostChanges
    (
        Id                 INT IDENTITY(1,1) NOT NULL,
        GoodsReceiptLineId INT           NOT NULL,
        ChangedAtUtc       DATETIME2(3)  NOT NULL CONSTRAINT DF_GoodsReceiptCostChanges_At DEFAULT (SYSUTCDATETIME()),
        CauseKind          NVARCHAR(12)  NOT NULL,     -- PINV | PINVCANCEL | LCA | LCACANCEL | GRNPOST | GRNCANCEL | NEGSTOCK
        CauseId            INT           NULL,         -- the invoice, LCA or goods receipt that caused it
        CauseNumber        NVARCHAR(30)  NULL,
        ReceivedBase       INT           NOT NULL,     -- the line's received pieces at the time
        InStockBase        DECIMAL(18,6) NOT NULL CONSTRAINT DF_GoodsReceiptCostChanges_InStock DEFAULT (0),   -- the share used for the stock / COGS split
        FobBefore          DECIMAL(18,6) NULL,
        FobAfter           DECIMAL(18,6) NULL,
        UnitCostBefore     DECIMAL(18,6) NULL,
        UnitCostAfter      DECIMAL(18,6) NULL,
        AmountBase         DECIMAL(18,2) NOT NULL CONSTRAINT DF_GoodsReceiptCostChanges_Amount DEFAULT (0),
        InventoryBase      DECIMAL(18,2) NOT NULL CONSTRAINT DF_GoodsReceiptCostChanges_Inventory DEFAULT (0),
        CogsBase           DECIMAL(18,2) NOT NULL CONSTRAINT DF_GoodsReceiptCostChanges_Cogs DEFAULT (0),
        CreatedBy          INT           NULL,
        CONSTRAINT PK_GoodsReceiptCostChanges PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_GoodsReceiptCostChanges_Cause CHECK (CauseKind IN (N'PINV', N'PINVCANCEL', N'LCA', N'LCACANCEL', N'GRNPOST', N'GRNCANCEL', N'NEGSTOCK')),
        CONSTRAINT CK_GoodsReceiptCostChanges_Split CHECK (AmountBase = InventoryBase + CogsBase),
        CONSTRAINT FK_GoodsReceiptCostChanges_Line      FOREIGN KEY (GoodsReceiptLineId) REFERENCES purchase.GoodsReceiptLines (Id),
        CONSTRAINT FK_GoodsReceiptCostChanges_CreatedBy FOREIGN KEY (CreatedBy)          REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_GoodsReceiptCostChanges_Line  ON purchase.GoodsReceiptCostChanges (GoodsReceiptLineId, ChangedAtUtc);
    CREATE NONCLUSTERED INDEX IX_GoodsReceiptCostChanges_Cause ON purchase.GoodsReceiptCostChanges (CauseKind, CauseId);
    PRINT 'Created purchase.GoodsReceiptCostChanges';
END
GO

-- The shape of the purchase files after scripts 52 and 55: a type (used for GRN), a document date, a note.
IF OBJECT_ID(N'purchase.GoodsReceiptFiles', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.GoodsReceiptFiles
    (
        Id               INT IDENTITY(1,1) NOT NULL,
        GoodsReceiptId   INT            NOT NULL,
        AttachmentTypeId INT            NOT NULL,
        DocumentDate     DATE           NULL,
        Note             NVARCHAR(500)  NULL,
        FileName         NVARCHAR(255)  NOT NULL,
        ContentType      NVARCHAR(100)  NOT NULL,
        SizeBytes        INT            NOT NULL,
        Content          VARBINARY(MAX) NOT NULL,
        CreatedAtUtc     DATETIME2(3)   NOT NULL CONSTRAINT DF_GoodsReceiptFiles_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy        INT            NULL,
        CONSTRAINT PK_GoodsReceiptFiles PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_GoodsReceiptFiles_Size CHECK (SizeBytes > 0),
        CONSTRAINT FK_GoodsReceiptFiles_Receipt   FOREIGN KEY (GoodsReceiptId)   REFERENCES purchase.GoodsReceipts (Id),
        CONSTRAINT FK_GoodsReceiptFiles_Type      FOREIGN KEY (AttachmentTypeId) REFERENCES masterdata.AttachmentTypes (Id),
        CONSTRAINT FK_GoodsReceiptFiles_CreatedBy FOREIGN KEY (CreatedBy)        REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_GoodsReceiptFiles_Receipt ON purchase.GoodsReceiptFiles (GoodsReceiptId);
    PRINT 'Created purchase.GoodsReceiptFiles';
END
GO

-- The common audit shape. No foreign key on the receipt, as purchase.PurchaseDocumentAudit: deleting a draft deletes
-- its audit rows itself.
IF OBJECT_ID(N'purchase.GoodsReceiptAudit', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.GoodsReceiptAudit
    (
        Id             BIGINT IDENTITY(1,1) NOT NULL,
        GoodsReceiptId INT           NOT NULL,
        Action         NVARCHAR(20)  NOT NULL,   -- Created | Updated | Posted | Cancelled | CostAdjusted | FileAdded | FileUpdated | FileDeleted
        Details        NVARCHAR(500) NULL,
        UserId         INT           NULL,
        AtUtc          DATETIME2(3)  NOT NULL CONSTRAINT DF_GoodsReceiptAudit_AtUtc DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_GoodsReceiptAudit PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_GoodsReceiptAudit_User FOREIGN KEY (UserId) REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_GoodsReceiptAudit_Receipt ON purchase.GoodsReceiptAudit (GoodsReceiptId, AtUtc);
    PRINT 'Created purchase.GoodsReceiptAudit';
END
GO

-- THE MOMENT OF THE SWITCH: one row, inserted once by script 65 in the transaction that fills GoodsReceivedBase.
-- Empty until then. Its date is shown as "Posted before goods receipts ({date})".
IF OBJECT_ID(N'purchase.GoodsReceiptSwitch', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.GoodsReceiptSwitch
    (
        Id            TINYINT      NOT NULL,
        SwitchedAtUtc DATETIME2(3) NOT NULL CONSTRAINT DF_GoodsReceiptSwitch_At DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_GoodsReceiptSwitch PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_GoodsReceiptSwitch_One CHECK (Id = 1)
    );
    PRINT 'Created purchase.GoodsReceiptSwitch';
END
GO

/* ================================================================== 3. Table types (frozen) */

-- FROZEN: IF TYPE_ID ... IS NULL never alters a type, and a type in use cannot be dropped at start-up. A later change
-- takes a new name (tvp_GoodsReceiptLine2). The API passes the columns in this order.
IF TYPE_ID(N'purchase.tvp_GoodsReceiptLine') IS NULL
BEGIN
    CREATE TYPE purchase.tvp_GoodsReceiptLine AS TABLE
    (
        LineNumber           INT           NOT NULL PRIMARY KEY,
        ItemId               INT           NOT NULL,
        ItemUnitId           INT           NOT NULL,
        Quantity             INT           NOT NULL,     -- in the unit
        WarehouseId          INT           NULL,         -- container receipts: ignored, the header's
        PoLineId             INT           NULL,
        InvoiceLineId        INT           NULL,
        ContainerLineId      INT           NULL,
        ExpectedQuantityBase INT           NULL,
        VarianceReasonCode   NVARCHAR(20)  NULL,
        VarianceReason       NVARCHAR(300) NULL,
        CloseShort           BIT           NULL,         -- NULL = 0
        ManualUnitCostBase   DECIMAL(18,6) NULL,
        ExpiryDate           DATE          NULL,
        Notes                NVARCHAR(300) NULL
    );
    PRINT 'Created type purchase.tvp_GoodsReceiptLine';
END
GO

-- The groups a rematch rebuilds: an order line ('P', with all its container lines), or a supplier + item ('S') for
-- goods without an order.
IF TYPE_ID(N'purchase.tvp_GoodsReceiptAnchor') IS NULL
BEGIN
    CREATE TYPE purchase.tvp_GoodsReceiptAnchor AS TABLE
    (
        Kind       CHAR(1) NOT NULL,     -- P order line | S supplier + item
        PoLineId   INT     NULL,
        SupplierId INT     NULL,
        ItemId     INT     NULL,
        CHECK ((Kind = 'P' AND PoLineId IS NOT NULL) OR (Kind = 'S' AND SupplierId IS NOT NULL AND ItemId IS NOT NULL))
    );
    PRINT 'Created type purchase.tvp_GoodsReceiptAnchor';
END
GO

/* ================================================================== 4. Document type GRN */

-- Numbered per branch at posting, six digits, no year: GRN-BR-002-000001 (as PINV-BR-003-000011). No prices.
-- THE FIRST INSERT ONLY (the OUTPUT of the MERGE) says which attachment types goods receipts use: "Other" and the
-- delivery notes ("Delivery Note", and a container's "Offloading Note"), packing list and bill of lading of the main
-- list. Never again: a kind an administrator takes off a type stays off. The UPDATE repairs a GRN row only while
-- nobody changed it on the Document Types page.
-- IN ONE TRANSACTION WITH THE MERGE: its OUTPUT is the only trigger of the seed, so a seed that fails (timeout,
-- deadlock, lost connection) must undo the insert too; the next start then inserts the row again and seeds.
SET XACT_ABORT ON;
BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @GrnInserted TABLE (Id INT NOT NULL);

    MERGE inventory.DocumentTypes AS t
    USING (VALUES (N'GRN', N'Goods Receipt', N'Purchase', 1, N'GRN-', 1, 0, N'None', 0, 1, 0, 6))
          AS s (Code, Name, Family, StockDirection, NumberPrefix, NumberOnPost, RequiresReason,
                DefaultPricing, PriceEditable, NumberPerBranch, YearInNumber, NumberLength)
    ON t.Code = s.Code
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (Code, Name, Family, StockDirection, NumberPrefix, NumberOnPost, RequiresReason,
                DefaultPricing, PriceEditable, NumberPerBranch, YearInNumber, NumberLength)
        VALUES (s.Code, s.Name, s.Family, s.StockDirection, s.NumberPrefix, s.NumberOnPost, s.RequiresReason,
                s.DefaultPricing, s.PriceEditable, s.NumberPerBranch, s.YearInNumber, s.NumberLength)
    OUTPUT inserted.Id INTO @GrnInserted (Id);

    UPDATE inventory.DocumentTypes
    SET DefaultPricing = N'None', PriceEditable = 0, NumberPerBranch = 1, YearInNumber = 0, NumberLength = 6
    WHERE Code = N'GRN' AND UpdatedAtUtc IS NULL
      AND (DefaultPricing <> N'None' OR PriceEditable <> 0 OR NumberPerBranch <> 1 OR YearInNumber <> 0 OR NumberLength <> 6);

    IF EXISTS (SELECT 1 FROM @GrnInserted)
    BEGIN
        -- "Other": the one the purchase invoices use, else script 52's choice; created when there is none at all.
        DECLARE @Other INT = (SELECT TOP (1) t.Id FROM masterdata.AttachmentTypes t
                              WHERE t.SubType = N'Other' AND t.Category IN (N'Other', N'General')
                              ORDER BY CASE WHEN EXISTS (SELECT 1 FROM masterdata.AttachmentTypeUsages u
                                                         WHERE u.AttachmentTypeId = t.Id AND u.DocumentKind = N'PINV') THEN 0 ELSE 1 END,
                                       CASE t.AppliesTo WHEN N'Logistics' THEN 0 ELSE 1 END,
                                       CASE t.Category WHEN N'Other' THEN 0 ELSE 1 END, t.Id);
        IF @Other IS NULL
        BEGIN
            INSERT INTO masterdata.AttachmentTypes (Category, SubType, SortOrder, AppliesTo) VALUES (N'General', N'Other', 999, N'Logistics');
            SET @Other = SCOPE_IDENTITY();
        END

        INSERT INTO masterdata.AttachmentTypeUsages (AttachmentTypeId, DocumentKind)
        SELECT t.Id, N'GRN'
        FROM masterdata.AttachmentTypes t
        WHERE (t.Id = @Other
               OR (t.AppliesTo = N'Logistics' AND t.SubType IN (N'Delivery Note', N'Offloading Note', N'Packing List', N'Bill of Lading')))
          AND NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypeUsages u WHERE u.AttachmentTypeId = t.Id AND u.DocumentKind = N'GRN');

        PRINT 'Document type GRN created; attachment types used for goods receipts: Other, Delivery Note, Offloading Note, Packing List, Bill of Lading.';
    END

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
SET XACT_ABORT OFF;
GO

/* ================================================================== 5. Permissions and their one-time grants */

-- The texts are PermissionCatalog.cs's (the start-up sync copies them over and gives them to the system roles).
-- THE GRANTS ARE MADE ONCE, in this batch and transaction, only for the codes this MERGE inserts (its OUTPUT): a right
-- an administrator takes away later is never given back. The people who bring goods into stock today keep doing it:
--   - roles holding containers.offload (the offload) or purchase.invoices.post (a local invoice adds stock today),
--     and the Manager role: view, create, post;
--   - roles holding containers.cancel or purchase.invoices.cancel: cancel;
--   - roles holding purchase.invoices.view or purchase.orders.view: view;
--   - every role that holds create: delete (of its own drafts' kind);
--   - system roles: everything (as the start-up sync does).
SET XACT_ABORT ON;
BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @Changed TABLE (Action NVARCHAR(10) NOT NULL, PermissionId INT NOT NULL, Code NVARCHAR(100) NOT NULL);

    MERGE security.Permissions AS target
    USING
    (
        VALUES
            (N'purchase.goodsreceipts.view',   N'View Goods Receipts',   N'Purchase', N'See goods receipts.',                                                                    1102),
            (N'purchase.goodsreceipts.create', N'Create Goods Receipts', N'Purchase', N'Create and edit draft goods receipts, from containers, orders, invoices or by hand.',     1104),
            (N'purchase.goodsreceipts.post',   N'Post Goods Receipts',   N'Purchase', N'Post goods receipts: the goods enter stock and the item costs are set.',                 1106),
            (N'purchase.goodsreceipts.cancel', N'Cancel Goods Receipts', N'Purchase', N'Cancel posted goods receipts (stock reversal).',                                         1108),
            (N'purchase.goodsreceipts.delete', N'Delete Goods Receipts', N'Purchase', N'Delete draft goods receipts.',                                                           1110)
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
        DECLARE @Grant TABLE (RoleId INT NOT NULL, Code NVARCHAR(100) NOT NULL, PRIMARY KEY (RoleId, Code));

        -- view, create and post: the roles that receive goods today
        INSERT INTO @Grant (RoleId, Code)
        SELECT r.Id, c.Code
        FROM security.Roles r
        CROSS JOIN (VALUES (N'purchase.goodsreceipts.view'), (N'purchase.goodsreceipts.create'), (N'purchase.goodsreceipts.post')) c (Code)
        WHERE r.IsSystem = 1 OR r.Name = N'Manager'
           OR EXISTS (SELECT 1 FROM security.RolePermissions rp INNER JOIN security.Permissions p ON p.Id = rp.PermissionId
                      WHERE rp.RoleId = r.Id AND p.Code IN (N'containers.offload', N'purchase.invoices.post'));

        -- cancel: the roles that reverse an offload or cancel an invoice today
        INSERT INTO @Grant (RoleId, Code)
        SELECT r.Id, N'purchase.goodsreceipts.cancel'
        FROM security.Roles r
        WHERE r.IsSystem = 1
           OR EXISTS (SELECT 1 FROM security.RolePermissions rp INNER JOIN security.Permissions p ON p.Id = rp.PermissionId
                      WHERE rp.RoleId = r.Id AND p.Code IN (N'containers.cancel', N'purchase.invoices.cancel'));

        -- view: the roles that see orders or invoices
        INSERT INTO @Grant (RoleId, Code)
        SELECT r.Id, N'purchase.goodsreceipts.view'
        FROM security.Roles r
        WHERE EXISTS (SELECT 1 FROM security.RolePermissions rp INNER JOIN security.Permissions p ON p.Id = rp.PermissionId
                      WHERE rp.RoleId = r.Id AND p.Code IN (N'purchase.invoices.view', N'purchase.orders.view'))
          AND NOT EXISTS (SELECT 1 FROM @Grant g WHERE g.RoleId = r.Id AND g.Code = N'purchase.goodsreceipts.view');

        -- delete: every role that may create (drafts are deleted by the people who make them)
        INSERT INTO @Grant (RoleId, Code)
        SELECT g.RoleId, N'purchase.goodsreceipts.delete' FROM @Grant g WHERE g.Code = N'purchase.goodsreceipts.create';

        INSERT INTO security.RolePermissions (RoleId, PermissionId)
        SELECT g.RoleId, c.PermissionId
        FROM @Grant g
        INNER JOIN @Changed c ON c.Code = g.Code AND c.Action = N'INSERT'
        WHERE NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = g.RoleId AND rp.PermissionId = c.PermissionId);

        DECLARE @Codes INT = (SELECT COUNT(*) FROM @Changed WHERE Action = N'INSERT'),
                @Roles INT = (SELECT COUNT(DISTINCT RoleId) FROM @Grant);
        PRINT 'Goods receipt permissions created and granted once: ' + CAST(@Codes AS NVARCHAR(10)) + ' code(s), '
              + CAST(@Roles AS NVARCHAR(10)) + ' role(s).';
    END

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
SET XACT_ABORT OFF;
GO

/* ================================================================== 6. Attachments: the document kind GRN */

-- Re-created (64) from the body of script 55: + GRN (goods receipts), after the purchase returns.
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
             (N'INV_OUT',   N'Inventory Out',     N'Inventory Out documents', 100)) k (Code, Name, Noun, SortOrder);
GO

-- Re-created (64) from the body of script 55: + the goods receipt files.
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

/* ================================================================== 7. Containers: who received one, and its latest Delivery */

-- THE ONLY TEST FOR "OFFLOADED BEFORE GOODS RECEIPTS". One row, always (NULL columns for a NULL or unknown id, so
-- callers may CROSS APPLY it on an outer-joined container):
--   ReceivedBy  'GRN' when a posted goods receipt of the container exists; 'Offload' when the container is Offloaded
--               or Closed (6, 7) without one (the offload of script 27); NULL otherwise.
--   GoodsReceipt*  the container's open receipt - a draft or the posted one (one at most, UX_GoodsReceipts_OpenContainer).
CREATE OR ALTER FUNCTION logistics.fn_Container_ReceivedBy (@ContainerId INT)
RETURNS TABLE
AS
RETURN
    SELECT ReceivedBy         = CAST(CASE WHEN g.Status = 2 THEN N'GRN'
                                          WHEN c.Status IN (6, 7) THEN N'Offload' END AS NVARCHAR(10)),
           GoodsReceiptId     = g.Id,
           GoodsReceiptNumber = g.DocumentNumber,
           GoodsReceiptStatus = g.Status
    FROM (SELECT ContainerId = @ContainerId) k
    LEFT  JOIN logistics.Containers c ON c.Id = k.ContainerId
    OUTER APPLY (SELECT TOP (1) gr.Id, gr.DocumentNumber, gr.Status
                 FROM purchase.GoodsReceipts gr
                 WHERE gr.ContainerId = k.ContainerId AND gr.Status < 3
                 ORDER BY gr.Status DESC, gr.Id DESC) g;
GO

-- THE LATEST COMPLETED DELIVERY of a container: the end of its latest completed movement whose type has the stage
-- Delivery (whatever the type's code). No row when there is none. Goods cannot be received before it (Save, Post), the
-- receipt page names its place, and the "Delivered, not received" filters start from it.
CREATE OR ALTER FUNCTION logistics.fn_Container_LastDelivery (@ContainerId INT)
RETURNS TABLE
AS
RETURN
    SELECT TOP (1) MovementId = m.Id, m.MovementNo, m.EndDate, PlaceId = m.ToPlaceId, PlaceName = tp.PortName,
                   m.CompletedAtUtc
    FROM logistics.MovementContainers mc
    INNER JOIN logistics.Movements m       ON m.Id = mc.MovementId AND m.Status = 3
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId AND mt.Stage = N'Delivery'
    INNER JOIN masterdata.Ports tp         ON tp.Id = m.ToPlaceId
    WHERE mc.ContainerId = @ContainerId
    ORDER BY m.EndDate DESC, m.CompletedAtUtc DESC, m.Id DESC;
GO

/* ================================================================== 8. Order lines: received, settled, to receive */

-- One row per line of a purchase order (none for another document type). In pieces:
--   OrderedBase          ordered
--   InvoicedBase         invoiced = ReceivedQuantityBase (its old name, its meaning unchanged)
--   GoodsReceivedBase    received; GoodsShortBase settled short (nothing more will come)
--   InContainersBase     loaded in containers not received yet (status 1-5: draft to cleared)
--   InDraftReceiptsBase  on draft goods receipts outside containers
--   ToReceiveBase        what the "Receive goods..." dialogs propose: ordered - received - short - in containers - in drafts
--   MaxOutsideBase       the posting cap of a local receipt line: ordered - received - in containers. Neither the drafts
--                        (the one being posted is one) nor the pieces settled short count: pieces recorded short that
--                        turn up later can still be received.
--   OutstandingBase      rule 17, for Shortages and the item's "On order": an open order ordered - received - short, a
--                        closed one invoiced - received - short; 0 when cancelled. Never below 0.
-- ON A CLOSED ORDER (4) "ordered" is what was INVOICED in all three, as in OutstandingBase (rule 17): a closed order
-- takes no more invoices (65011), so a piece received beyond its invoices could never be invoiced and would keep the
-- order price for good. An order closed by itself is fully invoiced, so only an order closed by hand is capped.
-- The status of the order is the caller's to check (OrderStatus): this function never refuses.
CREATE OR ALTER FUNCTION purchase.fn_PoLine_Progress (@PurchaseOrderId INT)
RETURNS TABLE
AS
RETURN
    SELECT PurchaseOrderId     = d.Id,
           PoLineId            = l.Id,
           l.LineNumber, l.ItemId, l.ItemUnitId, l.PackingFormula, l.WarehouseId,
           OrderStatus         = d.Status,
           OrderedBase         = l.QuantityBase,
           InvoicedBase        = l.ReceivedQuantityBase,
           l.GoodsReceivedBase,
           l.GoodsShortBase,
           InContainersBase    = q.InContainers,
           InDraftReceiptsBase = q.InDrafts,
           ToReceiveBase       = CASE WHEN x.ToReceive > 0 THEN x.ToReceive ELSE 0 END,
           MaxOutsideBase      = CASE WHEN x.MaxOutside > 0 THEN x.MaxOutside ELSE 0 END,
           OutstandingBase     = CASE WHEN x.Outstanding > 0 THEN x.Outstanding ELSE 0 END
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt         ON dt.Id = d.DocumentTypeId AND dt.Code = N'PO'
    INNER JOIN purchase.PurchaseDocumentLines l   ON l.DocumentId = d.Id
    CROSS APPLY (SELECT InContainers = ISNULL((SELECT SUM(cl.QuantityBase)
                                               FROM logistics.ContainerLines cl
                                               INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                                               WHERE cl.PoLineId = l.Id AND c.Status BETWEEN 1 AND 5), 0),
                        InDrafts     = ISNULL((SELECT SUM(gl.QuantityBase)
                                               FROM purchase.GoodsReceiptLines gl
                                               INNER JOIN purchase.GoodsReceipts g ON g.Id = gl.GoodsReceiptId
                                               WHERE gl.PoLineId = l.Id AND gl.ContainerLineId IS NULL AND g.Status = 1), 0)) q
    CROSS APPLY (SELECT Expected = CASE WHEN d.Status = 4 AND l.ReceivedQuantityBase < l.QuantityBase
                                        THEN l.ReceivedQuantityBase ELSE l.QuantityBase END) e
    CROSS APPLY (SELECT ToReceive   = e.Expected - l.GoodsReceivedBase - l.GoodsShortBase - q.InContainers - q.InDrafts,
                        MaxOutside  = e.Expected - l.GoodsReceivedBase - q.InContainers,
                        Outstanding = CASE d.Status WHEN 3 THEN 0
                                                    WHEN 4 THEN l.ReceivedQuantityBase - l.GoodsReceivedBase - l.GoodsShortBase
                                                    ELSE l.QuantityBase - l.GoodsReceivedBase - l.GoodsShortBase END) x
    WHERE d.Id = @PurchaseOrderId;
GO

-- WHAT AN ORDER LINE HAS COMMITTED OUTSIDE CONTAINERS, in pieces - script 65 uses it in place of the "dir" subquery
-- (invoiced outside containers) wherever the pieces still loadable into containers are worked out:
--   Qty = MAX(invoiced outside containers, received outside containers + on draft receipts outside containers).
-- A maximum, not a sum: an invoiced piece and a received piece outside containers are the same goods (they are matched).
-- Except the pieces of an invoice that took its goods into stock WHEN IT WAS POSTED, before goods receipts
-- (UsesGoodsReceipts = 0, ReceiptMode 1): they are invoiced AND received, and never matched (usp_GoodsReceipt_Rematch
-- leaves those invoices out), so they count on both sides - otherwise goods received later by a goods receipt for the
-- rest of the same order line would hide behind them in the maximum and could be loaded into a container again.
-- Qty is then: those pieces + MAX(the other invoiced pieces, received by goods receipts + on draft receipts).
--   InvoicedOutsideBase         today's "dir": lines of invoices in status 1, 2 or 4 not shipped in containers
--                               (ReceiptMode <> 2) with no container line; @ExceptDocumentId (NULL = none) leaves out
--                               one invoice, as the callers that check that invoice's own lines do
--   ReceivedOutsideBase         posted goods receipt lines of the order line with no container line, plus the pieces of
--                               the invoices received when they were posted (above)
--   InDraftReceiptsOutsideBase  goods receipt lines of the order line with no container line on draft receipts
-- One row, always (0 when nothing).
CREATE OR ALTER FUNCTION purchase.fn_PoLine_CommittedOutside (@PoLineId INT, @ExceptDocumentId INT)
RETURNS TABLE
AS
RETURN
    SELECT Qty                        = CASE WHEN inv.Qty >= inv.AtPosting + rcv.Posted + rcv.Drafts THEN inv.Qty
                                             ELSE inv.AtPosting + rcv.Posted + rcv.Drafts END,
           InvoicedOutsideBase        = inv.Qty,
           ReceivedOutsideBase        = inv.AtPosting + rcv.Posted,
           InDraftReceiptsOutsideBase = rcv.Drafts
    FROM (SELECT Qty       = ISNULL(SUM(x.QuantityBase), 0),
                 AtPosting = ISNULL(SUM(CASE WHEN xd.Status IN (2, 4) AND xd.UsesGoodsReceipts = 0 AND xd.ReceiptMode = 1
                                             THEN x.QuantityBase END), 0)
          FROM purchase.PurchaseDocumentLines x
          INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
          WHERE x.SourceLineId = @PoLineId AND x.ContainerLineId IS NULL AND xd.Status IN (1, 2, 4) AND xd.ReceiptMode <> 2
            AND (@ExceptDocumentId IS NULL OR xd.Id <> @ExceptDocumentId)) inv
    CROSS JOIN (SELECT Posted = ISNULL(SUM(CASE WHEN g.Status = 2 THEN gl.QuantityBase END), 0),
                       Drafts = ISNULL(SUM(CASE WHEN g.Status = 1 THEN gl.QuantityBase END), 0)
                FROM purchase.GoodsReceiptLines gl
                INNER JOIN purchase.GoodsReceipts g ON g.Id = gl.GoodsReceiptId
                WHERE gl.PoLineId = @PoLineId AND gl.ContainerLineId IS NULL AND g.Status IN (1, 2)) rcv;
GO

/* ================================================================== 9. Invoice lines: still to receive */

-- One row per line of a purchase invoice NOT linked to a container (the linked ones are received with their
-- containers). ToReceiveBase = invoiced - received - on draft goods receipts that point to the line, never below 0;
-- received = ReceivedQuantityBase (the pieces matched to the line, for an invoice that uses goods receipts or is
-- shipped in containers). 0 when the invoice is not posted or closed, and for an invoice posted before goods receipts
-- without "Shipped in containers" (UsesGoodsReceipts = 0, ReceiptMode 1): its goods entered stock when it was posted.
CREATE OR ALTER FUNCTION purchase.fn_InvoiceLine_ToReceive (@InvoiceId INT)
RETURNS TABLE
AS
RETURN
    SELECT InvoiceId           = d.Id,
           InvoiceLineId       = l.Id,
           l.LineNumber, l.ItemId, l.ItemUnitId, l.PackingFormula, l.WarehouseId, l.ExpiryDate,
           PoLineId            = l.SourceLineId,
           d.SupplierId,
           InvoiceStatus       = d.Status,
           ReceivedAtPosting   = CAST(CASE WHEN d.UsesGoodsReceipts = 0 AND d.ReceiptMode = 1 THEN 1 ELSE 0 END AS BIT),
           InvoicedBase        = l.QuantityBase,
           ReceivedBase        = l.ReceivedQuantityBase,
           ReturnedBase        = l.ReturnedQuantityBase,
           InDraftReceiptsBase = q.InDrafts,
           ToReceiveBase       = CASE WHEN d.Status NOT IN (2, 4) OR (d.UsesGoodsReceipts = 0 AND d.ReceiptMode = 1) THEN 0
                                      WHEN l.QuantityBase - l.ReceivedQuantityBase - q.InDrafts > 0
                                      THEN l.QuantityBase - l.ReceivedQuantityBase - q.InDrafts
                                      ELSE 0 END
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt       ON dt.Id = d.DocumentTypeId AND dt.Code = N'PINV'
    INNER JOIN purchase.PurchaseDocumentLines l ON l.DocumentId = d.Id AND l.ContainerLineId IS NULL
    CROSS APPLY (SELECT InDrafts = ISNULL((SELECT SUM(gl.QuantityBase)
                                           FROM purchase.GoodsReceiptLines gl
                                           INNER JOIN purchase.GoodsReceipts g ON g.Id = gl.GoodsReceiptId
                                           WHERE gl.InvoiceLineId = l.Id AND g.Status = 1), 0)) q
    WHERE d.Id = @InvoiceId;
GO

/* ================================================================== 10. Receipt lines: matching groups, target cost, current cost */

-- THE POSTED RECEIPT LINES OF THE GROUPS: an order line ('P', every container line of it included) or a supplier +
-- item ('S', goods without an order). The callers true up these lines after a rematch (leaving out the receipt that
-- is being posted, whose own cost is set directly).
CREATE OR ALTER FUNCTION purchase.fn_GoodsReceipt_GroupLines (@Anchors purchase.tvp_GoodsReceiptAnchor READONLY)
RETURNS TABLE
AS
RETURN
    SELECT GoodsReceiptLineId = gl.Id, gl.GoodsReceiptId
    FROM purchase.GoodsReceiptLines gl
    INNER JOIN purchase.GoodsReceipts g ON g.Id = gl.GoodsReceiptId AND g.Status = 2
    WHERE EXISTS (SELECT 1 FROM @Anchors a
                  WHERE (a.Kind = 'P' AND a.PoLineId = gl.PoLineId)
                     OR (a.Kind = 'S' AND gl.PoLineId IS NULL AND a.SupplierId = gl.SupplierId AND a.ItemId = gl.ItemId));
GO

/* PER POSTED GOODS RECEIPT LINE WITH RECEIVED PIECES (R > 0), read-only (Post, TrueUpCost and the invoice preview):
     matched pieces    the invoice line's FOB per piece, plus its own charges per piece (AllocatedChargesBase /
                       QuantityBase, which an LCA raises) - in the FOB of a container line, see below
     unmatched pieces  BaseFob / BaseCharges: the ORDER PRICE (PoFobBase = order line total / order rate / pieces, no
                       charges) when the line has an order line; else a manual line's typed cost; else the cost it was
                       received at (an invoice without an order keeps its price when that invoice is cancelled)
     Target FOB        (matched FOB + unmatched x BaseFob) / R; a CONTAINER line also carries here the own charges of
                       the invoice lines matched to it: (matched FOB + matched charges + unmatched x BaseFob) / R
     Target charges    a CONTAINER line: the container line's posted charges / R (cl.ChargesBase - moved only by the
                       container charges, CNTCHARGE); other lines: (matched charges + unmatched x BaseCharges) / R
                       WHY a container line's invoice charges ride on its FOB: a local invoice (receipt mode 1, with its
                       own charges and LCAs) is matched to a container's pieces by pass 2 (same order line, first in
                       first out). The container line has no column for an invoice's charges - its landed cost is
                       cl.FobCostBase + cl.ChargesBase / received - and the true-up moves only its FOB, so the charges
                       are carried by that FOB, as a local line's move carries them; left out, they were lost. An
                       imported invoice (linked to the container) has no charges of its own (65020): nothing changes.
     Current*          the cost the line carries now: the container line's for container lines (cl.FobCostBase,
                       cl.LandedCostBase), the receipt line's own columns for the others
     NetReceivedBase   R less the pieces returned from its invoice lines, shared over each invoice line's matches
                       (the in-stock share of a true-up counts only goods that can still be here)
     CostSource        where the target comes from: Order | Invoice | Mixed | Manual */
CREATE OR ALTER FUNCTION purchase.fn_GoodsReceiptLine_TargetCost (@GoodsReceiptId INT)
RETURNS TABLE
AS
RETURN
    SELECT GoodsReceiptId      = g.Id,
           GoodsReceiptLineId  = gl.Id,
           gl.LineNumber, gl.ItemId, gl.WarehouseId, gl.SupplierId, gl.PoLineId, gl.InvoiceLineId, gl.ContainerLineId,
           ContainerId         = cl.ContainerId,
           IsContainerLine     = CAST(CASE WHEN gl.ContainerLineId IS NOT NULL THEN 1 ELSE 0 END AS BIT),
           ReceivedBase        = gl.QuantityBase,
           MatchedBase         = m.Qty,
           NetReceivedBase     = CAST(gl.QuantityBase - m.Returned AS DECIMAL(18,6)),
           BaseFobBase         = b.Fob,
           BaseChargesBase     = b.Charges,
           TargetFobBase       = t.Fob,
           TargetChargesBase   = t.Charges,
           TargetUnitCostBase  = CAST(t.Fob + t.Charges AS DECIMAL(18,6)),
           CurrentFobBase      = CASE WHEN gl.ContainerLineId IS NOT NULL THEN cl.FobCostBase ELSE gl.FobCostBase END,
           CurrentChargesBase  = CASE WHEN gl.ContainerLineId IS NOT NULL THEN CAST(cl.ChargesBase / gl.QuantityBase AS DECIMAL(18,6))
                                      ELSE gl.ChargesBase END,
           CurrentUnitCostBase = CASE WHEN gl.ContainerLineId IS NOT NULL THEN cl.LandedCostBase ELSE gl.UnitCostBase END,
           CostSource          = CAST(CASE WHEN m.Qty >= gl.QuantityBase THEN N'Invoice'
                                           WHEN gl.PoLineId IS NULL AND gl.InvoiceLineId IS NOT NULL THEN N'Invoice'
                                           WHEN m.Qty > 0 THEN N'Mixed'
                                           WHEN gl.PoLineId IS NOT NULL THEN N'Order'
                                           ELSE N'Manual' END AS NVARCHAR(10))
    FROM purchase.GoodsReceipts g
    INNER JOIN purchase.GoodsReceiptLines gl      ON gl.GoodsReceiptId = g.Id AND gl.QuantityBase > 0
    LEFT  JOIN logistics.ContainerLines cl        ON cl.Id = gl.ContainerLineId
    LEFT  JOIN purchase.PurchaseDocumentLines pol ON pol.Id = gl.PoLineId
    LEFT  JOIN purchase.PurchaseDocuments po      ON po.Id = pol.DocumentId
    LEFT  JOIN purchase.PurchaseDocumentLines il  ON il.Id = gl.InvoiceLineId
    CROSS APPLY (SELECT Qty      = ISNULL(SUM(x.QuantityBase), 0),
                        Fob      = ISNULL(SUM(x.QuantityBase * COALESCE(p.FobCostBase, p.LineTotal / pd.ExchangeRate / p.QuantityBase)), 0),
                        Charges  = ISNULL(SUM(x.QuantityBase * p.AllocatedChargesBase / p.QuantityBase), 0),
                        Returned = ISNULL(SUM(CAST(x.QuantityBase AS DECIMAL(18,6))
                                              * CASE WHEN p.ReturnedQuantityBase < p.ReceivedQuantityBase THEN p.ReturnedQuantityBase
                                                     ELSE p.ReceivedQuantityBase END
                                              / NULLIF(p.ReceivedQuantityBase, 0)), 0)
                 FROM purchase.GoodsReceiptInvoiceMatches x
                 INNER JOIN purchase.PurchaseDocumentLines p ON p.Id = x.InvoiceLineId
                 INNER JOIN purchase.PurchaseDocuments pd    ON pd.Id = p.DocumentId
                 WHERE x.GoodsReceiptLineId = gl.Id) m
    CROSS APPLY (SELECT Fob = CAST(CASE WHEN gl.PoLineId IS NOT NULL
                                        THEN COALESCE(gl.PoFobBase, pol.LineTotal / po.ExchangeRate / NULLIF(pol.QuantityBase, 0), 0)
                                        WHEN gl.InvoiceLineId IS NULL THEN ISNULL(gl.ManualUnitCostBase, 0)
                                        ELSE COALESCE(gl.CostAtReceiptBase, il.UnitCostBase, 0) END AS DECIMAL(18,6)),
                        Charges = CAST(0 AS DECIMAL(18,6))) b
    CROSS APPLY (SELECT Fob     = CAST((m.Fob + CASE WHEN gl.ContainerLineId IS NOT NULL THEN m.Charges ELSE 0 END
                                        + (gl.QuantityBase - m.Qty) * b.Fob) / gl.QuantityBase AS DECIMAL(18,6)),
                        Charges = CAST(CASE WHEN gl.ContainerLineId IS NOT NULL THEN ISNULL(cl.ChargesBase, 0) / gl.QuantityBase
                                            ELSE (m.Charges + (gl.QuantityBase - m.Qty) * b.Charges) / gl.QuantityBase END AS DECIMAL(18,6))) t
    WHERE g.Id = @GoodsReceiptId AND g.Status = 2;
GO

-- THE CURRENT COST OF EACH LINE, per piece in base currency, and its value (received x landed).
--   Posted: what the posting set and the cost adjustments moved since - the CONTAINER LINE's for a container line
--           (FobCostBase, ChargesBase / received, LandedCostBase: never copied, so a late charge counts once), the
--           receipt line's own for the others. Cancelled: the cost at receipt.
--   Draft:  an ESTIMATE of the cost at receipt (IsEstimate = 1): container lines at the posted invoices' price of the
--           container line, else the order price, plus the posted charges over the loaded pieces; invoice lines at
--           the posted invoice line's FOB and charges; order lines at the order price; manual lines at the typed cost.
--           The real cost is set when the receipt is posted (matching to the invoices).
-- OrderPriceBase = the order line total / the order's rate / its pieces (after the line discount), or PoFobBase once
-- frozen at posting.
CREATE OR ALTER FUNCTION purchase.fn_GoodsReceiptLine_Cost (@GoodsReceiptId INT)
RETURNS TABLE
AS
RETURN
    SELECT LineId         = l.Id,
           l.GoodsReceiptId,
           OrderPriceBase = CAST(op.Price AS DECIMAL(18,6)),
           FobBase        = CAST(y.Fob AS DECIMAL(18,6)),
           ChargesBase    = CAST(y.Charges AS DECIMAL(18,6)),
           UnitCostBase   = CAST(z.Unit AS DECIMAL(18,6)),
           IsEstimate     = CAST(CASE WHEN g.Status = 1 THEN 1 ELSE 0 END AS BIT),
           ValueBase      = CAST(ROUND(CAST(l.QuantityBase AS DECIMAL(18,6)) * ISNULL(z.Unit, 0), 2) AS DECIMAL(18,2))
    FROM purchase.GoodsReceiptLines l
    INNER JOIN purchase.GoodsReceipts g             ON g.Id = l.GoodsReceiptId
    LEFT  JOIN logistics.ContainerLines cl          ON cl.Id = l.ContainerLineId
    LEFT  JOIN purchase.PurchaseDocumentLines pol   ON pol.Id = l.PoLineId
    LEFT  JOIN purchase.PurchaseDocuments po        ON po.Id = pol.DocumentId
    LEFT  JOIN purchase.PurchaseDocumentLines pil   ON pil.Id = l.InvoiceLineId
    LEFT  JOIN purchase.PurchaseDocuments pid       ON pid.Id = pil.DocumentId AND pid.Status IN (2, 4)
    OUTER APPLY (SELECT Price = COALESCE(l.PoFobBase,
                                         pol.LineTotal / NULLIF(po.ExchangeRate, 0) / NULLIF(pol.QuantityBase, 0))) op
    OUTER APPLY (SELECT Fob = SUM(x.LineTotal / NULLIF(xd.ExchangeRate, 0)) / NULLIF(SUM(x.QuantityBase), 0)
                 FROM purchase.PurchaseDocumentLines x
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId AND xd.Status IN (2, 4)
                 WHERE l.ContainerLineId IS NOT NULL AND g.Status = 1 AND x.ContainerLineId = l.ContainerLineId) ci
    CROSS APPLY (SELECT Fob = CASE WHEN g.Status = 3 THEN NULL
                                   WHEN g.Status = 2 AND l.ContainerLineId IS NOT NULL THEN cl.FobCostBase
                                   WHEN g.Status = 2 THEN l.FobCostBase
                                   WHEN l.ContainerLineId IS NOT NULL THEN COALESCE(ci.Fob, op.Price)
                                   WHEN pid.Id IS NOT NULL AND pil.FobCostBase IS NOT NULL THEN pil.FobCostBase
                                   WHEN l.PoLineId IS NOT NULL THEN op.Price
                                   ELSE l.ManualUnitCostBase END,
                        Charges = CASE WHEN g.Status = 3 THEN NULL
                                       WHEN g.Status = 2 AND l.ContainerLineId IS NOT NULL
                                           THEN cl.ChargesBase / NULLIF(cl.ReceivedQuantityBase, 0)
                                       WHEN g.Status = 2 THEN l.ChargesBase
                                       WHEN l.ContainerLineId IS NOT NULL THEN cl.ChargesBase / NULLIF(cl.QuantityBase, 0)
                                       WHEN pid.Id IS NOT NULL AND pil.FobCostBase IS NOT NULL
                                           THEN ISNULL(pil.AllocatedChargesBase, 0) / NULLIF(pil.QuantityBase, 0)
                                       ELSE CAST(0 AS DECIMAL(18,6)) END) y
    CROSS APPLY (SELECT Unit = CASE WHEN g.Status = 3 THEN l.CostAtReceiptBase
                                    WHEN g.Status = 2 AND l.ContainerLineId IS NOT NULL THEN COALESCE(cl.LandedCostBase, l.CostAtReceiptBase)
                                    WHEN g.Status = 2 THEN COALESCE(l.UnitCostBase, l.CostAtReceiptBase)
                                    ELSE y.Fob + ISNULL(y.Charges, 0) END) z
    WHERE l.GoodsReceiptId = @GoodsReceiptId;
GO

/* ================================================================== 11. Why a goods receipt cannot be posted, cancelled or deleted */

/* THE REFUSALS OF usp_GoodsReceipt_Post, in the order it raises them: one row per failing rule (its first case),
   Seq, ErrorNumber, Message. Post raises the first one; usp_GoodsReceipt_Get shows it as PostBlockedReason (through
   fn_GoodsReceipt_Blocks), so the page and the refusal say the same sentence. (The RowVersion check belongs to the
   call, not to the receipt.)
   A container receipt books every line into the header's warehouse; another receipt books each line into its own
   warehouse, else the header's. */
CREATE OR ALTER FUNCTION purchase.fn_GoodsReceipt_PostCheck (@Id INT)
RETURNS TABLE
AS
RETURN
WITH h AS
(
    SELECT g.Id, g.Status, g.SourceKind, g.ContainerId, g.SupplierId, g.WarehouseId, g.DocumentDate,
           c.ContainerRef, CtStatus = c.Status, CtBranchId = c.BranchId
    FROM purchase.GoodsReceipts g
    LEFT JOIN logistics.Containers c ON c.Id = g.ContainerId
    WHERE g.Id = @Id
),
l AS
(
    SELECT gl.Id, gl.LineNumber, gl.ItemId, gl.QuantityBase, gl.ExpectedQuantityBase, gl.VarianceReasonCode, gl.VarianceReason,
           gl.CloseShort, gl.PoLineId, gl.PurchaseOrderId, gl.InvoiceLineId, gl.ContainerLineId,
           i.ItemCode, ItemActive = i.IsActive,
           WarehouseId = CASE WHEN h.SourceKind = N'Container' THEN h.WarehouseId ELSE COALESCE(gl.WarehouseId, h.WarehouseId) END,
           Tag = N'Line ' + CAST(gl.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N')'
    FROM h
    INNER JOIN purchase.GoodsReceiptLines gl ON gl.GoodsReceiptId = h.Id
    INNER JOIN inventory.Items i             ON i.Id = gl.ItemId
)
SELECT x.Seq, x.ErrorNumber, x.Message
FROM
(
    SELECT Seq = 1, ErrorNumber = 63006, Message = CAST(N'Goods receipt not found.' AS NVARCHAR(400))
    WHERE NOT EXISTS (SELECT 1 FROM h)

    UNION ALL
    SELECT 2, 63010, N'Only a draft goods receipt can be posted.' FROM h WHERE h.Status <> 1

    UNION ALL
    SELECT 3, 63009, N'The goods receipt has no lines.' FROM h WHERE NOT EXISTS (SELECT 1 FROM l)

    UNION ALL
    SELECT 4, 63000, N'Choose the warehouse the goods are received into.'
    FROM h WHERE h.SourceKind = N'Container' AND h.WarehouseId IS NULL

    UNION ALL
    SELECT * FROM (SELECT TOP (1) Seq = 5, ErrorNumber = 63000, Message = l.Tag + N': choose the warehouse the goods are received into.'
                   FROM l WHERE l.WarehouseId IS NULL AND l.ContainerLineId IS NULL ORDER BY l.LineNumber) a

    UNION ALL
    SELECT 6, 63000, N'The warehouse ' + w.WarehouseCode + N' is inactive or does not belong to the branch of container ' + h.ContainerRef + N'.'
    FROM h INNER JOIN masterdata.Warehouses w ON w.Id = h.WarehouseId
    WHERE h.SourceKind = N'Container' AND (w.IsActive = 0 OR w.BranchId <> h.CtBranchId)

    UNION ALL
    SELECT * FROM (SELECT TOP (1) Seq = 7, ErrorNumber = 63000, Message = l.Tag + N': the warehouse ' + w.WarehouseCode + N' is inactive.'
                   FROM l INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
                   WHERE l.ContainerLineId IS NULL AND w.IsActive = 0 ORDER BY l.LineNumber) a

    UNION ALL
    SELECT * FROM (SELECT TOP (1) Seq = 8, ErrorNumber = 63000,
                          Message = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item ' + l.ItemCode + N' is inactive. Activate it in Item Definition before receiving it.'
                   FROM l WHERE l.ItemActive = 0 ORDER BY l.LineNumber) a

    UNION ALL
    -- one day of tolerance: the date is the reader's local date, compared with a UTC one (usp_PurchaseDocument_ValidateInput)
    SELECT 9, 63000, N'The date received cannot be in the future.'
    FROM h WHERE h.DocumentDate > DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE))

    UNION ALL
    SELECT 10, 63010, N'Only a confirmed container that is not received yet can be received: ' + h.ContainerRef + N' is '
                      + CASE h.CtStatus WHEN 1 THEN N'a draft' WHEN 6 THEN N'already offloaded' WHEN 7 THEN N'closed'
                                        WHEN 8 THEN N'cancelled' ELSE N'not ready' END + N'.'
    FROM h WHERE h.SourceKind = N'Container' AND (h.CtStatus IS NULL OR h.CtStatus NOT BETWEEN 2 AND 5)

    UNION ALL
    SELECT * FROM (SELECT TOP (1) Seq = 11, ErrorNumber = 63010,
                          Message = N'Container ' + h.ContainerRef + N' is travelling with movement ' + m.MovementNo
                                    + N'. Complete it before receiving the goods.'
                   FROM h
                   INNER JOIN logistics.MovementContainers mc ON mc.ContainerId = h.ContainerId
                   INNER JOIN logistics.Movements m           ON m.Id = mc.MovementId AND m.Status = 2
                   WHERE h.SourceKind = N'Container'
                   ORDER BY m.MovementNo) a

    UNION ALL
    -- not before the end of the container's latest completed Delivery (the rule of usp_GoodsReceipt_Save)
    SELECT 12, 63000, N'The goods cannot be received before ' + d.MovementNo + N' reached ' + d.PlaceName
                      + N' on ' + CONVERT(NVARCHAR(10), d.EndDate, 23) + N'.'
    FROM h CROSS APPLY logistics.fn_Container_LastDelivery(h.ContainerId) d
    WHERE h.SourceKind = N'Container' AND h.DocumentDate < d.EndDate

    UNION ALL
    -- the receipt mirrors the container line by line: same lines, items, order lines and loaded pieces
    SELECT 13, 63000, N'The container''s lines changed after this goods receipt was created. Delete it and receive the container again.'
    FROM h
    WHERE h.SourceKind = N'Container'
      AND (EXISTS (SELECT 1 FROM l
                   LEFT JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId AND cl.ContainerId = h.ContainerId
                   WHERE cl.Id IS NULL OR cl.ItemId <> l.ItemId OR cl.PoLineId <> ISNULL(l.PoLineId, -1)
                      OR cl.QuantityBase <> ISNULL(l.ExpectedQuantityBase, -1))
           OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                      WHERE cl.ContainerId = h.ContainerId AND (SELECT COUNT(*) FROM l WHERE l.ContainerLineId = cl.Id) <> 1))

    UNION ALL
    -- a container's goods are received with the container's own receipt only (it updates the container and its costs)
    SELECT * FROM (SELECT TOP (1) Seq = 13, ErrorNumber = 63000,
                          Message = l.Tag + N': goods loaded in a container are received with the goods receipt of that container.'
                   FROM h INNER JOIN l ON l.ContainerLineId IS NOT NULL
                   WHERE h.SourceKind <> N'Container'
                   ORDER BY l.LineNumber) a

    UNION ALL
    SELECT * FROM (SELECT TOP (1) Seq = 14, ErrorNumber = 63000,
                          Message = l.Tag + N': received ' + CAST(l.QuantityBase AS NVARCHAR(20)) + N' but only '
                                    + CAST(l.ExpectedQuantityBase AS NVARCHAR(20)) + N' were loaded.'
                   FROM l WHERE l.ContainerLineId IS NOT NULL AND l.QuantityBase > l.ExpectedQuantityBase
                   ORDER BY l.LineNumber) a

    UNION ALL
    SELECT * FROM (SELECT TOP (1) Seq = 15, ErrorNumber = 63000,
                          Message = CASE WHEN l.ContainerLineId IS NOT NULL
                                         THEN l.Tag + N': choose a reason when the received quantity differs from the loaded quantity.'
                                         ELSE l.Tag + N': give the reason why nothing more will come.' END
                   FROM l
                   WHERE l.VarianceReasonCode IS NULL
                     AND ((l.ContainerLineId IS NOT NULL AND l.QuantityBase <> l.ExpectedQuantityBase)
                          OR (l.ContainerLineId IS NULL AND l.CloseShort = 1 AND NULLIF(LTRIM(RTRIM(l.VarianceReason)), N'') IS NULL))
                   ORDER BY l.LineNumber) a

    UNION ALL
    -- 0 PIECES on a local line only with "Nothing more will come" on a line of an order (usp_GoodsReceipt_Save's rule;
    -- the table only refuses a negative quantity)
    SELECT * FROM (SELECT TOP (1) Seq = 15, ErrorNumber = 63000,
                          Message = l.Tag + N': the received quantity must be more than 0.'
                   FROM l WHERE l.ContainerLineId IS NULL AND l.QuantityBase = 0 AND (l.CloseShort = 0 OR l.PoLineId IS NULL)
                   ORDER BY l.LineNumber) a

    UNION ALL
    -- a manual share of a posted charge cannot sit on a line that receives nothing (it could not enter any cost)
    SELECT * FROM (SELECT TOP (1) Seq = 16, ErrorNumber = 70013,
                          Message = N'The posted charge ' + t.ChargeName + N' has a manual share on line ' + CAST(cl.LineNumber AS NVARCHAR(10))
                                    + N' (' + i.ItemCode + N'), which receives nothing. Cancel that charge and enter it again on the received lines.'
                   FROM h
                   INNER JOIN logistics.ContainerCharges ch           ON ch.ContainerId = h.ContainerId AND ch.Status = 2 AND ch.IncludeInLandedCost = 1
                   INNER JOIN logistics.ContainerChargeAllocations a ON a.ChargeId = ch.Id AND a.IsManual = 1 AND a.AmountBase > 0
                   INNER JOIN purchase.ChargeTypes t                  ON t.Id = ch.ChargeTypeId
                   INNER JOIN logistics.ContainerLines cl             ON cl.Id = a.ContainerLineId
                   INNER JOIN inventory.Items i                       ON i.Id = cl.ItemId
                   LEFT  JOIN l                                       ON l.ContainerLineId = cl.Id
                   WHERE h.SourceKind = N'Container' AND ISNULL(l.QuantityBase, cl.QuantityBase) = 0
                   ORDER BY cl.LineNumber) a

    UNION ALL
    SELECT * FROM (SELECT TOP (1) Seq = 17, ErrorNumber = 63010,
                          Message = CASE WHEN po.Status = 3 THEN N'The purchase order ' + ISNULL(po.DocumentNumber, N'') + N' is cancelled.'
                                         ELSE N'Only an approved order can be received: the purchase order '
                                              + ISNULL(po.DocumentNumber, N'(draft)') + N' is not approved.' END
                   FROM (SELECT DISTINCT l.PurchaseOrderId FROM l WHERE l.PurchaseOrderId IS NOT NULL) x
                   INNER JOIN purchase.PurchaseDocuments po ON po.Id = x.PurchaseOrderId
                   WHERE po.Status NOT IN (2, 4)
                   ORDER BY po.Id) a

    UNION ALL
    SELECT * FROM (SELECT TOP (1) Seq = 18, ErrorNumber = 63010,
                          Message = CASE WHEN d.Status = 3 THEN N'The purchase invoice ' + ISNULL(d.DocumentNumber, N'') + N' is cancelled: receive the goods from the order, or delete this goods receipt.'
                                         WHEN d.Status NOT IN (2, 4) THEN N'Post the invoice first: goods are received against a posted invoice, or from the order.'
                                         WHEN d.UsesGoodsReceipts = 0 AND d.ReceiptMode = 1 THEN N'Posted before goods receipts: the stock of ' + ISNULL(d.DocumentNumber, N'') + N' entered when it was posted.'
                                         ELSE N'This invoice''s goods travel in containers: they are received with their containers.' END
                   FROM l
                   INNER JOIN purchase.PurchaseDocumentLines il ON il.Id = l.InvoiceLineId
                   INNER JOIN purchase.PurchaseDocuments d      ON d.Id = il.DocumentId
                   WHERE d.Status NOT IN (2, 4) OR (d.UsesGoodsReceipts = 0 AND d.ReceiptMode = 1) OR il.ContainerLineId IS NOT NULL
                   ORDER BY l.LineNumber) a

    UNION ALL
    -- ORDER CAP, lines received outside containers only: their own container never counts against a container line
    SELECT * FROM (SELECT TOP (1) Seq = 19, ErrorNumber = 63011,
                          Message = N'Line ' + CAST(q.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - ' + CAST(q.Rec AS NVARCHAR(20))
                                    + N' pcs received but only ' + CAST(p.MaxOutsideBase AS NVARCHAR(20))
                                    + N' remain to receive on the order line outside containers.'
                   FROM (SELECT l.PoLineId, l.PurchaseOrderId, Rec = SUM(l.QuantityBase), LineNumber = MIN(l.LineNumber)
                         FROM l WHERE l.PoLineId IS NOT NULL AND l.ContainerLineId IS NULL
                         GROUP BY l.PoLineId, l.PurchaseOrderId) q
                   CROSS APPLY purchase.fn_PoLine_Progress(q.PurchaseOrderId) p
                   INNER JOIN inventory.Items i ON i.Id = p.ItemId
                   WHERE p.PoLineId = q.PoLineId AND q.Rec > p.MaxOutsideBase
                   ORDER BY q.LineNumber) a

    UNION ALL
    SELECT * FROM (SELECT TOP (1) Seq = 20, ErrorNumber = 63011,
                          Message = N'Line ' + CAST(q.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - ' + CAST(q.Rec AS NVARCHAR(20))
                                    + N' pcs received but only '
                                    + CAST(CASE WHEN il.QuantityBase > il.ReceivedQuantityBase THEN il.QuantityBase - il.ReceivedQuantityBase ELSE 0 END AS NVARCHAR(20))
                                    + N' remain to receive on invoice ' + ISNULL(d.DocumentNumber, N'') + N'.'
                   FROM (SELECT l.InvoiceLineId, Rec = SUM(l.QuantityBase), LineNumber = MIN(l.LineNumber)
                         FROM l WHERE l.InvoiceLineId IS NOT NULL AND l.PoLineId IS NULL
                         GROUP BY l.InvoiceLineId) q
                   INNER JOIN purchase.PurchaseDocumentLines il ON il.Id = q.InvoiceLineId
                   INNER JOIN purchase.PurchaseDocuments d      ON d.Id = il.DocumentId
                   INNER JOIN inventory.Items i                 ON i.Id = il.ItemId
                   WHERE q.Rec > il.QuantityBase - il.ReceivedQuantityBase
                   ORDER BY q.LineNumber) a

    UNION ALL
    -- WITHOUT AN ORDER: refused while the supplier has the item to receive on an order (or on an invoice without an order)
    SELECT * FROM (SELECT TOP (1) Seq = 21, ErrorNumber = 63011,
                          Message = s.PartyCode + N' has ' + ISNULL(po.DocumentNumber, N'an order') + N' with ' + CAST(p.OutstandingBase AS NVARCHAR(20))
                                    + N' pcs of ' + l.ItemCode + N' still to receive: receive them from the order.'
                   FROM h
                   INNER JOIN masterdata.Parties s          ON s.Id = h.SupplierId
                   INNER JOIN l                             ON l.PoLineId IS NULL AND l.InvoiceLineId IS NULL
                   INNER JOIN purchase.PurchaseDocuments po ON po.SupplierId = h.SupplierId AND po.Status IN (2, 4)
                   INNER JOIN inventory.DocumentTypes dt    ON dt.Id = po.DocumentTypeId AND dt.Code = N'PO'
                   CROSS APPLY purchase.fn_PoLine_Progress(po.Id) p
                   WHERE p.ItemId = l.ItemId AND p.OutstandingBase > 0
                   ORDER BY l.LineNumber, po.Id) a

    UNION ALL
    SELECT * FROM (SELECT TOP (1) Seq = 22, ErrorNumber = 63011,
                          Message = s.PartyCode + N' has ' + ISNULL(d.DocumentNumber, N'an invoice') + N' with '
                                    + CAST(il.QuantityBase - il.ReceivedQuantityBase AS NVARCHAR(20))
                                    + N' pcs of ' + l.ItemCode + N' still to receive: receive them from the invoice.'
                   FROM h
                   INNER JOIN masterdata.Parties s              ON s.Id = h.SupplierId
                   INNER JOIN l                                 ON l.PoLineId IS NULL AND l.InvoiceLineId IS NULL
                   INNER JOIN purchase.PurchaseDocuments d      ON d.SupplierId = h.SupplierId AND d.Status IN (2, 4)
                                                               AND NOT (d.UsesGoodsReceipts = 0 AND d.ReceiptMode = 1)
                   INNER JOIN inventory.DocumentTypes dt        ON dt.Id = d.DocumentTypeId AND dt.Code = N'PINV'
                   INNER JOIN purchase.PurchaseDocumentLines il ON il.DocumentId = d.Id AND il.SourceLineId IS NULL AND il.ItemId = l.ItemId
                   WHERE il.QuantityBase > il.ReceivedQuantityBase
                   ORDER BY l.LineNumber, d.Id) a

    UNION ALL
    SELECT 23, 63010, N'The document type GRN is inactive: activate it in Configuration ' + NCHAR(8250) + N' Document Types.'
    WHERE NOT EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Code = N'GRN' AND IsActive = 1)
) x;
GO

/* THE REFUSALS OF usp_GoodsReceipt_Cancel that can be told before it runs (Get shows the first as
   CancelBlockedReason). The reason, the RowVersion and the purchase returns (63010, known only once the matches are
   rebuilt without this receipt) are checked by the procedure itself.
     63008  its cost was adjusted afterwards: a GRNCOST change of its lines other than the NEGSTOCK of its own posting,
            or, for a container, a late charge (CNTCHARGE) - as 69018 for the offload
     63007  per item and warehouse: the stock on hand is less than what it brought */
CREATE OR ALTER FUNCTION purchase.fn_GoodsReceipt_CancelCheck (@Id INT)
RETURNS TABLE
AS
RETURN
WITH h AS
(
    SELECT g.Id, g.Status, g.ContainerId, c.ContainerRef, CtStatus = c.Status
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
                          Message = N'Cannot cancel: ' + i.ItemCode + N' in ' + w.WarehouseCode + N' has only '
                                    + CAST(oh.Q AS NVARCHAR(20)) + N' left, but this goods receipt brought ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
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

-- WHY A RECEIPT CANNOT BE POSTED, CANCELLED, DELETED OR EDITED NOW, for the receipt page (usp_GoodsReceipt_Get:
-- PostBlockedReason, CancelBlockedReason, DeleteBlockedReason, EditBlockedReason): one row per failed rule, Action
-- 'Post' | 'Cancel' | 'Delete' | 'Edit', in the order of the checks (Seq); the first row of an action is its reason,
-- none = allowed. The Post and Cancel rows ARE the refusals of usp_GoodsReceipt_Post / _Cancel
-- (fn_GoodsReceipt_PostCheck / _CancelCheck, written once), so the page and the refusal always say the same thing.
-- One more Cancel row is only an ESTIMATE (Seq 50, after the binding ones): a purchase return that took back goods of
-- this receipt. Cancel decides it after rebuilding the matches, inside its transaction, and never reads this row.
CREATE OR ALTER FUNCTION purchase.fn_GoodsReceipt_Blocks (@Id INT)
RETURNS TABLE
AS
RETURN
    WITH g AS
    (
        SELECT gr.Id, gr.Status FROM purchase.GoodsReceipts gr WHERE gr.Id = @Id
    )
    /* ---------- Post: the refusals of usp_GoodsReceipt_Post ---------- */
    SELECT Action = CAST(N'Post' AS NVARCHAR(10)), p.Seq, p.ErrorNumber, Message = CAST(p.Message AS NVARCHAR(400))
    FROM purchase.fn_GoodsReceipt_PostCheck(@Id) p
    /* ---------- Cancel: the refusals of usp_GoodsReceipt_Cancel ---------- */
    UNION ALL
    SELECT N'Cancel', c.Seq, c.ErrorNumber, CAST(c.Message AS NVARCHAR(400))
    FROM purchase.fn_GoodsReceipt_CancelCheck(@Id) c
    UNION ALL
    -- ESTIMATE of Cancel's purchase-return rule: an invoice line matched to this receipt keeps what the other posted
    -- receipts of its group still hold unmatched; returned pieces beyond that would be left without a receipt
    SELECT x.Action, x.Seq, x.ErrorNumber, x.Message
    FROM (SELECT TOP (1) Action = N'Cancel', Seq = 50, ErrorNumber = 63010,
                 Message = CAST(ISNULL(N'Purchase return ' + rt.DocumentNumber, N'A purchase return')
                                + N' took back goods of this receipt. Cancel the return first.' AS NVARCHAR(400))
          FROM g
          CROSS APPLY (SELECT m.InvoiceLineId, Mine = SUM(m.QuantityBase)
                       FROM purchase.GoodsReceiptInvoiceMatches m
                       INNER JOIN purchase.GoodsReceiptLines l ON l.Id = m.GoodsReceiptLineId
                       WHERE l.GoodsReceiptId = g.Id
                       GROUP BY m.InvoiceLineId) z
          INNER JOIN purchase.PurchaseDocumentLines pil ON pil.Id = z.InvoiceLineId
          INNER JOIN purchase.PurchaseDocuments pid     ON pid.Id = pil.DocumentId
          CROSS APPLY (SELECT Spare = ISNULL(SUM(ol.QuantityBase - ol.InvoicedBase), 0)
                       FROM purchase.GoodsReceiptLines ol
                       INNER JOIN purchase.GoodsReceipts og ON og.Id = ol.GoodsReceiptId AND og.Status = 2 AND og.Id <> g.Id
                       WHERE (pil.SourceLineId IS NOT NULL AND ol.PoLineId = pil.SourceLineId)
                          OR (pil.SourceLineId IS NULL AND ol.PoLineId IS NULL AND ol.SupplierId = pid.SupplierId AND ol.ItemId = pil.ItemId)) sp
          OUTER APPLY (SELECT TOP (1) rd.DocumentNumber
                       FROM purchase.PurchaseDocumentLines rl
                       INNER JOIN purchase.PurchaseDocuments rd ON rd.Id = rl.DocumentId AND rd.Status IN (2, 4)
                       WHERE rl.SourceLineId = pil.Id
                       ORDER BY rd.PostedAtUtc DESC, rd.Id DESC) rt
          WHERE g.Status = 2 AND pil.ReturnedQuantityBase > 0 AND pil.ReturnedQuantityBase > pil.ReceivedQuantityBase - z.Mine + sp.Spare
          ORDER BY pil.Id) x
    /* ---------- Delete, Edit: a draft only ---------- */
    UNION ALL
    SELECT N'Delete', 10, 63005, N'Only a draft goods receipt can be changed or deleted.'
    FROM g WHERE g.Status <> 1
    UNION ALL
    SELECT N'Edit', 10, 63005, N'Only a draft goods receipt can be changed or deleted.'
    FROM g WHERE g.Status <> 1;
GO

/* ================================================================== 12. Save: a draft, created or updated */

/* A DRAFT GOODS RECEIPT, created (@Id NULL) or updated (@Id + @RowVersion), from @Lines (purchase.tvp_GoodsReceiptLine,
   Quantity in the line's unit). Nothing moves in stock or cost: Post does that. Updating replaces the lines.

   The source is chosen when the draft is created and never changes (63000):
     Container  @ContainerId (+ @MovementId when made by the completion of that Delivery movement: IsAuto). The lines
                are the container's lines, each once and all of them, in pieces (the base unit), 0 to the loaded
                pieces, with a reason code when they differ; the warehouse is the header's ("Receive into"), which
                may stay empty on a draft but must be of the container's branch; branch = the container's.
     Order      every line names an order line (PoLineId) of posted or closed orders of ONE supplier; branch and
                supplier = the order's; PurchaseOrderId = the order when the lines are of one order.
     Invoice    @PurchaseInvoiceId, a posted or closed supplier invoice (not one posted before goods receipts without
                "Shipped in containers"); every line names one of its lines NOT linked to a container; PoLineId = that
                line's order line; branch and supplier = the invoice's.
     Manual     "Without an order": a supplier is required; the lines have no order, invoice or container line and a
                cost per piece (ManualUnitCostBase, default the item's last cost, else its average cost). Branch =
                @BranchId, else the warehouse's.
   The source is taken from the ids when @SourceKind is NULL. Local lines (not container) receive more than 0 - or 0
   with "Nothing more will come" on a line of an order, to settle the rest of that order line when nothing more
   arrives (refused when nothing is left to settle) - into an active warehouse (the line's, else the header's, else the
   order or invoice line's); "Nothing more will come" (CloseShort) only on a line of an order, with a reason (code or
   note). An order line or an invoice line appears once.
   Caps (as Post's, 63011): local lines of an order line no more than its MaxOutsideBase, lines of an invoice without
   an order no more than invoiced - received. ExpectedQuantityBase is set here, never taken from the caller: container
   = loaded; order line = its ToReceiveBase now, invoice line = its ToReceiveBase now (this receipt left out); manual
   = NULL. The date received is not in the future (one day of tolerance) and, for a container, not before its latest
   completed Delivery. Returns nothing: @NewId. */
CREATE OR ALTER PROCEDURE purchase.usp_GoodsReceipt_Save
    @Id                INT            = NULL,
    @SourceKind        NVARCHAR(10)   = NULL,    -- new receipt: Container | Order | Invoice | Manual; NULL = from the ids
    @DocumentDate      DATE           = NULL,    -- date received; NULL = today (UTC)
    @BranchId          INT            = NULL,    -- Manual (else the warehouse's); several orders; ignored otherwise
    @WarehouseId       INT            = NULL,    -- "Receive into": a container's lines, the default of local lines
    @SupplierId        INT            = NULL,    -- Manual: required; otherwise checked against the source
    @ContainerId       INT            = NULL,
    @PurchaseOrderId   INT            = NULL,    -- informative: taken from the lines
    @PurchaseInvoiceId INT            = NULL,
    @SupplierReference NVARCHAR(100)  = NULL,    -- delivery note no.
    @Notes             NVARCHAR(1000) = NULL,
    @Lines             purchase.tvp_GoodsReceiptLine READONLY,
    @RowVersion        BINARY(8)      = NULL,
    @UserId            INT            = NULL,
    @NewId             INT            = NULL OUTPUT,
    @MovementId        INT            = NULL     -- new container receipt: the completed Delivery movement that made it
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @SourceKind = NULLIF(LTRIM(RTRIM(@SourceKind)), N'');
    SET @SupplierReference = NULLIF(LTRIM(RTRIM(@SupplierReference)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    IF @DocumentDate IS NULL SET @DocumentDate = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @Msg NVARCHAR(400), @TypeId INT, @IsAuto BIT = 0,
            @OldStatus TINYINT, @OldSource NVARCHAR(10), @OldContainer INT, @OldInvoice INT, @OldMovement INT, @OldBranch INT,
            @Ref NVARCHAR(30), @CtStatus TINYINT, @CtBranch INT, @MovNo NVARCHAR(30),
            @InvNo NVARCHAR(30), @InvStatus TINYINT, @InvBranch INT, @InvSupplier INT, @InvOld BIT, @SourceText NVARCHAR(300);

    /* ---------- 1. The receipt and its source */
    IF @Id IS NOT NULL
    BEGIN
        SELECT @OldStatus = Status, @OldSource = SourceKind, @OldContainer = ContainerId, @OldInvoice = PurchaseInvoiceId,
               @OldMovement = MovementId, @OldBranch = BranchId, @IsAuto = IsAuto
        FROM purchase.GoodsReceipts WHERE Id = @Id;
        IF @OldStatus IS NULL THROW 63006, 'Goods receipt not found.', 1;
        IF @OldStatus <> 1 THROW 63005, 'Only a draft goods receipt can be changed or deleted.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.GoodsReceipts WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 63004, 'This goods receipt was modified by another user. Reload the page and try again.', 1;
        IF (@SourceKind IS NOT NULL AND @SourceKind <> @OldSource)
           OR (@ContainerId IS NOT NULL AND @ContainerId <> ISNULL(@OldContainer, -1))
           OR (@PurchaseInvoiceId IS NOT NULL AND @PurchaseInvoiceId <> ISNULL(@OldInvoice, -1))
           OR (@MovementId IS NOT NULL AND @MovementId <> ISNULL(@OldMovement, -1))
            THROW 63000, 'The source of a goods receipt cannot be changed: delete the draft and create another one.', 1;
        SELECT @SourceKind = @OldSource, @ContainerId = @OldContainer, @PurchaseInvoiceId = @OldInvoice, @MovementId = @OldMovement;
    END
    ELSE
    BEGIN
        SET @SourceKind = COALESCE(@SourceKind,
                                   CASE WHEN @ContainerId IS NOT NULL THEN N'Container'
                                        WHEN @PurchaseInvoiceId IS NOT NULL THEN N'Invoice'
                                        WHEN @PurchaseOrderId IS NOT NULL OR EXISTS (SELECT 1 FROM @Lines WHERE PoLineId IS NOT NULL) THEN N'Order'
                                        ELSE N'Manual' END);
        IF @SourceKind NOT IN (N'Container', N'Order', N'Invoice', N'Manual')
            THROW 63000, 'The source of a goods receipt is a container, an order, an invoice, or none (Manual).', 1;
        IF @SourceKind = N'Container' AND @ContainerId IS NULL THROW 63000, 'Choose the container.', 1;
        IF @SourceKind = N'Invoice' AND @PurchaseInvoiceId IS NULL THROW 63000, 'Choose the purchase invoice.', 1;
        IF (@SourceKind <> N'Container' AND (@ContainerId IS NOT NULL OR @MovementId IS NOT NULL))
           OR (@SourceKind <> N'Invoice' AND @PurchaseInvoiceId IS NOT NULL)
           OR (@SourceKind = N'Manual' AND @PurchaseOrderId IS NOT NULL)
            THROW 63000, 'A goods receipt has one source: a container, an order, an invoice, or none (Manual).', 1;
        SET @IsAuto = CASE WHEN @MovementId IS NOT NULL THEN 1 ELSE 0 END;
    END

    IF @DocumentDate > DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE))
        THROW 63000, 'The date received cannot be in the future.', 1;
    IF NOT EXISTS (SELECT 1 FROM @Lines) THROW 63009, 'The goods receipt has no lines.', 1;
    SET @TypeId = (SELECT Id FROM inventory.DocumentTypes WHERE Code = N'GRN');   -- an inactive type still takes drafts
    IF @TypeId IS NULL THROW 63010, 'The document type GRN is missing: restart the API so that script 64 creates it.', 1;

    /* ---------- 2. The lines, as given */
    DECLARE @L TABLE
    (
        LineNumber           INT           NOT NULL PRIMARY KEY,
        ItemId               INT           NOT NULL,
        ItemUnitId           INT           NOT NULL,
        Quantity             INT           NOT NULL,
        PackingFormula       INT           NULL,      -- NULL: the unit is not one of the item's
        IsBaseUnit           BIT           NULL,
        QuantityBase         INT           NULL,
        WarehouseId          INT           NULL,
        PoLineId             INT           NULL,
        PurchaseOrderId      INT           NULL,
        InvoiceLineId        INT           NULL,
        ContainerLineId      INT           NULL,
        ExpectedQuantityBase INT           NULL,
        VarianceReasonCode   NVARCHAR(20)  NULL,
        VarianceReason       NVARCHAR(300) NULL,
        CloseShort           BIT           NOT NULL,
        ManualUnitCostBase   DECIMAL(18,6) NULL,
        ExpiryDate           DATE          NULL,
        Notes                NVARCHAR(300) NULL,
        SupplierId           INT           NULL
    );
    INSERT INTO @L (LineNumber, ItemId, ItemUnitId, Quantity, PackingFormula, IsBaseUnit, QuantityBase, WarehouseId, PoLineId,
                    InvoiceLineId, ContainerLineId, ExpectedQuantityBase, VarianceReasonCode, VarianceReason, CloseShort,
                    ManualUnitCostBase, ExpiryDate, Notes)
    SELECT l.LineNumber, l.ItemId, l.ItemUnitId, l.Quantity, iu.PackingFormula, iu.IsBaseUnit,
           CASE WHEN iu.Id IS NOT NULL THEN l.Quantity * iu.PackingFormula END,
           l.WarehouseId, l.PoLineId, l.InvoiceLineId, l.ContainerLineId, l.ExpectedQuantityBase,
           NULLIF(UPPER(LTRIM(RTRIM(l.VarianceReasonCode))), N''), NULLIF(LTRIM(RTRIM(l.VarianceReason)), N''),
           ISNULL(l.CloseShort, 0), l.ManualUnitCostBase, l.ExpiryDate, NULLIF(LTRIM(RTRIM(l.Notes)), N'')
    FROM @Lines l
    LEFT JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId AND iu.ItemId = l.ItemId;

    SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' +
        CASE WHEN i.Id IS NULL THEN N'item not found.'
             WHEN l.PackingFormula IS NULL THEN N'the unit does not belong to item ' + i.ItemCode + N'.'
             WHEN l.Quantity < 0 THEN N'the received quantity cannot be negative.'
             WHEN l.VarianceReasonCode NOT IN (N'SHORT', N'DAMAGED', N'MISSING', N'LOADCOUNT', N'OTHER')
                 THEN N'the reason is Short-shipped (SHORT), Damaged (DAMAGED), Missing (MISSING), Wrongly counted at loading (LOADCOUNT) or Other (OTHER).'
             WHEN l.ManualUnitCostBase < 0 THEN N'the unit cost cannot be negative.'
             WHEN l.ContainerLineId IS NOT NULL AND @SourceKind <> N'Container' THEN N'only the goods receipt of a container has container lines.'
             WHEN l.InvoiceLineId IS NOT NULL AND @SourceKind <> N'Invoice' THEN N'only the goods receipt of an invoice has invoice lines.'
             ELSE N'a goods receipt without an order has no order lines.' END
    FROM @L l
    LEFT JOIN inventory.Items i ON i.Id = l.ItemId
    WHERE i.Id IS NULL OR l.PackingFormula IS NULL OR l.Quantity < 0
       OR (l.VarianceReasonCode IS NOT NULL AND l.VarianceReasonCode NOT IN (N'SHORT', N'DAMAGED', N'MISSING', N'LOADCOUNT', N'OTHER'))
       OR l.ManualUnitCostBase < 0
       OR (l.ContainerLineId IS NOT NULL AND @SourceKind <> N'Container')
       OR (l.InvoiceLineId IS NOT NULL AND @SourceKind <> N'Invoice')
       OR (l.PoLineId IS NOT NULL AND @SourceKind = N'Manual')
    ORDER BY l.LineNumber;
    IF @Msg IS NOT NULL THROW 63000, @Msg, 1;

    /* ---------- 3. By source */
    IF @SourceKind = N'Container'
    BEGIN
        SELECT @Ref = ContainerRef, @CtStatus = Status, @CtBranch = BranchId FROM logistics.Containers WHERE Id = @ContainerId;
        IF @Ref IS NULL THROW 63006, 'Container not found.', 1;
        IF @Id IS NULL AND @CtStatus NOT BETWEEN 2 AND 5
            THROW 63010, 'Only a confirmed container that is not received yet can be received.', 1;
        IF @Id IS NULL AND @MovementId IS NOT NULL
        BEGIN
            SELECT @MovNo = m.MovementNo FROM logistics.Movements m WHERE m.Id = @MovementId;
            IF NOT EXISTS (SELECT 1 FROM logistics.Movements m
                           INNER JOIN masterdata.MovementTypes mt     ON mt.Id = m.MovementTypeId AND mt.Stage = N'Delivery'
                           INNER JOIN logistics.MovementContainers mc ON mc.MovementId = m.Id AND mc.ContainerId = @ContainerId
                           WHERE m.Id = @MovementId AND m.Status = 3)
            BEGIN
                SET @Msg = N'Movement ' + ISNULL(@MovNo, N'#' + CAST(@MovementId AS NVARCHAR(10)))
                         + N' is not a completed Delivery movement of container ' + @Ref + N'.';
                THROW 63010, @Msg, 1;
            END
        END
        IF @MovementId IS NOT NULL AND @MovNo IS NULL SET @MovNo = (SELECT MovementNo FROM logistics.Movements WHERE Id = @MovementId);
        SET @BranchId = @CtBranch;
        IF @WarehouseId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1 AND BranchId = @CtBranch)
        BEGIN
            SET @Msg = N'The warehouse ' + ISNULL((SELECT WarehouseCode FROM masterdata.Warehouses WHERE Id = @WarehouseId), N'#' + CAST(@WarehouseId AS NVARCHAR(10)))
                     + N' is inactive or does not belong to the branch of container ' + @Ref + N'.';
            THROW 63000, @Msg, 1;
        END
        SELECT @Msg = N'The goods cannot be received before ' + d.MovementNo + N' reached ' + d.PlaceName + N' on '
                      + CONVERT(NVARCHAR(10), d.EndDate, 23) + N'.'
        FROM logistics.fn_Container_LastDelivery(@ContainerId) d
        WHERE @DocumentDate < d.EndDate;
        IF @Msg IS NOT NULL THROW 63000, @Msg, 1;

        -- the lines are the container's lines, each once, in pieces, never above the loaded pieces
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): ' +
            CASE WHEN cl.Id IS NULL THEN N'it is not a line of container ' + @Ref + N'.'
                 WHEN (SELECT COUNT(*) FROM @L d WHERE d.ContainerLineId = l.ContainerLineId) > 1
                     THEN N'line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N' of container ' + @Ref + N' is on this goods receipt twice.'
                 WHEN cl.ItemId <> l.ItemId THEN N'the item differs from the container line.'
                 WHEN l.IsBaseUnit = 0 THEN N'a container line is received in pieces (the base unit).'
                 ELSE N'received ' + CAST(l.QuantityBase AS NVARCHAR(20)) + N' but only ' + CAST(cl.QuantityBase AS NVARCHAR(20)) + N' were loaded.' END
        FROM @L l
        INNER JOIN inventory.Items i           ON i.Id = l.ItemId
        LEFT  JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId AND cl.ContainerId = @ContainerId
        WHERE cl.Id IS NULL OR cl.ItemId <> l.ItemId OR l.IsBaseUnit = 0 OR l.QuantityBase > cl.QuantityBase
           OR (SELECT COUNT(*) FROM @L d WHERE d.ContainerLineId = l.ContainerLineId) > 1
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 63000, @Msg, 1;

        SELECT TOP (1) @Msg = N'Line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N' of container ' + @Ref + N' (' + i.ItemCode
                              + N') is missing: a container is received with all its lines.'
        FROM logistics.ContainerLines cl
        INNER JOIN inventory.Items i ON i.Id = cl.ItemId
        WHERE cl.ContainerId = @ContainerId AND NOT EXISTS (SELECT 1 FROM @L l WHERE l.ContainerLineId = cl.Id)
        ORDER BY cl.LineNumber;
        IF @Msg IS NOT NULL THROW 63000, @Msg, 1;

        -- THE ITEM IS ACTIVE (rule 12), as on the lines of the other sources (section 4), with their sentence: a draft
        -- that Post would refuse is not made. (CreateForContainer, silent for a Delivery, skips such a container.)
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): item ' + i.ItemCode + N' is inactive.'
        FROM @L l
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        WHERE i.IsActive = 0
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 63000, @Msg, 1;

        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode
                              + N'): choose a reason when the received quantity differs from the loaded quantity.'
        FROM @L l
        INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
        INNER JOIN inventory.Items i           ON i.Id = l.ItemId
        WHERE l.QuantityBase <> cl.QuantityBase AND l.VarianceReasonCode IS NULL
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 63000, @Msg, 1;

        -- the links come from the container line: its order line, order and supplier; expected = loaded; one warehouse
        UPDATE l
        SET PoLineId = cl.PoLineId, PurchaseOrderId = cl.PurchaseOrderId, SupplierId = po.SupplierId,
            ExpectedQuantityBase = cl.QuantityBase, WarehouseId = @WarehouseId, CloseShort = 0, ManualUnitCostBase = NULL,
            ExpiryDate = COALESCE(l.ExpiryDate, pol.ExpiryDate)
        FROM @L l
        INNER JOIN logistics.ContainerLines cl        ON cl.Id = l.ContainerLineId
        INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = cl.PoLineId
        INNER JOIN purchase.PurchaseDocuments po      ON po.Id = cl.PurchaseOrderId;

        SET @SupplierId = CASE WHEN (SELECT COUNT(DISTINCT SupplierId) FROM @L) = 1 THEN (SELECT MIN(SupplierId) FROM @L) END;
        SET @PurchaseOrderId = CASE WHEN (SELECT COUNT(DISTINCT PurchaseOrderId) FROM @L) = 1 THEN (SELECT MIN(PurchaseOrderId) FROM @L) END;
        SET @SourceText = N'Draft from container ' + @Ref
                        + ISNULL(N', created automatically when ' + @MovNo + N' was completed', N'');
    END
    ELSE IF @SourceKind = N'Order'
    BEGIN
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' +
            CASE WHEN l.PoLineId IS NULL THEN N'choose a line of a purchase order.'
                 WHEN pol.Id IS NULL OR dt.Id IS NULL THEN N'the order line was not found.'
                 WHEN (SELECT COUNT(*) FROM @L d WHERE d.PoLineId = l.PoLineId) > 1
                     THEN N'line ' + CAST(pol.LineNumber AS NVARCHAR(10)) + N' of order ' + ISNULL(po.DocumentNumber, N'#' + CAST(po.Id AS NVARCHAR(10)))
                          + N' is on this goods receipt twice.'
                 ELSE N'the item differs from the order line.' END
        FROM @L l
        LEFT JOIN purchase.PurchaseDocumentLines pol ON pol.Id = l.PoLineId
        LEFT JOIN purchase.PurchaseDocuments po      ON po.Id = pol.DocumentId
        LEFT JOIN inventory.DocumentTypes dt         ON dt.Id = po.DocumentTypeId AND dt.Code = N'PO'
        WHERE l.PoLineId IS NULL OR pol.Id IS NULL OR dt.Id IS NULL OR pol.ItemId <> l.ItemId
           OR (SELECT COUNT(*) FROM @L d WHERE d.PoLineId = l.PoLineId) > 1
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 63000, @Msg, 1;

        SELECT TOP (1) @Msg = CASE WHEN po.Status = 3 THEN N'The purchase order ' + ISNULL(po.DocumentNumber, N'#' + CAST(po.Id AS NVARCHAR(10))) + N' is cancelled.'
                                   ELSE N'Only an approved order can be received.' END
        FROM @L l
        INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = l.PoLineId
        INNER JOIN purchase.PurchaseDocuments po      ON po.Id = pol.DocumentId
        WHERE po.Status NOT IN (2, 4)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 63010, @Msg, 1;

        UPDATE l
        SET PurchaseOrderId = pol.DocumentId, SupplierId = po.SupplierId, ManualUnitCostBase = NULL,
            WarehouseId = COALESCE(l.WarehouseId, @WarehouseId, pol.WarehouseId),
            ExpiryDate = COALESCE(l.ExpiryDate, pol.ExpiryDate)
        FROM @L l
        INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = l.PoLineId
        INNER JOIN purchase.PurchaseDocuments po      ON po.Id = pol.DocumentId;

        IF (SELECT COUNT(DISTINCT SupplierId) FROM @L) > 1
            THROW 63000, 'A goods receipt from purchase orders holds the orders of one supplier.', 1;
        IF @SupplierId IS NOT NULL AND @SupplierId <> (SELECT MIN(SupplierId) FROM @L)
            THROW 63000, 'The supplier must be the supplier of the purchase order.', 1;
        SET @SupplierId = (SELECT MIN(SupplierId) FROM @L);
        SET @PurchaseOrderId = CASE WHEN (SELECT COUNT(DISTINCT PurchaseOrderId) FROM @L) = 1 THEN (SELECT MIN(PurchaseOrderId) FROM @L) END;
        -- numbered in the order's branch; a receipt of several orders keeps the branch given (or the first line's order's)
        SET @BranchId = CASE WHEN @PurchaseOrderId IS NOT NULL THEN (SELECT BranchId FROM purchase.PurchaseDocuments WHERE Id = @PurchaseOrderId)
                             ELSE COALESCE(@BranchId, @OldBranch,
                                           (SELECT TOP (1) po.BranchId FROM @L l INNER JOIN purchase.PurchaseDocuments po ON po.Id = l.PurchaseOrderId
                                            ORDER BY l.LineNumber)) END;
        SET @SourceText = N'Draft from order ' + ISNULL((SELECT DocumentNumber FROM purchase.PurchaseDocuments WHERE Id = @PurchaseOrderId), N'(several orders)');
    END
    ELSE IF @SourceKind = N'Invoice'
    BEGIN
        SELECT @InvNo = d.DocumentNumber, @InvStatus = d.Status, @InvBranch = d.BranchId, @InvSupplier = d.SupplierId,
               @InvOld = CASE WHEN d.UsesGoodsReceipts = 0 AND d.ReceiptMode = 1 THEN 1 ELSE 0 END
        FROM purchase.PurchaseDocuments d
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId AND dt.Code = N'PINV'
        WHERE d.Id = @PurchaseInvoiceId;
        IF @InvStatus IS NULL THROW 63006, 'Purchase invoice not found.', 1;
        IF @InvStatus = 3 THROW 63010, 'The purchase invoice is cancelled.', 1;
        IF @InvStatus NOT IN (2, 4) THROW 63010, 'Post the invoice first: goods are received against a posted invoice, or from the order.', 1;
        IF @InvOld = 1 THROW 63010, 'Posted before goods receipts: its stock entered when it was posted (or when its container was offloaded).', 1;

        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' +
            CASE WHEN pil.Id IS NULL THEN N'choose a line of invoice ' + ISNULL(@InvNo, N'#' + CAST(@PurchaseInvoiceId AS NVARCHAR(10))) + N'.'
                 WHEN pil.ContainerLineId IS NOT NULL
                     THEN N'this invoice line travels in container ' + ISNULL(c.ContainerRef, N'?') + N': it is received with its container.'
                 WHEN (SELECT COUNT(*) FROM @L d WHERE d.InvoiceLineId = l.InvoiceLineId) > 1
                     THEN N'line ' + CAST(pil.LineNumber AS NVARCHAR(10)) + N' of the invoice is on this goods receipt twice.'
                 WHEN pil.ItemId <> l.ItemId THEN N'the item differs from the invoice line.'
                 ELSE N'the order line differs from the invoice line.' END
        FROM @L l
        LEFT JOIN purchase.PurchaseDocumentLines pil ON pil.Id = l.InvoiceLineId AND pil.DocumentId = @PurchaseInvoiceId
        LEFT JOIN logistics.ContainerLines cl        ON cl.Id = pil.ContainerLineId
        LEFT JOIN logistics.Containers c             ON c.Id = cl.ContainerId
        WHERE pil.Id IS NULL OR pil.ContainerLineId IS NOT NULL OR pil.ItemId <> l.ItemId
           OR (SELECT COUNT(*) FROM @L d WHERE d.InvoiceLineId = l.InvoiceLineId) > 1
           OR (l.PoLineId IS NOT NULL AND l.PoLineId <> ISNULL(pil.SourceLineId, -1))
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 63000, @Msg, 1;

        UPDATE l
        SET PoLineId = pil.SourceLineId, PurchaseOrderId = pol.DocumentId, SupplierId = @InvSupplier, ManualUnitCostBase = NULL,
            WarehouseId = COALESCE(l.WarehouseId, @WarehouseId, pil.WarehouseId),
            ExpiryDate = COALESCE(l.ExpiryDate, pil.ExpiryDate, pol.ExpiryDate)
        FROM @L l
        INNER JOIN purchase.PurchaseDocumentLines pil ON pil.Id = l.InvoiceLineId
        LEFT  JOIN purchase.PurchaseDocumentLines pol ON pol.Id = pil.SourceLineId;

        IF @SupplierId IS NOT NULL AND @SupplierId <> @InvSupplier
            THROW 63000, 'The supplier must be the supplier of the purchase invoice.', 1;
        SELECT @SupplierId = @InvSupplier, @BranchId = @InvBranch, @PurchaseOrderId = NULL;
        SET @SourceText = N'Draft from invoice ' + ISNULL(@InvNo, N'#' + CAST(@PurchaseInvoiceId AS NVARCHAR(10)));
    END
    ELSE   -- Manual: "Without an order"
    BEGIN
        IF @SupplierId IS NULL THROW 63000, 'Choose the supplier: a goods receipt without an order needs one.', 1;
        IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SupplierId AND IsSupplier = 1 AND IsActive = 1)
            THROW 63000, 'Supplier not found, inactive, or not flagged as a supplier.', 1;
        UPDATE l
        SET SupplierId = @SupplierId, ExpectedQuantityBase = NULL, PurchaseOrderId = NULL,
            WarehouseId = COALESCE(l.WarehouseId, @WarehouseId),
            ManualUnitCostBase = COALESCE(l.ManualUnitCostBase, i.LastCost, i.AverageCost)   -- the typed cost; default the item's last cost, else its average (as Post)
        FROM @L l INNER JOIN inventory.Items i ON i.Id = l.ItemId;
        SET @PurchaseOrderId = NULL;
        SET @SourceText = N'Draft without an order (' + (SELECT PartyCode FROM masterdata.Parties WHERE Id = @SupplierId) + N')';
    END

    /* ---------- 4. Local lines (order, invoice, manual): quantity, warehouse, "Nothing more will come", caps */
    IF @SourceKind <> N'Container'
    BEGIN
        IF @WarehouseId IS NULL SELECT TOP (1) @WarehouseId = WarehouseId FROM @L WHERE WarehouseId IS NOT NULL ORDER BY LineNumber;
        IF @WarehouseId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1)
            THROW 63000, 'The warehouse the goods are received into is not found or inactive.', 1;

        -- 0 PIECES ONLY WITH "NOTHING MORE WILL COME" on a line of an order (rules 14, 17): the usual way the rest of an
        -- order line is settled when the supplier says it will never arrive, after a partial delivery was received.
        -- The checks below still apply to such a line (an order line, a reason, an active warehouse); a line of a
        -- manual receipt or of an invoice without an order never takes 0.
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): ' +
            CASE WHEN i.IsActive = 0 THEN N'item ' + i.ItemCode + N' is inactive.'
                 WHEN l.Quantity = 0 AND l.CloseShort = 0 AND l.PoLineId IS NULL THEN N'the received quantity must be more than 0.'
                 WHEN l.Quantity = 0 AND l.CloseShort = 0
                     THEN N'the received quantity must be more than 0, or tick "Nothing more will come" to settle the rest of the order line.'
                 WHEN l.WarehouseId IS NULL THEN N'choose the warehouse the goods are received into.'
                 WHEN w.Id IS NULL OR w.IsActive = 0 THEN N'warehouse not found or inactive.'
                 WHEN l.PoLineId IS NULL THEN N'"Nothing more will come" applies to a line of a purchase order.'
                 ELSE N'give the reason why nothing more will come.' END
        FROM @L l
        INNER JOIN inventory.Items i          ON i.Id = l.ItemId
        LEFT  JOIN masterdata.Warehouses w    ON w.Id = l.WarehouseId
        WHERE i.IsActive = 0 OR (l.Quantity = 0 AND l.CloseShort = 0) OR l.WarehouseId IS NULL OR w.Id IS NULL OR w.IsActive = 0
           OR (l.CloseShort = 1 AND l.PoLineId IS NULL)
           OR (l.CloseShort = 1 AND l.VarianceReasonCode IS NULL AND l.VarianceReason IS NULL)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 63000, @Msg, 1;

        -- the caps of Post (63011), so a draft never promises what cannot be posted
        SELECT TOP (1) @Msg = N'Line ' + CAST(q.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - ' + CAST(q.Qty AS NVARCHAR(20))
                              + N' pcs received but only ' + CAST(p.MaxOutsideBase AS NVARCHAR(20))
                              + N' remain to receive on the order line outside containers.'
        FROM (SELECT PoLineId, OrderId = MIN(PurchaseOrderId), ItemId = MIN(ItemId), Qty = SUM(QuantityBase), LineNumber = MIN(LineNumber)
              FROM @L WHERE PoLineId IS NOT NULL GROUP BY PoLineId) q
        CROSS APPLY purchase.fn_PoLine_Progress(q.OrderId) p
        INNER JOIN inventory.Items i ON i.Id = q.ItemId
        WHERE p.PoLineId = q.PoLineId AND q.Qty > p.MaxOutsideBase
        ORDER BY q.LineNumber;
        IF @Msg IS NOT NULL THROW 63011, @Msg, 1;

        SELECT TOP (1) @Msg = N'Line ' + CAST(q.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - ' + CAST(q.Qty AS NVARCHAR(20))
                              + N' pcs received but only '
                              + CAST(CASE WHEN pil.QuantityBase - pil.ReceivedQuantityBase > 0 THEN pil.QuantityBase - pil.ReceivedQuantityBase ELSE 0 END AS NVARCHAR(20))
                              + N' remain to receive on invoice ' + ISNULL(@InvNo, N'#' + CAST(@PurchaseInvoiceId AS NVARCHAR(10))) + N'.'
        FROM (SELECT InvoiceLineId, ItemId = MIN(ItemId), Qty = SUM(QuantityBase), LineNumber = MIN(LineNumber)
              FROM @L WHERE InvoiceLineId IS NOT NULL AND PoLineId IS NULL GROUP BY InvoiceLineId) q
        INNER JOIN purchase.PurchaseDocumentLines pil ON pil.Id = q.InvoiceLineId
        INNER JOIN inventory.Items i                  ON i.Id = q.ItemId
        WHERE q.Qty > pil.QuantityBase - pil.ReceivedQuantityBase
        ORDER BY q.LineNumber;
        IF @Msg IS NOT NULL THROW 63011, @Msg, 1;

        IF @BranchId IS NULL SET @BranchId = (SELECT BranchId FROM masterdata.Warehouses WHERE Id = @WarehouseId);
    END

    IF @BranchId IS NULL THROW 63000, 'Choose the branch of the goods receipt.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 63000, 'Branch not found or inactive.', 1;

    /* ---------- 5. Write */
    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Id IS NULL
        BEGIN
            IF @SourceKind = N'Container'
            BEGIN
                -- ONE OPEN RECEIPT PER CONTAINER: the container row is locked, then the receipt is inserted only when none
                -- is open (the unique index UX_GoodsReceipts_OpenContainer would refuse a second with a raw 2601)
                DECLARE @OpenId INT, @OpenNo NVARCHAR(30);
                SELECT @CtStatus = Status FROM logistics.Containers WITH (UPDLOCK, HOLDLOCK) WHERE Id = @ContainerId;
                SELECT TOP (1) @OpenId = Id, @OpenNo = DocumentNumber
                FROM purchase.GoodsReceipts WITH (UPDLOCK, HOLDLOCK)
                WHERE ContainerId = @ContainerId AND Status < 3
                ORDER BY Status DESC, Id DESC;
                IF @OpenId IS NOT NULL
                BEGIN
                    SET @Msg = N'Container ' + @Ref + N' already has ' + ISNULL(N'goods receipt ' + @OpenNo, N'a draft goods receipt') + N'. Open it instead.';
                    THROW 63013, @Msg, 1;
                END
                IF @CtStatus NOT BETWEEN 2 AND 5
                    THROW 63010, 'Only a confirmed container that is not received yet can be received.', 1;
            END

            INSERT INTO purchase.GoodsReceipts (DocumentTypeId, DocumentDate, BranchId, WarehouseId, SupplierId, SourceKind, ContainerId,
                                                PurchaseOrderId, PurchaseInvoiceId, MovementId, IsAuto, SupplierReference, Notes, Status, CreatedBy)
            SELECT @TypeId, @DocumentDate, @BranchId, @WarehouseId, @SupplierId, @SourceKind, @ContainerId,
                   @PurchaseOrderId, @PurchaseInvoiceId, @MovementId, @IsAuto, @SupplierReference, @Notes, 1, @UserId
            WHERE @SourceKind <> N'Container'
               OR NOT EXISTS (SELECT 1 FROM purchase.GoodsReceipts x WHERE x.ContainerId = @ContainerId AND x.Status < 3);
            IF @@ROWCOUNT = 0
            BEGIN
                SET @Msg = N'Container ' + @Ref + N' already has a goods receipt. Open it instead.';
                THROW 63013, @Msg, 1;
            END
            SET @Id = SCOPE_IDENTITY();

            INSERT INTO purchase.GoodsReceiptAudit (GoodsReceiptId, Action, Details, UserId)
            VALUES (@Id, N'Created', LEFT(@SourceText + N' (number assigned on posting)', 500), @UserId);
            IF @SourceKind = N'Container'
                INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
                VALUES (@ContainerId, N'Event', LEFT(N'Draft goods receipt created' + ISNULL(N' when ' + @MovNo + N' was completed', N'')
                                                     + N': the goods enter the stock when it is posted.', 500), @UserId);
        END
        ELSE
        BEGIN
            UPDATE purchase.GoodsReceipts
            SET DocumentDate = @DocumentDate, BranchId = @BranchId, WarehouseId = @WarehouseId, SupplierId = @SupplierId,
                PurchaseOrderId = @PurchaseOrderId, SupplierReference = @SupplierReference, Notes = @Notes,
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id AND Status = 1 AND (@RowVersion IS NULL OR RowVersion = @RowVersion);
            IF @@ROWCOUNT = 0 THROW 63004, 'This goods receipt was modified by another user. Reload the page and try again.', 1;

            -- a draft has no matches; removed in case, so the lines can go
            DELETE m FROM purchase.GoodsReceiptInvoiceMatches m
            INNER JOIN purchase.GoodsReceiptLines l ON l.Id = m.GoodsReceiptLineId
            WHERE l.GoodsReceiptId = @Id;
            DELETE FROM purchase.GoodsReceiptLines WHERE GoodsReceiptId = @Id;

            INSERT INTO purchase.GoodsReceiptAudit (GoodsReceiptId, Action, Details, UserId)
            VALUES (@Id, N'Updated', N'Header and ' + CAST((SELECT COUNT(*) FROM @L) AS NVARCHAR(10)) + N' line(s) saved', @UserId);
        END

        -- EXPECTED = what is still to receive now, this receipt left out (its old lines are deleted above)
        IF @SourceKind = N'Order'
            UPDATE l SET ExpectedQuantityBase = p.ToReceiveBase
            FROM @L l CROSS APPLY purchase.fn_PoLine_Progress(l.PurchaseOrderId) p
            WHERE p.PoLineId = l.PoLineId;
        IF @SourceKind = N'Invoice'
            UPDATE l SET ExpectedQuantityBase = t.ToReceiveBase
            FROM @L l INNER JOIN purchase.fn_InvoiceLine_ToReceive(@PurchaseInvoiceId) t ON t.InvoiceLineId = l.InvoiceLineId;

        -- A LINE OF 0 THAT SETTLES NOTHING is refused: nothing is left to receive on its order line (or invoice line) now
        -- - everything received, settled, travelling in containers or on other draft receipts - so it would post as a no-op.
        SET @Msg = NULL;
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): nothing is left to receive on the '
                              + CASE WHEN @SourceKind = N'Invoice' THEN N'invoice line' ELSE N'order line' END
                              + N', so "Nothing more will come" has nothing to settle.'
        FROM @L l INNER JOIN inventory.Items i ON i.Id = l.ItemId
        WHERE @SourceKind <> N'Container' AND l.Quantity = 0 AND l.CloseShort = 1 AND ISNULL(l.ExpectedQuantityBase, 0) = 0
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 63009, @Msg, 1;

        INSERT INTO purchase.GoodsReceiptLines (GoodsReceiptId, LineNumber, ItemId, ItemUnitId, Quantity, PackingFormula,
                                                ExpectedQuantityBase, VarianceReasonCode, VarianceReason, CloseShort, WarehouseId,
                                                SupplierId, PurchaseOrderId, PoLineId, InvoiceLineId, ContainerLineId, ExpiryDate,
                                                ManualUnitCostBase, Notes)
        SELECT @Id, l.LineNumber, l.ItemId, l.ItemUnitId, l.Quantity, l.PackingFormula,
               l.ExpectedQuantityBase, l.VarianceReasonCode, l.VarianceReason, l.CloseShort, l.WarehouseId,
               l.SupplierId, l.PurchaseOrderId, l.PoLineId, l.InvoiceLineId, l.ContainerLineId, l.ExpiryDate,
               l.ManualUnitCostBase, l.Notes
        FROM @L l;

        UPDATE g
        SET TotalExpectedBase = x.Expected, TotalReceivedBase = x.Received
        FROM purchase.GoodsReceipts g
        CROSS APPLY (SELECT Expected = ISNULL(SUM(ISNULL(l.ExpectedQuantityBase, l.QuantityBase)), 0),
                            Received = ISNULL(SUM(l.QuantityBase), 0)
                     FROM purchase.GoodsReceiptLines l WHERE l.GoodsReceiptId = g.Id) x
        WHERE g.Id = @Id;

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 13. Receive goods... on a purchase order */

/* A DRAFT FROM A PURCHASE ORDER, posted or closed (63010 otherwise). @Lines empty = every line with something to
   receive (fn_PoLine_Progress.ToReceiveBase: ordered - received - settled short - in containers - in draft receipts);
   nothing (63009): "Everything still to receive on this order travels in containers..." or "Nothing is left...".
   Otherwise one row per order line (PoLineId; ItemId = the order line's item; Quantity in the row's ItemUnitId, the
   base unit for pieces; WarehouseId NULL = @WarehouseId, else the order line's; CloseShort with VarianceReasonCode /
   VarianceReason = "Nothing more will come"; ExpiryDate NULL = the order line's). Rows of 0 are dropped unless
   CloseShort. A line is written in the order line's unit when its pieces divide by its packing, else in pieces. The
   draft is made by usp_GoodsReceipt_Save (source Order): its checks and caps apply. */
CREATE OR ALTER PROCEDURE purchase.usp_GoodsReceipt_CreateFromOrder
    @PurchaseOrderId   INT,
    @Lines             purchase.tvp_GoodsReceiptLine READONLY,
    @DocumentDate      DATE           = NULL,
    @SupplierReference NVARCHAR(100)  = NULL,
    @UserId            INT            = NULL,
    @NewId             INT            = NULL OUTPUT,
    @WarehouseId       INT            = NULL,
    @Notes             NVARCHAR(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT, @No NVARCHAR(30), @BranchId INT, @SupplierId INT, @Msg NVARCHAR(400);
    SELECT @Status = d.Status, @No = ISNULL(d.DocumentNumber, N'#' + CAST(d.Id AS NVARCHAR(10))), @BranchId = d.BranchId, @SupplierId = d.SupplierId
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId AND dt.Code = N'PO'
    WHERE d.Id = @PurchaseOrderId;
    IF @Status IS NULL THROW 63006, 'Purchase order not found.', 1;
    IF @Status = 3 THROW 63010, 'The purchase order is cancelled.', 1;
    IF @Status NOT IN (2, 4) THROW 63010, 'Only an approved order can be received.', 1;

    DECLARE @Pick TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, PoLineId INT NOT NULL, QuantityBase INT NOT NULL, WarehouseId INT NULL,
                         CloseShort BIT NOT NULL, ReasonCode NVARCHAR(20) NULL, Reason NVARCHAR(300) NULL, ExpiryDate DATE NULL,
                         Notes NVARCHAR(300) NULL);

    IF EXISTS (SELECT 1 FROM @Lines)
    BEGIN
        SELECT TOP (1) @Msg = N'Line ' + CAST(r.LineNumber AS NVARCHAR(10)) + N': ' +
            CASE WHEN pol.Id IS NULL THEN N'it is not a line of order ' + @No + N'.'
                 WHEN pol.ItemId <> r.ItemId THEN N'the item differs from the order line.'
                 WHEN iu.Id IS NULL THEN N'the unit does not belong to the item of the order line.'
                 ELSE N'the received quantity cannot be negative.' END
        FROM @Lines r
        LEFT JOIN purchase.PurchaseDocumentLines pol ON pol.Id = r.PoLineId AND pol.DocumentId = @PurchaseOrderId
        LEFT JOIN inventory.ItemUnits iu             ON iu.Id = r.ItemUnitId AND iu.ItemId = r.ItemId
        WHERE pol.Id IS NULL OR pol.ItemId <> r.ItemId OR iu.Id IS NULL OR r.Quantity < 0
        ORDER BY r.LineNumber;
        IF @Msg IS NOT NULL THROW 63000, @Msg, 1;

        INSERT INTO @Pick (PoLineId, QuantityBase, WarehouseId, CloseShort, ReasonCode, Reason, ExpiryDate, Notes)
        SELECT r.PoLineId, r.Quantity * iu.PackingFormula, r.WarehouseId, ISNULL(r.CloseShort, 0), r.VarianceReasonCode, r.VarianceReason,
               r.ExpiryDate, r.Notes
        FROM @Lines r
        INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = r.PoLineId
        INNER JOIN inventory.ItemUnits iu             ON iu.Id = r.ItemUnitId
        WHERE r.Quantity > 0 OR ISNULL(r.CloseShort, 0) = 1
        ORDER BY pol.LineNumber, r.LineNumber;
        IF NOT EXISTS (SELECT 1 FROM @Pick) THROW 63009, 'Enter the pieces received on at least one line.', 1;
    END
    ELSE
    BEGIN
        INSERT INTO @Pick (PoLineId, QuantityBase, CloseShort)
        SELECT p.PoLineId, p.ToReceiveBase, 0
        FROM purchase.fn_PoLine_Progress(@PurchaseOrderId) p
        WHERE p.ToReceiveBase > 0
        ORDER BY p.LineNumber;
        IF NOT EXISTS (SELECT 1 FROM @Pick)
        BEGIN
            IF EXISTS (SELECT 1 FROM purchase.fn_PoLine_Progress(@PurchaseOrderId) p
                       WHERE p.InContainersBase > 0 AND p.OrderedBase - p.GoodsReceivedBase - p.GoodsShortBase - p.InDraftReceiptsBase > 0)
                THROW 63009, 'Everything still to receive on this order travels in containers: it is received with its containers.', 1;
            THROW 63009, 'Nothing is left to receive on this order.', 1;
        END
    END

    -- in the order line's unit when the pieces divide by its packing, else in pieces
    DECLARE @T purchase.tvp_GoodsReceiptLine;
    INSERT INTO @T (LineNumber, ItemId, ItemUnitId, Quantity, WarehouseId, PoLineId, VarianceReasonCode, VarianceReason, CloseShort,
                    ExpiryDate, Notes)
    SELECT k.Seq, pol.ItemId,
           CASE WHEN k.QuantityBase % pol.PackingFormula = 0 OR bu.Id IS NULL THEN pol.ItemUnitId ELSE bu.Id END,
           CASE WHEN k.QuantityBase % pol.PackingFormula = 0 OR bu.Id IS NULL THEN k.QuantityBase / pol.PackingFormula ELSE k.QuantityBase END,
           COALESCE(k.WarehouseId, @WarehouseId, pol.WarehouseId), k.PoLineId, k.ReasonCode, k.Reason, k.CloseShort,
           COALESCE(k.ExpiryDate, pol.ExpiryDate), k.Notes
    FROM @Pick k
    INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = k.PoLineId
    OUTER APPLY (SELECT TOP (1) u.Id FROM inventory.ItemUnits u WHERE u.ItemId = pol.ItemId AND u.IsBaseUnit = 1 ORDER BY u.Id) bu;

    IF @WarehouseId IS NULL SELECT TOP (1) @WarehouseId = WarehouseId FROM @T ORDER BY LineNumber;

    EXEC purchase.usp_GoodsReceipt_Save @SourceKind = N'Order', @DocumentDate = @DocumentDate, @BranchId = @BranchId,
         @WarehouseId = @WarehouseId, @SupplierId = @SupplierId, @PurchaseOrderId = @PurchaseOrderId,
         @SupplierReference = @SupplierReference, @Notes = @Notes, @Lines = @T, @UserId = @UserId, @NewId = @NewId OUTPUT;
END
GO

/* ================================================================== 14. Receive goods... on a posted purchase invoice */

/* A DRAFT FROM A POSTED (OR CLOSED) SUPPLIER INVOICE, for its lines NOT linked to a container (those are received with
   their containers). Refused (63010) for a draft or cancelled invoice and for one posted before goods receipts
   without "Shipped in containers" (its stock entered when it was posted), or with every line in a container offloaded
   the old way (its stock entered at that offload). @Lines empty = every such line with
   something to receive (fn_InvoiceLine_ToReceive: invoiced - received - in draft receipts); nothing (63009). Otherwise
   one row per invoice line (InvoiceLineId; ItemId = the line's item; Quantity in the row's ItemUnitId; WarehouseId
   NULL = @WarehouseId, else the invoice line's; CloseShort + reason on a line of an order; ExpiryDate NULL = the
   invoice line's, else the order line's). Each line keeps its order line (PoLineId), so the matching works; this
   receipt's pieces match this invoice first. Made by usp_GoodsReceipt_Save (source Invoice). */
CREATE OR ALTER PROCEDURE purchase.usp_GoodsReceipt_CreateFromInvoice
    @InvoiceId         INT,
    @Lines             purchase.tvp_GoodsReceiptLine READONLY,
    @DocumentDate      DATE           = NULL,
    @SupplierReference NVARCHAR(100)  = NULL,
    @UserId            INT            = NULL,
    @NewId             INT            = NULL OUTPUT,
    @WarehouseId       INT            = NULL,
    @Notes             NVARCHAR(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- POSTED BEFORE GOODS RECEIPTS (@Old): an invoice received when it was posted, or a "Shipped in containers" one
    -- whose lines are all in containers offloaded the old way (fn_Container_ReceivedBy 'Offload') - its goods are in
    -- stock already, they do not "travel in containers" (the reason usp_PurchaseDocument_Get gives, rule 15)
    DECLARE @Status TINYINT, @No NVARCHAR(30), @Old BIT, @Msg NVARCHAR(400);
    SELECT @Status = d.Status, @No = ISNULL(d.DocumentNumber, N'#' + CAST(d.Id AS NVARCHAR(10))),
           @Old = CASE WHEN d.UsesGoodsReceipts = 0 AND d.ReceiptMode = 1 THEN 1
                       WHEN d.UsesGoodsReceipts = 0
                            AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines x WHERE x.DocumentId = d.Id AND x.ContainerLineId IS NULL)
                            AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines x
                                            INNER JOIN logistics.ContainerLines cl ON cl.Id = x.ContainerLineId
                                            CROSS APPLY logistics.fn_Container_ReceivedBy(cl.ContainerId) rb
                                            WHERE x.DocumentId = d.Id AND ISNULL(rb.ReceivedBy, N'') <> N'Offload')
                       THEN 1 ELSE 0 END
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId AND dt.Code = N'PINV'
    WHERE d.Id = @InvoiceId;
    IF @Status IS NULL THROW 63006, 'Purchase invoice not found.', 1;
    IF @Status = 3 THROW 63010, 'The purchase invoice is cancelled.', 1;
    IF @Status NOT IN (2, 4) THROW 63010, 'Post the invoice first: goods are received against a posted invoice, or from the order.', 1;
    IF @Old = 1 THROW 63010, 'Posted before goods receipts: its stock entered when it was posted (or when its container was offloaded).', 1;

    DECLARE @Pick TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, InvoiceLineId INT NOT NULL, QuantityBase INT NOT NULL, WarehouseId INT NULL,
                         CloseShort BIT NOT NULL, ReasonCode NVARCHAR(20) NULL, Reason NVARCHAR(300) NULL, ExpiryDate DATE NULL,
                         Notes NVARCHAR(300) NULL);

    IF EXISTS (SELECT 1 FROM @Lines)
    BEGIN
        SELECT TOP (1) @Msg = N'Line ' + CAST(r.LineNumber AS NVARCHAR(10)) + N': ' +
            CASE WHEN pil.Id IS NULL THEN N'it is not a line of invoice ' + @No + N'.'
                 WHEN pil.ContainerLineId IS NOT NULL THEN N'this invoice line travels in a container: it is received with its container.'
                 WHEN pil.ItemId <> r.ItemId THEN N'the item differs from the invoice line.'
                 WHEN iu.Id IS NULL THEN N'the unit does not belong to the item of the invoice line.'
                 ELSE N'the received quantity cannot be negative.' END
        FROM @Lines r
        LEFT JOIN purchase.PurchaseDocumentLines pil ON pil.Id = r.InvoiceLineId AND pil.DocumentId = @InvoiceId
        LEFT JOIN inventory.ItemUnits iu             ON iu.Id = r.ItemUnitId AND iu.ItemId = r.ItemId
        WHERE pil.Id IS NULL OR pil.ContainerLineId IS NOT NULL OR pil.ItemId <> r.ItemId OR iu.Id IS NULL OR r.Quantity < 0
        ORDER BY r.LineNumber;
        IF @Msg IS NOT NULL THROW 63000, @Msg, 1;

        INSERT INTO @Pick (InvoiceLineId, QuantityBase, WarehouseId, CloseShort, ReasonCode, Reason, ExpiryDate, Notes)
        SELECT r.InvoiceLineId, r.Quantity * iu.PackingFormula, r.WarehouseId, ISNULL(r.CloseShort, 0), r.VarianceReasonCode, r.VarianceReason,
               r.ExpiryDate, r.Notes
        FROM @Lines r
        INNER JOIN purchase.PurchaseDocumentLines pil ON pil.Id = r.InvoiceLineId
        INNER JOIN inventory.ItemUnits iu             ON iu.Id = r.ItemUnitId
        WHERE r.Quantity > 0 OR ISNULL(r.CloseShort, 0) = 1
        ORDER BY pil.LineNumber, r.LineNumber;
        IF NOT EXISTS (SELECT 1 FROM @Pick) THROW 63009, 'Enter the pieces received on at least one line.', 1;
    END
    ELSE
    BEGIN
        INSERT INTO @Pick (InvoiceLineId, QuantityBase, CloseShort)
        SELECT t.InvoiceLineId, t.ToReceiveBase, 0
        FROM purchase.fn_InvoiceLine_ToReceive(@InvoiceId) t
        WHERE t.ToReceiveBase > 0
        ORDER BY t.LineNumber;
        IF NOT EXISTS (SELECT 1 FROM @Pick)
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM purchase.fn_InvoiceLine_ToReceive(@InvoiceId))
                THROW 63009, 'This invoice''s goods travel in containers: they are received with their containers.', 1;
            IF EXISTS (SELECT 1 FROM purchase.fn_InvoiceLine_ToReceive(@InvoiceId) t
                       WHERE t.InDraftReceiptsBase > 0 AND t.InvoicedBase - t.ReceivedBase > 0)
                THROW 63009, 'The rest of this invoice is on draft goods receipts: post or delete them first.', 1;
            THROW 63009, 'Every piece of this invoice is already received.', 1;
        END
    END

    DECLARE @T purchase.tvp_GoodsReceiptLine;
    INSERT INTO @T (LineNumber, ItemId, ItemUnitId, Quantity, WarehouseId, PoLineId, InvoiceLineId, VarianceReasonCode, VarianceReason,
                    CloseShort, ExpiryDate, Notes)
    SELECT k.Seq, pil.ItemId,
           CASE WHEN k.QuantityBase % pil.PackingFormula = 0 OR bu.Id IS NULL THEN pil.ItemUnitId ELSE bu.Id END,
           CASE WHEN k.QuantityBase % pil.PackingFormula = 0 OR bu.Id IS NULL THEN k.QuantityBase / pil.PackingFormula ELSE k.QuantityBase END,
           COALESCE(k.WarehouseId, @WarehouseId, pil.WarehouseId), pil.SourceLineId, k.InvoiceLineId, k.ReasonCode, k.Reason, k.CloseShort,
           COALESCE(k.ExpiryDate, pil.ExpiryDate, pol.ExpiryDate), k.Notes
    FROM @Pick k
    INNER JOIN purchase.PurchaseDocumentLines pil ON pil.Id = k.InvoiceLineId
    LEFT  JOIN purchase.PurchaseDocumentLines pol ON pol.Id = pil.SourceLineId
    OUTER APPLY (SELECT TOP (1) u.Id FROM inventory.ItemUnits u WHERE u.ItemId = pil.ItemId AND u.IsBaseUnit = 1 ORDER BY u.Id) bu;

    IF @WarehouseId IS NULL SELECT TOP (1) @WarehouseId = WarehouseId FROM @T ORDER BY LineNumber;

    EXEC purchase.usp_GoodsReceipt_Save @SourceKind = N'Invoice', @DocumentDate = @DocumentDate, @WarehouseId = @WarehouseId,
         @PurchaseInvoiceId = @InvoiceId, @SupplierReference = @SupplierReference, @Notes = @Notes, @Lines = @T,
         @UserId = @UserId, @NewId = @NewId OUTPUT;
END
GO

/* ================================================================== 15. Receive goods... on a container, and the Delivery hook */

/* A CONTAINER'S DRAFT: its lines in pieces, expected = received = loaded (or the received pieces and reasons of @Lines,
   rows by ContainerLineId, Quantity in the row's ItemUnitId), expiry = the order line's. Header: the container's
   branch; the supplier when its orders have one (else NULL: "Several suppliers"); the order when it holds one;
   "Receive into" = @WarehouseId, else the container's "Warehouse (offloading destination)" when it is active and of
   the container's branch, else empty (chosen on the draft); date = @DocumentDate, else the movement's end date, else
   today. With @MovementId (a completed Delivery-stage movement holding the container): IsAuto = 1.
   Eligible: status Confirmed to Cleared (2-5, decision 6: no Delivery needed) and no draft or posted receipt.
   @Silent = 0 ("Receive goods..."): THROW 63010 / 63013 / 63009, and an inactive item 63000 (usp_GoodsReceipt_Save's
   sentence). @Silent = 1 (the Delivery hook): no THROW for eligibility, @SkipReason = 'Cancelled' | 'NotConfirmed' |
   'Received' | 'HasDraft' | 'NoLines' | 'InactiveItem' (a line's item is inactive: Save would refuse the draft, and
   the completion of the Delivery must not fail for it) and @NewId NULL; other errors are thrown. The container row is locked (UPDLOCK, HOLDLOCK) for the whole check-and-insert. Answers
   only through its OUTPUT parameters (no result set), so CreateForMovement can call it. */
CREATE OR ALTER PROCEDURE purchase.usp_GoodsReceipt_CreateForContainer
    @ContainerId  INT,
    @DocumentDate DATE         = NULL,
    @MovementId   INT          = NULL,
    @UserId       INT          = NULL,
    @Silent       BIT          = 0,
    @NewId        INT          = NULL OUTPUT,
    @SkipReason   NVARCHAR(20) = NULL OUTPUT,
    @WarehouseId  INT          = NULL,
    @Lines        purchase.tvp_GoodsReceiptLine READONLY
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @NewId = NULL;
    SET @SkipReason = NULL;

    DECLARE @Status TINYINT, @Ref NVARCHAR(30), @BranchId INT, @CtWarehouse INT, @OpenId INT, @OpenNo NVARCHAR(30),
            @OpenStatus TINYINT, @Msg NVARCHAR(400);

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = Status, @Ref = ContainerRef, @BranchId = BranchId, @CtWarehouse = WarehouseId
        FROM logistics.Containers WITH (UPDLOCK, HOLDLOCK) WHERE Id = @ContainerId;
        IF @Status IS NULL THROW 63006, 'Container not found.', 1;

        SELECT TOP (1) @OpenId = Id, @OpenNo = DocumentNumber, @OpenStatus = Status
        FROM purchase.GoodsReceipts WITH (UPDLOCK, HOLDLOCK)
        WHERE ContainerId = @ContainerId AND Status < 3
        ORDER BY Status DESC, Id DESC;

        SET @SkipReason = CASE WHEN @Status = 8 THEN N'Cancelled'
                               WHEN @Status = 1 THEN N'NotConfirmed'
                               WHEN @Status IN (6, 7) OR @OpenStatus = 2 THEN N'Received'
                               WHEN @OpenStatus = 1 THEN N'HasDraft'
                               WHEN NOT EXISTS (SELECT 1 FROM logistics.ContainerLines WHERE ContainerId = @ContainerId) THEN N'NoLines' END;
        IF @SkipReason IS NOT NULL
        BEGIN
            IF @Silent = 1
            BEGIN
                COMMIT TRANSACTION;
                RETURN;
            END
            IF @OpenId IS NOT NULL
            BEGIN
                SET @Msg = N'Container ' + @Ref + N' already has ' + ISNULL(N'goods receipt ' + @OpenNo, N'a draft goods receipt') + N'. Open it instead.';
                THROW 63013, @Msg, 1;
            END
            IF @SkipReason = N'NoLines'
            BEGIN
                SET @Msg = N'Container ' + @Ref + N' has no lines to receive.';
                THROW 63009, @Msg, 1;
            END;
            THROW 63010, 'Only a confirmed container that is not received yet can be received.', 1;
        END

        -- the received pieces given by the dialog: rows of this container's lines, each once, in a unit of the item
        SELECT TOP (1) @Msg = N'Line ' + CAST(r.LineNumber AS NVARCHAR(10)) + N': ' +
            CASE WHEN cl.Id IS NULL THEN N'it is not a line of container ' + @Ref + N'.'
                 WHEN iu.Id IS NULL THEN N'the unit does not belong to the item of the container line.'
                 WHEN r.Quantity < 0 THEN N'the received quantity cannot be negative.'
                 ELSE N'the container line is given twice.' END
        FROM @Lines r
        LEFT JOIN logistics.ContainerLines cl ON cl.Id = r.ContainerLineId AND cl.ContainerId = @ContainerId
        LEFT JOIN inventory.ItemUnits iu      ON iu.Id = r.ItemUnitId AND iu.ItemId = cl.ItemId
        WHERE cl.Id IS NULL OR iu.Id IS NULL OR r.Quantity < 0
           OR (SELECT COUNT(*) FROM @Lines d WHERE d.ContainerLineId = r.ContainerLineId) > 1
        ORDER BY r.LineNumber;
        IF @Msg IS NOT NULL THROW 63000, @Msg, 1;

        DECLARE @T purchase.tvp_GoodsReceiptLine;
        INSERT INTO @T (LineNumber, ItemId, ItemUnitId, Quantity, PoLineId, ContainerLineId, ExpectedQuantityBase,
                        VarianceReasonCode, VarianceReason, CloseShort, ExpiryDate, Notes)
        SELECT ROW_NUMBER() OVER (ORDER BY cl.LineNumber), cl.ItemId, COALESCE(bu.Id, cl.ItemUnitId),
               CASE WHEN r.ContainerLineId IS NOT NULL THEN r.Quantity * iu.PackingFormula ELSE cl.QuantityBase END,
               cl.PoLineId, cl.Id, cl.QuantityBase, r.VarianceReasonCode, r.VarianceReason, 0,
               COALESCE(r.ExpiryDate, pol.ExpiryDate), r.Notes
        FROM logistics.ContainerLines cl
        INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = cl.PoLineId
        OUTER APPLY (SELECT TOP (1) u.Id FROM inventory.ItemUnits u WHERE u.ItemId = cl.ItemId AND u.IsBaseUnit = 1 ORDER BY u.Id) bu
        LEFT  JOIN @Lines r                           ON r.ContainerLineId = cl.Id
        LEFT  JOIN inventory.ItemUnits iu             ON iu.Id = r.ItemUnitId
        WHERE cl.ContainerId = @ContainerId;

        -- AN INACTIVE ITEM: Save refuses the draft (rule 12). Silent (the Delivery hook), the container is skipped with its
        -- reason, like the other skips, so the completion goes on; otherwise Save says which line.
        IF @Silent = 1 AND EXISTS (SELECT 1 FROM @T t INNER JOIN inventory.Items i ON i.Id = t.ItemId WHERE i.IsActive = 0)
        BEGIN
            SET @SkipReason = N'InactiveItem';
            COMMIT TRANSACTION;
            RETURN;
        END

        -- "Receive into": the container's warehouse only when it can take the goods (active, of the container's branch)
        IF @WarehouseId IS NULL
            SET @WarehouseId = (SELECT w.Id FROM masterdata.Warehouses w WHERE w.Id = @CtWarehouse AND w.IsActive = 1 AND w.BranchId = @BranchId);
        IF @DocumentDate IS NULL
            SET @DocumentDate = COALESCE((SELECT EndDate FROM logistics.Movements WHERE Id = @MovementId), CAST(SYSUTCDATETIME() AS DATE));

        EXEC purchase.usp_GoodsReceipt_Save @SourceKind = N'Container', @ContainerId = @ContainerId, @MovementId = @MovementId,
             @DocumentDate = @DocumentDate, @BranchId = @BranchId, @WarehouseId = @WarehouseId, @Lines = @T,
             @UserId = @UserId, @NewId = @NewId OUTPUT;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 16. The drafts of a completed Delivery movement */

/* CALLED BY THE API AFTER usp_Movement_SetStatus HAS COMMITTED the Complete of a Delivery-stage movement (any type
   code with the stage Delivery). Completing the movement never fails because of the receipts: each container goes
   through usp_GoodsReceipt_CreateForContainer (@Silent = 1) in its own transaction and TRY/CATCH, so one failure
   leaves the others. Refused (70010) for a movement that is not completed or not Delivery-stage, and inside an open
   transaction (63010): a failure here must not roll back the completion.
   One row per container of the movement, by reference: ContainerId, ContainerRef, GoodsReceiptId (the new draft, or
   the open receipt that made it skip), GoodsReceiptNumber, GoodsReceiptStatus, WarehouseCode (of the draft; NULL =
   to choose), Created, SkipReason ('Received' | 'HasDraft' | 'NotConfirmed' | 'Cancelled' | 'NoLines' | 'InactiveItem'
   | 'Error'), Message (plain English; for 'Error' the SQL message; for 'InactiveItem' the first inactive item). */
CREATE OR ALTER PROCEDURE purchase.usp_GoodsReceipt_CreateForMovement
    @MovementId INT,
    @UserId     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;

    IF @@TRANCOUNT > 0
        THROW 63010, 'The goods receipts of a movement are created after its completion is committed, outside any transaction.', 1;

    DECLARE @Status TINYINT, @Stage NVARCHAR(10), @MovNo NVARCHAR(30), @EndDate DATE;
    SELECT @Status = m.Status, @Stage = mt.Stage, @MovNo = m.MovementNo, @EndDate = m.EndDate
    FROM logistics.Movements m
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    WHERE m.Id = @MovementId;
    IF @Status IS NULL THROW 70006, 'Movement not found.', 1;
    IF @Status <> 3 OR @Stage <> N'Delivery' THROW 70010, 'Only a completed Delivery movement creates goods receipts.', 1;

    DECLARE @Result TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, ContainerId INT NOT NULL, ContainerRef NVARCHAR(30) NOT NULL,
                           GoodsReceiptId INT NULL, Created BIT NOT NULL, SkipReason NVARCHAR(20) NULL, Message NVARCHAR(400) NULL);
    DECLARE @Cid INT, @CRef NVARCHAR(30), @NewId INT, @Skip NVARCHAR(20), @Err NVARCHAR(400);

    DECLARE ctn CURSOR LOCAL FAST_FORWARD FOR
        SELECT c.Id, c.ContainerRef
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
        WHERE mc.MovementId = @MovementId
        ORDER BY c.ContainerRef;
    OPEN ctn;
    FETCH NEXT FROM ctn INTO @Cid, @CRef;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT @NewId = NULL, @Skip = NULL, @Err = NULL;
        BEGIN TRY
            EXEC purchase.usp_GoodsReceipt_CreateForContainer @ContainerId = @Cid, @DocumentDate = @EndDate, @MovementId = @MovementId,
                 @UserId = @UserId, @Silent = 1, @NewId = @NewId OUTPUT, @SkipReason = @Skip OUTPUT;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
            SELECT @NewId = NULL, @Skip = N'Error', @Err = LEFT(ERROR_MESSAGE(), 400);
        END CATCH

        INSERT INTO @Result (ContainerId, ContainerRef, GoodsReceiptId, Created, SkipReason, Message)
        VALUES (@Cid, @CRef, COALESCE(@NewId, (SELECT r.GoodsReceiptId FROM logistics.fn_Container_ReceivedBy(@Cid) r)),
                CASE WHEN @NewId IS NOT NULL THEN 1 ELSE 0 END, @Skip, @Err);
        FETCH NEXT FROM ctn INTO @Cid, @CRef;
    END
    CLOSE ctn;
    DEALLOCATE ctn;

    SELECT r.ContainerId, r.ContainerRef, r.GoodsReceiptId, GoodsReceiptNumber = g.DocumentNumber, GoodsReceiptStatus = g.Status,
           WarehouseCode = CASE WHEN r.Created = 1 THEN w.WarehouseCode END, r.Created, r.SkipReason,
           Message = CAST(CASE
               WHEN r.Created = 1 AND w.Id IS NOT NULL THEN N'Draft goods receipt created into ' + w.WarehouseCode + N'.'
               WHEN r.Created = 1 THEN N'Draft goods receipt created: choose the warehouse.'
               WHEN r.SkipReason = N'Error' THEN r.Message
               WHEN r.SkipReason = N'Received' AND g.Status = 2 THEN N'Already received with goods receipt ' + g.DocumentNumber + N'.'
               WHEN r.SkipReason = N'Received' THEN N'Already offloaded.'
               WHEN r.SkipReason = N'HasDraft' THEN N'Already has a draft goods receipt.'
               WHEN r.SkipReason = N'NotConfirmed' THEN N'Not confirmed: confirm the container, then use Receive goods... on it.'
               WHEN r.SkipReason = N'Cancelled' THEN N'The container is cancelled.'
               WHEN r.SkipReason = N'NoLines' THEN N'The container has no lines.'
               WHEN r.SkipReason = N'InactiveItem'
                   THEN N'Item ' + ISNULL(ia.ItemCode, N'?') + N' is inactive: activate it in Item Definition, then use Receive goods... on the container.' END
               AS NVARCHAR(400))
    FROM @Result r
    LEFT JOIN purchase.GoodsReceipts g    ON g.Id = r.GoodsReceiptId
    LEFT JOIN masterdata.Warehouses w     ON w.Id = g.WarehouseId
    OUTER APPLY (SELECT TOP (1) i.ItemCode
                 FROM logistics.ContainerLines cl INNER JOIN inventory.Items i ON i.Id = cl.ItemId
                 WHERE r.SkipReason = N'InactiveItem' AND cl.ContainerId = r.ContainerId AND i.IsActive = 0
                 ORDER BY cl.LineNumber) ia
    ORDER BY r.Seq;
END
GO

/* ================================================================== 17. Delete a draft */

-- A DRAFT ONLY (63005), with RowVersion (63004): its files, lines and audit go with it (nothing was in stock). The
-- container of a container receipt keeps a history line: it then waits without a receipt ("Receive goods..." again).
CREATE OR ALTER PROCEDURE purchase.usp_GoodsReceipt_Delete
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT, @ContainerId INT, @IsAuto BIT, @MovNo NVARCHAR(30);
    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = g.Status, @ContainerId = g.ContainerId, @IsAuto = g.IsAuto, @MovNo = m.MovementNo
        FROM purchase.GoodsReceipts g WITH (UPDLOCK, HOLDLOCK)
        LEFT JOIN logistics.Movements m ON m.Id = g.MovementId
        WHERE g.Id = @Id;
        IF @Status IS NULL THROW 63006, 'Goods receipt not found.', 1;
        IF @Status <> 1 THROW 63005, 'Only a draft goods receipt can be changed or deleted.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.GoodsReceipts WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 63004, 'This goods receipt was modified by another user. Reload the page and try again.', 1;

        DELETE m FROM purchase.GoodsReceiptInvoiceMatches m
        INNER JOIN purchase.GoodsReceiptLines l ON l.Id = m.GoodsReceiptLineId
        WHERE l.GoodsReceiptId = @Id;
        DELETE FROM purchase.GoodsReceiptFiles WHERE GoodsReceiptId = @Id;
        DELETE FROM purchase.GoodsReceiptLines WHERE GoodsReceiptId = @Id;
        DELETE FROM purchase.GoodsReceiptAudit WHERE GoodsReceiptId = @Id;
        DELETE FROM purchase.GoodsReceipts WHERE Id = @Id;

        IF @ContainerId IS NOT NULL
            INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
            VALUES (@ContainerId, N'Event',
                    LEFT(N'Draft goods receipt deleted' + CASE WHEN @IsAuto = 1 THEN ISNULL(N' (created when ' + @MovNo + N' was completed)', N'') ELSE N'' END
                         + N': receive the container again with Receive goods...', 500), @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 18. Get */

/* ONE GOODS RECEIPT, 6 result sets (none when the id is unknown):
     1 header: names, the source documents, the Delivery movement that made it (number, type, route, end date) and the
       container's latest completed Delivery (place, date: "Delivered"), totals (expected, received, short, invoiced,
       value at receipt, current value - an estimate on a draft), Can* and the *BlockedReason sentences of
       fn_GoodsReceipt_Blocks (the same as the refusals), the switch date, RowVersion
     2 lines: item, unit, warehouse, supplier, order / invoice / container line, expected / received / difference /
       reason / settled short (an estimate on a draft), order price, current cost (the container line's for a
       container line), cost at receipt, cost source, invoiced, value
     3 matches: which posted invoice lines pay for which received pieces (invoice number, pieces, invoice FOB)
     4 cost changes (history of the cost of the received goods)
     5 files (no content), shaped as usp_GoodsReceipt_File_List
     6 audit, newest first */
CREATE OR ALTER PROCEDURE purchase.usp_GoodsReceipt_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT g.Id, g.DocumentTypeId, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, DocumentTypeIsActive = dt.IsActive,
           g.DocumentNumber, g.DocumentDate, g.Status,
           StatusName = CASE g.Status WHEN 1 THEN N'Draft' WHEN 2 THEN N'Posted' ELSE N'Cancelled' END,
           g.SourceKind, g.IsAuto,
           g.BranchId, b.BranchCode, b.BranchName,
           g.WarehouseId, w.WarehouseCode, w.WarehouseName, WarehouseIsActive = w.IsActive,
           WarehouseInBranch = CAST(CASE WHEN w.Id IS NULL THEN NULL
                                         WHEN w.BranchId = ISNULL(c.BranchId, g.BranchId) THEN 1 ELSE 0 END AS BIT),
           g.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName,
           SupplierDisplayName = ISNULL(sp.PartyName, CASE WHEN g.SourceKind = N'Container' THEN N'Several suppliers' END),
           g.ContainerId, c.ContainerRef, c.ContainerNo, c.SealNo, c.TruckNo, c.WaybillNo, ContainerStatus = c.Status,
           ContainerBranchId = c.BranchId, ContainerWarehouseId = c.WarehouseId, ContainerWarehouseCode = cw.WarehouseCode,
           g.PurchaseOrderId, po.DocumentNumber AS PurchaseOrderNumber,
           g.PurchaseInvoiceId, pi.DocumentNumber AS PurchaseInvoiceNumber,
           g.MovementId, mv.MovementNo, MovementEndDate = mv.EndDate, MovementTypeName = mvt.TypeName, MovementStage = mvt.Stage,
           MovementFromName = mfp.PortName, MovementToName = mtp.PortName,
           DeliveryMovementId = ld.MovementId, DeliveryMovementNo = ld.MovementNo, DeliveredDate = ld.EndDate, DeliveryPlaceName = ld.PlaceName,
           g.SupplierReference, g.Notes,
           LineCount = ISNULL(tot.Lines, 0), g.TotalExpectedBase, g.TotalReceivedBase,
           TotalShortBase = ISNULL(CASE WHEN g.Status = 1 THEN tot.ShortDraft ELSE tot.Settled END, 0), TotalInvoicedBase = ISNULL(tot.Invoiced, 0),
           g.ValueAtReceiptBase, CurrentValueBase = ISNULL(val.Value, 0),
           IsValueEstimate = CAST(CASE WHEN g.Status = 1 THEN 1 ELSE 0 END AS BIT),
           BaseCurrencyCode = bc.CurrencyCode,
           g.PostedAtUtc, g.PostedBy, pu.FullName AS PostedByName,
           g.CancelledAtUtc, g.CancelledBy, xu.FullName AS CancelledByName, g.CancelReason,
           g.CreatedAtUtc, g.CreatedBy, cu.FullName AS CreatedByName, g.UpdatedAtUtc, g.UpdatedBy, uu.FullName AS UpdatedByName,
           CanEdit   = CAST(CASE WHEN g.Status = 1 THEN 1 ELSE 0 END AS BIT),
           CanPost   = CAST(CASE WHEN g.Status = 1 AND pb.Message IS NULL THEN 1 ELSE 0 END AS BIT),
           CanCancel = CAST(CASE WHEN g.Status = 2 AND cb.Message IS NULL THEN 1 ELSE 0 END AS BIT),
           CanDelete = CAST(CASE WHEN g.Status = 1 THEN 1 ELSE 0 END AS BIT),
           EditBlockedReason = eb.Message, PostBlockedReason = pb.Message, CancelBlockedReason = cb.Message, DeleteBlockedReason = db.Message,
           SwitchedAtUtc = (SELECT s.SwitchedAtUtc FROM purchase.GoodsReceiptSwitch s WHERE s.Id = 1),
           g.RowVersion
    FROM purchase.GoodsReceipts g
    INNER JOIN inventory.DocumentTypes dt   ON dt.Id = g.DocumentTypeId
    INNER JOIN masterdata.Branches b        ON b.Id = g.BranchId
    LEFT  JOIN masterdata.Warehouses w      ON w.Id = g.WarehouseId
    LEFT  JOIN masterdata.Parties sp        ON sp.Id = g.SupplierId
    LEFT  JOIN logistics.Containers c       ON c.Id = g.ContainerId
    LEFT  JOIN masterdata.Warehouses cw     ON cw.Id = c.WarehouseId
    LEFT  JOIN purchase.PurchaseDocuments po ON po.Id = g.PurchaseOrderId
    LEFT  JOIN purchase.PurchaseDocuments pi ON pi.Id = g.PurchaseInvoiceId
    LEFT  JOIN logistics.Movements mv       ON mv.Id = g.MovementId
    LEFT  JOIN masterdata.MovementTypes mvt ON mvt.Id = mv.MovementTypeId
    LEFT  JOIN masterdata.Ports mfp         ON mfp.Id = mv.FromPlaceId
    LEFT  JOIN masterdata.Ports mtp         ON mtp.Id = mv.ToPlaceId
    LEFT  JOIN masterdata.Currencies bc     ON bc.IsBaseCurrency = 1 AND bc.IsActive = 1
    LEFT  JOIN security.Users pu ON pu.Id = g.PostedBy
    LEFT  JOIN security.Users xu ON xu.Id = g.CancelledBy
    LEFT  JOIN security.Users cu ON cu.Id = g.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = g.UpdatedBy
    OUTER APPLY logistics.fn_Container_LastDelivery(g.ContainerId) ld
    OUTER APPLY (SELECT Lines = COUNT(*), Invoiced = SUM(l.InvoicedBase),
                        Settled = SUM(l.SettledShortBase),
                        ShortDraft = SUM(CASE WHEN (l.ContainerLineId IS NOT NULL OR l.CloseShort = 1) AND l.ExpectedQuantityBase > l.QuantityBase
                                              THEN l.ExpectedQuantityBase - l.QuantityBase ELSE 0 END)
                 FROM purchase.GoodsReceiptLines l WHERE l.GoodsReceiptId = g.Id) tot
    OUTER APPLY (SELECT Value = SUM(k.ValueBase) FROM purchase.fn_GoodsReceiptLine_Cost(g.Id) k) val
    OUTER APPLY (SELECT TOP (1) k.Message FROM purchase.fn_GoodsReceipt_Blocks(g.Id) k WHERE k.Action = N'Post'   ORDER BY k.Seq) pb
    OUTER APPLY (SELECT TOP (1) k.Message FROM purchase.fn_GoodsReceipt_Blocks(g.Id) k WHERE k.Action = N'Cancel' ORDER BY k.Seq) cb
    OUTER APPLY (SELECT TOP (1) k.Message FROM purchase.fn_GoodsReceipt_Blocks(g.Id) k WHERE k.Action = N'Delete' ORDER BY k.Seq) db
    OUTER APPLY (SELECT TOP (1) k.Message FROM purchase.fn_GoodsReceipt_Blocks(g.Id) k WHERE k.Action = N'Edit'   ORDER BY k.Seq) eb
    WHERE g.Id = @Id;

    -- 2: lines
    SELECT l.Id, l.GoodsReceiptId, l.LineNumber, l.ItemId, i.ItemCode, i.ItemName,
           l.ItemUnitId, ut.UnitTypeName, iu.SkuCode, l.PackingFormula,
           l.Quantity, l.QuantityBase, l.ExpectedQuantityBase,
           DifferenceBase = l.QuantityBase - l.ExpectedQuantityBase,
           l.VarianceReasonCode,
           VarianceReasonName = CASE l.VarianceReasonCode WHEN N'SHORT' THEN N'Short-shipped' WHEN N'DAMAGED' THEN N'Damaged'
                                                          WHEN N'MISSING' THEN N'Missing' WHEN N'LOADCOUNT' THEN N'Wrongly counted at loading'
                                                          WHEN N'OTHER' THEN N'Other' END,
           l.VarianceReason, l.CloseShort,
           SettledShortBase = CASE WHEN g.Status <> 1 THEN l.SettledShortBase
                                   WHEN (l.ContainerLineId IS NOT NULL OR l.CloseShort = 1) AND l.ExpectedQuantityBase > l.QuantityBase
                                       THEN l.ExpectedQuantityBase - l.QuantityBase ELSE 0 END,
           l.WarehouseId, w.WarehouseCode, w.WarehouseName,
           l.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName,
           l.PurchaseOrderId, po.DocumentNumber AS OrderNumber, l.PoLineId, pol.LineNumber AS PoLineNumber,
           OrderedBase = pol.QuantityBase, OrderUnitTypeName = put.UnitTypeName, OrderPackingFormula = pol.PackingFormula,
           l.InvoiceLineId, InvoiceId = pil.DocumentId, pid.DocumentNumber AS InvoiceNumber, pil.LineNumber AS InvoiceLineNumber,
           l.ContainerLineId, cl.LineNumber AS ContainerLineNumber, LoadedBase = cl.QuantityBase,
           l.ExpiryDate,
           l.PoFobBase, k.OrderPriceBase, l.ManualUnitCostBase,
           FobCostBase = k.FobBase, ChargesBase = k.ChargesBase, UnitCostBase = k.UnitCostBase, IsCostEstimate = k.IsEstimate,
           l.CostAtReceiptBase, l.CostSource,
           CostSourceName = CASE l.CostSource WHEN N'Order' THEN N'Order price' WHEN N'Invoice' THEN N'Invoice'
                                              WHEN N'Mixed' THEN N'Order + invoice' WHEN N'Manual' THEN N'Typed' END,
           l.InvoicedBase, NotInvoicedBase = l.QuantityBase - l.InvoicedBase,
           k.ValueBase, l.Notes,
           ItemLastCost = i.LastCost, ItemAverageCost = i.AverageCost
    FROM purchase.GoodsReceiptLines l
    INNER JOIN purchase.GoodsReceipts g             ON g.Id = l.GoodsReceiptId
    INNER JOIN inventory.Items i                    ON i.Id = l.ItemId
    INNER JOIN inventory.ItemUnits iu               ON iu.Id = l.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut              ON ut.Id = iu.UnitTypeId
    LEFT  JOIN masterdata.Warehouses w              ON w.Id = l.WarehouseId
    LEFT  JOIN masterdata.Parties sp                ON sp.Id = l.SupplierId
    LEFT  JOIN purchase.PurchaseDocuments po        ON po.Id = l.PurchaseOrderId
    LEFT  JOIN purchase.PurchaseDocumentLines pol   ON pol.Id = l.PoLineId
    LEFT  JOIN inventory.ItemUnits piu              ON piu.Id = pol.ItemUnitId
    LEFT  JOIN masterdata.UnitTypes put             ON put.Id = piu.UnitTypeId
    LEFT  JOIN purchase.PurchaseDocumentLines pil   ON pil.Id = l.InvoiceLineId
    LEFT  JOIN purchase.PurchaseDocuments pid       ON pid.Id = pil.DocumentId
    LEFT  JOIN logistics.ContainerLines cl          ON cl.Id = l.ContainerLineId
    LEFT  JOIN purchase.fn_GoodsReceiptLine_Cost(@Id) k ON k.LineId = l.Id
    WHERE l.GoodsReceiptId = @Id
    ORDER BY l.LineNumber;

    -- 3: matches
    SELECT m.GoodsReceiptLineId, l.LineNumber, l.ItemId, i.ItemCode,
           m.InvoiceLineId, InvoiceId = pil.DocumentId, pid.DocumentNumber AS InvoiceNumber, pid.DocumentDate AS InvoiceDate,
           pid.PostedAtUtc AS InvoicePostedAtUtc, pil.LineNumber AS InvoiceLineNumber,
           m.QuantityBase, InvoiceFobBase = pil.FobCostBase, InvoiceUnitCostBase = pil.UnitCostBase, m.MatchedAtUtc
    FROM purchase.GoodsReceiptInvoiceMatches m
    INNER JOIN purchase.GoodsReceiptLines l       ON l.Id = m.GoodsReceiptLineId
    INNER JOIN inventory.Items i                  ON i.Id = l.ItemId
    INNER JOIN purchase.PurchaseDocumentLines pil ON pil.Id = m.InvoiceLineId
    INNER JOIN purchase.PurchaseDocuments pid     ON pid.Id = pil.DocumentId
    WHERE l.GoodsReceiptId = @Id
    ORDER BY l.LineNumber, pid.PostedAtUtc, pid.Id, pil.LineNumber;

    -- 4: cost changes
    SELECT cc.Id, cc.GoodsReceiptLineId, l.LineNumber, l.ItemId, i.ItemCode, i.ItemName,
           cc.ChangedAtUtc, cc.CauseKind, cc.CauseId, cc.CauseNumber, cc.ReceivedBase, cc.InStockBase,
           cc.FobBefore, cc.FobAfter, cc.UnitCostBefore, cc.UnitCostAfter, cc.AmountBase, cc.InventoryBase, cc.CogsBase,
           cc.CreatedBy, u.FullName AS CreatedByName
    FROM purchase.GoodsReceiptCostChanges cc
    INNER JOIN purchase.GoodsReceiptLines l ON l.Id = cc.GoodsReceiptLineId
    INNER JOIN inventory.Items i            ON i.Id = l.ItemId
    LEFT  JOIN security.Users u             ON u.Id = cc.CreatedBy
    WHERE l.GoodsReceiptId = @Id
    ORDER BY cc.ChangedAtUtc, cc.Id;

    -- 5: files (no content)
    SELECT f.Id, f.GoodsReceiptId AS DocumentId, f.FileName, f.ContentType, f.SizeBytes, f.AttachmentTypeId, t.Category, t.SubType,
           IsOther = CAST(CASE WHEN t.SubType = N'Other' AND t.Category IN (N'Other', N'General') THEN 1 ELSE 0 END AS BIT),
           f.DocumentDate, f.Note, f.CreatedAtUtc, f.CreatedBy, u.FullName AS CreatedByName
    FROM purchase.GoodsReceiptFiles f
    LEFT JOIN masterdata.AttachmentTypes t ON t.Id = f.AttachmentTypeId
    LEFT JOIN security.Users u             ON u.Id = f.CreatedBy
    WHERE f.GoodsReceiptId = @Id
    ORDER BY f.CreatedAtUtc DESC, f.Id DESC;

    -- 6: audit
    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM purchase.GoodsReceiptAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.GoodsReceiptId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;
END
GO

/* ================================================================== 19. Search */

/* THE LIST, paged, and a totals row (2 result sets).
   Filters: @Search (number, container ref or no., order and invoice numbers - the source's and the lines' -, item
   code, delivery note no., supplier code or name, movement no.); status, source kind, branch, supplier (the header's or
   a line's: mixed containers), warehouse (the header's or a line's), dates; @ContainerId, @PurchaseOrderId (the
   header's or a line's), @InvoiceId (the source invoice, or an invoice its pieces are matched to), @MovementId,
   @IsAuto;
     @WithDifferences      a line received differently from what was expected and settled (container lines that
                           differ from the loaded pieces, "Nothing more will come", a reason given, pieces settled short)
     @ReceivedNotInvoiced  posted, with pieces received and not matched to posted invoices yet
     @DeliveredNotReceived the goods are at the warehouse but not in stock: draft container receipts whose container's
                           Delivery is completed
     @NotReceived          drafts of any source: nothing of them is in stock yet (the menu count's list)
   Sort: DocumentNumber | DocumentDate | SupplierName | Status | ReceivedBase | ValueBase | CreatedAtUtc | PostedAtUtc.
   1: one row per receipt (TotalCount = all pages); value = current value of the lines (an estimate on a draft).
   2: totals over every receipt of the filter (all pages): ReceivedNotInvoicedBase / ReceivedNotInvoicedValueBase (at
      the order price, for month-end; manual lines at their cost at receipt), ReceiptCount, DraftCount. */
CREATE OR ALTER PROCEDURE purchase.usp_GoodsReceipt_Search
    @Search               NVARCHAR(100) = NULL,
    @Status               TINYINT       = NULL,     -- 1 Draft | 2 Posted | 3 Cancelled
    @SourceKind           NVARCHAR(10)  = NULL,     -- Container | Order | Invoice | Manual
    @BranchId             INT           = NULL,
    @SupplierId           INT           = NULL,
    @WarehouseId          INT           = NULL,
    @DateFrom             DATE          = NULL,
    @DateTo               DATE          = NULL,
    @ContainerId          INT           = NULL,
    @PurchaseOrderId      INT           = NULL,
    @InvoiceId            INT           = NULL,
    @MovementId           INT           = NULL,
    @IsAuto               BIT           = NULL,
    @WithDifferences      BIT           = 0,
    @ReceivedNotInvoiced  BIT           = 0,
    @DeliveredNotReceived BIT           = 0,
    @NotReceived          BIT           = 0,
    @SortColumn           NVARCHAR(30)  = N'DocumentDate',
    @SortDirection        NVARCHAR(4)   = N'DESC',
    @PageNumber           INT           = 1,
    @PageSize             INT           = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @SourceKind = NULLIF(LTRIM(RTRIM(@SourceKind)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'DocumentNumber', N'DocumentDate', N'SupplierName', N'Status', N'ReceivedBase',
                                                  N'ValueBase', N'CreatedAtUtc', N'PostedAtUtc')
        SET @SortColumn = N'DocumentDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);
    SELECT @WithDifferences = ISNULL(@WithDifferences, 0), @ReceivedNotInvoiced = ISNULL(@ReceivedNotInvoiced, 0),
           @DeliveredNotReceived = ISNULL(@DeliveredNotReceived, 0), @NotReceived = ISNULL(@NotReceived, 0);

    -- the filter once; the page and the totals read it
    DECLARE @Ids TABLE (Id INT NOT NULL PRIMARY KEY);
    INSERT INTO @Ids (Id)
    SELECT g.Id
    FROM purchase.GoodsReceipts g
    LEFT JOIN logistics.Containers c         ON c.Id = g.ContainerId
    LEFT JOIN purchase.PurchaseDocuments po  ON po.Id = g.PurchaseOrderId
    LEFT JOIN purchase.PurchaseDocuments pi  ON pi.Id = g.PurchaseInvoiceId
    LEFT JOIN masterdata.Parties sp          ON sp.Id = g.SupplierId
    LEFT JOIN logistics.Movements mv         ON mv.Id = g.MovementId
    WHERE (@Status IS NULL OR g.Status = @Status)
      AND (@SourceKind IS NULL OR g.SourceKind = @SourceKind)
      AND (@BranchId IS NULL OR g.BranchId = @BranchId)
      AND (@DateFrom IS NULL OR g.DocumentDate >= @DateFrom)
      AND (@DateTo IS NULL OR g.DocumentDate <= @DateTo)
      AND (@ContainerId IS NULL OR g.ContainerId = @ContainerId)
      AND (@MovementId IS NULL OR g.MovementId = @MovementId)
      AND (@IsAuto IS NULL OR g.IsAuto = @IsAuto)
      AND (@SupplierId IS NULL OR g.SupplierId = @SupplierId
           OR EXISTS (SELECT 1 FROM purchase.GoodsReceiptLines l WHERE l.GoodsReceiptId = g.Id AND l.SupplierId = @SupplierId))
      AND (@WarehouseId IS NULL OR g.WarehouseId = @WarehouseId
           OR EXISTS (SELECT 1 FROM purchase.GoodsReceiptLines l WHERE l.GoodsReceiptId = g.Id AND l.WarehouseId = @WarehouseId))
      AND (@PurchaseOrderId IS NULL OR g.PurchaseOrderId = @PurchaseOrderId
           OR EXISTS (SELECT 1 FROM purchase.GoodsReceiptLines l WHERE l.GoodsReceiptId = g.Id AND l.PurchaseOrderId = @PurchaseOrderId))
      AND (@InvoiceId IS NULL OR g.PurchaseInvoiceId = @InvoiceId
           OR EXISTS (SELECT 1 FROM purchase.GoodsReceiptLines l
                      INNER JOIN purchase.GoodsReceiptInvoiceMatches m ON m.GoodsReceiptLineId = l.Id
                      INNER JOIN purchase.PurchaseDocumentLines pil    ON pil.Id = m.InvoiceLineId AND pil.DocumentId = @InvoiceId
                      WHERE l.GoodsReceiptId = g.Id))
      AND (@WithDifferences = 0
           OR EXISTS (SELECT 1 FROM purchase.GoodsReceiptLines l
                      WHERE l.GoodsReceiptId = g.Id
                        AND ((l.ContainerLineId IS NOT NULL AND l.QuantityBase <> ISNULL(l.ExpectedQuantityBase, l.QuantityBase))
                             OR l.CloseShort = 1 OR l.SettledShortBase > 0 OR l.VarianceReasonCode IS NOT NULL)))
      AND (@ReceivedNotInvoiced = 0
           OR (g.Status = 2 AND EXISTS (SELECT 1 FROM purchase.GoodsReceiptLines l WHERE l.GoodsReceiptId = g.Id AND l.QuantityBase > l.InvoicedBase)))
      AND (@DeliveredNotReceived = 0
           OR (g.Status = 1 AND g.SourceKind = N'Container' AND EXISTS (SELECT 1 FROM logistics.fn_Container_LastDelivery(g.ContainerId))))
      AND (@NotReceived = 0 OR g.Status = 1)
      AND (@Search IS NULL
           OR g.DocumentNumber LIKE N'%' + @Search + N'%' OR g.SupplierReference LIKE N'%' + @Search + N'%'
           OR c.ContainerRef LIKE N'%' + @Search + N'%' OR c.ContainerNo LIKE N'%' + @Search + N'%'
           OR po.DocumentNumber LIKE N'%' + @Search + N'%' OR pi.DocumentNumber LIKE N'%' + @Search + N'%'
           OR mv.MovementNo LIKE N'%' + @Search + N'%'
           OR sp.PartyCode LIKE N'%' + @Search + N'%' OR sp.PartyName LIKE N'%' + @Search + N'%'
           OR EXISTS (SELECT 1 FROM purchase.GoodsReceiptLines l
                      INNER JOIN inventory.Items i               ON i.Id = l.ItemId
                      LEFT  JOIN purchase.PurchaseDocuments lpo  ON lpo.Id = l.PurchaseOrderId
                      LEFT  JOIN purchase.PurchaseDocumentLines lil ON lil.Id = l.InvoiceLineId
                      LEFT  JOIN purchase.PurchaseDocuments lpi  ON lpi.Id = lil.DocumentId
                      WHERE l.GoodsReceiptId = g.Id
                        AND (i.ItemCode LIKE N'%' + @Search + N'%' OR lpo.DocumentNumber LIKE N'%' + @Search + N'%'
                             OR lpi.DocumentNumber LIKE N'%' + @Search + N'%')));

    -- 1: the page
    SELECT g.Id, g.DocumentNumber, g.DocumentDate, g.Status,
           StatusName = CASE g.Status WHEN 1 THEN N'Draft' WHEN 2 THEN N'Posted' ELSE N'Cancelled' END,
           g.SourceKind, g.IsAuto,
           g.BranchId, b.BranchCode, b.BranchName,
           g.WarehouseId, w.WarehouseCode, w.WarehouseName,
           g.SupplierId, sp.PartyCode AS SupplierCode,
           SupplierName = ISNULL(sp.PartyName, CASE WHEN g.SourceKind = N'Container' THEN N'Several suppliers' END),
           g.ContainerId, c.ContainerRef, c.ContainerNo,
           g.PurchaseOrderId, po.DocumentNumber AS PurchaseOrderNumber,
           g.PurchaseInvoiceId, pi.DocumentNumber AS PurchaseInvoiceNumber,
           g.MovementId, mv.MovementNo, g.SupplierReference,
           LineCount = ISNULL(t.Lines, 0), ExpectedBase = g.TotalExpectedBase, ReceivedBase = g.TotalReceivedBase,
           ShortBase = ISNULL(CASE WHEN g.Status = 1 THEN t.ShortDraft ELSE t.Settled END, 0), InvoicedBase = ISNULL(t.Invoiced, 0),
           ValueBase = ISNULL(v.Value, 0), IsValueEstimate = CAST(CASE WHEN g.Status = 1 THEN 1 ELSE 0 END AS BIT),
           g.PostedAtUtc, pu.FullName AS PostedByName, g.CreatedAtUtc, cu.FullName AS CreatedByName, g.UpdatedAtUtc,
           g.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM @Ids x
    INNER JOIN purchase.GoodsReceipts g       ON g.Id = x.Id
    INNER JOIN masterdata.Branches b          ON b.Id = g.BranchId
    LEFT  JOIN masterdata.Warehouses w        ON w.Id = g.WarehouseId
    LEFT  JOIN masterdata.Parties sp          ON sp.Id = g.SupplierId
    LEFT  JOIN logistics.Containers c         ON c.Id = g.ContainerId
    LEFT  JOIN purchase.PurchaseDocuments po  ON po.Id = g.PurchaseOrderId
    LEFT  JOIN purchase.PurchaseDocuments pi  ON pi.Id = g.PurchaseInvoiceId
    LEFT  JOIN logistics.Movements mv         ON mv.Id = g.MovementId
    LEFT  JOIN security.Users pu              ON pu.Id = g.PostedBy
    LEFT  JOIN security.Users cu              ON cu.Id = g.CreatedBy
    OUTER APPLY (SELECT Lines = COUNT(*), Invoiced = SUM(l.InvoicedBase),
                        Settled = SUM(l.SettledShortBase),
                        ShortDraft = SUM(CASE WHEN (l.ContainerLineId IS NOT NULL OR l.CloseShort = 1) AND l.ExpectedQuantityBase > l.QuantityBase
                                              THEN l.ExpectedQuantityBase - l.QuantityBase ELSE 0 END)
                 FROM purchase.GoodsReceiptLines l WHERE l.GoodsReceiptId = g.Id) t
    OUTER APPLY (SELECT Value = SUM(k.ValueBase) FROM purchase.fn_GoodsReceiptLine_Cost(g.Id) k) v
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN g.DocumentNumber WHEN N'SupplierName' THEN ISNULL(sp.PartyName, N'') END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN g.DocumentNumber WHEN N'SupplierName' THEN ISNULL(sp.PartyName, N'') END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'DocumentDate' THEN g.DocumentDate END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'DocumentDate' THEN g.DocumentDate END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Status' THEN CAST(g.Status AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Status' THEN CAST(g.Status AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'ReceivedBase' THEN g.TotalReceivedBase END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'ReceivedBase' THEN g.TotalReceivedBase END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'ValueBase' THEN v.Value END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'ValueBase' THEN v.Value END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN g.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN g.CreatedAtUtc END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'PostedAtUtc' THEN g.PostedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'PostedAtUtc' THEN g.PostedAtUtc END DESC,
        g.DocumentDate DESC, g.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;

    -- 2: totals over the whole filter: received and not invoiced yet, at the order price (month-end)
    SELECT ReceivedNotInvoicedBase = ISNULL(SUM(CASE WHEN g.Status = 2 AND l.QuantityBase > l.InvoicedBase
                                                     THEN l.QuantityBase - l.InvoicedBase END), 0),
           ReceivedNotInvoicedValueBase = CAST(ISNULL(SUM(CASE WHEN g.Status = 2 AND l.QuantityBase > l.InvoicedBase
                                                               THEN (l.QuantityBase - l.InvoicedBase)
                                                                    * COALESCE(l.PoFobBase, pol.LineTotal / NULLIF(po.ExchangeRate, 0) / NULLIF(pol.QuantityBase, 0),
                                                                               l.CostAtReceiptBase, 0) END), 0) AS DECIMAL(18,2)),
           ReceiptCount = (SELECT COUNT(*) FROM @Ids),
           DraftCount   = (SELECT COUNT(*) FROM @Ids i INNER JOIN purchase.GoodsReceipts d ON d.Id = i.Id AND d.Status = 1)
    FROM @Ids x
    INNER JOIN purchase.GoodsReceipts g           ON g.Id = x.Id
    INNER JOIN purchase.GoodsReceiptLines l       ON l.GoodsReceiptId = g.Id
    LEFT  JOIN purchase.PurchaseDocumentLines pol ON pol.Id = l.PoLineId
    LEFT  JOIN purchase.PurchaseDocuments po      ON po.Id = pol.DocumentId;
END
GO

/* ================================================================== 20. The menu count */

-- THE DRAFT GOODS RECEIPTS, for the menu count (hidden at 0) and its tooltip: how many, how many made by a Delivery,
-- how many still without a warehouse, the oldest. Goods receipts are not limited by branch, so every viewer sees the
-- same count; @UserId is kept for when they are.
CREATE OR ALTER PROCEDURE purchase.usp_GoodsReceipt_WaitingCount
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT DraftCount            = COUNT(*),
           AutoDraftCount        = ISNULL(SUM(CASE WHEN g.IsAuto = 1 THEN 1 ELSE 0 END), 0),
           WithoutWarehouseCount = ISNULL(SUM(CASE WHEN g.SourceKind = N'Container' AND g.WarehouseId IS NULL THEN 1 ELSE 0 END), 0),
           OldestDraftDate       = MIN(g.DocumentDate),
           OldestCreatedAtUtc    = MIN(g.CreatedAtUtc)
    FROM purchase.GoodsReceipts g
    WHERE g.Status = 1;
END
GO

/* ================================================================== 21. Files */

-- The goods receipt's files, in the shape of the purchase documents' (scripts 52 and 55): a type used for goods
-- receipts (63012 through usp_AttachmentType_CheckForKind), a document date, a note. A delivery note or a damage
-- report may come after the posting, so every status takes files, as the purchase documents do.
CREATE OR ALTER PROCEDURE purchase.usp_GoodsReceipt_File_Add
    @GoodsReceiptId   INT,
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
    IF NOT EXISTS (SELECT 1 FROM purchase.GoodsReceipts WHERE Id = @GoodsReceiptId) THROW 63006, 'Goods receipt not found.', 1;
    IF @FileName IS NULL OR LTRIM(RTRIM(@FileName)) = N'' THROW 63000, 'File name is required.', 1;
    IF @Content IS NULL OR @SizeBytes IS NULL OR @SizeBytes <= 0 THROW 63000, 'The file is empty.', 1;
    EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, N'GRN', 63012;

    BEGIN TRY
        BEGIN TRANSACTION;
        INSERT INTO purchase.GoodsReceiptFiles (GoodsReceiptId, AttachmentTypeId, DocumentDate, Note, FileName, ContentType, SizeBytes, Content, CreatedBy)
        VALUES (@GoodsReceiptId, @AttachmentTypeId, @DocumentDate, NULLIF(LTRIM(RTRIM(@Note)), N''), LTRIM(RTRIM(@FileName)),
                ISNULL(NULLIF(LTRIM(RTRIM(@ContentType)), N''), N'application/octet-stream'), @SizeBytes, @Content, @UserId);
        SET @NewId = SCOPE_IDENTITY();
        INSERT INTO purchase.GoodsReceiptAudit (GoodsReceiptId, Action, Details, UserId)
        VALUES (@GoodsReceiptId, N'FileAdded', LEFT(LTRIM(RTRIM(@FileName)), 500), @UserId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- The files of a receipt (one with @FileId), newest first; IsOther = still typed "Other".
CREATE OR ALTER PROCEDURE purchase.usp_GoodsReceipt_File_List
    @GoodsReceiptId INT, @AttachmentTypeId INT = NULL, @FileId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT f.Id, f.GoodsReceiptId AS DocumentId, f.FileName, f.ContentType, f.SizeBytes, f.AttachmentTypeId, t.Category, t.SubType,
           IsOther = CAST(CASE WHEN t.SubType = N'Other' AND t.Category IN (N'Other', N'General') THEN 1 ELSE 0 END AS BIT),
           f.DocumentDate, f.Note, f.CreatedAtUtc, f.CreatedBy, u.FullName AS CreatedByName
    FROM purchase.GoodsReceiptFiles f
    LEFT JOIN masterdata.AttachmentTypes t ON t.Id = f.AttachmentTypeId
    LEFT JOIN security.Users u             ON u.Id = f.CreatedBy
    WHERE f.GoodsReceiptId = @GoodsReceiptId
      AND (@AttachmentTypeId IS NULL OR f.AttachmentTypeId = @AttachmentTypeId)
      AND (@FileId IS NULL OR f.Id = @FileId)
    ORDER BY f.CreatedAtUtc DESC, f.Id DESC;
END
GO

-- One file with its content (the download).
CREATE OR ALTER PROCEDURE purchase.usp_GoodsReceipt_File_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, GoodsReceiptId AS DocumentId, FileName, ContentType, SizeBytes, Content, CreatedAtUtc
    FROM purchase.GoodsReceiptFiles WHERE Id = @Id;
END
GO

-- Type, date and note of a file, and optionally a new name or content (the checks of the upload); answers the file's
-- row (usp_GoodsReceipt_File_List). A type the file already has may stay though deactivated since.
CREATE OR ALTER PROCEDURE purchase.usp_GoodsReceipt_File_Update
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
    DECLARE @ReceiptId INT, @Old NVARCHAR(255), @OldType INT;
    SELECT @ReceiptId = GoodsReceiptId, @Old = FileName, @OldType = AttachmentTypeId FROM purchase.GoodsReceiptFiles WHERE Id = @Id;
    IF @ReceiptId IS NULL THROW 63006, 'File not found.', 1;
    SET @FileName = ISNULL(NULLIF(LTRIM(RTRIM(@FileName)), N''), @Old);
    IF @AttachmentTypeId IS NULL OR @AttachmentTypeId <> ISNULL(@OldType, -1)
        EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, N'GRN', 63012;
    IF @Content IS NOT NULL AND (@SizeBytes IS NULL OR @SizeBytes <= 0) THROW 63000, 'The file is empty.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        UPDATE purchase.GoodsReceiptFiles
        SET AttachmentTypeId = @AttachmentTypeId, DocumentDate = @DocumentDate, Note = NULLIF(LTRIM(RTRIM(@Note)), N''),
            FileName    = @FileName,
            ContentType = CASE WHEN @Content IS NULL THEN ContentType ELSE ISNULL(NULLIF(LTRIM(RTRIM(@ContentType)), N''), N'application/octet-stream') END,
            SizeBytes   = CASE WHEN @Content IS NULL THEN SizeBytes ELSE @SizeBytes END,
            Content     = ISNULL(@Content, Content)
        WHERE Id = @Id;
        INSERT INTO purchase.GoodsReceiptAudit (GoodsReceiptId, Action, Details, UserId)
        VALUES (@ReceiptId, N'FileUpdated', LEFT(CASE WHEN @Old = @FileName THEN @FileName ELSE @Old + N' -> ' + @FileName END
                                                 + CASE WHEN @Content IS NOT NULL THEN N' (new file)' ELSE N'' END, 500), @UserId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    EXEC purchase.usp_GoodsReceipt_File_List @GoodsReceiptId = @ReceiptId, @FileId = @Id;
END
GO

CREATE OR ALTER PROCEDURE purchase.usp_GoodsReceipt_File_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @ReceiptId INT, @Name NVARCHAR(255);
    SELECT @ReceiptId = GoodsReceiptId, @Name = FileName FROM purchase.GoodsReceiptFiles WHERE Id = @Id;
    IF @ReceiptId IS NULL THROW 63006, 'File not found.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE FROM purchase.GoodsReceiptFiles WHERE Id = @Id;
        INSERT INTO purchase.GoodsReceiptAudit (GoodsReceiptId, Action, Details, UserId) VALUES (@ReceiptId, N'FileDeleted', LEFT(@Name, 500), @UserId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 22. Matching received pieces to invoiced pieces */

/* ONE MATCHER AT A TIME, AND TAKEN FIRST. Every procedure that rematches or trues up the cost of received goods - goods
   receipt Post and Cancel, supplier invoice and return Post and Cancel, landed cost adjustment Post and Cancel - calls
   this as its FIRST statement after BEGIN TRANSACTION, before any row lock or write. Lock order: the matcher first,
   then rows, or two postings deadlock - taken later (as usp_GoodsReceipt_Rematch takes it, after its caller locked and
   wrote its own rows), one posting holds the lock and waits to read rows the other wrote, while the other holds those
   rows and waits for the lock, even for unrelated suppliers and items. Held until the caller's transaction ends, and
   re-entrant: Rematch and TrueUpCost take it again and go straight through, so a caller that forgets the early call
   still gets one matcher at a time. */
CREATE OR ALTER PROCEDURE purchase.usp_GoodsReceipt_LockMatching
AS
BEGIN
    SET NOCOUNT ON;

    IF @@TRANCOUNT = 0
        THROW 63010, 'The goods receipt matching lock is taken inside a transaction.', 1;

    DECLARE @Lock INT;
    EXEC @Lock = sp_getapplock @Resource = N'purchase.GoodsReceiptMatching', @LockMode = N'Exclusive',
                               @LockOwner = N'Transaction', @LockTimeout = 60000;
    IF @Lock < 0
        THROW 63010, 'Goods receipts and invoices are being matched for another user. Try again in a moment.', 1;
END
GO

/* REBUILDS THE MATCHES OF THE GROUPS FROM NOTHING. Receipt side = the lines of POSTED goods receipts; invoice side =
   the lines of POSTED or CLOSED supplier invoices (PINV), except those that received their own goods before goods
   receipts: an invoice posted with stock (UsesGoodsReceipts = 0, ReceiptMode 1) and the lines of a container offloaded
   the old way (fn_Container_ReceivedBy = 'Offload'). Passes, each taking only what the earlier ones left, first in
   first out by ISNULL(PostedAtUtc, CreatedAtUtc), Id on both sides:
     0  a receipt line made from an invoice line (InvoiceLineId) takes that invoice line first
     1  container line X: receipt lines of X - invoice lines linked to X
     2  order line Y: receipt lines of Y (any container or none) - invoice lines of Y (linked or not)
     3  supplier S + item I without an order: manual and invoice receipt lines - invoice lines without an order
   Afterwards: GoodsReceiptLines.InvoicedBase and CostSource, and the invoice lines' ReceivedQuantityBase (= the pieces
   matched to them) for the invoices goods receipts receive. Costs are NOT changed here: the caller trues them up
   (usp_GoodsReceipt_TrueUpCost on fn_GoodsReceipt_GroupLines). No result set unless @ReturnLines = 1 (the posted
   receipt lines of the groups), so a caller's own result (DocumentNumber) stays the first one.
   ONE MATCHER AT A TIME: an application lock held until the caller's transaction ends, because two postings of the
   same group would otherwise both rebuild from what they read (usp_GoodsReceipt_LockMatching; the callers take it
   first, before their own rows). Each side reads the rows of the groups only - an order line by its index, a supplier
   + item by theirs - never the other groups' rows, which other users may be writing. */
CREATE OR ALTER PROCEDURE purchase.usp_GoodsReceipt_Rematch
    @Anchors     purchase.tvp_GoodsReceiptAnchor READONLY,
    @ReturnLines BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC purchase.usp_GoodsReceipt_LockMatching;

        DECLARE @G TABLE (GroupKey NVARCHAR(40) NOT NULL PRIMARY KEY, PoLineId INT NULL, SupplierId INT NULL, ItemId INT NULL);
        INSERT INTO @G (GroupKey, PoLineId, SupplierId, ItemId)
        SELECT N'P' + CAST(a.PoLineId AS NVARCHAR(12)), a.PoLineId, NULL, NULL
        FROM @Anchors a WHERE a.Kind = 'P' AND a.PoLineId IS NOT NULL
        UNION
        SELECT N'S' + CAST(a.SupplierId AS NVARCHAR(12)) + N'.' + CAST(a.ItemId AS NVARCHAR(12)), NULL, a.SupplierId, a.ItemId
        FROM @Anchors a WHERE a.Kind = 'S' AND a.SupplierId IS NOT NULL AND a.ItemId IS NOT NULL;

        -- every receipt line of the groups, whatever its status: a cancelled receipt loses its matches here.
        -- Rem = what it can still take (posted receipts only).
        DECLARE @R TABLE (LineId INT NOT NULL PRIMARY KEY, GroupKey NVARCHAR(40) NOT NULL, Posted BIT NOT NULL,
                          InvoiceLineId INT NULL, ContainerLineId INT NULL, PoLineId INT NULL, T DATETIME2(3) NOT NULL,
                          Qty INT NOT NULL, Rem INT NOT NULL);
        -- (the two kinds of group apart, one statement each, so each seeks its own index - an order line's filtered
        -- index needs its IS NOT NULL said - and reads the groups' rows only: an OR join read every receipt line, and
        -- waited on rows other users were writing)
        INSERT INTO @R (LineId, GroupKey, Posted, InvoiceLineId, ContainerLineId, PoLineId, T, Qty, Rem)
        SELECT gl.Id, gk.GroupKey, CASE WHEN g.Status = 2 THEN 1 ELSE 0 END, gl.InvoiceLineId, gl.ContainerLineId, gl.PoLineId,
               ISNULL(g.PostedAtUtc, g.CreatedAtUtc), gl.QuantityBase,
               CASE WHEN g.Status = 2 THEN gl.QuantityBase ELSE 0 END
        FROM @G gk
        INNER JOIN purchase.GoodsReceiptLines gl ON gl.PoLineId = gk.PoLineId AND gl.PoLineId IS NOT NULL
        INNER JOIN purchase.GoodsReceipts g      ON g.Id = gl.GoodsReceiptId
        WHERE gk.PoLineId IS NOT NULL;

        INSERT INTO @R (LineId, GroupKey, Posted, InvoiceLineId, ContainerLineId, PoLineId, T, Qty, Rem)
        SELECT gl.Id, gk.GroupKey, CASE WHEN g.Status = 2 THEN 1 ELSE 0 END, gl.InvoiceLineId, gl.ContainerLineId, gl.PoLineId,
               ISNULL(g.PostedAtUtc, g.CreatedAtUtc), gl.QuantityBase,
               CASE WHEN g.Status = 2 THEN gl.QuantityBase ELSE 0 END
        FROM @G gk
        INNER JOIN purchase.GoodsReceiptLines gl ON gl.SupplierId = gk.SupplierId AND gl.ItemId = gk.ItemId AND gl.PoLineId IS NULL
        INNER JOIN purchase.GoodsReceipts g      ON g.Id = gl.GoodsReceiptId
        WHERE gk.PoLineId IS NULL;

        -- every supplier invoice line of the groups. Eligible = goods receipts receive its goods (its matches and its
        -- ReceivedQuantityBase are this procedure's); Rem = what it can still pay for (posted or closed, eligible).
        DECLARE @I TABLE (LineId INT NOT NULL PRIMARY KEY, GroupKey NVARCHAR(40) NOT NULL, Eligible BIT NOT NULL,
                          ContainerLineId INT NULL, T DATETIME2(3) NOT NULL, Rem INT NOT NULL);
        -- (the lines of the groups first, one statement per kind of group, as for the receipt lines)
        DECLARE @IL TABLE (LineId INT NOT NULL PRIMARY KEY, GroupKey NVARCHAR(40) NOT NULL);
        INSERT INTO @IL (LineId, GroupKey)
        SELECT l.Id, gk.GroupKey
        FROM @G gk
        INNER JOIN purchase.PurchaseDocumentLines l ON l.SourceLineId = gk.PoLineId AND l.SourceLineId IS NOT NULL
        WHERE gk.PoLineId IS NOT NULL;

        INSERT INTO @IL (LineId, GroupKey)
        SELECT l.Id, gk.GroupKey
        FROM @G gk
        INNER JOIN purchase.PurchaseDocumentLines l ON l.ItemId = gk.ItemId AND l.SourceLineId IS NULL
        INNER JOIN purchase.PurchaseDocuments d     ON d.Id = l.DocumentId AND d.SupplierId = gk.SupplierId
        WHERE gk.PoLineId IS NULL;

        INSERT INTO @I (LineId, GroupKey, Eligible, ContainerLineId, T, Rem)
        SELECT l.Id, x.GroupKey, e.Eligible, l.ContainerLineId, ISNULL(d.PostedAtUtc, d.CreatedAtUtc),
               CASE WHEN e.Eligible = 1 AND d.Status IN (2, 4) THEN l.QuantityBase ELSE 0 END
        FROM @IL x
        INNER JOIN purchase.PurchaseDocumentLines l ON l.Id = x.LineId
        INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
        INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId AND dt.Code = N'PINV'
        LEFT  JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
        OUTER APPLY logistics.fn_Container_ReceivedBy(cl.ContainerId) rb
        CROSS APPLY (SELECT Eligible = CAST(CASE WHEN d.UsesGoodsReceipts = 0 AND d.ReceiptMode = 1 THEN 0
                                                 WHEN rb.ReceivedBy = N'Offload' THEN 0
                                                 ELSE 1 END AS BIT)) e;

        DECLARE @M    TABLE (RLineId INT NOT NULL, ILineId INT NOT NULL, Qty INT NOT NULL);
        DECLARE @Pass TABLE (RLineId INT NOT NULL, ILineId INT NOT NULL, Qty INT NOT NULL);

        -- Each pass pairs the two sides of one key first in first out: the running totals give each line an interval
        -- [E - Rem, E) of the key's pieces, and a receipt line and an invoice line share the overlap of their intervals.

        -- pass 0: the invoice line the receipt was made from
        WITH r AS (SELECT LineId, K = InvoiceLineId, Rem,
                          E = SUM(Rem) OVER (PARTITION BY InvoiceLineId ORDER BY T, LineId ROWS UNBOUNDED PRECEDING)
                   FROM @R WHERE Rem > 0 AND InvoiceLineId IS NOT NULL),
             i AS (SELECT LineId, K = LineId, Rem, E = Rem FROM @I WHERE Rem > 0)
        INSERT INTO @Pass (RLineId, ILineId, Qty)
        SELECT r.LineId, i.LineId,
               (CASE WHEN r.E < i.E THEN r.E ELSE i.E END) - (CASE WHEN r.E - r.Rem > i.E - i.Rem THEN r.E - r.Rem ELSE i.E - i.Rem END)
        FROM r INNER JOIN i ON i.K = r.K
        WHERE r.E - r.Rem < i.E AND i.E - i.Rem < r.E;

        UPDATE r SET Rem = r.Rem - p.Qty FROM @R r INNER JOIN (SELECT RLineId, Qty = SUM(Qty) FROM @Pass GROUP BY RLineId) p ON p.RLineId = r.LineId;
        UPDATE i SET Rem = i.Rem - p.Qty FROM @I i INNER JOIN (SELECT ILineId, Qty = SUM(Qty) FROM @Pass GROUP BY ILineId) p ON p.ILineId = i.LineId;
        INSERT INTO @M (RLineId, ILineId, Qty) SELECT RLineId, ILineId, Qty FROM @Pass;
        DELETE FROM @Pass;

        -- pass 1: the container line
        WITH r AS (SELECT LineId, K = ContainerLineId, Rem,
                          E = SUM(Rem) OVER (PARTITION BY ContainerLineId ORDER BY T, LineId ROWS UNBOUNDED PRECEDING)
                   FROM @R WHERE Rem > 0 AND ContainerLineId IS NOT NULL),
             i AS (SELECT LineId, K = ContainerLineId, Rem,
                          E = SUM(Rem) OVER (PARTITION BY ContainerLineId ORDER BY T, LineId ROWS UNBOUNDED PRECEDING)
                   FROM @I WHERE Rem > 0 AND ContainerLineId IS NOT NULL)
        INSERT INTO @Pass (RLineId, ILineId, Qty)
        SELECT r.LineId, i.LineId,
               (CASE WHEN r.E < i.E THEN r.E ELSE i.E END) - (CASE WHEN r.E - r.Rem > i.E - i.Rem THEN r.E - r.Rem ELSE i.E - i.Rem END)
        FROM r INNER JOIN i ON i.K = r.K
        WHERE r.E - r.Rem < i.E AND i.E - i.Rem < r.E;

        UPDATE r SET Rem = r.Rem - p.Qty FROM @R r INNER JOIN (SELECT RLineId, Qty = SUM(Qty) FROM @Pass GROUP BY RLineId) p ON p.RLineId = r.LineId;
        UPDATE i SET Rem = i.Rem - p.Qty FROM @I i INNER JOIN (SELECT ILineId, Qty = SUM(Qty) FROM @Pass GROUP BY ILineId) p ON p.ILineId = i.LineId;
        INSERT INTO @M (RLineId, ILineId, Qty) SELECT RLineId, ILineId, Qty FROM @Pass;
        DELETE FROM @Pass;

        -- passes 2 and 3: the group itself (the order line, or the supplier + item)
        WITH r AS (SELECT LineId, K = GroupKey, Rem,
                          E = SUM(Rem) OVER (PARTITION BY GroupKey ORDER BY T, LineId ROWS UNBOUNDED PRECEDING)
                   FROM @R WHERE Rem > 0),
             i AS (SELECT LineId, K = GroupKey, Rem,
                          E = SUM(Rem) OVER (PARTITION BY GroupKey ORDER BY T, LineId ROWS UNBOUNDED PRECEDING)
                   FROM @I WHERE Rem > 0)
        INSERT INTO @Pass (RLineId, ILineId, Qty)
        SELECT r.LineId, i.LineId,
               (CASE WHEN r.E < i.E THEN r.E ELSE i.E END) - (CASE WHEN r.E - r.Rem > i.E - i.Rem THEN r.E - r.Rem ELSE i.E - i.Rem END)
        FROM r INNER JOIN i ON i.K = r.K
        WHERE r.E - r.Rem < i.E AND i.E - i.Rem < r.E;

        INSERT INTO @M (RLineId, ILineId, Qty) SELECT RLineId, ILineId, Qty FROM @Pass;

        DECLARE @New TABLE (RLineId INT NOT NULL, ILineId INT NOT NULL, Qty INT NOT NULL, PRIMARY KEY (RLineId, ILineId));
        INSERT INTO @New (RLineId, ILineId, Qty)
        SELECT RLineId, ILineId, SUM(Qty) FROM @M GROUP BY RLineId, ILineId HAVING SUM(Qty) > 0;

        -- the matches of the groups become @New; an unchanged pair keeps its MatchedAtUtc
        DELETE m
        FROM purchase.GoodsReceiptInvoiceMatches m
        WHERE (EXISTS (SELECT 1 FROM @R r WHERE r.LineId = m.GoodsReceiptLineId) OR EXISTS (SELECT 1 FROM @I i WHERE i.LineId = m.InvoiceLineId))
          AND NOT EXISTS (SELECT 1 FROM @New n WHERE n.RLineId = m.GoodsReceiptLineId AND n.ILineId = m.InvoiceLineId);

        UPDATE m SET QuantityBase = n.Qty, MatchedAtUtc = SYSUTCDATETIME()
        FROM purchase.GoodsReceiptInvoiceMatches m
        INNER JOIN @New n ON n.RLineId = m.GoodsReceiptLineId AND n.ILineId = m.InvoiceLineId
        WHERE m.QuantityBase <> n.Qty;

        INSERT INTO purchase.GoodsReceiptInvoiceMatches (GoodsReceiptLineId, InvoiceLineId, QuantityBase)
        SELECT n.RLineId, n.ILineId, n.Qty
        FROM @New n
        WHERE NOT EXISTS (SELECT 1 FROM purchase.GoodsReceiptInvoiceMatches m WHERE m.GoodsReceiptLineId = n.RLineId AND m.InvoiceLineId = n.ILineId);

        -- receipt lines: pieces invoiced, and where their cost comes from (posted lines)
        UPDATE gl
        SET InvoicedBase = x.Qty,
            CostSource = CASE WHEN r.Posted = 0 THEN gl.CostSource
                              WHEN gl.QuantityBase > 0 AND x.Qty >= gl.QuantityBase THEN N'Invoice'
                              WHEN gl.PoLineId IS NULL AND gl.InvoiceLineId IS NOT NULL THEN N'Invoice'   -- received at its invoice's cost
                              WHEN x.Qty > 0 THEN N'Mixed'
                              WHEN gl.PoLineId IS NOT NULL THEN N'Order'
                              ELSE N'Manual' END
        FROM purchase.GoodsReceiptLines gl
        INNER JOIN @R r ON r.LineId = gl.Id
        CROSS APPLY (SELECT Qty = ISNULL((SELECT SUM(n.Qty) FROM @New n WHERE n.RLineId = gl.Id), 0)) x;

        -- invoice lines that goods receipts receive: received = the pieces matched to them
        UPDATE l
        SET ReceivedQuantityBase = x.Qty
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN @I i ON i.LineId = l.Id AND i.Eligible = 1
        CROSS APPLY (SELECT Qty = ISNULL((SELECT SUM(n.Qty) FROM @New n WHERE n.ILineId = l.Id), 0)) x
        WHERE l.ReceivedQuantityBase <> x.Qty;

        COMMIT TRANSACTION;

        IF @ReturnLines = 1
            SELECT GoodsReceiptLineId = LineId FROM @R WHERE Posted = 1 ORDER BY LineId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 23. The cost of received goods follows the invoices */

/* BRINGS POSTED RECEIPT LINES TO THEIR TARGET COST (fn_GoodsReceiptLine_TargetCost), after anything that changed
   their matches or their invoices' cost: an invoice or an LCA posted or cancelled, a goods receipt posted or cancelled.
   Acts on the lines whose target FOB (container lines) or target landed cost (other lines) differs from the current
   one by 0.000001 or more.
     Amount     container line: ROUND((target FOB - cl.FobCostBase) x R, 2) - only the FOB moves, its charges are
                the container's (a matched local invoice's own charges ride on that FOB, see the target cost); other
                lines: ROUND((target landed - UnitCostBase) x R, 2)
     Split      per ITEM over the lines of this event: Remaining = min(sum of the lines' net received pieces, company
                stock on hand); the stock part = Amount x (1 - returned share) x Remaining / net received (cents left
                over by rounding on the line with the largest amount), the rest to cost of sales. No stock left: all to
                cost of sales. Company stock, not the warehouse's (unlike the container late charge and the LCA): the
                average is company-wide and transfers move goods out of the receiving warehouse. The RETURNED SHARE is
                for an LCA (or its cancel) only: it re-prices the pieces matched to the adjustment's invoice lines, and
                the returned ones among them are not in stock any more - their share goes to cost of sales, as the old
                LCA did (Allocated / Qty x Remaining). The other causes re-price only pieces whose match is new or
                removed, never returned ones (a return takes back matched pieces only).
     Records    one GoodsReceiptCostChanges row per line with an amount (its Id = CostAdjustments.SourceId), and
                inventory.CostAdjustments Inventory / COGS rows (SourceKind GRNCOST, SourceNumber = the GRN), dated
                at the later of now and the receipt's own ledger date, so that no replay puts it before its receipt.
                Compensating rows are written as they come (negative amounts included).
     Costs      container lines: cl.FobCostBase, then usp_Container_RecalcCosts; other lines: FobCostBase /
                ChargesBase / UnitCostBase / CostSource. Then usp_Item_RebuildCosts per item, as the late container
                charge does - also for the items of the posted MANUAL lines given ("Without an order"), adjusted or
                not: the caller's rematch may have matched or unmatched one at its typed cost, and such a line counts for
                the last cost, FOB cost and last supplier only once matched (rules 16, 24).
   Takes the matching lock (usp_GoodsReceipt_LockMatching): its callers already hold it, taken first.
   The totals come back in the OUTPUT parameters (no result set): for the invoice audit, the API message. */
CREATE OR ALTER PROCEDURE purchase.usp_GoodsReceipt_TrueUpCost
    @LineIds       logistics.tvp_IdList READONLY,     -- goods receipt line ids (other lines and unposted receipts are ignored)
    @CauseKind     NVARCHAR(12),                      -- PINV | PINVCANCEL | LCA | LCACANCEL | GRNPOST | GRNCANCEL
    @CauseId       INT           = NULL,              -- the invoice, LCA or goods receipt
    @CauseNumber   NVARCHAR(30)  = NULL,
    @UserId        INT           = NULL,
    @AmountBase    DECIMAL(18,2) = NULL OUTPUT,
    @InventoryBase DECIMAL(18,2) = NULL OUTPUT,
    @CogsBase      DECIMAL(18,2) = NULL OUTPUT,
    @LinesAdjusted INT           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SELECT @AmountBase = 0, @InventoryBase = 0, @CogsBase = 0, @LinesAdjusted = 0;
    IF @CauseKind IS NULL OR @CauseKind NOT IN (N'PINV', N'PINVCANCEL', N'LCA', N'LCACANCEL', N'GRNPOST', N'GRNCANCEL', N'NEGSTOCK')
        THROW 63000, 'Unknown cause of a goods receipt cost adjustment.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC purchase.usp_GoodsReceipt_LockMatching;

        DECLARE @W TABLE (LineId INT NOT NULL PRIMARY KEY, GoodsReceiptId INT NOT NULL, Number NVARCHAR(30) NOT NULL, ItemId INT NOT NULL,
                          WarehouseId INT NOT NULL, BranchId INT NOT NULL, ContainerLineId INT NULL, ContainerId INT NULL, IsContainer BIT NOT NULL,
                          R INT NOT NULL, RNet DECIMAL(18,6) NOT NULL,
                          FobBefore DECIMAL(18,6) NOT NULL, FobAfter DECIMAL(18,6) NOT NULL,
                          CostBefore DECIMAL(18,6) NOT NULL, CostAfter DECIMAL(18,6) NOT NULL, ChargesAfter DECIMAL(18,6) NOT NULL,
                          CostSource NVARCHAR(10) NULL,
                          Amount DECIMAL(18,2) NOT NULL DEFAULT (0), Inv DECIMAL(18,2) NOT NULL DEFAULT (0), InStock DECIMAL(18,6) NOT NULL DEFAULT (0),
                          RetShare DECIMAL(18,10) NOT NULL DEFAULT (0));

        INSERT INTO @W (LineId, GoodsReceiptId, Number, ItemId, WarehouseId, BranchId, ContainerLineId, ContainerId, IsContainer, R, RNet,
                        FobBefore, FobAfter, CostBefore, CostAfter, ChargesAfter, CostSource)
        SELECT t.GoodsReceiptLineId, t.GoodsReceiptId, g.DocumentNumber, t.ItemId, t.WarehouseId, w.BranchId, t.ContainerLineId, t.ContainerId,
               t.IsContainerLine, t.ReceivedBase, t.NetReceivedBase,
               t.CurrentFobBase, t.TargetFobBase, t.CurrentUnitCostBase, t.TargetUnitCostBase, t.TargetChargesBase, t.CostSource
        FROM (SELECT DISTINCT gl.GoodsReceiptId FROM @LineIds x INNER JOIN purchase.GoodsReceiptLines gl ON gl.Id = x.Id) r
        CROSS APPLY purchase.fn_GoodsReceiptLine_TargetCost(r.GoodsReceiptId) t
        INNER JOIN purchase.GoodsReceipts g    ON g.Id = t.GoodsReceiptId
        INNER JOIN masterdata.Warehouses w     ON w.Id = t.WarehouseId
        WHERE EXISTS (SELECT 1 FROM @LineIds x WHERE x.Id = t.GoodsReceiptLineId)
          AND t.CurrentFobBase IS NOT NULL AND t.CurrentUnitCostBase IS NOT NULL       -- set by every posting
          AND (ABS(t.TargetFobBase - t.CurrentFobBase) >= 0.000001
               OR (t.IsContainerLine = 0 AND ABS(t.TargetUnitCostBase - t.CurrentUnitCostBase) >= 0.000001));

        IF EXISTS (SELECT 1 FROM @W)
        BEGIN
            UPDATE @W SET Amount = ROUND(CASE WHEN IsContainer = 1 THEN FobAfter - FobBefore ELSE CostAfter - CostBefore END * R, 2);

            -- (LCA / LCACANCEL) THE RETURNED SHARE of what this event re-prices: the line's pieces matched to the
            -- adjustment's invoice lines, weighted by what the adjustment adds per piece of each, and of those the share
            -- returned from each invoice line (spread over its matches, as the net received is). Returned pieces are no
            -- longer in stock: that share goes to cost of sales whatever the stock, as the old LCA did. The adjustment's
            -- lines exist at both calls (Post inserts them first, Cancel keeps them). The other causes re-price only
            -- pieces whose match is new or removed, never a returned one.
            UPDATE w SET RetShare = ISNULL(x.Ret / NULLIF(x.Qty, 0), 0)
            FROM @W w
            CROSS APPLY (SELECT Qty = SUM(CAST(m.QuantityBase AS DECIMAL(18,6)) * ABS(a.ExtraPerBaseUnit)),
                                Ret = SUM(CAST(m.QuantityBase AS DECIMAL(18,6)) * ABS(a.ExtraPerBaseUnit)
                                          * CASE WHEN p.ReturnedQuantityBase < p.ReceivedQuantityBase THEN p.ReturnedQuantityBase
                                                 ELSE p.ReceivedQuantityBase END
                                          / NULLIF(p.ReceivedQuantityBase, 0))
                         FROM purchase.GoodsReceiptInvoiceMatches m
                         INNER JOIN purchase.PurchaseDocumentLines p     ON p.Id = m.InvoiceLineId
                         INNER JOIN purchase.LandedCostAdjustmentLines a ON a.PurchaseLineId = p.Id AND a.AdjustmentId = @CauseId
                         WHERE m.GoodsReceiptLineId = w.LineId) x
            WHERE @CauseKind IN (N'LCA', N'LCACANCEL');

            -- the part still in stock, per item for the whole event, on company stock
            DECLARE @Items TABLE (ItemId INT NOT NULL PRIMARY KEY, NetReceived DECIMAL(18,6) NOT NULL, OnHand DECIMAL(18,6) NOT NULL,
                                  Remaining DECIMAL(18,6) NULL, Amount DECIMAL(18,2) NOT NULL, Inv DECIMAL(18,2) NULL);
            INSERT INTO @Items (ItemId, NetReceived, OnHand, Amount)
            SELECT ItemId, SUM(CASE WHEN RNet > 0 THEN RNet ELSE 0 END), inventory.fn_StockOnHand(ItemId, NULL), SUM(Amount)
            FROM @W GROUP BY ItemId;

            UPDATE @Items SET Remaining = CASE WHEN OnHand <= 0 OR NetReceived <= 0 THEN 0
                                               WHEN OnHand < NetReceived THEN OnHand ELSE NetReceived END;

            -- the stock part of the amount that can still be in stock (all of it, but for the returned share above)
            UPDATE w
            SET Inv     = CASE WHEN i.Remaining = 0 THEN 0 ELSE ROUND(w.Amount * (1 - w.RetShare) * i.Remaining / i.NetReceived, 2) END,
                InStock = CASE WHEN i.Remaining = 0 OR w.RNet <= 0 THEN 0 ELSE w.RNet * i.Remaining / i.NetReceived END
            FROM @W w INNER JOIN @Items i ON i.ItemId = w.ItemId;

            UPDATE i
            SET Inv = CASE WHEN i.Remaining = 0 THEN 0 ELSE ROUND(x.Eligible * i.Remaining / i.NetReceived, 2) END
            FROM @Items i
            CROSS APPLY (SELECT Eligible = SUM(w.Amount * (1 - w.RetShare)) FROM @W w WHERE w.ItemId = i.ItemId) x;

            -- the cents lost by rounding the lines go to the line of the item with the largest amount
            WITH d AS (SELECT w.LineId, Diff = i.Inv - SUM(w.Inv) OVER (PARTITION BY w.ItemId),
                              Rn = ROW_NUMBER() OVER (PARTITION BY w.ItemId ORDER BY ABS(w.Amount) DESC, w.LineId)
                       FROM @W w INNER JOIN @Items i ON i.ItemId = w.ItemId)
            UPDATE w SET Inv = w.Inv + d.Diff
            FROM @W w INNER JOIN d ON d.LineId = w.LineId
            WHERE d.Rn = 1 AND d.Diff <> 0;

            DECLARE @Changes TABLE (ChangeId INT NOT NULL PRIMARY KEY, LineId INT NOT NULL);
            INSERT INTO purchase.GoodsReceiptCostChanges (GoodsReceiptLineId, CauseKind, CauseId, CauseNumber, ReceivedBase, InStockBase,
                                                          FobBefore, FobAfter, UnitCostBefore, UnitCostAfter, AmountBase, InventoryBase, CogsBase, CreatedBy)
            OUTPUT inserted.Id, inserted.GoodsReceiptLineId INTO @Changes (ChangeId, LineId)
            SELECT LineId, @CauseKind, @CauseId, @CauseNumber, R, InStock, FobBefore, FobAfter, CostBefore, CostAfter, Amount, Inv, Amount - Inv, @UserId
            FROM @W WHERE Amount <> 0;

            INSERT INTO inventory.CostAdjustments (AdjustmentDate, ItemId, WarehouseId, BranchId, Kind, AmountBase, SourceKind, SourceId, SourceNumber, PurchaseLineId, CreatedBy)
            SELECT CASE WHEN md.D > SYSUTCDATETIME() THEN md.D ELSE SYSUTCDATETIME() END,
                   w.ItemId, w.WarehouseId, w.BranchId, k.Kind, k.Amount, N'GRNCOST', c.ChangeId, w.Number, NULL, @UserId
            FROM @W w
            INNER JOIN @Changes c ON c.LineId = w.LineId
            OUTER APPLY (SELECT D = MAX(m.MovementDate) FROM inventory.StockMovements m
                         WHERE m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = N'GRN' AND m.DocumentId = w.GoodsReceiptId
                           AND m.IsReversal = 0) md
            CROSS APPLY (VALUES (N'Inventory', w.Inv), (N'COGS', w.Amount - w.Inv)) k (Kind, Amount)
            WHERE k.Amount <> 0;

            -- the new current cost: on the container line for container lines (its landed cost follows), else on the line
            UPDATE cl SET FobCostBase = w.FobAfter
            FROM logistics.ContainerLines cl INNER JOIN @W w ON w.ContainerLineId = cl.Id
            WHERE w.IsContainer = 1;

            UPDATE gl
            SET FobCostBase  = CASE WHEN w.IsContainer = 1 THEN gl.FobCostBase ELSE w.FobAfter END,
                ChargesBase  = CASE WHEN w.IsContainer = 1 THEN gl.ChargesBase ELSE w.ChargesAfter END,
                UnitCostBase = CASE WHEN w.IsContainer = 1 THEN gl.UnitCostBase ELSE w.CostAfter END,
                CostSource   = w.CostSource
            FROM purchase.GoodsReceiptLines gl INNER JOIN @W w ON w.LineId = gl.Id;

            DECLARE @ContainerId INT;
            DECLARE cts CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT ContainerId FROM @W WHERE IsContainer = 1;
            OPEN cts;
            FETCH NEXT FROM cts INTO @ContainerId;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC logistics.usp_Container_RecalcCosts @ContainerId;
                FETCH NEXT FROM cts INTO @ContainerId;
            END
            CLOSE cts;
            DEALLOCATE cts;

            INSERT INTO purchase.GoodsReceiptAudit (GoodsReceiptId, Action, Details, UserId)
            SELECT w.GoodsReceiptId, N'CostAdjusted',
                   LEFT(N'Cost adjusted by ' + ISNULL(@CauseNumber + N' ', N'')
                        + N'(' + CASE @CauseKind WHEN N'PINV' THEN N'invoice posted'
                                                 WHEN N'PINVCANCEL' THEN N'invoice cancelled'
                                                 WHEN N'LCA' THEN N'landed cost adjustment posted'
                                                 WHEN N'LCACANCEL' THEN N'landed cost adjustment cancelled'
                                                 WHEN N'GRNPOST' THEN N'goods receipt posted'
                                                 WHEN N'GRNCANCEL' THEN N'goods receipt cancelled'
                                                 ELSE N'negative stock filled' END
                        + N'): ' + CAST(SUM(w.Amount) AS NVARCHAR(30)) + N' (stock ' + CAST(SUM(w.Inv) AS NVARCHAR(30))
                        + N', cost of sales ' + CAST(SUM(w.Amount - w.Inv) AS NVARCHAR(30)) + N')', 500),
                   @UserId
            FROM @W w
            GROUP BY w.GoodsReceiptId
            HAVING SUM(CASE WHEN w.Amount <> 0 THEN 1 ELSE 0 END) > 0;

            SELECT @AmountBase = ISNULL(SUM(Amount), 0), @InventoryBase = ISNULL(SUM(Inv), 0), @CogsBase = ISNULL(SUM(Amount - Inv), 0),
                   @LinesAdjusted = SUM(CASE WHEN Amount <> 0 THEN 1 ELSE 0 END)
            FROM @W;
        END

        -- ITEM COSTS REPLAYED: the items of the adjusted lines, and those of the posted MANUAL lines given, adjusted or
        -- not. The caller's rematch can match or unmatch a manual line without changing its cost (an invoice at the
        -- typed price), and such a line counts for the last cost, FOB cost and last supplier only once matched (rules
        -- 16, 24): its item is replayed either way. (@Items is empty when nothing was adjusted.)
        DECLARE @ItemId INT;
        DECLARE items CURSOR LOCAL FAST_FORWARD FOR
            SELECT ItemId FROM @Items
            UNION
            SELECT gl.ItemId
            FROM @LineIds x
            INNER JOIN purchase.GoodsReceiptLines gl ON gl.Id = x.Id
            INNER JOIN purchase.GoodsReceipts g      ON g.Id = gl.GoodsReceiptId AND g.Status = 2
            WHERE gl.PoLineId IS NULL AND gl.InvoiceLineId IS NULL AND gl.QuantityBase > 0;
        OPEN items;
        FETCH NEXT FROM items INTO @ItemId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC inventory.usp_Item_RebuildCosts @ItemId;
            FETCH NEXT FROM items INTO @ItemId;
        END
        CLOSE items;
        DEALLOCATE items;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 24. Post a goods receipt */

/* THE GOODS ENTER STOCK, numbered GRN-<branch>-NNNNNN. One transaction: the matching lock first
   (usp_GoodsReceipt_LockMatching, before any row), then the receipt, its container, its order lines and its invoice
   lines without an order locked.
     1 Checks: fn_GoodsReceipt_PostCheck (its first refusal), and the RowVersion (63004).
     2 Number (inventory.usp_DocumentType_NextNumber), then Status 2 and PostedAtUtc in the same UPDATE - before the
       rematch, so this receipt is on the receipt side.
     3 Lines: warehouse (a container receipt: the header's), supplier, the typed cost of a manual line (default: the
       item's last cost, else its average), PoFobBase (order price per piece, frozen), SettledShortBase (container lines: loaded -
       received; a local line marked "Nothing more will come": the rest of its order line). Then the rematch of its
       groups (usp_GoodsReceipt_Rematch).
     4 Cost at receipt. A container (as the offload did): received and variance on the container lines, their FOB =
       the target FOB, the posted charges re-spread over what arrived and frozen (AppliedAtOffload), landed cost =
       the container line's. Other lines: the target cost (fn_GoodsReceiptLine_TargetCost) on the line.
     5 The other posted receipts of the same groups are trued up (GRNPOST): this one may have taken invoiced pieces
       they held. BEFORE this receipt's stock goes in: their in-stock share (company stock on hand) must count only
       goods that were already in stock - this receipt's pieces are already at their own cost.
     6 Stock, per supplier of the lines (last supplier and last cost follow the goods; a manual line not matched to an
       invoice changes neither): pieces that fill a negative company stock first take the cost difference to cost of
       sales (NEGSTOCK, rule 9a), then the moving average (usp_Item_ApplyReceipts, before the movements), then the
       movements (family Purchase, type GRN, the document date + the time of posting, each line's warehouse and the
       branch of that warehouse). Lines receiving nothing write nothing. The average starts from the one step 5 left.
     7 Order lines: received and settled short; an order fully invoiced and received closes ("Fully invoiced and
       received").
     8 The container becomes Offloaded at the warehouse (usp_Container_RefreshStatus).
     9 Totals and audits (the receipt, the orders, the container, the invoices it is matched to).
   Returns DocumentNumber. */
CREATE OR ALTER PROCEDURE purchase.usp_GoodsReceipt_Post
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- lock order: the matcher first, then rows, or two postings deadlock (usp_GoodsReceipt_LockMatching)
        EXEC purchase.usp_GoodsReceipt_LockMatching;

        DECLARE @Status TINYINT, @SourceKind NVARCHAR(10), @ContainerId INT, @BranchId INT, @WarehouseId INT, @SupplierId INT,
                @DocumentDate DATE, @Ref NVARCHAR(30);
        SELECT @Status = g.Status, @SourceKind = g.SourceKind, @ContainerId = g.ContainerId, @BranchId = g.BranchId,
               @WarehouseId = g.WarehouseId, @SupplierId = g.SupplierId, @DocumentDate = g.DocumentDate
        FROM purchase.GoodsReceipts g WITH (UPDLOCK, HOLDLOCK)
        WHERE g.Id = @Id;

        IF @Status IS NULL THROW 63006, 'Goods receipt not found.', 1;
        IF @Status <> 1 THROW 63010, 'Only a draft goods receipt can be posted.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.GoodsReceipts WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 63004, 'This goods receipt was modified by another user. Reload the page and try again.', 1;

        -- the container, the order lines and the invoice lines without an order stay as they are until this receipt is
        -- posted: an invoice line's received pieces change only in usp_GoodsReceipt_Rematch, after the check, so a
        -- second posting of the same line must wait here and then read them (Seq 20, 63011), as an order line does
        IF @ContainerId IS NOT NULL
            SELECT @Ref = c.ContainerRef FROM logistics.Containers c WITH (UPDLOCK, HOLDLOCK) WHERE c.Id = @ContainerId;
        DECLARE @Locked INT = (SELECT COUNT(*) FROM purchase.PurchaseDocumentLines pol WITH (UPDLOCK, HOLDLOCK)
                               WHERE pol.Id IN (SELECT gl.PoLineId FROM purchase.GoodsReceiptLines gl WHERE gl.GoodsReceiptId = @Id
                                                UNION
                                                SELECT gl.InvoiceLineId FROM purchase.GoodsReceiptLines gl
                                                WHERE gl.GoodsReceiptId = @Id AND gl.PoLineId IS NULL));

        DECLARE @Err INT, @Msg NVARCHAR(400);
        SELECT TOP (1) @Err = ErrorNumber, @Msg = Message FROM purchase.fn_GoodsReceipt_PostCheck(@Id) ORDER BY Seq;
        IF @Err IS NOT NULL
        BEGIN
            SET @Msg = ISNULL(@Msg, N'This goods receipt cannot be posted.');
            THROW @Err, @Msg, 1;
        END

        /* ---- 2. Number and status */
        DECLARE @Number NVARCHAR(30);
        EXEC inventory.usp_DocumentType_NextNumber N'GRN', @Number OUTPUT, @BranchId;

        UPDATE purchase.GoodsReceipts
        SET DocumentNumber = @Number, Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        /* ---- 3. Lines, settled short, matches */
        UPDATE gl
        SET WarehouseId        = CASE WHEN @SourceKind = N'Container' THEN @WarehouseId ELSE COALESCE(gl.WarehouseId, @WarehouseId) END,
            SupplierId         = COALESCE(po.SupplierId, inv.SupplierId, gl.SupplierId, @SupplierId),
            ManualUnitCostBase = CASE WHEN gl.PoLineId IS NULL AND gl.InvoiceLineId IS NULL
                                      THEN COALESCE(gl.ManualUnitCostBase, i.LastCost, i.AverageCost) ELSE gl.ManualUnitCostBase END,
            PoFobBase          = CASE WHEN gl.PoLineId IS NOT NULL
                                      THEN CAST(pol.LineTotal / po.ExchangeRate / NULLIF(pol.QuantityBase, 0) AS DECIMAL(18,6)) END
        FROM purchase.GoodsReceiptLines gl
        INNER JOIN inventory.Items i                  ON i.Id = gl.ItemId
        LEFT  JOIN purchase.PurchaseDocumentLines pol ON pol.Id = gl.PoLineId
        LEFT  JOIN purchase.PurchaseDocuments po      ON po.Id = pol.DocumentId
        LEFT  JOIN purchase.PurchaseDocumentLines il  ON il.Id = gl.InvoiceLineId
        LEFT  JOIN purchase.PurchaseDocuments inv     ON inv.Id = il.DocumentId
        WHERE gl.GoodsReceiptId = @Id;

        -- SETTLED SHORT: nothing more is expected for those pieces. A container line always settles loaded - received
        -- (a reason is required). A local line marked "Nothing more will come" settles the rest of its order line -
        -- at most what it expected - and never more than the order line still lacks.
        WITH s AS
        (
            SELECT gl.Id, gl.PoLineId, gl.LineNumber,
                   Want = CASE WHEN gl.ContainerLineId IS NOT NULL
                               THEN CASE WHEN gl.ExpectedQuantityBase > gl.QuantityBase THEN gl.ExpectedQuantityBase - gl.QuantityBase ELSE 0 END
                               WHEN gl.CloseShort = 1 AND gl.PoLineId IS NOT NULL
                               THEN CASE WHEN gl.ExpectedQuantityBase IS NULL THEN rest.Q
                                         WHEN gl.ExpectedQuantityBase - gl.QuantityBase < rest.Q
                                         THEN CASE WHEN gl.ExpectedQuantityBase > gl.QuantityBase THEN gl.ExpectedQuantityBase - gl.QuantityBase ELSE 0 END
                                         ELSE rest.Q END
                               ELSE 0 END,
                   IsLocal = CASE WHEN gl.ContainerLineId IS NULL THEN 1 ELSE 0 END,
                   Rest = rest.Q
            FROM purchase.GoodsReceiptLines gl
            OUTER APPLY (SELECT Q = CASE WHEN x.Q > 0 THEN x.Q ELSE 0 END
                         FROM (SELECT Q = p.OrderedBase - p.GoodsReceivedBase - p.GoodsShortBase - p.InContainersBase
                                          - (SELECT SUM(o.QuantityBase) FROM purchase.GoodsReceiptLines o
                                             WHERE o.GoodsReceiptId = @Id AND o.PoLineId = gl.PoLineId AND o.ContainerLineId IS NULL)
                               FROM purchase.fn_PoLine_Progress(gl.PurchaseOrderId) p
                               WHERE p.PoLineId = gl.PoLineId) x) rest
            WHERE gl.GoodsReceiptId = @Id
        ),
        c AS
        (
            SELECT s.Id, s.Want, s.IsLocal, s.Rest,
                   Before = ISNULL(SUM(CASE WHEN s.IsLocal = 1 THEN s.Want ELSE 0 END)
                                   OVER (PARTITION BY s.PoLineId, s.IsLocal ORDER BY s.LineNumber ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)
            FROM s
        )
        UPDATE gl
        SET SettledShortBase = CASE WHEN c.IsLocal = 0 THEN c.Want
                                    WHEN c.Want <= 0 THEN 0
                                    WHEN ISNULL(c.Rest, 0) - c.Before <= 0 THEN 0
                                    WHEN c.Want > ISNULL(c.Rest, 0) - c.Before THEN ISNULL(c.Rest, 0) - c.Before
                                    ELSE c.Want END
        FROM purchase.GoodsReceiptLines gl INNER JOIN c ON c.Id = gl.Id;

        DECLARE @Anchors purchase.tvp_GoodsReceiptAnchor;
        INSERT INTO @Anchors (Kind, PoLineId, SupplierId, ItemId)
        SELECT DISTINCT 'P', gl.PoLineId, NULL, NULL FROM purchase.GoodsReceiptLines gl WHERE gl.GoodsReceiptId = @Id AND gl.PoLineId IS NOT NULL
        UNION
        SELECT DISTINCT 'S', NULL, gl.SupplierId, gl.ItemId FROM purchase.GoodsReceiptLines gl
        WHERE gl.GoodsReceiptId = @Id AND gl.PoLineId IS NULL AND gl.SupplierId IS NOT NULL;

        EXEC purchase.usp_GoodsReceipt_Rematch @Anchors;

        /* ---- 4. Cost at receipt */
        IF @SourceKind = N'Container'
        BEGIN
            UPDATE cl
            SET ReceivedQuantityBase = gl.QuantityBase,
                VarianceReason = CASE WHEN gl.VarianceReasonCode IS NULL THEN NULLIF(LTRIM(RTRIM(gl.VarianceReason)), N'')
                                      ELSE gl.VarianceReasonCode + ISNULL(N': ' + NULLIF(LTRIM(RTRIM(gl.VarianceReason)), N''), N'') END,
                FobCostBase = COALESCE(t.TargetFobBase, gl.PoFobBase)
            FROM logistics.ContainerLines cl
            INNER JOIN purchase.GoodsReceiptLines gl ON gl.ContainerLineId = cl.Id AND gl.GoodsReceiptId = @Id
            LEFT  JOIN purchase.fn_GoodsReceiptLine_TargetCost(@Id) t ON t.GoodsReceiptLineId = gl.Id
            WHERE cl.ContainerId = @ContainerId;

            -- the posted charges follow the real quantities and values, then they are frozen in the cost of the goods
            EXEC logistics.usp_Container_ReallocateCharges @ContainerId, 0;
            UPDATE logistics.ContainerCharges SET AppliedAtOffload = 1
            WHERE ContainerId = @ContainerId AND Status = 2 AND IncludeInLandedCost = 1;
            EXEC logistics.usp_Container_RecalcCosts @ContainerId;
        END

        UPDATE gl
        SET FobCostBase       = CASE WHEN gl.ContainerLineId IS NULL THEN t.TargetFobBase END,
            ChargesBase       = CASE WHEN gl.ContainerLineId IS NULL THEN t.TargetChargesBase END,
            UnitCostBase      = CASE WHEN gl.ContainerLineId IS NULL THEN t.TargetUnitCostBase END,
            CostAtReceiptBase = CASE WHEN gl.ContainerLineId IS NOT NULL THEN cl.LandedCostBase ELSE t.TargetUnitCostBase END,
            CostSource        = COALESCE(t.CostSource, CASE WHEN gl.PoLineId IS NOT NULL THEN N'Order' ELSE gl.CostSource END)
        FROM purchase.GoodsReceiptLines gl
        LEFT JOIN logistics.ContainerLines cl ON cl.Id = gl.ContainerLineId
        LEFT JOIN purchase.fn_GoodsReceiptLine_TargetCost(@Id) t ON t.GoodsReceiptLineId = gl.Id
        WHERE gl.GoodsReceiptId = @Id;

        /* ---- 5. The other receipts of the same groups, BEFORE this receipt's stock goes in: their in-stock share
                  (company stock on hand) must count only goods that were in stock before it. This receipt's pieces are
                  already at their own cost (step 4); counted as the others' goods, the others' cost change would go to
                  the stock value instead of cost of sales. Its own lines are never among the others. */
        DECLARE @Others logistics.tvp_IdList;
        INSERT INTO @Others (Id)
        SELECT GoodsReceiptLineId FROM purchase.fn_GoodsReceipt_GroupLines(@Anchors) WHERE GoodsReceiptId <> @Id;
        IF EXISTS (SELECT 1 FROM @Others)
            EXEC purchase.usp_GoodsReceipt_TrueUpCost @Others, N'GRNPOST', @Id, @Number, @UserId;

        /* ---- 6. Stock (the average as step 5 left it) */
        DECLARE @MovementDate DATETIME2(3) =
            DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@DocumentDate AS DATETIME2(3)));
        DECLARE @AdjustmentDate DATETIME2(3) = CASE WHEN @MovementDate > SYSUTCDATETIME() THEN @MovementDate ELSE SYSUTCDATETIME() END;

        -- one batch per supplier and per "changes the last cost": usp_Item_ApplyReceipts takes one supplier and one flag,
        -- and each batch's movements go in before the next batch's average is worked out
        DECLARE @Rec TABLE (LineId INT NOT NULL PRIMARY KEY, Batch INT NOT NULL, ItemId INT NOT NULL, WarehouseId INT NOT NULL, BranchId INT NOT NULL,
                            SupplierId INT NULL, UpdateLast BIT NOT NULL, QuantityBase INT NOT NULL, UnitCostBase DECIMAL(18,6) NOT NULL,
                            FobCostBase DECIMAL(18,6) NULL, ExpiryDate DATE NULL);
        INSERT INTO @Rec (LineId, Batch, ItemId, WarehouseId, BranchId, SupplierId, UpdateLast, QuantityBase, UnitCostBase, FobCostBase, ExpiryDate)
        SELECT x.LineId, DENSE_RANK() OVER (ORDER BY ISNULL(x.SupplierId, 0), x.UpdateLast DESC),
               x.ItemId, x.WarehouseId, x.BranchId, x.SupplierId, x.UpdateLast, x.QuantityBase, x.UnitCostBase, x.FobCostBase, x.ExpiryDate
        FROM (SELECT LineId = gl.Id, gl.ItemId, gl.WarehouseId, w.BranchId, gl.SupplierId,
                     UpdateLast = CAST(CASE WHEN gl.PoLineId IS NULL AND gl.InvoiceLineId IS NULL AND gl.InvoicedBase = 0 THEN 0 ELSE 1 END AS BIT),
                     gl.QuantityBase, UnitCostBase = ISNULL(gl.CostAtReceiptBase, 0),
                     FobCostBase = CASE WHEN gl.ContainerLineId IS NOT NULL THEN cl.FobCostBase ELSE gl.FobCostBase END, gl.ExpiryDate
              FROM purchase.GoodsReceiptLines gl
              INNER JOIN masterdata.Warehouses w    ON w.Id = gl.WarehouseId
              LEFT  JOIN logistics.ContainerLines cl ON cl.Id = gl.ContainerLineId
              WHERE gl.GoodsReceiptId = @Id AND gl.QuantityBase > 0) x;

        -- the average the goods sold before this receipt went out at (rule 9a)
        DECLARE @Before TABLE (ItemId INT NOT NULL PRIMARY KEY, AverageCost DECIMAL(18,6) NOT NULL);
        INSERT INTO @Before (ItemId, AverageCost)
        SELECT i.Id, i.AverageCost FROM inventory.Items i WHERE i.Id IN (SELECT ItemId FROM @Rec);

        DECLARE @Neg TABLE (LineId INT NOT NULL PRIMARY KEY, ItemId INT NOT NULL, WarehouseId INT NOT NULL, BranchId INT NOT NULL, R INT NOT NULL,
                            CostBefore DECIMAL(18,6) NOT NULL, CostAfter DECIMAL(18,6) NOT NULL, Raw DECIMAL(38,10) NOT NULL, Amount DECIMAL(18,2) NULL);
        DECLARE @NegChanges TABLE (ChangeId INT NOT NULL PRIMARY KEY, LineId INT NOT NULL);
        DECLARE @R inventory.tvp_ItemReceipt;
        DECLARE @Batch INT = 1, @Batches INT = ISNULL((SELECT MAX(Batch) FROM @Rec), 0), @BatchSupplier INT, @BatchLast BIT;

        WHILE @Batch <= @Batches
        BEGIN
            SELECT TOP (1) @BatchSupplier = SupplierId, @BatchLast = UpdateLast FROM @Rec WHERE Batch = @Batch;

            -- NEGATIVE COMPANY STOCK FILLED BY THIS BATCH: those pieces were sold at the average before the receipt and are
            -- not in stock; the moving average starts again at the batch's cost, so (cost - average before) x the pieces
            -- filled would be in neither the stock nor the cost of sales. It goes to cost of sales, shared over the
            -- batch's lines of the item by their pieces (cents to the largest line).
            DELETE FROM @Neg;
            INSERT INTO @Neg (LineId, ItemId, WarehouseId, BranchId, R, CostBefore, CostAfter, Raw)
            SELECT r.LineId, r.ItemId, r.WarehouseId, r.BranchId, r.QuantityBase, bf.AverageCost, r.UnitCostBase,
                   CAST((r.UnitCostBase - bf.AverageCost) * f.F * r.QuantityBase AS DECIMAL(38,10)) / q.Qty
            FROM @Rec r
            INNER JOIN (SELECT ItemId, Qty = SUM(QuantityBase) FROM @Rec WHERE Batch = @Batch GROUP BY ItemId) q ON q.ItemId = r.ItemId
            INNER JOIN @Before bf ON bf.ItemId = r.ItemId
            CROSS APPLY (SELECT OnHand = inventory.fn_StockOnHand(r.ItemId, NULL)) oh
            CROSS APPLY (SELECT F = CASE WHEN oh.OnHand >= 0 THEN 0 WHEN -oh.OnHand < q.Qty THEN -oh.OnHand ELSE q.Qty END) f
            WHERE r.Batch = @Batch AND f.F > 0;

            IF EXISTS (SELECT 1 FROM @Neg)
            BEGIN
                UPDATE @Neg SET Amount = ROUND(Raw, 2);
                WITH d AS (SELECT n.LineId, Diff = ROUND(SUM(n.Raw) OVER (PARTITION BY n.ItemId), 2) - SUM(n.Amount) OVER (PARTITION BY n.ItemId),
                                  Rn = ROW_NUMBER() OVER (PARTITION BY n.ItemId ORDER BY n.R DESC, n.LineId)
                           FROM @Neg n)
                UPDATE n SET Amount = n.Amount + d.Diff FROM @Neg n INNER JOIN d ON d.LineId = n.LineId WHERE d.Rn = 1 AND d.Diff <> 0;

                DELETE FROM @NegChanges;
                INSERT INTO purchase.GoodsReceiptCostChanges (GoodsReceiptLineId, CauseKind, CauseId, CauseNumber, ReceivedBase, InStockBase,
                                                              FobBefore, FobAfter, UnitCostBefore, UnitCostAfter, AmountBase, InventoryBase, CogsBase, CreatedBy)
                OUTPUT inserted.Id, inserted.GoodsReceiptLineId INTO @NegChanges (ChangeId, LineId)
                SELECT n.LineId, N'NEGSTOCK', @Id, @Number, n.R, 0, NULL, NULL, n.CostBefore, n.CostAfter, n.Amount, 0, n.Amount, @UserId
                FROM @Neg n WHERE n.Amount <> 0;

                INSERT INTO inventory.CostAdjustments (AdjustmentDate, ItemId, WarehouseId, BranchId, Kind, AmountBase, SourceKind, SourceId, SourceNumber, PurchaseLineId, CreatedBy)
                SELECT @AdjustmentDate, n.ItemId, n.WarehouseId, n.BranchId, N'COGS', n.Amount, N'GRNCOST', c.ChangeId, @Number, NULL, @UserId
                FROM @Neg n INNER JOIN @NegChanges c ON c.LineId = n.LineId;
            END

            -- moving average first (on-hand before these movements), then the movements of the batch
            DELETE FROM @R;
            INSERT INTO @R (ItemId, QuantityBase, UnitCostBase, FobCostBase)
            SELECT ItemId, QuantityBase, UnitCostBase, FobCostBase FROM @Rec WHERE Batch = @Batch;
            EXEC inventory.usp_Item_ApplyReceipts @R, @BatchSupplier, @UserId, @BatchLast;

            INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                                  DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, CreatedBy)
            SELECT @MovementDate, r.ItemId, r.WarehouseId, r.BranchId, r.QuantityBase, r.UnitCostBase,
                   N'Purchase', N'GRN', @Id, r.LineId, @Number, NULL, r.ExpiryDate, @UserId
            FROM @Rec r
            WHERE r.Batch = @Batch;

            SET @Batch += 1;
        END

        /* ---- 7. Order lines: received, settled short; an order fully invoiced and received closes */
        UPDATE pol
        SET GoodsReceivedBase = pol.GoodsReceivedBase + x.Rec, GoodsShortBase = pol.GoodsShortBase + x.Short
        FROM purchase.PurchaseDocumentLines pol
        INNER JOIN (SELECT PoLineId, Rec = SUM(QuantityBase), Short = SUM(SettledShortBase)
                    FROM purchase.GoodsReceiptLines WHERE GoodsReceiptId = @Id AND PoLineId IS NOT NULL GROUP BY PoLineId) x ON x.PoLineId = pol.Id;

        DECLARE @Orders TABLE (Id INT NOT NULL PRIMARY KEY, Pcs INT NOT NULL);
        INSERT INTO @Orders (Id, Pcs)
        SELECT PurchaseOrderId, SUM(QuantityBase) FROM purchase.GoodsReceiptLines
        WHERE GoodsReceiptId = @Id AND PurchaseOrderId IS NOT NULL GROUP BY PurchaseOrderId;

        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        SELECT o.Id, N'Updated', N'Goods received by ' + @Number + N' - ' + CAST(o.Pcs AS NVARCHAR(20)) + N' pcs', @UserId FROM @Orders o;

        DECLARE @Closed TABLE (Id INT NOT NULL PRIMARY KEY);
        UPDATE po
        SET Status = 4, ClosedAtUtc = SYSUTCDATETIME(), ClosedBy = @UserId, CloseReason = N'Fully invoiced and received'
        OUTPUT inserted.Id INTO @Closed (Id)
        FROM purchase.PurchaseDocuments po
        INNER JOIN @Orders o ON o.Id = po.Id
        WHERE po.Status = 2
          AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines l
                          WHERE l.DocumentId = po.Id
                            AND (l.ReceivedQuantityBase < l.QuantityBase OR l.GoodsReceivedBase + l.GoodsShortBase < l.QuantityBase));

        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        SELECT c.Id, N'Closed', N'Closed: fully invoiced and received (' + @Number + N')', @UserId FROM @Closed c;

        /* ---- 8. The container */
        IF @SourceKind = N'Container'
        BEGIN
            UPDATE logistics.Containers
            SET OffloadedDate = @DocumentDate, OffloadedAtUtc = SYSUTCDATETIME(), OffloadedBy = @UserId,
                WarehouseId = @WarehouseId, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @ContainerId;

            EXEC logistics.usp_Container_RefreshStatus @ContainerId;

            DECLARE @CtPcs INT, @CtValue DECIMAL(18,2), @CtShort INT;
            SELECT @CtPcs = ISNULL(SUM(gl.QuantityBase), 0),
                   @CtValue = ISNULL(SUM(gl.QuantityBase * gl.CostAtReceiptBase), 0),
                   @CtShort = SUM(CASE WHEN gl.QuantityBase < gl.ExpectedQuantityBase THEN 1 ELSE 0 END)
            FROM purchase.GoodsReceiptLines gl WHERE gl.GoodsReceiptId = @Id;

            INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
            VALUES (@ContainerId, N'Offloaded',
                    LEFT(@Number + N': received ' + CAST(@CtPcs AS NVARCHAR(20)) + N' pcs into '
                         + (SELECT WarehouseCode FROM masterdata.Warehouses WHERE Id = @WarehouseId)
                         + N' at a landed value of ' + CAST(@CtValue AS NVARCHAR(30))
                         + CASE WHEN @CtShort > 0 THEN N'; ' + CAST(@CtShort AS NVARCHAR(10)) + N' line(s) short-shipped' ELSE N'' END, 500), @UserId);
        END

        /* ---- 9. Totals and audits */
        UPDATE g
        SET TotalExpectedBase = x.Expected, TotalReceivedBase = x.Received, ValueAtReceiptBase = x.Value
        FROM purchase.GoodsReceipts g
        CROSS APPLY (SELECT Expected = ISNULL(SUM(ISNULL(gl.ExpectedQuantityBase, gl.QuantityBase)), 0),
                            Received = ISNULL(SUM(gl.QuantityBase), 0),
                            Value    = CAST(ROUND(ISNULL(SUM(gl.QuantityBase * gl.CostAtReceiptBase), 0), 2) AS DECIMAL(18,2))
                     FROM purchase.GoodsReceiptLines gl WHERE gl.GoodsReceiptId = g.Id) x
        WHERE g.Id = @Id;

        DECLARE @Pcs INT = (SELECT TotalReceivedBase FROM purchase.GoodsReceipts WHERE Id = @Id),
                @Settled INT = (SELECT SUM(SettledShortBase) FROM purchase.GoodsReceiptLines WHERE GoodsReceiptId = @Id);
        DECLARE @Into NVARCHAR(100) =
            CASE WHEN (SELECT COUNT(DISTINCT WarehouseId) FROM purchase.GoodsReceiptLines WHERE GoodsReceiptId = @Id AND QuantityBase > 0) > 1
                 THEN CAST((SELECT COUNT(DISTINCT WarehouseId) FROM purchase.GoodsReceiptLines WHERE GoodsReceiptId = @Id AND QuantityBase > 0) AS NVARCHAR(10)) + N' warehouses'
                 ELSE ISNULL((SELECT TOP (1) w.WarehouseCode FROM purchase.GoodsReceiptLines gl
                              INNER JOIN masterdata.Warehouses w ON w.Id = gl.WarehouseId
                              WHERE gl.GoodsReceiptId = @Id ORDER BY CASE WHEN gl.QuantityBase > 0 THEN 0 ELSE 1 END, gl.LineNumber), N'-') END;

        INSERT INTO purchase.GoodsReceiptAudit (GoodsReceiptId, Action, Details, UserId)
        VALUES (@Id, N'Posted', LEFT(N'Posted as ' + @Number + N' - ' + CAST(@Pcs AS NVARCHAR(20)) + N' pcs into ' + @Into
                                     + CASE WHEN @Settled > 0 THEN N', ' + CAST(@Settled AS NVARCHAR(20)) + N' pcs settled short' ELSE N'' END, 500), @UserId);

        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        SELECT DISTINCT il.DocumentId, N'Updated', N'Goods received by ' + @Number, @UserId
        FROM purchase.GoodsReceiptInvoiceMatches m
        INNER JOIN purchase.GoodsReceiptLines gl     ON gl.Id = m.GoodsReceiptLineId AND gl.GoodsReceiptId = @Id
        INNER JOIN purchase.PurchaseDocumentLines il ON il.Id = m.InvoiceLineId;

        COMMIT TRANSACTION;
        SELECT @Number AS DocumentNumber;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 25. Cancel a goods receipt */

/* THE STOCK GOES BACK OUT, and everything the receipt set is undone. Only a posted receipt, with a reason (63000).
   Refused (fn_GoodsReceipt_CancelCheck): a closed container (63010), a cost adjusted afterwards (63008), stock used
   (63007); and, once the matches are rebuilt without it, when a purchase return took back goods that would be left
   without a receipt (63010: an invoice line ending with returned > received).
     - reversal movements (the copies, negative, IsReversal = 1, dated now) and Status 3;
     - the NEGSTOCK cost of sales of its own posting is reversed: the sold pieces are again without a receipt;
     - a container: its received quantities, variances and costs cleared, its charges no longer frozen and re-spread,
       back to its movement status (for example Cleared), so it can be received again;
     - the matches of its groups rebuilt, and the other receipts of those groups trued up (GRNCANCEL);
     - the order lines' received and settled short reduced; an order closed because it was fully received reopens;
     - the item costs replayed (usp_Item_RebuildCosts).
   The matching lock is taken first (usp_GoodsReceipt_LockMatching): a purchase return or a posting of the same goods
   then either commits before this cancel reads them (63007, 63010) or waits for it. */
CREATE OR ALTER PROCEDURE purchase.usp_GoodsReceipt_Cancel
    @Id         INT,
    @Reason     NVARCHAR(300),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');

    BEGIN TRY
        BEGIN TRANSACTION;

        -- lock order: the matcher first, then rows, or two postings deadlock (usp_GoodsReceipt_LockMatching)
        EXEC purchase.usp_GoodsReceipt_LockMatching;

        DECLARE @Status TINYINT, @ContainerId INT, @Number NVARCHAR(30), @Ref NVARCHAR(30);
        SELECT @Status = g.Status, @ContainerId = g.ContainerId, @Number = g.DocumentNumber
        FROM purchase.GoodsReceipts g WITH (UPDLOCK, HOLDLOCK)
        WHERE g.Id = @Id;

        IF @Status IS NULL THROW 63006, 'Goods receipt not found.', 1;
        IF @Status <> 2 THROW 63010, 'Only a posted goods receipt can be cancelled.', 1;
        IF @Reason IS NULL THROW 63000, 'A cancellation reason is required.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.GoodsReceipts WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 63004, 'This goods receipt was modified by another user. Reload the page and try again.', 1;

        IF @ContainerId IS NOT NULL
            SELECT @Ref = c.ContainerRef FROM logistics.Containers c WITH (UPDLOCK, HOLDLOCK) WHERE c.Id = @ContainerId;
        DECLARE @Locked INT = (SELECT COUNT(*) FROM purchase.PurchaseDocumentLines pol WITH (UPDLOCK, HOLDLOCK)
                               WHERE pol.Id IN (SELECT gl.PoLineId FROM purchase.GoodsReceiptLines gl WHERE gl.GoodsReceiptId = @Id));

        DECLARE @Err INT, @Msg NVARCHAR(400);
        SELECT TOP (1) @Err = ErrorNumber, @Msg = Message FROM purchase.fn_GoodsReceipt_CancelCheck(@Id) ORDER BY Seq;
        IF @Err IS NOT NULL
        BEGIN
            SET @Msg = ISNULL(@Msg, N'This goods receipt cannot be cancelled.');
            THROW @Err, @Msg, 1;
        END

        -- what it was matched to (the audit of those invoices) and the groups of its lines
        DECLARE @Invoices TABLE (Id INT NOT NULL PRIMARY KEY);
        INSERT INTO @Invoices (Id)
        SELECT DISTINCT il.DocumentId
        FROM purchase.GoodsReceiptInvoiceMatches m
        INNER JOIN purchase.GoodsReceiptLines gl     ON gl.Id = m.GoodsReceiptLineId AND gl.GoodsReceiptId = @Id
        INNER JOIN purchase.PurchaseDocumentLines il ON il.Id = m.InvoiceLineId;

        DECLARE @Anchors purchase.tvp_GoodsReceiptAnchor;
        INSERT INTO @Anchors (Kind, PoLineId, SupplierId, ItemId)
        SELECT DISTINCT 'P', gl.PoLineId, NULL, NULL FROM purchase.GoodsReceiptLines gl WHERE gl.GoodsReceiptId = @Id AND gl.PoLineId IS NOT NULL
        UNION
        SELECT DISTINCT 'S', NULL, gl.SupplierId, gl.ItemId FROM purchase.GoodsReceiptLines gl
        WHERE gl.GoodsReceiptId = @Id AND gl.PoLineId IS NULL AND gl.SupplierId IS NOT NULL;

        -- the invoice lines of those groups and what they had received, to tell which ones lose pieces
        DECLARE @GroupInvoiceLines TABLE (LineId INT NOT NULL PRIMARY KEY, ReceivedBefore INT NOT NULL);
        INSERT INTO @GroupInvoiceLines (LineId, ReceivedBefore)
        SELECT il.Id, il.ReceivedQuantityBase
        FROM purchase.PurchaseDocumentLines il
        INNER JOIN purchase.PurchaseDocuments d ON d.Id = il.DocumentId
        INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId AND dt.Code = N'PINV'
        WHERE EXISTS (SELECT 1 FROM @Anchors a
                      WHERE (a.Kind = 'P' AND a.PoLineId = il.SourceLineId)
                         OR (a.Kind = 'S' AND il.SourceLineId IS NULL AND a.SupplierId = d.SupplierId AND a.ItemId = il.ItemId));

        /* ---- stock */
        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, IsReversal, CreatedBy)
        SELECT SYSUTCDATETIME(), m.ItemId, m.WarehouseId, m.BranchId, -m.QuantityBase, m.UnitCostBase,
               m.DocumentFamily, m.DocumentTypeCode, m.DocumentId, m.DocumentLineId, m.DocumentNumber, m.ReasonCode, m.ExpiryDate, 1, @UserId
        FROM inventory.StockMovements m
        WHERE m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = N'GRN' AND m.DocumentId = @Id AND m.IsReversal = 0;

        UPDATE purchase.GoodsReceipts
        SET Status = 3, CancelledAtUtc = SYSUTCDATETIME(), CancelledBy = @UserId, CancelReason = @Reason,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        -- the cost of sales of the negative stock it filled goes back: without this receipt those pieces are again
        -- sold without a receipt (compensating rows, as the GRNCOST rows always are)
        DECLARE @NegBack TABLE (ChangeId INT NOT NULL PRIMARY KEY, LineId INT NOT NULL, Amount DECIMAL(18,2) NOT NULL);
        INSERT INTO purchase.GoodsReceiptCostChanges (GoodsReceiptLineId, CauseKind, CauseId, CauseNumber, ReceivedBase, InStockBase,
                                                      FobBefore, FobAfter, UnitCostBefore, UnitCostAfter, AmountBase, InventoryBase, CogsBase, CreatedBy)
        OUTPUT inserted.Id, inserted.GoodsReceiptLineId, inserted.AmountBase INTO @NegBack (ChangeId, LineId, Amount)
        SELECT cc.GoodsReceiptLineId, N'NEGSTOCK', @Id, @Number, cc.ReceivedBase, 0, NULL, NULL, cc.UnitCostAfter, cc.UnitCostBefore,
               -cc.AmountBase, -cc.InventoryBase, -cc.CogsBase, @UserId
        FROM purchase.GoodsReceiptCostChanges cc
        INNER JOIN purchase.GoodsReceiptLines gl ON gl.Id = cc.GoodsReceiptLineId AND gl.GoodsReceiptId = @Id
        WHERE cc.CauseKind = N'NEGSTOCK' AND cc.AmountBase <> 0;

        INSERT INTO inventory.CostAdjustments (AdjustmentDate, ItemId, WarehouseId, BranchId, Kind, AmountBase, SourceKind, SourceId, SourceNumber, PurchaseLineId, CreatedBy)
        SELECT SYSUTCDATETIME(), gl.ItemId, gl.WarehouseId, w.BranchId, N'COGS', n.Amount, N'GRNCOST', n.ChangeId, @Number, NULL, @UserId
        FROM @NegBack n
        INNER JOIN purchase.GoodsReceiptLines gl ON gl.Id = n.LineId
        INNER JOIN masterdata.Warehouses w       ON w.Id = gl.WarehouseId;

        /* ---- the container: back to its movement status, to be received again. BEFORE the rematch: a container still
           Offloaded without a posted receipt reads as offloaded the old way (fn_Container_ReceivedBy), and its invoice
           lines would be left out of the matching. */
        IF @ContainerId IS NOT NULL
        BEGIN
            UPDATE logistics.ContainerLines
            SET ReceivedQuantityBase = NULL, VarianceReason = NULL, FobCostBase = NULL, LandedCostBase = NULL
            WHERE ContainerId = @ContainerId;

            UPDATE logistics.ContainerCharges SET AppliedAtOffload = 0 WHERE ContainerId = @ContainerId;
            EXEC logistics.usp_Container_ReallocateCharges @ContainerId;

            UPDATE logistics.Containers
            SET OffloadedDate = NULL, OffloadedAtUtc = NULL, OffloadedBy = NULL,
                StatusNote = LEFT(N'Goods receipt ' + @Number + N' cancelled: ' + @Reason, 200),
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @ContainerId;

            EXEC logistics.usp_Container_RefreshStatus @ContainerId;

            INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
            VALUES (@ContainerId, N'OffloadCancelled', LEFT(N'Goods receipt ' + @Number + N' cancelled: ' + @Reason, 500), @UserId);
        END

        /* ---- matches and costs */
        EXEC purchase.usp_GoodsReceipt_Rematch @Anchors;

        SELECT TOP (1) @Msg = N'Purchase return ' + ISNULL(r.DocumentNumber, N'') + N' took back goods of this receipt. Cancel the return first.'
        FROM @GroupInvoiceLines g
        INNER JOIN purchase.PurchaseDocumentLines il ON il.Id = g.LineId
        OUTER APPLY (SELECT TOP (1) rd.DocumentNumber
                     FROM purchase.PurchaseDocumentLines rl
                     INNER JOIN purchase.PurchaseDocuments rd ON rd.Id = rl.DocumentId AND rd.Status IN (2, 4)
                     WHERE rl.SourceLineId = il.Id
                     ORDER BY rd.PostedAtUtc DESC, rd.Id DESC) r
        WHERE il.ReceivedQuantityBase < g.ReceivedBefore AND il.ReturnedQuantityBase > il.ReceivedQuantityBase
        ORDER BY il.Id;
        IF @Msg IS NOT NULL THROW 63010, @Msg, 1;

        DECLARE @Others logistics.tvp_IdList;
        INSERT INTO @Others (Id) SELECT GoodsReceiptLineId FROM purchase.fn_GoodsReceipt_GroupLines(@Anchors);
        IF EXISTS (SELECT 1 FROM @Others)
            EXEC purchase.usp_GoodsReceipt_TrueUpCost @Others, N'GRNCANCEL', @Id, @Number, @UserId;

        /* ---- order lines */
        UPDATE pol
        SET GoodsReceivedBase = pol.GoodsReceivedBase - x.Rec, GoodsShortBase = pol.GoodsShortBase - x.Short
        FROM purchase.PurchaseDocumentLines pol
        INNER JOIN (SELECT PoLineId, Rec = SUM(QuantityBase), Short = SUM(SettledShortBase)
                    FROM purchase.GoodsReceiptLines WHERE GoodsReceiptId = @Id AND PoLineId IS NOT NULL GROUP BY PoLineId) x ON x.PoLineId = pol.Id;

        DECLARE @Reopened TABLE (Id INT NOT NULL PRIMARY KEY);
        UPDATE po
        SET Status = 2, ClosedAtUtc = NULL, ClosedBy = NULL, CloseReason = NULL
        OUTPUT inserted.Id INTO @Reopened (Id)
        FROM purchase.PurchaseDocuments po
        WHERE po.Id IN (SELECT PurchaseOrderId FROM purchase.GoodsReceiptLines WHERE GoodsReceiptId = @Id AND PurchaseOrderId IS NOT NULL)
          AND po.Status = 4 AND po.CloseReason IN (N'Fully received', N'Fully invoiced and received')
          AND EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines l
                      WHERE l.DocumentId = po.Id AND l.GoodsReceivedBase + l.GoodsShortBase < l.QuantityBase);

        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        SELECT r.Id, N'Updated', N'Re-opened: ' + @Number + N' was cancelled', @UserId FROM @Reopened r;

        /* ---- item costs and audits */
        DECLARE @ItemId INT;
        DECLARE items CURSOR LOCAL FAST_FORWARD FOR
            SELECT DISTINCT ItemId FROM purchase.GoodsReceiptLines WHERE GoodsReceiptId = @Id AND QuantityBase > 0;
        OPEN items;
        FETCH NEXT FROM items INTO @ItemId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC inventory.usp_Item_RebuildCosts @ItemId;
            FETCH NEXT FROM items INTO @ItemId;
        END
        CLOSE items;
        DEALLOCATE items;

        INSERT INTO purchase.GoodsReceiptAudit (GoodsReceiptId, Action, Details, UserId) VALUES (@Id, N'Cancelled', @Reason, @UserId);

        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        SELECT i.Id, N'Updated', N'Goods receipt ' + @Number + N' cancelled', @UserId FROM @Invoices i;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 26. What posting a draft invoice would do to received goods */

/* AN ESTIMATE, READ-ONLY, for the post confirmation of a DRAFT supplier invoice. One row per invoice line:
     ReceivedNotInvoicedBase  the received pieces of its group not matched to an invoice yet, up to the line's
                              pieces, first in first out (a line linked to a container takes that container's first)
     CurrentCostBase          what those pieces cost now, per piece (landed)
     InvoiceCostBase          what they would cost with this invoice, per piece: its FOB (rate of the invoice) and
                              its own charges (allocated, else shared by value); container pieces also keep their
                              container charges (a local invoice's own charges ride on a container line's FOB, as
                              fn_GoodsReceiptLine_TargetCost has it; an imported invoice has none)
     DifferenceBase           the cost adjustment
     EstimatedInventoryBase / EstimatedCogsBase   the split on today's company stock, as the true-up does it
   Nothing for a document that is not a draft. The posting itself re-matches everything and may differ slightly. */
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseInvoice_ReceiptCostPreview
    @InvoiceId INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Status TINYINT, @Rate DECIMAL(18,6), @SupplierId INT, @Code NVARCHAR(20);
    SELECT @Status = d.Status, @Rate = d.ExchangeRate, @SupplierId = d.SupplierId, @Code = dt.Code
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    WHERE d.Id = @InvoiceId;
    IF @Status IS NULL OR @Code <> N'PINV' THROW 65006, 'Purchase invoice not found.', 1;

    -- the draft's own charges per line: as allocated, else shared by value (an estimate until it is posted)
    DECLARE @ChargesTotal DECIMAL(18,2) = ISNULL((SELECT SUM(AmountBase) FROM purchase.PurchaseCharges
                                                  WHERE DocumentKind = N'PINV' AND DocumentId = @InvoiceId AND IncludeInLandedCost = 1), 0);
    DECLARE @HasAllocations BIT = CASE WHEN EXISTS (SELECT 1 FROM purchase.PurchaseChargeAllocations x
                                                    INNER JOIN purchase.PurchaseCharges c ON c.Id = x.ChargeId
                                                    WHERE c.DocumentKind = N'PINV' AND c.DocumentId = @InvoiceId AND c.IncludeInLandedCost = 1)
                                       THEN 1 ELSE 0 END;
    DECLARE @ValueTotal DECIMAL(18,6) = (SELECT SUM(LineTotal / @Rate) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId);

    DECLARE @L TABLE (LineId INT NOT NULL PRIMARY KEY, LineNumber INT NOT NULL, ItemId INT NOT NULL, GroupKey NVARCHAR(40) NOT NULL,
                      ContainerLineId INT NULL, QuantityBase INT NOT NULL, FobBase DECIMAL(18,6) NOT NULL, ChargesBase DECIMAL(18,6) NOT NULL,
                      Rem INT NOT NULL);
    INSERT INTO @L (LineId, LineNumber, ItemId, GroupKey, ContainerLineId, QuantityBase, FobBase, ChargesBase, Rem)
    SELECT l.Id, l.LineNumber, l.ItemId,
           CASE WHEN l.SourceLineId IS NOT NULL THEN N'P' + CAST(l.SourceLineId AS NVARCHAR(12))
                ELSE N'S' + CAST(@SupplierId AS NVARCHAR(12)) + N'.' + CAST(l.ItemId AS NVARCHAR(12)) END,
           l.ContainerLineId, l.QuantityBase,
           CAST(l.LineTotal / @Rate / l.QuantityBase AS DECIMAL(18,6)),
           CAST(CASE WHEN @HasAllocations = 1
                     THEN ISNULL((SELECT SUM(x.AmountBase) FROM purchase.PurchaseChargeAllocations x
                                  INNER JOIN purchase.PurchaseCharges c ON c.Id = x.ChargeId
                                  WHERE x.PurchaseLineId = l.Id AND c.DocumentKind = N'PINV' AND c.DocumentId = @InvoiceId
                                    AND c.IncludeInLandedCost = 1), 0)
                     WHEN @ValueTotal > 0 THEN @ChargesTotal * (l.LineTotal / @Rate) / @ValueTotal
                     ELSE 0 END / l.QuantityBase AS DECIMAL(18,6)),
           -- a line of a container offloaded before goods receipts takes nothing: its goods are received already
           CASE WHEN rb.ReceivedBy = N'Offload' THEN 0 ELSE l.QuantityBase END
    FROM purchase.PurchaseDocumentLines l
    LEFT JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
    OUTER APPLY logistics.fn_Container_ReceivedBy(cl.ContainerId) rb
    WHERE l.DocumentId = @InvoiceId AND @Status = 1;

    -- received pieces of those groups not matched to an invoice yet, with what they cost now
    DECLARE @U TABLE (LineId INT NOT NULL PRIMARY KEY, GoodsReceiptId INT NOT NULL, GroupKey NVARCHAR(40) NOT NULL, ContainerLineId INT NULL,
                      ItemId INT NOT NULL, T DATETIME2(3) NOT NULL, Rem INT NOT NULL, IsContainer BIT NOT NULL,
                      BaseFob DECIMAL(18,6) NOT NULL, BaseCharges DECIMAL(18,6) NOT NULL, ContainerCharges DECIMAL(18,6) NOT NULL,
                      RNet DECIMAL(18,6) NOT NULL);
    INSERT INTO @U (LineId, GoodsReceiptId, GroupKey, ContainerLineId, ItemId, T, Rem, IsContainer, BaseFob, BaseCharges, ContainerCharges, RNet)
    SELECT t.GoodsReceiptLineId, t.GoodsReceiptId,
           CASE WHEN t.PoLineId IS NOT NULL THEN N'P' + CAST(t.PoLineId AS NVARCHAR(12))
                ELSE N'S' + CAST(t.SupplierId AS NVARCHAR(12)) + N'.' + CAST(t.ItemId AS NVARCHAR(12)) END,
           t.ContainerLineId, t.ItemId, ISNULL(g.PostedAtUtc, g.CreatedAtUtc), t.ReceivedBase - t.MatchedBase, t.IsContainerLine,
           t.BaseFobBase, t.BaseChargesBase, CASE WHEN t.IsContainerLine = 1 THEN t.TargetChargesBase ELSE 0 END, t.NetReceivedBase
    FROM (SELECT DISTINCT gl.GoodsReceiptId
          FROM purchase.GoodsReceiptLines gl
          INNER JOIN purchase.GoodsReceipts gr ON gr.Id = gl.GoodsReceiptId AND gr.Status = 2
          WHERE gl.PoLineId IN (SELECT l.SourceLineId FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = @InvoiceId)
             OR (gl.PoLineId IS NULL AND gl.SupplierId = @SupplierId
                 AND gl.ItemId IN (SELECT l.ItemId FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = @InvoiceId AND l.SourceLineId IS NULL))) r
    CROSS APPLY purchase.fn_GoodsReceiptLine_TargetCost(r.GoodsReceiptId) t
    INNER JOIN purchase.GoodsReceipts g ON g.Id = t.GoodsReceiptId
    WHERE t.ReceivedBase > t.MatchedBase;

    DELETE FROM @U WHERE GroupKey NOT IN (SELECT GroupKey FROM @L);

    -- first in first out, as the rematch would: the container line first, then the group
    DECLARE @Take TABLE (ULineId INT NOT NULL, LLineId INT NOT NULL, Qty INT NOT NULL);
    DECLARE @Pass TABLE (ULineId INT NOT NULL, LLineId INT NOT NULL, Qty INT NOT NULL);

    WITH u AS (SELECT LineId, K = ContainerLineId, Rem,
                      E = SUM(Rem) OVER (PARTITION BY ContainerLineId ORDER BY T, LineId ROWS UNBOUNDED PRECEDING)
               FROM @U WHERE Rem > 0 AND ContainerLineId IS NOT NULL),
         l AS (SELECT LineId, K = ContainerLineId, Rem,
                      E = SUM(Rem) OVER (PARTITION BY ContainerLineId ORDER BY LineNumber ROWS UNBOUNDED PRECEDING)
               FROM @L WHERE Rem > 0 AND ContainerLineId IS NOT NULL)
    INSERT INTO @Pass (ULineId, LLineId, Qty)
    SELECT u.LineId, l.LineId,
           (CASE WHEN u.E < l.E THEN u.E ELSE l.E END) - (CASE WHEN u.E - u.Rem > l.E - l.Rem THEN u.E - u.Rem ELSE l.E - l.Rem END)
    FROM u INNER JOIN l ON l.K = u.K
    WHERE u.E - u.Rem < l.E AND l.E - l.Rem < u.E;

    UPDATE u SET Rem = u.Rem - p.Qty FROM @U u INNER JOIN (SELECT ULineId, Qty = SUM(Qty) FROM @Pass GROUP BY ULineId) p ON p.ULineId = u.LineId;
    UPDATE l SET Rem = l.Rem - p.Qty FROM @L l INNER JOIN (SELECT LLineId, Qty = SUM(Qty) FROM @Pass GROUP BY LLineId) p ON p.LLineId = l.LineId;
    INSERT INTO @Take (ULineId, LLineId, Qty) SELECT ULineId, LLineId, Qty FROM @Pass;
    DELETE FROM @Pass;

    WITH u AS (SELECT LineId, K = GroupKey, Rem,
                      E = SUM(Rem) OVER (PARTITION BY GroupKey ORDER BY T, LineId ROWS UNBOUNDED PRECEDING)
               FROM @U WHERE Rem > 0),
         l AS (SELECT LineId, K = GroupKey, Rem,
                      E = SUM(Rem) OVER (PARTITION BY GroupKey ORDER BY LineNumber ROWS UNBOUNDED PRECEDING)
               FROM @L WHERE Rem > 0)
    INSERT INTO @Take (ULineId, LLineId, Qty)
    SELECT u.LineId, l.LineId,
           (CASE WHEN u.E < l.E THEN u.E ELSE l.E END) - (CASE WHEN u.E - u.Rem > l.E - l.Rem THEN u.E - u.Rem ELSE l.E - l.Rem END)
    FROM u INNER JOIN l ON l.K = u.K
    WHERE u.E - u.Rem < l.E AND l.E - l.Rem < u.E;

    -- per piece taken: now = its base cost (+ its container's charges); with the invoice = the invoice FOB + the invoice's
    -- own charges (+ the same container charges for container pieces: fn_GoodsReceiptLine_TargetCost)
    DECLARE @T TABLE (LLineId INT NOT NULL, ULineId INT NOT NULL, ItemId INT NOT NULL, Qty INT NOT NULL,
                      CostNow DECIMAL(18,6) NOT NULL, CostNew DECIMAL(18,6) NOT NULL, PRIMARY KEY (LLineId, ULineId));
    INSERT INTO @T (LLineId, ULineId, ItemId, Qty, CostNow, CostNew)
    SELECT k.LLineId, k.ULineId, u.ItemId, SUM(k.Qty),
           MAX(CASE WHEN u.IsContainer = 1 THEN u.BaseFob + u.ContainerCharges ELSE u.BaseFob + u.BaseCharges END),
           MAX(CASE WHEN u.IsContainer = 1 THEN l.FobBase + l.ChargesBase + u.ContainerCharges ELSE l.FobBase + l.ChargesBase END)
    FROM @Take k
    INNER JOIN @U u ON u.LineId = k.ULineId
    INNER JOIN @L l ON l.LineId = k.LLineId
    GROUP BY k.LLineId, k.ULineId, u.ItemId;

    -- the stock share per item, on today's company stock, over the receipt lines involved (as the true-up)
    DECLARE @Items TABLE (ItemId INT NOT NULL PRIMARY KEY, NetReceived DECIMAL(18,6) NOT NULL, OnHand DECIMAL(18,6) NOT NULL, Ratio DECIMAL(18,10) NOT NULL);
    INSERT INTO @Items (ItemId, NetReceived, OnHand, Ratio)
    SELECT x.ItemId, x.NetReceived, oh.Q,
           CASE WHEN oh.Q <= 0 OR x.NetReceived <= 0 THEN 0 WHEN oh.Q < x.NetReceived THEN oh.Q / x.NetReceived ELSE 1 END
    FROM (SELECT u.ItemId, NetReceived = SUM(CASE WHEN u.RNet > 0 THEN u.RNet ELSE 0 END)
          FROM @U u WHERE u.LineId IN (SELECT ULineId FROM @T) GROUP BY u.ItemId) x
    CROSS APPLY (SELECT Q = CAST(inventory.fn_StockOnHand(x.ItemId, NULL) AS DECIMAL(18,6))) oh;

    SELECT InvoiceLineId           = l.Id,
           l.LineNumber, l.ItemId, i.ItemCode, i.ItemName,
           InvoicedBase            = l.QuantityBase,
           ReceivedNotInvoicedBase = ISNULL(x.Qty, 0),
           CurrentCostBase         = CAST(x.Now / NULLIF(x.Qty, 0) AS DECIMAL(18,6)),
           InvoiceCostBase         = CAST(x.New / NULLIF(x.Qty, 0) AS DECIMAL(18,6)),
           DifferenceBase          = CAST(ISNULL(x.Diff, 0) AS DECIMAL(18,2)),
           EstimatedInventoryBase  = CAST(ROUND(ISNULL(x.Diff, 0) * ISNULL(it.Ratio, 0), 2) AS DECIMAL(18,2)),
           EstimatedCogsBase       = CAST(ISNULL(x.Diff, 0) - ROUND(ISNULL(x.Diff, 0) * ISNULL(it.Ratio, 0), 2) AS DECIMAL(18,2)),
           CompanyOnHandBase       = CAST(inventory.fn_StockOnHand(l.ItemId, NULL) AS INT),
           Receipts                = x.Receipts,
           IsEstimate              = CAST(1 AS BIT)
    FROM purchase.PurchaseDocumentLines l
    INNER JOIN inventory.Items i ON i.Id = l.ItemId
    OUTER APPLY (SELECT Qty  = SUM(t.Qty),
                        Now  = SUM(t.Qty * t.CostNow),
                        New  = SUM(t.Qty * t.CostNew),
                        Diff = SUM(ROUND((t.CostNew - t.CostNow) * t.Qty, 2)),
                        Receipts = (SELECT STRING_AGG(z.DocumentNumber, N', ') WITHIN GROUP (ORDER BY z.DocumentNumber)
                                    FROM (SELECT DISTINCT g.DocumentNumber FROM @T t2
                                          INNER JOIN @U u2 ON u2.LineId = t2.ULineId
                                          INNER JOIN purchase.GoodsReceipts g ON g.Id = u2.GoodsReceiptId
                                          WHERE t2.LLineId = l.Id) z)
                 FROM @T t WHERE t.LLineId = l.Id) x
    LEFT JOIN @Items it ON it.ItemId = l.ItemId
    WHERE l.DocumentId = @InvoiceId AND @Status = 1
    ORDER BY l.LineNumber;
END
GO

/* ================================================================== 99. Check */

SELECT o.ObjectName, ObjectType = ISNULL(so.type_desc, N'MISSING')
FROM (VALUES (N'purchase.GoodsReceipts'), (N'purchase.GoodsReceiptLines'), (N'purchase.GoodsReceiptInvoiceMatches'),
             (N'purchase.GoodsReceiptCostChanges'), (N'purchase.GoodsReceiptFiles'), (N'purchase.GoodsReceiptAudit'),
             (N'purchase.GoodsReceiptSwitch'),
             (N'masterdata.fn_AttachmentDocumentKinds'), (N'masterdata.usp_AttachmentType_Delete'),
             (N'logistics.fn_Container_ReceivedBy'), (N'logistics.fn_Container_LastDelivery'),
             (N'purchase.fn_PoLine_Progress'), (N'purchase.fn_PoLine_CommittedOutside'), (N'purchase.fn_InvoiceLine_ToReceive'),
             (N'purchase.fn_GoodsReceipt_GroupLines'), (N'purchase.fn_GoodsReceiptLine_TargetCost'), (N'purchase.fn_GoodsReceiptLine_Cost'),
             (N'purchase.fn_GoodsReceipt_PostCheck'), (N'purchase.fn_GoodsReceipt_CancelCheck'), (N'purchase.fn_GoodsReceipt_Blocks'),
             (N'purchase.usp_GoodsReceipt_Save'), (N'purchase.usp_GoodsReceipt_CreateFromOrder'),
             (N'purchase.usp_GoodsReceipt_CreateFromInvoice'), (N'purchase.usp_GoodsReceipt_CreateForContainer'),
             (N'purchase.usp_GoodsReceipt_CreateForMovement'), (N'purchase.usp_GoodsReceipt_Delete'),
             (N'purchase.usp_GoodsReceipt_Get'), (N'purchase.usp_GoodsReceipt_Search'), (N'purchase.usp_GoodsReceipt_WaitingCount'),
             (N'purchase.usp_GoodsReceipt_File_Add'), (N'purchase.usp_GoodsReceipt_File_List'), (N'purchase.usp_GoodsReceipt_File_Get'),
             (N'purchase.usp_GoodsReceipt_File_Update'), (N'purchase.usp_GoodsReceipt_File_Delete'),
             (N'purchase.usp_GoodsReceipt_LockMatching'),
             (N'purchase.usp_GoodsReceipt_Rematch'), (N'purchase.usp_GoodsReceipt_TrueUpCost'),
             (N'purchase.usp_GoodsReceipt_Post'), (N'purchase.usp_GoodsReceipt_Cancel'),
             (N'purchase.usp_PurchaseInvoice_ReceiptCostPreview')) o (ObjectName)
LEFT JOIN sys.objects so ON so.object_id = OBJECT_ID(o.ObjectName)
ORDER BY ObjectType, o.ObjectName;                                    -- expected 40: 12 functions, 21 procedures, 7 tables, none MISSING

SELECT TypeName = SCHEMA_NAME(schema_id) + N'.' + name FROM sys.table_types
WHERE SCHEMA_NAME(schema_id) = N'purchase' AND name IN (N'tvp_GoodsReceiptLine', N'tvp_GoodsReceiptAnchor');   -- expected 2

-- The new columns, and the widened container line note (800 bytes = 400 characters).
SELECT UsesGoodsReceipts = CASE WHEN COL_LENGTH(N'purchase.PurchaseDocuments', N'UsesGoodsReceipts') IS NULL THEN N'MISSING' ELSE N'ok' END,
       GoodsReceivedBase = CASE WHEN COL_LENGTH(N'purchase.PurchaseDocumentLines', N'GoodsReceivedBase') IS NULL THEN N'MISSING' ELSE N'ok' END,
       GoodsShortBase    = CASE WHEN COL_LENGTH(N'purchase.PurchaseDocumentLines', N'GoodsShortBase') IS NULL THEN N'MISSING' ELSE N'ok' END,
       VarianceReasonBytes = COL_LENGTH(N'logistics.ContainerLines', N'VarianceReason');   -- expected ok, ok, ok, 800

SELECT Code, Name, Family, StockDirection, NumberPrefix, NumberOnPost, NumberPerBranch, YearInNumber, NumberLength, DefaultPricing, IsActive
FROM inventory.DocumentTypes WHERE Code = N'GRN';                    -- expected 1 row

SELECT p.Code, p.Name, p.SortOrder, Roles = (SELECT COUNT(*) FROM security.RolePermissions rp WHERE rp.PermissionId = p.Id)
FROM security.Permissions p WHERE p.Code LIKE N'purchase.goodsreceipts.%' ORDER BY p.SortOrder;   -- expected 5

-- The attachment types used for goods receipts (as an administrator left them).
SELECT a.Category, a.SubType, a.AppliesTo, a.IsActive
FROM masterdata.AttachmentTypes a
WHERE EXISTS (SELECT 1 FROM masterdata.AttachmentTypeUsages u WHERE u.AttachmentTypeId = a.Id AND u.DocumentKind = N'GRN')
ORDER BY a.SortOrder;

-- The goods receipts by source and status, and the switch (empty until script 65).
SELECT g.SourceKind, Drafts = SUM(CASE WHEN g.Status = 1 THEN 1 ELSE 0 END), Posted = SUM(CASE WHEN g.Status = 2 THEN 1 ELSE 0 END),
       Cancelled = SUM(CASE WHEN g.Status = 3 THEN 1 ELSE 0 END)
FROM purchase.GoodsReceipts g
GROUP BY g.SourceKind
ORDER BY g.SourceKind;
SELECT SwitchedAtUtc FROM purchase.GoodsReceiptSwitch;              -- empty until script 65

PRINT 'Script 64 applied: goods receipts - tables, document type GRN, permissions, attachment kind, progress functions, drafts, posting, matching and cost true-up (not called before script 65).';
GO

SET NOEXEC OFF;
GO
