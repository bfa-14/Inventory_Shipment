/* =====================================================================================
   Inventory_Shipment - 24: CONTAINERS (schema logistics) - import shipment tracking

   A container is the shipment document between the purchase invoice and the warehouse:
     Draft -> Confirmed -> In Transit -> At Port -> Cleared -> Offloaded -> Closed   (or Cancelled)
   Statuses 3..5 are DERIVED from the dates/events, 6 comes from the offload, 7 and 8 are explicit.

   Decisions taken with the customer:
     1. Imported stock is received when the CONTAINER IS OFFLOADED, not when the purchase invoice is
        posted -> purchase.PurchaseDocuments.ReceiptMode (1 = on posting, 2 = on container offload).
        A PINV with ReceiptMode 2 still computes FOB / charges / landed cost at posting, but writes no
        stock movements; logistics.usp_Container_Offload writes them (at the invoice landed cost).
     2. Capacity = a number of units (base units) per CONTAINER TYPE, copied to the container and editable there.
     3. Over capacity is a WARNING with override (@AllowOverCapacity), never a hard block.
     4. One container may carry invoices of SEVERAL suppliers; the supplier is derived, never a header field.
     5. Oil is INFORMATION ONLY (inventory.Items.OilQtyPerUnit, copied to the container line), never stock.
     6. Added: a received quantity per line at offload with a short-shipment reason, and a cancel-offload
        that reverses the movements and replays the costs (inventory.usp_Item_RebuildCosts).
   Note: the freight forwarder and the transporter are ordinary supplier parties (masterdata.Parties,
   IsSupplier = 1), like the charge providers of script 23 - no new party flags.

   Shortage plans keep working across the change: inventory.fn_Shortage_Live is re-created so that
     Outstanding = open PO remaining + posted PINV (ReceiptMode 2) not yet received - Transit
     Transit     = quantity on containers In Transit / At Port / Cleared, not yet received
   so a quantity never disappears when a purchase order becomes an invoice. ShippedQuantityBase and
   purchase.usp_PurchaseDocument_MarkShipped stay in the database but are no longer used.

   Objects:
     masterdata.ContainerTypes / Ports / AttachmentTypes (+ Search/Get/Lookup/Save/SetActive/Delete)
     inventory.Items + OilQtyPerUnit (usp_Item_SetPurchasing / usp_Item_Get re-created)
     inventory.DocumentTypes: family CHECK extended with 'Logistics'; type CNT (KTG-2026-0001)
     purchase.PurchaseDocuments + ReceiptMode, ExporterReference, CommercialInvoiceNo
       (usp_PurchaseDocument_Save / _Post / _Cancel / _Delete / _Get re-created)
     logistics.Containers / ContainerInvoices / ContainerLines / ContainerEvents / ContainerFiles / ContainerAudit
     logistics.tvp_ContainerInvoice / tvp_ContainerLine / tvp_ContainerReceipt
     logistics.usp_Container_Search / _Get / _Save / _AddEvent / _Confirm / _Offload / _CancelOffload /
               _Close / _Cancel / _Delete / _AvailableInvoices / _RefreshStatus + file procedures
     inventory.fn_Shortage_Live re-created
   Errors 69xxx: 69000 validation, 69004 concurrency, 69005 not editable, 69006 not found,
                 69007 over capacity, 69008 allocation above the invoice line, 69009 no lines,
                 69010 invalid status, 69011 already offloaded, 69012 invoice in use,
                 69013 duplicate container number, 69014 master data in use,
                 69015 not enough stock to reverse an offload.
   Permissions (module Containers): containers.view 1300 / create 1310 / confirm 1320 / offload 1330 /
                 cancel 1340 / close 1350 / delete 1360 / overcapacity 1370;
                 masterdata.containertypes.manage 1380 / ports.manage 1390 / attachmenttypes.manage 1400.

   Requires scripts 19-23. Idempotent.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'purchase.PurchaseDocuments', N'U') IS NULL
   OR OBJECT_ID(N'inventory.ShortageDocuments', N'U') IS NULL
   OR OBJECT_ID(N'purchase.ChargeTypes', N'U') IS NULL
BEGIN
    RAISERROR ('Run scripts 19 to 23 before this script.', 16, 1);
    RETURN;
END
GO

IF SCHEMA_ID(N'logistics') IS NULL
    EXEC (N'CREATE SCHEMA [logistics] AUTHORIZATION [dbo];');
GO

/* ================================================================== 1. Master data: container types */

IF OBJECT_ID(N'masterdata.ContainerTypes', N'U') IS NULL
BEGIN
    CREATE TABLE masterdata.ContainerTypes
    (
        Id           INT IDENTITY(1,1) NOT NULL,
        TypeCode     NVARCHAR(10)   NOT NULL,
        TypeName     NVARCHAR(100)  NOT NULL,
        MaxUnits     INT            NULL,          -- default capacity in BASE units (pieces)
        MaxWeightKg  DECIMAL(18,3)  NULL,
        MaxVolumeCbm DECIMAL(18,3)  NULL,
        Description  NVARCHAR(500)  NULL,
        IsActive     BIT            NOT NULL CONSTRAINT DF_ContainerTypes_IsActive DEFAULT (1),
        CreatedAtUtc DATETIME2(3)   NOT NULL CONSTRAINT DF_ContainerTypes_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy    INT            NULL,
        UpdatedAtUtc DATETIME2(3)   NULL,
        UpdatedBy    INT            NULL,
        RowVersion   ROWVERSION     NOT NULL,
        CONSTRAINT PK_ContainerTypes PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_ContainerTypes_Code UNIQUE (TypeCode),
        CONSTRAINT CK_ContainerTypes_MaxUnits CHECK (MaxUnits IS NULL OR MaxUnits > 0),
        CONSTRAINT CK_ContainerTypes_Weight CHECK (MaxWeightKg IS NULL OR MaxWeightKg > 0),
        CONSTRAINT CK_ContainerTypes_Volume CHECK (MaxVolumeCbm IS NULL OR MaxVolumeCbm > 0),
        CONSTRAINT FK_ContainerTypes_CreatedBy FOREIGN KEY (CreatedBy) REFERENCES security.Users (Id),
        CONSTRAINT FK_ContainerTypes_UpdatedBy FOREIGN KEY (UpdatedBy) REFERENCES security.Users (Id)
    );
    PRINT 'Created masterdata.ContainerTypes';
END
GO

MERGE masterdata.ContainerTypes AS t
USING (VALUES
    (N'20GP', N'20ft General Purpose',  60,  28000.000,  33.000),
    (N'40GP', N'40ft General Purpose', 100,  26500.000,  67.000),
    (N'40HC', N'40ft High Cube',       120,  26500.000,  76.000),
    (N'45HC', N'45ft High Cube',       135,  27600.000,  86.000)
) AS s (TypeCode, TypeName, MaxUnits, MaxWeightKg, MaxVolumeCbm)
ON t.TypeCode = s.TypeCode
WHEN NOT MATCHED BY TARGET THEN
    INSERT (TypeCode, TypeName, MaxUnits, MaxWeightKg, MaxVolumeCbm)
    VALUES (s.TypeCode, s.TypeName, s.MaxUnits, s.MaxWeightKg, s.MaxVolumeCbm);
GO

CREATE OR ALTER PROCEDURE masterdata.usp_ContainerType_Search
    @Search        NVARCHAR(100) = NULL,
    @IsActive      BIT           = NULL,
    @SortColumn    NVARCHAR(30)  = N'TypeCode',   -- TypeCode | TypeName | MaxUnits | IsActive
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
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'TypeCode', N'TypeName', N'MaxUnits', N'IsActive') SET @SortColumn = N'TypeCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT c.Id, c.TypeCode, c.TypeName, c.MaxUnits, c.MaxWeightKg, c.MaxVolumeCbm, c.Description, c.IsActive,
           UsedCount = (SELECT COUNT(*) FROM logistics.Containers x WHERE x.ContainerTypeId = c.Id),
           c.CreatedAtUtc, c.CreatedBy, c.UpdatedAtUtc, c.UpdatedBy, c.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.ContainerTypes c
    WHERE (@Search IS NULL OR c.TypeCode LIKE N'%' + @Search + N'%' OR c.TypeName LIKE N'%' + @Search + N'%')
      AND (@IsActive IS NULL OR c.IsActive = @IsActive)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'TypeCode' THEN c.TypeCode WHEN N'TypeName' THEN c.TypeName END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'TypeCode' THEN c.TypeCode WHEN N'TypeName' THEN c.TypeName END END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'MaxUnits' THEN c.MaxUnits END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'MaxUnits' THEN c.MaxUnits END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(c.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(c.IsActive AS INT) END DESC,
        c.TypeCode ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_ContainerType_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, TypeCode, TypeName, MaxUnits, MaxWeightKg, MaxVolumeCbm, Description, IsActive,
           CreatedAtUtc, CreatedBy, UpdatedAtUtc, UpdatedBy, RowVersion
    FROM masterdata.ContainerTypes WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_ContainerType_Lookup
    @ActiveOnly BIT = 1,
    @IncludeId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, TypeCode, TypeName, MaxUnits, MaxWeightKg, MaxVolumeCbm, IsActive
    FROM masterdata.ContainerTypes
    WHERE (@ActiveOnly = 0 OR IsActive = 1 OR Id = @IncludeId)
    ORDER BY TypeCode;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_ContainerType_Save
    @Id           INT           = NULL,
    @TypeCode     NVARCHAR(10),
    @TypeName     NVARCHAR(100),
    @MaxUnits     INT           = NULL,
    @MaxWeightKg  DECIMAL(18,3) = NULL,
    @MaxVolumeCbm DECIMAL(18,3) = NULL,
    @Description  NVARCHAR(500) = NULL,
    @IsActive     BIT           = 1,
    @RowVersion   BINARY(8)     = NULL,
    @UserId       INT           = NULL,
    @NewId        INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @TypeCode = UPPER(NULLIF(LTRIM(RTRIM(@TypeCode)), N''));
    SET @TypeName = NULLIF(LTRIM(RTRIM(@TypeName)), N'');
    SET @Description = NULLIF(LTRIM(RTRIM(@Description)), N'');
    IF @TypeCode IS NULL THROW 69000, 'Container type code is required.', 1;
    IF @TypeName IS NULL THROW 69000, 'Container type name is required.', 1;
    IF @MaxUnits IS NOT NULL AND @MaxUnits <= 0 THROW 69000, 'Maximum units must be greater than zero.', 1;
    IF EXISTS (SELECT 1 FROM masterdata.ContainerTypes WHERE TypeCode = @TypeCode AND (@Id IS NULL OR Id <> @Id))
        THROW 69013, 'This container type code already exists.', 1;

    IF @Id IS NULL
    BEGIN
        INSERT INTO masterdata.ContainerTypes (TypeCode, TypeName, MaxUnits, MaxWeightKg, MaxVolumeCbm, Description, IsActive, CreatedBy)
        VALUES (@TypeCode, @TypeName, @MaxUnits, @MaxWeightKg, @MaxVolumeCbm, @Description, ISNULL(@IsActive, 1), @UserId);
        SET @NewId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM masterdata.ContainerTypes WHERE Id = @Id) THROW 69006, 'Container type not found.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.ContainerTypes WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 69004, 'This container type was modified by another user. Reload the page and try again.', 1;
        UPDATE masterdata.ContainerTypes
        SET TypeCode = @TypeCode, TypeName = @TypeName, MaxUnits = @MaxUnits, MaxWeightKg = @MaxWeightKg,
            MaxVolumeCbm = @MaxVolumeCbm, Description = @Description, IsActive = ISNULL(@IsActive, 1),
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;
        SET @NewId = @Id;
    END
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_ContainerType_SetActive
    @Id INT, @IsActive BIT, @RowVersion BINARY(8) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.ContainerTypes WHERE Id = @Id) THROW 69006, 'Container type not found.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.ContainerTypes WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 69004, 'This container type was modified by another user. Reload the page and try again.', 1;
    UPDATE masterdata.ContainerTypes SET IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_ContainerType_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.ContainerTypes WHERE Id = @Id) THROW 69006, 'Container type not found.', 1;
    IF EXISTS (SELECT 1 FROM logistics.Containers WHERE ContainerTypeId = @Id)
        THROW 69014, 'This container type is used by containers and cannot be deleted. Deactivate it instead.', 1;
    DELETE FROM masterdata.ContainerTypes WHERE Id = @Id;
END
GO

/* ================================================================== 2. Master data: ports and places */

