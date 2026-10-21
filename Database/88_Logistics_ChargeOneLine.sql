SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 88: LOGISTICS - A CHARGE ON A CONTAINER OF ONE ITEM ALWAYS FINDS ITS LINE, AND BY VALUE SAYS WHICH
   PRICE IS MISSING

   Reported on testing: a Customs charge on KTG-2026-0151, allocated By Item Value (the charge type's default), was refused
   at Post: "Customs: the allocation basis (Value) is zero for every line of the container. Use another method or a manual
   allocation." By value a line's share is its pieces x its price per piece in base currency: the FOB once received, else
   the price of the invoice lines linked to it (drafts too), else its order price (script 27). That price was 0: an order
   line at price 0 (or 100% discount), or an invoice line linked to it at 0 - which then hides the order's price. A
   container holds one model as a rule (84 pcs), and with one line every method gives that line the whole charge: the
   refusal stopped a charge that had only one place to go.

     1. logistics.usp_ContainerCharge_Allocate: A CONTAINER WITH ONE LINE THAT HAS PIECES PUTS THE WHOLE CHARGE ON IT,
        whatever the method - nothing to divide, so no price, weight or volume is needed, the way a charge on one
        container needs no split basis (usp_ContainerCharge_Create gives one container the whole amount). Its basis is
        stored as the method computes it (0 without a price, empty without a weight or a volume), shown as it is. Before,
        such a container refused a charge by value without a price, and by weight or volume without the item's figure;
        a goods receipt re-spreading its posted charges refused the same way.
     2. A container of several lines with pieces divides as before. When every one of them is at price 0, a charge by
        value is still refused (there is no value to divide by), and the message says which price is 0 and where to type
        it: "Customs on KTG-2026-0151: By Item Value needs a price, and every line is at 0 - line 1 TVS-APACHE-160 on the
        order PO-BR-002-000042, line 2 TVS-XL100 on a draft invoice. Type the price on the supplier invoice, or allocate
        the charge By Quantity or Manual." (at most three lines named, then "and n more"; a received line says "as
        received (GRN-...)", an invoiced one "on PINV-..."). The other refusals name the container too ("Customs on
        KTG-2026-0151: item TVS-XL100 has no weight (kg). ..."): Post posts the ticked charges in one transaction, so the
        refusal must say which container stops it.

   Not changed: the value of a line (the FOB once received, else its linked invoices, else its order line), how several
   lines divide a charge and the cents rule, a frozen or cancelled charge, Manual, a charge that does not enter the cost;
   the split between containers (usp_ContainerCharge_Create); the charges of a purchase invoice
   (purchase.usp_PurchaseCharges_Allocate). Re-created from its current body: logistics.usp_ContainerCharge_Allocate (27).
   No new table, column, permission or error number (70013 as before).

   Requires scripts 27 and 64 (Schema.sql runs them first). Idempotent, additive: re-applied at every API start-up, and
   builds a brand-new empty database.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'logistics.ContainerChargeAllocations', N'U') IS NULL               -- 27
   OR OBJECT_ID(N'purchase.GoodsReceiptLines', N'U') IS NULL                      -- 64
   OR COL_LENGTH(N'purchase.GoodsReceiptLines', N'ContainerLineId') IS NULL       -- 64
    THROW 70000, 'Script 88 requires scripts 27 and 64: apply them first.', 1;
GO

/* ================================================================== 1. usp_ContainerCharge_Allocate */

-- Divides ONE charge over the lines of its container by its method (Value | Quantity | Weight | Volume).
-- Quantity basis = received when the container is offloaded, loaded before. Value = FOB of the line once offloaded,
-- else its invoice lines, else its purchase order line (provisional).
-- Rounded to cents with the largest-remainder rule, so the shares always add up to the charge.
-- A charge already in the cost of the goods (applied at offload / adjusted after) is never spread again.
-- Re-created (88) from the body of script 27: ONE LINE WITH PIECES TAKES THE WHOLE CHARGE, whatever the method; when
-- several lines are all at price 0, the refusal of a charge by value names each line and where its price comes from;
-- every refusal names the container.
CREATE OR ALTER PROCEDURE logistics.usp_ContainerCharge_Allocate
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

/* ================================================================== 2. Check */

-- The charges that will now find their line: open charges by value, weight or volume on a container with one line that
-- has pieces, still without an allocation (the drafts the old rule left unspread). Posting them goes through now.
SELECT Charges = COUNT(*),
       ByValue = SUM(CASE WHEN ch.AllocationMethod = N'Value' THEN 1 ELSE 0 END),
       ByWeightOrVolume = SUM(CASE WHEN ch.AllocationMethod IN (N'Weight', N'Volume') THEN 1 ELSE 0 END)
FROM logistics.ContainerCharges ch
WHERE ch.Status = 1 AND ch.IncludeInLandedCost = 1 AND ch.AllocationMethod IN (N'Value', N'Weight', N'Volume')
  AND ch.AppliedAtOffload = 0 AND ch.AdjustedAfterOffload = 0
  AND NOT EXISTS (SELECT 1 FROM logistics.ContainerChargeAllocations a WHERE a.ChargeId = ch.Id)
  AND (SELECT COUNT(*) FROM logistics.ContainerLines cl
       WHERE cl.ContainerId = ch.ContainerId AND ISNULL(cl.ReceivedQuantityBase, cl.QuantityBase) > 0) = 1;

PRINT 'Script 88 applied: a container with one line takes the whole charge, whatever the method; a charge by value without any price says which (logistics.usp_ContainerCharge_Allocate).';
GO
