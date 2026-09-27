/* =====================================================================================
   Inventory_Shipment - 27: CONTAINERS AT THE CENTRE
   Containers from the purchase order, invoices from containers, shipment movements, container charges
   (real cost of every item), attachments per container or per movement.

   The model
     Purchase order (approved) --"Add container"--> container lines = PO lines + quantity loaded (BASE units).
         A container is created from one PO; lines of other approved POs (other suppliers too) may be added.
     Purchase invoice --created from containers--> every invoice line points to ONE container line.
         One invoice = one PO, it may cover several containers; a container may be split over several invoices.
         Invoice lines keep SourceLineId = the PO line, so the PO invoicing progress of script 26 still works.
     Shipment movement (MOV-2026-000001): movement type + from place -> to place (masterdata.Ports), carrier,
         vessel / truck, voyage, dates. One movement carries one or MORE containers.
         Planned -> In progress (Start) -> Completed (Complete); Cancelled.
         The status, the milestone dates and the current location of a container come from its movements.
         Movement type stage:  Origin   loading at the supplier (no status change)
                               Sea      started = in transit (dispatch date), completed = at port (port arrival)
                               Transit  started = in transit (transshipment, inland transport...)
                               Port     started = at port (port arrival)
                               Border   started = in transit, border crossing date
                               Customs  completed = cleared (customs release date)
                               Delivery started = cleared (on its way to the warehouse)
         Status never goes back (milestones). A container without movements keeps the dates typed on its header.
     Container charges: always per container, optionally linked to the movement that caused them, any currency.
         One charge typed for several containers = one record per container (same GroupId), the total split by
         Same (each gets the amount) | Equal | Pieces | Value.
         Each record is divided over the container lines by the charge type method
         (Value | Quantity | Weight | Volume | Manual) -> the real cost of every item.
         Draft -> Posted (locked) -> Cancelled. Only posted, landed charges enter the cost.
     Offload (stock in): needs every container line fully covered by POSTED invoice lines.
         FOB per unit = the invoice lines; charges per unit = posted charges / quantity RECEIVED;
         stock movement cost = landed = FOB + charges per unit.
         A charge posted after the offload (or cancelled after it) = cost adjustment: the part still in stock changes
         the average cost, the part already sold goes to COGS (inventory.CostAdjustments, SourceKind 'CNTCHARGE').
     Imported invoice (from containers): exporter reference required to post; charges and landed cost adjustments
         are refused on the invoice (they belong to the containers); the invoice page shows the container charges
         that fall on its lines (read-only). Receipt mode is automatic: 2 with containers, 1 without.
     Attachments: per container, general or linked to a movement and / or a charge, with an attachment type.
         One upload for several containers = one record per container, the file stored once (logistics.Files).

   Migration: the containers of script 24 were test data and are CLEARED the first time this script runs. The script
   stops (and changes nothing) when a container is still offloaded. Reverse those first:
       UPDATE logistics.Containers SET Status = 6 WHERE Status = 7;   -- closed test containers
       EXEC logistics.usp_Container_CancelOffload @Id = <id>, @Reason = N'Reset for script 27';   -- each offloaded one
   Legacy objects are KEPT (unused) because Schema.sql re-applies scripts 24-26 at every start-up and their old
   procedures must still compile: logistics.ContainerInvoices / ContainerEvents / ContainerFiles,
   ContainerLines.PurchaseDocumentId / PurchaseLineId (now nullable), types tvp_ContainerInvoice / tvp_ContainerLine.
   The old procedures _AvailableInvoices, _AddEvent and usp_ContainerFile_* are dropped at the end of every run.

   Fixed on the way: inventory.usp_Item_RebuildCosts matched reversals by family + document id only (a cancelled
   invoice could hide a container offload with the same id); it now matches the type code too (and, for containers,
   the offload number: an offload reversed and done again is KTG-2026-0001/2), and the last / FOB cost come from the
   latest RECEIPT (invoice received at posting or container offload). A draft purchase order that went through an
   approval request can be deleted again (its approval rows are removed with it).

   Errors: 69016 not fully invoiced (offload), 69017 container line already invoiced, 69018 cost adjustments exist,
           70000 validation, 70001 duplicate, 70004 concurrency, 70005 not editable, 70006 not found,
           70010 invalid status, 70012 container busy in another movement, 70013 allocation data missing,
           70014 in use, 65018 exporter reference required, 65019 container line mismatch / exceeded,
           65020 charges belong to the containers, 65021 the order is shipped in containers,
           67012 no landed cost adjustment on an imported invoice.
   Permissions: containers.movements.manage 1410, containers.charges.view 1420 / create 1430 / post 1440 /
                cancel 1450, containers.attachments.manage 1460, masterdata.movementtypes.manage 1470.

   Requires scripts 19-26. Idempotent.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'logistics.Containers', N'U') IS NULL OR OBJECT_ID(N'purchase.PurchaseOrderApprovals', N'U') IS NULL
BEGIN
    RAISERROR ('Run scripts 19 to 26 before this script.', 16, 1);
    SET NOEXEC ON;
END
GO

/* ================================================================== 0. Test data of the old model */

IF COL_LENGTH(N'logistics.ContainerLines', N'PoLineId') IS NULL
   AND EXISTS (SELECT 1 FROM logistics.Containers WHERE OffloadedDate IS NOT NULL OR Status IN (6, 7))
BEGIN
    RAISERROR ('Script 27 stopped, nothing changed: some containers are still offloaded. Reverse them first (see the header of this script), then run it again.', 16, 1);
    SET NOEXEC ON;
END
GO

IF COL_LENGTH(N'logistics.ContainerLines', N'PoLineId') IS NULL
BEGIN
    DECLARE @n INT = (SELECT COUNT(*) FROM logistics.Containers);
    DELETE FROM logistics.ContainerAudit;
    IF OBJECT_ID(N'logistics.ContainerFiles', N'U') IS NOT NULL EXEC (N'DELETE FROM logistics.ContainerFiles;');
    IF OBJECT_ID(N'logistics.ContainerEvents', N'U') IS NOT NULL EXEC (N'DELETE FROM logistics.ContainerEvents;');
    DELETE FROM logistics.ContainerLines;
    IF OBJECT_ID(N'logistics.ContainerInvoices', N'U') IS NOT NULL EXEC (N'DELETE FROM logistics.ContainerInvoices;');
    DELETE FROM logistics.Containers;
    -- offload + reversal pairs of the test containers (net zero, already ignored by the cost replay)
    DELETE FROM inventory.StockMovements WHERE DocumentTypeCode = N'CNT';
    -- draft invoices that were attached to a test container are local purchases again
    UPDATE purchase.PurchaseDocuments SET ReceiptMode = 1 WHERE Status = 1 AND ReceiptMode = 2;
    PRINT CAST(@n AS NVARCHAR(10)) + ' test container(s) of the old model cleared';
END
GO

/* ================================================================== 1. Container lines come from purchase ORDER lines */

IF COL_LENGTH(N'logistics.ContainerLines', N'PoLineId') IS NULL
BEGIN
    -- legacy columns (old procedures of script 24 still reference them): no constraint, nullable, unused
    IF OBJECT_ID(N'logistics.UQ_ContainerLines_Source', N'UQ') IS NOT NULL
        ALTER TABLE logistics.ContainerLines DROP CONSTRAINT UQ_ContainerLines_Source;
    IF OBJECT_ID(N'logistics.FK_ContainerLines_Invoice', N'F') IS NOT NULL
        ALTER TABLE logistics.ContainerLines DROP CONSTRAINT FK_ContainerLines_Invoice;
    IF OBJECT_ID(N'logistics.FK_ContainerLines_Line', N'F') IS NOT NULL
        ALTER TABLE logistics.ContainerLines DROP CONSTRAINT FK_ContainerLines_Line;
    IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ContainerLines_Source' AND object_id = OBJECT_ID(N'logistics.ContainerLines'))
        DROP INDEX IX_ContainerLines_Source ON logistics.ContainerLines;
    ALTER TABLE logistics.ContainerLines ALTER COLUMN PurchaseDocumentId INT NULL;
    ALTER TABLE logistics.ContainerLines ALTER COLUMN PurchaseLineId INT NULL;

    -- the table is empty here (cleared above), so NOT NULL columns can be added
    ALTER TABLE logistics.ContainerLines ADD
        PurchaseOrderId INT            NOT NULL,
        PoLineId        INT            NOT NULL,
        FobCostBase     DECIMAL(18,6)  NULL,        -- per base unit, from the posted invoice lines (offload)
        ChargesBase     DECIMAL(18,2)  NOT NULL CONSTRAINT DF_ContainerLines_Charges DEFAULT (0),   -- posted landed charges on the line
        LandedCostBase  DECIMAL(18,6)  NULL;        -- per base unit = FOB + charges / quantity received (offload)
    PRINT 'ContainerLines: added PurchaseOrderId, PoLineId, FobCostBase, ChargesBase, LandedCostBase';
END
GO

IF OBJECT_ID(N'logistics.FK_ContainerLines_Order', N'F') IS NULL
BEGIN
    ALTER TABLE logistics.ContainerLines ADD CONSTRAINT FK_ContainerLines_Order FOREIGN KEY (PurchaseOrderId) REFERENCES purchase.PurchaseDocuments (Id);
    ALTER TABLE logistics.ContainerLines ADD CONSTRAINT FK_ContainerLines_PoLine FOREIGN KEY (PoLineId) REFERENCES purchase.PurchaseDocumentLines (Id);
    ALTER TABLE logistics.ContainerLines ADD CONSTRAINT UQ_ContainerLines_PoLine UNIQUE (ContainerId, PoLineId);
    CREATE NONCLUSTERED INDEX IX_ContainerLines_PoLine ON logistics.ContainerLines (PoLineId);
    CREATE NONCLUSTERED INDEX IX_ContainerLines_Order  ON logistics.ContainerLines (PurchaseOrderId);
    PRINT 'ContainerLines: purchase order keys and indexes created';
END
GO

IF COL_LENGTH(N'logistics.Containers', N'PurchaseOrderId') IS NULL
BEGIN
    ALTER TABLE logistics.Containers ADD PurchaseOrderId INT NULL
        CONSTRAINT FK_Containers_Order FOREIGN KEY REFERENCES purchase.PurchaseDocuments (Id);
    PRINT 'Containers: added PurchaseOrderId (the order the container was created from)';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Containers_Order' AND object_id = OBJECT_ID(N'logistics.Containers'))
    CREATE NONCLUSTERED INDEX IX_Containers_Order ON logistics.Containers (PurchaseOrderId);
GO

-- Once a container has travelled with a movement, its milestone dates always come from its movements (even when that
-- movement is later cancelled or the container removed from it).
IF COL_LENGTH(N'logistics.Containers', N'DatesFromMovements') IS NULL
BEGIN
    ALTER TABLE logistics.Containers ADD DatesFromMovements BIT NOT NULL CONSTRAINT DF_Containers_DatesFromMovements DEFAULT (0);
    PRINT 'Containers: added DatesFromMovements';
END
GO

IF COL_LENGTH(N'purchase.PurchaseDocumentLines', N'ContainerLineId') IS NULL
BEGIN
    ALTER TABLE purchase.PurchaseDocumentLines ADD ContainerLineId INT NULL
        CONSTRAINT FK_PurchaseDocumentLines_ContainerLine FOREIGN KEY REFERENCES logistics.ContainerLines (Id);
    PRINT 'PurchaseDocumentLines: added ContainerLineId (invoice line -> container line)';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_PurchaseDocumentLines_ContainerLine'
               AND object_id = OBJECT_ID(N'purchase.PurchaseDocumentLines'))
    CREATE NONCLUSTERED INDEX IX_PurchaseDocumentLines_ContainerLine ON purchase.PurchaseDocumentLines (ContainerLineId)
        WHERE ContainerLineId IS NOT NULL;
GO

/* ================================================================== 2. Types (new names: the old ones stay for script 24) */

IF TYPE_ID(N'logistics.tvp_ContainerLoadLine') IS NULL
BEGIN
    CREATE TYPE logistics.tvp_ContainerLoadLine AS TABLE
    (
        LineNumber    INT           NOT NULL PRIMARY KEY,
        PoLineId      INT           NOT NULL,      -- purchase ORDER line
        QuantityBase  INT           NOT NULL,      -- base units (pieces) loaded
        OilIncluded   BIT           NOT NULL,
        OilQtyPerUnit DECIMAL(9,2)  NULL,          -- NULL = the item's value
        Notes         NVARCHAR(300) NULL
    );
    PRINT 'Created type logistics.tvp_ContainerLoadLine';
END
GO

IF TYPE_ID(N'logistics.tvp_IdList') IS NULL
    CREATE TYPE logistics.tvp_IdList AS TABLE (Id INT NOT NULL PRIMARY KEY);
GO

IF TYPE_ID(N'logistics.tvp_ContainerLineQty') IS NULL
    CREATE TYPE logistics.tvp_ContainerLineQty AS TABLE (ContainerLineId INT NOT NULL PRIMARY KEY, QuantityBase INT NOT NULL);
GO

IF TYPE_ID(N'logistics.tvp_ChargeManual') IS NULL
    CREATE TYPE logistics.tvp_ChargeManual AS TABLE (ContainerLineId INT NOT NULL PRIMARY KEY, AmountBase DECIMAL(18,2) NOT NULL);
GO

IF TYPE_ID(N'purchase.tvp_LineContainer') IS NULL
    CREATE TYPE purchase.tvp_LineContainer AS TABLE (LineNumber INT NOT NULL PRIMARY KEY, ContainerLineId INT NOT NULL);
GO

/* ================================================================== 3. Movement types and movements */

IF OBJECT_ID(N'masterdata.MovementTypes', N'U') IS NULL
BEGIN
    CREATE TABLE masterdata.MovementTypes
    (
        Id           INT IDENTITY(1,1) NOT NULL,
        TypeCode     NVARCHAR(10)  NOT NULL,
        TypeName     NVARCHAR(100) NOT NULL,
        Stage        NVARCHAR(10)  NOT NULL,      -- Origin | Sea | Transit | Port | Border | Customs | Delivery
        SortOrder    INT           NOT NULL CONSTRAINT DF_MovementTypes_Sort DEFAULT (0),
        IsActive     BIT           NOT NULL CONSTRAINT DF_MovementTypes_IsActive DEFAULT (1),
        CreatedAtUtc DATETIME2(3)  NOT NULL CONSTRAINT DF_MovementTypes_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy    INT           NULL,
        UpdatedAtUtc DATETIME2(3)  NULL,
        UpdatedBy    INT           NULL,
        RowVersion   ROWVERSION    NOT NULL,
        CONSTRAINT PK_MovementTypes PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_MovementTypes_Code UNIQUE (TypeCode),
        CONSTRAINT CK_MovementTypes_Stage CHECK (Stage IN (N'Origin', N'Sea', N'Transit', N'Port', N'Border', N'Customs', N'Delivery')),
        CONSTRAINT FK_MovementTypes_CreatedBy FOREIGN KEY (CreatedBy) REFERENCES security.Users (Id),
        CONSTRAINT FK_MovementTypes_UpdatedBy FOREIGN KEY (UpdatedBy) REFERENCES security.Users (Id)
    );
    PRINT 'Created masterdata.MovementTypes';
END
GO

MERGE masterdata.MovementTypes AS t
USING (VALUES
    (N'LOAD',     N'Loading at supplier', N'Origin',   10),
    (N'SEA',      N'Sea freight',         N'Sea',      20),
    (N'TRANSHIP', N'Transshipment',       N'Transit',  30),
    (N'PORT',     N'Port arrival',        N'Port',     40),
    (N'INLAND',   N'Inland transport',    N'Transit',  50),
    (N'BORDER',   N'Border crossing',     N'Border',   60),
    (N'CUSTOMS',  N'Customs clearance',   N'Customs',  70),
    (N'DELIVERY', N'Warehouse delivery',  N'Delivery', 80)
) AS s (TypeCode, TypeName, Stage, SortOrder)
ON t.TypeCode = s.TypeCode
WHEN NOT MATCHED BY TARGET THEN
    INSERT (TypeCode, TypeName, Stage, SortOrder) VALUES (s.TypeCode, s.TypeName, s.Stage, s.SortOrder);
GO

MERGE inventory.DocumentTypes AS t
USING (VALUES (N'MOV', N'Shipment Movement', N'Logistics', 0, N'MOV-', 0, 0)) AS s (Code, Name, Family, StockDirection, NumberPrefix, NumberOnPost, RequiresReason)
ON t.Code = s.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Family, StockDirection, NumberPrefix, NumberOnPost, RequiresReason)
    VALUES (s.Code, s.Name, s.Family, s.StockDirection, s.NumberPrefix, s.NumberOnPost, s.RequiresReason);
GO

UPDATE inventory.DocumentTypes
SET DefaultPricing = N'None', PriceEditable = 0, NumberPerBranch = 0, YearInNumber = 1, NumberLength = 6
WHERE Code = N'MOV';
GO

IF OBJECT_ID(N'logistics.Movements', N'U') IS NULL
BEGIN
    CREATE TABLE logistics.Movements
    (
        Id              INT IDENTITY(1,1) NOT NULL,
        DocumentTypeId  INT            NOT NULL,        -- MOV
        MovementNo      NVARCHAR(30)   NOT NULL,        -- MOV-2026-000001
        MovementTypeId  INT            NOT NULL,
        FromPlaceId     INT            NOT NULL,        -- masterdata.Ports (ports, borders, inland places)
        ToPlaceId       INT            NOT NULL,        -- the same place for a stay (port, customs, border)
        PlannedDate     DATE           NULL,
        StartDate       DATE           NULL,            -- departure / arrival at the place (set by Start)
        Eta             DATE           NULL,            -- expected end
        EndDate         DATE           NULL,            -- arrival / release (set by Complete)
        CarrierPartyId  INT            NULL,            -- shipping line, transporter, clearing agent...
        VehicleOrVessel NVARCHAR(100)  NULL,            -- vessel name / truck plate
        VoyageNo        NVARCHAR(30)   NULL,
        Reference       NVARCHAR(50)   NULL,            -- booking, waybill, declaration...
        Status          TINYINT        NOT NULL CONSTRAINT DF_Movements_Status DEFAULT (1),   -- 1 Planned, 2 In progress, 3 Completed, 4 Cancelled
        CancelReason    NVARCHAR(300)  NULL,
        Notes           NVARCHAR(1000) NULL,
        StartedAtUtc    DATETIME2(3)   NULL,
        StartedBy       INT            NULL,
        CompletedAtUtc  DATETIME2(3)   NULL,
        CompletedBy     INT            NULL,
        CancelledAtUtc  DATETIME2(3)   NULL,
        CancelledBy     INT            NULL,
        CreatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_Movements_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy       INT            NULL,
        UpdatedAtUtc    DATETIME2(3)   NULL,
        UpdatedBy       INT            NULL,
        RowVersion      ROWVERSION     NOT NULL,
        CONSTRAINT PK_Movements PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_Movements_No UNIQUE (MovementNo),
        CONSTRAINT CK_Movements_Status CHECK (Status BETWEEN 1 AND 4),
        CONSTRAINT CK_Movements_Dates CHECK (EndDate IS NULL OR StartDate IS NULL OR EndDate >= StartDate),
        CONSTRAINT FK_Movements_DocType     FOREIGN KEY (DocumentTypeId) REFERENCES inventory.DocumentTypes (Id),
        CONSTRAINT FK_Movements_Type        FOREIGN KEY (MovementTypeId) REFERENCES masterdata.MovementTypes (Id),
        CONSTRAINT FK_Movements_From        FOREIGN KEY (FromPlaceId)    REFERENCES masterdata.Ports (Id),
        CONSTRAINT FK_Movements_To          FOREIGN KEY (ToPlaceId)      REFERENCES masterdata.Ports (Id),
        CONSTRAINT FK_Movements_Carrier     FOREIGN KEY (CarrierPartyId) REFERENCES masterdata.Parties (Id),
        CONSTRAINT FK_Movements_StartedBy   FOREIGN KEY (StartedBy)      REFERENCES security.Users (Id),
        CONSTRAINT FK_Movements_CompletedBy FOREIGN KEY (CompletedBy)    REFERENCES security.Users (Id),
        CONSTRAINT FK_Movements_CancelledBy FOREIGN KEY (CancelledBy)    REFERENCES security.Users (Id),
        CONSTRAINT FK_Movements_CreatedBy   FOREIGN KEY (CreatedBy)      REFERENCES security.Users (Id),
        CONSTRAINT FK_Movements_UpdatedBy   FOREIGN KEY (UpdatedBy)      REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_Movements_Status ON logistics.Movements (Status, StartDate DESC);
    PRINT 'Created logistics.Movements';
END
GO

IF OBJECT_ID(N'logistics.MovementContainers', N'U') IS NULL
BEGIN
    CREATE TABLE logistics.MovementContainers
    (
        Id          INT IDENTITY(1,1) NOT NULL,
        MovementId  INT           NOT NULL,
        ContainerId INT           NOT NULL,
        CONSTRAINT PK_MovementContainers PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_MovementContainers UNIQUE (MovementId, ContainerId),
        CONSTRAINT FK_MovementContainers_Movement  FOREIGN KEY (MovementId)  REFERENCES logistics.Movements (Id),
        CONSTRAINT FK_MovementContainers_Container FOREIGN KEY (ContainerId) REFERENCES logistics.Containers (Id)
    );
    CREATE NONCLUSTERED INDEX IX_MovementContainers_Container ON logistics.MovementContainers (ContainerId);
    PRINT 'Created logistics.MovementContainers';
END
GO

/* ================================================================== 4. Container charges */

IF OBJECT_ID(N'logistics.ContainerCharges', N'U') IS NULL
BEGIN
    CREATE TABLE logistics.ContainerCharges
    (
        Id                   INT IDENTITY(1,1) NOT NULL,
        ContainerId          INT              NOT NULL,
        MovementId           INT              NULL,          -- the movement that caused it (optional)
        GroupId              UNIQUEIDENTIFIER NULL,          -- records created together for several containers
        ChargeTypeId         INT              NOT NULL,      -- purchase.ChargeTypes
        Description          NVARCHAR(200)    NULL,
        ProviderPartyId      INT              NULL,          -- forwarder, clearing agent, transporter...
        Reference            NVARCHAR(100)    NULL,          -- provider invoice / receipt number
        ChargeDate           DATE             NOT NULL,
        CurrencyId           INT              NOT NULL,
        RateType             TINYINT          NOT NULL CONSTRAINT DF_ContainerCharges_RateType DEFAULT (1),
        ExchangeRate         DECIMAL(18,6)    NOT NULL,      -- units of the charge currency per 1 base unit
        Amount               DECIMAL(18,2)    NOT NULL,
        AmountBase           DECIMAL(18,2)    NOT NULL,
        AllocationMethod     NVARCHAR(10)     NOT NULL,      -- Value | Quantity | Weight | Volume | Manual
        IncludeInLandedCost  BIT              NOT NULL,      -- copied from the charge type
        Status               TINYINT          NOT NULL CONSTRAINT DF_ContainerCharges_Status DEFAULT (1),   -- 1 Draft, 2 Posted, 3 Cancelled
        AppliedAtOffload     BIT              NOT NULL CONSTRAINT DF_ContainerCharges_AtOffload DEFAULT (0), -- in the offload cost
        AdjustedAfterOffload BIT              NOT NULL CONSTRAINT DF_ContainerCharges_Adjusted DEFAULT (0),  -- posted after: cost adjustment
        Notes                NVARCHAR(300)    NULL,
        PostedAtUtc          DATETIME2(3)     NULL,
        PostedBy             INT              NULL,
        CancelledAtUtc       DATETIME2(3)     NULL,
        CancelledBy          INT              NULL,
        CancelReason         NVARCHAR(300)    NULL,
        CreatedAtUtc         DATETIME2(3)     NOT NULL CONSTRAINT DF_ContainerCharges_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy            INT              NULL,
        UpdatedAtUtc         DATETIME2(3)     NULL,
        UpdatedBy            INT              NULL,
        RowVersion           ROWVERSION       NOT NULL,
        CONSTRAINT PK_ContainerCharges PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_ContainerCharges_Status CHECK (Status BETWEEN 1 AND 3),
        CONSTRAINT CK_ContainerCharges_Method CHECK (AllocationMethod IN (N'Value', N'Quantity', N'Weight', N'Volume', N'Manual')),
        CONSTRAINT CK_ContainerCharges_Amount CHECK (Amount >= 0),
        CONSTRAINT CK_ContainerCharges_Rate CHECK (ExchangeRate > 0),
        CONSTRAINT FK_ContainerCharges_Container   FOREIGN KEY (ContainerId)     REFERENCES logistics.Containers (Id),
        CONSTRAINT FK_ContainerCharges_Movement    FOREIGN KEY (MovementId)      REFERENCES logistics.Movements (Id),
        CONSTRAINT FK_ContainerCharges_Type        FOREIGN KEY (ChargeTypeId)    REFERENCES purchase.ChargeTypes (Id),
        CONSTRAINT FK_ContainerCharges_Provider    FOREIGN KEY (ProviderPartyId) REFERENCES masterdata.Parties (Id),
        CONSTRAINT FK_ContainerCharges_Currency    FOREIGN KEY (CurrencyId)      REFERENCES masterdata.Currencies (Id),
        CONSTRAINT FK_ContainerCharges_PostedBy    FOREIGN KEY (PostedBy)        REFERENCES security.Users (Id),
        CONSTRAINT FK_ContainerCharges_CancelledBy FOREIGN KEY (CancelledBy)     REFERENCES security.Users (Id),
        CONSTRAINT FK_ContainerCharges_CreatedBy   FOREIGN KEY (CreatedBy)       REFERENCES security.Users (Id),
        CONSTRAINT FK_ContainerCharges_UpdatedBy   FOREIGN KEY (UpdatedBy)       REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_ContainerCharges_Container ON logistics.ContainerCharges (ContainerId, Status);
    CREATE NONCLUSTERED INDEX IX_ContainerCharges_Movement  ON logistics.ContainerCharges (MovementId) WHERE MovementId IS NOT NULL;
    CREATE NONCLUSTERED INDEX IX_ContainerCharges_Group     ON logistics.ContainerCharges (GroupId) WHERE GroupId IS NOT NULL;
    PRINT 'Created logistics.ContainerCharges';
END
GO

IF OBJECT_ID(N'logistics.ContainerChargeAllocations', N'U') IS NULL
BEGIN
    CREATE TABLE logistics.ContainerChargeAllocations
    (
        Id              INT IDENTITY(1,1) NOT NULL,
        ChargeId        INT           NOT NULL,
        ContainerLineId INT           NOT NULL,
        Basis           DECIMAL(18,6) NULL,          -- value / pieces / kg / cbm used (NULL = manual)
        AmountBase      DECIMAL(18,2) NOT NULL,
        IsManual        BIT           NOT NULL CONSTRAINT DF_ContainerChargeAllocations_Manual DEFAULT (0),
        CONSTRAINT PK_ContainerChargeAllocations PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_ContainerChargeAllocations UNIQUE (ChargeId, ContainerLineId),
        CONSTRAINT CK_ContainerChargeAllocations_Amount CHECK (AmountBase >= 0),
        CONSTRAINT FK_ContainerChargeAllocations_Charge FOREIGN KEY (ChargeId)        REFERENCES logistics.ContainerCharges (Id),
        CONSTRAINT FK_ContainerChargeAllocations_Line   FOREIGN KEY (ContainerLineId) REFERENCES logistics.ContainerLines (Id)
    );
    CREATE NONCLUSTERED INDEX IX_ContainerChargeAllocations_Line ON logistics.ContainerChargeAllocations (ContainerLineId);
    PRINT 'Created logistics.ContainerChargeAllocations';
END
GO

/* ================================================================== 5. Attachments: the file once, one record per container */

IF OBJECT_ID(N'logistics.Files', N'U') IS NULL
BEGIN
    CREATE TABLE logistics.Files
    (
        Id           INT IDENTITY(1,1) NOT NULL,
        FileName     NVARCHAR(255)  NOT NULL,
        ContentType  NVARCHAR(100)  NOT NULL,
        SizeBytes    INT            NOT NULL,
        Content      VARBINARY(MAX) NOT NULL,
        CreatedAtUtc DATETIME2(3)   NOT NULL CONSTRAINT DF_LogisticsFiles_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy    INT            NULL,
        CONSTRAINT PK_LogisticsFiles PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_LogisticsFiles_Size CHECK (SizeBytes > 0),
        CONSTRAINT FK_LogisticsFiles_CreatedBy FOREIGN KEY (CreatedBy) REFERENCES security.Users (Id)
    );
    PRINT 'Created logistics.Files';
END
GO

IF OBJECT_ID(N'logistics.ContainerAttachments', N'U') IS NULL
BEGIN
    CREATE TABLE logistics.ContainerAttachments
    (
        Id               INT IDENTITY(1,1) NOT NULL,
        ContainerId      INT              NOT NULL,
        MovementId       INT              NULL,        -- NULL = the container in general
        ChargeId         INT              NULL,        -- e.g. the provider invoice of a charge
        AttachmentTypeId INT              NULL,
        FileId           INT              NOT NULL,
        Note             NVARCHAR(300)    NULL,
        DocumentDate     DATE             NULL,
        GroupId          UNIQUEIDENTIFIER NULL,        -- records created by one upload for several containers
        CreatedAtUtc     DATETIME2(3)     NOT NULL CONSTRAINT DF_ContainerAttachments_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy        INT              NULL,
        CONSTRAINT PK_ContainerAttachments PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_ContainerAttachments_Container FOREIGN KEY (ContainerId)      REFERENCES logistics.Containers (Id),
        CONSTRAINT FK_ContainerAttachments_Movement  FOREIGN KEY (MovementId)       REFERENCES logistics.Movements (Id),
        CONSTRAINT FK_ContainerAttachments_Charge    FOREIGN KEY (ChargeId)         REFERENCES logistics.ContainerCharges (Id),
        CONSTRAINT FK_ContainerAttachments_Type      FOREIGN KEY (AttachmentTypeId) REFERENCES masterdata.AttachmentTypes (Id),
        CONSTRAINT FK_ContainerAttachments_File      FOREIGN KEY (FileId)           REFERENCES logistics.Files (Id),
        CONSTRAINT FK_ContainerAttachments_CreatedBy FOREIGN KEY (CreatedBy)        REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_ContainerAttachments_Container ON logistics.ContainerAttachments (ContainerId);
    CREATE NONCLUSTERED INDEX IX_ContainerAttachments_Movement  ON logistics.ContainerAttachments (MovementId) WHERE MovementId IS NOT NULL;
    CREATE NONCLUSTERED INDEX IX_ContainerAttachments_Charge    ON logistics.ContainerAttachments (ChargeId) WHERE ChargeId IS NOT NULL;
    CREATE NONCLUSTERED INDEX IX_ContainerAttachments_File      ON logistics.ContainerAttachments (FileId);
    PRINT 'Created logistics.ContainerAttachments';
END
GO

/* ================================================================== 6. Master data: movement types */

CREATE OR ALTER PROCEDURE masterdata.usp_MovementType_Search
    @Search        NVARCHAR(100) = NULL,
    @Stage         NVARCHAR(10)  = NULL,
    @IsActive      BIT           = NULL,
    @SortColumn    NVARCHAR(30)  = N'SortOrder',   -- SortOrder | TypeCode | TypeName | Stage | IsActive
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
    SET @Stage = NULLIF(LTRIM(RTRIM(@Stage)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'SortOrder', N'TypeCode', N'TypeName', N'Stage', N'IsActive') SET @SortColumn = N'SortOrder';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT t.Id, t.TypeCode, t.TypeName, t.Stage, t.SortOrder, t.IsActive,
           UsedCount = (SELECT COUNT(*) FROM logistics.Movements m WHERE m.MovementTypeId = t.Id),
           t.CreatedAtUtc, t.CreatedBy, t.UpdatedAtUtc, t.UpdatedBy, t.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.MovementTypes t
    WHERE (@Search IS NULL OR t.TypeCode LIKE N'%' + @Search + N'%' OR t.TypeName LIKE N'%' + @Search + N'%')
      AND (@Stage IS NULL OR t.Stage = @Stage)
      AND (@IsActive IS NULL OR t.IsActive = @IsActive)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'TypeCode' THEN t.TypeCode WHEN N'TypeName' THEN t.TypeName WHEN N'Stage' THEN t.Stage END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'TypeCode' THEN t.TypeCode WHEN N'TypeName' THEN t.TypeName WHEN N'Stage' THEN t.Stage END END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'SortOrder' THEN t.SortOrder END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'SortOrder' THEN t.SortOrder END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(t.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(t.IsActive AS INT) END DESC,
        t.SortOrder ASC, t.TypeCode ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_MovementType_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, TypeCode, TypeName, Stage, SortOrder, IsActive, CreatedAtUtc, CreatedBy, UpdatedAtUtc, UpdatedBy, RowVersion
    FROM masterdata.MovementTypes WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_MovementType_Lookup
    @ActiveOnly BIT = 1,
    @IncludeId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, TypeCode, TypeName, Stage, SortOrder, IsActive
    FROM masterdata.MovementTypes
    WHERE @ActiveOnly = 0 OR IsActive = 1 OR Id = @IncludeId
    ORDER BY SortOrder, TypeName;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_MovementType_Save
    @Id         INT           = NULL,
    @TypeCode   NVARCHAR(10),
    @TypeName   NVARCHAR(100),
    @Stage      NVARCHAR(10),
    @SortOrder  INT           = 0,
    @IsActive   BIT           = 1,
    @RowVersion BINARY(8)     = NULL,
    @UserId     INT           = NULL,
    @NewId      INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @TypeCode = UPPER(NULLIF(LTRIM(RTRIM(@TypeCode)), N''));
    SET @TypeName = NULLIF(LTRIM(RTRIM(@TypeName)), N'');
    SET @Stage = NULLIF(LTRIM(RTRIM(@Stage)), N'');
    IF @TypeCode IS NULL THROW 70000, 'Movement type code is required.', 1;
    IF @TypeName IS NULL THROW 70000, 'Movement type name is required.', 1;
    IF @Stage IS NULL OR @Stage NOT IN (N'Origin', N'Sea', N'Transit', N'Port', N'Border', N'Customs', N'Delivery')
        THROW 70000, 'Stage must be Origin, Sea, Transit, Port, Border, Customs or Delivery.', 1;
    IF EXISTS (SELECT 1 FROM masterdata.MovementTypes WHERE TypeCode = @TypeCode AND (@Id IS NULL OR Id <> @Id))
        THROW 70001, 'This movement type code already exists.', 1;

    IF @Id IS NULL
    BEGIN
        INSERT INTO masterdata.MovementTypes (TypeCode, TypeName, Stage, SortOrder, IsActive, CreatedBy)
        VALUES (@TypeCode, @TypeName, @Stage, ISNULL(@SortOrder, 0), ISNULL(@IsActive, 1), @UserId);
        SET @NewId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM masterdata.MovementTypes WHERE Id = @Id) THROW 70006, 'Movement type not found.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.MovementTypes WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 70004, 'This movement type was modified by another user. Reload the page and try again.', 1;
        -- the stage drives the container status: it cannot change once the type is used
        IF EXISTS (SELECT 1 FROM masterdata.MovementTypes WHERE Id = @Id AND Stage <> @Stage)
           AND EXISTS (SELECT 1 FROM logistics.Movements WHERE MovementTypeId = @Id)
            THROW 70014, 'This movement type is used by movements: its stage can no longer change.', 1;
        UPDATE masterdata.MovementTypes
        SET TypeCode = @TypeCode, TypeName = @TypeName, Stage = @Stage, SortOrder = ISNULL(@SortOrder, 0),
            IsActive = ISNULL(@IsActive, 1), UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;
        SET @NewId = @Id;
    END
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_MovementType_SetActive
    @Id INT, @IsActive BIT, @RowVersion BINARY(8) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.MovementTypes WHERE Id = @Id) THROW 70006, 'Movement type not found.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.MovementTypes WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 70004, 'This movement type was modified by another user. Reload the page and try again.', 1;
    UPDATE masterdata.MovementTypes SET IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_MovementType_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.MovementTypes WHERE Id = @Id) THROW 70006, 'Movement type not found.', 1;
    IF EXISTS (SELECT 1 FROM logistics.Movements WHERE MovementTypeId = @Id)
        THROW 70014, 'This movement type is used by movements and cannot be deleted. Deactivate it instead.', 1;
    DELETE FROM masterdata.MovementTypes WHERE Id = @Id;
END
GO

/* ------------------------------------------------------------------ Master data procedures that check usage (re-created) */

-- Re-created: ports are used by containers and by movements (the route events of script 24 are gone).
CREATE OR ALTER PROCEDURE masterdata.usp_Port_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Ports WHERE Id = @Id) THROW 69006, 'Port not found.', 1;
    IF EXISTS (SELECT 1 FROM logistics.Containers WHERE PortOfLoadingId = @Id OR PortOfDestinationId = @Id OR FinalDestinationId = @Id)
       OR EXISTS (SELECT 1 FROM logistics.Movements WHERE FromPlaceId = @Id OR ToPlaceId = @Id)
        THROW 69014, 'This place is used by containers or movements and cannot be deleted. Deactivate it instead.', 1;
    DELETE FROM masterdata.Ports WHERE Id = @Id;
END
GO

-- Re-created: attachment types are used by container attachments.
CREATE OR ALTER PROCEDURE masterdata.usp_AttachmentType_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Id = @Id) THROW 69006, 'Attachment type not found.', 1;
    IF EXISTS (SELECT 1 FROM logistics.ContainerAttachments WHERE AttachmentTypeId = @Id)
        THROW 69014, 'This attachment type is used by documents and cannot be deleted. Deactivate it instead.', 1;
    DELETE FROM masterdata.AttachmentTypes WHERE Id = @Id;
