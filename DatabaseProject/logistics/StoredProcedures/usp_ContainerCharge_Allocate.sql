/* ================================================================== 7. Charges: allocation over the container lines, container cost */

-- Divides ONE charge over the lines of its container by its method (Value | Quantity | Weight | Volume).
-- Quantity basis = received when the container is offloaded, loaded before. Value = FOB of the line once offloaded,
-- else its invoice lines, else its purchase order line (provisional).
-- Rounded to cents with the largest-remainder rule, so the shares always add up to the charge.
-- A charge already in the cost of the goods (applied at offload / adjusted after) is never spread again.
CREATE   PROCEDURE logistics.usp_ContainerCharge_Allocate
    @ChargeId INT,
    @Silent   BIT = 0      -- 1 = keep the current allocation when the basis is missing (drafts)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ContainerId INT, @Method NVARCHAR(10), @Amount DECIMAL(18,2), @InLanded BIT, @Status TINYINT, @Frozen BIT, @TypeName NVARCHAR(100);
    SELECT @ContainerId = ch.ContainerId, @Method = ch.AllocationMethod, @Amount = ch.AmountBase, @InLanded = ch.IncludeInLandedCost,
           @Status = ch.Status, @Frozen = CASE WHEN ch.AppliedAtOffload = 1 OR ch.AdjustedAfterOffload = 1 THEN 1 ELSE 0 END,
           @TypeName = ct.ChargeName
    FROM logistics.ContainerCharges ch
    INNER JOIN purchase.ChargeTypes ct ON ct.Id = ch.ChargeTypeId
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

    DECLARE @Lines TABLE (LineId INT PRIMARY KEY, LineNumber INT, ItemCode NVARCHAR(50), Qty DECIMAL(18,6),
                          UnitValue DECIMAL(18,6), WeightKg DECIMAL(18,3), VolumeCbm DECIMAL(18,4));
    INSERT INTO @Lines (LineId, LineNumber, ItemCode, Qty, UnitValue, WeightKg, VolumeCbm)
    SELECT cl.Id, cl.LineNumber, i.ItemCode, ISNULL(cl.ReceivedQuantityBase, cl.QuantityBase),
           COALESCE(cl.FobCostBase, inv.UnitValue, po.UnitValue, 0), i.WeightKg, i.VolumeCbm
    FROM logistics.ContainerLines cl
    INNER JOIN inventory.Items i ON i.Id = cl.ItemId
    OUTER APPLY (SELECT UnitValue = SUM(pil.LineTotal / pid.ExchangeRate) / NULLIF(SUM(pil.QuantityBase), 0)
                 FROM purchase.PurchaseDocumentLines pil
                 INNER JOIN purchase.PurchaseDocuments pid ON pid.Id = pil.DocumentId
                 WHERE pil.ContainerLineId = cl.Id AND pid.Status IN (1, 2, 4)) inv
    OUTER APPLY (SELECT UnitValue = pol.LineTotal / pod.ExchangeRate / NULLIF(pol.QuantityBase, 0)
                 FROM purchase.PurchaseDocumentLines pol
                 INNER JOIN purchase.PurchaseDocuments pod ON pod.Id = pol.DocumentId
                 WHERE pol.Id = cl.PoLineId) po
    WHERE cl.ContainerId = @ContainerId;

    DECLARE @Msg NVARCHAR(400);
    IF @Method = N'Weight' AND EXISTS (SELECT 1 FROM @Lines WHERE WeightKg IS NULL AND Qty > 0)
    BEGIN
        IF @Silent = 1 RETURN;
        SELECT TOP (1) @Msg = @TypeName + N': item ' + ItemCode + N' has no weight (kg). Set it in Item Definition or change the allocation method.'
        FROM @Lines WHERE WeightKg IS NULL AND Qty > 0 ORDER BY LineNumber;
        THROW 70013, @Msg, 1;
    END
    IF @Method = N'Volume' AND EXISTS (SELECT 1 FROM @Lines WHERE VolumeCbm IS NULL AND Qty > 0)
    BEGIN
        IF @Silent = 1 RETURN;
        SELECT TOP (1) @Msg = @TypeName + N': item ' + ItemCode + N' has no volume (CBM). Set it in Item Definition or change the allocation method.'
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
        SET @Msg = @TypeName + N': the allocation basis (' + @Method + N') is zero for every line of the container. Use another method or a manual allocation.';
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

