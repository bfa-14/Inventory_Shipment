SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 93: INVENTORY - BATCH, SERIAL AND EXPIRY ON TRANSFERS (prompt 50)

   US-02's last bullet: "Batch, serial, and expiry details are captured in a separate dialog when the item requires
   them". Built on transfers only (B1), without rebuilding the stock ledger of any module. The word is TRACKING:
   "Details" already means the header fields of a transfer.

     1. THE ITEM (Item Definition, Edit Items): Tracking None (0) / Batch numbers (1) / Serial numbers (2), Requires
        expiry date, and for serial items an optional exact Serial no. length (17 for a TVS chassis no.). Every
        existing item is None / no: nothing changes until someone ticks them. The item's KIND, never stored on the
        item: 2 Serial, 1 Batch, 3 Expiry (None + Requires expiry), NULL none.
     2. A DISPATCH (and Dispatch and receive) of a line of a tracked item with pcs > 0 needs its rows: one serial no.
        per piece, or batch rows (batch no., expiry, pcs) or expiry rows (expiry, pcs) adding up to the line's pcs; the
        dispatch is refused until every tracked line is complete (62016). Rows for an untracked line, or for a line
        that does not leave, are refused.
     3. NUMBERS (B4, one place: inventory.fn_TrackingNo_Normalize): CR, LF, TAB, NBSP and BOM and spaces trimmed at
        both ends only, capitals, at most 50 characters; one of those characters left INSIDE is refused. Serial:
        letters, digits, . / - (no spaces); batch: letters, digits, spaces, . / _ # -; the item's exact length.
     4. ONE SOURCE OF THE DISPATCH RULES: inventory.fn_TransferDispatch_TrackingProblems, read by the dialog's Check
        (errors and warnings) and by the posting (errors, with the same sentences). A serial no. is unique in a
        dispatch (and in any posting: an index) and NEVER ON THE WAY TWICE (62017, checked under an application lock
        per item, after the source lock, so two dispatches of one serial from two warehouses never both pass). The
        format errors come BEFORE the source lock (B17): a slow check never blocks the warehouse. What transfers know
        of a number's last place gives WARNINGS only (last received elsewhere, written off, an expiry in the past, a
        batch that left before with another expiry).
     5. A RECEIPT FOLLOWS ITS DISPATCH LINE (B3, TransferPostingLines.TrackingKind, a snapshot taken at dispatch):
        each row on the way is received, still coming or lost, per serial / per row (B6); received + lost of a row
        never above its on the way (62012); the line's Received is the rows' sum, its Lost the rows' lost (its
        "Nothing more will arrive" is not read). A line that left without rows is received without them. Dispatch and
        receive receives every row of its dispatch.
     6. STORED in one new table, inventory.TransferPostingTracking, child of script 90's posting lines: a receipt row
        points at the dispatch row it receives; a dispatch row's SettledBase = received + written off by POSTED
        receipts (90's rule for its lines). Rows are never changed by a reversal nor deleted: a reversed posting's
        rows read "Reversed".
     7. THE LEDGER CARRIES THE EXPIRY (B7): a tracked line writes one stock row per leg and expiry date
        (StockMovements.ExpiryDate), with the same frozen cost: on hand, the valuation and the cost replay add them up
        exactly as before. An untracked line writes script 90's rows, unchanged.
     8. REVERSE keeps every row; reversing a receipt puts its serials and batch pieces back on the way and undoes its
        losses, and is refused while one of its serials has been dispatched again since (62013), under the same
        per-item serial lock.
     9. SEEN AND FOUND: the order's Get carries per line the item's tracking and per posting line its kind and count
        only (B18); the rows of one posting by their own procedure (usp_TransferPosting_Tracking); the list finds the
        orders by a batch or serial no. (contains, 3 characters or more) and says what happened to it; suggestions:
        the serials received into the source by transfers and not sent since (B12).
    10. No new permission (B11). Untracked items behave exactly as in script 90: the new branches run only for
        tracked lines; script 90's table types are untouched, the tracking travels in two new, optional table-valued
        parameters (an omitted one is an empty table, so every caller of script 90 keeps working, B15).

   Objects
     New columns       inventory.Items.TrackingMode (TINYINT NOT NULL, DF 0), RequiresExpiry (BIT NOT NULL, DF 0),
                       SerialLength (TINYINT NULL), CK_Items_Tracking;
                       inventory.TransferPostingLines.TrackingKind (TINYINT NULL), CK_TransferPostingLines_TrackingKind
     New table         inventory.TransferPostingTracking (and its indexes)
     New types         inventory.tvp_TransferDispatchTracking, tvp_TransferReceiptTracking
     New functions     inventory.fn_TrackingNo_Normalize, fn_TransferSerial_LastEvent,
                       fn_TransferDispatch_TrackingProblems
     New procedures    inventory.usp_Item_SetTracking, usp_TransferPosting_Tracking,
                       usp_TransferOrder_CheckDispatchTracking, usp_TransferOrder_TrackingSuggestions
     Re-created        inventory.usp_Item_Get                      from the body of script 87: + TrackingMode,
                                                                   RequiresExpiry, SerialLength
                       inventory.fn_TransferPosting_ReverseBlock   from the body of script 90: + a receipt whose serial
                                                                   was dispatched again since (Seq 3, 62013)
                       inventory.usp_TransferOrder_DispatchCore    from the body of script 90: + @Tracking, the rules
                                                                   (before the source lock), the serial locks, 62017, the
                                                                   rows, the ledger per expiry date
                       inventory.usp_TransferOrder_Dispatch        from the body of script 90: + @Tracking, the audit's
                                                                   tracking counts
                       inventory.usp_TransferOrder_ReceiveCore     from the body of script 90: + @Tracking, the receipt
                                                                   rules, the rows, the ledger per expiry date, the
                                                                   dispatch rows' Settled
                       inventory.usp_TransferOrder_Receive         from the body of script 90: + @Tracking
                       inventory.usp_TransferOrder_DispatchAndReceive  from the body of script 90: + @Tracking, every
                                                                   row of the new dispatch received
                       inventory.usp_TransferPosting_Reverse       from the body of script 90: + the serial locks of a
                                                                   receipt, its rows back on the way
                       inventory.usp_TransferOrder_Get             from the body of script 91: + the item's tracking per
                                                                   line, the kind and count per posting line
                       inventory.usp_TransferOrder_Search          from the body of script 92: + @TrackingNo,
                                                                   MatchedTracking

   Errors (block 62xxx, shared with the stock documents): new 62016 batch, serial or expiry rows missing, incomplete or
   invalid (dispatch and receipt; HTTP 400, TRANSFER_TRACKING), new 62017 a serial no. already on the way with a posted
   dispatch (409, SERIAL_ON_THE_WAY). Reused: 62000, 62006, 62010 (the serial lock not obtained in 30 s), 62012, 62013
   (its code REVERSE_LATER_FIRST), 56000 / 56006 (the item's tracking).

   Not changed: script 90's table types and every caller of its procedures; every other procedure of transfers (Save,
   Release, approval, NothingMoreSent, Cancel, SetEta, CreateReturn, FillToMax, the levels), of items
   (usp_Item_Create / _Update / _Search / _Lookup / _SetPurchasing / _SetNotes) and of every other family; the ledger's
   shape (no column added), on hand, the valuation, the Dashboard, Shortages, Stock Levels, the cost replay
   (inventory.usp_Item_RebuildCosts) and the item statement (it already returns ExpiryDate); script 92's access rules
   and trigger (the split rows stamp CreatedBy = @UserId like any).

   Requires scripts 90, 91 and 92 (Schema.sql runs them first). Idempotent, additive: re-applied at every API start-up,
   and builds a brand-new empty database (every column and table before the objects that read them).
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'inventory.TransferPostingLines', N'U') IS NULL                                        -- 90
   OR NOT EXISTS (SELECT 1 FROM sys.table_types WHERE name = N'tvp_TransferDispatchLine' AND schema_id = SCHEMA_ID(N'inventory'))  -- 90
   OR OBJECT_ID(N'inventory.ItemWarehouseLevels', N'U') IS NULL                                     -- 91
   OR OBJECT_ID(N'inventory.TR_StockMovements_WarehouseAccess', N'TR') IS NULL                      -- 92
    THROW 62000, 'Script 93 requires scripts 90, 91 and 92: apply them first.', 1;
GO

/* ================================================================== 2. The item's tracking */

-- (93) HOW AN ITEM IS TRACKED ON TRANSFERS: 0 None, 1 Batch numbers, 2 Serial numbers; RequiresExpiry: each dispatch
--      gives the expiry of its pieces; SerialLength: serial items only, the exact length (17 = TVS chassis no.). Every
--      existing item gets None / no / NULL: nothing changes until someone ticks them (Item Definition, Edit Items).
IF COL_LENGTH(N'inventory.Items', N'TrackingMode') IS NULL
BEGIN
    ALTER TABLE inventory.Items ADD
        TrackingMode   TINYINT NOT NULL CONSTRAINT DF_Items_TrackingMode   DEFAULT (0),
        RequiresExpiry BIT     NOT NULL CONSTRAINT DF_Items_RequiresExpiry DEFAULT (0),
        SerialLength   TINYINT NULL;
    PRINT 'inventory.Items: added TrackingMode, RequiresExpiry, SerialLength (every item None)';
END
GO

-- Its own batch: the columns above must exist when the constraint is compiled.
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_Items_Tracking' AND parent_object_id = OBJECT_ID(N'inventory.Items'))
BEGIN
    ALTER TABLE inventory.Items ADD CONSTRAINT CK_Items_Tracking
        CHECK (TrackingMode IN (0, 1, 2) AND (SerialLength IS NULL OR (TrackingMode = 2 AND SerialLength BETWEEN 1 AND 50)));
    PRINT 'inventory.Items: added CK_Items_Tracking';
END
GO

/* ================================================================== 3. The posting line's tracking kind */

-- (93) THE KIND A DISPATCH LINE LEFT WITH (B3): the item's kind (1 Batch, 2 Serial, 3 Expiry) when the line carried
--      rows, NULL when it did not (every line posted by script 90: its behaviour). A receipt line copies its dispatch
--      line's, so goods on the way are received the way they left, whatever the item says now.
IF COL_LENGTH(N'inventory.TransferPostingLines', N'TrackingKind') IS NULL
BEGIN
    ALTER TABLE inventory.TransferPostingLines ADD TrackingKind TINYINT NULL;
    PRINT 'inventory.TransferPostingLines: added TrackingKind';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_TransferPostingLines_TrackingKind'
                                                     AND parent_object_id = OBJECT_ID(N'inventory.TransferPostingLines'))
BEGIN
    ALTER TABLE inventory.TransferPostingLines ADD CONSTRAINT CK_TransferPostingLines_TrackingKind
        CHECK (TrackingKind IS NULL OR TrackingKind IN (1, 2, 3));
    PRINT 'inventory.TransferPostingLines: added CK_TransferPostingLines_TrackingKind';
END
GO

/* ================================================================== 4. The tracking rows */

-- (93) ONE ROW PER SERIAL NO., PER BATCH OR PER EXPIRY GROUP OF A POSTING LINE. A dispatch row: what left (QuantityBase
--      > 0, 1 for a serial) and SettledBase = received + written off by POSTED receipts (on the way = QuantityBase -
--      SettledBase while its dispatch is Posted, 0 once Reversed: script 90's rule for its lines). A receipt row points
--      at the dispatch row it receives (DispatchTrackingId): received (QuantityBase >= 0) and LostBase. Numbers in
--      capitals (fn_TrackingNo_Normalize). PostingId and ItemId repeat the line's, for the uniqueness index and the
--      searches (Check 9). Never deleted (postings never are): no cascade.
IF OBJECT_ID(N'inventory.TransferPostingTracking', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.TransferPostingTracking
    (
        Id                 INT IDENTITY(1,1) NOT NULL,
        PostingLineId      INT          NOT NULL,
        PostingId          INT          NOT NULL,
        ItemId             INT          NOT NULL,
        RowNumber          INT          NOT NULL,     -- 1..n in the posting line: the order typed (dispatch), the dispatch rows' (receipt)
        Kind               TINYINT      NOT NULL,     -- = the line's TrackingKind: 1 Batch, 2 Serial, 3 Expiry
        BatchNo            NVARCHAR(50) NULL,         -- Kind 1
        SerialNo           NVARCHAR(50) NULL,         -- Kind 2
        ExpiryDate         DATE         NULL,         -- Kind 3, and Kinds 1 / 2 when the item required it at dispatch
        QuantityBase       INT          NOT NULL,     -- dispatch: pcs sent; receipt: pcs received
        LostBase           INT          NOT NULL CONSTRAINT DF_TransferPostingTracking_Lost DEFAULT (0),      -- receipt rows
        SettledBase        INT          NOT NULL CONSTRAINT DF_TransferPostingTracking_Settled DEFAULT (0),   -- dispatch rows
        DispatchTrackingId INT          NULL,         -- receipt rows: the dispatch row received
        CONSTRAINT PK_TransferPostingTracking PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_TransferPostingTracking_Kind CHECK (Kind IN (1, 2, 3)),
        CONSTRAINT CK_TransferPostingTracking_Shape CHECK ((Kind = 1 AND BatchNo IS NOT NULL AND SerialNo IS NULL)
                                                           OR (Kind = 2 AND SerialNo IS NOT NULL AND BatchNo IS NULL)
                                                           OR (Kind = 3 AND BatchNo IS NULL AND SerialNo IS NULL AND ExpiryDate IS NOT NULL)),
        CONSTRAINT CK_TransferPostingTracking_Blank CHECK (LEN(ISNULL(BatchNo, N'x')) > 0 AND LEN(ISNULL(SerialNo, N'x')) > 0),
        CONSTRAINT CK_TransferPostingTracking_Expiry CHECK (ExpiryDate IS NULL OR ExpiryDate BETWEEN '20000101' AND '20991231'),
        CONSTRAINT CK_TransferPostingTracking_Qty CHECK (QuantityBase >= 0 AND LostBase >= 0 AND SettledBase >= 0
                                                         AND ((DispatchTrackingId IS NULL AND QuantityBase > 0 AND LostBase = 0 AND SettledBase <= QuantityBase)
                                                              OR (DispatchTrackingId IS NOT NULL AND QuantityBase + LostBase > 0 AND SettledBase = 0))),
        CONSTRAINT CK_TransferPostingTracking_Serial CHECK (Kind <> 2 OR (DispatchTrackingId IS NULL AND QuantityBase = 1)
                                                            OR (DispatchTrackingId IS NOT NULL AND QuantityBase + LostBase = 1)),
        CONSTRAINT FK_TransferPostingTracking_Line     FOREIGN KEY (PostingLineId)      REFERENCES inventory.TransferPostingLines (Id),
        CONSTRAINT FK_TransferPostingTracking_Posting  FOREIGN KEY (PostingId)          REFERENCES inventory.TransferPostings (Id),
        CONSTRAINT FK_TransferPostingTracking_Item     FOREIGN KEY (ItemId)             REFERENCES inventory.Items (Id),
        CONSTRAINT FK_TransferPostingTracking_Dispatch FOREIGN KEY (DispatchTrackingId) REFERENCES inventory.TransferPostingTracking (Id)
    );
    CREATE UNIQUE NONCLUSTERED INDEX UX_TransferPostingTracking_Number ON inventory.TransferPostingTracking (PostingLineId, RowNumber);
    -- a serial is never twice in one posting, whatever a procedure does
    CREATE UNIQUE NONCLUSTERED INDEX UX_TransferPostingTracking_Serial ON inventory.TransferPostingTracking (PostingId, ItemId, SerialNo)
        WHERE SerialNo IS NOT NULL;
    CREATE UNIQUE NONCLUSTERED INDEX UX_TransferPostingTracking_Batch ON inventory.TransferPostingTracking (PostingLineId, BatchNo)
        WHERE BatchNo IS NOT NULL;
    CREATE UNIQUE NONCLUSTERED INDEX UX_TransferPostingTracking_ExpiryRow ON inventory.TransferPostingTracking (PostingLineId, ExpiryDate)
        WHERE Kind = 3;
    -- "already on the way", the last event of a serial, the suggestions
    CREATE NONCLUSTERED INDEX IX_TransferPostingTracking_ItemSerial ON inventory.TransferPostingTracking (ItemId, SerialNo)
        INCLUDE (PostingId, QuantityBase, LostBase, SettledBase, DispatchTrackingId) WHERE SerialNo IS NOT NULL;
    CREATE NONCLUSTERED INDEX IX_TransferPostingTracking_BatchNo ON inventory.TransferPostingTracking (BatchNo)
        INCLUDE (ItemId, PostingId, ExpiryDate) WHERE BatchNo IS NOT NULL;
    CREATE NONCLUSTERED INDEX IX_TransferPostingTracking_Dispatch ON inventory.TransferPostingTracking (DispatchTrackingId)
        WHERE DispatchTrackingId IS NOT NULL;
    CREATE NONCLUSTERED INDEX IX_TransferPostingTracking_Posting ON inventory.TransferPostingTracking (PostingId, PostingLineId);
    PRINT 'Created inventory.TransferPostingTracking';
END
GO

/* ================================================================== 5. The table types (new; script 90's stay frozen) */

-- FROZEN like script 90's: a later change takes a new type. Text columns 100 wide, so that a number too long reaches the
-- rule that names it (62016) instead of being cut; RowNumber = the row's place in the dialog (1-based), set by the API.
IF NOT EXISTS (SELECT 1 FROM sys.table_types WHERE name = N'tvp_TransferDispatchTracking' AND schema_id = SCHEMA_ID(N'inventory'))
BEGIN
    CREATE TYPE inventory.tvp_TransferDispatchTracking AS TABLE
    ( TransferOrderLineId INT NOT NULL, RowNumber INT NOT NULL,
      BatchNo NVARCHAR(100) NULL, SerialNo NVARCHAR(100) NULL, ExpiryDate DATE NULL, QuantityBase INT NOT NULL,
      PRIMARY KEY (TransferOrderLineId, RowNumber),
      INDEX IX_Serial NONCLUSTERED (SerialNo),
      INDEX IX_Batch NONCLUSTERED (TransferOrderLineId, BatchNo) );
    PRINT 'Created type inventory.tvp_TransferDispatchTracking';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.table_types WHERE name = N'tvp_TransferReceiptTracking' AND schema_id = SCHEMA_ID(N'inventory'))
BEGIN
    CREATE TYPE inventory.tvp_TransferReceiptTracking AS TABLE
    ( DispatchTrackingId INT NOT NULL PRIMARY KEY, ReceivedBase INT NOT NULL, LostBase INT NOT NULL );
    PRINT 'Created type inventory.tvp_TransferReceiptTracking';
END
GO

/* ================================================================== 6. The functions */

-- (93) THE ONE PLACE OF RULE B4: a batch or serial no. as typed, scanned or pasted -> as kept. Tabs, line breaks, the
--      no-break space (NCHAR 160), the byte order mark (NCHAR 65279) and spaces are trimmed at BOTH ENDS ONLY (a scanner
--      adds a CR or a tab); one left inside stays, and the rules refuse it, so that a pasted "serial TAB expiry" never
--      glues into one serial. Then capitals (the comparison does not depend on the collation). Empty -> NULL. Compared
--      by code point (UNICODE), not by collation: a zero-width character is "ignorable" to a Windows collation. Called
--      ONCE per row by the procedures, never inside the problem function.
CREATE OR ALTER FUNCTION inventory.fn_TrackingNo_Normalize (@Value NVARCHAR(100))
RETURNS NVARCHAR(100)
AS
BEGIN
    IF @Value IS NULL RETURN NULL;

    DECLARE @First INT = 1, @Last INT = DATALENGTH(@Value) / 2;   -- DATALENGTH: LEN ignores trailing spaces
    WHILE @First <= @Last AND UNICODE(SUBSTRING(@Value, @First, 1)) IN (9, 10, 13, 32, 160, 65279) SET @First += 1;
    WHILE @Last >= @First AND UNICODE(SUBSTRING(@Value, @Last, 1)) IN (9, 10, 13, 32, 160, 65279) SET @Last -= 1;
    IF @Last < @First RETURN NULL;

    RETURN UPPER(SUBSTRING(@Value, @First, @Last - @First + 1));
END
GO

-- (93) THE LAST THING TRANSFERS KNOW OF A SERIAL NO. (5.3.5.2): the latest row of that item and serial on a POSTED
--      posting, by the row's Id (the order the rows were written in; a posting's PostedAtUtc is taken when it starts,
--      so a dispatch that waited on a lock can carry an earlier time than the receipt it follows; the receipt of a
--      "Dispatch and receive" is written after its dispatch): OnTheWay (a dispatch row not settled),
--      Received / Lost (a receipt row), Settled (a dispatch row whose receipt is the later event; never the latest in
--      practice). Read by the warnings only (Check, never the posting): no module but transfers records serials, so it
--      is a clue, never the truth (B5). The latest row is a MAX(Id), never a TOP (1) ... ORDER BY: applied to each of
--      10,000 serials (Check), a TOP (1) let the optimiser pick a row-goal plan (measured 21 s to 399 s; MAX: 1.6 s).
--      The rows and the posting are read by SEEKS (FORCESEEK, 93 tests): estimating thousands of rows per serial, the
--      optimiser otherwise hashed every posted posting for each serial, so a Check of 10,000 serials grew with the
--      postings (37 s with 5,050 postings; with the seeks 0.7-2.0 s).
CREATE OR ALTER FUNCTION inventory.fn_TransferSerial_LastEvent (@ItemId INT, @SerialNo NVARCHAR(50))
RETURNS TABLE
AS
RETURN
SELECT PostingId       = p.Id,
       PostingKind     = p.Kind,
       PostingNumber   = p.DocumentNumber,
       PostingDate     = p.PostingDate,
       TransferOrderId = p.TransferOrderId,
       OrderNumber     = o.DocumentNumber,
       FromWarehouseId = p.FromWarehouseId,
       FromCode        = fw.WarehouseCode,
       ToWarehouseId   = p.ToWarehouseId,
       ToCode          = tw.WarehouseCode,
       Event           = CAST(CASE WHEN x.DispatchTrackingId IS NULL
                                   THEN CASE WHEN x.SettledBase < x.QuantityBase THEN N'OnTheWay' ELSE N'Settled' END
                                   WHEN x.QuantityBase = 1 THEN N'Received'
                                   WHEN x.LostBase = 1 THEN N'Lost' END AS NVARCHAR(10)),
       LossReasonName  = CAST(CASE WHEN x.DispatchTrackingId IS NOT NULL AND x.LostBase > 0 THEN
                                   CASE pl.LossReasonCode WHEN N'DAMAGED' THEN N'Damaged' WHEN N'MISSING' THEN N'Missing / stolen'
                                                          WHEN N'DISPATCHCOUNT' THEN N'Wrongly counted at dispatch'
                                                          WHEN N'OTHER' THEN N'Other' END END AS NVARCHAR(40))
FROM (SELECT LastId = MAX(lx.Id)
      FROM inventory.TransferPostingTracking lx WITH (FORCESEEK)
      INNER JOIN inventory.TransferPostings lp WITH (FORCESEEK) ON lp.Id = lx.PostingId AND lp.Status = 2
      WHERE lx.ItemId = @ItemId AND lx.SerialNo = @SerialNo AND lx.SerialNo IS NOT NULL) l
INNER JOIN inventory.TransferPostingTracking x ON x.Id = l.LastId
INNER JOIN inventory.TransferPostings p     ON p.Id = x.PostingId
INNER JOIN inventory.TransferPostingLines pl ON pl.Id = x.PostingLineId
INNER JOIN inventory.TransferOrders o       ON o.Id = p.TransferOrderId
INNER JOIN masterdata.Warehouses fw         ON fw.Id = p.FromWarehouseId
INNER JOIN masterdata.Warehouses tw         ON tw.Id = p.ToWarehouseId;
GO

/* (93) WHAT IS WRONG WITH THE BATCH, SERIAL AND EXPIRY ROWS OF A DISPATCH (5.3.5.3): one row per problem (Seq, Severity
   Error | Warning, ErrorNumber, TransferOrderLineId, LineNumber, RowNumber, Message). THE ONE SOURCE OF THE DISPATCH
   TRACKING RULES: usp_TransferOrder_CheckDispatchTracking (the dialog's Done) returns every row (warnings only for
   @ForLineId when given, errors for the whole dispatch); usp_TransferOrder_DispatchCore throws the first Error of its
   phase: Seq < 90 before the source lock, Seq 90 (already on the way, 62017) after the serial locks. @Tracking holds
   ALREADY NORMALISED numbers (the caller's table variable, fn_TrackingNo_Normalize). Every branch has a CONSTANT Seq and
   Severity, so a caller's WHERE Seq < 90 / Seq = 90 lets the optimiser drop the other branches (the warnings never run
   at posting). Every message part that can be NULL is wrapped in ISNULL. {x} = a number cut to 50 characters + "...". */