END
GO

-- Re-created: charge types are also used by container charges.
CREATE OR ALTER PROCEDURE purchase.usp_ChargeType_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM purchase.ChargeTypes WHERE Id = @Id) THROW 68006, 'Charge type not found.', 1;
    IF EXISTS (SELECT 1 FROM purchase.PurchaseCharges WHERE ChargeTypeId = @Id)
       OR EXISTS (SELECT 1 FROM logistics.ContainerCharges WHERE ChargeTypeId = @Id)
        THROW 68005, 'This charge type was used in transactions and cannot be deleted. Deactivate it instead.', 1;
    DELETE FROM purchase.ChargeTypes WHERE Id = @Id;
END
GO

/* ================================================================== 7. Charges: allocation over the container lines, container cost */

-- Divides ONE charge over the lines of its container by its method (Value | Quantity | Weight | Volume).
-- Quantity basis = received when the container is offloaded, loaded before. Value = FOB of the line once offloaded,
-- else its invoice lines, else its purchase order line (provisional).
-- Rounded to cents with the largest-remainder rule, so the shares always add up to the charge.
-- A charge already in the cost of the goods (applied at offload / adjusted after) is never spread again.
CREATE OR ALTER PROCEDURE logistics.usp_ContainerCharge_Allocate
    @ChargeId INT,
    @Silent   BIT = 0      -- 1 = keep the current allocation when the basis is missing (drafts)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ContainerId INT, @Method NVARCHAR(10), @Amount DECIMAL(18,2), @InLanded BIT, @Status TINYINT, @Frozen BIT, @TypeName NVARCHAR(100);
    SELECT @ContainerId = ch.ContainerId, @Method = ch.AllocationMethod, @Amount = ch.AmountBase, @InLanded = ch.IncludeInLandedCost,
           @Status = ch.Status, @Frozen = CASE WHEN ch.AppliedAtOffload = 1 OR ch.AdjustedAfterOffload = 1 THEN 1 ELSE 0 END,
           @TypeName = ct.ChargeName
    FROM logistics.ContainerCharges ch
    INNER JOIN purchase.ChargeTypes ct ON ct.Id = ch.ChargeTypeId
    WHERE ch.Id = @ChargeId;

    IF @ContainerId IS NULL THROW 70006, 'Charge not found.', 1;
    IF @Frozen = 1 OR @Status = 3 RETURN;
    IF @InLanded = 0
    BEGIN
        DELETE FROM logistics.ContainerChargeAllocations WHERE ChargeId = @ChargeId;
        RETURN;
    END
    IF @Method = N'Manual'
    BEGIN
        DELETE FROM logistics.ContainerChargeAllocations WHERE ChargeId = @ChargeId AND IsManual = 0;
        RETURN;
    END

    DECLARE @Lines TABLE (LineId INT PRIMARY KEY, LineNumber INT, ItemCode NVARCHAR(50), Qty DECIMAL(18,6),
                          UnitValue DECIMAL(18,6), WeightKg DECIMAL(18,3), VolumeCbm DECIMAL(18,4));
    INSERT INTO @Lines (LineId, LineNumber, ItemCode, Qty, UnitValue, WeightKg, VolumeCbm)
    SELECT cl.Id, cl.LineNumber, i.ItemCode, ISNULL(cl.ReceivedQuantityBase, cl.QuantityBase),
           COALESCE(cl.FobCostBase, inv.UnitValue, po.UnitValue, 0), i.WeightKg, i.VolumeCbm
    FROM logistics.ContainerLines cl
    INNER JOIN inventory.Items i ON i.Id = cl.ItemId
    OUTER APPLY (SELECT UnitValue = SUM(pil.LineTotal / pid.ExchangeRate) / NULLIF(SUM(pil.QuantityBase), 0)
                 FROM purchase.PurchaseDocumentLines pil
                 INNER JOIN purchase.PurchaseDocuments pid ON pid.Id = pil.DocumentId
                 WHERE pil.ContainerLineId = cl.Id AND pid.Status IN (1, 2, 4)) inv
    OUTER APPLY (SELECT UnitValue = pol.LineTotal / pod.ExchangeRate / NULLIF(pol.QuantityBase, 0)
                 FROM purchase.PurchaseDocumentLines pol
                 INNER JOIN purchase.PurchaseDocuments pod ON pod.Id = pol.DocumentId
                 WHERE pol.Id = cl.PoLineId) po
    WHERE cl.ContainerId = @ContainerId;

    DECLARE @Msg NVARCHAR(400);
    IF @Method = N'Weight' AND EXISTS (SELECT 1 FROM @Lines WHERE WeightKg IS NULL AND Qty > 0)
    BEGIN
        IF @Silent = 1 RETURN;
        SELECT TOP (1) @Msg = @TypeName + N': item ' + ItemCode + N' has no weight (kg). Set it in Item Definition or change the allocation method.'
        FROM @Lines WHERE WeightKg IS NULL AND Qty > 0 ORDER BY LineNumber;
        THROW 70013, @Msg, 1;
    END
    IF @Method = N'Volume' AND EXISTS (SELECT 1 FROM @Lines WHERE VolumeCbm IS NULL AND Qty > 0)
    BEGIN
        IF @Silent = 1 RETURN;
        SELECT TOP (1) @Msg = @TypeName + N': item ' + ItemCode + N' has no volume (CBM). Set it in Item Definition or change the allocation method.'
        FROM @Lines WHERE VolumeCbm IS NULL AND Qty > 0 ORDER BY LineNumber;
        THROW 70013, @Msg, 1;
    END

    DECLARE @Basis TABLE (LineId INT PRIMARY KEY, Basis DECIMAL(18,6), Share DECIMAL(38,10));
    INSERT INTO @Basis (LineId, Basis)
    SELECT LineId, CASE @Method WHEN N'Value' THEN Qty * UnitValue
                                WHEN N'Quantity' THEN Qty
                                WHEN N'Weight' THEN Qty * ISNULL(WeightKg, 0)
                                WHEN N'Volume' THEN Qty * ISNULL(VolumeCbm, 0) END
    FROM @Lines;
    DELETE FROM @Basis WHERE Basis IS NULL OR Basis <= 0;

    DECLARE @Total DECIMAL(18,6) = (SELECT SUM(Basis) FROM @Basis);
    IF @Total IS NULL OR @Total <= 0
    BEGIN
        IF @Silent = 1 RETURN;
        SET @Msg = @TypeName + N': the allocation basis (' + @Method + N') is zero for every line of the container. Use another method or a manual allocation.';
        THROW 70013, @Msg, 1;
    END

    UPDATE @Basis SET Share = CAST(@Amount AS DECIMAL(38,10)) * Basis / @Total;

    DELETE FROM logistics.ContainerChargeAllocations WHERE ChargeId = @ChargeId;
    INSERT INTO logistics.ContainerChargeAllocations (ChargeId, ContainerLineId, Basis, AmountBase, IsManual)
    SELECT @ChargeId, LineId, Basis, FLOOR(Share * 100) / 100, 0 FROM @Basis;

    -- the cents lost by rounding down go to the lines with the largest remainders
    DECLARE @Cents INT = CAST(ROUND((@Amount - (SELECT SUM(AmountBase) FROM logistics.ContainerChargeAllocations WHERE ChargeId = @ChargeId)) * 100, 0) AS INT);
    IF @Cents > 0
    BEGIN
        WITH r AS
        (
            SELECT a.Id, Rn = ROW_NUMBER() OVER (ORDER BY b.Share * 100 - FLOOR(b.Share * 100) DESC, b.Basis DESC, a.ContainerLineId)
            FROM logistics.ContainerChargeAllocations a
            INNER JOIN @Basis b ON b.LineId = a.ContainerLineId
            WHERE a.ChargeId = @ChargeId
        )
        UPDATE a SET AmountBase = a.AmountBase + 0.01
        FROM logistics.ContainerChargeAllocations a
        INNER JOIN r ON r.Id = a.Id
        WHERE r.Rn <= @Cents;
    END
END
GO

-- Charges per container line (posted, landed) and, once offloaded, the landed cost per unit:
-- FOB + charges / quantity received.
CREATE OR ALTER PROCEDURE logistics.usp_Container_RecalcCosts
    @ContainerId INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE cl
    SET ChargesBase = ISNULL(x.Charges, 0),
        LandedCostBase = CASE WHEN cl.FobCostBase IS NULL THEN NULL
                              WHEN ISNULL(cl.ReceivedQuantityBase, 0) > 0 THEN cl.FobCostBase + ISNULL(x.Charges, 0) / cl.ReceivedQuantityBase
                              ELSE cl.FobCostBase END
    FROM logistics.ContainerLines cl
    OUTER APPLY (SELECT Charges = SUM(a.AmountBase)
                 FROM logistics.ContainerChargeAllocations a
                 INNER JOIN logistics.ContainerCharges ch ON ch.Id = a.ChargeId
                 WHERE a.ContainerLineId = cl.Id AND ch.Status = 2 AND ch.IncludeInLandedCost = 1) x
    WHERE cl.ContainerId = @ContainerId;
END
GO

-- Spreads again every charge of the container that is not yet in the cost of the goods
-- (after the lines, the invoices or the received quantities changed).
CREATE OR ALTER PROCEDURE logistics.usp_Container_ReallocateCharges
    @ContainerId  INT,
    @PostedSilent BIT = 1,     -- 0 = a POSTED charge without basis raises an error (offload)
    @OnlyValue    BIT = 0      -- 1 = only the charges allocated by value (an invoice changed)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ChargeId INT, @Status TINYINT, @Silent BIT;
    DECLARE charges CURSOR LOCAL FAST_FORWARD FOR
        SELECT Id, Status FROM logistics.ContainerCharges
        WHERE ContainerId = @ContainerId AND Status IN (1, 2) AND AppliedAtOffload = 0 AND AdjustedAfterOffload = 0
          AND IncludeInLandedCost = 1 AND AllocationMethod <> N'Manual'
          AND (@OnlyValue = 0 OR AllocationMethod = N'Value')
        ORDER BY Id;
    OPEN charges;
    FETCH NEXT FROM charges INTO @ChargeId, @Status;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Silent = CASE WHEN @Status = 1 THEN 1 ELSE ISNULL(@PostedSilent, 1) END;
        EXEC logistics.usp_ContainerCharge_Allocate @ChargeId, @Silent;
        FETCH NEXT FROM charges INTO @ChargeId, @Status;
    END
    CLOSE charges;
    DEALLOCATE charges;
    EXEC logistics.usp_Container_RecalcCosts @ContainerId;
END
GO

-- A charge that enters (@Sign = 1) or leaves (@Sign = -1) the cost of goods already offloaded:
-- the part still in stock changes the inventory value (moving average), the part already sold goes to COGS.
-- Then the item costs are replayed (exact average, last / FOB cost from the latest receipt).
CREATE OR ALTER PROCEDURE logistics.usp_ContainerCharge_ApplyCost
    @ChargeId INT,
    @Sign     SMALLINT,
    @UserId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ContainerId INT, @Ref NVARCHAR(30), @BranchId INT, @WarehouseId INT;
    SELECT @ContainerId = c.Id, @Ref = c.ContainerRef, @BranchId = c.BranchId, @WarehouseId = c.WarehouseId
    FROM logistics.ContainerCharges ch
    INNER JOIN logistics.Containers c ON c.Id = ch.ContainerId
    WHERE ch.Id = @ChargeId;
    IF @ContainerId IS NULL THROW 70006, 'Charge not found.', 1;
    IF @WarehouseId IS NULL THROW 70010, 'The container has no offloading warehouse.', 1;

    DECLARE @Adj TABLE (LineId INT PRIMARY KEY, ItemId INT, Delta DECIMAL(18,2), Inv DECIMAL(18,2) NULL);
    INSERT INTO @Adj (LineId, ItemId, Delta)
    SELECT cl.Id, cl.ItemId, @Sign * a.AmountBase
    FROM logistics.ContainerChargeAllocations a
    INNER JOIN logistics.ContainerLines cl ON cl.Id = a.ContainerLineId
    WHERE a.ChargeId = @ChargeId AND a.AmountBase <> 0;

    -- per item: what the container brought, and how much of it can still be in stock (capped by the warehouse stock)
    DECLARE @Items TABLE (ItemId INT PRIMARY KEY, Received DECIMAL(18,6), Remaining DECIMAL(18,6), CompanyOnHand DECIMAL(18,6));
    INSERT INTO @Items (ItemId, Received, Remaining, CompanyOnHand)
    SELECT x.ItemId, x.Received,
           CASE WHEN oh.Q < x.Received THEN CASE WHEN oh.Q > 0 THEN oh.Q ELSE 0 END ELSE x.Received END,
           inventory.fn_StockOnHand(x.ItemId, NULL)
    FROM (SELECT cl.ItemId, Received = SUM(ISNULL(cl.ReceivedQuantityBase, 0))
          FROM logistics.ContainerLines cl
          WHERE cl.ContainerId = @ContainerId
          GROUP BY cl.ItemId) x
    CROSS APPLY (SELECT Q = inventory.fn_StockOnHand(x.ItemId, @WarehouseId)) oh
    WHERE x.ItemId IN (SELECT ItemId FROM @Adj);

    UPDATE a
    SET Inv = CASE WHEN i.CompanyOnHand <= 0 OR i.Received <= 0 THEN 0 ELSE ROUND(a.Delta * i.Remaining / i.Received, 2) END
    FROM @Adj a
    INNER JOIN @Items i ON i.ItemId = a.ItemId;

    INSERT INTO inventory.CostAdjustments (AdjustmentDate, ItemId, WarehouseId, BranchId, Kind, AmountBase, SourceKind, SourceId, SourceNumber, PurchaseLineId, CreatedBy)
    SELECT SYSUTCDATETIME(), a.ItemId, @WarehouseId, @BranchId, k.Kind, k.Amount, N'CNTCHARGE', @ChargeId, @Ref, NULL, @UserId
    FROM @Adj a
    CROSS APPLY (VALUES (N'Inventory', ISNULL(a.Inv, 0)), (N'COGS', a.Delta - ISNULL(a.Inv, 0))) k (Kind, Amount)
    WHERE k.Amount <> 0;

    DECLARE @ItemId INT;
    DECLARE items CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT ItemId FROM @Adj;
    OPEN items;
    FETCH NEXT FROM items INTO @ItemId;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC inventory.usp_Item_RebuildCosts @ItemId;
        FETCH NEXT FROM items INTO @ItemId;
    END
    CLOSE items;
    DEALLOCATE items;
END
GO

/* ================================================================== 8. Container status from the movements */

-- Status (milestones, never back): 1 Draft, 2 Confirmed, 3 In Transit, 4 At Port, 5 Cleared, 6 Offloaded, 7 Closed, 8 Cancelled.
-- With movements (started or completed) the milestone dates come from them - for good once a container has travelled
-- with one (DatesFromMovements); a container that never moved keeps the dates typed on its header.
CREATE OR ALTER PROCEDURE logistics.usp_Container_RefreshStatus
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasMovements BIT = 0, @Level INT = 2, @Dispatch DATE, @PortArrival DATE, @Border DATE, @Customs DATE;

    SELECT @HasMovements = CASE WHEN COUNT(*) > 0 THEN 1 ELSE 0 END,
           @Level = ISNULL(MAX(CASE WHEN mt.Stage = N'Delivery' THEN 5
                                    WHEN mt.Stage = N'Customs' AND m.Status = 3 THEN 5
                                    WHEN mt.Stage = N'Port' THEN 4
                                    WHEN mt.Stage = N'Sea' AND m.Status = 3 THEN 4
                                    WHEN mt.Stage = N'Origin' THEN 2
                                    ELSE 3 END), 2),
           @Dispatch    = MIN(CASE WHEN mt.Stage IN (N'Sea', N'Transit', N'Border') THEN m.StartDate END),
           @PortArrival = MAX(CASE WHEN mt.Stage = N'Sea' AND m.Status = 3 THEN m.EndDate WHEN mt.Stage = N'Port' THEN m.StartDate END),
           @Border      = MAX(CASE WHEN mt.Stage = N'Border' THEN m.StartDate END),
           @Customs     = MAX(CASE WHEN mt.Stage = N'Customs' AND m.Status = 3 THEN m.EndDate END)
    FROM logistics.MovementContainers mc
    INNER JOIN logistics.Movements m       ON m.Id = mc.MovementId
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    WHERE mc.ContainerId = @Id AND m.Status IN (2, 3);

    -- once the container has travelled with a movement, the dates always follow the movements (NULL when none is left)
    IF @HasMovements = 1 OR EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @Id AND DatesFromMovements = 1)
        UPDATE logistics.Containers
        SET DispatchDate = @Dispatch, ActualPortArrival = @PortArrival, BorderCrossingDate = @Border, CustomsReleaseDate = @Customs,
            DatesFromMovements = 1
        WHERE Id = @Id;

    UPDATE c
    SET TotalLines         = ISNULL(x.Lines, 0),
        TotalAllocatedBase = ISNULL(x.Allocated, 0),
        TotalReceivedBase  = ISNULL(x.Received, 0),
        TotalOilQty        = ISNULL(x.Oil, 0),
        Status = CASE WHEN c.Status IN (7, 8) THEN c.Status
                      WHEN c.OffloadedDate IS NOT NULL THEN 6
                      WHEN c.ConfirmedAtUtc IS NULL THEN 1
                      ELSE (SELECT MAX(s.v) FROM (VALUES (2),
                                                         (CASE WHEN @HasMovements = 1 THEN @Level END),
                                                         (CASE WHEN c.CustomsReleaseDate IS NOT NULL THEN 5
                                                               WHEN c.ActualPortArrival IS NOT NULL THEN 4
                                                               WHEN c.DispatchDate IS NOT NULL THEN 3 END)) s (v)) END,
        CurrentLocation = CASE WHEN c.Status = 8 THEN c.CurrentLocation
                               WHEN c.OffloadedDate IS NOT NULL THEN LEFT(w.WarehouseName, 100)
                               WHEN mv.Place IS NOT NULL THEN LEFT(mv.Place, 100)
                               WHEN c.CustomsReleaseDate IS NOT NULL OR c.ActualPortArrival IS NOT NULL THEN pd.PortName
                               WHEN c.DispatchDate IS NOT NULL THEN N'In transit'
                               END
    FROM logistics.Containers c
    LEFT JOIN masterdata.Warehouses w ON w.Id = c.WarehouseId
    LEFT JOIN masterdata.Ports pd     ON pd.Id = c.PortOfDestinationId
    CROSS APPLY (SELECT Lines = COUNT(*), Allocated = SUM(QuantityBase), Received = SUM(ISNULL(ReceivedQuantityBase, 0)),
                        Oil = SUM(TotalOilQty)
                 FROM logistics.ContainerLines WHERE ContainerId = @Id) x
    OUTER APPLY (SELECT TOP (1) Place = CASE WHEN m.Status = 3 THEN tp.PortName
                                             WHEN m.FromPlaceId = m.ToPlaceId THEN mt.TypeName + N' - ' + fp.PortName
                                             ELSE mt.TypeName + N': ' + fp.PortName + N' ' + NCHAR(8594) + N' ' + tp.PortName END
                 FROM logistics.MovementContainers mc
                 INNER JOIN logistics.Movements m       ON m.Id = mc.MovementId
                 INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
                 INNER JOIN masterdata.Ports fp         ON fp.Id = m.FromPlaceId
                 INNER JOIN masterdata.Ports tp         ON tp.Id = m.ToPlaceId
                 WHERE mc.ContainerId = @Id AND m.Status IN (2, 3)
                 ORDER BY CASE WHEN m.Status = 2 THEN 0 ELSE 1 END, COALESCE(m.EndDate, m.StartDate) DESC, m.Id DESC) mv
    WHERE c.Id = @Id;
END
GO

/* ================================================================== 9. Containers: search, details */

