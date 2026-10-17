SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 79: CONFIGURATION - WHAT A DOCUMENT TYPE DOES (item cost, on-hand, goods receipts on Delivery)

   The owner's words: "In the Document Types page allow the invoice to affect the cost or not ... make the effect on
   cost and on-hand configurable in the interface, but keep the business we did in the last work for goods receipts",
   and "goods receipts must be created automatically (or manually) when the movement reaches the warehouse -
   configurable in the Document Types page".

   Three switches on inventory.DocumentTypes, edited in Configuration > Document Types. Their defaults are what the
   application did until now, so nothing changes until someone turns one:
     AffectsItemCost      (1)  PINV only. On: the invoice's price and its own charges become the cost of the goods
                               received against it (scripts 64-65, the cost true-up). Off: the received goods keep the
                               order price (plus their container's charges); the invoice is still payable, still counts
                               as invoicing the order, still caps returns and closes containers.
     AffectsOnHand        (0)  PINV only. Off: the invoice moves no stock (goods come with goods receipts). On: posting
                               the invoice ALSO RECEIVES its goods, with a goods receipt created and posted at once -
                               the "Receive the goods now" of the post confirmation, made the type's rule, for every way
                               an invoice is posted (its page, Post selected, an import that posts). Goods receipts stay
                               the only way stock enters: nothing is counted twice, and lines travelling in containers
                               (a "Shipped in containers" invoice) are left to their containers' receipts.
     AutoCreateOnDelivery (1)  GRN only. On: completing a Delivery-stage movement drafts a goods receipt per container
                               (script 64). Off: no draft is made; goods receipts are made by hand with Receive goods...
                               on each container (the "Delivered, not received" filter lists them).

   A supplier invoice CAPTURES the first two WHEN IT IS POSTED (purchase.PurchaseDocuments.AffectsCost /
   ReceiveOnPost, like OneItemOnly of script 63): changing the type later never re-prices or re-receives an invoice
   already posted. A draft follows the type as it is when it is posted; readers of a draft use the type's flag. Every
   document that exists gets AffectsCost 1 and ReceiveOnPost 0: today's behaviour.

   AFFECTS ITEM COST = 0, the one rule in one place: purchase.fn_GoodsReceiptLine_TargetCost prices the pieces matched
   to such an invoice as if they were unmatched (the order price; a container line keeps its container's charges).
   Everything that prices received goods reads it (goods receipt posting, every true-up, the item's last and FOB
   cost), so the rule flows through. The matching itself (usp_GoodsReceipt_Rematch) is unchanged - the invoiced and
   received counters, the return caps, container Close and payments need it - only its CostSource says where the cost
   really comes from. The true-up calls stay: cancelling a non-cost invoice can hand its pieces to a cost-affecting
   invoice of the same order line. Around it:
     - a receipt line made from an order-less non-cost invoice takes a manual cost: typed, else the item's last cost,
       else its average; an item with no cost at all takes the invoice's price once, so goods never enter at nothing.
       Such a line, like a manual one, sets the item's last cost only once matched to a cost-affecting invoice;
     - a purchase return from such an invoice takes its goods out at the current cost of the receipt lines matched to
       the invoice line (what they are in stock at), not at the invoice's landed cost; the supplier credit stays the
       invoice price;
     - a landed cost adjustment on it is refused (67013): it would change no cost;
     - the post confirmation's estimate and the invoice's "Cost of received goods" say the goods keep their cost.

   Procedures re-created from their current bodies: inventory.usp_DocumentType_List (66), inventory.usp_DocumentType_Update
   (22), purchase.fn_GoodsReceiptLine_TargetCost (64), purchase.fn_GoodsReceiptLine_Cost (64),
   purchase.usp_GoodsReceipt_Rematch (64), inventory.usp_Item_RebuildCosts (65), purchase.usp_GoodsReceipt_Post (77),
   purchase.usp_PurchaseDocument_Save (65), purchase.usp_PurchaseDocument_Post (77), purchase.usp_PurchaseDocument_Get
   (77), purchase.usp_PurchaseInvoice_ReceiptCostPreview (78), purchase.usp_LandedCostAdjustment_Save (65),
   purchase.usp_LandedCostAdjustment_Post (65), purchase.usp_GoodsReceipt_CreateForMovement (72),
   logistics.usp_Movement_Get (72).
   Unchanged on purpose: usp_GoodsReceipt_TrueUpCost, usp_PurchaseDocument_Cancel, usp_GoodsReceipt_Cancel,
   usp_GoodsReceipt_CreateForContainer (Receive goods... on a container), usp_Container_Search ("Delivered, not
   received"), usp_Movement_SetStatus (cancelling a Delivery still deletes the drafts it made, when there are some).
   New error: 67013 a landed cost adjustment on an invoice that does not change item costs.

   Requires scripts 63, 64, 65, 66, 77 and 78 (Schema.sql runs them first). Idempotent, additive: re-applied at every
   API start-up, and builds a brand-new empty database (the columns are added before any procedure reads them).
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'purchase.usp_GoodsReceipt_Rematch', N'P') IS NULL                     -- 64
   OR OBJECT_ID(N'purchase.GoodsReceiptSwitch', N'U') IS NULL                          -- 65
   OR COL_LENGTH(N'inventory.DocumentTypes', N'BivacItemsOnly') IS NULL                -- 66
   OR COL_LENGTH(N'purchase.PurchaseDocuments', N'OneItemOnly') IS NULL                -- 63
   OR OBJECT_ID(N'purchase.fn_PurchaseOrder_Invoicing') IS NULL                        -- 77
   OR OBJECT_ID(N'logistics.usp_Container_OrderDefaults', N'P') IS NULL                -- 78
    THROW 62000, 'Script 79 requires scripts 63, 64, 65, 66, 77 and 78: apply them first.', 1;
GO

/* ================================================================== 1. The switches, and what an invoice captured */

-- Before any procedure below reads them. The defaults are today's behaviour for every type and every document.
IF COL_LENGTH(N'inventory.DocumentTypes', N'AffectsItemCost') IS NULL
BEGIN
    ALTER TABLE inventory.DocumentTypes ADD
        AffectsItemCost BIT NOT NULL CONSTRAINT DF_DocumentTypes_AffectsItemCost DEFAULT (1);        -- PINV: its price is the cost of the goods received
    PRINT 'DocumentTypes: added AffectsItemCost';
END
GO

IF COL_LENGTH(N'inventory.DocumentTypes', N'AffectsOnHand') IS NULL
BEGIN
    ALTER TABLE inventory.DocumentTypes ADD
        AffectsOnHand BIT NOT NULL CONSTRAINT DF_DocumentTypes_AffectsOnHand DEFAULT (0);            -- PINV: posting it receives its goods (a goods receipt)
    PRINT 'DocumentTypes: added AffectsOnHand';
END
GO

IF COL_LENGTH(N'inventory.DocumentTypes', N'AutoCreateOnDelivery') IS NULL
BEGIN
    ALTER TABLE inventory.DocumentTypes ADD
        AutoCreateOnDelivery BIT NOT NULL CONSTRAINT DF_DocumentTypes_AutoCreateOnDelivery DEFAULT (1);  -- GRN: a completed Delivery drafts them
    PRINT 'DocumentTypes: added AutoCreateOnDelivery';
END
GO

-- Captured when a supplier invoice is posted (usp_PurchaseDocument_Post): every existing document gets today's values.
IF COL_LENGTH(N'purchase.PurchaseDocuments', N'AffectsCost') IS NULL
BEGIN
    ALTER TABLE purchase.PurchaseDocuments ADD
        AffectsCost BIT NOT NULL CONSTRAINT DF_PurchaseDocuments_AffectsCost DEFAULT (1);            -- 0 = its price never becomes an item cost
    PRINT 'PurchaseDocuments: added AffectsCost';
END
GO

IF COL_LENGTH(N'purchase.PurchaseDocuments', N'ReceiveOnPost') IS NULL
BEGIN
    ALTER TABLE purchase.PurchaseDocuments ADD
        ReceiveOnPost BIT NOT NULL CONSTRAINT DF_PurchaseDocuments_ReceiveOnPost DEFAULT (0);        -- 1 = posting it received its goods (the type's rule)
    PRINT 'PurchaseDocuments: added ReceiveOnPost';
END
GO

/* ================================================================== 2. Configuration > Document Types: the switches */

-- Re-created (79) from the body of script 66: + the three switches.
CREATE OR ALTER PROCEDURE inventory.usp_DocumentType_List
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, Code, Name, Family, StockDirection, NumberPrefix, NextNumber, NumberLength, NumberOnPost,
           RequiresReason, DefaultPricing, PriceEditable, NumberPerBranch, YearInNumber, IsActive, UpdatedAtUtc, UpdatedBy, RowVersion,
           BivacItemsOnly,  -- (66) 1 = every line must be a BIVAC item
           -- (79) what the type does; each means something on one type only (the others keep the default)
           AffectsItemCost,       -- PINV: its price becomes the cost of the goods received against it
           AffectsOnHand,         -- PINV: posting it receives its goods with a goods receipt
           AutoCreateOnDelivery   -- GRN: a completed Delivery movement drafts one per container
    FROM inventory.DocumentTypes
    ORDER BY Family, Code;
END
GO

-- Re-created (79) from the body of script 22: + @AffectsItemCost, @AffectsOnHand, @AutoCreateOnDelivery (NULL =
-- unchanged, like @YearInNumber). Changing them changes no document already posted: an invoice captured its values.
CREATE OR ALTER PROCEDURE inventory.usp_DocumentType_Update
    @Id              INT,
    @Name            NVARCHAR(100),
    @NumberPrefix    NVARCHAR(10),
    @NumberLength    TINYINT,
    @NumberOnPost    BIT,
    @RequiresReason  BIT,
    @DefaultPricing  NVARCHAR(10),
    @PriceEditable   BIT,
    @NumberPerBranch BIT,
    @IsActive        BIT,
    @RowVersion      BINARY(8) = NULL,
    @UserId          INT       = NULL,
    @YearInNumber    BIT       = NULL,    -- NULL = unchanged
    -- (79) NULL = unchanged (an older form never turns one off); each is refused on a type it does not apply to
    @AffectsItemCost      BIT = NULL,     -- PINV
    @AffectsOnHand        BIT = NULL,     -- PINV
    @AutoCreateOnDelivery BIT = NULL      -- GRN
AS
BEGIN
    SET NOCOUNT ON;
    SET @Name = NULLIF(LTRIM(RTRIM(@Name)), N'');
    SET @NumberPrefix = NULLIF(LTRIM(RTRIM(@NumberPrefix)), N'');
    IF @Name IS NULL THROW 62000, 'Name is required.', 1;
    IF @NumberPrefix IS NULL THROW 62000, 'Number prefix is required.', 1;
    IF @NumberLength IS NULL OR @NumberLength NOT BETWEEN 3 AND 10 THROW 62000, 'Number length must be between 3 and 10.', 1;
    IF @DefaultPricing NOT IN (N'Cost', N'PriceList', N'None') THROW 62000, 'Default pricing must be Cost, PriceList or None.', 1;
    IF NOT EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Id = @Id) THROW 62006, 'Document type not found.', 1;
    -- (79) a switch belongs to one type: sent for another, it would be stored and read by nothing
    DECLARE @Code NVARCHAR(20) = (SELECT Code FROM inventory.DocumentTypes WHERE Id = @Id);
    IF (@AffectsItemCost IS NOT NULL OR @AffectsOnHand IS NOT NULL) AND @Code <> N'PINV'
        THROW 62000, 'Affects item cost and Affects on-hand apply to the purchase invoice type (PINV) only.', 1;
    IF @AutoCreateOnDelivery IS NOT NULL AND @Code <> N'GRN'
        THROW 62000, 'Create goods receipts on Delivery applies to the goods receipt type (GRN) only.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 62004, 'This document type was modified by another user. Reload the page and try again.', 1;

    UPDATE inventory.DocumentTypes
    SET Name = @Name, NumberPrefix = @NumberPrefix, NumberLength = @NumberLength, NumberOnPost = ISNULL(@NumberOnPost, 0),
        RequiresReason = ISNULL(@RequiresReason, 0), DefaultPricing = @DefaultPricing, PriceEditable = ISNULL(@PriceEditable, 1),
        NumberPerBranch = ISNULL(@NumberPerBranch, 1), YearInNumber = ISNULL(@YearInNumber, YearInNumber), IsActive = ISNULL(@IsActive, 1),
        AffectsItemCost = ISNULL(@AffectsItemCost, AffectsItemCost), AffectsOnHand = ISNULL(@AffectsOnHand, AffectsOnHand),
        AutoCreateOnDelivery = ISNULL(@AutoCreateOnDelivery, AutoCreateOnDelivery),
        UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
END
GO

/* ================================================================== 3. The one rule: an invoice that does not change item costs */

-- Re-created (79) from the body of script 64. (79) The pieces matched to an invoice whose AffectsCost is 0 cost as
-- if they were unmatched: the order price (a container line keeps its container's charges, which never came from an
-- invoice). MatchedBase still counts every match (the post confirmation's "received, not invoiced", the counters);
-- CostMatchedBase counts those that price. A receipt line made from an order-less invoice of that kind keeps the cost
-- its receipt gave it. CostSource says where the target really comes from.
CREATE OR ALTER FUNCTION purchase.fn_GoodsReceiptLine_TargetCost (@GoodsReceiptId INT)
RETURNS TABLE
AS
RETURN
    SELECT GoodsReceiptId      = g.Id,
           GoodsReceiptLineId  = gl.Id,
           gl.LineNumber, gl.ItemId, gl.WarehouseId, gl.SupplierId, gl.PoLineId, gl.InvoiceLineId, gl.ContainerLineId,
           ContainerId         = cl.ContainerId,
           IsContainerLine     = CAST(CASE WHEN gl.ContainerLineId IS NOT NULL THEN 1 ELSE 0 END AS BIT),
           ReceivedBase        = gl.QuantityBase,
           MatchedBase         = m.Qty,
           CostMatchedBase     = m.CostQty,     -- (79) of them, the pieces matched to invoices that change item costs
           NetReceivedBase     = CAST(gl.QuantityBase - m.Returned AS DECIMAL(18,6)),
           BaseFobBase         = b.Fob,
           BaseChargesBase     = b.Charges,
           TargetFobBase       = t.Fob,
           TargetChargesBase   = t.Charges,
           TargetUnitCostBase  = CAST(t.Fob + t.Charges AS DECIMAL(18,6)),
           CurrentFobBase      = CASE WHEN gl.ContainerLineId IS NOT NULL THEN cl.FobCostBase ELSE gl.FobCostBase END,
           CurrentChargesBase  = CASE WHEN gl.ContainerLineId IS NOT NULL THEN CAST(cl.ChargesBase / gl.QuantityBase AS DECIMAL(18,6))
                                      ELSE gl.ChargesBase END,
           CurrentUnitCostBase = CASE WHEN gl.ContainerLineId IS NOT NULL THEN cl.LandedCostBase ELSE gl.UnitCostBase END,
           CostSource          = CAST(CASE WHEN m.CostQty >= gl.QuantityBase THEN N'Invoice'
                                           WHEN gl.PoLineId IS NULL AND gl.InvoiceLineId IS NOT NULL AND ISNULL(ild.AffectsCost, 1) = 1 THEN N'Invoice'
                                           WHEN m.CostQty > 0 THEN N'Mixed'
                                           WHEN gl.PoLineId IS NOT NULL THEN N'Order'
                                           ELSE N'Manual' END AS NVARCHAR(10))
    FROM purchase.GoodsReceipts g
    INNER JOIN purchase.GoodsReceiptLines gl      ON gl.GoodsReceiptId = g.Id AND gl.QuantityBase > 0
    LEFT  JOIN logistics.ContainerLines cl        ON cl.Id = gl.ContainerLineId
    LEFT  JOIN purchase.PurchaseDocumentLines pol ON pol.Id = gl.PoLineId
    LEFT  JOIN purchase.PurchaseDocuments po      ON po.Id = pol.DocumentId
    LEFT  JOIN purchase.PurchaseDocumentLines il  ON il.Id = gl.InvoiceLineId
    LEFT  JOIN purchase.PurchaseDocuments ild     ON ild.Id = il.DocumentId
    CROSS APPLY (SELECT Qty      = ISNULL(SUM(x.QuantityBase), 0),
                        -- (79) only an invoice that changes item costs prices its pieces (AffectsCost, captured when
                        --      it was posted); the others' pieces cost as if unmatched, below
                        CostQty  = ISNULL(SUM(CASE WHEN pd.AffectsCost = 1 THEN x.QuantityBase ELSE 0 END), 0),
                        Fob      = ISNULL(SUM(CASE WHEN pd.AffectsCost = 1
                                                   THEN x.QuantityBase * COALESCE(p.FobCostBase, p.LineTotal / pd.ExchangeRate / p.QuantityBase) ELSE 0 END), 0),
                        Charges  = ISNULL(SUM(CASE WHEN pd.AffectsCost = 1 THEN x.QuantityBase * p.AllocatedChargesBase / p.QuantityBase ELSE 0 END), 0),
                        Returned = ISNULL(SUM(CAST(x.QuantityBase AS DECIMAL(18,6))
                                              * CASE WHEN p.ReturnedQuantityBase < p.ReceivedQuantityBase THEN p.ReturnedQuantityBase
                                                     ELSE p.ReceivedQuantityBase END
                                              / NULLIF(p.ReceivedQuantityBase, 0)), 0)
                 FROM purchase.GoodsReceiptInvoiceMatches x
                 INNER JOIN purchase.PurchaseDocumentLines p ON p.Id = x.InvoiceLineId
                 INNER JOIN purchase.PurchaseDocuments pd    ON pd.Id = p.DocumentId
                 WHERE x.GoodsReceiptLineId = gl.Id) m
    CROSS APPLY (SELECT Fob = CAST(CASE WHEN gl.PoLineId IS NOT NULL
                                        THEN COALESCE(gl.PoFobBase, pol.LineTotal / po.ExchangeRate / NULLIF(pol.QuantityBase, 0), 0)
                                        WHEN gl.InvoiceLineId IS NULL THEN ISNULL(gl.ManualUnitCostBase, 0)
                                        -- (79) an invoice without an order that does not change item costs: the cost
                                        --      the receipt gave it (usp_GoodsReceipt_Post: typed, else the item's)
                                        WHEN ild.AffectsCost = 0 THEN COALESCE(gl.ManualUnitCostBase, gl.CostAtReceiptBase, 0)
                                        ELSE COALESCE(gl.CostAtReceiptBase, il.UnitCostBase, 0) END AS DECIMAL(18,6)),
                        Charges = CAST(0 AS DECIMAL(18,6))) b
    CROSS APPLY (SELECT Fob     = CAST((m.Fob + CASE WHEN gl.ContainerLineId IS NOT NULL THEN m.Charges ELSE 0 END
                                        + (gl.QuantityBase - m.CostQty) * b.Fob) / gl.QuantityBase AS DECIMAL(18,6)),
                        Charges = CAST(CASE WHEN gl.ContainerLineId IS NOT NULL THEN ISNULL(cl.ChargesBase, 0) / gl.QuantityBase
                                            ELSE (m.Charges + (gl.QuantityBase - m.CostQty) * b.Charges) / gl.QuantityBase END AS DECIMAL(18,6))) t
    WHERE g.Id = @GoodsReceiptId AND g.Status = 2;
GO

-- Re-created (79) from the body of script 64: a DRAFT's estimate leaves out the invoices that do not change item costs
-- (their pieces are estimated at the order price), as the posting will (section 3).
CREATE OR ALTER FUNCTION purchase.fn_GoodsReceiptLine_Cost (@GoodsReceiptId INT)
RETURNS TABLE
AS
RETURN
    SELECT LineId         = l.Id,
           l.GoodsReceiptId,
           OrderPriceBase = CAST(op.Price AS DECIMAL(18,6)),
           FobBase        = CAST(y.Fob AS DECIMAL(18,6)),
           ChargesBase    = CAST(y.Charges AS DECIMAL(18,6)),
           UnitCostBase   = CAST(z.Unit AS DECIMAL(18,6)),
           IsEstimate     = CAST(CASE WHEN g.Status = 1 THEN 1 ELSE 0 END AS BIT),
           ValueBase      = CAST(ROUND(CAST(l.QuantityBase AS DECIMAL(18,6)) * ISNULL(z.Unit, 0), 2) AS DECIMAL(18,2))
    FROM purchase.GoodsReceiptLines l
    INNER JOIN purchase.GoodsReceipts g             ON g.Id = l.GoodsReceiptId
    LEFT  JOIN logistics.ContainerLines cl          ON cl.Id = l.ContainerLineId
    LEFT  JOIN purchase.PurchaseDocumentLines pol   ON pol.Id = l.PoLineId
    LEFT  JOIN purchase.PurchaseDocuments po        ON po.Id = pol.DocumentId
    LEFT  JOIN purchase.PurchaseDocumentLines pil   ON pil.Id = l.InvoiceLineId
    LEFT  JOIN purchase.PurchaseDocuments pid       ON pid.Id = pil.DocumentId AND pid.Status IN (2, 4) AND pid.AffectsCost = 1
    LEFT  JOIN inventory.Items it                   ON it.Id = l.ItemId
    OUTER APPLY (SELECT Price = COALESCE(l.PoFobBase,
                                         pol.LineTotal / NULLIF(po.ExchangeRate, 0) / NULLIF(pol.QuantityBase, 0))) op
    OUTER APPLY (SELECT Fob = SUM(x.LineTotal / NULLIF(xd.ExchangeRate, 0)) / NULLIF(SUM(x.QuantityBase), 0)
                 FROM purchase.PurchaseDocumentLines x
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId AND xd.Status IN (2, 4) AND xd.AffectsCost = 1
                 WHERE l.ContainerLineId IS NOT NULL AND g.Status = 1 AND x.ContainerLineId = l.ContainerLineId) ci
    CROSS APPLY (SELECT Fob = CASE WHEN g.Status = 3 THEN NULL
                                   WHEN g.Status = 2 AND l.ContainerLineId IS NOT NULL THEN cl.FobCostBase
                                   WHEN g.Status = 2 THEN l.FobCostBase
                                   WHEN l.ContainerLineId IS NOT NULL THEN COALESCE(ci.Fob, op.Price)
                                   WHEN pid.Id IS NOT NULL AND pil.FobCostBase IS NOT NULL THEN pil.FobCostBase
                                   WHEN l.PoLineId IS NOT NULL THEN op.Price
                                   -- (79) an order-less invoice that does not change item costs: what the posting will take
                                   WHEN l.PoLineId IS NULL AND l.InvoiceLineId IS NOT NULL
                                       THEN COALESCE(l.ManualUnitCostBase, NULLIF(it.LastCost, 0), NULLIF(it.AverageCost, 0), pil.UnitCostBase)
                                   ELSE l.ManualUnitCostBase END,
                        Charges = CASE WHEN g.Status = 3 THEN NULL
                                       WHEN g.Status = 2 AND l.ContainerLineId IS NOT NULL
                                           THEN cl.ChargesBase / NULLIF(cl.ReceivedQuantityBase, 0)
                                       WHEN g.Status = 2 THEN l.ChargesBase
                                       WHEN l.ContainerLineId IS NOT NULL THEN cl.ChargesBase / NULLIF(cl.QuantityBase, 0)
                                       WHEN pid.Id IS NOT NULL AND pil.FobCostBase IS NOT NULL
                                           THEN ISNULL(pil.AllocatedChargesBase, 0) / NULLIF(pil.QuantityBase, 0)
                                       ELSE CAST(0 AS DECIMAL(18,6)) END) y
    CROSS APPLY (SELECT Unit = CASE WHEN g.Status = 3 THEN l.CostAtReceiptBase
                                    WHEN g.Status = 2 AND l.ContainerLineId IS NOT NULL THEN COALESCE(cl.LandedCostBase, l.CostAtReceiptBase)
                                    WHEN g.Status = 2 THEN COALESCE(l.UnitCostBase, l.CostAtReceiptBase)
                                    ELSE y.Fob + ISNULL(y.Charges, 0) END) z
    WHERE l.GoodsReceiptId = @GoodsReceiptId;
GO

/* ================================================================== 4. The matching is unchanged: only where the cost comes from */

-- Re-created (79) from the body of script 64: every invoice is matched as before (the counters, the return caps,
-- container Close and the payments need it); a receipt line's CostSource counts only the matches to invoices that
-- change item costs, the same rule as section 3.
CREATE OR ALTER PROCEDURE purchase.usp_GoodsReceipt_Rematch
    @Anchors     purchase.tvp_GoodsReceiptAnchor READONLY,
    @ReturnLines BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC purchase.usp_GoodsReceipt_LockMatching;

        DECLARE @G TABLE (GroupKey NVARCHAR(40) NOT NULL PRIMARY KEY, PoLineId INT NULL, SupplierId INT NULL, ItemId INT NULL);
        INSERT INTO @G (GroupKey, PoLineId, SupplierId, ItemId)
        SELECT N'P' + CAST(a.PoLineId AS NVARCHAR(12)), a.PoLineId, NULL, NULL
        FROM @Anchors a WHERE a.Kind = 'P' AND a.PoLineId IS NOT NULL
        UNION
        SELECT N'S' + CAST(a.SupplierId AS NVARCHAR(12)) + N'.' + CAST(a.ItemId AS NVARCHAR(12)), NULL, a.SupplierId, a.ItemId
        FROM @Anchors a WHERE a.Kind = 'S' AND a.SupplierId IS NOT NULL AND a.ItemId IS NOT NULL;

        -- every receipt line of the groups, whatever its status: a cancelled receipt loses its matches here.
        -- Rem = what it can still take (posted receipts only).
        DECLARE @R TABLE (LineId INT NOT NULL PRIMARY KEY, GroupKey NVARCHAR(40) NOT NULL, Posted BIT NOT NULL,
                          InvoiceLineId INT NULL, ContainerLineId INT NULL, PoLineId INT NULL, T DATETIME2(3) NOT NULL,
                          Qty INT NOT NULL, Rem INT NOT NULL);
        -- (the two kinds of group apart, one statement each, so each seeks its own index - an order line's filtered
        -- index needs its IS NOT NULL said - and reads the groups' rows only: an OR join read every receipt line, and
        -- waited on rows other users were writing)
        INSERT INTO @R (LineId, GroupKey, Posted, InvoiceLineId, ContainerLineId, PoLineId, T, Qty, Rem)
        SELECT gl.Id, gk.GroupKey, CASE WHEN g.Status = 2 THEN 1 ELSE 0 END, gl.InvoiceLineId, gl.ContainerLineId, gl.PoLineId,
               ISNULL(g.PostedAtUtc, g.CreatedAtUtc), gl.QuantityBase,
               CASE WHEN g.Status = 2 THEN gl.QuantityBase ELSE 0 END
        FROM @G gk
        INNER JOIN purchase.GoodsReceiptLines gl ON gl.PoLineId = gk.PoLineId AND gl.PoLineId IS NOT NULL
        INNER JOIN purchase.GoodsReceipts g      ON g.Id = gl.GoodsReceiptId
        WHERE gk.PoLineId IS NOT NULL;

        INSERT INTO @R (LineId, GroupKey, Posted, InvoiceLineId, ContainerLineId, PoLineId, T, Qty, Rem)
        SELECT gl.Id, gk.GroupKey, CASE WHEN g.Status = 2 THEN 1 ELSE 0 END, gl.InvoiceLineId, gl.ContainerLineId, gl.PoLineId,
               ISNULL(g.PostedAtUtc, g.CreatedAtUtc), gl.QuantityBase,
               CASE WHEN g.Status = 2 THEN gl.QuantityBase ELSE 0 END
        FROM @G gk
        INNER JOIN purchase.GoodsReceiptLines gl ON gl.SupplierId = gk.SupplierId AND gl.ItemId = gk.ItemId AND gl.PoLineId IS NULL
        INNER JOIN purchase.GoodsReceipts g      ON g.Id = gl.GoodsReceiptId
        WHERE gk.PoLineId IS NULL;

        -- every supplier invoice line of the groups. Eligible = goods receipts receive its goods (its matches and its
        -- ReceivedQuantityBase are this procedure's); Rem = what it can still pay for (posted or closed, eligible).
        DECLARE @I TABLE (LineId INT NOT NULL PRIMARY KEY, GroupKey NVARCHAR(40) NOT NULL, Eligible BIT NOT NULL,
                          ContainerLineId INT NULL, T DATETIME2(3) NOT NULL, Rem INT NOT NULL);
        -- (the lines of the groups first, one statement per kind of group, as for the receipt lines)
        DECLARE @IL TABLE (LineId INT NOT NULL PRIMARY KEY, GroupKey NVARCHAR(40) NOT NULL);
        INSERT INTO @IL (LineId, GroupKey)
        SELECT l.Id, gk.GroupKey
        FROM @G gk
        INNER JOIN purchase.PurchaseDocumentLines l ON l.SourceLineId = gk.PoLineId AND l.SourceLineId IS NOT NULL
        WHERE gk.PoLineId IS NOT NULL;

        INSERT INTO @IL (LineId, GroupKey)
        SELECT l.Id, gk.GroupKey
        FROM @G gk
        INNER JOIN purchase.PurchaseDocumentLines l ON l.ItemId = gk.ItemId AND l.SourceLineId IS NULL
        INNER JOIN purchase.PurchaseDocuments d     ON d.Id = l.DocumentId AND d.SupplierId = gk.SupplierId
        WHERE gk.PoLineId IS NULL;

        INSERT INTO @I (LineId, GroupKey, Eligible, ContainerLineId, T, Rem)
        SELECT l.Id, x.GroupKey, e.Eligible, l.ContainerLineId, ISNULL(d.PostedAtUtc, d.CreatedAtUtc),
               CASE WHEN e.Eligible = 1 AND d.Status IN (2, 4) THEN l.QuantityBase ELSE 0 END
        FROM @IL x
        INNER JOIN purchase.PurchaseDocumentLines l ON l.Id = x.LineId
        INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
        INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId AND dt.Code = N'PINV'
        LEFT  JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
        OUTER APPLY logistics.fn_Container_ReceivedBy(cl.ContainerId) rb
        CROSS APPLY (SELECT Eligible = CAST(CASE WHEN d.UsesGoodsReceipts = 0 AND d.ReceiptMode = 1 THEN 0
                                                 WHEN rb.ReceivedBy = N'Offload' THEN 0
                                                 ELSE 1 END AS BIT)) e;

        DECLARE @M    TABLE (RLineId INT NOT NULL, ILineId INT NOT NULL, Qty INT NOT NULL);
        DECLARE @Pass TABLE (RLineId INT NOT NULL, ILineId INT NOT NULL, Qty INT NOT NULL);

        -- Each pass pairs the two sides of one key first in first out: the running totals give each line an interval
        -- [E - Rem, E) of the key's pieces, and a receipt line and an invoice line share the overlap of their intervals.

        -- pass 0: the invoice line the receipt was made from
        WITH r AS (SELECT LineId, K = InvoiceLineId, Rem,
                          E = SUM(Rem) OVER (PARTITION BY InvoiceLineId ORDER BY T, LineId ROWS UNBOUNDED PRECEDING)
                   FROM @R WHERE Rem > 0 AND InvoiceLineId IS NOT NULL),
             i AS (SELECT LineId, K = LineId, Rem, E = Rem FROM @I WHERE Rem > 0)
        INSERT INTO @Pass (RLineId, ILineId, Qty)
        SELECT r.LineId, i.LineId,
               (CASE WHEN r.E < i.E THEN r.E ELSE i.E END) - (CASE WHEN r.E - r.Rem > i.E - i.Rem THEN r.E - r.Rem ELSE i.E - i.Rem END)
        FROM r INNER JOIN i ON i.K = r.K
        WHERE r.E - r.Rem < i.E AND i.E - i.Rem < r.E;

        UPDATE r SET Rem = r.Rem - p.Qty FROM @R r INNER JOIN (SELECT RLineId, Qty = SUM(Qty) FROM @Pass GROUP BY RLineId) p ON p.RLineId = r.LineId;
        UPDATE i SET Rem = i.Rem - p.Qty FROM @I i INNER JOIN (SELECT ILineId, Qty = SUM(Qty) FROM @Pass GROUP BY ILineId) p ON p.ILineId = i.LineId;
        INSERT INTO @M (RLineId, ILineId, Qty) SELECT RLineId, ILineId, Qty FROM @Pass;
        DELETE FROM @Pass;

        -- pass 1: the container line
        WITH r AS (SELECT LineId, K = ContainerLineId, Rem,
                          E = SUM(Rem) OVER (PARTITION BY ContainerLineId ORDER BY T, LineId ROWS UNBOUNDED PRECEDING)
                   FROM @R WHERE Rem > 0 AND ContainerLineId IS NOT NULL),
             i AS (SELECT LineId, K = ContainerLineId, Rem,
                          E = SUM(Rem) OVER (PARTITION BY ContainerLineId ORDER BY T, LineId ROWS UNBOUNDED PRECEDING)
                   FROM @I WHERE Rem > 0 AND ContainerLineId IS NOT NULL)
        INSERT INTO @Pass (RLineId, ILineId, Qty)
        SELECT r.LineId, i.LineId,
               (CASE WHEN r.E < i.E THEN r.E ELSE i.E END) - (CASE WHEN r.E - r.Rem > i.E - i.Rem THEN r.E - r.Rem ELSE i.E - i.Rem END)
        FROM r INNER JOIN i ON i.K = r.K
        WHERE r.E - r.Rem < i.E AND i.E - i.Rem < r.E;

        UPDATE r SET Rem = r.Rem - p.Qty FROM @R r INNER JOIN (SELECT RLineId, Qty = SUM(Qty) FROM @Pass GROUP BY RLineId) p ON p.RLineId = r.LineId;
        UPDATE i SET Rem = i.Rem - p.Qty FROM @I i INNER JOIN (SELECT ILineId, Qty = SUM(Qty) FROM @Pass GROUP BY ILineId) p ON p.ILineId = i.LineId;
        INSERT INTO @M (RLineId, ILineId, Qty) SELECT RLineId, ILineId, Qty FROM @Pass;
        DELETE FROM @Pass;

        -- passes 2 and 3: the group itself (the order line, or the supplier + item)
        WITH r AS (SELECT LineId, K = GroupKey, Rem,
                          E = SUM(Rem) OVER (PARTITION BY GroupKey ORDER BY T, LineId ROWS UNBOUNDED PRECEDING)
                   FROM @R WHERE Rem > 0),
             i AS (SELECT LineId, K = GroupKey, Rem,
                          E = SUM(Rem) OVER (PARTITION BY GroupKey ORDER BY T, LineId ROWS UNBOUNDED PRECEDING)
                   FROM @I WHERE Rem > 0)
        INSERT INTO @Pass (RLineId, ILineId, Qty)
        SELECT r.LineId, i.LineId,
               (CASE WHEN r.E < i.E THEN r.E ELSE i.E END) - (CASE WHEN r.E - r.Rem > i.E - i.Rem THEN r.E - r.Rem ELSE i.E - i.Rem END)
        FROM r INNER JOIN i ON i.K = r.K
        WHERE r.E - r.Rem < i.E AND i.E - i.Rem < r.E;

        INSERT INTO @M (RLineId, ILineId, Qty) SELECT RLineId, ILineId, Qty FROM @Pass;

        DECLARE @New TABLE (RLineId INT NOT NULL, ILineId INT NOT NULL, Qty INT NOT NULL, PRIMARY KEY (RLineId, ILineId));
        INSERT INTO @New (RLineId, ILineId, Qty)
        SELECT RLineId, ILineId, SUM(Qty) FROM @M GROUP BY RLineId, ILineId HAVING SUM(Qty) > 0;

        -- the matches of the groups become @New; an unchanged pair keeps its MatchedAtUtc
        DELETE m
        FROM purchase.GoodsReceiptInvoiceMatches m
        WHERE (EXISTS (SELECT 1 FROM @R r WHERE r.LineId = m.GoodsReceiptLineId) OR EXISTS (SELECT 1 FROM @I i WHERE i.LineId = m.InvoiceLineId))
          AND NOT EXISTS (SELECT 1 FROM @New n WHERE n.RLineId = m.GoodsReceiptLineId AND n.ILineId = m.InvoiceLineId);

        UPDATE m SET QuantityBase = n.Qty, MatchedAtUtc = SYSUTCDATETIME()
        FROM purchase.GoodsReceiptInvoiceMatches m
        INNER JOIN @New n ON n.RLineId = m.GoodsReceiptLineId AND n.ILineId = m.InvoiceLineId
        WHERE m.QuantityBase <> n.Qty;

        INSERT INTO purchase.GoodsReceiptInvoiceMatches (GoodsReceiptLineId, InvoiceLineId, QuantityBase)
        SELECT n.RLineId, n.ILineId, n.Qty
        FROM @New n
        WHERE NOT EXISTS (SELECT 1 FROM purchase.GoodsReceiptInvoiceMatches m WHERE m.GoodsReceiptLineId = n.RLineId AND m.InvoiceLineId = n.ILineId);

        -- receipt lines: pieces invoiced, and where their cost comes from (posted lines)
        UPDATE gl
        SET InvoicedBase = x.Qty,
            -- (79) the cost comes from an invoice only when that invoice changes item costs (section 3)
            CostSource = CASE WHEN r.Posted = 0 THEN gl.CostSource
                              WHEN gl.QuantityBase > 0 AND x.CostQty >= gl.QuantityBase THEN N'Invoice'
                              WHEN gl.PoLineId IS NULL AND gl.InvoiceLineId IS NOT NULL AND ISNULL(ri.AffectsCost, 1) = 1 THEN N'Invoice'   -- received at its invoice's cost
                              WHEN x.CostQty > 0 THEN N'Mixed'
                              WHEN gl.PoLineId IS NOT NULL THEN N'Order'
                              ELSE N'Manual' END
        FROM purchase.GoodsReceiptLines gl
        INNER JOIN @R r ON r.LineId = gl.Id
        CROSS APPLY (SELECT Qty     = ISNULL((SELECT SUM(n.Qty) FROM @New n WHERE n.RLineId = gl.Id), 0),
                            CostQty = ISNULL((SELECT SUM(n.Qty) FROM @New n
                                              INNER JOIN purchase.PurchaseDocumentLines p ON p.Id = n.ILineId
                                              INNER JOIN purchase.PurchaseDocuments pd    ON pd.Id = p.DocumentId
                                              WHERE n.RLineId = gl.Id AND pd.AffectsCost = 1), 0)) x
        OUTER APPLY (SELECT pd.AffectsCost FROM purchase.PurchaseDocumentLines p
                     INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = p.DocumentId
                     WHERE p.Id = gl.InvoiceLineId) ri;

        -- invoice lines that goods receipts receive: received = the pieces matched to them
        UPDATE l
        SET ReceivedQuantityBase = x.Qty
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN @I i ON i.LineId = l.Id AND i.Eligible = 1
        CROSS APPLY (SELECT Qty = ISNULL((SELECT SUM(n.Qty) FROM @New n WHERE n.ILineId = l.Id), 0)) x
        WHERE l.ReceivedQuantityBase <> x.Qty;

        COMMIT TRANSACTION;

        IF @ReturnLines = 1
            SELECT GoodsReceiptLineId = LineId FROM @R WHERE Posted = 1 ORDER BY LineId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 5. The item's last cost */

-- Re-created (79) from the body of script 65: a line received without an order counts for the last cost, FOB cost
-- and last supplier only once matched to an invoice that changes item costs - a manual line as before (its typed
-- cost is not a purchase price), and now a line of an order-less invoice that does not change item costs.
CREATE OR ALTER PROCEDURE inventory.usp_Item_RebuildCosts
    @ItemId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Events TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, ItemId INT, Qty INT, Cost DECIMAL(18,6), Amount DECIMAL(18,2));
    INSERT INTO @Events (ItemId, Qty, Cost, Amount)
    SELECT x.ItemId, x.Qty, x.Cost, x.Amount
    FROM
    (
        SELECT m.ItemId, EventDate = m.MovementDate, Src = 1, SrcId = m.Id, Qty = m.QuantityBase, Cost = m.UnitCostBase, Amount = CAST(NULL AS DECIMAL(18,2))
        FROM inventory.StockMovements m
        WHERE (@ItemId IS NULL OR m.ItemId = @ItemId)
          AND NOT EXISTS (SELECT 1 FROM inventory.StockMovements r WHERE r.DocumentFamily = m.DocumentFamily AND r.DocumentTypeCode = m.DocumentTypeCode
                                                                     AND r.DocumentId = m.DocumentId AND r.IsReversal = 1
                                                                     AND (m.DocumentTypeCode <> N'CNT' OR r.DocumentNumber = m.DocumentNumber))
        UNION ALL
        SELECT c.ItemId, c.AdjustmentDate, 2, CAST(c.Id AS INT), 0, NULL, c.AmountBase
        FROM inventory.CostAdjustments c
        WHERE c.Kind = N'Inventory' AND (@ItemId IS NULL OR c.ItemId = @ItemId)
    ) x
    ORDER BY x.ItemId, x.EventDate, x.Src, x.SrcId;

    DECLARE @Result TABLE (ItemId INT PRIMARY KEY, AverageCost DECIMAL(18,6));
    DECLARE @CurItem INT = NULL, @OnHand DECIMAL(18,6) = 0, @Avg DECIMAL(18,6) = 0;
    DECLARE @EItem INT, @EQty INT, @ECost DECIMAL(18,6), @EAmount DECIMAL(18,2);

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT ItemId, Qty, Cost, Amount FROM @Events ORDER BY Seq;
    OPEN cur;
    FETCH NEXT FROM cur INTO @EItem, @EQty, @ECost, @EAmount;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @CurItem IS NULL OR @CurItem <> @EItem
        BEGIN
            IF @CurItem IS NOT NULL INSERT INTO @Result (ItemId, AverageCost) VALUES (@CurItem, @Avg);
            SELECT @CurItem = @EItem, @OnHand = 0, @Avg = 0;
        END

        IF @EAmount IS NOT NULL                                   -- inventory value adjustment (LCA)
            SET @Avg = CASE WHEN @OnHand > 0 THEN @Avg + @EAmount / @OnHand ELSE @Avg END;
        ELSE IF @EQty > 0                                         -- receipt
        BEGIN
            SET @Avg = CASE WHEN @OnHand + @EQty > 0 THEN ((CASE WHEN @OnHand > 0 THEN @OnHand ELSE 0 END) * @Avg + @EQty * ISNULL(@ECost, @Avg)) / ((CASE WHEN @OnHand > 0 THEN @OnHand ELSE 0 END) + @EQty) ELSE @Avg END;
            SET @OnHand = @OnHand + @EQty;
        END
        ELSE                                                      -- issue: average unchanged
            SET @OnHand = @OnHand + @EQty;

        FETCH NEXT FROM cur INTO @EItem, @EQty, @ECost, @EAmount;
    END
    CLOSE cur; DEALLOCATE cur;
    IF @CurItem IS NOT NULL INSERT INTO @Result (ItemId, AverageCost) VALUES (@CurItem, @Avg);

    -- Items with no remaining events (everything cancelled) fall back to 0.
    UPDATE i SET AverageCost = ISNULL(r.AverageCost, 0)
    FROM inventory.Items i
    LEFT JOIN @Result r ON r.ItemId = i.Id
    WHERE (@ItemId IS NULL OR i.Id = @ItemId);

    UPDATE i
    SET LastCost = x.Landed, FobCost = x.Fob, LastSupplierId = x.SupplierId, LastPurchaseAtUtc = x.ReceivedAtUtc
    FROM inventory.Items i
    OUTER APPLY (SELECT TOP (1) r.Landed, r.Fob, r.SupplierId, r.ReceivedAtUtc
                 FROM (-- (65) (a) a local invoice posted before goods receipts (it received its goods when posted)
                       SELECT Landed = l.UnitCostBase, Fob = l.FobCostBase, d.SupplierId, ReceivedAtUtc = d.PostedAtUtc, Tie = l.Id
                       FROM purchase.PurchaseDocumentLines l
                       INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
                       INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                       WHERE dt.Code = N'PINV' AND d.Status = 2 AND d.ReceiptMode = 1 AND d.UsesGoodsReceipts = 0 AND l.ItemId = i.Id
                       UNION ALL
                       -- (65) (b) a container offloaded before goods receipts (a container received with one is (c))
                       SELECT cl.LandedCostBase, cl.FobCostBase, po.SupplierId, c.OffloadedAtUtc, cl.Id
                       FROM logistics.ContainerLines cl
                       INNER JOIN logistics.Containers c        ON c.Id = cl.ContainerId
                       INNER JOIN purchase.PurchaseDocuments po ON po.Id = cl.PurchaseOrderId
                       CROSS APPLY logistics.fn_Container_ReceivedBy(c.Id) rb
                       WHERE rb.ReceivedBy = N'Offload' AND cl.ItemId = i.Id AND cl.ReceivedQuantityBase > 0
                       UNION ALL
                       -- (65) (c) a posted goods receipt line with pieces; a manual line only once matched to an invoice
                       SELECT CASE WHEN gl.ContainerLineId IS NOT NULL THEN gcl.LandedCostBase ELSE gl.UnitCostBase END,
                              CASE WHEN gl.ContainerLineId IS NOT NULL THEN gcl.FobCostBase ELSE gl.FobCostBase END,
                              gl.SupplierId, g.PostedAtUtc, gl.Id
                       FROM purchase.GoodsReceiptLines gl
                       INNER JOIN purchase.GoodsReceipts g      ON g.Id = gl.GoodsReceiptId AND g.Status = 2
                       LEFT  JOIN logistics.ContainerLines gcl  ON gcl.Id = gl.ContainerLineId
                       WHERE gl.ItemId = i.Id AND gl.QuantityBase > 0
                         -- (79) a line without an order - manual, or from an invoice that does not change item
                         --      costs - counts once matched to an invoice that does: its cost is not a purchase price
                         AND NOT (gl.PoLineId IS NULL
                                  AND (gl.InvoiceLineId IS NULL
                                       OR EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines p
                                                  INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = p.DocumentId
                                                  WHERE p.Id = gl.InvoiceLineId AND pd.AffectsCost = 0))
                                  AND NOT EXISTS (SELECT 1 FROM purchase.GoodsReceiptInvoiceMatches x
                                                  INNER JOIN purchase.PurchaseDocumentLines p ON p.Id = x.InvoiceLineId
                                                  INNER JOIN purchase.PurchaseDocuments pd    ON pd.Id = p.DocumentId
                                                  WHERE x.GoodsReceiptLineId = gl.Id AND pd.AffectsCost = 1))) r
                 ORDER BY r.ReceivedAtUtc DESC, r.Tie DESC) x
    WHERE (@ItemId IS NULL OR i.Id = @ItemId);
END
GO

/* ================================================================== 6. Posting a goods receipt */

-- Re-created (79) from the body of script 77: step 3 gives a line of an order-less invoice that does not change item
-- costs a manual cost; step 6 lets a line without an order change the last cost only once matched to an invoice that
-- does. The cost at receipt is the target cost (section 3): pieces matched to such an invoice enter at the order price.
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

/* ================================================================== 7. Returns from an invoice that does not change item costs */

-- Re-created (79) from the body of script 65: a return from an invoice that does not change item costs carries the
-- current cost of the receipt lines matched to its invoice line (what the goods are in stock at), not the invoice's
-- landed cost; its price - the supplier's credit - is still the invoice's. Worked out again when it is posted.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Save
    @Id                  INT            = NULL,
    @DocumentTypeCode    NVARCHAR(20),
    @DocumentDate        DATE,
    @ExpectedDate        DATE           = NULL,
    @BranchId            INT,
    @WarehouseId         INT = NULL,
    @SupplierId          INT,
    @CurrencyId          INT            = NULL,
    @RateType            TINYINT        = 1,
    @ExchangeRate        DECIMAL(18,6)  = NULL,
    @SupplierReference   NVARCHAR(100)  = NULL,
    @Notes               NVARCHAR(1000) = NULL,
    @Lines               purchase.tvp_PurchaseDocumentLine READONLY,
    @MaxDiscountPercent  DECIMAL(9,4)   = 100,
    @SourceDocumentId    INT            = NULL,
    @RowVersion          BINARY(8)      = NULL,
    @UserId              INT            = NULL,
    @ReceiptMode         TINYINT        = NULL,    -- NULL = unchanged (1 on creation)
    @ExporterReference   NVARCHAR(50)   = NULL,
    @CommercialInvoiceNo NVARCHAR(50)   = NULL,
    @LineContainers      purchase.tvp_LineContainer READONLY,   -- invoice from containers: the container line of every line
    @NewId               INT OUTPUT,
    @OneItemOnly         BIT            = NULL     -- (63) a NEW supplier invoice: 1 one item, 0 several; NULL = the setting. Kept on update.
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* The warehouse lives on the LINES. The header keeps one so that document lists, filters,
       reports and exports still have a warehouse to show; when the caller does not send one it is
       taken from the first line. */
    IF @WarehouseId IS NULL
        SELECT TOP (1) @WarehouseId = WarehouseId FROM @Lines ORDER BY LineNumber;

    SET @SupplierReference = NULLIF(LTRIM(RTRIM(@SupplierReference)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    SET @ExporterReference = NULLIF(LTRIM(RTRIM(@ExporterReference)), N'');
    SET @CommercialInvoiceNo = NULLIF(LTRIM(RTRIM(@CommercialInvoiceNo)), N'');
    IF @ReceiptMode IS NOT NULL AND @ReceiptMode NOT IN (1, 2) THROW 65000, 'Receipt mode must be 1 (on posting) or 2 (on container offload).', 1;
    IF @ReceiptMode = 2 AND @DocumentTypeCode <> N'PINV' THROW 65000, 'Only purchase invoices can be received on container offload.', 1;

    DECLARE @TypeId INT, @Direction SMALLINT, @Cur INT, @Rate DECIMAL(18,6);
    EXEC purchase.usp_PurchaseDocument_ValidateInput @DocumentTypeCode, @DocumentDate, @ExpectedDate, @BranchId, @WarehouseId, @SupplierId,
         @CurrencyId, @RateType, @ExchangeRate, @MaxDiscountPercent, @SourceDocumentId, @Lines,
         @TypeId OUTPUT, @Direction OUTPUT, @Cur OUTPUT, @Rate OUTPUT;

    -- (63) ONE ITEM OR SEVERAL IS THE INVOICE'S OWN MODE: chosen when it is created (@OneItemOnly, NULL = the setting
    --      Purchase.OneItemPerInvoice) and kept by every later save. An invoice saved before script 63 has none: it
    --      follows the setting as it is now. Orders and returns have no mode.
    DECLARE @OneItem BIT = NULL;
    IF @DocumentTypeCode = N'PINV'
        SET @OneItem = COALESCE(CASE WHEN @Id IS NULL THEN @OneItemOnly
                                     ELSE (SELECT OneItemOnly FROM purchase.PurchaseDocuments WHERE Id = @Id) END,
                                configuration.fn_SettingBool(N'Purchase.OneItemPerInvoice'));

    -- (45) A supplier invoice holds ONE item: any number of lines, all of the same item. (63) When its mode says so.
    IF @OneItem = 1 AND (SELECT COUNT(DISTINCT ItemId) FROM @Lines) > 1
    BEGIN
        DECLARE @ItemCount INT = (SELECT COUNT(DISTINCT ItemId) FROM @Lines), @ItemCodes NVARCHAR(400);
        SELECT @ItemCodes = STRING_AGG(x.ItemCode, N', ') WITHIN GROUP (ORDER BY x.FirstLine)
        FROM (SELECT TOP (5) i.ItemCode, FirstLine = MIN(l.LineNumber)
              FROM @Lines l INNER JOIN inventory.Items i ON i.Id = l.ItemId
              GROUP BY l.ItemId, i.ItemCode
              ORDER BY MIN(l.LineNumber)) x;
        SET @ItemCodes = N'A supplier invoice holds one item. This one has ' + CAST(@ItemCount AS NVARCHAR(10)) + N': ' + @ItemCodes
                         + CASE WHEN @ItemCount > 5 THEN N'...' ELSE N'.' END + N' Create one invoice per item, or use Split by item.';
        THROW 65029, @ItemCodes, 1;
    END

    IF @Id IS NOT NULL
    BEGIN
        DECLARE @Status TINYINT = (SELECT Status FROM purchase.PurchaseDocuments WHERE Id = @Id);
        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @Status <> 1 THROW 65005, 'Only draft documents can be edited.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND DocumentTypeId <> @TypeId)
            THROW 65000, 'The document type cannot be changed.', 1;
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND ISNULL(SourceDocumentId, 0) <> ISNULL(@SourceDocumentId, 0))
            THROW 65000, 'The source document cannot be changed.', 1;
        -- (43) A container is unlinked from the Containers card of the invoice (usp_PurchaseInvoice_UnlinkContainer),
        --      never by saving the invoice without the lines that are on it.
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines pl
                   WHERE pl.DocumentId = @Id AND pl.ContainerLineId IS NOT NULL
                     AND NOT EXISTS (SELECT 1 FROM @LineContainers x WHERE x.ContainerLineId = pl.ContainerLineId))
        BEGIN
            IF @ReceiptMode = 1 THROW 65026, 'Unlink the containers before switching off Shipped in containers.', 1;
            THROW 65019, 'This invoice is linked to containers: keep their lines, or unlink a container from the Containers card of the invoice.', 1;
        END
    END

    -- Lines linked to containers (all of them, or (43) only some: the rest is linked later) point to a container line of
    -- the same order line and item, within what is loaded and not yet invoiced elsewhere. A linked line forces receipt
    -- mode 2 ("shipped in containers").
    IF EXISTS (SELECT 1 FROM @LineContainers)
    BEGIN
        IF @DocumentTypeCode <> N'PINV' THROW 65019, 'Only purchase invoices can be linked to containers.', 1;
        IF @SourceDocumentId IS NULL THROW 65019, 'An invoice from containers must refer to its purchase order.', 1;
        IF EXISTS (SELECT 1 FROM @LineContainers x WHERE NOT EXISTS (SELECT 1 FROM @Lines l WHERE l.LineNumber = x.LineNumber))
            THROW 65019, 'A container line is given for a line that does not exist.', 1;
        IF @Id IS NOT NULL AND EXISTS (SELECT 1 FROM purchase.PurchaseCharges WHERE DocumentKind = N'PINV' AND DocumentId = @Id)
            THROW 65020, 'This invoice has its own charges. Remove them: the charges of an import are entered on its containers.', 1;

        -- (65) A container received with a goods receipt can still be invoiced (the goods may arrive first): only a
        --      cancelled container, or one offloaded before goods receipts, is refused.
        DECLARE @CtMsg NVARCHAR(400);
        SELECT TOP (1) @CtMsg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' +
            CASE WHEN cl.Id IS NULL THEN N'the container line no longer exists.'
                 WHEN c.Status = 8 OR (c.Status IN (6, 7) AND rb.ReceivedBy = N'Offload')
                      THEN N'container ' + c.ContainerRef + N' is cancelled or was offloaded before goods receipts.'
                 WHEN cl.PurchaseOrderId <> @SourceDocumentId THEN N'the container line belongs to another purchase order.'
                 WHEN cl.ItemId <> l.ItemId THEN N'the item differs from the container line.'
                 ELSE N'the order line differs from the container line.' END
        FROM @Lines l
        INNER JOIN @LineContainers x          ON x.LineNumber = l.LineNumber
        LEFT  JOIN logistics.ContainerLines cl ON cl.Id = x.ContainerLineId
        LEFT  JOIN logistics.Containers c      ON c.Id = cl.ContainerId
        OUTER APPLY logistics.fn_Container_ReceivedBy(c.Id) rb
        WHERE cl.Id IS NULL OR c.Status = 8 OR (c.Status IN (6, 7) AND rb.ReceivedBy = N'Offload') OR cl.PurchaseOrderId <> @SourceDocumentId
           OR cl.ItemId <> l.ItemId OR ISNULL(l.SourceLineId, 0) <> cl.PoLineId
        ORDER BY l.LineNumber;
        IF @CtMsg IS NOT NULL THROW 65019, @CtMsg, 1;

        SELECT TOP (1) @CtMsg = N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                                + CAST(q.Here AS NVARCHAR(20)) + N' invoiced here + ' + CAST(ISNULL(o.Other, 0) AS NVARCHAR(20))
                                + N' in other invoices, but only ' + CAST(cl.QuantityBase AS NVARCHAR(20)) + N' are loaded.'
        FROM (SELECT x.ContainerLineId, Here = SUM(l.Quantity * iu.PackingFormula)
              FROM @Lines l
              INNER JOIN @LineContainers x      ON x.LineNumber = l.LineNumber
              INNER JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId
              GROUP BY x.ContainerLineId) q
        INNER JOIN logistics.ContainerLines cl ON cl.Id = q.ContainerLineId
        INNER JOIN logistics.Containers c      ON c.Id = cl.ContainerId
        INNER JOIN inventory.Items i           ON i.Id = cl.ItemId
        OUTER APPLY (SELECT Other = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                     INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                     WHERE pil.ContainerLineId = cl.Id AND pd.Status <> 3 AND (@Id IS NULL OR pd.Id <> @Id)) o
        WHERE q.Here + ISNULL(o.Other, 0) > cl.QuantityBase
        ORDER BY c.ContainerRef, cl.LineNumber;
        IF @CtMsg IS NOT NULL THROW 65019, @CtMsg, 1;

        IF @ReceiptMode = 1 THROW 65026, 'Unlink the containers before switching off Shipped in containers.', 1;
        SET @ReceiptMode = 2;
    END

    -- (43) "Shipped in containers" (receipt mode 2) is chosen on a purchase invoice: NULL = unchanged (1 on creation).
    DECLARE @EffectiveMode TINYINT = CASE WHEN @DocumentTypeCode <> N'PINV' THEN 1
                                          ELSE COALESCE(@ReceiptMode, (SELECT ReceiptMode FROM purchase.PurchaseDocuments WHERE Id = @Id), 1) END;
    DECLARE @ModeMsg NVARCHAR(400);
    IF @EffectiveMode = 2
    BEGIN
        -- the goods enter the stock at the offload of the containers they are linked to: lines of the order only
        IF @SourceDocumentId IS NULL THROW 65000, 'Only an invoice created from a purchase order can be shipped in containers.', 1;
        SELECT TOP (1) @ModeMsg = N'Line ' + CAST(LineNumber AS NVARCHAR(10)) + N': only lines of the purchase order can be shipped in containers.'
        FROM @Lines WHERE SourceLineId IS NULL ORDER BY LineNumber;
        IF @ModeMsg IS NOT NULL THROW 65000, @ModeMsg, 1;
    END
    ELSE IF @DocumentTypeCode = N'PINV' AND @SourceDocumentId IS NOT NULL
    BEGIN
        -- received on posting: what the containers of the order hold plus what is invoiced outside containers cannot
        -- exceed the order line, or the same goods would be received twice
        -- (65) Outside containers = MAX(invoiced outside containers, this invoice included; received outside containers +
        --      on draft goods receipts outside containers) - fn_PoLine_CommittedOutside, without this invoice. A maximum,
        --      not a sum: goods received from the order and the invoice that pays for them are the same pieces.
        SELECT TOP (1) @ModeMsg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): the containers of the order hold '
                                  + CAST(ct.Qty AS NVARCHAR(20)) + N' of the ' + CAST(pol.QuantityBase AS NVARCHAR(20))
                                  + N' ordered. Keep Shipped in containers on and link the invoice to them.'
        FROM (SELECT x.SourceLineId, Qty = SUM(x.Quantity * iu.PackingFormula), LineNumber = MIN(x.LineNumber)
              FROM @Lines x INNER JOIN inventory.ItemUnits iu ON iu.Id = x.ItemUnitId
              WHERE x.SourceLineId IS NOT NULL GROUP BY x.SourceLineId) l
        INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = l.SourceLineId
        INNER JOIN inventory.Items i                  ON i.Id = pol.ItemId
        CROSS APPLY (SELECT Qty = ISNULL(SUM(cl.QuantityBase), 0) FROM logistics.ContainerLines cl
                     INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                     WHERE cl.PoLineId = pol.Id AND c.Status <> 8) ct
        CROSS APPLY purchase.fn_PoLine_CommittedOutside(pol.Id, @Id) co
        CROSS APPLY (SELECT Qty = CASE WHEN l.Qty + co.InvoicedOutsideBase >= co.ReceivedOutsideBase + co.InDraftReceiptsOutsideBase
                                       THEN l.Qty + co.InvoicedOutsideBase
                                       ELSE co.ReceivedOutsideBase + co.InDraftReceiptsOutsideBase END) dir
        WHERE ct.Qty > 0 AND dir.Qty + ct.Qty > pol.QuantityBase
        ORDER BY l.LineNumber;
        IF @ModeMsg IS NOT NULL THROW 65026, @ModeMsg, 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Id IS NULL
        BEGIN
            DECLARE @Number NVARCHAR(30) = NULL;
            IF EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Id = @TypeId AND NumberOnPost = 0)
                EXEC inventory.usp_DocumentType_NextNumber @DocumentTypeCode, @Number OUTPUT, @BranchId;

            INSERT INTO purchase.PurchaseDocuments (DocumentTypeId, DocumentNumber, DocumentDate, ExpectedDate, BranchId, WarehouseId, SupplierId,
                                                    CurrencyId, RateType, ExchangeRate, SupplierReference, Notes, Status, SourceDocumentId,
                                                    ReceiptMode, ExporterReference, CommercialInvoiceNo, CreatedBy, OneItemOnly)
            VALUES (@TypeId, @Number, @DocumentDate, @ExpectedDate, @BranchId, @WarehouseId, @SupplierId,
                    @Cur, @RateType, @Rate, @SupplierReference, @Notes, 1, @SourceDocumentId,
                    ISNULL(@ReceiptMode, 1), @ExporterReference, @CommercialInvoiceNo, @UserId,
                    @OneItem);   -- (63) the mode of a new supplier invoice, stored once (NULL on orders and returns)
            SET @Id = SCOPE_IDENTITY();

            INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Created', ISNULL(N'Draft ' + @Number, N'Draft (number assigned on posting)')
                        + ISNULL(N' from ' + (SELECT DocumentNumber FROM purchase.PurchaseDocuments WHERE Id = @SourceDocumentId), N''), @UserId);
        END
        ELSE
        BEGIN
            UPDATE purchase.PurchaseDocuments
            SET DocumentDate = @DocumentDate, ExpectedDate = @ExpectedDate, BranchId = @BranchId, WarehouseId = @WarehouseId,
                SupplierId = @SupplierId, CurrencyId = @Cur, RateType = @RateType, ExchangeRate = @Rate,
                SupplierReference = @SupplierReference, Notes = @Notes,
                ReceiptMode = ISNULL(@ReceiptMode, ReceiptMode),
                ExporterReference = @ExporterReference, CommercialInvoiceNo = @CommercialInvoiceNo,
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;

            -- Lines are replaced: manual charge allocations pointing at the old lines are dropped (the charges stay).
            DELETE a FROM purchase.PurchaseChargeAllocations a
            INNER JOIN purchase.PurchaseCharges c ON c.Id = a.ChargeId
            WHERE c.DocumentKind = N'PINV' AND c.DocumentId = @Id;
            DELETE FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id;

            INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Updated', N'Header and ' + CAST((SELECT COUNT(*) FROM @Lines) AS NVARCHAR(10)) + N' line(s) saved', @UserId);
        END

        INSERT INTO purchase.PurchaseDocumentLines (DocumentId, LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, PackingFormula,
                                                    UnitPrice, DiscountPercent, UnitCostBase, FobCostBase, ImportRowNumber, Notes, SourceLineId)
        SELECT @Id, l.LineNumber, l.ItemId, l.ItemUnitId, l.WarehouseId, l.ExpiryDate, l.Quantity, iu.PackingFormula,
               ISNULL(l.UnitPrice, ROUND(ISNULL(i.LastCost, 0) * iu.PackingFormula * @Rate, 4)),
               ISNULL(l.DiscountPercent, 0),
               -- returns carry the LANDED cost (the container's for imports). (65) From an invoice that uses goods receipts,
               -- or is shipped in containers, the invoice line's OWN current cost: its landed cost, or for a container
               -- line its FOB + the container line's charges per piece received (the container line's FOB mixes the
               -- prices of every invoice and of the order). A line NOT linked to a container whose pieces are matched to
               -- goods received in containers (pass 2 of the matching) takes those containers' charges the same way, per
               -- matched piece; its pieces matched outside containers keep its landed cost. Worked out again when the
               -- return is posted.
               CASE WHEN @DocumentTypeCode = N'PRET' THEN
                    CASE WHEN sd.AffectsCost = 0 THEN COALESCE(rc.Unit, i.AverageCost)          -- (79)
                         WHEN sd.UsesGoodsReceipts = 1 OR sd.ReceiptMode = 2
                         THEN CASE WHEN scl.Id IS NOT NULL THEN src.FobCostBase + ISNULL(scl.ChargesBase / NULLIF(scl.ReceivedQuantityBase, 0), 0)
                                   WHEN mc.CtPcs > 0 THEN (mc.CtPcs * src.FobCostBase + mc.CtCharges + (mc.Pcs - mc.CtPcs) * src.UnitCostBase) / mc.Pcs
                                   ELSE src.UnitCostBase END
                         ELSE COALESCE(scl.LandedCostBase, src.UnitCostBase) END END,
               CASE WHEN @DocumentTypeCode = N'PRET' THEN
                    CASE WHEN sd.AffectsCost = 0 THEN rc.Fob                                       -- (79)
                         WHEN sd.UsesGoodsReceipts = 1 OR sd.ReceiptMode = 2 THEN src.FobCostBase
                         ELSE COALESCE(scl.FobCostBase, src.FobCostBase) END END,
               l.ImportRowNumber, NULLIF(LTRIM(RTRIM(l.Notes)), N''), l.SourceLineId
        FROM @Lines l
        INNER JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        LEFT  JOIN purchase.PurchaseDocumentLines src ON src.Id = l.SourceLineId
        LEFT  JOIN purchase.PurchaseDocuments sd      ON sd.Id = src.DocumentId     -- (65) the source invoice
        LEFT  JOIN logistics.ContainerLines scl       ON scl.Id = src.ContainerLineId
        -- (65) an unlinked invoice line: its matched pieces, those received in containers and their containers' charges
        OUTER APPLY (SELECT Pcs       = SUM(m.QuantityBase),
                            CtPcs     = SUM(CASE WHEN gl.ContainerLineId IS NOT NULL THEN m.QuantityBase ELSE 0 END),
                            CtCharges = SUM(CASE WHEN gl.ContainerLineId IS NOT NULL
                                                 THEN m.QuantityBase * ISNULL(mcl.ChargesBase / NULLIF(mcl.ReceivedQuantityBase, 0), 0)
                                                 ELSE 0 END)
                     FROM purchase.GoodsReceiptInvoiceMatches m
                     INNER JOIN purchase.GoodsReceiptLines gl ON gl.Id = m.GoodsReceiptLineId
                     LEFT  JOIN logistics.ContainerLines mcl  ON mcl.Id = gl.ContainerLineId
                     WHERE @DocumentTypeCode = N'PRET' AND m.InvoiceLineId = src.Id AND src.ContainerLineId IS NULL) mc
        -- (79) an invoice that does not change item costs: its goods are in stock at their receipt lines' cost (the order
        --      price, plus container charges), so they go back at the current cost of the receipt lines matched to it
        OUTER APPLY (SELECT Unit = SUM(m.QuantityBase * CASE WHEN gl.ContainerLineId IS NOT NULL THEN rcl.LandedCostBase ELSE gl.UnitCostBase END)
                                   / NULLIF(SUM(m.QuantityBase), 0),
                            Fob  = SUM(m.QuantityBase * CASE WHEN gl.ContainerLineId IS NOT NULL THEN rcl.FobCostBase ELSE gl.FobCostBase END)
                                   / NULLIF(SUM(m.QuantityBase), 0)
                     FROM purchase.GoodsReceiptInvoiceMatches m
                     INNER JOIN purchase.GoodsReceiptLines gl ON gl.Id = m.GoodsReceiptLineId
                     LEFT  JOIN logistics.ContainerLines rcl  ON rcl.Id = gl.ContainerLineId
                     WHERE @DocumentTypeCode = N'PRET' AND sd.AffectsCost = 0 AND m.InvoiceLineId = src.Id) rc;

        UPDATE pl SET ContainerLineId = x.ContainerLineId
        FROM purchase.PurchaseDocumentLines pl
        INNER JOIN @LineContainers x ON x.LineNumber = pl.LineNumber
        WHERE pl.DocumentId = @Id;

        UPDATE d
        SET TotalItems = x.Items, TotalQuantity = x.Qty, Subtotal = x.Sub, TotalAmount = x.Amt, TotalDiscount = x.Sub - x.Amt,
            TotalAmountBase = ROUND(x.Amt / @Rate, 2), TotalLandedCostBase = ROUND(x.Amt / @Rate, 2) + d.TotalChargesBase
        FROM purchase.PurchaseDocuments d
        CROSS APPLY (SELECT COUNT(*) AS Items, ISNULL(SUM(QuantityBase), 0) AS Qty,
                            ISNULL(SUM(CONVERT(DECIMAL(18,2), Quantity * UnitPrice)), 0) AS Sub, ISNULL(SUM(LineTotal), 0) AS Amt
                     FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id) x
        WHERE d.Id = @Id;

        -- the value basis of the container charges follows the invoice prices
        IF EXISTS (SELECT 1 FROM @LineContainers)
        BEGIN
            DECLARE @Cid INT;
            DECLARE cts CURSOR LOCAL FAST_FORWARD FOR
                SELECT DISTINCT cl.ContainerId FROM @LineContainers x INNER JOIN logistics.ContainerLines cl ON cl.Id = x.ContainerLineId;
            OPEN cts;
            FETCH NEXT FROM cts INTO @Cid;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC logistics.usp_Container_ReallocateCharges @Cid, 1, 1;
                FETCH NEXT FROM cts INTO @Cid;
            END
            CLOSE cts;
            DEALLOCATE cts;
        END

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 8. Posting an invoice: the type's two switches captured, and its goods received */