IF OBJECT_ID(N'masterdata.Ports', N'U') IS NULL
BEGIN
    CREATE TABLE masterdata.Ports
    (
        Id           INT IDENTITY(1,1) NOT NULL,
        PortCode     NVARCHAR(10)  NOT NULL,
        PortName     NVARCHAR(100) NOT NULL,
        CountryCode  NCHAR(2)      NULL,
        Kind         NVARCHAR(10)  NOT NULL CONSTRAINT DF_Ports_Kind DEFAULT (N'Sea'),   -- Sea | Inland | Border | Air
        IsActive     BIT           NOT NULL CONSTRAINT DF_Ports_IsActive DEFAULT (1),
        CreatedAtUtc DATETIME2(3)  NOT NULL CONSTRAINT DF_Ports_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy    INT           NULL,
        UpdatedAtUtc DATETIME2(3)  NULL,
        UpdatedBy    INT           NULL,
        RowVersion   ROWVERSION    NOT NULL,
        CONSTRAINT PK_Ports PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_Ports_Code UNIQUE (PortCode),
        CONSTRAINT CK_Ports_Kind CHECK (Kind IN (N'Sea', N'Inland', N'Border', N'Air')),
        CONSTRAINT FK_Ports_CreatedBy FOREIGN KEY (CreatedBy) REFERENCES security.Users (Id),
        CONSTRAINT FK_Ports_UpdatedBy FOREIGN KEY (UpdatedBy) REFERENCES security.Users (Id)
    );
    PRINT 'Created masterdata.Ports';
END
GO

MERGE masterdata.Ports AS t
USING (VALUES
    (N'INMAA', N'Chennai',        N'IN', N'Sea'),
    (N'INNSA', N'Nhava Sheva',    N'IN', N'Sea'),
    (N'CNSHA', N'Shanghai',       N'CN', N'Sea'),
    (N'TZDAR', N'Dar es Salaam',  N'TZ', N'Sea'),
    (N'ZADUR', N'Durban',         N'ZA', N'Sea'),
    (N'MZBEW', N'Beira',          N'MZ', N'Sea'),
    (N'ZMKAS', N'Kasumbalesa',    N'ZM', N'Border'),
    (N'CDLUB', N'Lubumbashi',     N'CD', N'Inland'),
    (N'CDKLW', N'Kolwezi',        N'CD', N'Inland')
) AS s (PortCode, PortName, CountryCode, Kind)
ON t.PortCode = s.PortCode
WHEN NOT MATCHED BY TARGET THEN
    INSERT (PortCode, PortName, CountryCode, Kind) VALUES (s.PortCode, s.PortName, s.CountryCode, s.Kind);
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Port_Search
    @Search        NVARCHAR(100) = NULL,
    @Kind          NVARCHAR(10)  = NULL,
    @IsActive      BIT           = NULL,
    @SortColumn    NVARCHAR(30)  = N'PortCode',   -- PortCode | PortName | CountryCode | Kind | IsActive
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
    SET @Kind = NULLIF(LTRIM(RTRIM(@Kind)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'PortCode', N'PortName', N'CountryCode', N'Kind', N'IsActive') SET @SortColumn = N'PortCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT p.Id, p.PortCode, p.PortName, p.CountryCode, p.Kind, p.IsActive,
           p.CreatedAtUtc, p.CreatedBy, p.UpdatedAtUtc, p.UpdatedBy, p.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.Ports p
    WHERE (@Search IS NULL OR p.PortCode LIKE N'%' + @Search + N'%' OR p.PortName LIKE N'%' + @Search + N'%')
      AND (@Kind IS NULL OR p.Kind = @Kind)
      AND (@IsActive IS NULL OR p.IsActive = @IsActive)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'PortCode' THEN p.PortCode WHEN N'PortName' THEN p.PortName
                                                                 WHEN N'CountryCode' THEN p.CountryCode WHEN N'Kind' THEN p.Kind END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'PortCode' THEN p.PortCode WHEN N'PortName' THEN p.PortName
                                                                 WHEN N'CountryCode' THEN p.CountryCode WHEN N'Kind' THEN p.Kind END END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(p.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(p.IsActive AS INT) END DESC,
        p.PortCode ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Port_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, PortCode, PortName, CountryCode, Kind, IsActive, CreatedAtUtc, CreatedBy, UpdatedAtUtc, UpdatedBy, RowVersion
    FROM masterdata.Ports WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Port_Lookup
    @Kind       NVARCHAR(10) = NULL,
    @ActiveOnly BIT          = 1,
    @IncludeId  INT          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Kind = NULLIF(LTRIM(RTRIM(@Kind)), N'');
    SELECT Id, PortCode, PortName, CountryCode, Kind, IsActive
    FROM masterdata.Ports
    WHERE (@ActiveOnly = 0 OR IsActive = 1 OR Id = @IncludeId)
      AND (@Kind IS NULL OR Kind = @Kind OR Id = @IncludeId)
    ORDER BY PortName;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Port_Save
    @Id          INT           = NULL,
    @PortCode    NVARCHAR(10),
    @PortName    NVARCHAR(100),
    @CountryCode NCHAR(2)      = NULL,
    @Kind        NVARCHAR(10)  = N'Sea',
    @IsActive    BIT           = 1,
    @RowVersion  BINARY(8)     = NULL,
    @UserId      INT           = NULL,
    @NewId       INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @PortCode = UPPER(NULLIF(LTRIM(RTRIM(@PortCode)), N''));
    SET @PortName = NULLIF(LTRIM(RTRIM(@PortName)), N'');
    SET @CountryCode = UPPER(NULLIF(LTRIM(RTRIM(@CountryCode)), N''));
    SET @Kind = NULLIF(LTRIM(RTRIM(@Kind)), N'');
    IF @PortCode IS NULL THROW 69000, 'Port code is required.', 1;
    IF @PortName IS NULL THROW 69000, 'Port name is required.', 1;
    IF @Kind IS NULL OR @Kind NOT IN (N'Sea', N'Inland', N'Border', N'Air') THROW 69000, 'Kind must be Sea, Inland, Border or Air.', 1;
    IF EXISTS (SELECT 1 FROM masterdata.Ports WHERE PortCode = @PortCode AND (@Id IS NULL OR Id <> @Id))
        THROW 69013, 'This port code already exists.', 1;

    IF @Id IS NULL
    BEGIN
        INSERT INTO masterdata.Ports (PortCode, PortName, CountryCode, Kind, IsActive, CreatedBy)
        VALUES (@PortCode, @PortName, @CountryCode, @Kind, ISNULL(@IsActive, 1), @UserId);
        SET @NewId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM masterdata.Ports WHERE Id = @Id) THROW 69006, 'Port not found.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Ports WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 69004, 'This port was modified by another user. Reload the page and try again.', 1;
        UPDATE masterdata.Ports
        SET PortCode = @PortCode, PortName = @PortName, CountryCode = @CountryCode, Kind = @Kind,
            IsActive = ISNULL(@IsActive, 1), UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;
        SET @NewId = @Id;
    END
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Port_SetActive
    @Id INT, @IsActive BIT, @RowVersion BINARY(8) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Ports WHERE Id = @Id) THROW 69006, 'Port not found.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Ports WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 69004, 'This port was modified by another user. Reload the page and try again.', 1;
    UPDATE masterdata.Ports SET IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_Port_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Ports WHERE Id = @Id) THROW 69006, 'Port not found.', 1;
    IF EXISTS (SELECT 1 FROM logistics.Containers WHERE PortOfLoadingId = @Id OR PortOfDestinationId = @Id OR FinalDestinationId = @Id)
       OR EXISTS (SELECT 1 FROM logistics.ContainerEvents WHERE PortId = @Id)
        THROW 69014, 'This port is used by containers and cannot be deleted. Deactivate it instead.', 1;
    DELETE FROM masterdata.Ports WHERE Id = @Id;
END
GO

/* ================================================================== 3. Master data: attachment types */

IF OBJECT_ID(N'masterdata.AttachmentTypes', N'U') IS NULL
BEGIN
    CREATE TABLE masterdata.AttachmentTypes
    (
        Id           INT IDENTITY(1,1) NOT NULL,
        Category     NVARCHAR(30)  NOT NULL,    -- Container | Purchase | Shipping | Customs | Transport | Delivery | Other
        SubType      NVARCHAR(60)  NOT NULL,
        IsActive     BIT           NOT NULL CONSTRAINT DF_AttachmentTypes_IsActive DEFAULT (1),
        SortOrder    INT           NOT NULL CONSTRAINT DF_AttachmentTypes_SortOrder DEFAULT (0),
        CreatedAtUtc DATETIME2(3)  NOT NULL CONSTRAINT DF_AttachmentTypes_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy    INT           NULL,
        UpdatedAtUtc DATETIME2(3)  NULL,
        UpdatedBy    INT           NULL,
        RowVersion   ROWVERSION    NOT NULL,
        CONSTRAINT PK_AttachmentTypes PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_AttachmentTypes_Name UNIQUE (Category, SubType),
        CONSTRAINT FK_AttachmentTypes_CreatedBy FOREIGN KEY (CreatedBy) REFERENCES security.Users (Id),
        CONSTRAINT FK_AttachmentTypes_UpdatedBy FOREIGN KEY (UpdatedBy) REFERENCES security.Users (Id)
    );
    PRINT 'Created masterdata.AttachmentTypes';
END
GO

MERGE masterdata.AttachmentTypes AS t
USING (VALUES
    (N'Container', N'Booking Confirmation', 10),
    (N'Container', N'Container Release',    20),
    (N'Purchase',  N'Commercial Invoice',   30),
    (N'Purchase',  N'Packing List',         40),
    (N'Purchase',  N'Proforma Invoice',     50),
    (N'Shipping',  N'Bill of Lading',       60),
    (N'Shipping',  N'Freight Invoice',      70),
    (N'Shipping',  N'Insurance Policy',     80),
    (N'Customs',   N'FERI',                 90),
    (N'Customs',   N'Declaration',         100),
    (N'Customs',   N'Clearing Invoice',    110),
    (N'Transport', N'Waybill',             120),
    (N'Transport', N'Transport Invoice',   130),
    (N'Delivery',  N'Offloading Note',     140),
    (N'Other',     N'Other',               999)
) AS s (Category, SubType, SortOrder)
ON t.Category = s.Category AND t.SubType = s.SubType
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Category, SubType, SortOrder) VALUES (s.Category, s.SubType, s.SortOrder);
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

    SELECT a.Id, a.Category, a.SubType, a.SortOrder, a.IsActive,
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
    SELECT Id, Category, SubType, SortOrder, IsActive, CreatedAtUtc, CreatedBy, UpdatedAtUtc, UpdatedBy, RowVersion
    FROM masterdata.AttachmentTypes WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_AttachmentType_Lookup
    @ActiveOnly BIT = 1,
    @IncludeId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, Category, SubType, DisplayName = Category + N' / ' + SubType, SortOrder, IsActive
    FROM masterdata.AttachmentTypes
    WHERE (@ActiveOnly = 0 OR IsActive = 1 OR Id = @IncludeId)
    ORDER BY SortOrder, Category, SubType;
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
    @NewId      INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Category = NULLIF(LTRIM(RTRIM(@Category)), N'');
    SET @SubType = NULLIF(LTRIM(RTRIM(@SubType)), N'');
    IF @Category IS NULL THROW 69000, 'Category is required.', 1;
    IF @SubType IS NULL THROW 69000, 'Sub type is required.', 1;
    IF EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Category = @Category AND SubType = @SubType AND (@Id IS NULL OR Id <> @Id))
        THROW 69013, 'This category and sub type already exist.', 1;

    IF @Id IS NULL
    BEGIN
        INSERT INTO masterdata.AttachmentTypes (Category, SubType, SortOrder, IsActive, CreatedBy)
        VALUES (@Category, @SubType, ISNULL(@SortOrder, 0), ISNULL(@IsActive, 1), @UserId);
        SET @NewId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Id = @Id) THROW 69006, 'Attachment type not found.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 69004, 'This attachment type was modified by another user. Reload the page and try again.', 1;
        UPDATE masterdata.AttachmentTypes
        SET Category = @Category, SubType = @SubType, SortOrder = ISNULL(@SortOrder, 0), IsActive = ISNULL(@IsActive, 1),
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;
        SET @NewId = @Id;
    END
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_AttachmentType_SetActive
    @Id INT, @IsActive BIT, @RowVersion BINARY(8) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Id = @Id) THROW 69006, 'Attachment type not found.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 69004, 'This attachment type was modified by another user. Reload the page and try again.', 1;
    UPDATE masterdata.AttachmentTypes SET IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE masterdata.usp_AttachmentType_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Id = @Id) THROW 69006, 'Attachment type not found.', 1;
    IF EXISTS (SELECT 1 FROM logistics.ContainerFiles WHERE AttachmentTypeId = @Id)
        THROW 69014, 'This attachment type is used by documents and cannot be deleted. Deactivate it instead.', 1;
    DELETE FROM masterdata.AttachmentTypes WHERE Id = @Id;
END
GO

/* ================================================================== 4. Items: oil per unit (information only) */

IF COL_LENGTH(N'inventory.Items', N'OilQtyPerUnit') IS NULL
BEGIN
    ALTER TABLE inventory.Items ADD OilQtyPerUnit DECIMAL(9,2) NULL
        CONSTRAINT CK_Items_OilQtyPerUnit CHECK (OilQtyPerUnit IS NULL OR OilQtyPerUnit >= 0);
    PRINT 'Items: added OilQtyPerUnit';
END
GO

