SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 77: PURCHASE ORDER STATUSES BY INVOICING - "Closed" is gone

   The owner's words: "the statuses must be: 1- Draft 2- Saved (when no invoices related found) 3- Partially posted
   (when the items in the related invoices are less than the items in the order) 4- Posted (when the items in the
   related invoices are equal to the items in the order), and remove Closed".

   What an order SHOWS:
     Draft (1), Waiting for approval (5) and Cancelled (3): unchanged.
     An approved order (2) shows how far its POSTED supplier invoices cover it (purchase.fn_PurchaseOrder_Invoicing,
     the InvoicingStatus that usp_PurchaseDocument_Get and _Search already returned since script 26):
       0 Saved             no posted invoice yet
       1 Partially posted  invoiced < ordered
       2 Posted            invoiced = ordered (each line is capped at what it ordered, so the totals are equal only
                           when every line is fully invoiced)
     Draft invoices do not count; purchase returns do not lower it (they never touched the order's counters).
     The stored code stays 2 for all three: the approval, the receipts, the containers, Shortages and the Dashboard
     read "approved" as 2, and nothing has to change there. The API and the web name the three states.

   Closed (4) is never written again for an order:
     - usp_PurchaseDocument_Post no longer closes the order when an invoice fills it: it writes "Fully invoiced by
       PINV-..." in the order's history;
     - usp_GoodsReceipt_Post no longer closes it when the goods are in: an order's status depends on its invoices only;
     - usp_PurchaseDocument_Close (Close Order) is retired: it keeps its parameters and refuses (65010).
   The pieces that will never arrive are settled with "Nothing more will come" on a goods receipt, as before.

   Left as they are, on purpose (they only READ status 4, or reopen from it: dead branches once no order is closed):
     purchase.fn_PoLine_Progress (its "closed" cap), usp_PurchaseDocument_Cancel / usp_GoodsReceipt_Cancel /
     logistics.usp_Container_CancelOffload (their reopen from 4), and every "Status IN (2, 4)" test (receipts,
     Shortages, item On order, Dashboard, containers). Supplier invoices and returns never had status 4.

   The orders already closed (one-off data step, below): back to 2, ClosedAtUtc / ClosedBy / CloseReason emptied, one
   history row "Closed status removed (was: ...)". While closed, an order expected only what was invoiced
   (fn_PoLine_Progress: invoiced - received - short); open again it would expect the whole order. So the pieces the
   close gave up are SETTLED SHORT on each line: + max(0, ordered - max(invoiced, received + short)). Still to come
   (Shortages, the item's On order, the Dashboard's On the way, "To receive", "Receive goods..." proposals) is then
   what it was. An order closed by itself is fully invoiced, so nothing is added to it. (Script 65's drift report
   counts those added pieces as a difference: its "expected" knows only goods receipts and old offloads.)
   The same pieces are also kept apart in a new column, purchase.PurchaseDocumentLines.ClosedShortBase, because a piece
   settled short may still be RECEIVED if it turns up (fn_PoLine_Progress.MaxOutsideBase) and is not counted when
   containers are loaded (fn_PoLine_CommittedOutside): without it, an order closed by hand would again take goods
   receipts and containers for what its close gave up. Both functions are re-created below to leave those pieces out
   (all of them while they are not invoiced; once the supplier invoices some, those count as any invoiced piece). They
   can still be invoiced, like any piece settled short (the supplier claim covers what never arrives).

   Procedures re-created from their current bodies: purchase.usp_PurchaseDocument_Post (72), purchase.usp_GoodsReceipt_Post
   (64), purchase.usp_PurchaseDocument_Close (65, retired), purchase.usp_PurchaseDocument_Get (65: the linked documents
   + InvoicingStatus), inventory.usp_ShortageDocument_Get (25: its orders + InvoicingStatus), inventory.usp_Item_PurchaseOrders
   (65: + InvoicingStatus), purchase.fn_PoLine_Progress and purchase.fn_PoLine_CommittedOutside (64: ClosedShortBase).
   New: purchase.fn_PurchaseOrder_Invoicing; the column purchase.PurchaseDocumentLines.ClosedShortBase.

   Errors: no new number. 65010 "Purchase orders are no longer closed: ..." (Close).

   Requires scripts 64, 65 and 72 (Schema.sql runs them first). Idempotent, additive: re-applied at every API start-up,
   and builds a brand-new empty database (the data step finds no closed order there).
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'purchase.fn_PoLine_Progress', N'IF') IS NULL                 -- 64
   OR OBJECT_ID(N'purchase.usp_GoodsReceipt_Post', N'P') IS NULL            -- 64
   OR OBJECT_ID(N'purchase.usp_GoodsReceipt_LockMatching', N'P') IS NULL    -- 64
   OR OBJECT_ID(N'logistics.fn_Container_CloseBlock', N'IF') IS NULL        -- 65
   OR OBJECT_ID(N'masterdata.fn_Warehouse_IsLeaf', N'FN') IS NULL           -- 70
   OR OBJECT_ID(N'masterdata.fn_Warehouse_IsUsed', N'FN') IS NULL           -- 71 (72 re-created it)
BEGIN
    RAISERROR ('Run scripts 64 to 72 before this script.', 16, 1);
    SET NOEXEC ON;
END
GO

/* ================================================================== 0. The pieces a close by hand gave up */

-- Set once, by the data step of section 2, on the lines of the orders closed by hand: the pieces it settled short
-- (also added to GoodsShortBase). 0 everywhere else, and never written again.
IF COL_LENGTH(N'purchase.PurchaseDocumentLines', N'ClosedShortBase') IS NULL
    ALTER TABLE purchase.PurchaseDocumentLines
        ADD ClosedShortBase INT NOT NULL CONSTRAINT DF_PurchaseDocumentLines_ClosedShortBase DEFAULT (0);
GO

/* ================================================================== 1. How far the posted invoices cover an order */

-- One row for a purchase order (none for an invoice or a return): ordered and invoiced pieces over its lines, and
-- InvoicingStatus 0 not invoiced (Saved), 1 partially (Partially posted), 2 fully (Posted). Invoiced = the lines'
-- ReceivedQuantityBase, raised by a posted invoice and lowered by its cancellation (its old name: it has always meant
-- invoiced). The formula of usp_PurchaseDocument_Get / _Search since script 26, in one place.
CREATE OR ALTER FUNCTION purchase.fn_PurchaseOrder_Invoicing (@PurchaseOrderId INT)
RETURNS TABLE
AS
RETURN
    SELECT PurchaseOrderId = d.Id,
           OrderedBase     = p.Ordered,
           InvoicedBase    = p.Invoiced,
           InvoicingStatus = CAST(CASE WHEN p.Invoiced = 0 THEN 0 WHEN p.Invoiced >= p.Ordered THEN 2 ELSE 1 END AS TINYINT)
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId AND dt.Code = N'PO'
    CROSS APPLY (SELECT Ordered  = ISNULL(SUM(l.QuantityBase), 0),
                        Invoiced = ISNULL(SUM(l.ReceivedQuantityBase), 0)
                 FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = d.Id) p
    WHERE d.Id = @PurchaseOrderId;
GO

/* ================================================================== 2. The orders already closed go back (once) */

-- ONE-OFF DATA STEP, in one transaction: either every closed order is back with its settled pieces and its history
-- row, or none is. A later start finds no order in status 4 and does nothing (the procedures below never write 4).
SET XACT_ABORT ON;
BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @Reopen TABLE (Id INT NOT NULL PRIMARY KEY, CloseReason NVARCHAR(300) NULL, SettledBase INT NOT NULL DEFAULT (0));

    INSERT INTO @Reopen (Id, CloseReason)
    SELECT d.Id, d.CloseReason
    FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId AND dt.Code = N'PO'
    WHERE d.Status = 4;

    IF EXISTS (SELECT 1 FROM @Reopen)
    BEGIN
        -- What the close gave up, per line: the pieces neither invoiced nor received / settled short. Settled short
        -- now, so the order still expects what it expected while closed (invoiced - received - short).
        DECLARE @Lines TABLE (LineId INT NOT NULL PRIMARY KEY, DocumentId INT NOT NULL, Extra INT NOT NULL);
        INSERT INTO @Lines (LineId, DocumentId, Extra)
        SELECT l.Id, l.DocumentId, x.Extra
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN @Reopen r ON r.Id = l.DocumentId
        CROSS APPLY (SELECT Done = CASE WHEN l.ReceivedQuantityBase >= l.GoodsReceivedBase + l.GoodsShortBase
                                        THEN l.ReceivedQuantityBase ELSE l.GoodsReceivedBase + l.GoodsShortBase END) k
        CROSS APPLY (SELECT Extra = l.QuantityBase - k.Done) x
        WHERE x.Extra > 0;

        UPDATE l SET GoodsShortBase = l.GoodsShortBase + x.Extra, ClosedShortBase = l.ClosedShortBase + x.Extra
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN @Lines x ON x.LineId = l.Id;

        UPDATE r SET SettledBase = s.Pcs
        FROM @Reopen r
        INNER JOIN (SELECT DocumentId, Pcs = SUM(Extra) FROM @Lines GROUP BY DocumentId) s ON s.DocumentId = r.Id;

        UPDATE d
        SET Status = 2, ClosedAtUtc = NULL, ClosedBy = NULL, CloseReason = NULL, UpdatedAtUtc = SYSUTCDATETIME()
        FROM purchase.PurchaseDocuments d
        INNER JOIN @Reopen r ON r.Id = d.Id;

        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        SELECT r.Id, N'Updated',
               LEFT(N'Closed status removed (was: ' + ISNULL(NULLIF(LTRIM(RTRIM(r.CloseReason)), N''), N'Closed manually') + N')'
                    + CASE WHEN r.SettledBase > 0
                           THEN N'; ' + CAST(r.SettledBase AS NVARCHAR(20)) + N' pcs not invoiced settled short: nothing more will come'
                           ELSE N'' END, 500),
               NULL
        FROM @Reopen r;

        DECLARE @ReopenCount INT, @ReopenSettled INT;
        SELECT @ReopenCount = COUNT(*), @ReopenSettled = ISNULL(SUM(SettledBase), 0) FROM @Reopen;
        PRINT 'Purchase orders: ' + CAST(@ReopenCount AS NVARCHAR(10)) + ' closed order(s) back to approved, '
              + CAST(@ReopenSettled AS NVARCHAR(20)) + ' pcs not invoiced settled short.';
    END

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH
-- Back to the connection's default, as after the one-off steps of scripts 64, 65 and 69: the API applies every batch of
-- Schema.sql on one connection.
SET XACT_ABORT OFF;
GO

/* ================================================================== 2b. What a close by hand gave up stays given up */

-- Re-created (77) from the body of script 64: (77) MaxOutsideBase, the posting cap of a local receipt line, leaves out the
-- pieces a close by hand gave up (ClosedShortBase, section 2) while they are not invoiced. Every other piece settled short
-- may still be received if it turns up, as before; and once the supplier invoices given-up pieces they are received like
-- any invoiced piece. Nothing else changes.
-- One row per line of a purchase order (none for another document type). In pieces:
--   OrderedBase          ordered
--   InvoicedBase         invoiced = ReceivedQuantityBase (its old name, its meaning unchanged)
--   GoodsReceivedBase    received; GoodsShortBase settled short (nothing more will come)
--   InContainersBase     loaded in containers not received yet (status 1-5: draft to cleared)
--   InDraftReceiptsBase  on draft goods receipts outside containers
--   ToReceiveBase        what the "Receive goods..." dialogs propose: ordered - received - short - in containers - in drafts
--   MaxOutsideBase       the posting cap of a local receipt line: ordered - received - in containers - (77) given up by a
--                        close and not invoiced. Neither the drafts (the one being posted is one) nor the other pieces
--                        settled short count: pieces recorded short that turn up later can still be received.
--   OutstandingBase      rule 17, for Shortages and the item's "On order": an open order ordered - received - short, a
--                        closed one invoiced - received - short; 0 when cancelled. Never below 0.
-- ON A CLOSED ORDER (4) "ordered" is what was INVOICED in all three, as in OutstandingBase (rule 17). (77) No order is
-- closed any more: the closed branches stay for the old rows only, which section 2 turned back into approved orders.
-- The status of the order is the caller's to check (OrderStatus): this function never refuses.
CREATE OR ALTER FUNCTION purchase.fn_PoLine_Progress (@PurchaseOrderId INT)
RETURNS TABLE
AS
RETURN
    SELECT PurchaseOrderId     = d.Id,
           PoLineId            = l.Id,
           l.LineNumber, l.ItemId, l.ItemUnitId, l.PackingFormula, l.WarehouseId,
           OrderStatus         = d.Status,
           OrderedBase         = l.QuantityBase,
           InvoicedBase        = l.ReceivedQuantityBase,
           l.GoodsReceivedBase,
           l.GoodsShortBase,
           InContainersBase    = q.InContainers,
           InDraftReceiptsBase = q.InDrafts,
           ToReceiveBase       = CASE WHEN x.ToReceive > 0 THEN x.ToReceive ELSE 0 END,
           MaxOutsideBase      = CASE WHEN x.MaxOutside > 0 THEN x.MaxOutside ELSE 0 END,
           OutstandingBase     = CASE WHEN x.Outstanding > 0 THEN x.Outstanding ELSE 0 END
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt         ON dt.Id = d.DocumentTypeId AND dt.Code = N'PO'
    INNER JOIN purchase.PurchaseDocumentLines l   ON l.DocumentId = d.Id
    CROSS APPLY (SELECT InContainers = ISNULL((SELECT SUM(cl.QuantityBase)
                                               FROM logistics.ContainerLines cl
                                               INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                                               WHERE cl.PoLineId = l.Id AND c.Status BETWEEN 1 AND 5), 0),
                        InDrafts     = ISNULL((SELECT SUM(gl.QuantityBase)
                                               FROM purchase.GoodsReceiptLines gl
                                               INNER JOIN purchase.GoodsReceipts g ON g.Id = gl.GoodsReceiptId
                                               WHERE gl.PoLineId = l.Id AND gl.ContainerLineId IS NULL AND g.Status = 1), 0)) q
    CROSS APPLY (SELECT Expected = CASE WHEN d.Status = 4 AND l.ReceivedQuantityBase < l.QuantityBase
                                        THEN l.ReceivedQuantityBase ELSE l.QuantityBase END,
                        -- (77) given up by a close and still not invoiced: at most what is not invoiced
                        GivenUp  = CASE WHEN l.ClosedShortBase <= 0 THEN 0
                                        WHEN l.ClosedShortBase < l.QuantityBase - l.ReceivedQuantityBase THEN l.ClosedShortBase
                                        WHEN l.QuantityBase > l.ReceivedQuantityBase THEN l.QuantityBase - l.ReceivedQuantityBase
                                        ELSE 0 END) e
    CROSS APPLY (SELECT ToReceive   = e.Expected - l.GoodsReceivedBase - l.GoodsShortBase - q.InContainers - q.InDrafts,
                        MaxOutside  = e.Expected - l.GoodsReceivedBase - q.InContainers - e.GivenUp,
                        Outstanding = CASE d.Status WHEN 3 THEN 0
                                                    WHEN 4 THEN l.ReceivedQuantityBase - l.GoodsReceivedBase - l.GoodsShortBase
                                                    ELSE l.QuantityBase - l.GoodsReceivedBase - l.GoodsShortBase END) x
    WHERE d.Id = @PurchaseOrderId;