-- Re-created (79) from the body of script 77:
--   - a supplier invoice captures its type's AffectsItemCost and AffectsOnHand in the same UPDATE that posts it (before
--     the rematch and the true-up, which read AffectsCost through section 3);
--   - AffectsOnHand: once the invoice is committed, its goods are received as "Receive the goods now" does, without
--     the tick - the type's rule, whoever posts (no goods receipt right is needed: the rule is the type's); a receipt
--     that fails leaves the invoice posted, with the reason in @ReceiveWarning as before;
--   - a return from an invoice that does not change item costs goes out at the current cost of the matched receipt
--     lines (section 7);
--   - the answer's row says what the type made of it (ReceiveOnPost, AffectsCost).
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
    -- (79) what the type says when the invoice is posted, captured on it: its price becomes the cost of the goods received
    --      against it (AffectsItemCost), posting it receives its goods (AffectsOnHand)
    DECLARE @AffectsCost BIT = 1, @AutoReceive BIT = 0;

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
               @OneItemOnly = d.OneItemOnly,
               @AffectsCost = CASE WHEN dt.Code = N'PINV' THEN dt.AffectsItemCost ELSE 1 END,
               @AutoReceive = CASE WHEN dt.Code = N'PINV' THEN dt.AffectsOnHand ELSE 0 END
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
            -- (79) From an invoice that does not change item costs: the current cost of the receipt lines matched to the
            --      invoice line, what its goods are in stock at (usp_PurchaseDocument_Save); none -> the average, below.
            UPDATE l
            SET UnitCostBase = CASE WHEN sd.AffectsCost = 0 THEN rc.Unit
                                    WHEN scl.Id IS NOT NULL THEN src.FobCostBase + ISNULL(scl.ChargesBase / NULLIF(scl.ReceivedQuantityBase, 0), 0)
                                    WHEN mc.CtPcs > 0 THEN (mc.CtPcs * src.FobCostBase + mc.CtCharges + (mc.Pcs - mc.CtPcs) * src.UnitCostBase) / mc.Pcs
                                    ELSE src.UnitCostBase END,
                FobCostBase  = CASE WHEN sd.AffectsCost = 0 THEN rc.Fob ELSE src.FobCostBase END
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
            -- (79) an invoice that does not change item costs: its goods are in stock at their receipt lines' cost (the order
            --      price, plus container charges), so they go back at the current cost of the receipt lines matched to it
            OUTER APPLY (SELECT Unit = SUM(m.QuantityBase * CASE WHEN gl.ContainerLineId IS NOT NULL THEN rcl.LandedCostBase ELSE gl.UnitCostBase END)
                                       / NULLIF(SUM(m.QuantityBase), 0),
                                Fob  = SUM(m.QuantityBase * CASE WHEN gl.ContainerLineId IS NOT NULL THEN rcl.FobCostBase ELSE gl.FobCostBase END)
                                       / NULLIF(SUM(m.QuantityBase), 0)
                         FROM purchase.GoodsReceiptInvoiceMatches m
                         INNER JOIN purchase.GoodsReceiptLines gl ON gl.Id = m.GoodsReceiptLineId
                         LEFT  JOIN logistics.ContainerLines rcl  ON rcl.Id = gl.ContainerLineId
                         WHERE sd.AffectsCost = 0 AND m.InvoiceLineId = src.Id) rc
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
            -- (79) captured from the type now, before the rematch below reads AffectsCost: changing the type later never
            --      re-prices or re-receives this invoice
            AffectsCost       = CASE WHEN @TypeCode = N'PINV' THEN @AffectsCost ELSE AffectsCost END,
            ReceiveOnPost     = CASE WHEN @TypeCode = N'PINV' THEN @AutoReceive ELSE ReceiveOnPost END,
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
                                + CASE WHEN @TypeCode = N'PINV' AND @AffectsCost = 0 THEN N'; does not change item costs' ELSE N'' END   -- (79)
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
                   CostAdjustedCogsBase = @CostCogs, CostAdjustedLines = @CostLines,
                   ReceiveOnPost = @AutoReceive, AffectsCost = @AffectsCost;      -- (79) what the type made of it
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
    /* (79) THE TYPE'S RULE (Affects on-hand): the same receipt, whoever posts and however (the page, Post selected, an
       import that posts) - for an invoice not shipped in containers with something to receive; otherwise there is
       nothing for it to do, and it says nothing (its container lines are received with their containers). A tick of
       "Receive the goods now" keeps its own answer, a refusal included. */
    DECLARE @Receive BIT = CASE WHEN ISNULL(@ReceiveNow, 0) = 1 AND @TypeCode = N'PINV' THEN 1 ELSE 0 END;
    IF @Receive = 0 AND @AutoReceive = 1 AND @TypeCode = N'PINV' AND ISNULL(@ReceiptMode, 1) <> 2
       AND EXISTS (SELECT 1 FROM purchase.fn_InvoiceLine_ToReceive(@Id) t WHERE t.ToReceiveBase > 0)
        SET @Receive = 1;

    IF @Receive = 1
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