-- Re-created with @OilQtyPerUnit as a new optional last parameter (litres shipped with one unit, information only).
CREATE OR ALTER PROCEDURE inventory.usp_Item_SetPurchasing
    @Id                INT,
    @DefaultSupplierId INT           = NULL,
    @LeadTimeDays      INT           = NULL,
    @UserId            INT           = NULL,
    @PcPerContainer    INT           = NULL,
    @WeightKg          DECIMAL(18,3) = NULL,
    @VolumeCbm         DECIMAL(18,4) = NULL,
    @OilQtyPerUnit     DECIMAL(9,2)  = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inventory.Items WHERE Id = @Id) THROW 56000, 'Item not found.', 1;
    IF @DefaultSupplierId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @DefaultSupplierId AND IsSupplier = 1 AND IsActive = 1)
        THROW 56000, 'Default supplier not found, inactive, or not flagged as a supplier.', 1;
    IF @LeadTimeDays IS NOT NULL AND @LeadTimeDays < 0 THROW 56000, 'Lead time cannot be negative.', 1;
    IF @PcPerContainer IS NOT NULL AND @PcPerContainer <= 0 THROW 56000, 'PC per container must be greater than zero.', 1;
    IF @WeightKg IS NOT NULL AND @WeightKg < 0 THROW 56000, 'Weight cannot be negative.', 1;
    IF @VolumeCbm IS NOT NULL AND @VolumeCbm < 0 THROW 56000, 'Volume cannot be negative.', 1;
    IF @OilQtyPerUnit IS NOT NULL AND @OilQtyPerUnit < 0 THROW 56000, 'Oil quantity cannot be negative.', 1;

    UPDATE inventory.Items
    SET DefaultSupplierId = @DefaultSupplierId, LeadTimeDays = @LeadTimeDays, PcPerContainer = @PcPerContainer,
        WeightKg = @WeightKg, VolumeCbm = @VolumeCbm, OilQtyPerUnit = @OilQtyPerUnit,
        UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
END
GO

-- Re-created: the header now also returns OilQtyPerUnit.
CREATE OR ALTER PROCEDURE inventory.usp_Item_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT i.Id, i.ItemCode, i.ItemName, i.BrandId, b.BrandName, i.Model,
           i.ItemFamilyId, f.FamilyCode, f.FamilyName, i.CountryOfOrigin,
           i.DefaultWarehouseId, w.WarehouseCode, w.WarehouseName, i.Description,
           i.WarrantyMonths, i.MinQuantity, i.MaxQuantity, i.IsBivac, i.IsActive,
           OnHand = inventory.fn_StockOnHand(i.Id, NULL),
           FobCost = CAST(i.FobCost AS DECIMAL(18,2)),
           LastCost = CAST(i.LastCost AS DECIMAL(18,2)),
           AverageCost = CAST(i.AverageCost AS DECIMAL(18,2)),
           InventoryValue = CAST(inventory.fn_StockOnHand(i.Id, NULL) * i.AverageCost AS DECIMAL(18,2)),
           LastPurchaseCost = CAST(i.FobCost AS DECIMAL(18,2)),      -- kept for the current API mapping (= FOB)
           i.DefaultSupplierId, ds.PartyCode AS DefaultSupplierCode, ds.PartyName AS DefaultSupplierName, i.LeadTimeDays, i.PcPerContainer,
           i.WeightKg, i.VolumeCbm, i.OilQtyPerUnit,
           i.LastSupplierId, ls.PartyName AS LastSupplierName, i.LastPurchaseAtUtc,
           i.CreatedAtUtc, i.CreatedBy, cu.FullName AS CreatedByName,
           i.UpdatedAtUtc, i.UpdatedBy, uu.FullName AS UpdatedByName, i.RowVersion
    FROM inventory.Items i
    INNER JOIN masterdata.Brands b       ON b.Id = i.BrandId
    INNER JOIN masterdata.ItemFamilies f ON f.Id = i.ItemFamilyId
    INNER JOIN masterdata.Warehouses w   ON w.Id = i.DefaultWarehouseId
    LEFT  JOIN masterdata.Parties ds     ON ds.Id = i.DefaultSupplierId
    LEFT  JOIN masterdata.Parties ls     ON ls.Id = i.LastSupplierId
    LEFT  JOIN security.Users cu ON cu.Id = i.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = i.UpdatedBy
    WHERE i.Id = @Id;

    SELECT u.Id, u.ItemId, u.UnitTypeId, ut.UnitTypeName, u.PackingFormula, u.SkuCode, u.Barcode,
           u.IsSalesUnit, u.IsPurchaseUnit, u.IsBaseUnit, u.RowVersion
    FROM inventory.ItemUnits u
    INNER JOIN masterdata.UnitTypes ut ON ut.Id = u.UnitTypeId
    WHERE u.ItemId = @Id
    ORDER BY u.IsBaseUnit DESC, u.PackingFormula, ut.UnitTypeName;

    SELECT fl.Id, fl.ItemId, fl.FileName, fl.ContentType, fl.SizeBytes, fl.IsItemImage, fl.CreatedAtUtc
    FROM inventory.ItemFiles fl
    WHERE fl.ItemId = @Id
    ORDER BY fl.IsItemImage DESC, fl.CreatedAtUtc DESC;
END
GO

/* ================================================================== 5. Document type CNT (family Logistics) */

IF EXISTS (SELECT 1 FROM sys.check_constraints
           WHERE name = N'CK_DocumentTypes_Family'
             AND parent_object_id = OBJECT_ID(N'inventory.DocumentTypes')
             AND [definition] NOT LIKE N'%Logistics%')
BEGIN
    ALTER TABLE inventory.DocumentTypes DROP CONSTRAINT CK_DocumentTypes_Family;
    ALTER TABLE inventory.DocumentTypes ADD CONSTRAINT CK_DocumentTypes_Family
        CHECK (Family IN (N'Inventory', N'Purchase', N'Sales', N'Logistics'));
    PRINT 'DocumentTypes: family Logistics allowed';
END
GO

MERGE inventory.DocumentTypes AS t
USING (VALUES (N'CNT', N'Container', N'Logistics', 1, N'KTG-', 0, 0)) AS s (Code, Name, Family, StockDirection, NumberPrefix, NumberOnPost, RequiresReason)
ON t.Code = s.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Family, StockDirection, NumberPrefix, NumberOnPost, RequiresReason)
    VALUES (s.Code, s.Name, s.Family, s.StockDirection, s.NumberPrefix, s.NumberOnPost, s.RequiresReason);
GO

UPDATE inventory.DocumentTypes
SET DefaultPricing = N'None', PriceEditable = 0, NumberPerBranch = 0, YearInNumber = 1, NumberLength = 4
WHERE Code = N'CNT';
GO

/* ================================================================== 6. Container tables */

IF OBJECT_ID(N'logistics.Containers', N'U') IS NULL
BEGIN
    CREATE TABLE logistics.Containers
    (
        Id                  INT IDENTITY(1,1) NOT NULL,
        DocumentTypeId      INT            NOT NULL,                 -- CNT
        ContainerRef        NVARCHAR(30)   NOT NULL,                 -- KTG-2026-0001 (assigned on first save)
        ContainerNo         NVARCHAR(20)   NULL,                     -- carrier box number, e.g. MSKU9988776
        ContainerTypeId     INT            NOT NULL,
        SealNo              NVARCHAR(30)   NULL,
        CustomsSealNo       NVARCHAR(30)   NULL,
        Description         NVARCHAR(500)  NULL,
        -- order
        OrderDate           DATE           NOT NULL,
        OrderMonthKey       AS (YEAR(OrderDate) * 100 + MONTH(OrderDate)) PERSISTED,
        ShippingMethod      NVARCHAR(10)   NOT NULL CONSTRAINT DF_Containers_Method DEFAULT (N'Sea'),
        CountryOfOrigin     NCHAR(2)       NULL,
        ForwarderId         INT            NULL,                     -- masterdata.Parties (service supplier)
        TransporterId       INT            NULL,
        -- shipping
        ShippingLine        NVARCHAR(100)  NULL,
        VesselName          NVARCHAR(100)  NULL,
        VoyageNo            NVARCHAR(30)   NULL,
        BookingNo           NVARCHAR(30)   NULL,
        PortOfLoadingId     INT            NULL,
        PortOfDestinationId INT            NULL,
        FinalDestinationId  INT            NULL,
        DispatchDate        DATE           NULL,
        Eta                 DATE           NULL,
        FreeDays            INT            NULL,
        GrossWeightKg       DECIMAL(18,3)  NULL,
        VolumeCbm           DECIMAL(18,3)  NULL,
        Packages            INT            NULL,
        -- bill of lading
        BlNo                NVARCHAR(30)   NULL,
        BlDate              DATE           NULL,
        BlNotes             NVARCHAR(500)  NULL,
        -- capacity
        MaxUnits            INT            NULL,                     -- copied from the type, editable
        TotalLines          INT            NOT NULL CONSTRAINT DF_Containers_Lines DEFAULT (0),
        TotalAllocatedBase  INT            NOT NULL CONSTRAINT DF_Containers_Allocated DEFAULT (0),
        TotalReceivedBase   INT            NOT NULL CONSTRAINT DF_Containers_Received DEFAULT (0),
        TotalOilQty         DECIMAL(18,2)  NOT NULL CONSTRAINT DF_Containers_Oil DEFAULT (0),
        UtilizationPct      AS (CASE WHEN MaxUnits > 0 THEN CONVERT(DECIMAL(9,2), 100.0 * TotalAllocatedBase / MaxUnits) END) PERSISTED,
        -- operations
        BranchId            INT            NOT NULL,
        WarehouseId         INT            NULL,                     -- offloading destination
        TruckNo             NVARCHAR(30)   NULL,
        WaybillNo           NVARCHAR(30)   NULL,
        DeclarationNo       NVARCHAR(30)   NULL,
        FeriNo              NVARCHAR(30)   NULL,
        ActualPortArrival   DATE           NULL,
        BorderCrossingDate  DATE           NULL,
        CustomsReleaseDate  DATE           NULL,
        LastFreeDay         AS (CASE WHEN FreeDays IS NOT NULL AND ActualPortArrival IS NOT NULL
                                     THEN DATEADD(DAY, FreeDays, ActualPortArrival) END) PERSISTED,
        OffloadedDate       DATE           NULL,
        OffloadedAtUtc      DATETIME2(3)   NULL,
        OffloadedBy         INT            NULL,
        -- status: 1 Draft, 2 Confirmed, 3 In Transit, 4 At Port, 5 Cleared, 6 Offloaded, 7 Closed, 8 Cancelled
        Status              TINYINT        NOT NULL CONSTRAINT DF_Containers_Status DEFAULT (1),
        StatusNote          NVARCHAR(200)  NULL,
        CurrentLocation     NVARCHAR(100)  NULL,
        ConfirmedAtUtc      DATETIME2(3)   NULL,
        ConfirmedBy         INT            NULL,
        ClosedAtUtc         DATETIME2(3)   NULL,
        ClosedBy            INT            NULL,
        CancelledAtUtc      DATETIME2(3)   NULL,
        CancelledBy         INT            NULL,
        CancelReason        NVARCHAR(300)  NULL,
        Notes               NVARCHAR(1000) NULL,
        CreatedAtUtc        DATETIME2(3)   NOT NULL CONSTRAINT DF_Containers_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy           INT            NULL,
        UpdatedAtUtc        DATETIME2(3)   NULL,
        UpdatedBy           INT            NULL,
        RowVersion          ROWVERSION     NOT NULL,
        CONSTRAINT PK_Containers PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_Containers_Ref UNIQUE (ContainerRef),
        CONSTRAINT CK_Containers_Status CHECK (Status BETWEEN 1 AND 8),
        CONSTRAINT CK_Containers_Method CHECK (ShippingMethod IN (N'Sea', N'Air', N'Road')),
        CONSTRAINT CK_Containers_MaxUnits CHECK (MaxUnits IS NULL OR MaxUnits > 0),
        CONSTRAINT CK_Containers_FreeDays CHECK (FreeDays IS NULL OR FreeDays >= 0),
        CONSTRAINT FK_Containers_Type        FOREIGN KEY (DocumentTypeId)      REFERENCES inventory.DocumentTypes (Id),
        CONSTRAINT FK_Containers_CtType      FOREIGN KEY (ContainerTypeId)     REFERENCES masterdata.ContainerTypes (Id),
        CONSTRAINT FK_Containers_Branch      FOREIGN KEY (BranchId)            REFERENCES masterdata.Branches (Id),
        CONSTRAINT FK_Containers_Warehouse   FOREIGN KEY (WarehouseId)         REFERENCES masterdata.Warehouses (Id),
        CONSTRAINT FK_Containers_Forwarder   FOREIGN KEY (ForwarderId)         REFERENCES masterdata.Parties (Id),
        CONSTRAINT FK_Containers_Transporter FOREIGN KEY (TransporterId)       REFERENCES masterdata.Parties (Id),
        CONSTRAINT FK_Containers_PortLoad    FOREIGN KEY (PortOfLoadingId)     REFERENCES masterdata.Ports (Id),
        CONSTRAINT FK_Containers_PortDest    FOREIGN KEY (PortOfDestinationId) REFERENCES masterdata.Ports (Id),
        CONSTRAINT FK_Containers_FinalDest   FOREIGN KEY (FinalDestinationId)  REFERENCES masterdata.Ports (Id),
        CONSTRAINT FK_Containers_Offloaded   FOREIGN KEY (OffloadedBy)         REFERENCES security.Users (Id),
        CONSTRAINT FK_Containers_Confirmed   FOREIGN KEY (ConfirmedBy)         REFERENCES security.Users (Id),
        CONSTRAINT FK_Containers_Closed      FOREIGN KEY (ClosedBy)            REFERENCES security.Users (Id),
        CONSTRAINT FK_Containers_Cancelled   FOREIGN KEY (CancelledBy)         REFERENCES security.Users (Id),
        CONSTRAINT FK_Containers_CreatedBy   FOREIGN KEY (CreatedBy)           REFERENCES security.Users (Id),
        CONSTRAINT FK_Containers_UpdatedBy   FOREIGN KEY (UpdatedBy)           REFERENCES security.Users (Id)
    );
    -- The same box number comes back years later: unique only while the container is still open.
    CREATE UNIQUE NONCLUSTERED INDEX UX_Containers_ContainerNo ON logistics.Containers (ContainerNo)
        WHERE ContainerNo IS NOT NULL AND Status < 7;
    CREATE NONCLUSTERED INDEX IX_Containers_Status     ON logistics.Containers (Status, OrderDate DESC);
    CREATE NONCLUSTERED INDEX IX_Containers_Warehouse  ON logistics.Containers (WarehouseId, Status);
    CREATE NONCLUSTERED INDEX IX_Containers_OrderMonth ON logistics.Containers (OrderMonthKey);
    PRINT 'Created logistics.Containers';
