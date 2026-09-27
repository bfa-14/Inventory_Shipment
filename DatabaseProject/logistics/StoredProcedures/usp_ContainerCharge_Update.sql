CREATE   PROCEDURE logistics.usp_ContainerCharge_Update
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