CREATE OR ALTER PROCEDURE logistics.usp_Container_Search
    @Search              NVARCHAR(100) = NULL,   -- ref, container no., B/L, vessel, PO / PI no., commercial invoice, supplier
    @ContainerRef        NVARCHAR(30)  = NULL,
    @ContainerNo         NVARCHAR(20)  = NULL,
    @SupplierId          INT           = NULL,
    @PurchaseDocumentId  INT           = NULL,   -- a purchase ORDER or a purchase INVOICE linked to the container
    @PurchaseOrderId     INT           = NULL,   -- containers carrying lines of this order
    @CommercialInvoiceNo NVARCHAR(50)  = NULL,
    @ItemId              INT           = NULL,
    @BlNo                NVARCHAR(30)  = NULL,
    @Status              TINYINT       = NULL,
    @PortId              INT           = NULL,
    @WarehouseId         INT           = NULL,
    @BranchId            INT           = NULL,
    @MovementId          INT           = NULL,   -- containers of this movement
    @OrderMonthKey       INT           = NULL,   -- e.g. 202601
    @DateFrom            DATE          = NULL,   -- order date
    @DateTo              DATE          = NULL,
    @SortColumn          NVARCHAR(30)  = N'OrderDate',  -- ContainerRef | ContainerNo | OrderDate | DispatchDate | Eta | Status | CreatedAtUtc
    @SortDirection       NVARCHAR(4)   = N'DESC',
    @PageNumber          INT           = 1,
    @PageSize            INT           = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @ContainerRef = NULLIF(LTRIM(RTRIM(@ContainerRef)), N'');
    SET @ContainerNo = NULLIF(LTRIM(RTRIM(@ContainerNo)), N'');
    SET @CommercialInvoiceNo = NULLIF(LTRIM(RTRIM(@CommercialInvoiceNo)), N'');
    SET @BlNo = NULLIF(LTRIM(RTRIM(@BlNo)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'ContainerRef', N'ContainerNo', N'OrderDate', N'DispatchDate', N'Eta', N'Status', N'CreatedAtUtc')
        SET @SortColumn = N'OrderDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT c.Id, c.ContainerRef, c.ContainerNo, ct.TypeCode AS ContainerTypeCode, ct.TypeName AS ContainerTypeName,
           c.OrderDate, c.OrderMonthKey, OrderMonth = FORMAT(c.OrderDate, N'MMM-yyyy', N'en-US'),
           c.BranchId, b.BranchCode, b.BranchName, c.WarehouseId, w.WarehouseCode, w.WarehouseName,
           c.PurchaseOrderId, mpo.DocumentNumber AS PurchaseOrderNumber,
           OrderCount = ISNULL(po.OrderCount, 0),
           OrderNumbers = CASE WHEN ISNULL(po.OrderCount, 0) = 0 THEN NULL
                               WHEN po.OrderCount = 1 THEN po.FirstOrder
                               ELSE po.FirstOrder + N' +' + CAST(po.OrderCount - 1 AS NVARCHAR(10)) END,
           SupplierCount = ISNULL(po.SupplierCount, 0),
           SupplierNames = CASE WHEN ISNULL(po.SupplierCount, 0) = 0 THEN NULL
                                WHEN po.SupplierCount = 1 THEN po.FirstSupplier
                                ELSE po.FirstSupplier + N' +' + CAST(po.SupplierCount - 1 AS NVARCHAR(10)) END,
           InvoiceCount = ISNULL(inv.InvoiceCount, 0),
           InvoiceNumbers = CASE WHEN ISNULL(inv.InvoiceCount, 0) = 0 THEN NULL
                                 WHEN inv.InvoiceCount = 1 THEN inv.FirstInvoice
                                 ELSE inv.FirstInvoice + N' +' + CAST(inv.InvoiceCount - 1 AS NVARCHAR(10)) END,
           CommercialInvoiceNos = CASE WHEN inv.CiCount = 1 THEN inv.FirstCi
                                       WHEN inv.CiCount > 1 THEN inv.FirstCi + N' +' + CAST(inv.CiCount - 1 AS NVARCHAR(10)) END,
           ExporterReferences = CASE WHEN inv.ErCount = 1 THEN inv.FirstEr
                                     WHEN inv.ErCount > 1 THEN inv.FirstEr + N' +' + CAST(inv.ErCount - 1 AS NVARCHAR(10)) END,
           ItemCount = ISNULL(ln.ItemCount, 0),
           ItemSummary = CASE WHEN ISNULL(ln.ItemCount, 0) = 0 THEN NULL
                              WHEN ln.ItemCount = 1 THEN ln.FirstItem
                              ELSE N'Mixed - ' + CAST(ln.ItemCount AS NVARCHAR(10)) + N' items' END,
           TotalQtyBase = ISNULL(ln.Qty, 0),
           InvoicedQtyBase = ISNULL(inv.PostedQty, 0),
           InvoicingStatus = CASE WHEN ISNULL(inv.PostedQty, 0) = 0 THEN 0
                                  WHEN inv.PostedQty >= ISNULL(ln.Qty, 0) THEN 2 ELSE 1 END,     -- 0 none, 1 partly, 2 fully (posted)
           TotalReceivedBase = c.TotalReceivedBase, c.TotalOilQty,
           c.MaxUnits, c.UtilizationPct,
           c.BlNo, c.BlDate, c.DispatchDate, c.Eta, c.ActualPortArrival, c.CustomsReleaseDate, c.OffloadedDate,
           c.FreeDays, c.LastFreeDay,
           DaysAtPort = CASE WHEN c.ActualPortArrival IS NOT NULL
                             THEN DATEDIFF(DAY, c.ActualPortArrival, ISNULL(c.OffloadedDate, CAST(SYSUTCDATETIME() AS DATE))) END,
           c.CurrentLocation, c.Status, c.StatusNote,
           CurrentMovementId = mv.Id, CurrentMovementNo = mv.MovementNo, CurrentMovementStatus = mv.Status,
           ChargesPostedBase = ISNULL(chg.Posted, 0), ChargesDraftBase = ISNULL(chg.Draft, 0),
           AttachmentCount = (SELECT COUNT(*) FROM logistics.ContainerAttachments a WHERE a.ContainerId = c.Id),
           pl.PortName AS PortOfLoadingName, pd.PortName AS PortOfDestinationName,
           c.CreatedAtUtc, c.CreatedBy, cu.FullName AS CreatedByName, c.UpdatedAtUtc, c.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM logistics.Containers c
    INNER JOIN masterdata.ContainerTypes ct ON ct.Id = c.ContainerTypeId
    INNER JOIN masterdata.Branches b        ON b.Id = c.BranchId
    LEFT  JOIN masterdata.Warehouses w      ON w.Id = c.WarehouseId
    LEFT  JOIN masterdata.Ports pl          ON pl.Id = c.PortOfLoadingId
    LEFT  JOIN masterdata.Ports pd          ON pd.Id = c.PortOfDestinationId
    LEFT  JOIN purchase.PurchaseDocuments mpo ON mpo.Id = c.PurchaseOrderId
    LEFT  JOIN security.Users cu            ON cu.Id = c.CreatedBy
    OUTER APPLY (SELECT OrderCount = COUNT(DISTINCT cl.PurchaseOrderId), SupplierCount = COUNT(DISTINCT d.SupplierId),
                        FirstOrder = MIN(d.DocumentNumber), FirstSupplier = MIN(sp.PartyName)
                 FROM logistics.ContainerLines cl
                 INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                 INNER JOIN masterdata.Parties sp        ON sp.Id = d.SupplierId
                 WHERE cl.ContainerId = c.Id) po
    OUTER APPLY (SELECT InvoiceCount = COUNT(DISTINCT d.Id),
                        CiCount = COUNT(DISTINCT d.CommercialInvoiceNo), ErCount = COUNT(DISTINCT d.ExporterReference),
                        FirstInvoice = MIN(d.DocumentNumber), FirstCi = MIN(d.CommercialInvoiceNo), FirstEr = MIN(d.ExporterReference),
                        PostedQty = SUM(CASE WHEN d.Status IN (2, 4) THEN pil.QuantityBase ELSE 0 END)
                 FROM logistics.ContainerLines cl
                 INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
                 INNER JOIN purchase.PurchaseDocuments d        ON d.Id = pil.DocumentId
                 WHERE cl.ContainerId = c.Id AND d.Status <> 3) inv
    OUTER APPLY (SELECT ItemCount = COUNT(DISTINCT cl.ItemId), Qty = SUM(cl.QuantityBase), FirstItem = MIN(i.ItemName)
                 FROM logistics.ContainerLines cl
                 INNER JOIN inventory.Items i ON i.Id = cl.ItemId
                 WHERE cl.ContainerId = c.Id) ln
    OUTER APPLY (SELECT Posted = SUM(CASE WHEN ch.Status = 2 THEN ch.AmountBase END),
                        Draft  = SUM(CASE WHEN ch.Status = 1 THEN ch.AmountBase END)
                 FROM logistics.ContainerCharges ch WHERE ch.ContainerId = c.Id) chg
    OUTER APPLY (SELECT TOP (1) m.Id, m.MovementNo, m.Status
                 FROM logistics.MovementContainers mc
                 INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
                 WHERE mc.ContainerId = c.Id AND m.Status IN (2, 3)
                 ORDER BY CASE WHEN m.Status = 2 THEN 0 ELSE 1 END, COALESCE(m.EndDate, m.StartDate) DESC, m.Id DESC) mv
    WHERE (@Search IS NULL OR c.ContainerRef LIKE N'%' + @Search + N'%' OR c.ContainerNo LIKE N'%' + @Search + N'%'
           OR c.BlNo LIKE N'%' + @Search + N'%' OR c.VesselName LIKE N'%' + @Search + N'%'
           OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                      INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                      INNER JOIN masterdata.Parties sp        ON sp.Id = d.SupplierId
                      WHERE cl.ContainerId = c.Id AND (d.DocumentNumber LIKE N'%' + @Search + N'%' OR sp.PartyName LIKE N'%' + @Search + N'%'))
           OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                      INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
                      INNER JOIN purchase.PurchaseDocuments d        ON d.Id = pil.DocumentId
                      WHERE cl.ContainerId = c.Id AND d.Status <> 3
                        AND (d.DocumentNumber LIKE N'%' + @Search + N'%' OR d.CommercialInvoiceNo LIKE N'%' + @Search + N'%'
                             OR d.ExporterReference LIKE N'%' + @Search + N'%')))
      AND (@ContainerRef IS NULL OR c.ContainerRef LIKE N'%' + @ContainerRef + N'%')
      AND (@ContainerNo IS NULL OR c.ContainerNo LIKE N'%' + @ContainerNo + N'%')
      AND (@BlNo IS NULL OR c.BlNo LIKE N'%' + @BlNo + N'%')
      AND (@Status IS NULL OR c.Status = @Status)
      AND (@BranchId IS NULL OR c.BranchId = @BranchId)
      AND (@WarehouseId IS NULL OR c.WarehouseId = @WarehouseId)
      AND (@PortId IS NULL OR c.PortOfLoadingId = @PortId OR c.PortOfDestinationId = @PortId OR c.FinalDestinationId = @PortId)
      AND (@OrderMonthKey IS NULL OR c.OrderMonthKey = @OrderMonthKey)
      AND (@DateFrom IS NULL OR c.OrderDate >= @DateFrom)
      AND (@DateTo IS NULL OR c.OrderDate <= @DateTo)
      AND (@SupplierId IS NULL OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                                          INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                                          WHERE cl.ContainerId = c.Id AND d.SupplierId = @SupplierId))
      AND (@PurchaseOrderId IS NULL OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl WHERE cl.ContainerId = c.Id AND cl.PurchaseOrderId = @PurchaseOrderId))
      AND (@PurchaseDocumentId IS NULL
           OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl WHERE cl.ContainerId = c.Id AND cl.PurchaseOrderId = @PurchaseDocumentId)
           OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                      INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
                      WHERE cl.ContainerId = c.Id AND pil.DocumentId = @PurchaseDocumentId))
      AND (@CommercialInvoiceNo IS NULL OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                                                   INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
                                                   INNER JOIN purchase.PurchaseDocuments d        ON d.Id = pil.DocumentId
                                                   WHERE cl.ContainerId = c.Id AND d.Status <> 3
                                                     AND d.CommercialInvoiceNo LIKE N'%' + @CommercialInvoiceNo + N'%'))
      AND (@ItemId IS NULL OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl WHERE cl.ContainerId = c.Id AND cl.ItemId = @ItemId))
      AND (@MovementId IS NULL OR EXISTS (SELECT 1 FROM logistics.MovementContainers mc WHERE mc.ContainerId = c.Id AND mc.MovementId = @MovementId))
    ORDER BY
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'ContainerRef' THEN c.ContainerRef WHEN N'ContainerNo' THEN c.ContainerNo END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'ContainerRef' THEN c.ContainerRef WHEN N'ContainerNo' THEN c.ContainerNo END END DESC,
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'OrderDate' THEN c.OrderDate WHEN N'DispatchDate' THEN c.DispatchDate WHEN N'Eta' THEN c.Eta END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'OrderDate' THEN c.OrderDate WHEN N'DispatchDate' THEN c.DispatchDate WHEN N'Eta' THEN c.Eta END END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Status' THEN CAST(c.Status AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Status' THEN CAST(c.Status AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN c.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN c.CreatedAtUtc END DESC,
        c.OrderDate DESC, c.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

-- Eight result sets: 1 header, 2 lines (with invoicing and cost), 3 invoices, 4 movements, 5 charges,
-- 6 charge allocations per line, 7 attachments, 8 audit.
CREATE OR ALTER PROCEDURE logistics.usp_Container_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT c.Id, c.DocumentTypeId, c.ContainerRef, c.ContainerNo,
           c.ContainerTypeId, ct.TypeCode AS ContainerTypeCode, ct.TypeName AS ContainerTypeName,
           TypeMaxUnits = ct.MaxUnits, ct.MaxWeightKg, ct.MaxVolumeCbm,
           c.SealNo, c.CustomsSealNo, c.Description,
           c.OrderDate, c.OrderMonthKey, OrderMonth = FORMAT(c.OrderDate, N'MMM-yyyy', N'en-US'),
           c.ShippingMethod, c.CountryOfOrigin,
           c.PurchaseOrderId, mpo.DocumentNumber AS PurchaseOrderNumber, mpo.SupplierId AS PurchaseOrderSupplierId,
           mps.PartyName AS PurchaseOrderSupplierName,
           c.ForwarderId, fw.PartyName AS ForwarderName, c.TransporterId, tr.PartyName AS TransporterName,
           c.ShippingLine, c.VesselName, c.VoyageNo, c.BookingNo,
           c.PortOfLoadingId, pl.PortName AS PortOfLoadingName, pl.CountryCode AS PortOfLoadingCountry,
           c.PortOfDestinationId, pd.PortName AS PortOfDestinationName, pd.CountryCode AS PortOfDestinationCountry,
           c.FinalDestinationId, fd.PortName AS FinalDestinationName,
           c.DispatchDate, c.Eta, c.FreeDays, c.LastFreeDay, c.GrossWeightKg, c.VolumeCbm, c.Packages,
           c.BlNo, c.BlDate, c.BlNotes,
           c.MaxUnits, c.TotalLines, c.TotalAllocatedBase, c.TotalReceivedBase, c.TotalOilQty, c.UtilizationPct,
           RemainingCapacityBase = CASE WHEN c.MaxUnits IS NOT NULL THEN c.MaxUnits - c.TotalAllocatedBase END,
           IsOverCapacity = CASE WHEN c.MaxUnits IS NOT NULL AND c.TotalAllocatedBase > c.MaxUnits THEN 1 ELSE 0 END,
           c.BranchId, b.BranchCode, b.BranchName, c.WarehouseId, w.WarehouseCode, w.WarehouseName,
           c.TruckNo, c.WaybillNo, c.DeclarationNo, c.FeriNo,
           c.ActualPortArrival, c.BorderCrossingDate, c.CustomsReleaseDate,
           DaysAtPort = CASE WHEN c.ActualPortArrival IS NOT NULL
                             THEN DATEDIFF(DAY, c.ActualPortArrival, ISNULL(c.OffloadedDate, CAST(SYSUTCDATETIME() AS DATE))) END,
           c.OffloadedDate, c.OffloadedAtUtc, c.OffloadedBy, ou.FullName AS OffloadedByName,
           c.Status, c.StatusNote, c.CurrentLocation, c.Notes,
           c.DatesFromMovements,
           HasMovements = CAST(CASE WHEN EXISTS (SELECT 1 FROM logistics.MovementContainers mc
                                                 INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
                                                 WHERE mc.ContainerId = c.Id AND m.Status IN (2, 3)) THEN 1 ELSE 0 END AS BIT),
           InvoicedPostedBase = ISNULL(inv.Posted, 0), InvoicedDraftBase = ISNULL(inv.Draft, 0),
           IsFullyInvoiced = CAST(CASE WHEN c.TotalAllocatedBase > 0 AND NOT EXISTS
                                       (SELECT 1 FROM logistics.ContainerLines cl
                                        OUTER APPLY (SELECT Q = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                                                     INNER JOIN purchase.PurchaseDocuments pid ON pid.Id = pil.DocumentId
                                                     WHERE pil.ContainerLineId = cl.Id AND pid.Status IN (2, 4)) q
                                        WHERE cl.ContainerId = c.Id AND ISNULL(q.Q, 0) < cl.QuantityBase) THEN 1 ELSE 0 END AS BIT),
           ChargesPostedBase = ISNULL(chg.Posted, 0), ChargesDraftBase = ISNULL(chg.Draft, 0),
           ChargesLandedPostedBase = ISNULL(chg.LandedPosted, 0),
           FobTotalBase = cost.Fob, LandedTotalBase = cost.Fob + ISNULL(chg.LandedPosted, 0),
           c.ConfirmedAtUtc, c.ConfirmedBy, fu.FullName AS ConfirmedByName,
           c.ClosedAtUtc, c.ClosedBy, ku.FullName AS ClosedByName,
           c.CancelledAtUtc, c.CancelledBy, xu.FullName AS CancelledByName, c.CancelReason,
           c.CreatedAtUtc, c.CreatedBy, cu.FullName AS CreatedByName,
           c.UpdatedAtUtc, c.UpdatedBy, uu.FullName AS UpdatedByName, c.RowVersion
    FROM logistics.Containers c
    INNER JOIN masterdata.ContainerTypes ct ON ct.Id = c.ContainerTypeId
    INNER JOIN masterdata.Branches b        ON b.Id = c.BranchId
    LEFT  JOIN masterdata.Warehouses w      ON w.Id = c.WarehouseId
    LEFT  JOIN purchase.PurchaseDocuments mpo ON mpo.Id = c.PurchaseOrderId
    LEFT  JOIN masterdata.Parties mps       ON mps.Id = mpo.SupplierId
    LEFT  JOIN masterdata.Parties fw        ON fw.Id = c.ForwarderId
    LEFT  JOIN masterdata.Parties tr        ON tr.Id = c.TransporterId
    LEFT  JOIN masterdata.Ports pl          ON pl.Id = c.PortOfLoadingId
    LEFT  JOIN masterdata.Ports pd          ON pd.Id = c.PortOfDestinationId
    LEFT  JOIN masterdata.Ports fd          ON fd.Id = c.FinalDestinationId
    LEFT  JOIN security.Users ou ON ou.Id = c.OffloadedBy
    LEFT  JOIN security.Users fu ON fu.Id = c.ConfirmedBy
    LEFT  JOIN security.Users ku ON ku.Id = c.ClosedBy
    LEFT  JOIN security.Users xu ON xu.Id = c.CancelledBy
    LEFT  JOIN security.Users cu ON cu.Id = c.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = c.UpdatedBy
    OUTER APPLY (SELECT Posted = SUM(CASE WHEN d.Status IN (2, 4) THEN pil.QuantityBase END),
                        Draft  = SUM(CASE WHEN d.Status = 1 THEN pil.QuantityBase END)
                 FROM logistics.ContainerLines cl
                 INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
                 INNER JOIN purchase.PurchaseDocuments d        ON d.Id = pil.DocumentId
                 WHERE cl.ContainerId = c.Id) inv
    OUTER APPLY (SELECT Posted = SUM(CASE WHEN ch.Status = 2 THEN ch.AmountBase END),
                        Draft  = SUM(CASE WHEN ch.Status = 1 THEN ch.AmountBase END),
                        LandedPosted = SUM(CASE WHEN ch.Status = 2 AND ch.IncludeInLandedCost = 1 THEN ch.AmountBase END)
                 FROM logistics.ContainerCharges ch WHERE ch.ContainerId = c.Id) chg
    OUTER APPLY (SELECT Fob = SUM(CAST(ISNULL(cl.ReceivedQuantityBase, cl.QuantityBase) AS DECIMAL(18,6)) * ISNULL(u.UnitFob, 0))
                 FROM logistics.ContainerLines cl
                 OUTER APPLY (SELECT UnitFob = COALESCE(cl.FobCostBase,
                                                        (SELECT SUM(pil.LineTotal / pid.ExchangeRate) / NULLIF(SUM(pil.QuantityBase), 0)
                                                         FROM purchase.PurchaseDocumentLines pil
                                                         INNER JOIN purchase.PurchaseDocuments pid ON pid.Id = pil.DocumentId
                                                         WHERE pil.ContainerLineId = cl.Id AND pid.Status IN (1, 2, 4)),
                                                        (SELECT pol.LineTotal / pod.ExchangeRate / NULLIF(pol.QuantityBase, 0)
                                                         FROM purchase.PurchaseDocumentLines pol
                                                         INNER JOIN purchase.PurchaseDocuments pod ON pod.Id = pol.DocumentId
                                                         WHERE pol.Id = cl.PoLineId))) u
                 WHERE cl.ContainerId = c.Id) cost
    WHERE c.Id = @Id;

    -- 2: lines. FOB per unit: after offload the frozen value, else the invoices (posted or draft), else the order price.
    SELECT cl.Id, cl.ContainerId, cl.LineNumber,
           cl.PurchaseOrderId, po.DocumentNumber AS PurchaseOrderNumber, po.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName,
           cl.PoLineId, pol.LineNumber AS PoLineNumber,
           cl.ItemId, i.ItemCode, i.ItemName, i.Model, br.BrandName,
           cl.ItemUnitId, ut.UnitTypeName, cl.PackingFormula,
           PoUnitTypeName = pt.UnitTypeName, PoPackingFormula = pol.PackingFormula,
           cl.Quantity, cl.QuantityBase, cl.OilIncluded, cl.OilQtyPerUnit, cl.TotalOilQty,
           OrderedBase = pol.QuantityBase,
           LoadedElsewhereBase = ISNULL(oth.Qty, 0),
           InvoicedPostedBase = ISNULL(inv.Posted, 0), InvoicedDraftBase = ISNULL(inv.Draft, 0),
           AvailableToInvoiceBase = cl.QuantityBase - ISNULL(inv.Posted, 0) - ISNULL(inv.Draft, 0),
           InvoiceNumbers = inv.Numbers,
           cl.ReceivedQuantityBase, cl.VarianceReason, cl.Notes,
           UnitFobBase = COALESCE(cl.FobCostBase, inv.UnitValue, pol.LineTotal / po.ExchangeRate / NULLIF(pol.QuantityBase, 0)),
           FobSource = CASE WHEN cl.FobCostBase IS NOT NULL THEN N'Offload' WHEN inv.UnitValue IS NOT NULL THEN N'Invoice' ELSE N'Order' END,
           cl.FobCostBase, cl.ChargesBase,
           DraftChargesBase = ISNULL(dch.Draft, 0),
           ChargesPerUnitBase = cl.ChargesBase / NULLIF(ISNULL(cl.ReceivedQuantityBase, cl.QuantityBase), 0),
           LandedCostBase = COALESCE(cl.LandedCostBase,
                                     COALESCE(inv.UnitValue, pol.LineTotal / po.ExchangeRate / NULLIF(pol.QuantityBase, 0))
                                     + cl.ChargesBase / NULLIF(cl.QuantityBase, 0)),
           IsLandedFinal = CAST(CASE WHEN cl.LandedCostBase IS NOT NULL THEN 1 ELSE 0 END AS BIT),
           i.WeightKg, i.VolumeCbm
    FROM logistics.ContainerLines cl
    INNER JOIN purchase.PurchaseDocuments po     ON po.Id = cl.PurchaseOrderId
    INNER JOIN masterdata.Parties sp             ON sp.Id = po.SupplierId
    INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = cl.PoLineId
    INNER JOIN inventory.ItemUnits piu           ON piu.Id = pol.ItemUnitId
    INNER JOIN masterdata.UnitTypes pt           ON pt.Id = piu.UnitTypeId
    INNER JOIN inventory.Items i                 ON i.Id = cl.ItemId
    INNER JOIN masterdata.Brands br              ON br.Id = i.BrandId
    INNER JOIN inventory.ItemUnits iu            ON iu.Id = cl.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut           ON ut.Id = iu.UnitTypeId
    OUTER APPLY (SELECT Qty = SUM(o.QuantityBase) FROM logistics.ContainerLines o
                 INNER JOIN logistics.Containers oc ON oc.Id = o.ContainerId
                 WHERE o.PoLineId = cl.PoLineId AND o.ContainerId <> cl.ContainerId AND oc.Status <> 8) oth
    OUTER APPLY (SELECT Posted = SUM(CASE WHEN d.Status IN (2, 4) THEN pil.QuantityBase END),
                        Draft  = SUM(CASE WHEN d.Status = 1 THEN pil.QuantityBase END),
                        UnitValue = SUM(pil.LineTotal / d.ExchangeRate) / NULLIF(SUM(pil.QuantityBase), 0),
                        Numbers = STRING_AGG(d.DocumentNumber, N', ')
                 FROM purchase.PurchaseDocumentLines pil
                 INNER JOIN purchase.PurchaseDocuments d ON d.Id = pil.DocumentId
                 WHERE pil.ContainerLineId = cl.Id AND d.Status <> 3) inv
    OUTER APPLY (SELECT Draft = SUM(a.AmountBase) FROM logistics.ContainerChargeAllocations a
                 INNER JOIN logistics.ContainerCharges ch ON ch.Id = a.ChargeId
                 WHERE a.ContainerLineId = cl.Id AND ch.Status = 1) dch
    WHERE cl.ContainerId = @Id
    ORDER BY cl.LineNumber;

    -- 3: invoices of the container (derived from the invoice lines)
    SELECT d.Id AS PurchaseDocumentId, d.DocumentNumber, d.DocumentDate, d.Status AS InvoiceStatus, d.ReceiptMode,
           d.SourceDocumentId AS PurchaseOrderId, po.DocumentNumber AS PurchaseOrderNumber,
           d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName,
           d.CurrencyId, cur.CurrencyCode, cur.Symbol AS CurrencySymbol, d.ExchangeRate,
           d.SupplierReference, d.ExporterReference, d.CommercialInvoiceNo,
           QtyInContainerBase = SUM(pil.QuantityBase),
           AmountInContainer = SUM(pil.LineTotal),
           AmountInContainerBase = SUM(pil.LineTotal / d.ExchangeRate),
           d.TotalAmount, d.TotalAmountBase
    FROM logistics.ContainerLines cl
    INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
    INNER JOIN purchase.PurchaseDocuments d        ON d.Id = pil.DocumentId
    INNER JOIN masterdata.Parties sp               ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies cur           ON cur.Id = d.CurrencyId
    LEFT  JOIN purchase.PurchaseDocuments po       ON po.Id = d.SourceDocumentId
    WHERE cl.ContainerId = @Id AND d.Status <> 3
    GROUP BY d.Id, d.DocumentNumber, d.DocumentDate, d.Status, d.ReceiptMode, d.SourceDocumentId, po.DocumentNumber,
             d.SupplierId, sp.PartyCode, sp.PartyName, d.CurrencyId, cur.CurrencyCode, cur.Symbol, d.ExchangeRate,
             d.SupplierReference, d.ExporterReference, d.CommercialInvoiceNo, d.TotalAmount, d.TotalAmountBase
    ORDER BY d.DocumentDate, d.Id;

    -- 4: movements of the container (the route), oldest first
    SELECT m.Id AS MovementId, m.MovementNo, m.MovementTypeId, mt.TypeCode, mt.TypeName, mt.Stage,
           m.FromPlaceId, fp.PortCode AS FromCode, fp.PortName AS FromName, fp.CountryCode AS FromCountry, fp.Kind AS FromKind,
           m.ToPlaceId, tp.PortCode AS ToCode, tp.PortName AS ToName, tp.CountryCode AS ToCountry, tp.Kind AS ToKind,
           m.PlannedDate, m.StartDate, m.Eta, m.EndDate, m.Status,
           m.CarrierPartyId, cp.PartyName AS CarrierName, m.VehicleOrVessel, m.VoyageNo, m.Reference, m.Notes,
           ContainerCount = (SELECT COUNT(*) FROM logistics.MovementContainers x WHERE x.MovementId = m.Id),
           ChargesBase = (SELECT SUM(ch.AmountBase) FROM logistics.ContainerCharges ch
                          WHERE ch.ContainerId = @Id AND ch.MovementId = m.Id AND ch.Status = 2),
           AttachmentCount = (SELECT COUNT(*) FROM logistics.ContainerAttachments a WHERE a.ContainerId = @Id AND a.MovementId = m.Id)
    FROM logistics.MovementContainers mc
    INNER JOIN logistics.Movements m       ON m.Id = mc.MovementId
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    INNER JOIN masterdata.Ports fp         ON fp.Id = m.FromPlaceId
    INNER JOIN masterdata.Ports tp         ON tp.Id = m.ToPlaceId
    LEFT  JOIN masterdata.Parties cp       ON cp.Id = m.CarrierPartyId
    WHERE mc.ContainerId = @Id
    ORDER BY CASE m.Status WHEN 4 THEN 1 ELSE 0 END, COALESCE(m.StartDate, m.PlannedDate, CAST(m.CreatedAtUtc AS DATE)), m.Id;

    -- 5: charges of the container
    SELECT ch.Id, ch.ContainerId, ch.MovementId, m.MovementNo, ch.GroupId,
           GroupSize = CASE WHEN ch.GroupId IS NULL THEN 1 ELSE (SELECT COUNT(*) FROM logistics.ContainerCharges g WHERE g.GroupId = ch.GroupId) END,
           ch.ChargeTypeId, t.ChargeCode, t.ChargeName, ch.Description, ch.ProviderPartyId, pp.PartyName AS ProviderName, ch.Reference,
           ch.ChargeDate, ch.CurrencyId, cur.CurrencyCode, ch.RateType, ch.ExchangeRate, ch.Amount, ch.AmountBase,
           ch.AllocationMethod, ch.IncludeInLandedCost, ch.Status, ch.AppliedAtOffload, ch.AdjustedAfterOffload,
           AllocatedBase = (SELECT SUM(a.AmountBase) FROM logistics.ContainerChargeAllocations a WHERE a.ChargeId = ch.Id),
           AttachmentCount = (SELECT COUNT(*) FROM logistics.ContainerAttachments a WHERE a.ChargeId = ch.Id),
           ch.Notes, ch.PostedAtUtc, pu.FullName AS PostedByName, ch.CancelledAtUtc, ch.CancelReason,
           ch.CreatedAtUtc, cu.FullName AS CreatedByName, ch.RowVersion
    FROM logistics.ContainerCharges ch
    INNER JOIN purchase.ChargeTypes t    ON t.Id = ch.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = ch.CurrencyId
    LEFT  JOIN masterdata.Parties pp     ON pp.Id = ch.ProviderPartyId
    LEFT  JOIN logistics.Movements m     ON m.Id = ch.MovementId
    LEFT  JOIN security.Users pu         ON pu.Id = ch.PostedBy
    LEFT  JOIN security.Users cu         ON cu.Id = ch.CreatedBy
    WHERE ch.ContainerId = @Id
    ORDER BY ch.ChargeDate, ch.Id;

    -- 6: how every charge is divided over the lines (the real cost of each item)
    SELECT a.ChargeId, a.ContainerLineId, cl.LineNumber, cl.ItemId, i.ItemCode, i.ItemName,
           a.Basis, a.AmountBase, a.IsManual,
           PerUnitBase = a.AmountBase / NULLIF(ISNULL(cl.ReceivedQuantityBase, cl.QuantityBase), 0)
    FROM logistics.ContainerChargeAllocations a
    INNER JOIN logistics.ContainerCharges ch ON ch.Id = a.ChargeId
    INNER JOIN logistics.ContainerLines cl   ON cl.Id = a.ContainerLineId
    INNER JOIN inventory.Items i             ON i.Id = cl.ItemId
    WHERE ch.ContainerId = @Id
    ORDER BY a.ChargeId, cl.LineNumber;

    -- 7: attachments (general, per movement, per charge); SharedWith = other containers holding the same file
    SELECT a.Id, a.ContainerId, a.MovementId, m.MovementNo, a.ChargeId, a.AttachmentTypeId, at.Category, at.SubType,
           a.FileId, f.FileName, f.ContentType, f.SizeBytes, a.Note, a.DocumentDate, a.GroupId,
           SharedWith = (SELECT COUNT(*) FROM logistics.ContainerAttachments s WHERE s.FileId = a.FileId AND s.Id <> a.Id),
           a.CreatedAtUtc, a.CreatedBy, u.FullName AS CreatedByName
    FROM logistics.ContainerAttachments a
    INNER JOIN logistics.Files f ON f.Id = a.FileId
    LEFT  JOIN masterdata.AttachmentTypes at ON at.Id = a.AttachmentTypeId
    LEFT  JOIN logistics.Movements m         ON m.Id = a.MovementId
    LEFT  JOIN security.Users u              ON u.Id = a.CreatedBy
    WHERE a.ContainerId = @Id
    ORDER BY a.CreatedAtUtc DESC, a.Id DESC;

    -- 8: audit
    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM logistics.ContainerAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.ContainerId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;
END
GO

/* ================================================================== 10. Containers: loaded from purchase orders */

-- Order lines that can still be loaded: approved, open orders. Loadable = ordered - invoiced WITHOUT a container
-- (local receipts) - loaded in other containers. @ContainerId = the container being edited (its own lines count apart).
CREATE OR ALTER PROCEDURE logistics.usp_Container_AvailablePoLines
    @PurchaseOrderId INT           = NULL,
    @SupplierId      INT           = NULL,
    @Search          NVARCHAR(100) = NULL,    -- order number, item code or name
    @ContainerId     INT           = NULL,
    @Top             INT           = 200
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @Top IS NULL OR @Top < 1 SET @Top = 200;

    SELECT TOP (@Top)
           d.Id AS PurchaseOrderId, d.DocumentNumber AS PurchaseOrderNumber, d.DocumentDate AS OrderDate, d.Status AS OrderStatus,
           d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName,
           d.CurrencyId, cur.CurrencyCode, d.WarehouseId, w.WarehouseCode, w.WarehouseName,
           l.Id AS PoLineId, l.LineNumber AS PoLineNumber, l.ItemId, i.ItemCode, i.ItemName, i.Model, br.BrandName,
           l.ItemUnitId, ut.UnitTypeName, l.PackingFormula, l.Quantity AS OrderedQuantity,
           OrderedBase         = l.QuantityBase,
           InvoicedDirectBase  = ISNULL(dir.Qty, 0),
           LoadedElsewhereBase = ISNULL(oth.Qty, 0),
           LoadedHereBase      = ISNULL(here.Qty, 0),
           MaxHereBase         = l.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0),
           AvailableBase       = l.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0) - ISNULL(here.Qty, 0),
           l.UnitPrice, l.DiscountPercent,
           UnitValueBase = l.LineTotal / d.ExchangeRate / NULLIF(l.QuantityBase, 0),
           ItemOilQtyPerUnit = i.OilQtyPerUnit,
           PcPerContainer = cnt.PackingFormula,
           i.WeightKg, i.VolumeCbm
    FROM purchase.PurchaseDocumentLines l
    INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
    INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Parties sp        ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies cur    ON cur.Id = d.CurrencyId
    INNER JOIN masterdata.Warehouses w      ON w.Id = d.WarehouseId
    INNER JOIN inventory.Items i            ON i.Id = l.ItemId
    INNER JOIN masterdata.Brands br         ON br.Id = i.BrandId
    INNER JOIN inventory.ItemUnits iu       ON iu.Id = l.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut      ON ut.Id = iu.UnitTypeId
    OUTER APPLY (SELECT Qty = SUM(x.QuantityBase) FROM purchase.PurchaseDocumentLines x
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
                 WHERE x.SourceLineId = l.Id AND x.ContainerLineId IS NULL AND xd.Status IN (1, 2, 4)) dir
    OUTER APPLY (SELECT Qty = SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                 INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                 WHERE cl.PoLineId = l.Id AND c.Status <> 8 AND (@ContainerId IS NULL OR cl.ContainerId <> @ContainerId)) oth
    OUTER APPLY (SELECT Qty = SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                 WHERE cl.PoLineId = l.Id AND cl.ContainerId = @ContainerId) here
    OUTER APPLY (SELECT TOP (1) u.PackingFormula FROM inventory.ItemUnits u
                 INNER JOIN masterdata.UnitTypes t ON t.Id = u.UnitTypeId
                 WHERE u.ItemId = l.ItemId AND t.IsContainer = 1) cnt
    WHERE dt.Code = N'PO' AND d.Status = 2
      AND (@PurchaseOrderId IS NULL OR d.Id = @PurchaseOrderId)
      AND (@SupplierId IS NULL OR d.SupplierId = @SupplierId)
      AND (@Search IS NULL OR d.DocumentNumber LIKE N'%' + @Search + N'%' OR i.ItemCode LIKE N'%' + @Search + N'%'
           OR i.ItemName LIKE N'%' + @Search + N'%' OR sp.PartyName LIKE N'%' + @Search + N'%')
      AND (l.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0) - ISNULL(here.Qty, 0) > 0 OR ISNULL(here.Qty, 0) > 0)
    ORDER BY d.DocumentDate DESC, d.Id DESC, l.LineNumber;
END
GO