CREATE OR ALTER FUNCTION inventory.fn_TransferDispatch_TrackingProblems
(
    @OrderId   INT,
    @Lines     inventory.tvp_TransferDispatchLine READONLY,
    @Tracking  inventory.tvp_TransferDispatchTracking READONLY,
    @ForLineId INT
)
RETURNS TABLE
AS
RETURN
WITH hd AS
(
    -- the order: always one row (an aggregate without GROUP BY)
    SELECT No       = ISNULL(MAX(o.DocumentNumber), N'this transfer order'),
           FromId   = MAX(o.FromWarehouseId),
           FromCode = ISNULL(MAX(fw.WarehouseCode), N'')
    FROM inventory.TransferOrders o
    INNER JOIN masterdata.Warehouses fw ON fw.Id = o.FromWarehouseId
    WHERE o.Id = @OrderId
),
ln AS
(
    -- the lines that leave on this dispatch, with the item's kind now
    SELECT LineId = l.Id, l.LineNumber, l.ItemId, i.ItemCode, Q = x.QuantityBase,
           K = CASE i.TrackingMode WHEN 2 THEN 2 WHEN 1 THEN 1 ELSE CASE WHEN i.RequiresExpiry = 1 THEN 3 END END,
           i.RequiresExpiry, i.SerialLength,
           P = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N')'
    FROM @Lines x
    INNER JOIN inventory.TransferOrderLines l ON l.Id = x.TransferOrderLineId AND l.TransferOrderId = @OrderId
    INNER JOIN inventory.Items i              ON i.Id = l.ItemId
    WHERE x.QuantityBase > 0
),
j AS
(
    -- the rows of those lines
    SELECT ln.LineId, ln.LineNumber, ln.ItemId, ln.ItemCode, ln.Q, ln.K, ln.RequiresExpiry, ln.SerialLength, ln.P,
           t.RowNumber, t.SerialNo, t.BatchNo, t.ExpiryDate, t.QuantityBase,
           R    = CAST(t.RowNumber AS NVARCHAR(10)),
           SLen = LEN(t.SerialNo),
           BLen = LEN(t.BatchNo),
           SX   = ISNULL(CASE WHEN LEN(t.SerialNo) > 50 THEN LEFT(t.SerialNo, 50) + NCHAR(8230) ELSE t.SerialNo END, N''),
           BX   = ISNULL(CASE WHEN LEN(t.BatchNo) > 50 THEN LEFT(t.BatchNo, 50) + NCHAR(8230) ELSE t.BatchNo END, N''),
           ExpX = ISNULL(CONVERT(NVARCHAR(10), t.ExpiryDate, 103), N'')
    FROM @Tracking t
    INNER JOIN ln ON ln.LineId = t.TransferOrderLineId
),
sd AS
(
    -- the serials of serial lines, with their duplicates on the line and on the dispatch's other lines of the item
    SELECT j.LineId, j.LineNumber, j.ItemCode, j.P, j.RowNumber, j.SX,
           LineRn  = ROW_NUMBER() OVER (PARTITION BY j.LineId, j.SerialNo ORDER BY j.RowNumber),
           MinLine = MIN(j.LineNumber) OVER (PARTITION BY j.ItemId, j.SerialNo),
           MaxLine = MAX(j.LineNumber) OVER (PARTITION BY j.ItemId, j.SerialNo)
    FROM j
    WHERE j.K = 2 AND j.SerialNo IS NOT NULL
),
bd AS
(
    SELECT j.LineId, j.LineNumber, j.P, j.RowNumber, j.BX,
           Rn = ROW_NUMBER() OVER (PARTITION BY j.LineId, j.BatchNo ORDER BY j.RowNumber)
    FROM j
    WHERE j.K = 1 AND j.BatchNo IS NOT NULL
),
xd AS
(
    SELECT j.LineId, j.LineNumber, j.P, j.RowNumber, j.ExpX,
           Rn = ROW_NUMBER() OVER (PARTITION BY j.LineId, j.ExpiryDate ORDER BY j.RowNumber)
    FROM j
    WHERE j.K = 3 AND j.ExpiryDate IS NOT NULL
)
SELECT Seq                 = CAST(b.Seq AS INT),
       Severity            = CAST(b.Severity AS NVARCHAR(10)),
       ErrorNumber         = CAST(b.ErrorNumber AS INT),
       TransferOrderLineId = CAST(b.LineId AS INT),
       LineNumber          = CAST(b.LineNumber AS INT),
       RowNumber           = CAST(b.RowNumber AS INT),
       Message             = CAST(b.Message AS NVARCHAR(400))
FROM
(
    -- 5. At most 10,000 rows a dispatch (B14)
    SELECT Seq = 5, Severity = N'Error', ErrorNumber = 62016, LineId = CAST(NULL AS INT), LineNumber = CAST(NULL AS INT),
           RowNumber = CAST(NULL AS INT), Message = CAST(N'A dispatch holds at most 10,000 batch, serial or expiry rows.' AS NVARCHAR(400))
    WHERE (SELECT COUNT(*) FROM @Tracking) > 10000

    UNION ALL
    -- 7. A row naming a line that is not on the order
    SELECT 7, N'Error', 62016, t.TransferOrderLineId, NULL, MIN(t.RowNumber),
           N'A batch, serial or expiry row names a line that is not on ' + MAX(hd.No) + N'.'
    FROM @Tracking t
    CROSS JOIN hd
    WHERE NOT EXISTS (SELECT 1 FROM inventory.TransferOrderLines l WHERE l.Id = t.TransferOrderLineId AND l.TransferOrderId = @OrderId)
    GROUP BY t.TransferOrderLineId

    UNION ALL
    -- 8. Rows for a line of the order that does not leave on this dispatch
    SELECT 8, N'Error', 62016, l.Id, l.LineNumber, NULL,
           N'Batches, serial nos. or expiry dates were given for line ' + CAST(l.LineNumber AS NVARCHAR(10))
           + N', which does not leave on this dispatch.'
    FROM inventory.TransferOrderLines l
    WHERE l.TransferOrderId = @OrderId
      AND EXISTS (SELECT 1 FROM @Tracking t WHERE t.TransferOrderLineId = l.Id)
      AND NOT EXISTS (SELECT 1 FROM ln WHERE ln.LineId = l.Id)

    UNION ALL
    -- 10. Rows for a line whose item takes none
    SELECT 10, N'Error', 62016, ln.LineId, ln.LineNumber, NULL,
           ln.P + N': ' + ln.ItemCode + N' takes no batch, serial or expiry details (Item Definition): open Dispatch'
           + NCHAR(8230) + N' again.'
    FROM ln
    WHERE ln.K IS NULL AND EXISTS (SELECT 1 FROM @Tracking t WHERE t.TransferOrderLineId = ln.LineId)

    UNION ALL
    -- 11. Rows of another kind than the item's now (it changed while the dialog was open)
    SELECT 11, N'Error', 62016, ln.LineId, ln.LineNumber, NULL,
           ln.P + N': the rows do not match how ' + ln.ItemCode + N' is tracked now ('
           + CASE ln.K WHEN 1 THEN N'batch numbers' WHEN 2 THEN N'serial numbers' ELSE N'expiry dates' END
           + N'): open Dispatch' + NCHAR(8230) + N' again.'
    FROM ln
    WHERE ln.K IS NOT NULL
      AND EXISTS (SELECT 1 FROM @Tracking t
                  WHERE t.TransferOrderLineId = ln.LineId
                    AND ((ln.K = 2 AND t.BatchNo IS NOT NULL) OR (ln.K = 1 AND t.SerialNo IS NOT NULL)
                         OR (ln.K = 3 AND (t.BatchNo IS NOT NULL OR t.SerialNo IS NOT NULL))))

    UNION ALL
    -- 12. A tracked line that leaves without its rows
    SELECT 12, N'Error', 62016, ln.LineId, ln.LineNumber, NULL,
           ln.P + CASE ln.K WHEN 2 THEN N': type the serial numbers of the ' + CAST(ln.Q AS NVARCHAR(20)) + N' pcs that leave (Serial nos.'
                                        + NCHAR(8230) + N').'
                            WHEN 1 THEN N': say which batches the ' + CAST(ln.Q AS NVARCHAR(20)) + N' pcs come from (Batches'
                                        + NCHAR(8230) + N').'
                            ELSE N': give the expiry dates of the ' + CAST(ln.Q AS NVARCHAR(20)) + N' pcs (Expiry dates'
                                 + NCHAR(8230) + N').' END
    FROM ln
    WHERE ln.K IS NOT NULL AND NOT EXISTS (SELECT 1 FROM @Tracking t WHERE t.TransferOrderLineId = ln.LineId)

    UNION ALL
    -- 13. The number is missing
    SELECT 13, N'Error', 62016, j.LineId, j.LineNumber, j.RowNumber,
           j.P + N', row ' + j.R + CASE WHEN j.K = 2 THEN N': the serial no. is missing.' ELSE N': the batch no. is missing.' END
    FROM j
    WHERE (j.K = 2 AND j.SerialNo IS NULL) OR (j.K = 1 AND j.BatchNo IS NULL)

    UNION ALL
    -- 14. The expiry date is required (Expiry items, and batch / serial items that require it)
    SELECT 14, N'Error', 62016, j.LineId, j.LineNumber, j.RowNumber,
           j.P + N', row ' + j.R + N': the expiry date is required for ' + j.ItemCode + N'.'
    FROM j
    WHERE j.K IS NOT NULL AND j.RequiresExpiry = 1 AND j.ExpiryDate IS NULL

    UNION ALL
    -- 15. At most 50 characters
    SELECT 15, N'Error', 62016, j.LineId, j.LineNumber, j.RowNumber,
           j.P + CASE WHEN j.K = 2 THEN N': serial no. ' + j.SX ELSE N': batch no. ' + j.BX END + N' is longer than 50 characters.'
    FROM j
    WHERE (j.K = 2 AND j.SLen > 50) OR (j.K = 1 AND j.BLen > 50)

    UNION ALL
    -- 16. A serial no.: letters, digits, . / - (a tab or a line break inside has its own sentence). The hyphen comes
    --     FIRST in the brackets: "./-]" would be read as a range by LIKE and refuse every hyphen.
    SELECT 16, N'Error', 62016, j.LineId, j.LineNumber, j.RowNumber,
           j.P + N': serial no. ' + j.SX
           + CASE WHEN j.SerialNo COLLATE Latin1_General_BIN LIKE N'%[' + NCHAR(9) + NCHAR(10) + NCHAR(13) + N']%'
                  THEN N' may not hold a tab or a line break: paste a list with Paste list' + NCHAR(8230) + N' instead.'
                  ELSE N' may hold only letters, digits and . / - (no spaces).' END
    FROM j
    WHERE j.K = 2 AND j.SerialNo COLLATE Latin1_General_BIN LIKE N'%[^-A-Z0-9./]%'

    UNION ALL
    -- 17. A batch no.: letters, digits, spaces, . / _ # - (a tab or a line break inside has its own sentence)
    SELECT 17, N'Error', 62016, j.LineId, j.LineNumber, j.RowNumber,
           j.P + N': batch no. ' + j.BX
           + CASE WHEN j.BatchNo COLLATE Latin1_General_BIN LIKE N'%[' + NCHAR(9) + NCHAR(10) + NCHAR(13) + N']%'
                  THEN N' may not hold a tab or a line break: paste a list with Paste list' + NCHAR(8230) + N' instead.'
                  ELSE N' may hold only letters, digits, spaces and . / _ # -.' END
    FROM j
    WHERE j.K = 1 AND j.BatchNo COLLATE Latin1_General_BIN LIKE N'%[^-A-Z0-9 ./_#]%'

    UNION ALL
    -- 18. The item's exact serial no. length
    SELECT 18, N'Error', 62016, j.LineId, j.LineNumber, j.RowNumber,
           j.P + N': serial no. ' + j.SX + N' has ' + CAST(j.SLen AS NVARCHAR(10)) + N' characters; the serial numbers of '
           + j.ItemCode + N' have ' + CAST(j.SerialLength AS NVARCHAR(10)) + N' (Item Definition).'
    FROM j
    WHERE j.K = 2 AND j.SerialNo IS NOT NULL AND j.SerialLength IS NOT NULL AND j.SLen <> j.SerialLength

    UNION ALL
    -- 19. An expiry date between 01/01/2000 and 31/12/2099
    SELECT 19, N'Error', 62016, j.LineId, j.LineNumber, j.RowNumber,
           j.P + N', row ' + j.R + N': ' + j.ExpX + N' is not a valid expiry date.'
    FROM j
    WHERE j.K IS NOT NULL AND (j.ExpiryDate < '20000101' OR j.ExpiryDate > '20991231')

    UNION ALL
    -- 20. The pieces of a row
    SELECT 20, N'Error', 62016, j.LineId, j.LineNumber, j.RowNumber,
           j.P + N', row ' + j.R + CASE WHEN j.K = 2 THEN N': a serial number is one piece.'
                                         ELSE N': the pieces must be a whole number above 0.' END
    FROM j
    WHERE (j.K = 2 AND j.QuantityBase <> 1) OR (j.K IN (1, 3) AND j.QuantityBase <= 0)

    UNION ALL
    -- 21. A serial no. once in a dispatch: twice on one line (the second row named) ...
    SELECT 21, N'Error', 62016, sd.LineId, sd.LineNumber, sd.RowNumber,
           sd.P + N': serial no. ' + sd.SX + N' is typed twice.'
    FROM sd
    WHERE sd.LineRn = 2

    UNION ALL
    -- ... or on two lines of the same item (each line's row named, so each line's dialog shows it)
    SELECT 21, N'Error', 62016, sd.LineId, sd.LineNumber, sd.RowNumber,
           N'Serial no. ' + sd.SX + N' of ' + sd.ItemCode + N' is twice in this dispatch (lines '
           + CAST(sd.MinLine AS NVARCHAR(10)) + N' and ' + CAST(sd.MaxLine AS NVARCHAR(10)) + N').'
    FROM sd
    WHERE sd.LineRn = 1 AND sd.MinLine <> sd.MaxLine

    UNION ALL
    -- 22. One row per batch on a line
    SELECT 22, N'Error', 62016, bd.LineId, bd.LineNumber, bd.RowNumber,
           bd.P + N': batch ' + bd.BX + N' is on two rows: put its pieces on one row.'
    FROM bd
    WHERE bd.Rn = 2

    UNION ALL
    -- 23. One row per expiry date on an Expiry line
    SELECT 23, N'Error', 62016, xd.LineId, xd.LineNumber, xd.RowNumber,
           xd.P + N': expiry ' + xd.ExpX + N' is on two rows: put its pieces on one row.'
    FROM xd
    WHERE xd.Rn = 2

    UNION ALL
    -- 24. The rows add up to the pcs that leave (12 applies when there is no row)
    SELECT 24, N'Error', 62016, ln.LineId, ln.LineNumber, NULL,
           ln.P + CASE ln.K WHEN 2 THEN N': ' + CAST(ln.Q AS NVARCHAR(20)) + N' pcs leave but ' + CAST(c.C AS NVARCHAR(20))
                                        + N' serial numbers are typed.'
                            WHEN 1 THEN N': the batches add up to ' + CAST(c.S AS NVARCHAR(20)) + N' pcs but '
                                        + CAST(ln.Q AS NVARCHAR(20)) + N' pcs leave.'
                            ELSE N': the expiry dates add up to ' + CAST(c.S AS NVARCHAR(20)) + N' pcs but '
                                 + CAST(ln.Q AS NVARCHAR(20)) + N' pcs leave.' END
    FROM ln
    CROSS APPLY (SELECT C = COUNT(*), S = ISNULL(SUM(CAST(t.QuantityBase AS BIGINT)), 0)
                 FROM @Tracking t WHERE t.TransferOrderLineId = ln.LineId) c
    WHERE ln.K IS NOT NULL AND c.C > 0
      AND ((ln.K = 2 AND c.C <> ln.Q) OR (ln.K IN (1, 3) AND c.S <> ln.Q))

    UNION ALL
    -- 90. NEVER ON THE WAY TWICE (B5, 62017): a row of a POSTED dispatch of the same item and serial not settled yet.
    --     The dispatch reads it after the per-item serial lock (5b), so two dispatches never both pass.
    --     THE ROW IS FOUND BY A MAX(Id) THROUGH IX_TransferPostingTracking_ItemSerial, never a TOP (1) ... ORDER BY the
    --     posting's time: per serial, that let the optimiser scan every posted dispatch in PostedAtUtc order (a row-goal
    --     plan), so its cost grew with the number of postings - 10,000 serials took 1.2 s with 45 postings, 17.7 s with
    --     1,045 and 92 s with 5,045 (the MAX: 0.05-0.12 s), under the source and serial locks. The latest by the row's
    --     Id, as fn_TransferSerial_LastEvent reads it; at most one row is ever on the way (Check 6), so the sentence is
    --     the same. The rows and the posting are read by SEEKS (FORCESEEK, 93 tests): estimating thousands of rows per
    --     serial, the optimiser otherwise hashed every posted dispatch for each serial (0.8-1.3 s for 10,000 serials with
    --     17 posted dispatches, growing with them; with the seeks 0.13 s).
    SELECT 90, N'Error', 62017, j.LineId, j.LineNumber, j.RowNumber,
           N'Serial no. ' + j.SX + N' of ' + j.ItemCode + N' is already on the way with ' + w.DispatchNumber + N' ('
           + w.OrderNumber + N': ' + w.FromCode + N' ' + NCHAR(8594) + N' ' + w.ToCode
           + N'): receive it first, or reverse that dispatch.'
    FROM j
    CROSS APPLY (SELECT DispatchNumber = p.DocumentNumber, OrderNumber = ISNULL(o.DocumentNumber, N''),
                        FromCode = ISNULL(fw.WarehouseCode, N''), ToCode = ISNULL(tw.WarehouseCode, N'')
                 FROM (SELECT Id = MAX(x.Id)
                       FROM inventory.TransferPostingTracking x WITH (FORCESEEK)
                       INNER JOIN inventory.TransferPostings px WITH (FORCESEEK) ON px.Id = x.PostingId AND px.Kind = N'Dispatch' AND px.Status = 2
                       WHERE x.ItemId = j.ItemId AND x.SerialNo = j.SerialNo AND x.SerialNo IS NOT NULL
                         AND x.DispatchTrackingId IS NULL AND x.SettledBase < x.QuantityBase) m
                 INNER JOIN inventory.TransferPostingTracking x ON x.Id = m.Id
                 INNER JOIN inventory.TransferPostings p ON p.Id = x.PostingId
                 INNER JOIN inventory.TransferOrders o   ON o.Id = p.TransferOrderId
                 INNER JOIN masterdata.Warehouses fw     ON fw.Id = p.FromWarehouseId
                 INNER JOIN masterdata.Warehouses tw     ON tw.Id = p.ToWarehouseId) w                             -- (93 tests)
    WHERE j.K = 2 AND j.SerialNo IS NOT NULL

    UNION ALL
    -- 100. WARNINGS (Check only; @ForLineId: that line's). A serial last received by a transfer into another warehouse
    SELECT 100, N'Warning', CAST(NULL AS INT), j.LineId, j.LineNumber, j.RowNumber,
           N'Serial no. ' + j.SX + N' was last received into ' + ISNULL(e.ToCode, N'') + N' by ' + ISNULL(e.PostingNumber, N'')
           + N' on ' + ISNULL(CONVERT(NVARCHAR(10), e.PostingDate, 103), N'') + N', not into ' + hd.FromCode
           + N': check it is really here.'
    FROM j
    CROSS JOIN hd
    CROSS APPLY inventory.fn_TransferSerial_LastEvent(j.ItemId, j.SerialNo) e
    WHERE j.K = 2 AND j.SerialNo IS NOT NULL AND j.SLen <= 50 AND e.Event = N'Received' AND e.ToWarehouseId <> hd.FromId
      AND (@ForLineId IS NULL OR j.LineId = @ForLineId)

    UNION ALL
    -- 101. A serial written off as lost by a receipt
    SELECT 101, N'Warning', NULL, j.LineId, j.LineNumber, j.RowNumber,
           N'Serial no. ' + j.SX + N' was written off as lost by ' + ISNULL(e.PostingNumber, N'') + N' on '
           + ISNULL(CONVERT(NVARCHAR(10), e.PostingDate, 103), N'') + N' (' + ISNULL(e.LossReasonName, N'') + N'): dispatch it only if it was found.'
    FROM j
    CROSS APPLY inventory.fn_TransferSerial_LastEvent(j.ItemId, j.SerialNo) e
    WHERE j.K = 2 AND j.SerialNo IS NOT NULL AND j.SLen <= 50 AND e.Event = N'Lost'
      AND (@ForLineId IS NULL OR j.LineId = @ForLineId)

    UNION ALL
    -- 102. An expiry in the past (once per line and date, B13)
    SELECT 102, N'Warning', NULL, j.LineId, j.LineNumber, MIN(j.RowNumber),
           MAX(j.P) + N': expiry ' + MAX(j.ExpX) + N' is in the past.'
    FROM j
    WHERE j.K IS NOT NULL AND j.ExpiryDate < CAST(SYSUTCDATETIME() AS DATE)
      AND (@ForLineId IS NULL OR j.LineId = @ForLineId)
    GROUP BY j.LineId, j.LineNumber, j.ExpiryDate

    UNION ALL
    -- 103. A batch that left before with another expiry (its latest posted dispatch row)
    SELECT 103, N'Warning', NULL, j.LineId, j.LineNumber, j.RowNumber,
           j.P + N': batch ' + j.BX + N' left with expiry ' + ISNULL(CONVERT(NVARCHAR(10), pb.ExpiryDate, 103), N'no expiry')
           + N' on ' + ISNULL(pb.DispatchNumber, N'') + N'; here it is ' + ISNULL(NULLIF(j.ExpX, N''), N'no expiry') + N'.'
    FROM j
    CROSS APPLY (SELECT TOP (1) x.ExpiryDate, DispatchNumber = p.DocumentNumber
                 FROM inventory.TransferPostingTracking x
                 INNER JOIN inventory.TransferPostings p ON p.Id = x.PostingId AND p.Kind = N'Dispatch' AND p.Status = 2
                 WHERE x.BatchNo = j.BatchNo AND x.BatchNo IS NOT NULL AND x.ItemId = j.ItemId AND x.DispatchTrackingId IS NULL
                 ORDER BY p.PostedAtUtc DESC, p.Id DESC) pb
    WHERE j.K = 1 AND j.BatchNo IS NOT NULL AND j.BLen <= 50
      AND (@ForLineId IS NULL OR j.LineId = @ForLineId)
      AND NOT ((pb.ExpiryDate IS NULL AND j.ExpiryDate IS NULL) OR pb.ExpiryDate = j.ExpiryDate)
) b;
GO

