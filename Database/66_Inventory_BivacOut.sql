SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 66: BIVAC OUT - A STOCK DOCUMENT THAT HOLDS BIVAC ITEMS ONLY

   The business owner: "BIVAC must be created as inventory out, must let me choose which BIVAC item to choose in
   order to make the inventory out for it." BIVAC Out is a third stock document next to Inventory In and Inventory
   Out, with its own menu entry, list, numbers and permissions. It takes units OUT of stock exactly as an Inventory
   Out does (company-wide average cost, fixed at posting, never typed; refused when stock is short, 62007; a cancel
   writes the reverse movements); the only difference is that every line must be an item flagged "BIVAC Item"
   (inventory.Items.IsBivac, script 11). It is not linked to a shipment: the BIVAC certificate or the container
   number goes in Reference No., and the certificate can be attached as a document.

   Rule
     - THE RULE LIVES ON THE DOCUMENT TYPE: inventory.DocumentTypes.BivacItemsOnly (BIT NOT NULL, default 0). 1 = every
       line of a document of this type must be a BIVAC item. Only BIV_OUT has 1; Configuration > Document Types shows
       it read-only (usp_DocumentType_Update does not change it). Nothing reads the code BIV_OUT: a later type with
       BivacItemsOnly = 1 behaves the same.
     - DOCUMENT TYPE BIV_OUT "BIVAC Out" (inserted once, never overwritten): family Inventory, stock direction -1, prefix
       BIV-, numbered per branch at the FIRST SAVE (NumberOnPost 0) - BIV-BR-002-000001 -, no reason required, cost
       pricing that cannot be typed (DefaultPricing Cost, PriceEditable 0); number length and year as INV_OUT has them.
       The procedures of Inventory In / Out (Save, Post, Cancel, Delete, Search, Get, files) already work for any
       active type of family Inventory: they look at the stock direction, never at the codes.
     - SAVE (usp_StockDocument_ValidateInput) AND POST (usp_StockDocument_Post) refuse a line whose item is not BIVAC
       when the type is BivacItemsOnly: 62000 'Line {n}: {item code} is not a BIVAC item. A BIVAC Out holds BIVAC items
       only.' (the type's name). Post checks again because an item can be un-flagged after the draft was saved.
     - THE ITEM PICKER (usp_Item_Lookup): new @BivacOnly (default 0): 1 = only items flagged BIVAC (plus @IncludeId, so
       a saved line still resolves); the rows say IsBivac. The pages load the list ONCE and filter it in the browser,
       and the API never sent @Top, so the default of 20 rows silently hid every item after the 20th from every line
       dropdown: @Top now defaults to NULL = every matching item (a caller that sends @Top still gets at most that).
     - THE EXCEL IMPORT CHECK (sales.usp_InvoiceImport_Validate): a row of a BivacItemsOnly type (the row's own type,
       else the page's) whose item is not BIVAC is an Error row: '{item code} is not a BIVAC item.'
     - ATTACHMENTS: BIV_OUT is a document kind (masterdata.fn_AttachmentDocumentKinds, "BIVAC Out"); when BIV_OUT is
       first inserted it is used for the attachment types Inventory Out is used for (copied once: a kind an
       administrator takes off a type later stays off). An administrator can add a "BIVAC certificate" type in
       Master Data > Attachment Types.
     - PERMISSIONS inventory.bivacout.view / create / post / cancel / delete (module Inventory, SortOrder 810-850, next
       to Inventory Out's 760-800), with PermissionCatalog.cs's texts; granted to the system roles only, as the
       start-up catalog sync does - other roles get them through Users & Permissions > Role Permissions.
     - UNCHANGED: Inventory In / Out (behaviour, OUT- / IN- numbering, reasons, existing documents), the average cost
       method, the BIV charge type, what IsBivac means.

   Objects
     inventory.DocumentTypes.BivacItemsOnly (new column)
     inventory.DocumentTypes: BIV_OUT (new row; on its first insert only, its "Used for" rows)
     security.Permissions: inventory.bivacout.* (new rows)
     masterdata.fn_AttachmentDocumentKinds (re-created from its current body, script 64: + BIV_OUT)
     inventory.usp_DocumentType_List (re-created from its current body, script 22: + BivacItemsOnly)
     inventory.usp_Item_Lookup (re-created from its current body, script 30: + @BivacOnly, + IsBivac, @Top NULL = all)
     inventory.usp_StockDocument_ValidateInput (re-created from its current body, script 31: + the BIVAC line check)
     inventory.usp_StockDocument_Post (re-created from its current body, script 23: + the BIVAC line check)
     sales.usp_InvoiceImport_Validate (re-created from its current body, script 48: + the BIVAC row check)

   Errors: no new number. 62000 (inventory validation) carries the BIVAC line message.

   Requires scripts 11, 15, 22, 23, 30, 31, 48, 52, 55 and 64. Idempotent, additive: re-applied at every API start-up
   through Schema.sql, and builds a brand-new empty database (the column before any procedure that reads it).
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF COL_LENGTH(N'inventory.Items', N'IsBivac') IS NULL
   OR COL_LENGTH(N'inventory.DocumentTypes', N'YearInNumber') IS NULL
   OR OBJECT_ID(N'inventory.StockDocuments', N'U') IS NULL
   OR OBJECT_ID(N'inventory.usp_StockDocument_ValidateInput', N'P') IS NULL
   OR OBJECT_ID(N'sales.usp_InvoiceImport_Validate', N'P') IS NULL
   OR OBJECT_ID(N'masterdata.AttachmentTypeUsages', N'U') IS NULL
   OR OBJECT_ID(N'masterdata.usp_AttachmentType_CheckForKind', N'P') IS NULL
   OR OBJECT_ID(N'purchase.GoodsReceiptFiles', N'U') IS NULL
BEGIN
    RAISERROR ('Run scripts 11, 15, 22, 23, 30, 31, 48, 52, 55 and 64 before this script.', 16, 1);
    SET NOEXEC ON;
END
GO

/* ================================================================== 1. The rule's home: BivacItemsOnly on the document type */

-- Before any procedure below reads it. Every existing type gets 0: nothing changes for them.
IF COL_LENGTH(N'inventory.DocumentTypes', N'BivacItemsOnly') IS NULL
BEGIN
    ALTER TABLE inventory.DocumentTypes ADD
        BivacItemsOnly BIT NOT NULL CONSTRAINT DF_DocumentTypes_BivacItemsOnly DEFAULT (0);   -- 1 = every line must be a BIVAC item (BIV_OUT)
    PRINT 'DocumentTypes: added BivacItemsOnly';
END
GO

/* ================================================================== 2. Attachments: the document kind BIV_OUT */

-- Re-created (66) from the body of script 64: + BIV_OUT (BIVAC Out), after Inventory Out.
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
             (N'BIV_OUT',   N'BIVAC Out',         N'BIVAC Out documents',     105)) k (Code, Name, Noun, SortOrder);   -- (66)
GO

/* ================================================================== 3. Document type BIV_OUT */

-- INSERTED ONCE, NEVER OVERWRITTEN: whatever an administrator changes later on Configuration > Document Types (name,
-- prefix, length, active) stays. Numbered per branch at the first save, like Inventory Out: BIV-BR-002-000001. The
-- number length and the year segment are Inventory Out's.
-- THE FIRST INSERT ONLY (the OUTPUT of the MERGE) copies Inventory Out's "Used for" rows to BIV_OUT, so its upload
-- dialog offers what Inventory Out's offers ("Other", "Delivery Note", ...). Never again: a kind an administrator
-- takes off a type stays off.
SET XACT_ABORT ON;
BEGIN TRY
    BEGIN TRANSACTION;   -- the row and its "Used for" rows together, or neither

    DECLARE @BivInserted TABLE (Id INT NOT NULL);

    MERGE inventory.DocumentTypes AS t
    USING (SELECT Code = N'BIV_OUT', Name = N'BIVAC Out', Family = N'Inventory', StockDirection = CAST(-1 AS SMALLINT),
                  NumberPrefix = N'BIV-', NumberOnPost = CAST(0 AS BIT), RequiresReason = CAST(0 AS BIT),
                  DefaultPricing = N'Cost', PriceEditable = CAST(0 AS BIT), NumberPerBranch = CAST(1 AS BIT),
                  YearInNumber = ISNULL((SELECT YearInNumber FROM inventory.DocumentTypes WHERE Code = N'INV_OUT'), CAST(0 AS BIT)),
                  NumberLength = ISNULL((SELECT NumberLength FROM inventory.DocumentTypes WHERE Code = N'INV_OUT'), CAST(6 AS TINYINT)),
                  IsActive = CAST(1 AS BIT), BivacItemsOnly = CAST(1 AS BIT)) AS s
    ON t.Code = s.Code
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (Code, Name, Family, StockDirection, NumberPrefix, NumberOnPost, RequiresReason,
                DefaultPricing, PriceEditable, NumberPerBranch, YearInNumber, NumberLength, IsActive, BivacItemsOnly)
        VALUES (s.Code, s.Name, s.Family, s.StockDirection, s.NumberPrefix, s.NumberOnPost, s.RequiresReason,
                s.DefaultPricing, s.PriceEditable, s.NumberPerBranch, s.YearInNumber, s.NumberLength, s.IsActive, s.BivacItemsOnly)
    OUTPUT inserted.Id INTO @BivInserted (Id);

    IF EXISTS (SELECT 1 FROM @BivInserted)
    BEGIN
        INSERT INTO masterdata.AttachmentTypeUsages (AttachmentTypeId, DocumentKind)
        SELECT u.AttachmentTypeId, N'BIV_OUT'
        FROM masterdata.AttachmentTypeUsages u
        WHERE u.DocumentKind = N'INV_OUT'
          AND NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypeUsages x WHERE x.AttachmentTypeId = u.AttachmentTypeId AND x.DocumentKind = N'BIV_OUT');
        DECLARE @Copied INT = @@ROWCOUNT;

        PRINT 'Document type BIV_OUT (BIVAC Out) created; it uses the attachment types of Inventory Out ('
              + CAST(@Copied AS NVARCHAR(10)) + ' type(s)).';
    END

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
SET XACT_ABORT OFF;
GO

