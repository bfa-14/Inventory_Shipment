SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 113: LOGISTICS - A CONTAINER CHARGE PAID CASH OR ON ACCOUNT

   The owner: "when the charge is paid cash, an automatic payment is done related to the container charge and its
   status is Paid; on account, the charge is unpaid and the amount payable to the charge's supplier". The Payment
   panel of a sales invoice (script 38), on a container charge:

     1. logistics.ContainerCharges: PaymentType (1 Cash, 2 On account; every charge before this script On account,
        what it always was), PaymentMethodId, PaymentAccountId (the cash / bank account it was paid from) and
        PaymentReference (a transfer no.). purchase.Payments.FromChargePost: the payment a cash charge made.
     2. logistics.fn_ContainerCharge_PaymentProblem: one place for what a cash charge needs - its provider (the payee,
        an active supplier), a payment method that is not a cheque (a cheque has its own details: pay it with
        Supplier Payments), an active account holding the charge's currency; a deduction is never paid cash.
        Checked when a charge is saved and again when it is posted.
     3. logistics.usp_ContainerCharge_PayCash: the payment of posted cash charges, through the supplier payment module
        (usp_Payment_Save + usp_Payment_Post, a Container Charge Payment): ONE payment for the charges of one group
        posted together (a charge split over containers), else one per charge, for the whole amount at the charge's
        own rate, dated the charge date; the charge is then Paid.
     4. usp_ContainerCharge_Create / _Update (re-created from script 102's bodies): + the four fields (NULL = On
        account); _CopyToContainers (102): the copies take the source's. usp_ContainerCharge_Post (102): a cash
        charge pays for itself inside the post's transaction - a refused payment posts nothing.
     5. usp_ContainerCharge_Cancel (97): its automatic payment is reversed with it (other payments still block it);
        the other charges that payment paid get a payment of their own again. purchase.usp_Payment_Reverse (47):
        refuses an automatic payment on its own (73010: cancel the charge instead), unless its charge's cancel asks.
     6. usp_ContainerCharge_Get (97) / _Search (47) and purchase.usp_Payment_Get (73) read the new fields.

   Errors: no new number (70000 a cash charge incomplete, 73010 an automatic payment reversed alone).
   Requires scripts 38, 47, 73, 97 and 102. Idempotent.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF COL_LENGTH(N'purchase.ChargeTypes', N'IsDeduction') IS NULL
   OR COL_LENGTH(N'logistics.ContainerCharges', N'BivacItemId') IS NULL
   OR OBJECT_ID(N'purchase.Payments', N'U') IS NULL
    THROW 50000, 'Script 113 requires scripts 47, 97 and 102: apply them first.', 1;
GO

/* ================================================================== 1. Columns */

IF COL_LENGTH(N'logistics.ContainerCharges', N'PaymentType') IS NULL
    ALTER TABLE logistics.ContainerCharges ADD PaymentType TINYINT NOT NULL
        CONSTRAINT DF_ContainerCharges_PaymentType DEFAULT (2) WITH VALUES;
GO
IF COL_LENGTH(N'logistics.ContainerCharges', N'PaymentMethodId') IS NULL
    ALTER TABLE logistics.ContainerCharges ADD PaymentMethodId INT NULL;
GO
IF COL_LENGTH(N'logistics.ContainerCharges', N'PaymentAccountId') IS NULL
    ALTER TABLE logistics.ContainerCharges ADD PaymentAccountId INT NULL;
