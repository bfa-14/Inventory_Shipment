SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 119: INVENTORY - A POSTED SHORTAGE PLAN GOES BACK TO DRAFT WHILE IT HAS NO PURCHASE ORDER

   The owner: "Can edit or cancel shortage when Purchase order not created". A posted shortage plan was locked for
   good: a plan posted by mistake, or one whose quantities had to change before anything was ordered, could be neither
   corrected nor removed.

   The rule: a POSTED plan may go BACK TO DRAFT while no purchase order made from it is alive - none at all, or only
   cancelled ones. A draft is then edited, recalculated and posted again, or deleted (the plan's "cancel": a draft is
   deleted, as before). A purchase order made from the plan that is a draft, waiting for approval or approved keeps
   the plan locked - the order points at the plan's figures - and the refusal names it: cancel it (or delete it while
   it is a draft) first.

     inventory.fn_ShortageDocument_UnpostBlock (@Id)                       (NEW)
        why the plan cannot go back to draft now, in the words shown on the disabled button; NULL when it can.
     inventory.usp_ShortageDocument_Unpost (@Id, @RowVersion, @UserId)     (NEW)
        Posted -> Draft: the posting stamp is cleared, "Back to draft" in the plan's history. 66006 not found,
        66010 the function's sentence, 66004 changed by another user.
     inventory.usp_ShortageDocument_Get                                    (from script 98)
        + UnpostBlockedReason in the header row; nothing else changes.

   No table, column, permission (it takes Post Shortage Plans) or error number. Requires script 98. Idempotent.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF COL_LENGTH(N'inventory.ShortageDocumentLines', N'LeadTimeSource') IS NULL
   OR COL_LENGTH(N'purchase.PurchaseDocuments', N'SourceShortageId') IS NULL
    THROW 50000, 'Script 119 requires script 98: apply it first.', 1;
GO

/* ================================================================== 1. Why a plan cannot go back to draft */

CREATE OR ALTER FUNCTION inventory.fn_ShortageDocument_UnpostBlock (@Id INT)
RETURNS NVARCHAR(400)
AS
BEGIN
    DECLARE @Status TINYINT, @Number NVARCHAR(30);
    SELECT @Status = Status, @Number = DocumentNumber FROM inventory.ShortageDocuments WHERE Id = @Id;
    IF @Status IS NULL RETURN N'Shortage document not found.';
    IF @Status <> 2 RETURN @Number + N' is a draft already.';

    -- The purchase orders made from the plan that are not cancelled (3): the oldest names the refusal.
    DECLARE @Orders INT, @OrderNumber NVARCHAR(30), @OrderStatus TINYINT;
    SELECT @Orders = COUNT(*) FROM purchase.PurchaseDocuments p WHERE p.SourceShortageId = @Id AND p.Status <> 3;
    IF @Orders = 0 RETURN NULL;

    SELECT TOP (1) @OrderNumber = p.DocumentNumber, @OrderStatus = p.Status
    FROM purchase.PurchaseDocuments p
    WHERE p.SourceShortageId = @Id AND p.Status <> 3
    ORDER BY p.CreatedAtUtc, p.Id;

    RETURN @Number + N' has '
         + CASE WHEN @OrderStatus = 1 THEN N'a draft purchase order' + ISNULL(N' (' + NULLIF(@OrderNumber, N'') + N')', N'')
                WHEN @OrderStatus = 5 THEN N'a purchase order waiting for approval' + ISNULL(N' (' + NULLIF(@OrderNumber, N'') + N')', N'')
                ELSE N'purchase order ' + ISNULL(NULLIF(@OrderNumber, N''), N'(not numbered)') END
         + CASE WHEN @Orders > 1 THEN N' and ' + CAST(@Orders - 1 AS NVARCHAR(10)) + N' more' ELSE N'' END
         + N' made from it: '
         + CASE WHEN @OrderStatus = 1 AND @Orders = 1 THEN N'delete that draft first'
                WHEN @OrderStatus = 5 AND @Orders = 1 THEN N'withdraw and delete it first'
                ELSE N'cancel ' + CASE WHEN @Orders > 1 THEN N'them' ELSE N'it' END + N' first' END
         + N', then bring the plan back to draft.';
END
GO

/* ================================================================== 2. Back to draft */

