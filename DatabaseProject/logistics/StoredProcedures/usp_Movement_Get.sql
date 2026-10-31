/* ================================================================== 3. The movement page: can it be cancelled, and why not */

-- Re-created (83) from the body of script 82: + whether the movement can be cancelled now and, when it cannot, the first
-- refusal of its Cancel (header: CanCancel, CancelBlockedReason - fn_Movement_CancelBlock, the Cancel's own words). Nothing
-- else changes.
CREATE   PROCEDURE logistics.usp_Movement_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    -- (82) the movement's number, status and containers: whether each of them can be split off (fn_Movement_SplitBlock)
    DECLARE @MovementNo NVARCHAR(30), @MovementStatus TINYINT, @ContainerCount INT;
    SELECT @MovementNo = MovementNo, @MovementStatus = Status FROM logistics.Movements WHERE Id = @Id;
    SET @ContainerCount = (SELECT COUNT(*) FROM logistics.MovementContainers WHERE MovementId = @Id);

    SELECT m.Id, m.DocumentTypeId, m.MovementNo, m.MovementTypeId, mt.TypeCode, mt.TypeName, mt.Stage,
           m.FromPlaceId, fp.PortCode AS FromCode, fp.PortName AS FromName, fp.CountryCode AS FromCountry, fp.Kind AS FromKind,
           m.ToPlaceId, tp.PortCode AS ToCode, tp.PortName AS ToName, tp.CountryCode AS ToCountry, tp.Kind AS ToKind,
           m.PlannedDate, m.StartDate, m.Eta, m.EndDate, m.Status, m.CancelReason,
           m.CarrierPartyId, cp.PartyName AS CarrierName, m.VehicleOrVessel, m.VoyageNo, m.Reference, m.Notes,
           m.StartedAtUtc, su.FullName AS StartedByName, m.CompletedAtUtc, ku.FullName AS CompletedByName,
           m.CancelledAtUtc, xu.FullName AS CancelledByName,
           m.CreatedAtUtc, m.CreatedBy, cu.FullName AS CreatedByName, m.UpdatedAtUtc, m.UpdatedBy, uu.FullName AS UpdatedByName,
           m.RowVersion,
           -- (79) the GRN type's switch: does completing a Delivery draft the goods receipts (the Complete dialog says)
           GoodsReceiptsAutomatic = CAST(ISNULL((SELECT dt.AutoCreateOnDelivery FROM inventory.DocumentTypes dt WHERE dt.Code = N'GRN'), 1) AS BIT),
           -- (80) a planned movement: why it cannot start yet (NULL = it can) and its earliest start date; a movement in
           -- progress: the earliest start date its edited start date may take (usp_Movement_Save, 70018)
           StartBlockedReason = sb.Reason, sb.StartNotBefore, sb.StartNotBeforeMovementNo, sb.StartNotBeforePlaceName,
           -- (82) the movement it was split off (usp_Movement_SplitContainers): "Split from MOV-..."
           m.SplitFromMovementId, SplitFromMovementNo = sf.MovementNo,
           -- (82) cancelling it undoes the split: the movement its containers go back to, as the Cancel dialog says it
           SplitUndoMovementId = ut.MovementId, SplitUndoMovementNo = ut.MovementNo, SplitUndoStatus = ut.Status,
           SplitUndoEndDate = ut.EndDate, SplitUndoToName = ut.ToName, SplitUndoStage = ut.Stage,
           -- (83) can it be cancelled now and, when it cannot, the first refusal of its Cancel in the Cancel's own words
           -- (fn_Movement_CancelBlock): the page disables its "Cancel..." with it
           CanCancel = CAST(CASE WHEN cb.Reason IS NULL THEN 1 ELSE 0 END AS BIT), CancelBlockedReason = cb.Reason
    FROM logistics.Movements m
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    INNER JOIN masterdata.Ports fp         ON fp.Id = m.FromPlaceId
    INNER JOIN masterdata.Ports tp         ON tp.Id = m.ToPlaceId
    LEFT  JOIN masterdata.Parties cp       ON cp.Id = m.CarrierPartyId
    LEFT  JOIN security.Users su ON su.Id = m.StartedBy
    LEFT  JOIN security.Users ku ON ku.Id = m.CompletedBy
    LEFT  JOIN security.Users xu ON xu.Id = m.CancelledBy
    LEFT  JOIN security.Users cu ON cu.Id = m.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = m.UpdatedBy
    OUTER APPLY logistics.fn_Movement_StartBlock(m.Id) sb   -- (80)
    LEFT  JOIN logistics.Movements sf ON sf.Id = m.SplitFromMovementId                  -- (82)
    OUTER APPLY logistics.fn_Movement_SplitUndoTarget(m.Id) ut                          -- (82)
    OUTER APPLY logistics.fn_Movement_CancelBlock(m.Id) cb                              -- (83)
    WHERE m.Id = @Id;

    SELECT c.Id AS ContainerId, c.ContainerRef, c.ContainerNo, ct.TypeCode AS ContainerTypeCode, c.Status AS ContainerStatus,
           c.CurrentLocation, c.TotalAllocatedBase, c.TotalOilQty,
           ItemSummary = CASE WHEN ln.ItemCount = 1 THEN ln.FirstItem WHEN ln.ItemCount > 1 THEN N'Mixed - ' + CAST(ln.ItemCount AS NVARCHAR(10)) + N' items' END,
           SupplierName = ln.FirstSupplier,
           ChargesBase = (SELECT SUM(ch.AmountBase) FROM logistics.ContainerCharges ch WHERE ch.ContainerId = c.Id AND ch.MovementId = @Id AND ch.Status = 2),
           DraftChargesBase = (SELECT SUM(ch.AmountBase) FROM logistics.ContainerCharges ch WHERE ch.ContainerId = c.Id AND ch.MovementId = @Id AND ch.Status = 1),
           AttachmentCount = (SELECT COUNT(*) FROM logistics.ContainerAttachments a WHERE a.ContainerId = c.Id AND a.MovementId = @Id),
           c.RowVersion AS ContainerRowVersion,
           -- (65) the container's open goods receipt (a draft or the posted one) and the warehouse its draft would take:
           -- the Complete dialog of a Delivery says what will be created ("draft goods receipt into LUB-WH", "warehouse to
           -- choose", "already has GRN-..."). WarehouseInBranch = the container's warehouse is active, of its branch and
           -- (72) at the bottom of the tree (script 70): the rule of usp_GoodsReceipt_CreateForContainer. AutoDraftOfThisMovement = the receipt is a draft made by
           -- this movement's completion: cancelling the movement deletes it (usp_Movement_SetStatus); the Cancel dialog
           -- names those edited since (GoodsReceiptUpdatedAtUtc / ByName, NULL when never edited).
           GoodsReceiptId = gr.GoodsReceiptId, GoodsReceiptNumber = gr.GoodsReceiptNumber, GoodsReceiptStatus = gr.GoodsReceiptStatus,
           WarehouseCode = w.WarehouseCode,
           WarehouseInBranch = CAST(CASE WHEN w.IsActive = 1 AND w.BranchId = c.BranchId AND masterdata.fn_Warehouse_IsLeaf(w.Id) = 1
                                         THEN 1 ELSE 0 END AS BIT),
           -- (72) why it will not be taken, NULL when it will be (or the container has none: "warehouse to choose")
           WarehouseNote = CAST(CASE WHEN w.Id IS NULL THEN NULL
                                     WHEN w.IsActive = 0 THEN w.WarehouseCode + N', the container''s, is inactive'
                                     WHEN w.BranchId <> c.BranchId THEN w.WarehouseCode + N', the container''s, is not of the container''s branch'
                                     WHEN masterdata.fn_Warehouse_IsLeaf(w.Id) = 0 THEN w.WarehouseCode + N', the container''s, has warehouses under it'
                                END AS NVARCHAR(200)),
           AutoDraftOfThisMovement = CAST(CASE WHEN g.Status = 1 AND g.IsAuto = 1 AND g.MovementId = @Id THEN 1 ELSE 0 END AS BIT),
           GoodsReceiptUpdatedAtUtc = g.UpdatedAtUtc, GoodsReceiptUpdatedByName = gu.FullName,
           -- (82) "Only some containers arrived": can it be split off this movement in progress, and why not
           CanSplitOff = CAST(CASE WHEN sp.Reason IS NULL THEN 1 ELSE 0 END AS BIT), SplitOffBlockedReason = sp.Reason
    FROM logistics.MovementContainers mc
    INNER JOIN logistics.Containers c       ON c.Id = mc.ContainerId
    INNER JOIN masterdata.ContainerTypes ct ON ct.Id = c.ContainerTypeId
    CROSS APPLY logistics.fn_Container_ReceivedBy(c.Id) gr
    LEFT  JOIN purchase.GoodsReceipts g     ON g.Id = gr.GoodsReceiptId
    LEFT  JOIN security.Users gu            ON gu.Id = g.UpdatedBy
    LEFT  JOIN masterdata.Warehouses w      ON w.Id = c.WarehouseId
    OUTER APPLY (SELECT ItemCount = COUNT(DISTINCT cl.ItemId), FirstItem = MIN(i.ItemName), FirstSupplier = MIN(sp.PartyName)
                 FROM logistics.ContainerLines cl
                 INNER JOIN inventory.Items i ON i.Id = cl.ItemId
                 INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                 INNER JOIN masterdata.Parties sp ON sp.Id = d.SupplierId
                 WHERE cl.ContainerId = c.Id) ln
    CROSS APPLY logistics.fn_Movement_SplitBlock(@Id, @MovementNo, @MovementStatus, @ContainerCount, c.Id, c.ContainerRef) sp  -- (82)
    WHERE mc.MovementId = @Id
    ORDER BY c.ContainerRef;

    SELECT ch.Id, ch.ContainerId, c.ContainerRef, ch.GroupId, ch.ChargeTypeId, t.ChargeCode, t.ChargeName, ch.Description,
           pp.PartyName AS ProviderName, ch.Reference, ch.ChargeDate, cur.CurrencyCode, ch.Amount, ch.AmountBase,
           ch.AllocationMethod, ch.IncludeInLandedCost, ch.Status, ch.RowVersion
    FROM logistics.ContainerCharges ch
    INNER JOIN logistics.Containers c    ON c.Id = ch.ContainerId
    INNER JOIN purchase.ChargeTypes t    ON t.Id = ch.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = ch.CurrencyId
    LEFT  JOIN masterdata.Parties pp     ON pp.Id = ch.ProviderPartyId
    WHERE ch.MovementId = @Id
    ORDER BY ch.ChargeDate, c.ContainerRef, ch.Id;

    SELECT a.Id, a.ContainerId, c.ContainerRef, a.ChargeId, a.AttachmentTypeId, at.Category, at.SubType,
           a.FileId, f.FileName, f.ContentType, f.SizeBytes, a.Note, a.DocumentDate, a.GroupId,
           a.CreatedAtUtc, u.FullName AS CreatedByName
    FROM logistics.ContainerAttachments a
    INNER JOIN logistics.Containers c        ON c.Id = a.ContainerId
    INNER JOIN logistics.Files f             ON f.Id = a.FileId
    LEFT  JOIN masterdata.AttachmentTypes at ON at.Id = a.AttachmentTypeId
    LEFT  JOIN security.Users u              ON u.Id = a.CreatedBy
    WHERE a.MovementId = @Id
    ORDER BY a.CreatedAtUtc DESC, c.ContainerRef;

    -- 5: (82) its history beyond its own stamps (logistics.MovementAudit): a split, on the original and on the copy
    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM logistics.MovementAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.MovementId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;
END

GO