GO
IF COL_LENGTH(N'logistics.ContainerCharges', N'PaymentReference') IS NULL
    ALTER TABLE logistics.ContainerCharges ADD PaymentReference NVARCHAR(100) NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_ContainerCharges_PaymentType')
    ALTER TABLE logistics.ContainerCharges ADD CONSTRAINT CK_ContainerCharges_PaymentType CHECK (PaymentType IN (1, 2));
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_ContainerCharges_PaymentMethod')
    ALTER TABLE logistics.ContainerCharges ADD CONSTRAINT FK_ContainerCharges_PaymentMethod FOREIGN KEY (PaymentMethodId) REFERENCES masterdata.PaymentMethods (Id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_ContainerCharges_PaymentAccount')
    ALTER TABLE logistics.ContainerCharges ADD CONSTRAINT FK_ContainerCharges_PaymentAccount FOREIGN KEY (PaymentAccountId) REFERENCES masterdata.CashBankAccounts (Id);
GO
IF COL_LENGTH(N'purchase.Payments', N'FromChargePost') IS NULL
    ALTER TABLE purchase.Payments ADD FromChargePost BIT NOT NULL CONSTRAINT DF_Payments_FromChargePost DEFAULT (0) WITH VALUES;
GO

/* ================================================================== 2. What a cash charge needs */

CREATE OR ALTER FUNCTION logistics.fn_ContainerCharge_PaymentProblem
(
    @PaymentType     TINYINT,
    @MethodId        INT,
    @AccountId       INT,
    @CurrencyId      INT,
    @ProviderPartyId INT,
    @ChargeTypeId    INT
)
RETURNS TABLE
AS
RETURN
(
    SELECT Message =
        CASE WHEN ISNULL(@PaymentType, 2) NOT IN (1, 2) THEN N'Payment Type must be Cash or On account.'
             WHEN ISNULL(@PaymentType, 2) = 2 THEN NULL
             WHEN EXISTS (SELECT 1 FROM purchase.ChargeTypes WHERE Id = @ChargeTypeId AND IsDeduction = 1)
                  THEN N'A deduction is not paid: choose On account.'
             WHEN @ProviderPartyId IS NULL THEN N'A cash charge is paid to its provider: choose the provider.'
             WHEN NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @ProviderPartyId AND IsActive = 1 AND IsSupplier = 1)
                  THEN N'The provider is not an active supplier, so it cannot be paid: choose On account.'
             WHEN @MethodId IS NULL THEN N'A cash charge needs its Payment Method.'
             WHEN NOT EXISTS (SELECT 1 FROM masterdata.PaymentMethods WHERE Id = @MethodId AND IsActive = 1)
                  THEN N'The payment method is no longer active.'
             WHEN EXISTS (SELECT 1 FROM masterdata.PaymentMethods WHERE Id = @MethodId AND MethodCode = N'CHQ')
                  THEN N'A cheque is paid with Purchase > Supplier Payments, where its details are typed: choose On account.'
             WHEN @AccountId IS NULL THEN N'A cash charge needs the Cash / Bank Account it was paid from.'
             ELSE (SELECT CASE WHEN a.IsActive = 0 THEN N'The account ' + a.AccountCode + N' is no longer active.'
                               WHEN a.CurrencyId <> @CurrencyId THEN N'The account ' + a.AccountCode + N' holds ' + ac.CurrencyCode
                                    + N', but this charge is in ' + ISNULL(cc.CurrencyCode, N'another currency') + N'. Choose an account in '
                                    + ISNULL(cc.CurrencyCode, N'the charge''s currency') + N'.' END
                   FROM (SELECT 1 AS One) one
                   LEFT JOIN masterdata.CashBankAccounts a ON a.Id = @AccountId
                   LEFT JOIN masterdata.Currencies ac      ON ac.Id = a.CurrencyId
                   LEFT JOIN masterdata.Currencies cc      ON cc.Id = @CurrencyId)
        END
);
GO

/* ================================================================== 3. The payment of posted cash charges */