END
GO

IF OBJECT_ID(N'logistics.ContainerInvoices', N'U') IS NULL
BEGIN
    CREATE TABLE logistics.ContainerInvoices
    (
        Id                 INT IDENTITY(1,1) NOT NULL,
        ContainerId        INT NOT NULL,
        PurchaseDocumentId INT NOT NULL,      -- purchase.PurchaseDocuments (PINV)
        CONSTRAINT PK_ContainerInvoices PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_ContainerInvoices UNIQUE (ContainerId, PurchaseDocumentId),
        CONSTRAINT FK_ContainerInvoices_Container FOREIGN KEY (ContainerId)        REFERENCES logistics.Containers (Id),
        CONSTRAINT FK_ContainerInvoices_Invoice   FOREIGN KEY (PurchaseDocumentId) REFERENCES purchase.PurchaseDocuments (Id)
    );
    CREATE NONCLUSTERED INDEX IX_ContainerInvoices_Invoice ON logistics.ContainerInvoices (PurchaseDocumentId);
    PRINT 'Created logistics.ContainerInvoices';
END
GO

IF OBJECT_ID(N'logistics.ContainerLines', N'U') IS NULL
BEGIN
    CREATE TABLE logistics.ContainerLines
    (
        Id                   INT IDENTITY(1,1) NOT NULL,
        ContainerId          INT            NOT NULL,
        LineNumber           INT            NOT NULL,
        PurchaseDocumentId   INT            NOT NULL,
        PurchaseLineId       INT            NOT NULL,
        ItemId               INT            NOT NULL,
        ItemUnitId           INT            NOT NULL,
        PackingFormula       INT            NOT NULL,
        Quantity             INT            NOT NULL,                -- in the purchase line unit
        QuantityBase         AS (Quantity * PackingFormula) PERSISTED,
        OilIncluded          BIT            NOT NULL CONSTRAINT DF_ContainerLines_Oil DEFAULT (0),
        OilQtyPerUnit        DECIMAL(9,2)   NULL,                    -- information only (litres per unit)
        TotalOilQty          AS (CONVERT(DECIMAL(18,2), Quantity * ISNULL(OilQtyPerUnit, 0))) PERSISTED,
        ReceivedQuantityBase INT            NULL,                    -- filled at offload
        VarianceReason       NVARCHAR(200)  NULL,
        Notes                NVARCHAR(300)  NULL,
        CONSTRAINT PK_ContainerLines PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_ContainerLines_LineNo UNIQUE (ContainerId, LineNumber),
        CONSTRAINT UQ_ContainerLines_Source UNIQUE (ContainerId, PurchaseLineId),
        CONSTRAINT CK_ContainerLines_Qty CHECK (Quantity > 0),
        CONSTRAINT CK_ContainerLines_Received CHECK (ReceivedQuantityBase IS NULL OR ReceivedQuantityBase >= 0),
        CONSTRAINT FK_ContainerLines_Container FOREIGN KEY (ContainerId)        REFERENCES logistics.Containers (Id),
        CONSTRAINT FK_ContainerLines_Invoice   FOREIGN KEY (PurchaseDocumentId) REFERENCES purchase.PurchaseDocuments (Id),
        CONSTRAINT FK_ContainerLines_Line      FOREIGN KEY (PurchaseLineId)     REFERENCES purchase.PurchaseDocumentLines (Id),
        CONSTRAINT FK_ContainerLines_Item      FOREIGN KEY (ItemId)             REFERENCES inventory.Items (Id),
        CONSTRAINT FK_ContainerLines_Unit      FOREIGN KEY (ItemUnitId)         REFERENCES inventory.ItemUnits (Id)
    );
    CREATE NONCLUSTERED INDEX IX_ContainerLines_Container ON logistics.ContainerLines (ContainerId);
    CREATE NONCLUSTERED INDEX IX_ContainerLines_Source    ON logistics.ContainerLines (PurchaseLineId);
    CREATE NONCLUSTERED INDEX IX_ContainerLines_Item      ON logistics.ContainerLines (ItemId);
    PRINT 'Created logistics.ContainerLines';
END
GO

