-- (after the lines, the invoices or the received quantities changed).
CREATE   PROCEDURE logistics.usp_Container_ReallocateCharges
    @ContainerId  INT,
    @PostedSilent BIT = 1,     -- 0 = a POSTED charge without basis raises an error (offload)
    @OnlyValue    BIT = 0      -- 1 = only the charges allocated by value (an invoice changed)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ChargeId INT, @Status TINYINT, @Silent BIT;
    DECLARE charges CURSOR LOCAL FAST_FORWARD FOR
        SELECT Id, Status FROM logistics.ContainerCharges
        WHERE ContainerId = @ContainerId AND Status IN (1, 2) AND AppliedAtOffload = 0 AND AdjustedAfterOffload = 0
          AND IncludeInLandedCost = 1 AND AllocationMethod <> N'Manual'
          AND (@OnlyValue = 0 OR AllocationMethod = N'Value')
        ORDER BY Id;
    OPEN charges;
    FETCH NEXT FROM charges INTO @ChargeId, @Status;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Silent = CASE WHEN @Status = 1 THEN 1 ELSE ISNULL(@PostedSilent, 1) END;
        EXEC logistics.usp_ContainerCharge_Allocate @ChargeId, @Silent;
        FETCH NEXT FROM charges INTO @ChargeId, @Status;
    END
    CLOSE charges;
    DEALLOCATE charges;
    EXEC logistics.usp_Container_RecalcCosts @ContainerId;
END

GO