GO

-- Re-created (77) from the body of script 64: (77) Qty also counts the pieces a close by hand gave up (ClosedShortBase)
-- while they are not invoiced, so they cannot be loaded into containers again: they will never come. Disjoint from the
-- invoiced and received pieces when the close was removed (section 2 settled only what was neither), so they are added
-- to the maximum; once the supplier invoices some of them they count as invoiced instead. Nothing else changes.
-- WHAT AN ORDER LINE HAS COMMITTED OUTSIDE CONTAINERS, in pieces - script 65 uses it in place of the "dir" subquery
-- (invoiced outside containers) wherever the pieces still loadable into containers are worked out:
--   Qty = MAX(invoiced outside containers, received outside containers + on draft receipts outside containers)
--         + (77) given up by a close and not invoiced.
-- A maximum, not a sum: an invoiced piece and a received piece outside containers are the same goods (they are matched).
-- Except the pieces of an invoice that took its goods into stock WHEN IT WAS POSTED, before goods receipts
-- (UsesGoodsReceipts = 0, ReceiptMode 1): they are invoiced AND received, and never matched (usp_GoodsReceipt_Rematch
-- leaves those invoices out), so they count on both sides - otherwise goods received later by a goods receipt for the
-- rest of the same order line would hide behind them in the maximum and could be loaded into a container again.
-- Qty is then: those pieces + MAX(the other invoiced pieces, received by goods receipts + on draft receipts).
--   InvoicedOutsideBase         today's "dir": lines of invoices in status 1, 2 or 4 not shipped in containers
--                               (ReceiptMode <> 2) with no container line; @ExceptDocumentId (NULL = none) leaves out
--                               one invoice, as the callers that check that invoice's own lines do
--   ReceivedOutsideBase         posted goods receipt lines of the order line with no container line, plus the pieces of
--                               the invoices received when they were posted (above)
--   InDraftReceiptsOutsideBase  goods receipt lines of the order line with no container line on draft receipts
-- One row, always (0 when nothing).
CREATE OR ALTER FUNCTION purchase.fn_PoLine_CommittedOutside (@PoLineId INT, @ExceptDocumentId INT)
RETURNS TABLE
AS
RETURN
    SELECT Qty                        = CASE WHEN inv.Qty >= inv.AtPosting + rcv.Posted + rcv.Drafts THEN inv.Qty
                                             ELSE inv.AtPosting + rcv.Posted + rcv.Drafts END
                                        + gu.GivenUp,
           InvoicedOutsideBase        = inv.Qty,
           ReceivedOutsideBase        = inv.AtPosting + rcv.Posted,
           InDraftReceiptsOutsideBase = rcv.Drafts
    FROM (SELECT Qty       = ISNULL(SUM(x.QuantityBase), 0),
                 AtPosting = ISNULL(SUM(CASE WHEN xd.Status IN (2, 4) AND xd.UsesGoodsReceipts = 0 AND xd.ReceiptMode = 1
                                             THEN x.QuantityBase END), 0)
          FROM purchase.PurchaseDocumentLines x
          INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
          WHERE x.SourceLineId = @PoLineId AND x.ContainerLineId IS NULL AND xd.Status IN (1, 2, 4) AND xd.ReceiptMode <> 2
            AND (@ExceptDocumentId IS NULL OR xd.Id <> @ExceptDocumentId)) inv
    CROSS JOIN (SELECT Posted = ISNULL(SUM(CASE WHEN g.Status = 2 THEN gl.QuantityBase END), 0),
                       Drafts = ISNULL(SUM(CASE WHEN g.Status = 1 THEN gl.QuantityBase END), 0)
                FROM purchase.GoodsReceiptLines gl
                INNER JOIN purchase.GoodsReceipts g ON g.Id = gl.GoodsReceiptId
                WHERE gl.PoLineId = @PoLineId AND gl.ContainerLineId IS NULL AND g.Status IN (1, 2)) rcv
    -- (77) given up by a close and still not invoiced (as in fn_PoLine_Progress); 0 for every other line
    CROSS JOIN (SELECT GivenUp = ISNULL(MAX(CASE WHEN l.ClosedShortBase <= 0 THEN 0
                                                 WHEN l.ClosedShortBase < l.QuantityBase - l.ReceivedQuantityBase THEN l.ClosedShortBase
                                                 WHEN l.QuantityBase > l.ReceivedQuantityBase THEN l.QuantityBase - l.ReceivedQuantityBase
                                                 ELSE 0 END), 0)
                FROM purchase.PurchaseDocumentLines l WHERE l.Id = @PoLineId) gu;
GO

/* ================================================================== 3. Post: the order is no longer closed */