CREATE OR ALTER PROCEDURE logistics.usp_ContainerCharge_PayCash
    @Ids    logistics.tvp_IdList READONLY,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Posted cash charges not yet paid by a payment of their own; one payment per key: the charges of one group
    -- posted together share it when they share its payee, currency, method, account, reference, branch and date.
    DECLARE @C TABLE (Id INT PRIMARY KEY, PayKey NVARCHAR(400) NOT NULL, ContainerId INT NOT NULL, ContainerRef NVARCHAR(30) NOT NULL);
    INSERT INTO @C (Id, PayKey, ContainerId, ContainerRef)
    SELECT ch.Id,
           CONCAT(ISNULL(CAST(ch.GroupId AS NVARCHAR(36)), N'#' + CAST(ch.Id AS NVARCHAR(10))), N'|', ch.ProviderPartyId, N'|', ch.CurrencyId,
                  N'|', ch.PaymentMethodId, N'|', ch.PaymentAccountId, N'|', ISNULL(ch.PaymentReference, N''), N'|', c.BranchId,
                  N'|', CONVERT(NVARCHAR(10), ch.ChargeDate, 120)),
           ch.ContainerId, c.ContainerRef
    FROM @Ids x
    INNER JOIN logistics.ContainerCharges ch ON ch.Id = x.Id
    INNER JOIN logistics.Containers c        ON c.Id = ch.ContainerId
    WHERE ch.Status = 2 AND ch.PaymentType = 1 AND ch.Amount > 0
      AND NOT EXISTS (SELECT 1 FROM purchase.PaymentAllocations a INNER JOIN purchase.Payments p ON p.Id = a.PaymentId
                      WHERE a.ContainerChargeId = ch.Id AND a.RemovedAtUtc IS NULL AND p.Status = 2 AND p.FromChargePost = 1);
    IF NOT EXISTS (SELECT 1 FROM @C) RETURN;

    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg = N'Container ' + x.ContainerRef + N': ' + pp.Message
    FROM @C x
    INNER JOIN logistics.ContainerCharges ch ON ch.Id = x.Id
    CROSS APPLY logistics.fn_ContainerCharge_PaymentProblem(ch.PaymentType, ch.PaymentMethodId, ch.PaymentAccountId, ch.CurrencyId,
                                                            ch.ProviderPartyId, ch.ChargeTypeId) pp
    WHERE pp.Message IS NOT NULL
    ORDER BY x.ContainerRef;
    IF @Msg IS NOT NULL THROW 70000, @Msg, 1;

    DECLARE @Key NVARCHAR(400), @First INT, @PayeeId INT, @BranchId INT, @CurrencyId INT, @MethodId INT, @AccountId INT,
            @PayRef NVARCHAR(100), @PayDate DATE, @Rate DECIMAL(18,6), @Total DECIMAL(18,2), @Notes NVARCHAR(500),
            @PaymentId INT, @PaymentNo NVARCHAR(30), @Cur NVARCHAR(10);
    DECLARE keys CURSOR LOCAL STATIC READ_ONLY FORWARD_ONLY FOR SELECT PayKey, MIN(Id) FROM @C GROUP BY PayKey ORDER BY MIN(Id);
    OPEN keys;
    FETCH NEXT FROM keys INTO @Key, @First;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT @PayeeId = ch.ProviderPartyId, @BranchId = c.BranchId, @CurrencyId = ch.CurrencyId, @MethodId = ch.PaymentMethodId,
               @AccountId = ch.PaymentAccountId, @PayRef = ch.PaymentReference, @PayDate = ch.ChargeDate, @Rate = ch.ExchangeRate,
               @Cur = cur.CurrencyCode
        FROM logistics.ContainerCharges ch
        INNER JOIN logistics.Containers c    ON c.Id = ch.ContainerId
        INNER JOIN masterdata.Currencies cur ON cur.Id = ch.CurrencyId
        WHERE ch.Id = @First;

        SELECT @Total = SUM(ch.Amount),
               @Notes = LEFT(N'Automatic payment of a container charge paid cash: '
                             + STRING_AGG(CAST(x.ContainerRef AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY x.ContainerRef), 500)
        FROM @C x INNER JOIN logistics.ContainerCharges ch ON ch.Id = x.Id
        WHERE x.PayKey = @Key;

        DECLARE @Lines purchase.tvp_PaymentLine, @Allocs purchase.tvp_PaymentAllocation, @Split purchase.tvp_PaymentAllocationContainer;
        DELETE FROM @Lines;
        DELETE FROM @Allocs;
        INSERT INTO @Lines (LineNumber, PaymentMethodId, CurrencyId, Amount, RateToPayment, CashBankAccountId, Reference)
        VALUES (1, @MethodId, @CurrencyId, @Total, 1, @AccountId, @PayRef);
        INSERT INTO @Allocs (DocumentKind, DocumentId, Amount, RateToPayment)
        SELECT N'CHARGE', ch.Id, ch.Amount, 1
        FROM @C x INNER JOIN logistics.ContainerCharges ch ON ch.Id = x.Id
        WHERE x.PayKey = @Key;

        SET @PaymentId = NULL;
        EXEC purchase.usp_Payment_Save @Id = NULL, @PaymentDate = @PayDate, @PayeeId = @PayeeId, @BranchId = @BranchId,
             @PaymentType = 3, @CurrencyId = @CurrencyId, @Amount = @Total, @ExchangeRate = @Rate, @Reference = @PayRef,
             @Notes = @Notes, @Lines = @Lines, @Allocations = @Allocs, @AllocationContainers = @Split,
             @RowVersion = NULL, @UserId = @UserId, @NewId = @PaymentId OUTPUT;

        UPDATE purchase.Payments SET FromChargePost = 1 WHERE Id = @PaymentId;
        SET @PaymentNo = (SELECT PaymentNumber FROM purchase.Payments WHERE Id = @PaymentId);
        INSERT INTO purchase.PaymentAudit (PaymentId, Action, Details, UserId)
        VALUES (@PaymentId, N'AutoCreated', N'Created automatically by posting a container charge paid cash', @UserId);

        EXEC purchase.usp_Payment_Post @Id = @PaymentId, @RowVersion = NULL, @UserId = @UserId;

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        SELECT x.ContainerId, N'Updated',
               LEFT(N'Charge paid cash: ' + t.ChargeCode + N' ' + t.ChargeName + N' ' + CAST(ch.Amount AS NVARCHAR(30)) + N' ' + @Cur
                    + N' (payment ' + ISNULL(@PaymentNo, N'#' + CAST(@PaymentId AS NVARCHAR(10))) + N')', 500), @UserId
        FROM @C x
        INNER JOIN logistics.ContainerCharges ch ON ch.Id = x.Id
        INNER JOIN purchase.ChargeTypes t        ON t.Id = ch.ChargeTypeId
        WHERE x.PayKey = @Key;

        FETCH NEXT FROM keys INTO @Key, @First;
    END
    CLOSE keys;
    DEALLOCATE keys;
END
GO

/* ================================================================== 4-6. The procedures re-created */

-- Re-created (113) from script 102's body: + PaymentType, PaymentMethodId, PaymentAccountId, PaymentReference. Nothing else changes.
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
    @BivacItemId      INT            = NULL,      -- (97) the BIVAC item of a BIVAC charge (charge type BIV)
    @PaymentType      TINYINT        = NULL,      -- (113) 1 Cash, 2 On account (NULL = On account)
    @PaymentMethodId  INT            = NULL,      -- (113) Cash: how it was paid
    @PaymentAccountId INT            = NULL,      -- (113) Cash: the cash / bank account it was paid from
    @PaymentReference NVARCHAR(100)  = NULL       -- (113) Cash: a transfer no.
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

    -- (113) how the charge is paid: Cash pays it when it is posted, On account leaves it payable to its provider
    SET @PaymentType = ISNULL(@PaymentType, 2);
    SET @PaymentReference = NULLIF(LTRIM(RTRIM(@PaymentReference)), N'');
    IF @PaymentType = 2 SELECT @PaymentMethodId = NULL, @PaymentAccountId = NULL, @PaymentReference = NULL;
    SET @Msg = (SELECT p.Message FROM logistics.fn_ContainerCharge_PaymentProblem(@PaymentType, @PaymentMethodId, @PaymentAccountId,
                                                                                  @CurrencyId, @ProviderPartyId, @ChargeTypeId) p);
    IF @Msg IS NOT NULL THROW 70000, @Msg, 1;

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
                                                BivacItemId, PaymentType, PaymentMethodId, PaymentAccountId, PaymentReference)
        OUTPUT inserted.Id, inserted.ContainerId INTO @New (Id, ContainerId)
        SELECT s.ContainerId, @MovementId, @Group, @ChargeTypeId, @Description, @ProviderPartyId, @Reference, @ChargeDate,
               @CurrencyId, @RateType, @Rate, s.Amount, ROUND(s.Amount / @Rate, 2), @Method, @InLanded, @Notes, @UserId,
               @BivacItemId, @PaymentType, @PaymentMethodId, @PaymentAccountId, @PaymentReference
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

