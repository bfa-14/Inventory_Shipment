SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 97: BIVAC - THE COST OF A BIVAC ITEM PER PORT, AND THE BIVAC OUT OF A BIVAC CHARGE

     1. A BIVAC ITEM HAS A COST PER PORT (inventory.ItemBivacPortCosts: item, port, cost in the base currency), kept on
        Item Definition ("BIVAC cost per port", Edit Items) for items with "BIVAC Item" ticked only. Each port once;
        0 or more. A port whose cost is removed simply has none.
     2. A BIVAC CHARGE NAMES ITS BIVAC ITEM. In Add charge, the charge type BIVAC / Inspection (code BIV) asks "Which
        BIVAC?" (the active BIVAC items); each container's charge is that item's cost at the container's port (its port
        of destination, else its final destination, else its port of loading), in the base currency - the amount,
        currency and split typed are not used. Refused (70000) when the item is not an active BIVAC item, when a
        container's port has no cost for it ("TEST-BIV has no BIVAC cost for Dar es Salaam: set it on Item Definition
        (BIVAC cost per port)."), when a BIV charge names no item, or another charge type names one. A draft keeps its
        amount editable; it keeps its type (another type is refused, and no other charge becomes a BIVAC one on edit).
        "Apply to other containers..." copies the item, at the cost of each target container's port.
     3. POSTING A BIVAC CHARGE POSTS A BIVAC OUT (Inventory > BIVAC Out): 1 piece of its BIVAC item out of the
        container's warehouse, dated the charge date, Reference No. the container's ref, linked to the charge
        (ContainerCharges.BivacOutDocumentId), in the post's transaction - refused with the BIVAC Out's own words
        (not enough stock 62007, a warehouse that is not at the bottom of the tree, a warehouse the user may not use
        50010), and then nothing of the post is kept. A container without a usable warehouse: "Container KTG-...
        has no warehouse to take its BIVAC from: set the container's warehouse first." (70010).
     4. CANCELLING A BIVAC CHARGE CANCELS ITS BIVAC OUT (the item comes back, the BIVAC Out shows Cancelled with
        "BIVAC charge cancelled: {reason}"). A BIVAC Out made by a charge is not cancelled on its own page: the
        charge's Cancel does it (62010 says so).
     5. The Excel import of charges does not take BIVAC rows (the item is chosen in Add charge): the API's check says so.

   Objects
     New tables / columns   inventory.ItemBivacPortCosts; inventory.tvp_ItemPortCost;
                            logistics.ContainerCharges.BivacItemId, .BivacOutDocumentId
     New                    logistics.fn_Container_BivacPort, fn_Container_BivacCost, fn_ContainerCharge_BivacBlock,
                            logistics.usp_ContainerCharge_PostBivacOut, logistics.usp_ContainerCharge_BivacOptions,
                            inventory.usp_Item_BivacPortCosts_Get, inventory.usp_Item_SetBivacPortCosts
     Re-created             logistics.usp_ContainerCharge_Create, _Update (from 96), _Post (from 65), _Cancel (from 65),
                            _Get (from 67), _CopyToContainers (from 28); inventory.usp_StockDocument_Cancel (from 90:
                            a BIVAC Out of a charge is cancelled by its charge)

   Errors: no new number (70000, 70010, and the BIVAC Out's own 62xxx).
   Requires scripts 66 and 96. Idempotent, additive: re-applied at every API start-up, and builds an empty database.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF COL_LENGTH(N'inventory.Items', N'IsBivac') IS NULL OR OBJECT_ID(N'logistics.fn_ContainerCharge_ReferenceClash', N'IF') IS NULL
    THROW 70000, 'Script 97 requires scripts 66 and 96: apply them first.', 1;
GO

/* ================================================================== 1. Tables and columns */

IF OBJECT_ID(N'inventory.ItemBivacPortCosts', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.ItemBivacPortCosts
    (
        Id           INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_ItemBivacPortCosts PRIMARY KEY CLUSTERED,
        ItemId       INT           NOT NULL CONSTRAINT FK_ItemBivacPortCosts_Item REFERENCES inventory.Items (Id) ON DELETE CASCADE,
        PortId       INT           NOT NULL CONSTRAINT FK_ItemBivacPortCosts_Port REFERENCES masterdata.Ports (Id),
        CostBase     DECIMAL(18,2) NOT NULL CONSTRAINT CK_ItemBivacPortCosts_Cost CHECK (CostBase >= 0),
        UpdatedAtUtc DATETIME2(3)  NOT NULL CONSTRAINT DF_ItemBivacPortCosts_Updated DEFAULT (SYSUTCDATETIME()),
        UpdatedBy    INT           NULL,
        CONSTRAINT UQ_ItemBivacPortCosts UNIQUE (ItemId, PortId)
    );
    PRINT 'Created inventory.ItemBivacPortCosts';
END
GO

IF TYPE_ID(N'inventory.tvp_ItemPortCost') IS NULL
    CREATE TYPE inventory.tvp_ItemPortCost AS TABLE (PortId INT NOT NULL PRIMARY KEY, CostBase DECIMAL(18,2) NULL);
GO

IF COL_LENGTH(N'logistics.ContainerCharges', N'BivacItemId') IS NULL
    ALTER TABLE logistics.ContainerCharges ADD BivacItemId INT NULL
        CONSTRAINT FK_ContainerCharges_BivacItem REFERENCES inventory.Items (Id);
GO
IF COL_LENGTH(N'logistics.ContainerCharges', N'BivacOutDocumentId') IS NULL
    ALTER TABLE logistics.ContainerCharges ADD BivacOutDocumentId INT NULL
        CONSTRAINT FK_ContainerCharges_BivacOut REFERENCES inventory.StockDocuments (Id);
GO

/* ================================================================== 2. The port of a container, and the BIVAC cost there */

-- (97) The port a container's BIVAC is paid at: its port of destination, else its final destination, else its port of loading.
CREATE OR ALTER FUNCTION logistics.fn_Container_BivacPort (@ContainerId INT)
RETURNS TABLE
AS
RETURN
SELECT c.Id AS ContainerId, PortId = p.Id, PortName = p.PortName
FROM logistics.Containers c
LEFT JOIN masterdata.Ports p ON p.Id = COALESCE(c.PortOfDestinationId, c.FinalDestinationId, c.PortOfLoadingId)
WHERE c.Id = @ContainerId;
GO

-- (97) One row: the cost of @ItemId at the container's BIVAC port (CostBase NULL when none is set there).
CREATE OR ALTER FUNCTION logistics.fn_Container_BivacCost (@ContainerId INT, @ItemId INT)
RETURNS TABLE
AS
RETURN
SELECT bp.ContainerId, bp.PortId, bp.PortName, pc.CostBase
FROM logistics.fn_Container_BivacPort(@ContainerId) bp
LEFT JOIN inventory.ItemBivacPortCosts pc ON pc.ItemId = @ItemId AND pc.PortId = bp.PortId;
GO

-- (97) At most one row: why a charge of @ChargeTypeId naming @BivacItemId cannot be made for @ContainerIds (NULL Reason
-- = it can): a BIV charge needs an active BIVAC item with a cost at every container's port; another type names none.
CREATE OR ALTER FUNCTION logistics.fn_ContainerCharge_BivacBlock
(
    @ChargeTypeId INT,
    @BivacItemId  INT,
    @ContainerIds logistics.tvp_IdList READONLY
)
RETURNS TABLE
AS
RETURN
SELECT Reason = CAST(CASE
    WHEN t.ChargeCode = N'BIV' AND @BivacItemId IS NULL
        THEN N'A BIVAC charge names its BIVAC: choose which BIVAC item (Item Definition''s items with BIVAC Item ticked).'
    WHEN ISNULL(t.ChargeCode, N'') <> N'BIV' AND @BivacItemId IS NOT NULL
        THEN N'Only a BIVAC / Inspection charge names a BIVAC item.'
    WHEN @BivacItemId IS NOT NULL AND (i.Id IS NULL OR i.IsBivac = 0 OR i.IsActive = 0)
        THEN N'The BIVAC item is not an active item with BIVAC Item ticked.'
    WHEN @BivacItemId IS NOT NULL
        THEN (SELECT TOP (1) i.ItemCode + N' has no BIVAC cost for ' + ISNULL(bc.PortName, N'the port of container ' + c.ContainerRef)
                             + N': set it on Item Definition (BIVAC cost per port).'
              FROM @ContainerIds x
              INNER JOIN logistics.Containers c ON c.Id = x.Id
              CROSS APPLY logistics.fn_Container_BivacCost(x.Id, @BivacItemId) bc
              WHERE bc.CostBase IS NULL
              ORDER BY c.ContainerRef)
    END AS NVARCHAR(400))
FROM (SELECT Dummy = 1) d
LEFT JOIN purchase.ChargeTypes t ON t.Id = @ChargeTypeId
LEFT JOIN inventory.Items i      ON i.Id = @BivacItemId;
GO

/* ================================================================== 3. The BIVAC cost per port of an item */

CREATE OR ALTER PROCEDURE inventory.usp_Item_BivacPortCosts_Get
    @ItemId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT pc.PortId, p.PortCode, p.PortName, p.CountryCode, pc.CostBase, pc.UpdatedAtUtc, u.FullName AS UpdatedByName
    FROM inventory.ItemBivacPortCosts pc
    INNER JOIN masterdata.Ports p ON p.Id = pc.PortId
    LEFT  JOIN security.Users u   ON u.Id = pc.UpdatedBy
    WHERE pc.ItemId = @ItemId
    ORDER BY p.PortName;
END
GO

-- (97) THE WHOLE LIST AT ONCE: the ports given are the item's costs, a port left out has none. A BIVAC item only.
CREATE OR ALTER PROCEDURE inventory.usp_Item_SetBivacPortCosts
    @ItemId INT,
    @Costs  inventory.tvp_ItemPortCost READONLY,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @IsBivac BIT = (SELECT IsBivac FROM inventory.Items WHERE Id = @ItemId);
    IF @IsBivac IS NULL THROW 56006, 'Item not found.', 1;
    IF @IsBivac = 0 AND EXISTS (SELECT 1 FROM @Costs)
        THROW 56000, 'Only a BIVAC item has a cost per port: tick BIVAC Item and save the item first.', 1;
    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg = CASE WHEN p.Id IS NULL THEN N'A port was not found: reload the page and try again.'
                               WHEN x.CostBase IS NULL THEN p.PortName + N': type the cost, or remove the port.'
                               ELSE p.PortName + N': the cost cannot be negative.' END
    FROM @Costs x LEFT JOIN masterdata.Ports p ON p.Id = x.PortId
    WHERE p.Id IS NULL OR x.CostBase IS NULL OR x.CostBase < 0;
    IF @Msg IS NOT NULL THROW 56000, @Msg, 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE pc FROM inventory.ItemBivacPortCosts pc
        WHERE pc.ItemId = @ItemId AND NOT EXISTS (SELECT 1 FROM @Costs x WHERE x.PortId = pc.PortId);
        UPDATE pc SET CostBase = x.CostBase, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        FROM inventory.ItemBivacPortCosts pc INNER JOIN @Costs x ON x.PortId = pc.PortId
        WHERE pc.ItemId = @ItemId AND pc.CostBase <> x.CostBase;
        INSERT INTO inventory.ItemBivacPortCosts (ItemId, PortId, CostBase, UpdatedBy)
        SELECT @ItemId, x.PortId, x.CostBase, @UserId FROM @Costs x
        WHERE NOT EXISTS (SELECT 1 FROM inventory.ItemBivacPortCosts pc WHERE pc.ItemId = @ItemId AND pc.PortId = x.PortId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
    EXEC inventory.usp_Item_BivacPortCosts_Get @ItemId;
END
GO

/* ================================================================== 4. What Add charge offers for a BIVAC charge */

-- (97) The active BIVAC items, each with its cost at each container's port (NULL = none there) and the total.
CREATE OR ALTER PROCEDURE logistics.usp_ContainerCharge_BivacOptions
    @ContainerIds logistics.tvp_IdList READONLY
AS
BEGIN
    SET NOCOUNT ON;
    SELECT i.Id AS ItemId, i.ItemCode, i.ItemName,
           Containers = (SELECT COUNT(*) FROM @ContainerIds),
           Priced = (SELECT COUNT(*) FROM @ContainerIds x CROSS APPLY logistics.fn_Container_BivacCost(x.Id, i.Id) bc WHERE bc.CostBase IS NOT NULL),
           TotalBase = (SELECT SUM(bc.CostBase) FROM @ContainerIds x CROSS APPLY logistics.fn_Container_BivacCost(x.Id, i.Id) bc),
           MissingPorts = STUFF((SELECT DISTINCT N', ' + ISNULL(bc.PortName, N'(no port)')
                                 FROM @ContainerIds x CROSS APPLY logistics.fn_Container_BivacCost(x.Id, i.Id) bc
                                 WHERE bc.CostBase IS NULL
                                 FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(400)'), 1, 2, N'')
    FROM inventory.Items i
    WHERE i.IsBivac = 1 AND i.IsActive = 1
    ORDER BY i.ItemCode;

    SELECT x.Id AS ContainerId, c.ContainerRef, bp.PortId, bp.PortName
    FROM @ContainerIds x
    INNER JOIN logistics.Containers c ON c.Id = x.Id
    CROSS APPLY logistics.fn_Container_BivacPort(x.Id) bp
    ORDER BY c.ContainerRef;
END
GO

/* ================================================================== 5. The BIVAC Out of a BIVAC charge */

-- (97) Called by usp_ContainerCharge_Post, in its transaction: a BIVAC Out (BIV_OUT) of 1 piece of the charge's BIVAC
-- item from the container's warehouse, saved and posted with the BIVAC Out's own procedures, linked to the charge.
CREATE OR ALTER PROCEDURE logistics.usp_ContainerCharge_PostBivacOut
    @ChargeId INT,
    @UserId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @ItemId INT, @Date DATE, @BranchId INT, @WarehouseId INT, @Ref NVARCHAR(30), @ChargeRef NVARCHAR(100), @Msg NVARCHAR(400);
    SELECT @ItemId = ch.BivacItemId, @Date = ch.ChargeDate, @BranchId = c.BranchId, @Ref = c.ContainerRef, @ChargeRef = ch.Reference,
           @WarehouseId = (SELECT w.Id FROM masterdata.Warehouses w
                           WHERE w.Id = c.WarehouseId AND w.IsActive = 1 AND masterdata.fn_Warehouse_IsLeaf(w.Id) = 1)
    FROM logistics.ContainerCharges ch INNER JOIN logistics.Containers c ON c.Id = ch.ContainerId
    WHERE ch.Id = @ChargeId;
    IF @ItemId IS NULL RETURN;
    IF @WarehouseId IS NULL
    BEGIN
        SET @Msg = N'Container ' + @Ref + N' has no warehouse to take its BIVAC from (active, at the bottom of the tree): set the container''s warehouse first.';
        THROW 70010, @Msg, 1;
    END
    IF @Date > CAST(SYSUTCDATETIME() AS DATE) SET @Date = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @Lines inventory.tvp_StockDocumentLine, @DocId INT;
    INSERT INTO @Lines (LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, UnitCost, Notes)
    SELECT 1, @ItemId, u.Id, @WarehouseId, NULL, 1, NULL, LEFT(N'BIVAC of container ' + @Ref, 300)
    FROM (SELECT TOP (1) Id FROM inventory.ItemUnits WHERE ItemId = @ItemId ORDER BY CASE WHEN IsBaseUnit = 1 THEN 0 ELSE 1 END, Id) u;
    IF NOT EXISTS (SELECT 1 FROM @Lines)
    BEGIN
        SET @Msg = N'The BIVAC item has no unit: add its base unit on Item Definition first.';
        THROW 70010, @Msg, 1;
    END
    DECLARE @Notes NVARCHAR(1000) = N'Made by the BIVAC charge of container ' + @Ref + ISNULL(N' (' + @ChargeRef + N')', N'') + N'.';
    EXEC inventory.usp_StockDocument_Save @DocumentTypeCode = N'BIV_OUT', @DocumentDate = @Date, @BranchId = @BranchId,
         @WarehouseId = @WarehouseId, @ReferenceNo = @Ref, @Notes = @Notes, @Lines = @Lines, @UserId = @UserId, @NewId = @DocId OUTPUT;
    EXEC inventory.usp_StockDocument_Post @Id = @DocId, @UserId = @UserId;
    UPDATE logistics.ContainerCharges SET BivacOutDocumentId = @DocId WHERE Id = @ChargeId;
END
GO

/* ================================================================== 6. Add charge */

-- Re-created (97) from the body of script 96: + @BivacItemId (fn_ContainerCharge_BivacBlock; a BIVAC charge's amount
-- is the item's cost at each container's port, in the base currency). Nothing else changes.
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
    @UserId           INT            = NULL,
    @BivacItemId      INT            = NULL       -- (97) the BIVAC item of a BIVAC charge (charge type BIV)
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

    -- (97) A BIVAC CHARGE NAMES ITS BIVAC ITEM, whose cost at each container's port is the charge of that container (in
    -- the base currency): the amount, the currency and the split typed are not used. Its posting takes 1 piece of the
    -- item out of the container's warehouse with a BIVAC Out (usp_ContainerCharge_Post).
    SET @Msg = (SELECT b.Reason FROM logistics.fn_ContainerCharge_BivacBlock(@ChargeTypeId, @BivacItemId, @ContainerIds) b);
    IF @Msg IS NOT NULL THROW 70000, @Msg, 1;
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

    -- (97) a BIVAC charge: each container's amount is the item's cost at its port, in the base currency
    IF @BivacItemId IS NOT NULL
    BEGIN
        SET @CurrencyId = @BaseCurrency;
        SET @Rate = 1;
        SET @CurrencyCode = (SELECT CurrencyCode FROM masterdata.Currencies WHERE Id = @BaseCurrency);
        UPDATE s SET Amount = bc.CostBase
        FROM @Split s CROSS APPLY logistics.fn_Container_BivacCost(s.ContainerId, @BivacItemId) bc;
        SET @TotalAmount = (SELECT SUM(Amount) FROM @Split);
        SET @SplitRule = N'Same';
    END

    DECLARE @Group UNIQUEIDENTIFIER = CASE WHEN @Count > 1 THEN NEWID() END;
    DECLARE @New TABLE (Id INT PRIMARY KEY, ContainerId INT);

    BEGIN TRY
        BEGIN TRANSACTION;

        -- (96) A PROVIDER'S INVOICE IS ENTERED ONCE: the reference of a provider (or of no provider) is refused when a charge
        -- not cancelled already carries it - one charge for all its containers (this call, Apply to other containers..., or
        -- the import, which keep one group). Under one lock, so two users typing the same invoice cannot both pass.
        IF @Reference IS NOT NULL
        BEGIN
            EXEC sp_getapplock @Resource = N'logistics.ContainerChargeReference', @LockMode = N'Exclusive',
                 @LockOwner = N'Transaction', @LockTimeout = 30000;
            SET @Msg = (SELECT r.Message FROM logistics.fn_ContainerCharge_ReferenceClash(@ProviderPartyId, @Reference, NULL, NULL) r);
            IF @Msg IS NOT NULL THROW 70001, @Msg, 1;
        END

        INSERT INTO logistics.ContainerCharges (ContainerId, MovementId, GroupId, ChargeTypeId, Description, ProviderPartyId, Reference, ChargeDate,
                                                CurrencyId, RateType, ExchangeRate, Amount, AmountBase, AllocationMethod, IncludeInLandedCost, Notes, CreatedBy,
                                                BivacItemId)
        OUTPUT inserted.Id, inserted.ContainerId INTO @New (Id, ContainerId)
        SELECT s.ContainerId, @MovementId, @Group, @ChargeTypeId, @Description, @ProviderPartyId, @Reference, @ChargeDate,
               @CurrencyId, @RateType, @Rate, s.Amount, ROUND(s.Amount / @Rate, 2), @Method, @InLanded, @Notes, @UserId,
               @BivacItemId
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

/* ================================================================== 7. A draft charge changed */

-- Re-created (97) from the body of script 96: a BIVAC charge keeps its type, no other charge becomes one. Nothing else changes.
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
    -- (97) a BIVAC charge keeps its type (its BIVAC item goes with it); another charge does not become one here
    DECLARE @WasBivac BIT = CASE WHEN EXISTS (SELECT 1 FROM logistics.ContainerCharges WHERE Id = @Id AND BivacItemId IS NOT NULL) THEN 1 ELSE 0 END;
    DECLARE @IsBivacType BIT = CASE WHEN EXISTS (SELECT 1 FROM purchase.ChargeTypes WHERE Id = @ChargeTypeId AND ChargeCode = N'BIV') THEN 1 ELSE 0 END;
    IF @WasBivac = 1 AND @IsBivacType = 0
        THROW 70000, 'A BIVAC charge keeps its charge type: delete this draft and add the charge again with Add charge.', 1;
    IF @WasBivac = 0 AND @IsBivacType = 1
        THROW 70000, 'A BIVAC charge is added with Add charge, where its BIVAC item is chosen: delete this draft and add it there.', 1;
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

        -- (96) a provider's invoice is entered once: the charges of this charge's own group keep it
        IF @Reference IS NOT NULL
        BEGIN
            EXEC sp_getapplock @Resource = N'logistics.ContainerChargeReference', @LockMode = N'Exclusive',
                 @LockOwner = N'Transaction', @LockTimeout = 30000;
            DECLARE @Clash NVARCHAR(400) = (SELECT r.Message
                                            FROM logistics.fn_ContainerCharge_ReferenceClash(
                                                     @ProviderPartyId, @Reference,
                                                     (SELECT GroupId FROM logistics.ContainerCharges WHERE Id = @Id), @Id) r);
            IF @Clash IS NOT NULL THROW 70001, @Clash, 1;
        END

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

/* ================================================================== 8. Post */

-- Re-created (97) from the body of script 65: + the BIVAC Out of a BIVAC charge (usp_ContainerCharge_PostBivacOut). Nothing else changes.
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

        -- (65) the containers of the charges, held until the commit, before anything is written (see above)
        DECLARE @HeldContainers INT = (SELECT COUNT(*) FROM logistics.Containers c WITH (UPDLOCK, HOLDLOCK)
                                       WHERE c.Id IN (SELECT ch.ContainerId FROM @List x INNER JOIN logistics.ContainerCharges ch ON ch.Id = x.Id));

        DECLARE @ChargeId INT, @ContainerId INT, @CtStatus TINYINT, @Method NVARCHAR(10), @InLanded BIT,
                @AmountBase DECIMAL(18,2), @Ref NVARCHAR(30), @Label NVARCHAR(200), @After BIT;
        DECLARE posts CURSOR LOCAL FAST_FORWARD FOR
            SELECT ch.Id FROM @List x INNER JOIN logistics.ContainerCharges ch ON ch.Id = x.Id ORDER BY ch.ContainerId, ch.Id;
        OPEN posts;
        FETCH NEXT FROM posts INTO @ChargeId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            -- (65) the container's status as committed: a goods receipt of it has finished (or not begun)
            SELECT @ContainerId = ch.ContainerId, @CtStatus = c.Status, @Method = ch.AllocationMethod, @InLanded = ch.IncludeInLandedCost,
                   @AmountBase = ch.AmountBase, @Ref = c.ContainerRef,
                   @Label = t.ChargeCode + N' ' + t.ChargeName + N' ' + CAST(ch.Amount AS NVARCHAR(30)) + N' ' + cur.CurrencyCode
            FROM logistics.ContainerCharges ch
            INNER JOIN logistics.Containers c WITH (UPDLOCK, HOLDLOCK) ON c.Id = ch.ContainerId
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

            -- (97) A BIVAC CHARGE TAKES ITS BIVAC OUT OF THE CONTAINER'S WAREHOUSE: 1 piece of its BIVAC item, posted with
            -- the charge (Inventory > BIVAC Out shows it, Reference No. the container); refused with the BIVAC Out's own
            -- words (not enough stock, a warehouse the user may not use...), and then nothing of the post is kept.
            IF EXISTS (SELECT 1 FROM logistics.ContainerCharges WHERE Id = @ChargeId AND BivacItemId IS NOT NULL AND BivacOutDocumentId IS NULL)
                EXEC logistics.usp_ContainerCharge_PostBivacOut @ChargeId, @UserId;

            INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
            VALUES (@ContainerId, N'Updated', LEFT(N'Charge posted: ' + @Label
                                                   + CASE WHEN @After = 1 THEN N' (after receipt: item costs adjusted)' ELSE N'' END
                                                   + ISNULL((SELECT N' (BIVAC Out ' + d.DocumentNumber + N')'
                                                             FROM logistics.ContainerCharges x
                                                             INNER JOIN inventory.StockDocuments d ON d.Id = x.BivacOutDocumentId
                                                             WHERE x.Id = @ChargeId), N''), 500), @UserId);

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

/* ================================================================== 9. Cancel */

-- Re-created (97) from the body of script 65: + the BIVAC Out of a BIVAC charge is cancelled with it. Nothing else changes.
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

    BEGIN TRY
        BEGIN TRANSACTION;

        -- (65) under lock: the container first, then the charge (a charge never changes container)
        DECLARE @ContainerId INT = (SELECT ContainerId FROM logistics.ContainerCharges WHERE Id = @Id);
        DECLARE @Status TINYINT, @CtStatus TINYINT, @InCost BIT, @Label NVARCHAR(200);
        SELECT @CtStatus = c.Status FROM logistics.Containers c WITH (UPDLOCK, HOLDLOCK) WHERE c.Id = @ContainerId;
        SELECT @Status = ch.Status,
               @InCost = CASE WHEN @CtStatus = 6 AND ch.IncludeInLandedCost = 1 AND (ch.AppliedAtOffload = 1 OR ch.AdjustedAfterOffload = 1) THEN 1 ELSE 0 END,
               @Label = t.ChargeCode + N' ' + t.ChargeName + N' ' + CAST(ch.Amount AS NVARCHAR(30)) + N' ' + cur.CurrencyCode
        FROM logistics.ContainerCharges ch WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN purchase.ChargeTypes t    ON t.Id = ch.ChargeTypeId
        INNER JOIN masterdata.Currencies cur ON cur.Id = ch.CurrencyId
        WHERE ch.Id = @Id AND ch.ContainerId = @ContainerId;

        IF @Status IS NULL THROW 70006, 'Charge not found.', 1;
        IF @Status <> 2 THROW 70010, 'Only a posted charge can be cancelled (delete a draft instead).', 1;
        -- (47) Money paid against it would be left pointing at nothing: the payments are reversed (or de-allocated) first.
        IF EXISTS (SELECT 1 FROM purchase.PaymentAllocations a INNER JOIN purchase.Payments p ON p.Id = a.PaymentId
                   WHERE a.ContainerChargeId = @Id AND a.RemovedAtUtc IS NULL AND p.Status = 2)
            THROW 70010, 'This charge cannot be cancelled: supplier payments are allocated to it. Reverse those payments (or remove the allocations) first.', 1;
        IF @CtStatus = 7 THROW 70010, 'The container is closed. Reopen it first.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.ContainerCharges WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 70004, 'This charge was modified by another user. Reload the page and try again.', 1;

        UPDATE logistics.ContainerCharges
        SET Status = 3, CancelledAtUtc = SYSUTCDATETIME(), CancelledBy = @UserId, CancelReason = @Reason,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        EXEC logistics.usp_Container_RecalcCosts @ContainerId;
        IF @InCost = 1 EXEC logistics.usp_ContainerCharge_ApplyCost @Id, -1, @UserId;

        -- (97) the BIVAC Out of a BIVAC charge is cancelled with it (its own rules and words: the BIVAC item comes back)
        DECLARE @BivacOut INT = (SELECT ch.BivacOutDocumentId FROM logistics.ContainerCharges ch
                                 INNER JOIN inventory.StockDocuments d ON d.Id = ch.BivacOutDocumentId AND d.Status = 2
                                 WHERE ch.Id = @Id);
        IF @BivacOut IS NOT NULL
        BEGIN
            DECLARE @BivacReason NVARCHAR(300) = LEFT(N'BIVAC charge cancelled: ' + @Reason, 300);
            EXEC inventory.usp_StockDocument_Cancel @Id = @BivacOut, @Reason = @BivacReason, @UserId = @UserId;
        END

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

/* ================================================================== 10. Get */

-- Re-created (97) from the body of script 67: + the BIVAC item and the BIVAC Out. Nothing else changes.
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
           ch.CreatedAtUtc, cu.FullName AS CreatedByName, ch.UpdatedAtUtc, uu.FullName AS UpdatedByName, ch.RowVersion,
           -- (47) supplier payments: posted charges only (NULL otherwise)
           PaidAmount = pst.PaidAmount, OutstandingAmount = pst.OutstandingAmount, PaymentStatus = pst.PaymentStatus,
           -- (97) a BIVAC charge: its BIVAC item, and the BIVAC Out its posting made
           ch.BivacItemId, BivacItemCode = bi.ItemCode, BivacItemName = bi.ItemName,
           ch.BivacOutDocumentId, BivacOutNumber = bo.DocumentNumber, BivacOutStatus = bo.Status
    FROM logistics.ContainerCharges ch
    LEFT  JOIN inventory.Items bi          ON bi.Id = ch.BivacItemId
    LEFT  JOIN inventory.StockDocuments bo ON bo.Id = ch.BivacOutDocumentId
    OUTER APPLY logistics.fn_ContainerChargeSettlement(ch.Id) pst
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
           IsOther = CAST(CASE WHEN at.Id IS NULL OR (at.SubType = N'Other' AND at.Category IN (N'Other', N'General')) THEN 1 ELSE 0 END AS BIT),   -- (67)
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

/* ================================================================== 11. Apply to other containers */

-- Re-created (97) from the body of script 28: + a copy of a BIVAC charge takes its item at each container's port cost. Nothing else changes.
CREATE OR ALTER PROCEDURE logistics.usp_ContainerCharge_CopyToContainers
    @ChargeId         INT,
    @ContainerIds     logistics.tvp_IdList READONLY,
    @Amount           DECIMAL(18,2) = NULL,
    @ChargeDate       DATE          = NULL,
    @AllocationMethod NVARCHAR(10)  = NULL,
    @Post             BIT           = 0,
    @UserId           INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @AllocationMethod = NULLIF(LTRIM(RTRIM(@AllocationMethod)), N'');

    DECLARE @SrcContainer INT, @SrcRef NVARCHAR(30), @SrcStatus TINYINT, @GroupId UNIQUEIDENTIFIER, @SrcMovement INT,
            @TypeId INT, @SrcMethod NVARCHAR(10), @SrcAmount DECIMAL(18,2), @SrcDate DATE, @CurrencyId INT, @RateType TINYINT,
            @Rate DECIMAL(18,6), @InLanded BIT, @Description NVARCHAR(200), @ProviderId INT, @Reference NVARCHAR(100),
            @Notes NVARCHAR(300), @SrcBivac INT;
    SELECT @SrcBivac = ch.BivacItemId,   -- (97)
           @SrcContainer = ch.ContainerId, @SrcRef = c.ContainerRef, @SrcStatus = ch.Status, @GroupId = ch.GroupId,
           @SrcMovement = ch.MovementId, @TypeId = ch.ChargeTypeId, @SrcMethod = ch.AllocationMethod, @SrcAmount = ch.Amount,
           @SrcDate = ch.ChargeDate, @CurrencyId = ch.CurrencyId, @RateType = ch.RateType, @Rate = ch.ExchangeRate,
           @InLanded = ch.IncludeInLandedCost, @Description = ch.Description, @ProviderId = ch.ProviderPartyId,
           @Reference = ch.Reference, @Notes = ch.Notes
    FROM logistics.ContainerCharges ch
    INNER JOIN logistics.Containers c ON c.Id = ch.ContainerId
    WHERE ch.Id = @ChargeId;

    IF @SrcContainer IS NULL THROW 70006, 'Charge not found.', 1;
    IF @SrcStatus = 3 THROW 70010, 'A cancelled charge cannot be copied.', 1;
    IF @Amount IS NOT NULL AND @Amount < 0 THROW 70000, 'The amount cannot be negative.', 1;
    IF @AllocationMethod IS NOT NULL AND @AllocationMethod NOT IN (N'Value', N'Quantity', N'Weight', N'Volume')
        THROW 70000, 'Allocation method of the copies must be Value, Quantity, Weight or Volume (a manual split can be typed on each draft afterwards).', 1;

    DECLARE @TypeMethod NVARCHAR(10), @TypeLabel NVARCHAR(120);
    SELECT @TypeMethod = AllocationMethod, @TypeLabel = ChargeCode + N' ' + ChargeName
    FROM purchase.ChargeTypes WHERE Id = @TypeId AND IsActive = 1;
    IF @TypeLabel IS NULL THROW 70000, 'The charge type of this charge is no longer active.', 1;

    DECLARE @Method NVARCHAR(10) = COALESCE(@AllocationMethod, CASE WHEN @SrcMethod = N'Manual' THEN @TypeMethod ELSE @SrcMethod END);
    IF @Method IS NULL OR @Method NOT IN (N'Value', N'Quantity', N'Weight', N'Volume') SET @Method = N'Value';
    SET @Amount = ISNULL(@Amount, @SrcAmount);
    SET @ChargeDate = ISNULL(@ChargeDate, @SrcDate);
    DECLARE @AmountBase DECIMAL(18,2) = ROUND(@Amount / @Rate, 2);
    DECLARE @CurrencyCode NVARCHAR(10) = (SELECT CurrencyCode FROM masterdata.Currencies WHERE Id = @CurrencyId);

    -- the original's container is skipped (it already has the charge)
    DECLARE @Ids TABLE (Id INT NOT NULL PRIMARY KEY);
    INSERT INTO @Ids (Id) SELECT Id FROM @ContainerIds WHERE Id <> @SrcContainer;
    IF NOT EXISTS (SELECT 1 FROM @Ids) THROW 70000, 'Select at least one other container.', 1;

    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg = CASE WHEN c.Id IS NULL THEN N'A selected container no longer exists.'
                               ELSE N'Container ' + c.ContainerRef + N' is closed or cancelled.' END
    FROM @Ids x LEFT JOIN logistics.Containers c ON c.Id = x.Id
    WHERE c.Id IS NULL OR c.Status IN (7, 8)
    ORDER BY c.ContainerRef;
    IF @Msg IS NOT NULL THROW 70010, @Msg, 1;

    IF @GroupId IS NOT NULL
    BEGIN
        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' already has this charge.'
        FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id
        WHERE EXISTS (SELECT 1 FROM logistics.ContainerCharges g WHERE g.GroupId = @GroupId AND g.ContainerId = x.Id AND g.Status <> 3)
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70001, @Msg, 1;
    END

    -- (97) a copy of a BIVAC charge: the same BIVAC item, at the cost of each container's own port
    IF @SrcBivac IS NOT NULL
    BEGIN
        DECLARE @Targets logistics.tvp_IdList;
        INSERT INTO @Targets (Id) SELECT Id FROM @Ids;
        SET @Msg = (SELECT b.Reason FROM logistics.fn_ContainerCharge_BivacBlock(@TypeId, @SrcBivac, @Targets) b);
        IF @Msg IS NOT NULL THROW 70000, @Msg, 1;
    END

    DECLARE @New TABLE (Id INT NOT NULL PRIMARY KEY, ContainerId INT NOT NULL);
    DECLARE @NewChargeId INT, @Ref NVARCHAR(30) = NULL;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- read again under lock: two users copying the same charge at the same moment
        SELECT @GroupId = GroupId, @SrcStatus = Status
        FROM logistics.ContainerCharges WITH (UPDLOCK, HOLDLOCK)
        WHERE Id = @ChargeId;
        IF @@ROWCOUNT = 0 THROW 70006, 'Charge not found.', 1;
        IF @SrcStatus = 3 THROW 70010, 'A cancelled charge cannot be copied.', 1;
        IF @GroupId IS NOT NULL
        BEGIN
            SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' already has this charge.'
            FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id
            WHERE EXISTS (SELECT 1 FROM logistics.ContainerCharges g WHERE g.GroupId = @GroupId AND g.ContainerId = x.Id AND g.Status <> 3)
            ORDER BY c.ContainerRef;
            IF @Msg IS NOT NULL THROW 70001, @Msg, 1;
        END
        ELSE
        BEGIN
            SET @GroupId = NEWID();
            UPDATE logistics.ContainerCharges SET GroupId = @GroupId WHERE Id = @ChargeId;
        END

        INSERT INTO logistics.ContainerCharges (ContainerId, MovementId, GroupId, ChargeTypeId, Description, ProviderPartyId, Reference, ChargeDate,
                                                CurrencyId, RateType, ExchangeRate, Amount, AmountBase, AllocationMethod, IncludeInLandedCost, Notes, CreatedBy,
                                                BivacItemId)
        OUTPUT inserted.Id, inserted.ContainerId INTO @New (Id, ContainerId)
        SELECT x.Id,
               CASE WHEN @SrcMovement IS NOT NULL
                         AND EXISTS (SELECT 1 FROM logistics.MovementContainers mc
                                     INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
                                     WHERE mc.MovementId = @SrcMovement AND mc.ContainerId = x.Id AND m.Status <> 4)
                    THEN @SrcMovement END,
               @GroupId, @TypeId, @Description, @ProviderId, @Reference, @ChargeDate,
               @CurrencyId, @RateType, @Rate,
               CASE WHEN @SrcBivac IS NOT NULL THEN bc.CostBase ELSE @Amount END,
               CASE WHEN @SrcBivac IS NOT NULL THEN ROUND(bc.CostBase / @Rate, 2) ELSE @AmountBase END,
               @Method, @InLanded, @Notes, @UserId, @SrcBivac
        FROM @Ids x
        OUTER APPLY logistics.fn_Container_BivacCost(x.Id, @SrcBivac) bc;

        DECLARE new_cur CURSOR LOCAL STATIC READ_ONLY FORWARD_ONLY FOR SELECT Id FROM @New ORDER BY Id;
        OPEN new_cur;
        FETCH NEXT FROM new_cur INTO @NewChargeId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC logistics.usp_ContainerCharge_Allocate @NewChargeId, 1;
            FETCH NEXT FROM new_cur INTO @NewChargeId;
        END
        CLOSE new_cur;
        DEALLOCATE new_cur;

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        SELECT n.ContainerId, N'Updated',
               LEFT(N'Charge added (draft): ' + @TypeLabel + N' ' + CAST(@Amount AS NVARCHAR(30)) + N' ' + ISNULL(@CurrencyCode, N'')
                    + N' (copied from ' + @SrcRef + N')', 500),
               @UserId
        FROM @New n;

        IF ISNULL(@Post, 0) = 1
        BEGIN
            DECLARE post_cur CURSOR LOCAL STATIC READ_ONLY FORWARD_ONLY FOR
                SELECT n.Id, c.ContainerRef FROM @New n INNER JOIN logistics.Containers c ON c.Id = n.ContainerId ORDER BY c.ContainerRef;
            OPEN post_cur;
            FETCH NEXT FROM post_cur INTO @NewChargeId, @Ref;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC logistics.usp_ContainerCharge_Post @Id = @NewChargeId, @UserId = @UserId;
                FETCH NEXT FROM post_cur INTO @NewChargeId, @Ref;
            END
            CLOSE post_cur;
            DEALLOCATE post_cur;
            SET @Ref = NULL;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrNo INT = ERROR_NUMBER(), @ErrMsg NVARCHAR(2048) = ERROR_MESSAGE();
        IF @ErrNo >= 50000 AND @Ref IS NOT NULL
        BEGIN
            SET @ErrMsg = LEFT(@Ref + N': ' + @ErrMsg, 2048);
            THROW @ErrNo, @ErrMsg, 1;
        END;
        THROW;
    END CATCH

    SELECT ch.Id, ch.ContainerId, c.ContainerRef, c.ContainerNo, ch.GroupId, ch.Amount, ch.AmountBase, ch.AllocationMethod, ch.Status, ch.RowVersion
    FROM @New n
    INNER JOIN logistics.ContainerCharges ch ON ch.Id = n.Id
    INNER JOIN logistics.Containers c        ON c.Id = ch.ContainerId
    ORDER BY c.ContainerRef;
END
GO

/* ================================================================== 12. A BIVAC Out of a charge goes with its charge */

-- Re-created (97) from the body of script 90: + a BIVAC Out made by a posted BIVAC charge is cancelled by that charge's
-- Cancel only. Nothing else changes.
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

        -- (97) A BIVAC OUT MADE BY A BIVAC CHARGE goes with its charge: cancelling the charge cancels it (the charge is then
        -- already cancelled when this runs)
        DECLARE @ChargeOf NVARCHAR(30) = (SELECT TOP (1) c.ContainerRef FROM logistics.ContainerCharges ch
                                          INNER JOIN logistics.Containers c ON c.Id = ch.ContainerId
                                          WHERE ch.BivacOutDocumentId = @Id AND ch.Status = 2);
        IF @ChargeOf IS NOT NULL
        BEGIN
            DECLARE @ChargeMsg NVARCHAR(400) = N'This BIVAC Out was made by the BIVAC charge of container ' + @ChargeOf
                                             + N': cancel that charge instead (its BIVAC Out is cancelled with it).';
            THROW 62010, @ChargeMsg, 1;
        END

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

/* ================================================================== 13. Check */

-- 97a: the BIVAC items and how many ports have a cost; 97b: the BIVAC charges and their BIVAC Out
SELECT i.ItemCode, i.ItemName, i.IsActive, Ports = (SELECT COUNT(*) FROM inventory.ItemBivacPortCosts pc WHERE pc.ItemId = i.Id)
FROM inventory.Items i WHERE i.IsBivac = 1 ORDER BY i.ItemCode;
SELECT ch.Id, c.ContainerRef, ch.Status, BivacItem = i.ItemCode, BivacOut = d.DocumentNumber, BivacOutStatus = d.Status
FROM logistics.ContainerCharges ch
INNER JOIN logistics.Containers c ON c.Id = ch.ContainerId
INNER JOIN inventory.Items i      ON i.Id = ch.BivacItemId
LEFT  JOIN inventory.StockDocuments d ON d.Id = ch.BivacOutDocumentId
ORDER BY ch.Id DESC;
PRINT 'Script 97 applied: BIVAC cost per port on BIVAC items; a BIVAC charge names its BIVAC item and posts its BIVAC Out.';
GO