CREATE OR ALTER PROCEDURE logistics.usp_Container_Save
    @Id                  INT            = NULL,   -- NULL = create (ContainerRef assigned now)
    @PurchaseOrderId     INT            = NULL,   -- required on create: the order the container is created from
    @ContainerNo         NVARCHAR(20)   = NULL,
    @ContainerTypeId     INT,
    @SealNo              NVARCHAR(30)   = NULL,
    @CustomsSealNo       NVARCHAR(30)   = NULL,
    @Description         NVARCHAR(500)  = NULL,
    @OrderDate           DATE,
    @ShippingMethod      NVARCHAR(10)   = N'Sea',
    @CountryOfOrigin     NCHAR(2)       = NULL,
    @ForwarderId         INT            = NULL,
    @TransporterId       INT            = NULL,
    @ShippingLine        NVARCHAR(100)  = NULL,
    @VesselName          NVARCHAR(100)  = NULL,
    @VoyageNo            NVARCHAR(30)   = NULL,
    @BookingNo           NVARCHAR(30)   = NULL,
    @PortOfLoadingId     INT            = NULL,
    @PortOfDestinationId INT            = NULL,
    @FinalDestinationId  INT            = NULL,
    @DispatchDate        DATE           = NULL,   -- the four milestone dates are replaced by the movements when there are some
    @Eta                 DATE           = NULL,
    @FreeDays            INT            = NULL,
    @GrossWeightKg       DECIMAL(18,3)  = NULL,
    @VolumeCbm           DECIMAL(18,3)  = NULL,
    @Packages            INT            = NULL,
    @BlNo                NVARCHAR(30)   = NULL,
    @BlDate              DATE           = NULL,
    @BlNotes             NVARCHAR(500)  = NULL,
    @MaxUnits            INT            = NULL,   -- NULL = the container type's capacity
    @BranchId            INT,
    @WarehouseId         INT            = NULL,
    @TruckNo             NVARCHAR(30)   = NULL,
    @WaybillNo           NVARCHAR(30)   = NULL,
    @DeclarationNo       NVARCHAR(30)   = NULL,
    @FeriNo              NVARCHAR(30)   = NULL,
    @ActualPortArrival   DATE           = NULL,
    @BorderCrossingDate  DATE           = NULL,
    @CustomsReleaseDate  DATE           = NULL,
    @StatusNote          NVARCHAR(200)  = NULL,
    @Notes               NVARCHAR(1000) = NULL,
    @Lines               logistics.tvp_ContainerLoadLine READONLY,
    @AllowOverCapacity   BIT            = 0,
    @RowVersion          BINARY(8)      = NULL,
    @UserId              INT            = NULL,
    @NewId               INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @ContainerNo = UPPER(NULLIF(LTRIM(RTRIM(@ContainerNo)), N''));
    SET @SealNo = NULLIF(LTRIM(RTRIM(@SealNo)), N'');
    SET @CustomsSealNo = NULLIF(LTRIM(RTRIM(@CustomsSealNo)), N'');
    SET @Description = NULLIF(LTRIM(RTRIM(@Description)), N'');
    SET @ShippingMethod = NULLIF(LTRIM(RTRIM(@ShippingMethod)), N'');
    SET @BlNo = NULLIF(LTRIM(RTRIM(@BlNo)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    SET @StatusNote = NULLIF(LTRIM(RTRIM(@StatusNote)), N'');
    IF @ShippingMethod IS NULL SET @ShippingMethod = N'Sea';

    IF @OrderDate IS NULL THROW 69000, 'Order date is required.', 1;
    IF @ShippingMethod NOT IN (N'Sea', N'Air', N'Road') THROW 69000, 'Shipping method must be Sea, Air or Road.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.ContainerTypes WHERE Id = @ContainerTypeId AND IsActive = 1)
        THROW 69000, 'Container type not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 69000, 'Branch not found or inactive.', 1;
    IF @WarehouseId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1)
        THROW 69000, 'Offloading warehouse not found or inactive.', 1;
    IF @FreeDays IS NOT NULL AND @FreeDays < 0 THROW 69000, 'Free days cannot be negative.', 1;
    IF @MaxUnits IS NOT NULL AND @MaxUnits <= 0 THROW 69000, 'Maximum units must be greater than zero.', 1;
    IF @DispatchDate IS NOT NULL AND @Eta IS NOT NULL AND @Eta < @DispatchDate
        THROW 69000, 'The ETA cannot be earlier than the dispatch date.', 1;
    IF @ContainerNo IS NOT NULL AND EXISTS (SELECT 1 FROM logistics.Containers
                                            WHERE ContainerNo = @ContainerNo AND Status < 7 AND (@Id IS NULL OR Id <> @Id))
        THROW 69013, 'Another open container already uses this container number.', 1;

    DECLARE @Status TINYINT = NULL;
    IF @Id IS NOT NULL
    BEGIN
        SELECT @Status = Status, @PurchaseOrderId = ISNULL(PurchaseOrderId, @PurchaseOrderId) FROM logistics.Containers WHERE Id = @Id;
        IF @Status IS NULL THROW 69006, 'Container not found.', 1;
        IF @Status >= 6 THROW 69005, 'An offloaded, closed or cancelled container can no longer be changed.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 69004, 'This container was modified by another user. Reload the page and try again.', 1;
    END
    ELSE
    BEGIN
        IF @PurchaseOrderId IS NULL THROW 69000, 'The purchase order is required: a container is created from a purchase order.', 1;
        IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                       WHERE d.Id = @PurchaseOrderId AND dt.Code = N'PO' AND d.Status = 2)
            THROW 69000, 'The purchase order must be approved and still open.', 1;
    END

    DECLARE @Msg NVARCHAR(400);

    IF EXISTS (SELECT PoLineId FROM @Lines GROUP BY PoLineId HAVING COUNT(*) > 1)
        THROW 69000, 'The same order line appears twice in the container.', 1;

    -- Lines: order line of an approved order (lines already loaded may belong to an order closed since), quantity, oil.
    SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' +
        CASE WHEN pol.Id IS NULL OR dt.Code <> N'PO' THEN N'the purchase order line no longer exists.'
             WHEN l.QuantityBase <= 0 THEN N'the quantity must be greater than zero.'
             WHEN l.OilQtyPerUnit < 0 THEN N'the oil quantity cannot be negative.'
             WHEN ex.Id IS NULL AND d.Status <> 2 THEN N'order ' + ISNULL(d.DocumentNumber, N'(draft)') + N' is not approved or no longer open.'
             WHEN ex.Id IS NOT NULL AND d.Status NOT IN (2, 4) THEN N'order ' + ISNULL(d.DocumentNumber, N'(draft)') + N' was cancelled.'
             ELSE N'item ' + i.ItemCode + N' has no base unit.' END
    FROM @Lines l
    LEFT JOIN purchase.PurchaseDocumentLines pol ON pol.Id = l.PoLineId
    LEFT JOIN purchase.PurchaseDocuments d       ON d.Id = pol.DocumentId
    LEFT JOIN inventory.DocumentTypes dt         ON dt.Id = d.DocumentTypeId
    LEFT JOIN inventory.Items i                  ON i.Id = pol.ItemId
    LEFT JOIN logistics.ContainerLines ex        ON ex.ContainerId = @Id AND ex.PoLineId = l.PoLineId
    WHERE pol.Id IS NULL OR dt.Code <> N'PO' OR l.QuantityBase <= 0 OR l.OilQtyPerUnit < 0
       OR (ex.Id IS NULL AND d.Status <> 2) OR (ex.Id IS NOT NULL AND d.Status NOT IN (2, 4))
       OR NOT EXISTS (SELECT 1 FROM inventory.ItemUnits u WHERE u.ItemId = pol.ItemId AND u.IsBaseUnit = 1)
    ORDER BY l.LineNumber;
    IF @Msg IS NOT NULL THROW 69000, @Msg, 1;

    -- Quantity still loadable on the order line.
    SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - '
                          + CAST(l.QuantityBase AS NVARCHAR(20)) + N' loaded but only '
                          + CAST(pol.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0) AS NVARCHAR(20))
                          + N' remain on order ' + ISNULL(d.DocumentNumber, N'(draft)') + N' line ' + CAST(pol.LineNumber AS NVARCHAR(10)) + N'.'
    FROM @Lines l
    INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = l.PoLineId
    INNER JOIN purchase.PurchaseDocuments d       ON d.Id = pol.DocumentId
    INNER JOIN inventory.Items i                  ON i.Id = pol.ItemId
    OUTER APPLY (SELECT Qty = SUM(x.QuantityBase) FROM purchase.PurchaseDocumentLines x
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
                 WHERE x.SourceLineId = pol.Id AND x.ContainerLineId IS NULL AND xd.Status IN (1, 2, 4)) dir
    OUTER APPLY (SELECT Qty = SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                 INNER JOIN logistics.Containers c2 ON c2.Id = cl.ContainerId
                 WHERE cl.PoLineId = pol.Id AND c2.Status <> 8 AND (@Id IS NULL OR cl.ContainerId <> @Id)) oth
    WHERE l.QuantityBase > pol.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0)
    ORDER BY l.LineNumber;
    IF @Msg IS NOT NULL THROW 69008, @Msg, 1;

    IF @Id IS NOT NULL
    BEGIN
        -- Invoiced lines cannot be removed, nor loaded below what is invoiced.
        SELECT TOP (1) @Msg = N'Line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - '
                              + CAST(q.Invoiced AS NVARCHAR(20)) + N' already invoiced (' + ISNULL(q.Numbers, N'') + N'); '
                              + CASE WHEN l.PoLineId IS NULL THEN N'the line cannot be removed.' ELSE N'the quantity cannot be lower.' END
        FROM logistics.ContainerLines cl
        INNER JOIN inventory.Items i ON i.Id = cl.ItemId
        CROSS APPLY (SELECT Invoiced = ISNULL(SUM(pil.QuantityBase), 0), Numbers = STRING_AGG(pd.DocumentNumber, N', ')
                     FROM purchase.PurchaseDocumentLines pil
                     INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                     WHERE pil.ContainerLineId = cl.Id AND pd.Status <> 3) q
        LEFT JOIN @Lines l ON l.PoLineId = cl.PoLineId
        WHERE cl.ContainerId = @Id AND q.Invoiced > 0 AND (l.PoLineId IS NULL OR l.QuantityBase < q.Invoiced)
        ORDER BY cl.LineNumber;
        IF @Msg IS NOT NULL THROW 69017, @Msg, 1;

        -- A removed line cannot carry a manual share of a posted charge.
        SELECT TOP (1) @Msg = N'Line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N' carries a manual share of the posted charge '
                              + t.ChargeName + N'. Cancel that charge before removing the line.'
        FROM logistics.ContainerLines cl
        INNER JOIN logistics.ContainerChargeAllocations a ON a.ContainerLineId = cl.Id AND a.IsManual = 1
        INNER JOIN logistics.ContainerCharges ch          ON ch.Id = a.ChargeId AND ch.Status = 2
        INNER JOIN purchase.ChargeTypes t                 ON t.Id = ch.ChargeTypeId
        WHERE cl.ContainerId = @Id AND NOT EXISTS (SELECT 1 FROM @Lines l WHERE l.PoLineId = cl.PoLineId)
        ORDER BY cl.LineNumber;
        IF @Msg IS NOT NULL THROW 70014, @Msg, 1;
    END

    -- Capacity: a warning that the caller can override, never a hard block.
    DECLARE @Capacity INT = @MaxUnits;
    IF @Capacity IS NULL AND @Id IS NOT NULL SELECT @Capacity = MaxUnits FROM logistics.Containers WHERE Id = @Id;
    IF @Capacity IS NULL SELECT @Capacity = MaxUnits FROM masterdata.ContainerTypes WHERE Id = @ContainerTypeId;

    DECLARE @Allocated INT = ISNULL((SELECT SUM(QuantityBase) FROM @Lines), 0);
    IF @Capacity IS NOT NULL AND @Allocated > @Capacity AND ISNULL(@AllowOverCapacity, 0) = 0
    BEGIN
        SET @Msg = N'The container holds ' + CAST(@Capacity AS NVARCHAR(10)) + N' units and ' + CAST(@Allocated AS NVARCHAR(10))
                 + N' are loaded. Confirm to load it above its capacity.';
        THROW 69007, @Msg, 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Id IS NULL
        BEGIN
            DECLARE @Ref NVARCHAR(30), @TypeId INT = (SELECT Id FROM inventory.DocumentTypes WHERE Code = N'CNT');
            EXEC inventory.usp_DocumentType_NextNumber N'CNT', @Ref OUTPUT, @BranchId;

            INSERT INTO logistics.Containers (DocumentTypeId, ContainerRef, PurchaseOrderId, ContainerNo, ContainerTypeId, SealNo, CustomsSealNo, Description,
                                              OrderDate, ShippingMethod, CountryOfOrigin, ForwarderId, TransporterId,
                                              ShippingLine, VesselName, VoyageNo, BookingNo, PortOfLoadingId, PortOfDestinationId, FinalDestinationId,
                                              DispatchDate, Eta, FreeDays, GrossWeightKg, VolumeCbm, Packages, BlNo, BlDate, BlNotes,
                                              MaxUnits, BranchId, WarehouseId, TruckNo, WaybillNo, DeclarationNo, FeriNo,
                                              ActualPortArrival, BorderCrossingDate, CustomsReleaseDate, StatusNote, Notes, Status, CreatedBy)
            VALUES (@TypeId, @Ref, @PurchaseOrderId, @ContainerNo, @ContainerTypeId, @SealNo, @CustomsSealNo, @Description,
                    @OrderDate, @ShippingMethod, @CountryOfOrigin, @ForwarderId, @TransporterId,
                    @ShippingLine, @VesselName, @VoyageNo, @BookingNo, @PortOfLoadingId, @PortOfDestinationId, @FinalDestinationId,
                    @DispatchDate, @Eta, @FreeDays, @GrossWeightKg, @VolumeCbm, @Packages, @BlNo, @BlDate, @BlNotes,
                    @Capacity, @BranchId, @WarehouseId, @TruckNo, @WaybillNo, @DeclarationNo, @FeriNo,
                    @ActualPortArrival, @BorderCrossingDate, @CustomsReleaseDate, @StatusNote, @Notes, 1, @UserId);
            SET @Id = SCOPE_IDENTITY();
            INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
            VALUES (@Id, N'Created', N'Draft ' + @Ref + ISNULL(N' from order ' + (SELECT DocumentNumber FROM purchase.PurchaseDocuments WHERE Id = @PurchaseOrderId), N''), @UserId);
        END
        ELSE
        BEGIN
            UPDATE logistics.Containers
            SET ContainerNo = @ContainerNo, ContainerTypeId = @ContainerTypeId, SealNo = @SealNo, CustomsSealNo = @CustomsSealNo,
                Description = @Description, OrderDate = @OrderDate, ShippingMethod = @ShippingMethod, CountryOfOrigin = @CountryOfOrigin,
                ForwarderId = @ForwarderId, TransporterId = @TransporterId, ShippingLine = @ShippingLine, VesselName = @VesselName,
                VoyageNo = @VoyageNo, BookingNo = @BookingNo, PortOfLoadingId = @PortOfLoadingId, PortOfDestinationId = @PortOfDestinationId,
                FinalDestinationId = @FinalDestinationId, DispatchDate = @DispatchDate, Eta = @Eta, FreeDays = @FreeDays,
                GrossWeightKg = @GrossWeightKg, VolumeCbm = @VolumeCbm, Packages = @Packages, BlNo = @BlNo, BlDate = @BlDate, BlNotes = @BlNotes,
                MaxUnits = @Capacity, BranchId = @BranchId, WarehouseId = @WarehouseId, TruckNo = @TruckNo, WaybillNo = @WaybillNo,
                DeclarationNo = @DeclarationNo, FeriNo = @FeriNo, ActualPortArrival = @ActualPortArrival,
                BorderCrossingDate = @BorderCrossingDate, CustomsReleaseDate = @CustomsReleaseDate, StatusNote = @StatusNote, Notes = @Notes,
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;
            INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
            VALUES (@Id, N'Updated', N'Header and ' + CAST((SELECT COUNT(*) FROM @Lines) AS NVARCHAR(10)) + N' line(s) saved', @UserId);
        END

        -- Lines are kept per order line: removed ones go (with their charge shares), the others are updated, new ones added.
        -- Lines of CANCELLED invoices let go of the removed container lines.
        UPDATE pil SET ContainerLineId = NULL
        FROM purchase.PurchaseDocumentLines pil
        INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId AND pd.Status = 3
        INNER JOIN logistics.ContainerLines cl   ON cl.Id = pil.ContainerLineId
        WHERE cl.ContainerId = @Id AND NOT EXISTS (SELECT 1 FROM @Lines l WHERE l.PoLineId = cl.PoLineId);

        DELETE a FROM logistics.ContainerChargeAllocations a
        INNER JOIN logistics.ContainerLines cl ON cl.Id = a.ContainerLineId
        WHERE cl.ContainerId = @Id AND NOT EXISTS (SELECT 1 FROM @Lines l WHERE l.PoLineId = cl.PoLineId);

        DELETE cl FROM logistics.ContainerLines cl
        WHERE cl.ContainerId = @Id AND NOT EXISTS (SELECT 1 FROM @Lines l WHERE l.PoLineId = cl.PoLineId);

        UPDATE cl
        SET LineNumber = l.LineNumber, Quantity = l.QuantityBase, OilIncluded = ISNULL(l.OilIncluded, 0),
            OilQtyPerUnit = CASE WHEN ISNULL(l.OilIncluded, 0) = 1 THEN ISNULL(l.OilQtyPerUnit, i.OilQtyPerUnit) END,
            Notes = NULLIF(LTRIM(RTRIM(l.Notes)), N'')
        FROM logistics.ContainerLines cl
        INNER JOIN @Lines l          ON l.PoLineId = cl.PoLineId
        INNER JOIN inventory.Items i ON i.Id = cl.ItemId
        WHERE cl.ContainerId = @Id;

        INSERT INTO logistics.ContainerLines (ContainerId, LineNumber, PurchaseOrderId, PoLineId, ItemId, ItemUnitId, PackingFormula,
                                              Quantity, OilIncluded, OilQtyPerUnit, Notes)
        SELECT @Id, l.LineNumber, pol.DocumentId, pol.Id, pol.ItemId, bu.Id, 1, l.QuantityBase, ISNULL(l.OilIncluded, 0),
               CASE WHEN ISNULL(l.OilIncluded, 0) = 1 THEN ISNULL(l.OilQtyPerUnit, i.OilQtyPerUnit) END,
               NULLIF(LTRIM(RTRIM(l.Notes)), N'')
        FROM @Lines l
        INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = l.PoLineId
        INNER JOIN inventory.Items i                  ON i.Id = pol.ItemId
        CROSS APPLY (SELECT TOP (1) u.Id FROM inventory.ItemUnits u WHERE u.ItemId = pol.ItemId AND u.IsBaseUnit = 1 ORDER BY u.Id) bu
        WHERE NOT EXISTS (SELECT 1 FROM logistics.ContainerLines cl WHERE cl.ContainerId = @Id AND cl.PoLineId = l.PoLineId);

        EXEC logistics.usp_Container_ReallocateCharges @Id;
        EXEC logistics.usp_Container_RefreshStatus @Id;

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Container lines that can still be invoiced (containers not offloaded / closed / cancelled), by order or by container.
CREATE OR ALTER PROCEDURE logistics.usp_Container_InvoiceCandidates
    @PurchaseOrderId INT = NULL,
    @ContainerId     INT = NULL,
    @IncludeAll      BIT = 0      -- 1 = also the lines already fully invoiced
AS
BEGIN
    SET NOCOUNT ON;
    IF @PurchaseOrderId IS NULL AND @ContainerId IS NULL THROW 69000, 'Give a purchase order or a container.', 1;

    SELECT cl.Id AS ContainerLineId, cl.ContainerId, c.ContainerRef, c.ContainerNo, c.Status AS ContainerStatus, cl.LineNumber,
           cl.PurchaseOrderId, d.DocumentNumber AS PurchaseOrderNumber, d.Status AS OrderStatus,
           d.SupplierId, sp.PartyName AS SupplierName, d.CurrencyId, cur.CurrencyCode,
           cl.PoLineId, pol.LineNumber AS PoLineNumber, cl.ItemId, i.ItemCode, i.ItemName,
           PoItemUnitId = pol.ItemUnitId, PoUnitTypeName = ut.UnitTypeName, PoPackingFormula = pol.PackingFormula,
           pol.UnitPrice, pol.DiscountPercent,
           LoadedBase         = cl.QuantityBase,
           InvoicedPostedBase = ISNULL(q.Posted, 0),
           InvoicedDraftBase  = ISNULL(q.Draft, 0),
           AvailableBase      = cl.QuantityBase - ISNULL(q.Posted, 0) - ISNULL(q.Draft, 0),
           OrderLineRemainingBase = pol.QuantityBase - pol.ReceivedQuantityBase - ISNULL(od.Draft, 0)
    FROM logistics.ContainerLines cl
    INNER JOIN logistics.Containers c             ON c.Id = cl.ContainerId
    INNER JOIN purchase.PurchaseDocuments d       ON d.Id = cl.PurchaseOrderId
    INNER JOIN masterdata.Parties sp              ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies cur          ON cur.Id = d.CurrencyId
    INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = cl.PoLineId
    INNER JOIN inventory.ItemUnits iu             ON iu.Id = pol.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut            ON ut.Id = iu.UnitTypeId
    INNER JOIN inventory.Items i                  ON i.Id = cl.ItemId
    OUTER APPLY (SELECT Posted = SUM(CASE WHEN x.Status IN (2, 4) THEN pil.QuantityBase END),
                        Draft  = SUM(CASE WHEN x.Status = 1 THEN pil.QuantityBase END)
                 FROM purchase.PurchaseDocumentLines pil
                 INNER JOIN purchase.PurchaseDocuments x ON x.Id = pil.DocumentId
                 WHERE pil.ContainerLineId = cl.Id) q
    OUTER APPLY (SELECT Draft = SUM(pil.QuantityBase)
                 FROM purchase.PurchaseDocumentLines pil
                 INNER JOIN purchase.PurchaseDocuments x ON x.Id = pil.DocumentId
                 WHERE pil.SourceLineId = pol.Id AND x.Status = 1) od
    WHERE c.Status NOT IN (6, 7, 8)
      AND (@PurchaseOrderId IS NULL OR cl.PurchaseOrderId = @PurchaseOrderId)
      AND (@ContainerId IS NULL OR cl.ContainerId = @ContainerId)
      AND (@IncludeAll = 1 OR cl.QuantityBase - ISNULL(q.Posted, 0) - ISNULL(q.Draft, 0) > 0)
    ORDER BY d.DocumentNumber, c.ContainerRef, cl.LineNumber;
END
GO

/* ================================================================== 11. Containers: confirm, close, reopen, cancel, delete */

CREATE OR ALTER PROCEDURE logistics.usp_Container_Confirm
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT = (SELECT Status FROM logistics.Containers WHERE Id = @Id);
    IF @Status IS NULL THROW 69006, 'Container not found.', 1;
    IF @Status <> 1 THROW 69010, 'Only a draft container can be confirmed.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 69004, 'This container was modified by another user. Reload the page and try again.', 1;
    IF NOT EXISTS (SELECT 1 FROM logistics.ContainerLines WHERE ContainerId = @Id)
        THROW 69009, 'The container has no items. Load at least one order line before confirming.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        UPDATE logistics.Containers
        SET ConfirmedAtUtc = SYSUTCDATETIME(), ConfirmedBy = @UserId, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;
        EXEC logistics.usp_Container_RefreshStatus @Id;
        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        VALUES (@Id, N'Confirmed', N'Loading plan confirmed', @UserId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE logistics.usp_Container_Close
    @Id INT, @RowVersion BINARY(8) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Status TINYINT = (SELECT Status FROM logistics.Containers WHERE Id = @Id);
    IF @Status IS NULL THROW 69006, 'Container not found.', 1;
    IF @Status <> 6 THROW 69010, 'Only an offloaded container can be closed.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 69004, 'This container was modified by another user. Reload the page and try again.', 1;
    IF EXISTS (SELECT 1 FROM logistics.ContainerCharges WHERE ContainerId = @Id AND Status = 1)
        THROW 70010, 'The container still has draft charges. Post or delete them before closing it.', 1;

    UPDATE logistics.Containers
    SET Status = 7, ClosedAtUtc = SYSUTCDATETIME(), ClosedBy = @UserId, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
    INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId) VALUES (@Id, N'Closed', N'Container closed', @UserId);
END
GO

-- A closed container is opened again (e.g. a late charge arrives).
CREATE OR ALTER PROCEDURE logistics.usp_Container_Reopen
    @Id INT, @RowVersion BINARY(8) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Status TINYINT = (SELECT Status FROM logistics.Containers WHERE Id = @Id);
    IF @Status IS NULL THROW 69006, 'Container not found.', 1;
    IF @Status <> 7 THROW 69010, 'Only a closed container can be reopened.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 69004, 'This container was modified by another user. Reload the page and try again.', 1;
    IF EXISTS (SELECT 1 FROM logistics.Containers c
               INNER JOIN logistics.Containers o ON o.ContainerNo = c.ContainerNo AND o.Id <> c.Id AND o.Status < 7
               WHERE c.Id = @Id AND c.ContainerNo IS NOT NULL)
        THROW 69013, 'Another open container already uses this container number. Change that one first.', 1;

    UPDATE logistics.Containers
    SET Status = 6, ClosedAtUtc = NULL, ClosedBy = NULL, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
    INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId) VALUES (@Id, N'Updated', N'Container reopened', @UserId);
END
GO

CREATE OR ALTER PROCEDURE logistics.usp_Container_Cancel
    @Id INT, @Reason NVARCHAR(300), @RowVersion BINARY(8) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 69000, 'A cancellation reason is required.', 1;

    DECLARE @Status TINYINT = (SELECT Status FROM logistics.Containers WHERE Id = @Id);
    IF @Status IS NULL THROW 69006, 'Container not found.', 1;
    IF @Status >= 6 THROW 69010, 'An offloaded, closed or cancelled container cannot be cancelled. Reverse the offload first.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 69004, 'This container was modified by another user. Reload the page and try again.', 1;

    DECLARE @Msg NVARCHAR(400);
    IF EXISTS (SELECT 1 FROM logistics.ContainerLines cl
               INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
               INNER JOIN purchase.PurchaseDocuments d        ON d.Id = pil.DocumentId
               WHERE cl.ContainerId = @Id AND d.Status <> 3)
    BEGIN
        SELECT TOP (1) @Msg = N'The container is invoiced by ' + ISNULL(d.DocumentNumber, N'a draft invoice') + N'. Cancel or delete its invoices first.'
        FROM logistics.ContainerLines cl
        INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
        INNER JOIN purchase.PurchaseDocuments d        ON d.Id = pil.DocumentId
        WHERE cl.ContainerId = @Id AND d.Status <> 3
        ORDER BY d.Status DESC, d.DocumentNumber;
        THROW 69012, @Msg, 1;
    END
    IF EXISTS (SELECT 1 FROM logistics.ContainerCharges WHERE ContainerId = @Id AND Status IN (1, 2))
        THROW 70014, 'The container has charges. Delete the drafts and cancel the posted ones first.', 1;
    SELECT TOP (1) @Msg = N'The container is part of movement ' + m.MovementNo + N'. Remove it from that movement first.'
    FROM logistics.MovementContainers mc
    INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
    WHERE mc.ContainerId = @Id AND m.Status IN (1, 2)
    ORDER BY m.MovementNo;
    IF @Msg IS NOT NULL THROW 70012, @Msg, 1;

    UPDATE logistics.Containers
    SET Status = 8, CancelledAtUtc = SYSUTCDATETIME(), CancelledBy = @UserId, CancelReason = @Reason,
        UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
    INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId) VALUES (@Id, N'Cancelled', @Reason, @UserId);
END
GO

CREATE OR ALTER PROCEDURE logistics.usp_Container_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Status TINYINT = (SELECT Status FROM logistics.Containers WHERE Id = @Id);
    IF @Status IS NULL THROW 69006, 'Container not found.', 1;
    IF @Status <> 1 THROW 69005, 'Only a draft container can be deleted. Cancel the others.', 1;
    IF EXISTS (SELECT 1 FROM logistics.ContainerLines cl
               INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
               INNER JOIN purchase.PurchaseDocuments d        ON d.Id = pil.DocumentId
               WHERE cl.ContainerId = @Id AND d.Status <> 3)
        THROW 69012, 'The container is invoiced. Cancel or delete its invoices first.', 1;
    IF EXISTS (SELECT 1 FROM logistics.ContainerCharges WHERE ContainerId = @Id AND Status IN (2, 3))
        THROW 70014, 'Posted or cancelled charges refer to this container. Cancel the container instead.', 1;
    IF EXISTS (SELECT 1 FROM logistics.MovementContainers mc INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
               WHERE mc.ContainerId = @Id AND m.Status IN (2, 3))
        THROW 70012, 'The container already travelled with a movement. Cancel the container instead.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE @Files TABLE (FileId INT PRIMARY KEY);
        INSERT INTO @Files (FileId) SELECT DISTINCT FileId FROM logistics.ContainerAttachments WHERE ContainerId = @Id;
        DELETE FROM logistics.ContainerAttachments WHERE ContainerId = @Id;
        DELETE f FROM logistics.Files f INNER JOIN @Files x ON x.FileId = f.Id
        WHERE NOT EXISTS (SELECT 1 FROM logistics.ContainerAttachments a WHERE a.FileId = f.Id);

        UPDATE pil SET ContainerLineId = NULL                  -- lines of cancelled invoices
        FROM purchase.PurchaseDocumentLines pil
        INNER JOIN logistics.ContainerLines cl ON cl.Id = pil.ContainerLineId
        WHERE cl.ContainerId = @Id;

        DELETE a FROM logistics.ContainerChargeAllocations a INNER JOIN logistics.ContainerCharges ch ON ch.Id = a.ChargeId WHERE ch.ContainerId = @Id;
        DELETE FROM logistics.ContainerCharges WHERE ContainerId = @Id;
        DELETE FROM logistics.MovementContainers WHERE ContainerId = @Id;
        DELETE FROM logistics.ContainerLines WHERE ContainerId = @Id;
        DELETE FROM logistics.ContainerAudit WHERE ContainerId = @Id;
        DELETE FROM logistics.Containers WHERE Id = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 12. Shipment movements */

