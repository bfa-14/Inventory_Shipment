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
CREATE   PROCEDURE inventory.usp_TransferOrder_Search
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