IF OBJECT_ID(N'logistics.ContainerEvents', N'U') IS NULL
BEGIN
    CREATE TABLE logistics.ContainerEvents
    (
        Id           BIGINT IDENTITY(1,1) NOT NULL,
        ContainerId  INT           NOT NULL,
        EventType    NVARCHAR(20)  NOT NULL,   -- Booked | Dispatched | PortArrival | CustomsRelease | BorderCrossing | Offloaded | Note
        EventDate    DATE          NOT NULL,
        PortId       INT           NULL,
        LocationText NVARCHAR(100) NULL,
        Notes        NVARCHAR(300) NULL,
        CreatedAtUtc DATETIME2(3)  NOT NULL CONSTRAINT DF_ContainerEvents_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy    INT           NULL,
        CONSTRAINT PK_ContainerEvents PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_ContainerEvents_Type CHECK (EventType IN (N'Booked', N'Dispatched', N'PortArrival', N'CustomsRelease', N'BorderCrossing', N'Offloaded', N'Note')),
        CONSTRAINT FK_ContainerEvents_Container FOREIGN KEY (ContainerId) REFERENCES logistics.Containers (Id),
        CONSTRAINT FK_ContainerEvents_Port      FOREIGN KEY (PortId)      REFERENCES masterdata.Ports (Id),
        CONSTRAINT FK_ContainerEvents_CreatedBy FOREIGN KEY (CreatedBy)   REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_ContainerEvents_Container ON logistics.ContainerEvents (ContainerId, EventDate, Id);
    PRINT 'Created logistics.ContainerEvents';
END
GO

IF OBJECT_ID(N'logistics.ContainerFiles', N'U') IS NULL
BEGIN
    CREATE TABLE logistics.ContainerFiles
    (
        Id               INT IDENTITY(1,1) NOT NULL,
        ContainerId      INT            NOT NULL,
        AttachmentTypeId INT            NULL,
        FileName         NVARCHAR(255)  NOT NULL,
        ContentType      NVARCHAR(100)  NOT NULL,
        SizeBytes        INT            NOT NULL,
        Content          VARBINARY(MAX) NOT NULL,
        Note             NVARCHAR(300)  NULL,
        DocumentDate     DATE           NULL,
        CreatedAtUtc     DATETIME2(3)   NOT NULL CONSTRAINT DF_ContainerFiles_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy        INT            NULL,
        CONSTRAINT PK_ContainerFiles PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_ContainerFiles_Size CHECK (SizeBytes > 0),
        CONSTRAINT FK_ContainerFiles_Container FOREIGN KEY (ContainerId)      REFERENCES logistics.Containers (Id),
        CONSTRAINT FK_ContainerFiles_Type      FOREIGN KEY (AttachmentTypeId) REFERENCES masterdata.AttachmentTypes (Id),
        CONSTRAINT FK_ContainerFiles_CreatedBy FOREIGN KEY (CreatedBy)        REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_ContainerFiles_Container ON logistics.ContainerFiles (ContainerId);
    PRINT 'Created logistics.ContainerFiles';
END
GO

IF OBJECT_ID(N'logistics.ContainerAudit', N'U') IS NULL
BEGIN
    CREATE TABLE logistics.ContainerAudit
    (
        Id          BIGINT IDENTITY(1,1) NOT NULL,
        ContainerId INT           NOT NULL,
        Action      NVARCHAR(20)  NOT NULL,   -- Created | Updated | Confirmed | Event | Offloaded | OffloadCancelled | Closed | Cancelled
        Details     NVARCHAR(500) NULL,
        UserId      INT           NULL,
        AtUtc       DATETIME2(3)  NOT NULL CONSTRAINT DF_ContainerAudit_AtUtc DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_ContainerAudit PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_ContainerAudit_Container FOREIGN KEY (ContainerId) REFERENCES logistics.Containers (Id),
        CONSTRAINT FK_ContainerAudit_User      FOREIGN KEY (UserId)      REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_ContainerAudit_Container ON logistics.ContainerAudit (ContainerId, AtUtc);
    PRINT 'Created logistics.ContainerAudit';
END
GO

IF TYPE_ID(N'logistics.tvp_ContainerInvoice') IS NULL
BEGIN
    CREATE TYPE logistics.tvp_ContainerInvoice AS TABLE
    (
        PurchaseDocumentId INT NOT NULL PRIMARY KEY
    );
    PRINT 'Created type logistics.tvp_ContainerInvoice';
END
GO

IF TYPE_ID(N'logistics.tvp_ContainerLine') IS NULL
BEGIN
    CREATE TYPE logistics.tvp_ContainerLine AS TABLE
    (
        LineNumber     INT           NOT NULL PRIMARY KEY,
        PurchaseLineId INT           NOT NULL,
        Quantity       INT           NOT NULL,      -- in the purchase line unit
        OilIncluded    BIT           NOT NULL,
        OilQtyPerUnit  DECIMAL(9,2)  NULL,          -- NULL = the item's value
        Notes          NVARCHAR(300) NULL
    );
    PRINT 'Created type logistics.tvp_ContainerLine';
END
GO

IF TYPE_ID(N'logistics.tvp_ContainerReceipt') IS NULL
BEGIN
    CREATE TYPE logistics.tvp_ContainerReceipt AS TABLE
    (
        LineId               INT           NOT NULL PRIMARY KEY,
        ReceivedQuantityBase INT           NOT NULL,
        VarianceReason       NVARCHAR(200) NULL
    );
    PRINT 'Created type logistics.tvp_ContainerReceipt';
END
GO

/* ================================================================== 7. Purchase invoices: receipt mode + references

   ReceiptMode 1 = stock enters when the invoice is posted (local purchases, unchanged behaviour)
   ReceiptMode 2 = stock enters when the CONTAINER is offloaded (imports). Posting still computes the FOB,
                   allocates the charges and closes the source purchase order, but writes no stock movement.
   ================================================================== */

IF COL_LENGTH(N'purchase.PurchaseDocuments', N'ReceiptMode') IS NULL
BEGIN
    ALTER TABLE purchase.PurchaseDocuments ADD
        ReceiptMode         TINYINT      NOT NULL CONSTRAINT DF_PurchaseDocuments_ReceiptMode DEFAULT (1),
        ExporterReference   NVARCHAR(50) NULL,
        CommercialInvoiceNo NVARCHAR(50) NULL,
        CONSTRAINT CK_PurchaseDocuments_ReceiptMode CHECK (ReceiptMode IN (1, 2));
    PRINT 'PurchaseDocuments: added ReceiptMode, ExporterReference, CommercialInvoiceNo';
END
GO

-- Re-created: saves the two supplier references and the receipt mode (PINV only; forced to 2 once the
-- invoice is allocated to a container).
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
        -- An invoice already loaded into a container is always received at offload.
        IF EXISTS (SELECT 1 FROM logistics.ContainerInvoices ci INNER JOIN logistics.Containers c ON c.Id = ci.ContainerId
                   WHERE ci.PurchaseDocumentId = @Id AND c.Status <> 8)
            SET @ReceiptMode = 2;
        -- Lines that are allocated to a container cannot be replaced.
        IF EXISTS (SELECT 1 FROM logistics.ContainerLines cl INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                   WHERE cl.PurchaseDocumentId = @Id AND c.Status <> 8)
            THROW 69012, 'This invoice has quantities loaded into a container. Remove them from the container before changing the lines.', 1;
    END

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

            -- Lines of cancelled containers protect nothing: they are cleaned up first.
            DELETE cl FROM logistics.ContainerLines cl
            INNER JOIN logistics.Containers c2 ON c2.Id = cl.ContainerId
            WHERE cl.PurchaseDocumentId = @Id AND c2.Status = 8;

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
               CASE WHEN @DocumentTypeCode = N'PRET' THEN src.UnitCostBase END,      -- returns carry the invoice LANDED cost
               CASE WHEN @DocumentTypeCode = N'PRET' THEN src.FobCostBase END,
               l.ImportRowNumber, NULLIF(LTRIM(RTRIM(l.Notes)), N''), l.SourceLineId
        FROM @Lines l
        INNER JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        LEFT  JOIN purchase.PurchaseDocumentLines src ON src.Id = l.SourceLineId;

        UPDATE d
        SET TotalItems = x.Items, TotalQuantity = x.Qty, Subtotal = x.Sub, TotalAmount = x.Amt, TotalDiscount = x.Sub - x.Amt,
            TotalAmountBase = ROUND(x.Amt / @Rate, 2), TotalLandedCostBase = ROUND(x.Amt / @Rate, 2) + d.TotalChargesBase
        FROM purchase.PurchaseDocuments d
        CROSS APPLY (SELECT COUNT(*) AS Items, ISNULL(SUM(QuantityBase), 0) AS Qty,
                            ISNULL(SUM(CONVERT(DECIMAL(18,2), Quantity * UnitPrice)), 0) AS Sub, ISNULL(SUM(LineTotal), 0) AS Amt
                     FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id) x
        WHERE d.Id = @Id;

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Re-created: a PINV with ReceiptMode = 2 computes its costs but does NOT touch the stock ledger;
-- logistics.usp_Container_Offload writes the movements when the container arrives.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Post
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
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
        IF @Status <> 1 THROW 65010, 'Only draft documents can be posted.', 1;
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
                                       ELSE N' (order confirmed)' END
                                + CASE WHEN @TypeCode = N'PINV' THEN N'; landed charges ' + CAST((SELECT TotalChargesBase FROM purchase.PurchaseDocuments WHERE Id = @Id) AS NVARCHAR(30)) ELSE N'' END, @UserId);

        COMMIT TRANSACTION;
        SELECT @Number AS DocumentNumber;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Re-created: an invoice loaded into a container cannot be cancelled while the container is not a draft,
-- and a cancelled invoice releases its own received quantities.
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

        DECLARE @Ct NVARCHAR(200);
        SELECT TOP (1) @Ct = c.ContainerRef
        FROM logistics.ContainerLines cl
        INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
        WHERE cl.PurchaseDocumentId = @Id AND c.Status NOT IN (1, 8)
        ORDER BY c.ContainerRef;
        IF @Ct IS NOT NULL
            THROW 69012, 'This invoice cannot be cancelled: its quantities are loaded into a container that has left the supplier. Cancel the container first.', 1;
        IF EXISTS (SELECT 1 FROM logistics.ContainerLines WHERE PurchaseDocumentId = @Id AND ISNULL(ReceivedQuantityBase, 0) > 0)
            THROW 69012, 'This invoice cannot be cancelled: part of it was already received by a container offload.', 1;

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

        -- A cancelled invoice is removed from the containers that were still being prepared.
        DELETE FROM logistics.ContainerLines WHERE PurchaseDocumentId = @Id;
        DELETE FROM logistics.ContainerInvoices WHERE PurchaseDocumentId = @Id;

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

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Re-created: a draft that is already linked to a container cannot be deleted.
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
    IF EXISTS (SELECT 1 FROM logistics.ContainerInvoices ci INNER JOIN logistics.Containers c ON c.Id = ci.ContainerId
               WHERE ci.PurchaseDocumentId = @Id AND c.Status <> 8)
        THROW 69012, 'This invoice is linked to a container. Remove it from the container first.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE cl FROM logistics.ContainerLines cl
        INNER JOIN logistics.Containers c2 ON c2.Id = cl.ContainerId
        WHERE cl.PurchaseDocumentId = @Id AND c2.Status = 8;
        DELETE ci FROM logistics.ContainerInvoices ci
        INNER JOIN logistics.Containers c3 ON c3.Id = ci.ContainerId
        WHERE ci.PurchaseDocumentId = @Id AND c3.Status = 8;
        DELETE a FROM purchase.PurchaseChargeAllocations a INNER JOIN purchase.PurchaseCharges c ON c.Id = a.ChargeId WHERE c.DocumentKind = N'PINV' AND c.DocumentId = @Id;
        DELETE FROM purchase.PurchaseCharges WHERE DocumentKind = N'PINV' AND DocumentId = @Id;
        DELETE FROM purchase.PurchaseDocumentFiles WHERE DocumentId = @Id;
        DELETE FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id;
        DELETE FROM purchase.PurchaseDocumentAudit WHERE DocumentId = @Id;
        DELETE FROM purchase.PurchaseDocuments WHERE Id = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Re-created: header carries the receipt mode and the import references; a 7th result set lists the containers.
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
END
GO

/* ================================================================== 8. Containers: helpers, search, get */

-- Recomputes the totals, the derived status and the current location. Closed (7) and cancelled (8) stay.
CREATE OR ALTER PROCEDURE logistics.usp_Container_RefreshStatus
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE c
    SET TotalLines         = ISNULL(x.Lines, 0),
        TotalAllocatedBase = ISNULL(x.Allocated, 0),
        TotalReceivedBase  = ISNULL(x.Received, 0),
        TotalOilQty        = ISNULL(x.Oil, 0),
        Status = CASE WHEN c.Status IN (7, 8) THEN c.Status
                      WHEN c.OffloadedDate IS NOT NULL THEN 6
                      WHEN c.CustomsReleaseDate IS NOT NULL THEN 5
                      WHEN c.ActualPortArrival IS NOT NULL THEN 4
                      WHEN c.DispatchDate IS NOT NULL THEN 3
                      WHEN c.ConfirmedAtUtc IS NOT NULL THEN 2
                      ELSE 1 END,
        CurrentLocation = COALESCE(ev.Place,
                                   CASE WHEN c.OffloadedDate IS NOT NULL THEN (SELECT WarehouseName FROM masterdata.Warehouses WHERE Id = c.WarehouseId)
                                        WHEN c.CustomsReleaseDate IS NOT NULL OR c.ActualPortArrival IS NOT NULL
                                             THEN (SELECT PortName FROM masterdata.Ports WHERE Id = c.PortOfDestinationId)
                                        WHEN c.DispatchDate IS NOT NULL THEN N'In transit'
                                        ELSE NULL END)
    FROM logistics.Containers c
    CROSS APPLY (SELECT Lines = COUNT(*), Allocated = SUM(QuantityBase), Received = SUM(ISNULL(ReceivedQuantityBase, 0)),
                        Oil = SUM(TotalOilQty)
                 FROM logistics.ContainerLines WHERE ContainerId = @Id) x
    OUTER APPLY (SELECT TOP (1) Place = COALESCE(p.PortName, e.LocationText)
                 FROM logistics.ContainerEvents e
                 LEFT JOIN masterdata.Ports p ON p.Id = e.PortId
                 WHERE e.ContainerId = @Id AND (p.PortName IS NOT NULL OR e.LocationText IS NOT NULL)
                 ORDER BY e.EventDate DESC, e.Id DESC) ev
    WHERE c.Id = @Id;
END
GO

-- Purchase invoices that still have quantities to load (posted or draft PINV, not cancelled).
CREATE OR ALTER PROCEDURE logistics.usp_Container_AvailableInvoices
    @Search      NVARCHAR(100) = NULL,
    @SupplierId  INT           = NULL,
    @ContainerId INT           = NULL,     -- excluded from "allocated elsewhere"
    @Top         INT           = 50
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @Top IS NULL OR @Top < 1 SET @Top = 50;

    SELECT TOP (@Top)
           d.Id, d.DocumentNumber, d.DocumentDate, d.Status, d.ReceiptMode,
           d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName,
           d.CurrencyId, c.CurrencyCode, c.Symbol AS CurrencySymbol,
           d.SupplierReference, d.ExporterReference, d.CommercialInvoiceNo,
           d.WarehouseId, w.WarehouseCode, w.WarehouseName,
           TotalQtyBase     = x.Total,
           AllocatedBase    = ISNULL(x.Allocated, 0),
           AllocatedHereBase = ISNULL(x.Here, 0),
           RemainingBase    = x.Total - ISNULL(x.Allocated, 0),
           d.TotalAmount, d.TotalAmountBase
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Parties sp      ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    INNER JOIN masterdata.Warehouses w    ON w.Id = d.WarehouseId
    CROSS APPLY (SELECT Total = ISNULL(SUM(l.QuantityBase), 0),
                        Allocated = ISNULL((SELECT SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                                            INNER JOIN logistics.Containers ct ON ct.Id = cl.ContainerId
                                            WHERE cl.PurchaseDocumentId = d.Id AND ct.Status <> 8), 0),
                        Here = ISNULL((SELECT SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                                       WHERE cl.PurchaseDocumentId = d.Id AND cl.ContainerId = @ContainerId), 0)
                 FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = d.Id) x
    WHERE dt.Code = N'PINV'
      AND d.Status IN (1, 2)
      AND (@SupplierId IS NULL OR d.SupplierId = @SupplierId)
      AND (@Search IS NULL OR d.DocumentNumber LIKE N'%' + @Search + N'%' OR d.CommercialInvoiceNo LIKE N'%' + @Search + N'%'
           OR d.SupplierReference LIKE N'%' + @Search + N'%' OR d.ExporterReference LIKE N'%' + @Search + N'%' OR sp.PartyName LIKE N'%' + @Search + N'%')
      AND (x.Total - ISNULL(x.Allocated, 0) > 0 OR ISNULL(x.Here, 0) > 0)
    ORDER BY d.DocumentDate DESC, d.Id DESC;
END
GO

CREATE OR ALTER PROCEDURE logistics.usp_Container_Search
    @Search              NVARCHAR(100) = NULL,   -- ref, container no., B/L, PI no., commercial invoice no.
    @ContainerRef        NVARCHAR(30)  = NULL,
    @ContainerNo         NVARCHAR(20)  = NULL,
    @SupplierId          INT           = NULL,
    @PurchaseDocumentId  INT           = NULL,
    @CommercialInvoiceNo NVARCHAR(50)  = NULL,
    @ItemId              INT           = NULL,
    @BlNo                NVARCHAR(30)  = NULL,
    @Status              TINYINT       = NULL,
    @PortId              INT           = NULL,
    @WarehouseId         INT           = NULL,
    @BranchId            INT           = NULL,
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
           c.OrderDate, c.OrderMonthKey,
           OrderMonth = FORMAT(c.OrderDate, N'MMM-yyyy', N'en-US'),
           c.BranchId, b.BranchCode, b.BranchName, c.WarehouseId, w.WarehouseCode, w.WarehouseName,
           SupplierCount = ISNULL(inv.SupplierCount, 0),
           SupplierNames = CASE WHEN ISNULL(inv.SupplierCount, 0) = 0 THEN NULL
                                WHEN inv.SupplierCount = 1 THEN inv.FirstSupplier
                                ELSE inv.FirstSupplier + N' +' + CAST(inv.SupplierCount - 1 AS NVARCHAR(10)) END,
           InvoiceCount = ISNULL(inv.InvoiceCount, 0),
           InvoiceNumbers = CASE WHEN ISNULL(inv.InvoiceCount, 0) = 0 THEN NULL
                                 WHEN inv.InvoiceCount = 1 THEN inv.FirstInvoice
                                 ELSE inv.FirstInvoice + N' +' + CAST(inv.InvoiceCount - 1 AS NVARCHAR(10)) END,
           CommercialInvoiceNos = CASE WHEN inv.CiCount = 1 THEN inv.FirstCi
                                       WHEN inv.CiCount > 1 THEN inv.FirstCi + N' +' + CAST(inv.CiCount - 1 AS NVARCHAR(10)) END,
           ItemCount = ISNULL(ln.ItemCount, 0),
           ItemSummary = CASE WHEN ISNULL(ln.ItemCount, 0) = 0 THEN NULL
                              WHEN ln.ItemCount = 1 THEN ln.FirstItem
                              ELSE N'Mixed - ' + CAST(ln.ItemCount AS NVARCHAR(10)) + N' items' END,
           TotalQtyBase = ISNULL(ln.Qty, 0), TotalReceivedBase = c.TotalReceivedBase, c.TotalOilQty,
           c.MaxUnits, c.UtilizationPct,
           c.BlNo, c.BlDate, c.DispatchDate, c.Eta, c.ActualPortArrival, c.CustomsReleaseDate, c.OffloadedDate,
           c.FreeDays, c.LastFreeDay,
           DaysAtPort = CASE WHEN c.ActualPortArrival IS NOT NULL
                             THEN DATEDIFF(DAY, c.ActualPortArrival, ISNULL(c.OffloadedDate, CAST(SYSUTCDATETIME() AS DATE))) END,
           c.CurrentLocation, c.Status, c.StatusNote,
           pl.PortName AS PortOfLoadingName, pd.PortName AS PortOfDestinationName,
           c.CreatedAtUtc, c.CreatedBy, cu.FullName AS CreatedByName, c.UpdatedAtUtc, c.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM logistics.Containers c
    INNER JOIN masterdata.ContainerTypes ct ON ct.Id = c.ContainerTypeId
    INNER JOIN masterdata.Branches b        ON b.Id = c.BranchId
    LEFT  JOIN masterdata.Warehouses w      ON w.Id = c.WarehouseId
    LEFT  JOIN masterdata.Ports pl          ON pl.Id = c.PortOfLoadingId
    LEFT  JOIN masterdata.Ports pd          ON pd.Id = c.PortOfDestinationId
    LEFT  JOIN security.Users cu            ON cu.Id = c.CreatedBy
    OUTER APPLY (SELECT InvoiceCount = COUNT(*), SupplierCount = COUNT(DISTINCT d.SupplierId),
                        CiCount = COUNT(d.CommercialInvoiceNo),
                        FirstInvoice = MIN(d.DocumentNumber), FirstSupplier = MIN(sp.PartyName), FirstCi = MIN(d.CommercialInvoiceNo)
                 FROM logistics.ContainerInvoices ci
                 INNER JOIN purchase.PurchaseDocuments d ON d.Id = ci.PurchaseDocumentId
                 INNER JOIN masterdata.Parties sp ON sp.Id = d.SupplierId
                 WHERE ci.ContainerId = c.Id) inv
    OUTER APPLY (SELECT ItemCount = COUNT(DISTINCT cl.ItemId), Qty = SUM(cl.QuantityBase), FirstItem = MIN(i.ItemName)
                 FROM logistics.ContainerLines cl
                 INNER JOIN inventory.Items i ON i.Id = cl.ItemId
                 WHERE cl.ContainerId = c.Id) ln
    WHERE (@Search IS NULL OR c.ContainerRef LIKE N'%' + @Search + N'%' OR c.ContainerNo LIKE N'%' + @Search + N'%'
           OR c.BlNo LIKE N'%' + @Search + N'%' OR c.VesselName LIKE N'%' + @Search + N'%'
           OR EXISTS (SELECT 1 FROM logistics.ContainerInvoices ci INNER JOIN purchase.PurchaseDocuments d ON d.Id = ci.PurchaseDocumentId
                      INNER JOIN masterdata.Parties sp ON sp.Id = d.SupplierId
                      WHERE ci.ContainerId = c.Id AND (d.DocumentNumber LIKE N'%' + @Search + N'%'
                            OR d.CommercialInvoiceNo LIKE N'%' + @Search + N'%' OR sp.PartyName LIKE N'%' + @Search + N'%')))
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
      AND (@SupplierId IS NULL OR EXISTS (SELECT 1 FROM logistics.ContainerInvoices ci INNER JOIN purchase.PurchaseDocuments d ON d.Id = ci.PurchaseDocumentId
                                          WHERE ci.ContainerId = c.Id AND d.SupplierId = @SupplierId))
      AND (@PurchaseDocumentId IS NULL OR EXISTS (SELECT 1 FROM logistics.ContainerInvoices ci WHERE ci.ContainerId = c.Id AND ci.PurchaseDocumentId = @PurchaseDocumentId))
      AND (@CommercialInvoiceNo IS NULL OR EXISTS (SELECT 1 FROM logistics.ContainerInvoices ci INNER JOIN purchase.PurchaseDocuments d ON d.Id = ci.PurchaseDocumentId
                                                   WHERE ci.ContainerId = c.Id AND d.CommercialInvoiceNo LIKE N'%' + @CommercialInvoiceNo + N'%'))
      AND (@ItemId IS NULL OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl WHERE cl.ContainerId = c.Id AND cl.ItemId = @ItemId))
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

-- Six result sets: header, invoices, lines, events, files, audit.
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
           c.ConfirmedAtUtc, c.ConfirmedBy, fu.FullName AS ConfirmedByName,
           c.ClosedAtUtc, c.ClosedBy, ku.FullName AS ClosedByName,
           c.CancelledAtUtc, c.CancelledBy, xu.FullName AS CancelledByName, c.CancelReason,
           c.CreatedAtUtc, c.CreatedBy, cu.FullName AS CreatedByName,
           c.UpdatedAtUtc, c.UpdatedBy, uu.FullName AS UpdatedByName, c.RowVersion
    FROM logistics.Containers c
    INNER JOIN masterdata.ContainerTypes ct ON ct.Id = c.ContainerTypeId
    INNER JOIN masterdata.Branches b        ON b.Id = c.BranchId
    LEFT  JOIN masterdata.Warehouses w      ON w.Id = c.WarehouseId
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
    WHERE c.Id = @Id;

    SELECT ci.Id, ci.ContainerId, ci.PurchaseDocumentId, d.DocumentNumber, d.DocumentDate, d.Status AS InvoiceStatus,
           d.ReceiptMode, d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName,
           d.CurrencyId, cur.CurrencyCode, cur.Symbol AS CurrencySymbol, d.ExchangeRate,
           d.SupplierReference, d.ExporterReference, d.CommercialInvoiceNo,
           d.WarehouseId, w.WarehouseCode, w.WarehouseName,
           TotalQtyBase       = x.Total,
           AllocatedHereBase  = ISNULL(x.Here, 0),
           AllocatedTotalBase = ISNULL(x.Everywhere, 0),
           RemainingBase      = x.Total - ISNULL(x.Everywhere, 0),
           d.TotalAmount, d.TotalAmountBase, d.TotalLandedCostBase
    FROM logistics.ContainerInvoices ci
    INNER JOIN purchase.PurchaseDocuments d ON d.Id = ci.PurchaseDocumentId
    INNER JOIN masterdata.Parties sp        ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies cur    ON cur.Id = d.CurrencyId
    INNER JOIN masterdata.Warehouses w      ON w.Id = d.WarehouseId
    CROSS APPLY (SELECT Total = ISNULL(SUM(l.QuantityBase), 0),
                        Here = ISNULL((SELECT SUM(cl.QuantityBase) FROM logistics.ContainerLines cl WHERE cl.PurchaseDocumentId = d.Id AND cl.ContainerId = @Id), 0),
                        Everywhere = ISNULL((SELECT SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                                             INNER JOIN logistics.Containers c2 ON c2.Id = cl.ContainerId
                                             WHERE cl.PurchaseDocumentId = d.Id AND c2.Status <> 8), 0)
                 FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = d.Id) x
    WHERE ci.ContainerId = @Id
    ORDER BY d.DocumentNumber;

    SELECT cl.Id, cl.ContainerId, cl.LineNumber, cl.PurchaseDocumentId, d.DocumentNumber AS InvoiceNumber,
           d.CommercialInvoiceNo, sp.PartyName AS SupplierName,
           cl.PurchaseLineId, pl.LineNumber AS InvoiceLineNumber,
           cl.ItemId, i.ItemCode, i.ItemName, i.Model, br.BrandName,
           cl.ItemUnitId, ut.UnitTypeName, cl.PackingFormula,
           cl.Quantity, cl.QuantityBase, cl.OilIncluded, cl.OilQtyPerUnit, cl.TotalOilQty,
           cl.ReceivedQuantityBase, cl.VarianceReason, cl.Notes,
           InvoiceQtyBase        = pl.QuantityBase,
           AllocatedElsewhereBase = ISNULL(other.Qty, 0),
           AvailableBase         = pl.QuantityBase - ISNULL(other.Qty, 0),
           UnitCostBase          = pl.UnitCostBase, FobCostBase = pl.FobCostBase,
           OnHandBase            = inventory.fn_StockOnHand(cl.ItemId, pl.WarehouseId),
           pl.WarehouseId, w.WarehouseCode, w.WarehouseName
    FROM logistics.ContainerLines cl
    INNER JOIN purchase.PurchaseDocuments d      ON d.Id = cl.PurchaseDocumentId
    INNER JOIN masterdata.Parties sp             ON sp.Id = d.SupplierId
    INNER JOIN purchase.PurchaseDocumentLines pl ON pl.Id = cl.PurchaseLineId
    INNER JOIN masterdata.Warehouses w           ON w.Id = pl.WarehouseId
    INNER JOIN inventory.Items i                 ON i.Id = cl.ItemId
    INNER JOIN masterdata.Brands br              ON br.Id = i.BrandId
    INNER JOIN inventory.ItemUnits iu            ON iu.Id = cl.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut           ON ut.Id = iu.UnitTypeId
    OUTER APPLY (SELECT Qty = SUM(o.QuantityBase) FROM logistics.ContainerLines o
                 INNER JOIN logistics.Containers oc ON oc.Id = o.ContainerId
                 WHERE o.PurchaseLineId = cl.PurchaseLineId AND o.ContainerId <> @Id AND oc.Status <> 8) other
    WHERE cl.ContainerId = @Id
    ORDER BY cl.LineNumber;

    SELECT e.Id, e.ContainerId, e.EventType, e.EventDate, e.PortId, p.PortName, e.LocationText, e.Notes,
           e.CreatedAtUtc, e.CreatedBy, u.FullName AS CreatedByName
    FROM logistics.ContainerEvents e
    LEFT JOIN masterdata.Ports p ON p.Id = e.PortId
    LEFT JOIN security.Users u   ON u.Id = e.CreatedBy
    WHERE e.ContainerId = @Id
    ORDER BY e.EventDate DESC, e.Id DESC;

    SELECT f.Id, f.ContainerId, f.AttachmentTypeId, at.Category, at.SubType, f.FileName, f.ContentType, f.SizeBytes,
           f.Note, f.DocumentDate, f.CreatedAtUtc, f.CreatedBy, u.FullName AS CreatedByName
    FROM logistics.ContainerFiles f
    LEFT JOIN masterdata.AttachmentTypes at ON at.Id = f.AttachmentTypeId
    LEFT JOIN security.Users u ON u.Id = f.CreatedBy
    WHERE f.ContainerId = @Id
    ORDER BY f.CreatedAtUtc DESC;

    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM logistics.ContainerAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.ContainerId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;
END
GO

/* ================================================================== 9. Containers: save, confirm, events */

CREATE OR ALTER PROCEDURE logistics.usp_Container_Save
    @Id                  INT            = NULL,   -- NULL = create (ContainerRef assigned now)
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
    @DispatchDate        DATE           = NULL,
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
    @Invoices            logistics.tvp_ContainerInvoice READONLY,
    @Lines               logistics.tvp_ContainerLine READONLY,
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
        SELECT @Status = Status FROM logistics.Containers WHERE Id = @Id;
        IF @Status IS NULL THROW 69006, 'Container not found.', 1;
        IF @Status >= 6 THROW 69005, 'An offloaded, closed or cancelled container can no longer be changed.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 69004, 'This container was modified by another user. Reload the page and try again.', 1;
    END

    -- Invoices: every line's invoice is linked, even when the caller forgot it.
    DECLARE @Inv TABLE (PurchaseDocumentId INT PRIMARY KEY);
    INSERT INTO @Inv (PurchaseDocumentId) SELECT PurchaseDocumentId FROM @Invoices;
    INSERT INTO @Inv (PurchaseDocumentId)
    SELECT DISTINCT pl.DocumentId FROM @Lines l
    INNER JOIN purchase.PurchaseDocumentLines pl ON pl.Id = l.PurchaseLineId
    WHERE pl.DocumentId NOT IN (SELECT PurchaseDocumentId FROM @Inv);

    DECLARE @Msg NVARCHAR(400);

    SELECT TOP (1) @Msg =
        CASE WHEN d.Id IS NULL THEN N'A purchase invoice of the container no longer exists.'
             WHEN dt.Code <> N'PINV' THEN N'Document ' + d.DocumentNumber + N' is not a purchase invoice.'
             WHEN d.Status = 3 THEN N'Invoice ' + d.DocumentNumber + N' is cancelled.'
             WHEN d.Status = 2 AND d.ReceiptMode = 1 THEN N'Invoice ' + d.DocumentNumber + N' was already received into stock when it was posted, so it cannot be loaded into a container.'
             END
    FROM @Inv v
    LEFT JOIN purchase.PurchaseDocuments d ON d.Id = v.PurchaseDocumentId
    LEFT JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId
    WHERE d.Id IS NULL OR dt.Code <> N'PINV' OR d.Status = 3 OR (d.Status = 2 AND d.ReceiptMode = 1);
    IF @Msg IS NOT NULL THROW 69012, @Msg, 1;

    -- Lines: quantity, ownership and the quantity still available on the invoice line.
    SELECT TOP (1) @Msg =
        CASE WHEN pl.Id IS NULL THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': the invoice line no longer exists.'
             WHEN l.Quantity <= 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': the quantity must be greater than zero.'
             WHEN pl.DocumentId NOT IN (SELECT PurchaseDocumentId FROM @Inv)
                  THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': the invoice of this line is not linked to the container.'
             WHEN l.OilQtyPerUnit < 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': the oil quantity cannot be negative.'
             END
    FROM @Lines l
    LEFT JOIN purchase.PurchaseDocumentLines pl ON pl.Id = l.PurchaseLineId
    WHERE pl.Id IS NULL OR l.Quantity <= 0 OR l.OilQtyPerUnit < 0 OR pl.DocumentId NOT IN (SELECT PurchaseDocumentId FROM @Inv)
    ORDER BY l.LineNumber;
    IF @Msg IS NOT NULL THROW 69000, @Msg, 1;

    IF EXISTS (SELECT PurchaseLineId FROM @Lines GROUP BY PurchaseLineId HAVING COUNT(*) > 1)
        THROW 69000, 'The same invoice line appears twice in the container.', 1;

    SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - '
                          + CAST(l.Quantity * pl.PackingFormula AS NVARCHAR(20)) + N' base units allocated but only '
                          + CAST(pl.QuantityBase - ISNULL(o.Qty, 0) AS NVARCHAR(20)) + N' remain on invoice line '
                          + CAST(pl.LineNumber AS NVARCHAR(10)) + N' of ' + d.DocumentNumber + N'.'
    FROM @Lines l
    INNER JOIN purchase.PurchaseDocumentLines pl ON pl.Id = l.PurchaseLineId
    INNER JOIN purchase.PurchaseDocuments d      ON d.Id = pl.DocumentId
    INNER JOIN inventory.Items i                 ON i.Id = pl.ItemId
    OUTER APPLY (SELECT Qty = SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                 INNER JOIN logistics.Containers c2 ON c2.Id = cl.ContainerId
                 WHERE cl.PurchaseLineId = l.PurchaseLineId AND c2.Status <> 8 AND (@Id IS NULL OR cl.ContainerId <> @Id)) o
    WHERE l.Quantity * pl.PackingFormula > pl.QuantityBase - ISNULL(o.Qty, 0)
    ORDER BY l.LineNumber;
    IF @Msg IS NOT NULL THROW 69008, @Msg, 1;

    -- Capacity: a warning that the caller can override, never a hard block.
    DECLARE @Capacity INT = @MaxUnits;
    IF @Capacity IS NULL AND @Id IS NOT NULL SELECT @Capacity = MaxUnits FROM logistics.Containers WHERE Id = @Id;
    IF @Capacity IS NULL SELECT @Capacity = MaxUnits FROM masterdata.ContainerTypes WHERE Id = @ContainerTypeId;

    DECLARE @Allocated INT = ISNULL((SELECT SUM(l.Quantity * pl.PackingFormula) FROM @Lines l
                                     INNER JOIN purchase.PurchaseDocumentLines pl ON pl.Id = l.PurchaseLineId), 0);
    IF @Capacity IS NOT NULL AND @Allocated > @Capacity AND ISNULL(@AllowOverCapacity, 0) = 0
    BEGIN
        SET @Msg = N'The container holds ' + CAST(@Capacity AS NVARCHAR(10)) + N' units and ' + CAST(@Allocated AS NVARCHAR(10))
                 + N' are allocated. Confirm to load it above its capacity.';
        THROW 69007, @Msg, 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Id IS NULL
        BEGIN
            DECLARE @Ref NVARCHAR(30), @TypeId INT = (SELECT Id FROM inventory.DocumentTypes WHERE Code = N'CNT');
            EXEC inventory.usp_DocumentType_NextNumber N'CNT', @Ref OUTPUT, @BranchId;

            INSERT INTO logistics.Containers (DocumentTypeId, ContainerRef, ContainerNo, ContainerTypeId, SealNo, CustomsSealNo, Description,
                                              OrderDate, ShippingMethod, CountryOfOrigin, ForwarderId, TransporterId,
                                              ShippingLine, VesselName, VoyageNo, BookingNo, PortOfLoadingId, PortOfDestinationId, FinalDestinationId,
                                              DispatchDate, Eta, FreeDays, GrossWeightKg, VolumeCbm, Packages, BlNo, BlDate, BlNotes,
                                              MaxUnits, BranchId, WarehouseId, TruckNo, WaybillNo, DeclarationNo, FeriNo,
                                              ActualPortArrival, BorderCrossingDate, CustomsReleaseDate, StatusNote, Notes, Status, CreatedBy)
            VALUES (@TypeId, @Ref, @ContainerNo, @ContainerTypeId, @SealNo, @CustomsSealNo, @Description,
                    @OrderDate, @ShippingMethod, @CountryOfOrigin, @ForwarderId, @TransporterId,
                    @ShippingLine, @VesselName, @VoyageNo, @BookingNo, @PortOfLoadingId, @PortOfDestinationId, @FinalDestinationId,
                    @DispatchDate, @Eta, @FreeDays, @GrossWeightKg, @VolumeCbm, @Packages, @BlNo, @BlDate, @BlNotes,
                    @Capacity, @BranchId, @WarehouseId, @TruckNo, @WaybillNo, @DeclarationNo, @FeriNo,
                    @ActualPortArrival, @BorderCrossingDate, @CustomsReleaseDate, @StatusNote, @Notes, 1, @UserId);
            SET @Id = SCOPE_IDENTITY();
            INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId) VALUES (@Id, N'Created', N'Draft ' + @Ref, @UserId);
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

        DELETE FROM logistics.ContainerLines WHERE ContainerId = @Id;
        DELETE FROM logistics.ContainerInvoices WHERE ContainerId = @Id AND PurchaseDocumentId NOT IN (SELECT PurchaseDocumentId FROM @Inv);
        INSERT INTO logistics.ContainerInvoices (ContainerId, PurchaseDocumentId)
        SELECT @Id, v.PurchaseDocumentId FROM @Inv v
        WHERE NOT EXISTS (SELECT 1 FROM logistics.ContainerInvoices ci WHERE ci.ContainerId = @Id AND ci.PurchaseDocumentId = v.PurchaseDocumentId);

        INSERT INTO logistics.ContainerLines (ContainerId, LineNumber, PurchaseDocumentId, PurchaseLineId, ItemId, ItemUnitId,
                                              PackingFormula, Quantity, OilIncluded, OilQtyPerUnit, Notes)
        SELECT @Id, l.LineNumber, pl.DocumentId, l.PurchaseLineId, pl.ItemId, pl.ItemUnitId,
               pl.PackingFormula, l.Quantity, ISNULL(l.OilIncluded, 0),
               CASE WHEN ISNULL(l.OilIncluded, 0) = 1 THEN ISNULL(l.OilQtyPerUnit, i.OilQtyPerUnit) END,
               NULLIF(LTRIM(RTRIM(l.Notes)), N'')
        FROM @Lines l
        INNER JOIN purchase.PurchaseDocumentLines pl ON pl.Id = l.PurchaseLineId
        INNER JOIN inventory.Items i ON i.Id = pl.ItemId;

        -- Draft invoices loaded into a container are received at offload from now on.
        UPDATE d SET ReceiptMode = 2, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        FROM purchase.PurchaseDocuments d
        INNER JOIN @Inv v ON v.PurchaseDocumentId = d.Id
        WHERE d.ReceiptMode = 1;

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
        THROW 69009, 'The container has no items. Load at least one invoice line before confirming.', 1;

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