CREATE OR ALTER PROCEDURE logistics.usp_Movement_Search
    @Search         NVARCHAR(100) = NULL,   -- movement no., vessel / truck, voyage, reference, container ref / no.
    @Status         TINYINT       = NULL,
    @MovementTypeId INT           = NULL,
    @PlaceId        INT           = NULL,   -- from or to
    @ContainerId    INT           = NULL,
    @CarrierPartyId INT           = NULL,
    @DateFrom       DATE          = NULL,   -- start date, else planned date
    @DateTo         DATE          = NULL,
    @SortColumn     NVARCHAR(30)  = N'StartDate',   -- MovementNo | StartDate | Eta | EndDate | Status | CreatedAtUtc
    @SortDirection  NVARCHAR(4)   = N'DESC',
    @PageNumber     INT           = 1,
    @PageSize       INT           = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'MovementNo', N'StartDate', N'Eta', N'EndDate', N'Status', N'CreatedAtUtc') SET @SortColumn = N'StartDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);
    DECLARE @Today DATE = CAST(SYSUTCDATETIME() AS DATE);

    SELECT m.Id, m.MovementNo, m.MovementTypeId, mt.TypeCode, mt.TypeName, mt.Stage,
           m.FromPlaceId, fp.PortCode AS FromCode, fp.PortName AS FromName, fp.Kind AS FromKind,
           m.ToPlaceId, tp.PortCode AS ToCode, tp.PortName AS ToName, tp.Kind AS ToKind,
           m.PlannedDate, m.StartDate, m.Eta, m.EndDate, m.Status,
           m.CarrierPartyId, cp.PartyName AS CarrierName, m.VehicleOrVessel, m.VoyageNo, m.Reference,
           ContainerCount = ISNULL(ctn.Cnt, 0),
           ContainerRefs = CASE WHEN ISNULL(ctn.Cnt, 0) = 0 THEN NULL WHEN ctn.Cnt = 1 THEN ctn.FirstRef
                                ELSE ctn.FirstRef + N' +' + CAST(ctn.Cnt - 1 AS NVARCHAR(10)) END,
           ChargesPostedBase = (SELECT SUM(ch.AmountBase) FROM logistics.ContainerCharges ch WHERE ch.MovementId = m.Id AND ch.Status = 2),
           AttachmentCount = (SELECT COUNT(*) FROM logistics.ContainerAttachments a WHERE a.MovementId = m.Id),
           DurationDays = CASE WHEN m.StartDate IS NOT NULL THEN DATEDIFF(DAY, m.StartDate, ISNULL(m.EndDate, @Today)) END,
           IsLate = CAST(CASE WHEN m.Status IN (1, 2) AND m.Eta < @Today THEN 1 ELSE 0 END AS BIT),
           m.CreatedAtUtc, cu.FullName AS CreatedByName, m.UpdatedAtUtc, m.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM logistics.Movements m
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    INNER JOIN masterdata.Ports fp         ON fp.Id = m.FromPlaceId
    INNER JOIN masterdata.Ports tp         ON tp.Id = m.ToPlaceId
    LEFT  JOIN masterdata.Parties cp       ON cp.Id = m.CarrierPartyId
    LEFT  JOIN security.Users cu           ON cu.Id = m.CreatedBy
    OUTER APPLY (SELECT Cnt = COUNT(*), FirstRef = MIN(c.ContainerRef)
                 FROM logistics.MovementContainers mc INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
                 WHERE mc.MovementId = m.Id) ctn
    WHERE (@Search IS NULL OR m.MovementNo LIKE N'%' + @Search + N'%' OR m.VehicleOrVessel LIKE N'%' + @Search + N'%'
           OR m.VoyageNo LIKE N'%' + @Search + N'%' OR m.Reference LIKE N'%' + @Search + N'%'
           OR EXISTS (SELECT 1 FROM logistics.MovementContainers mc INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
                      WHERE mc.MovementId = m.Id AND (c.ContainerRef LIKE N'%' + @Search + N'%' OR c.ContainerNo LIKE N'%' + @Search + N'%')))
      AND (@Status IS NULL OR m.Status = @Status)
      AND (@MovementTypeId IS NULL OR m.MovementTypeId = @MovementTypeId)
      AND (@PlaceId IS NULL OR m.FromPlaceId = @PlaceId OR m.ToPlaceId = @PlaceId)
      AND (@CarrierPartyId IS NULL OR m.CarrierPartyId = @CarrierPartyId)
      AND (@ContainerId IS NULL OR EXISTS (SELECT 1 FROM logistics.MovementContainers mc WHERE mc.MovementId = m.Id AND mc.ContainerId = @ContainerId))
      AND (@DateFrom IS NULL OR COALESCE(m.StartDate, m.PlannedDate) >= @DateFrom)
      AND (@DateTo IS NULL OR COALESCE(m.StartDate, m.PlannedDate) <= @DateTo)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'MovementNo' THEN m.MovementNo END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'MovementNo' THEN m.MovementNo END DESC,
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'StartDate' THEN COALESCE(m.StartDate, m.PlannedDate) WHEN N'Eta' THEN m.Eta WHEN N'EndDate' THEN m.EndDate END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'StartDate' THEN COALESCE(m.StartDate, m.PlannedDate) WHEN N'Eta' THEN m.Eta WHEN N'EndDate' THEN m.EndDate END END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Status' THEN CAST(m.Status AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Status' THEN CAST(m.Status AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN m.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN m.CreatedAtUtc END DESC,
        m.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

-- Four result sets: 1 header, 2 containers, 3 charges linked to the movement, 4 attachments linked to the movement.
CREATE OR ALTER PROCEDURE logistics.usp_Movement_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT m.Id, m.DocumentTypeId, m.MovementNo, m.MovementTypeId, mt.TypeCode, mt.TypeName, mt.Stage,
           m.FromPlaceId, fp.PortCode AS FromCode, fp.PortName AS FromName, fp.CountryCode AS FromCountry, fp.Kind AS FromKind,
           m.ToPlaceId, tp.PortCode AS ToCode, tp.PortName AS ToName, tp.CountryCode AS ToCountry, tp.Kind AS ToKind,
           m.PlannedDate, m.StartDate, m.Eta, m.EndDate, m.Status, m.CancelReason,
           m.CarrierPartyId, cp.PartyName AS CarrierName, m.VehicleOrVessel, m.VoyageNo, m.Reference, m.Notes,
           m.StartedAtUtc, su.FullName AS StartedByName, m.CompletedAtUtc, ku.FullName AS CompletedByName,
           m.CancelledAtUtc, xu.FullName AS CancelledByName,
           m.CreatedAtUtc, m.CreatedBy, cu.FullName AS CreatedByName, m.UpdatedAtUtc, m.UpdatedBy, uu.FullName AS UpdatedByName,
           m.RowVersion
    FROM logistics.Movements m
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    INNER JOIN masterdata.Ports fp         ON fp.Id = m.FromPlaceId
    INNER JOIN masterdata.Ports tp         ON tp.Id = m.ToPlaceId
    LEFT  JOIN masterdata.Parties cp       ON cp.Id = m.CarrierPartyId
    LEFT  JOIN security.Users su ON su.Id = m.StartedBy
    LEFT  JOIN security.Users ku ON ku.Id = m.CompletedBy
    LEFT  JOIN security.Users xu ON xu.Id = m.CancelledBy
    LEFT  JOIN security.Users cu ON cu.Id = m.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = m.UpdatedBy
    WHERE m.Id = @Id;

    SELECT c.Id AS ContainerId, c.ContainerRef, c.ContainerNo, ct.TypeCode AS ContainerTypeCode, c.Status AS ContainerStatus,
           c.CurrentLocation, c.TotalAllocatedBase, c.TotalOilQty,
           ItemSummary = CASE WHEN ln.ItemCount = 1 THEN ln.FirstItem WHEN ln.ItemCount > 1 THEN N'Mixed - ' + CAST(ln.ItemCount AS NVARCHAR(10)) + N' items' END,
           SupplierName = ln.FirstSupplier,
           ChargesBase = (SELECT SUM(ch.AmountBase) FROM logistics.ContainerCharges ch WHERE ch.ContainerId = c.Id AND ch.MovementId = @Id AND ch.Status = 2),
           DraftChargesBase = (SELECT SUM(ch.AmountBase) FROM logistics.ContainerCharges ch WHERE ch.ContainerId = c.Id AND ch.MovementId = @Id AND ch.Status = 1),
           AttachmentCount = (SELECT COUNT(*) FROM logistics.ContainerAttachments a WHERE a.ContainerId = c.Id AND a.MovementId = @Id),
           c.RowVersion AS ContainerRowVersion
    FROM logistics.MovementContainers mc
    INNER JOIN logistics.Containers c       ON c.Id = mc.ContainerId
    INNER JOIN masterdata.ContainerTypes ct ON ct.Id = c.ContainerTypeId
    OUTER APPLY (SELECT ItemCount = COUNT(DISTINCT cl.ItemId), FirstItem = MIN(i.ItemName), FirstSupplier = MIN(sp.PartyName)
                 FROM logistics.ContainerLines cl
                 INNER JOIN inventory.Items i ON i.Id = cl.ItemId
                 INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                 INNER JOIN masterdata.Parties sp ON sp.Id = d.SupplierId
                 WHERE cl.ContainerId = c.Id) ln
    WHERE mc.MovementId = @Id
    ORDER BY c.ContainerRef;

    SELECT ch.Id, ch.ContainerId, c.ContainerRef, ch.GroupId, ch.ChargeTypeId, t.ChargeCode, t.ChargeName, ch.Description,
           pp.PartyName AS ProviderName, ch.Reference, ch.ChargeDate, cur.CurrencyCode, ch.Amount, ch.AmountBase,
           ch.AllocationMethod, ch.IncludeInLandedCost, ch.Status, ch.RowVersion
    FROM logistics.ContainerCharges ch
    INNER JOIN logistics.Containers c    ON c.Id = ch.ContainerId
    INNER JOIN purchase.ChargeTypes t    ON t.Id = ch.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = ch.CurrencyId
    LEFT  JOIN masterdata.Parties pp     ON pp.Id = ch.ProviderPartyId
    WHERE ch.MovementId = @Id
    ORDER BY ch.ChargeDate, c.ContainerRef, ch.Id;

    SELECT a.Id, a.ContainerId, c.ContainerRef, a.ChargeId, a.AttachmentTypeId, at.Category, at.SubType,
           a.FileId, f.FileName, f.ContentType, f.SizeBytes, a.Note, a.DocumentDate, a.GroupId,
           a.CreatedAtUtc, u.FullName AS CreatedByName
    FROM logistics.ContainerAttachments a
    INNER JOIN logistics.Containers c        ON c.Id = a.ContainerId
    INNER JOIN logistics.Files f             ON f.Id = a.FileId
    LEFT  JOIN masterdata.AttachmentTypes at ON at.Id = a.AttachmentTypeId
    LEFT  JOIN security.Users u              ON u.Id = a.CreatedBy
    WHERE a.MovementId = @Id
    ORDER BY a.CreatedAtUtc DESC, c.ContainerRef;
END
GO

-- Planned movements: everything editable. In progress: header and containers editable (start date too), no end date.
CREATE OR ALTER PROCEDURE logistics.usp_Movement_Save
    @Id              INT            = NULL,
    @MovementTypeId  INT,
    @FromPlaceId     INT,
    @ToPlaceId       INT,
    @PlannedDate     DATE           = NULL,
    @StartDate       DATE           = NULL,   -- used only while in progress (Start sets it)
    @Eta             DATE           = NULL,
    @CarrierPartyId  INT            = NULL,
    @VehicleOrVessel NVARCHAR(100)  = NULL,
    @VoyageNo        NVARCHAR(30)   = NULL,
    @Reference       NVARCHAR(50)   = NULL,
    @Notes           NVARCHAR(1000) = NULL,
    @ContainerIds    logistics.tvp_IdList READONLY,
    @RowVersion      BINARY(8)      = NULL,
    @UserId          INT            = NULL,
    @NewId           INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @VehicleOrVessel = NULLIF(LTRIM(RTRIM(@VehicleOrVessel)), N'');
    SET @VoyageNo = NULLIF(LTRIM(RTRIM(@VoyageNo)), N'');
    SET @Reference = NULLIF(LTRIM(RTRIM(@Reference)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');

    IF NOT EXISTS (SELECT 1 FROM masterdata.MovementTypes WHERE Id = @MovementTypeId AND IsActive = 1)
        THROW 70000, 'Movement type not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Ports WHERE Id = @FromPlaceId AND IsActive = 1)
        THROW 70000, 'The departure place is not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Ports WHERE Id = @ToPlaceId AND IsActive = 1)
        THROW 70000, 'The destination place is not found or inactive.', 1;
    IF @CarrierPartyId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @CarrierPartyId AND IsActive = 1)
        THROW 70000, 'The carrier is not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM @ContainerIds) THROW 70000, 'Select at least one container.', 1;

    DECLARE @Status TINYINT = 1;
    IF @Id IS NOT NULL
    BEGIN
        SELECT @Status = Status FROM logistics.Movements WHERE Id = @Id;
        IF @Status IS NULL THROW 70006, 'Movement not found.', 1;
        IF @Status NOT IN (1, 2) THROW 70005, 'A completed or cancelled movement can no longer be changed.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Movements WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 70004, 'This movement was modified by another user. Reload the page and try again.', 1;
        IF @Status = 2 AND @StartDate IS NULL THROW 70000, 'The start date of a movement in progress is required.', 1;
    END
    IF @Status = 1 SET @StartDate = NULL;
    IF @StartDate IS NOT NULL AND @Eta IS NOT NULL AND @Eta < @StartDate THROW 70000, 'The ETA cannot be earlier than the start date.', 1;
    IF @PlannedDate IS NOT NULL AND @Eta IS NOT NULL AND @Eta < @PlannedDate THROW 70000, 'The ETA cannot be earlier than the planned date.', 1;

    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg = CASE WHEN c.Id IS NULL THEN N'A selected container no longer exists.'
                               WHEN c.Status >= 6 THEN N'Container ' + c.ContainerRef + N' is already offloaded, closed or cancelled.'
                               WHEN @Status = 2 AND c.Status = 1 THEN N'Container ' + c.ContainerRef + N' is not confirmed yet.' END
    FROM @ContainerIds x
    LEFT JOIN logistics.Containers c ON c.Id = x.Id
    WHERE (c.Id IS NULL OR c.Status >= 6 OR (@Status = 2 AND c.Status = 1))
      AND (@Id IS NULL OR NOT EXISTS (SELECT 1 FROM logistics.MovementContainers mc WHERE mc.MovementId = @Id AND mc.ContainerId = x.Id))
    ORDER BY c.ContainerRef;
    IF @Msg IS NOT NULL THROW 70000, @Msg, 1;

    IF @Status = 2
    BEGIN
        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' is already travelling with movement ' + m.MovementNo + N'.'
        FROM @ContainerIds x
        INNER JOIN logistics.Containers c         ON c.Id = x.Id
        INNER JOIN logistics.MovementContainers o ON o.ContainerId = x.Id AND o.MovementId <> @Id
        INNER JOIN logistics.Movements m          ON m.Id = o.MovementId AND m.Status = 2
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70012, @Msg, 1;
    END

    DECLARE @Affected TABLE (ContainerId INT PRIMARY KEY);

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Label NVARCHAR(300);
        IF @Id IS NULL
        BEGIN
            DECLARE @Number NVARCHAR(30), @TypeId INT = (SELECT Id FROM inventory.DocumentTypes WHERE Code = N'MOV');
            EXEC inventory.usp_DocumentType_NextNumber N'MOV', @Number OUTPUT, NULL;
            INSERT INTO logistics.Movements (DocumentTypeId, MovementNo, MovementTypeId, FromPlaceId, ToPlaceId, PlannedDate, Eta,
                                             CarrierPartyId, VehicleOrVessel, VoyageNo, Reference, Notes, Status, CreatedBy)
            VALUES (@TypeId, @Number, @MovementTypeId, @FromPlaceId, @ToPlaceId, @PlannedDate, @Eta,
                    @CarrierPartyId, @VehicleOrVessel, @VoyageNo, @Reference, @Notes, 1, @UserId);
            SET @Id = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            UPDATE logistics.Movements
            SET MovementTypeId = @MovementTypeId, FromPlaceId = @FromPlaceId, ToPlaceId = @ToPlaceId, PlannedDate = @PlannedDate,
                StartDate = CASE WHEN Status = 2 THEN @StartDate ELSE NULL END, Eta = @Eta,
                CarrierPartyId = @CarrierPartyId, VehicleOrVessel = @VehicleOrVessel, VoyageNo = @VoyageNo, Reference = @Reference,
                Notes = @Notes, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;
        END

        SELECT @Label = m.MovementNo + N' ' + mt.TypeName + N': ' + fp.PortName + N' ' + NCHAR(8594) + N' ' + tp.PortName
        FROM logistics.Movements m
        INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
        INNER JOIN masterdata.Ports fp ON fp.Id = m.FromPlaceId
        INNER JOIN masterdata.Ports tp ON tp.Id = m.ToPlaceId
        WHERE m.Id = @Id;

        INSERT INTO @Affected (ContainerId)
        SELECT mc.ContainerId FROM logistics.MovementContainers mc
        WHERE mc.MovementId = @Id AND NOT EXISTS (SELECT 1 FROM @ContainerIds x WHERE x.Id = mc.ContainerId)
        UNION
        SELECT x.Id FROM @ContainerIds x
        WHERE NOT EXISTS (SELECT 1 FROM logistics.MovementContainers mc WHERE mc.MovementId = @Id AND mc.ContainerId = x.Id);

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        SELECT a.ContainerId, N'Updated',
               LEFT(CASE WHEN EXISTS (SELECT 1 FROM @ContainerIds x WHERE x.Id = a.ContainerId) THEN N'Added to movement ' ELSE N'Removed from movement ' END + @Label, 500),
               @UserId
        FROM @Affected a;

        DELETE mc FROM logistics.MovementContainers mc
        WHERE mc.MovementId = @Id AND NOT EXISTS (SELECT 1 FROM @ContainerIds x WHERE x.Id = mc.ContainerId);
        INSERT INTO logistics.MovementContainers (MovementId, ContainerId)
        SELECT @Id, x.Id FROM @ContainerIds x
        WHERE NOT EXISTS (SELECT 1 FROM logistics.MovementContainers mc WHERE mc.MovementId = @Id AND mc.ContainerId = x.Id);

        -- in progress: the containers' status follows (all of them, the dates may have changed)
        IF @Status = 2
        BEGIN
            INSERT INTO @Affected (ContainerId)
            SELECT x.Id FROM @ContainerIds x WHERE NOT EXISTS (SELECT 1 FROM @Affected a WHERE a.ContainerId = x.Id);
            DECLARE @Cid INT;
            DECLARE ctn CURSOR LOCAL FAST_FORWARD FOR SELECT ContainerId FROM @Affected;
            OPEN ctn;
            FETCH NEXT FROM ctn INTO @Cid;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC logistics.usp_Container_RefreshStatus @Cid;
                FETCH NEXT FROM ctn INTO @Cid;
            END
            CLOSE ctn;
            DEALLOCATE ctn;
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

-- Status changes of a movement. @Action: Start | Complete | Cancel. The containers' status and dates follow.
CREATE OR ALTER PROCEDURE logistics.usp_Movement_SetStatus
    @Id         INT,
    @Action     NVARCHAR(10),
    @Date       DATE          = NULL,    -- Start: start date; Complete: end date (default today)
    @Reason     NVARCHAR(300) = NULL,    -- Cancel
    @RowVersion BINARY(8)     = NULL,
    @UserId     INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Action = NULLIF(LTRIM(RTRIM(@Action)), N'');
    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Date IS NULL SET @Date = CAST(SYSUTCDATETIME() AS DATE);
    IF @Action IS NULL OR @Action NOT IN (N'Start', N'Complete', N'Cancel') THROW 70000, 'Action must be Start, Complete or Cancel.', 1;

    DECLARE @Status TINYINT, @StartDate DATE, @Label NVARCHAR(300);
    SELECT @Status = m.Status, @StartDate = m.StartDate,
           @Label = m.MovementNo + N' ' + mt.TypeName + N': ' + fp.PortName + N' ' + NCHAR(8594) + N' ' + tp.PortName
    FROM logistics.Movements m WITH (UPDLOCK, HOLDLOCK)
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    INNER JOIN masterdata.Ports fp ON fp.Id = m.FromPlaceId
    INNER JOIN masterdata.Ports tp ON tp.Id = m.ToPlaceId
    WHERE m.Id = @Id;

    IF @Status IS NULL THROW 70006, 'Movement not found.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Movements WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 70004, 'This movement was modified by another user. Reload the page and try again.', 1;
    IF @Action = N'Start' AND @Status <> 1 THROW 70010, 'Only a planned movement can be started.', 1;
    IF @Action = N'Complete' AND @Status <> 2 THROW 70010, 'Only a movement in progress can be completed.', 1;
    IF @Action = N'Complete' AND @Date < @StartDate THROW 70000, 'The end date cannot be earlier than the start date.', 1;
    IF @Action = N'Cancel' AND @Status = 4 THROW 70010, 'The movement is already cancelled.', 1;
    IF @Action = N'Cancel' AND @Reason IS NULL THROW 70000, 'A cancellation reason is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM logistics.MovementContainers WHERE MovementId = @Id) AND @Action <> N'Cancel'
        THROW 70000, 'The movement has no containers.', 1;

    DECLARE @Msg NVARCHAR(400);
    IF @Action = N'Start'
    BEGIN
        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + CASE WHEN c.Status = 1 THEN N' is not confirmed yet.'
                                                                    ELSE N' is already offloaded, closed or cancelled.' END
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
        WHERE mc.MovementId = @Id AND (c.Status = 1 OR c.Status >= 6)
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70010, @Msg, 1;

        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' is already travelling with movement ' + m.MovementNo + N'. Complete it first.'
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Containers c         ON c.Id = mc.ContainerId
        INNER JOIN logistics.MovementContainers o ON o.ContainerId = mc.ContainerId AND o.MovementId <> @Id
        INNER JOIN logistics.Movements m          ON m.Id = o.MovementId AND m.Status = 2
        WHERE mc.MovementId = @Id
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70012, @Msg, 1;
    END
    IF @Action = N'Cancel'
    BEGIN
        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' is already offloaded: its route can no longer change.'
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
        WHERE mc.MovementId = @Id AND c.Status IN (6, 7) AND @Status IN (2, 3)
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70010, @Msg, 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE logistics.Movements
        SET Status = CASE @Action WHEN N'Start' THEN 2 WHEN N'Complete' THEN 3 ELSE 4 END,
            StartDate = CASE WHEN @Action = N'Start' THEN @Date ELSE StartDate END,
            EndDate = CASE WHEN @Action = N'Complete' THEN @Date ELSE EndDate END,
            StartedAtUtc = CASE WHEN @Action = N'Start' THEN SYSUTCDATETIME() ELSE StartedAtUtc END,
            StartedBy = CASE WHEN @Action = N'Start' THEN @UserId ELSE StartedBy END,
            CompletedAtUtc = CASE WHEN @Action = N'Complete' THEN SYSUTCDATETIME() ELSE CompletedAtUtc END,
            CompletedBy = CASE WHEN @Action = N'Complete' THEN @UserId ELSE CompletedBy END,
            CancelledAtUtc = CASE WHEN @Action = N'Cancel' THEN SYSUTCDATETIME() ELSE CancelledAtUtc END,
            CancelledBy = CASE WHEN @Action = N'Cancel' THEN @UserId ELSE CancelledBy END,
            CancelReason = CASE WHEN @Action = N'Cancel' THEN @Reason ELSE CancelReason END,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        SELECT mc.ContainerId, N'Event',
               LEFT(CASE @Action WHEN N'Start' THEN N'Started ' WHEN N'Complete' THEN N'Arrived / completed ' ELSE N'Cancelled ' END
                    + @Label + N' on ' + CONVERT(NVARCHAR(10), @Date, 23) + ISNULL(N' - ' + @Reason, N''), 500),
               @UserId
        FROM logistics.MovementContainers mc WHERE mc.MovementId = @Id;

        DECLARE @Cid INT;
        DECLARE ctn CURSOR LOCAL FAST_FORWARD FOR SELECT ContainerId FROM logistics.MovementContainers WHERE MovementId = @Id;
        OPEN ctn;
        FETCH NEXT FROM ctn INTO @Cid;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC logistics.usp_Container_RefreshStatus @Cid;
            FETCH NEXT FROM ctn INTO @Cid;
        END
        CLOSE ctn;
        DEALLOCATE ctn;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE logistics.usp_Movement_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Status TINYINT = (SELECT Status FROM logistics.Movements WHERE Id = @Id);
    IF @Status IS NULL THROW 70006, 'Movement not found.', 1;
    IF @Status <> 1 THROW 70005, 'Only a planned movement can be deleted. Cancel the others.', 1;
    IF EXISTS (SELECT 1 FROM logistics.ContainerCharges WHERE MovementId = @Id)
       OR EXISTS (SELECT 1 FROM logistics.ContainerAttachments WHERE MovementId = @Id)
        THROW 70014, 'Charges or attachments refer to this movement. Cancel it instead.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE FROM logistics.MovementContainers WHERE MovementId = @Id;
        DELETE FROM logistics.Movements WHERE Id = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Tracking board: open containers (and those offloaded during the last @OffloadedDays days) with their route legs.
CREATE OR ALTER PROCEDURE logistics.usp_Container_Tracking
    @ContainerId   INT           = NULL,
    @Search        NVARCHAR(100) = NULL,
    @OffloadedDays INT           = 30
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @Today DATE = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @Ids TABLE (Id INT PRIMARY KEY);
    INSERT INTO @Ids (Id)
    SELECT c.Id FROM logistics.Containers c
    WHERE (@ContainerId IS NULL OR c.Id = @ContainerId)
      AND (@ContainerId IS NOT NULL OR c.Status IN (2, 3, 4, 5)
           OR (c.Status IN (6, 7) AND c.OffloadedDate >= DATEADD(DAY, -ISNULL(@OffloadedDays, 30), @Today)))
      AND (@Search IS NULL OR c.ContainerRef LIKE N'%' + @Search + N'%' OR c.ContainerNo LIKE N'%' + @Search + N'%'
           OR c.BlNo LIKE N'%' + @Search + N'%' OR c.VesselName LIKE N'%' + @Search + N'%');

    -- 1: containers
    SELECT c.Id, c.ContainerRef, c.ContainerNo, ct.TypeCode AS ContainerTypeCode, c.Status, c.CurrentLocation,
           c.DispatchDate, c.Eta, c.ActualPortArrival, c.CustomsReleaseDate, c.OffloadedDate, c.LastFreeDay,
           DaysAtPort = CASE WHEN c.ActualPortArrival IS NOT NULL
                             THEN DATEDIFF(DAY, c.ActualPortArrival, ISNULL(c.OffloadedDate, @Today)) END,
           c.TotalAllocatedBase, c.TotalOilQty,
           ItemSummary = CASE WHEN ln.ItemCount = 1 THEN ln.FirstItem WHEN ln.ItemCount > 1 THEN N'Mixed - ' + CAST(ln.ItemCount AS NVARCHAR(10)) + N' items' END,
           SupplierName = ln.FirstSupplier,
           pl.PortName AS PortOfLoadingName, pd.PortName AS PortOfDestinationName, fd.PortName AS FinalDestinationName,
           w.WarehouseName
    FROM @Ids x
    INNER JOIN logistics.Containers c       ON c.Id = x.Id
    INNER JOIN masterdata.ContainerTypes ct ON ct.Id = c.ContainerTypeId
    LEFT  JOIN masterdata.Ports pl          ON pl.Id = c.PortOfLoadingId
    LEFT  JOIN masterdata.Ports pd          ON pd.Id = c.PortOfDestinationId
    LEFT  JOIN masterdata.Ports fd          ON fd.Id = c.FinalDestinationId
    LEFT  JOIN masterdata.Warehouses w      ON w.Id = c.WarehouseId
    OUTER APPLY (SELECT ItemCount = COUNT(DISTINCT cl.ItemId), FirstItem = MIN(i.ItemName), FirstSupplier = MIN(sp.PartyName)
                 FROM logistics.ContainerLines cl
                 INNER JOIN inventory.Items i ON i.Id = cl.ItemId
                 INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                 INNER JOIN masterdata.Parties sp ON sp.Id = d.SupplierId
                 WHERE cl.ContainerId = c.Id) ln
    ORDER BY c.Status, c.Eta, c.ContainerRef;

    -- 2: legs in route order; ProgressPct places the container on an in-progress leg (elapsed / planned duration)
    SELECT mc.ContainerId, m.Id AS MovementId, m.MovementNo,
           Seq = ROW_NUMBER() OVER (PARTITION BY mc.ContainerId ORDER BY COALESCE(m.StartDate, m.PlannedDate, CAST(m.CreatedAtUtc AS DATE)), m.Id),
           mt.TypeCode, mt.TypeName, mt.Stage,
           m.FromPlaceId, fp.PortCode AS FromCode, fp.PortName AS FromName, fp.Kind AS FromKind, fp.CountryCode AS FromCountry,
           m.ToPlaceId, tp.PortCode AS ToCode, tp.PortName AS ToName, tp.Kind AS ToKind, tp.CountryCode AS ToCountry,
           m.PlannedDate, m.StartDate, m.Eta, m.EndDate, m.Status,
           cp.PartyName AS CarrierName, m.VehicleOrVessel, m.VoyageNo,
           ProgressPct = CASE WHEN m.Status = 3 THEN 100
                              WHEN m.Status = 1 THEN 0
                              WHEN m.Eta IS NOT NULL AND m.StartDate IS NOT NULL AND m.Eta > m.StartDate
                                   THEN CASE WHEN DATEDIFF(DAY, m.StartDate, @Today) <= 0 THEN 0
                                             WHEN DATEDIFF(DAY, m.StartDate, @Today) * 100 / DATEDIFF(DAY, m.StartDate, m.Eta) > 95 THEN 95
                                             ELSE DATEDIFF(DAY, m.StartDate, @Today) * 100 / DATEDIFF(DAY, m.StartDate, m.Eta) END
                              ELSE 50 END,
           IsLate = CAST(CASE WHEN m.Status IN (1, 2) AND m.Eta < @Today THEN 1 ELSE 0 END AS BIT)
    FROM @Ids x
    INNER JOIN logistics.MovementContainers mc ON mc.ContainerId = x.Id
    INNER JOIN logistics.Movements m           ON m.Id = mc.MovementId AND m.Status <> 4
    INNER JOIN masterdata.MovementTypes mt     ON mt.Id = m.MovementTypeId
    INNER JOIN masterdata.Ports fp             ON fp.Id = m.FromPlaceId
    INNER JOIN masterdata.Ports tp             ON tp.Id = m.ToPlaceId
    LEFT  JOIN masterdata.Parties cp           ON cp.Id = m.CarrierPartyId
    ORDER BY mc.ContainerId, Seq;
END
GO

/* ================================================================== 13. Attachments: per container, general or per movement / charge */

-- One upload for one or several containers: the file is stored once, one record per container.
-- With @MovementId every container must be in the movement. With @ChargeId the record of each container points to
-- that container's charge of the same group (a provider invoice covering several containers).
CREATE OR ALTER PROCEDURE logistics.usp_ContainerAttachment_Add
    @ContainerIds     logistics.tvp_IdList READONLY,
    @MovementId       INT            = NULL,
    @ChargeId         INT            = NULL,
    @AttachmentTypeId INT            = NULL,
    @FileName         NVARCHAR(255),
    @ContentType      NVARCHAR(100),
    @SizeBytes        INT,
    @Content          VARBINARY(MAX),
    @Note             NVARCHAR(300)  = NULL,
    @DocumentDate     DATE           = NULL,
    @UserId           INT            = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @FileName = NULLIF(LTRIM(RTRIM(@FileName)), N'');
    SET @Note = NULLIF(LTRIM(RTRIM(@Note)), N'');

    DECLARE @Ids TABLE (Id INT PRIMARY KEY);
    INSERT INTO @Ids (Id) SELECT Id FROM @ContainerIds;
    -- a charge alone is enough: its container is taken
    IF NOT EXISTS (SELECT 1 FROM @Ids) AND @ChargeId IS NOT NULL
        INSERT INTO @Ids (Id) SELECT ContainerId FROM logistics.ContainerCharges WHERE Id = @ChargeId;

    IF NOT EXISTS (SELECT 1 FROM @Ids) THROW 70000, 'Select at least one container.', 1;
    IF @FileName IS NULL THROW 70000, 'The file name is required.', 1;
    IF @SizeBytes IS NULL OR @SizeBytes <= 0 OR @Content IS NULL THROW 70000, 'The file is empty.', 1;
    IF @AttachmentTypeId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Id = @AttachmentTypeId)
        THROW 70000, 'Attachment type not found.', 1;
    IF EXISTS (SELECT 1 FROM @Ids x WHERE NOT EXISTS (SELECT 1 FROM logistics.Containers c WHERE c.Id = x.Id))
        THROW 70006, 'A selected container no longer exists.', 1;
    IF @MovementId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Movements WHERE Id = @MovementId)
        THROW 70006, 'Movement not found.', 1;

    DECLARE @Msg NVARCHAR(400);
    IF @MovementId IS NOT NULL
    BEGIN
        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' is not part of this movement.'
        FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id
        WHERE NOT EXISTS (SELECT 1 FROM logistics.MovementContainers mc WHERE mc.MovementId = @MovementId AND mc.ContainerId = x.Id)
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70000, @Msg, 1;
    END

    DECLARE @GroupOfCharge UNIQUEIDENTIFIER = NULL;
    IF @ChargeId IS NOT NULL
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM logistics.ContainerCharges WHERE Id = @ChargeId) THROW 70006, 'Charge not found.', 1;
        SELECT @GroupOfCharge = GroupId FROM logistics.ContainerCharges WHERE Id = @ChargeId;
        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' has no charge of this group.'
        FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id
        WHERE NOT EXISTS (SELECT 1 FROM logistics.ContainerCharges ch
                          WHERE ch.ContainerId = x.Id AND (ch.Id = @ChargeId OR (@GroupOfCharge IS NOT NULL AND ch.GroupId = @GroupOfCharge)))
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70000, @Msg, 1;
    END

    DECLARE @Group UNIQUEIDENTIFIER = CASE WHEN (SELECT COUNT(*) FROM @Ids) > 1 THEN NEWID() END;
    DECLARE @FileId INT;

    BEGIN TRY
        BEGIN TRANSACTION;
        INSERT INTO logistics.Files (FileName, ContentType, SizeBytes, Content, CreatedBy)
        VALUES (@FileName, ISNULL(NULLIF(LTRIM(RTRIM(@ContentType)), N''), N'application/octet-stream'), @SizeBytes, @Content, @UserId);
        SET @FileId = SCOPE_IDENTITY();

        INSERT INTO logistics.ContainerAttachments (ContainerId, MovementId, ChargeId, AttachmentTypeId, FileId, Note, DocumentDate, GroupId, CreatedBy)
        SELECT x.Id, @MovementId,
               (SELECT TOP (1) ch.Id FROM logistics.ContainerCharges ch
                WHERE ch.ContainerId = x.Id AND (ch.Id = @ChargeId OR (@GroupOfCharge IS NOT NULL AND ch.GroupId = @GroupOfCharge))
                ORDER BY CASE WHEN ch.Id = @ChargeId THEN 0 ELSE 1 END, ch.Id),
               @AttachmentTypeId, @FileId, @Note, @DocumentDate, @Group, @UserId
        FROM @Ids x;

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        SELECT x.Id, N'Updated', LEFT(N'Attachment added: ' + @FileName
                                      + ISNULL(N' (movement ' + (SELECT MovementNo FROM logistics.Movements WHERE Id = @MovementId) + N')', N''), 500), @UserId
        FROM @Ids x;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT a.Id, a.ContainerId, c.ContainerRef, a.FileId, a.MovementId, a.ChargeId
    FROM logistics.ContainerAttachments a
    INNER JOIN logistics.Containers c ON c.Id = a.ContainerId
    WHERE a.FileId = @FileId
    ORDER BY c.ContainerRef;
END
GO

-- Removes one record (@AllShared = 0) or the file from every container that holds it (@AllShared = 1).
CREATE OR ALTER PROCEDURE logistics.usp_ContainerAttachment_Delete
    @Id        INT,
    @AllShared BIT = 0,
    @UserId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @FileId INT, @FileName NVARCHAR(255);
    SELECT @FileId = a.FileId, @FileName = f.FileName
    FROM logistics.ContainerAttachments a INNER JOIN logistics.Files f ON f.Id = a.FileId
    WHERE a.Id = @Id;
    IF @FileId IS NULL THROW 70006, 'Attachment not found.', 1;

    DECLARE @Gone TABLE (ContainerId INT);
    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE FROM logistics.ContainerAttachments
        OUTPUT deleted.ContainerId INTO @Gone (ContainerId)
        WHERE Id = @Id OR (ISNULL(@AllShared, 0) = 1 AND FileId = @FileId);

        IF NOT EXISTS (SELECT 1 FROM logistics.ContainerAttachments WHERE FileId = @FileId)
            DELETE FROM logistics.Files WHERE Id = @FileId;

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        SELECT DISTINCT g.ContainerId, N'Updated', LEFT(N'Attachment removed: ' + @FileName, 500), @UserId FROM @Gone g;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE logistics.usp_ContainerAttachment_GetFile
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT a.Id, a.ContainerId, a.MovementId, a.ChargeId, f.FileName, f.ContentType, f.SizeBytes, f.Content
    FROM logistics.ContainerAttachments a
    INNER JOIN logistics.Files f ON f.Id = a.FileId
    WHERE a.Id = @Id;
END
GO

/* ================================================================== 14. Container charges: create, update, post, cancel, delete */

-- One charge typed for one or several containers: one DRAFT record per container (same GroupId when several).
-- @SplitRule: Same = every container gets @TotalAmount; Equal = equal parts; Pieces = by quantity; Value = by FOB value.
-- Returns the created charges.
CREATE OR ALTER PROCEDURE logistics.usp_ContainerCharge_Create
    @ContainerIds     logistics.tvp_IdList READONLY,
    @MovementId       INT            = NULL,
    @ChargeTypeId     INT,
    @Description      NVARCHAR(200)  = NULL,
    @ProviderPartyId  INT            = NULL,
    @Reference        NVARCHAR(100)  = NULL,
    @ChargeDate       DATE,
    @CurrencyId       INT            = NULL,      -- NULL = base currency
    @RateType         TINYINT        = NULL,      -- NULL = 1 (official)
    @ExchangeRate     DECIMAL(18,6)  = NULL,      -- NULL = the rate of the charge date
    @TotalAmount      DECIMAL(18,2),
    @SplitRule        NVARCHAR(10)   = N'Pieces',
    @AllocationMethod NVARCHAR(10)   = NULL,      -- NULL = the charge type's method
    @Notes            NVARCHAR(300)  = NULL,
    @UserId           INT            = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Description = NULLIF(LTRIM(RTRIM(@Description)), N'');
    SET @Reference = NULLIF(LTRIM(RTRIM(@Reference)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    SET @SplitRule = ISNULL(NULLIF(LTRIM(RTRIM(@SplitRule)), N''), N'Pieces');
    SET @AllocationMethod = NULLIF(LTRIM(RTRIM(@AllocationMethod)), N'');
    SET @RateType = ISNULL(@RateType, 1);

    IF @ChargeDate IS NULL THROW 70000, 'The charge date is required.', 1;
    IF @TotalAmount IS NULL OR @TotalAmount < 0 THROW 70000, 'The amount cannot be negative.', 1;
    IF @SplitRule NOT IN (N'Same', N'Equal', N'Pieces', N'Value') THROW 70000, 'Split rule must be Same, Equal, Pieces or Value.', 1;
    IF @AllocationMethod IS NOT NULL AND @AllocationMethod NOT IN (N'Value', N'Quantity', N'Weight', N'Volume', N'Manual')
        THROW 70000, 'Allocation method must be Value, Quantity, Weight, Volume or Manual.', 1;
    IF @RateType NOT IN (1, 2, 3) THROW 70000, 'Unknown rate type.', 1;
    IF @ExchangeRate IS NOT NULL AND @ExchangeRate <= 0 THROW 70000, 'The exchange rate must be greater than zero.', 1;

    DECLARE @Method NVARCHAR(10), @InLanded BIT, @TypeLabel NVARCHAR(120);
    SELECT @Method = ISNULL(@AllocationMethod, AllocationMethod), @InLanded = IncludeInLandedCost, @TypeLabel = ChargeCode + N' ' + ChargeName
    FROM purchase.ChargeTypes WHERE Id = @ChargeTypeId AND IsActive = 1;
    IF @Method IS NULL THROW 70000, 'Charge type not found or inactive.', 1;
    IF @ProviderPartyId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @ProviderPartyId AND IsActive = 1)
        THROW 70000, 'The provider is not found or inactive.', 1;

    DECLARE @Ids TABLE (Id INT PRIMARY KEY);
    INSERT INTO @Ids (Id) SELECT Id FROM @ContainerIds;
    IF NOT EXISTS (SELECT 1 FROM @Ids) THROW 70000, 'Select at least one container.', 1;

    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg = CASE WHEN c.Id IS NULL THEN N'A selected container no longer exists.'
                               ELSE N'Container ' + c.ContainerRef + N' is closed or cancelled.' END
    FROM @Ids x LEFT JOIN logistics.Containers c ON c.Id = x.Id
    WHERE c.Id IS NULL OR c.Status IN (7, 8)
    ORDER BY c.ContainerRef;
    IF @Msg IS NOT NULL THROW 70010, @Msg, 1;

    IF @MovementId IS NOT NULL
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM logistics.Movements WHERE Id = @MovementId AND Status <> 4)
            THROW 70000, 'The movement is not found or cancelled.', 1;
        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' is not part of this movement.'
        FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id
        WHERE NOT EXISTS (SELECT 1 FROM logistics.MovementContainers mc WHERE mc.MovementId = @MovementId AND mc.ContainerId = x.Id)
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70000, @Msg, 1;
    END

    DECLARE @BaseCurrency INT = (SELECT TOP (1) Id FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1);
    SET @CurrencyId = ISNULL(@CurrencyId, @BaseCurrency);
    IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsActive = 1)
        THROW 70000, 'Currency not found or inactive.', 1;
    DECLARE @Rate DECIMAL(18,6) = CASE WHEN @CurrencyId = @BaseCurrency THEN 1
                                       ELSE COALESCE(@ExchangeRate, masterdata.fn_GetRate(@CurrencyId, @RateType, @ChargeDate)) END;
    IF @Rate IS NULL OR @Rate <= 0 THROW 70000, 'No exchange rate for this currency on the charge date. Add one or enter the rate.', 1;
    DECLARE @CurrencyCode NVARCHAR(10) = (SELECT CurrencyCode FROM masterdata.Currencies WHERE Id = @CurrencyId);

    -- split of the total over the containers
    DECLARE @Split TABLE (ContainerId INT PRIMARY KEY, Weight DECIMAL(38,10), Share DECIMAL(38,10), Amount DECIMAL(18,2));
    INSERT INTO @Split (ContainerId, Weight)
    SELECT x.Id, CASE @SplitRule WHEN N'Pieces' THEN ISNULL(q.Qty, 0) WHEN N'Value' THEN ISNULL(q.Val, 0) ELSE 1 END
    FROM @Ids x
    OUTER APPLY (SELECT Qty = SUM(CAST(ISNULL(cl.ReceivedQuantityBase, cl.QuantityBase) AS DECIMAL(38,10))),
                        Val = SUM(CAST(ISNULL(cl.ReceivedQuantityBase, cl.QuantityBase) AS DECIMAL(38,10))
                                  * COALESCE(cl.FobCostBase, inv.UnitValue, po.UnitValue, 0))
                 FROM logistics.ContainerLines cl
                 OUTER APPLY (SELECT UnitValue = SUM(pil.LineTotal / pid.ExchangeRate) / NULLIF(SUM(pil.QuantityBase), 0)
                              FROM purchase.PurchaseDocumentLines pil
                              INNER JOIN purchase.PurchaseDocuments pid ON pid.Id = pil.DocumentId
                              WHERE pil.ContainerLineId = cl.Id AND pid.Status IN (1, 2, 4)) inv
                 OUTER APPLY (SELECT UnitValue = pol.LineTotal / pod.ExchangeRate / NULLIF(pol.QuantityBase, 0)
                              FROM purchase.PurchaseDocumentLines pol
                              INNER JOIN purchase.PurchaseDocuments pod ON pod.Id = pol.DocumentId
                              WHERE pol.Id = cl.PoLineId) po
                 WHERE cl.ContainerId = x.Id) q;

    DECLARE @Count INT = (SELECT COUNT(*) FROM @Split), @W DECIMAL(38,10) = (SELECT SUM(Weight) FROM @Split);
    IF @Count > 1 AND @SplitRule IN (N'Pieces', N'Value') AND (@W IS NULL OR @W <= 0)
        THROW 70013, 'The selected containers have no items (or no value) to split the amount by. Use Equal or Same.', 1;

    IF @Count = 1 OR @SplitRule = N'Same'
        UPDATE @Split SET Amount = @TotalAmount;
    ELSE
    BEGIN
        UPDATE @Split SET Share = CAST(@TotalAmount AS DECIMAL(38,10)) * Weight / @W;
        UPDATE @Split SET Amount = FLOOR(Share * 100) / 100;
        DECLARE @Cents INT = CAST(ROUND((@TotalAmount - (SELECT SUM(Amount) FROM @Split)) * 100, 0) AS INT);
        IF @Cents > 0
        BEGIN
            WITH r AS (SELECT ContainerId, Rn = ROW_NUMBER() OVER (ORDER BY Share * 100 - FLOOR(Share * 100) DESC, Weight DESC, ContainerId) FROM @Split)
            UPDATE s SET Amount = s.Amount + 0.01
            FROM @Split s INNER JOIN r ON r.ContainerId = s.ContainerId
            WHERE r.Rn <= @Cents;
        END
    END

    DECLARE @Group UNIQUEIDENTIFIER = CASE WHEN @Count > 1 THEN NEWID() END;
    DECLARE @New TABLE (Id INT PRIMARY KEY, ContainerId INT);

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO logistics.ContainerCharges (ContainerId, MovementId, GroupId, ChargeTypeId, Description, ProviderPartyId, Reference, ChargeDate,
                                                CurrencyId, RateType, ExchangeRate, Amount, AmountBase, AllocationMethod, IncludeInLandedCost, Notes, CreatedBy)
        OUTPUT inserted.Id, inserted.ContainerId INTO @New (Id, ContainerId)
        SELECT s.ContainerId, @MovementId, @Group, @ChargeTypeId, @Description, @ProviderPartyId, @Reference, @ChargeDate,
               @CurrencyId, @RateType, @Rate, s.Amount, ROUND(s.Amount / @Rate, 2), @Method, @InLanded, @Notes, @UserId
        FROM @Split s;

        DECLARE @ChargeId INT;
        DECLARE newc CURSOR LOCAL FAST_FORWARD FOR SELECT Id FROM @New ORDER BY Id;
        OPEN newc;
        FETCH NEXT FROM newc INTO @ChargeId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC logistics.usp_ContainerCharge_Allocate @ChargeId, 1;
            FETCH NEXT FROM newc INTO @ChargeId;
        END
        CLOSE newc;
        DEALLOCATE newc;

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        SELECT n.ContainerId, N'Updated',
               LEFT(N'Charge added (draft): ' + @TypeLabel + N' ' + CAST(ch.Amount AS NVARCHAR(30)) + N' ' + @CurrencyCode
                    + CASE WHEN @Count > 1 THEN N' (' + @SplitRule + N' split of ' + CAST(@TotalAmount AS NVARCHAR(30)) + N' over '
                                                + CAST(@Count AS NVARCHAR(10)) + N' containers)' ELSE N'' END, 500),
               @UserId
        FROM @New n INNER JOIN logistics.ContainerCharges ch ON ch.Id = n.Id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT ch.Id, ch.ContainerId, c.ContainerRef, c.ContainerNo, ch.GroupId, ch.Amount, ch.AmountBase, ch.Status, ch.RowVersion
    FROM @New n
    INNER JOIN logistics.ContainerCharges ch ON ch.Id = n.Id
    INNER JOIN logistics.Containers c        ON c.Id = ch.ContainerId
    ORDER BY c.ContainerRef;
END
GO