-- Re-created (77) from the body of script 72: when a supplier invoice is posted, its order's invoiced counters go up
-- as before, but the order no longer closes when it is fully invoiced and received: "Fully invoiced by PINV-..." goes in
-- its history. The source test reads "no longer open (cancelled)": an order is never closed now. Nothing else changes.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Post
    @Id         INT,
    @RowVersion   BINARY(8) = NULL,
    @UserId       INT       = NULL,
    @FromApproval BIT       = 0,     -- 1 = called by the approval
    -- (65) "Receive the goods now" (a supplier invoice only): once the invoice is posted and committed, its lines not in
    --      a container are received with a goods receipt, created and posted in a second transaction. The API passes 1
    --      only for a user who may also create and post goods receipts. A receipt that fails leaves the invoice posted
    --      and says why in @ReceiveWarning.
    @ReceiveNow         BIT           = 0,
    @GoodsReceiptId     INT           = NULL OUTPUT,
    @GoodsReceiptNumber NVARCHAR(30)  = NULL OUTPUT,
    @ReceiveWarning     NVARCHAR(700) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SELECT @GoodsReceiptId = NULL, @GoodsReceiptNumber = NULL, @ReceiveWarning = NULL;
    -- (65) the cost of goods already received, brought to this invoice's price (usp_GoodsReceipt_TrueUpCost)
    DECLARE @CostAmount DECIMAL(18,2) = 0, @CostInventory DECIMAL(18,2) = 0, @CostCogs DECIMAL(18,2) = 0, @CostLines INT = 0;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- (65) lock order: the goods receipt matcher first, then rows, or two postings deadlock. Only a supplier invoice or
        --      a return (their type, read without a lock: it never changes).
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                   WHERE d.Id = @Id AND dt.Code IN (N'PINV', N'PRET'))
            EXEC purchase.usp_GoodsReceipt_LockMatching;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Direction SMALLINT, @Number NVARCHAR(30), @DocumentDate DATE,
                @BranchId INT, @SupplierId INT, @Rate DECIMAL(18,6), @SourceId INT, @ReceiptMode TINYINT,
                @OneItemOnly BIT;

        SELECT @Status = d.Status, @TypeCode = dt.Code, @Direction = dt.StockDirection, @Number = d.DocumentNumber,
               @DocumentDate = d.DocumentDate, @BranchId = d.BranchId, @SupplierId = d.SupplierId, @Rate = d.ExchangeRate,
               @SourceId = d.SourceDocumentId, @ReceiptMode = d.ReceiptMode,
               @OneItemOnly = d.OneItemOnly
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @TypeCode = N'PO' AND ISNULL(@FromApproval, 0) = 1 AND @Status <> 5
            THROW 65010, 'Only a purchase order waiting for approval can be approved.', 1;
        IF (@TypeCode <> N'PO' OR ISNULL(@FromApproval, 0) = 0) AND @Status <> 1
            THROW 65010, 'Only draft documents can be posted.', 1;

        DECLARE @PostedWithoutApproval BIT = CASE WHEN @TypeCode = N'PO' AND ISNULL(@FromApproval, 0) = 0 THEN 1 ELSE 0 END;
        IF @PostedWithoutApproval = 1 AND purchase.fn_PurchaseOrder_NeedsApproval(@Id) = 1
            THROW 65013, 'This order needs approval: send it for approval.', 1;

        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id)
            THROW 65009, 'The document has no lines. Add at least one item before posting.', 1;

        -- (45) A supplier invoice holds ONE item: a draft saved with several before script 45 is split first.
        -- (63) Only when its mode is one item: its own, or the setting when it has none (saved before script 63).
        IF @TypeCode = N'PINV' AND COALESCE(@OneItemOnly, configuration.fn_SettingBool(N'Purchase.OneItemPerInvoice')) = 1
           AND (SELECT COUNT(DISTINCT ItemId) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id) > 1
        BEGIN
            DECLARE @ItemCount INT = (SELECT COUNT(DISTINCT ItemId) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id),
                    @ItemCodes NVARCHAR(400);
            SELECT @ItemCodes = STRING_AGG(x.ItemCode, N', ') WITHIN GROUP (ORDER BY x.FirstLine)
            FROM (SELECT TOP (5) i.ItemCode, FirstLine = MIN(l.LineNumber)
                  FROM purchase.PurchaseDocumentLines l INNER JOIN inventory.Items i ON i.Id = l.ItemId
                  WHERE l.DocumentId = @Id
                  GROUP BY l.ItemId, i.ItemCode
                  ORDER BY MIN(l.LineNumber)) x;
            SET @ItemCodes = N'A supplier invoice holds one item. This one has ' + CAST(@ItemCount AS NVARCHAR(10)) + N': ' + @ItemCodes
                         + CASE WHEN @ItemCount > 5 THEN N'...' ELSE N'.' END + N' Create one invoice per item, or use Split by item.';
            THROW 65029, @ItemCodes, 1;
        END
        IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SupplierId AND IsActive = 1)
            THROW 65008, 'The supplier is inactive.', 1;

        -- Imports: the goods are received by the container, not by this posting.
        -- (65) EVERY SUPPLIER INVOICE, whatever its receipt mode: goods enter stock only through a posted goods receipt.
        --      The invoice still gets its FOB, its charges and its landed cost per line (the INVOICE COST that received
        --      goods are valued at or corrected to), and it is marked UsesGoodsReceipts = 1 when it is posted below.
        --      Returns still take their goods out at posting. (Was @ReceiveNow, now the name of the parameter.)
        DECLARE @StockAtPosting BIT = CASE WHEN @TypeCode = N'PINV' THEN 0 ELSE 1 END;

        DECLARE @FromContainers BIT = CASE WHEN @TypeCode = N'PINV' AND EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines
                                                                                WHERE DocumentId = @Id AND ContainerLineId IS NOT NULL) THEN 1 ELSE 0 END;
        -- (43) Shipped in containers: an imported invoice, linked to its containers now or later. Lines not in a container
        --      yet are allowed: they enter the stock at the offload of the containers they are linked to afterwards.
        IF @TypeCode = N'PINV' AND @ReceiptMode = 2
        BEGIN
            IF NULLIF(LTRIM(RTRIM((SELECT ExporterReference FROM purchase.PurchaseDocuments WHERE Id = @Id))), N'') IS NULL
                THROW 65018, 'The exporter reference is required on an imported invoice. Enter it before posting.', 1;
            IF EXISTS (SELECT 1 FROM purchase.PurchaseCharges WHERE DocumentKind = N'PINV' AND DocumentId = @Id)
                THROW 65020, 'This invoice has its own charges. Remove them: the charges of an import are entered on its containers.', 1;
        END

        IF @FromContainers = 1
        BEGIN

            -- (65) A container received with a goods receipt can be invoiced (the goods may arrive first): only a cancelled
            --      container, or one offloaded before goods receipts, is refused - and more than the loaded pieces.
            DECLARE @CtMsg NVARCHAR(400);
            SELECT TOP (1) @CtMsg = N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                                    + CASE WHEN c.Status = 8 OR (c.Status IN (6, 7) AND rb.ReceivedBy = N'Offload')
                                           THEN N'the container is cancelled or was offloaded before goods receipts.'
                                           ELSE CAST(q.Here AS NVARCHAR(20)) + N' invoiced here + ' + CAST(ISNULL(o.Posted, 0) AS NVARCHAR(20))
                                                + N' in posted invoices, but only ' + CAST(cl.QuantityBase AS NVARCHAR(20)) + N' are loaded.' END
            FROM (SELECT ContainerLineId, Here = SUM(QuantityBase) FROM purchase.PurchaseDocumentLines
                  WHERE DocumentId = @Id GROUP BY ContainerLineId) q
            INNER JOIN logistics.ContainerLines cl ON cl.Id = q.ContainerLineId
            INNER JOIN logistics.Containers c      ON c.Id = cl.ContainerId
            INNER JOIN inventory.Items i           ON i.Id = cl.ItemId
            OUTER APPLY (SELECT Posted = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                         INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                         WHERE pil.ContainerLineId = cl.Id AND pd.Status IN (2, 4) AND pd.Id <> @Id) o
            CROSS APPLY logistics.fn_Container_ReceivedBy(c.Id) rb
            WHERE c.Status = 8 OR (c.Status IN (6, 7) AND rb.ReceivedBy = N'Offload') OR q.Here + ISNULL(o.Posted, 0) > cl.QuantityBase
            ORDER BY c.ContainerRef, cl.LineNumber;
            IF @CtMsg IS NOT NULL THROW 65019, @CtMsg, 1;
        END

        DECLARE @Msg NVARCHAR(400);
        SELECT TOP (1) @Msg =
            CASE WHEN i.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item ' + i.ItemCode + N' is inactive.'
                 WHEN w.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is inactive.' END
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id AND (i.IsActive = 0 OR w.IsActive = 0)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 65000, @Msg, 1;

        -- A parent warehouse holds no stock of its own: a line takes a warehouse at the bottom of the tree (script 70).
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' has warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree.'
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id AND masterdata.fn_Warehouse_IsLeaf(w.Id) = 0
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 65000, @Msg, 1;

        IF @SourceId IS NOT NULL
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @SourceId AND Status = 2)
                THROW 65011, 'The source document is no longer open (cancelled).', 1;

            IF @TypeCode = N'PINV'
            BEGIN
                SELECT TOP (1) @Msg = N'Line ' + CAST(x.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - ' + CAST(x.Qty AS NVARCHAR(20))
                                     + N' base units invoiced but only ' + CAST(s.QuantityBase - s.ReceivedQuantityBase AS NVARCHAR(20)) + N' remain on the order line.'
                FROM (SELECT SourceLineId, SUM(QuantityBase) AS Qty, MIN(LineNumber) AS LineNumber FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x
                INNER JOIN purchase.PurchaseDocumentLines s ON s.Id = x.SourceLineId
                INNER JOIN inventory.Items i ON i.Id = s.ItemId
                WHERE x.Qty > s.QuantityBase - s.ReceivedQuantityBase
                ORDER BY x.LineNumber;
                IF @Msg IS NOT NULL THROW 65011, @Msg, 1;
            END
            IF @TypeCode = N'PRET'
            BEGIN
                -- (65) From an invoice that uses goods receipts, or is shipped in containers, only what was RECEIVED and not
                --      returned yet goes back (rule 23): goods received but not invoiced, or invoiced but not received, are
                --      not on the invoice line. An invoice posted with its stock before goods receipts keeps invoiced - returned.
                --      The source lines are locked until the return raises their ReturnedQuantityBase below, so what they
                --      received cannot move in between (the matching lock above keeps goods receipts out meanwhile).
                SELECT TOP (1) @Msg = N'Line ' + CAST(x.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - ' + CAST(x.Qty AS NVARCHAR(20))
                                     + CASE WHEN g.ByReceipts = 1
                                            THEN N' base units returned but only ' + CAST(CASE WHEN g.Avail > 0 THEN g.Avail ELSE 0 END AS NVARCHAR(20))
                                                 + N' were received and not returned on the invoice line.'
                                            ELSE N' base units returned but only ' + CAST(s.QuantityBase - s.ReturnedQuantityBase AS NVARCHAR(20)) + N' can still be returned from the invoice line.' END
                FROM (SELECT SourceLineId, SUM(QuantityBase) AS Qty, MIN(LineNumber) AS LineNumber FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x
                INNER JOIN purchase.PurchaseDocumentLines s WITH (UPDLOCK, HOLDLOCK) ON s.Id = x.SourceLineId
                INNER JOIN purchase.PurchaseDocuments sd    ON sd.Id = s.DocumentId
                INNER JOIN inventory.Items i ON i.Id = s.ItemId
                CROSS APPLY (SELECT ByReceipts = CASE WHEN sd.UsesGoodsReceipts = 1 OR sd.ReceiptMode = 2 THEN 1 ELSE 0 END,
                                    Avail      = CASE WHEN sd.UsesGoodsReceipts = 1 OR sd.ReceiptMode = 2 THEN s.ReceivedQuantityBase - s.ReturnedQuantityBase
                                                      ELSE s.QuantityBase - s.ReturnedQuantityBase END) g
                WHERE x.Qty > g.Avail
                ORDER BY x.LineNumber;
                IF @Msg IS NOT NULL THROW 65011, @Msg, 1;
            END
        END

        IF @Direction = -1
        BEGIN
            SELECT TOP (1) @Msg = N'Insufficient stock for ' + i.ItemCode + N' in ' + w.WarehouseCode + N': available '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N', required ' + CAST(x.Qty AS NVARCHAR(20)) + N' (base units).'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 65007, @Msg, 1;
        END

        IF @Number IS NULL
            EXEC inventory.usp_DocumentType_NextNumber @TypeCode, @Number OUTPUT, @BranchId;

        IF @TypeCode = N'PINV'
        BEGIN
            -- FOB per base unit, then charges allocated over the lines, then landed cost per base unit.
            EXEC purchase.usp_PurchaseCharges_Allocate N'PINV', @Id, @Id;

            UPDATE l
            SET FobCostBase = (l.LineTotal / @Rate) / l.QuantityBase,
                AllocatedChargesBase = ISNULL(a.Total, 0),
                UnitCostBase = ((l.LineTotal / @Rate) + ISNULL(a.Total, 0)) / l.QuantityBase
            FROM purchase.PurchaseDocumentLines l
            OUTER APPLY (SELECT SUM(x.AmountBase) AS Total
                         FROM purchase.PurchaseChargeAllocations x
                         INNER JOIN purchase.PurchaseCharges c ON c.Id = x.ChargeId
                         WHERE x.PurchaseLineId = l.Id AND c.DocumentKind = N'PINV' AND c.DocumentId = @Id AND c.IncludeInLandedCost = 1) a
            WHERE l.DocumentId = @Id;

            UPDATE d
            SET TotalChargesBase = ISNULL(x.Charges, 0), TotalLandedCostBase = d.TotalAmountBase + ISNULL(x.Charges, 0)
            FROM purchase.PurchaseDocuments d
            CROSS APPLY (SELECT SUM(AllocatedChargesBase) AS Charges FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id) x
            WHERE d.Id = @Id;
        END
        ELSE IF @TypeCode = N'PRET'
        BEGIN
            -- (65) Rule 23: from an invoice that uses goods receipts, or is shipped in containers, the goods go back at the
            --      invoice line's OWN CURRENT cost, worked out again now (a landed cost adjustment or a late container
            --      charge may have moved it since the draft): its landed cost, or for a container line its FOB + the
            --      container line's charges per piece received; for a line NOT linked whose pieces are matched to goods
            --      received in containers, those containers' charges per matched piece (as usp_PurchaseDocument_Save).
            --      The FOB is the invoice line's.
            UPDATE l
            SET UnitCostBase = CASE WHEN scl.Id IS NOT NULL THEN src.FobCostBase + ISNULL(scl.ChargesBase / NULLIF(scl.ReceivedQuantityBase, 0), 0)
                                    WHEN mc.CtPcs > 0 THEN (mc.CtPcs * src.FobCostBase + mc.CtCharges + (mc.Pcs - mc.CtPcs) * src.UnitCostBase) / mc.Pcs
                                    ELSE src.UnitCostBase END,
                FobCostBase  = src.FobCostBase
            FROM purchase.PurchaseDocumentLines l
            INNER JOIN purchase.PurchaseDocumentLines src ON src.Id = l.SourceLineId
            INNER JOIN purchase.PurchaseDocuments sd      ON sd.Id = src.DocumentId
            LEFT  JOIN logistics.ContainerLines scl       ON scl.Id = src.ContainerLineId
            OUTER APPLY (SELECT Pcs       = SUM(m.QuantityBase),
                                CtPcs     = SUM(CASE WHEN gl.ContainerLineId IS NOT NULL THEN m.QuantityBase ELSE 0 END),
                                CtCharges = SUM(CASE WHEN gl.ContainerLineId IS NOT NULL
                                                     THEN m.QuantityBase * ISNULL(mcl.ChargesBase / NULLIF(mcl.ReceivedQuantityBase, 0), 0)
                                                     ELSE 0 END)
                         FROM purchase.GoodsReceiptInvoiceMatches m
                         INNER JOIN purchase.GoodsReceiptLines gl ON gl.Id = m.GoodsReceiptLineId
                         LEFT  JOIN logistics.ContainerLines mcl  ON mcl.Id = gl.ContainerLineId
                         WHERE m.InvoiceLineId = src.Id AND src.ContainerLineId IS NULL) mc
            WHERE l.DocumentId = @Id AND (sd.UsesGoodsReceipts = 1 OR sd.ReceiptMode = 2) AND src.FobCostBase IS NOT NULL;

            UPDATE l SET UnitCostBase = ISNULL(l.UnitCostBase, ISNULL(inventory.fn_AverageCost(l.ItemId), 0))
            FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = @Id;
        END

        IF @Direction = 1 AND @StockAtPosting = 1
        BEGIN
            DECLARE @R inventory.tvp_ItemReceipt;
            INSERT INTO @R (ItemId, QuantityBase, UnitCostBase, FobCostBase)
            SELECT l.ItemId, l.QuantityBase, ISNULL(l.UnitCostBase, 0), l.FobCostBase FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = @Id;
            EXEC inventory.usp_Item_ApplyReceipts @R, @SupplierId, @UserId, 1;
        END

        IF @Direction <> 0 AND @StockAtPosting = 1
        BEGIN
            DECLARE @MovementDate DATETIME2(3) =
                DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@DocumentDate AS DATETIME2(3)));

            INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                                  DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, CreatedBy)
            -- (48) the branch of the line's warehouse, which need not be the document's branch
            SELECT @MovementDate, l.ItemId, l.WarehouseId, w.BranchId, @Direction * l.QuantityBase, l.UnitCostBase,
                   N'Purchase', @TypeCode, @Id, l.Id, @Number, NULL, l.ExpiryDate, @UserId
            FROM purchase.PurchaseDocumentLines l
            INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
            WHERE l.DocumentId = @Id;

            IF @Direction = 1
                UPDATE purchase.PurchaseDocumentLines SET ReceivedQuantityBase = QuantityBase WHERE DocumentId = @Id;
        END

        IF @SourceId IS NOT NULL AND @TypeCode = N'PINV'
        BEGIN
            UPDATE s SET ReceivedQuantityBase = s.ReceivedQuantityBase + x.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;

            -- (77) An order no longer closes: it stays approved (2), and what it shows - Saved, Partially posted, Posted -
            --      follows its POSTED invoices (purchase.fn_PurchaseOrder_Invoicing). The order's history says which
            --      invoice completed it; the goods may still be to receive, and are received as before.
            IF (SELECT InvoicingStatus FROM purchase.fn_PurchaseOrder_Invoicing(@SourceId)) = 2
                INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
                VALUES (@SourceId, N'Updated', N'Fully invoiced by ' + @Number, @UserId);
        END
        IF @SourceId IS NOT NULL AND @TypeCode = N'PRET'
        BEGIN
            UPDATE s SET ReturnedQuantityBase = s.ReturnedQuantityBase + x.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;
        END

        -- (65) A supplier invoice is marked as using goods receipts WHEN IT IS POSTED (never as a draft): from now on its
        --      lines are matched to received pieces, and their ReceivedQuantityBase is the pieces matched to them.
        UPDATE purchase.PurchaseDocuments
        SET DocumentNumber = @Number, Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId,
            UsesGoodsReceipts = CASE WHEN @TypeCode = N'PINV' THEN 1 ELSE UsesGoodsReceipts END,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        -- (65) GOODS ALREADY RECEIVED FOLLOW THIS INVOICE'S COST. Its pieces are matched to the received pieces of its
        --      groups - each order line it invoices, and the supplier + item for lines without an order - now that it is
        --      posted (usp_GoodsReceipt_Rematch, first in first out); then every posted receipt line of those groups is
        --      brought to its target cost (usp_GoodsReceipt_TrueUpCost, cause PINV): the part still in stock to the
        --      stock value, the rest to cost of sales.
        IF @TypeCode = N'PINV'
        BEGIN
            DECLARE @Anchors purchase.tvp_GoodsReceiptAnchor;
            INSERT INTO @Anchors (Kind, PoLineId, SupplierId, ItemId)
            SELECT DISTINCT 'P', l.SourceLineId, NULL, NULL FROM purchase.PurchaseDocumentLines l
            WHERE l.DocumentId = @Id AND l.SourceLineId IS NOT NULL
            UNION
            SELECT DISTINCT 'S', NULL, @SupplierId, l.ItemId FROM purchase.PurchaseDocumentLines l
            WHERE l.DocumentId = @Id AND l.SourceLineId IS NULL;

            EXEC purchase.usp_GoodsReceipt_Rematch @Anchors;

            DECLARE @GroupLines logistics.tvp_IdList;
            INSERT INTO @GroupLines (Id) SELECT GoodsReceiptLineId FROM purchase.fn_GoodsReceipt_GroupLines(@Anchors);
            IF EXISTS (SELECT 1 FROM @GroupLines)
                EXEC purchase.usp_GoodsReceipt_TrueUpCost @GroupLines, N'PINV', @Id, @Number, @UserId,
                     @CostAmount OUTPUT, @CostInventory OUTPUT, @CostCogs OUTPUT, @CostLines OUTPUT;
        END

        DECLARE @LineCount INT = (SELECT COUNT(*) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id);
        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@Id, N'Posted', LEFT(N'Posted as ' + @Number + N' - ' + CAST(@LineCount AS NVARCHAR(10)) + N' line(s)'
                                + CASE WHEN @Direction <> 0 AND @StockAtPosting = 1 THEN N' written to the stock ledger'
                                       WHEN @StockAtPosting = 0 THEN N'; goods are received with goods receipts'     -- (65) every supplier invoice
                                       WHEN @PostedWithoutApproval = 1 THEN N' (approval not needed)'
                                       ELSE N' (order approved)' END
                                + CASE WHEN @TypeCode = N'PINV' THEN N'; landed charges ' + CAST((SELECT TotalChargesBase FROM purchase.PurchaseDocuments WHERE Id = @Id) AS NVARCHAR(30)) ELSE N'' END
                                + CASE WHEN @CostLines > 0 THEN N'; cost of received goods adjusted by ' + CAST(@CostAmount AS NVARCHAR(30))
                                                                + N' (stock ' + CAST(@CostInventory AS NVARCHAR(30)) + N', cost of sales ' + CAST(@CostCogs AS NVARCHAR(30)) + N')'
                                       ELSE N'' END, 500), @UserId);

        -- A purchase order posted without approval: the user who posts it is recorded as approver, as an approval does.
        IF @PostedWithoutApproval = 1
        BEGIN
            UPDATE purchase.PurchaseDocuments SET ApprovedAtUtc = SYSUTCDATETIME(), ApprovedBy = @UserId WHERE Id = @Id;

            DECLARE @RequireApproval BIT, @ApprovalLimit DECIMAL(19, 4);
            SELECT @RequireApproval = RequireApproval, @ApprovalLimit = ApprovalLimitBase FROM purchase.ApprovalSettings WHERE Id = 1;
            INSERT INTO purchase.PurchaseOrderApprovalEvents (PurchaseDocumentId, EventType, UserId, Note)
            VALUES (@Id, 7, @UserId,
                    CASE WHEN @RequireApproval = 0 THEN N'Approval not required'
                         ELSE N'Under the approval limit of ' + FORMAT(@ApprovalLimit, N'N2', N'en-US')
                              + ISNULL(N' ' + (SELECT TOP (1) CurrencyCode FROM masterdata.Currencies
                                               WHERE IsBaseCurrency = 1 AND IsActive = 1), N'') END);
        END

        -- containers of an import: the invoice is known now (value basis of the charges, history)
        IF @FromContainers = 1
        BEGIN
            DECLARE @Cid INT;
            DECLARE cts CURSOR LOCAL FAST_FORWARD FOR
                SELECT DISTINCT cl.ContainerId FROM purchase.PurchaseDocumentLines l
                INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
                WHERE l.DocumentId = @Id;
            OPEN cts;
            FETCH NEXT FROM cts INTO @Cid;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC logistics.usp_Container_ReallocateCharges @Cid, 1, 1;
                INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
                VALUES (@Cid, N'Updated', N'Purchase invoice ' + @Number + N' posted', @UserId);
                FETCH NEXT FROM cts INTO @Cid;
            END
            CLOSE cts;
            DEALLOCATE cts;
        END

        COMMIT TRANSACTION;
        -- (65) + what the posting did to the cost of goods already received (0 when nothing)
        IF ISNULL(@FromApproval, 0) = 0
            SELECT @Number AS DocumentNumber, CostAdjustedBase = @CostAmount, CostAdjustedInventoryBase = @CostInventory,
                   CostAdjustedCogsBase = @CostCogs, CostAdjustedLines = @CostLines;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    /* (65) "RECEIVE THE GOODS NOW" (decision 7): the invoice is posted and committed above, whatever happens here. Its
       lines not in a container are received with ONE goods receipt (usp_GoodsReceipt_CreateFromInvoice: every line with
       something to receive, into the line's warehouse, dated like the invoice) and posted at once
       (usp_GoodsReceipt_Post), in a second transaction: all or nothing, so a refusal leaves no draft behind and
       "Receive goods..." on the invoice still offers everything. The refusal comes back in @ReceiveWarning; the
       receipt's id and number in @GoodsReceiptId / @GoodsReceiptNumber. usp_GoodsReceipt_Post returns its own
       DocumentNumber as a further result set, after the invoice's row: the receipt's outcome is read from the OUTPUT
       parameters. Inside a caller's transaction there is no second transaction to make: nothing is received. */
    IF ISNULL(@ReceiveNow, 0) = 1 AND @TypeCode = N'PINV'
    BEGIN
        DECLARE @ReceiptId INT = NULL, @ReceiptReason NVARCHAR(600) = NULL, @ReceiptDate DATE = @DocumentDate;
        IF @@TRANCOUNT > 0
            SET @ReceiptReason = N'it is made in a transaction of its own, and this posting runs inside another one';
        ELSE
        BEGIN
            BEGIN TRY
                BEGIN TRANSACTION;

                -- the matcher first, before the draft's rows are written (usp_GoodsReceipt_Post takes it again)
                EXEC purchase.usp_GoodsReceipt_LockMatching;

                DECLARE @NoLines purchase.tvp_GoodsReceiptLine;
                EXEC purchase.usp_GoodsReceipt_CreateFromInvoice @InvoiceId = @Id, @Lines = @NoLines, @DocumentDate = @ReceiptDate,
                     @UserId = @UserId, @NewId = @ReceiptId OUTPUT;
                EXEC purchase.usp_GoodsReceipt_Post @Id = @ReceiptId, @RowVersion = NULL, @UserId = @UserId;

                SELECT @GoodsReceiptId = Id, @GoodsReceiptNumber = DocumentNumber FROM purchase.GoodsReceipts WHERE Id = @ReceiptId;
                COMMIT TRANSACTION;
            END TRY
            BEGIN CATCH
                IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
                SELECT @GoodsReceiptId = NULL, @GoodsReceiptNumber = NULL, @ReceiptReason = ERROR_MESSAGE();
            END CATCH
        END

        IF @ReceiptReason IS NOT NULL
        BEGIN
            -- "Invoice posted; the goods receipt was not: {reason}. Use Receive goods..." (one final period)
            SET @ReceiptReason = LTRIM(RTRIM(@ReceiptReason));
            IF RIGHT(@ReceiptReason, 1) = N'.' SET @ReceiptReason = LEFT(@ReceiptReason, LEN(@ReceiptReason) - 1);
            SET @ReceiveWarning = LEFT(N'Invoice posted; the goods receipt was not: ' + @ReceiptReason + N'. Use Receive goods' + NCHAR(8230), 700);
        END
    END