-- Route events drive the dates, the status and the current location.
CREATE OR ALTER PROCEDURE logistics.usp_Container_AddEvent
    @ContainerId  INT,
    @EventType    NVARCHAR(20),
    @EventDate    DATE,
    @PortId       INT           = NULL,
    @LocationText NVARCHAR(100) = NULL,
    @Notes        NVARCHAR(300) = NULL,
    @UserId       INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @EventType = NULLIF(LTRIM(RTRIM(@EventType)), N'');
    SET @LocationText = NULLIF(LTRIM(RTRIM(@LocationText)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    IF @EventType IS NULL OR @EventType NOT IN (N'Booked', N'Dispatched', N'PortArrival', N'CustomsRelease', N'BorderCrossing', N'Note')
        THROW 69000, 'Event type must be Booked, Dispatched, PortArrival, CustomsRelease, BorderCrossing or Note (the offload writes its own event).', 1;
    IF @EventDate IS NULL THROW 69000, 'The event date is required.', 1;
    IF @PortId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Ports WHERE Id = @PortId) THROW 69000, 'Port not found.', 1;

    DECLARE @Status TINYINT = (SELECT Status FROM logistics.Containers WHERE Id = @ContainerId);
    IF @Status IS NULL THROW 69006, 'Container not found.', 1;
    IF @Status = 8 THROW 69010, 'A cancelled container cannot receive events.', 1;
    IF @Status >= 6 AND @EventType <> N'Note' THROW 69010, 'The container is already offloaded; only notes can be added.', 1;
    IF @Status = 1 AND @EventType <> N'Note' THROW 69010, 'Confirm the container before recording its route.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO logistics.ContainerEvents (ContainerId, EventType, EventDate, PortId, LocationText, Notes, CreatedBy)
        VALUES (@ContainerId, @EventType, @EventDate, @PortId, @LocationText, @Notes, @UserId);

        UPDATE logistics.Containers
        SET DispatchDate       = CASE WHEN @EventType = N'Dispatched'     THEN @EventDate ELSE DispatchDate END,
            ActualPortArrival  = CASE WHEN @EventType = N'PortArrival'    THEN @EventDate ELSE ActualPortArrival END,
            CustomsReleaseDate = CASE WHEN @EventType = N'CustomsRelease' THEN @EventDate ELSE CustomsReleaseDate END,
            BorderCrossingDate = CASE WHEN @EventType = N'BorderCrossing' THEN @EventDate ELSE BorderCrossingDate END,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @ContainerId;

        EXEC logistics.usp_Container_RefreshStatus @ContainerId;

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        VALUES (@ContainerId, N'Event', @EventType + N' on ' + CONVERT(NVARCHAR(10), @EventDate, 23)
                + ISNULL(N' - ' + (SELECT PortName FROM masterdata.Ports WHERE Id = @PortId), ISNULL(N' - ' + @LocationText, N'')), @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 10. Containers: offload = stock in */

-- The goods arrive: stock movements at the LANDED cost of the invoice line, moving average updated,
-- the invoice lines are marked received. A received quantity may be lower than the loaded one (short shipment).
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
    IF @Status NOT IN (3, 4, 5) THROW 69010, 'Only a container that has left the supplier can be offloaded.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 69004, 'This container was modified by another user. Reload the page and try again.', 1;

    IF @WarehouseId IS NULL SET @WarehouseId = @CtWarehouse;
    IF @WarehouseId IS NULL THROW 69000, 'The offloading warehouse is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1 AND BranchId = @BranchId)
        THROW 69000, 'The offloading warehouse is inactive or does not belong to the container branch.', 1;
    IF NOT EXISTS (SELECT 1 FROM logistics.ContainerLines WHERE ContainerId = @Id)
        THROW 69009, 'The container has no items.', 1;

    DECLARE @Msg NVARCHAR(400);

    -- Every invoice must be posted: the landed cost is only known then.
    SELECT TOP (1) @Msg = N'Invoice ' + d.DocumentNumber + N' is not posted yet. Post it before offloading the container.'
    FROM logistics.ContainerInvoices ci
    INNER JOIN purchase.PurchaseDocuments d ON d.Id = ci.PurchaseDocumentId
    WHERE ci.ContainerId = @Id AND d.Status NOT IN (2, 4)
    ORDER BY d.DocumentNumber;
    IF @Msg IS NOT NULL THROW 69010, @Msg, 1;

    SELECT TOP (1) @Msg =
        CASE WHEN cl.Id IS NULL THEN N'A received line does not belong to this container.'
             WHEN r.ReceivedQuantityBase < 0 THEN N'Line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N': the received quantity cannot be negative.'
             WHEN r.ReceivedQuantityBase > cl.QuantityBase THEN N'Line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N': received '
                  + CAST(r.ReceivedQuantityBase AS NVARCHAR(20)) + N' but only ' + CAST(cl.QuantityBase AS NVARCHAR(20)) + N' were loaded.'
             WHEN r.ReceivedQuantityBase <> cl.QuantityBase AND NULLIF(LTRIM(RTRIM(r.VarianceReason)), N'') IS NULL
                  THEN N'Line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N': a reason is required when the received quantity differs from the loaded quantity.'
             END
    FROM @Lines r
    LEFT JOIN logistics.ContainerLines cl ON cl.Id = r.LineId AND cl.ContainerId = @Id
    WHERE cl.Id IS NULL OR r.ReceivedQuantityBase < 0 OR r.ReceivedQuantityBase > cl.QuantityBase
       OR (r.ReceivedQuantityBase <> cl.QuantityBase AND NULLIF(LTRIM(RTRIM(r.VarianceReason)), N'') IS NULL)
    ORDER BY cl.LineNumber;
    IF @Msg IS NOT NULL THROW 69000, @Msg, 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE cl
        SET ReceivedQuantityBase = ISNULL(r.ReceivedQuantityBase, cl.QuantityBase),
            VarianceReason = NULLIF(LTRIM(RTRIM(r.VarianceReason)), N'')
        FROM logistics.ContainerLines cl
        LEFT JOIN @Lines r ON r.LineId = cl.Id
        WHERE cl.ContainerId = @Id;

        -- What really entered stock, with the cost frozen on the invoice line.
        DECLARE @Rec TABLE (LineId INT, ItemId INT, SupplierId INT, QuantityBase INT,
                            UnitCostBase DECIMAL(18,6), FobCostBase DECIMAL(18,6), ExpiryDate DATE);
        INSERT INTO @Rec (LineId, ItemId, SupplierId, QuantityBase, UnitCostBase, FobCostBase, ExpiryDate)
        SELECT cl.Id, cl.ItemId, d.SupplierId, cl.ReceivedQuantityBase,
               ISNULL(pl.UnitCostBase, 0), pl.FobCostBase, pl.ExpiryDate
        FROM logistics.ContainerLines cl
        INNER JOIN purchase.PurchaseDocumentLines pl ON pl.Id = cl.PurchaseLineId
        INNER JOIN purchase.PurchaseDocuments d      ON d.Id = cl.PurchaseDocumentId
        WHERE cl.ContainerId = @Id AND cl.ReceivedQuantityBase > 0;

        -- Moving average per supplier (last supplier / last cost follow the supplier of the goods).
        DECLARE @SupplierId INT;
        DECLARE @R inventory.tvp_ItemReceipt;
        DECLARE suppliers CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT SupplierId FROM @Rec;
        OPEN suppliers; FETCH NEXT FROM suppliers INTO @SupplierId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            DELETE FROM @R;
            INSERT INTO @R (ItemId, QuantityBase, UnitCostBase, FobCostBase)
            SELECT ItemId, QuantityBase, UnitCostBase, FobCostBase FROM @Rec WHERE SupplierId = @SupplierId;
            EXEC inventory.usp_Item_ApplyReceipts @R, @SupplierId, @UserId, 1;
            FETCH NEXT FROM suppliers INTO @SupplierId;
        END
        CLOSE suppliers; DEALLOCATE suppliers;

        DECLARE @MovementDate DATETIME2(3) =
            DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@OffloadedDate AS DATETIME2(3)));

        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, CreatedBy)
        SELECT @MovementDate, r.ItemId, @WarehouseId, @BranchId, r.QuantityBase, r.UnitCostBase,
               N'Purchase', N'CNT', @Id, r.LineId, @Ref, NULL, r.ExpiryDate, @UserId
        FROM @Rec r;

        -- The invoice lines are received for what actually arrived.
        UPDATE pl SET ReceivedQuantityBase = pl.ReceivedQuantityBase + x.Qty
        FROM purchase.PurchaseDocumentLines pl
        INNER JOIN (SELECT cl.PurchaseLineId, Qty = SUM(cl.ReceivedQuantityBase)
                    FROM logistics.ContainerLines cl WHERE cl.ContainerId = @Id AND cl.ReceivedQuantityBase > 0
                    GROUP BY cl.PurchaseLineId) x ON x.PurchaseLineId = pl.Id;

        UPDATE logistics.Containers
        SET OffloadedDate = @OffloadedDate, OffloadedAtUtc = SYSUTCDATETIME(), OffloadedBy = @UserId,
            WarehouseId = @WarehouseId, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO logistics.ContainerEvents (ContainerId, EventType, EventDate, LocationText, Notes, CreatedBy)
        SELECT @Id, N'Offloaded', @OffloadedDate, w.WarehouseName, N'Stock received', @UserId
        FROM masterdata.Warehouses w WHERE w.Id = @WarehouseId;

        EXEC logistics.usp_Container_RefreshStatus @Id;

        DECLARE @Total INT = (SELECT ISNULL(SUM(QuantityBase), 0) FROM @Rec);
        DECLARE @Short INT = (SELECT COUNT(*) FROM logistics.ContainerLines WHERE ContainerId = @Id AND ReceivedQuantityBase < QuantityBase);
        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        VALUES (@Id, N'Offloaded', N'Received ' + CAST(@Total AS NVARCHAR(20)) + N' base unit(s) into '
                + (SELECT WarehouseCode FROM masterdata.Warehouses WHERE Id = @WarehouseId)
                + CASE WHEN @Short > 0 THEN N'; ' + CAST(@Short AS NVARCHAR(10)) + N' line(s) short-shipped' ELSE N'' END, @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Reverses an offload: the movements are reversed, the invoice lines released and the costs replayed.
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

    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg = N'Cannot reverse: ' + i.ItemCode + N' in ' + w.WarehouseCode + N' has only '
                         + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20))
                         + N' left, but this container brought ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
    FROM (SELECT m.ItemId, m.WarehouseId, Qty = SUM(m.QuantityBase)
          FROM inventory.StockMovements m
          WHERE m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = N'CNT' AND m.DocumentId = @Id AND m.IsReversal = 0
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
        WHERE m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = N'CNT' AND m.DocumentId = @Id AND m.IsReversal = 0;

        UPDATE pl SET ReceivedQuantityBase = pl.ReceivedQuantityBase - x.Qty
        FROM purchase.PurchaseDocumentLines pl
        INNER JOIN (SELECT cl.PurchaseLineId, Qty = SUM(cl.ReceivedQuantityBase)
                    FROM logistics.ContainerLines cl WHERE cl.ContainerId = @Id AND cl.ReceivedQuantityBase > 0
                    GROUP BY cl.PurchaseLineId) x ON x.PurchaseLineId = pl.Id;

        DECLARE @Items TABLE (ItemId INT PRIMARY KEY);
        INSERT INTO @Items (ItemId) SELECT DISTINCT ItemId FROM logistics.ContainerLines WHERE ContainerId = @Id;

        UPDATE logistics.ContainerLines SET ReceivedQuantityBase = NULL, VarianceReason = NULL WHERE ContainerId = @Id;
        DELETE FROM logistics.ContainerEvents WHERE ContainerId = @Id AND EventType = N'Offloaded';

        UPDATE logistics.Containers
        SET OffloadedDate = NULL, OffloadedAtUtc = NULL, OffloadedBy = NULL,
            StatusNote = LEFT(N'Offload reversed: ' + @Reason, 200), UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        EXEC logistics.usp_Container_RefreshStatus @Id;

        DECLARE @ItemId INT;
        DECLARE citems CURSOR LOCAL FAST_FORWARD FOR SELECT ItemId FROM @Items;
        OPEN citems; FETCH NEXT FROM citems INTO @ItemId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC inventory.usp_Item_RebuildCosts @ItemId;
            FETCH NEXT FROM citems INTO @ItemId;
        END
        CLOSE citems; DEALLOCATE citems;

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId) VALUES (@Id, N'OffloadCancelled', @Reason, @UserId);

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

    UPDATE logistics.Containers
    SET Status = 7, ClosedAtUtc = SYSUTCDATETIME(), ClosedBy = @UserId, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
    INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId) VALUES (@Id, N'Closed', N'Container closed', @UserId);
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
    IF @Status >= 6 THROW 69010, 'An offloaded or closed container cannot be cancelled. Reverse the offload first.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 69004, 'This container was modified by another user. Reload the page and try again.', 1;

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

    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE FROM logistics.ContainerLines WHERE ContainerId = @Id;
        DELETE FROM logistics.ContainerInvoices WHERE ContainerId = @Id;
        DELETE FROM logistics.ContainerEvents WHERE ContainerId = @Id;
        DELETE FROM logistics.ContainerFiles WHERE ContainerId = @Id;
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

