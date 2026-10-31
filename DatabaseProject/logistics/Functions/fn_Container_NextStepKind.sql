/* ================================================================== 2. The step of a container */

-- One row: the next step of a container from what the caller already read of it (the list reads it for every row, so
-- nothing is read twice): its status, its ship state (fn_Container_ShipState), its latest completed Delivery
-- (fn_Container_LastDelivery) and its open goods receipt (fn_Container_ReceivedBy). The first that applies:
-- Done, Complete, OpenReceipt, StartPlanned, Ship, Receive, NextLeg (see the header). BlockedReason: why it cannot be
-- taken at all (the journey is over; a draft or the planned movement's own refusal on StartPlanned). The rights
-- (containers.movements.manage, containers.confirm for a draft, the goods receipt rights) are the caller's to check.
CREATE   FUNCTION logistics.fn_Container_NextStepKind
(
    @ContainerId            INT,
    @Status                 TINYINT,
    @MovementCount          INT,
    @ActiveMovementId       INT,
    @PlannedMovementId      INT,
    @PlannedBlockedReason   NVARCHAR(400),
    @LastMovementId         INT,
    @LastDeliveryMovementId INT,
    @GoodsReceiptStatus     TINYINT
)
RETURNS TABLE
AS
RETURN
SELECT Kind = CAST(CASE WHEN @Status >= 6 THEN N'Done'
                        WHEN @ActiveMovementId IS NOT NULL THEN N'Complete'
                        WHEN @GoodsReceiptStatus = 1 THEN N'OpenReceipt'
                        WHEN @PlannedMovementId IS NOT NULL THEN N'StartPlanned'
                        WHEN ISNULL(@MovementCount, 0) = 0 THEN N'Ship'
                        WHEN @LastDeliveryMovementId = @LastMovementId THEN N'Receive'
                        ELSE N'NextLeg' END AS NVARCHAR(12)),
       BlockedReason = CAST(CASE
            WHEN @Status = 8 THEN N'This container is cancelled.'
            WHEN @Status IN (6, 7)
                 -- where it was received: its posted goods receipt, else (an offload of before) its own warehouse
                 THEN ISNULL(N'Received into ' + (SELECT TOP (1) COALESCE(gw.WarehouseName, cw.WarehouseName)
                                                  FROM logistics.Containers c
                                                  LEFT JOIN masterdata.Warehouses cw ON cw.Id = c.WarehouseId
                                                  OUTER APPLY (SELECT TOP (1) w.WarehouseName
                                                               FROM purchase.GoodsReceipts g
                                                               INNER JOIN masterdata.Warehouses w ON w.Id = g.WarehouseId
                                                               WHERE g.ContainerId = c.Id AND g.Status = 2
                                                               ORDER BY g.Id DESC) gw
                                                  WHERE c.Id = @ContainerId) + N': the journey is over.',
                             CASE WHEN @Status = 7 THEN N'This container is closed: its journey is over.'
                                  ELSE N'This container is received: its journey is over.' END)
            WHEN @ActiveMovementId IS NOT NULL OR @GoodsReceiptStatus = 1 THEN NULL
            WHEN @PlannedMovementId IS NOT NULL AND @Status = 1 THEN N'Confirm the container first: a draft cannot start a movement.'
            WHEN @PlannedMovementId IS NOT NULL THEN @PlannedBlockedReason END AS NVARCHAR(400));

GO