-- (90) WHY A DISPATCH OR A TRANSFER RECEIPT CANNOT BE REVERSED NOW, the posting's own rules (the order's are the
--      ReverseDispatch / ReverseReceipt rows of fn_TransferOrder_Blocks): one row per failed rule, the first (lowest
--      Seq) is the reason, none = allowed. Read by usp_TransferPosting_Reverse (thrown as it comes) and by
--      usp_TransferOrder_Get (the posting's ReverseBlockedReason). A RECEIPT BEFORE ITS DISPATCH: a dispatch whose goods
--      a posted receipt took (received or written off) waits for that receipt's reversal; a receipt only while the
--      destination still holds what it brought.
-- Re-created (93) from the body of script 90: + a RECEIPT whose serial (received or lost) is on a row of a POSTED
-- dispatch written after it cannot be reversed (Seq 3, 62013): reversing it would put the serial on the way twice.
CREATE OR ALTER FUNCTION inventory.fn_TransferPosting_ReverseBlock (@PostingId INT)
RETURNS TABLE
AS
RETURN
WITH p AS
(
    SELECT tp.Id, tp.Kind, tp.Status, tp.DocumentNumber, tp.ToWarehouseId, tp.TransitWarehouseId
    FROM inventory.TransferPostings tp
    WHERE tp.Id = @PostingId
),
r AS
(
    -- the posted receipts with a line on one of the dispatch's lines
    SELECT rp.Id, rp.DocumentNumber, rp.PostedAtUtc
    FROM inventory.TransferPostings rp
    WHERE rp.Kind = N'Receipt' AND rp.Status = 2
      AND EXISTS (SELECT 1 FROM inventory.TransferPostingLines rl
                  INNER JOIN inventory.TransferPostingLines dl ON dl.Id = rl.DispatchLineId
                  WHERE rl.PostingId = rp.Id AND dl.PostingId = @PostingId)
)
SELECT Seq = CAST(x.Seq AS INT), ErrorNumber = CAST(x.ErrorNumber AS INT), Message = CAST(x.Message AS NVARCHAR(400))
FROM
(
    SELECT Seq = 1, ErrorNumber = 62006, Message = CAST(N'Dispatch or receipt not found.' AS NVARCHAR(400))
    WHERE NOT EXISTS (SELECT 1 FROM p)

    UNION ALL
    SELECT 2, 62010, p.DocumentNumber + N' is already reversed.'
    FROM p WHERE p.Status = 3

    UNION ALL
    SELECT 3, 62013, p.DocumentNumber + N' has goods received by ' + rl.List
                     + CASE WHEN rn.N > 3 THEN N' and ' + CAST(rn.N - 3 AS NVARCHAR(10)) + N' more' ELSE N'' END
                     + N': reverse that receipt first.'
    FROM p
    CROSS APPLY (SELECT N = COUNT(*) FROM r) rn
    CROSS APPLY (SELECT List = STRING_AGG(t.DocumentNumber, N', ') WITHIN GROUP (ORDER BY t.PostedAtUtc, t.Id)
                 FROM (SELECT TOP (3) r.Id, r.DocumentNumber, r.PostedAtUtc FROM r ORDER BY r.PostedAtUtc, r.Id) t) rl
    WHERE p.Kind = N'Dispatch' AND p.Status = 2 AND rn.N > 0

    UNION ALL
    -- (93) a receipt whose serial (received or lost) left again with a POSTED dispatch written after it: reversing it
    --      would put the serial on the way twice. Before the stock sentence (Seq 4): the precise reason, even when the
    --      serial left again from the receiving warehouse itself. "After" = the dispatch row's Id is above the receipt
    --      row's, never the postings' PostedAtUtc: a posting takes its time when it STARTS, and a dispatch that waited
    --      on its source lock while this receipt committed would carry an earlier time than the receipt it follows. Its
    --      rows are written only after its on-the-way check (62017), so after this receipt's commit: a higher Id.
    --      PER RECEIPT ROW, THE FIRST LATER DISPATCH ROW (a MIN through IX_TransferPostingTracking_ItemSerial, the posting
    --      by a seek), then the first of those (93 tests): a TOP (1) ... ORDER BY the dispatch row's Id let the optimiser
    --      scan every tracking row in Id order against the receipt's rows (a row-goal plan) - with no serial dispatched
    --      again, the usual case, it read them all: 77-99 s for the Get of an order with a 10,000-serial receipt, which
    --      timed out the answer of Receive and Dispatch and receive after they had posted. The same first row: the
    --      smallest of the per-row smallest Ids.
    SELECT * FROM (SELECT TOP (1) Seq = 3, ErrorNumber = 62013,
                          Message = N'Cannot reverse: serial no. ' + rr.SerialNo + N' of ' + p.DocumentNumber
                                    + N' has been dispatched again with ' + p2.DocumentNumber + N': reverse that dispatch first.'
                   FROM p
                   INNER JOIN inventory.TransferPostingTracking rr ON rr.PostingId = p.Id AND rr.SerialNo IS NOT NULL
                   CROSS APPLY (SELECT Id = MIN(dx.Id)
                                FROM inventory.TransferPostingTracking dx WITH (FORCESEEK)
                                INNER JOIN inventory.TransferPostings px WITH (FORCESEEK) ON px.Id = dx.PostingId AND px.Kind = N'Dispatch' AND px.Status = 2
                                WHERE dx.ItemId = rr.ItemId AND dx.SerialNo = rr.SerialNo AND dx.SerialNo IS NOT NULL
                                  AND dx.DispatchTrackingId IS NULL AND dx.Id > rr.Id) m
                   INNER JOIN inventory.TransferPostingTracking d2 ON d2.Id = m.Id
                   INNER JOIN inventory.TransferPostings p2 ON p2.Id = d2.PostingId
                   WHERE p.Kind = N'Receipt' AND p.Status = 2
                   ORDER BY m.Id, rr.RowNumber) a3

    UNION ALL
    -- a receipt, per item: the destination must still hold what it brought
    SELECT * FROM (SELECT TOP (1) Seq = 4, ErrorNumber = 62007,
                          Message = N'Cannot reverse: ' + i.ItemCode + N' in ' + w.WarehouseCode + N' has only '
                                    + CAST(oh.Q AS NVARCHAR(20)) + N' left, but this receipt brought ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
                   FROM p
                   CROSS APPLY (SELECT m.ItemId, m.WarehouseId, Qty = SUM(m.QuantityBase)
                                FROM inventory.StockMovements m
                                WHERE m.DocumentFamily = N'Transfer' AND m.DocumentTypeCode = N'TRR' AND m.DocumentId = p.Id
                                  AND m.IsReversal = 0 AND m.WarehouseId = p.ToWarehouseId
                                GROUP BY m.ItemId, m.WarehouseId) x
                   CROSS APPLY (SELECT Q = ISNULL(SUM(s.QuantityBase), 0) FROM inventory.StockMovements s
                                WHERE s.ItemId = x.ItemId AND s.WarehouseId = x.WarehouseId) oh
                   INNER JOIN inventory.Items i       ON i.Id = x.ItemId
                   INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
                   WHERE p.Kind = N'Receipt' AND p.Status = 2 AND x.Qty > oh.Q
                   ORDER BY i.ItemCode) a4

    UNION ALL
    -- a dispatch, per item: the On the way warehouse must still hold what it sent (a safety net: while no posted receipt
    -- took its goods - Seq 3 - they are all still there)
    SELECT * FROM (SELECT TOP (1) Seq = 5, ErrorNumber = 62007,
                          Message = N'Cannot reverse: ' + i.ItemCode + N' in ' + w.WarehouseCode + N' has only '
                                    + CAST(oh.Q AS NVARCHAR(20)) + N' left, but this dispatch sent ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
                   FROM p
                   CROSS APPLY (SELECT m.ItemId, m.WarehouseId, Qty = SUM(m.QuantityBase)
                                FROM inventory.StockMovements m
                                WHERE m.DocumentFamily = N'Transfer' AND m.DocumentTypeCode = N'TRD' AND m.DocumentId = p.Id
                                  AND m.IsReversal = 0 AND m.WarehouseId = p.TransitWarehouseId
                                GROUP BY m.ItemId, m.WarehouseId) x
                   CROSS APPLY (SELECT Q = ISNULL(SUM(s.QuantityBase), 0) FROM inventory.StockMovements s
                                WHERE s.ItemId = x.ItemId AND s.WarehouseId = x.WarehouseId) oh
                   INNER JOIN inventory.Items i       ON i.Id = x.ItemId
                   INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
                   WHERE p.Kind = N'Dispatch' AND p.Status = 2 AND x.Qty > oh.Q
                   ORDER BY i.ItemCode) a5
) x;
GO

/* ================================================================== 7. The item procedures */

-- Re-created (93) from the body of script 87: + TrackingMode, RequiresExpiry, SerialLength after Note, Link (the first
-- result set; read by name). Nothing else.
CREATE OR ALTER PROCEDURE inventory.usp_Item_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT i.Id, i.ItemCode, i.ItemName, i.BrandId, b.BrandName, i.Model,
           i.ItemFamilyId, f.FamilyCode, f.FamilyName, i.CountryOfOrigin,
           i.DefaultWarehouseId, w.WarehouseCode, w.WarehouseName, i.Description,
           i.WarrantyMonths, i.MinQuantity, i.MaxQuantity, i.IsBivac, i.IsActive,
           OnHand = inventory.fn_StockOnHand(i.Id, NULL),
           FobCost = CAST(i.FobCost AS DECIMAL(18,2)),
           LastCost = CAST(i.LastCost AS DECIMAL(18,2)),
           AverageCost = CAST(i.AverageCost AS DECIMAL(18,2)),
           InventoryValue = CAST(inventory.fn_StockOnHand(i.Id, NULL) * i.AverageCost AS DECIMAL(18,2)),
           LastPurchaseCost = CAST(i.FobCost AS DECIMAL(18,2)),      -- kept for the current API mapping (= FOB)
           i.DefaultSupplierId, ds.PartyCode AS DefaultSupplierCode, ds.PartyName AS DefaultSupplierName, i.LeadTimeDays,
           PcPerContainer = cnt.PackingFormula,      -- from the item's Container unit
           PcPerContainerFromUnit = CAST(CASE WHEN cnt.PackingFormula IS NOT NULL THEN 1 ELSE 0 END AS BIT),
           i.WeightKg, i.VolumeCbm, i.OilQtyPerUnit,
           i.LastSupplierId, ls.PartyName AS LastSupplierName, i.LastPurchaseAtUtc,
           i.Note, i.Link,                           -- (87)
           i.TrackingMode, i.RequiresExpiry, i.SerialLength,   -- (93)
           i.CreatedAtUtc, i.CreatedBy, cu.FullName AS CreatedByName,
           i.UpdatedAtUtc, i.UpdatedBy, uu.FullName AS UpdatedByName, i.RowVersion
    FROM inventory.Items i
    INNER JOIN masterdata.Brands b       ON b.Id = i.BrandId
    INNER JOIN masterdata.ItemFamilies f ON f.Id = i.ItemFamilyId
    INNER JOIN masterdata.Warehouses w   ON w.Id = i.DefaultWarehouseId
    LEFT  JOIN masterdata.Parties ds     ON ds.Id = i.DefaultSupplierId
    LEFT  JOIN masterdata.Parties ls     ON ls.Id = i.LastSupplierId
    LEFT  JOIN security.Users cu ON cu.Id = i.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = i.UpdatedBy
    OUTER APPLY
    (
        SELECT TOP (1) u.PackingFormula
        FROM inventory.ItemUnits u INNER JOIN masterdata.UnitTypes t ON t.Id = u.UnitTypeId
        WHERE u.ItemId = i.Id AND t.IsContainer = 1
    ) cnt
    WHERE i.Id = @Id;

    SELECT u.Id, u.ItemId, u.UnitTypeId, ut.UnitTypeName, u.PackingFormula, u.SkuCode, u.Barcode,
           u.IsSalesUnit, u.IsPurchaseUnit, u.IsBaseUnit, IsContainerUnit = ut.IsContainer,
           u.LengthCm, u.WidthCm, u.HeightCm, u.WeightKg, u.RowVersion
    FROM inventory.ItemUnits u
    INNER JOIN masterdata.UnitTypes ut ON ut.Id = u.UnitTypeId
    WHERE u.ItemId = @Id
    ORDER BY u.IsBaseUnit DESC, u.PackingFormula, ut.UnitTypeName;

    SELECT fl.Id, fl.ItemId, fl.FileName, fl.ContentType, fl.SizeBytes, fl.IsItemImage, fl.CreatedAtUtc
    FROM inventory.ItemFiles fl
    WHERE fl.ItemId = @Id
    ORDER BY fl.IsItemImage DESC, fl.CreatedAtUtc DESC;
END
GO

-- (93) THE ITEM'S TRACKING (5.3.6.2), written the way usp_Item_SetNotes writes the note: the API calls it after the
--      item is created (always) or updated (only when the request carries trackingMode). A change applies to the next
--      dispatches (B10): goods on the way keep what they left with. "Item not found." is 56006 on purpose (404). Nothing
--      written when nothing differs.
CREATE OR ALTER PROCEDURE inventory.usp_Item_SetTracking
    @Id             INT,
    @TrackingMode   TINYINT,
    @RequiresExpiry BIT,
    @SerialLength   TINYINT = NULL,
    @UserId         INT     = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM inventory.Items WHERE Id = @Id) THROW 56006, 'Item not found.', 1;
    IF @TrackingMode IS NULL OR @TrackingMode NOT IN (0, 1, 2)
        THROW 56000, 'Tracking must be None, Batch numbers or Serial numbers.', 1;
    IF @SerialLength IS NOT NULL AND @TrackingMode <> 2
        THROW 56000, 'Serial no. length applies to serial-numbered items only.', 1;
    IF @SerialLength IS NOT NULL AND @SerialLength NOT BETWEEN 1 AND 50
        THROW 56000, 'Serial no. length must be between 1 and 50, or empty for any length.', 1;

    SET @RequiresExpiry = ISNULL(@RequiresExpiry, 0);

    UPDATE inventory.Items
    SET TrackingMode = @TrackingMode, RequiresExpiry = @RequiresExpiry, SerialLength = @SerialLength,
        UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id
      AND (TrackingMode <> @TrackingMode OR RequiresExpiry <> @RequiresExpiry
           OR ISNULL(CAST(SerialLength AS INT), -1) <> ISNULL(CAST(@SerialLength AS INT), -1));
END
GO

/* ================================================================== 8. The transfer procedures (5.3.7)

   Each re-created (93) from its CURRENT body (script 90's for the cores, the public dispatch / receive procedures and
   Reverse; 91's for Get; 92's for Search) plus the change its "Re-created (93)" line names, the changed lines marked
   (93); every 90 / 91 / 92 sentence, number, lock and check stays; every ledger INSERT stamps CreatedBy = @UserId and
   has no OUTPUT (W16). */

/* 13.16 POST A DISPATCH (internal: no transaction of its own; the caller holds one, the order's lock and its checks).
   In order (62000 unless said):
     1. the dates: the dispatch date required, at most one day ahead (the reader's time zone), not before the order
        date; the ETA required, not before the dispatch date;
     2. the lines: only those with pieces count (none: 62009); a line not on the order; negative pieces;
     3. not above To dispatch (62012); 4. no inactive item;
     5. one dispatch at a time from the source warehouse (an application lock held to the end of the transaction);
     6. the source holds the pieces, per item over the lines (62007; the out-of-stock sales setting does not apply);
   then the On the way warehouse of the destination branch (created when missing), the TRD number by the source branch,
   the posting and its lines (each line keeps its order line's number and the item's average of the moment), the ledger
   (per line: From -q, then On the way +q, both TRF_OUT) and the order lines' Dispatched. */