-- A DRAFT charge. @Manual = the shares per container line when the method is Manual (they must add up to the amount).
CREATE OR ALTER PROCEDURE logistics.usp_ContainerCharge_Update
    @Id               INT,
    @MovementId       INT            = NULL,
    @ChargeTypeId     INT,
    @Description      NVARCHAR(200)  = NULL,
    @ProviderPartyId  INT            = NULL,
    @Reference        NVARCHAR(100)  = NULL,
    @ChargeDate       DATE,
    @CurrencyId       INT            = NULL,
    @RateType         TINYINT        = NULL,
    @ExchangeRate     DECIMAL(18,6)  = NULL,
    @Amount           DECIMAL(18,2),
    @AllocationMethod NVARCHAR(10)   = NULL,
    @Notes            NVARCHAR(300)  = NULL,
    @Manual           logistics.tvp_ChargeManual READONLY,
    @RowVersion       BINARY(8)      = NULL,
    @UserId           INT            = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Description = NULLIF(LTRIM(RTRIM(@Description)), N'');
    SET @Reference = NULLIF(LTRIM(RTRIM(@Reference)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    SET @AllocationMethod = NULLIF(LTRIM(RTRIM(@AllocationMethod)), N'');
    SET @RateType = ISNULL(@RateType, 1);

    DECLARE @ContainerId INT, @Status TINYINT, @CtStatus TINYINT;
    SELECT @ContainerId = ch.ContainerId, @Status = ch.Status, @CtStatus = c.Status
    FROM logistics.ContainerCharges ch INNER JOIN logistics.Containers c ON c.Id = ch.ContainerId
    WHERE ch.Id = @Id;
    IF @ContainerId IS NULL THROW 70006, 'Charge not found.', 1;
    IF @Status <> 1 THROW 70005, 'Only a draft charge can be changed. Cancel a posted charge and enter it again.', 1;
    IF @CtStatus IN (7, 8) THROW 70010, 'The container is closed or cancelled.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.ContainerCharges WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 70004, 'This charge was modified by another user. Reload the page and try again.', 1;

    IF @ChargeDate IS NULL THROW 70000, 'The charge date is required.', 1;
    IF @Amount IS NULL OR @Amount < 0 THROW 70000, 'The amount cannot be negative.', 1;
    IF @AllocationMethod IS NOT NULL AND @AllocationMethod NOT IN (N'Value', N'Quantity', N'Weight', N'Volume', N'Manual')
        THROW 70000, 'Allocation method must be Value, Quantity, Weight, Volume or Manual.', 1;
    IF @RateType NOT IN (1, 2, 3) THROW 70000, 'Unknown rate type.', 1;
    IF @ExchangeRate IS NOT NULL AND @ExchangeRate <= 0 THROW 70000, 'The exchange rate must be greater than zero.', 1;

    DECLARE @Method NVARCHAR(10), @InLanded BIT;
    SELECT @Method = ISNULL(@AllocationMethod, AllocationMethod), @InLanded = IncludeInLandedCost
    FROM purchase.ChargeTypes WHERE Id = @ChargeTypeId AND IsActive = 1;
    IF @Method IS NULL THROW 70000, 'Charge type not found or inactive.', 1;
    IF @ProviderPartyId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @ProviderPartyId AND IsActive = 1)
        THROW 70000, 'The provider is not found or inactive.', 1;
    IF @MovementId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.MovementContainers mc INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
                                               WHERE mc.MovementId = @MovementId AND mc.ContainerId = @ContainerId AND m.Status <> 4)
        THROW 70000, 'The container is not part of this movement (or the movement is cancelled).', 1;

    DECLARE @BaseCurrency INT = (SELECT TOP (1) Id FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1);
    SET @CurrencyId = ISNULL(@CurrencyId, @BaseCurrency);
    IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsActive = 1)
        THROW 70000, 'Currency not found or inactive.', 1;
    DECLARE @Rate DECIMAL(18,6) = CASE WHEN @CurrencyId = @BaseCurrency THEN 1
                                       ELSE COALESCE(@ExchangeRate, masterdata.fn_GetRate(@CurrencyId, @RateType, @ChargeDate)) END;
    IF @Rate IS NULL OR @Rate <= 0 THROW 70000, 'No exchange rate for this currency on the charge date. Add one or enter the rate.', 1;
    DECLARE @AmountBase DECIMAL(18,2) = ROUND(@Amount / @Rate, 2);

    IF @Method = N'Manual' AND @InLanded = 1 AND EXISTS (SELECT 1 FROM @Manual)
    BEGIN
        IF EXISTS (SELECT 1 FROM @Manual m WHERE NOT EXISTS (SELECT 1 FROM logistics.ContainerLines cl WHERE cl.Id = m.ContainerLineId AND cl.ContainerId = @ContainerId))
            THROW 70000, 'A manual share refers to a line that is not in the container.', 1;
        IF EXISTS (SELECT 1 FROM @Manual WHERE AmountBase < 0) THROW 70000, 'Manual shares cannot be negative.', 1;
        IF ABS((SELECT SUM(AmountBase) FROM @Manual) - @AmountBase) > 0.01
        BEGIN
            DECLARE @Msg NVARCHAR(400) = N'The manual shares (' + CAST((SELECT SUM(AmountBase) FROM @Manual) AS NVARCHAR(30))
                                       + N') must add up to the charge in base currency (' + CAST(@AmountBase AS NVARCHAR(30)) + N').';
            THROW 70013, @Msg, 1;
        END
    END

    BEGIN TRY
        BEGIN TRANSACTION;
        UPDATE logistics.ContainerCharges
        SET MovementId = @MovementId, ChargeTypeId = @ChargeTypeId, Description = @Description, ProviderPartyId = @ProviderPartyId,
            Reference = @Reference, ChargeDate = @ChargeDate, CurrencyId = @CurrencyId, RateType = @RateType, ExchangeRate = @Rate,
            Amount = @Amount, AmountBase = @AmountBase, AllocationMethod = @Method, IncludeInLandedCost = @InLanded, Notes = @Notes,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        IF @Method = N'Manual' AND @InLanded = 1
        BEGIN
            IF EXISTS (SELECT 1 FROM @Manual)
            BEGIN
                DELETE FROM logistics.ContainerChargeAllocations WHERE ChargeId = @Id;
                INSERT INTO logistics.ContainerChargeAllocations (ChargeId, ContainerLineId, Basis, AmountBase, IsManual)
                SELECT @Id, ContainerLineId, NULL, AmountBase, 1 FROM @Manual WHERE AmountBase > 0;
            END
            ELSE
                DELETE FROM logistics.ContainerChargeAllocations WHERE ChargeId = @Id AND IsManual = 0;
        END
        ELSE
            EXEC logistics.usp_ContainerCharge_Allocate @Id, 1;

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        SELECT @ContainerId, N'Updated', LEFT(N'Charge changed (draft): ' + t.ChargeCode + N' ' + t.ChargeName + N' '
                                               + CAST(@Amount AS NVARCHAR(30)) + N' ' + cur.CurrencyCode, 500), @UserId
        FROM purchase.ChargeTypes t CROSS JOIN masterdata.Currencies cur
        WHERE t.Id = @ChargeTypeId AND cur.Id = @CurrencyId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Posts one draft (@Id) or several (@Ids, e.g. a whole group) in one transaction.
-- Before the offload: the charge joins the provisional cost of the lines. After the offload: cost adjustment
-- (the part still in stock -> average cost, the part already sold -> COGS).
CREATE OR ALTER PROCEDURE logistics.usp_ContainerCharge_Post
    @Id         INT       = NULL,
    @Ids        logistics.tvp_IdList READONLY,
    @RowVersion BINARY(8) = NULL,     -- checked with @Id only
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @List TABLE (Id INT PRIMARY KEY);
    INSERT INTO @List (Id) SELECT Id FROM @Ids;
    IF @Id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM @List WHERE Id = @Id) INSERT INTO @List (Id) VALUES (@Id);
    IF NOT EXISTS (SELECT 1 FROM @List) THROW 70000, 'Select at least one charge.', 1;
    IF @Id IS NOT NULL AND @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.ContainerCharges WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 70004, 'This charge was modified by another user. Reload the page and try again.', 1;

    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg = CASE WHEN ch.Id IS NULL THEN N'A selected charge no longer exists.'
                               WHEN ch.Status <> 1 THEN N'A charge of container ' + c.ContainerRef + N' is not a draft.'
                               ELSE N'Container ' + c.ContainerRef + N' is closed or cancelled.' END
    FROM @List x
    LEFT JOIN logistics.ContainerCharges ch ON ch.Id = x.Id
    LEFT JOIN logistics.Containers c        ON c.Id = ch.ContainerId
    WHERE ch.Id IS NULL OR ch.Status <> 1 OR c.Status IN (7, 8);
    IF @Msg IS NOT NULL THROW 70010, @Msg, 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @ChargeId INT, @ContainerId INT, @CtStatus TINYINT, @Method NVARCHAR(10), @InLanded BIT,
                @AmountBase DECIMAL(18,2), @Ref NVARCHAR(30), @Label NVARCHAR(200), @After BIT;
        DECLARE posts CURSOR LOCAL FAST_FORWARD FOR
            SELECT ch.Id FROM @List x INNER JOIN logistics.ContainerCharges ch ON ch.Id = x.Id ORDER BY ch.ContainerId, ch.Id;
        OPEN posts;
        FETCH NEXT FROM posts INTO @ChargeId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SELECT @ContainerId = ch.ContainerId, @CtStatus = c.Status, @Method = ch.AllocationMethod, @InLanded = ch.IncludeInLandedCost,
                   @AmountBase = ch.AmountBase, @Ref = c.ContainerRef,
                   @Label = t.ChargeCode + N' ' + t.ChargeName + N' ' + CAST(ch.Amount AS NVARCHAR(30)) + N' ' + cur.CurrencyCode
            FROM logistics.ContainerCharges ch
            INNER JOIN logistics.Containers c    ON c.Id = ch.ContainerId
            INNER JOIN purchase.ChargeTypes t    ON t.Id = ch.ChargeTypeId
            INNER JOIN masterdata.Currencies cur ON cur.Id = ch.CurrencyId
            WHERE ch.Id = @ChargeId;

            SET @After = CASE WHEN @CtStatus = 6 AND @InLanded = 1 THEN 1 ELSE 0 END;

            IF @InLanded = 1 AND @Method <> N'Manual'
                EXEC logistics.usp_ContainerCharge_Allocate @ChargeId, 0;
            IF @InLanded = 1 AND @Method = N'Manual'
               AND ABS(ISNULL((SELECT SUM(AmountBase) FROM logistics.ContainerChargeAllocations WHERE ChargeId = @ChargeId), 0) - @AmountBase) > 0.01
            BEGIN
                SET @Msg = N'Container ' + @Ref + N': the manual shares of ' + @Label + N' must add up to '
                         + CAST(@AmountBase AS NVARCHAR(30)) + N' (base currency). Edit the charge first.';
                THROW 70013, @Msg, 1;
            END

            UPDATE logistics.ContainerCharges
            SET Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId, AdjustedAfterOffload = @After,
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @ChargeId;

            EXEC logistics.usp_Container_RecalcCosts @ContainerId;
            IF @After = 1 EXEC logistics.usp_ContainerCharge_ApplyCost @ChargeId, 1, @UserId;

            INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
            VALUES (@ContainerId, N'Updated', LEFT(N'Charge posted: ' + @Label
                                                   + CASE WHEN @After = 1 THEN N' (after the offload: item costs adjusted)' ELSE N'' END, 500), @UserId);

            FETCH NEXT FROM posts INTO @ChargeId;
        END
        CLOSE posts;
        DEALLOCATE posts;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Cancels a POSTED charge. When it is already in the cost of offloaded goods, the cost is reversed the same way.
CREATE OR ALTER PROCEDURE logistics.usp_ContainerCharge_Cancel
    @Id         INT,
    @Reason     NVARCHAR(300),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 70000, 'A cancellation reason is required.', 1;

    DECLARE @ContainerId INT, @Status TINYINT, @CtStatus TINYINT, @InCost BIT, @Label NVARCHAR(200);
    SELECT @ContainerId = ch.ContainerId, @Status = ch.Status, @CtStatus = c.Status,
           @InCost = CASE WHEN c.Status = 6 AND ch.IncludeInLandedCost = 1 AND (ch.AppliedAtOffload = 1 OR ch.AdjustedAfterOffload = 1) THEN 1 ELSE 0 END,
           @Label = t.ChargeCode + N' ' + t.ChargeName + N' ' + CAST(ch.Amount AS NVARCHAR(30)) + N' ' + cur.CurrencyCode
    FROM logistics.ContainerCharges ch
    INNER JOIN logistics.Containers c    ON c.Id = ch.ContainerId
    INNER JOIN purchase.ChargeTypes t    ON t.Id = ch.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = ch.CurrencyId
    WHERE ch.Id = @Id;

    IF @ContainerId IS NULL THROW 70006, 'Charge not found.', 1;
    IF @Status <> 2 THROW 70010, 'Only a posted charge can be cancelled (delete a draft instead).', 1;
    IF @CtStatus = 7 THROW 70010, 'The container is closed. Reopen it first.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.ContainerCharges WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 70004, 'This charge was modified by another user. Reload the page and try again.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        UPDATE logistics.ContainerCharges
        SET Status = 3, CancelledAtUtc = SYSUTCDATETIME(), CancelledBy = @UserId, CancelReason = @Reason,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        EXEC logistics.usp_Container_RecalcCosts @ContainerId;
        IF @InCost = 1 EXEC logistics.usp_ContainerCharge_ApplyCost @Id, -1, @UserId;

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        VALUES (@ContainerId, N'Updated', LEFT(N'Charge cancelled: ' + @Label + N' - ' + @Reason
                                               + CASE WHEN @InCost = 1 THEN N' (item costs adjusted back)' ELSE N'' END, 500), @UserId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE logistics.usp_ContainerCharge_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @ContainerId INT, @Status TINYINT, @Label NVARCHAR(200);
    SELECT @ContainerId = ch.ContainerId, @Status = ch.Status,
           @Label = t.ChargeCode + N' ' + t.ChargeName + N' ' + CAST(ch.Amount AS NVARCHAR(30))
    FROM logistics.ContainerCharges ch INNER JOIN purchase.ChargeTypes t ON t.Id = ch.ChargeTypeId
    WHERE ch.Id = @Id;
    IF @ContainerId IS NULL THROW 70006, 'Charge not found.', 1;
    IF @Status <> 1 THROW 70005, 'Only a draft charge can be deleted. Cancel a posted one.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        UPDATE logistics.ContainerAttachments SET ChargeId = NULL WHERE ChargeId = @Id;
        DELETE FROM logistics.ContainerChargeAllocations WHERE ChargeId = @Id;
        DELETE FROM logistics.ContainerCharges WHERE Id = @Id;
        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        VALUES (@ContainerId, N'Updated', LEFT(N'Draft charge deleted: ' + @Label, 500), @UserId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE logistics.usp_ContainerCharge_Search
    @Search          NVARCHAR(100) = NULL,   -- container ref / no., reference, description, provider
    @ContainerId     INT           = NULL,
    @MovementId      INT           = NULL,
    @ChargeTypeId    INT           = NULL,
    @ProviderPartyId INT           = NULL,
    @Status          TINYINT       = NULL,
    @DateFrom        DATE          = NULL,
    @DateTo          DATE          = NULL,
    @SortColumn      NVARCHAR(30)  = N'ChargeDate',   -- ChargeDate | ContainerRef | ChargeName | AmountBase | Status | CreatedAtUtc
    @SortDirection   NVARCHAR(4)   = N'DESC',
    @PageNumber      INT           = 1,
    @PageSize        INT           = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'ChargeDate', N'ContainerRef', N'ChargeName', N'AmountBase', N'Status', N'CreatedAtUtc') SET @SortColumn = N'ChargeDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT ch.Id, ch.ContainerId, c.ContainerRef, c.ContainerNo, c.Status AS ContainerStatus,
           ch.MovementId, m.MovementNo, ch.GroupId,
           GroupSize = CASE WHEN ch.GroupId IS NULL THEN 1 ELSE (SELECT COUNT(*) FROM logistics.ContainerCharges g WHERE g.GroupId = ch.GroupId) END,
           ch.ChargeTypeId, t.ChargeCode, t.ChargeName, ch.Description, ch.ProviderPartyId, pp.PartyName AS ProviderName, ch.Reference,
           ch.ChargeDate, ch.CurrencyId, cur.CurrencyCode, ch.RateType, ch.ExchangeRate, ch.Amount, ch.AmountBase,
           ch.AllocationMethod, ch.IncludeInLandedCost, ch.Status, ch.AppliedAtOffload, ch.AdjustedAfterOffload,
           AttachmentCount = (SELECT COUNT(*) FROM logistics.ContainerAttachments a WHERE a.ChargeId = ch.Id),
           ch.PostedAtUtc, ch.CreatedAtUtc, cu.FullName AS CreatedByName, ch.RowVersion,
           TotalAmountBase = SUM(ch.AmountBase) OVER (),
           COUNT(*) OVER () AS TotalCount
    FROM logistics.ContainerCharges ch
    INNER JOIN logistics.Containers c    ON c.Id = ch.ContainerId
    INNER JOIN purchase.ChargeTypes t    ON t.Id = ch.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = ch.CurrencyId
    LEFT  JOIN masterdata.Parties pp     ON pp.Id = ch.ProviderPartyId
    LEFT  JOIN logistics.Movements m     ON m.Id = ch.MovementId
    LEFT  JOIN security.Users cu         ON cu.Id = ch.CreatedBy
    WHERE (@Search IS NULL OR c.ContainerRef LIKE N'%' + @Search + N'%' OR c.ContainerNo LIKE N'%' + @Search + N'%'
           OR ch.Reference LIKE N'%' + @Search + N'%' OR ch.Description LIKE N'%' + @Search + N'%' OR pp.PartyName LIKE N'%' + @Search + N'%')
      AND (@ContainerId IS NULL OR ch.ContainerId = @ContainerId)
      AND (@MovementId IS NULL OR ch.MovementId = @MovementId)
      AND (@ChargeTypeId IS NULL OR ch.ChargeTypeId = @ChargeTypeId)
      AND (@ProviderPartyId IS NULL OR ch.ProviderPartyId = @ProviderPartyId)
      AND (@Status IS NULL OR ch.Status = @Status)
      AND (@DateFrom IS NULL OR ch.ChargeDate >= @DateFrom)
      AND (@DateTo IS NULL OR ch.ChargeDate <= @DateTo)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'ContainerRef' THEN c.ContainerRef WHEN N'ChargeName' THEN t.ChargeName END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'ContainerRef' THEN c.ContainerRef WHEN N'ChargeName' THEN t.ChargeName END END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'ChargeDate' THEN ch.ChargeDate END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'ChargeDate' THEN ch.ChargeDate END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'AmountBase' THEN ch.AmountBase END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'AmountBase' THEN ch.AmountBase END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Status' THEN CAST(ch.Status AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Status' THEN CAST(ch.Status AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN ch.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN ch.CreatedAtUtc END DESC,
        ch.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

-- Four result sets: 1 charge, 2 its shares per container line (real cost per item), 3 its attachments, 4 the other
-- containers' charges of the same group.
CREATE OR ALTER PROCEDURE logistics.usp_ContainerCharge_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT ch.Id, ch.ContainerId, c.ContainerRef, c.ContainerNo, c.Status AS ContainerStatus,
           ch.MovementId, m.MovementNo, ch.GroupId,
           ch.ChargeTypeId, t.ChargeCode, t.ChargeName, ch.Description, ch.ProviderPartyId, pp.PartyName AS ProviderName, ch.Reference,
           ch.ChargeDate, ch.CurrencyId, cur.CurrencyCode, ch.RateType, ch.ExchangeRate, ch.Amount, ch.AmountBase,
           ch.AllocationMethod, ch.IncludeInLandedCost, ch.Status, ch.AppliedAtOffload, ch.AdjustedAfterOffload, ch.Notes,
           ch.PostedAtUtc, pu.FullName AS PostedByName, ch.CancelledAtUtc, xu.FullName AS CancelledByName, ch.CancelReason,
           ch.CreatedAtUtc, cu.FullName AS CreatedByName, ch.UpdatedAtUtc, uu.FullName AS UpdatedByName, ch.RowVersion
    FROM logistics.ContainerCharges ch
    INNER JOIN logistics.Containers c    ON c.Id = ch.ContainerId
    INNER JOIN purchase.ChargeTypes t    ON t.Id = ch.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = ch.CurrencyId
    LEFT  JOIN masterdata.Parties pp     ON pp.Id = ch.ProviderPartyId
    LEFT  JOIN logistics.Movements m     ON m.Id = ch.MovementId
    LEFT  JOIN security.Users pu ON pu.Id = ch.PostedBy
    LEFT  JOIN security.Users xu ON xu.Id = ch.CancelledBy
    LEFT  JOIN security.Users cu ON cu.Id = ch.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = ch.UpdatedBy
    WHERE ch.Id = @Id;

    SELECT cl.Id AS ContainerLineId, cl.LineNumber, cl.ItemId, i.ItemCode, i.ItemName,
           QuantityBase = ISNULL(cl.ReceivedQuantityBase, cl.QuantityBase),
           a.Basis, AmountBase = ISNULL(a.AmountBase, 0), IsManual = ISNULL(a.IsManual, 0),
           PerUnitBase = ISNULL(a.AmountBase, 0) / NULLIF(ISNULL(cl.ReceivedQuantityBase, cl.QuantityBase), 0)
    FROM logistics.ContainerCharges ch
    INNER JOIN logistics.ContainerLines cl ON cl.ContainerId = ch.ContainerId
    INNER JOIN inventory.Items i           ON i.Id = cl.ItemId
    LEFT  JOIN logistics.ContainerChargeAllocations a ON a.ChargeId = ch.Id AND a.ContainerLineId = cl.Id
    WHERE ch.Id = @Id
    ORDER BY cl.LineNumber;

    SELECT a.Id, a.ContainerId, a.MovementId, a.AttachmentTypeId, at.Category, at.SubType,
           a.FileId, f.FileName, f.ContentType, f.SizeBytes, a.Note, a.DocumentDate, a.CreatedAtUtc, u.FullName AS CreatedByName
    FROM logistics.ContainerAttachments a
    INNER JOIN logistics.Files f ON f.Id = a.FileId
    LEFT  JOIN masterdata.AttachmentTypes at ON at.Id = a.AttachmentTypeId
    LEFT  JOIN security.Users u ON u.Id = a.CreatedBy
    WHERE a.ChargeId = @Id
    ORDER BY a.CreatedAtUtc DESC;

    SELECT g.Id, g.ContainerId, c.ContainerRef, c.ContainerNo, g.Amount, g.AmountBase, g.Status, g.RowVersion
    FROM logistics.ContainerCharges ch
    INNER JOIN logistics.ContainerCharges g ON g.GroupId = ch.GroupId AND g.Id <> ch.Id
    INNER JOIN logistics.Containers c       ON c.Id = g.ContainerId
    WHERE ch.Id = @Id AND ch.GroupId IS NOT NULL
    ORDER BY c.ContainerRef;
END
GO

/* ================================================================== 15. Offload = stock in at the real cost */

-- Needs every line fully invoiced by POSTED invoices and no movement in progress.
-- FOB per unit = the posted invoice lines; the posted charges are spread again over what really arrived and frozen;
-- landed per unit = FOB + charges / quantity received. Stock movements at the landed cost, moving average updated,
-- the invoice lines are received (in posting order) for what arrived.
CREATE OR ALTER PROCEDURE logistics.usp_Container_Offload
    @Id            INT,
    @Lines         logistics.tvp_ContainerReceipt READONLY,   -- empty = everything received as loaded
    @OffloadedDate DATE      = NULL,
    @WarehouseId   INT       = NULL,                          -- NULL = the container's warehouse
    @RowVersion    BINARY(8) = NULL,
    @UserId        INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @OffloadedDate IS NULL SET @OffloadedDate = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @Status TINYINT, @BranchId INT, @Ref NVARCHAR(30), @CtWarehouse INT;
    SELECT @Status = Status, @BranchId = BranchId, @Ref = ContainerRef, @CtWarehouse = WarehouseId
    FROM logistics.Containers WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;

    IF @Status IS NULL THROW 69006, 'Container not found.', 1;
    IF @Status IN (6, 7) THROW 69011, 'This container is already offloaded.', 1;
    IF @Status = 1 THROW 69010, 'Confirm the container before offloading it.', 1;
    IF @Status = 8 THROW 69010, 'A cancelled container cannot be offloaded.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 69004, 'This container was modified by another user. Reload the page and try again.', 1;

    IF @WarehouseId IS NULL SET @WarehouseId = @CtWarehouse;
    IF @WarehouseId IS NULL THROW 69000, 'The offloading warehouse is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1 AND BranchId = @BranchId)
        THROW 69000, 'The offloading warehouse is inactive or does not belong to the container branch.', 1;
    IF NOT EXISTS (SELECT 1 FROM logistics.ContainerLines WHERE ContainerId = @Id)
        THROW 69009, 'The container has no items.', 1;

    DECLARE @Msg NVARCHAR(400);

    SELECT TOP (1) @Msg = N'Movement ' + m.MovementNo + N' of this container is still in progress. Complete it before offloading.'
    FROM logistics.MovementContainers mc
    INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
    WHERE mc.ContainerId = @Id AND m.Status = 2
    ORDER BY m.MovementNo;
    IF @Msg IS NOT NULL THROW 70010, @Msg, 1;

    SELECT TOP (1) @Msg = N'Line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): ' + CAST(cl.QuantityBase AS NVARCHAR(20))
                          + N' loaded but ' + CAST(ISNULL(q.Posted, 0) AS NVARCHAR(20)) + N' invoiced by posted invoices'
                          + CASE WHEN ISNULL(q.Draft, 0) > 0 THEN N' (' + CAST(q.Draft AS NVARCHAR(20)) + N' in draft invoices)' ELSE N'' END
                          + N'. Every line must be invoiced and the invoices posted before the offload.'
    FROM logistics.ContainerLines cl
    INNER JOIN inventory.Items i ON i.Id = cl.ItemId
    OUTER APPLY (SELECT Posted = SUM(CASE WHEN d.Status IN (2, 4) THEN pil.QuantityBase END),
                        Draft  = SUM(CASE WHEN d.Status = 1 THEN pil.QuantityBase END)
                 FROM purchase.PurchaseDocumentLines pil
                 INNER JOIN purchase.PurchaseDocuments d ON d.Id = pil.DocumentId
                 WHERE pil.ContainerLineId = cl.Id) q
    WHERE cl.ContainerId = @Id AND ISNULL(q.Posted, 0) <> cl.QuantityBase
    ORDER BY cl.LineNumber;
    IF @Msg IS NOT NULL THROW 69016, @Msg, 1;

    SELECT TOP (1) @Msg =
        CASE WHEN cl.Id IS NULL THEN N'A received line does not belong to this container.'
             WHEN r.ReceivedQuantityBase < 0 THEN N'Line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N': the received quantity cannot be negative.'
             WHEN r.ReceivedQuantityBase > cl.QuantityBase THEN N'Line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N': received '
                  + CAST(r.ReceivedQuantityBase AS NVARCHAR(20)) + N' but only ' + CAST(cl.QuantityBase AS NVARCHAR(20)) + N' were loaded.'
             ELSE N'Line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N': a reason is required when the received quantity differs from the loaded quantity.'
             END
    FROM @Lines r
    LEFT JOIN logistics.ContainerLines cl ON cl.Id = r.LineId AND cl.ContainerId = @Id
    WHERE cl.Id IS NULL OR r.ReceivedQuantityBase < 0 OR r.ReceivedQuantityBase > cl.QuantityBase
       OR (r.ReceivedQuantityBase <> cl.QuantityBase AND NULLIF(LTRIM(RTRIM(r.VarianceReason)), N'') IS NULL)
    ORDER BY cl.LineNumber;
    IF @Msg IS NOT NULL THROW 69000, @Msg, 1;

    -- a manual share of a posted charge cannot sit on a line that receives nothing (it could not enter any cost)
    SELECT TOP (1) @Msg = N'The posted charge ' + t.ChargeName + N' has a manual share on line ' + CAST(cl.LineNumber AS NVARCHAR(10))
                          + N' (' + i.ItemCode + N'), which receives nothing. Cancel that charge and enter it again on the received lines.'
    FROM logistics.ContainerChargeAllocations a
    INNER JOIN logistics.ContainerCharges ch ON ch.Id = a.ChargeId AND ch.Status = 2 AND ch.IncludeInLandedCost = 1 AND a.IsManual = 1
    INNER JOIN purchase.ChargeTypes t        ON t.Id = ch.ChargeTypeId
    INNER JOIN logistics.ContainerLines cl   ON cl.Id = a.ContainerLineId
    INNER JOIN inventory.Items i             ON i.Id = cl.ItemId
    LEFT  JOIN @Lines r                      ON r.LineId = cl.Id
    WHERE ch.ContainerId = @Id AND a.AmountBase > 0 AND ISNULL(r.ReceivedQuantityBase, cl.QuantityBase) = 0
    ORDER BY cl.LineNumber;
    IF @Msg IS NOT NULL THROW 70013, @Msg, 1;

    -- every offload has its own number in the ledger (KTG-2026-0001, then KTG-2026-0001/2 after a reversal)
    DECLARE @OffloadNo INT = 1 + (SELECT COUNT(DISTINCT m.DocumentNumber) FROM inventory.StockMovements m
                                  WHERE m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = N'CNT' AND m.DocumentId = @Id AND m.IsReversal = 0);
    DECLARE @Tag NVARCHAR(30) = LEFT(@Ref + CASE WHEN @OffloadNo > 1 THEN N'/' + CAST(@OffloadNo AS NVARCHAR(10)) ELSE N'' END, 30);

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE cl
        SET ReceivedQuantityBase = ISNULL(r.ReceivedQuantityBase, cl.QuantityBase),
            VarianceReason = NULLIF(LTRIM(RTRIM(r.VarianceReason)), N''),
            FobCostBase = f.Fob
        FROM logistics.ContainerLines cl
        LEFT JOIN @Lines r ON r.LineId = cl.Id
        OUTER APPLY (SELECT Fob = SUM(pil.FobCostBase * pil.QuantityBase) / NULLIF(SUM(pil.QuantityBase), 0)
                     FROM purchase.PurchaseDocumentLines pil
                     INNER JOIN purchase.PurchaseDocuments d ON d.Id = pil.DocumentId
                     WHERE pil.ContainerLineId = cl.Id AND d.Status IN (2, 4)) f
        WHERE cl.ContainerId = @Id;

        -- the posted charges follow the real quantities and values, then they are frozen in the cost of the goods
        EXEC logistics.usp_Container_ReallocateCharges @Id, 0;
        UPDATE logistics.ContainerCharges SET AppliedAtOffload = 1
        WHERE ContainerId = @Id AND Status = 2 AND IncludeInLandedCost = 1;
        EXEC logistics.usp_Container_RecalcCosts @Id;

        DECLARE @Rec TABLE (LineId INT PRIMARY KEY, ItemId INT, SupplierId INT, QuantityBase INT,
                            UnitCostBase DECIMAL(18,6), FobCostBase DECIMAL(18,6), ExpiryDate DATE);
        INSERT INTO @Rec (LineId, ItemId, SupplierId, QuantityBase, UnitCostBase, FobCostBase, ExpiryDate)
        SELECT cl.Id, cl.ItemId, po.SupplierId, cl.ReceivedQuantityBase, ISNULL(cl.LandedCostBase, 0), cl.FobCostBase,
               (SELECT MIN(pil.ExpiryDate) FROM purchase.PurchaseDocumentLines pil
                INNER JOIN purchase.PurchaseDocuments d ON d.Id = pil.DocumentId
                WHERE pil.ContainerLineId = cl.Id AND d.Status IN (2, 4))
        FROM logistics.ContainerLines cl
        INNER JOIN purchase.PurchaseDocuments po ON po.Id = cl.PurchaseOrderId
        WHERE cl.ContainerId = @Id AND cl.ReceivedQuantityBase > 0;

        DECLARE @MovementDate DATETIME2(3) =
            DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@OffloadedDate AS DATETIME2(3)));

        -- per supplier (last supplier / last cost follow the supplier of the goods): moving average first, then the
        -- movements of that supplier, so the next supplier's average sees them
        DECLARE @SupplierId INT;
        DECLARE @R inventory.tvp_ItemReceipt;
        DECLARE suppliers CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT SupplierId FROM @Rec;
        OPEN suppliers;
        FETCH NEXT FROM suppliers INTO @SupplierId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            DELETE FROM @R;
            INSERT INTO @R (ItemId, QuantityBase, UnitCostBase, FobCostBase)
            SELECT ItemId, QuantityBase, UnitCostBase, FobCostBase FROM @Rec WHERE SupplierId = @SupplierId;
            EXEC inventory.usp_Item_ApplyReceipts @R, @SupplierId, @UserId, 1;

            INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                                  DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, CreatedBy)
            SELECT @MovementDate, r.ItemId, @WarehouseId, @BranchId, r.QuantityBase, r.UnitCostBase,
                   N'Purchase', N'CNT', @Id, r.LineId, @Tag, NULL, r.ExpiryDate, @UserId
            FROM @Rec r
            WHERE r.SupplierId = @SupplierId;

            FETCH NEXT FROM suppliers INTO @SupplierId;
        END
        CLOSE suppliers;
        DEALLOCATE suppliers;

        -- the invoice lines are received, in posting order, for what actually arrived
        WITH x AS
        (
            SELECT pil.Id, pil.QuantityBase, Rec = ISNULL(cl.ReceivedQuantityBase, 0),
                   Before = ISNULL(SUM(pil.QuantityBase) OVER (PARTITION BY cl.Id ORDER BY d.PostedAtUtc, pil.Id
                                                               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)
            FROM logistics.ContainerLines cl
            INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
            INNER JOIN purchase.PurchaseDocuments d        ON d.Id = pil.DocumentId AND d.Status IN (2, 4)
            WHERE cl.ContainerId = @Id
        )
        UPDATE pl
        SET ReceivedQuantityBase = pl.ReceivedQuantityBase
                                 + CASE WHEN x.Rec - x.Before <= 0 THEN 0
                                        WHEN x.Rec - x.Before >= x.QuantityBase THEN x.QuantityBase
                                        ELSE x.Rec - x.Before END
        FROM purchase.PurchaseDocumentLines pl
        INNER JOIN x ON x.Id = pl.Id;

        UPDATE logistics.Containers
        SET OffloadedDate = @OffloadedDate, OffloadedAtUtc = SYSUTCDATETIME(), OffloadedBy = @UserId,
            WarehouseId = @WarehouseId, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        EXEC logistics.usp_Container_RefreshStatus @Id;

        DECLARE @Total INT = (SELECT ISNULL(SUM(QuantityBase), 0) FROM @Rec);
        DECLARE @Short INT = (SELECT COUNT(*) FROM logistics.ContainerLines WHERE ContainerId = @Id AND ReceivedQuantityBase < QuantityBase);
        DECLARE @Value DECIMAL(18,2) = (SELECT ISNULL(SUM(QuantityBase * UnitCostBase), 0) FROM @Rec);
        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        VALUES (@Id, N'Offloaded', LEFT(@Tag + N': received ' + CAST(@Total AS NVARCHAR(20)) + N' base unit(s) into '
                + (SELECT WarehouseCode FROM masterdata.Warehouses WHERE Id = @WarehouseId)
                + N' at a landed value of ' + CAST(@Value AS NVARCHAR(30))
                + CASE WHEN @Short > 0 THEN N'; ' + CAST(@Short AS NVARCHAR(10)) + N' line(s) short-shipped' ELSE N'' END, 500), @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Reverses an offload: movements reversed, invoice lines released, charges spread again (not frozen), costs replayed.
-- Refused once a charge changed the item costs after the offload (69018).
CREATE OR ALTER PROCEDURE logistics.usp_Container_CancelOffload
    @Id         INT,
    @Reason     NVARCHAR(300),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 69000, 'A reason is required.', 1;

    DECLARE @Status TINYINT = (SELECT Status FROM logistics.Containers WHERE Id = @Id);
    IF @Status IS NULL THROW 69006, 'Container not found.', 1;
    IF @Status <> 6 THROW 69010, 'Only an offloaded container that is not closed can be reversed.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 69004, 'This container was modified by another user. Reload the page and try again.', 1;
    IF EXISTS (SELECT 1 FROM inventory.CostAdjustments ca
               INNER JOIN logistics.ContainerCharges ch ON ch.Id = ca.SourceId
               WHERE ca.SourceKind = N'CNTCHARGE' AND ch.ContainerId = @Id)
        THROW 69018, 'Charges were posted or cancelled after the offload and the item costs were adjusted. The offload can no longer be reversed.', 1;

    -- the offload to reverse = the latest one of this container that is not reversed yet
    DECLARE @Tag NVARCHAR(30) =
        (SELECT TOP (1) m.DocumentNumber FROM inventory.StockMovements m
         WHERE m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = N'CNT' AND m.DocumentId = @Id AND m.IsReversal = 0
           AND NOT EXISTS (SELECT 1 FROM inventory.StockMovements r
                           WHERE r.DocumentFamily = m.DocumentFamily AND r.DocumentTypeCode = m.DocumentTypeCode
                             AND r.DocumentId = m.DocumentId AND r.DocumentNumber = m.DocumentNumber AND r.IsReversal = 1)
         ORDER BY m.Id DESC);

    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg = N'Cannot reverse: ' + i.ItemCode + N' in ' + w.WarehouseCode + N' has only '
                         + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20))
                         + N' left, but this container brought ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
    FROM (SELECT m.ItemId, m.WarehouseId, Qty = SUM(m.QuantityBase)
          FROM inventory.StockMovements m
          WHERE m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = N'CNT' AND m.DocumentId = @Id AND m.IsReversal = 0
            AND m.DocumentNumber = @Tag
          GROUP BY m.ItemId, m.WarehouseId) x
    INNER JOIN inventory.Items i ON i.Id = x.ItemId
    INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
    WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
    ORDER BY i.ItemCode;
    IF @Msg IS NOT NULL THROW 69015, @Msg, 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, IsReversal, CreatedBy)
        SELECT SYSUTCDATETIME(), m.ItemId, m.WarehouseId, m.BranchId, -m.QuantityBase, m.UnitCostBase,
               m.DocumentFamily, m.DocumentTypeCode, m.DocumentId, m.DocumentLineId, m.DocumentNumber, m.ReasonCode, m.ExpiryDate, 1, @UserId
        FROM inventory.StockMovements m
        WHERE m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = N'CNT' AND m.DocumentId = @Id AND m.IsReversal = 0
          AND m.DocumentNumber = @Tag;

        -- the invoice lines of the container were received only by this offload
        UPDATE pl SET ReceivedQuantityBase = 0
        FROM purchase.PurchaseDocumentLines pl
        INNER JOIN logistics.ContainerLines cl ON cl.Id = pl.ContainerLineId
        WHERE cl.ContainerId = @Id;

        DECLARE @Items TABLE (ItemId INT PRIMARY KEY);
        INSERT INTO @Items (ItemId) SELECT DISTINCT ItemId FROM logistics.ContainerLines WHERE ContainerId = @Id;

        UPDATE logistics.ContainerLines
        SET ReceivedQuantityBase = NULL, VarianceReason = NULL, FobCostBase = NULL, LandedCostBase = NULL
        WHERE ContainerId = @Id;

        UPDATE logistics.ContainerCharges SET AppliedAtOffload = 0 WHERE ContainerId = @Id;
        EXEC logistics.usp_Container_ReallocateCharges @Id;

        UPDATE logistics.Containers
        SET OffloadedDate = NULL, OffloadedAtUtc = NULL, OffloadedBy = NULL,
            StatusNote = LEFT(N'Offload reversed: ' + @Reason, 200), UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        EXEC logistics.usp_Container_RefreshStatus @Id;

        DECLARE @ItemId INT;
        DECLARE citems CURSOR LOCAL FAST_FORWARD FOR SELECT ItemId FROM @Items;
        OPEN citems;
        FETCH NEXT FROM citems INTO @ItemId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC inventory.usp_Item_RebuildCosts @ItemId;
            FETCH NEXT FROM citems INTO @ItemId;
        END
        CLOSE citems;
        DEALLOCATE citems;

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId) VALUES (@Id, N'OffloadCancelled', @Reason, @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 16. Purchase documents re-created for the container model

   Save        + @LineContainers (invoice from containers), receipt mode automatic (2 with containers, 1 without),
                 returns of imported goods carry the container landed cost; the value basis of the container charges follows.
   Post        imported invoice: exporter reference required (65018), every line on a container line within what is
                 loaded (65019), no invoice charges (65020).
   Cancel      an order loaded into containers cannot be cancelled (65021); an invoice whose container is offloaded neither.
   Delete      nothing to clean on the containers any more.
   Get         lines: container of the line, loaded / transit per order line, container charges share and estimated landed
                 cost per invoice line; set 6 adds the container charges (kind CNT, read-only) with the share of this invoice;
                 set 7 = containers of the order / invoice.
   CreateFromSource  refused for an order shipped in containers (65021): use CreateFromContainers.
   SetCharges / LandedCostAdjustment_Save  refused on an imported invoice (65020 / 67012).
   Close       an order whose containers are not fully invoiced cannot be closed (65021).
   ================================================================== */

-- Re-created (27): invoice from containers (@LineContainers), automatic receipt mode, landed cost of imported returns.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Save
    @Id                  INT            = NULL,
    @DocumentTypeCode    NVARCHAR(20),
    @DocumentDate        DATE,
    @ExpectedDate        DATE           = NULL,
    @BranchId            INT,
    @WarehouseId         INT,
    @SupplierId          INT,
    @CurrencyId          INT            = NULL,
    @RateType            TINYINT        = 1,
    @ExchangeRate        DECIMAL(18,6)  = NULL,
    @SupplierReference   NVARCHAR(100)  = NULL,
    @Notes               NVARCHAR(1000) = NULL,
    @Lines               purchase.tvp_PurchaseDocumentLine READONLY,
    @MaxDiscountPercent  DECIMAL(9,4)   = 100,
    @SourceDocumentId    INT            = NULL,
    @RowVersion          BINARY(8)      = NULL,
    @UserId              INT            = NULL,
    @ReceiptMode         TINYINT        = NULL,    -- NULL = unchanged (1 on creation)
    @ExporterReference   NVARCHAR(50)   = NULL,
    @CommercialInvoiceNo NVARCHAR(50)   = NULL,
    @LineContainers      purchase.tvp_LineContainer READONLY,   -- invoice from containers: the container line of every line
    @NewId               INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @SupplierReference = NULLIF(LTRIM(RTRIM(@SupplierReference)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    SET @ExporterReference = NULLIF(LTRIM(RTRIM(@ExporterReference)), N'');
    SET @CommercialInvoiceNo = NULLIF(LTRIM(RTRIM(@CommercialInvoiceNo)), N'');
    IF @ReceiptMode IS NOT NULL AND @ReceiptMode NOT IN (1, 2) THROW 65000, 'Receipt mode must be 1 (on posting) or 2 (on container offload).', 1;
    IF @ReceiptMode = 2 AND @DocumentTypeCode <> N'PINV' THROW 65000, 'Only purchase invoices can be received on container offload.', 1;

    DECLARE @TypeId INT, @Direction SMALLINT, @Cur INT, @Rate DECIMAL(18,6);
    EXEC purchase.usp_PurchaseDocument_ValidateInput @DocumentTypeCode, @DocumentDate, @ExpectedDate, @BranchId, @WarehouseId, @SupplierId,
         @CurrencyId, @RateType, @ExchangeRate, @MaxDiscountPercent, @SourceDocumentId, @Lines,
         @TypeId OUTPUT, @Direction OUTPUT, @Cur OUTPUT, @Rate OUTPUT;

    IF @Id IS NOT NULL
    BEGIN
        DECLARE @Status TINYINT = (SELECT Status FROM purchase.PurchaseDocuments WHERE Id = @Id);
        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @Status <> 1 THROW 65005, 'Only draft documents can be edited.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND DocumentTypeId <> @TypeId)
            THROW 65000, 'The document type cannot be changed.', 1;
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND ISNULL(SourceDocumentId, 0) <> ISNULL(@SourceDocumentId, 0))
            THROW 65000, 'The source document cannot be changed.', 1;
        IF NOT EXISTS (SELECT 1 FROM @LineContainers)
           AND EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND ContainerLineId IS NOT NULL)
            THROW 65019, 'This invoice comes from containers: every line must keep its container line.', 1;
    END

    -- Invoice from containers (imports): every line points to a container line of the same order line and item, within
    -- what is loaded and not yet invoiced elsewhere. Receipt mode is automatic: 2 with containers, 1 without.
    IF EXISTS (SELECT 1 FROM @LineContainers)
    BEGIN
        IF @DocumentTypeCode <> N'PINV' THROW 65019, 'Only purchase invoices can be linked to containers.', 1;
        IF @SourceDocumentId IS NULL THROW 65019, 'An invoice from containers must refer to its purchase order.', 1;
        IF EXISTS (SELECT 1 FROM @Lines l WHERE NOT EXISTS (SELECT 1 FROM @LineContainers x WHERE x.LineNumber = l.LineNumber))
           OR EXISTS (SELECT 1 FROM @LineContainers x WHERE NOT EXISTS (SELECT 1 FROM @Lines l WHERE l.LineNumber = x.LineNumber))
            THROW 65019, 'Every line of an invoice from containers must come from a container line.', 1;
        IF @Id IS NOT NULL AND EXISTS (SELECT 1 FROM purchase.PurchaseCharges WHERE DocumentKind = N'PINV' AND DocumentId = @Id)
            THROW 65020, 'This invoice has its own charges. Remove them: the charges of an import are entered on its containers.', 1;

        DECLARE @CtMsg NVARCHAR(400);
        SELECT TOP (1) @CtMsg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' +
            CASE WHEN cl.Id IS NULL THEN N'the container line no longer exists.'
                 WHEN c.Status IN (6, 7, 8) THEN N'container ' + c.ContainerRef + N' is already offloaded, closed or cancelled.'
                 WHEN cl.PurchaseOrderId <> @SourceDocumentId THEN N'the container line belongs to another purchase order.'
                 WHEN cl.ItemId <> l.ItemId THEN N'the item differs from the container line.'
                 ELSE N'the order line differs from the container line.' END
        FROM @Lines l
        INNER JOIN @LineContainers x          ON x.LineNumber = l.LineNumber
        LEFT  JOIN logistics.ContainerLines cl ON cl.Id = x.ContainerLineId
        LEFT  JOIN logistics.Containers c      ON c.Id = cl.ContainerId
        WHERE cl.Id IS NULL OR c.Status IN (6, 7, 8) OR cl.PurchaseOrderId <> @SourceDocumentId
           OR cl.ItemId <> l.ItemId OR ISNULL(l.SourceLineId, 0) <> cl.PoLineId
        ORDER BY l.LineNumber;
        IF @CtMsg IS NOT NULL THROW 65019, @CtMsg, 1;

        SELECT TOP (1) @CtMsg = N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                                + CAST(q.Here AS NVARCHAR(20)) + N' invoiced here + ' + CAST(ISNULL(o.Other, 0) AS NVARCHAR(20))
                                + N' in other invoices, but only ' + CAST(cl.QuantityBase AS NVARCHAR(20)) + N' are loaded.'
        FROM (SELECT x.ContainerLineId, Here = SUM(l.Quantity * iu.PackingFormula)
              FROM @Lines l
              INNER JOIN @LineContainers x      ON x.LineNumber = l.LineNumber
              INNER JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId
              GROUP BY x.ContainerLineId) q
        INNER JOIN logistics.ContainerLines cl ON cl.Id = q.ContainerLineId
        INNER JOIN logistics.Containers c      ON c.Id = cl.ContainerId
        INNER JOIN inventory.Items i           ON i.Id = cl.ItemId
        OUTER APPLY (SELECT Other = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                     INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                     WHERE pil.ContainerLineId = cl.Id AND pd.Status <> 3 AND (@Id IS NULL OR pd.Id <> @Id)) o
        WHERE q.Here + ISNULL(o.Other, 0) > cl.QuantityBase
        ORDER BY c.ContainerRef, cl.LineNumber;
        IF @CtMsg IS NOT NULL THROW 65019, @CtMsg, 1;

        SET @ReceiptMode = 2;
    END
    ELSE IF @DocumentTypeCode = N'PINV'
        SET @ReceiptMode = 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Id IS NULL
        BEGIN
            DECLARE @Number NVARCHAR(30) = NULL;
            IF EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Id = @TypeId AND NumberOnPost = 0)
                EXEC inventory.usp_DocumentType_NextNumber @DocumentTypeCode, @Number OUTPUT, @BranchId;

            INSERT INTO purchase.PurchaseDocuments (DocumentTypeId, DocumentNumber, DocumentDate, ExpectedDate, BranchId, WarehouseId, SupplierId,
                                                    CurrencyId, RateType, ExchangeRate, SupplierReference, Notes, Status, SourceDocumentId,
                                                    ReceiptMode, ExporterReference, CommercialInvoiceNo, CreatedBy)
            VALUES (@TypeId, @Number, @DocumentDate, @ExpectedDate, @BranchId, @WarehouseId, @SupplierId,
                    @Cur, @RateType, @Rate, @SupplierReference, @Notes, 1, @SourceDocumentId,
                    ISNULL(@ReceiptMode, 1), @ExporterReference, @CommercialInvoiceNo, @UserId);
            SET @Id = SCOPE_IDENTITY();

            INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Created', ISNULL(N'Draft ' + @Number, N'Draft (number assigned on posting)')
                        + ISNULL(N' from ' + (SELECT DocumentNumber FROM purchase.PurchaseDocuments WHERE Id = @SourceDocumentId), N''), @UserId);
        END
        ELSE
        BEGIN
            UPDATE purchase.PurchaseDocuments
            SET DocumentDate = @DocumentDate, ExpectedDate = @ExpectedDate, BranchId = @BranchId, WarehouseId = @WarehouseId,
                SupplierId = @SupplierId, CurrencyId = @Cur, RateType = @RateType, ExchangeRate = @Rate,
                SupplierReference = @SupplierReference, Notes = @Notes,
                ReceiptMode = ISNULL(@ReceiptMode, ReceiptMode),
                ExporterReference = @ExporterReference, CommercialInvoiceNo = @CommercialInvoiceNo,
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;

            -- Lines are replaced: manual charge allocations pointing at the old lines are dropped (the charges stay).
            DELETE a FROM purchase.PurchaseChargeAllocations a
            INNER JOIN purchase.PurchaseCharges c ON c.Id = a.ChargeId
            WHERE c.DocumentKind = N'PINV' AND c.DocumentId = @Id;
            DELETE FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id;

            INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Updated', N'Header and ' + CAST((SELECT COUNT(*) FROM @Lines) AS NVARCHAR(10)) + N' line(s) saved', @UserId);
        END

        INSERT INTO purchase.PurchaseDocumentLines (DocumentId, LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, PackingFormula,
                                                    UnitPrice, DiscountPercent, UnitCostBase, FobCostBase, ImportRowNumber, Notes, SourceLineId)
        SELECT @Id, l.LineNumber, l.ItemId, l.ItemUnitId, @WarehouseId, l.ExpiryDate, l.Quantity, iu.PackingFormula,
               ISNULL(l.UnitPrice, ROUND(ISNULL(i.LastCost, 0) * iu.PackingFormula * @Rate, 4)),
               ISNULL(l.DiscountPercent, 0),
               CASE WHEN @DocumentTypeCode = N'PRET' THEN COALESCE(scl.LandedCostBase, src.UnitCostBase) END,   -- returns carry the LANDED cost (the container's for imports)
               CASE WHEN @DocumentTypeCode = N'PRET' THEN COALESCE(scl.FobCostBase, src.FobCostBase) END,
               l.ImportRowNumber, NULLIF(LTRIM(RTRIM(l.Notes)), N''), l.SourceLineId
        FROM @Lines l
        INNER JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        LEFT  JOIN purchase.PurchaseDocumentLines src ON src.Id = l.SourceLineId
        LEFT  JOIN logistics.ContainerLines scl       ON scl.Id = src.ContainerLineId;

        UPDATE pl SET ContainerLineId = x.ContainerLineId
        FROM purchase.PurchaseDocumentLines pl
        INNER JOIN @LineContainers x ON x.LineNumber = pl.LineNumber
        WHERE pl.DocumentId = @Id;

        UPDATE d
        SET TotalItems = x.Items, TotalQuantity = x.Qty, Subtotal = x.Sub, TotalAmount = x.Amt, TotalDiscount = x.Sub - x.Amt,
            TotalAmountBase = ROUND(x.Amt / @Rate, 2), TotalLandedCostBase = ROUND(x.Amt / @Rate, 2) + d.TotalChargesBase
        FROM purchase.PurchaseDocuments d
        CROSS APPLY (SELECT COUNT(*) AS Items, ISNULL(SUM(QuantityBase), 0) AS Qty,
                            ISNULL(SUM(CONVERT(DECIMAL(18,2), Quantity * UnitPrice)), 0) AS Sub, ISNULL(SUM(LineTotal), 0) AS Amt
                     FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id) x
        WHERE d.Id = @Id;

        -- the value basis of the container charges follows the invoice prices
        IF EXISTS (SELECT 1 FROM @LineContainers)
        BEGIN
            DECLARE @Cid INT;
            DECLARE cts CURSOR LOCAL FAST_FORWARD FOR
                SELECT DISTINCT cl.ContainerId FROM @LineContainers x INNER JOIN logistics.ContainerLines cl ON cl.Id = x.ContainerLineId;
            OPEN cts;
            FETCH NEXT FROM cts INTO @Cid;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC logistics.usp_Container_ReallocateCharges @Cid, 1, 1;
                FETCH NEXT FROM cts INTO @Cid;
            END
            CLOSE cts;
            DEALLOCATE cts;
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

-- Re-created (27): an imported invoice (from containers) needs the exporter reference, stays within what is loaded and
-- has no charges of its own. Purchase orders are posted only by their approval (@FromApproval = 1).
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

        DECLARE @FromContainers BIT = CASE WHEN @TypeCode = N'PINV' AND EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines
                                                                                WHERE DocumentId = @Id AND ContainerLineId IS NOT NULL) THEN 1 ELSE 0 END;
        IF @FromContainers = 1
        BEGIN
            IF NULLIF(LTRIM(RTRIM((SELECT ExporterReference FROM purchase.PurchaseDocuments WHERE Id = @Id))), N'') IS NULL
                THROW 65018, 'The exporter reference is required on an imported invoice. Enter it before posting.', 1;
            IF EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND ContainerLineId IS NULL)
                THROW 65019, 'Every line of an invoice from containers must come from a container line.', 1;
            IF EXISTS (SELECT 1 FROM purchase.PurchaseCharges WHERE DocumentKind = N'PINV' AND DocumentId = @Id)
                THROW 65020, 'This invoice has its own charges. Remove them: the charges of an import are entered on its containers.', 1;

            DECLARE @CtMsg NVARCHAR(400);
            SELECT TOP (1) @CtMsg = N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                                    + CASE WHEN c.Status IN (6, 7, 8) THEN N'the container is already offloaded, closed or cancelled.'
                                           ELSE CAST(q.Here AS NVARCHAR(20)) + N' invoiced here + ' + CAST(ISNULL(o.Posted, 0) AS NVARCHAR(20))
                                                + N' in posted invoices, but only ' + CAST(cl.QuantityBase AS NVARCHAR(20)) + N' are loaded.' END
            FROM (SELECT ContainerLineId, Here = SUM(QuantityBase) FROM purchase.PurchaseDocumentLines
                  WHERE DocumentId = @Id GROUP BY ContainerLineId) q
            INNER JOIN logistics.ContainerLines cl ON cl.Id = q.ContainerLineId
            INNER JOIN logistics.Containers c      ON c.Id = cl.ContainerId
            INNER JOIN inventory.Items i           ON i.Id = cl.ItemId
            OUTER APPLY (SELECT Posted = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                         INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                         WHERE pil.ContainerLineId = cl.Id AND pd.Status IN (2, 4) AND pd.Id <> @Id) o
            WHERE c.Status IN (6, 7, 8) OR q.Here + ISNULL(o.Posted, 0) > cl.QuantityBase
            ORDER BY c.ContainerRef, cl.LineNumber;
            IF @CtMsg IS NOT NULL THROW 65019, @CtMsg, 1;
        END

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

        -- containers of an import: the invoice is known now (value basis of the charges, history)
        IF @FromContainers = 1
        BEGIN
            DECLARE @Cid INT;
            DECLARE cts CURSOR LOCAL FAST_FORWARD FOR
                SELECT DISTINCT cl.ContainerId FROM purchase.PurchaseDocumentLines l
                INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
                WHERE l.DocumentId = @Id;
            OPEN cts;
            FETCH NEXT FROM cts INTO @Cid;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC logistics.usp_Container_ReallocateCharges @Cid, 1, 1;
                INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
                VALUES (@Cid, N'Updated', N'Purchase invoice ' + @Number + N' posted', @UserId);
                FETCH NEXT FROM cts INTO @Cid;
            END
            CLOSE cts;
            DEALLOCATE cts;
        END

        COMMIT TRANSACTION;
        IF ISNULL(@FromApproval, 0) = 0 SELECT @Number AS DocumentNumber;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Re-created (27): an order loaded into containers cannot be cancelled; an invoice whose container is offloaded neither.