/* ================================================================== 4. Permissions */

-- The texts are PermissionCatalog.cs's (the start-up sync copies them over). Granted to the SYSTEM ROLES only, as the
-- start-up sync grants every permission (it would do it at the next start anyway): the other roles get BIVAC Out
-- through Users & Permissions > Role Permissions, never by default.
SET XACT_ABORT ON;
BEGIN TRY
    BEGIN TRANSACTION;

    MERGE security.Permissions AS target
    USING
    (
        VALUES
            (N'inventory.bivacout.view',   N'View BIVAC Out',   N'Inventory', N'See BIVAC Out documents.',                       810),
            (N'inventory.bivacout.create', N'Create BIVAC Out', N'Inventory', N'Create and edit draft BIVAC Out documents.',     820),
            (N'inventory.bivacout.post',   N'Post BIVAC Out',   N'Inventory', N'Post BIVAC Out documents (removes stock).',      830),
            (N'inventory.bivacout.cancel', N'Cancel BIVAC Out', N'Inventory', N'Cancel posted BIVAC Out documents (reversal).',  840),
            (N'inventory.bivacout.delete', N'Delete BIVAC Out', N'Inventory', N'Delete draft BIVAC Out documents.',              850)
    ) AS source (Code, Name, Module, Description, SortOrder)
    ON target.Code = source.Code
    WHEN MATCHED AND (target.Name <> source.Name OR target.Module <> source.Module
                      OR ISNULL(target.Description, N'') <> source.Description OR target.SortOrder <> source.SortOrder) THEN
        UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (Code, Name, Module, Description, SortOrder)
        VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder);

    INSERT INTO security.RolePermissions (RoleId, PermissionId)
    SELECT r.Id, p.Id
    FROM security.Roles r
    CROSS JOIN security.Permissions p
    WHERE r.IsSystem = 1
      AND p.Code LIKE N'inventory.bivacout.%'
      AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
