-- (the original joins a new group when it had none), same type, description, provider, reference, currency, rate
-- and landed-cost flag. Amount per container = @Amount (charge currency) or the original amount; date = @ChargeDate or
-- the original's; method = @AllocationMethod or the original's (a Manual original gives the charge type's method).
-- The movement of the original is kept for the containers that travel with it. @Post = 1 posts the copies at once.
-- Returns the created charges (Id, ContainerId, ContainerRef, ContainerNo, GroupId, Amount, AmountBase, AllocationMethod,
-- Status, RowVersion). An error while posting names the container.
CREATE   PROCEDURE logistics.usp_ContainerCharge_CopyToContainers
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
            @Notes NVARCHAR(300);
    SELECT @SrcContainer = ch.ContainerId, @SrcRef = c.ContainerRef, @SrcStatus = ch.Status, @GroupId = ch.GroupId,
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
                                                CurrencyId, RateType, ExchangeRate, Amount, AmountBase, AllocationMethod, IncludeInLandedCost, Notes, CreatedBy)
        OUTPUT inserted.Id, inserted.ContainerId INTO @New (Id, ContainerId)
        SELECT x.Id,
               CASE WHEN @SrcMovement IS NOT NULL
                         AND EXISTS (SELECT 1 FROM logistics.MovementContainers mc
                                     INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
                                     WHERE mc.MovementId = @SrcMovement AND mc.ContainerId = x.Id AND m.Status <> 4)
                    THEN @SrcMovement END,
               @GroupId, @TypeId, @Description, @ProviderId, @Reference, @ChargeDate,
               @CurrencyId, @RateType, @Rate, @Amount, @AmountBase, @Method, @InLanded, @Notes, @UserId
        FROM @Ids x;

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

