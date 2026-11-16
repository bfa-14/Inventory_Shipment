SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 102: PURCHASE - DEDUCTIONS: A CHARGE THAT LOWERS THE COST

   A charge can now take value off the goods instead of adding to it: the owner's case is an item delivered with spare
   parts in its box, the spare parts taken out at the warehouse and sold on their own - their value comes off the item.
   A supplier's refund or credit is entered the same way.

     1. purchase.ChargeTypes.IsDeduction (BIT, default 0); a deduction is part of the landed cost and never a recoverable
        tax (CK_ChargeTypes_DeductionLanded). New type DED "Deduction / refund" (Value), created once if missing.
        usp_ChargeType_Lookup / _Search return IsDeduction; usp_ChargeType_Save takes it (NULL: 0 on a new type, unchanged
        on an existing one) and refuses to change it on a type already used by charges (68005).
     2. THE AMOUNT OF A DEDUCTION IS STORED NEGATIVE, whichever sign was typed: CK_ContainerCharges_Amount,
        CK_ContainerChargeAllocations_Amount and CK_PurchaseCharges_Amount (>= 0) are dropped; the procedures decide the
        sign from the type instead - a deduction is negative, any other charge 0 or more ("The amount cannot be negative.
        To lower the cost, choose a deduction charge type (Deduction / refund).").
     3. Container charges - usp_ContainerCharge_Create, _Update (its manual shares follow the sign), _CopyToContainers
        ("Apply to other containers": a deduction's copies are deductions). Splitting over containers and allocating
        over items (usp_ContainerCharge_Allocate) already work with a negative amount: unchanged.
     4. usp_ContainerCharge_Post: A DEDUCTION NEVER TAKES A COST BELOW ZERO - a line's value with its charges, and after
        the receipt the item's average cost (70013 "Container KTG-...: this deduction would bring {item} below zero ...").
     5. usp_ContainerCharge_ApplyCost: cancelling a deduction posted after the receipt puts back into stock no more than its
        posting took out, per item (the mirror of script 89's cap for a charge).
     6. fn_ContainerChargeSettlement: a deduction is not paid - PaymentStatus 'Deduction', nothing outstanding, so it never
        appears among the documents a supplier payment can pay.
     7. An invoice's own charges and landed cost adjustments (purchase.usp_PurchaseCharges_Write): the same sign rule and
        manual shares, and the deductions never take more than the invoice's goods are worth.

   Who may enter a deduction: whoever may enter a charge (no new permission). No new error number.
   Each procedure re-created from its current body (scripts 23, 47, 89, 96, 97) plus only this change. Idempotent.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'purchase.ChargeTypes', N'U') IS NULL OR OBJECT_ID(N'logistics.ContainerCharges', N'U') IS NULL
   OR COL_LENGTH(N'logistics.ContainerCharges', N'BivacItemId') IS NULL
    THROW 70000, 'Script 102 requires scripts 23, 27 and 97: apply them first.', 1;
GO

/* ================================================================== 1. Charge types: IsDeduction */

IF COL_LENGTH(N'purchase.ChargeTypes', N'IsDeduction') IS NULL
    ALTER TABLE purchase.ChargeTypes ADD IsDeduction BIT NOT NULL CONSTRAINT DF_ChargeTypes_IsDeduction DEFAULT (0);
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_ChargeTypes_DeductionLanded')
    ALTER TABLE purchase.ChargeTypes ADD CONSTRAINT CK_ChargeTypes_DeductionLanded
        CHECK (IsDeduction = 0 OR (IncludeInLandedCost = 1 AND IsRecoverableTax = 0));
GO

IF NOT EXISTS (SELECT 1 FROM purchase.ChargeTypes WHERE ChargeCode = N'DED')
   AND NOT EXISTS (SELECT 1 FROM purchase.ChargeTypes WHERE ChargeName = N'Deduction / refund')
    INSERT INTO purchase.ChargeTypes (ChargeCode, ChargeName, AllocationMethod, IncludeInLandedCost, IsRecoverableTax, Description, IsActive, IsDeduction)
    VALUES (N'DED', N'Deduction / refund', N'Value', 1, 0,
            N'Lowers the cost of the goods: spare parts taken out of a box and sold on their own, a supplier''s refund or credit.', 1, 1);
GO

/* ================================================================== 2. The amount constraints: the sign is the procedures' */

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_ContainerCharges_Amount' AND parent_object_id = OBJECT_ID(N'logistics.ContainerCharges'))
    ALTER TABLE logistics.ContainerCharges DROP CONSTRAINT CK_ContainerCharges_Amount;
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_ContainerChargeAllocations_Amount' AND parent_object_id = OBJECT_ID(N'logistics.ContainerChargeAllocations'))
    ALTER TABLE logistics.ContainerChargeAllocations DROP CONSTRAINT CK_ContainerChargeAllocations_Amount;
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_PurchaseCharges_Amount' AND parent_object_id = OBJECT_ID(N'purchase.PurchaseCharges'))
    ALTER TABLE purchase.PurchaseCharges DROP CONSTRAINT CK_PurchaseCharges_Amount;
GO

/* ================================================================== 3. Charge type procedures */

CREATE OR ALTER PROCEDURE purchase.usp_ChargeType_Lookup
    @ActiveOnly BIT = 1, @IncludeId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, ChargeCode, ChargeName, AllocationMethod, IncludeInLandedCost, IsRecoverableTax, IsActive,
           IsDeduction                                                     -- (102)
    FROM purchase.ChargeTypes
    WHERE @ActiveOnly = 0 OR IsActive = 1 OR Id = @IncludeId
    ORDER BY ChargeName;
END
GO

CREATE OR ALTER PROCEDURE purchase.usp_ChargeType_Save
    @Id                  INT           = NULL,
    @ChargeCode          NVARCHAR(10),
    @ChargeName          NVARCHAR(100),
    @AllocationMethod    NVARCHAR(10),
    @IncludeInLandedCost BIT           = 1,
    @IsRecoverableTax    BIT           = 0,
    @Description         NVARCHAR(500) = NULL,
    @IsActive            BIT           = 1,
    @RowVersion          BINARY(8)     = NULL,
    @UserId              INT           = NULL,
    @NewId               INT OUTPUT,
    @IsDeduction         BIT           = NULL      -- (102) NULL: 0 on a new type, unchanged on an existing one
AS
BEGIN
    SET NOCOUNT ON;
    SET @ChargeCode = UPPER(NULLIF(LTRIM(RTRIM(@ChargeCode)), N''));
    SET @ChargeName = NULLIF(LTRIM(RTRIM(@ChargeName)), N'');
    SET @Description = NULLIF(LTRIM(RTRIM(@Description)), N'');
    IF @ChargeCode IS NULL THROW 68000, 'Charge Code is required.', 1;
    IF @ChargeName IS NULL THROW 68000, 'Charge Name is required.', 1;
    IF @AllocationMethod NOT IN (N'Value', N'Quantity', N'Weight', N'Volume', N'Manual') THROW 68000, 'Allocation method must be Value, Quantity, Weight, Volume or Manual.', 1;
    IF ISNULL(@IsRecoverableTax, 0) = 1 AND ISNULL(@IncludeInLandedCost, 1) = 1 THROW 68000, 'A recoverable tax cannot be included in the landed cost.', 1;
    -- (102) A DEDUCTION LOWERS THE LANDED COST: it is part of it, and never a recoverable tax.
    IF ISNULL(@IsDeduction, 0) = 1 AND (ISNULL(@IncludeInLandedCost, 1) = 0 OR ISNULL(@IsRecoverableTax, 0) = 1)
        THROW 68000, 'A deduction lowers the landed cost: tick "Include in landed cost" and leave "Recoverable tax" off.', 1;
    -- (102) ...and a type already used keeps its sign: its charges were stored as costs (or as deductions).
    IF @Id IS NOT NULL AND @IsDeduction IS NOT NULL
       AND EXISTS (SELECT 1 FROM purchase.ChargeTypes WHERE Id = @Id AND IsDeduction <> @IsDeduction)
       AND (EXISTS (SELECT 1 FROM logistics.ContainerCharges WHERE ChargeTypeId = @Id)
            OR EXISTS (SELECT 1 FROM purchase.PurchaseCharges WHERE ChargeTypeId = @Id))
        THROW 68005, 'This charge type is already used by charges: whether it is a deduction cannot change. Create another charge type instead.', 1;
    IF EXISTS (SELECT 1 FROM purchase.ChargeTypes WHERE ChargeCode = @ChargeCode AND (@Id IS NULL OR Id <> @Id)) THROW 68001, 'This Charge Code already exists.', 1;
    IF EXISTS (SELECT 1 FROM purchase.ChargeTypes WHERE ChargeName = @ChargeName AND (@Id IS NULL OR Id <> @Id)) THROW 68002, 'This Charge Name already exists.', 1;

    IF @Id IS NULL
    BEGIN
        INSERT INTO purchase.ChargeTypes (ChargeCode, ChargeName, AllocationMethod, IncludeInLandedCost, IsRecoverableTax, Description, IsActive, CreatedBy, IsDeduction)
        VALUES (@ChargeCode, @ChargeName, @AllocationMethod, ISNULL(@IncludeInLandedCost, 1), ISNULL(@IsRecoverableTax, 0), @Description, ISNULL(@IsActive, 1), @UserId,
                ISNULL(@IsDeduction, 0));
        SET @NewId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM purchase.ChargeTypes WHERE Id = @Id) THROW 68006, 'Charge type not found.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.ChargeTypes WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 68004, 'This charge type was modified by another user. Reload the page and try again.', 1;
        UPDATE purchase.ChargeTypes
        SET ChargeCode = @ChargeCode, ChargeName = @ChargeName, AllocationMethod = @AllocationMethod, IncludeInLandedCost = ISNULL(@IncludeInLandedCost, 1),
            IsRecoverableTax = ISNULL(@IsRecoverableTax, 0), Description = @Description, IsActive = ISNULL(@IsActive, 1),
            IsDeduction = ISNULL(@IsDeduction, IsDeduction),
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;
        SET @NewId = @Id;
    END
END
GO

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
           c.IsDeduction,                                                  -- (102)
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

/* ================================================================== 4. Container charges */

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
    IF @TotalAmount IS NULL THROW 70000, 'The amount is required.', 1;
    IF @SplitRule NOT IN (N'Same', N'Equal', N'Pieces', N'Value') THROW 70000, 'Split rule must be Same, Equal, Pieces or Value.', 1;
    IF @AllocationMethod IS NOT NULL AND @AllocationMethod NOT IN (N'Value', N'Quantity', N'Weight', N'Volume', N'Manual')
        THROW 70000, 'Allocation method must be Value, Quantity, Weight, Volume or Manual.', 1;
    IF @RateType NOT IN (1, 2, 3) THROW 70000, 'Unknown rate type.', 1;
    IF @ExchangeRate IS NOT NULL AND @ExchangeRate <= 0 THROW 70000, 'The exchange rate must be greater than zero.', 1;

    DECLARE @Method NVARCHAR(10), @InLanded BIT, @TypeLabel NVARCHAR(120);
    SELECT @Method = ISNULL(@AllocationMethod, AllocationMethod), @InLanded = IncludeInLandedCost, @TypeLabel = ChargeCode + N' ' + ChargeName
    FROM purchase.ChargeTypes WHERE Id = @ChargeTypeId AND IsActive = 1;
    IF @Method IS NULL THROW 70000, 'Charge type not found or inactive.', 1;
    -- (102) A DEDUCTION TYPE LOWERS THE COST: what is typed is taken off (stored negative, whichever sign was sent). Any
    -- other type is a cost and cannot be negative.
    DECLARE @IsDeduction BIT = CASE WHEN EXISTS (SELECT 1 FROM purchase.ChargeTypes WHERE Id = @ChargeTypeId AND IsDeduction = 1) THEN 1 ELSE 0 END;
    IF @IsDeduction = 1
    BEGIN
        IF @TotalAmount = 0 THROW 70000, 'Enter the amount deducted.', 1;
        SET @TotalAmount = -ABS(@TotalAmount);
    END
    ELSE IF @TotalAmount < 0
        THROW 70000, 'The amount cannot be negative. To lower the cost, choose a deduction charge type (Deduction / refund).', 1;
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
    IF @Amount IS NULL THROW 70000, 'The amount is required.', 1;
    IF @AllocationMethod IS NOT NULL AND @AllocationMethod NOT IN (N'Value', N'Quantity', N'Weight', N'Volume', N'Manual')
        THROW 70000, 'Allocation method must be Value, Quantity, Weight, Volume or Manual.', 1;
    IF @RateType NOT IN (1, 2, 3) THROW 70000, 'Unknown rate type.', 1;
    IF @ExchangeRate IS NOT NULL AND @ExchangeRate <= 0 THROW 70000, 'The exchange rate must be greater than zero.', 1;

    DECLARE @Method NVARCHAR(10), @InLanded BIT;
    SELECT @Method = ISNULL(@AllocationMethod, AllocationMethod), @InLanded = IncludeInLandedCost
    FROM purchase.ChargeTypes WHERE Id = @ChargeTypeId AND IsActive = 1;
    IF @Method IS NULL THROW 70000, 'Charge type not found or inactive.', 1;
    -- (102) A DEDUCTION TYPE LOWERS THE COST: what is typed is taken off (stored negative, whichever sign was sent). Any
    -- other type is a cost and cannot be negative.
    DECLARE @IsDeduction BIT = CASE WHEN EXISTS (SELECT 1 FROM purchase.ChargeTypes WHERE Id = @ChargeTypeId AND IsDeduction = 1) THEN 1 ELSE 0 END;
    IF @IsDeduction = 1
    BEGIN
        IF @Amount = 0 THROW 70000, 'Enter the amount deducted.', 1;
        SET @Amount = -ABS(@Amount);
    END
    ELSE IF @Amount < 0
        THROW 70000, 'The amount cannot be negative. To lower the cost, choose a deduction charge type (Deduction / refund).', 1;
    -- (102) the manual shares of a deduction are shares of what is taken off: negative, whichever sign was sent
    DECLARE @M TABLE (ContainerLineId INT NOT NULL, AmountBase DECIMAL(18,2) NOT NULL);
    INSERT INTO @M (ContainerLineId, AmountBase)
    SELECT ContainerLineId, CASE WHEN @IsDeduction = 1 THEN -ABS(AmountBase) ELSE AmountBase END FROM @Manual;
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

    IF @Method = N'Manual' AND @InLanded = 1 AND EXISTS (SELECT 1 FROM @M)
    BEGIN
        IF EXISTS (SELECT 1 FROM @M m WHERE NOT EXISTS (SELECT 1 FROM logistics.ContainerLines cl WHERE cl.Id = m.ContainerLineId AND cl.ContainerId = @ContainerId))
            THROW 70000, 'A manual share refers to a line that is not in the container.', 1;
        IF @IsDeduction = 0 AND EXISTS (SELECT 1 FROM @M WHERE AmountBase < 0) THROW 70000, 'Manual shares cannot be negative.', 1;
        IF ABS((SELECT SUM(AmountBase) FROM @M) - @AmountBase) > 0.01
        BEGIN
            DECLARE @Msg NVARCHAR(400) = N'The manual shares (' + CAST((SELECT SUM(AmountBase) FROM @M) AS NVARCHAR(30))
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
            IF EXISTS (SELECT 1 FROM @M)
            BEGIN
                DELETE FROM logistics.ContainerChargeAllocations WHERE ChargeId = @Id;
                INSERT INTO logistics.ContainerChargeAllocations (ChargeId, ContainerLineId, Basis, AmountBase, IsManual)
                SELECT @Id, ContainerLineId, NULL, AmountBase, 1 FROM @M WHERE AmountBase <> 0;     -- (102) a deduction's shares are negative
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
    -- (102) the sign is decided below, from the charge type: a deduction's copies are deductions
    IF @AllocationMethod IS NOT NULL AND @AllocationMethod NOT IN (N'Value', N'Quantity', N'Weight', N'Volume')
        THROW 70000, 'Allocation method of the copies must be Value, Quantity, Weight or Volume (a manual split can be typed on each draft afterwards).', 1;

    DECLARE @TypeMethod NVARCHAR(10), @TypeLabel NVARCHAR(120);
    SELECT @TypeMethod = AllocationMethod, @TypeLabel = ChargeCode + N' ' + ChargeName
    FROM purchase.ChargeTypes WHERE Id = @TypeId AND IsActive = 1;
    IF @TypeLabel IS NULL THROW 70000, 'The charge type of this charge is no longer active.', 1;

    DECLARE @Method NVARCHAR(10) = COALESCE(@AllocationMethod, CASE WHEN @SrcMethod = N'Manual' THEN @TypeMethod ELSE @SrcMethod END);
    IF @Method IS NULL OR @Method NOT IN (N'Value', N'Quantity', N'Weight', N'Volume') SET @Method = N'Value';
    SET @Amount = ISNULL(@Amount, @SrcAmount);
    IF EXISTS (SELECT 1 FROM purchase.ChargeTypes WHERE Id = @TypeId AND IsDeduction = 1)
        SET @Amount = -ABS(@Amount);
    ELSE IF @Amount < 0
        THROW 70000, 'The amount cannot be negative.', 1;
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

            -- (102) A DEDUCTION NEVER TAKES A COST BELOW ZERO: not a line's value with its charges (its FOB x the pieces,
            -- received or loaded, plus every posted charge on it) and, after the receipt, not the item's average cost.
            -- Refused here, inside the post's transaction, so nothing of it is kept.
            IF @AmountBase < 0
            BEGIN
                SET @Msg = NULL;
                SELECT TOP (1) @Msg = N'Container ' + @Ref + N': this deduction would bring ' + i.ItemCode + N' below zero ('
                                    + CAST(CAST(cl.FobCostBase * ISNULL(cl.ReceivedQuantityBase, cl.QuantityBase) + cl.ChargesBase AS DECIMAL(18,2)) AS NVARCHAR(30))
                                    + N' with its charges). Lower the deduction or allocate it differently.'
                FROM logistics.ContainerLines cl
                INNER JOIN inventory.Items i ON i.Id = cl.ItemId
                WHERE cl.ContainerId = @ContainerId AND cl.FobCostBase IS NOT NULL
                  AND cl.FobCostBase * ISNULL(cl.ReceivedQuantityBase, cl.QuantityBase) + ISNULL(cl.ChargesBase, 0) < 0
                ORDER BY cl.LineNumber;
                IF @Msg IS NOT NULL THROW 70013, @Msg, 1;

                IF @After = 1
                BEGIN
                    SELECT TOP (1) @Msg = N'Container ' + @Ref + N': this deduction would bring the average cost of ' + i.ItemCode
                                        + N' below zero (' + CAST(CAST(i.AverageCost AS DECIMAL(18,2)) AS NVARCHAR(30)) + N'). Lower the deduction.'
                    FROM inventory.Items i
                    WHERE i.AverageCost < 0
                      AND i.Id IN (SELECT cl.ItemId FROM logistics.ContainerChargeAllocations a
                                   INNER JOIN logistics.ContainerLines cl ON cl.Id = a.ContainerLineId
                                   WHERE a.ChargeId = @ChargeId)
                    ORDER BY i.ItemCode;
                    IF @Msg IS NOT NULL THROW 70013, @Msg, 1;
                END
            END

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

