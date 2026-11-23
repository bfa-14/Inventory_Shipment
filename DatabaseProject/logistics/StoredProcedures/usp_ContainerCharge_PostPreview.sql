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
CREATE   PROCEDURE logistics.usp_ContainerCharge_PostPreview
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