-- Re-created (113) from script 102's body: + the four payment fields. Nothing else changes.
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
    @UserId           INT            = NULL,
    @PaymentType      TINYINT        = NULL,      -- (113) 1 Cash, 2 On account (NULL = On account)
    @PaymentMethodId  INT            = NULL,
    @PaymentAccountId INT            = NULL,
    @PaymentReference NVARCHAR(100)  = NULL
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

    -- (113) how the charge is paid (see Create)
    SET @PaymentType = ISNULL(@PaymentType, 2);
    SET @PaymentReference = NULLIF(LTRIM(RTRIM(@PaymentReference)), N'');
    IF @PaymentType = 2 SELECT @PaymentMethodId = NULL, @PaymentAccountId = NULL, @PaymentReference = NULL;
    DECLARE @PayMsg NVARCHAR(400) = (SELECT p.Message FROM logistics.fn_ContainerCharge_PaymentProblem(@PaymentType, @PaymentMethodId,
                                         @PaymentAccountId, @CurrencyId, @ProviderPartyId, @ChargeTypeId) p);
    IF @PayMsg IS NOT NULL THROW 70000, @PayMsg, 1;

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
            PaymentType = @PaymentType, PaymentMethodId = @PaymentMethodId, PaymentAccountId = @PaymentAccountId, PaymentReference = @PaymentReference,
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