-- A cancelled invoice releases its own received quantities and its container lines.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Cancel
    @Id         INT,
    @Reason     NVARCHAR(300),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 65000, 'A cancellation reason is required.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Direction SMALLINT, @SourceId INT, @Number NVARCHAR(30), @ReceiptMode TINYINT;
        SELECT @Status = d.Status, @TypeCode = dt.Code, @Direction = dt.StockDirection, @SourceId = d.SourceDocumentId,
               @Number = d.DocumentNumber, @ReceiptMode = d.ReceiptMode
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @Status NOT IN (2, 4) THROW 65010, 'Only posted documents can be cancelled (delete drafts instead).', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE SourceDocumentId = @Id AND Status IN (2, 4))
            THROW 65011, 'This document cannot be cancelled: posted documents were created from it. Cancel those first.', 1;
        IF EXISTS (SELECT 1 FROM purchase.LandedCostAdjustments WHERE SourceInvoiceId = @Id AND Status = 2)
            THROW 65011, 'This invoice cannot be cancelled: posted landed cost adjustments refer to it. Cancel those first.', 1;

        DECLARE @Ct NVARCHAR(400);
        IF @TypeCode = N'PO' AND EXISTS (SELECT 1 FROM logistics.ContainerLines cl INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                                         WHERE cl.PurchaseOrderId = @Id AND c.Status <> 8)
            THROW 65021, 'This purchase order is loaded into containers. Cancel those containers (or remove its lines from them) first.', 1;
        SELECT TOP (1) @Ct = N'This invoice cannot be cancelled: container ' + c.ContainerRef + N' was already offloaded with it. Reverse the offload first.'
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
        INNER JOIN logistics.Containers c      ON c.Id = cl.ContainerId
        WHERE l.DocumentId = @Id AND c.Status IN (6, 7)
        ORDER BY c.ContainerRef;
        IF @Ct IS NOT NULL THROW 69012, @Ct, 1;

        DECLARE @Msg NVARCHAR(400);
        IF @Direction = 1 AND @ReceiptMode = 1
        BEGIN
            SELECT TOP (1) @Msg = N'Cannot cancel: ' + i.ItemCode + N' in ' + w.WarehouseCode + N' has only '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N' left, but this document added ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 65007, @Msg, 1;
        END

        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, IsReversal, CreatedBy)
        SELECT SYSUTCDATETIME(), m.ItemId, m.WarehouseId, m.BranchId, -m.QuantityBase, m.UnitCostBase,
               m.DocumentFamily, m.DocumentTypeCode, m.DocumentId, m.DocumentLineId, m.DocumentNumber, m.ReasonCode, m.ExpiryDate, 1, @UserId
        FROM inventory.StockMovements m
        WHERE m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = @TypeCode AND m.DocumentId = @Id AND m.IsReversal = 0;

        IF @TypeCode = N'PINV'
            UPDATE purchase.PurchaseDocumentLines SET ReceivedQuantityBase = 0 WHERE DocumentId = @Id;

        IF @SourceId IS NOT NULL AND @TypeCode = N'PINV'
        BEGIN
            UPDATE s SET ReceivedQuantityBase = s.ReceivedQuantityBase - x.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;

            IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @SourceId AND Status = 4 AND CloseReason = N'Fully received')
            BEGIN
                UPDATE purchase.PurchaseDocuments SET Status = 2, ClosedAtUtc = NULL, ClosedBy = NULL, CloseReason = NULL WHERE Id = @SourceId;
                INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@SourceId, N'Updated', N'Re-opened: ' + @Number + N' was cancelled', @UserId);
            END
        END
        IF @SourceId IS NOT NULL AND @TypeCode = N'PRET'
        BEGIN
            UPDATE s SET ReturnedQuantityBase = s.ReturnedQuantityBase - x.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;
        END

        UPDATE purchase.PurchaseDocuments
        SET Status = 3, CancelledAtUtc = SYSUTCDATETIME(), CancelledBy = @UserId, CancelReason = @Reason,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@Id, N'Cancelled', @Reason, @UserId);

        -- A cancelled receipt / return changes the cost history: replay the ledger for the items concerned.
        IF @Direction <> 0
        BEGIN
            DECLARE @ItemId INT;
            DECLARE items CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT ItemId FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id;
            OPEN items; FETCH NEXT FROM items INTO @ItemId;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC inventory.usp_Item_RebuildCosts @ItemId;
                FETCH NEXT FROM items INTO @ItemId;
            END
            CLOSE items; DEALLOCATE items;
        END

        -- containers of an import: the value basis of their charges changed
        DECLARE @Cid INT;
        DECLARE cts CURSOR LOCAL FAST_FORWARD FOR
            SELECT DISTINCT cl.ContainerId FROM purchase.PurchaseDocumentLines l
            INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
            WHERE l.DocumentId = @Id;
        OPEN cts;
        FETCH NEXT FROM cts INTO @Cid;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC logistics.usp_Container_ReallocateCharges @Cid, 1, 1;
            INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
            VALUES (@Cid, N'Updated', LEFT(N'Purchase invoice ' + ISNULL(@Number, N'') + N' cancelled: ' + @Reason, 500), @UserId);
            FETCH NEXT FROM cts INTO @Cid;
        END
        CLOSE cts;
        DEALLOCATE cts;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Re-created (27): a deleted draft simply leaves its container lines; the containers' charge basis follows;
-- the approval requests of a draft order are deleted with it.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Delete
    @Id     INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT = (SELECT Status FROM purchase.PurchaseDocuments WHERE Id = @Id);
    IF @Status IS NULL THROW 65006, 'Document not found.', 1;
    IF @Status <> 1 THROW 65005, 'Only draft documents can be deleted. Posted documents must be cancelled.', 1;

    DECLARE @Containers TABLE (ContainerId INT PRIMARY KEY);
    INSERT INTO @Containers (ContainerId)
    SELECT DISTINCT cl.ContainerId FROM purchase.PurchaseDocumentLines l
    INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
    WHERE l.DocumentId = @Id;

    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE a FROM purchase.PurchaseChargeAllocations a INNER JOIN purchase.PurchaseCharges c ON c.Id = a.ChargeId WHERE c.DocumentKind = N'PINV' AND c.DocumentId = @Id;
        DELETE FROM purchase.PurchaseCharges WHERE DocumentKind = N'PINV' AND DocumentId = @Id;
        DELETE FROM purchase.PurchaseDocumentFiles WHERE DocumentId = @Id;
        DELETE FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id;
        DELETE FROM purchase.PurchaseOrderApprovals WHERE DocumentId = @Id;
        DELETE FROM purchase.PurchaseDocumentAudit WHERE DocumentId = @Id;
        DELETE FROM purchase.PurchaseDocuments WHERE Id = @Id;

        DECLARE @Cid INT;
        DECLARE cts CURSOR LOCAL FAST_FORWARD FOR SELECT ContainerId FROM @Containers;
        OPEN cts;
        FETCH NEXT FROM cts INTO @Cid;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC logistics.usp_Container_ReallocateCharges @Cid, 1, 1;
            FETCH NEXT FROM cts INTO @Cid;
        END
        CLOSE cts;
        DEALLOCATE cts;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Re-created (27): containers of the order / invoice, container charges on the invoice (read-only), 8 result sets.
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
           IsContainerBound = CAST(CASE WHEN EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines x
                                                    WHERE x.DocumentId = d.Id AND x.ContainerLineId IS NOT NULL) THEN 1 ELSE 0 END AS BIT),
           ContainerCount = CASE WHEN dt.Code = N'PO'
                                 THEN (SELECT COUNT(DISTINCT cl.ContainerId) FROM logistics.ContainerLines cl
                                       INNER JOIN logistics.Containers c9 ON c9.Id = cl.ContainerId
                                       WHERE cl.PurchaseOrderId = d.Id AND c9.Status <> 8)
                                 ELSE (SELECT COUNT(DISTINCT cl.ContainerId) FROM purchase.PurchaseDocumentLines x
                                       INNER JOIN logistics.ContainerLines cl ON cl.Id = x.ContainerLineId
                                       WHERE x.DocumentId = d.Id) END,
           LoadedBase = CASE WHEN dt.Code = N'PO'
                             THEN ISNULL((SELECT SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                                          INNER JOIN logistics.Containers c9 ON c9.Id = cl.ContainerId
                                          WHERE cl.PurchaseOrderId = d.Id AND c9.Status <> 8), 0) END,
           ContainerChargesBase = cch.Share,
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
    OUTER APPLY (SELECT Share = SUM(a.AmountBase * CAST(x.QuantityBase AS DECIMAL(18,6)) / NULLIF(cl.QuantityBase, 0))
                 FROM purchase.PurchaseDocumentLines x
                 INNER JOIN logistics.ContainerLines cl            ON cl.Id = x.ContainerLineId
                 INNER JOIN logistics.ContainerChargeAllocations a ON a.ContainerLineId = cl.Id
                 INNER JOIN logistics.ContainerCharges ch          ON ch.Id = a.ChargeId AND ch.Status = 2 AND ch.IncludeInLandedCost = 1
                 WHERE x.DocumentId = d.Id) cch
    WHERE d.Id = @Id;

    SELECT l.Id, l.DocumentId, l.LineNumber, l.ItemId, i.ItemCode, i.ItemName,
           l.ItemUnitId, ut.UnitTypeName, iu.SkuCode, iu.Barcode, l.PackingFormula,
           l.WarehouseId, w.WarehouseCode, w.WarehouseName, l.ExpiryDate,
           l.Quantity, l.QuantityBase, l.UnitPrice, l.DiscountPercent, l.LineDiscount, l.LineTotal,
           l.UnitCostBase, LandedCostBase = l.UnitCostBase, l.FobCostBase, l.AllocatedChargesBase,
           l.ReceivedQuantityBase, l.ReturnedQuantityBase, l.ShippedQuantityBase,
           AllocatedToContainersBase = CASE WHEN dt.Code = N'PO' THEN ISNULL(ct.Allocated, 0)
                                            WHEN l.ContainerLineId IS NOT NULL THEN l.QuantityBase ELSE 0 END,
           TransitBase = CASE WHEN dt.Code = N'PO' THEN ISNULL(ct.Transit, 0)
                              WHEN lct.Status IN (3, 4, 5) THEN l.QuantityBase ELSE 0 END,
           RemainingBase = CASE WHEN dt.Code = N'PO' THEN l.QuantityBase - l.ReceivedQuantityBase
                                WHEN dt.Code = N'PINV' THEN l.QuantityBase - l.ReturnedQuantityBase END,
           AvailableForContainerBase = CASE WHEN dt.Code = N'PO' THEN l.QuantityBase - ISNULL(ct.Allocated, 0) - ISNULL(dir.Qty, 0) END,
           InvoicedDirectBase = CASE WHEN dt.Code = N'PO' THEN ISNULL(dir.Qty, 0) END,
           l.ContainerLineId, ContainerId = lcl.ContainerId, ContainerRef = lct.ContainerRef, ContainerNo = lct.ContainerNo,
           ContainerStatus = lct.Status,
           ContainerChargesBase = CASE WHEN l.ContainerLineId IS NOT NULL THEN ISNULL(lch.Share, 0) END,
           EstimatedLandedCostBase = CASE WHEN l.ContainerLineId IS NOT NULL
                                          THEN COALESCE(lcl.LandedCostBase,
                                                        ISNULL(l.FobCostBase, l.LineTotal / NULLIF(d.ExchangeRate, 0) / NULLIF(l.QuantityBase, 0))
                                                        + ISNULL(lch.Share, 0) / NULLIF(l.QuantityBase, 0)) END,
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
                 WHERE cl.PoLineId = l.Id AND c.Status <> 8) ct
    OUTER APPLY (SELECT Qty = SUM(x.QuantityBase) FROM purchase.PurchaseDocumentLines x
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
                 WHERE x.SourceLineId = l.Id AND x.ContainerLineId IS NULL AND xd.Status IN (1, 2, 4) AND dt.Code = N'PO') dir
    LEFT  JOIN logistics.ContainerLines lcl ON lcl.Id = l.ContainerLineId
    LEFT  JOIN logistics.Containers lct     ON lct.Id = lcl.ContainerId
    OUTER APPLY (SELECT Charges = SUM(a.AmountBase)
                 FROM logistics.ContainerChargeAllocations a
                 INNER JOIN logistics.ContainerCharges ch ON ch.Id = a.ChargeId AND ch.Status = 2 AND ch.IncludeInLandedCost = 1
                 WHERE a.ContainerLineId = l.ContainerLineId) lcc
    OUTER APPLY (SELECT Share = lcc.Charges * CAST(l.QuantityBase AS DECIMAL(18,6)) / NULLIF(lcl.QuantityBase, 0)) lch
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

    -- 6: charges of the invoice (kind PINV), of its landed cost adjustments (kind LCA) and, for an import, the charges of
    --    its containers (kind CNT, read-only: DocumentId = container, AdjustmentStatus = charge status) with ShareBase =
    --    the part that falls on this invoice's lines.
    SELECT c.Id, c.DocumentKind, c.DocumentId, SourceNumber = CASE WHEN c.DocumentKind = N'LCA' THEN lca.DocumentNumber ELSE d.DocumentNumber END,
           c.LineNumber, c.ChargeTypeId, ct.ChargeCode, ct.ChargeName, c.Description, c.ProviderPartyId, pp.PartyName AS ProviderName, c.Reference,
           c.CurrencyId, cur.CurrencyCode, c.RateType, c.ExchangeRate, c.Amount, c.AmountBase, c.AllocationMethod, c.IncludeInLandedCost, c.IncludedInSupplierInvoice, c.Notes,
           AllocatedBase = (SELECT SUM(AmountBase) FROM purchase.PurchaseChargeAllocations x WHERE x.ChargeId = c.Id),
           AdjustmentStatus = lca.Status,
           ContainerId = CAST(NULL AS INT), ContainerRef = CAST(NULL AS NVARCHAR(30)), ChargeDate = CAST(NULL AS DATE),
           ChargeStatus = CAST(NULL AS TINYINT), ShareBase = CAST(NULL AS DECIMAL(18,2))
    FROM purchase.PurchaseCharges c
    INNER JOIN purchase.ChargeTypes ct ON ct.Id = c.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = c.CurrencyId
    LEFT  JOIN masterdata.Parties pp ON pp.Id = c.ProviderPartyId
    LEFT  JOIN purchase.PurchaseDocuments d ON d.Id = c.DocumentId AND c.DocumentKind = N'PINV'
    LEFT  JOIN purchase.LandedCostAdjustments lca ON lca.Id = c.DocumentId AND c.DocumentKind = N'LCA'
    WHERE (c.DocumentKind = N'PINV' AND c.DocumentId = @Id)
       OR (c.DocumentKind = N'LCA' AND lca.SourceInvoiceId = @Id)
    UNION ALL
    SELECT ch.Id, N'CNT', ch.ContainerId, cn.ContainerRef,
           CAST(ROW_NUMBER() OVER (ORDER BY cn.ContainerRef, ch.ChargeDate, ch.Id) AS INT),
           ch.ChargeTypeId, t.ChargeCode, t.ChargeName, ch.Description, ch.ProviderPartyId, pp.PartyName, ch.Reference,
           ch.CurrencyId, cur.CurrencyCode, ch.RateType, ch.ExchangeRate, ch.Amount, ch.AmountBase, ch.AllocationMethod, ch.IncludeInLandedCost,
           CAST(0 AS BIT), ch.Notes,
           ISNULL(s.Share, 0), ch.Status,
           ch.ContainerId, cn.ContainerRef, ch.ChargeDate, ch.Status, CAST(ISNULL(s.Share, 0) AS DECIMAL(18,2))
    FROM logistics.ContainerCharges ch
    INNER JOIN logistics.Containers cn   ON cn.Id = ch.ContainerId
    INNER JOIN purchase.ChargeTypes t    ON t.Id = ch.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = ch.CurrencyId
    LEFT  JOIN masterdata.Parties pp     ON pp.Id = ch.ProviderPartyId
    OUTER APPLY (SELECT Share = SUM(a.AmountBase * CAST(l.QuantityBase AS DECIMAL(18,6)) / NULLIF(cl.QuantityBase, 0))
                 FROM purchase.PurchaseDocumentLines l
                 INNER JOIN logistics.ContainerLines cl            ON cl.Id = l.ContainerLineId
                 INNER JOIN logistics.ContainerChargeAllocations a ON a.ContainerLineId = cl.Id AND a.ChargeId = ch.Id
                 WHERE l.DocumentId = @Id) s
    WHERE ch.Status IN (1, 2)
      AND EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines l
                  INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
                  WHERE l.DocumentId = @Id AND cl.ContainerId = ch.ContainerId)
    ORDER BY 2, 3, 5;

    -- 7: containers of the document: for an order the containers carrying its lines, for an invoice its containers.
    SELECT ct.Id, ct.ContainerRef, ct.ContainerNo, ct.Status, ct.DispatchDate, ct.Eta, ct.OffloadedDate,
           ct.CurrentLocation, w.WarehouseCode, w.WarehouseName,
           AllocatedBase = ISNULL(x.Allocated, 0), ReceivedBase = ISNULL(x.Received, 0), InvoicedBase = ISNULL(x.Invoiced, 0),
           ct.ContainerTypeId, ctt.TypeCode AS ContainerTypeCode, ct.PurchaseOrderId
    FROM logistics.Containers ct
    INNER JOIN masterdata.ContainerTypes ctt ON ctt.Id = ct.ContainerTypeId
    LEFT  JOIN masterdata.Warehouses w       ON w.Id = ct.WarehouseId
    CROSS APPLY (SELECT Allocated = SUM(q.Allocated), Received = SUM(q.Received), Invoiced = SUM(q.Invoiced)
                 FROM (SELECT Allocated = cl.QuantityBase, Received = ISNULL(cl.ReceivedQuantityBase, 0),
                              Invoiced = ISNULL((SELECT SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                                                 INNER JOIN purchase.PurchaseDocuments pid ON pid.Id = pil.DocumentId
                                                 WHERE pil.ContainerLineId = cl.Id AND pid.Status IN (2, 4)), 0)
                       FROM logistics.ContainerLines cl
                       WHERE cl.ContainerId = ct.Id AND cl.PurchaseOrderId = @Id
                       UNION ALL
                       SELECT l.QuantityBase, l.ReceivedQuantityBase, l.QuantityBase
                       FROM purchase.PurchaseDocumentLines l
                       INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
                       WHERE l.DocumentId = @Id AND cl.ContainerId = ct.Id) q) x
    WHERE ct.Status <> 8
      AND (EXISTS (SELECT 1 FROM logistics.ContainerLines cl WHERE cl.ContainerId = ct.Id AND cl.PurchaseOrderId = @Id)
           OR EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines l
                      INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
                      WHERE l.DocumentId = @Id AND cl.ContainerId = ct.Id))
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