END
GO

/* ================================================================== 4. Goods receipt post: the order is no longer closed */

-- Re-created (77) from the body of script 64: step 7 still adds the received and settled-short pieces to the order
-- lines and writes "Goods received by GRN-..." on the orders, but no longer closes an order fully invoiced and
-- received: an order's status follows its invoices only (section 1). Nothing else changes.
CREATE OR ALTER PROCEDURE purchase.usp_GoodsReceipt_Post
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- lock order: the matcher first, then rows, or two postings deadlock (usp_GoodsReceipt_LockMatching)
        EXEC purchase.usp_GoodsReceipt_LockMatching;

        DECLARE @Status TINYINT, @SourceKind NVARCHAR(10), @ContainerId INT, @BranchId INT, @WarehouseId INT, @SupplierId INT,
                @DocumentDate DATE, @Ref NVARCHAR(30);
        SELECT @Status = g.Status, @SourceKind = g.SourceKind, @ContainerId = g.ContainerId, @BranchId = g.BranchId,
               @WarehouseId = g.WarehouseId, @SupplierId = g.SupplierId, @DocumentDate = g.DocumentDate
        FROM purchase.GoodsReceipts g WITH (UPDLOCK, HOLDLOCK)
        WHERE g.Id = @Id;

        IF @Status IS NULL THROW 63006, 'Goods receipt not found.', 1;
        IF @Status <> 1 THROW 63010, 'Only a draft goods receipt can be posted.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.GoodsReceipts WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 63004, 'This goods receipt was modified by another user. Reload the page and try again.', 1;

        -- the container, the order lines and the invoice lines without an order stay as they are until this receipt is
        -- posted: an invoice line's received pieces change only in usp_GoodsReceipt_Rematch, after the check, so a
        -- second posting of the same line must wait here and then read them (Seq 20, 63011), as an order line does
        IF @ContainerId IS NOT NULL
            SELECT @Ref = c.ContainerRef FROM logistics.Containers c WITH (UPDLOCK, HOLDLOCK) WHERE c.Id = @ContainerId;
        DECLARE @Locked INT = (SELECT COUNT(*) FROM purchase.PurchaseDocumentLines pol WITH (UPDLOCK, HOLDLOCK)
                               WHERE pol.Id IN (SELECT gl.PoLineId FROM purchase.GoodsReceiptLines gl WHERE gl.GoodsReceiptId = @Id
                                                UNION
                                                SELECT gl.InvoiceLineId FROM purchase.GoodsReceiptLines gl
                                                WHERE gl.GoodsReceiptId = @Id AND gl.PoLineId IS NULL));

        DECLARE @Err INT, @Msg NVARCHAR(400);
        SELECT TOP (1) @Err = ErrorNumber, @Msg = Message FROM purchase.fn_GoodsReceipt_PostCheck(@Id) ORDER BY Seq;
        IF @Err IS NOT NULL
        BEGIN
            SET @Msg = ISNULL(@Msg, N'This goods receipt cannot be posted.');
            THROW @Err, @Msg, 1;
        END

        /* ---- 2. Number and status */
        DECLARE @Number NVARCHAR(30);
        EXEC inventory.usp_DocumentType_NextNumber N'GRN', @Number OUTPUT, @BranchId;

        UPDATE purchase.GoodsReceipts
        SET DocumentNumber = @Number, Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        /* ---- 3. Lines, settled short, matches */
        UPDATE gl
        SET WarehouseId        = CASE WHEN @SourceKind = N'Container' THEN @WarehouseId ELSE COALESCE(gl.WarehouseId, @WarehouseId) END,
            SupplierId         = COALESCE(po.SupplierId, inv.SupplierId, gl.SupplierId, @SupplierId),
            ManualUnitCostBase = CASE WHEN gl.PoLineId IS NULL AND gl.InvoiceLineId IS NULL
                                      THEN COALESCE(gl.ManualUnitCostBase, i.LastCost, i.AverageCost) ELSE gl.ManualUnitCostBase END,
            PoFobBase          = CASE WHEN gl.PoLineId IS NOT NULL
                                      THEN CAST(pol.LineTotal / po.ExchangeRate / NULLIF(pol.QuantityBase, 0) AS DECIMAL(18,6)) END
        FROM purchase.GoodsReceiptLines gl
        INNER JOIN inventory.Items i                  ON i.Id = gl.ItemId
        LEFT  JOIN purchase.PurchaseDocumentLines pol ON pol.Id = gl.PoLineId
        LEFT  JOIN purchase.PurchaseDocuments po      ON po.Id = pol.DocumentId
        LEFT  JOIN purchase.PurchaseDocumentLines il  ON il.Id = gl.InvoiceLineId
        LEFT  JOIN purchase.PurchaseDocuments inv     ON inv.Id = il.DocumentId
        WHERE gl.GoodsReceiptId = @Id;

        -- SETTLED SHORT: nothing more is expected for those pieces. A container line always settles loaded - received
        -- (a reason is required). A local line marked "Nothing more will come" settles the rest of its order line -
        -- at most what it expected - and never more than the order line still lacks.
        WITH s AS
        (
            SELECT gl.Id, gl.PoLineId, gl.LineNumber,
                   Want = CASE WHEN gl.ContainerLineId IS NOT NULL
                               THEN CASE WHEN gl.ExpectedQuantityBase > gl.QuantityBase THEN gl.ExpectedQuantityBase - gl.QuantityBase ELSE 0 END
                               WHEN gl.CloseShort = 1 AND gl.PoLineId IS NOT NULL
                               THEN CASE WHEN gl.ExpectedQuantityBase IS NULL THEN rest.Q
                                         WHEN gl.ExpectedQuantityBase - gl.QuantityBase < rest.Q
                                         THEN CASE WHEN gl.ExpectedQuantityBase > gl.QuantityBase THEN gl.ExpectedQuantityBase - gl.QuantityBase ELSE 0 END
                                         ELSE rest.Q END
                               ELSE 0 END,
                   IsLocal = CASE WHEN gl.ContainerLineId IS NULL THEN 1 ELSE 0 END,
                   Rest = rest.Q
            FROM purchase.GoodsReceiptLines gl
            OUTER APPLY (SELECT Q = CASE WHEN x.Q > 0 THEN x.Q ELSE 0 END
                         FROM (SELECT Q = p.OrderedBase - p.GoodsReceivedBase - p.GoodsShortBase - p.InContainersBase
                                          - (SELECT SUM(o.QuantityBase) FROM purchase.GoodsReceiptLines o
                                             WHERE o.GoodsReceiptId = @Id AND o.PoLineId = gl.PoLineId AND o.ContainerLineId IS NULL)
                               FROM purchase.fn_PoLine_Progress(gl.PurchaseOrderId) p
                               WHERE p.PoLineId = gl.PoLineId) x) rest
            WHERE gl.GoodsReceiptId = @Id
        ),
        c AS
        (
            SELECT s.Id, s.Want, s.IsLocal, s.Rest,
                   Before = ISNULL(SUM(CASE WHEN s.IsLocal = 1 THEN s.Want ELSE 0 END)
                                   OVER (PARTITION BY s.PoLineId, s.IsLocal ORDER BY s.LineNumber ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)
            FROM s
        )
        UPDATE gl
        SET SettledShortBase = CASE WHEN c.IsLocal = 0 THEN c.Want
                                    WHEN c.Want <= 0 THEN 0
                                    WHEN ISNULL(c.Rest, 0) - c.Before <= 0 THEN 0
                                    WHEN c.Want > ISNULL(c.Rest, 0) - c.Before THEN ISNULL(c.Rest, 0) - c.Before
                                    ELSE c.Want END
        FROM purchase.GoodsReceiptLines gl INNER JOIN c ON c.Id = gl.Id;

        DECLARE @Anchors purchase.tvp_GoodsReceiptAnchor;
        INSERT INTO @Anchors (Kind, PoLineId, SupplierId, ItemId)
        SELECT DISTINCT 'P', gl.PoLineId, NULL, NULL FROM purchase.GoodsReceiptLines gl WHERE gl.GoodsReceiptId = @Id AND gl.PoLineId IS NOT NULL
        UNION
        SELECT DISTINCT 'S', NULL, gl.SupplierId, gl.ItemId FROM purchase.GoodsReceiptLines gl
        WHERE gl.GoodsReceiptId = @Id AND gl.PoLineId IS NULL AND gl.SupplierId IS NOT NULL;

        EXEC purchase.usp_GoodsReceipt_Rematch @Anchors;

        /* ---- 4. Cost at receipt */
        IF @SourceKind = N'Container'
        BEGIN
            UPDATE cl
            SET ReceivedQuantityBase = gl.QuantityBase,
                -- the reason's NAME, as the receipt shows it ("Short-shipped: 2 pcs short"), never the internal code: the
                -- container page and the item's containers show this text as it is
                VarianceReason = CASE WHEN gl.VarianceReasonCode IS NULL THEN NULLIF(LTRIM(RTRIM(gl.VarianceReason)), N'')
                                      ELSE CASE gl.VarianceReasonCode WHEN N'SHORT' THEN N'Short-shipped' WHEN N'DAMAGED' THEN N'Damaged'
                                                                      WHEN N'MISSING' THEN N'Missing'
                                                                      WHEN N'LOADCOUNT' THEN N'Wrongly counted at loading'
                                                                      WHEN N'OTHER' THEN N'Other' ELSE gl.VarianceReasonCode END
                                           + ISNULL(N': ' + NULLIF(LTRIM(RTRIM(gl.VarianceReason)), N''), N'') END,
                FobCostBase = COALESCE(t.TargetFobBase, gl.PoFobBase)
            FROM logistics.ContainerLines cl
            INNER JOIN purchase.GoodsReceiptLines gl ON gl.ContainerLineId = cl.Id AND gl.GoodsReceiptId = @Id
            LEFT  JOIN purchase.fn_GoodsReceiptLine_TargetCost(@Id) t ON t.GoodsReceiptLineId = gl.Id
            WHERE cl.ContainerId = @ContainerId;

            -- the posted charges follow the real quantities and values, then they are frozen in the cost of the goods
            EXEC logistics.usp_Container_ReallocateCharges @ContainerId, 0;
            UPDATE logistics.ContainerCharges SET AppliedAtOffload = 1
            WHERE ContainerId = @ContainerId AND Status = 2 AND IncludeInLandedCost = 1;
            EXEC logistics.usp_Container_RecalcCosts @ContainerId;
        END

        UPDATE gl
        SET FobCostBase       = CASE WHEN gl.ContainerLineId IS NULL THEN t.TargetFobBase END,
            ChargesBase       = CASE WHEN gl.ContainerLineId IS NULL THEN t.TargetChargesBase END,
            UnitCostBase      = CASE WHEN gl.ContainerLineId IS NULL THEN t.TargetUnitCostBase END,
            CostAtReceiptBase = CASE WHEN gl.ContainerLineId IS NOT NULL THEN cl.LandedCostBase ELSE t.TargetUnitCostBase END,
            CostSource        = COALESCE(t.CostSource, CASE WHEN gl.PoLineId IS NOT NULL THEN N'Order' ELSE gl.CostSource END)
        FROM purchase.GoodsReceiptLines gl
        LEFT JOIN logistics.ContainerLines cl ON cl.Id = gl.ContainerLineId
        LEFT JOIN purchase.fn_GoodsReceiptLine_TargetCost(@Id) t ON t.GoodsReceiptLineId = gl.Id
        WHERE gl.GoodsReceiptId = @Id;

        /* ---- 5. The other receipts of the same groups, BEFORE this receipt's stock goes in: their in-stock share
                  (company stock on hand) must count only goods that were in stock before it. This receipt's pieces are
                  already at their own cost (step 4); counted as the others' goods, the others' cost change would go to
                  the stock value instead of cost of sales. Its own lines are never among the others. */
        DECLARE @Others logistics.tvp_IdList;
        INSERT INTO @Others (Id)
        SELECT GoodsReceiptLineId FROM purchase.fn_GoodsReceipt_GroupLines(@Anchors) WHERE GoodsReceiptId <> @Id;
        IF EXISTS (SELECT 1 FROM @Others)
            EXEC purchase.usp_GoodsReceipt_TrueUpCost @Others, N'GRNPOST', @Id, @Number, @UserId;

        /* ---- 6. Stock (the average as step 5 left it) */
        DECLARE @MovementDate DATETIME2(3) =
            DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@DocumentDate AS DATETIME2(3)));
        DECLARE @AdjustmentDate DATETIME2(3) = CASE WHEN @MovementDate > SYSUTCDATETIME() THEN @MovementDate ELSE SYSUTCDATETIME() END;

        -- one batch per supplier and per "changes the last cost": usp_Item_ApplyReceipts takes one supplier and one flag,
        -- and each batch's movements go in before the next batch's average is worked out
        DECLARE @Rec TABLE (LineId INT NOT NULL PRIMARY KEY, Batch INT NOT NULL, ItemId INT NOT NULL, WarehouseId INT NOT NULL, BranchId INT NOT NULL,
                            SupplierId INT NULL, UpdateLast BIT NOT NULL, QuantityBase INT NOT NULL, UnitCostBase DECIMAL(18,6) NOT NULL,
                            FobCostBase DECIMAL(18,6) NULL, ExpiryDate DATE NULL);
        INSERT INTO @Rec (LineId, Batch, ItemId, WarehouseId, BranchId, SupplierId, UpdateLast, QuantityBase, UnitCostBase, FobCostBase, ExpiryDate)
        SELECT x.LineId, DENSE_RANK() OVER (ORDER BY ISNULL(x.SupplierId, 0), x.UpdateLast DESC),
               x.ItemId, x.WarehouseId, x.BranchId, x.SupplierId, x.UpdateLast, x.QuantityBase, x.UnitCostBase, x.FobCostBase, x.ExpiryDate
        FROM (SELECT LineId = gl.Id, gl.ItemId, gl.WarehouseId, w.BranchId, gl.SupplierId,
                     UpdateLast = CAST(CASE WHEN gl.PoLineId IS NULL AND gl.InvoiceLineId IS NULL AND gl.InvoicedBase = 0 THEN 0 ELSE 1 END AS BIT),
                     gl.QuantityBase, UnitCostBase = ISNULL(gl.CostAtReceiptBase, 0),
                     FobCostBase = CASE WHEN gl.ContainerLineId IS NOT NULL THEN cl.FobCostBase ELSE gl.FobCostBase END, gl.ExpiryDate
              FROM purchase.GoodsReceiptLines gl
              INNER JOIN masterdata.Warehouses w    ON w.Id = gl.WarehouseId
              LEFT  JOIN logistics.ContainerLines cl ON cl.Id = gl.ContainerLineId
              WHERE gl.GoodsReceiptId = @Id AND gl.QuantityBase > 0) x;

        -- the average the goods sold before this receipt went out at (rule 9a)
        DECLARE @Before TABLE (ItemId INT NOT NULL PRIMARY KEY, AverageCost DECIMAL(18,6) NOT NULL);
        INSERT INTO @Before (ItemId, AverageCost)
        SELECT i.Id, i.AverageCost FROM inventory.Items i WHERE i.Id IN (SELECT ItemId FROM @Rec);

        DECLARE @Neg TABLE (LineId INT NOT NULL PRIMARY KEY, ItemId INT NOT NULL, WarehouseId INT NOT NULL, BranchId INT NOT NULL, R INT NOT NULL,
                            CostBefore DECIMAL(18,6) NOT NULL, CostAfter DECIMAL(18,6) NOT NULL, Raw DECIMAL(38,10) NOT NULL, Amount DECIMAL(18,2) NULL);
        DECLARE @NegChanges TABLE (ChangeId INT NOT NULL PRIMARY KEY, LineId INT NOT NULL);
        DECLARE @R inventory.tvp_ItemReceipt;
        DECLARE @Batch INT = 1, @Batches INT = ISNULL((SELECT MAX(Batch) FROM @Rec), 0), @BatchSupplier INT, @BatchLast BIT;

        WHILE @Batch <= @Batches
        BEGIN
            SELECT TOP (1) @BatchSupplier = SupplierId, @BatchLast = UpdateLast FROM @Rec WHERE Batch = @Batch;

            -- NEGATIVE COMPANY STOCK FILLED BY THIS BATCH: those pieces were sold at the average before the receipt and are
            -- not in stock; the moving average starts again at the batch's cost, so (cost - average before) x the pieces
            -- filled would be in neither the stock nor the cost of sales. It goes to cost of sales, shared over the
            -- batch's lines of the item by their pieces (cents to the largest line).
            DELETE FROM @Neg;
            INSERT INTO @Neg (LineId, ItemId, WarehouseId, BranchId, R, CostBefore, CostAfter, Raw)
            SELECT r.LineId, r.ItemId, r.WarehouseId, r.BranchId, r.QuantityBase, bf.AverageCost, r.UnitCostBase,
                   CAST((r.UnitCostBase - bf.AverageCost) * f.F * r.QuantityBase AS DECIMAL(38,10)) / q.Qty
            FROM @Rec r
            INNER JOIN (SELECT ItemId, Qty = SUM(QuantityBase) FROM @Rec WHERE Batch = @Batch GROUP BY ItemId) q ON q.ItemId = r.ItemId
            INNER JOIN @Before bf ON bf.ItemId = r.ItemId
            CROSS APPLY (SELECT OnHand = inventory.fn_StockOnHand(r.ItemId, NULL)) oh
            CROSS APPLY (SELECT F = CASE WHEN oh.OnHand >= 0 THEN 0 WHEN -oh.OnHand < q.Qty THEN -oh.OnHand ELSE q.Qty END) f
            WHERE r.Batch = @Batch AND f.F > 0;

            IF EXISTS (SELECT 1 FROM @Neg)
            BEGIN
                UPDATE @Neg SET Amount = ROUND(Raw, 2);
                WITH d AS (SELECT n.LineId, Diff = ROUND(SUM(n.Raw) OVER (PARTITION BY n.ItemId), 2) - SUM(n.Amount) OVER (PARTITION BY n.ItemId),
                                  Rn = ROW_NUMBER() OVER (PARTITION BY n.ItemId ORDER BY n.R DESC, n.LineId)
                           FROM @Neg n)
                UPDATE n SET Amount = n.Amount + d.Diff FROM @Neg n INNER JOIN d ON d.LineId = n.LineId WHERE d.Rn = 1 AND d.Diff <> 0;

                DELETE FROM @NegChanges;
                INSERT INTO purchase.GoodsReceiptCostChanges (GoodsReceiptLineId, CauseKind, CauseId, CauseNumber, ReceivedBase, InStockBase,
                                                              FobBefore, FobAfter, UnitCostBefore, UnitCostAfter, AmountBase, InventoryBase, CogsBase, CreatedBy)
                OUTPUT inserted.Id, inserted.GoodsReceiptLineId INTO @NegChanges (ChangeId, LineId)
                SELECT n.LineId, N'NEGSTOCK', @Id, @Number, n.R, 0, NULL, NULL, n.CostBefore, n.CostAfter, n.Amount, 0, n.Amount, @UserId
                FROM @Neg n WHERE n.Amount <> 0;

                INSERT INTO inventory.CostAdjustments (AdjustmentDate, ItemId, WarehouseId, BranchId, Kind, AmountBase, SourceKind, SourceId, SourceNumber, PurchaseLineId, CreatedBy)
                SELECT @AdjustmentDate, n.ItemId, n.WarehouseId, n.BranchId, N'COGS', n.Amount, N'GRNCOST', c.ChangeId, @Number, NULL, @UserId
                FROM @Neg n INNER JOIN @NegChanges c ON c.LineId = n.LineId;
            END

            -- moving average first (on-hand before these movements), then the movements of the batch
            DELETE FROM @R;
            INSERT INTO @R (ItemId, QuantityBase, UnitCostBase, FobCostBase)
            SELECT ItemId, QuantityBase, UnitCostBase, FobCostBase FROM @Rec WHERE Batch = @Batch;
            EXEC inventory.usp_Item_ApplyReceipts @R, @BatchSupplier, @UserId, @BatchLast;

            INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                                  DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, CreatedBy)
            SELECT @MovementDate, r.ItemId, r.WarehouseId, r.BranchId, r.QuantityBase, r.UnitCostBase,
                   N'Purchase', N'GRN', @Id, r.LineId, @Number, NULL, r.ExpiryDate, @UserId
            FROM @Rec r
            WHERE r.Batch = @Batch;

            SET @Batch += 1;
        END

        /* ---- 7. Order lines: received, settled short (77: the order's status does not depend on its receipts) */
        UPDATE pol
        SET GoodsReceivedBase = pol.GoodsReceivedBase + x.Rec, GoodsShortBase = pol.GoodsShortBase + x.Short
        FROM purchase.PurchaseDocumentLines pol
        INNER JOIN (SELECT PoLineId, Rec = SUM(QuantityBase), Short = SUM(SettledShortBase)
                    FROM purchase.GoodsReceiptLines WHERE GoodsReceiptId = @Id AND PoLineId IS NOT NULL GROUP BY PoLineId) x ON x.PoLineId = pol.Id;

        DECLARE @Orders TABLE (Id INT NOT NULL PRIMARY KEY, Pcs INT NOT NULL);
        INSERT INTO @Orders (Id, Pcs)
        SELECT PurchaseOrderId, SUM(QuantityBase) FROM purchase.GoodsReceiptLines
        WHERE GoodsReceiptId = @Id AND PurchaseOrderId IS NOT NULL GROUP BY PurchaseOrderId;

        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        SELECT o.Id, N'Updated', N'Goods received by ' + @Number + N' - ' + CAST(o.Pcs AS NVARCHAR(20)) + N' pcs', @UserId FROM @Orders o;

        /* ---- 8. The container */
        IF @SourceKind = N'Container'
        BEGIN
            UPDATE logistics.Containers
            SET OffloadedDate = @DocumentDate, OffloadedAtUtc = SYSUTCDATETIME(), OffloadedBy = @UserId,
                WarehouseId = @WarehouseId, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @ContainerId;

            EXEC logistics.usp_Container_RefreshStatus @ContainerId;

            DECLARE @CtPcs INT, @CtValue DECIMAL(18,2), @CtShort INT;
            SELECT @CtPcs = ISNULL(SUM(gl.QuantityBase), 0),
                   @CtValue = ISNULL(SUM(gl.QuantityBase * gl.CostAtReceiptBase), 0),
                   @CtShort = SUM(CASE WHEN gl.QuantityBase < gl.ExpectedQuantityBase THEN 1 ELSE 0 END)
            FROM purchase.GoodsReceiptLines gl WHERE gl.GoodsReceiptId = @Id;

            INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
            VALUES (@ContainerId, N'Offloaded',
                    LEFT(@Number + N': received ' + CAST(@CtPcs AS NVARCHAR(20)) + N' pcs into '
                         + (SELECT WarehouseCode FROM masterdata.Warehouses WHERE Id = @WarehouseId)
                         + N' at a landed value of ' + CAST(@CtValue AS NVARCHAR(30))
                         + CASE WHEN @CtShort > 0 THEN N'; ' + CAST(@CtShort AS NVARCHAR(10)) + N' line(s) short-shipped' ELSE N'' END, 500), @UserId);
        END

        /* ---- 9. Totals and audits */
        UPDATE g
        SET TotalExpectedBase = x.Expected, TotalReceivedBase = x.Received, ValueAtReceiptBase = x.Value
        FROM purchase.GoodsReceipts g
        CROSS APPLY (SELECT Expected = ISNULL(SUM(ISNULL(gl.ExpectedQuantityBase, gl.QuantityBase)), 0),
                            Received = ISNULL(SUM(gl.QuantityBase), 0),
                            Value    = CAST(ROUND(ISNULL(SUM(gl.QuantityBase * gl.CostAtReceiptBase), 0), 2) AS DECIMAL(18,2))
                     FROM purchase.GoodsReceiptLines gl WHERE gl.GoodsReceiptId = g.Id) x
        WHERE g.Id = @Id;

        DECLARE @Pcs INT = (SELECT TotalReceivedBase FROM purchase.GoodsReceipts WHERE Id = @Id),
                @Settled INT = (SELECT SUM(SettledShortBase) FROM purchase.GoodsReceiptLines WHERE GoodsReceiptId = @Id);
        DECLARE @Into NVARCHAR(100) =
            CASE WHEN (SELECT COUNT(DISTINCT WarehouseId) FROM purchase.GoodsReceiptLines WHERE GoodsReceiptId = @Id AND QuantityBase > 0) > 1
                 THEN CAST((SELECT COUNT(DISTINCT WarehouseId) FROM purchase.GoodsReceiptLines WHERE GoodsReceiptId = @Id AND QuantityBase > 0) AS NVARCHAR(10)) + N' warehouses'
                 ELSE ISNULL((SELECT TOP (1) w.WarehouseCode FROM purchase.GoodsReceiptLines gl
                              INNER JOIN masterdata.Warehouses w ON w.Id = gl.WarehouseId
                              WHERE gl.GoodsReceiptId = @Id ORDER BY CASE WHEN gl.QuantityBase > 0 THEN 0 ELSE 1 END, gl.LineNumber), N'-') END;

        INSERT INTO purchase.GoodsReceiptAudit (GoodsReceiptId, Action, Details, UserId)
        VALUES (@Id, N'Posted', LEFT(N'Posted as ' + @Number + N' - ' + CAST(@Pcs AS NVARCHAR(20)) + N' pcs into ' + @Into
                                     + CASE WHEN @Settled > 0 THEN N', ' + CAST(@Settled AS NVARCHAR(20)) + N' pcs settled short' ELSE N'' END, 500), @UserId);

        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        SELECT DISTINCT il.DocumentId, N'Updated', N'Goods received by ' + @Number, @UserId
        FROM purchase.GoodsReceiptInvoiceMatches m
        INNER JOIN purchase.GoodsReceiptLines gl     ON gl.Id = m.GoodsReceiptLineId AND gl.GoodsReceiptId = @Id
        INNER JOIN purchase.PurchaseDocumentLines il ON il.Id = m.InvoiceLineId;

        COMMIT TRANSACTION;
        SELECT @Number AS DocumentNumber;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 5. Close Order: retired */

