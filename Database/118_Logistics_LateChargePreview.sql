SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 118: LOGISTICS - A LATE CONTAINER CHARGE SAYS WHAT IT WILL DO BEFORE IT IS POSTED (prompt 53)

   The owner: "I want to be able to add charges to the containers even after shipment ends and the container arrives
   to the warehouse". A container received into the warehouse (Offloaded) already takes charges: posted, a charge
   becomes a cost adjustment of the goods received (usp_ContainerCharge_ApplyCost, scripts 27 and 89) - the part the
   company still holds of the container's items goes to their average cost, the part already sold to cost of sales -
   and the container line's landed cost, the goods receipt's cost per piece and the item's last cost all follow it
   (usp_Container_RecalcCosts). A closed container is reopened first (the page does both in one step, prompt 53).
   What was missing is the sentence before the click: the post confirmation said only "the item costs will be
   adjusted", never how much would go to stock and how much to cost of sales.

   WHAT THIS SCRIPT ADDS
   1. logistics.fn_ContainerCharge_StockShare(@ChargeId, @Sign): each line's delta and its stock part, the rule of
      usp_ContainerCharge_ApplyCost (89) moved here unchanged: per item, min(the company's stock, what the container
      brought) / what the container brought, rounded to the cent per line; the rest is cost of sales. Before the
      cancel's caps (89, 102), which stay in ApplyCost.
   2. logistics.usp_ContainerCharge_ApplyCost re-created from its current body (script 102): its lines and stock parts
      read from the function. Nothing else changes: the same rows, the same amounts.
   3. logistics.usp_ContainerCharge_PostPreview(@Ids): for each listed charge, whether its post is a late one (a draft
      that enters the cost, on an Offloaded container) and then its split - the pieces received, those the company
      still holds, the amount to stock and the amount to cost of sales - or the refusal its post would give. Each charge
      is divided over its lines as Post divides it (usp_ContainerCharge_Allocate, strict), in a transaction rolled back:
      the preview writes nothing, and its figures are the post's as long as nobody posts or sells meanwhile.

   Not changed: the post and the cancel of a charge, their caps, rounding and refusals; the goods receipt, its cost and
   its cancel rule (63008); the landed cost, the average and last cost, the Container Report; payments.
   No table, column, type, permission or error number. Requires scripts 27, 89 and 102. Idempotent.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'logistics.usp_ContainerCharge_ApplyCost', N'P') IS NULL
   OR OBJECT_ID(N'inventory.fn_StockOnHand', N'FN') IS NULL
   OR COL_LENGTH(N'purchase.ChargeTypes', N'IsDeduction') IS NULL                     -- 102
    THROW 50000, 'Script 118 requires scripts 27, 89 and 102: apply them first.', 1;
GO

/* ================================================================== 1. fn_ContainerCharge_StockShare */