-- Re-created (27): an order shipped in containers is invoiced from its containers (65021).
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
    IF @SrcType = N'PO' AND EXISTS (SELECT 1 FROM logistics.ContainerLines cl INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                                    WHERE cl.PurchaseOrderId = @SourceId AND c.Status <> 8)
        THROW 65021, 'This purchase order is shipped in containers: create its invoices from the containers.', 1;

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


-- Draft purchase invoice from container lines of ONE purchase order. @Selection = container lines + base quantities;
-- empty = everything of this order that is loaded and not yet invoiced (containers not offloaded).
-- Lines: the order line's unit and price (base unit when the quantity is not a whole number of it), SourceLineId = order line,
-- ContainerLineId = container line, receipt mode 2 (the stock enters at the container offload).
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_CreateFromContainers
    @PurchaseOrderId INT,
    @Selection       logistics.tvp_ContainerLineQty READONLY,
    @DocumentDate    DATE = NULL,
    @UserId          INT  = NULL,
    @NewId           INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF @DocumentDate IS NULL SET @DocumentDate = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @TypeCode NVARCHAR(20), @Status TINYINT, @BranchId INT, @WarehouseId INT, @SupplierId INT, @CurrencyId INT,
            @RateType TINYINT, @SupplierRef NVARCHAR(100);
    SELECT @TypeCode = dt.Code, @Status = d.Status, @BranchId = d.BranchId, @WarehouseId = d.WarehouseId, @SupplierId = d.SupplierId,
           @CurrencyId = d.CurrencyId, @RateType = d.RateType, @SupplierRef = d.SupplierReference
    FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    WHERE d.Id = @PurchaseOrderId;

    IF @TypeCode IS NULL THROW 65006, 'Purchase order not found.', 1;
    IF @TypeCode <> N'PO' THROW 65011, 'Invoices from containers are created for a purchase order.', 1;
    IF @Status <> 2 THROW 65011, 'The purchase order must be approved and still open.', 1;

    DECLARE @Pick TABLE (ContainerLineId INT PRIMARY KEY, QuantityBase INT);
    IF EXISTS (SELECT 1 FROM @Selection)
        INSERT INTO @Pick (ContainerLineId, QuantityBase) SELECT ContainerLineId, QuantityBase FROM @Selection;
    ELSE
        INSERT INTO @Pick (ContainerLineId, QuantityBase)
        SELECT cl.Id, cl.QuantityBase - ISNULL(q.Qty, 0)
        FROM logistics.ContainerLines cl
        INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
        OUTER APPLY (SELECT Qty = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                     INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                     WHERE pil.ContainerLineId = cl.Id AND pd.Status <> 3) q
        WHERE cl.PurchaseOrderId = @PurchaseOrderId AND c.Status NOT IN (6, 7, 8) AND cl.QuantityBase - ISNULL(q.Qty, 0) > 0;

    IF NOT EXISTS (SELECT 1 FROM @Pick) THROW 65019, 'Nothing is left to invoice on the containers of this order.', 1;

    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg =
        CASE WHEN cl.Id IS NULL THEN N'A selected container line no longer exists.'
             WHEN cl.PurchaseOrderId <> @PurchaseOrderId THEN N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N' belongs to another purchase order.'
             WHEN c.Status IN (6, 7, 8) THEN N'Container ' + c.ContainerRef + N' is already offloaded, closed or cancelled.'
             WHEN p.QuantityBase <= 0 THEN N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N': the quantity must be greater than zero.'
             ELSE N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N': ' + CAST(p.QuantityBase AS NVARCHAR(20))
                  + N' selected but only ' + CAST(cl.QuantityBase - ISNULL(q.Qty, 0) AS NVARCHAR(20)) + N' are loaded and not yet invoiced.' END
    FROM @Pick p
    LEFT JOIN logistics.ContainerLines cl ON cl.Id = p.ContainerLineId
    LEFT JOIN logistics.Containers c      ON c.Id = cl.ContainerId
    OUTER APPLY (SELECT Qty = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                 INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                 WHERE pil.ContainerLineId = cl.Id AND pd.Status <> 3) q
    WHERE cl.Id IS NULL OR cl.PurchaseOrderId <> @PurchaseOrderId OR c.Status IN (6, 7, 8) OR p.QuantityBase <= 0
       OR p.QuantityBase > cl.QuantityBase - ISNULL(q.Qty, 0)
    ORDER BY c.ContainerRef, cl.LineNumber;
    IF @Msg IS NOT NULL THROW 65019, @Msg, 1;

    -- the order line must still allow it (posted invoices + drafts)
    SELECT TOP (1) @Msg = N'Order line ' + CAST(pol.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): ' + CAST(x.Qty AS NVARCHAR(20))
                          + N' selected but only ' + CAST(pol.QuantityBase - pol.ReceivedQuantityBase - ISNULL(dr.Qty, 0) AS NVARCHAR(20))
                          + N' remain to invoice (the rest is in posted or draft invoices).'
    FROM (SELECT cl.PoLineId, Qty = SUM(p.QuantityBase) FROM @Pick p
          INNER JOIN logistics.ContainerLines cl ON cl.Id = p.ContainerLineId GROUP BY cl.PoLineId) x
    INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = x.PoLineId
    INNER JOIN inventory.Items i                  ON i.Id = pol.ItemId
    OUTER APPLY (SELECT Qty = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                 INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                 WHERE pil.SourceLineId = pol.Id AND pd.Status = 1) dr
    WHERE x.Qty > pol.QuantityBase - pol.ReceivedQuantityBase - ISNULL(dr.Qty, 0)
    ORDER BY pol.LineNumber;
    IF @Msg IS NOT NULL THROW 65011, @Msg, 1;

    DECLARE @Rows TABLE (LineNumber INT PRIMARY KEY, ContainerLineId INT, PoLineId INT, QuantityBase INT);
    INSERT INTO @Rows (LineNumber, ContainerLineId, PoLineId, QuantityBase)
    SELECT ROW_NUMBER() OVER (ORDER BY c.ContainerRef, cl.LineNumber), cl.Id, cl.PoLineId, p.QuantityBase
    FROM @Pick p
    INNER JOIN logistics.ContainerLines cl ON cl.Id = p.ContainerLineId
    INNER JOIN logistics.Containers c      ON c.Id = cl.ContainerId;

    DECLARE @Lines purchase.tvp_PurchaseDocumentLine;
    INSERT INTO @Lines (LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, UnitPrice, DiscountPercent, ImportRowNumber, Notes, SourceLineId)
    SELECT r.LineNumber, pol.ItemId, u.ItemUnitId, @WarehouseId, pol.ExpiryDate, u.Quantity, u.UnitPrice, pol.DiscountPercent, NULL,
           LEFT(N'Container ' + c.ContainerRef + ISNULL(N' / ' + c.ContainerNo, N''), 300), pol.Id
    FROM @Rows r
    INNER JOIN logistics.ContainerLines cl        ON cl.Id = r.ContainerLineId
    INNER JOIN logistics.Containers c             ON c.Id = cl.ContainerId
    INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = r.PoLineId
    CROSS APPLY (SELECT ItemUnitId = CASE WHEN r.QuantityBase % pol.PackingFormula = 0 THEN pol.ItemUnitId
                                          ELSE (SELECT TOP (1) Id FROM inventory.ItemUnits WHERE ItemId = pol.ItemId AND IsBaseUnit = 1) END,
                        Quantity   = CASE WHEN r.QuantityBase % pol.PackingFormula = 0 THEN r.QuantityBase / pol.PackingFormula ELSE r.QuantityBase END,
                        UnitPrice  = CASE WHEN r.QuantityBase % pol.PackingFormula = 0 THEN pol.UnitPrice ELSE ROUND(pol.UnitPrice / pol.PackingFormula, 4) END) u;

    DECLARE @LineContainers purchase.tvp_LineContainer;
    INSERT INTO @LineContainers (LineNumber, ContainerLineId) SELECT LineNumber, ContainerLineId FROM @Rows;

    EXEC purchase.usp_PurchaseDocument_Save
         @Id = NULL, @DocumentTypeCode = N'PINV', @DocumentDate = @DocumentDate, @ExpectedDate = NULL,
         @BranchId = @BranchId, @WarehouseId = @WarehouseId, @SupplierId = @SupplierId, @CurrencyId = @CurrencyId,
         @RateType = @RateType, @ExchangeRate = NULL, @SupplierReference = @SupplierRef, @Notes = NULL,
         @Lines = @Lines, @MaxDiscountPercent = 100, @SourceDocumentId = @PurchaseOrderId, @RowVersion = NULL, @UserId = @UserId,
         @ReceiptMode = 2, @LineContainers = @LineContainers, @NewId = @NewId OUTPUT;

    INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
    SELECT DISTINCT cl.ContainerId, N'Updated',
           N'Draft purchase invoice ' + ISNULL((SELECT DocumentNumber FROM purchase.PurchaseDocuments WHERE Id = @NewId), N'#' + CAST(@NewId AS NVARCHAR(10)))
           + N' created from the container', @UserId
    FROM @Rows r INNER JOIN logistics.ContainerLines cl ON cl.Id = r.ContainerLineId;
END
GO

-- Re-created (27): charges of a DRAFT local purchase invoice; an imported invoice has its charges on its containers.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_SetCharges
    @DocumentId        INT,
    @Charges           purchase.tvp_PurchaseCharge READONLY,
    @ManualAllocations purchase.tvp_ManualAllocation READONLY,
    @RowVersion        BINARY(8) = NULL,
    @UserId            INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Date DATE, @CurrencyId INT;
    SELECT @Status = d.Status, @TypeCode = dt.Code, @Date = d.DocumentDate, @CurrencyId = d.CurrencyId
    FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId WHERE d.Id = @DocumentId;
    IF @Status IS NULL THROW 65006, 'Document not found.', 1;
    IF @TypeCode <> N'PINV' THROW 65010, 'Charges are entered on purchase invoices only (use a Landed Cost Adjustment after posting).', 1;
    IF @Status <> 1 THROW 65005, 'Charges can only be changed on a draft invoice.', 1;
    IF EXISTS (SELECT 1 FROM @Charges)
       AND EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines WHERE DocumentId = @DocumentId AND ContainerLineId IS NOT NULL)
        THROW 65020, 'This invoice comes from containers: its charges are entered on the containers (Container Charges).', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @DocumentId AND RowVersion = @RowVersion)
        THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        EXEC purchase.usp_PurchaseCharges_Write N'PINV', @DocumentId, @Date, @CurrencyId, @DocumentId, @Charges, @ManualAllocations, @UserId;
        UPDATE purchase.PurchaseDocuments SET UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @DocumentId;
        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@DocumentId, N'Updated', N'Charges saved: ' + CAST((SELECT COUNT(*) FROM @Charges) AS NVARCHAR(10)) + N' line(s)', @UserId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Re-created (27): no landed cost adjustment on an imported invoice (late charges go to its containers).
CREATE OR ALTER PROCEDURE purchase.usp_LandedCostAdjustment_Save
    @Id                INT            = NULL,
    @SourceInvoiceId   INT,
    @DocumentDate      DATE,
    @Notes             NVARCHAR(1000) = NULL,
    @Charges           purchase.tvp_PurchaseCharge READONLY,
    @ManualAllocations purchase.tvp_ManualAllocation READONLY,
    @RowVersion        BINARY(8)      = NULL,
    @UserId            INT            = NULL,
    @NewId             INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    IF @DocumentDate IS NULL THROW 67000, 'Date is required.', 1;
    IF @DocumentDate > CAST(SYSUTCDATETIME() AS DATE) THROW 67000, 'Date cannot be in the future.', 1;

    DECLARE @InvStatus TINYINT, @InvType NVARCHAR(20), @BranchId INT, @BaseCurrency INT = (SELECT TOP (1) Id FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1);
    SELECT @InvStatus = d.Status, @InvType = dt.Code, @BranchId = d.BranchId
    FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId WHERE d.Id = @SourceInvoiceId;
    IF @InvStatus IS NULL THROW 67011, 'Purchase invoice not found.', 1;
    IF @InvType <> N'PINV' OR @InvStatus <> 2 THROW 67011, 'Landed cost adjustments apply to POSTED purchase invoices only.', 1;
    IF EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines WHERE DocumentId = @SourceInvoiceId AND ContainerLineId IS NOT NULL)
        THROW 67012, 'This invoice comes from containers: late charges are entered on the containers (Container Charges), not as a landed cost adjustment.', 1;
    IF NOT EXISTS (SELECT 1 FROM @Charges) THROW 67000, 'At least one charge is required.', 1;

    IF @Id IS NOT NULL
    BEGIN
        DECLARE @Status TINYINT = (SELECT Status FROM purchase.LandedCostAdjustments WHERE Id = @Id);
        IF @Status IS NULL THROW 67006, 'Adjustment not found.', 1;
        IF @Status <> 1 THROW 67005, 'Only draft adjustments can be edited.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.LandedCostAdjustments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 67004, 'This adjustment was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM purchase.LandedCostAdjustments WHERE Id = @Id AND SourceInvoiceId <> @SourceInvoiceId)
            THROW 67000, 'The invoice of an adjustment cannot be changed.', 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;
        IF @Id IS NULL
        BEGIN
            DECLARE @Number NVARCHAR(30), @TypeId INT = (SELECT Id FROM inventory.DocumentTypes WHERE Code = N'LCA');
            EXEC inventory.usp_DocumentType_NextNumber N'LCA', @Number OUTPUT, @BranchId;
            INSERT INTO purchase.LandedCostAdjustments (DocumentTypeId, DocumentNumber, DocumentDate, BranchId, SourceInvoiceId, Notes, Status, CreatedBy)
            VALUES (@TypeId, @Number, @DocumentDate, @BranchId, @SourceInvoiceId, @Notes, 1, @UserId);
            SET @Id = SCOPE_IDENTITY();
        END
        ELSE
            UPDATE purchase.LandedCostAdjustments SET DocumentDate = @DocumentDate, Notes = @Notes, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;

        EXEC purchase.usp_PurchaseCharges_Write N'LCA', @Id, @DocumentDate, @BaseCurrency, @SourceInvoiceId, @Charges, @ManualAllocations, @UserId;

        UPDATE a SET TotalChargesBase = ISNULL((SELECT SUM(AmountBase) FROM purchase.PurchaseCharges WHERE DocumentKind = N'LCA' AND DocumentId = @Id AND IncludeInLandedCost = 1), 0)
        FROM purchase.LandedCostAdjustments a WHERE a.Id = @Id;

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Re-created (27): purchase orders only; an order whose containers are not fully invoiced cannot be closed.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Close
    @Id         INT,
    @Reason     NVARCHAR(300) = NULL,
    @RowVersion BINARY(8)     = NULL,
    @UserId     INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Status TINYINT, @TypeCode NVARCHAR(20);
    SELECT @Status = d.Status, @TypeCode = dt.Code FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId WHERE d.Id = @Id;
    IF @Status IS NULL THROW 65006, 'Document not found.', 1;
    IF @TypeCode <> N'PO' THROW 65010, 'Only purchase orders can be closed.', 1;
    IF @Status <> 2 THROW 65010, 'Only open (posted) purchase orders can be closed.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;

    DECLARE @Ct NVARCHAR(400);
    SELECT TOP (1) @Ct = N'Container ' + c.ContainerRef + N' carries lines of this order that are not fully invoiced. Invoice them (or remove the lines) before closing the order.'
    FROM logistics.ContainerLines cl
    INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
    OUTER APPLY (SELECT Q = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                 INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                 WHERE pil.ContainerLineId = cl.Id AND pd.Status IN (2, 4)) q
    WHERE cl.PurchaseOrderId = @Id AND c.Status NOT IN (6, 7, 8) AND ISNULL(q.Q, 0) < cl.QuantityBase
    ORDER BY c.ContainerRef;
    IF @Ct IS NOT NULL THROW 65021, @Ct, 1;

    UPDATE purchase.PurchaseDocuments
    SET Status = 4, ClosedAtUtc = SYSUTCDATETIME(), ClosedBy = @UserId, CloseReason = ISNULL(NULLIF(LTRIM(RTRIM(@Reason)), N''), N'Closed manually'),
        UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
    INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@Id, N'Closed', ISNULL(@Reason, N'Closed manually'), @UserId);
END
GO

-- Re-created (27): the usage count includes the container charges.
CREATE OR ALTER PROCEDURE purchase.usp_ChargeType_Search
    @Search              NVARCHAR(100) = NULL,   -- code or name (contains)
    @AllocationMethod    NVARCHAR(10)  = NULL,
    @IncludeInLandedCost BIT           = NULL,   -- "Cost impact" filter
    @IsActive            BIT           = NULL,
    @SortColumn          NVARCHAR(30)  = N'ChargeCode',
    @SortDirection       NVARCHAR(4)   = N'ASC',
    @PageNumber          INT           = 1,
    @PageSize            INT           = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'ChargeCode', N'ChargeName', N'AllocationMethod', N'IsActive', N'CreatedAtUtc') SET @SortColumn = N'ChargeCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT c.Id, c.ChargeCode, c.ChargeName, c.AllocationMethod, c.IncludeInLandedCost, c.IsRecoverableTax, c.Description, c.IsActive,
           UsageCount = (SELECT COUNT(*) FROM purchase.PurchaseCharges pc WHERE pc.ChargeTypeId = c.Id)
                      + (SELECT COUNT(*) FROM logistics.ContainerCharges cc WHERE cc.ChargeTypeId = c.Id),
           c.CreatedAtUtc, c.UpdatedAtUtc, c.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM purchase.ChargeTypes c
    WHERE (@Search IS NULL OR c.ChargeCode LIKE N'%' + @Search + N'%' OR c.ChargeName LIKE N'%' + @Search + N'%')
      AND (@AllocationMethod IS NULL OR c.AllocationMethod = @AllocationMethod)
      AND (@IncludeInLandedCost IS NULL OR c.IncludeInLandedCost = @IncludeInLandedCost)
      AND (@IsActive IS NULL OR c.IsActive = @IsActive)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'ChargeCode' THEN c.ChargeCode WHEN N'ChargeName' THEN c.ChargeName WHEN N'AllocationMethod' THEN c.AllocationMethod END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'ChargeCode' THEN c.ChargeCode WHEN N'ChargeName' THEN c.ChargeName WHEN N'AllocationMethod' THEN c.AllocationMethod END END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(c.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(c.IsActive AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN c.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN c.CreatedAtUtc END DESC,
        c.ChargeCode
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

/* ================================================================== 17. Costs, shortage plans */

-- Re-created (27): replays the ledger (documents without reversal, matched by family + TYPE + id) + inventory cost
-- adjustments in date order -> exact moving average; LastCost / FobCost / last supplier from the latest RECEIPT:
-- a local invoice received at posting or a container offload (landed cost of the container line).
-- @ItemId NULL = every item (maintenance).
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
        SELECT m.ItemId, EventDate = m.MovementDate, Src = 1, SrcId = m.Id, Qty = m.QuantityBase, Cost = m.UnitCostBase, Amount = CAST(NULL AS DECIMAL(18,2))
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
                 FROM (SELECT Landed = l.UnitCostBase, Fob = l.FobCostBase, d.SupplierId, ReceivedAtUtc = d.PostedAtUtc, Tie = l.Id
                       FROM purchase.PurchaseDocumentLines l
                       INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
                       INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                       WHERE dt.Code = N'PINV' AND d.Status = 2 AND d.ReceiptMode = 1 AND l.ItemId = i.Id
                       UNION ALL
                       SELECT cl.LandedCostBase, cl.FobCostBase, po.SupplierId, c.OffloadedAtUtc, cl.Id
                       FROM logistics.ContainerLines cl
                       INNER JOIN logistics.Containers c        ON c.Id = cl.ContainerId
                       INNER JOIN purchase.PurchaseDocuments po ON po.Id = cl.PurchaseOrderId
                       WHERE c.Status IN (6, 7) AND cl.ItemId = i.Id AND cl.ReceivedQuantityBase > 0) r
                 ORDER BY r.ReceivedAtUtc DESC, r.Tie DESC) x
    WHERE (@ItemId IS NULL OR i.Id = @ItemId);
END
GO

-- Re-created (27): transit = container lines (from order lines) not offloaded; an imported invoice stops being
-- "pending" once its container is offloaded (short-shipped quantities do not stay expected forever).
CREATE OR ALTER FUNCTION inventory.fn_Shortage_Live (@WarehouseId INT, @MonthsOfHistory INT)
RETURNS TABLE
AS
RETURN
(
    SELECT i.Id AS ItemId, i.ItemCode, i.ItemName, i.BrandId, i.ItemFamilyId, i.IsBivac,
           i.DefaultSupplierId, i.LastSupplierId, i.MinQuantity, i.MaxQuantity, i.LastCost, i.AverageCost, i.LeadTimeDays,
           ItemPcPerContainer = cnt.PackingFormula,                         -- the item's Container unit, NULL when none
           PcPerContainerFromUnit = CAST(CASE WHEN cnt.PackingFormula IS NOT NULL THEN 1 ELSE 0 END AS BIT),
           CurrentInventoryBase     = inventory.fn_StockOnHand(i.Id, @WarehouseId),
           TransitBase              = ISNULL(tr.Transit, 0),
           OutstandingOrderBase     = CASE WHEN ISNULL(po.PoOpen, 0) + ISNULL(po.InvPending, 0) - ISNULL(tr.Transit, 0) > 0
                                           THEN ISNULL(po.PoOpen, 0) + ISNULL(po.InvPending, 0) - ISNULL(tr.Transit, 0) ELSE 0 END,
           ExpectedMonthlySalesBase = CONVERT(DECIMAL(18,2), CAST(ISNULL(s.Sold, 0) AS DECIMAL(18,4)) / NULLIF(@MonthsOfHistory, 0)),
           SoldInPeriodBase         = ISNULL(s.Sold, 0),
           PurchaseItemUnitId       = pu.ItemUnitId,
           PurchaseUnitName         = pu.UnitTypeName,
           PurchasePackingFormula   = pu.PackingFormula
    FROM inventory.Items i
    OUTER APPLY
    (
        -- open purchase orders + invoices whose goods are still travelling
        SELECT PoOpen     = SUM(CASE WHEN dt.Code = N'PO'   THEN l.QuantityBase - l.ReceivedQuantityBase ELSE 0 END),
               InvPending = SUM(CASE WHEN dt.Code = N'PINV' THEN l.QuantityBase - l.ReceivedQuantityBase ELSE 0 END)
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
        INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId
        WHERE l.ItemId = i.Id AND l.WarehouseId = @WarehouseId AND l.QuantityBase > l.ReceivedQuantityBase
          AND ((dt.Code = N'PO'   AND d.Status = 2)
            OR (dt.Code = N'PINV' AND d.Status = 2 AND d.ReceiptMode = 2
                AND NOT EXISTS (SELECT 1 FROM logistics.ContainerLines xcl INNER JOIN logistics.Containers xc ON xc.Id = xcl.ContainerId
                                WHERE xcl.Id = l.ContainerLineId AND xc.Status IN (6, 7))))
    ) po
    OUTER APPLY
    (
        -- loaded into a container that has left the supplier and is not offloaded yet
        SELECT Transit = SUM(cl.QuantityBase - ISNULL(cl.ReceivedQuantityBase, 0))
        FROM logistics.ContainerLines cl
        INNER JOIN logistics.Containers c             ON c.Id = cl.ContainerId
        INNER JOIN purchase.PurchaseDocumentLines pl  ON pl.Id = cl.PoLineId
        WHERE cl.ItemId = i.Id AND c.Status IN (3, 4, 5)
          AND pl.WarehouseId = @WarehouseId                  -- the order's warehouse, like the open order / invoice quantities
          AND cl.QuantityBase > ISNULL(cl.ReceivedQuantityBase, 0)
    ) tr
    OUTER APPLY
    (
        SELECT Sold = SUM(-m.QuantityBase)
        FROM inventory.StockMovements m
        WHERE m.ItemId = i.Id AND m.WarehouseId = @WarehouseId AND m.DocumentFamily = N'Sales'
          AND m.MovementDate >= DATEADD(MONTH, -@MonthsOfHistory, CAST(SYSUTCDATETIME() AS DATE))
    ) s
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

/* ================================================================== 18. Procedures of the old model (script 24 re-creates them at every start-up) */

IF OBJECT_ID(N'logistics.usp_Container_AvailableInvoices', N'P') IS NOT NULL DROP PROCEDURE logistics.usp_Container_AvailableInvoices;
IF OBJECT_ID(N'logistics.usp_Container_AddEvent', N'P') IS NOT NULL DROP PROCEDURE logistics.usp_Container_AddEvent;
IF OBJECT_ID(N'logistics.usp_ContainerFile_Add', N'P') IS NOT NULL DROP PROCEDURE logistics.usp_ContainerFile_Add;
IF OBJECT_ID(N'logistics.usp_ContainerFile_Get', N'P') IS NOT NULL DROP PROCEDURE logistics.usp_ContainerFile_Get;
IF OBJECT_ID(N'logistics.usp_ContainerFile_Delete', N'P') IS NOT NULL DROP PROCEDURE logistics.usp_ContainerFile_Delete;
GO

/* ================================================================== 19. Permissions */

MERGE security.Permissions AS target
USING
(
    VALUES
        (N'containers.movements.manage',    N'Manage Shipment Movements',  N'Containers',  N'Plan, start, complete and cancel movements of containers.',          1410),
        (N'containers.charges.view',        N'View Container Charges',     N'Containers',  N'See the charges of containers and how they are divided over the items.', 1420),
        (N'containers.charges.create',      N'Create Container Charges',   N'Containers',  N'Enter, edit and delete draft charges on containers.',                 1430),
        (N'containers.charges.post',        N'Post Container Charges',     N'Containers',  N'Post container charges: they enter the cost of the items.',          1440),
        (N'containers.charges.cancel',      N'Cancel Container Charges',   N'Containers',  N'Cancel posted container charges (the item costs are adjusted back).', 1450),
        (N'containers.attachments.manage',  N'Manage Container Documents', N'Containers',  N'Add and remove documents on containers and movements.',              1460),
        (N'masterdata.movementtypes.manage', N'Manage movement types',     N'Master Data', N'Define the movement types and the stage each one represents.',         1470)
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
WHERE p.Code IN (N'containers.movements.manage', N'containers.charges.view', N'containers.charges.create', N'containers.charges.post',
                 N'containers.charges.cancel', N'containers.attachments.manage', N'masterdata.movementtypes.manage')
  AND (r.IsSystem = 1
       OR (r.Name = N'Manager' AND p.Code IN (N'containers.movements.manage', N'containers.charges.view', N'containers.charges.create',
                                              N'containers.attachments.manage')))
  AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);
GO

/* ================================================================== 20. Check */

SELECT TypeCode, TypeName, Stage, SortOrder FROM masterdata.MovementTypes ORDER BY SortOrder;
SELECT Code, Name, Family, NumberPrefix, NumberLength, YearInNumber, NumberPerBranch FROM inventory.DocumentTypes WHERE Code IN (N'CNT', N'MOV');
SELECT Code, Name, Module, SortOrder FROM security.Permissions WHERE SortOrder BETWEEN 1410 AND 1470 ORDER BY SortOrder;
SELECT NewColumns = COUNT(*) FROM sys.columns
WHERE (object_id = OBJECT_ID(N'logistics.ContainerLines') AND name IN (N'PurchaseOrderId', N'PoLineId', N'FobCostBase', N'ChargesBase', N'LandedCostBase'))
   OR (object_id = OBJECT_ID(N'purchase.PurchaseDocumentLines') AND name = N'ContainerLineId')
   OR (object_id = OBJECT_ID(N'logistics.Containers') AND name = N'PurchaseOrderId');     -- expected 7
SELECT LogisticsProcedures = COUNT(*) FROM sys.procedures WHERE SCHEMA_NAME(schema_id) = N'logistics';

-- Imported invoices of the old model left without container (test data): cancel them from the purchase invoice page.
SELECT d.Id, d.DocumentNumber, d.DocumentDate, NotReceivedBase = SUM(l.QuantityBase - l.ReceivedQuantityBase)
FROM purchase.PurchaseDocuments d
INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
INNER JOIN purchase.PurchaseDocumentLines l ON l.DocumentId = d.Id
WHERE dt.Code = N'PINV' AND d.Status = 2 AND d.ReceiptMode = 2 AND l.ContainerLineId IS NULL AND l.QuantityBase > l.ReceivedQuantityBase
GROUP BY d.Id, d.DocumentNumber, d.DocumentDate
ORDER BY d.DocumentDate;

PRINT 'Script 27 applied: containers from purchase orders, invoices from containers, movements, container charges, attachments.';
GO

SET NOEXEC OFF;
GO