CREATE OR ALTER PROCEDURE logistics.usp_ContainerCharge_ApplyCost
    @ChargeId INT,
    @Sign     SMALLINT,
    @UserId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ContainerId INT, @Ref NVARCHAR(30), @BranchId INT, @WarehouseId INT, @AdjustedAfter BIT;
    SELECT @ContainerId = c.Id, @Ref = c.ContainerRef, @BranchId = c.BranchId, @WarehouseId = c.WarehouseId,
           @AdjustedAfter = ch.AdjustedAfterOffload                                  -- (89) for the cancel's cap
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

    -- per item: what the container brought, and how much of it can still be in stock - (89) capped by the COMPANY's
    -- stock of the item, every warehouse (was: the receiving warehouse's stock)
    DECLARE @Items TABLE (ItemId INT PRIMARY KEY, Received DECIMAL(18,6), Remaining DECIMAL(18,6), CompanyOnHand DECIMAL(18,6));
    INSERT INTO @Items (ItemId, Received, Remaining, CompanyOnHand)
    SELECT x.ItemId, x.Received,
           CASE WHEN oh.Q < x.Received THEN CASE WHEN oh.Q > 0 THEN oh.Q ELSE 0 END ELSE x.Received END,
           oh.Q
    FROM (SELECT cl.ItemId, Received = SUM(ISNULL(cl.ReceivedQuantityBase, 0))
          FROM logistics.ContainerLines cl
          WHERE cl.ContainerId = @ContainerId
          GROUP BY cl.ItemId) x
    CROSS APPLY (SELECT Q = inventory.fn_StockOnHand(x.ItemId, NULL)) oh                -- (89) NULL: every warehouse
    WHERE x.ItemId IN (SELECT ItemId FROM @Adj);

    UPDATE a
    SET Inv = CASE WHEN i.CompanyOnHand <= 0 OR i.Received <= 0 THEN 0 ELSE ROUND(a.Delta * i.Remaining / i.Received, 2) END
    FROM @Adj a
    INNER JOIN @Items i ON i.ItemId = a.ItemId;

    -- (89) A CANCEL NEVER TAKES MORE OUT OF STOCK THAN ITS POSTING PUT IN, per item. The stock part above is worked out
    --      again with today's stock - right when goods were sold since the posting (they took their share of the charge
    --      to cost of sales at the average) - but it can exceed what the posting put in: a charge posted before script 89
    --      (the receiving warehouse's stock decided then), or pieces of other purchases received since (they count as the
    --      container's). Taking out more would push the average below where it was before the charge. It is lowered to
    --      the posting's Inventory rows, in proportion over the item's lines, the cents on the line with the largest
    --      amount; the rest goes to cost of sales. A charge frozen in the goods' cost at the receipt (AppliedAtOffload)
    --      put all of it in stock: no cap.
    IF @Sign = -1 AND @AdjustedAfter = 1
    BEGIN
        DECLARE @Cap TABLE (ItemId INT PRIMARY KEY, Posted DECIMAL(18,2) NOT NULL, TakenOut DECIMAL(18,2) NOT NULL);
        INSERT INTO @Cap (ItemId, Posted, TakenOut)
        SELECT a.ItemId,
               ISNULL((SELECT SUM(c.AmountBase) FROM inventory.CostAdjustments c
                       WHERE c.SourceKind = N'CNTCHARGE' AND c.SourceId = @ChargeId AND c.Kind = N'Inventory'
                         AND c.ItemId = a.ItemId), 0),
               -SUM(ISNULL(a.Inv, 0))
        FROM @Adj a
        GROUP BY a.ItemId;
        UPDATE @Cap SET Posted = 0 WHERE Posted < 0;

        UPDATE a
        SET Inv = -ROUND(-ISNULL(a.Inv, 0) * c.Posted / c.TakenOut, 2)
        FROM @Adj a
        INNER JOIN @Cap c ON c.ItemId = a.ItemId
        WHERE c.TakenOut > c.Posted;                                     -- TakenOut > Posted >= 0: never a division by 0

        ;WITH d AS (SELECT a.LineId, Diff = -c.Posted - SUM(ISNULL(a.Inv, 0)) OVER (PARTITION BY a.ItemId),
                           Rn = ROW_NUMBER() OVER (PARTITION BY a.ItemId ORDER BY ABS(a.Delta) DESC, a.LineId)
                    FROM @Adj a
                    INNER JOIN @Cap c ON c.ItemId = a.ItemId
                    WHERE c.TakenOut > c.Posted)
        UPDATE a SET Inv = ISNULL(a.Inv, 0) + d.Diff
        FROM @Adj a
        INNER JOIN d ON d.LineId = a.LineId
        WHERE d.Rn = 1 AND d.Diff <> 0;
    END

    -- (102) THE MIRROR FOR A DEDUCTION: its cancel puts back into stock no more than its posting took out of it, per item
    --       (pieces received since would otherwise get a share of it); the rest goes back to cost of sales. The cap above
    --       does nothing for a deduction (what it took out is negative).
    IF @Sign = -1 AND @AdjustedAfter = 1 AND EXISTS (SELECT 1 FROM logistics.ContainerCharges WHERE Id = @ChargeId AND AmountBase < 0)
    BEGIN
        DECLARE @Back TABLE (ItemId INT PRIMARY KEY, TookOut DECIMAL(18,2) NOT NULL, PutBack DECIMAL(18,2) NOT NULL);
        INSERT INTO @Back (ItemId, TookOut, PutBack)
        SELECT a.ItemId,
               -ISNULL((SELECT SUM(c.AmountBase) FROM inventory.CostAdjustments c
                        WHERE c.SourceKind = N'CNTCHARGE' AND c.SourceId = @ChargeId AND c.Kind = N'Inventory'
                          AND c.ItemId = a.ItemId), 0),
               SUM(ISNULL(a.Inv, 0))
        FROM @Adj a
        GROUP BY a.ItemId;
        UPDATE @Back SET TookOut = 0 WHERE TookOut < 0;

        UPDATE a
        SET Inv = ROUND(ISNULL(a.Inv, 0) * b.TookOut / b.PutBack, 2)
        FROM @Adj a
        INNER JOIN @Back b ON b.ItemId = a.ItemId
        WHERE b.PutBack > b.TookOut;                                     -- PutBack > TookOut >= 0: never a division by 0

        ;WITH d AS (SELECT a.LineId, Diff = b.TookOut - SUM(ISNULL(a.Inv, 0)) OVER (PARTITION BY a.ItemId),
                           Rn = ROW_NUMBER() OVER (PARTITION BY a.ItemId ORDER BY ABS(a.Delta) DESC, a.LineId)
                    FROM @Adj a
                    INNER JOIN @Back b ON b.ItemId = a.ItemId
                    WHERE b.PutBack > b.TookOut)
        UPDATE a SET Inv = ISNULL(a.Inv, 0) + d.Diff
        FROM @Adj a
        INNER JOIN d ON d.LineId = a.LineId
        WHERE d.Rn = 1 AND d.Diff <> 0;
    END

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

CREATE OR ALTER FUNCTION logistics.fn_ContainerChargeSettlement (@ChargeId INT)
RETURNS TABLE
AS
RETURN
(
    SELECT p.PaidAmount,
           -- (102) a deduction is not paid: nothing outstanding, and its own status
           OutstandingAmount = CASE WHEN c.Status = 2 THEN CASE WHEN c.Amount < 0 THEN 0 ELSE c.Amount - p.PaidAmount END END,
           PaymentStatus     = CASE WHEN c.Status <> 2 THEN NULL
                                    WHEN c.Amount < 0 THEN N'Deduction'
                                    WHEN c.Amount - p.PaidAmount <= 0.005 THEN N'Paid'
                                    WHEN p.PaidAmount <= 0 THEN N'Unpaid'
                                    ELSE N'Partial' END
    FROM logistics.ContainerCharges c
    CROSS APPLY (SELECT PaidAmount = ISNULL((SELECT SUM(a.AmountDocCurrency)
                                             FROM purchase.PaymentAllocations a
                                             INNER JOIN purchase.Payments pay ON pay.Id = a.PaymentId
                                             WHERE a.ContainerChargeId = c.Id AND a.RemovedAtUtc IS NULL AND pay.Status = 2), 0)) p
    WHERE c.Id = @ChargeId
);
GO

/* ================================================================== 5. An invoice's own charges and landed cost adjustments */

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseCharges_Write
    @DocumentKind      NVARCHAR(10),
    @DocumentId        INT,
    @DocumentDate      DATE,
    @DefaultCurrencyId INT,
    @TargetInvoiceId   INT,
    @Charges           purchase.tvp_PurchaseCharge READONLY,
    @ManualAllocations purchase.tvp_ManualAllocation READONLY,
    @UserId            INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg = N'Charge ' + CAST(c.LineNumber AS NVARCHAR(10)) + N': ' +
        CASE WHEN ct.Id IS NULL THEN N'charge type not found.'
             WHEN ct.IsActive = 0 THEN N'charge type ' + ct.ChargeName + N' is inactive.'
             WHEN c.Amount < 0 AND ct.IsDeduction = 0 THEN N'amount cannot be negative (to lower the cost, choose a deduction charge type).'
             WHEN c.Amount = 0 AND ct.IsDeduction = 1 THEN N'enter the amount deducted.'
             WHEN c.AllocationMethod IS NOT NULL AND c.AllocationMethod NOT IN (N'Value', N'Quantity', N'Weight', N'Volume', N'Manual') THEN N'unknown allocation method.'
             WHEN c.ExchangeRate IS NOT NULL AND c.ExchangeRate <= 0 THEN N'exchange rate must be greater than zero.'
             WHEN c.CurrencyId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = c.CurrencyId AND IsActive = 1) THEN N'currency not found or inactive.'
             WHEN c.ProviderPartyId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = c.ProviderPartyId AND IsActive = 1) THEN N'provider not found or inactive.' END
    FROM @Charges c
    LEFT JOIN purchase.ChargeTypes ct ON ct.Id = c.ChargeTypeId
    WHERE ct.Id IS NULL OR ct.IsActive = 0 OR (c.Amount < 0 AND ct.IsDeduction = 0) OR (c.Amount = 0 AND ct.IsDeduction = 1)
       OR (c.AllocationMethod IS NOT NULL AND c.AllocationMethod NOT IN (N'Value', N'Quantity', N'Weight', N'Volume', N'Manual'))
       OR (c.ExchangeRate IS NOT NULL AND c.ExchangeRate <= 0)
       OR (c.CurrencyId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = c.CurrencyId AND IsActive = 1))
       OR (c.ProviderPartyId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = c.ProviderPartyId AND IsActive = 1))
    ORDER BY c.LineNumber;
    IF @Msg IS NOT NULL THROW 65012, @Msg, 1;

    -- (102) A DEDUCTION TYPE LOWERS THE COST: its amount and its manual shares are stored negative, whichever sign was sent.
    SELECT * INTO #DedCharges FROM @Charges;
    UPDATE c SET Amount = -ABS(c.Amount)
    FROM #DedCharges c INNER JOIN purchase.ChargeTypes ct ON ct.Id = c.ChargeTypeId
    WHERE ct.IsDeduction = 1;
    SELECT * INTO #DedManual FROM @ManualAllocations;
    UPDATE m SET AmountBase = -ABS(m.AmountBase)
    FROM #DedManual m
    INNER JOIN @Charges c ON c.LineNumber = m.ChargeLineNumber
    INNER JOIN purchase.ChargeTypes ct ON ct.Id = c.ChargeTypeId
    WHERE ct.IsDeduction = 1;

    -- Resolve currency + rate per charge (base currency -> 1).
    DECLARE @Resolved TABLE (LineNumber INT PRIMARY KEY, CurrencyId INT, RateType TINYINT, Rate DECIMAL(18,6), AmountBase DECIMAL(18,2), Method NVARCHAR(10), InLanded BIT);
    INSERT INTO @Resolved (LineNumber, CurrencyId, RateType, Rate, AmountBase, Method, InLanded)
    SELECT c.LineNumber, cur.Id, ISNULL(c.RateType, 1),
           r.Rate,
           ROUND(c.Amount / NULLIF(r.Rate, 0), 2),
           ISNULL(c.AllocationMethod, ct.AllocationMethod),
           ct.IncludeInLandedCost
    FROM #DedCharges c
    INNER JOIN purchase.ChargeTypes ct ON ct.Id = c.ChargeTypeId
    CROSS APPLY (SELECT Id, IsBaseCurrency FROM masterdata.Currencies WHERE Id = ISNULL(c.CurrencyId, @DefaultCurrencyId)) cur
    CROSS APPLY (SELECT Rate = CASE WHEN cur.IsBaseCurrency = 1 THEN 1 ELSE COALESCE(c.ExchangeRate, masterdata.fn_GetRate(cur.Id, ISNULL(c.RateType, 1), @DocumentDate)) END) r;

    SELECT TOP (1) @Msg = N'Charge ' + CAST(LineNumber AS NVARCHAR(10)) + N': no exchange rate for its currency on ' + CONVERT(NVARCHAR(10), @DocumentDate, 120) + N' - add one or enter the rate.'
    FROM @Resolved WHERE Rate IS NULL ORDER BY LineNumber;
    IF @Msg IS NOT NULL THROW 65008, @Msg, 1;

    -- Manual allocations must match a Manual charge, reference lines of the target invoice and sum to the charge amount.
    IF EXISTS (SELECT 1 FROM #DedManual m LEFT JOIN @Resolved r ON r.LineNumber = m.ChargeLineNumber WHERE r.LineNumber IS NULL OR r.Method <> N'Manual')
        THROW 65012, 'A manual allocation refers to a charge that does not exist or is not allocated manually.', 1;
    IF EXISTS (SELECT 1 FROM #DedManual m WHERE NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines l WHERE l.Id = m.PurchaseLineId AND l.DocumentId = @TargetInvoiceId))
        THROW 65012, 'A manual allocation refers to a line that does not belong to the invoice.', 1;
    IF EXISTS (SELECT 1 FROM #DedManual m INNER JOIN @Resolved r ON r.LineNumber = m.ChargeLineNumber
               INNER JOIN #DedCharges c ON c.LineNumber = m.ChargeLineNumber
               INNER JOIN purchase.ChargeTypes ct ON ct.Id = c.ChargeTypeId
               WHERE m.AmountBase < 0 AND ct.IsDeduction = 0)
        THROW 65012, 'Manual allocation amounts cannot be negative.', 1;
    SELECT TOP (1) @Msg = N'Charge ' + CAST(r.LineNumber AS NVARCHAR(10)) + N': manual allocations (' + CAST(ISNULL(m.Total, 0) AS NVARCHAR(30)) + N') must equal the charge amount in base currency (' + CAST(r.AmountBase AS NVARCHAR(30)) + N').'
    FROM @Resolved r
    LEFT JOIN (SELECT ChargeLineNumber, Total = SUM(AmountBase) FROM #DedManual GROUP BY ChargeLineNumber) m ON m.ChargeLineNumber = r.LineNumber
    WHERE r.Method = N'Manual' AND r.InLanded = 1 AND r.AmountBase <> 0 AND ABS(ISNULL(m.Total, 0) - r.AmountBase) > 0.01
    ORDER BY r.LineNumber;
    IF @Msg IS NOT NULL THROW 65012, @Msg, 1;

    -- (102) THE DEDUCTIONS NEVER TAKE MORE THAN THE GOODS ARE WORTH: what they take off, in the base currency, is at most
    -- the invoice's lines (their value, at the invoice's rate).
    DECLARE @Deducted DECIMAL(18,2) = (SELECT -SUM(AmountBase) FROM @Resolved WHERE AmountBase < 0 AND InLanded = 1);
    IF @Deducted > (SELECT ISNULL(SUM(l.LineTotal / NULLIF(d.ExchangeRate, 0)), 0)
                    FROM purchase.PurchaseDocumentLines l
                    INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
                    WHERE l.DocumentId = @TargetInvoiceId)
    BEGIN
        SET @Msg = N'The deductions (' + CAST(@Deducted AS NVARCHAR(30)) + N' in base currency) are more than the goods of the invoice are worth.';
        THROW 65012, @Msg, 1;
    END

    DELETE a FROM purchase.PurchaseChargeAllocations a INNER JOIN purchase.PurchaseCharges c ON c.Id = a.ChargeId WHERE c.DocumentKind = @DocumentKind AND c.DocumentId = @DocumentId;
    DELETE FROM purchase.PurchaseCharges WHERE DocumentKind = @DocumentKind AND DocumentId = @DocumentId;

    INSERT INTO purchase.PurchaseCharges (DocumentKind, DocumentId, LineNumber, ChargeTypeId, Description, ProviderPartyId, Reference, CurrencyId, RateType, ExchangeRate,
                                          Amount, AmountBase, AllocationMethod, IncludeInLandedCost, IncludedInSupplierInvoice, Notes, CreatedBy)
    SELECT @DocumentKind, @DocumentId, c.LineNumber, c.ChargeTypeId, NULLIF(LTRIM(RTRIM(c.Description)), N''), c.ProviderPartyId, NULLIF(LTRIM(RTRIM(c.Reference)), N''),
           r.CurrencyId, r.RateType, r.Rate, c.Amount, r.AmountBase, r.Method, r.InLanded, ISNULL(c.IncludedInSupplierInvoice, 0), NULLIF(LTRIM(RTRIM(c.Notes)), N''), @UserId
    FROM #DedCharges c INNER JOIN @Resolved r ON r.LineNumber = c.LineNumber;

    INSERT INTO purchase.PurchaseChargeAllocations (ChargeId, PurchaseLineId, Basis, AmountBase, IsManual)
    SELECT pc.Id, m.PurchaseLineId, NULL, m.AmountBase, 1
    FROM #DedManual m
    INNER JOIN purchase.PurchaseCharges pc ON pc.DocumentKind = @DocumentKind AND pc.DocumentId = @DocumentId AND pc.LineNumber = m.ChargeLineNumber
    WHERE pc.IncludeInLandedCost = 1;
END
GO

/* ================================================================== 6. Check */

SELECT ChargeCode, ChargeName, AllocationMethod, IncludeInLandedCost, IsDeduction FROM purchase.ChargeTypes WHERE IsDeduction = 1;

PRINT 'Script 102 applied: deduction charge types (DED "Deduction / refund"): a charge that lowers the cost of the goods.';
GO