-- Re-created (113) from script 102's body: the copies take the source's payment fields. Nothing else changes.
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

        -- (113) the copies are paid as the charge copied is
        UPDATE ch SET PaymentType = src.PaymentType, PaymentMethodId = src.PaymentMethodId, PaymentAccountId = src.PaymentAccountId,
                      PaymentReference = src.PaymentReference
        FROM logistics.ContainerCharges ch
        INNER JOIN @New n ON n.Id = ch.Id
        CROSS JOIN logistics.ContainerCharges src
        WHERE src.Id = @ChargeId;

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

-- Re-created (113) from script 102's body: a cash charge pays for itself (usp_ContainerCharge_PayCash) before the commit. Nothing else changes.
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

        -- (113) A CASH CHARGE PAYS FOR ITSELF, through the supplier payment module: one payment for the charges of a group
        -- posted together, posted now. Refused, nothing of the post is kept.
        DECLARE @Paid logistics.tvp_IdList;
        INSERT INTO @Paid (Id) SELECT Id FROM @List;
        EXEC logistics.usp_ContainerCharge_PayCash @Paid, @UserId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Re-created (113) from script 97's body: its automatic payment is reversed with it. Nothing else changes.
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
                   WHERE a.ContainerChargeId = @Id AND a.RemovedAtUtc IS NULL AND p.Status = 2 AND p.FromChargePost = 0)   -- (113) not its own
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

        -- (113) the payment a cash charge made goes with it; the other charges it paid are paid again on their own
        DECLARE @AutoPay INT, @AutoNo NVARCHAR(30);
        SELECT TOP (1) @AutoPay = p.Id, @AutoNo = p.PaymentNumber
        FROM purchase.PaymentAllocations a INNER JOIN purchase.Payments p ON p.Id = a.PaymentId
        WHERE a.ContainerChargeId = @Id AND a.RemovedAtUtc IS NULL AND p.Status = 2 AND p.FromChargePost = 1;
        IF @AutoPay IS NOT NULL
        BEGIN
            DECLARE @Others logistics.tvp_IdList;
            INSERT INTO @Others (Id)
            SELECT ContainerChargeId FROM purchase.PaymentAllocations
            WHERE PaymentId = @AutoPay AND ContainerChargeId <> @Id AND RemovedAtUtc IS NULL;
            DECLARE @PayReason NVARCHAR(500) = LEFT(N'Container charge cancelled: ' + @Reason, 500);
            EXEC purchase.usp_Payment_Reverse @Id = @AutoPay, @Reason = @PayReason, @UserId = @UserId, @FromCharge = 1;
            IF EXISTS (SELECT 1 FROM @Others) EXEC logistics.usp_ContainerCharge_PayCash @Others, @UserId;
        END

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        VALUES (@ContainerId, N'Updated', LEFT(N'Charge cancelled: ' + @Label + N' - ' + @Reason
                                               + CASE WHEN @AutoPay IS NOT NULL THEN N' (payment ' + ISNULL(@AutoNo, N'') + N' reversed)' ELSE N'' END
                                               + CASE WHEN @InCost = 1 THEN N' (item costs adjusted back)' ELSE N'' END, 500), @UserId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Re-created (113) from script 47's body: + @FromCharge, an automatic payment is reversed only by its charge's cancel. Nothing else changes.
CREATE OR ALTER PROCEDURE purchase.usp_Payment_Reverse
    @Id         INT,
    @Reason     NVARCHAR(500),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL,
    @FromCharge BIT       = 0      -- (113) 1: the cancel of the cash charge that made it
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 73000, 'A reason is required to reverse a payment.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @Type TINYINT;
        SELECT @Status = Status, @Type = PaymentType FROM purchase.Payments WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;

        IF @Status IS NULL THROW 73006, 'Payment not found.', 1;
        IF @Status <> 2 THROW 73010, 'Only a posted payment can be reversed.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.Payments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 73004, 'This payment was modified by another user. Reload the page and try again.', 1;
        -- (113) a cash charge's payment is part of the charge: it goes when the charge is cancelled
        IF ISNULL(@FromCharge, 0) = 0 AND EXISTS (SELECT 1 FROM purchase.Payments WHERE Id = @Id AND FromChargePost = 1)
            THROW 73010, 'This payment was made automatically when a container charge paid cash was posted: cancel the charge instead.', 1;

        /* A FREE PAYMENT THAT HAS SINCE PAID DOCUMENTS CANNOT JUST VANISH: they would go back to owing money
           nobody told them about. Its allocations are removed first, so somebody decides about each one. An
           allocated payment's own allocations are part of it: reversing it simply stops them counting. */
        IF @Type = 1 AND EXISTS (SELECT 1 FROM purchase.PaymentAllocations WHERE PaymentId = @Id AND RemovedAtUtc IS NULL)
            THROW 73012, 'This payment has been applied to documents since it was posted. Remove those allocations before reversing it.', 1;

        UPDATE purchase.Payments
        SET Status = 3, ReversedAtUtc = SYSUTCDATETIME(), ReversedBy = @UserId, ReverseReason = @Reason,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO purchase.PaymentAudit (PaymentId, Action, Details, UserId) VALUES (@Id, N'Reversed', @Reason, @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Re-created (113) from script 97's body: + the payment fields and the payment a cash charge made. Nothing else changes.
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
           ch.BivacOutDocumentId, BivacOutNumber = bo.DocumentNumber, BivacOutStatus = bo.Status,
           -- (113) how it is paid, and the payment a cash charge made
           ch.PaymentType, ch.PaymentMethodId, PaymentMethodName = pm.MethodName, ch.PaymentAccountId,
           PaymentAccountCode = pa.AccountCode, PaymentAccountName = pa.AccountName, ch.PaymentReference,
           CashPaymentId = cp.Id, CashPaymentNumber = cp.PaymentNumber
    FROM logistics.ContainerCharges ch
    LEFT  JOIN inventory.Items bi          ON bi.Id = ch.BivacItemId
    LEFT  JOIN masterdata.PaymentMethods pm   ON pm.Id = ch.PaymentMethodId
    LEFT  JOIN masterdata.CashBankAccounts pa ON pa.Id = ch.PaymentAccountId
    OUTER APPLY (SELECT TOP (1) p.Id, p.PaymentNumber FROM purchase.PaymentAllocations a
                 INNER JOIN purchase.Payments p ON p.Id = a.PaymentId
                 WHERE a.ContainerChargeId = ch.Id AND a.RemovedAtUtc IS NULL AND p.Status = 2 AND p.FromChargePost = 1) cp
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

-- Re-created (113) from script 47's body: + PaymentType. Nothing else changes.
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
           -- (47) supplier payments: posted charges only (NULL otherwise)
           PaidAmount = pst.PaidAmount, OutstandingAmount = pst.OutstandingAmount, PaymentStatus = pst.PaymentStatus,
           ch.PaymentType,   -- (113)
           COUNT(*) OVER () AS TotalCount
    FROM logistics.ContainerCharges ch
    OUTER APPLY logistics.fn_ContainerChargeSettlement(ch.Id) pst
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

-- Re-created (113) from script 73's body: + FromChargePost. Nothing else changes.
CREATE OR ALTER PROCEDURE purchase.usp_Payment_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT p.Id, p.PaymentNumber, p.PaymentDate, p.PayeeId, py.PartyCode AS PayeeCode, py.PartyName AS PayeeName, py.Address AS PayeeAddress,
           p.BranchId, b.BranchCode, b.BranchName, p.PaymentType,
           p.CurrencyId, c.CurrencyCode, c.CurrencyName, c.Symbol AS CurrencySymbol, c.DecimalPlaces, c.IsBaseCurrency,
           p.Amount, p.ExchangeRate, p.AmountBase, bc.CurrencyCode AS BaseCurrencyCode,
           p.Reference, p.Notes, p.Status,
           LinesTotal     = ISNULL(ln.Total, 0),
           AllocatedTotal = ISNULL(al.Total, 0),
           -- Only a posted FREE payment holds an advance; an allocated one is spent by definition.
           UnappliedAmount = CASE WHEN p.Status = 2 AND p.PaymentType = 1 THEN p.Amount - ISNULL(al.Total, 0) ELSE 0 END,
           AllocationKind = al.Kind,
           p.PostedAtUtc, p.PostedBy, pu.FullName AS PostedByName,
           p.ReversedAtUtc, p.ReversedBy, ru.FullName AS ReversedByName, p.ReverseReason,
           p.CreatedAtUtc, p.CreatedBy, cu.FullName AS CreatedByName, p.UpdatedAtUtc, p.UpdatedBy, uu.FullName AS UpdatedByName,
           p.RowVersion,
           p.FromChargePost   -- (113) made by a container charge paid cash
    FROM purchase.Payments p
    INNER JOIN masterdata.Parties py    ON py.Id = p.PayeeId
    INNER JOIN masterdata.Branches b    ON b.Id = p.BranchId
    INNER JOIN masterdata.Currencies c  ON c.Id = p.CurrencyId
    LEFT  JOIN masterdata.Currencies bc ON bc.IsBaseCurrency = 1 AND bc.IsActive = 1
    OUTER APPLY (SELECT Total = SUM(AmountPaymentCurrency) FROM purchase.PaymentLines WHERE PaymentId = p.Id) ln
    OUTER APPLY (SELECT Total = SUM(AmountPaymentCurrency), Kind = MIN(DocumentKind)
                 FROM purchase.PaymentAllocations WHERE PaymentId = p.Id AND RemovedAtUtc IS NULL) al
    LEFT  JOIN security.Users pu ON pu.Id = p.PostedBy
    LEFT  JOIN security.Users ru ON ru.Id = p.ReversedBy
    LEFT  JOIN security.Users cu ON cu.Id = p.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = p.UpdatedBy
    WHERE p.Id = @Id;

    SELECT l.Id, l.PaymentId, l.LineNumber, l.PaymentMethodId, pm.MethodCode, pm.MethodName,
           IsCheque = CAST(CASE WHEN pm.MethodCode = N'CHQ' THEN 1 ELSE 0 END AS BIT),
           l.CurrencyId, cu.CurrencyCode, cu.DecimalPlaces, l.Amount, l.RateToPayment, l.AmountPaymentCurrency, l.AmountBase,
           l.CashBankAccountId, a.AccountCode, a.AccountName, l.Reference,
           l.ChequeNo, l.ChequeDate, l.ChequeDueDate, l.ClearanceStatus,
           ClearanceStatusName = CASE l.ClearanceStatus WHEN 1 THEN N'Pending' WHEN 2 THEN N'Cleared' WHEN 3 THEN N'Returned' END,
           l.ClearanceUpdatedAtUtc, xu.FullName AS ClearanceUpdatedByName
    FROM purchase.PaymentLines l
    INNER JOIN masterdata.PaymentMethods pm  ON pm.Id = l.PaymentMethodId
    INNER JOIN masterdata.Currencies cu      ON cu.Id = l.CurrencyId
    INNER JOIN masterdata.CashBankAccounts a ON a.Id = l.CashBankAccountId
    LEFT  JOIN security.Users xu ON xu.Id = l.ClearanceUpdatedBy
    WHERE l.PaymentId = @Id
    ORDER BY l.LineNumber;

    /* PreviouslyPaid is what OTHER posted payments have paid the document: this payment's own share is
       taken out when it is posted and still live, so a draft and a posted payment read the same. */
    SELECT al.Id, al.PaymentId, al.DocumentKind, DocumentId = ISNULL(al.PurchaseDocumentId, al.ContainerChargeId),
           pd.DocumentNumber, pd.DocumentDate, pd.ContainerRef, pd.ChargeTypeName, pd.Reference AS DocumentReference,
           pd.CurrencyId AS DocumentCurrencyId, pd.CurrencyCode AS DocumentCurrencyCode, pd.DecimalPlaces AS DocumentDecimalPlaces,
           pd.DocumentTotal, pd.ReturnedAmount,
           PreviouslyPaid = pd.PaidAmount - CASE WHEN p.Status = 2 AND al.RemovedAtUtc IS NULL THEN al.AmountDocCurrency ELSE 0 END,
           pd.OutstandingAmount, pd.PaymentStatus,
           al.AmountDocCurrency, al.DocExchangeRate, al.RateToPayment, al.AmountPaymentCurrency, al.AmountBase,
           al.AllocatedAtUtc, au.FullName AS AllocatedByName, al.RemovedAtUtc, xu.FullName AS RemovedByName
    FROM purchase.PaymentAllocations al
    INNER JOIN purchase.Payments p ON p.Id = al.PaymentId
    CROSS APPLY purchase.fn_PayableDocument(al.DocumentKind, ISNULL(al.PurchaseDocumentId, al.ContainerChargeId)) pd
    LEFT  JOIN security.Users au ON au.Id = al.AllocatedBy
    LEFT  JOIN security.Users xu ON xu.Id = al.RemovedBy
    WHERE al.PaymentId = @Id
    ORDER BY al.AllocatedAtUtc, al.Id;

    SELECT f.Id, f.PaymentId, f.AttachmentTypeId, t.Category, t.SubType, f.Note, f.FileName, f.ContentType, f.SizeBytes,
           f.CreatedAtUtc, u.FullName AS CreatedByName
    FROM purchase.PaymentFiles f
    LEFT JOIN masterdata.AttachmentTypes t ON t.Id = f.AttachmentTypeId
    LEFT JOIN security.Users u ON u.Id = f.CreatedBy
    WHERE f.PaymentId = @Id
    ORDER BY f.CreatedAtUtc, f.Id;

    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM purchase.PaymentAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.PaymentId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;

    /* Script 73: the container split of each invoice allocation - EVERY container of the invoice (and
       "Unlinked items"), with this payment's amount on it, so a draft can be edited. PreviouslyPaid leaves
       out this payment's own share once it is posted, like the allocation above. */
    SELECT AllocationId = al.Id, s.DocumentId, s.ContainerId, s.ContainerRef, s.ContainerNo, s.Items, s.ContainerAmount,
           PreviouslyPaid = s.PaidAmount - CASE WHEN p.Status = 2 AND al.RemovedAtUtc IS NULL THEN ISNULL(pac.AmountDocCurrency, 0) ELSE 0 END,
           s.OutstandingAmount, s.PaymentStatus,
           AllocatedAmount = ISNULL(pac.AmountDocCurrency, 0)
    FROM purchase.PaymentAllocations al
    INNER JOIN purchase.Payments p ON p.Id = al.PaymentId
    CROSS APPLY purchase.fn_InvoiceContainerSettlement(al.PurchaseDocumentId) s
    LEFT JOIN purchase.PaymentAllocationContainers pac ON pac.PaymentAllocationId = al.Id AND pac.ContainerKey = s.ContainerKey
    WHERE al.PaymentId = @Id AND al.PurchaseDocumentId IS NOT NULL AND s.HasContainers = 1
    ORDER BY al.Id, CASE WHEN s.ContainerKey = 0 THEN 1 ELSE 0 END, s.ContainerRef;
END
GO

PRINT 'Script 113 applied: a container charge paid cash or on account (the automatic payment of a cash charge).';
GO