-- Re-created (93) from the body of script 90: + @Tracking; the batch, serial and expiry rules before the source lock
-- (step 4b), one lock per serial item after it (5b), the serial on the way after the stock check (6b), the posting
-- lines' TrackingKind and their rows (9b), the ledger per posting line and expiry date (10).
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_DispatchCore
    @Id             INT,
    @Date           DATE,
    @Eta            DATE,
    @ReferenceNo    NVARCHAR(100)  = NULL,
    @Notes          NVARCHAR(1000) = NULL,
    @Lines          inventory.tvp_TransferDispatchLine READONLY,
    @UserId         INT            = NULL,
    @PostingId      INT            = NULL OUTPUT,
    @DocumentNumber NVARCHAR(30)   = NULL OUTPUT,
    @Tracking       inventory.tvp_TransferDispatchTracking READONLY        -- (93) the rows of the tracked lines; omitted = none
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- The caller's transaction holds the order's lock: posting outside one would leave the counters unguarded.
    IF @@TRANCOUNT = 0
        THROW 62010, 'A transfer dispatch is posted inside its caller''s transaction.', 1;

    SET @PostingId = NULL;
    SET @DocumentNumber = NULL;

    DECLARE @Msg NVARCHAR(400), @No NVARCHAR(30), @OrderDate DATE, @FromId INT, @ToId INT, @FromCode NVARCHAR(20),
            @FromBranchId INT, @ToBranchId INT, @TransitId INT, @TransitBranchId INT, @TypeId INT, @Lock INT,
            @Resource NVARCHAR(255), @Now DATETIME2(3) = SYSUTCDATETIME(), @MovementDate DATETIME2(3);
    DECLARE @Tomorrow DATE = DATEADD(DAY, 1, CAST(@Now AS DATE));
    DECLARE @ErrNo INT, @SerialItemId INT, @SerialItemCode NVARCHAR(30), @Tracked BIT = 0;     -- (93)

    DECLARE @L TABLE
    (
        OrderLineId INT           NOT NULL PRIMARY KEY,
        LineNumber  INT           NOT NULL,
        ItemId      INT           NOT NULL,
        Qty         INT           NOT NULL,
        ToDispatch  INT           NOT NULL,
        Cost        DECIMAL(18,6) NULL,
        K           TINYINT       NULL          -- (93) the item's kind when the line is read: 2 Serial, 1 Batch, 3 Expiry
    );

    -- (93) 0. The batch and serial numbers as they are kept (fn_TrackingNo_Normalize), once per row
    DECLARE @T inventory.tvp_TransferDispatchTracking;
    INSERT INTO @T (TransferOrderLineId, RowNumber, BatchNo, SerialNo, ExpiryDate, QuantityBase)
    SELECT TransferOrderLineId, RowNumber,
           CASE WHEN BatchNo IS NOT NULL THEN inventory.fn_TrackingNo_Normalize(BatchNo) END,      -- a call only when there is a number
           CASE WHEN SerialNo IS NOT NULL THEN inventory.fn_TrackingNo_Normalize(SerialNo) END,
           ExpiryDate, QuantityBase
    FROM @Tracking;

    SELECT @No = ISNULL(o.DocumentNumber, N'this transfer order'), @OrderDate = o.DocumentDate,
           @FromId = o.FromWarehouseId, @ToId = o.ToWarehouseId,
           @FromCode = fw.WarehouseCode, @FromBranchId = fw.BranchId, @ToBranchId = tw.BranchId
    FROM inventory.TransferOrders o
    INNER JOIN masterdata.Warehouses fw ON fw.Id = o.FromWarehouseId
    INNER JOIN masterdata.Warehouses tw ON tw.Id = o.ToWarehouseId
    WHERE o.Id = @Id;
    IF @FromId IS NULL THROW 62006, 'Transfer order not found.', 1;

    -- 1. The dates (one day of tolerance ahead: the date is the reader's local one, the check is UTC)
    IF @Date IS NULL THROW 62000, 'The dispatch date is required.', 1;
    IF @Date > @Tomorrow THROW 62000, 'The dispatch date cannot be in the future.', 1;
    IF @Date < @OrderDate
    BEGIN
        SET @Msg = N'The dispatch date cannot be before the order date (' + CONVERT(NVARCHAR(10), @OrderDate, 103) + N').';
        THROW 62000, @Msg, 1;
    END
    IF @Eta IS NULL THROW 62000, 'The ETA is required.', 1;
    IF @Eta < @Date THROW 62000, 'The ETA cannot be before the dispatch date.', 1;

    -- 2. The lines: only those with pieces count; a line of another order, or pieces below 0, are refused
    IF NOT EXISTS (SELECT 1 FROM @Lines WHERE QuantityBase > 0)
        THROW 62009, 'Nothing to dispatch: type the pieces that leave.', 1;

    IF EXISTS (SELECT 1 FROM @Lines x
               WHERE x.QuantityBase <> 0
                 AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrderLines l WHERE l.Id = x.TransferOrderLineId AND l.TransferOrderId = @Id))
    BEGIN
        SET @Msg = N'A line of the dispatch is not on ' + @No + N'.';
        THROW 62000, @Msg, 1;
    END

    SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': the pieces dispatched cannot be negative.'
    FROM @Lines x
    INNER JOIN inventory.TransferOrderLines l ON l.Id = x.TransferOrderLineId AND l.TransferOrderId = @Id
    WHERE x.QuantityBase < 0
    ORDER BY l.LineNumber;
    IF @Msg IS NOT NULL THROW 62000, @Msg, 1;

    INSERT INTO @L (OrderLineId, LineNumber, ItemId, Qty, ToDispatch, K)                                         -- (93)
    SELECT l.Id, l.LineNumber, l.ItemId, x.QuantityBase,
           CASE WHEN l.OrderedBase - l.DispatchedBase - l.NotSentBase > 0 THEN l.OrderedBase - l.DispatchedBase - l.NotSentBase ELSE 0 END,
           CASE i.TrackingMode WHEN 2 THEN 2 WHEN 1 THEN 1 ELSE CASE WHEN i.RequiresExpiry = 1 THEN 3 END END      -- (93)
    FROM @Lines x
    INNER JOIN inventory.TransferOrderLines l ON l.Id = x.TransferOrderLineId AND l.TransferOrderId = @Id
    INNER JOIN inventory.Items i              ON i.Id = l.ItemId                                                   -- (93)
    WHERE x.QuantityBase > 0;

    -- 3. Not above what is left to dispatch on the line (Ordered - Dispatched - Not sent)
    SELECT TOP (1) @Msg = N'Line ' + CAST(x.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): ' + CAST(x.Qty AS NVARCHAR(20))
                          + N' pcs dispatched but only ' + CAST(x.ToDispatch AS NVARCHAR(20)) + N' are left to dispatch.'
    FROM @L x
    INNER JOIN inventory.Items i ON i.Id = x.ItemId
    WHERE x.Qty > x.ToDispatch
    ORDER BY x.LineNumber;
    IF @Msg IS NOT NULL THROW 62012, @Msg, 1;

    -- 4. An item made inactive since the release
    SELECT TOP (1) @Msg = N'Line ' + CAST(x.LineNumber AS NVARCHAR(10)) + N': item ' + i.ItemCode + N' is inactive.'
    FROM @L x
    INNER JOIN inventory.Items i ON i.Id = x.ItemId
    WHERE i.IsActive = 0
    ORDER BY x.LineNumber;
    IF @Msg IS NOT NULL THROW 62000, @Msg, 1;

    -- (93) 4b. THE BATCH, SERIAL AND EXPIRY ROWS (fn_TransferDispatch_TrackingProblems, the dialog's own rules): the
    --      format, count and duplicate errors BEFORE the source lock (B17), so a slow check never blocks the warehouse.
    --      An untracked dispatch (no row, no line of a tracked item) runs script 90's checks only.
    IF EXISTS (SELECT 1 FROM @T) OR EXISTS (SELECT 1 FROM @L WHERE K IS NOT NULL)
    BEGIN
        SET @Tracked = 1;
        SELECT TOP (1) @ErrNo = q.ErrorNumber, @Msg = q.Message
        FROM inventory.fn_TransferDispatch_TrackingProblems(@Id, @Lines, @T, NULL) q
        WHERE q.Severity = N'Error' AND q.Seq < 90
        ORDER BY q.Seq, q.LineNumber, q.RowNumber;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;
    END

    -- 5. ONE DISPATCH AT A TIME FROM A WAREHOUSE: two orders from LKS-01 would otherwise both read the same stock and
    --    both pass step 6. Held until the caller's transaction ends.
    SET @Resource = N'inventory.TransferDispatch.' + CAST(@FromId AS NVARCHAR(10));
    EXEC @Lock = sp_getapplock @Resource = @Resource, @LockMode = N'Exclusive', @LockOwner = N'Transaction', @LockTimeout = 30000;
    IF @Lock < 0
    BEGIN
        SET @Msg = N'Another dispatch from ' + ISNULL(@FromCode, N'this warehouse') + N' is being posted. Try again in a moment.';
        THROW 62010, @Msg, 1;
    END

    -- (93) 5b. ONE DISPATCH OF AN ITEM'S SERIALS AT A TIME, from any warehouse (B5): two dispatches of one serial from two
    --      warehouses would otherwise both pass step 6b. One lock per serial item, in ItemId order, so two dispatches
    --      never wait for each other in a circle. Held until the caller's transaction ends.
    SET @SerialItemId = 0;
    WHILE 1 = 1
    BEGIN
        SET @SerialItemCode = NULL;
        SELECT TOP (1) @SerialItemId = x.ItemId, @SerialItemCode = i.ItemCode
        FROM @L x
        INNER JOIN inventory.Items i ON i.Id = x.ItemId
        WHERE x.K = 2 AND x.ItemId > @SerialItemId
        ORDER BY x.ItemId;
        IF @SerialItemCode IS NULL BREAK;

        SET @Resource = N'inventory.TransferSerial.' + CAST(@SerialItemId AS NVARCHAR(10));
        EXEC @Lock = sp_getapplock @Resource = @Resource, @LockMode = N'Exclusive', @LockOwner = N'Transaction', @LockTimeout = 30000;
        IF @Lock < 0
        BEGIN
            SET @Msg = N'Another dispatch of ' + @SerialItemCode + N' serial numbers is being posted. Try again in a moment.';
            THROW 62010, @Msg, 1;
        END
    END

    -- 6. The source holds the pieces, per item over the lines (the same item may be on two lines in two units)
    SELECT TOP (1) @Msg = N'Insufficient stock for ' + i.ItemCode + N' in ' + @FromCode + N': available '
                          + CAST(oh.Q AS NVARCHAR(20)) + N', required ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
    FROM (SELECT ItemId, Qty = SUM(Qty), FirstLine = MIN(LineNumber) FROM @L GROUP BY ItemId) x
    INNER JOIN inventory.Items i ON i.Id = x.ItemId
    CROSS APPLY (SELECT Q = ISNULL(SUM(m.QuantityBase), 0) FROM inventory.StockMovements m
                 WHERE m.ItemId = x.ItemId AND m.WarehouseId = @FromId) oh
    WHERE x.Qty > oh.Q
    ORDER BY x.FirstLine;
    IF @Msg IS NOT NULL THROW 62007, @Msg, 1;

    -- (93) 6b. NEVER ON THE WAY TWICE (62017), read under the serial locks of 5b
    IF EXISTS (SELECT 1 FROM @T WHERE SerialNo IS NOT NULL)
    BEGIN
        SELECT TOP (1) @ErrNo = q.ErrorNumber, @Msg = q.Message
        FROM inventory.fn_TransferDispatch_TrackingProblems(@Id, @Lines, @T, NULL) q
        WHERE q.Seq = 90
        ORDER BY q.LineNumber, q.RowNumber;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;
    END

    -- 7. The goods travel in the On the way warehouse of the DESTINATION branch (created when it is missing)
    EXEC masterdata.usp_Warehouse_EnsureTransit @BranchId = @ToBranchId, @UserId = @UserId, @WarehouseId = @TransitId OUTPUT;
    SELECT @TransitBranchId = BranchId FROM masterdata.Warehouses WHERE Id = @TransitId;

    -- 8. The number, by the source branch (an inactive TRD type is refused by Blocks, Seq 83, and again here: 62008)
    SELECT @TypeId = Id FROM inventory.DocumentTypes WHERE Code = N'TRD';
    EXEC inventory.usp_DocumentType_NextNumber @Code = N'TRD', @DocumentNumber = @DocumentNumber OUTPUT, @BranchId = @FromBranchId;

    -- 9. The posting and its lines. The cost is the item's average now, frozen for information: it moves nothing.
    UPDATE x SET Cost = i.AverageCost
    FROM @L x INNER JOIN inventory.Items i ON i.Id = x.ItemId;

    INSERT INTO inventory.TransferPostings (TransferOrderId, DocumentTypeId, Kind, DocumentNumber, PostingDate, Eta, BranchId,
                                           FromWarehouseId, ToWarehouseId, TransitWarehouseId, ReferenceNo, Notes, PostedWithId,
                                           Status, TotalQuantityBase, TotalLostBase, ValueBase, LostValueBase, PostedAtUtc, PostedBy)
    SELECT @Id, @TypeId, N'Dispatch', @DocumentNumber, @Date, @Eta, @FromBranchId,
           @FromId, @ToId, @TransitId, NULLIF(LTRIM(RTRIM(@ReferenceNo)), N''), NULLIF(LTRIM(RTRIM(@Notes)), N''), NULL,
           2, SUM(x.Qty), 0, CAST(ROUND(SUM(CAST(x.Qty AS DECIMAL(18,6)) * ISNULL(x.Cost, 0)), 2) AS DECIMAL(18,2)), 0, @Now, @UserId
    FROM @L x;
    SET @PostingId = SCOPE_IDENTITY();

    -- (93) a line that carries rows keeps the kind they were checked against (B3); any other line NULL, as in script 90
    INSERT INTO inventory.TransferPostingLines (PostingId, LineNumber, TransferOrderLineId, ItemId, DispatchLineId, TransitWarehouseId,
                                                QuantityBase, LostBase, LossReasonCode, LossNote, SettledBase, UnitCostBase, LossUnitCostBase,
                                                TrackingKind)
    SELECT @PostingId, x.LineNumber, x.OrderLineId, x.ItemId, NULL, @TransitId, x.Qty, 0, NULL, NULL, 0, x.Cost, NULL,
           CASE WHEN EXISTS (SELECT 1 FROM @T t WHERE t.TransferOrderLineId = x.OrderLineId) THEN x.K END                -- (93)
    FROM @L x
    ORDER BY x.LineNumber;

    -- (93) 9b. The rows: one per serial no., per batch or per expiry group, in the order typed (B7: never on the ledger)
    IF @Tracked = 1
        INSERT INTO inventory.TransferPostingTracking (PostingLineId, PostingId, ItemId, RowNumber, Kind, BatchNo, SerialNo, ExpiryDate,
                                                       QuantityBase, LostBase, SettledBase, DispatchTrackingId)
        SELECT pl.Id, @PostingId, pl.ItemId, ROW_NUMBER() OVER (PARTITION BY t.TransferOrderLineId ORDER BY t.RowNumber), pl.TrackingKind,
               CASE WHEN pl.TrackingKind = 1 THEN t.BatchNo END, CASE WHEN pl.TrackingKind = 2 THEN t.SerialNo END, t.ExpiryDate,
               t.QuantityBase, 0, 0, NULL
        FROM @T t
        INNER JOIN inventory.TransferPostingLines pl ON pl.PostingId = @PostingId AND pl.TransferOrderLineId = t.TransferOrderLineId
        WHERE pl.TrackingKind IS NOT NULL;

    -- 10. The ledger, per posting line: the source -q, then On the way +q (each in its warehouse's branch), dated the
    --     dispatch date at the time of posting (inventory.usp_StockDocument_Post's rule). (93) Per posting line AND
    --     EXPIRY DATE (B7): a tracked line one pair per distinct ExpiryDate of its rows (NULL a group) with the group's
    --     pcs; an untracked line one pair of its pcs without expiry - script 90's rows exactly.
    SET @MovementDate = DATEADD(SECOND, DATEDIFF(SECOND, CAST(@Now AS DATE), @Now), CAST(@Date AS DATETIME2(3)));

    INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                          DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber,
                                          ReasonCode, ExpiryDate, IsReversal, CreatedBy)
    SELECT @MovementDate, pl.ItemId, g.WarehouseId, g.BranchId, g.Sign * e.Qty, pl.UnitCostBase,                 -- (93)
           N'Transfer', N'TRD', @PostingId, pl.Id, @DocumentNumber,
           N'TRF_OUT', e.ExpiryDate, 0, @UserId                                                                  -- (93)
    FROM inventory.TransferPostingLines pl
    CROSS APPLY (SELECT t.ExpiryDate, Qty = SUM(t.QuantityBase)                                                    -- (93)
                 FROM inventory.TransferPostingTracking t
                 WHERE t.PostingLineId = pl.Id AND pl.TrackingKind IS NOT NULL
                 GROUP BY t.ExpiryDate
                 UNION ALL
                 SELECT CAST(NULL AS DATE), pl.QuantityBase
                 WHERE pl.TrackingKind IS NULL) e
    CROSS APPLY (VALUES (1, @FromId, @FromBranchId, -1),
                        (2, @TransitId, @TransitBranchId, 1)) g (Leg, WarehouseId, BranchId, Sign)
    WHERE pl.PostingId = @PostingId
    ORDER BY pl.LineNumber, CASE WHEN e.ExpiryDate IS NULL THEN 0 ELSE 1 END, e.ExpiryDate, g.Leg;               -- (93)

    -- 11. The order lines' Dispatched (posted, not reversed postings only)
    UPDATE l SET DispatchedBase = l.DispatchedBase + x.Qty
    FROM inventory.TransferOrderLines l
    INNER JOIN @L x ON x.OrderLineId = l.Id;
END
GO

/* 13.17 DISPATCH (Blocks, Dispatch: a released order, not closed, something to dispatch, TRD active, the warehouses, some
   stock at From): the core above, the order's header stamp and the audit "{TRD}: {n} line(s), {pcs} pcs, ETA {date}.".
   Result set: PostingId, DocumentNumber (the API answers "{TRD} posted: {q} pcs left {From}."). */
-- Re-created (93) from the body of script 90: + @Tracking (passed to the core); the audit adds the tracking counts.
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_Dispatch
    @Id             INT,
    @RowVersion     BINARY(8)      = NULL,
    @Date           DATE,
    @Eta            DATE,
    @ReferenceNo    NVARCHAR(100)  = NULL,
    @Notes          NVARCHAR(1000) = NULL,
    @Lines          inventory.tvp_TransferDispatchLine READONLY,
    @UserId         INT            = NULL,
    @PostingId      INT            = NULL OUTPUT,
    @DocumentNumber NVARCHAR(30)   = NULL OUTPUT,
    @Tracking       inventory.tvp_TransferDispatchTracking READONLY        -- (93)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @Status TINYINT, @Now DATETIME2(3) = SYSUTCDATETIME();

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = Status FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NOT NULL AND @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;

        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
        WHERE b.Action = N'Dispatch' AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        EXEC inventory.usp_TransferOrder_DispatchCore @Id = @Id, @Date = @Date, @Eta = @Eta, @ReferenceNo = @ReferenceNo,
             @Notes = @Notes, @Lines = @Lines, @UserId = @UserId,
             @PostingId = @PostingId OUTPUT, @DocumentNumber = @DocumentNumber OUTPUT,
             @Tracking = @Tracking;                                                                               -- (93)

        -- The order's RowVersion moves with its postings: a page opened before the dispatch must reload before it acts.
        UPDATE inventory.TransferOrders SET UpdatedAtUtc = @Now, UpdatedBy = @UserId WHERE Id = @Id;

        INSERT INTO inventory.TransferOrderAudit (TransferOrderId, PostingId, Action, Details, UserId)
        SELECT @Id, p.Id, N'Dispatched',
               LEFT(p.DocumentNumber + N': ' + CAST(n.Lines AS NVARCHAR(10)) + N' line(s), ' + CAST(p.TotalQuantityBase AS NVARCHAR(20))
                    + N' pcs, ETA ' + CONVERT(NVARCHAR(10), p.Eta, 103) + N'.'
                    -- (93) the rows it carries, their non-zero counts
                    + CASE WHEN tk.S + tk.B + tk.E > 0
                           THEN N' ' + STUFF(CONCAT(CASE WHEN tk.S > 0 THEN N', ' + CAST(tk.S AS NVARCHAR(10)) + N' serial no(s)' END,
                                                    CASE WHEN tk.B > 0 THEN N', ' + CAST(tk.B AS NVARCHAR(10)) + N' batch(es)' END,
                                                    CASE WHEN tk.E > 0 THEN N', ' + CAST(tk.E AS NVARCHAR(10)) + N' expiry date(s)' END), 1, 2, N'') + N'.'
                           ELSE N'' END, 500),
               @UserId
        FROM inventory.TransferPostings p
        CROSS APPLY (SELECT Lines = COUNT(*) FROM inventory.TransferPostingLines pl WHERE pl.PostingId = p.Id) n
        CROSS APPLY (SELECT S = ISNULL(SUM(CASE WHEN t.Kind = 2 THEN 1 ELSE 0 END), 0),                          -- (93)
                            B = ISNULL(SUM(CASE WHEN t.Kind = 1 THEN 1 ELSE 0 END), 0),
                            E = ISNULL(SUM(CASE WHEN t.Kind = 3 THEN 1 ELSE 0 END), 0)
                     FROM inventory.TransferPostingTracking t WHERE t.PostingId = p.Id) tk
        WHERE p.Id = @PostingId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT PostingId = @PostingId, DocumentNumber = @DocumentNumber;
END
GO

/* 13.18 POST A TRANSFER RECEIPT (internal: no transaction of its own; the caller holds one, the order's lock and its
   checks). Each row receives one dispatch line. In order (62000 unless said):
     1. the dispatch line is on a POSTED dispatch of this order; 2. received not below 0;
     3. received not above what is on the way on that dispatch line (62012);
     4. "Nothing more will arrive": the rest (on the way - received) is LOST and needs a reason (Damaged, Missing,
        Wrongly counted at dispatch, Other with a note);
     5. rows that receive and lose nothing are ignored; none left: 62009;
     6. the receipt date required, at most one day ahead, not before any dispatch it receives;
     7. the destination still fit (Blocks Receive, Seq 92: its sentences in one place);
     8. a safety net: the On the way warehouse holds what is received and written off (62007);
   then the TRR number by the destination branch, the posting and its lines (1..n, dispatch then line; the dispatch
   line's frozen cost; the item's average now on a line with a loss), the ledger (per line, the legs with pieces: On the
   way -received and To +received, TRF_IN, at the dispatch's cost; On the way -lost, TRF_LOSS, at the average - the only
   leg of a transfer that changes the company's stock), the dispatch lines' Settled and the order lines' Received and
   Lost. @PostedWithId: the dispatch of a "Dispatch and receive".
   THE MOVEMENT DATE is the receipt date at the time of posting, but never before the latest ledger row in the On the
   way warehouse of the dispatch lines it receives (their dispatch rows, their earlier receipts and every reversal of
   those) + 1 second: a receipt typed the next morning for yesterday, after an earlier receipt was reversed today, would
   otherwise take the pieces out of On the way before that reversal put them back, and the warehouse's running balance
   would dip below 0. */
-- Re-created (93) from the body of script 90: + @Tracking; a line that left with rows is received with them (step 1b),
-- its Lost from them (4), its rows (10b), the ledger per expiry date (11), the dispatch rows' Settled (12).
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_ReceiveCore
    @Id             INT,
    @Date           DATE,
    @ReferenceNo    NVARCHAR(100)  = NULL,
    @Notes          NVARCHAR(1000) = NULL,
    @Lines          inventory.tvp_TransferReceiptLine READONLY,
    @UserId         INT            = NULL,
    @PostingId      INT            = NULL OUTPUT,
    @DocumentNumber NVARCHAR(30)   = NULL OUTPUT,
    @PostedWithId   INT            = NULL,
    @Tracking       inventory.tvp_TransferReceiptTracking READONLY         -- (93) per dispatch row received / lost; omitted = none
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @@TRANCOUNT = 0
        THROW 62010, 'A transfer receipt is posted inside its caller''s transaction.', 1;

    SET @PostingId = NULL;
    SET @DocumentNumber = NULL;

    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @No NVARCHAR(30), @FromId INT, @ToId INT, @ToBranchId INT, @TypeId INT,
            @Now DATETIME2(3) = SYSUTCDATETIME(), @MovementDate DATETIME2(3), @Latest DATETIME2(3);
    DECLARE @Tomorrow DATE = DATEADD(DAY, 1, CAST(@Now AS DATE));

    DECLARE @R TABLE
    (
        DispatchLineId     INT           NOT NULL PRIMARY KEY,
        DispatchId         INT           NOT NULL,
        DispatchNumber     NVARCHAR(30)  NOT NULL,
        DispatchDate       DATE          NOT NULL,
        DispatchPostedAt   DATETIME2(3)  NOT NULL,
        DispatchLineNumber INT           NOT NULL,
        OrderLineId        INT           NOT NULL,
        ItemId             INT           NOT NULL,
        TransitId          INT           NOT NULL,
        UnitCost           DECIMAL(18,6) NULL,
        OnTheWay           INT           NOT NULL,
        Received           INT           NOT NULL,
        NothingMore        BIT           NOT NULL,
        Lost               INT           NOT NULL DEFAULT (0),
        ReasonCode         NVARCHAR(20)  NULL,
        Note               NVARCHAR(300) NULL,
        LossCost           DECIMAL(18,6) NULL,
        Seq                INT           NULL,
        TrackingKind       TINYINT       NULL        -- (93) the dispatch line's: it left with rows (B3)
    );

    -- (93) the receipt's batch, serial and expiry rows, with the dispatch row each one receives
    DECLARE @RT TABLE
    (
        DispatchTrackingId INT          NOT NULL PRIMARY KEY,
        DispatchLineId     INT          NULL,
        Kind               TINYINT      NULL,
        RowNumber          INT          NULL,
        SerialNo           NVARCHAR(50) NULL,
        BatchNo            NVARCHAR(50) NULL,
        ExpiryDate         DATE         NULL,
        OnTheWay           INT          NULL,
        Received           INT          NOT NULL,
        Lost               INT          NOT NULL,
        OnPostedDispatch   BIT          NOT NULL
    );

    SELECT @No = ISNULL(o.DocumentNumber, N'this transfer order'), @FromId = o.FromWarehouseId, @ToId = o.ToWarehouseId,
           @ToBranchId = tw.BranchId
    FROM inventory.TransferOrders o
    INNER JOIN masterdata.Warehouses tw ON tw.Id = o.ToWarehouseId
    WHERE o.Id = @Id;
    IF @ToId IS NULL THROW 62006, 'Transfer order not found.', 1;

    -- 1. Each row receives a line of a dispatch of this order that is still posted
    IF EXISTS (SELECT 1 FROM @Lines x
               WHERE NOT EXISTS (SELECT 1
                                 FROM inventory.TransferPostingLines dl
                                 INNER JOIN inventory.TransferPostings dp ON dp.Id = dl.PostingId
                                 WHERE dl.Id = x.DispatchLineId AND dl.DispatchLineId IS NULL
                                   AND dp.TransferOrderId = @Id AND dp.Kind = N'Dispatch' AND dp.Status = 2))
    BEGIN
        SET @Msg = N'A line of the receipt is not on a dispatch of ' + @No + N' that is still posted.';
        THROW 62000, @Msg, 1;
    END

    INSERT INTO @R (DispatchLineId, DispatchId, DispatchNumber, DispatchDate, DispatchPostedAt, DispatchLineNumber, OrderLineId,
                    ItemId, TransitId, UnitCost, OnTheWay, Received, NothingMore, ReasonCode, Note, TrackingKind)  -- (93)
    SELECT dl.Id, dp.Id, dp.DocumentNumber, dp.PostingDate, dp.PostedAtUtc, dl.LineNumber, dl.TransferOrderLineId,
           dl.ItemId, dl.TransitWarehouseId, dl.UnitCostBase, dl.QuantityBase - dl.SettledBase, x.ReceivedBase,
           ISNULL(x.NothingMoreWillArrive, 0),
           NULLIF(UPPER(LTRIM(RTRIM(x.LossReasonCode))), N''), NULLIF(LTRIM(RTRIM(x.LossNote)), N''),
           dl.TrackingKind                                                                                       -- (93)
    FROM @Lines x
    INNER JOIN inventory.TransferPostingLines dl ON dl.Id = x.DispatchLineId
    INNER JOIN inventory.TransferPostings dp     ON dp.Id = dl.PostingId;

    -- dispatch then line: the receipt's line numbers, and the order every "first failing" below is looked for in
    UPDATE r SET Seq = s.Seq
    FROM @R r
    INNER JOIN (SELECT DispatchLineId, Seq = ROW_NUMBER() OVER (ORDER BY DispatchPostedAt, DispatchId, DispatchLineNumber) FROM @R) s
            ON s.DispatchLineId = r.DispatchLineId;

    -- (93) 1b. THE BATCH, SERIAL AND EXPIRY ROWS (5.3.7.3): a dispatch line that left with rows is received with them,
    --      whatever the item says now; one that left without is received without (B3). Each row is a dispatch row of
    --      a line of this receipt; received + lost never above the row's on the way (under the order's lock, which
    --      every receipt and reversal of this order takes first). The first failing row: dispatch, line, row.
    IF EXISTS (SELECT 1 FROM @Tracking)
    BEGIN
        IF (SELECT COUNT(*) FROM @Tracking) > 10000
            THROW 62016, 'A receipt holds at most 10,000 batch, serial or expiry rows: receive one dispatch at a time.', 1;

        INSERT INTO @RT (DispatchTrackingId, DispatchLineId, Kind, RowNumber, SerialNo, BatchNo, ExpiryDate, OnTheWay, Received, Lost,
                         OnPostedDispatch)
        SELECT x.DispatchTrackingId, d.PostingLineId, d.Kind, d.RowNumber, d.SerialNo, d.BatchNo, d.ExpiryDate,
               d.QuantityBase - d.SettledBase, x.ReceivedBase, x.LostBase,
               CASE WHEN d.Id IS NOT NULL AND d.DispatchTrackingId IS NULL AND dp.Kind = N'Dispatch' AND dp.Status = 2
                         AND dp.TransferOrderId = @Id THEN 1 ELSE 0 END
        FROM @Tracking x
        LEFT JOIN inventory.TransferPostingTracking d ON d.Id = x.DispatchTrackingId
        LEFT JOIN inventory.TransferPostings dp       ON dp.Id = d.PostingId;

        IF EXISTS (SELECT 1 FROM @RT WHERE OnPostedDispatch = 0)
        BEGIN
            SET @Msg = N'A batch, serial or expiry row of the receipt is not on a dispatch of ' + @No + N' that is still posted.';
            THROW 62000, @Msg, 1;
        END

        SELECT TOP (1) @Msg = N'A batch, serial or expiry row of the receipt is not on ' + dp.DocumentNumber + N' line '
                              + CAST(dl.LineNumber AS NVARCHAR(10)) + N'.'
        FROM @RT t
        INNER JOIN inventory.TransferPostingLines dl ON dl.Id = t.DispatchLineId
        INNER JOIN inventory.TransferPostings dp     ON dp.Id = dl.PostingId
        WHERE NOT EXISTS (SELECT 1 FROM @R r WHERE r.DispatchLineId = t.DispatchLineId)
        ORDER BY dp.PostedAtUtc, dp.Id, dl.LineNumber, t.RowNumber;
        IF @Msg IS NOT NULL THROW 62000, @Msg, 1;

        SELECT TOP (1) @Msg = r.DispatchNumber + N' line ' + CAST(r.DispatchLineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode
                              + N') left without batch, serial or expiry details: receive it without them.'
        FROM @RT t
        INNER JOIN @R r ON r.DispatchLineId = t.DispatchLineId
        INNER JOIN inventory.Items i ON i.Id = r.ItemId
        WHERE r.TrackingKind IS NULL
        ORDER BY r.Seq, t.RowNumber;
        IF @Msg IS NOT NULL THROW 62000, @Msg, 1;

        SELECT TOP (1) @Msg = r.DispatchNumber + N' line ' + CAST(r.DispatchLineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode
                              + N'): the pieces received or written off cannot be negative.'
        FROM @RT t
        INNER JOIN @R r ON r.DispatchLineId = t.DispatchLineId
        INNER JOIN inventory.Items i ON i.Id = r.ItemId
        WHERE t.Received < 0 OR t.Lost < 0
        ORDER BY r.Seq, t.RowNumber;
        IF @Msg IS NOT NULL THROW 62000, @Msg, 1;

        SELECT TOP (1) @Msg = r.DispatchNumber + N' line ' + CAST(r.DispatchLineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode
                              + N'): serial no. ' + ISNULL(t.SerialNo, N'') + N' either arrived or is lost, not both.'
        FROM @RT t
        INNER JOIN @R r ON r.DispatchLineId = t.DispatchLineId
        INNER JOIN inventory.Items i ON i.Id = r.ItemId
        WHERE t.Kind = 2 AND CAST(t.Received AS BIGINT) + t.Lost > 1      -- BIGINT: two huge numbers typed never overflow (8115)
        ORDER BY r.Seq, t.RowNumber;
        IF @Msg IS NOT NULL THROW 62000, @Msg, 1;

        SELECT TOP (1) @Msg = r.DispatchNumber + N' line ' + CAST(r.DispatchLineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                              + CASE t.Kind WHEN 2 THEN N'serial no. ' + ISNULL(t.SerialNo, N'') + N' is no longer on the way.'
                                     ELSE CASE t.Kind WHEN 1 THEN N'batch ' + ISNULL(t.BatchNo, N'')
                                                      ELSE N'expiry ' + ISNULL(CONVERT(NVARCHAR(10), t.ExpiryDate, 103), N'') END
                                          + N': ' + CAST(t.Received AS NVARCHAR(20)) + N' pcs received and ' + CAST(t.Lost AS NVARCHAR(20))
                                          + N' written off, but only ' + CAST(t.OnTheWay AS NVARCHAR(20)) + N' are on the way.' END
        FROM @RT t
        INNER JOIN @R r ON r.DispatchLineId = t.DispatchLineId
        INNER JOIN inventory.Items i ON i.Id = r.ItemId
        WHERE CAST(t.Received AS BIGINT) + t.Lost > t.OnTheWay
        ORDER BY r.Seq, t.RowNumber;
        IF @Msg IS NOT NULL THROW 62012, @Msg, 1;
    END

    -- (93) a line that left with rows is received with them: some rows when it receives or writes off anything ...
    SELECT TOP (1) @Msg = r.DispatchNumber + N' line ' + CAST(r.DispatchLineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                          + CASE r.TrackingKind WHEN 2 THEN N'tick the serial numbers that arrived (Serial nos.' + NCHAR(8230) + N').'
                                                WHEN 1 THEN N'say what arrived of each batch (Batches' + NCHAR(8230) + N').'
                                                ELSE N'say what arrived of each expiry date (Expiry dates' + NCHAR(8230) + N').' END
    FROM @R r
    INNER JOIN inventory.Items i ON i.Id = r.ItemId
    WHERE r.TrackingKind IS NOT NULL AND (r.Received > 0 OR r.NothingMore = 1)
      AND NOT EXISTS (SELECT 1 FROM @RT t WHERE t.DispatchLineId = r.DispatchLineId)
    ORDER BY r.Seq;
    IF @Msg IS NOT NULL THROW 62016, @Msg, 1;

    -- ... and its Received is the rows' sum
    SELECT TOP (1) @Msg = r.DispatchNumber + N' line ' + CAST(r.DispatchLineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode
                          + N'): the rows add up to ' + CAST(x.Received AS NVARCHAR(20)) + N' pcs received, but the line says '
                          + CAST(r.Received AS NVARCHAR(20)) + N': open Receive' + NCHAR(8230) + N' again.'
    FROM @R r
    INNER JOIN inventory.Items i ON i.Id = r.ItemId
    INNER JOIN (SELECT DispatchLineId, Received = SUM(Received) FROM @RT GROUP BY DispatchLineId) x ON x.DispatchLineId = r.DispatchLineId
    WHERE r.TrackingKind IS NOT NULL AND x.Received <> r.Received
    ORDER BY r.Seq;
    IF @Msg IS NOT NULL THROW 62016, @Msg, 1;

    -- 2. Not below 0
    SELECT TOP (1) @Msg = r.DispatchNumber + N' line ' + CAST(r.DispatchLineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode
                          + N'): the pieces received cannot be negative.'
    FROM @R r INNER JOIN inventory.Items i ON i.Id = r.ItemId
    WHERE r.Received < 0
    ORDER BY r.Seq;
    IF @Msg IS NOT NULL THROW 62000, @Msg, 1;

    -- 3. Not above what is on the way on the dispatch line
    SELECT TOP (1) @Msg = r.DispatchNumber + N' line ' + CAST(r.DispatchLineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                          + CAST(r.Received AS NVARCHAR(20)) + N' pcs received but only ' + CAST(r.OnTheWay AS NVARCHAR(20)) + N' are on the way.'
    FROM @R r INNER JOIN inventory.Items i ON i.Id = r.ItemId
    WHERE r.Received > r.OnTheWay
    ORDER BY r.Seq;
    IF @Msg IS NOT NULL THROW 62012, @Msg, 1;

    -- 4. "Nothing more will arrive": the rest is lost and says why. A reason sent with nothing lost is not kept.
    --    (93) A line that left with rows: its Lost is its rows' (B6, which piece is lost); its "Nothing more will
    --    arrive" is not read.
    UPDATE r SET Lost = CASE WHEN r.TrackingKind IS NOT NULL
                             THEN ISNULL((SELECT SUM(t.Lost) FROM @RT t WHERE t.DispatchLineId = r.DispatchLineId), 0)
                             WHEN r.NothingMore = 1 THEN r.OnTheWay - r.Received ELSE 0 END
    FROM @R r;
    UPDATE @R SET ReasonCode = NULL, Note = NULL WHERE Lost = 0;

    SELECT TOP (1) @Msg = r.DispatchNumber + N' line ' + CAST(r.DispatchLineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                          + CASE WHEN r.ReasonCode IS NULL THEN N'choose why the rest will not arrive.'
                                 WHEN r.ReasonCode NOT IN (N'DAMAGED', N'MISSING', N'DISPATCHCOUNT', N'OTHER') THEN N'unknown reason.'
                                 ELSE N'say what happened in the note (reason Other).' END
    FROM @R r INNER JOIN inventory.Items i ON i.Id = r.ItemId
    WHERE r.Lost > 0
      AND (r.ReasonCode IS NULL OR r.ReasonCode NOT IN (N'DAMAGED', N'MISSING', N'DISPATCHCOUNT', N'OTHER')
           OR (r.ReasonCode = N'OTHER' AND r.Note IS NULL))
    ORDER BY r.Seq;
    IF @Msg IS NOT NULL THROW 62000, @Msg, 1;

    -- 5. Rows that receive and lose nothing are ignored ((93) a tracked line whose rows are all 0 / 0 too)
    DELETE FROM @R WHERE Received = 0 AND Lost = 0;
    IF NOT EXISTS (SELECT 1 FROM @R)
        THROW 62009, 'Nothing to receive: type the pieces that arrived, or tick Nothing more will arrive.', 1;

    UPDATE r SET Seq = s.Seq
    FROM @R r
    INNER JOIN (SELECT DispatchLineId, Seq = ROW_NUMBER() OVER (ORDER BY DispatchPostedAt, DispatchId, DispatchLineNumber) FROM @R) s
            ON s.DispatchLineId = r.DispatchLineId;

    -- 6. The date: not before the latest dispatch it receives
    IF @Date IS NULL THROW 62000, 'The receipt date is required.', 1;
    IF @Date > @Tomorrow THROW 62000, 'The receipt date cannot be in the future.', 1;
    SELECT TOP (1) @Msg = N'TRR cannot be dated before ' + r.DispatchNumber + N' left on ' + CONVERT(NVARCHAR(10), r.DispatchDate, 103) + N'.'
    FROM @R r
    WHERE r.DispatchDate > @Date
    ORDER BY r.DispatchDate DESC, r.DispatchPostedAt DESC, r.DispatchId DESC;
    IF @Msg IS NOT NULL THROW 62000, @Msg, 1;

    -- 7. The destination: rules 3-5 of fn_TransferOrder_WarehouseProblem for To alone, inactive in its own words
    --    (Blocks, Receive, Seq 92: the one place of these sentences)
    SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
    FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
    WHERE b.Action = N'Receive' AND b.Seq = 92 AND b.Message IS NOT NULL
    ORDER BY b.Seq;
    IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

    -- 8. A safety net: the On the way warehouse holds what this receipt takes out of it
    SELECT TOP (1) @Msg = N'Insufficient stock for ' + i.ItemCode + N' in ' + w.WarehouseCode + N': available '
                          + CAST(oh.Q AS NVARCHAR(20)) + N', required ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
    FROM (SELECT ItemId, TransitId, Qty = SUM(Received + Lost), FirstSeq = MIN(Seq) FROM @R GROUP BY ItemId, TransitId) x
    INNER JOIN inventory.Items i       ON i.Id = x.ItemId
    INNER JOIN masterdata.Warehouses w ON w.Id = x.TransitId
    CROSS APPLY (SELECT Q = ISNULL(SUM(m.QuantityBase), 0) FROM inventory.StockMovements m
                 WHERE m.ItemId = x.ItemId AND m.WarehouseId = x.TransitId) oh
    WHERE x.Qty > oh.Q
    ORDER BY x.FirstSeq;
    IF @Msg IS NOT NULL THROW 62007, @Msg, 1;

    -- 9. The number, by the destination branch (an inactive TRR type: Blocks Seq 84, and again here: 62008)
    SELECT @TypeId = Id FROM inventory.DocumentTypes WHERE Code = N'TRR';
    EXEC inventory.usp_DocumentType_NextNumber @Code = N'TRR', @DocumentNumber = @DocumentNumber OUTPUT, @BranchId = @ToBranchId;

    -- 10. The posting and its lines: received at the dispatch's frozen cost, lost at the average now
    UPDATE r SET LossCost = i.AverageCost
    FROM @R r INNER JOIN inventory.Items i ON i.Id = r.ItemId
    WHERE r.Lost > 0;

    INSERT INTO inventory.TransferPostings (TransferOrderId, DocumentTypeId, Kind, DocumentNumber, PostingDate, Eta, BranchId,
                                           FromWarehouseId, ToWarehouseId, TransitWarehouseId, ReferenceNo, Notes, PostedWithId,
                                           Status, TotalQuantityBase, TotalLostBase, ValueBase, LostValueBase, PostedAtUtc, PostedBy)
    SELECT @Id, @TypeId, N'Receipt', @DocumentNumber, @Date, NULL, @ToBranchId,
           @FromId, @ToId, NULL, NULLIF(LTRIM(RTRIM(@ReferenceNo)), N''), NULLIF(LTRIM(RTRIM(@Notes)), N''), @PostedWithId,
           2, SUM(r.Received), SUM(r.Lost),
           CAST(ROUND(SUM(CAST(r.Received AS DECIMAL(18,6)) * ISNULL(r.UnitCost, 0)), 2) AS DECIMAL(18,2)),
           CAST(ROUND(SUM(CAST(r.Lost AS DECIMAL(18,6)) * ISNULL(r.LossCost, 0)), 2) AS DECIMAL(18,2)),
           @Now, @UserId
    FROM @R r;
    SET @PostingId = SCOPE_IDENTITY();

    INSERT INTO inventory.TransferPostingLines (PostingId, LineNumber, TransferOrderLineId, ItemId, DispatchLineId, TransitWarehouseId,
                                                QuantityBase, LostBase, LossReasonCode, LossNote, SettledBase, UnitCostBase, LossUnitCostBase,
                                                TrackingKind)                                                    -- (93)
    SELECT @PostingId, r.Seq, r.OrderLineId, r.ItemId, r.DispatchLineId, r.TransitId,
           r.Received, r.Lost, r.ReasonCode, r.Note, 0, r.UnitCost, r.LossCost,
           r.TrackingKind                                                                                        -- (93)
    FROM @R r
    ORDER BY r.Seq;

    -- (93) 10b. One receipt row per row that arrives or is written off (a row still coming is not written); its number
    --      and expiry are its dispatch row's
    INSERT INTO inventory.TransferPostingTracking (PostingLineId, PostingId, ItemId, RowNumber, Kind, BatchNo, SerialNo, ExpiryDate,
                                                   QuantityBase, LostBase, SettledBase, DispatchTrackingId)
    SELECT rl.Id, @PostingId, d.ItemId, ROW_NUMBER() OVER (PARTITION BY rl.Id ORDER BY d.RowNumber), d.Kind,
           d.BatchNo, d.SerialNo, d.ExpiryDate, t.Received, t.Lost, 0, d.Id
    FROM @RT t
    INNER JOIN inventory.TransferPostingTracking d ON d.Id = t.DispatchTrackingId
    INNER JOIN inventory.TransferPostingLines rl   ON rl.PostingId = @PostingId AND rl.DispatchLineId = d.PostingLineId
    WHERE CAST(t.Received AS BIGINT) + t.Lost > 0;

    -- 11. The ledger. The movement date: see the header (never before what it receives, + 1 second).
    SET @MovementDate = DATEADD(SECOND, DATEDIFF(SECOND, CAST(@Now AS DATE), @Now), CAST(@Date AS DATETIME2(3)));

    ;WITH k AS
    (
        SELECT DocumentId = r.DispatchId, DocumentLineId = r.DispatchLineId, TypeCode = N'TRD', WarehouseId = r.TransitId
        FROM @R r
        UNION ALL
        SELECT rl.PostingId, rl.Id, N'TRR', r.TransitId
        FROM @R r
        INNER JOIN inventory.TransferPostingLines rl ON rl.DispatchLineId = r.DispatchLineId
        WHERE rl.PostingId <> @PostingId
    )
    SELECT @Latest = MAX(m.MovementDate)
    FROM k
    INNER JOIN inventory.StockMovements m ON m.DocumentFamily = N'Transfer' AND m.DocumentId = k.DocumentId
                                         AND m.DocumentTypeCode = k.TypeCode AND m.DocumentLineId = k.DocumentLineId
                                         AND m.WarehouseId = k.WarehouseId;
    IF @Latest IS NOT NULL AND @MovementDate < DATEADD(SECOND, 1, @Latest)
        SET @MovementDate = DATEADD(SECOND, 1, @Latest);

    -- (93) per receipt line AND EXPIRY DATE (B7): a tracked line one group per distinct ExpiryDate of its rows (NULL a
    --      group) with the group's received and lost; an untracked line one group without expiry - script 90's rows
    INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                          DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber,
                                          ReasonCode, ExpiryDate, IsReversal, CreatedBy)
    SELECT @MovementDate, rl.ItemId, g.WarehouseId, w.BranchId, g.Qty, g.Cost,
           N'Transfer', N'TRR', @PostingId, rl.Id, @DocumentNumber,
           g.Reason, e.ExpiryDate, 0, @UserId                                                                    -- (93)
    FROM inventory.TransferPostingLines rl
    CROSS APPLY (SELECT t.ExpiryDate, Received = SUM(t.QuantityBase), Lost = SUM(t.LostBase)                     -- (93)
                 FROM inventory.TransferPostingTracking t
                 WHERE t.PostingLineId = rl.Id AND rl.TrackingKind IS NOT NULL
                 GROUP BY t.ExpiryDate
                 UNION ALL
                 SELECT CAST(NULL AS DATE), rl.QuantityBase, rl.LostBase
                 WHERE rl.TrackingKind IS NULL) e
    CROSS APPLY (VALUES (1, rl.TransitWarehouseId, -e.Received, rl.UnitCostBase,     N'TRF_IN'),
                        (2, @ToId,                  e.Received, rl.UnitCostBase,     N'TRF_IN'),
                        (3, rl.TransitWarehouseId, -e.Lost,     rl.LossUnitCostBase, N'TRF_LOSS')) g (Leg, WarehouseId, Qty, Cost, Reason)
    INNER JOIN masterdata.Warehouses w ON w.Id = g.WarehouseId
    WHERE rl.PostingId = @PostingId AND g.Qty <> 0
    ORDER BY rl.LineNumber, CASE WHEN e.ExpiryDate IS NULL THEN 0 ELSE 1 END, e.ExpiryDate, g.Leg;               -- (93)

    -- 12. The dispatch lines' Settled; the order lines' Received and Lost (one order line may be received from two
    --     dispatches in one receipt)
    UPDATE dl SET SettledBase = dl.SettledBase + r.Received + r.Lost
    FROM inventory.TransferPostingLines dl
    INNER JOIN @R r ON r.DispatchLineId = dl.Id;

    -- (93) the dispatch rows' Settled: what this receipt received and wrote off of each
    UPDATE d SET SettledBase = d.SettledBase + x.QuantityBase + x.LostBase
    FROM inventory.TransferPostingTracking d
    INNER JOIN inventory.TransferPostingTracking x ON x.DispatchTrackingId = d.Id
    WHERE x.PostingId = @PostingId;

    UPDATE l SET ReceivedBase = l.ReceivedBase + x.Received, LostBase = l.LostBase + x.Lost
    FROM inventory.TransferOrderLines l
    INNER JOIN (SELECT OrderLineId, Received = SUM(Received), Lost = SUM(Lost) FROM @R GROUP BY OrderLineId) x ON x.OrderLineId = l.Id;
END
GO

/* 13.19 RECEIVE (Blocks, Receive: a released order with goods on the way, TRR active, the destination fit): the core
   above, the order's header stamp and the audit "{TRR}: {r} pcs received from {TRD list}; {l} pc(s) written off
   ({reasons})." (the second part only with a loss). Result set: PostingId, DocumentNumber, ReceivedBase, LostBase. */
-- Re-created (93) from the body of script 90: + @Tracking, passed to the core.
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_Receive
    @Id             INT,
    @RowVersion     BINARY(8)      = NULL,
    @Date           DATE,
    @ReferenceNo    NVARCHAR(100)  = NULL,
    @Notes          NVARCHAR(1000) = NULL,
    @Lines          inventory.tvp_TransferReceiptLine READONLY,
    @UserId         INT            = NULL,
    @PostingId      INT            = NULL OUTPUT,
    @DocumentNumber NVARCHAR(30)   = NULL OUTPUT,
    @Tracking       inventory.tvp_TransferReceiptTracking READONLY         -- (93)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @Status TINYINT, @Now DATETIME2(3) = SYSUTCDATETIME(),
            @Received INT, @Lost INT;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = Status FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NOT NULL AND @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;

        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
        WHERE b.Action = N'Receive' AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        EXEC inventory.usp_TransferOrder_ReceiveCore @Id = @Id, @Date = @Date, @ReferenceNo = @ReferenceNo, @Notes = @Notes,
             @Lines = @Lines, @UserId = @UserId, @PostingId = @PostingId OUTPUT, @DocumentNumber = @DocumentNumber OUTPUT,
             @PostedWithId = NULL,
             @Tracking = @Tracking;                                                                               -- (93)

        UPDATE inventory.TransferOrders SET UpdatedAtUtc = @Now, UpdatedBy = @UserId WHERE Id = @Id;

        SELECT @Received = TotalQuantityBase, @Lost = TotalLostBase FROM inventory.TransferPostings WHERE Id = @PostingId;

        INSERT INTO inventory.TransferOrderAudit (TransferOrderId, PostingId, Action, Details, UserId)
        SELECT @Id, @PostingId, N'Received',
               LEFT(@DocumentNumber + N': ' + CAST(@Received AS NVARCHAR(20)) + N' pcs received from ' + ISNULL(d.List, N'')
                    + CASE WHEN d.N > 3 THEN N' and ' + CAST(d.N - 3 AS NVARCHAR(10)) + N' more' ELSE N'' END
                    + CASE WHEN @Lost > 0 THEN N'; ' + CAST(@Lost AS NVARCHAR(20)) + N' pc(s) written off (' + ISNULL(rs.Names, N'') + N')' ELSE N'' END
                    + N'.', 500),
               @UserId
        FROM (SELECT N = COUNT(*),
                     List = (SELECT STRING_AGG(t.DocumentNumber, N', ') WITHIN GROUP (ORDER BY t.PostedAtUtc, t.Id)
                             FROM (SELECT TOP (3) dp.Id, dp.DocumentNumber, dp.PostedAtUtc
                                   FROM inventory.TransferPostings dp
                                   WHERE EXISTS (SELECT 1 FROM inventory.TransferPostingLines rl
                                                 INNER JOIN inventory.TransferPostingLines dl ON dl.Id = rl.DispatchLineId
                                                 WHERE rl.PostingId = @PostingId AND dl.PostingId = dp.Id)
                                   ORDER BY dp.PostedAtUtc, dp.Id) t)
              FROM inventory.TransferPostings dp
              WHERE EXISTS (SELECT 1 FROM inventory.TransferPostingLines rl
                            INNER JOIN inventory.TransferPostingLines dl ON dl.Id = rl.DispatchLineId
                            WHERE rl.PostingId = @PostingId AND dl.PostingId = dp.Id)) d
        CROSS APPLY (SELECT Names = STRING_AGG(n.Name, N', ') WITHIN GROUP (ORDER BY n.Sort)
                     FROM (SELECT DISTINCT v.Name, v.Sort
                           FROM inventory.TransferPostingLines rl
                           INNER JOIN (VALUES (N'DAMAGED', N'Damaged', 1), (N'MISSING', N'Missing / stolen', 2),
                                              (N'DISPATCHCOUNT', N'Wrongly counted at dispatch', 3), (N'OTHER', N'Other', 4)) v (Code, Name, Sort)
                                   ON v.Code = rl.LossReasonCode
                           WHERE rl.PostingId = @PostingId AND rl.LostBase > 0) n) rs;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT PostingId = @PostingId, DocumentNumber = @DocumentNumber, ReceivedBase = @Received, LostBase = @Lost;
END
GO

/* 13.20 DISPATCH AND RECEIVE (Blocks, DispatchAndReceive: Dispatch's rules and TRR active; FB decision 17) - one date,
   one transaction: the dispatch core with ETA = the date, then the receipt core with one row per new dispatch line
   (received = all of it, nothing lost), the same date, PostedWithId = the dispatch. Any refusal of either rolls both
   back, numbers included (the number sequences are written in this transaction). Earlier dispatches on the way are
   untouched. Dispatch's parameters; @Eta is not read. Result set: DispatchPostingId, DispatchNumber, ReceiptPostingId,
   ReceiptNumber; @PostingId / @DocumentNumber = the dispatch's. */
-- Re-created (93) from the body of script 90: + @Tracking to the dispatch core; the receipt receives every row of the
-- new dispatch (received = sent, nothing lost), serial by serial.
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_DispatchAndReceive
    @Id             INT,
    @RowVersion     BINARY(8)      = NULL,
    @Date           DATE,
    @Eta            DATE           = NULL,      -- not read: the goods arrive on @Date
    @ReferenceNo    NVARCHAR(100)  = NULL,
    @Notes          NVARCHAR(1000) = NULL,
    @Lines          inventory.tvp_TransferDispatchLine READONLY,
    @UserId         INT            = NULL,
    @PostingId      INT            = NULL OUTPUT,
    @DocumentNumber NVARCHAR(30)   = NULL OUTPUT,
    @Tracking       inventory.tvp_TransferDispatchTracking READONLY        -- (93)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @Status TINYINT, @Now DATETIME2(3) = SYSUTCDATETIME(),
            @ReceiptId INT, @ReceiptNumber NVARCHAR(30), @Pcs INT;
    DECLARE @Receipt inventory.tvp_TransferReceiptLine;
    DECLARE @ReceiptTracking inventory.tvp_TransferReceiptTracking;                                               -- (93)

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = Status FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NOT NULL AND @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;

        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
        WHERE b.Action = N'DispatchAndReceive' AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        EXEC inventory.usp_TransferOrder_DispatchCore @Id = @Id, @Date = @Date, @Eta = @Date, @ReferenceNo = @ReferenceNo,
             @Notes = @Notes, @Lines = @Lines, @UserId = @UserId,
             @PostingId = @PostingId OUTPUT, @DocumentNumber = @DocumentNumber OUTPUT,
             @Tracking = @Tracking;                                                                               -- (93)

        -- the receipt takes exactly what was just dispatched
        INSERT INTO @Receipt (DispatchLineId, ReceivedBase, NothingMoreWillArrive, LossReasonCode, LossNote)
        SELECT pl.Id, pl.QuantityBase, 0, NULL, NULL
        FROM inventory.TransferPostingLines pl
        WHERE pl.PostingId = @PostingId;

        -- (93) ... serial by serial, batch by batch: every row of the new dispatch arrives
        INSERT INTO @ReceiptTracking (DispatchTrackingId, ReceivedBase, LostBase)
        SELECT t.Id, t.QuantityBase, 0
        FROM inventory.TransferPostingTracking t
        WHERE t.PostingId = @PostingId;

        EXEC inventory.usp_TransferOrder_ReceiveCore @Id = @Id, @Date = @Date, @ReferenceNo = @ReferenceNo, @Notes = @Notes,
             @Lines = @Receipt, @UserId = @UserId, @PostingId = @ReceiptId OUTPUT, @DocumentNumber = @ReceiptNumber OUTPUT,
             @PostedWithId = @PostingId,
             @Tracking = @ReceiptTracking;                                                                        -- (93)

        UPDATE inventory.TransferOrders SET UpdatedAtUtc = @Now, UpdatedBy = @UserId WHERE Id = @Id;

        SELECT @Pcs = TotalQuantityBase FROM inventory.TransferPostings WHERE Id = @PostingId;
        INSERT INTO inventory.TransferOrderAudit (TransferOrderId, PostingId, Action, Details, UserId)
        SELECT @Id, @PostingId, N'DispatchedAndReceived',
               LEFT(@DocumentNumber + N' and ' + @ReceiptNumber + N': ' + CAST(@Pcs AS NVARCHAR(20)) + N' pcs from '
                    + fw.WarehouseCode + N' to ' + tw.WarehouseCode + N' on ' + CONVERT(NVARCHAR(10), @Date, 103) + N'.', 500),
               @UserId
        FROM inventory.TransferOrders o
        INNER JOIN masterdata.Warehouses fw ON fw.Id = o.FromWarehouseId
        INNER JOIN masterdata.Warehouses tw ON tw.Id = o.ToWarehouseId
        WHERE o.Id = @Id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT DispatchPostingId = @PostingId, DispatchNumber = @DocumentNumber,
           ReceiptPostingId = @ReceiptId, ReceiptNumber = @ReceiptNumber;
END
GO

/* 13.23 REVERSE ONE WHOLE DISPATCH OR RECEIPT, in place (FB decision 8, T23-T24). The posting's order is locked and its
   RowVersion checked (@RowVersion is the ORDER's); then the order's rule (Blocks, ReverseDispatch / ReverseReceipt) and
   the posting's (fn_TransferPosting_ReverseBlock: not reversed yet; a dispatch after the receipts of its goods; a receipt
   while the destination still holds what it brought) - a reverse that can never go through says so before it asks for a
   reason (script 83) - then the reason and the date (today by default, at most one day ahead, not before the posting).
   Every ledger row of the posting gets its opposite (every column copied, ExpiryDate included; the pieces negated;
   IsReversal 1; CreatedBy the acting user), dated the reversal date at the time it is done but never before the rows it
   undoes + 1 second - for a dispatch, never before any row of a receipt of its lines in its On the way warehouse either
   (a receipt reversed later than the dispatch's reversal date would otherwise leave the On the way warehouse below 0 in
   between). A dispatch takes its pieces off the order lines' Dispatched (and adds them to Not sent on a closed order:
   it stays closed); a receipt takes its pieces off its dispatch lines' Settled and the order lines' Received and Lost
   (its goods are back On the way, its write-off undone). The posting is marked Reversed with the date, the reason and
   who. The cost replay leaves a reversed posting out with its reversal; no partial reversal.
   A RECEIPT THAT WROTE PIECES OFF changes the company's stock when it is reversed (the lost pieces come back at the
   average frozen on the loss, which may have moved since): its items' costs are REPLAYED (inventory.usp_Item_RebuildCosts),
   as every cancel that writes reversal rows (M4, script 89), under the goods receipt matching lock taken first (89's
   order: the matcher, then the document), giving way in a deadlock (DEADLOCK_PRIORITY LOW: the API runs it again). A
   dispatch, or a receipt without a loss, leaves the company's stock as it was: no replay. A receipt's reversal takes
   pieces out of To: it holds the dispatch lock of To (inventory.TransferDispatch.{To}) before it checks To's stock,
   so a dispatch from To cannot pass its stock check on the same pieces at the same time. */
-- Re-created (93) from the body of script 90: + a receipt holding serials takes the serial locks of its items (in ItemId
-- order) after the order's rule and before the posting's (fn_TransferPosting_ReverseBlock); + a receipt's rows go back
-- on the way (their dispatch rows' SettledBase), its losses undone. Rows are never changed or deleted.
CREATE OR ALTER PROCEDURE inventory.usp_TransferPosting_Reverse
    @PostingId  INT,
    @RowVersion BINARY(8)     = NULL,     -- the ORDER's
    @Reason     NVARCHAR(300) = NULL,
    @Date       DATE          = NULL,
    @UserId     INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET DEADLOCK_PRIORITY LOW;      -- the replay of a reversed loss reads the item's ledger: the reverse gives way, the API runs it again

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @OrderId INT, @Status TINYINT, @Kind NVARCHAR(10), @TypeCode NVARCHAR(20),
            @Number NVARCHAR(30), @PostingDate DATE, @NotSentAt DATETIME2(3),
            @Now DATETIME2(3) = SYSUTCDATETIME(), @ReversalAt DATETIME2(3), @Latest DATETIME2(3), @LatestReceipts DATETIME2(3),
            @ToId INT, @Resource NVARCHAR(255), @Lock INT, @ItemId INT;
    DECLARE @SerialItemId INT = 0, @SerialItemCode NVARCHAR(30);     -- (93) (@Lock and @Resource are 90's)

    BEGIN TRY
        BEGIN TRANSACTION;

        -- a receipt that wrote pieces off: the matching lock first, for the replay below (89's lock order)
        IF EXISTS (SELECT 1 FROM inventory.TransferPostings
                   WHERE Id = @PostingId AND Kind = N'Receipt' AND Status = 2 AND TotalLostBase > 0)
            EXEC purchase.usp_GoodsReceipt_LockMatching;

        SELECT @OrderId = TransferOrderId FROM inventory.TransferPostings WHERE Id = @PostingId;
        IF @OrderId IS NULL
        BEGIN
            SELECT TOP (1) @ErrNo = q.ErrorNumber, @Msg = q.Message
            FROM inventory.fn_TransferPosting_ReverseBlock(@PostingId) q
            WHERE q.Message IS NOT NULL
            ORDER BY q.Seq;
            SELECT @ErrNo = ISNULL(@ErrNo, 62006), @Msg = ISNULL(@Msg, N'Dispatch or receipt not found.');
            THROW @ErrNo, @Msg, 1;
        END

        SELECT @Status = Status, @NotSentAt = NotSentAtUtc
        FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @OrderId;
        IF @Status IS NOT NULL AND @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @OrderId AND RowVersion = @RowVersion)
            THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;

        SELECT @Kind = Kind, @Number = DocumentNumber, @PostingDate = PostingDate, @ToId = ToWarehouseId,
               @TypeCode = CASE Kind WHEN N'Dispatch' THEN N'TRD' ELSE N'TRR' END
        FROM inventory.TransferPostings WITH (UPDLOCK, HOLDLOCK) WHERE Id = @PostingId;

        -- a receipt takes its pieces back out of To: one stock check at a time on To, with the dispatches from To
        -- (inventory.usp_TransferOrder_DispatchCore step 5; the same order: the order header, then the warehouse)
        IF @Kind = N'Receipt'
        BEGIN
            SET @Resource = N'inventory.TransferDispatch.' + CAST(@ToId AS NVARCHAR(10));
            EXEC @Lock = sp_getapplock @Resource = @Resource, @LockMode = N'Exclusive', @LockOwner = N'Transaction', @LockTimeout = 30000;
            IF @Lock < 0
            BEGIN
                SELECT @Msg = N'Another dispatch from ' + ISNULL((SELECT WarehouseCode FROM masterdata.Warehouses WHERE Id = @ToId), N'this warehouse')
                              + N' is being posted. Try again in a moment.';
                THROW 62010, @Msg, 1;
            END
        END

        -- the order's rule first, then the posting's own
        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@OrderId, @UserId) b
        WHERE b.Action = CASE @Kind WHEN N'Dispatch' THEN N'ReverseDispatch' ELSE N'ReverseReceipt' END AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        -- (93) A RECEIPT OF SERIALS: the serial locks of its items (the dispatch's, 5b), in ItemId order, so that no
        --      dispatch of one of its serials slips in between the check below (62013) and the reversal
        IF @Kind = N'Receipt'
        BEGIN
            WHILE 1 = 1
            BEGIN
                SET @SerialItemCode = NULL;
                SELECT TOP (1) @SerialItemId = t.ItemId, @SerialItemCode = i.ItemCode
                FROM inventory.TransferPostingTracking t
                INNER JOIN inventory.Items i ON i.Id = t.ItemId
                WHERE t.PostingId = @PostingId AND t.Kind = 2 AND t.ItemId > @SerialItemId
                ORDER BY t.ItemId;
                IF @SerialItemCode IS NULL BREAK;

                SET @Resource = N'inventory.TransferSerial.' + CAST(@SerialItemId AS NVARCHAR(10));
                EXEC @Lock = sp_getapplock @Resource = @Resource, @LockMode = N'Exclusive', @LockOwner = N'Transaction', @LockTimeout = 30000;
                IF @Lock < 0
                BEGIN
                    SET @Msg = N'Another dispatch of ' + @SerialItemCode + N' serial numbers is being posted. Try again in a moment.';
                    THROW 62010, @Msg, 1;
                END
            END
        END

        SELECT TOP (1) @ErrNo = q.ErrorNumber, @Msg = q.Message
        FROM inventory.fn_TransferPosting_ReverseBlock(@PostingId) q
        WHERE q.Message IS NOT NULL
        ORDER BY q.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        IF @Reason IS NULL THROW 62000, 'A reason is required to reverse it.', 1;

        IF @Date IS NULL SET @Date = CAST(@Now AS DATE);
        IF @Date > DATEADD(DAY, 1, CAST(@Now AS DATE)) THROW 62000, 'The reversal date cannot be in the future.', 1;
        IF @Date < @PostingDate
        BEGIN
            SET @Msg = N'The reversal cannot be dated before ' + @Number + N' (' + CONVERT(NVARCHAR(10), @PostingDate, 103) + N').';
            THROW 62000, @Msg, 1;
        END

        -- its own rows only; a posting without any is refused rather than marked reversed (inventory.usp_StockDocument_Cancel, 89)
        IF NOT EXISTS (SELECT 1 FROM inventory.StockMovements m
                       WHERE m.DocumentFamily = N'Transfer' AND m.DocumentTypeCode = @TypeCode AND m.DocumentId = @PostingId AND m.IsReversal = 0)
            THROW 62010, 'This dispatch or receipt has no stock movements of its own to reverse. Ask the administrator to check the stock ledger.', 1;

        -- the date of the reversal rows: see the header
        SET @ReversalAt = DATEADD(SECOND, DATEDIFF(SECOND, CAST(@Now AS DATE), @Now), CAST(@Date AS DATETIME2(3)));
        SELECT @Latest = MAX(m.MovementDate)
        FROM inventory.StockMovements m
        WHERE m.DocumentFamily = N'Transfer' AND m.DocumentTypeCode = @TypeCode AND m.DocumentId = @PostingId;
        IF @Kind = N'Dispatch'
            SELECT @LatestReceipts = MAX(m.MovementDate)
            FROM inventory.TransferPostingLines dl
            INNER JOIN inventory.TransferPostingLines rl ON rl.DispatchLineId = dl.Id
            INNER JOIN inventory.StockMovements m ON m.DocumentFamily = N'Transfer' AND m.DocumentTypeCode = N'TRR'
                                                 AND m.DocumentId = rl.PostingId AND m.DocumentLineId = rl.Id
                                                 AND m.WarehouseId = dl.TransitWarehouseId
            WHERE dl.PostingId = @PostingId;
        IF @LatestReceipts > @Latest SET @Latest = @LatestReceipts;
        IF @Latest IS NOT NULL AND @ReversalAt < DATEADD(SECOND, 1, @Latest)
            SET @ReversalAt = DATEADD(SECOND, 1, @Latest);

        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber,
                                              ReasonCode, ExpiryDate, IsReversal, CreatedBy)
        SELECT @ReversalAt, m.ItemId, m.WarehouseId, m.BranchId, -m.QuantityBase, m.UnitCostBase,
               m.DocumentFamily, m.DocumentTypeCode, m.DocumentId, m.DocumentLineId, m.DocumentNumber,
               m.ReasonCode, m.ExpiryDate, 1, @UserId
        FROM inventory.StockMovements m
        WHERE m.DocumentFamily = N'Transfer' AND m.DocumentTypeCode = @TypeCode AND m.DocumentId = @PostingId AND m.IsReversal = 0
        ORDER BY m.Id;

        IF @Kind = N'Dispatch'
        BEGIN
            -- its pieces leave the order's Dispatched; on a closed order they become Not sent (it stays closed)
            UPDATE l SET DispatchedBase = l.DispatchedBase - x.Qty,
                         NotSentBase    = l.NotSentBase + CASE WHEN @NotSentAt IS NOT NULL THEN x.Qty ELSE 0 END
            FROM inventory.TransferOrderLines l
            INNER JOIN (SELECT TransferOrderLineId, Qty = SUM(QuantityBase) FROM inventory.TransferPostingLines
                        WHERE PostingId = @PostingId GROUP BY TransferOrderLineId) x ON x.TransferOrderLineId = l.Id;
        END
        ELSE
        BEGIN
            -- its goods are back On the way, its write-off undone
            UPDATE dl SET SettledBase = dl.SettledBase - x.Qty
            FROM inventory.TransferPostingLines dl
            INNER JOIN (SELECT DispatchLineId, Qty = SUM(QuantityBase + LostBase) FROM inventory.TransferPostingLines
                        WHERE PostingId = @PostingId GROUP BY DispatchLineId) x ON x.DispatchLineId = dl.Id;

            -- (93) ... its serials and batch pieces too (their dispatch rows), its losses undone
            UPDATE dd SET SettledBase = dd.SettledBase - (rd.QuantityBase + rd.LostBase)
            FROM inventory.TransferPostingTracking dd
            INNER JOIN inventory.TransferPostingTracking rd ON rd.DispatchTrackingId = dd.Id
            WHERE rd.PostingId = @PostingId;

            UPDATE l SET ReceivedBase = l.ReceivedBase - x.Received, LostBase = l.LostBase - x.Lost
            FROM inventory.TransferOrderLines l
            INNER JOIN (SELECT TransferOrderLineId, Received = SUM(QuantityBase), Lost = SUM(LostBase) FROM inventory.TransferPostingLines
                        WHERE PostingId = @PostingId GROUP BY TransferOrderLineId) x ON x.TransferOrderLineId = l.Id;
        END

        UPDATE inventory.TransferPostings
        SET Status = 3, ReversedAtUtc = @Now, ReversedBy = @UserId, ReverseDate = @Date, ReverseReason = @Reason
        WHERE Id = @PostingId;

        -- a receipt's write-off undone: the company's stock changed, so its items' costs are replayed (see the header)
        IF @Kind = N'Receipt'
        BEGIN
            DECLARE items CURSOR LOCAL FAST_FORWARD FOR
                SELECT DISTINCT ItemId FROM inventory.TransferPostingLines WHERE PostingId = @PostingId AND LostBase > 0;
            OPEN items; FETCH NEXT FROM items INTO @ItemId;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC inventory.usp_Item_RebuildCosts @ItemId;
                FETCH NEXT FROM items INTO @ItemId;
            END
            CLOSE items; DEALLOCATE items;
        END

        UPDATE inventory.TransferOrders SET UpdatedAtUtc = @Now, UpdatedBy = @UserId WHERE Id = @OrderId;

        INSERT INTO inventory.TransferOrderAudit (TransferOrderId, PostingId, Action, Details, UserId)
        VALUES (@OrderId, @PostingId, N'Reversed',
                LEFT(@Number + N' reversed on ' + CONVERT(NVARCHAR(10), @Date, 103) + N': ' + @Reason, 500), @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* (91) ONE TRANSFER ORDER, script 90's six result sets with every column, + the destination's stock levels (3.3.6.1):
     1 header + ToLevelCount (levels at To of active items), ItemsBelowMin (the items whose lines are red),
       CanFillToMax / FillToMaxBlockedReason and CanAddBelowMin / AddBelowMinBlockedReason (fn_TransferOrder_Blocks)
     2 lines + ToHasLevel, ToMinBase, ToMaxBase, ToOutToDispatchBase, ToProjectedBeforeBase, ToProjectedAfterBase,
       IsBelowMin, FromHasLevel, FromMinBase, FromProjectedBeforeBase, FromAfterBase, FromBelowMinAfter: fn_StockPosition
       of the item at To and at From with this order left out, then what this order brings (Ordered while a draft or
       waiting, To dispatch + On the way once released, nothing cancelled) and takes (Ordered, To dispatch, nothing).
       Script 90's five figures keep their names and values (fn_StockPosition reads the same fn_TransferPosition). */
-- Re-created (91) from the body of script 90: + the order's levels and the two abilities (result 1), the lines' Min /
-- Max / Projected at To and From after this order (result 2).
-- Re-created (93) from the body of script 91: + per line the item's TrackingMode, RequiresExpiry, SerialLength and
-- TrackingKind; + per posting line its TrackingKind and TrackingCount (B18: no rows here).
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_Get
    @Id     INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Today DATE = CAST(SYSUTCDATETIME() AS DATE);

    -- THE REFUSALS OF EVERY ACTION, read once: the first row (lowest Seq) of an action is its reason.
    DECLARE @B TABLE (Action NVARCHAR(30) NOT NULL PRIMARY KEY, Message NVARCHAR(400) NOT NULL);
    INSERT INTO @B (Action, Message)
    SELECT k.Action, k.Message
    FROM (SELECT b.Action, b.Message, Rn = ROW_NUMBER() OVER (PARTITION BY b.Action ORDER BY b.Seq)
          FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
          WHERE b.Message IS NOT NULL) k
    WHERE k.Rn = 1;

    -- The three order-level answers of the postings, computed once (92 adds its access rows to them).
    DECLARE @ReverseDispatch NVARCHAR(400) = (SELECT Message FROM @B WHERE Action = N'ReverseDispatch'),
            @ReverseReceipt  NVARCHAR(400) = (SELECT Message FROM @B WHERE Action = N'ReverseReceipt'),
            @ChangeEta       NVARCHAR(400) = (SELECT Message FROM @B WHERE Action = N'ChangeEta');

    -- (91) WHAT THIS ORDER BRINGS TO To AND TAKES FROM From, per item (3.3.6.1), read by the header (ItemsBelowMin) and
    --      the lines: a draft or an order waiting for approval its Ordered; a released one what it still has to dispatch
    --      (+ what is on the way, for To; what was received is in To's on hand already); a cancelled one nothing.
    DECLARE @BT TABLE (ItemId INT NOT NULL PRIMARY KEY, BringsBase INT NOT NULL, TakesBase INT NOT NULL);
    INSERT INTO @BT (ItemId, BringsBase, TakesBase)
    SELECT l.ItemId,
           BringsBase = SUM(CASE o.Status WHEN 2 THEN td.ToDispatch + (l.DispatchedBase - l.ReceivedBase - l.LostBase)
                                          WHEN 3 THEN 0 ELSE l.OrderedBase END),
           TakesBase  = SUM(CASE o.Status WHEN 2 THEN td.ToDispatch WHEN 3 THEN 0 ELSE l.OrderedBase END)
    FROM inventory.TransferOrderLines l
    INNER JOIN inventory.TransferOrders o ON o.Id = l.TransferOrderId
    CROSS APPLY (SELECT ToDispatch = CASE WHEN l.OrderedBase - l.DispatchedBase - l.NotSentBase > 0
                                          THEN l.OrderedBase - l.DispatchedBase - l.NotSentBase ELSE 0 END) td
    WHERE l.TransferOrderId = @Id
    GROUP BY l.ItemId;

    -- (91) WHERE From AND To STAND FOR THE ORDER'S ITEMS, this order left out: fn_StockPosition (script 90's five
    --      figures + the level), ONCE per item and warehouse - read by the header (ItemsBelowMin) and by every line of
    --      the item. (It ran once per line and once more per item for the header: the regression review's 2-3 times
    --      script 90's reads.) A table variable: the order page's plan is kept between calls.
    DECLARE @FromId INT, @ToId INT;
    SELECT @FromId = FromWarehouseId, @ToId = ToWarehouseId FROM inventory.TransferOrders WHERE Id = @Id;

    DECLARE @SP TABLE
    (
        ItemId INT NOT NULL, WarehouseId INT NOT NULL, OnHandBase INT NOT NULL, InOnTheWayBase INT NOT NULL,
        InToDispatchBase INT NOT NULL, OutToDispatchBase INT NOT NULL, ProjectedBase INT NOT NULL, HasLevel BIT NOT NULL,
        MinBase INT NULL, MaxBase INT NULL, PRIMARY KEY (ItemId, WarehouseId)
    );
    INSERT INTO @SP (ItemId, WarehouseId, OnHandBase, InOnTheWayBase, InToDispatchBase, OutToDispatchBase, ProjectedBase,
                     HasLevel, MinBase, MaxBase)
    SELECT bt.ItemId, w.WarehouseId, sp.OnHandBase, sp.InOnTheWayBase, sp.InToDispatchBase, sp.OutToDispatchBase,
           sp.ProjectedBase, sp.HasLevel, sp.MinBase, sp.MaxBase
    FROM @BT bt
    CROSS JOIN (VALUES (@FromId), (@ToId)) w (WarehouseId)
    CROSS APPLY inventory.fn_StockPosition(bt.ItemId, w.WarehouseId, @Id) sp;

    -- 1: header
    SELECT o.Id, o.DocumentTypeId, o.DocumentNumber, o.DocumentDate,
           o.BranchId, b.BranchCode, b.BranchName,
           o.FromWarehouseId, FromWarehouseCode = fw.WarehouseCode, FromWarehouseName = fw.WarehouseName,
           FromBranchId = fw.BranchId, FromBranchCode = fb.BranchCode, FromBranchName = fb.BranchName,
           o.ToWarehouseId, ToWarehouseCode = tw.WarehouseCode, ToWarehouseName = tw.WarehouseName,
           ToBranchId = tw.BranchId, ToBranchCode = tb.BranchCode, ToBranchName = tb.BranchName,
           o.ExpectedArrival, o.ReferenceNo, o.Notes,
           o.Status, StatusCode = CASE o.Status WHEN 1 THEN N'Draft' WHEN 2 THEN N'Released' WHEN 3 THEN N'Cancelled' ELSE N'PendingApproval' END,
           o.ReturnOfOrderId, ReturnOfNumber = ro.DocumentNumber,
           o.TotalLines, o.TotalOrderedBase,
           o.ApprovalRequestedAtUtc, o.ApprovalRequestedBy, ApprovalRequestedByName = rqu.FullName,
           o.ApprovedAtUtc, o.ApprovedBy, ApprovedByName = apu.FullName, o.ApprovedDirectly,
           o.RejectedAtUtc, o.RejectedBy, RejectedByName = rju.FullName, o.RejectReason,
           o.ReleasedAtUtc, o.ReleasedBy, ReleasedByName = rlu.FullName,
           o.NotSentAtUtc, o.NotSentBy, NotSentByName = nsu.FullName, o.NotSentReason,
           o.CancelledAtUtc, o.CancelledBy, CancelledByName = cxu.FullName, o.CancelReason,
           o.CreatedAtUtc, o.CreatedBy, CreatedByName = cu.FullName, o.UpdatedAtUtc, o.UpdatedBy, UpdatedByName = uu.FullName,
           NeedsApproval = dt.NeedsApproval, NumberOnPost = dt.NumberOnPost,
           OrderedBase    = ISNULL(st.OrderedBase, 0),    DispatchedBase = ISNULL(st.DispatchedBase, 0),
           ReceivedBase   = ISNULL(st.ReceivedBase, 0),   LostBase       = ISNULL(st.LostBase, 0),
           NotSentBase    = ISNULL(st.NotSentBase, 0),    ToDispatchBase = ISNULL(st.ToDispatchBase, 0),
           OnTheWayBase   = ISNULL(st.OnTheWayBase, 0),   ItemCount      = ISNULL(st.ItemCount, 0),
           LateDispatches = ISNULL(st.LateDispatches, 0), IsLate         = CAST(ISNULL(st.IsLate, 0) AS BIT),
           st.DisplayStatus,
           OnTheWayValueBase = CAST(ISNULL(v.Value, 0) AS DECIMAL(18,2)),
           CanEdit               = CAST(CASE WHEN k.EditR               IS NULL THEN 1 ELSE 0 END AS BIT), EditBlockedReason               = k.EditR,
           CanDelete             = CAST(CASE WHEN k.DeleteR             IS NULL THEN 1 ELSE 0 END AS BIT), DeleteBlockedReason             = k.DeleteR,
           CanRelease            = CAST(CASE WHEN k.ReleaseR            IS NULL THEN 1 ELSE 0 END AS BIT), ReleaseBlockedReason            = k.ReleaseR,
           CanSendForApproval    = CAST(CASE WHEN k.SendForApprovalR    IS NULL THEN 1 ELSE 0 END AS BIT), SendForApprovalBlockedReason    = k.SendForApprovalR,
           CanApprove            = CAST(CASE WHEN k.ApproveR            IS NULL THEN 1 ELSE 0 END AS BIT), ApproveBlockedReason            = k.ApproveR,
           CanReject             = CAST(CASE WHEN k.RejectR             IS NULL THEN 1 ELSE 0 END AS BIT), RejectBlockedReason             = k.RejectR,
           CanWithdraw           = CAST(CASE WHEN k.WithdrawR           IS NULL THEN 1 ELSE 0 END AS BIT), WithdrawBlockedReason           = k.WithdrawR,
           CanBackToDraft        = CAST(CASE WHEN k.BackToDraftR        IS NULL THEN 1 ELSE 0 END AS BIT), BackToDraftBlockedReason        = k.BackToDraftR,
           CanDispatch           = CAST(CASE WHEN k.DispatchR           IS NULL THEN 1 ELSE 0 END AS BIT), DispatchBlockedReason           = k.DispatchR,
           CanReceive            = CAST(CASE WHEN k.ReceiveR            IS NULL THEN 1 ELSE 0 END AS BIT), ReceiveBlockedReason            = k.ReceiveR,
           CanDispatchAndReceive = CAST(CASE WHEN k.DispatchAndReceiveR IS NULL THEN 1 ELSE 0 END AS BIT), DispatchAndReceiveBlockedReason = k.DispatchAndReceiveR,
           CanNothingMoreSent    = CAST(CASE WHEN k.NothingMoreSentR    IS NULL THEN 1 ELSE 0 END AS BIT), NothingMoreSentBlockedReason    = k.NothingMoreSentR,
           CanCancel             = CAST(CASE WHEN k.CancelR             IS NULL THEN 1 ELSE 0 END AS BIT), CancelBlockedReason             = k.CancelR,
           CanCreateReturn       = CAST(CASE WHEN k.CreateReturnR       IS NULL THEN 1 ELSE 0 END AS BIT), CreateReturnBlockedReason       = k.CreateReturnR,
           CanUpdateDetails      = CAST(CASE WHEN k.UpdateDetailsR      IS NULL THEN 1 ELSE 0 END AS BIT), UpdateDetailsBlockedReason      = k.UpdateDetailsR,
           CanEditExpectedArrival = CAST(CASE WHEN ea.Reason IS NULL THEN 1 ELSE 0 END AS BIT), EditExpectedArrivalBlockedReason = ea.Reason,
           -- (91) To's stock levels (active items), the items still below To's Min after this order, Fill to Max and
           --      Add items below Min (fn_TransferOrder_Blocks)
           ToLevelCount          = lc.N,
           ItemsBelowMin         = bm.N,
           CanFillToMax          = CAST(CASE WHEN k.FillToMaxR          IS NULL THEN 1 ELSE 0 END AS BIT), FillToMaxBlockedReason          = k.FillToMaxR,
           CanAddBelowMin        = CAST(CASE WHEN k.AddBelowMinR        IS NULL THEN 1 ELSE 0 END AS BIT), AddBelowMinBlockedReason        = k.AddBelowMinR,
           o.RowVersion
    FROM inventory.TransferOrders o
    INNER JOIN inventory.DocumentTypes dt   ON dt.Id = o.DocumentTypeId
    INNER JOIN masterdata.Branches b        ON b.Id = o.BranchId
    INNER JOIN masterdata.Warehouses fw     ON fw.Id = o.FromWarehouseId
    INNER JOIN masterdata.Branches fb       ON fb.Id = fw.BranchId
    INNER JOIN masterdata.Warehouses tw     ON tw.Id = o.ToWarehouseId
    INNER JOIN masterdata.Branches tb       ON tb.Id = tw.BranchId
    LEFT  JOIN inventory.TransferOrders ro  ON ro.Id = o.ReturnOfOrderId
    LEFT  JOIN security.Users rqu ON rqu.Id = o.ApprovalRequestedBy
    LEFT  JOIN security.Users apu ON apu.Id = o.ApprovedBy
    LEFT  JOIN security.Users rju ON rju.Id = o.RejectedBy
    LEFT  JOIN security.Users rlu ON rlu.Id = o.ReleasedBy
    LEFT  JOIN security.Users nsu ON nsu.Id = o.NotSentBy
    LEFT  JOIN security.Users cxu ON cxu.Id = o.CancelledBy
    LEFT  JOIN security.Users cu  ON cu.Id  = o.CreatedBy
    LEFT  JOIN security.Users uu  ON uu.Id  = o.UpdatedBy
    OUTER APPLY inventory.fn_TransferOrder_State(o.Id) st
    -- the pieces on the way, at the cost frozen on their dispatch line (information: a transfer moves no cost)
    OUTER APPLY (SELECT Value = ROUND(SUM(CAST(dl.QuantityBase - dl.SettledBase AS DECIMAL(18,6)) * ISNULL(dl.UnitCostBase, 0)), 2)
                 FROM inventory.TransferPostingLines dl
                 INNER JOIN inventory.TransferPostings p ON p.Id = dl.PostingId
                 WHERE p.TransferOrderId = o.Id AND p.Kind = N'Dispatch' AND p.Status = 2 AND dl.QuantityBase > dl.SettledBase) v
    CROSS APPLY (SELECT EditR               = MAX(CASE WHEN a.Action = N'Edit'               THEN a.Message END),
                        DeleteR             = MAX(CASE WHEN a.Action = N'Delete'             THEN a.Message END),
                        ReleaseR            = MAX(CASE WHEN a.Action = N'Release'            THEN a.Message END),
                        SendForApprovalR    = MAX(CASE WHEN a.Action = N'SendForApproval'    THEN a.Message END),
                        ApproveR            = MAX(CASE WHEN a.Action = N'Approve'            THEN a.Message END),
                        RejectR             = MAX(CASE WHEN a.Action = N'Reject'             THEN a.Message END),
                        WithdrawR           = MAX(CASE WHEN a.Action = N'Withdraw'           THEN a.Message END),
                        BackToDraftR        = MAX(CASE WHEN a.Action = N'BackToDraft'        THEN a.Message END),
                        DispatchR           = MAX(CASE WHEN a.Action = N'Dispatch'           THEN a.Message END),
                        ReceiveR            = MAX(CASE WHEN a.Action = N'Receive'            THEN a.Message END),
                        DispatchAndReceiveR = MAX(CASE WHEN a.Action = N'DispatchAndReceive' THEN a.Message END),
                        NothingMoreSentR    = MAX(CASE WHEN a.Action = N'NothingMoreSent'    THEN a.Message END),
                        CancelR             = MAX(CASE WHEN a.Action = N'Cancel'             THEN a.Message END),
                        CreateReturnR       = MAX(CASE WHEN a.Action = N'CreateReturn'       THEN a.Message END),
                        UpdateDetailsR      = MAX(CASE WHEN a.Action = N'UpdateDetails'      THEN a.Message END),
                        FillToMaxR          = MAX(CASE WHEN a.Action = N'FillToMax'          THEN a.Message END),   -- (91)
                        AddBelowMinR        = MAX(CASE WHEN a.Action = N'AddBelowMin'        THEN a.Message END)    -- (91)
                 FROM @B a) k
    -- (T9) Expected arrival and Reference No. stay editable on a released order until it is received or closed
    CROSS APPLY (SELECT Reason = CASE WHEN o.Status = 3 OR st.DisplayStatus IN (N'Received', N'Closed')
                                      THEN N'Only the notes can change on a received, closed or cancelled transfer order.'
                                      ELSE k.UpdateDetailsR END) ea
    -- (91) the levels at To of active items; the items whose line is red (To still below its Min after this order)
    CROSS APPLY (SELECT N = COUNT(*)
                 FROM inventory.ItemWarehouseLevels lv
                 INNER JOIN inventory.Items li ON li.Id = lv.ItemId AND li.IsActive = 1
                 WHERE lv.WarehouseId = o.ToWarehouseId) lc
    CROSS APPLY (SELECT N = COUNT(*)
                 FROM @BT bt
                 INNER JOIN @SP sp ON sp.ItemId = bt.ItemId AND sp.WarehouseId = o.ToWarehouseId
                 WHERE sp.HasLevel = 1 AND sp.ProjectedBase + bt.BringsBase < sp.MinBase) bm
    WHERE o.Id = @Id;

    -- 2: lines, and where From and To stand with transfers (this order left out); (91) To's level for the item, and
    --    where To and From stand WITH this order (what it brings / takes, @BT): the line is red while To stays below its
    --    Min (IsBelowMin, L19), From orange when it goes below its own Min (FromBelowMinAfter)
    SELECT l.Id, l.LineNumber, l.ItemId, i.ItemCode, i.ItemName, ItemIsActive = i.IsActive,
           l.ItemUnitId, UnitName = ut.UnitTypeName, iu.IsBaseUnit, l.Quantity, l.PackingFormula, l.OrderedBase,
           l.DispatchedBase, l.ReceivedBase, l.LostBase, l.NotSentBase,
           ToDispatchBase = CASE WHEN l.OrderedBase - l.DispatchedBase - l.NotSentBase > 0
                                 THEN l.OrderedBase - l.DispatchedBase - l.NotSentBase ELSE 0 END,
           OnTheWayBase   = l.DispatchedBase - l.ReceivedBase - l.LostBase,
           l.Notes,
           OnHandFromBase    = ISNULL(pf.OnHandBase, 0),
           CommittedFromBase = ISNULL(pf.OutToDispatchBase, 0),
           AvailableFromBase = CASE WHEN pf.OnHandBase - pf.OutToDispatchBase > 0 THEN pf.OnHandBase - pf.OutToDispatchBase ELSE 0 END,
           OnHandToBase      = ISNULL(pt.OnHandBase, 0),
           IncomingToBase    = ISNULL(pt.InOnTheWayBase + pt.InToDispatchBase, 0),
           ToHasLevel              = ISNULL(pt.HasLevel, CAST(0 AS BIT)),                                     -- (91)
           ToMinBase               = pt.MinBase,
           ToMaxBase               = pt.MaxBase,
           ToOutToDispatchBase     = ISNULL(pt.OutToDispatchBase, 0),
           ToProjectedBeforeBase   = ISNULL(pt.ProjectedBase, 0),
           ToProjectedAfterBase    = ISNULL(pt.ProjectedBase, 0) + ISNULL(bt.BringsBase, 0),
           IsBelowMin              = CAST(CASE WHEN pt.HasLevel = 1 AND ISNULL(pt.ProjectedBase, 0) + ISNULL(bt.BringsBase, 0) < pt.MinBase
                                               THEN 1 ELSE 0 END AS BIT),
           FromHasLevel            = ISNULL(pf.HasLevel, CAST(0 AS BIT)),
           FromMinBase             = pf.MinBase,
           FromProjectedBeforeBase = ISNULL(pf.ProjectedBase, 0),
           FromAfterBase           = ISNULL(pf.ProjectedBase, 0) - ISNULL(bt.TakesBase, 0),
           FromBelowMinAfter       = CAST(CASE WHEN pf.HasLevel = 1 AND ISNULL(pf.ProjectedBase, 0) - ISNULL(bt.TakesBase, 0) < pf.MinBase
                                               THEN 1 ELSE 0 END AS BIT),
           -- (93) how the item is tracked now, and the kind a dispatch asks for (2 Serial, 1 Batch, 3 Expiry, NULL none)
           TrackingMode   = i.TrackingMode,
           RequiresExpiry = i.RequiresExpiry,
           SerialLength   = i.SerialLength,
           TrackingKind   = CAST(CASE i.TrackingMode WHEN 2 THEN 2 WHEN 1 THEN 1 ELSE CASE WHEN i.RequiresExpiry = 1 THEN 3 END END AS TINYINT)
    FROM inventory.TransferOrderLines l
    INNER JOIN inventory.TransferOrders o ON o.Id = l.TransferOrderId
    INNER JOIN inventory.Items i          ON i.Id = l.ItemId
    INNER JOIN inventory.ItemUnits iu     ON iu.Id = l.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut    ON ut.Id = iu.UnitTypeId
    LEFT  JOIN @BT bt                     ON bt.ItemId = l.ItemId                                             -- (91)
    -- (91) fn_StockPosition's columns (script 90's fn_TransferPosition's five figures + the warehouse's level), worked
    --      out once above for every item of the order (@SP)
    LEFT  JOIN @SP pf ON pf.ItemId = l.ItemId AND pf.WarehouseId = o.FromWarehouseId
    LEFT  JOIN @SP pt ON pt.ItemId = l.ItemId AND pt.WarehouseId = o.ToWarehouseId
    WHERE l.TransferOrderId = @Id
    ORDER BY l.LineNumber;

    -- 3: dispatches and receipts. Reverse: the order-level answer (Blocks) first, then the posting's own
    --    (fn_TransferPosting_ReverseBlock). Change ETA: the order-level answer, then "a dispatch with goods on the way".
    SELECT p.Id, p.Kind, DocumentTypeCode = pdt.Code, p.DocumentNumber, p.PostingDate, p.Eta, p.ReferenceNo, p.Notes,
           StatusCode = CASE p.Status WHEN 2 THEN N'Posted' ELSE N'Reversed' END,
           p.TransitWarehouseId, TransitWarehouseCode = xw.WarehouseCode, TransitWarehouseName = xw.WarehouseName,
           BranchCode = pb.BranchCode, p.PostedWithId, PostedWithNumber = pw.DocumentNumber,
           p.TotalQuantityBase, p.TotalLostBase,
           OnTheWayBase = ISNULL(w.OnTheWay, 0),
           IsLate = CAST(CASE WHEN p.Kind = N'Dispatch' AND p.Status = 2 AND ISNULL(w.OnTheWay, 0) > 0 AND p.Eta < @Today THEN 1 ELSE 0 END AS BIT),
           p.ValueBase, p.LostValueBase,
           p.PostedAtUtc, PostedByName = pu.FullName,
           p.ReverseDate, p.ReversedAtUtc, ReversedByName = ru.FullName, p.ReverseReason,
           CanReverse   = CAST(CASE WHEN r.Reason IS NULL THEN 1 ELSE 0 END AS BIT), ReverseBlockedReason   = r.Reason,
           CanChangeEta = CAST(CASE WHEN e.Reason IS NULL THEN 1 ELSE 0 END AS BIT), ChangeEtaBlockedReason = e.Reason
    FROM inventory.TransferPostings p
    INNER JOIN inventory.DocumentTypes pdt      ON pdt.Id = p.DocumentTypeId
    INNER JOIN masterdata.Branches pb           ON pb.Id = p.BranchId
    LEFT  JOIN masterdata.Warehouses xw         ON xw.Id = p.TransitWarehouseId
    LEFT  JOIN inventory.TransferPostings pw    ON pw.Id = p.PostedWithId
    LEFT  JOIN security.Users pu                ON pu.Id = p.PostedBy
    LEFT  JOIN security.Users ru                ON ru.Id = p.ReversedBy
    -- on the way of a dispatch: its lines' sent - settled while it is posted, 0 once reversed (a receipt: 0)
    OUTER APPLY (SELECT OnTheWay = SUM(dl.QuantityBase - dl.SettledBase)
                 FROM inventory.TransferPostingLines dl
                 WHERE dl.PostingId = p.Id AND p.Kind = N'Dispatch' AND p.Status = 2) w
    OUTER APPLY (SELECT TOP (1) q.Message FROM inventory.fn_TransferPosting_ReverseBlock(p.Id) q
                 WHERE q.Message IS NOT NULL ORDER BY q.Seq) rb
    CROSS APPLY (SELECT Reason = COALESCE(CASE WHEN p.Kind = N'Dispatch' THEN @ReverseDispatch ELSE @ReverseReceipt END, rb.Message)) r
    CROSS APPLY (SELECT Reason = COALESCE(@ChangeEta,
                                          CASE WHEN NOT (p.Kind = N'Dispatch' AND p.Status = 2 AND ISNULL(w.OnTheWay, 0) > 0)
                                               THEN N'Only a dispatch with goods on the way can change its ETA.' END)) e
    WHERE p.TransferOrderId = @Id
    ORDER BY p.PostedAtUtc, p.Id;

    -- 4: their lines
    SELECT pl.Id, pl.PostingId, pl.LineNumber, pl.TransferOrderLineId, OrderLineNumber = ol.LineNumber,
           pl.ItemId, i.ItemCode, i.ItemName,
           pl.QuantityBase, pl.LostBase, pl.LossReasonCode, pl.LossNote, pl.SettledBase,
           OnTheWayBase = CASE WHEN p.Kind = N'Dispatch' AND p.Status = 2 THEN pl.QuantityBase - pl.SettledBase ELSE 0 END,
           pl.DispatchLineId, DispatchNumber = dp.DocumentNumber,
           pl.UnitCostBase, pl.LossUnitCostBase,
           -- (93) the kind it left with, and how many rows it holds (its rows: usp_TransferPosting_Tracking, B18)
           pl.TrackingKind,
           TrackingCount = ISNULL(tc.N, 0)
    FROM inventory.TransferPostingLines pl
    INNER JOIN inventory.TransferPostings p         ON p.Id = pl.PostingId
    INNER JOIN inventory.TransferOrderLines ol      ON ol.Id = pl.TransferOrderLineId
    INNER JOIN inventory.Items i                    ON i.Id = pl.ItemId
    LEFT  JOIN inventory.TransferPostingLines dl    ON dl.Id = pl.DispatchLineId
    LEFT  JOIN inventory.TransferPostings dp        ON dp.Id = dl.PostingId
    OUTER APPLY (SELECT N = COUNT(*) FROM inventory.TransferPostingTracking t
                 WHERE t.PostingLineId = pl.Id AND pl.TrackingKind IS NOT NULL) tc                                -- (93)
    WHERE p.TransferOrderId = @Id
    ORDER BY p.PostedAtUtc, p.Id, pl.LineNumber;

    -- 5: audit
    SELECT a.Id, a.PostingId, a.Action, a.Details, a.UserId, UserName = u.FullName, a.AtUtc
    FROM inventory.TransferOrderAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.TransferOrderId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;

    -- 6: the returns of this order (new orders in the other direction, 2.3.8.20)
    SELECT r.Id, r.DocumentNumber, r.DocumentDate,
           StatusCode = CASE r.Status WHEN 1 THEN N'Draft' WHEN 2 THEN N'Released' WHEN 3 THEN N'Cancelled' ELSE N'PendingApproval' END,
           rs.DisplayStatus
    FROM inventory.TransferOrders r
    OUTER APPLY inventory.fn_TransferOrder_State(r.Id) rs
    WHERE r.ReturnOfOrderId = @Id
    ORDER BY r.Id;
END
GO

-- (93) THE BATCH, SERIAL AND EXPIRY ROWS OF ONE DISPATCH OR RECEIPT (5.3.7.8), read when they are shown (the posting's
--      list, the Receive dialog with @OnTheWayOnly = 1, the dispatch note, the export) - never by the order's Get (B18).
--      One row per tracking row, by line and row, with its state in words; a dispatch row's receipts (POSTED, oldest
--      first, at most 3 then " and {n} more"; the same for the ones that wrote pieces off) are worked out for the
--      posting's rows in one aggregate.
CREATE OR ALTER PROCEDURE inventory.usp_TransferPosting_Tracking
    @PostingId    INT,
    @OnTheWayOnly BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Kind NVARCHAR(10), @Status TINYINT;
    SELECT @Kind = Kind, @Status = Status FROM inventory.TransferPostings WHERE Id = @PostingId;
    IF @Kind IS NULL THROW 62006, 'Dispatch or receipt not found.', 1;
    SET @OnTheWayOnly = ISNULL(@OnTheWayOnly, 0);

    -- a dispatch: what its POSTED receipts did with each row
    DECLARE @Rcv TABLE
    (
        DispatchTrackingId INT           NOT NULL PRIMARY KEY,
        Received           INT           NOT NULL,
        Lost               INT           NOT NULL,
        N                  INT           NOT NULL,
        List               NVARCHAR(200) NULL,
        LostN              INT           NOT NULL,
        LostList           NVARCHAR(200) NULL,
        Reasons            NVARCHAR(100) NULL
    );
    IF @Kind = N'Dispatch'
        INSERT INTO @Rcv (DispatchTrackingId, Received, Lost, N, List, LostN, LostList, Reasons)
        SELECT r.DispatchTrackingId, SUM(r.QuantityBase), SUM(r.LostBase), COUNT(*),
               STRING_AGG(CASE WHEN r.Rn <= 3 THEN r.DocumentNumber END, N', ') WITHIN GROUP (ORDER BY r.Rn),
               SUM(CASE WHEN r.LostBase > 0 THEN 1 ELSE 0 END),
               -- the receipts that wrote pieces off, capped like List (a batch received in many parts, each with a loss)
               STRING_AGG(CASE WHEN r.LostBase > 0 AND r.LostRn <= 3 THEN r.DocumentNumber END, N', ') WITHIN GROUP (ORDER BY r.Rn),
               CASE WHEN MIN(r.ReasonName) = MAX(r.ReasonName) THEN MIN(r.ReasonName)
                    ELSE MIN(r.ReasonName) + N', ' + MAX(r.ReasonName) END
        FROM (SELECT x.DispatchTrackingId, x.QuantityBase, x.LostBase, rp.DocumentNumber,
                     ReasonName = CASE WHEN x.LostBase > 0 THEN
                                       CASE rl.LossReasonCode WHEN N'DAMAGED' THEN N'Damaged' WHEN N'MISSING' THEN N'Missing / stolen'
                                                              WHEN N'DISPATCHCOUNT' THEN N'Wrongly counted at dispatch'
                                                              WHEN N'OTHER' THEN N'Other' END END,
                     Rn = ROW_NUMBER() OVER (PARTITION BY x.DispatchTrackingId ORDER BY rp.PostedAtUtc, rp.Id),
                     LostRn = ROW_NUMBER() OVER (PARTITION BY x.DispatchTrackingId, CASE WHEN x.LostBase > 0 THEN 1 ELSE 0 END
                                                 ORDER BY rp.PostedAtUtc, rp.Id)
              FROM inventory.TransferPostingTracking d
              INNER JOIN inventory.TransferPostingTracking x ON x.DispatchTrackingId = d.Id
              INNER JOIN inventory.TransferPostings rp       ON rp.Id = x.PostingId AND rp.Status = 2
              INNER JOIN inventory.TransferPostingLines rl   ON rl.Id = x.PostingLineId
              WHERE d.PostingId = @PostingId) r
        GROUP BY r.DispatchTrackingId;

    SELECT t.Id, t.PostingId, t.PostingLineId, PostingLineNumber = pl.LineNumber, t.ItemId, i.ItemCode, t.RowNumber, t.Kind,
           t.BatchNo, t.SerialNo, t.ExpiryDate, t.QuantityBase, t.LostBase, t.SettledBase,
           OnTheWayBase = CASE WHEN @Kind = N'Dispatch' AND @Status = 2 THEN t.QuantityBase - t.SettledBase ELSE 0 END,
           t.DispatchTrackingId, DispatchNumber = dp.DocumentNumber,
           State = CAST(s.State AS NVARCHAR(20)),
           StateText = CAST(CASE s.State
                                 WHEN N'Reversed'       THEN N'Reversed'
                                 WHEN N'OnTheWay'       THEN N'On the way'
                                 WHEN N'PartlyReceived' THEN STUFF(CONCAT(CASE WHEN ISNULL(rc.Received, 0) > 0 THEN N', ' + CAST(rc.Received AS NVARCHAR(20)) + N' received' END,
                                                                          CASE WHEN ISNULL(rc.Lost, 0) > 0 THEN N', ' + CAST(rc.Lost AS NVARCHAR(20)) + N' written off' END,
                                                                          N', ' + CAST(t.QuantityBase - t.SettledBase AS NVARCHAR(20)) + N' on the way'), 1, 2, N'')
                                 WHEN N'Received'       THEN CASE WHEN t.DispatchTrackingId IS NULL
                                                                  THEN N'Received by ' + ISNULL(rc.List, N'')
                                                                       + CASE WHEN rc.N > 3 THEN N' and ' + CAST(rc.N - 3 AS NVARCHAR(10)) + N' more' ELSE N'' END
                                                                  ELSE N'Received' END
                                 WHEN N'Lost'           THEN CASE WHEN t.DispatchTrackingId IS NULL
                                                                  THEN N'Written off by ' + ISNULL(rc.LostList, N'')
                                                                       + CASE WHEN rc.LostN > 3 THEN N' and ' + CAST(rc.LostN - 3 AS NVARCHAR(10)) + N' more' ELSE N'' END
                                                                       + N' (' + ISNULL(rc.Reasons, N'') + N')'
                                                                  ELSE N'Written off (' + ISNULL(rn.ReasonName, N'') + N')' END
                                 WHEN N'Settled'        THEN CAST(ISNULL(rc.Received, 0) AS NVARCHAR(20)) + N' received, '
                                                             + CAST(ISNULL(rc.Lost, 0) AS NVARCHAR(20)) + N' written off'
                                 WHEN N'PartlyLost'     THEN CAST(t.QuantityBase AS NVARCHAR(20)) + N' received, ' + CAST(t.LostBase AS NVARCHAR(20))
                                                             + N' written off (' + ISNULL(rn.ReasonName, N'') + N')'
                            END AS NVARCHAR(300))
    FROM inventory.TransferPostingTracking t
    INNER JOIN inventory.TransferPostingLines pl  ON pl.Id = t.PostingLineId
    INNER JOIN inventory.Items i                  ON i.Id = t.ItemId
    LEFT  JOIN inventory.TransferPostingTracking dt ON dt.Id = t.DispatchTrackingId
    LEFT  JOIN inventory.TransferPostings dp      ON dp.Id = dt.PostingId
    LEFT  JOIN @Rcv rc                            ON rc.DispatchTrackingId = t.Id
    CROSS APPLY (SELECT ReasonName = CASE pl.LossReasonCode WHEN N'DAMAGED' THEN N'Damaged' WHEN N'MISSING' THEN N'Missing / stolen'
                                                           WHEN N'DISPATCHCOUNT' THEN N'Wrongly counted at dispatch'
                                                           WHEN N'OTHER' THEN N'Other' END) rn
    CROSS APPLY (SELECT State = CASE WHEN @Status = 3 THEN N'Reversed'
                                     WHEN t.DispatchTrackingId IS NULL THEN
                                          CASE WHEN t.SettledBase = 0 THEN N'OnTheWay'
                                               WHEN t.SettledBase < t.QuantityBase THEN N'PartlyReceived'
                                               WHEN ISNULL(rc.Lost, 0) = 0 THEN N'Received'
                                               WHEN ISNULL(rc.Received, 0) = 0 THEN N'Lost'
                                               ELSE N'Settled' END
                                     WHEN t.LostBase = 0 THEN N'Received'
                                     WHEN t.QuantityBase = 0 THEN N'Lost'
                                     ELSE N'PartlyLost' END) s
    WHERE t.PostingId = @PostingId
      AND (@OnTheWayOnly = 0 OR (@Kind = N'Dispatch' AND @Status = 2 AND t.QuantityBase > t.SettledBase))
    ORDER BY pl.LineNumber, t.RowNumber;
END
GO

/* 13.1 THE LIST, paged, and a totals row (2 result sets).
   Filters: @Search (the order's number, its reference, From's or To's code or name, the code of an item on one of its
   lines, the number of one of its dispatches or receipts); @Status = a shown status (Draft, PendingApproval, Released,
   PartlyDispatched, Dispatched, PartlyReceived, Received, Closed, Cancelled) or Open (released, neither Received nor
   Closed); @BranchId = From's OR To's branch (a transfer concerns both); From, To; @OnTheWayOnly (pieces on the way),
   @LateOnly (Late, worked out on the server in UTC), @WaitingForApproval (stored status 4: the approvers' list, the
   menu count's); the order date; @ItemId (an order with a line of the item).
   Sort: DocumentNumber | DocumentDate | FromWarehouse | ToWarehouse | Status (in the order of the shown statuses) |
   OrderedBase | OnTheWayBase | ExpectedArrival | CreatedAtUtc.
   1: one row per order (TotalCount = all pages): its figures, shown status and Late from fn_TransferOrder_State, the
      one place they are worked out.
   2: over every order of the filter (all pages): Orders, OnTheWayBase, LateOrders, WaitingForApproval. */
-- Re-created (92) from the body of script 90: + @UserId, @Mine (From or to / From / To the reader's warehouses: Any |
-- From | To, any case; NULL = no filter; an unrestricted reader is never filtered). Result sets unchanged.
-- Re-created (93) from the body of script 92: + @TrackingNo (the orders whose dispatches or receipts hold a batch or
-- serial no. containing it, 3 characters or more) and the column MatchedTracking (what happened to it).
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_Search
    @Search             NVARCHAR(100) = NULL,
    @Status             NVARCHAR(20)  = NULL,
    @BranchId           INT           = NULL,
    @FromWarehouseId    INT           = NULL,
    @ToWarehouseId      INT           = NULL,
    @OnTheWayOnly       BIT           = 0,
    @LateOnly           BIT           = 0,
    @WaitingForApproval BIT           = 0,
    @DateFrom           DATE          = NULL,
    @DateTo             DATE          = NULL,
    @ItemId             INT           = NULL,
    @SortColumn         NVARCHAR(30)  = N'DocumentDate',
    @SortDirection      NVARCHAR(4)   = N'DESC',
    @PageNumber         INT           = 1,
    @PageSize           INT           = 25,
    @UserId             INT           = NULL,   -- (92) the reader
    @Mine               NVARCHAR(4)   = NULL,   -- (92) Any | From | To the reader's warehouses; NULL = no filter
    @TrackingNo         NVARCHAR(100) = NULL    -- (93) a batch or serial no., or part of one (3 characters or more)
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 25;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @Status = NULLIF(LTRIM(RTRIM(@Status)), N'');
    IF @Status IS NOT NULL AND @Status NOT IN (N'Draft', N'PendingApproval', N'Released', N'PartlyDispatched', N'Dispatched',
                                               N'PartlyReceived', N'Received', N'Closed', N'Cancelled', N'Open')
        THROW 62000, 'The status filter is Draft, PendingApproval, Released, PartlyDispatched, Dispatched, PartlyReceived, Received, Closed, Cancelled or Open.', 1;
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'DocumentNumber', N'DocumentDate', N'FromWarehouse', N'ToWarehouse', N'Status',
                                                  N'OrderedBase', N'OnTheWayBase', N'ExpectedArrival', N'CreatedAtUtc')
        SET @SortColumn = N'DocumentDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);
    SELECT @OnTheWayOnly = ISNULL(@OnTheWayOnly, 0), @LateOnly = ISNULL(@LateOnly, 0), @WaitingForApproval = ISNULL(@WaitingForApproval, 0);

    -- (92) the reader's warehouses (W15): a restricted reader's list starts on "From or to my warehouses"
    SET @Mine = NULLIF(LTRIM(RTRIM(@Mine)), N'');
    IF @Mine IS NOT NULL AND @Mine NOT IN (N'Any', N'From', N'To')
        THROW 62000, 'Unknown warehouse filter: choose any, from or to.', 1;
    DECLARE @MineUnrestricted BIT = security.fn_User_IsUnrestricted(@UserId);
    DECLARE @MineIds TABLE (WarehouseId INT NOT NULL PRIMARY KEY);
    IF @Mine IS NOT NULL AND @MineUnrestricted = 0
        INSERT INTO @MineIds (WarehouseId) SELECT WarehouseId FROM security.fn_User_Warehouses(@UserId);

    -- (93) a batch or serial no. as the postings keep it (capitals, trimmed), found by "contains" (B9): chassis numbers
    --      are quoted by their last digits. LIKE's own characters typed are taken as they are.
    SET @TrackingNo = inventory.fn_TrackingNo_Normalize(@TrackingNo);
    IF LEN(@TrackingNo) < 3 THROW 62000, 'Type at least 3 characters of the batch or serial number.', 1;
    DECLARE @Pattern NVARCHAR(400) = N'%' + REPLACE(REPLACE(REPLACE(@TrackingNo, N'[', N'[[]'), N'%', N'[%]'), N'_', N'[_]') + N'%';
    -- (93) the matching rows, ONCE (one pass over the tracking rows): @MatchOrder below reads them
    --      (an EXISTS per order let the optimiser scan every row once per order: 2 s on 50,000 rows instead of 0.05)
    DECLARE @Match TABLE
    (
        TrackingId      INT          NOT NULL PRIMARY KEY,
        TransferOrderId INT          NOT NULL,
        Number          NVARCHAR(50) NOT NULL,
        PostingStatus   TINYINT      NOT NULL,
        PostingKind     NVARCHAR(10) NOT NULL,
        PostingNumber   NVARCHAR(30) NOT NULL,
        ToWarehouseId   INT          NOT NULL,
        QuantityBase    INT          NOT NULL,
        SettledBase     INT          NOT NULL
    );
    IF @TrackingNo IS NOT NULL
        INSERT INTO @Match (TrackingId, TransferOrderId, Number, PostingStatus, PostingKind, PostingNumber,
                            ToWarehouseId, QuantityBase, SettledBase)
        SELECT tx.Id, px.TransferOrderId, COALESCE(tx.SerialNo, tx.BatchNo), px.Status, px.Kind, px.DocumentNumber,
               px.ToWarehouseId, tx.QuantityBase, tx.SettledBase
        FROM inventory.TransferPostingTracking tx
        INNER JOIN inventory.TransferPostings px ON px.Id = tx.PostingId
        WHERE tx.SerialNo LIKE @Pattern OR tx.BatchNo LIKE @Pattern;

    -- (93) ... and per order, ONCE, what MatchedTracking says: the order's latest matching row (rows of posted postings
    --      first, so a serial back on the way after a reversed receipt reads "on the way"; then by the row's Id, the
    --      order the rows were written in) and the count of distinct numbers. Worked out here, keyed by the order, and
    --      not per row of the page: an APPLY over @Match per order ran in a plan compiled for an empty @Match (the
    --      list's first call has no filter) and took minutes when every chassis no. matched (MD6...).
    DECLARE @MatchOrder TABLE
    (
        TransferOrderId INT           NOT NULL PRIMARY KEY,
        Txt             NVARCHAR(300) NULL,
        N               INT           NOT NULL
    );
    IF @TrackingNo IS NOT NULL
        INSERT INTO @MatchOrder (TransferOrderId, Txt, N)
        SELECT r.TransferOrderId, r.Txt, r.N
        FROM (SELECT m.TransferOrderId,
                     Txt = LEFT(m.Number, 50) + N': '
                           + CASE WHEN m.PostingStatus = 3 THEN N'reversed (' + m.PostingNumber + N')'
                                  WHEN m.PostingKind = N'Dispatch' AND m.SettledBase < m.QuantityBase THEN N'on the way (' + m.PostingNumber + N')'
                                  WHEN m.PostingKind = N'Dispatch' THEN N'dispatched (' + m.PostingNumber + N')'
                                  WHEN m.QuantityBase > 0 THEN N'received into ' + ISNULL(rw.WarehouseCode, N'') + N' (' + m.PostingNumber + N')'
                                  ELSE N'written off (' + m.PostingNumber + N')' END,
                     -- the distinct numbers of the order (COUNT(DISTINCT) is not a window function)
                     N  = DENSE_RANK() OVER (PARTITION BY m.TransferOrderId ORDER BY m.Number)
                          + DENSE_RANK() OVER (PARTITION BY m.TransferOrderId ORDER BY m.Number DESC) - 1,
                     Rn = ROW_NUMBER() OVER (PARTITION BY m.TransferOrderId
                                             ORDER BY CASE WHEN m.PostingStatus = 2 THEN 0 ELSE 1 END, m.TrackingId DESC)
              FROM @Match m
              LEFT JOIN masterdata.Warehouses rw ON rw.Id = m.ToWarehouseId) r
        WHERE r.Rn = 1
        OPTION (RECOMPILE);   -- runs only with a filter: sized for the rows found, never for the empty @Match of the first call

    -- THE FILTER ONCE, with each order's state: the shown status, Late and On the way are filters, so the state is
    -- worked out before the page, and the page and the totals both read it from here.
    DECLARE @Ids TABLE
    (
        Id             INT          NOT NULL PRIMARY KEY,
        StoredStatus   TINYINT      NOT NULL,
        DisplayStatus  NVARCHAR(20) NULL,
        StatusRank     INT          NOT NULL,
        IsLate         BIT          NOT NULL,
        ItemCount      INT          NOT NULL,
        OrderedBase    INT          NOT NULL,
        DispatchedBase INT          NOT NULL,
        ReceivedBase   INT          NOT NULL,
        OnTheWayBase   INT          NOT NULL,
        ToDispatchBase INT          NOT NULL,
        NotSentBase    INT          NOT NULL,
        LostBase       INT          NOT NULL
    );
    INSERT INTO @Ids (Id, StoredStatus, DisplayStatus, StatusRank, IsLate, ItemCount, OrderedBase, DispatchedBase, ReceivedBase,
                      OnTheWayBase, ToDispatchBase, NotSentBase, LostBase)
    SELECT o.Id, o.Status, st.DisplayStatus,
           CASE st.DisplayStatus WHEN N'Draft' THEN 1 WHEN N'PendingApproval' THEN 2 WHEN N'Released' THEN 3
                                 WHEN N'PartlyDispatched' THEN 4 WHEN N'Dispatched' THEN 5 WHEN N'PartlyReceived' THEN 6
                                 WHEN N'Received' THEN 7 WHEN N'Closed' THEN 8 ELSE 9 END,
           CAST(ISNULL(st.IsLate, 0) AS BIT), ISNULL(st.ItemCount, 0), ISNULL(st.OrderedBase, 0), ISNULL(st.DispatchedBase, 0),
           ISNULL(st.ReceivedBase, 0), ISNULL(st.OnTheWayBase, 0), ISNULL(st.ToDispatchBase, 0), ISNULL(st.NotSentBase, 0),
           ISNULL(st.LostBase, 0)
    FROM inventory.TransferOrders o
    INNER JOIN masterdata.Warehouses fw ON fw.Id = o.FromWarehouseId
    INNER JOIN masterdata.Warehouses tw ON tw.Id = o.ToWarehouseId
    OUTER APPLY inventory.fn_TransferOrder_State(o.Id) st
    WHERE (@BranchId IS NULL OR fw.BranchId = @BranchId OR tw.BranchId = @BranchId)
      AND (@FromWarehouseId IS NULL OR o.FromWarehouseId = @FromWarehouseId)
      AND (@ToWarehouseId IS NULL OR o.ToWarehouseId = @ToWarehouseId)
      AND (@DateFrom IS NULL OR o.DocumentDate >= @DateFrom)
      AND (@DateTo IS NULL OR o.DocumentDate <= @DateTo)
      AND (@WaitingForApproval = 0 OR o.Status = 4)
      AND (@ItemId IS NULL OR EXISTS (SELECT 1 FROM inventory.TransferOrderLines l WHERE l.TransferOrderId = o.Id AND l.ItemId = @ItemId))
      AND (@Mine IS NULL OR @MineUnrestricted = 1                                                          -- (92)
           OR (@Mine IN (N'Any', N'From') AND o.FromWarehouseId IN (SELECT WarehouseId FROM @MineIds))
           OR (@Mine IN (N'Any', N'To')   AND o.ToWarehouseId   IN (SELECT WarehouseId FROM @MineIds)))
      AND (@TrackingNo IS NULL OR o.Id IN (SELECT mo.TransferOrderId FROM @MatchOrder mo))                 -- (93)
      AND (@Status IS NULL
           OR (@Status = N'Open' AND o.Status = 2 AND ISNULL(st.DisplayStatus, N'') NOT IN (N'Received', N'Closed'))
           OR st.DisplayStatus = @Status)
      AND (@OnTheWayOnly = 0 OR st.OnTheWayBase > 0)
      AND (@LateOnly = 0 OR st.IsLate = 1)
      AND (@Search IS NULL
           OR o.DocumentNumber LIKE N'%' + @Search + N'%' OR o.ReferenceNo LIKE N'%' + @Search + N'%'
           OR fw.WarehouseCode LIKE N'%' + @Search + N'%' OR fw.WarehouseName LIKE N'%' + @Search + N'%'
           OR tw.WarehouseCode LIKE N'%' + @Search + N'%' OR tw.WarehouseName LIKE N'%' + @Search + N'%'
           OR EXISTS (SELECT 1 FROM inventory.TransferOrderLines l
                      INNER JOIN inventory.Items i ON i.Id = l.ItemId
                      WHERE l.TransferOrderId = o.Id AND i.ItemCode LIKE N'%' + @Search + N'%')
           OR EXISTS (SELECT 1 FROM inventory.TransferPostings p
                      WHERE p.TransferOrderId = o.Id AND p.DocumentNumber LIKE N'%' + @Search + N'%'));

    -- 1: the page
    SELECT o.Id, o.DocumentNumber, o.DocumentDate, o.BranchId, b.BranchCode,
           o.FromWarehouseId, FromWarehouseCode = fw.WarehouseCode, FromWarehouseName = fw.WarehouseName, FromBranchCode = fb.BranchCode,
           o.ToWarehouseId, ToWarehouseCode = tw.WarehouseCode, ToWarehouseName = tw.WarehouseName, ToBranchCode = tb.BranchCode,
           StatusCode = CASE o.Status WHEN 1 THEN N'Draft' WHEN 2 THEN N'Released' WHEN 3 THEN N'Cancelled' ELSE N'PendingApproval' END,
           x.DisplayStatus, x.IsLate, x.ItemCount, x.OrderedBase, x.DispatchedBase, x.ReceivedBase, x.OnTheWayBase,
           x.ToDispatchBase, x.NotSentBase, x.LostBase,
           o.ExpectedArrival, o.ReferenceNo, o.ReturnOfOrderId, ReturnOfNumber = ro.DocumentNumber,
           o.CreatedAtUtc, CreatedByName = cu.FullName,
           COUNT(*) OVER () AS TotalCount,
           -- (93) what happened to the number found (@MatchOrder: the order's latest matching row), + " and {n} more"
           MatchedTracking = CAST(CASE WHEN @TrackingNo IS NOT NULL AND mt.Txt IS NOT NULL
                                       THEN mt.Txt + CASE WHEN mt.N > 1 THEN N' and ' + CAST(mt.N - 1 AS NVARCHAR(10)) + N' more' ELSE N'' END
                                  END AS NVARCHAR(300))
    FROM @Ids x
    INNER JOIN inventory.TransferOrders o   ON o.Id = x.Id
    INNER JOIN masterdata.Branches b        ON b.Id = o.BranchId
    INNER JOIN masterdata.Warehouses fw     ON fw.Id = o.FromWarehouseId
    INNER JOIN masterdata.Branches fb       ON fb.Id = fw.BranchId
    INNER JOIN masterdata.Warehouses tw     ON tw.Id = o.ToWarehouseId
    INNER JOIN masterdata.Branches tb       ON tb.Id = tw.BranchId
    LEFT  JOIN inventory.TransferOrders ro  ON ro.Id = o.ReturnOfOrderId
    LEFT  JOIN security.Users cu            ON cu.Id = o.CreatedBy
    LEFT  JOIN @MatchOrder mt               ON mt.TransferOrderId = o.Id                                    -- (93)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN o.DocumentNumber WHEN N'FromWarehouse' THEN fw.WarehouseCode
                             WHEN N'ToWarehouse' THEN tw.WarehouseCode END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN o.DocumentNumber WHEN N'FromWarehouse' THEN fw.WarehouseCode
                             WHEN N'ToWarehouse' THEN tw.WarehouseCode END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'DocumentDate' THEN o.DocumentDate END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'DocumentDate' THEN o.DocumentDate END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Status' THEN x.StatusRank END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Status' THEN x.StatusRank END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'OrderedBase' THEN x.OrderedBase END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'OrderedBase' THEN x.OrderedBase END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'OnTheWayBase' THEN x.OnTheWayBase END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'OnTheWayBase' THEN x.OnTheWayBase END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'ExpectedArrival' THEN o.ExpectedArrival END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'ExpectedArrival' THEN o.ExpectedArrival END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN o.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN o.CreatedAtUtc END DESC,
        o.DocumentDate DESC, o.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;

    -- 2: totals over the whole filter (the list's summary row)
    SELECT Orders             = COUNT(*),
           OnTheWayBase       = ISNULL(SUM(x.OnTheWayBase), 0),
           LateOrders         = ISNULL(SUM(CASE WHEN x.IsLate = 1 THEN 1 ELSE 0 END), 0),
           WaitingForApproval = ISNULL(SUM(CASE WHEN x.StoredStatus = 4 THEN 1 ELSE 0 END), 0)
    FROM @Ids x;
END
GO

-- (93) THE DIALOG'S DONE (5.3.7.10): every problem of the batch, serial and expiry rows of a dispatch being typed, with
--      the posting's sentences - errors for the whole dispatch, warnings for @ForLineId (or all). Read only, no lock, no
--      warehouse check (a read, W3): the dispatch checks everything again.
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_CheckDispatchTracking
    @Id        INT,
    @Lines     inventory.tvp_TransferDispatchLine READONLY,
    @Tracking  inventory.tvp_TransferDispatchTracking READONLY,
    @ForLineId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id) THROW 62006, 'Transfer order not found.', 1;

    -- the numbers as the posting keeps them (normalised once)
    DECLARE @T inventory.tvp_TransferDispatchTracking;
    INSERT INTO @T (TransferOrderLineId, RowNumber, BatchNo, SerialNo, ExpiryDate, QuantityBase)
    SELECT TransferOrderLineId, RowNumber,
           CASE WHEN BatchNo IS NOT NULL THEN inventory.fn_TrackingNo_Normalize(BatchNo) END,      -- a call only when there is a number
           CASE WHEN SerialNo IS NOT NULL THEN inventory.fn_TrackingNo_Normalize(SerialNo) END,
           ExpiryDate, QuantityBase
    FROM @Tracking;

    SELECT q.Seq, q.Severity, q.ErrorNumber, q.TransferOrderLineId, q.LineNumber, q.RowNumber, q.Message
    FROM inventory.fn_TransferDispatch_TrackingProblems(@Id, @Lines, @T, @ForLineId) q
    ORDER BY q.Seq, q.LineNumber, q.RowNumber;
END
GO

-- (93) THE SERIALS KNOWN AT THE SOURCE (5.3.7.11, B12): for a serial item, the serials whose LATEST posted transfer
--      event (the latest row on a posted posting, by the row's Id, as fn_TransferSerial_LastEvent) is a receipt that
--      received them into the order's From - received into the source by transfers and not sent since - set-based over
--      the item's serials (index ItemSerial), by date received, at most 2,000. Other kinds: no
--      row. Result 1: SerialNo, ExpiryDate, ReceivedByNumber, ReceivedOn. Result 2: the line's TrackingKind now (2 / 1 /
--      3 / NULL), for the answer's trackingKind.
CREATE OR ALTER PROCEDURE inventory.usp_TransferOrder_TrackingSuggestions
    @Id                  INT,
    @TransferOrderLineId INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ItemId INT, @FromId INT, @K TINYINT;
    SELECT @ItemId = l.ItemId, @FromId = o.FromWarehouseId,
           @K = CASE i.TrackingMode WHEN 2 THEN 2 WHEN 1 THEN 1 ELSE CASE WHEN i.RequiresExpiry = 1 THEN 3 END END
    FROM inventory.TransferOrderLines l
    INNER JOIN inventory.TransferOrders o ON o.Id = l.TransferOrderId
    INNER JOIN inventory.Items i          ON i.Id = l.ItemId
    WHERE l.Id = @TransferOrderLineId AND l.TransferOrderId = @Id;
    IF @ItemId IS NULL THROW 62006, 'Transfer order not found.', 1;

    SELECT TOP (2000) x.SerialNo, x.ExpiryDate, ReceivedByNumber = x.DocumentNumber, ReceivedOn = x.PostingDate
    FROM (SELECT t.SerialNo, t.ExpiryDate, t.QuantityBase, t.DispatchTrackingId, p.DocumentNumber, p.PostingDate, p.ToWarehouseId,
                 Rn = ROW_NUMBER() OVER (PARTITION BY t.SerialNo ORDER BY t.Id DESC)
          FROM inventory.TransferPostingTracking t
          INNER JOIN inventory.TransferPostings p ON p.Id = t.PostingId AND p.Status = 2
          WHERE @K = 2 AND t.ItemId = @ItemId AND t.SerialNo IS NOT NULL) x
    WHERE x.Rn = 1 AND x.DispatchTrackingId IS NOT NULL AND x.QuantityBase = 1 AND x.ToWarehouseId = @FromId
    ORDER BY x.PostingDate, x.SerialNo;

    SELECT TrackingKind = @K;
END
GO

/* ================================================================== 9. Check */

-- 1. The objects of script 93 (expected: none MISSING)
SELECT o.ObjectName, ObjectType = ISNULL(so.type_desc, N'MISSING')
FROM (VALUES
  (N'inventory.TransferPostingTracking'), (N'inventory.fn_TrackingNo_Normalize'), (N'inventory.fn_TransferSerial_LastEvent'),
  (N'inventory.fn_TransferDispatch_TrackingProblems'), (N'inventory.usp_Item_SetTracking'), (N'inventory.usp_TransferPosting_Tracking'),
  (N'inventory.usp_TransferOrder_CheckDispatchTracking'), (N'inventory.usp_TransferOrder_TrackingSuggestions')) o (ObjectName)
LEFT JOIN sys.objects so ON so.object_id = OBJECT_ID(o.ObjectName)
UNION ALL
SELECT c.ColumnName, CASE WHEN COL_LENGTH(c.TableName, c.ColumnName) IS NULL THEN N'MISSING' ELSE N'COLUMN' END
FROM (VALUES (N'inventory.Items', N'TrackingMode'), (N'inventory.Items', N'RequiresExpiry'), (N'inventory.Items', N'SerialLength'),
             (N'inventory.TransferPostingLines', N'TrackingKind')) c (TableName, ColumnName)
UNION ALL
SELECT t.TypeName, CASE WHEN EXISTS (SELECT 1 FROM sys.table_types tt WHERE tt.name = t.TypeName AND tt.schema_id = SCHEMA_ID(N'inventory'))
                        THEN N'TABLE_TYPE' ELSE N'MISSING' END
FROM (VALUES (N'tvp_TransferDispatchTracking'), (N'tvp_TransferReceiptTracking')) t (TypeName);

-- 2. Items by tracking (an empty database: no row; a copy: every item None / no until someone ticks them)
SELECT TrackingMode, RequiresExpiry, Items = COUNT(*) FROM inventory.Items GROUP BY TrackingMode, RequiresExpiry ORDER BY TrackingMode, RequiresExpiry;

-- 3. Each tracked dispatch line agrees with its rows: some rows, their pcs = the line's, their settled = the line's
--    (expected: 0 rows)
SELECT BadDispatchLine = pl.Id, pl.QuantityBase, pl.SettledBase, x.N, x.Q, x.S
FROM inventory.TransferPostingLines pl
INNER JOIN inventory.TransferPostings p ON p.Id = pl.PostingId AND p.Kind = N'Dispatch'
OUTER APPLY (SELECT N = COUNT(*), Q = SUM(t.QuantityBase), S = SUM(t.SettledBase)
             FROM inventory.TransferPostingTracking t WHERE t.PostingLineId = pl.Id) x
WHERE pl.TrackingKind IS NOT NULL
  AND (x.N = 0 OR x.Q <> pl.QuantityBase OR x.S <> pl.SettledBase);

-- 4. Each tracked receipt line agrees with its rows: received and lost (expected: 0 rows)
SELECT BadReceiptLine = pl.Id, pl.QuantityBase, pl.LostBase, x.N, x.Q, x.L
FROM inventory.TransferPostingLines pl
INNER JOIN inventory.TransferPostings p ON p.Id = pl.PostingId AND p.Kind = N'Receipt'
OUTER APPLY (SELECT N = COUNT(*), Q = SUM(t.QuantityBase), L = SUM(t.LostBase)
             FROM inventory.TransferPostingTracking t WHERE t.PostingLineId = pl.Id) x
WHERE pl.TrackingKind IS NOT NULL
  AND (x.N = 0 OR x.Q <> pl.QuantityBase OR x.L <> pl.LostBase);

-- 5. A line without TrackingKind has no row; every row's Kind is its line's (expected: 0 rows)
SELECT RowOfWrongLine = t.Id, t.Kind, pl.TrackingKind
FROM inventory.TransferPostingTracking t
INNER JOIN inventory.TransferPostingLines pl ON pl.Id = t.PostingLineId
WHERE pl.TrackingKind IS NULL OR pl.TrackingKind <> t.Kind;

-- 6. No serial on the way twice (expected: 0 rows)
SELECT SerialOnTheWayTwice = d.SerialNo, d.ItemId
FROM inventory.TransferPostingTracking d
INNER JOIN inventory.TransferPostings p ON p.Id = d.PostingId AND p.Kind = N'Dispatch' AND p.Status = 2
WHERE d.SerialNo IS NOT NULL AND d.DispatchTrackingId IS NULL AND d.SettledBase < d.QuantityBase
GROUP BY d.ItemId, d.SerialNo
HAVING COUNT(*) > 1;

-- 7. The On the way legs of each tracked dispatch line, by expiry, equal its rows by expiry (expected: 0 rows)
SELECT LegsDifferFromRows = pl.Id, x.ExpiryDate
FROM inventory.TransferPostingLines pl
INNER JOIN inventory.TransferPostings p ON p.Id = pl.PostingId AND p.Kind = N'Dispatch'
CROSS APPLY (SELECT d.ExpiryDate, Q = SUM(d.QuantityBase) FROM inventory.TransferPostingTracking d
             WHERE d.PostingLineId = pl.Id GROUP BY d.ExpiryDate) x
WHERE pl.TrackingKind IS NOT NULL
  AND x.Q <> ISNULL((SELECT SUM(m.QuantityBase) FROM inventory.StockMovements m
                     WHERE m.DocumentFamily = N'Transfer' AND m.DocumentTypeCode = N'TRD' AND m.DocumentId = pl.PostingId
                       AND m.DocumentLineId = pl.Id AND m.WarehouseId = pl.TransitWarehouseId AND m.IsReversal = 0
                       AND ((m.ExpiryDate IS NULL AND x.ExpiryDate IS NULL) OR m.ExpiryDate = x.ExpiryDate)), 0);

-- 8. A dispatch row's SettledBase = received + lost of the rows of POSTED receipts pointing at it (expected: 0 rows)
SELECT BadSettled = d.Id, d.SettledBase, x.Q
FROM inventory.TransferPostingTracking d
OUTER APPLY (SELECT Q = ISNULL(SUM(r.QuantityBase + r.LostBase), 0)
             FROM inventory.TransferPostingTracking r
             INNER JOIN inventory.TransferPostings rp ON rp.Id = r.PostingId AND rp.Status = 2
             WHERE r.DispatchTrackingId = d.Id) x
WHERE d.DispatchTrackingId IS NULL AND d.SettledBase <> x.Q;

-- 9. A row's PostingId and ItemId are its posting line's (expected: 0 rows)
SELECT RowOfOtherPosting = t.Id
FROM inventory.TransferPostingTracking t
INNER JOIN inventory.TransferPostingLines pl ON pl.Id = t.PostingLineId
WHERE pl.PostingId <> t.PostingId OR pl.ItemId <> t.ItemId;

-- 10. Every transfer reversal row has the expiry of the row it reverses: a reversed posting nets to zero per line,
--     warehouse, reason and expiry (expected: 0 rows)
SELECT ReversalDiffers = m.DocumentTypeCode, m.DocumentId, m.DocumentLineId, m.WarehouseId, m.ExpiryDate
FROM inventory.StockMovements m
INNER JOIN inventory.TransferPostings p ON p.Id = m.DocumentId AND p.Status = 3
WHERE m.DocumentFamily = N'Transfer' AND m.DocumentTypeCode = CASE p.Kind WHEN N'Dispatch' THEN N'TRD' ELSE N'TRR' END
GROUP BY m.DocumentTypeCode, m.DocumentId, m.DocumentLineId, m.WarehouseId, m.ReasonCode, m.ExpiryDate
HAVING SUM(m.QuantityBase) <> 0;

PRINT 'Script 93 applied: batch, serial and expiry on transfers.';
GO