/* ================================================================== 9. The invoice page reads them */

-- Re-created (79) from the body of script 77: + AffectsCost and ReceiveOnPost on the header. Nothing else changes.
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
           GoodsReceiptsSinceUtc = (SELECT TOP (1) s.SwitchedAtUtc FROM purchase.GoodsReceiptSwitch s),
           -- (79) a supplier invoice: its price becomes the cost of the goods received against it (AffectsCost), posting it
           --      receives its goods (ReceiveOnPost) - what it captured when posted, the type's switch while a draft;
           --      1 / 0 on orders and returns, not concerned
           AffectsCost   = CAST(CASE WHEN dt.Code <> N'PINV' THEN 1 WHEN d.Status = 1 THEN dt.AffectsItemCost ELSE d.AffectsCost END AS BIT),
           ReceiveOnPost = CAST(CASE WHEN dt.Code <> N'PINV' THEN 0 WHEN d.Status = 1 THEN dt.AffectsOnHand ELSE d.ReceiveOnPost END AS BIT)
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

/* ================================================================== 10. The post confirmation's estimate */

-- Re-created (79) from the body of script 78: when the PINV type does not change item costs, the received pieces keep
-- their cost (no difference, no estimate), and each row says so (AffectsCost).
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseInvoice_ReceiptCostPreview
    @InvoiceId INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Status TINYINT, @Rate DECIMAL(18,6), @SupplierId INT, @Code NVARCHAR(20), @Affects BIT;
    -- (79) a draft follows its type: AffectsItemCost as it is now is what the posting will capture
    SELECT @Status = d.Status, @Rate = d.ExchangeRate, @SupplierId = d.SupplierId, @Code = dt.Code, @Affects = dt.AffectsItemCost
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    WHERE d.Id = @InvoiceId;
    IF @Status IS NULL OR @Code <> N'PINV' THROW 65006, 'Purchase invoice not found.', 1;

    -- the draft's own charges per line: as allocated, else shared by value (an estimate until it is posted)
    DECLARE @ChargesTotal DECIMAL(18,2) = ISNULL((SELECT SUM(AmountBase) FROM purchase.PurchaseCharges
                                                  WHERE DocumentKind = N'PINV' AND DocumentId = @InvoiceId AND IncludeInLandedCost = 1), 0);
    DECLARE @HasAllocations BIT = CASE WHEN EXISTS (SELECT 1 FROM purchase.PurchaseChargeAllocations x
                                                    INNER JOIN purchase.PurchaseCharges c ON c.Id = x.ChargeId
                                                    WHERE c.DocumentKind = N'PINV' AND c.DocumentId = @InvoiceId AND c.IncludeInLandedCost = 1)
                                       THEN 1 ELSE 0 END;
    DECLARE @ValueTotal DECIMAL(18,6) = (SELECT SUM(LineTotal / @Rate) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId);

    DECLARE @L TABLE (LineId INT NOT NULL PRIMARY KEY, LineNumber INT NOT NULL, ItemId INT NOT NULL, GroupKey NVARCHAR(40) NOT NULL,
                      ContainerLineId INT NULL, QuantityBase INT NOT NULL, FobBase DECIMAL(18,6) NOT NULL, ChargesBase DECIMAL(18,6) NOT NULL,
                      Rem INT NOT NULL);
    INSERT INTO @L (LineId, LineNumber, ItemId, GroupKey, ContainerLineId, QuantityBase, FobBase, ChargesBase, Rem)
    SELECT l.Id, l.LineNumber, l.ItemId,
           CASE WHEN l.SourceLineId IS NOT NULL THEN N'P' + CAST(l.SourceLineId AS NVARCHAR(12))
                ELSE N'S' + CAST(@SupplierId AS NVARCHAR(12)) + N'.' + CAST(l.ItemId AS NVARCHAR(12)) END,
           l.ContainerLineId, l.QuantityBase,
           CAST(l.LineTotal / @Rate / l.QuantityBase AS DECIMAL(18,6)),
           CAST(CASE WHEN @HasAllocations = 1
                     THEN ISNULL((SELECT SUM(x.AmountBase) FROM purchase.PurchaseChargeAllocations x
                                  INNER JOIN purchase.PurchaseCharges c ON c.Id = x.ChargeId
                                  WHERE x.PurchaseLineId = l.Id AND c.DocumentKind = N'PINV' AND c.DocumentId = @InvoiceId
                                    AND c.IncludeInLandedCost = 1), 0)
                     WHEN @ValueTotal > 0 THEN @ChargesTotal * (l.LineTotal / @Rate) / @ValueTotal
                     ELSE 0 END / l.QuantityBase AS DECIMAL(18,6)),
           -- a line of a container offloaded before goods receipts takes nothing: its goods are received already
           CASE WHEN rb.ReceivedBy = N'Offload' THEN 0 ELSE l.QuantityBase END
    FROM purchase.PurchaseDocumentLines l
    LEFT JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
    OUTER APPLY logistics.fn_Container_ReceivedBy(cl.ContainerId) rb
    WHERE l.DocumentId = @InvoiceId AND @Status = 1;

    -- received pieces of those groups not matched to an invoice yet, with what they cost now
    DECLARE @U TABLE (LineId INT NOT NULL PRIMARY KEY, GoodsReceiptId INT NOT NULL, GroupKey NVARCHAR(40) NOT NULL, ContainerLineId INT NULL,
                      ItemId INT NOT NULL, T DATETIME2(3) NOT NULL, Rem INT NOT NULL, IsContainer BIT NOT NULL,
                      BaseFob DECIMAL(18,6) NOT NULL, BaseCharges DECIMAL(18,6) NOT NULL, ContainerCharges DECIMAL(18,6) NOT NULL,
                      RNet DECIMAL(18,6) NOT NULL);
    INSERT INTO @U (LineId, GoodsReceiptId, GroupKey, ContainerLineId, ItemId, T, Rem, IsContainer, BaseFob, BaseCharges, ContainerCharges, RNet)
    SELECT t.GoodsReceiptLineId, t.GoodsReceiptId,
           CASE WHEN t.PoLineId IS NOT NULL THEN N'P' + CAST(t.PoLineId AS NVARCHAR(12))
                ELSE N'S' + CAST(t.SupplierId AS NVARCHAR(12)) + N'.' + CAST(t.ItemId AS NVARCHAR(12)) END,
           t.ContainerLineId, t.ItemId, ISNULL(g.PostedAtUtc, g.CreatedAtUtc), t.ReceivedBase - t.MatchedBase, t.IsContainerLine,
           t.BaseFobBase, t.BaseChargesBase, CASE WHEN t.IsContainerLine = 1 THEN t.TargetChargesBase ELSE 0 END, t.NetReceivedBase
    FROM (SELECT DISTINCT gl.GoodsReceiptId
          FROM purchase.GoodsReceiptLines gl
          INNER JOIN purchase.GoodsReceipts gr ON gr.Id = gl.GoodsReceiptId AND gr.Status = 2
          WHERE gl.PoLineId IN (SELECT l.SourceLineId FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = @InvoiceId)
             OR (gl.PoLineId IS NULL AND gl.SupplierId = @SupplierId
                 AND gl.ItemId IN (SELECT l.ItemId FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = @InvoiceId AND l.SourceLineId IS NULL))) r
    CROSS APPLY purchase.fn_GoodsReceiptLine_TargetCost(r.GoodsReceiptId) t
    INNER JOIN purchase.GoodsReceipts g ON g.Id = t.GoodsReceiptId
    WHERE t.ReceivedBase > t.MatchedBase;

    DELETE FROM @U WHERE GroupKey NOT IN (SELECT GroupKey FROM @L);

    -- first in first out, as the rematch would: the container line first, then the group
    DECLARE @Take TABLE (ULineId INT NOT NULL, LLineId INT NOT NULL, Qty INT NOT NULL);
    DECLARE @Pass TABLE (ULineId INT NOT NULL, LLineId INT NOT NULL, Qty INT NOT NULL);

    WITH u AS (SELECT LineId, K = ContainerLineId, Rem,
                      E = SUM(Rem) OVER (PARTITION BY ContainerLineId ORDER BY T, LineId ROWS UNBOUNDED PRECEDING)
               FROM @U WHERE Rem > 0 AND ContainerLineId IS NOT NULL),
         l AS (SELECT LineId, K = ContainerLineId, Rem,
                      E = SUM(Rem) OVER (PARTITION BY ContainerLineId ORDER BY LineNumber ROWS UNBOUNDED PRECEDING)
               FROM @L WHERE Rem > 0 AND ContainerLineId IS NOT NULL)
    INSERT INTO @Pass (ULineId, LLineId, Qty)
    SELECT u.LineId, l.LineId,
           (CASE WHEN u.E < l.E THEN u.E ELSE l.E END) - (CASE WHEN u.E - u.Rem > l.E - l.Rem THEN u.E - u.Rem ELSE l.E - l.Rem END)
    FROM u INNER JOIN l ON l.K = u.K
    WHERE u.E - u.Rem < l.E AND l.E - l.Rem < u.E;

    UPDATE u SET Rem = u.Rem - p.Qty FROM @U u INNER JOIN (SELECT ULineId, Qty = SUM(Qty) FROM @Pass GROUP BY ULineId) p ON p.ULineId = u.LineId;
    UPDATE l SET Rem = l.Rem - p.Qty FROM @L l INNER JOIN (SELECT LLineId, Qty = SUM(Qty) FROM @Pass GROUP BY LLineId) p ON p.LLineId = l.LineId;
    INSERT INTO @Take (ULineId, LLineId, Qty) SELECT ULineId, LLineId, Qty FROM @Pass;
    DELETE FROM @Pass;

    WITH u AS (SELECT LineId, K = GroupKey, Rem,
                      E = SUM(Rem) OVER (PARTITION BY GroupKey ORDER BY T, LineId ROWS UNBOUNDED PRECEDING)
               FROM @U WHERE Rem > 0),
         l AS (SELECT LineId, K = GroupKey, Rem,
                      E = SUM(Rem) OVER (PARTITION BY GroupKey ORDER BY LineNumber ROWS UNBOUNDED PRECEDING)
               FROM @L WHERE Rem > 0)
    INSERT INTO @Take (ULineId, LLineId, Qty)
    SELECT u.LineId, l.LineId,
           (CASE WHEN u.E < l.E THEN u.E ELSE l.E END) - (CASE WHEN u.E - u.Rem > l.E - l.Rem THEN u.E - u.Rem ELSE l.E - l.Rem END)
    FROM u INNER JOIN l ON l.K = u.K
    WHERE u.E - u.Rem < l.E AND l.E - l.Rem < u.E;

    -- per piece taken: now = its base cost (+ its container's charges); with the invoice = the invoice FOB + the invoice's
    -- own charges (+ the same container charges for container pieces: fn_GoodsReceiptLine_TargetCost)
    DECLARE @T TABLE (LLineId INT NOT NULL, ULineId INT NOT NULL, ItemId INT NOT NULL, Qty INT NOT NULL,
                      CostNow DECIMAL(18,6) NOT NULL, CostNew DECIMAL(18,6) NOT NULL, PRIMARY KEY (LLineId, ULineId));
    INSERT INTO @T (LLineId, ULineId, ItemId, Qty, CostNow, CostNew)
    SELECT k.LLineId, k.ULineId, u.ItemId, SUM(k.Qty),
           MAX(CASE WHEN u.IsContainer = 1 THEN u.BaseFob + u.ContainerCharges ELSE u.BaseFob + u.BaseCharges END),
           MAX(CASE WHEN u.IsContainer = 1 THEN l.FobBase + l.ChargesBase + u.ContainerCharges ELSE l.FobBase + l.ChargesBase END)
    FROM @Take k
    INNER JOIN @U u ON u.LineId = k.ULineId
    INNER JOIN @L l ON l.LineId = k.LLineId
    GROUP BY k.LLineId, k.ULineId, u.ItemId;

    -- (79) an invoice that does not change item costs leaves the received pieces at their cost: no difference
    IF @Affects = 0 UPDATE @T SET CostNew = CostNow;

    -- the stock share per item, on today's company stock, over the receipt lines involved (as the true-up)
    DECLARE @Items TABLE (ItemId INT NOT NULL PRIMARY KEY, NetReceived DECIMAL(18,6) NOT NULL, OnHand DECIMAL(18,6) NOT NULL, Ratio DECIMAL(18,10) NOT NULL);
    INSERT INTO @Items (ItemId, NetReceived, OnHand, Ratio)
    SELECT x.ItemId, x.NetReceived, oh.Q,
           CASE WHEN oh.Q <= 0 OR x.NetReceived <= 0 THEN 0 WHEN oh.Q < x.NetReceived THEN oh.Q / x.NetReceived ELSE 1 END
    FROM (SELECT u.ItemId, NetReceived = SUM(CASE WHEN u.RNet > 0 THEN u.RNet ELSE 0 END)
          FROM @U u WHERE u.LineId IN (SELECT ULineId FROM @T) GROUP BY u.ItemId) x
    CROSS APPLY (SELECT Q = CAST(inventory.fn_StockOnHand(x.ItemId, NULL) AS DECIMAL(18,6))) oh;

    SELECT InvoiceLineId           = l.Id,
           l.LineNumber, l.ItemId, i.ItemCode, i.ItemName,
           InvoicedBase            = l.QuantityBase,
           ReceivedNotInvoicedBase = ISNULL(x.Qty, 0),
           CurrentCostBase         = CAST(x.Now / NULLIF(x.Qty, 0) AS DECIMAL(18,6)),
           InvoiceCostBase         = CAST(x.New / NULLIF(x.Qty, 0) AS DECIMAL(18,6)),
           DifferenceBase          = CAST(ISNULL(x.Diff, 0) AS DECIMAL(18,2)),
           EstimatedInventoryBase  = CAST(ROUND(ISNULL(x.Diff, 0) * ISNULL(it.Ratio, 0), 2) AS DECIMAL(18,2)),
           EstimatedCogsBase       = CAST(ISNULL(x.Diff, 0) - ROUND(ISNULL(x.Diff, 0) * ISNULL(it.Ratio, 0), 2) AS DECIMAL(18,2)),
           CompanyOnHandBase       = CAST(inventory.fn_StockOnHand(l.ItemId, NULL) AS INT),
           Receipts                = x.Receipts,
           IsEstimate              = CAST(1 AS BIT),
           AffectsCost             = @Affects      -- (79)
    FROM purchase.PurchaseDocumentLines l
    INNER JOIN inventory.Items i ON i.Id = l.ItemId
    OUTER APPLY (SELECT Qty  = SUM(t.Qty),
                        Now  = SUM(t.Qty * t.CostNow),
                        New  = SUM(t.Qty * t.CostNew),
                        Diff = SUM(ROUND((t.CostNew - t.CostNow) * t.Qty, 2)),
                        -- (78) at most 10 numbers, else the first 5 and "+N more" (NVARCHAR(MAX): 9829 above about 210)
                        Receipts = (SELECT CAST(STRING_AGG(CASE WHEN z.N <= 10 OR z.Rn <= 5 THEN CAST(z.DocumentNumber AS NVARCHAR(MAX)) END, N', ')
                                                    WITHIN GROUP (ORDER BY z.DocumentNumber)
                                                + CASE WHEN MAX(z.N) > 10 THEN N' +' + CAST(MAX(z.N) - 5 AS NVARCHAR(10)) + N' more' ELSE N'' END
                                                AS NVARCHAR(400))
                                    FROM (SELECT y.DocumentNumber, Rn = ROW_NUMBER() OVER (ORDER BY y.DocumentNumber), N = COUNT(*) OVER ()
                                          FROM (SELECT DISTINCT g.DocumentNumber FROM @T t2
                                                INNER JOIN @U u2 ON u2.LineId = t2.ULineId
                                                INNER JOIN purchase.GoodsReceipts g ON g.Id = u2.GoodsReceiptId
                                                WHERE t2.LLineId = l.Id) y) z)
                 FROM @T t WHERE t.LLineId = l.Id) x
    LEFT JOIN @Items it ON it.ItemId = l.ItemId
    WHERE l.DocumentId = @InvoiceId AND @Status = 1
    ORDER BY l.LineNumber;
END
GO

/* ================================================================== 11. Landed cost adjustments: refused on an invoice that does not change item costs */

-- Re-created (79) from the body of script 65: + 67013 after 67012.
CREATE OR ALTER PROCEDURE purchase.usp_LandedCostAdjustment_Save
    @Id                INT            = NULL,
    @SourceInvoiceId   INT,
    @DocumentDate      DATE,
    @Notes             NVARCHAR(1000) = NULL,
    @Charges           purchase.tvp_PurchaseCharge READONLY,
    @ManualAllocations purchase.tvp_ManualAllocation READONLY,
    @RowVersion        BINARY(8)      = NULL,
    @UserId            INT            = NULL,
    @NewId             INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    IF @DocumentDate IS NULL THROW 67000, 'Date is required.', 1;
    IF @DocumentDate > CAST(SYSUTCDATETIME() AS DATE) THROW 67000, 'Date cannot be in the future.', 1;

    DECLARE @InvStatus TINYINT, @InvType NVARCHAR(20), @BranchId INT, @BaseCurrency INT = (SELECT TOP (1) Id FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1);
    SELECT @InvStatus = d.Status, @InvType = dt.Code, @BranchId = d.BranchId
    FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId WHERE d.Id = @SourceInvoiceId;
    IF @InvStatus IS NULL THROW 67011, 'Purchase invoice not found.', 1;
    IF @InvType <> N'PINV' OR @InvStatus <> 2 THROW 67011, 'Landed cost adjustments apply to POSTED purchase invoices only.', 1;
    -- (65) + "Shipped in containers" (ReceiptMode 2), linked or not
    IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @SourceInvoiceId AND ReceiptMode = 2)
       OR EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines WHERE DocumentId = @SourceInvoiceId AND ContainerLineId IS NOT NULL)
        THROW 67012, 'This invoice comes from containers: late charges are entered on the containers (Container Charges), not as a landed cost adjustment.', 1;
    -- (79) an invoice that does not change item costs: an adjustment on it would change no cost
    IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @SourceInvoiceId AND AffectsCost = 0)
        THROW 67013, 'This invoice does not change item costs (its document type was set so when it was posted): a landed cost adjustment on it would change no cost. Container charges still enter the cost of goods received in containers.', 1;
    IF NOT EXISTS (SELECT 1 FROM @Charges) THROW 67000, 'At least one charge is required.', 1;

    IF @Id IS NOT NULL
    BEGIN
        DECLARE @Status TINYINT = (SELECT Status FROM purchase.LandedCostAdjustments WHERE Id = @Id);
        IF @Status IS NULL THROW 67006, 'Adjustment not found.', 1;
        IF @Status <> 1 THROW 67005, 'Only draft adjustments can be edited.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.LandedCostAdjustments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 67004, 'This adjustment was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM purchase.LandedCostAdjustments WHERE Id = @Id AND SourceInvoiceId <> @SourceInvoiceId)
            THROW 67000, 'The invoice of an adjustment cannot be changed.', 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;
        IF @Id IS NULL
        BEGIN
            DECLARE @Number NVARCHAR(30), @TypeId INT = (SELECT Id FROM inventory.DocumentTypes WHERE Code = N'LCA');
            EXEC inventory.usp_DocumentType_NextNumber N'LCA', @Number OUTPUT, @BranchId;
            INSERT INTO purchase.LandedCostAdjustments (DocumentTypeId, DocumentNumber, DocumentDate, BranchId, SourceInvoiceId, Notes, Status, CreatedBy)
            VALUES (@TypeId, @Number, @DocumentDate, @BranchId, @SourceInvoiceId, @Notes, 1, @UserId);
            SET @Id = SCOPE_IDENTITY();
        END
        ELSE
            UPDATE purchase.LandedCostAdjustments SET DocumentDate = @DocumentDate, Notes = @Notes, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;

        EXEC purchase.usp_PurchaseCharges_Write N'LCA', @Id, @DocumentDate, @BaseCurrency, @SourceInvoiceId, @Charges, @ManualAllocations, @UserId;

        UPDATE a SET TotalChargesBase = ISNULL((SELECT SUM(AmountBase) FROM purchase.PurchaseCharges WHERE DocumentKind = N'LCA' AND DocumentId = @Id AND IncludeInLandedCost = 1), 0)
        FROM purchase.LandedCostAdjustments a WHERE a.Id = @Id;

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Re-created (79) from the body of script 65: + 67013 after 67012, for a draft saved before (an adjustment cancelled
-- afterwards keeps its cancel: it was posted on an invoice that changed item costs).
CREATE OR ALTER PROCEDURE purchase.usp_LandedCostAdjustment_Post
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- (65) lock order: the goods receipt matcher first, then rows - the true-up below reads the receipts of the
        --      invoice's groups, which a goods receipt or an invoice being posted writes
        EXEC purchase.usp_GoodsReceipt_LockMatching;

        DECLARE @Status TINYINT, @InvoiceId INT, @Number NVARCHAR(30), @Date DATE, @BranchId INT;
        SELECT @Status = Status, @InvoiceId = SourceInvoiceId, @Number = DocumentNumber, @Date = DocumentDate, @BranchId = BranchId
        FROM purchase.LandedCostAdjustments WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NULL THROW 67006, 'Adjustment not found.', 1;
        IF @Status <> 1 THROW 67010, 'Only draft adjustments can be posted.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.LandedCostAdjustments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 67004, 'This adjustment was modified by another user. Reload the page and try again.', 1;
        IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @InvoiceId AND Status = 2)
            THROW 67011, 'The purchase invoice is no longer posted.', 1;
        -- (65) an imported invoice, linked to containers or "Shipped in containers" (ReceiptMode 2): as Save refuses it
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @InvoiceId AND ReceiptMode = 2)
           OR EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId AND ContainerLineId IS NOT NULL)
            THROW 67012, 'This invoice comes from containers: late charges are entered on the containers (Container Charges), not as a landed cost adjustment.', 1;
        -- (79) an invoice that does not change item costs: an adjustment on it would change no cost
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @InvoiceId AND AffectsCost = 0)
            THROW 67013, 'This invoice does not change item costs (its document type was set so when it was posted): a landed cost adjustment on it would change no cost. Container charges still enter the cost of goods received in containers.', 1;

        -- (65) an invoice whose goods come with goods receipts: the cost moves through the receipts
        DECLARE @UsesGoodsReceipts BIT =
            ISNULL((SELECT CAST(CASE WHEN dt.Code = N'PINV' AND d.UsesGoodsReceipts = 1 THEN 1 ELSE 0 END AS BIT)
                    FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                    WHERE d.Id = @InvoiceId), 0);

        EXEC purchase.usp_PurchaseCharges_Allocate N'LCA', @Id, @InvoiceId;

        DECLARE @Rate DECIMAL(18,6) = (SELECT ExchangeRate FROM purchase.PurchaseDocuments WHERE Id = @InvoiceId);

        DELETE FROM purchase.LandedCostAdjustmentLines WHERE AdjustmentId = @Id;
        INSERT INTO purchase.LandedCostAdjustmentLines (AdjustmentId, PurchaseLineId, ItemId, WarehouseId, ReceivedBase, NetReceivedBase, RemainingBase,
                                                        AllocatedBase, ExtraPerBaseUnit, InventoryPortionBase, CogsPortionBase, LandedCostBefore, LandedCostAfter)
        SELECT @Id, l.Id, l.ItemId, l.WarehouseId, l.QuantityBase, n.NetReceived, r.Remaining,
               a.Allocated, a.Allocated / l.QuantityBase,
               InvPortion = ROUND(a.Allocated / l.QuantityBase * r.Remaining, 2),
               CogsPortion = a.Allocated - ROUND(a.Allocated / l.QuantityBase * r.Remaining, 2),
               l.UnitCostBase,
               ((l.LineTotal / @Rate) + l.AllocatedChargesBase + a.Allocated) / l.QuantityBase
        FROM purchase.PurchaseDocumentLines l
        CROSS APPLY (SELECT Allocated = ISNULL((SELECT SUM(x.AmountBase) FROM purchase.PurchaseChargeAllocations x
                                                 INNER JOIN purchase.PurchaseCharges c ON c.Id = x.ChargeId
                                                 WHERE x.PurchaseLineId = l.Id AND c.DocumentKind = N'LCA' AND c.DocumentId = @Id AND c.IncludeInLandedCost = 1), 0)) a
        CROSS APPLY (SELECT NetReceived = l.QuantityBase - l.ReturnedQuantityBase) n
        CROSS APPLY (SELECT Remaining = CASE WHEN inventory.fn_StockOnHand(l.ItemId, l.WarehouseId) < n.NetReceived
                                             THEN CASE WHEN inventory.fn_StockOnHand(l.ItemId, l.WarehouseId) > 0 THEN inventory.fn_StockOnHand(l.ItemId, l.WarehouseId) ELSE 0 END
                                             ELSE n.NetReceived END) r
        WHERE l.DocumentId = @InvoiceId AND a.Allocated <> 0;

        -- Items with no stock at all: everything goes to COGS. (65) Older invoices only.
        UPDATE x SET CogsPortionBase = x.CogsPortionBase + x.InventoryPortionBase, InventoryPortionBase = 0
        FROM purchase.LandedCostAdjustmentLines x
        WHERE x.AdjustmentId = @Id AND inventory.fn_StockOnHand(x.ItemId, NULL) <= 0 AND @UsesGoodsReceipts = 0;

        -- Inventory value -> moving average (company-wide: value added / total on hand of the item). (65) Older invoices only.
        UPDATE i SET AverageCost = i.AverageCost + p.Inv / inventory.fn_StockOnHand(i.Id, NULL)
        FROM inventory.Items i
        INNER JOIN (SELECT ItemId, Inv = SUM(InventoryPortionBase) FROM purchase.LandedCostAdjustmentLines WHERE AdjustmentId = @Id GROUP BY ItemId) p ON p.ItemId = i.Id
        WHERE p.Inv <> 0 AND inventory.fn_StockOnHand(i.Id, NULL) > 0 AND @UsesGoodsReceipts = 0;

        -- Invoice lines / header carry the new landed cost.
        UPDATE l SET AllocatedChargesBase = l.AllocatedChargesBase + x.AllocatedBase, UnitCostBase = x.LandedCostAfter
        FROM purchase.PurchaseDocumentLines l INNER JOIN purchase.LandedCostAdjustmentLines x ON x.PurchaseLineId = l.Id
        WHERE x.AdjustmentId = @Id;
        UPDATE d SET TotalChargesBase = ISNULL(x.Charges, 0), TotalLandedCostBase = d.TotalAmountBase + ISNULL(x.Charges, 0)
        FROM purchase.PurchaseDocuments d
        CROSS APPLY (SELECT SUM(AllocatedChargesBase) AS Charges FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId) x
        WHERE d.Id = @InvoiceId;

        -- Value ledger. (65) Older invoices only.
        INSERT INTO inventory.CostAdjustments (AdjustmentDate, ItemId, WarehouseId, BranchId, Kind, AmountBase, SourceKind, SourceId, SourceNumber, PurchaseLineId, CreatedBy)
        SELECT DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@Date AS DATETIME2(3))),
               x.ItemId, x.WarehouseId, @BranchId, k.Kind, k.Amount, N'LCA', @Id, @Number, x.PurchaseLineId, @UserId
        FROM purchase.LandedCostAdjustmentLines x
        CROSS APPLY (VALUES (N'Inventory', x.InventoryPortionBase), (N'COGS', x.CogsPortionBase)) k (Kind, Amount)
        WHERE x.AdjustmentId = @Id AND k.Amount <> 0 AND @UsesGoodsReceipts = 0;

        -- (65) Older invoices: the ITEM COSTS REPLAYED from the ledger (usp_Item_RebuildCosts, as Cancel does) - the
        --      average with the rows just written, and the last cost, FOB cost and last supplier by the switch's rule: the
        --      latest RECEIPT, a goods receipt included. (Was: the last cost set to this invoice's when it is the item's
        --      latest posted invoice - since the switch that overwrote the cost of goods received later and left the FOB
        --      cost of another purchase beside it, or kept a stale one.) An invoice that uses goods receipts: the true-up
        --      below replays the items it adjusts.
        IF @UsesGoodsReceipts = 0
        BEGIN
            DECLARE @ItemId INT;
            DECLARE items CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT ItemId FROM purchase.LandedCostAdjustmentLines WHERE AdjustmentId = @Id;
            OPEN items; FETCH NEXT FROM items INTO @ItemId;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC inventory.usp_Item_RebuildCosts @ItemId;
                FETCH NEXT FROM items INTO @ItemId;
            END
            CLOSE items; DEALLOCATE items;
        END

        -- (65) AN INVOICE THAT USES GOODS RECEIPTS: the goods received against its adjusted lines are brought to their new
        --      cost (the invoice lines carry it now), and what that did is kept on the adjustment's lines.
        DECLARE @AdjAmount DECIMAL(18,2) = 0, @AdjInventory DECIMAL(18,2) = 0, @AdjCogs DECIMAL(18,2) = 0, @AdjLines INT = 0;
        IF @UsesGoodsReceipts = 1
        BEGIN
            DECLARE @ReceiptLines logistics.tvp_IdList;
            INSERT INTO @ReceiptLines (Id)
            SELECT DISTINCT m.GoodsReceiptLineId
            FROM purchase.GoodsReceiptInvoiceMatches m
            INNER JOIN purchase.LandedCostAdjustmentLines x ON x.PurchaseLineId = m.InvoiceLineId AND x.AdjustmentId = @Id;

            EXEC purchase.usp_GoodsReceipt_TrueUpCost @ReceiptLines, N'LCA', @Id, @Number, @UserId,
                 @AdjAmount OUTPUT, @AdjInventory OUTPUT, @AdjCogs OUTPUT, @AdjLines OUTPUT;

            -- Each receipt line's change is shared over the adjustment lines it is matched to, by matched pieces x what the
            -- adjustment adds per piece of each line (one invoice line per receipt line in practice); its in-stock pieces
            -- by matched pieces. The cents lost by rounding go to the line with the largest allocation.
            DECLARE @Share TABLE (PurchaseLineId INT NOT NULL PRIMARY KEY, Matched INT NOT NULL, InStock DECIMAL(18,6) NOT NULL,
                                  Inv DECIMAL(18,2) NOT NULL, Cogs DECIMAL(18,2) NOT NULL);
            WITH w AS (SELECT x.PurchaseLineId, m.GoodsReceiptLineId, Qty = m.QuantityBase,
                              Wt = CAST(m.QuantityBase AS DECIMAL(38,10)) * ABS(x.ExtraPerBaseUnit)
                       FROM purchase.LandedCostAdjustmentLines x
                       INNER JOIN purchase.GoodsReceiptInvoiceMatches m ON m.InvoiceLineId = x.PurchaseLineId
                       WHERE x.AdjustmentId = @Id),
                 t AS (SELECT GoodsReceiptLineId, WSum = SUM(Wt), QSum = SUM(Qty) FROM w GROUP BY GoodsReceiptLineId),
                 c AS (SELECT GoodsReceiptLineId, InStock = SUM(InStockBase), Inv = SUM(InventoryBase), Cogs = SUM(CogsBase)
                       FROM purchase.GoodsReceiptCostChanges
                       WHERE CauseKind = N'LCA' AND CauseId = @Id
                       GROUP BY GoodsReceiptLineId)
            INSERT INTO @Share (PurchaseLineId, Matched, InStock, Inv, Cogs)
            SELECT w.PurchaseLineId, SUM(w.Qty),
                   ISNULL(SUM(c.InStock * w.Qty / t.QSum), 0),
                   ROUND(ISNULL(SUM(c.Inv * f.F), 0), 2),
                   ROUND(ISNULL(SUM(c.Cogs * f.F), 0), 2)
            FROM w
            INNER JOIN t ON t.GoodsReceiptLineId = w.GoodsReceiptLineId
            LEFT  JOIN c ON c.GoodsReceiptLineId = w.GoodsReceiptLineId
            CROSS APPLY (SELECT F = CASE WHEN t.WSum > 0 THEN w.Wt / t.WSum ELSE CAST(w.Qty AS DECIMAL(38,10)) / t.QSum END) f
            GROUP BY w.PurchaseLineId;

            UPDATE x
            SET ReceivedBase         = ISNULL(s.Matched, 0),
                NetReceivedBase      = ISNULL(s.Matched, 0) - CASE WHEN l.ReturnedQuantityBase < ISNULL(s.Matched, 0) THEN l.ReturnedQuantityBase ELSE ISNULL(s.Matched, 0) END,
                RemainingBase        = CAST(ROUND(ISNULL(s.InStock, 0), 0) AS INT),
                InventoryPortionBase = ISNULL(s.Inv, 0),
                CogsPortionBase      = ISNULL(s.Cogs, 0)
            FROM purchase.LandedCostAdjustmentLines x
            INNER JOIN purchase.PurchaseDocumentLines l ON l.Id = x.PurchaseLineId
            LEFT  JOIN @Share s ON s.PurchaseLineId = x.PurchaseLineId
            WHERE x.AdjustmentId = @Id;

            WITH d AS (SELECT x.Id,
                              InvDiff  = @AdjInventory - SUM(x.InventoryPortionBase) OVER (),
                              CogsDiff = @AdjCogs - SUM(x.CogsPortionBase) OVER (),
                              Rn = ROW_NUMBER() OVER (ORDER BY ABS(x.AllocatedBase) DESC, x.Id)
                       FROM purchase.LandedCostAdjustmentLines x
                       WHERE x.AdjustmentId = @Id)
            UPDATE x
            SET InventoryPortionBase = x.InventoryPortionBase + d.InvDiff, CogsPortionBase = x.CogsPortionBase + d.CogsDiff
            FROM purchase.LandedCostAdjustmentLines x INNER JOIN d ON d.Id = x.Id
            WHERE d.Rn = 1 AND (d.InvDiff <> 0 OR d.CogsDiff <> 0);
        END

        UPDATE a
        SET Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId,
            InventoryPortionBase = ISNULL(t.Inv, 0), CogsPortionBase = ISNULL(t.Cogs, 0)
        FROM purchase.LandedCostAdjustments a
        CROSS APPLY (SELECT SUM(InventoryPortionBase) AS Inv, SUM(CogsPortionBase) AS Cogs FROM purchase.LandedCostAdjustmentLines WHERE AdjustmentId = @Id) t
        WHERE a.Id = @Id;

        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@InvoiceId, N'Updated', LEFT(N'Landed cost adjustment ' + @Number + N' posted: ' + CAST((SELECT TotalChargesBase FROM purchase.LandedCostAdjustments WHERE Id = @Id) AS NVARCHAR(30)) + N' added to the landed cost'
                                             -- (65) what it did to the goods already received
                                             + CASE WHEN @UsesGoodsReceipts = 1 AND @AdjAmount <> 0
                                                    THEN N'; cost of received goods adjusted by ' + CAST(@AdjAmount AS NVARCHAR(30)) + N' (stock '
                                                         + CAST(@AdjInventory AS NVARCHAR(30)) + N', cost of sales ' + CAST(@AdjCogs AS NVARCHAR(30)) + N')'
                                                    ELSE N'' END, 500), @UserId);

        COMMIT TRANSACTION;
        SELECT @Number AS DocumentNumber;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 12. A completed Delivery: automatic or by hand */