CREATE OR ALTER PROCEDURE inventory.usp_ShortageDocument_Unpost
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- The plan's row is held to the end, so a purchase order cannot be made from it meanwhile.
        DECLARE @Status TINYINT = (SELECT Status FROM inventory.ShortageDocuments WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id);
        IF @Status IS NULL THROW 66006, 'Shortage document not found.', 1;

        DECLARE @Block NVARCHAR(400) = inventory.fn_ShortageDocument_UnpostBlock(@Id);
        IF @Block IS NOT NULL THROW 66010, @Block, 1;

        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.ShortageDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 66004, 'This document was modified by another user. Reload the page and try again.', 1;

        UPDATE inventory.ShortageDocuments
        SET Status = 1, PostedAtUtc = NULL, PostedBy = NULL, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;
        INSERT INTO inventory.ShortageDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@Id, N'Back to draft', N'No purchase order made from it: it can be changed, posted again or deleted', @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 3. inventory.usp_ShortageDocument_Get (from script 98) */

CREATE OR ALTER PROCEDURE inventory.usp_ShortageDocument_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.Id, d.DocumentNumber, d.Description, d.DocumentDate,
           d.BranchId, b.BranchCode, b.BranchName, d.WarehouseId, w.WarehouseCode, w.WarehouseName,
           d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName,
           d.LeadTimeMonths, d.MonthsOfHistory, d.Notes, d.Status,
           d.TotalLines, d.TotalShortageBase, d.TotalRequiredBase, d.TotalContainers, d.ContainersRounded, d.ContainerUtilizationPct,
           d.CalculatedAtUtc, d.PostedAtUtc, d.PostedBy, pu.FullName AS PostedByName,
           d.CreatedAtUtc, d.CreatedBy, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.UpdatedBy, uu.FullName AS UpdatedByName, d.RowVersion,
           UnpostBlockedReason = inventory.fn_ShortageDocument_UnpostBlock(d.Id)   -- (119) NULL: it may go back to draft
    FROM inventory.ShortageDocuments d
    INNER JOIN masterdata.Branches b ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Parties sp ON sp.Id = d.SupplierId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = d.UpdatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    WHERE d.Id = @Id;

    SELECT l.Id, l.DocumentId, l.LineNumber, l.ItemId, i.ItemCode, i.ItemName, br.BrandName, f.FamilyName, i.IsBivac,
           l.CurrentInventoryBase, l.TransitBase, l.TransfersInBase, l.OutstandingOrderBase, l.StockPlusTransitBase, l.TotalExpectedStockBase,   -- (90)
           l.ExpectedMonthlySalesBase, l.ExpectedMonthlySalesManual, l.EffectiveMonthlySales, l.LeadTimeMonths,
           l.LeadTimeManual, l.LeadTimeSource,                                                                 -- (98)
           l.ExpectedRequirementBase, l.ShortageBase, l.CoverageMonths,
           l.PurchaseItemUnitId, ut.UnitTypeName AS PurchaseUnitName, l.PurchasePackingFormula,
           l.RequiredQty, l.RequiredBase, l.PcPerContainer, l.PcPerContainerFromUnit, l.ContainerRequirement,
           l.MinQuantity, l.MaxQuantity, l.LastCost, l.Notes
    FROM inventory.ShortageDocumentLines l
    INNER JOIN inventory.Items i ON i.Id = l.ItemId
    INNER JOIN masterdata.Brands br ON br.Id = i.BrandId
    INNER JOIN masterdata.ItemFamilies f ON f.Id = i.ItemFamilyId
    INNER JOIN inventory.ItemUnits iu ON iu.Id = l.PurchaseItemUnitId
    INNER JOIN masterdata.UnitTypes ut ON ut.Id = iu.UnitTypeId
    WHERE l.DocumentId = @Id
    ORDER BY l.LineNumber;

    -- (77) + InvoicingStatus (0 / 1 / 2: Saved, Partially posted, Posted on an approved order)
    SELECT p.Id, p.DocumentNumber, p.DocumentDate, p.Status, p.TotalAmount, c.CurrencyCode, p.CreatedAtUtc,
           inv.InvoicingStatus
    FROM purchase.PurchaseDocuments p
    INNER JOIN masterdata.Currencies c ON c.Id = p.CurrencyId
    OUTER APPLY purchase.fn_PurchaseOrder_Invoicing(p.Id) inv
    WHERE p.SourceShortageId = @Id
    ORDER BY p.CreatedAtUtc;

    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM inventory.ShortageDocumentAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.DocumentId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;
END
GO

/* ================================================================== 4. Check */

-- The posted plans and whether each may go back to draft now (NULL: it may).
SELECT TOP (20) d.Id, d.DocumentNumber, UnpostBlockedReason = inventory.fn_ShortageDocument_UnpostBlock(d.Id)
FROM inventory.ShortageDocuments d
WHERE d.Status = 2
ORDER BY d.Id DESC;

PRINT 'Script 119 applied: a posted shortage plan goes back to draft while it has no purchase order (inventory.usp_ShortageDocument_Unpost).';
GO