-- WHAT A CHARGE DOES TO THE COST OF GOODS ALREADY RECEIVED, line by line (@Sign 1 = it enters, -1 = it leaves): Delta =
-- the line's share of the charge (its allocation), Inv = the part of it that goes to the stock the company still holds,
-- the rest (Delta - Inv) to cost of sales. Per item of the container: Received = the pieces its lines brought,
-- CompanyOnHand = the item's stock in every warehouse (89: was the receiving warehouse's), Remaining = the smaller of the
-- two, never below 0; Inv = Delta x Remaining / Received rounded to the cent, 0 when nothing is held or nothing came.
-- Moved here (118) unchanged from usp_ContainerCharge_ApplyCost (89), with the same types, so both give the same cents.
-- The cancel's caps (89, 102) are applied by ApplyCost on top; a preview of a post needs none.
CREATE OR ALTER FUNCTION logistics.fn_ContainerCharge_StockShare (@ChargeId INT, @Sign SMALLINT)
RETURNS TABLE
AS
RETURN
    SELECT LineId = cl.Id, cl.ItemId,
           Delta = CAST(@Sign * a.AmountBase AS DECIMAL(18,2)),
           Inv = CAST(CASE WHEN q.CompanyOnHand <= 0 OR q.Received <= 0 THEN 0
                           ELSE ROUND(CAST(@Sign * a.AmountBase AS DECIMAL(18,2)) * q.Remaining / q.Received, 2) END AS DECIMAL(18,2)),
           q.Received, q.Remaining, q.CompanyOnHand
    FROM logistics.ContainerChargeAllocations a
    INNER JOIN logistics.ContainerLines cl ON cl.Id = a.ContainerLineId
    CROSS APPLY (SELECT Received = SUM(ISNULL(x.ReceivedQuantityBase, 0))
                 FROM logistics.ContainerLines x
                 WHERE x.ContainerId = cl.ContainerId AND x.ItemId = cl.ItemId) r
    CROSS APPLY (SELECT Q = inventory.fn_StockOnHand(cl.ItemId, NULL)) oh               -- NULL: every warehouse
    CROSS APPLY (SELECT Received      = CAST(r.Received AS DECIMAL(18,6)),
                        Remaining     = CAST(CASE WHEN oh.Q < r.Received THEN CASE WHEN oh.Q > 0 THEN oh.Q ELSE 0 END
                                                  ELSE r.Received END AS DECIMAL(18,6)),
                        CompanyOnHand = CAST(oh.Q AS DECIMAL(18,6))) q
    WHERE a.ChargeId = @ChargeId AND a.AmountBase <> 0;
GO

/* ================================================================== 2. usp_ContainerCharge_ApplyCost */

