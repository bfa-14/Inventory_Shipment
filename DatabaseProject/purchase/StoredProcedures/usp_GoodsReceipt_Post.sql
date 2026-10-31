/* ================================================================== 6. Posting a goods receipt */

-- Re-created (79) from the body of script 77: step 3 gives a line of an order-less invoice that does not change item
-- costs a manual cost; step 6 lets a line without an order change the last cost only once matched to an invoice that
-- does. The cost at receipt is the target cost (section 3): pieces matched to such an invoice enter at the order price.
CREATE   PROCEDURE purchase.usp_GoodsReceipt_Post
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
            -- (79) + a line of an order-less invoice that does not change item costs: it has no order price, and
            --      its invoice's price is not its cost - the typed cost, else the item's; an item with no cost yet takes
            --      the invoice's price once, so goods never enter at nothing
            ManualUnitCostBase = CASE WHEN gl.PoLineId IS NULL AND gl.InvoiceLineId IS NULL
                                      THEN COALESCE(gl.ManualUnitCostBase, i.LastCost, i.AverageCost)
                                      WHEN gl.PoLineId IS NULL AND inv.AffectsCost = 0
                                      THEN COALESCE(gl.ManualUnitCostBase, NULLIF(i.LastCost, 0), NULLIF(i.AverageCost, 0), il.UnitCostBase)
                                      ELSE gl.ManualUnitCostBase END,
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
                     -- (79) a line without an order changes the last cost only once matched to an invoice that
                     --      changes item costs (as usp_Item_RebuildCosts)
                     UpdateLast = CAST(CASE WHEN gl.PoLineId IS NULL
                                                 AND NOT EXISTS (SELECT 1 FROM purchase.GoodsReceiptInvoiceMatches mx
                                                                 INNER JOIN purchase.PurchaseDocumentLines px ON px.Id = mx.InvoiceLineId
                                                                 INNER JOIN purchase.PurchaseDocuments pdx    ON pdx.Id = px.DocumentId
                                                                 WHERE mx.GoodsReceiptLineId = gl.Id AND pdx.AffectsCost = 1)
                                            THEN 0 ELSE 1 END AS BIT),
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