-- Re-created (77): an order is no longer closed. Its parameters stay for an older caller; the procedure refuses.
-- Pieces that will never arrive are settled with "Nothing more will come" when goods are received.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Close
    @Id         INT,
    @Reason     NVARCHAR(300) = NULL,     -- ignored since script 77
    @RowVersion BINARY(8)     = NULL,     -- ignored since script 77
    @UserId     INT           = NULL      -- ignored since script 77
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id) THROW 65006, 'Document not found.', 1;
    THROW 65010, 'Purchase orders are no longer closed: an order shows Saved, Partially posted or Posted from its posted invoices. Use "Nothing more will come" when receiving to settle pieces that will never arrive.', 1;
END
GO

/* ================================================================== 6. Get: the linked documents say how far an order is invoiced */

-- Re-created (77) from the body of script 65: the source and child documents (result set 5) carry InvoicingStatus,
-- so an invoice page names its order Saved, Partially posted or Posted. Nothing else changes.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.Id, d.DocumentTypeId, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, dt.StockDirection, dt.NumberOnPost,
           d.DocumentNumber, d.DocumentDate, d.ExpectedDate,
           d.BranchId, b.BranchCode, b.BranchName, d.WarehouseId, w.WarehouseCode, w.WarehouseName,
           d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName, sp.Phone AS SupplierPhone, sp.Email AS SupplierEmail, sp.Address AS SupplierAddress,
           d.CurrencyId, c.CurrencyCode, c.CurrencyName, c.Symbol AS CurrencySymbol, c.DecimalPlaces, c.IsBaseCurrency,
           d.RateType, d.ExchangeRate, bc.CurrencyCode AS BaseCurrencyCode,
           d.SupplierReference, d.ExporterReference, d.CommercialInvoiceNo, d.ReceiptMode, d.Notes, d.Status,
           IsContainerBound = CAST(CASE WHEN EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines x
                                                    WHERE x.DocumentId = d.Id AND x.ContainerLineId IS NOT NULL) THEN 1 ELSE 0 END AS BIT),
           ContainerCount = CASE WHEN dt.Code = N'PO'
                                 THEN (SELECT COUNT(DISTINCT cl.ContainerId) FROM logistics.ContainerLines cl
                                       INNER JOIN logistics.Containers c9 ON c9.Id = cl.ContainerId
                                       WHERE cl.PurchaseOrderId = d.Id AND c9.Status <> 8)
                                 ELSE (SELECT COUNT(DISTINCT cl.ContainerId) FROM purchase.PurchaseDocumentLines x
                                       INNER JOIN logistics.ContainerLines cl ON cl.Id = x.ContainerLineId
                                       WHERE x.DocumentId = d.Id) END,
           LoadedBase = CASE WHEN dt.Code = N'PO'
                             THEN ISNULL((SELECT SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                                          INNER JOIN logistics.Containers c9 ON c9.Id = cl.ContainerId
                                          WHERE cl.PurchaseOrderId = d.Id AND c9.Status <> 8), 0) END,
           ContainerChargesBase = cch.Share,
           ContainersNeeded = need.Containers,     -- (43) invoices: sum over the items of the pieces / pieces per container
           d.ApprovalRequestedAtUtc, d.ApprovalRequestedBy, rqu.FullName AS ApprovalRequestedByName,
           d.ApprovedAtUtc, d.ApprovedBy, apu.FullName AS ApprovedByName, d.ApprovalChannel,
           d.RejectedAtUtc, d.RejectedBy, rju.FullName AS RejectedByName, d.RejectReason,
           OrderedBase = prog.Ordered, InvoicedBase = prog.Invoiced, InDraftInvoicesBase = ISNULL(drf.InDraft, 0),
           InvoicingStatus = CASE WHEN dt.Code <> N'PO' THEN NULL WHEN ISNULL(prog.Invoiced, 0) = 0 THEN 0
                                  WHEN prog.Invoiced >= prog.Ordered THEN 2 ELSE 1 END,      -- 0 not, 1 partially, 2 fully invoiced
           d.TotalItems, d.TotalQuantity, d.Subtotal, d.TotalDiscount, d.TotalAmount, d.TotalAmountBase, d.TotalChargesBase, d.TotalLandedCostBase,
           d.SourceDocumentId, src.DocumentNumber AS SourceDocumentNumber, sdt.Code AS SourceDocumentTypeCode,
           d.SourceShortageId, sh.DocumentNumber AS SourceShortageNumber,
           d.PostedAtUtc, d.PostedBy, pu.FullName AS PostedByName,
           d.CancelledAtUtc, d.CancelledBy, xu.FullName AS CancelledByName, d.CancelReason,
           d.ClosedAtUtc, d.ClosedBy, ku.FullName AS ClosedByName, d.CloseReason,
           d.CreatedAtUtc, d.CreatedBy, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.UpdatedBy, uu.FullName AS UpdatedByName,
           d.RowVersion,
           -- (47) supplier payments: posted purchase invoices only (NULL otherwise)
           PaidAmount = pst.PaidAmount, ReturnedAmount = pst.ReturnedAmount, OutstandingAmount = pst.OutstandingAmount, PaymentStatus = pst.PaymentStatus,
           -- (63) supplier invoices: 1 = it holds one item (65029 refuses a second), 0 = it may hold several. Its own mode,
           --      or the setting when it has none (saved before script 63). 0 on orders and returns: not concerned.
           OneItemOnly = CAST(CASE WHEN dt.Code = N'PINV'
                                   THEN COALESCE(d.OneItemOnly, configuration.fn_SettingBool(N'Purchase.OneItemPerInvoice')) ELSE 0 END AS BIT),
           -- (65) goods receipts: 1 = a supplier invoice posted after the switch (its goods enter with goods receipts);
           --      CanReceive / ReceiveBlockedReason = "Receive goods..." on this order or invoice (rules 14, 15);
           --      GoodsReceiptsSinceUtc = the switch ("Posted before goods receipts ({date})")
           d.UsesGoodsReceipts,
           CanReceive = CAST(CASE WHEN rcv.Reason IS NULL THEN 1 ELSE 0 END AS BIT),
           ReceiveBlockedReason = rcv.Reason,
           GoodsReceiptsSinceUtc = (SELECT TOP (1) s.SwitchedAtUtc FROM purchase.GoodsReceiptSwitch s)
    FROM purchase.PurchaseDocuments d
    OUTER APPLY purchase.fn_InvoiceSettlement(d.Id) pst
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Branches b      ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w    ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Parties sp      ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    LEFT  JOIN masterdata.Currencies bc   ON bc.IsBaseCurrency = 1 AND bc.IsActive = 1
    LEFT  JOIN purchase.PurchaseDocuments src ON src.Id = d.SourceDocumentId
    LEFT  JOIN inventory.DocumentTypes sdt ON sdt.Id = src.DocumentTypeId
    LEFT  JOIN inventory.ShortageDocuments sh ON sh.Id = d.SourceShortageId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = d.UpdatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    LEFT  JOIN security.Users xu ON xu.Id = d.CancelledBy
    LEFT  JOIN security.Users ku ON ku.Id = d.ClosedBy
    LEFT  JOIN security.Users rqu ON rqu.Id = d.ApprovalRequestedBy
    LEFT  JOIN security.Users apu ON apu.Id = d.ApprovedBy
    LEFT  JOIN security.Users rju ON rju.Id = d.RejectedBy
    OUTER APPLY (SELECT Ordered = SUM(pl.QuantityBase), Invoiced = SUM(pl.ReceivedQuantityBase)
                 FROM purchase.PurchaseDocumentLines pl WHERE pl.DocumentId = d.Id) prog
    OUTER APPLY (SELECT InDraft = SUM(x.QuantityBase)
                 FROM purchase.PurchaseDocumentLines pl
                 INNER JOIN purchase.PurchaseDocumentLines x ON x.SourceLineId = pl.Id
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId AND xd.Status = 1
                 WHERE pl.DocumentId = d.Id) drf
    OUTER APPLY (SELECT Share = SUM(a.AmountBase * CAST(x.QuantityBase AS DECIMAL(18,6)) / NULLIF(cl.QuantityBase, 0))
                 FROM purchase.PurchaseDocumentLines x
                 INNER JOIN logistics.ContainerLines cl            ON cl.Id = x.ContainerLineId
                 INNER JOIN logistics.ContainerChargeAllocations a ON a.ContainerLineId = cl.Id
                 INNER JOIN logistics.ContainerCharges ch          ON ch.Id = a.ChargeId AND ch.Status = 2 AND ch.IncludeInLandedCost = 1
                 WHERE x.DocumentId = d.Id) cch
    OUTER APPLY (SELECT Containers = CASE WHEN dt.Code = N'PINV'
                                          THEN CAST(SUM(CAST(s.InvoicedBase AS DECIMAL(19,4)) / s.PcsPerContainer) AS DECIMAL(18,2)) END
                 FROM purchase.fn_PurchaseInvoice_ItemContainers(d.Id) s) need
    -- (65) what "Receive goods..." would find: an order's lines (rule 14), an invoice's lines not in a container (rule 15)
    OUTER APPLY (SELECT ToReceive = SUM(p.ToReceiveBase), MaxOutside = SUM(p.MaxOutsideBase), InContainers = SUM(p.InContainersBase),
                        NotReceived = SUM(CASE WHEN p.OrderedBase - p.GoodsReceivedBase - p.GoodsShortBase > 0
                                               THEN p.OrderedBase - p.GoodsReceivedBase - p.GoodsShortBase ELSE 0 END),
                        InDrafts = SUM(p.InDraftReceiptsBase),
                        Room = SUM(CASE WHEN p.MaxOutsideBase > p.InDraftReceiptsBase THEN p.MaxOutsideBase - p.InDraftReceiptsBase ELSE 0 END)
                 FROM purchase.fn_PoLine_Progress(d.Id) p
                 WHERE dt.Code = N'PO') pr
    OUTER APPLY (SELECT Lines = COUNT(*), ToReceive = SUM(t.ToReceiveBase), InDrafts = SUM(t.InDraftReceiptsBase),
                        NotReceived = SUM(CASE WHEN t.InvoicedBase - t.ReceivedBase > 0 THEN t.InvoicedBase - t.ReceivedBase ELSE 0 END)
                 FROM purchase.fn_InvoiceLine_ToReceive(d.Id) t
                 WHERE dt.Code = N'PINV') ir
    -- (65) why "Receive goods..." is disabled (NULL = it is not). An order also opens it for pieces recorded short that
    --      turn up later (MaxOutsideBase: what remains outside containers, settled pieces included; the dialog proposes 0),
    --      but not for what draft goods receipts already hold (Room: MaxOutsideBase - InDraftReceiptsBase per line).
    CROSS APPLY (SELECT Reason = CAST(CASE
                     WHEN dt.Code = N'PO' THEN
                         CASE WHEN d.Status = 1 THEN N'Approve the order first: goods are received against an approved order.'
                              WHEN d.Status = 5 THEN N'This order is waiting for approval.'
                              WHEN d.Status = 3 THEN N'This order is cancelled.'
                              WHEN ISNULL(pr.ToReceive, 0) > 0 OR ISNULL(pr.Room, 0) > 0 THEN NULL
                              WHEN ISNULL(pr.InDrafts, 0) > 0
                                  THEN N'The rest of this order is on draft goods receipts: post or delete them first.'
                              WHEN ISNULL(pr.InContainers, 0) > 0 AND ISNULL(pr.NotReceived, 0) > 0
                                  THEN N'Everything still to receive travels in containers: it is received with its containers.'
                              ELSE N'Everything ordered is already received.' END
                     WHEN dt.Code = N'PINV' THEN
                         CASE WHEN d.Status = 1 THEN N'Post the invoice first: goods are received against a posted invoice, or from the order.'
                              WHEN d.Status = 3 THEN N'This invoice is cancelled.'
                              WHEN d.UsesGoodsReceipts = 0 AND d.ReceiptMode = 1
                                  THEN N'Posted before goods receipts: its stock entered when it was posted (or when its container was offloaded).'
                              -- an older "Shipped in containers" invoice whose lines are all in containers offloaded the old way
                              WHEN d.UsesGoodsReceipts = 0 AND ISNULL(ir.Lines, 0) = 0
                                   AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines x
                                                   INNER JOIN logistics.ContainerLines cl ON cl.Id = x.ContainerLineId
                                                   CROSS APPLY logistics.fn_Container_ReceivedBy(cl.ContainerId) rb
                                                   WHERE x.DocumentId = d.Id AND ISNULL(rb.ReceivedBy, N'') <> N'Offload')
                                  THEN N'Posted before goods receipts: its stock entered when it was posted (or when its container was offloaded).'
                              WHEN ISNULL(ir.Lines, 0) = 0 THEN N'This invoice''s goods travel in containers: they are received with their containers.'
                              WHEN ISNULL(ir.ToReceive, 0) > 0 THEN NULL
                              WHEN ISNULL(ir.InDrafts, 0) > 0 AND ISNULL(ir.NotReceived, 0) > 0
                                  THEN N'The rest of this invoice is on draft goods receipts: post or delete them first.'
                              ELSE N'Every piece of this invoice is already received.' END
                     ELSE N'A purchase return takes goods out: it is not received.' END AS NVARCHAR(400))) rcv
    WHERE d.Id = @Id;

    SELECT l.Id, l.DocumentId, l.LineNumber, l.ItemId, i.ItemCode, i.ItemName,
           l.ItemUnitId, ut.UnitTypeName, iu.SkuCode, iu.Barcode, l.PackingFormula,
           l.WarehouseId, w.WarehouseCode, w.WarehouseName, l.ExpiryDate,
           l.Quantity, l.QuantityBase, l.UnitPrice, l.DiscountPercent, l.LineDiscount, l.LineTotal,
           l.UnitCostBase, LandedCostBase = l.UnitCostBase, l.FobCostBase, l.AllocatedChargesBase,
           l.ReceivedQuantityBase, l.ReturnedQuantityBase, l.ShippedQuantityBase,
           AllocatedToContainersBase = CASE WHEN dt.Code = N'PO' THEN ISNULL(ct.Allocated, 0)
                                            WHEN l.ContainerLineId IS NOT NULL THEN l.QuantityBase ELSE 0 END,
           TransitBase = CASE WHEN dt.Code = N'PO' THEN ISNULL(ct.Transit, 0)
                              WHEN lct.Status IN (3, 4, 5) THEN l.QuantityBase ELSE 0 END,
           -- (65) an invoice whose goods come through goods receipts returns what was received (rule 23), as Post checks it
           RemainingBase = CASE WHEN dt.Code = N'PO' THEN l.QuantityBase - l.ReceivedQuantityBase
                                WHEN dt.Code = N'PINV' AND (d.UsesGoodsReceipts = 1 OR d.ReceiptMode = 2) THEN l.ReceivedQuantityBase - l.ReturnedQuantityBase
                                WHEN dt.Code = N'PINV' THEN l.QuantityBase - l.ReturnedQuantityBase END,
           AvailableForContainerBase = CASE WHEN dt.Code = N'PO' THEN l.QuantityBase - ISNULL(ct.Allocated, 0) - ISNULL(dir.Qty, 0) END,
           InvoicedDirectBase = CASE WHEN dt.Code = N'PO' THEN ISNULL(dir.Qty, 0) END,
           l.ContainerLineId, ContainerId = lcl.ContainerId, ContainerRef = lct.ContainerRef, ContainerNo = lct.ContainerNo,
           ContainerStatus = lct.Status,
           ContainerChargesBase = CASE WHEN l.ContainerLineId IS NOT NULL THEN ISNULL(lch.Share, 0) END,
           EstimatedLandedCostBase = CASE WHEN l.ContainerLineId IS NOT NULL
                                          THEN COALESCE(lcl.LandedCostBase,
                                                        ISNULL(l.FobCostBase, l.LineTotal / NULLIF(d.ExchangeRate, 0) / NULLIF(l.QuantityBase, 0))
                                                        + ISNULL(lch.Share, 0) / NULLIF(l.QuantityBase, 0)) END,
           InDraftDocumentsBase = ISNULL(dr.Qty, 0),
           AvailableToInvoiceBase = CASE WHEN dt.Code = N'PO' THEN l.QuantityBase - l.ReceivedQuantityBase - ISNULL(dr.Qty, 0) END,
           l.ImportRowNumber, l.Notes, l.SourceLineId,
           OnHandBase  = inventory.fn_StockOnHand(l.ItemId, l.WarehouseId),
           ItemLastCost = i.LastCost, ItemAverageCost = i.AverageCost, ItemFobCost = i.FobCost,
           -- (65) order lines: received, settled short, in containers / draft receipts, to receive, still to come
           --      (purchase.fn_PoLine_Progress); invoice lines: to receive with "Receive goods..." (fn_InvoiceLine_ToReceive;
           --      0 on a line in a container). InvoicedDirectBase above now holds what the order line committed outside
           --      containers (fn_PoLine_CommittedOutside: the larger of invoiced, and received + on draft receipts); its parts:
           GoodsReceivedBase   = pp.GoodsReceivedBase,
           GoodsShortBase      = pp.GoodsShortBase,
           InContainersBase    = pp.InContainersBase,
           InDraftReceiptsBase = COALESCE(pp.InDraftReceiptsBase, ip.InDraftReceiptsBase, CASE WHEN dt.Code = N'PINV' THEN 0 END),
           ToReceiveBase       = COALESCE(pp.ToReceiveBase, ip.ToReceiveBase, CASE WHEN dt.Code = N'PINV' THEN 0 END),
           MaxOutsideBase      = pp.MaxOutsideBase,
           OutstandingBase     = pp.OutstandingBase,
           InvoicedOutsideBase        = CASE WHEN dt.Code = N'PO' THEN ISNULL(dir.InvoicedOutsideBase, 0) END,
           ReceivedOutsideBase        = CASE WHEN dt.Code = N'PO' THEN ISNULL(dir.ReceivedOutsideBase, 0) END,
           InDraftReceiptsOutsideBase = CASE WHEN dt.Code = N'PO' THEN ISNULL(dir.InDraftReceiptsOutsideBase, 0) END
    FROM purchase.PurchaseDocumentLines l
    INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
    INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId
    INNER JOIN inventory.Items i            ON i.Id = l.ItemId
    INNER JOIN inventory.ItemUnits iu       ON iu.Id = l.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut      ON ut.Id = iu.UnitTypeId
    INNER JOIN masterdata.Warehouses w      ON w.Id = l.WarehouseId
    OUTER APPLY (SELECT Allocated = SUM(cl.QuantityBase),
                        Transit   = SUM(CASE WHEN c.Status IN (3, 4, 5) THEN cl.QuantityBase - ISNULL(cl.ReceivedQuantityBase, 0) ELSE 0 END)
                 FROM logistics.ContainerLines cl
                 INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                 WHERE cl.PoLineId = l.Id AND c.Status <> 8) ct
    -- (65) committed outside containers: the larger of invoiced, and received + on draft goods receipts (was: invoiced)
    OUTER APPLY (SELECT co.Qty, co.InvoicedOutsideBase, co.ReceivedOutsideBase, co.InDraftReceiptsOutsideBase
                 FROM purchase.fn_PoLine_CommittedOutside(l.Id, NULL) co
                 WHERE dt.Code = N'PO') dir
    LEFT  JOIN purchase.fn_PoLine_Progress(@Id) pp      ON pp.PoLineId = l.Id
    LEFT  JOIN purchase.fn_InvoiceLine_ToReceive(@Id) ip ON ip.InvoiceLineId = l.Id
    LEFT  JOIN logistics.ContainerLines lcl ON lcl.Id = l.ContainerLineId
    LEFT  JOIN logistics.Containers lct     ON lct.Id = lcl.ContainerId
    OUTER APPLY (SELECT Charges = SUM(a.AmountBase)
                 FROM logistics.ContainerChargeAllocations a
                 INNER JOIN logistics.ContainerCharges ch ON ch.Id = a.ChargeId AND ch.Status = 2 AND ch.IncludeInLandedCost = 1
                 WHERE a.ContainerLineId = l.ContainerLineId) lcc
    OUTER APPLY (SELECT Share = lcc.Charges * CAST(l.QuantityBase AS DECIMAL(18,6)) / NULLIF(lcl.QuantityBase, 0)) lch
    OUTER APPLY (SELECT Qty = SUM(x.QuantityBase) FROM purchase.PurchaseDocumentLines x
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
                 WHERE x.SourceLineId = l.Id AND xd.Status = 1) dr
    WHERE l.DocumentId = @Id
    ORDER BY l.LineNumber;

    SELECT f.Id, f.DocumentId, f.FileName, f.ContentType, f.SizeBytes, f.CreatedAtUtc, u.FullName AS CreatedByName
    FROM purchase.PurchaseDocumentFiles f
    LEFT JOIN security.Users u ON u.Id = f.CreatedBy
    WHERE f.DocumentId = @Id
    ORDER BY f.CreatedAtUtc DESC;

    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM purchase.PurchaseDocumentAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.DocumentId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;

    -- (77) + InvoicingStatus of a linked purchase order (0 / 1 / 2: Saved, Partially posted, Posted); NULL otherwise
    SELECT Relation = N'Source', x.Id, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, x.DocumentNumber, x.DocumentDate, x.Status, x.TotalAmount, c.CurrencyCode,
           inv.InvoicingStatus
    FROM purchase.PurchaseDocuments d
    INNER JOIN purchase.PurchaseDocuments x ON x.Id = d.SourceDocumentId
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = x.DocumentTypeId
    INNER JOIN masterdata.Currencies c ON c.Id = x.CurrencyId
    OUTER APPLY purchase.fn_PurchaseOrder_Invoicing(x.Id) inv
    WHERE d.Id = @Id
    UNION ALL
    SELECT N'Child', x.Id, dt.Code, dt.Name, x.DocumentNumber, x.DocumentDate, x.Status, x.TotalAmount, c.CurrencyCode,
           inv.InvoicingStatus
    FROM purchase.PurchaseDocuments x
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = x.DocumentTypeId
    INNER JOIN masterdata.Currencies c ON c.Id = x.CurrencyId
    OUTER APPLY purchase.fn_PurchaseOrder_Invoicing(x.Id) inv
    WHERE x.SourceDocumentId = @Id
    ORDER BY Relation DESC, DocumentDate, Id;

    -- 6: charges of the invoice (kind PINV), of its landed cost adjustments (kind LCA) and, for an import, the charges of
    --    its containers (kind CNT, read-only: DocumentId = container, AdjustmentStatus = charge status) with ShareBase =
    --    the part that falls on this invoice's lines.
    SELECT c.Id, c.DocumentKind, c.DocumentId, SourceNumber = CASE WHEN c.DocumentKind = N'LCA' THEN lca.DocumentNumber ELSE d.DocumentNumber END,
           c.LineNumber, c.ChargeTypeId, ct.ChargeCode, ct.ChargeName, c.Description, c.ProviderPartyId, pp.PartyName AS ProviderName, c.Reference,
           c.CurrencyId, cur.CurrencyCode, c.RateType, c.ExchangeRate, c.Amount, c.AmountBase, c.AllocationMethod, c.IncludeInLandedCost, c.IncludedInSupplierInvoice, c.Notes,
           AllocatedBase = (SELECT SUM(AmountBase) FROM purchase.PurchaseChargeAllocations x WHERE x.ChargeId = c.Id),
           AdjustmentStatus = lca.Status,
           ContainerId = CAST(NULL AS INT), ContainerRef = CAST(NULL AS NVARCHAR(30)), ChargeDate = CAST(NULL AS DATE),
           ChargeStatus = CAST(NULL AS TINYINT), ShareBase = CAST(NULL AS DECIMAL(18,2))
    FROM purchase.PurchaseCharges c
    INNER JOIN purchase.ChargeTypes ct ON ct.Id = c.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = c.CurrencyId
    LEFT  JOIN masterdata.Parties pp ON pp.Id = c.ProviderPartyId
    LEFT  JOIN purchase.PurchaseDocuments d ON d.Id = c.DocumentId AND c.DocumentKind = N'PINV'
    LEFT  JOIN purchase.LandedCostAdjustments lca ON lca.Id = c.DocumentId AND c.DocumentKind = N'LCA'
    WHERE (c.DocumentKind = N'PINV' AND c.DocumentId = @Id)
       OR (c.DocumentKind = N'LCA' AND lca.SourceInvoiceId = @Id)
    UNION ALL
    SELECT ch.Id, N'CNT', ch.ContainerId, cn.ContainerRef,
           CAST(ROW_NUMBER() OVER (ORDER BY cn.ContainerRef, ch.ChargeDate, ch.Id) AS INT),
           ch.ChargeTypeId, t.ChargeCode, t.ChargeName, ch.Description, ch.ProviderPartyId, pp.PartyName, ch.Reference,
           ch.CurrencyId, cur.CurrencyCode, ch.RateType, ch.ExchangeRate, ch.Amount, ch.AmountBase, ch.AllocationMethod, ch.IncludeInLandedCost,
           CAST(0 AS BIT), ch.Notes,
           ISNULL(s.Share, 0), ch.Status,
           ch.ContainerId, cn.ContainerRef, ch.ChargeDate, ch.Status, CAST(ISNULL(s.Share, 0) AS DECIMAL(18,2))
    FROM logistics.ContainerCharges ch
    INNER JOIN logistics.Containers cn   ON cn.Id = ch.ContainerId
    INNER JOIN purchase.ChargeTypes t    ON t.Id = ch.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = ch.CurrencyId
    LEFT  JOIN masterdata.Parties pp     ON pp.Id = ch.ProviderPartyId
    OUTER APPLY (SELECT Share = SUM(a.AmountBase * CAST(l.QuantityBase AS DECIMAL(18,6)) / NULLIF(cl.QuantityBase, 0))
                 FROM purchase.PurchaseDocumentLines l
                 INNER JOIN logistics.ContainerLines cl            ON cl.Id = l.ContainerLineId
                 INNER JOIN logistics.ContainerChargeAllocations a ON a.ContainerLineId = cl.Id AND a.ChargeId = ch.Id
                 WHERE l.DocumentId = @Id) s
    WHERE ch.Status IN (1, 2)
      AND EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines l
                  INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
                  WHERE l.DocumentId = @Id AND cl.ContainerId = ch.ContainerId)
    ORDER BY 2, 3, 5;

    -- 7: containers of the document: for an order the containers carrying its lines, for an invoice its containers.
    SELECT ct.Id, ct.ContainerRef, ct.ContainerNo, ct.Status, ct.DispatchDate, ct.Eta, ct.OffloadedDate,
           ct.CurrentLocation, w.WarehouseCode, w.WarehouseName,
           AllocatedBase = ISNULL(x.Allocated, 0), ReceivedBase = ISNULL(x.Received, 0), InvoicedBase = ISNULL(x.Invoiced, 0),
           ct.ContainerTypeId, ctt.TypeCode AS ContainerTypeCode, ct.PurchaseOrderId
    FROM logistics.Containers ct
    INNER JOIN masterdata.ContainerTypes ctt ON ctt.Id = ct.ContainerTypeId
    LEFT  JOIN masterdata.Warehouses w       ON w.Id = ct.WarehouseId
    CROSS APPLY (SELECT Allocated = SUM(q.Allocated), Received = SUM(q.Received), Invoiced = SUM(q.Invoiced)
                 FROM (SELECT Allocated = cl.QuantityBase, Received = ISNULL(cl.ReceivedQuantityBase, 0),
                              Invoiced = ISNULL((SELECT SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                                                 INNER JOIN purchase.PurchaseDocuments pid ON pid.Id = pil.DocumentId
                                                 WHERE pil.ContainerLineId = cl.Id AND pid.Status IN (2, 4)), 0)
                       FROM logistics.ContainerLines cl
                       WHERE cl.ContainerId = ct.Id AND cl.PurchaseOrderId = @Id
                       UNION ALL
                       SELECT l.QuantityBase, l.ReceivedQuantityBase, l.QuantityBase
                       FROM purchase.PurchaseDocumentLines l
                       INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
                       WHERE l.DocumentId = @Id AND cl.ContainerId = ct.Id) q) x
    WHERE ct.Status <> 8
      AND (EXISTS (SELECT 1 FROM logistics.ContainerLines cl WHERE cl.ContainerId = ct.Id AND cl.PurchaseOrderId = @Id)
           OR EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines l
                      INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
                      WHERE l.DocumentId = @Id AND cl.ContainerId = ct.Id))
    ORDER BY ct.ContainerRef;

    -- 8: approval requests and decisions (purchase orders).
    SELECT a.Id, a.RequestNo, a.ApproverUserId, u.FullName AS ApproverName, u.Email AS ApproverEmail,
           a.Status, a.ExpiresAtUtc, a.DecidedAtUtc, a.DecisionNote, a.Channel, a.RequestedAtUtc, ru.FullName AS RequestedByName
    FROM purchase.PurchaseOrderApprovals a
    INNER JOIN security.Users u ON u.Id = a.ApproverUserId
    LEFT  JOIN security.Users ru ON ru.Id = a.RequestedBy
    WHERE a.DocumentId = @Id
    ORDER BY a.RequestNo DESC, a.Id;

    -- 9 (65): goods receipts of the document - an order: those of its lines (from the order, its invoices, its
    --    containers); an invoice: those made from it and those whose pieces are matched to its lines. HereBase = the
    --    pieces of the receipt that concern this document (an order: on its lines; an invoice: matched to its lines,
    --    or received from it). Value = the value at receipt (fixed when posted).
    SELECT g.Id, g.DocumentNumber, g.DocumentDate, g.Status, g.SourceKind, g.IsAuto,
           g.ContainerId, ContainerRef = c.ContainerRef, g.WarehouseId, w.WarehouseCode, w.WarehouseName,
           ReceivedBase = g.TotalReceivedBase, HereBase = ISNULL(h.Pcs, 0), ValueAtReceiptBase = g.ValueAtReceiptBase,
           g.PostedAtUtc, g.CreatedAtUtc
    FROM purchase.GoodsReceipts g
    LEFT  JOIN logistics.Containers c    ON c.Id = g.ContainerId
    LEFT  JOIN masterdata.Warehouses w   ON w.Id = g.WarehouseId
    OUTER APPLY (SELECT Pcs = SUM(x.Pcs)
                 FROM (SELECT Pcs = gl.QuantityBase
                       FROM purchase.GoodsReceiptLines gl
                       WHERE gl.GoodsReceiptId = g.Id AND gl.PurchaseOrderId = @Id
                       UNION ALL
                       SELECT m.QuantityBase
                       FROM purchase.GoodsReceiptLines gl
                       INNER JOIN purchase.GoodsReceiptInvoiceMatches m ON m.GoodsReceiptLineId = gl.Id
                       INNER JOIN purchase.PurchaseDocumentLines il     ON il.Id = m.InvoiceLineId AND il.DocumentId = @Id
                       WHERE gl.GoodsReceiptId = g.Id
                       UNION ALL
                       SELECT gl.QuantityBase
                       FROM purchase.GoodsReceiptLines gl
                       INNER JOIN purchase.PurchaseDocumentLines il ON il.Id = gl.InvoiceLineId AND il.DocumentId = @Id
                       WHERE gl.GoodsReceiptId = g.Id AND g.Status = 1) x) h
    WHERE g.PurchaseOrderId = @Id OR g.PurchaseInvoiceId = @Id
       OR EXISTS (SELECT 1 FROM purchase.GoodsReceiptLines gl WHERE gl.GoodsReceiptId = g.Id AND gl.PurchaseOrderId = @Id)
       OR EXISTS (SELECT 1 FROM purchase.GoodsReceiptLines gl
                  INNER JOIN purchase.GoodsReceiptInvoiceMatches m ON m.GoodsReceiptLineId = gl.Id
                  INNER JOIN purchase.PurchaseDocumentLines il     ON il.Id = m.InvoiceLineId AND il.DocumentId = @Id
                  WHERE gl.GoodsReceiptId = g.Id)
    ORDER BY g.DocumentDate, g.Id;

    -- 10 (65): cost adjustments of received goods caused by this invoice - posted or cancelled - and by its landed
    --    cost adjustments (purchase.GoodsReceiptCostChanges; empty for an order or a return).
    SELECT cc.Id, cc.ChangedAtUtc, cc.CauseKind, cc.CauseId, cc.CauseNumber,
           cc.GoodsReceiptLineId, GoodsReceiptId = g.Id, GoodsReceiptNumber = g.DocumentNumber, gl.ItemId, i.ItemCode, i.ItemName,
           cc.ReceivedBase, cc.InStockBase, cc.FobBefore, cc.FobAfter, cc.UnitCostBefore, cc.UnitCostAfter,
           cc.AmountBase, cc.InventoryBase, cc.CogsBase
    FROM purchase.GoodsReceiptCostChanges cc
    INNER JOIN purchase.GoodsReceiptLines gl ON gl.Id = cc.GoodsReceiptLineId
    INNER JOIN purchase.GoodsReceipts g      ON g.Id = gl.GoodsReceiptId
    INNER JOIN inventory.Items i             ON i.Id = gl.ItemId
    WHERE (cc.CauseKind IN (N'PINV', N'PINVCANCEL') AND cc.CauseId = @Id)
       OR (cc.CauseKind IN (N'LCA', N'LCACANCEL')
           AND cc.CauseId IN (SELECT a.Id FROM purchase.LandedCostAdjustments a WHERE a.SourceInvoiceId = @Id))
    ORDER BY cc.ChangedAtUtc, cc.Id;
