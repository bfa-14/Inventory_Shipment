-- Basis: Value = line total in base currency, Quantity = base units, Weight = base units x item WeightKg, Volume = base units x item VolumeCbm.
-- Rounded to 2 decimals; the rounding remainder goes to the line with the largest basis, so the sum equals the charge.
CREATE   PROCEDURE purchase.usp_PurchaseCharges_Allocate
    @DocumentKind    NVARCHAR(10),
    @DocumentId      INT,
    @TargetInvoiceId INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Rate DECIMAL(18,6) = (SELECT ExchangeRate FROM purchase.PurchaseDocuments WHERE Id = @TargetInvoiceId);

    DECLARE @Lines TABLE (LineId INT PRIMARY KEY, LineNumber INT, ItemCode NVARCHAR(30), ValueBase DECIMAL(18,6), QtyBase INT, WeightKg DECIMAL(18,3), VolumeCbm DECIMAL(18,4));
    INSERT INTO @Lines (LineId, LineNumber, ItemCode, ValueBase, QtyBase, WeightKg, VolumeCbm)
    SELECT l.Id, l.LineNumber, i.ItemCode, l.LineTotal / @Rate, l.QuantityBase, i.WeightKg, i.VolumeCbm
    FROM purchase.PurchaseDocumentLines l INNER JOIN inventory.Items i ON i.Id = l.ItemId
    WHERE l.DocumentId = @TargetInvoiceId;

    DECLARE @ChargeId INT, @LineNo INT, @Method NVARCHAR(10), @Amount DECIMAL(18,2), @Msg NVARCHAR(400);
    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT Id, LineNumber, AllocationMethod, AmountBase FROM purchase.PurchaseCharges
        WHERE DocumentKind = @DocumentKind AND DocumentId = @DocumentId AND IncludeInLandedCost = 1 AND AllocationMethod <> N'Manual'
        ORDER BY LineNumber;
    OPEN cur;
    FETCH NEXT FROM cur INTO @ChargeId, @LineNo, @Method, @Amount;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        DELETE FROM purchase.PurchaseChargeAllocations WHERE ChargeId = @ChargeId AND IsManual = 0;

        IF @Method = N'Weight' AND EXISTS (SELECT 1 FROM @Lines WHERE WeightKg IS NULL)
        BEGIN
            SELECT TOP (1) @Msg = N'Charge ' + CAST(@LineNo AS NVARCHAR(10)) + N': item ' + ItemCode + N' has no weight (kg) - set it in Item Definition or change the allocation method.' FROM @Lines WHERE WeightKg IS NULL ORDER BY LineNumber;
            THROW 65012, @Msg, 1;
        END
        IF @Method = N'Volume' AND EXISTS (SELECT 1 FROM @Lines WHERE VolumeCbm IS NULL)
        BEGIN
            SELECT TOP (1) @Msg = N'Charge ' + CAST(@LineNo AS NVARCHAR(10)) + N': item ' + ItemCode + N' has no volume (CBM) - set it in Item Definition or change the allocation method.' FROM @Lines WHERE VolumeCbm IS NULL ORDER BY LineNumber;
            THROW 65012, @Msg, 1;
        END

        DECLARE @Basis TABLE (LineId INT PRIMARY KEY, Basis DECIMAL(18,6));
        DELETE FROM @Basis;
        INSERT INTO @Basis (LineId, Basis)
        SELECT LineId, CASE @Method WHEN N'Value' THEN ValueBase WHEN N'Quantity' THEN QtyBase WHEN N'Weight' THEN QtyBase * WeightKg WHEN N'Volume' THEN QtyBase * VolumeCbm END
        FROM @Lines;

        DECLARE @Total DECIMAL(18,6) = (SELECT SUM(Basis) FROM @Basis);
        IF @Total IS NULL OR @Total <= 0
        BEGIN
            SET @Msg = N'Charge ' + CAST(@LineNo AS NVARCHAR(10)) + N': the allocation basis (' + @Method + N') is zero for every line - use another method or a manual allocation.';
            THROW 65012, @Msg, 1;
        END

        INSERT INTO purchase.PurchaseChargeAllocations (ChargeId, PurchaseLineId, Basis, AmountBase, IsManual)
        SELECT @ChargeId, LineId, Basis, ROUND(@Amount * Basis / @Total, 2), 0 FROM @Basis;

        DECLARE @Remainder DECIMAL(18,2) = @Amount - (SELECT SUM(AmountBase) FROM purchase.PurchaseChargeAllocations WHERE ChargeId = @ChargeId);
        IF @Remainder <> 0
            UPDATE a SET AmountBase = a.AmountBase + @Remainder
            FROM purchase.PurchaseChargeAllocations a
            WHERE a.Id = (SELECT TOP (1) a2.Id FROM purchase.PurchaseChargeAllocations a2 INNER JOIN @Basis b ON b.LineId = a2.PurchaseLineId
                          WHERE a2.ChargeId = @ChargeId ORDER BY b.Basis DESC, a2.PurchaseLineId);

        FETCH NEXT FROM cur INTO @ChargeId, @LineNo, @Method, @Amount;
    END
    CLOSE cur; DEALLOCATE cur;
END

GO