-- A charge that enters (@Sign = 1) or leaves (@Sign = -1) the cost of goods already received: the part still in the
-- company's stock changes the average cost, the part already sold goes to cost of sales; then the items' costs are
-- replayed. Re-created (118) from the body of script 102: its lines and their stock parts come from
-- logistics.fn_ContainerCharge_StockShare (the rule it held, moved there unchanged); the caps of a cancel stay here.
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

    -- (118) EACH LINE'S DELTA AND ITS STOCK PART FROM logistics.fn_ContainerCharge_StockShare: the rule that was written
    --       here (89: the company's stock of the item, capped at what the container brought), in one place, which the
    --       post preview (usp_ContainerCharge_PostPreview) reads too, so the confirmation says what the post will do.
    DECLARE @Adj TABLE (LineId INT PRIMARY KEY, ItemId INT, Delta DECIMAL(18,2), Inv DECIMAL(18,2) NULL);
    INSERT INTO @Adj (LineId, ItemId, Delta, Inv)
    SELECT s.LineId, s.ItemId, s.Delta, s.Inv
    FROM logistics.fn_ContainerCharge_StockShare(@ChargeId, @Sign) s;

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

/* ================================================================== 3. usp_ContainerCharge_PostPreview */

-- WHAT POSTING THESE CHARGES WILL DO, before the click (the post confirmations of the container page, the charge drawer
-- and Logistics › Container Charges). One row per listed charge that exists:
--   AfterReceipt = 1 when its post adjusts the cost of goods already received: a draft that enters the cost, on an
--                  Offloaded container (usp_ContainerCharge_Post's @After); its split then follows -
--   ReceivedBase  the pieces the container brought of the items the charge goes to,
--   InStockBase   those the company still holds (in every warehouse, at most what came),
--   ToStockBase   the amount that goes to their average cost, ToCostOfSalesBase the amount that goes to cost of sales
--                 (the pieces already sold): fn_ContainerCharge_StockShare, as the post will write them.
--   Problem       the refusal its post would give instead (not a draft, a closed container, no basis for its
--                 allocation, manual shares that do not add up), in the post's own words; no split then.
-- Each charge is divided over its lines as Post divides it (usp_ContainerCharge_Allocate, strict), inside a
-- transaction that is rolled back: nothing is written. A table variable keeps the figures through the rollback.
-- Run outside a transaction (the API's way): a rollback here would undo the caller's work.
CREATE OR ALTER PROCEDURE logistics.usp_ContainerCharge_PostPreview
    @Ids logistics.tvp_IdList READONLY
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @@TRANCOUNT > 0 THROW 70000, 'The post preview runs outside a transaction.', 1;

    DECLARE @Out TABLE (ChargeId INT PRIMARY KEY, AfterReceipt BIT NOT NULL, ReceivedBase DECIMAL(18,6) NULL,
                        InStockBase DECIMAL(18,6) NULL, ToStockBase DECIMAL(18,2) NULL, ToCostOfSalesBase DECIMAL(18,2) NULL,
                        Problem NVARCHAR(400) NULL);
    DECLARE @Share TABLE (LineId INT PRIMARY KEY, ItemId INT, Delta DECIMAL(18,2), Inv DECIMAL(18,2),
                          Received DECIMAL(18,6), Remaining DECIMAL(18,6));

    -- the charges, read once into a table variable: the loop below rolls a transaction back for each, and a table
    -- variable (unlike a cursor, closed by a rollback where CURSOR_CLOSE_ON_COMMIT is on) keeps its rows through it
    DECLARE @List TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, ChargeId INT NOT NULL, Status TINYINT NOT NULL, CtStatus TINYINT NOT NULL,
                         Ref NVARCHAR(30) NOT NULL, Method NVARCHAR(10) NOT NULL, InLanded BIT NOT NULL, AmountBase DECIMAL(18,2) NOT NULL,
                         Label NVARCHAR(200) NOT NULL);
    INSERT INTO @List (ChargeId, Status, CtStatus, Ref, Method, InLanded, AmountBase, Label)
    SELECT ch.Id, ch.Status, c.Status, c.ContainerRef, ch.AllocationMethod, ch.IncludeInLandedCost, ch.AmountBase,
           t.ChargeCode + N' ' + t.ChargeName + N' ' + CAST(ch.Amount AS NVARCHAR(30)) + N' ' + cur.CurrencyCode
    FROM (SELECT DISTINCT Id FROM @Ids) x
    INNER JOIN logistics.ContainerCharges ch ON ch.Id = x.Id
    INNER JOIN logistics.Containers c        ON c.Id = ch.ContainerId
    INNER JOIN purchase.ChargeTypes t        ON t.Id = ch.ChargeTypeId
    INNER JOIN masterdata.Currencies cur     ON cur.Id = ch.CurrencyId
    ORDER BY ch.ContainerId, ch.Id;

    DECLARE @Seq INT = 1, @Last INT = (SELECT MAX(Seq) FROM @List),
            @ChargeId INT, @Status TINYINT, @CtStatus TINYINT, @Ref NVARCHAR(30), @Method NVARCHAR(10), @InLanded BIT,
            @AmountBase DECIMAL(18,2), @Label NVARCHAR(200), @After BIT, @Problem NVARCHAR(400);
    WHILE @Seq <= @Last
    BEGIN
        SELECT @ChargeId = ChargeId, @Status = Status, @CtStatus = CtStatus, @Ref = Ref, @Method = Method, @InLanded = InLanded,
               @AmountBase = AmountBase, @Label = Label
        FROM @List WHERE Seq = @Seq;

        SET @After = CASE WHEN @Status = 1 AND @CtStatus = 6 AND @InLanded = 1 THEN 1 ELSE 0 END;
        -- the post's refusals of a charge it cannot take, in its words
        SET @Problem = CASE WHEN @Status <> 1 THEN N'A charge of container ' + @Ref + N' is not a draft.'
                            WHEN @CtStatus IN (7, 8) THEN N'Container ' + @Ref + N' is closed or cancelled.' END;
        DELETE FROM @Share;

        IF @After = 1
        BEGIN
            BEGIN TRY
                BEGIN TRANSACTION;

                IF @Method <> N'Manual'
                    EXEC logistics.usp_ContainerCharge_Allocate @ChargeId, 0;
                ELSE IF ABS(ISNULL((SELECT SUM(AmountBase) FROM logistics.ContainerChargeAllocations WHERE ChargeId = @ChargeId), 0) - @AmountBase) > 0.01
                    SET @Problem = N'Container ' + @Ref + N': the manual shares of ' + @Label + N' must add up to '
                                 + CAST(@AmountBase AS NVARCHAR(30)) + N' (base currency). Edit the charge first.';

                IF @Problem IS NULL
                    INSERT INTO @Share (LineId, ItemId, Delta, Inv, Received, Remaining)
                    SELECT s.LineId, s.ItemId, s.Delta, s.Inv, s.Received, s.Remaining
                    FROM logistics.fn_ContainerCharge_StockShare(@ChargeId, 1) s;

                ROLLBACK TRANSACTION;
            END TRY
            BEGIN CATCH
                IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
                IF ERROR_NUMBER() < 50000 THROW;                     -- not a business refusal: the caller hears it
                SET @Problem = LEFT(ERROR_MESSAGE(), 400);
            END CATCH
        END

        INSERT INTO @Out (ChargeId, AfterReceipt, ReceivedBase, InStockBase, ToStockBase, ToCostOfSalesBase, Problem)
        SELECT @ChargeId, @After,
               CASE WHEN @After = 1 AND @Problem IS NULL THEN ISNULL((SELECT SUM(i.Received) FROM (SELECT DISTINCT ItemId, Received FROM @Share) i), 0) END,
               CASE WHEN @After = 1 AND @Problem IS NULL THEN ISNULL((SELECT SUM(i.Remaining) FROM (SELECT DISTINCT ItemId, Remaining FROM @Share) i), 0) END,
               CASE WHEN @After = 1 AND @Problem IS NULL THEN ISNULL((SELECT SUM(Inv) FROM @Share), 0) END,
               CASE WHEN @After = 1 AND @Problem IS NULL THEN ISNULL((SELECT SUM(Delta - Inv) FROM @Share), 0) END,
               @Problem;

        SET @Seq += 1;
    END

    SELECT o.ChargeId, ch.ContainerId, c.ContainerRef, t.ChargeCode, t.ChargeName, ch.AmountBase, o.AfterReceipt,
           o.ReceivedBase, o.InStockBase, o.ToStockBase, o.ToCostOfSalesBase, o.Problem
    FROM @Out o
    INNER JOIN logistics.ContainerCharges ch ON ch.Id = o.ChargeId
    INNER JOIN logistics.Containers c        ON c.Id = ch.ContainerId
    INNER JOIN purchase.ChargeTypes t        ON t.Id = ch.ChargeTypeId
    ORDER BY c.ContainerRef, o.ChargeId;
END
GO

/* ================================================================== 4. Check */

-- The late charges posted so far (after the goods were received) and what they put in stock and in cost of sales:
-- unchanged by this script, which only moves the rule into a function and adds the preview.
SELECT LateChargesPosted = COUNT(DISTINCT ch.Id),
       ToStockBase       = ISNULL(SUM(CASE WHEN a.Kind = N'Inventory' THEN a.AmountBase END), 0),
       ToCostOfSalesBase = ISNULL(SUM(CASE WHEN a.Kind = N'COGS' THEN a.AmountBase END), 0)
FROM logistics.ContainerCharges ch
LEFT JOIN inventory.CostAdjustments a ON a.SourceKind = N'CNTCHARGE' AND a.SourceId = ch.Id
WHERE ch.Status = 2 AND ch.AdjustedAfterOffload = 1;

PRINT 'Script 118 applied: a late container charge says before it is posted what goes to stock and what to cost of sales (fn_ContainerCharge_StockShare, usp_ContainerCharge_PostPreview).';
GO