SET XACT_ABORT OFF;
GO

/* ================================================================== 5. Document types: + BivacItemsOnly */

-- Re-created (66) from the body of script 22: + BivacItemsOnly (the pages read the rule from here).
CREATE OR ALTER PROCEDURE inventory.usp_DocumentType_List
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, Code, Name, Family, StockDirection, NumberPrefix, NextNumber, NumberLength, NumberOnPost,
           RequiresReason, DefaultPricing, PriceEditable, NumberPerBranch, YearInNumber, IsActive, UpdatedAtUtc, UpdatedBy, RowVersion,
           BivacItemsOnly   -- (66) 1 = every line must be a BIVAC item
    FROM inventory.DocumentTypes
    ORDER BY Family, Code;
END
GO

/* ================================================================== 6. The item picker: BIVAC items only, and no 20-row cut */

-- Re-created (66) from the body of script 30: + @BivacOnly, + IsBivac in the rows, @Top NULL = every item.
CREATE OR ALTER PROCEDURE inventory.usp_Item_Lookup
    @Search     NVARCHAR(200) = NULL,
    @ActiveOnly BIT           = 1,
    @IncludeId  INT           = NULL,
    @Top        INT           = NULL,   -- (66) NULL = every matching item (it was 20: see below)
    /* 1 = only items with a unit that may be sold. The sales invoice passes it; everything else
       leaves it 0 and sees every item, because an inventory count or a purchase is not a sale. */
    @SalesOnly  BIT           = 0,
    /* (66) 1 = only items flagged "BIVAC Item" (inventory.Items.IsBivac): the lines of a document type whose
       BivacItemsOnly is 1 (BIVAC Out). 0 = every item, as before. */
    @BivacOnly  BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @SalesOnly = ISNULL(@SalesOnly, 0);
    SET @BivacOnly = ISNULL(@BivacOnly, 0);
    /* (66) NO CUT BY DEFAULT. The pages load this list ONCE, without a search, and filter it in the browser; the
       API never sends @Top. The old default of 20 (at most 200) therefore hid every item after the 20th from
       every line dropdown. NULL now means every matching item; a caller that sends @Top gets at most that. */
    IF @Top IS NULL OR @Top < 1 SET @Top = 2147483647;

    /* THE REPORTED UNIT FOLLOWS THE FILTER. With @SalesOnly the picker should land on a unit it is
       allowed to sell, so the sales unit is preferred over the base one; the base unit is still the
       fallback, and is what every other caller gets. */
    SELECT TOP (@Top) i.Id, i.ItemCode, i.ItemName, i.IsActive,
           ut.UnitTypeName AS BaseUnitName, bu.Id AS BaseUnitId,
           i.IsBivac   -- (66)
    FROM inventory.Items i
    OUTER APPLY (
        SELECT TOP (1) u.Id, u.UnitTypeId
        FROM inventory.ItemUnits u
        WHERE u.ItemId = i.Id
          AND (@SalesOnly = 0 OR u.IsSalesUnit = 1)
        ORDER BY CASE WHEN @SalesOnly = 1 AND u.IsSalesUnit = 1 THEN 0
                      WHEN u.IsBaseUnit = 1 THEN 1
                      ELSE 2 END, u.Id
    ) bu
    LEFT JOIN masterdata.UnitTypes ut ON ut.Id = bu.UnitTypeId
    WHERE (@ActiveOnly = 0 OR i.IsActive = 1 OR i.Id = @IncludeId)
      AND (@Search IS NULL OR i.ItemCode LIKE N'%' + @Search + N'%' OR i.ItemName LIKE N'%' + @Search + N'%')
      /* AN ITEM WITH NO SELLABLE UNIT IS NOT OFFERED - except the one the caller names with
         @IncludeId, so a saved line whose item was since taken off sale still resolves. */
      AND (@SalesOnly = 0 OR i.Id = @IncludeId
           OR EXISTS (SELECT 1 FROM inventory.ItemUnits su WHERE su.ItemId = i.Id AND su.IsSalesUnit = 1))
      /* (66) BIVAC ITEMS ONLY when asked - again except the one named by @IncludeId, so a saved line whose item
         was since un-flagged still resolves (Save and Post refuse it with 62000). */
      AND (@BivacOnly = 0 OR i.IsBivac = 1 OR i.Id = @IncludeId)
    ORDER BY CASE WHEN i.ItemCode LIKE @Search + N'%' THEN 0 ELSE 1 END, i.ItemCode;
END
GO

/* ================================================================== 7. Save: a BIVAC-only type takes BIVAC items only */

