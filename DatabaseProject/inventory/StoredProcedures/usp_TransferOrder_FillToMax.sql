/* (91) FILL TO MAX (@AddItems empty) AND ADD ITEMS BELOW MIN (@AddItems = the drawer's ticked items), on a SAVED draft
   (business-context 4.14, 3.4.3; the rule is inventory.fn_TransferFill_Plan's). @Apply = 0: a preview, no lock,
   nothing written. @Apply = 1: the order WITH (UPDLOCK, HOLDLOCK) and its RowVersion (62004; none sent: 62000), the plan worked out
   again, then Fill SETS the first line of each filled item (Ordered = the units, the unit's current packing formula),
   Add inserts one line per filled item at the end (line numbers in item code order), the order's totals follow, and
   one audit row (FillToMax / ItemsAddedBelowMin) is written. Nothing to change: no line and no header is written (the
   RowVersion stays valid), only the audit row. The refusals are fn_TransferOrder_Blocks' FillToMax / AddBelowMin
   rows. Result 1: the summary and the sentence. Result 2: the plan, in item code order (Add after an apply: the new
   line numbers). Result 3: the warnings (From below its own Min; other drafts or waiting orders to To holding the same
   items: L10). */
CREATE   PROCEDURE inventory.usp_TransferOrder_FillToMax
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @AddItems   inventory.tvp_TransferFillItem READONLY,
    @Apply      BIT       = 0,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Apply = ISNULL(@Apply, 0);

    DECLARE @Mode NVARCHAR(10) = CASE WHEN EXISTS (SELECT 1 FROM @AddItems) THEN N'Add' ELSE N'Fill' END;
    DECLARE @ErrNo INT, @Msg NVARCHAR(400), @FromId INT, @ToId INT, @FromCode NVARCHAR(20), @ToCode NVARCHAR(20),
            @Message NVARCHAR(500), @Filled INT, @Capped INT, @Changed INT, @AtOrAboveMin INT, @NoLevel INT,
            @Covered INT, @Inactive INT, @OnOrder INT, @NotFilled INT, @MaxLine INT;
    DECLARE @c inventory.tvp_TransferFillCandidate;
    DECLARE @PlanItems logistics.tvp_IdList;
    DECLARE @W TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, Message NVARCHAR(500) NOT NULL);

    -- 0. The order; an apply is made with the RowVersion the page read (L9): without one it could overwrite a change
    --    it never saw
    IF NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id) THROW 62006, 'Transfer order not found.', 1;
    IF @Apply = 1 AND @RowVersion IS NULL THROW 62000, 'The row version is missing. Reload the page and try again.', 1;

    BEGIN TRY
        -- 1. Apply: the order locked until the commit, and the RowVersion the page read. A preview reads without a lock.
        IF @Apply = 1
        BEGIN
            BEGIN TRANSACTION;
            SELECT @FromId = FromWarehouseId, @ToId = ToWarehouseId
            FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
            IF @FromId IS NULL THROW 62006, 'Transfer order not found.', 1;
            IF NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id AND RowVersion = @RowVersion)
                THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;
        END
        ELSE
            SELECT @FromId = FromWarehouseId, @ToId = ToWarehouseId FROM inventory.TransferOrders WHERE Id = @Id;

        SELECT @FromCode = WarehouseCode FROM masterdata.Warehouses WHERE Id = @FromId;
        SELECT @ToCode   = WarehouseCode FROM masterdata.Warehouses WHERE Id = @ToId;

        -- 2. Why it cannot be done now (a draft, the TRO type on, fit warehouses, lines, levels at To)
        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
        WHERE b.Action = CASE @Mode WHEN N'Add' THEN N'AddBelowMin' ELSE N'FillToMax' END AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        -- 3. The candidates
        IF @Mode = N'Fill'
            -- one per item of the order: its lowest-numbered line, the other lines of the item counted in OtherLinesBase
            INSERT INTO @c (Seq, ItemId, ItemUnitId, PackingFormula, LineId, LineNumber, CurrentQuantity, CurrentQuantityBase, OtherLinesBase, OnOrder)
            SELECT ROW_NUMBER() OVER (ORDER BY f.LineNumber), f.ItemId, f.ItemUnitId, iu.PackingFormula, f.Id, f.LineNumber,
                   f.Quantity, f.OrderedBase, f.ItemBase - f.OrderedBase, 0
            FROM (SELECT l.Id, l.LineNumber, l.ItemId, l.ItemUnitId, l.Quantity, l.OrderedBase,
                         ItemBase = SUM(l.OrderedBase) OVER (PARTITION BY l.ItemId),
                         Rn       = ROW_NUMBER() OVER (PARTITION BY l.ItemId ORDER BY l.LineNumber)
                  FROM inventory.TransferOrderLines l
                  WHERE l.TransferOrderId = @Id) f
            INNER JOIN inventory.ItemUnits iu ON iu.Id = f.ItemUnitId
            WHERE f.Rn = 1;
        ELSE
        BEGIN
            -- one per ticked item, in the unit given (it must be the item's) or its base unit; an item already on the order
            -- (OnOrder, skipped) counts the order's lines of it in OtherLinesBase, as the drawer does, so its figures after
            -- this order are Get's
            SELECT TOP (1) @Msg = CASE WHEN i.Id IS NULL THEN N'Item not found.'
                                       ELSE N'The unit does not belong to item ' + i.ItemCode + N'.' END
            FROM @AddItems a
            LEFT JOIN inventory.Items i      ON i.Id = a.ItemId
            LEFT JOIN inventory.ItemUnits iu ON iu.Id = a.ItemUnitId AND iu.ItemId = a.ItemId
            WHERE i.Id IS NULL OR (a.ItemUnitId IS NOT NULL AND iu.Id IS NULL)
            ORDER BY CASE WHEN i.Id IS NULL THEN 0 ELSE 1 END, i.ItemCode;
            IF @Msg IS NOT NULL THROW 62000, @Msg, 1;

            INSERT INTO @c (Seq, ItemId, ItemUnitId, PackingFormula, LineId, LineNumber, CurrentQuantity, CurrentQuantityBase, OtherLinesBase, OnOrder)
            SELECT ROW_NUMBER() OVER (ORDER BY i.ItemCode), a.ItemId, u.Id, u.PackingFormula, NULL, NULL, NULL, NULL,
                   ISNULL(ol.Pcs, 0),
                   CASE WHEN ol.N > 0 THEN 1 ELSE 0 END
            FROM @AddItems a
            INNER JOIN inventory.Items i ON i.Id = a.ItemId
            CROSS APPLY (SELECT N = COUNT(*), Pcs = SUM(l.OrderedBase)
                         FROM inventory.TransferOrderLines l
                         WHERE l.TransferOrderId = @Id AND l.ItemId = a.ItemId) ol
            CROSS APPLY (SELECT TOP (1) iu.Id, iu.PackingFormula
                         FROM inventory.ItemUnits iu
                         WHERE iu.ItemId = a.ItemId AND (iu.Id = a.ItemUnitId OR a.ItemUnitId IS NULL)
                         ORDER BY CASE WHEN iu.Id = a.ItemUnitId THEN 0 ELSE 1 END, iu.IsBaseUnit DESC, iu.PackingFormula, iu.Id) u;
        END

        -- 4. The plan, with the figures after this order
        SELECT p.Seq, p.ItemId, p.ItemCode, p.ItemName, p.ItemIsActive, p.ItemUnitId, UnitName = ut.UnitTypeName, p.PackingFormula,
               p.LineId, p.LineNumber, p.CurrentQuantity, p.CurrentQuantityBase, p.OtherLinesBase, p.OnOrder,
               p.ToOnHandBase, p.ToInOnTheWayBase, p.ToInToDispatchBase, p.ToOutToDispatchBase, p.ProjectedBeforeBase,
               p.ToHasLevel, p.MinBase, p.MaxBase, p.FromOnHandBase, p.FromCommittedBase, p.AvailableFromBase, p.AvailableForLineBase,
               p.NeedBase, p.UnitsNeeded, p.UnitsAvailable, p.Outcome, p.NewQuantity, p.NewQuantityBase, p.IsCapped,
               p.FromHasLevel, p.FromMinBase, p.FromProjectedBeforeBase,
               ProjectedAfterBase = p.ProjectedBeforeBase + p.OtherLinesBase + COALESCE(p.NewQuantityBase, p.CurrentQuantityBase, 0),
               FromAfterBase      = p.FromProjectedBeforeBase - (p.OtherLinesBase + COALESCE(p.NewQuantityBase, p.CurrentQuantityBase, 0)),
               FromBelowMinAfter  = CAST(CASE WHEN p.FromHasLevel = 1
                                               AND p.FromProjectedBeforeBase - (p.OtherLinesBase + COALESCE(p.NewQuantityBase, p.CurrentQuantityBase, 0)) < p.FromMinBase
                                              THEN 1 ELSE 0 END AS BIT),
               -- a filled line whose Ordered changes (in its unit, or in pcs when the unit's packing changed since it was saved)
               IsChanged          = CAST(CASE WHEN p.Outcome = N'Filled'
                                               AND (p.NewQuantity <> ISNULL(p.CurrentQuantity, 0) OR p.NewQuantityBase <> ISNULL(p.CurrentQuantityBase, 0))
                                              THEN 1 ELSE 0 END AS BIT),
               PurchasesToComeBase = CAST(NULL AS INT),
               NewLineNumber       = CAST(NULL AS INT)
        INTO #plan
        FROM inventory.fn_TransferFill_Plan(@FromId, @ToId, @Id, @c) p
        INNER JOIN inventory.ItemUnits iu  ON iu.Id = p.ItemUnitId
        INNER JOIN masterdata.UnitTypes ut ON ut.Id = iu.UnitTypeId
        OPTION (RECOMPILE);   -- the candidates' real count: a drawer's 2,000 items read the history once, not per item

        -- what purchase orders and containers still bring to To, shown dimmed (not counted, L11): a preview only
        IF @Apply = 0
            UPDATE p
            SET PurchasesToComeBase = pc.Pcs
            FROM #plan p
            CROSS APPLY (SELECT Pcs = s.TransitBase + s.OutstandingOrderBase
                         FROM inventory.fn_Shortage_Live(@ToId, 1) s
                         WHERE s.ItemId = p.ItemId) pc;

        SELECT @Filled       = ISNULL(SUM(CASE WHEN Outcome = N'Filled' THEN 1 ELSE 0 END), 0),
               @Capped       = ISNULL(SUM(CASE WHEN IsCapped = 1 THEN 1 ELSE 0 END), 0),
               @Changed      = ISNULL(SUM(CASE WHEN IsChanged = 1 THEN 1 ELSE 0 END), 0),
               @AtOrAboveMin = ISNULL(SUM(CASE WHEN Outcome = N'AtOrAboveMin' THEN 1 ELSE 0 END), 0),
               @NoLevel      = ISNULL(SUM(CASE WHEN Outcome = N'NoLevel' THEN 1 ELSE 0 END), 0),
               @Covered      = ISNULL(SUM(CASE WHEN Outcome = N'Covered' THEN 1 ELSE 0 END), 0),
               @Inactive     = ISNULL(SUM(CASE WHEN Outcome = N'Inactive' THEN 1 ELSE 0 END), 0),
               @OnOrder      = ISNULL(SUM(CASE WHEN Outcome = N'OnOrder' THEN 1 ELSE 0 END), 0),
               @NotFilled    = ISNULL(SUM(CASE WHEN Outcome = N'NothingAvailable' THEN 1 ELSE 0 END), 0)
        FROM #plan;

        SET @Message = inventory.fn_TransferFill_Message(@Mode, @FromCode, @ToCode, @Filled, @Capped, @AtOrAboveMin, @NoLevel,
                                                         @Covered, @Inactive, @OnOrder, @NotFilled,
                                                         CASE WHEN @Apply = 1 AND @Filled > 0 AND @Changed = 0 THEN 1 ELSE 0 END);

        -- 5. The warnings: From below its own Min after this order, per filled item; other drafts / waiting orders to To
        --    holding the plan's items (fn_TransferFill_FromWarning, fn_TransferFill_OtherOrdersWarning)
        INSERT INTO @W (Message)
        SELECT inventory.fn_TransferFill_FromWarning(@FromCode, p.ItemCode, p.FromAfterBase, p.FromMinBase)
        FROM #plan p
        WHERE p.Outcome = N'Filled' AND p.FromBelowMinAfter = 1
        ORDER BY p.ItemCode, p.Seq;

        INSERT INTO @PlanItems (Id) SELECT DISTINCT p.ItemId FROM #plan p;
        INSERT INTO @W (Message)
        SELECT w.Message FROM inventory.fn_TransferFill_OtherOrdersWarning(@ToId, @ToCode, @Id, @PlanItems) w;

        -- 6. Apply
        IF @Apply = 1
        BEGIN
            IF @Changed > 0
            BEGIN
                IF @Mode = N'Fill'
                    UPDATE l
                    SET Quantity = p.NewQuantity, PackingFormula = p.PackingFormula
                    FROM inventory.TransferOrderLines l
                    INNER JOIN #plan p ON p.LineId = l.Id
                    WHERE l.TransferOrderId = @Id AND p.IsChanged = 1;
                ELSE
                BEGIN
                    SET @MaxLine = ISNULL((SELECT MAX(LineNumber) FROM inventory.TransferOrderLines WHERE TransferOrderId = @Id), 0);

                    UPDATE p
                    SET NewLineNumber = @MaxLine + x.Rn
                    FROM #plan p
                    INNER JOIN (SELECT Seq, Rn = ROW_NUMBER() OVER (ORDER BY ItemCode, Seq) FROM #plan WHERE IsChanged = 1) x ON x.Seq = p.Seq;

                    INSERT INTO inventory.TransferOrderLines (TransferOrderId, LineNumber, ItemId, ItemUnitId, Quantity, PackingFormula, Notes)
                    SELECT @Id, p.NewLineNumber, p.ItemId, p.ItemUnitId, p.NewQuantity, p.PackingFormula, NULL
                    FROM #plan p
                    WHERE p.IsChanged = 1;
                END

                UPDATE o
                SET TotalLines       = t.N,
                    TotalOrderedBase = t.Pcs,
                    UpdatedAtUtc     = SYSUTCDATETIME(),
                    UpdatedBy        = @UserId
                FROM inventory.TransferOrders o
                CROSS APPLY (SELECT N = COUNT(*), Pcs = ISNULL(SUM(l.OrderedBase), 0)
                             FROM inventory.TransferOrderLines l WHERE l.TransferOrderId = o.Id) t
                WHERE o.Id = @Id;
            END

            INSERT INTO inventory.TransferOrderAudit (TransferOrderId, Action, Details, UserId)
            VALUES (@Id, CASE @Mode WHEN N'Add' THEN N'ItemsAddedBelowMin' ELSE N'FillToMax' END, LEFT(@Message, 500), @UserId);

            COMMIT TRANSACTION;
        END
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    -- 7. The answer
    -- 1: the summary
    SELECT Mode = @Mode, Applied = @Apply, Message = @Message,
           Filled = @Filled, Capped = @Capped, Changed = @Changed, AtOrAboveMin = @AtOrAboveMin, NoLevel = @NoLevel,
           Covered = @Covered, Inactive = @Inactive, OnOrder = @OnOrder, NotFilled = @NotFilled;

    -- 2: the plan, in item code order: the plan's own columns (fn_TransferFill_Plan: ProjectedBeforeBase, MinBase,
    --    MaxBase) + ProjectedAfterBase (spec 3.3.6.3); the API maps them to TransferFillResult.lines' to... names.
    SELECT p.Seq, p.ItemId, p.ItemCode, p.ItemName, p.ItemIsActive,
           p.LineId, LineNumber = COALESCE(p.NewLineNumber, p.LineNumber),
           p.ItemUnitId, p.UnitName, p.PackingFormula,
           p.CurrentQuantity, p.CurrentQuantityBase, p.NewQuantity, p.NewQuantityBase, p.OtherLinesBase, p.OnOrder,
           p.ToOnHandBase, p.ToInOnTheWayBase, p.ToInToDispatchBase, p.ToOutToDispatchBase,
           p.ProjectedBeforeBase, p.ProjectedAfterBase,
           p.ToHasLevel, p.MinBase, p.MaxBase,
           p.NeedBase, p.UnitsNeeded, p.UnitsAvailable,
           p.FromOnHandBase, p.FromCommittedBase, p.AvailableFromBase, p.AvailableForLineBase,
           p.Outcome, p.IsCapped, p.IsChanged,
           p.FromHasLevel, p.FromMinBase, p.FromProjectedBeforeBase, p.FromAfterBase, p.FromBelowMinAfter,
           p.PurchasesToComeBase
    FROM #plan p
    ORDER BY p.ItemCode, p.Seq;

    -- 3: the warnings
    SELECT w.Message FROM @W w ORDER BY w.Seq;
END

GO