END
GO

/* ================================================================== 7. Shortage plan: its purchase orders */

-- Re-created (77) from the body of script 25: the purchase orders made from the plan carry InvoicingStatus.
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
           d.CreatedAtUtc, d.CreatedBy, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.UpdatedBy, uu.FullName AS UpdatedByName, d.RowVersion
    FROM inventory.ShortageDocuments d
    INNER JOIN masterdata.Branches b ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Parties sp ON sp.Id = d.SupplierId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = d.UpdatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    WHERE d.Id = @Id;

    SELECT l.Id, l.DocumentId, l.LineNumber, l.ItemId, i.ItemCode, i.ItemName, br.BrandName, f.FamilyName, i.IsBivac,
           l.CurrentInventoryBase, l.TransitBase, l.OutstandingOrderBase, l.StockPlusTransitBase, l.TotalExpectedStockBase,
           l.ExpectedMonthlySalesBase, l.ExpectedMonthlySalesManual, l.EffectiveMonthlySales, l.LeadTimeMonths,
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

/* ================================================================== 8. Item Definition > Purchase orders */

-- Re-created (77) from the body of script 65: + InvoicingStatus of each order (the whole order's, not only this
-- item's lines: it is the order's status). Still to come is unchanged.
CREATE OR ALTER PROCEDURE inventory.usp_Item_PurchaseOrders
    @ItemId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.Id AS DocumentId, d.DocumentNumber, d.DocumentDate, d.ExpectedDate, d.Status AS StatusCode,
           s.PartyCode AS SupplierCode, s.PartyName AS SupplierName, br.BranchName,
           c.CurrencyCode, c.DecimalPlaces,
           x.OrderedBase, x.ReceivedBase, x.InvoicedBase, x.ShortBase,                       -- (65) received = goods received
           OutstandingBase = CASE WHEN d.Status IN (2, 4) THEN x.OutstandingBase ELSE 0 END, -- (65) rule 25
           x.Amount,
           inv.InvoicingStatus                                                               -- (77) the ORDER's, every item
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId AND t.Code = N'PO'
    CROSS APPLY (SELECT OrderedBase = SUM(l.QuantityBase), ReceivedBase = SUM(l.GoodsReceivedBase),
                        InvoicedBase = SUM(l.ReceivedQuantityBase), ShortBase = SUM(l.GoodsShortBase),
                        OutstandingBase = SUM(p.OutstandingBase), Amount = SUM(l.LineTotal)
                 FROM purchase.PurchaseDocumentLines l
                 CROSS APPLY purchase.fn_PoLine_Progress(l.DocumentId) p
                 WHERE l.DocumentId = d.Id AND l.ItemId = @ItemId AND p.PoLineId = l.Id) x
    INNER JOIN masterdata.Parties s    ON s.Id = d.SupplierId
    INNER JOIN masterdata.Branches br  ON br.Id = d.BranchId
    INNER JOIN masterdata.Currencies c ON c.Id = d.CurrencyId
    OUTER APPLY purchase.fn_PurchaseOrder_Invoicing(d.Id) inv
    WHERE x.OrderedBase IS NOT NULL
    ORDER BY d.DocumentDate DESC, d.Id DESC;