-- Re-created (66) from the body of script 31: + the BIVAC line check of a BivacItemsOnly type.
CREATE OR ALTER PROCEDURE inventory.usp_StockDocument_ValidateInput
    @DocumentTypeCode NVARCHAR(20),
    @DocumentDate     DATE,
    @BranchId         INT,
    @WarehouseId      INT = NULL,
    @ReasonId         INT,
    @Lines            inventory.tvp_StockDocumentLine READONLY,
    @DocumentTypeId   INT OUTPUT,
    @StockDirection   SMALLINT OUTPUT,
    @CurrencyId       INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RequiresReason BIT, @BivacOnly BIT, @TypeName NVARCHAR(100);
    SELECT @DocumentTypeId = Id, @StockDirection = StockDirection, @RequiresReason = RequiresReason,
           @BivacOnly = BivacItemsOnly, @TypeName = Name   -- (66)
    FROM inventory.DocumentTypes WHERE Code = @DocumentTypeCode AND Family = N'Inventory' AND IsActive = 1;
    IF @DocumentTypeId IS NULL
        THROW 62008, 'Document type not found, inactive, or not an inventory document.', 1;

    IF @DocumentDate IS NULL THROW 62000, 'Document Date is required.', 1;
    /* ONE DAY OF TOLERANCE, because this compares a LOCAL date against a UTC one. The date on the
       document is the one the reader sees on their own clock; SYSUTCDATETIME() is the server's in
       UTC. East of Greenwich the two disagree for the first hours after midnight - at 00:20 in
       Beirut (UTC+3) it is still yesterday in UTC, so a document dated today was refused as being
       in the future. A day covers every offset without letting a genuinely future date through by
       more than one. */
    IF @DocumentDate > DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE))
        THROW 62000, 'Document Date cannot be in the future.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 62008, 'Branch not found or inactive.', 1;
    IF @WarehouseId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1 AND BranchId = @BranchId)
        THROW 62008, 'The default warehouse must be an active warehouse of the selected branch.', 1;
    IF @RequiresReason = 1 AND @ReasonId IS NULL THROW 62000, 'Reason is required.', 1;
    IF @ReasonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.StockReasons
                                             WHERE Id = @ReasonId AND IsActive = 1
                                               AND (AppliesTo = N'Both' OR (AppliesTo = N'In' AND @StockDirection = 1) OR (AppliesTo = N'Out' AND @StockDirection = -1)))
        THROW 62008, 'Reason not found, inactive, or not applicable to this document type.', 1;

    SELECT @CurrencyId = Id FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1;
    IF @CurrencyId IS NULL THROW 62008, 'No active base currency is configured.', 1;

    -- Per-line checks: the first failing line produces the message.
    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg =
        CASE WHEN i.Id IS NULL THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item not found.'
             WHEN i.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item ' + i.ItemCode + N' is inactive.'
             -- (66) a BIVAC-only type (BIVAC Out) takes BIVAC items only
             WHEN @BivacOnly = 1 AND i.IsBivac = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode
                  + N' is not a BIVAC item. A ' + @TypeName + N' holds BIVAC items only.'
             WHEN iu.Id IS NULL THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': the unit does not belong to item ' + i.ItemCode + N'.'
             WHEN w.Id IS NULL OR w.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse not found or inactive.'
             WHEN w.BranchId <> @BranchId THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is not available for the selected branch.'
             WHEN l.Quantity IS NULL OR l.Quantity <= 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': quantity must be greater than zero.'
             WHEN l.UnitCost IS NOT NULL AND l.UnitCost < 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': unit cost cannot be negative.'
        END
    FROM @Lines l
    LEFT JOIN inventory.Items i       ON i.Id = l.ItemId
    LEFT JOIN inventory.ItemUnits iu  ON iu.Id = l.ItemUnitId AND iu.ItemId = l.ItemId
    LEFT JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
    WHERE i.Id IS NULL OR i.IsActive = 0 OR (@BivacOnly = 1 AND i.IsBivac = 0) OR iu.Id IS NULL OR w.Id IS NULL OR w.IsActive = 0 OR w.BranchId <> @BranchId
       OR l.Quantity IS NULL OR l.Quantity <= 0 OR (l.UnitCost IS NOT NULL AND l.UnitCost < 0)
    ORDER BY l.LineNumber;

    IF @Msg IS NOT NULL THROW 62000, @Msg, 1;
END
GO

/* ================================================================== 8. Post: the same check (the item may have changed since the save) */

-- Re-created (66) from the body of script 23: + the BIVAC line check of a BivacItemsOnly type.
CREATE OR ALTER PROCEDURE inventory.usp_StockDocument_Post
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Direction SMALLINT, @Number NVARCHAR(30), @DocumentDate DATE, @BranchId INT, @ReasonCode NVARCHAR(20);
        DECLARE @BivacOnly BIT, @TypeName NVARCHAR(100);   -- (66)

        SELECT @Status = d.Status, @TypeCode = dt.Code, @Direction = dt.StockDirection, @Number = d.DocumentNumber,
               @DocumentDate = d.DocumentDate, @BranchId = d.BranchId, @ReasonCode = r.ReasonCode,
               @BivacOnly = dt.BivacItemsOnly, @TypeName = dt.Name   -- (66)
        FROM inventory.StockDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        LEFT  JOIN inventory.StockReasons r ON r.Id = d.ReasonId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 62006, 'Document not found.', 1;
        IF @Status <> 1 THROW 62010, 'Only draft documents can be posted.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.StockDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF NOT EXISTS (SELECT 1 FROM inventory.StockDocumentLines WHERE DocumentId = @Id)
            THROW 62009, 'The document has no lines. Add at least one item before posting.', 1;

        DECLARE @Msg NVARCHAR(400);
        SELECT TOP (1) @Msg =
            CASE WHEN i.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item ' + i.ItemCode + N' is inactive.'
                 -- (66) again at posting: the item may have been un-flagged since the draft was saved
                 WHEN @BivacOnly = 1 AND i.IsBivac = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode
                      + N' is not a BIVAC item. A ' + @TypeName + N' holds BIVAC items only.'
                 WHEN w.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is inactive.'
                 WHEN w.BranchId <> @BranchId THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is not in the document branch.' END
        FROM inventory.StockDocumentLines l
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id AND (i.IsActive = 0 OR (@BivacOnly = 1 AND i.IsBivac = 0) OR w.IsActive = 0 OR w.BranchId <> @BranchId)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 62000, @Msg, 1;

        IF @Direction = -1
        BEGIN
            UPDATE l SET UnitCost = ISNULL(inventory.fn_AverageCost(l.ItemId), 0) * l.PackingFormula
            FROM inventory.StockDocumentLines l WHERE l.DocumentId = @Id;

            SELECT TOP (1) @Msg = N'Insufficient stock for ' + i.ItemCode + N' in ' + w.WarehouseCode + N': available '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N', required ' + CAST(x.Qty AS NVARCHAR(20)) + N' (base units).'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM inventory.StockDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 62007, @Msg, 1;

            UPDATE d SET TotalCost = x.Cost
            FROM inventory.StockDocuments d
            CROSS APPLY (SELECT ISNULL(SUM(LineTotal), 0) AS Cost FROM inventory.StockDocumentLines WHERE DocumentId = @Id) x
            WHERE d.Id = @Id;
        END

        IF @Number IS NULL
            EXEC inventory.usp_DocumentType_NextNumber @TypeCode, @Number OUTPUT, @BranchId;

        IF @Direction = 1
        BEGIN
            DECLARE @R inventory.tvp_ItemReceipt;
            INSERT INTO @R (ItemId, QuantityBase, UnitCostBase, FobCostBase)
            SELECT l.ItemId, l.QuantityBase, CASE WHEN l.PackingFormula > 0 THEN l.UnitCost / l.PackingFormula ELSE l.UnitCost END, NULL
            FROM inventory.StockDocumentLines l WHERE l.DocumentId = @Id;
            EXEC inventory.usp_Item_ApplyReceipts @R, NULL, @UserId, 0;      -- average yes, last / FOB cost no
        END

        DECLARE @MovementDate DATETIME2(3) =
            DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@DocumentDate AS DATETIME2(3)));

        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, CreatedBy)
        SELECT @MovementDate, l.ItemId, l.WarehouseId, @BranchId, @Direction * l.QuantityBase,
               CASE WHEN l.PackingFormula > 0 THEN l.UnitCost / l.PackingFormula END,
               N'Inventory', @TypeCode, @Id, l.Id, @Number, @ReasonCode, l.ExpiryDate, @UserId
        FROM inventory.StockDocumentLines l
        WHERE l.DocumentId = @Id;

        UPDATE inventory.StockDocuments
        SET DocumentNumber = @Number, Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        DECLARE @LineCount INT = (SELECT COUNT(*) FROM inventory.StockDocumentLines WHERE DocumentId = @Id);
        INSERT INTO inventory.StockDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@Id, N'Posted', N'Posted as ' + @Number + N' - ' + CAST(@LineCount AS NVARCHAR(10)) + N' line(s) written to the stock ledger', @UserId);

        COMMIT TRANSACTION;
        SELECT @Number AS DocumentNumber;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 9. Excel import: a BIVAC-only type refuses other items */