/* ------------------------------------------------------------------ Attachments */

CREATE OR ALTER PROCEDURE logistics.usp_ContainerFile_Add
    @ContainerId      INT,
    @AttachmentTypeId INT            = NULL,
    @FileName         NVARCHAR(255),
    @ContentType      NVARCHAR(100),
    @SizeBytes        INT,
    @Content          VARBINARY(MAX),
    @Note             NVARCHAR(300)  = NULL,
    @DocumentDate     DATE           = NULL,
    @UserId           INT            = NULL,
    @NewId            INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @ContainerId) THROW 69006, 'Container not found.', 1;
    IF @SizeBytes IS NULL OR @SizeBytes <= 0 THROW 69000, 'The file is empty.', 1;
    IF @AttachmentTypeId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Id = @AttachmentTypeId)
        THROW 69000, 'Attachment type not found.', 1;

    INSERT INTO logistics.ContainerFiles (ContainerId, AttachmentTypeId, FileName, ContentType, SizeBytes, Content, Note, DocumentDate, CreatedBy)
    VALUES (@ContainerId, @AttachmentTypeId, @FileName, @ContentType, @SizeBytes, @Content, NULLIF(LTRIM(RTRIM(@Note)), N''), @DocumentDate, @UserId);
    SET @NewId = SCOPE_IDENTITY();

    INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
    VALUES (@ContainerId, N'Updated', N'Attachment added: ' + @FileName, @UserId);