-- Re-created (79) from the body of script 72: when the GRN type's AutoCreateOnDelivery is 0, no draft is made (an
-- empty answer in the same columns). Receive goods... on a container (usp_GoodsReceipt_CreateForContainer) is unchanged.
CREATE OR ALTER PROCEDURE purchase.usp_GoodsReceipt_CreateForMovement
    @MovementId INT,
    @UserId     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;

    IF @@TRANCOUNT > 0
        THROW 63010, 'The goods receipts of a movement are created after its completion is committed, outside any transaction.', 1;

    DECLARE @Status TINYINT, @Stage NVARCHAR(10), @MovNo NVARCHAR(30), @EndDate DATE;
    SELECT @Status = m.Status, @Stage = mt.Stage, @MovNo = m.MovementNo, @EndDate = m.EndDate
    FROM logistics.Movements m
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    WHERE m.Id = @MovementId;
    IF @Status IS NULL THROW 70006, 'Movement not found.', 1;
    IF @Status <> 3 OR @Stage <> N'Delivery' THROW 70010, 'Only a completed Delivery movement creates goods receipts.', 1;

    -- (79) Configuration > Document Types: goods receipts are made by hand. The completion is committed already and
    --      must never fail because of its receipts, so: the same columns, no row (the API says why).
    IF EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Code = N'GRN' AND AutoCreateOnDelivery = 0)
    BEGIN
        SELECT ContainerId = CAST(NULL AS INT), ContainerRef = CAST(NULL AS NVARCHAR(30)), GoodsReceiptId = CAST(NULL AS INT),
               GoodsReceiptNumber = CAST(NULL AS NVARCHAR(30)), GoodsReceiptStatus = CAST(NULL AS TINYINT),
               WarehouseCode = CAST(NULL AS NVARCHAR(20)), Created = CAST(0 AS BIT), SkipReason = CAST(NULL AS NVARCHAR(20)),
               Message = CAST(NULL AS NVARCHAR(400))
        WHERE 1 = 0;
        RETURN;
    END

    DECLARE @Result TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, ContainerId INT NOT NULL, ContainerRef NVARCHAR(30) NOT NULL,
                           GoodsReceiptId INT NULL, Created BIT NOT NULL, SkipReason NVARCHAR(20) NULL, Message NVARCHAR(400) NULL);
    DECLARE @Cid INT, @CRef NVARCHAR(30), @NewId INT, @Skip NVARCHAR(20), @Err NVARCHAR(400);

    DECLARE ctn CURSOR LOCAL FAST_FORWARD FOR
        SELECT c.Id, c.ContainerRef
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
        WHERE mc.MovementId = @MovementId
        ORDER BY c.ContainerRef;
    OPEN ctn;
    FETCH NEXT FROM ctn INTO @Cid, @CRef;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT @NewId = NULL, @Skip = NULL, @Err = NULL;
        BEGIN TRY
            EXEC purchase.usp_GoodsReceipt_CreateForContainer @ContainerId = @Cid, @DocumentDate = @EndDate, @MovementId = @MovementId,
                 @UserId = @UserId, @Silent = 1, @NewId = @NewId OUTPUT, @SkipReason = @Skip OUTPUT;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
            SELECT @NewId = NULL, @Skip = N'Error', @Err = LEFT(ERROR_MESSAGE(), 400);
        END CATCH

        INSERT INTO @Result (ContainerId, ContainerRef, GoodsReceiptId, Created, SkipReason, Message)
        VALUES (@Cid, @CRef, COALESCE(@NewId, (SELECT r.GoodsReceiptId FROM logistics.fn_Container_ReceivedBy(@Cid) r)),
                CASE WHEN @NewId IS NOT NULL THEN 1 ELSE 0 END, @Skip, @Err);
        FETCH NEXT FROM ctn INTO @Cid, @CRef;
    END
    CLOSE ctn;
    DEALLOCATE ctn;

    SELECT r.ContainerId, r.ContainerRef, r.GoodsReceiptId, GoodsReceiptNumber = g.DocumentNumber, GoodsReceiptStatus = g.Status,
           WarehouseCode = CASE WHEN r.Created = 1 THEN w.WarehouseCode END, r.Created, r.SkipReason,
           Message = CAST(CASE
               WHEN r.Created = 1 AND w.Id IS NOT NULL THEN N'Draft goods receipt created into ' + w.WarehouseCode + N'.'
               -- (72) the container's warehouse was not taken: say why, rather than leave the reader to guess
               WHEN r.Created = 1 AND cw.Id IS NOT NULL
                   THEN N'Draft goods receipt created: choose the warehouse (' + cw.WarehouseCode + N', the container''s, '
                        + CASE WHEN cw.IsActive = 0 THEN N'is inactive'
                               WHEN cw.BranchId <> c.BranchId THEN N'is not of the container''s branch'
                               ELSE N'has warehouses under it: stock is kept only in the warehouses at the bottom of the tree' END + N').'
               WHEN r.Created = 1 THEN N'Draft goods receipt created: choose the warehouse.'
               WHEN r.SkipReason = N'Error' THEN r.Message
               WHEN r.SkipReason = N'Received' AND g.Status = 2 THEN N'Already received with goods receipt ' + g.DocumentNumber + N'.'
               WHEN r.SkipReason = N'Received' THEN N'Already offloaded.'
               WHEN r.SkipReason = N'HasDraft' THEN N'Already has a draft goods receipt.'
               WHEN r.SkipReason = N'NotConfirmed' THEN N'Not confirmed: confirm the container, then use Receive goods' + NCHAR(8230) + N' on it.'
               WHEN r.SkipReason = N'Cancelled' THEN N'The container is cancelled.'
               WHEN r.SkipReason = N'NoLines' THEN N'The container has no lines.'
               WHEN r.SkipReason = N'InactiveItem'
                   THEN N'Item ' + ISNULL(ia.ItemCode, N'?') + N' is inactive: activate it in Item Definition, then use Receive goods' + NCHAR(8230) + N' on the container.' END
               AS NVARCHAR(400))
    FROM @Result r
    LEFT JOIN purchase.GoodsReceipts g    ON g.Id = r.GoodsReceiptId
    LEFT JOIN masterdata.Warehouses w     ON w.Id = g.WarehouseId
    LEFT JOIN logistics.Containers c      ON c.Id = r.ContainerId
    LEFT JOIN masterdata.Warehouses cw    ON cw.Id = c.WarehouseId
    OUTER APPLY (SELECT TOP (1) i.ItemCode
                 FROM logistics.ContainerLines cl INNER JOIN inventory.Items i ON i.Id = cl.ItemId
                 WHERE r.SkipReason = N'InactiveItem' AND cl.ContainerId = r.ContainerId AND i.IsActive = 0
                 ORDER BY cl.LineNumber) ia
    ORDER BY r.Seq;