-- Re-created (66) from the body of script 48: + ErrB, the BIVAC row check of a BivacItemsOnly type (the row's own
-- type, else the page's). The rows returned keep their columns.
CREATE OR ALTER PROCEDURE sales.usp_InvoiceImport_Validate
    @BranchId            INT,
    @DefaultWarehouseId  INT,
    @PriceListId         INT           = NULL,  -- NULL = cost mode (inventory / purchase): Unit Price column = cost, no price list checks
    @AllowPriceOverride  BIT           = 0,
    @MaxDiscountPercent  DECIMAL(9,4)  = 100,
    @Rows                sales.tvp_InvoiceImportRow READONLY,
    @CheckStock          BIT           = 0,     -- 1 = cumulative stock check per item + warehouse (outgoing documents)
    @DocumentTypeCode    NVARCHAR(20)  = NULL   -- the page's document type; rows for another type become Errors
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 61008, 'Branch not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @DefaultWarehouseId AND IsActive = 1 AND BranchId = @BranchId)
        THROW 61008, 'The default warehouse is not an active warehouse of the selected branch.', 1;
    IF @PriceListId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE Id = @PriceListId AND IsActive = 1)
        THROW 61008, 'Price list not found or inactive.', 1;
    IF @MaxDiscountPercent IS NULL OR @MaxDiscountPercent < 0 SET @MaxDiscountPercent = 0;
    SET @CheckStock = ISNULL(@CheckStock, 0);
    SET @DocumentTypeCode = NULLIF(LTRIM(RTRIM(@DocumentTypeCode)), N'');

    DECLARE @PageTypeName NVARCHAR(100), @Family NVARCHAR(20), @PageBivacOnly BIT = 0;
    IF @DocumentTypeCode IS NOT NULL
    BEGIN
        SELECT @PageTypeName = Name, @Family = Family, @PageBivacOnly = BivacItemsOnly FROM inventory.DocumentTypes WHERE Code = @DocumentTypeCode;
        IF @PageTypeName IS NULL THROW 61008, 'Document type not found.', 1;
    END
    -- Unit preference: 1 = sales unit first, 2 = purchase unit first, 0 = base unit first.
    DECLARE @UnitPref TINYINT = CASE WHEN @Family = N'Sales' OR (@Family IS NULL AND @PriceListId IS NOT NULL) THEN 1
                                     WHEN @Family = N'Purchase' THEN 2 ELSE 0 END;

    DECLARE @Today DATE = CAST(SYSUTCDATETIME() AS DATE);

    ;WITH resolved AS
    (
        SELECT r.RowNumber,
               ItemRef      = NULLIF(LTRIM(RTRIM(r.ItemRef)), N''),
               UnitName     = NULLIF(LTRIM(RTRIM(r.UnitName)), N''),
               WarehouseRef = NULLIF(LTRIM(RTRIM(r.WarehouseRef)), N''),
               r.Quantity, r.RawQuantity, ManualPrice = r.UnitPrice, r.DiscountPercent, r.ExpiryDate, r.RawExpiryDate,
               Notes        = NULLIF(LTRIM(RTRIM(r.Notes)), N''),
               RowTypeRef   = NULLIF(LTRIM(RTRIM(r.DocumentTypeCode)), N''),
               rt.RowTypeCode, rt.RowTypeName, rt.RowTypeBivacOnly,
               it.ItemId, it.ItemCode, it.ItemName, it.ItemActive, it.BarcodeUnitId, it.ItemIsBivac,
               u.ItemUnitId, u.UnitTypeName, u.PackingFormula,
               w.WarehouseId, w.WarehouseCode, w.WarehouseName, w.WarehouseActive, w.WarehouseBranchId,
               pr.BranchPrice, pr.AllBranchesPrice
        FROM @Rows r
        OUTER APPLY
        (
            SELECT TOP (1) dt.Code AS RowTypeCode, dt.Name AS RowTypeName, dt.BivacItemsOnly AS RowTypeBivacOnly
            FROM inventory.DocumentTypes dt
            WHERE NULLIF(LTRIM(RTRIM(r.DocumentTypeCode)), N'') IS NOT NULL
              AND (dt.Code = LTRIM(RTRIM(r.DocumentTypeCode)) OR dt.Name = LTRIM(RTRIM(r.DocumentTypeCode)))
            ORDER BY CASE WHEN dt.Code = LTRIM(RTRIM(r.DocumentTypeCode)) THEN 0 ELSE 1 END
        ) rt
        OUTER APPLY
        (
            SELECT TOP (1) i.Id AS ItemId, i.ItemCode, i.ItemName, i.IsActive AS ItemActive, bu.Id AS BarcodeUnitId, i.IsBivac AS ItemIsBivac
            FROM inventory.Items i
            LEFT JOIN inventory.ItemUnits bu ON bu.ItemId = i.Id AND bu.Barcode = NULLIF(LTRIM(RTRIM(r.ItemRef)), N'')
            WHERE i.ItemCode = NULLIF(LTRIM(RTRIM(r.ItemRef)), N'') OR bu.Id IS NOT NULL
            ORDER BY CASE WHEN i.ItemCode = NULLIF(LTRIM(RTRIM(r.ItemRef)), N'') THEN 0 ELSE 1 END
        ) it
        OUTER APPLY
        (
            SELECT TOP (1) iu.Id AS ItemUnitId, t.UnitTypeName, iu.PackingFormula
            FROM inventory.ItemUnits iu
            INNER JOIN masterdata.UnitTypes t ON t.Id = iu.UnitTypeId
            WHERE iu.ItemId = it.ItemId
              AND (   (NULLIF(LTRIM(RTRIM(r.UnitName)), N'') IS NOT NULL
                       AND (t.UnitTypeName = LTRIM(RTRIM(r.UnitName)) OR iu.SkuCode = LTRIM(RTRIM(r.UnitName))))
                   OR (NULLIF(LTRIM(RTRIM(r.UnitName)), N'') IS NULL AND it.BarcodeUnitId IS NOT NULL AND iu.Id = it.BarcodeUnitId)
                   OR (NULLIF(LTRIM(RTRIM(r.UnitName)), N'') IS NULL AND it.BarcodeUnitId IS NULL))
            ORDER BY CASE @UnitPref WHEN 1 THEN CASE WHEN iu.IsSalesUnit = 1 THEN 0 ELSE 1 END
                                    WHEN 2 THEN CASE WHEN iu.IsPurchaseUnit = 1 THEN 0 ELSE 1 END
                                    ELSE CASE WHEN iu.IsBaseUnit = 1 THEN 0 ELSE 1 END END,
                     iu.IsBaseUnit DESC, iu.PackingFormula
        ) u
        OUTER APPLY
        (
            SELECT TOP (1) wh.Id AS WarehouseId, wh.WarehouseCode, wh.WarehouseName, wh.IsActive AS WarehouseActive, wh.BranchId AS WarehouseBranchId
            FROM masterdata.Warehouses wh
            WHERE (NULLIF(LTRIM(RTRIM(r.WarehouseRef)), N'') IS NOT NULL
                   AND (wh.WarehouseCode = LTRIM(RTRIM(r.WarehouseRef)) OR wh.WarehouseName = LTRIM(RTRIM(r.WarehouseRef))))
               OR (NULLIF(LTRIM(RTRIM(r.WarehouseRef)), N'') IS NULL AND wh.Id = @DefaultWarehouseId)
            ORDER BY CASE WHEN wh.WarehouseCode = LTRIM(RTRIM(r.WarehouseRef)) THEN 0 ELSE 1 END
        ) w
        OUTER APPLY
        (
            SELECT BranchPrice      = (SELECT TOP (1) Price FROM masterdata.UnitPrices
                                       WHERE ItemUnitId = u.ItemUnitId AND PriceListId = @PriceListId AND BranchId = @BranchId AND IsActive = 1),
                   AllBranchesPrice = (SELECT TOP (1) Price FROM masterdata.UnitPrices
                                       WHERE ItemUnitId = u.ItemUnitId AND PriceListId = @PriceListId AND BranchId IS NULL AND IsActive = 1)
        ) pr
    ),
    stocked AS
    (
        SELECT x.*,
               QtyBase    = CASE WHEN x.ItemUnitId IS NOT NULL AND x.Quantity IS NOT NULL AND x.Quantity > 0 AND x.Quantity = FLOOR(x.Quantity)
                                 THEN CAST(x.Quantity AS INT) * x.PackingFormula ELSE 0 END,
               OnHandBase = CASE WHEN x.ItemId IS NOT NULL AND x.WarehouseId IS NOT NULL THEN inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) END,
               AllowOos   = CASE WHEN x.WarehouseId IS NOT NULL THEN (SELECT p.Allowed FROM sales.fn_OutOfStockPolicy(x.WarehouseId) p) END
        FROM resolved x
    ),
    running AS
    (
        SELECT s.*,
               RequiredBase = SUM(s.QtyBase) OVER (PARTITION BY s.ItemId, s.WarehouseId ORDER BY s.RowNumber ROWS UNBOUNDED PRECEDING),
               EarlierRows  = STUFF((SELECT N', ' + CAST(s2.RowNumber AS NVARCHAR(10))
                                     FROM stocked s2
                                     WHERE s2.ItemId = s.ItemId AND s2.WarehouseId = s.WarehouseId AND s2.QtyBase > 0 AND s2.RowNumber < s.RowNumber
                                     ORDER BY s2.RowNumber FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(MAX)'), 1, 2, N'')
        FROM stocked s
    ),
    judged AS
    (
        SELECT x.*,
               SystemPrice = COALESCE(x.BranchPrice, x.AllBranchesPrice),
               EffectiveDiscount = ISNULL(x.DiscountPercent, 0),
               Err0 = CASE WHEN x.RowTypeRef IS NOT NULL AND x.RowTypeCode IS NULL THEN N'Document Type ''' + x.RowTypeRef + N''' does not exist.'
                           WHEN x.RowTypeCode IS NOT NULL AND @DocumentTypeCode IS NOT NULL AND x.RowTypeCode <> @DocumentTypeCode
                                THEN N'This row is for ' + x.RowTypeName + N' (' + x.RowTypeCode + N'), not for ' + @PageTypeName + N'.' END,
               Err1 = CASE WHEN x.ItemRef IS NULL THEN N'Item Code / Barcode is required.'
                           WHEN x.ItemId IS NULL THEN N'Item Code ' + x.ItemRef + N' does not exist.'
                           WHEN x.ItemActive = 0 THEN N'Item ' + x.ItemCode + N' is inactive.' END,
               -- (66) a BIVAC-only type (the row's own, else the page's) takes BIVAC items only
               ErrB = CASE WHEN x.ItemId IS NOT NULL AND x.ItemIsBivac = 0
                            AND CASE WHEN x.RowTypeCode IS NOT NULL THEN x.RowTypeBivacOnly ELSE @PageBivacOnly END = 1
                                THEN x.ItemCode + N' is not a BIVAC item.' END,
               Err2 = CASE WHEN x.Quantity IS NULL AND x.RawQuantity IS NOT NULL THEN N'Quantity ''' + x.RawQuantity + N''' is not a number.'
                           WHEN x.Quantity IS NULL OR x.Quantity <= 0 THEN N'Quantity must be greater than zero.'
                           WHEN x.Quantity <> FLOOR(x.Quantity) THEN N'Quantity must be a whole number of pieces.' END,
               Err3 = CASE WHEN x.ItemId IS NOT NULL AND x.UnitName IS NOT NULL AND x.ItemUnitId IS NULL
                                THEN N'Unit ''' + x.UnitName + N''' is not configured for Item ' + x.ItemCode + N'.'
                           WHEN x.ItemId IS NOT NULL AND x.ItemUnitId IS NULL THEN N'Item ' + x.ItemCode + N' has no units configured.' END,
               Err4 = CASE WHEN x.WarehouseRef IS NOT NULL AND x.WarehouseId IS NULL THEN N'Warehouse ' + x.WarehouseRef + N' does not exist.'
                           WHEN x.WarehouseActive = 0 THEN N'Warehouse ' + x.WarehouseCode + N' is inactive.' END,
               Err5 = CASE WHEN @PriceListId IS NOT NULL AND x.ItemUnitId IS NOT NULL
                            AND COALESCE(x.BranchPrice, x.AllBranchesPrice) IS NULL
                            AND NOT (x.ManualPrice IS NOT NULL AND @AllowPriceOverride = 1)
                                THEN N'No selling price was found for Item ' + x.ItemCode + N', Unit ' + x.UnitTypeName + N', and the selected Price List.'
                           WHEN x.ManualPrice IS NOT NULL AND x.ManualPrice < 0 THEN N'Unit Price cannot be negative.' END,
               Err6 = CASE WHEN ISNULL(x.DiscountPercent, 0) < 0 OR ISNULL(x.DiscountPercent, 0) > @MaxDiscountPercent
                                THEN N'Discount % must be between 0 and ' + CAST(CAST(@MaxDiscountPercent AS DECIMAL(9,2)) AS NVARCHAR(20)) + N'.' END,
               Err7 = CASE WHEN x.ExpiryDate IS NULL AND x.RawExpiryDate IS NOT NULL THEN N'Expiry Date ''' + x.RawExpiryDate + N''' is not a valid date.' END,
               Err8 = CASE WHEN @CheckStock = 1 AND NOT (@DocumentTypeCode = N'SINV' AND ISNULL(x.AllowOos, 0) = 1) AND x.QtyBase > 0 AND x.WarehouseId IS NOT NULL AND x.RequiredBase > ISNULL(x.OnHandBase, 0)
                                THEN N'Insufficient stock for ' + x.ItemCode + N' in ' + x.WarehouseCode + N': available ' + CAST(ISNULL(x.OnHandBase, 0) AS NVARCHAR(20))
                                     + N', required ' + CAST(x.RequiredBase AS NVARCHAR(20))
                                     + CASE WHEN x.EarlierRows IS NULL THEN N'' ELSE N' (with rows ' + x.EarlierRows + N')' END + N'.' END,
               Warn4 = CASE WHEN @CheckStock = 1 AND @DocumentTypeCode = N'SINV' AND ISNULL(x.AllowOos, 0) = 1 AND x.QtyBase > 0 AND x.WarehouseId IS NOT NULL
                             AND x.RequiredBase > ISNULL(x.OnHandBase, 0)
                                THEN N'Out of stock: ' + x.ItemCode + N' in ' + x.WarehouseCode + N' - available ' + CAST(ISNULL(x.OnHandBase, 0) AS NVARCHAR(20))
                                     + N', selling ' + CAST(x.RequiredBase AS NVARCHAR(20)) + N'. Posting will ask you to confirm.' END,
               Warn1 = CASE WHEN @PriceListId IS NOT NULL AND x.ManualPrice IS NOT NULL AND @AllowPriceOverride = 0 AND COALESCE(x.BranchPrice, x.AllBranchesPrice) IS NOT NULL
                                THEN N'Manual price ignored - system price ' + CAST(COALESCE(x.BranchPrice, x.AllBranchesPrice) AS NVARCHAR(30)) + N' used (no price override permission).' END,
               Warn2 = CASE WHEN x.ExpiryDate IS NOT NULL AND x.ExpiryDate < @Today THEN N'Expiry date is in the past.' END,
               Warn3 = CASE WHEN @UnitPref = 1 AND x.UnitName IS NULL AND x.BarcodeUnitId IS NULL AND x.ItemUnitId IS NOT NULL
                             AND NOT EXISTS (SELECT 1 FROM inventory.ItemUnits s WHERE s.ItemId = x.ItemId AND s.IsSalesUnit = 1)
                                THEN N'No sales unit is flagged for this item - the base unit was used.'
                            WHEN @UnitPref = 2 AND x.UnitName IS NULL AND x.BarcodeUnitId IS NULL AND x.ItemUnitId IS NOT NULL
                             AND NOT EXISTS (SELECT 1 FROM inventory.ItemUnits s WHERE s.ItemId = x.ItemId AND s.IsPurchaseUnit = 1)
                                THEN N'No purchase unit is flagged for this item - the base unit was used.' END
        FROM running x
    )
    SELECT j.RowNumber,
           Status  = CASE WHEN COALESCE(j.Err0, j.Err1, j.ErrB, j.Err2, j.Err3, j.Err4, j.Err5, j.Err6, j.Err7, j.Err8) IS NOT NULL THEN N'Error'
                          WHEN COALESCE(j.Warn1, j.Warn2, j.Warn3, j.Warn4) IS NOT NULL THEN N'Warning'
                          ELSE N'Valid' END,
           Message = NULLIF(LTRIM(CONCAT(ISNULL(j.Err0 + N' ', N''), ISNULL(j.Err1 + N' ', N''), ISNULL(j.ErrB + N' ', N''), ISNULL(j.Err2 + N' ', N''), ISNULL(j.Err3 + N' ', N''), ISNULL(j.Err4 + N' ', N''),
                                         ISNULL(j.Err5 + N' ', N''), ISNULL(j.Err6 + N' ', N''), ISNULL(j.Err7 + N' ', N''), ISNULL(j.Err8 + N' ', N''),
                                         ISNULL(j.Warn1 + N' ', N''), ISNULL(j.Warn2 + N' ', N''), ISNULL(j.Warn3 + N' ', N''), ISNULL(j.Warn4, N''))), N''),
           RowDocumentTypeCode = ISNULL(j.RowTypeCode, @DocumentTypeCode),
           j.ItemRef, j.ItemId, j.ItemCode, j.ItemName,
           j.ItemUnitId, j.UnitTypeName, j.PackingFormula,
           j.WarehouseId, j.WarehouseCode, j.WarehouseName,
           Quantity    = CASE WHEN j.Quantity IS NOT NULL AND j.Quantity > 0 AND j.Quantity = FLOOR(j.Quantity) THEN CAST(j.Quantity AS INT) END,
           UnitPrice   = CASE WHEN @PriceListId IS NULL THEN j.ManualPrice
                              WHEN j.ManualPrice IS NOT NULL AND @AllowPriceOverride = 1 THEN j.ManualPrice
                              ELSE j.SystemPrice END,
           PriceSource = CASE WHEN @PriceListId IS NULL THEN CASE WHEN j.ManualPrice IS NOT NULL THEN N'Manual' END
                              WHEN j.ManualPrice IS NOT NULL AND @AllowPriceOverride = 1 THEN N'Manual'
                              WHEN j.BranchPrice IS NOT NULL THEN N'Branch'
                              WHEN j.AllBranchesPrice IS NOT NULL THEN N'AllBranches' END,
           ManualPrice = j.ManualPrice,
           DiscountPercent = j.EffectiveDiscount,
           j.ExpiryDate, j.Notes,
           j.OnHandBase, j.RequiredBase
    FROM judged j
    ORDER BY j.RowNumber;
END
GO

/* ================================================================== 99. Check */

SELECT o.ObjectName, ObjectType = ISNULL(so.type_desc, N'MISSING')
FROM (VALUES (N'masterdata.fn_AttachmentDocumentKinds'), (N'inventory.usp_DocumentType_List'), (N'inventory.usp_Item_Lookup'),
             (N'inventory.usp_StockDocument_ValidateInput'), (N'inventory.usp_StockDocument_Post'),
             (N'sales.usp_InvoiceImport_Validate')) o (ObjectName)
LEFT JOIN sys.objects so ON so.object_id = OBJECT_ID(o.ObjectName)
ORDER BY ObjectType, o.ObjectName;                                    -- expected 6: 1 function, 5 procedures, none MISSING

-- The rule per type: only BIV_OUT is BIVAC-only.
SELECT Code, Name, Family, StockDirection, NumberPrefix, NumberOnPost, NumberPerBranch, YearInNumber, NumberLength,
       RequiresReason, DefaultPricing, PriceEditable, IsActive, BivacItemsOnly
FROM inventory.DocumentTypes WHERE Code IN (N'INV_IN', N'INV_OUT', N'BIV_OUT') ORDER BY Code;   -- expected 3 rows, BivacItemsOnly 1 on BIV_OUT only

SELECT p.Code, p.Name, p.SortOrder, Roles = (SELECT COUNT(*) FROM security.RolePermissions rp WHERE rp.PermissionId = p.Id)
FROM security.Permissions p WHERE p.Code LIKE N'inventory.bivacout.%' ORDER BY p.SortOrder;   -- expected 5

-- The attachment types used for BIVAC Out (as an administrator left them).
SELECT a.Category, a.SubType, a.IsActive
FROM masterdata.AttachmentTypes a
WHERE EXISTS (SELECT 1 FROM masterdata.AttachmentTypeUsages u WHERE u.AttachmentTypeId = a.Id AND u.DocumentKind = N'BIV_OUT')
ORDER BY a.SortOrder;

-- The BIVAC items, and the BIVAC Out documents by status.
SELECT BivacItems = COUNT(*) FROM inventory.Items WHERE IsBivac = 1 AND IsActive = 1;
SELECT d.Status, Documents = COUNT(*)
FROM inventory.StockDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
WHERE dt.BivacItemsOnly = 1
GROUP BY d.Status ORDER BY d.Status;

PRINT 'Script 66 applied: BIVAC Out (BIV_OUT) - a stock document of BIVAC items only, out at average cost; item picker without the 20-row cut.';
GO

SET NOEXEC OFF;
GO
