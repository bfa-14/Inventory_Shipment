/* ================================================================== 3. Lists that grew with the containers (9829) */

-- Re-created (78) from the body of script 65: the audit row of the invoice names at most 20 containers (9829 above
-- about 190 before). Nothing else changes.
CREATE   PROCEDURE purchase.usp_PurchaseInvoice_LinkContainers
    @InvoiceId  INT,
    @RowVersion BINARY(8) = NULL,
    @Links      logistics.tvp_ContainerLineQty READONLY,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @TypeCode NVARCHAR(20), @Status TINYINT, @OrderId INT, @Mode TINYINT, @Number NVARCHAR(30), @UsesGrn BIT;
        SELECT @TypeCode = dt.Code, @Status = d.Status, @OrderId = d.SourceDocumentId, @Mode = d.ReceiptMode,
               @Number = ISNULL(d.DocumentNumber, N'draft #' + CAST(d.Id AS NVARCHAR(10))), @UsesGrn = d.UsesGoodsReceipts
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @InvoiceId;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;

        -- (65) RULE 28: AN INVOICE LINE A GOODS RECEIPT REFERS TO STAYS OUTSIDE CONTAINERS (65028, as Unlink answers it).
        -- Linking moves or splits the invoice's lines outside containers: none of them may be the line a draft or posted
        -- receipt was made from (Receive goods... on the invoice), or a line a posted receipt's pieces are matched to, or
        -- carry pieces received or returned. Rule 6 of purchase.fn_PurchaseInvoice_ContainerState fails for the same
        -- lines - the card's reason, and the 65030 of Add container and Auto-plan from the invoice - so this is checked
        -- before usp_PurchaseInvoice_CheckContainers raises it: a Link refused for them names the line and its receipt
        -- (65028). The invoice's rules 1-5 still come first, with their 65030. Document-wide, as rule 6 is: a receipt on
        -- any line outside containers stops the link (a posted one is named first, as the card does).
        DECLARE @Msg NVARCHAR(400), @Rule TINYINT;
        SELECT @Rule = s.FailedRule FROM purchase.fn_PurchaseInvoice_ContainerState(@InvoiceId) s;
        IF @Rule IS NULL OR @Rule >= 6
        BEGIN
            SELECT TOP (1) @Msg = N'Line ' + CAST(pil.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                                  + CASE WHEN g.Status = 2 THEN N'goods receipt ' + g.DocumentNumber ELSE N'a draft goods receipt' END
                                  + N' refers to this invoice line: delete or cancel it first.'
            FROM purchase.PurchaseDocumentLines pil
            INNER JOIN inventory.Items i ON i.Id = pil.ItemId
            CROSS APPLY (SELECT TOP (1) r.Status, r.DocumentNumber
                         FROM (SELECT gr.Id, gr.Status, gr.DocumentNumber          -- a receipt made from the line, draft or posted
                               FROM purchase.GoodsReceiptLines gl
                               INNER JOIN purchase.GoodsReceipts gr ON gr.Id = gl.GoodsReceiptId
                               WHERE gl.InvoiceLineId = pil.Id AND gr.Status < 3
                               UNION ALL
                               SELECT gr.Id, gr.Status, gr.DocumentNumber          -- a posted receipt whose pieces are matched to it
                               FROM purchase.GoodsReceiptInvoiceMatches m
                               INNER JOIN purchase.GoodsReceiptLines gl ON gl.Id = m.GoodsReceiptLineId
                               INNER JOIN purchase.GoodsReceipts gr     ON gr.Id = gl.GoodsReceiptId
                               WHERE m.InvoiceLineId = pil.Id AND gr.Status = 2) r
                         ORDER BY r.Status DESC, r.Id) g
            WHERE pil.DocumentId = @InvoiceId AND pil.ContainerLineId IS NULL
            ORDER BY CASE WHEN g.Status = 2 THEN 0 ELSE 1 END, pil.LineNumber;
            IF @Msg IS NOT NULL THROW 65028, @Msg, 1;

            IF EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines
                       WHERE DocumentId = @InvoiceId AND ContainerLineId IS NULL AND (ReceivedQuantityBase > 0 OR ReturnedQuantityBase > 0))
                THROW 65028, 'Goods of this invoice outside containers were already received or returned: it can no longer be linked.', 1;
        END

        -- (51) the invoice's rules 1-6: the same sentences as the state of the page
        EXEC purchase.usp_PurchaseInvoice_CheckContainers @InvoiceId = @InvoiceId, @Action = N'Link';
        IF @TypeCode <> N'PINV' OR @OrderId IS NULL
            THROW 65028, 'Only a purchase invoice created from a purchase order can be linked to containers.', 1;
        IF @Status NOT IN (1, 2) THROW 65010, 'A cancelled invoice cannot be linked to containers.', 1;
        IF @Status = 2 AND @Mode <> 2 AND @UsesGrn = 1      -- (65) posted after the switch: its goods come with goods receipts
        BEGIN
            SET @Msg = N'This invoice was posted without "Shipped in containers": its goods are received with Receive goods' + NCHAR(8230) + N', not with containers.';
            THROW 65028, @Msg, 1;
        END
        IF @Status = 2 AND @Mode <> 2
            THROW 65028, 'This invoice was received when it was posted: it cannot be linked to containers.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @InvoiceId AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF NOT EXISTS (SELECT 1 FROM @Links) THROW 65000, 'Choose at least one container line to link.', 1;
        IF EXISTS (SELECT 1 FROM purchase.PurchaseCharges WHERE DocumentKind = N'PINV' AND DocumentId = @InvoiceId)
            THROW 65020, 'This invoice has its own charges. Remove them: the charges of an import are entered on its containers.', 1;
        IF EXISTS (SELECT 1 FROM purchase.LandedCostAdjustments WHERE SourceInvoiceId = @InvoiceId AND Status <> 3)
            THROW 65028, 'This invoice has a landed cost adjustment: cancel or delete it before linking the invoice to containers.', 1;
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments r WHERE r.SourceDocumentId = @InvoiceId AND r.Status <> 3)
            THROW 65028, 'This invoice has purchase returns: it can no longer be linked to containers.', 1;

        -- the containers: still Draft or Confirmed
        SELECT TOP (1) @Msg = CASE WHEN c.Status = 8 THEN N'Container ' + c.ContainerRef + N' is cancelled.'
                                   ELSE N'Container ' + c.ContainerRef + N' has started moving: it can no longer be linked.' END
        FROM @Links k
        INNER JOIN logistics.ContainerLines cl ON cl.Id = k.ContainerLineId
        INNER JOIN logistics.Containers c      ON c.Id = cl.ContainerId
        WHERE c.Status NOT IN (1, 2)
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 65027, @Msg, 1;

        -- the lines: of this order, a quantity, within what is loaded and not yet invoiced
        SELECT TOP (1) @Msg =
            CASE WHEN cl.Id IS NULL THEN N'A container line to link no longer exists.'
                 WHEN cl.PurchaseOrderId <> @OrderId THEN N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10))
                      + N' belongs to another purchase order.'
                 WHEN k.QuantityBase <= 0 THEN N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10))
                      + N': the quantity must be greater than zero.'
                 ELSE N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                      + CAST(k.QuantityBase AS NVARCHAR(20)) + N' to link but only ' + CAST(cl.QuantityBase - ISNULL(q.Qty, 0) AS NVARCHAR(20))
                      + N' are loaded and not yet invoiced.' END
        FROM @Links k
        LEFT JOIN logistics.ContainerLines cl ON cl.Id = k.ContainerLineId
        LEFT JOIN logistics.Containers c      ON c.Id = cl.ContainerId
        LEFT JOIN inventory.Items i           ON i.Id = cl.ItemId
        OUTER APPLY (SELECT Qty = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                     INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                     WHERE pil.ContainerLineId = cl.Id AND pd.Status <> 3) q
        WHERE cl.Id IS NULL OR cl.PurchaseOrderId <> @OrderId OR k.QuantityBase <= 0
           OR k.QuantityBase > cl.QuantityBase - ISNULL(q.Qty, 0)
        ORDER BY c.ContainerRef, cl.LineNumber;
        IF @Msg IS NOT NULL THROW 65019, @Msg, 1;

        -- the invoice: within its pieces of that order line outside containers
        SELECT TOP (1) @Msg = i.ItemCode + N': ' + CAST(t.Qty AS NVARCHAR(20)) + N' pieces to link but only '
                              + CAST(ISNULL(u.UnlinkedBase, 0) AS NVARCHAR(20)) + N' of this invoice (order line '
                              + CAST(pol.LineNumber AS NVARCHAR(10)) + N') are not in a container yet.'
        FROM (SELECT cl.PoLineId, Qty = SUM(k.QuantityBase) FROM @Links k
              INNER JOIN logistics.ContainerLines cl ON cl.Id = k.ContainerLineId GROUP BY cl.PoLineId) t
        INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = t.PoLineId
        INNER JOIN inventory.Items i                  ON i.Id = pol.ItemId
        LEFT  JOIN purchase.fn_PurchaseInvoice_Unlinked(@InvoiceId) u ON u.PoLineId = t.PoLineId
        WHERE t.Qty > ISNULL(u.UnlinkedBase, 0)
        ORDER BY pol.LineNumber;
        IF @Msg IS NOT NULL THROW 65019, @Msg, 1;

        DECLARE @OldTotal DECIMAL(18,2) = (SELECT ISNULL(SUM(LineTotal), 0) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId);
        DECLARE @NextNo INT = (SELECT ISNULL(MAX(LineNumber), 0) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId);
        DECLARE @Cl INT, @PoLineId INT, @Need INT, @LineId INT, @Have INT, @Pf INT, @ItemId INT, @BaseUnit INT, @LastLine INT;

        DECLARE links CURSOR LOCAL STATIC READ_ONLY FORWARD_ONLY FOR
            SELECT k.ContainerLineId, cl.PoLineId, k.QuantityBase
            FROM @Links k
            INNER JOIN logistics.ContainerLines cl ON cl.Id = k.ContainerLineId
            INNER JOIN logistics.Containers c      ON c.Id = cl.ContainerId
            ORDER BY c.ContainerRef, cl.LineNumber;
        OPEN links;
        FETCH NEXT FROM links INTO @Cl, @PoLineId, @Need;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            WHILE @Need > 0
            BEGIN
                SET @LineId = NULL;
                SELECT TOP (1) @LineId = Id, @Have = QuantityBase, @Pf = PackingFormula, @ItemId = ItemId
                FROM purchase.PurchaseDocumentLines
                WHERE DocumentId = @InvoiceId AND ContainerLineId IS NULL AND SourceLineId = @PoLineId AND QuantityBase > 0
                ORDER BY LineNumber;
                IF @LineId IS NULL THROW 65019, 'The invoice has no more pieces of that order line outside containers.', 1;

                IF @Have <= @Need
                BEGIN
                    -- the whole line goes into the container
                    UPDATE purchase.PurchaseDocumentLines SET ContainerLineId = @Cl WHERE Id = @LineId;
                    SET @Need -= @Have;
                    SET @LastLine = @LineId;
                END
                ELSE
                BEGIN
                    SET @BaseUnit = (SELECT TOP (1) Id FROM inventory.ItemUnits WHERE ItemId = @ItemId AND IsBaseUnit = 1 ORDER BY Id);
                    IF @BaseUnit IS NULL AND (@Need % @Pf <> 0 OR (@Have - @Need) % @Pf <> 0)
                        THROW 65028, 'The item of a line to split has no base unit.', 1;

                    -- the linked part: a new line
                    SET @NextNo += 1;
                    INSERT INTO purchase.PurchaseDocumentLines (DocumentId, LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, PackingFormula,
                                                                UnitPrice, DiscountPercent, UnitCostBase, ReceivedQuantityBase, ReturnedQuantityBase,
                                                                ImportRowNumber, Notes, SourceLineId, ShippedQuantityBase, FobCostBase, AllocatedChargesBase,
                                                                ContainerLineId)
                    SELECT @InvoiceId, @NextNo, l.ItemId,
                           CASE WHEN @Need % l.PackingFormula = 0 THEN l.ItemUnitId ELSE @BaseUnit END,
                           l.WarehouseId, l.ExpiryDate,
                           CASE WHEN @Need % l.PackingFormula = 0 THEN @Need / l.PackingFormula ELSE @Need END,
                           CASE WHEN @Need % l.PackingFormula = 0 THEN l.PackingFormula ELSE 1 END,
                           CASE WHEN @Need % l.PackingFormula = 0 THEN l.UnitPrice ELSE ROUND(l.UnitPrice / l.PackingFormula, 4) END,
                           l.DiscountPercent, l.UnitCostBase, 0, 0, l.ImportRowNumber, l.Notes, l.SourceLineId, 0, l.FobCostBase, 0, @Cl
                    FROM purchase.PurchaseDocumentLines l
                    WHERE l.Id = @LineId;

                    -- the rest stays where it was, unlinked (it keeps its id: what refers to the line still finds it)
                    UPDATE purchase.PurchaseDocumentLines
                    SET ItemUnitId     = CASE WHEN (@Have - @Need) % PackingFormula = 0 THEN ItemUnitId ELSE @BaseUnit END,
                        Quantity       = CASE WHEN (@Have - @Need) % PackingFormula = 0 THEN (@Have - @Need) / PackingFormula ELSE @Have - @Need END,
                        UnitPrice      = CASE WHEN (@Have - @Need) % PackingFormula = 0 THEN UnitPrice ELSE ROUND(UnitPrice / PackingFormula, 4) END,
                        PackingFormula = CASE WHEN (@Have - @Need) % PackingFormula = 0 THEN PackingFormula ELSE 1 END
                    WHERE Id = @LineId;

                    SET @Need = 0;
                    SET @LastLine = @LineId;
                END
            END
            FETCH NEXT FROM links INTO @Cl, @PoLineId, @Need;
        END
        CLOSE links;
        DEALLOCATE links;

        -- the lines of every container first, by container, then what is not in a container yet
        UPDATE l SET LineNumber = x.Seq
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN (SELECT pl.Id, Seq = ROW_NUMBER() OVER (ORDER BY CASE WHEN pl.ContainerLineId IS NULL THEN 1 ELSE 0 END,
                                                                    c.ContainerRef, cl.LineNumber, pl.LineNumber, pl.Id)
                    FROM purchase.PurchaseDocumentLines pl
                    LEFT JOIN logistics.ContainerLines cl ON cl.Id = pl.ContainerLineId
                    LEFT JOIN logistics.Containers c      ON c.Id = cl.ContainerId
                    WHERE pl.DocumentId = @InvoiceId) x ON x.Id = l.Id
        WHERE l.LineNumber <> x.Seq;

        -- the document total does not change: a rounding difference goes on the last line split
        DECLARE @Diff DECIMAL(18,2) = @OldTotal - (SELECT ISNULL(SUM(LineTotal), 0) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId);
        IF @Diff <> 0 AND @LastLine IS NOT NULL
            UPDATE purchase.PurchaseDocumentLines
            SET UnitPrice = ROUND(UnitPrice + @Diff / NULLIF(Quantity * (1 - DiscountPercent / 100.0), 0), 4)
            WHERE Id = @LastLine;

        UPDATE d
        SET ReceiptMode = 2,
            TotalItems = x.Items, TotalQuantity = x.Qty, Subtotal = x.Sub, TotalAmount = x.Amt, TotalDiscount = x.Sub - x.Amt,
            TotalAmountBase = ROUND(x.Amt / d.ExchangeRate, 2), TotalLandedCostBase = ROUND(x.Amt / d.ExchangeRate, 2) + d.TotalChargesBase,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        FROM purchase.PurchaseDocuments d
        CROSS APPLY (SELECT COUNT(*) AS Items, ISNULL(SUM(QuantityBase), 0) AS Qty,
                            ISNULL(SUM(CONVERT(DECIMAL(18,2), Quantity * UnitPrice)), 0) AS Sub, ISNULL(SUM(LineTotal), 0) AS Amt
                     FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId) x
        WHERE d.Id = @InvoiceId;

        -- the value basis of the container charges follows the invoice, and both sides keep the history
        DECLARE @Cid INT, @Ref NVARCHAR(30), @Qty INT;
        DECLARE cts CURSOR LOCAL STATIC READ_ONLY FORWARD_ONLY FOR
            SELECT cl.ContainerId, c.ContainerRef, SUM(k.QuantityBase)
            FROM @Links k
            INNER JOIN logistics.ContainerLines cl ON cl.Id = k.ContainerLineId
            INNER JOIN logistics.Containers c      ON c.Id = cl.ContainerId
            GROUP BY cl.ContainerId, c.ContainerRef
            ORDER BY c.ContainerRef;
        OPEN cts;
        FETCH NEXT FROM cts INTO @Cid, @Ref, @Qty;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC logistics.usp_Container_ReallocateCharges @Cid, 1, 1;
            INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
            VALUES (@Cid, N'Updated', N'Linked to purchase invoice ' + @Number + N': ' + CAST(@Qty AS NVARCHAR(20)) + N' pieces', @UserId);
            FETCH NEXT FROM cts INTO @Cid, @Ref, @Qty;
        END
        CLOSE cts;
        DEALLOCATE cts;

        -- (78) THE AUDIT NAMES AT MOST 20 CONTAINERS, THEN "and N more"; aggregated as NVARCHAR(MAX). Over NVARCHAR(30)
        -- refs STRING_AGG returned NVARCHAR(4000) and failed (9829) from about 190 containers - the LEFT came too late -
        -- rolling back the whole link (Link containers, Add container and Auto-plan from the invoice). The text is cut
        -- to the 500 characters of PurchaseDocumentAudit.Details (the old LEFT(..., 1000) failed with 2628 once 20 long
        -- refs and quantities passed 500), keeping its "and N more"; the refs in number order (KTG-2026-9999 before
        -- KTG-2026-10000).
        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        SELECT @InvoiceId, N'Updated', LEFT(a.Head + a.Names, 500 - LEN(a.Tail)) + a.Tail, @UserId
        FROM (SELECT Head  = CASE WHEN MAX(x.N) <= 20 THEN N'Linked to containers '
                                  ELSE N'Linked to ' + CAST(MAX(x.N) AS NVARCHAR(10)) + N' containers: ' END,
                     Names = STRING_AGG(CASE WHEN x.Rn <= 20 THEN CAST(x.Ref AS NVARCHAR(MAX)) + N' (' + CAST(x.Qty AS NVARCHAR(20)) + N')' END, N', ')
                               WITHIN GROUP (ORDER BY LEN(x.Ref), x.Ref),
                     Tail  = CASE WHEN MAX(x.N) > 20 THEN N' and ' + CAST(MAX(x.N) - 20 AS NVARCHAR(10)) + N' more' ELSE N'' END
        FROM (SELECT g.Ref, g.Qty, Rn = ROW_NUMBER() OVER (ORDER BY LEN(g.Ref), g.Ref), N = COUNT(*) OVER ()
              FROM (SELECT Ref = c.ContainerRef, Qty = SUM(k.QuantityBase)
                    FROM @Links k
                    INNER JOIN logistics.ContainerLines cl ON cl.Id = k.ContainerLineId
                    INNER JOIN logistics.Containers c      ON c.Id = cl.ContainerId
                    GROUP BY c.ContainerRef) g) x) a;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    EXEC purchase.usp_PurchaseInvoice_ContainerSummary @InvoiceId;
END

GO

