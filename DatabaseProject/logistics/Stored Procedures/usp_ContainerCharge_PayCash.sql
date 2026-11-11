/* ================================================================== 3. The payment of posted cash charges */

CREATE   PROCEDURE logistics.usp_ContainerCharge_PayCash
    @Ids    logistics.tvp_IdList READONLY,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Posted cash charges not yet paid by a payment of their own; one payment per key: the charges of one group
    -- posted together share it when they share its payee, currency, method, account, reference, branch and date.
    DECLARE @C TABLE (Id INT PRIMARY KEY, PayKey NVARCHAR(400) NOT NULL, ContainerId INT NOT NULL, ContainerRef NVARCHAR(30) NOT NULL);
    INSERT INTO @C (Id, PayKey, ContainerId, ContainerRef)
    SELECT ch.Id,
           CONCAT(ISNULL(CAST(ch.GroupId AS NVARCHAR(36)), N'#' + CAST(ch.Id AS NVARCHAR(10))), N'|', ch.ProviderPartyId, N'|', ch.CurrencyId,
                  N'|', ch.PaymentMethodId, N'|', ch.PaymentAccountId, N'|', ISNULL(ch.PaymentReference, N''), N'|', c.BranchId,
                  N'|', CONVERT(NVARCHAR(10), ch.ChargeDate, 120)),
           ch.ContainerId, c.ContainerRef
    FROM @Ids x
    INNER JOIN logistics.ContainerCharges ch ON ch.Id = x.Id
    INNER JOIN logistics.Containers c        ON c.Id = ch.ContainerId
    WHERE ch.Status = 2 AND ch.PaymentType = 1 AND ch.Amount > 0
      AND NOT EXISTS (SELECT 1 FROM purchase.PaymentAllocations a INNER JOIN purchase.Payments p ON p.Id = a.PaymentId
                      WHERE a.ContainerChargeId = ch.Id AND a.RemovedAtUtc IS NULL AND p.Status = 2 AND p.FromChargePost = 1);
    IF NOT EXISTS (SELECT 1 FROM @C) RETURN;

    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg = N'Container ' + x.ContainerRef + N': ' + pp.Message
    FROM @C x
    INNER JOIN logistics.ContainerCharges ch ON ch.Id = x.Id
    CROSS APPLY logistics.fn_ContainerCharge_PaymentProblem(ch.PaymentType, ch.PaymentMethodId, ch.PaymentAccountId, ch.CurrencyId,
                                                            ch.ProviderPartyId, ch.ChargeTypeId) pp
    WHERE pp.Message IS NOT NULL
    ORDER BY x.ContainerRef;
    IF @Msg IS NOT NULL THROW 70000, @Msg, 1;

    DECLARE @Key NVARCHAR(400), @First INT, @PayeeId INT, @BranchId INT, @CurrencyId INT, @MethodId INT, @AccountId INT,
            @PayRef NVARCHAR(100), @PayDate DATE, @Rate DECIMAL(18,6), @Total DECIMAL(18,2), @Notes NVARCHAR(500),
            @PaymentId INT, @PaymentNo NVARCHAR(30), @Cur NVARCHAR(10);
    DECLARE keys CURSOR LOCAL STATIC READ_ONLY FORWARD_ONLY FOR SELECT PayKey, MIN(Id) FROM @C GROUP BY PayKey ORDER BY MIN(Id);
    OPEN keys;
    FETCH NEXT FROM keys INTO @Key, @First;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT @PayeeId = ch.ProviderPartyId, @BranchId = c.BranchId, @CurrencyId = ch.CurrencyId, @MethodId = ch.PaymentMethodId,
               @AccountId = ch.PaymentAccountId, @PayRef = ch.PaymentReference, @PayDate = ch.ChargeDate, @Rate = ch.ExchangeRate,
               @Cur = cur.CurrencyCode
        FROM logistics.ContainerCharges ch
        INNER JOIN logistics.Containers c    ON c.Id = ch.ContainerId
        INNER JOIN masterdata.Currencies cur ON cur.Id = ch.CurrencyId
        WHERE ch.Id = @First;

        SELECT @Total = SUM(ch.Amount),
               @Notes = LEFT(N'Automatic payment of a container charge paid cash: '
                             + STRING_AGG(CAST(x.ContainerRef AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY x.ContainerRef), 500)
        FROM @C x INNER JOIN logistics.ContainerCharges ch ON ch.Id = x.Id
        WHERE x.PayKey = @Key;

        DECLARE @Lines purchase.tvp_PaymentLine, @Allocs purchase.tvp_PaymentAllocation, @Split purchase.tvp_PaymentAllocationContainer;
        DELETE FROM @Lines;
        DELETE FROM @Allocs;
        INSERT INTO @Lines (LineNumber, PaymentMethodId, CurrencyId, Amount, RateToPayment, CashBankAccountId, Reference)
        VALUES (1, @MethodId, @CurrencyId, @Total, 1, @AccountId, @PayRef);
        INSERT INTO @Allocs (DocumentKind, DocumentId, Amount, RateToPayment)
        SELECT N'CHARGE', ch.Id, ch.Amount, 1
        FROM @C x INNER JOIN logistics.ContainerCharges ch ON ch.Id = x.Id
        WHERE x.PayKey = @Key;

        SET @PaymentId = NULL;
        EXEC purchase.usp_Payment_Save @Id = NULL, @PaymentDate = @PayDate, @PayeeId = @PayeeId, @BranchId = @BranchId,
             @PaymentType = 3, @CurrencyId = @CurrencyId, @Amount = @Total, @ExchangeRate = @Rate, @Reference = @PayRef,
             @Notes = @Notes, @Lines = @Lines, @Allocations = @Allocs, @AllocationContainers = @Split,
             @RowVersion = NULL, @UserId = @UserId, @NewId = @PaymentId OUTPUT;

        UPDATE purchase.Payments SET FromChargePost = 1 WHERE Id = @PaymentId;
        SET @PaymentNo = (SELECT PaymentNumber FROM purchase.Payments WHERE Id = @PaymentId);
        INSERT INTO purchase.PaymentAudit (PaymentId, Action, Details, UserId)
        VALUES (@PaymentId, N'AutoCreated', N'Created automatically by posting a container charge paid cash', @UserId);

        EXEC purchase.usp_Payment_Post @Id = @PaymentId, @RowVersion = NULL, @UserId = @UserId;

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        SELECT x.ContainerId, N'Updated',
               LEFT(N'Charge paid cash: ' + t.ChargeCode + N' ' + t.ChargeName + N' ' + CAST(ch.Amount AS NVARCHAR(30)) + N' ' + @Cur
                    + N' (payment ' + ISNULL(@PaymentNo, N'#' + CAST(@PaymentId AS NVARCHAR(10))) + N')', 500), @UserId
        FROM @C x
        INNER JOIN logistics.ContainerCharges ch ON ch.Id = x.Id
        INNER JOIN purchase.ChargeTypes t        ON t.Id = ch.ChargeTypeId
        WHERE x.PayKey = @Key;

        FETCH NEXT FROM keys INTO @Key, @First;
    END
    CLOSE keys;
    DEALLOCATE keys;
END