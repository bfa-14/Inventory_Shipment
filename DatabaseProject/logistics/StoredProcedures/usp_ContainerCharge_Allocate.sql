/* ================================================================== 1. usp_ContainerCharge_Allocate */

-- Divides ONE charge over the lines of its container by its method (Value | Quantity | Weight | Volume).
-- Quantity basis = received when the container is offloaded, loaded before. Value = FOB of the line once offloaded,
-- else its invoice lines, else its purchase order line (provisional).
-- Rounded to cents with the largest-remainder rule, so the shares always add up to the charge.
-- A charge already in the cost of the goods (applied at offload / adjusted after) is never spread again.
-- Re-created (88) from the body of script 27: ONE LINE WITH PIECES TAKES THE WHOLE CHARGE, whatever the method; when
-- several lines are all at price 0, the refusal of a charge by value names each line and where its price comes from;
-- every refusal names the container.
CREATE   PROCEDURE logistics.usp_ContainerCharge_Allocate
    @ChargeId INT,
    @Silent   BIT = 0      -- 1 = keep the current allocation when the basis is missing (drafts)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ContainerId INT, @Method NVARCHAR(10), @Amount DECIMAL(18,2), @InLanded BIT, @Status TINYINT, @Frozen BIT,
            @Where NVARCHAR(140);
    SELECT @ContainerId = ch.ContainerId, @Method = ch.AllocationMethod, @Amount = ch.AmountBase, @InLanded = ch.IncludeInLandedCost,
           @Status = ch.Status, @Frozen = CASE WHEN ch.AppliedAtOffload = 1 OR ch.AdjustedAfterOffload = 1 THEN 1 ELSE 0 END,
           @Where = ct.ChargeName + N' on ' + c.ContainerRef      -- (88) "Customs on KTG-2026-0151", for every refusal
    FROM logistics.ContainerCharges ch
    INNER JOIN purchase.ChargeTypes ct ON ct.Id = ch.ChargeTypeId
    INNER JOIN logistics.Containers c  ON c.Id = ch.ContainerId
    WHERE ch.Id = @ChargeId;

    IF @ContainerId IS NULL THROW 70006, 'Charge not found.', 1;
    IF @Frozen = 1 OR @Status = 3 RETURN;
    IF @InLanded = 0
    BEGIN
        DELETE FROM logistics.ContainerChargeAllocations WHERE ChargeId = @ChargeId;
        RETURN;
    END
    IF @Method = N'Manual'
    BEGIN
        DELETE FROM logistics.ContainerChargeAllocations WHERE ChargeId = @ChargeId AND IsManual = 0;
        RETURN;
    END

    -- (88) ValueFrom: where the line's value comes from, for the refusal of a charge by value
    DECLARE @Lines TABLE (LineId INT PRIMARY KEY, LineNumber INT, ItemCode NVARCHAR(50), Qty DECIMAL(18,6),
                          UnitValue DECIMAL(18,6), WeightKg DECIMAL(18,3), VolumeCbm DECIMAL(18,4), ValueFrom NVARCHAR(100));
    INSERT INTO @Lines (LineId, LineNumber, ItemCode, Qty, UnitValue, WeightKg, VolumeCbm, ValueFrom)
    SELECT cl.Id, cl.LineNumber, i.ItemCode, ISNULL(cl.ReceivedQuantityBase, cl.QuantityBase),
           COALESCE(cl.FobCostBase, inv.UnitValue, po.UnitValue, 0), i.WeightKg, i.VolumeCbm,
           CASE WHEN cl.FobCostBase IS NOT NULL THEN N'as received' + ISNULL(N' (' + grn.Number + N')', N'')
                WHEN inv.UnitValue IS NOT NULL THEN ISNULL(N'on ' + inv.Number, N'on a draft invoice')
                WHEN po.UnitValue IS NOT NULL THEN N'on the order' + ISNULL(N' ' + po.Number, N'')
                ELSE N'without a price' END
    FROM logistics.ContainerLines cl
    INNER JOIN inventory.Items i ON i.Id = cl.ItemId
    OUTER APPLY (SELECT UnitValue = SUM(pil.LineTotal / pid.ExchangeRate) / NULLIF(SUM(pil.QuantityBase), 0),
                        Number = MIN(pid.DocumentNumber)                     -- (88) a posted one; drafts have none
                 FROM purchase.PurchaseDocumentLines pil
                 INNER JOIN purchase.PurchaseDocuments pid ON pid.Id = pil.DocumentId
                 WHERE pil.ContainerLineId = cl.Id AND pid.Status IN (1, 2, 4)) inv
    OUTER APPLY (SELECT UnitValue = pol.LineTotal / pod.ExchangeRate / NULLIF(pol.QuantityBase, 0),
                        Number = pod.DocumentNumber                          -- (88)
                 FROM purchase.PurchaseDocumentLines pol
                 INNER JOIN purchase.PurchaseDocuments pod ON pod.Id = pol.DocumentId
                 WHERE pol.Id = cl.PoLineId) po
    OUTER APPLY (SELECT TOP (1) Number = g.DocumentNumber                    -- (88) the goods receipt that received it
                 FROM purchase.GoodsReceiptLines gl
                 INNER JOIN purchase.GoodsReceipts g ON g.Id = gl.GoodsReceiptId AND g.Status = 2
                 WHERE cl.FobCostBase IS NOT NULL AND gl.ContainerLineId = cl.Id
                 ORDER BY g.Id DESC) grn
    WHERE cl.ContainerId = @ContainerId;

    /* (88) ONE LINE WITH PIECES TAKES THE WHOLE CHARGE, whatever the method: there is nothing to divide, so no price,
       weight or volume is needed - the way one container takes the whole amount of a charge (usp_ContainerCharge_Create).
       Its basis is kept as the method computes it: 0 without a price, NULL without the item's weight or volume. */
    IF (SELECT COUNT(*) FROM @Lines WHERE Qty > 0) = 1
    BEGIN
        DELETE FROM logistics.ContainerChargeAllocations WHERE ChargeId = @ChargeId;
        INSERT INTO logistics.ContainerChargeAllocations (ChargeId, ContainerLineId, Basis, AmountBase, IsManual)
        SELECT @ChargeId, LineId, CASE @Method WHEN N'Value' THEN Qty * UnitValue
                                               WHEN N'Quantity' THEN Qty
                                               WHEN N'Weight' THEN Qty * WeightKg
                                               WHEN N'Volume' THEN Qty * VolumeCbm END,
               @Amount, 0
        FROM @Lines WHERE Qty > 0;
        RETURN;
    END

    DECLARE @Msg NVARCHAR(2048);
    IF @Method = N'Weight' AND EXISTS (SELECT 1 FROM @Lines WHERE WeightKg IS NULL AND Qty > 0)
    BEGIN
        IF @Silent = 1 RETURN;
        SELECT TOP (1) @Msg = @Where + N': item ' + ItemCode + N' has no weight (kg). Set it in Item Definition or change the allocation method.'
        FROM @Lines WHERE WeightKg IS NULL AND Qty > 0 ORDER BY LineNumber;
        THROW 70013, @Msg, 1;
    END
    IF @Method = N'Volume' AND EXISTS (SELECT 1 FROM @Lines WHERE VolumeCbm IS NULL AND Qty > 0)
    BEGIN
        IF @Silent = 1 RETURN;
        SELECT TOP (1) @Msg = @Where + N': item ' + ItemCode + N' has no volume (CBM). Set it in Item Definition or change the allocation method.'
        FROM @Lines WHERE VolumeCbm IS NULL AND Qty > 0 ORDER BY LineNumber;
        THROW 70013, @Msg, 1;
    END

    DECLARE @Basis TABLE (LineId INT PRIMARY KEY, Basis DECIMAL(18,6), Share DECIMAL(38,10));
    INSERT INTO @Basis (LineId, Basis)
    SELECT LineId, CASE @Method WHEN N'Value' THEN Qty * UnitValue
                                WHEN N'Quantity' THEN Qty
                                WHEN N'Weight' THEN Qty * ISNULL(WeightKg, 0)
                                WHEN N'Volume' THEN Qty * ISNULL(VolumeCbm, 0) END
    FROM @Lines;
    DELETE FROM @Basis WHERE Basis IS NULL OR Basis <= 0;

    DECLARE @Total DECIMAL(18,6) = (SELECT SUM(Basis) FROM @Basis);
    IF @Total IS NULL OR @Total <= 0
    BEGIN
        IF @Silent = 1 RETURN;
        IF @Method = N'Value' AND EXISTS (SELECT 1 FROM @Lines WHERE Qty > 0)
        BEGIN
            -- (88) every line with pieces is at price 0: each one named with where its price comes from (three at most)
            DECLARE @Zero INT = (SELECT COUNT(*) FROM @Lines WHERE Qty > 0);
            SELECT @Msg = @Where + N': By Item Value needs a price, and every line is at 0 - '
                        + STRING_AGG(CAST(N'line ' + CAST(z.LineNumber AS NVARCHAR(10)) + N' ' + z.ItemCode + N' ' + z.ValueFrom AS NVARCHAR(MAX)), N', ')
                              WITHIN GROUP (ORDER BY z.LineNumber)
                        + CASE WHEN @Zero > 3 THEN N', and ' + CAST(@Zero - 3 AS NVARCHAR(10)) + N' more' ELSE N'' END
                        + N'. Type the price on the supplier invoice, or allocate the charge By Quantity or Manual.'
            FROM (SELECT TOP (3) LineNumber, ItemCode, ValueFrom FROM @Lines WHERE Qty > 0 ORDER BY LineNumber) z;
            THROW 70013, @Msg, 1;
        END
        SET @Msg = @Where + N': the allocation basis (' + @Method + N') is zero for every line of the container. Use another method or a manual allocation.';
        THROW 70013, @Msg, 1;
    END

    UPDATE @Basis SET Share = CAST(@Amount AS DECIMAL(38,10)) * Basis / @Total;

    DELETE FROM logistics.ContainerChargeAllocations WHERE ChargeId = @ChargeId;
    INSERT INTO logistics.ContainerChargeAllocations (ChargeId, ContainerLineId, Basis, AmountBase, IsManual)
    SELECT @ChargeId, LineId, Basis, FLOOR(Share * 100) / 100, 0 FROM @Basis;

    -- the cents lost by rounding down go to the lines with the largest remainders
    DECLARE @Cents INT = CAST(ROUND((@Amount - (SELECT SUM(AmountBase) FROM logistics.ContainerChargeAllocations WHERE ChargeId = @ChargeId)) * 100, 0) AS INT);
    IF @Cents > 0
    BEGIN
        WITH r AS
        (
            SELECT a.Id, Rn = ROW_NUMBER() OVER (ORDER BY b.Share * 100 - FLOOR(b.Share * 100) DESC, b.Basis DESC, a.ContainerLineId)
            FROM logistics.ContainerChargeAllocations a
            INNER JOIN @Basis b ON b.LineId = a.ContainerLineId
            WHERE a.ChargeId = @ChargeId
        )
        UPDATE a SET AmountBase = a.AmountBase + 0.01
        FROM logistics.ContainerChargeAllocations a
        INNER JOIN r ON r.Id = a.Id
        WHERE r.Rn <= @Cents;
    END
END

GO