END
GO

CREATE OR ALTER PROCEDURE logistics.usp_ContainerFile_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, ContainerId, AttachmentTypeId, FileName, ContentType, SizeBytes, Content, Note, DocumentDate, CreatedAtUtc, CreatedBy
    FROM logistics.ContainerFiles WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE logistics.usp_ContainerFile_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ContainerId INT, @FileName NVARCHAR(255);
    SELECT @ContainerId = ContainerId, @FileName = FileName FROM logistics.ContainerFiles WHERE Id = @Id;
    IF @ContainerId IS NULL THROW 69006, 'File not found.', 1;
    DELETE FROM logistics.ContainerFiles WHERE Id = @Id;
    INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
    VALUES (@ContainerId, N'Updated', N'Attachment removed: ' + @FileName, @UserId);
END
GO

/* ================================================================== 11. Shortage plans: expected stock follows the invoices and the containers

   Until now only open purchase orders counted, so the quantity vanished from the plan as soon as the order
   became an invoice, while the goods were still at sea. From now on:
     Outstanding = open PO remaining + posted invoices (ReceiptMode 2) not yet received - what is in transit
     Transit     = quantity loaded on containers In Transit / At Port / Cleared and not yet received
   ================================================================== */

CREATE OR ALTER FUNCTION inventory.fn_Shortage_Live (@WarehouseId INT, @MonthsOfHistory INT)
RETURNS TABLE
AS
RETURN
(
    SELECT i.Id AS ItemId, i.ItemCode, i.ItemName, i.BrandId, i.ItemFamilyId, i.IsBivac,
           i.DefaultSupplierId, i.LastSupplierId, i.MinQuantity, i.MaxQuantity, i.LastCost, i.AverageCost, i.LeadTimeDays,
           ItemPcPerContainer = i.PcPerContainer,
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
            OR (dt.Code = N'PINV' AND d.Status = 2 AND d.ReceiptMode = 2))
    ) po
    OUTER APPLY
    (
        -- loaded into a container that has left the supplier and is not offloaded yet
        SELECT Transit = SUM(cl.QuantityBase - ISNULL(cl.ReceivedQuantityBase, 0))
        FROM logistics.ContainerLines cl
        INNER JOIN logistics.Containers c             ON c.Id = cl.ContainerId
        INNER JOIN purchase.PurchaseDocumentLines pl  ON pl.Id = cl.PurchaseLineId
        WHERE cl.ItemId = i.Id AND c.Status IN (3, 4, 5)
          AND ISNULL(c.WarehouseId, pl.WarehouseId) = @WarehouseId
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
    WHERE i.IsActive = 1
);
GO

/* ================================================================== 12. Permissions */

MERGE security.Permissions AS target
USING
(
    VALUES
        (N'containers.view',         N'View Containers',          N'Containers',  N'See the container list and details.',                         1300),
        (N'containers.create',       N'Create Containers',        N'Containers',  N'Create and edit containers and their loading plan.',          1310),
        (N'containers.confirm',      N'Confirm Containers',       N'Containers',  N'Confirm the loading plan of a container.',                    1320),
        (N'containers.offload',      N'Offload Containers',       N'Containers',  N'Offload a container: the goods enter stock.',                 1330),
        (N'containers.cancel',       N'Cancel Containers',        N'Containers',  N'Cancel a container or reverse an offload.',                   1340),
        (N'containers.close',        N'Close Containers',         N'Containers',  N'Close an offloaded container.',                               1350),
        (N'containers.delete',       N'Delete Containers',        N'Containers',  N'Delete draft containers.',                                    1360),
        (N'containers.overcapacity', N'Load Above Capacity',      N'Containers',  N'Load a container above the capacity of its type.',            1370),
        (N'masterdata.containertypes.manage', N'Manage container types', N'Master Data', N'Define container types and their capacity.',           1380),
        (N'masterdata.ports.manage',          N'Manage ports',           N'Master Data', N'Define ports, borders and inland destinations.',       1390),
        (N'masterdata.attachmenttypes.manage', N'Manage attachment types', N'Master Data', N'Define the document types used by attachments.',     1400)
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
WHERE (p.Code LIKE N'containers.%' OR p.Code IN (N'masterdata.containertypes.manage', N'masterdata.ports.manage', N'masterdata.attachmenttypes.manage'))
  AND (r.IsSystem = 1
       OR (r.Name = N'Manager' AND p.Code IN (N'containers.view', N'containers.create', N'containers.confirm', N'containers.offload')))
  AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);
GO

/* ================================================================== 13. Check */

SELECT TypeCode, TypeName, MaxUnits FROM masterdata.ContainerTypes ORDER BY TypeCode;
SELECT PortCode, PortName, CountryCode, Kind FROM masterdata.Ports ORDER BY Kind, PortCode;
SELECT Category, SubType FROM masterdata.AttachmentTypes ORDER BY SortOrder;
SELECT Code, Name, Family, NumberPrefix, NumberLength, YearInNumber, NumberPerBranch FROM inventory.DocumentTypes WHERE Code = N'CNT';
SELECT Code, Name, Module, SortOrder FROM security.Permissions WHERE Code LIKE N'containers.%' OR Code LIKE N'masterdata.%types.manage' OR Code = N'masterdata.ports.manage' ORDER BY SortOrder;
SELECT ObjectCount = COUNT(*) FROM sys.objects WHERE SCHEMA_NAME(schema_id) = N'logistics';
PRINT 'Script 24 applied: containers, receipt mode on purchase invoices, shortage plans updated.';
GO
