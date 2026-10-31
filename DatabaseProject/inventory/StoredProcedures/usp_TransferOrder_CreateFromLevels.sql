/* (91) "CREATE TRANSFER ORDER..." FROM TICKED ROWS OF STOCK LEVELS (L14, S14): one destination, From chosen by the user;
   each ticked item in its base unit, planned as Add items below Min (no order yet: nothing excluded, no other lines);
   nothing filled: nothing created (62009, the sentence says why). The draft is saved by script 90's
   usp_TransferOrder_Save, which runs its own transaction and checks (none is opened around it): the number is given by
   Save as for any draft (NULL while TRO is numbered at release). Result 1: NewId, DocumentNumber, Message. Result 2: the
   warnings of Fill to Max for the new draft (From below its own Min; other drafts or waiting orders to To holding its
   items, L10). */
CREATE   PROCEDURE inventory.usp_TransferOrder_CreateFromLevels
    @FromWarehouseId INT,
    @ToWarehouseId   INT,
    @ItemIds         logistics.tvp_IdList READONLY,
    @DocumentDate    DATE = NULL,
    @ExpectedArrival DATE = NULL,
    @UserId          INT  = NULL,
    @NewId           INT  = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Msg NVARCHAR(400), @FromCode NVARCHAR(20), @ToCode NVARCHAR(20), @Number NVARCHAR(30), @Notes NVARCHAR(1000),
            @AddMessage NVARCHAR(500), @Filled INT, @Capped INT, @AtOrAboveMin INT, @NoLevel INT, @Covered INT,
            @Inactive INT, @OnOrder INT, @NotFilled INT;
    DECLARE @c inventory.tvp_TransferFillCandidate;
    DECLARE @Lines inventory.tvp_TransferOrderLine;
    DECLARE @FilledItems logistics.tvp_IdList;
    DECLARE @W TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, Message NVARCHAR(500) NOT NULL);

    SET @NewId = NULL;
    SET @DocumentDate = ISNULL(@DocumentDate, CAST(SYSUTCDATETIME() AS DATE));

    EXEC inventory.usp_TransferOrder_CheckWarehouses @FromWarehouseId, @ToWarehouseId;

    IF NOT EXISTS (SELECT 1 FROM @ItemIds) THROW 62009, 'Tick at least one item.', 1;
    IF EXISTS (SELECT 1 FROM @ItemIds x WHERE NOT EXISTS (SELECT 1 FROM inventory.Items i WHERE i.Id = x.Id))
        THROW 62000, 'Item not found.', 1;

    SELECT @FromCode = WarehouseCode FROM masterdata.Warehouses WHERE Id = @FromWarehouseId;
    SELECT @ToCode   = WarehouseCode FROM masterdata.Warehouses WHERE Id = @ToWarehouseId;

    INSERT INTO @c (Seq, ItemId, ItemUnitId, PackingFormula, LineId, LineNumber, CurrentQuantity, CurrentQuantityBase, OtherLinesBase, OnOrder)
    SELECT ROW_NUMBER() OVER (ORDER BY i.ItemCode), i.Id, u.Id, u.PackingFormula, NULL, NULL, NULL, NULL, 0, 0
    FROM @ItemIds x
    INNER JOIN inventory.Items i ON i.Id = x.Id
    CROSS APPLY (SELECT TOP (1) iu.Id, iu.PackingFormula FROM inventory.ItemUnits iu
                 WHERE iu.ItemId = i.Id ORDER BY iu.IsBaseUnit DESC, iu.PackingFormula, iu.Id) u;

    SELECT p.Seq, p.ItemId, p.ItemCode, p.ItemUnitId, p.Outcome, p.NewQuantity, p.NewQuantityBase, p.IsCapped,
           p.FromHasLevel, p.FromMinBase, p.FromProjectedBeforeBase
    INTO #plan
    FROM inventory.fn_TransferFill_Plan(@FromWarehouseId, @ToWarehouseId, NULL, @c) p
    OPTION (RECOMPILE);

    SELECT @Filled       = ISNULL(SUM(CASE WHEN Outcome = N'Filled' THEN 1 ELSE 0 END), 0),
           @Capped       = ISNULL(SUM(CASE WHEN IsCapped = 1 THEN 1 ELSE 0 END), 0),
           @AtOrAboveMin = ISNULL(SUM(CASE WHEN Outcome = N'AtOrAboveMin' THEN 1 ELSE 0 END), 0),
           @NoLevel      = ISNULL(SUM(CASE WHEN Outcome = N'NoLevel' THEN 1 ELSE 0 END), 0),
           @Covered      = ISNULL(SUM(CASE WHEN Outcome = N'Covered' THEN 1 ELSE 0 END), 0),
           @Inactive     = ISNULL(SUM(CASE WHEN Outcome = N'Inactive' THEN 1 ELSE 0 END), 0),
           @OnOrder      = ISNULL(SUM(CASE WHEN Outcome = N'OnOrder' THEN 1 ELSE 0 END), 0),
           @NotFilled    = ISNULL(SUM(CASE WHEN Outcome = N'NothingAvailable' THEN 1 ELSE 0 END), 0)
    FROM #plan;

    IF @Filled = 0
    BEGIN
        SET @Msg = CASE WHEN @NotFilled > 0
                        THEN N'Nothing to transfer: ' + ISNULL(@FromCode, N'the source') + N' has none of these items available.'
                        ELSE N'Nothing to transfer: none of these items is below its Min at ' + ISNULL(@ToCode, N'the destination') + N'.' END;
        THROW 62009, @Msg, 1;
    END

    SET @AddMessage = inventory.fn_TransferFill_Message(N'Add', @FromCode, @ToCode, @Filled, @Capped, @AtOrAboveMin, @NoLevel,
                                                        @Covered, @Inactive, @OnOrder, @NotFilled, 0);

    INSERT INTO @Lines (LineNumber, ItemId, ItemUnitId, Quantity, Notes)
    SELECT ROW_NUMBER() OVER (ORDER BY p.ItemCode, p.Seq), p.ItemId, p.ItemUnitId, p.NewQuantity, NULL
    FROM #plan p
    WHERE p.Outcome = N'Filled';

    SET @Notes = N'Created from Inventory ' + NCHAR(8250) + N' Stock Levels: items below Min at ' + ISNULL(@ToCode, N'the destination') + N'.';

    EXEC inventory.usp_TransferOrder_Save
         @Id              = NULL,
         @DocumentDate    = @DocumentDate,
         @FromWarehouseId = @FromWarehouseId,
         @ToWarehouseId   = @ToWarehouseId,
         @ExpectedArrival = @ExpectedArrival,
         @ReferenceNo     = NULL,
         @Notes           = @Notes,
         @Lines           = @Lines,
         @RowVersion      = NULL,
         @UserId          = @UserId,
         @NewId           = @NewId OUTPUT;

    SELECT @Number = DocumentNumber FROM inventory.TransferOrders WHERE Id = @NewId;

    -- 1: the draft and the sentence
    SELECT NewId = @NewId, DocumentNumber = @Number,
           Message = COALESCE(@Number, N'Draft transfer order #' + CAST(@NewId AS NVARCHAR(12))) + N' created. ' + @AddMessage;

    -- 2: the warnings of Fill to Max (3.3.6.3 step 5) for the draft just made: From below its own Min for a filled
    --    item; other drafts or waiting orders to To that already hold its items (a second click makes a second draft
    --    for the same shortage: it is said)
    INSERT INTO @W (Message)
    SELECT inventory.fn_TransferFill_FromWarning(@FromCode, p.ItemCode, p.FromProjectedBeforeBase - p.NewQuantityBase, p.FromMinBase)
    FROM #plan p
    WHERE p.Outcome = N'Filled' AND p.FromHasLevel = 1 AND p.FromProjectedBeforeBase - p.NewQuantityBase < p.FromMinBase
    ORDER BY p.ItemCode, p.Seq;

    INSERT INTO @FilledItems (Id) SELECT DISTINCT p.ItemId FROM #plan p WHERE p.Outcome = N'Filled';
    INSERT INTO @W (Message)
    SELECT w.Message FROM inventory.fn_TransferFill_OtherOrdersWarning(@ToWarehouseId, @ToCode, @NewId, @FilledItems) w;

    SELECT w.Message FROM @W w ORDER BY w.Seq;
END

GO