END
GO

-- Re-created (79) from the body of script 72: + GoodsReceiptsAutomatic on the header. Nothing else changes.
CREATE OR ALTER PROCEDURE logistics.usp_Movement_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

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
           GoodsReceiptsAutomatic = CAST(ISNULL((SELECT dt.AutoCreateOnDelivery FROM inventory.DocumentTypes dt WHERE dt.Code = N'GRN'), 1) AS BIT)
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
           GoodsReceiptUpdatedAtUtc = g.UpdatedAtUtc, GoodsReceiptUpdatedByName = gu.FullName
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
END
GO

/* ================================================================== 13. Check */

-- The switches as they are (defaults: PINV affects item cost 1, on-hand 0; GRN on Delivery 1).
SELECT dt.Code, dt.AffectsItemCost, dt.AffectsOnHand, dt.AutoCreateOnDelivery
FROM inventory.DocumentTypes dt
WHERE dt.Code IN (N'PINV', N'GRN');

-- The invoices posted without changing item costs, or receiving their goods when posted. Expected at first: none.
SELECT Kind = N'AffectsCost 0', Invoices = COUNT(*) FROM purchase.PurchaseDocuments WHERE AffectsCost = 0
UNION ALL
SELECT N'ReceiveOnPost 1', COUNT(*) FROM purchase.PurchaseDocuments WHERE ReceiveOnPost = 1;

PRINT 'Script 79 applied: Document Types - a purchase invoice may change item costs or not, may receive its goods when posted, and goods receipts may be made by hand after a Delivery.';
GO
