/* ================================================================== 14. Container charges: create, update, post, cancel, delete */

-- One charge typed for one or several containers: one DRAFT record per container (same GroupId when several).
-- @SplitRule: Same = every container gets @TotalAmount; Equal = equal parts; Pieces = by quantity; Value = by FOB value.
-- Returns the created charges.
CREATE   PROCEDURE logistics.usp_ContainerCharge_Create
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