END
GO

/* ================================================================== 9. Check */

-- No purchase order is closed any more. Expected: none.
SELECT d.Id, d.DocumentNumber, d.CloseReason
FROM purchase.PurchaseDocuments d
INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId AND dt.Code = N'PO'
WHERE d.Status = 4;

-- Purchase orders by what they show.
SELECT Shown = CASE d.Status WHEN 1 THEN N'Draft' WHEN 5 THEN N'Waiting for approval' WHEN 3 THEN N'Cancelled'
                             WHEN 2 THEN CASE inv.InvoicingStatus WHEN 0 THEN N'Saved' WHEN 1 THEN N'Partially posted' ELSE N'Posted' END
                             ELSE N'Closed (unexpected)' END,
       Orders = COUNT(*)
FROM purchase.PurchaseDocuments d
INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId AND dt.Code = N'PO'
CROSS APPLY purchase.fn_PurchaseOrder_Invoicing(d.Id) inv
GROUP BY CASE d.Status WHEN 1 THEN N'Draft' WHEN 5 THEN N'Waiting for approval' WHEN 3 THEN N'Cancelled'
                       WHEN 2 THEN CASE inv.InvoicingStatus WHEN 0 THEN N'Saved' WHEN 1 THEN N'Partially posted' ELSE N'Posted' END
                       ELSE N'Closed (unexpected)' END
ORDER BY Shown;

-- Order lines whose pieces a close by hand gave up (section 2): settled short, not received, not loaded again.
SELECT Lines = COUNT(*), GivenUpPcs = ISNULL(SUM(ClosedShortBase), 0)
FROM purchase.PurchaseDocumentLines WHERE ClosedShortBase > 0;

PRINT 'Script 77 applied: purchase orders show Saved, Partially posted or Posted from their posted invoices; Closed is gone.';
GO
