SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 114: FIXES - TEMPORARY TABLES IN THE DATABASE'S COLLATION

   Reported on testing: Reports › Container Report and Reports › Container Charges answered "The server ran into a
   problem." Run in the database, both procedures stopped with Msg 451 "Cannot resolve collation conflict between
   "SQL_Latin1_General_CP1256_CI_AS" and "SQL_Latin1_General_CP1_CI_AS" in CASE operator".

   WHY. Testing's database was restored from a copy made on a SQL Server whose collation is
   SQL_Latin1_General_CP1256_CI_AS (the default of a SQL Server installed on an Arabic Windows), into production's
   SQL Server, whose collation is SQL_Latin1_General_CP1_CI_AS. A database keeps the collation it was created with;
   a temporary table lives in tempdb, so a text column of a CREATE TABLE #x takes the SERVER's collation unless it
   says otherwise. Wherever the two meet in one expression - a CASE, a COALESCE, an =, a UNION of a #table's text
   and a table's text or a literal - SQL Server cannot choose and refuses the statement (451 / 468). On a developer
   PC the database and the server share one collation, so nothing shows there.

   THE FIX: every text column of every CREATE TABLE #x says COLLATE DATABASE_DEFAULT - the collation of the database
   the procedure runs in, whatever the server's. The twelve procedures that create such tables, each re-created
   from its CURRENT body (the last one in Schema.sql) with that one change and nothing else:

       sales.usp_Customer_Statement                 (from script 37)
       purchase.usp_PurchaseOrder_DueReminders      (from script 42)
       purchase.usp_PurchaseOrder_Resend            (from script 42)
       purchase.usp_PurchaseOrder_RequestApproval   (from script 44)
       logistics.usp_Shipment_Board                 (from script 82)
       inventory.usp_StockLevel_CompanySearch       (from script 91)
       inventory.usp_StockLevel_Search              (from script 91)
       inventory.usp_ItemWarehouseLevel_Import      (from script 92)
       reporting.usp_ItemBalance_Data               (from script 103)
       logistics.usp_Container_NextStepPreview      (from script 104)
       reporting.usp_ContainerChargeReport          (from script 105)
       logistics.usp_ContainerReport                (from script 110)

   Nothing changes in a database whose collation is its server's (DATABASE_DEFAULT is then the same collation).
   Table variables, table types, SELECT ... INTO #x and the tables themselves already follow the database.
   From now on a CREATE TABLE #x gives each text column COLLATE DATABASE_DEFAULT (CLAUDE.md, "How a change is made").

   No table, column, permission or error number. Requires scripts 37, 42, 44, 82, 91, 92, 103, 104, 105 and 110.
   Idempotent.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'reporting.usp_ContainerChargeReport', N'P') IS NULL
   OR OBJECT_ID(N'reporting.usp_ItemBalance_Data', N'P') IS NULL
   OR NOT EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID(N'logistics.usp_ContainerReport') AND name = N'@WithCharges')
    THROW 50000, 'Script 114 requires scripts 103, 105 and 110: apply them first.', 1;
GO

/* ================================================================== 1. The procedures re-created */

-- Re-created (114) from the body of script 37: COLLATE DATABASE_DEFAULT on the text columns of its #tables (3).
CREATE OR ALTER PROCEDURE sales.usp_Customer_Statement
    @ClientId INT,
    @DateFrom DATE = NULL,
    @DateTo   DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @ClientId AND IsClient = 1)
        THROW 71006, 'Customer not found.', 1;

    DECLARE @Base NVARCHAR(10) = (SELECT TOP (1) CurrencyCode FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1);

    CREATE TABLE #E (
        EntryDate DATE NOT NULL, SortGroup TINYINT NOT NULL, DocumentId INT NOT NULL, EntryType NVARCHAR(30) COLLATE DATABASE_DEFAULT NOT NULL,
        DocumentNumber NVARCHAR(50) COLLATE DATABASE_DEFAULT NULL, CurrencyCode NVARCHAR(10) COLLATE DATABASE_DEFAULT NULL, DecimalPlaces TINYINT NULL, DocAmount DECIMAL(18,2) NOT NULL,
        Debit DECIMAL(18,2) NOT NULL, Credit DECIMAL(18,2) NOT NULL, Balance DECIMAL(18,2) NULL);

    DECLARE @SINV INT = (SELECT Id FROM inventory.DocumentTypes WHERE Code = N'SINV');
    DECLARE @SRET INT = (SELECT Id FROM inventory.DocumentTypes WHERE Code = N'SRET');

    -- Invoices (posted, or cancelled after posting)
    INSERT #E (EntryDate, SortGroup, DocumentId, EntryType, DocumentNumber, CurrencyCode, DecimalPlaces, DocAmount, Debit, Credit)
    SELECT CAST(d.DocumentDate AS DATE), 1, d.Id, N'Invoice', d.DocumentNumber, c.CurrencyCode, c.DecimalPlaces, d.TotalAmount, d.TotalAmountBase, 0
    FROM sales.SalesDocuments d INNER JOIN masterdata.Currencies c ON c.Id = d.CurrencyId
    WHERE d.ClientId = @ClientId AND d.DocumentTypeId = @SINV AND d.PostedAtUtc IS NOT NULL AND d.Status IN (2, 3);

    INSERT #E (EntryDate, SortGroup, DocumentId, EntryType, DocumentNumber, CurrencyCode, DecimalPlaces, DocAmount, Debit, Credit)
    SELECT CAST(d.CancelledAtUtc AS DATE), 2, d.Id, N'Invoice cancelled', d.DocumentNumber, c.CurrencyCode, c.DecimalPlaces, d.TotalAmount, 0, d.TotalAmountBase
    FROM sales.SalesDocuments d INNER JOIN masterdata.Currencies c ON c.Id = d.CurrencyId
    WHERE d.ClientId = @ClientId AND d.DocumentTypeId = @SINV AND d.Status = 3 AND d.PostedAtUtc IS NOT NULL AND d.CancelledAtUtc IS NOT NULL;

    -- Sales returns
    INSERT #E (EntryDate, SortGroup, DocumentId, EntryType, DocumentNumber, CurrencyCode, DecimalPlaces, DocAmount, Debit, Credit)
    SELECT CAST(d.DocumentDate AS DATE), 3, d.Id, N'Sales return', d.DocumentNumber, c.CurrencyCode, c.DecimalPlaces, d.TotalAmount, 0, d.TotalAmountBase
    FROM sales.SalesDocuments d INNER JOIN masterdata.Currencies c ON c.Id = d.CurrencyId
    WHERE d.ClientId = @ClientId AND d.DocumentTypeId = @SRET AND d.Status = 2;

    -- Receipts (posted, or reversed after posting) and their reversals
    INSERT #E (EntryDate, SortGroup, DocumentId, EntryType, DocumentNumber, CurrencyCode, DecimalPlaces, DocAmount, Debit, Credit)
    SELECT r.ReceiptDate, 4, r.Id, N'Receipt', r.ReceiptNumber, c.CurrencyCode, c.DecimalPlaces, r.Amount, 0, r.AmountBase
    FROM sales.Receipts r INNER JOIN masterdata.Currencies c ON c.Id = r.CurrencyId
    WHERE r.ClientId = @ClientId AND r.PostedAtUtc IS NOT NULL AND r.Status IN (2, 3);

    INSERT #E (EntryDate, SortGroup, DocumentId, EntryType, DocumentNumber, CurrencyCode, DecimalPlaces, DocAmount, Debit, Credit)
    SELECT CAST(r.ReversedAtUtc AS DATE), 5, r.Id, N'Receipt reversed', r.ReceiptNumber, c.CurrencyCode, c.DecimalPlaces, r.Amount, r.AmountBase, 0
    FROM sales.Receipts r INNER JOIN masterdata.Currencies c ON c.Id = r.CurrencyId
    WHERE r.ClientId = @ClientId AND r.Status = 3 AND r.ReversedAtUtc IS NOT NULL;

    -- Running balance over the whole history, so a period starts from the true balance brought forward.
    ;WITH R AS (
        SELECT EntryDate, SortGroup, DocumentId, Balance,
               NewBalance = SUM(Debit - Credit) OVER (ORDER BY EntryDate, SortGroup, DocumentId ROWS UNBOUNDED PRECEDING)
        FROM #E)
    UPDATE R SET Balance = NewBalance;

    DECLARE @Opening DECIMAL(18,2) = ISNULL((SELECT SUM(Debit - Credit) FROM #E WHERE @DateFrom IS NOT NULL AND EntryDate < @DateFrom), 0);

    SELECT p.Id AS ClientId, p.PartyCode AS ClientCode, p.PartyName AS ClientName, @Base AS BaseCurrencyCode,
           OpeningBalance = @Opening
    FROM masterdata.Parties p WHERE p.Id = @ClientId;

    SELECT EntryDate, EntryType, DocumentId, DocumentNumber, CurrencyCode, DecimalPlaces, DocAmount, Debit, Credit, Balance
    FROM #E
    WHERE (@DateFrom IS NULL OR EntryDate >= @DateFrom) AND (@DateTo IS NULL OR EntryDate <= @DateTo)
    ORDER BY EntryDate, SortGroup, DocumentId;
END
GO

-- Re-created (114) from the body of script 42: COLLATE DATABASE_DEFAULT on the text columns of its #tables (4).
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_DueReminders
    @MaxOrders INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @MaxOrders IS NULL OR @MaxOrders < 1 SET @MaxOrders = 50;

    DECLARE @Hours INT = ISNULL((SELECT ReminderHours FROM purchase.ApprovalSettings WHERE Id = 1), 0);

    CREATE TABLE #IssuedLinks
    (
        PurchaseDocumentId INT NOT NULL, UserId INT NOT NULL, FullName NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL, Email NVARCHAR(256) COLLATE DATABASE_DEFAULT NULL,
        Token VARCHAR(64) COLLATE DATABASE_DEFAULT NULL, ExpiresAtUtc DATETIME2(3) NULL, RequestNo INT NOT NULL, Channel NVARCHAR(10) COLLATE DATABASE_DEFAULT NOT NULL,
        CanApproveInApp BIT NOT NULL, SendEmail BIT NOT NULL
    );
    CREATE TABLE #Due (PurchaseDocumentId INT NOT NULL PRIMARY KEY, WaitingSinceUtc DATETIME2(3) NULL, LastSentUtc DATETIME2(3) NULL);

    IF @Hours > 0
        INSERT INTO #Due (PurchaseDocumentId, WaitingSinceUtc, LastSentUtc)
        SELECT TOP (@MaxOrders) d.Id, w.WaitingSinceUtc, w.LastSentUtc
        FROM purchase.PurchaseDocuments d
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId AND dt.Code = N'PO'
        CROSS APPLY (SELECT WaitingSinceUtc = COALESCE((SELECT MAX(CAST(e.AtUtc AS DATETIME2(3))) FROM purchase.PurchaseOrderApprovalEvents e
                                                        WHERE e.PurchaseDocumentId = d.Id AND e.EventType = 1), d.ApprovalRequestedAtUtc),
                            LastSentUtc = COALESCE((SELECT MAX(CAST(e.AtUtc AS DATETIME2(3))) FROM purchase.PurchaseOrderApprovalEvents e
                                                    WHERE e.PurchaseDocumentId = d.Id AND e.EventType IN (1, 2, 3)), d.ApprovalRequestedAtUtc)) w
        WHERE d.Status = 5
          AND w.LastSentUtc < DATEADD(HOUR, -@Hours, SYSUTCDATETIME())
        ORDER BY w.LastSentUtc, d.Id;

    DECLARE @Id INT, @LastSent DATETIME2(3), @Err NVARCHAR(2048);
    DECLARE due CURSOR LOCAL FAST_FORWARD FOR SELECT PurchaseDocumentId FROM #Due ORDER BY LastSentUtc, PurchaseDocumentId;
    OPEN due;
    FETCH NEXT FROM due INTO @Id;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            -- still waiting and still due (another API instance may have reminded it meanwhile)
            SET @LastSent = NULL;
            SELECT @LastSent = COALESCE((SELECT MAX(CAST(e.AtUtc AS DATETIME2(3))) FROM purchase.PurchaseOrderApprovalEvents e
                                         WHERE e.PurchaseDocumentId = d.Id AND e.EventType IN (1, 2, 3)), d.ApprovalRequestedAtUtc)
            FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
            WHERE d.Id = @Id AND d.Status = 5;

            IF @LastSent < DATEADD(HOUR, -@Hours, SYSUTCDATETIME())
                EXEC purchase.usp_PurchaseOrder_IssueLinks @PurchaseDocumentId = @Id, @EventType = 2, @UserId = NULL;

            COMMIT TRANSACTION;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
            IF ERROR_NUMBER() <> 65015
            BEGIN
                SET @Err = N'Reminder of purchase order ' + CAST(@Id AS NVARCHAR(10)) + N' skipped: ' + ERROR_MESSAGE();
                RAISERROR (N'%s', 10, 1, @Err) WITH NOWAIT;
            END
        END CATCH

        FETCH NEXT FROM due INTO @Id;
    END
    CLOSE due;
    DEALLOCATE due;

    SELECT l.UserId, l.FullName, l.Email, l.Token, l.ExpiresAtUtc, l.RequestNo, l.Channel, l.CanApproveInApp, l.SendEmail,
           l.PurchaseDocumentId, d.WaitingSinceUtc
    FROM #IssuedLinks l
    INNER JOIN #Due d ON d.PurchaseDocumentId = l.PurchaseDocumentId
    ORDER BY d.LastSentUtc, l.PurchaseDocumentId, l.FullName;
END
GO

-- Re-created (114) from the body of script 42: COLLATE DATABASE_DEFAULT on the text columns of its #tables (4).
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_Resend
    @PurchaseDocumentId INT,
    @RowVersion         BINARY(8) = NULL,
    @UserId             INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #IssuedLinks
    (
        PurchaseDocumentId INT NOT NULL, UserId INT NOT NULL, FullName NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL, Email NVARCHAR(256) COLLATE DATABASE_DEFAULT NULL,
        Token VARCHAR(64) COLLATE DATABASE_DEFAULT NULL, ExpiresAtUtc DATETIME2(3) NULL, RequestNo INT NOT NULL, Channel NVARCHAR(10) COLLATE DATABASE_DEFAULT NOT NULL,
        CanApproveInApp BIT NOT NULL, SendEmail BIT NOT NULL
    );

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Current BINARY(8);
        SELECT @Status = d.Status, @TypeCode = dt.Code, @Current = d.RowVersion
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @PurchaseDocumentId;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @TypeCode <> N'PO' OR @Status <> 5 THROW 65010, 'Only a purchase order waiting for approval can be sent again.', 1;
        IF @RowVersion IS NOT NULL AND @Current <> @RowVersion
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;

        EXEC purchase.usp_PurchaseOrder_IssueLinks @PurchaseDocumentId = @PurchaseDocumentId, @EventType = 3, @UserId = @UserId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT UserId, FullName, Email, Token, ExpiresAtUtc, RequestNo, Channel, CanApproveInApp, SendEmail
    FROM #IssuedLinks
    ORDER BY FullName;
END
GO

-- Re-created (114) from the body of script 44: COLLATE DATABASE_DEFAULT on the text columns of its #tables (4).
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseOrder_RequestApproval
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL,
    @ValidHours INT       = NULL      -- NULL = ApprovalSettings.LinkValidHours
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @TypeCode NVARCHAR(20), @Status TINYINT, @SupplierId INT;
    SELECT @TypeCode = dt.Code, @Status = d.Status, @SupplierId = d.SupplierId
    FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    WHERE d.Id = @Id;

    IF @TypeCode IS NULL THROW 65006, 'Document not found.', 1;
    IF @TypeCode <> N'PO' THROW 65010, 'Only purchase orders go through approval.', 1;
    IF @Status <> 1 THROW 65010, 'Only a draft purchase order can be sent for approval.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
    IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id)
        THROW 65009, 'The purchase order has no lines. Add at least one item before sending it for approval.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SupplierId AND IsActive = 1)
        THROW 65008, 'The supplier is inactive.', 1;
    IF ISNULL((SELECT EmailSupplierOnApproval FROM purchase.ApprovalSettings WHERE Id = 1), 0) = 1
       AND NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SupplierId AND NULLIF(LTRIM(RTRIM(Email)), N'') IS NOT NULL)
        THROW 65016, 'The supplier has no email in Parties. Add it first: the approved order is emailed to the supplier.', 1;
    IF purchase.fn_PurchaseOrder_NeedsApproval(@Id) = 0
        THROW 65022, 'This order does not need approval: post it.', 1;

    CREATE TABLE #IssuedLinks
    (
        PurchaseDocumentId INT NOT NULL, UserId INT NOT NULL, FullName NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL, Email NVARCHAR(256) COLLATE DATABASE_DEFAULT NULL,
        Token VARCHAR(64) COLLATE DATABASE_DEFAULT NULL, ExpiresAtUtc DATETIME2(3) NULL, RequestNo INT NOT NULL, Channel NVARCHAR(10) COLLATE DATABASE_DEFAULT NOT NULL,
        CanApproveInApp BIT NOT NULL, SendEmail BIT NOT NULL
    );

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE purchase.PurchaseDocuments
        SET Status = 5, ApprovalRequestedAtUtc = SYSUTCDATETIME(), ApprovalRequestedBy = @UserId,
            RejectedAtUtc = NULL, RejectedBy = NULL, RejectReason = NULL,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id AND Status = 1;
        IF @@ROWCOUNT = 0 THROW 65010, 'Only a draft purchase order can be sent for approval.', 1;

        -- links of the by-email approvers, event 1, audit line (65015 when nobody can approve)
        EXEC purchase.usp_PurchaseOrder_IssueLinks @PurchaseDocumentId = @Id, @EventType = 1, @UserId = @UserId, @ValidHours = @ValidHours;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT UserId, FullName, Email, Token, ExpiresAtUtc, RequestNo, Channel, CanApproveInApp, SendEmail
    FROM #IssuedLinks
    ORDER BY FullName;
END
GO

-- Re-created (114) from the body of script 82: COLLATE DATABASE_DEFAULT on the text columns of its #tables (1).
CREATE OR ALTER PROCEDURE logistics.usp_Shipment_Board
    @Search          NVARCHAR(100) = NULL,   -- ref, container no., B/L, vessel or truck, purchase order number
    @SupplierId      INT           = NULL,
    @PurchaseOrderId INT           = NULL,   -- containers carrying lines of this order
    @BranchId        INT           = NULL,
    @PlaceId         INT           = NULL,   -- where it stands, or the From / To of the leg carrying it
    @LateOnly        BIT           = 0,      -- the leg in progress has an ETA before today
    @WithPlannedLeg  BIT           = 0,      -- a planned next leg holds it
    @ShowReceived    BIT           = 0,      -- + the containers received in the last @ReceivedDays days (read-only)
    @ReceivedDays    INT           = 30
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @LateOnly = ISNULL(@LateOnly, 0);
    SET @WithPlannedLeg = ISNULL(@WithPlannedLeg, 0);
    SET @ShowReceived = ISNULL(@ShowReceived, 0);
    IF @ReceivedDays IS NULL OR @ReceivedDays < 1 SET @ReceivedDays = 30;
    IF @ReceivedDays > 366 SET @ReceivedDays = 366;
    DECLARE @Today DATE = CAST(SYSUTCDATETIME() AS DATE);
    DECLARE @ReceivedFrom DATE = DATEADD(DAY, -@ReceivedDays, @Today);

    -- 1. THE CONTAINERS ON THE BOARD: Draft to Cleared, and with the switch the ones received lately (the Tracking board's
    -- rule: offloaded on or after the date); then the filters, each a set-based step over those (an OR of searches over
    -- 50,000 containers took 28 s).
    CREATE TABLE #C (Id INT NOT NULL PRIMARY KEY, Status TINYINT NOT NULL);
    INSERT INTO #C (Id, Status)
    SELECT c.Id, c.Status
    FROM logistics.Containers c
    WHERE (c.Status BETWEEN 1 AND 5 OR (@ShowReceived = 1 AND c.Status IN (6, 7) AND c.OffloadedDate >= @ReceivedFrom))
      AND (@BranchId IS NULL OR c.BranchId = @BranchId)
    OPTION (RECOMPILE);

    -- the search: the container's ref, number, B/L or vessel, the number of an order on it, or the vessel or truck of the
    -- leg carrying it
    IF @Search IS NOT NULL
    BEGIN
        DECLARE @Like NVARCHAR(110) = N'%' + @Search + N'%';
        SELECT x.Id
        INTO #Found
        FROM #C x
        INNER JOIN logistics.Containers c ON c.Id = x.Id
        WHERE c.ContainerRef LIKE @Like OR c.ContainerNo LIKE @Like OR c.BlNo LIKE @Like OR c.VesselName LIKE @Like
        UNION
        SELECT x.Id
        FROM #C x
        INNER JOIN logistics.ContainerLines cl  ON cl.ContainerId = x.Id
        INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
        WHERE d.DocumentNumber LIKE @Like
        UNION
        SELECT x.Id
        FROM #C x
        INNER JOIN logistics.MovementContainers mc ON mc.ContainerId = x.Id
        INNER JOIN logistics.Movements m           ON m.Id = mc.MovementId AND m.Status = 2
        WHERE m.VehicleOrVessel LIKE @Like;

        DELETE x FROM #C x WHERE NOT EXISTS (SELECT 1 FROM #Found f WHERE f.Id = x.Id);
    END

    IF @SupplierId IS NOT NULL
        DELETE x
        FROM #C x
        WHERE NOT EXISTS (SELECT 1
                          FROM logistics.ContainerLines cl
                          INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                          WHERE cl.ContainerId = x.Id AND d.SupplierId = @SupplierId);

    IF @PurchaseOrderId IS NOT NULL
        DELETE x
        FROM #C x
        WHERE NOT EXISTS (SELECT 1 FROM logistics.ContainerLines cl WHERE cl.ContainerId = x.Id AND cl.PurchaseOrderId = @PurchaseOrderId);

    -- 2. WHERE EACH STANDS: the definitions of fn_Container_ShipState (phase 1), worked out SET-BASED over the movements of
    -- the board's containers, read once: its movements not cancelled, the latest of them (where its next leg leaves from),
    -- the one in progress, its next planned one (the lowest Id above the latest it started or made), its last completed
    -- one; and its latest completed Delivery (fn_Container_LastDelivery's order). Read through the functions for each
    -- container, the same took seconds on 5,000 containers.
    SELECT mc.ContainerId, MovementId = m.Id, m.Status, m.MovementTypeId, m.ToPlaceId, m.EndDate, m.CompletedAtUtc
    INTO #M
    FROM #C x
    INNER JOIN logistics.MovementContainers mc ON mc.ContainerId = x.Id
    INNER JOIN logistics.Movements m           ON m.Id = mc.MovementId AND m.Status <> 4;
    CREATE CLUSTERED INDEX IX_M ON #M (ContainerId, MovementId);

    SELECT x.Id, MovementCount = COUNT(m.MovementId), LatestId = MAX(m.MovementId),
           ActiveId = MAX(CASE WHEN m.Status = 2 THEN m.MovementId END),
           StartedMaxId = MAX(CASE WHEN m.Status IN (2, 3) THEN m.MovementId END),
           LastCompletedId = MAX(CASE WHEN m.Status = 3 THEN m.MovementId END)
    INTO #Ms
    FROM #C x
    LEFT JOIN #M m ON m.ContainerId = x.Id
    GROUP BY x.Id;

    SELECT s.Id, s.MovementCount, s.LatestId, s.ActiveId, s.LastCompletedId, PlannedId = pn.PlannedId,
           LastDeliveryId = ld.MovementId
    INTO #Sh
    FROM #Ms s
    LEFT JOIN (SELECT m.ContainerId, PlannedId = MIN(m.MovementId)
               FROM #M m
               INNER JOIN #Ms x ON x.Id = m.ContainerId
               WHERE m.Status = 1 AND m.MovementId > ISNULL(x.StartedMaxId, 0)
               GROUP BY m.ContainerId) pn ON pn.ContainerId = s.Id
    LEFT JOIN (SELECT m.ContainerId, m.MovementId,
                      Seq = ROW_NUMBER() OVER (PARTITION BY m.ContainerId
                                               ORDER BY m.EndDate DESC, m.CompletedAtUtc DESC, m.MovementId DESC)
               FROM #M m
               INNER JOIN masterdata.MovementTypes t ON t.Id = m.MovementTypeId AND t.Stage = N'Delivery'
               WHERE m.Status = 3) ld ON ld.ContainerId = s.Id AND ld.Seq = 1;

    -- the movements they name, once each, with how many containers each carries
    SELECT v.Id, m.MovementNo, m.Status, m.MovementTypeId, TypeCode = mt.TypeCode, TypeName = mt.TypeName, mt.Stage,
           m.FromPlaceId, FromName = fp.PortName, FromKind = fp.Kind, m.ToPlaceId, ToName = tp.PortName, ToKind = tp.Kind,
           m.PlannedDate, m.StartDate, m.Eta, m.EndDate, m.VehicleOrVessel, m.VoyageNo, CarrierName = cp.PartyName,
           Cnt = (SELECT COUNT(*) FROM logistics.MovementContainers x WHERE x.MovementId = v.Id)
    INTO #Mv
    FROM (SELECT Id = ActiveId FROM #Sh WHERE ActiveId IS NOT NULL
          UNION SELECT PlannedId FROM #Sh WHERE PlannedId IS NOT NULL
          UNION SELECT LatestId FROM #Sh WHERE LatestId IS NOT NULL
          UNION SELECT LastCompletedId FROM #Sh WHERE LastCompletedId IS NOT NULL
          UNION SELECT LastDeliveryId FROM #Sh WHERE LastDeliveryId IS NOT NULL) v
    INNER JOIN logistics.Movements m       ON m.Id = v.Id
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    INNER JOIN masterdata.Ports fp         ON fp.Id = m.FromPlaceId
    INNER JOIN masterdata.Ports tp         ON tp.Id = m.ToPlaceId
    LEFT  JOIN masterdata.Parties cp       ON cp.Id = m.CarrierPartyId;
    CREATE UNIQUE CLUSTERED INDEX IX_Mv ON #Mv (Id);

    -- who received it and its open goods receipt (fn_Container_ReceivedBy, the only test for "offloaded before goods
    -- receipts"), read for the containers that have an open goods receipt or are received: for any other it says nothing
    -- (NULL), and read for 5,000 rows it cost a spool of every container
    SELECT x.Id
    INTO #Rc
    FROM #C x
    WHERE x.Status IN (6, 7)
       OR EXISTS (SELECT 1 FROM purchase.GoodsReceipts g WHERE g.ContainerId = x.Id AND g.Status < 3);

    SELECT x.Id, rb.ReceivedBy, rb.GoodsReceiptId, rb.GoodsReceiptNumber, rb.GoodsReceiptStatus
    INTO #Rb
    FROM #Rc x
    CROSS APPLY logistics.fn_Container_ReceivedBy(x.Id) rb;

    SELECT c.Id, c.ContainerRef, c.ContainerNo, ContainerTypeCode = ct.TypeCode, c.Status, c.BranchId, BranchCode = b.BranchCode,
           c.PurchaseOrderId, PurchaseOrderNumber = mpo.DocumentNumber,
           c.PortOfLoadingId, PortOfLoadingName = pl.PortName, c.PortOfDestinationId, PortOfDestinationName = pd.PortName,
           c.FinalDestinationId, FinalDestinationName = fd.PortName,
           c.VesselName, c.VoyageNo, c.BlNo, c.Eta, c.LastFreeDay, c.OffloadedDate, c.WarehouseId,
           -- fn_Container_ShipState's columns
           sh.MovementCount,
           PlaceId = CASE WHEN lm.Id IS NULL THEN c.PortOfLoadingId ELSE lm.ToPlaceId END,
           PlaceName = CASE WHEN lm.Id IS NULL THEN pl.PortName ELSE lm.ToName END,
           PlaceSince = CASE WHEN lm.Status = 3 THEN lm.EndDate END,
           ActiveMovementId = am.Id, ActiveMovementNo = am.MovementNo, ActiveMovementTypeName = am.TypeName,
           ActiveMovementStage = am.Stage, ActiveMovementFromName = am.FromName, ActiveMovementToName = am.ToName,
           ActiveMovementStartDate = am.StartDate, ActiveMovementEta = am.Eta, ActiveMovementContainerCount = am.Cnt,
           ActiveMovementFromPlaceId = am.FromPlaceId, ActiveMovementToPlaceId = am.ToPlaceId,
           ActiveMovementTypeCode = am.TypeCode, ActiveFromKind = am.FromKind, ActiveToKind = am.ToKind,
           ActiveMovementVehicleOrVessel = am.VehicleOrVessel, ActiveMovementVoyageNo = am.VoyageNo,
           ActiveMovementCarrierName = am.CarrierName,
           PlannedMovementId = np.Id, PlannedMovementNo = np.MovementNo, PlannedMovementTypeName = np.TypeName,
           PlannedMovementStage = np.Stage, PlannedMovementFromName = np.FromName, PlannedMovementToName = np.ToName,
           PlannedMovementDate = np.PlannedDate, PlannedMovementContainerCount = np.Cnt,
           LastMovementId = lc.Id, LastMovementNo = lc.MovementNo, LastMovementEndDate = lc.EndDate,
           LastStage = lc.Stage, LastToPlaceId = lc.ToPlaceId, LastToName = lc.ToName, LastToKind = lc.ToKind,
           rb.ReceivedBy, rb.GoodsReceiptId, rb.GoodsReceiptNumber, rb.GoodsReceiptStatus,
           LastDeliveryMovementId = dl.Id, DeliveredDate = dl.EndDate, DeliveryPlaceId = dl.ToPlaceId,
           DeliveryPlaceName = dl.ToName
    INTO #B
    FROM #Sh sh
    LEFT  JOIN #Rb rb                       ON rb.Id = sh.Id
    INNER JOIN logistics.Containers c       ON c.Id = sh.Id
    INNER JOIN masterdata.ContainerTypes ct ON ct.Id = c.ContainerTypeId
    INNER JOIN masterdata.Branches b        ON b.Id = c.BranchId
    LEFT  JOIN masterdata.Ports pl          ON pl.Id = c.PortOfLoadingId
    LEFT  JOIN masterdata.Ports pd          ON pd.Id = c.PortOfDestinationId
    LEFT  JOIN masterdata.Ports fd          ON fd.Id = c.FinalDestinationId
    LEFT  JOIN purchase.PurchaseDocuments mpo ON mpo.Id = c.PurchaseOrderId
    LEFT  JOIN #Mv lm ON lm.Id = sh.LatestId
    LEFT  JOIN #Mv am ON am.Id = sh.ActiveId
    LEFT  JOIN #Mv np ON np.Id = sh.PlannedId
    LEFT  JOIN #Mv lc ON lc.Id = sh.LastCompletedId
    LEFT  JOIN #Mv dl ON dl.Id = sh.LastDeliveryId;
    CREATE UNIQUE CLUSTERED INDEX IX_B ON #B (Id);

    -- why a planned movement cannot start yet, once per movement (fn_Movement_StartBlock: read through each row's ship
    -- state it cost seconds)
    SELECT p.MovementId, sb.Reason, sb.StartNotBefore
    INTO #Sb
    FROM (SELECT DISTINCT MovementId = PlannedMovementId FROM #B WHERE PlannedMovementId IS NOT NULL) p
    CROSS APPLY logistics.fn_Movement_StartBlock(p.MovementId) sb;

    -- 3. ITS NEXT STEP (fn_Container_NextStepKind) AND ITS COLUMN (fn_Container_BoardPhase), then the place it stands at
    -- (the steps below keep only what they add: the card is put together once, at the end)
    SELECT b.Id, PlannedMovementBlockedReason = sb.Reason, PlannedMovementNotBefore = sb.StartNotBefore,
           NextStepKind = nk.Kind, NextStepBlockedReason = nk.BlockedReason, ph.Phase, ph.PhaseOrder,
           IsLate = CAST(CASE WHEN b.ActiveMovementEta < @Today THEN 1 ELSE 0 END AS BIT),
           IsFreeTimeOver = CAST(CASE WHEN b.Status IN (4, 5) AND b.LastFreeDay IS NOT NULL
                                           AND b.LastFreeDay < ISNULL(b.DeliveredDate, @Today) THEN 1 ELSE 0 END AS BIT),
           -- (a container followed by typed dates - In Transit to Cleared without a leg - has neither leg: at port, its
           -- port of destination; cleared or received by hand, that port, else its final destination - where
           -- usp_Container_RefreshStatus puts it)
           AtPlaceId = CASE ph.Phase WHEN N'AtSupplier' THEN b.PortOfLoadingId
                                     WHEN N'AtPort' THEN COALESCE(b.ActiveMovementToPlaceId, b.LastToPlaceId, b.PortOfDestinationId)
                                     WHEN N'AtBorderCustoms' THEN COALESCE(b.ActiveMovementToPlaceId, b.LastToPlaceId,
                                                                           b.PortOfDestinationId, b.FinalDestinationId)
                                     WHEN N'Delivered' THEN COALESCE(b.DeliveryPlaceId, b.LastToPlaceId,
                                                                     CASE WHEN b.Status BETWEEN 3 AND 5
                                                                          THEN COALESCE(b.PortOfDestinationId, b.FinalDestinationId) END,
                                                                     b.PortOfLoadingId) END,
           AtPlaceName = CASE ph.Phase WHEN N'AtSupplier' THEN b.PortOfLoadingName
                                       WHEN N'AtPort' THEN COALESCE(b.ActiveMovementToName, b.LastToName, b.PortOfDestinationName)
                                       WHEN N'AtBorderCustoms' THEN COALESCE(b.ActiveMovementToName, b.LastToName,
                                                                             b.PortOfDestinationName, b.FinalDestinationName)
                                       WHEN N'Delivered' THEN COALESCE(b.DeliveryPlaceName, b.LastToName,
                                                                       CASE WHEN b.Status BETWEEN 3 AND 5
                                                                            THEN COALESCE(b.PortOfDestinationName, b.FinalDestinationName) END,
                                                                       b.PortOfLoadingName) END,
           -- since when: a stay in progress since its start, else the end of the leg that brought it, the delivery, the receipt
           AtPlaceSince = CASE WHEN ph.Phase IN (N'AtPort', N'AtBorderCustoms') AND b.ActiveMovementId IS NOT NULL THEN b.ActiveMovementStartDate
                               WHEN ph.Phase IN (N'AtPort', N'AtBorderCustoms') THEN b.LastMovementEndDate
                               WHEN ph.Phase = N'Delivered' THEN COALESCE(b.DeliveredDate, b.LastMovementEndDate)
                               WHEN ph.Phase = N'Received' THEN b.OffloadedDate END
    INTO #S
    FROM #B b
    LEFT JOIN #Sb sb ON sb.MovementId = b.PlannedMovementId
    CROSS APPLY logistics.fn_Container_NextStepKind(b.Id, b.Status, b.MovementCount, b.ActiveMovementId, b.PlannedMovementId,
                                                    sb.Reason, b.LastMovementId, b.LastDeliveryMovementId,
                                                    b.GoodsReceiptStatus) nk
    CROSS APPLY logistics.fn_Container_BoardPhase(b.Status, b.GoodsReceiptStatus, b.ActiveMovementStage, b.ActiveMovementTypeCode,
                                                  b.ActiveFromKind, b.ActiveToKind,
                                                  CASE WHEN b.LastMovementId IS NULL THEN NULL ELSE b.LastStage END,
                                                  b.LastToKind) ph
    WHERE ph.Phase IS NOT NULL;
    CREATE UNIQUE CLUSTERED INDEX IX_S ON #S (Id);

    -- the filters that read where it stands (place, late, planned leg)
    IF @PlaceId IS NOT NULL OR @LateOnly = 1 OR @WithPlannedLeg = 1
        DELETE s
        FROM #S s
        INNER JOIN #B b ON b.Id = s.Id
        WHERE (@PlaceId IS NOT NULL AND ISNULL(s.AtPlaceId, 0) <> @PlaceId AND ISNULL(b.ActiveMovementFromPlaceId, 0) <> @PlaceId
               AND ISNULL(b.ActiveMovementToPlaceId, 0) <> @PlaceId)
           OR (@LateOnly = 1 AND s.IsLate = 0)
           OR (@WithPlannedLeg = 1 AND b.PlannedMovementId IS NULL);

    -- the warehouse a received container went into: its posted goods receipt's, else (an offload of before) its own
    SELECT s.Id, ReceivedWarehouseId = w.Id, ReceivedWarehouseName = w.WarehouseName
    INTO #Rw
    FROM #S s
    INNER JOIN #B b ON b.Id = s.Id
    LEFT JOIN purchase.GoodsReceipts g    ON g.Id = b.GoodsReceiptId AND b.GoodsReceiptStatus = 2
    INNER JOIN masterdata.Warehouses w    ON w.Id = COALESCE(g.WarehouseId, b.WarehouseId)
    WHERE s.Phase = N'Received';

    -- 4. THE PROPOSED NEXT LEG (Ship, NextLeg: "Inland transport to Kasumbalesa..."), as usp_Container_Search gives it:
    -- the usual leg from a place once per (place, last stage), not once per row.
    SELECT b.Id AS ContainerId, b.PlaceId, LastStage = CASE WHEN b.MovementCount = 0 THEN NULL ELSE b.LastStage END,
           IsCleared = CAST(CASE WHEN b.Status = 5 THEN 1 ELSE 0 END AS BIT),
           b.PortOfDestinationId, b.FinalDestinationId
    INTO #Leg
    FROM #S s
    INNER JOIN #B b ON b.Id = s.Id
    WHERE s.NextStepKind IN (N'Ship', N'NextLeg');

    -- the history of a (place, none) pair only when a container that never moved has no port of destination: with one,
    -- fn_Container_NextLegProposal proposes Sea freight to it and reads no history
    -- (one statement per pair: the same pairs through one CROSS APPLY took half as long again)
    CREATE TABLE #Hist (PlaceId INT NOT NULL, LastStage NVARCHAR(10) COLLATE DATABASE_DEFAULT NULL, MovementTypeId INT NULL, ToPlaceId INT NULL, Legs INT NULL);
    DECLARE @Pairs TABLE (Seq INT IDENTITY(1, 1) PRIMARY KEY, PlaceId INT NOT NULL, LastStage NVARCHAR(10) NULL);
    INSERT INTO @Pairs (PlaceId, LastStage)
    SELECT DISTINCT PlaceId, LastStage FROM #Leg
    WHERE PlaceId IS NOT NULL AND (LastStage IS NOT NULL OR PortOfDestinationId IS NULL);
    DECLARE @Pair INT = 1, @PairPlaceId INT, @PairStage NVARCHAR(10);
    WHILE EXISTS (SELECT 1 FROM @Pairs WHERE Seq = @Pair)
    BEGIN
        SELECT @PairPlaceId = PlaceId, @PairStage = LastStage FROM @Pairs WHERE Seq = @Pair;
        INSERT INTO #Hist (PlaceId, LastStage, MovementTypeId, ToPlaceId, Legs)
        SELECT @PairPlaceId, @PairStage, h.MovementTypeId, h.ToPlaceId, h.Legs
        FROM logistics.fn_Movement_NextLegHistory(@PairPlaceId, @PairStage) h;
        SET @Pair += 1;
    END

    -- fn_Container_NextLegProposal reads of the container only its port of destination and final destination: the
    -- proposal is worked out once per distinct (place, last stage, cleared, those two ports), for one of its containers
    SELECT d.PlaceId, d.LastStage, d.IsCleared, d.PortOfDestinationId, d.FinalDestinationId,
           pr.TypeId, pr.TypeCode, pr.TypeName, pr.Stage, pr.FromPlaceId, pr.FromName, pr.ToPlaceId, pr.ToName,
           pr.Source, pr.Legs, pr.IsStay
    INTO #Prop
    FROM (SELECT l.PlaceId, l.LastStage, l.IsCleared, l.PortOfDestinationId, l.FinalDestinationId, AnyContainerId = MIN(l.ContainerId)
          FROM #Leg l
          GROUP BY l.PlaceId, l.LastStage, l.IsCleared, l.PortOfDestinationId, l.FinalDestinationId) d
    LEFT JOIN #Hist h ON h.PlaceId = d.PlaceId AND ISNULL(h.LastStage, N'') = ISNULL(d.LastStage, N'')
    OUTER APPLY logistics.fn_Container_NextLegProposal(d.AnyContainerId, d.PlaceId, d.LastStage, d.IsCleared,
                                                       h.MovementTypeId, h.ToPlaceId, h.Legs) pr;

    -- 5. THE ORDERS, SUPPLIERS AND ITEMS of each card (usp_Container_Search's: the first order and supplier + how many more)
    SELECT cl.ContainerId, cl.PurchaseOrderId, cl.ItemId, Qty = SUM(cl.QuantityBase)
    INTO #L1
    FROM #S s
    INNER JOIN logistics.ContainerLines cl ON cl.ContainerId = s.Id
    GROUP BY cl.ContainerId, cl.PurchaseOrderId, cl.ItemId;

    SELECT o.ContainerId, OrderCount = COUNT(*), FirstOrder = MIN(d.DocumentNumber),
           SupplierCount = COUNT(DISTINCT d.SupplierId), FirstSupplier = MIN(sp.PartyName)
    INTO #Lo
    FROM (SELECT DISTINCT ContainerId, PurchaseOrderId FROM #L1) o
    INNER JOIN purchase.PurchaseDocuments d ON d.Id = o.PurchaseOrderId
    INNER JOIN masterdata.Parties sp        ON sp.Id = d.SupplierId
    GROUP BY o.ContainerId;

    SELECT x.ContainerId, ItemCount = COUNT(*), Qty = SUM(x.Qty), FirstItemCode = MIN(i.ItemCode), FirstItemName = MIN(i.ItemName)
    INTO #Li
    FROM (SELECT ContainerId, ItemId, Qty = SUM(Qty) FROM #L1 GROUP BY ContainerId, ItemId) x
    INNER JOIN inventory.Items i ON i.Id = x.ItemId
    GROUP BY x.ContainerId;

    -- 6. THE CARDS, in the order of the board: column, group, ref
    SELECT b.Id, b.ContainerRef, b.ContainerNo, b.ContainerTypeCode, b.Status, b.BranchId, b.BranchCode,
           b.PurchaseOrderId, b.PurchaseOrderNumber,
           OrderCount = ISNULL(lo.OrderCount, 0),
           OrderNumbers = CASE WHEN ISNULL(lo.OrderCount, 0) = 0 THEN NULL
                               WHEN lo.OrderCount = 1 THEN lo.FirstOrder
                               ELSE lo.FirstOrder + N' +' + CAST(lo.OrderCount - 1 AS NVARCHAR(10)) END,
           SupplierCount = ISNULL(lo.SupplierCount, 0),
           SupplierNames = CASE WHEN ISNULL(lo.SupplierCount, 0) = 0 THEN NULL
                                WHEN lo.SupplierCount = 1 THEN lo.FirstSupplier
                                ELSE lo.FirstSupplier + N' +' + CAST(lo.SupplierCount - 1 AS NVARCHAR(10)) END,
           ItemCount = ISNULL(li.ItemCount, 0),
           ItemCode = CASE WHEN li.ItemCount = 1 THEN li.FirstItemCode END,
           ItemName = CASE WHEN li.ItemCount = 1 THEN li.FirstItemName END,
           TotalQtyBase = ISNULL(li.Qty, 0),
           b.PortOfLoadingId, b.PortOfLoadingName, b.PortOfDestinationName, b.FinalDestinationName,
           b.VesselName, b.VoyageNo, b.BlNo, b.Eta, b.LastFreeDay, b.OffloadedDate,
           -- the board
           s.Phase, s.PhaseOrder, gk.GroupKey, gk.GroupLabel,
           GroupOrder = DENSE_RANK() OVER (PARTITION BY s.Phase ORDER BY gk.SortNone, gk.SortDate, gk.GroupLabel, gk.GroupKey),
           AtPlaceId = s.AtPlaceId, AtPlaceName = COALESCE(s.AtPlaceName, rw.ReceivedWarehouseName), s.AtPlaceSince,
           s.IsLate, s.IsFreeTimeOver, rw.ReceivedWarehouseId, rw.ReceivedWarehouseName,
           -- followed by typed dates: no leg started or completed, above Confirmed by the dates typed on it (NULL otherwise,
           -- so the board's answer leaves it out)
           FollowedByTypedDates = CAST(CASE WHEN b.ActiveMovementId IS NULL AND b.LastMovementId IS NULL AND b.Status BETWEEN 3 AND 5
                                            THEN 1 END AS BIT),
           -- the shipment (fn_Container_ShipState), the columns of usp_Container_Search
           b.MovementCount, b.PlaceId, b.PlaceName, b.PlaceSince,
           b.ActiveMovementId, b.ActiveMovementNo, b.ActiveMovementTypeName, b.ActiveMovementStage,
           b.ActiveMovementFromPlaceId, b.ActiveMovementFromName, b.ActiveMovementToPlaceId, b.ActiveMovementToName,
           b.ActiveMovementStartDate, b.ActiveMovementEta, b.ActiveMovementContainerCount,
           b.ActiveMovementVehicleOrVessel, b.ActiveMovementVoyageNo, b.ActiveMovementCarrierName,
           b.PlannedMovementId, b.PlannedMovementNo, b.PlannedMovementTypeName, b.PlannedMovementStage,
           b.PlannedMovementFromName, b.PlannedMovementToName, b.PlannedMovementDate, b.PlannedMovementContainerCount,
           s.PlannedMovementBlockedReason, s.PlannedMovementNotBefore,
           b.LastMovementId, b.LastMovementNo, b.LastMovementEndDate,
           -- the movement in progress, else the last completed one (the list's Movement column)
           CurrentMovementId = COALESCE(b.ActiveMovementId, b.LastMovementId),
           CurrentMovementNo = COALESCE(b.ActiveMovementNo, b.LastMovementNo),
           CurrentMovementStatus = CAST(CASE WHEN b.ActiveMovementId IS NOT NULL THEN 2 WHEN b.LastMovementId IS NOT NULL THEN 3 END AS TINYINT),
           -- its next step and the proposed new leg (fn_Container_NextStepKind, fn_Container_NextLegProposal)
           s.NextStepKind, s.NextStepBlockedReason,
           ProposedTypeId = pr.TypeId, ProposedTypeCode = pr.TypeCode, ProposedTypeName = pr.TypeName, ProposedStage = pr.Stage,
           ProposedFromPlaceId = pr.FromPlaceId, ProposedFromName = pr.FromName,
           ProposedToPlaceId = pr.ToPlaceId, ProposedToName = pr.ToName,
           ProposalSource = pr.Source, ProposalLegs = pr.Legs, ProposedIsStay = pr.IsStay,
           -- goods receipts
           b.ReceivedBy, b.GoodsReceiptId, b.GoodsReceiptNumber, b.GoodsReceiptStatus, b.DeliveredDate, b.DeliveryPlaceName
    FROM #S s
    INNER JOIN #B b ON b.Id = s.Id
    LEFT JOIN #Rw rw ON rw.Id = s.Id
    LEFT JOIN #Leg l ON l.ContainerId = s.Id
    LEFT JOIN #Prop pr ON pr.PlaceId = l.PlaceId AND ISNULL(pr.LastStage, N'') = ISNULL(l.LastStage, N'')
                      AND pr.IsCleared = l.IsCleared AND ISNULL(pr.PortOfDestinationId, 0) = ISNULL(l.PortOfDestinationId, 0)
                      AND ISNULL(pr.FinalDestinationId, 0) = ISNULL(l.FinalDestinationId, 0)
    LEFT JOIN #Lo lo ON lo.ContainerId = s.Id
    LEFT JOIN #Li li ON li.ContainerId = s.Id
    -- the group: its key, its words, and what orders the groups of a column
    CROSS APPLY (SELECT GroupKey = CASE s.Phase
                            -- a container followed by typed dates is at sea on no movement: a group of its own
                            WHEN N'AtSea' THEN ISNULL(N'MOV|' + CAST(b.ActiveMovementId AS NVARCHAR(12)), N'TYPED')
                            WHEN N'OnTheRoad' THEN N'LEG|' + CAST(b.ActiveMovementFromPlaceId AS NVARCHAR(12)) + N'|'
                                                   + CAST(b.ActiveMovementToPlaceId AS NVARCHAR(12))
                            WHEN N'Received' THEN N'WH|' + ISNULL(CAST(rw.ReceivedWarehouseId AS NVARCHAR(12)), N'0')
                            ELSE N'AT|' + ISNULL(CAST(s.AtPlaceId AS NVARCHAR(12)), N'0') END,
                        GroupLabel = CAST(CASE s.Phase
                            WHEN N'AtSea' THEN CASE WHEN b.ActiveMovementId IS NULL THEN N'Followed by typed dates' ELSE
                                     CONCAT_WS(N' ' + NCHAR(183) + N' ', b.ActiveMovementNo,
                                     NULLIF(CONCAT_WS(N' ', b.ActiveMovementVehicleOrVessel,
                                                      CASE WHEN b.ActiveMovementVoyageNo IS NULL THEN NULL
                                                           WHEN b.ActiveMovementVoyageNo LIKE N'V%' THEN b.ActiveMovementVoyageNo
                                                           ELSE N'V.' + b.ActiveMovementVoyageNo END), N''),
                                     b.ActiveMovementFromName + N' ' + NCHAR(8594) + N' ' + b.ActiveMovementToName,
                                     N'ETA ' + CONVERT(NVARCHAR(10), b.ActiveMovementEta, 103)) END
                            -- a stay on the road (a border crossing) has no From -> To: "Border crossing at Kasumbalesa"
                            WHEN N'OnTheRoad' THEN CASE WHEN b.ActiveMovementFromPlaceId = b.ActiveMovementToPlaceId
                                                        THEN b.ActiveMovementTypeName + N' at ' + b.ActiveMovementFromName
                                                        ELSE b.ActiveMovementFromName + N' ' + NCHAR(8594) + N' ' + b.ActiveMovementToName END
                            WHEN N'AtSupplier' THEN ISNULL(s.AtPlaceName, N'No port of loading')
                            WHEN N'Received' THEN ISNULL(rw.ReceivedWarehouseName, N'No warehouse')
                            ELSE ISNULL(s.AtPlaceName, N'Place unknown') END AS NVARCHAR(300)),
                        SortNone = CASE WHEN s.Phase = N'Received' AND rw.ReceivedWarehouseId IS NULL THEN 1
                                        WHEN s.Phase NOT IN (N'AtSea', N'OnTheRoad', N'Received') AND s.AtPlaceId IS NULL THEN 1
                                        WHEN s.Phase = N'AtSea' AND b.ActiveMovementId IS NULL THEN 1   -- typed dates, after the ships
                                        ELSE 0 END,
                        SortDate = CASE WHEN s.Phase = N'AtSea' THEN ISNULL(b.ActiveMovementEta, '99991231') END) gk
    ORDER BY s.PhaseOrder, GroupOrder, LEN(b.ContainerRef), b.ContainerRef, b.Id;

    -- 7. THE COLUMNS, left to right: their containers and pieces (Received only with the switch)
    SELECT col.Phase, col.Title, col.PhaseOrder, [Count] = ISNULL(n.Containers, 0), Pieces = ISNULL(n.Pieces, 0)
    FROM (VALUES (N'AtSupplier', N'At supplier', 1), (N'AtSea', N'At sea', 2), (N'AtPort', N'At port', 3),
                 (N'OnTheRoad', N'On the road', 4), (N'AtBorderCustoms', N'At border / customs', 5),
                 (N'Delivered', N'Delivered, to receive', 6),
                 (N'Received', N'Received (' + CAST(@ReceivedDays AS NVARCHAR(10)) + N' days)', 7)) col (Phase, Title, PhaseOrder)
    LEFT JOIN (SELECT s.Phase, Containers = COUNT(*), Pieces = SUM(CAST(ISNULL(li.Qty, 0) AS BIGINT))
               FROM #S s
               LEFT JOIN #Li li ON li.ContainerId = s.Id
               GROUP BY s.Phase) n
           ON n.Phase = col.Phase
    WHERE col.Phase <> N'Received' OR @ShowReceived = 1
    ORDER BY col.PhaseOrder;
END
GO

-- Re-created (114) from the body of script 91: COLLATE DATABASE_DEFAULT on the text columns of its #tables (1).
CREATE OR ALTER PROCEDURE inventory.usp_StockLevel_CompanySearch
    @Search          NVARCHAR(100) = NULL,
    @BranchId        INT           = NULL,
    @ItemFamilyId    INT           = NULL,
    @BrandId         INT           = NULL,
    @Status          NVARCHAR(20)  = NULL,
    @ActiveItemsOnly BIT           = 1
AS
BEGIN
    SET NOCOUNT ON;

    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @Status = NULLIF(LTRIM(RTRIM(@Status)), N'');
    SET @ActiveItemsOnly = ISNULL(@ActiveItemsOnly, 1);

    IF @Status IS NOT NULL AND @Status NOT IN (N'BelowMin', N'AboveMax', N'Ok')
        THROW 56000, 'Unknown status: choose Below Min, Above Max or OK.', 1;

    -- (91) THE DASHBOARD'S OWN FORMULA (reporting.usp_Dashboard_Summary, script 72): the stock of EVERY warehouse of the
    --      branch - inactive ones and its On the way warehouse included - or of the company, against the item's company
    --      Minimum Quantity. Change one, change both (test f compares them).
    DECLARE @Stock TABLE (ItemId INT NOT NULL PRIMARY KEY, OnHand INT NOT NULL);
    INSERT INTO @Stock (ItemId, OnHand)
    SELECT m.ItemId, SUM(m.QuantityBase)
    FROM inventory.StockMovements m
    INNER JOIN masterdata.Warehouses w ON w.Id = m.WarehouseId
    WHERE @BranchId IS NULL OR w.BranchId = @BranchId
    GROUP BY m.ItemId;

    CREATE TABLE #co
    (
        ItemId INT NOT NULL PRIMARY KEY, OnHandBase INT NOT NULL, Status NVARCHAR(10) COLLATE DATABASE_DEFAULT NOT NULL, MissingBase INT NOT NULL
    );
    INSERT INTO #co (ItemId, OnHandBase, Status, MissingBase)
    SELECT i.Id, s.OnHand,
           CASE WHEN i.MinQuantity > 0 AND s.OnHand < i.MinQuantity               THEN N'BelowMin'
                WHEN i.MaxQuantity IS NOT NULL AND s.OnHand > i.MaxQuantity       THEN N'AboveMax'
                ELSE N'Ok' END,
           CASE WHEN i.MinQuantity > 0 AND s.OnHand < i.MinQuantity THEN i.MinQuantity - s.OnHand ELSE 0 END
    FROM inventory.Items i
    CROSS APPLY (SELECT OnHand = ISNULL((SELECT st.OnHand FROM @Stock st WHERE st.ItemId = i.Id), 0)) s
    WHERE (i.MinQuantity > 0 OR i.MaxQuantity IS NOT NULL)
      AND (@ActiveItemsOnly = 0 OR i.IsActive = 1)
      AND (@BrandId IS NULL OR i.BrandId = @BrandId)
      AND (@ItemFamilyId IS NULL OR i.ItemFamilyId IN (SELECT f.Id FROM masterdata.fn_ItemFamily_Subtree(@ItemFamilyId) f))
      AND (@Search IS NULL OR i.ItemCode LIKE N'%' + @Search + N'%' OR i.ItemName LIKE N'%' + @Search + N'%'
           OR EXISTS (SELECT 1 FROM inventory.ItemUnits u WHERE u.ItemId = i.Id AND u.Barcode = @Search));

    -- 1: the items
    SELECT c.ItemId, i.ItemCode, i.ItemName, ItemIsActive = i.IsActive, ItemFamilyName = f.FamilyName, b.BrandName,
           c.OnHandBase, i.MinQuantity, i.MaxQuantity, c.Status, c.MissingBase,
           WarehouseLevelCount = (SELECT COUNT(*)
                                  FROM inventory.ItemWarehouseLevels lv
                                  INNER JOIN masterdata.Warehouses w ON w.Id = lv.WarehouseId AND w.IsActive = 1
                                  WHERE lv.ItemId = c.ItemId AND (@BranchId IS NULL OR w.BranchId = @BranchId))
    FROM #co c
    INNER JOIN inventory.Items i         ON i.Id = c.ItemId
    LEFT  JOIN masterdata.ItemFamilies f ON f.Id = i.ItemFamilyId
    LEFT  JOIN masterdata.Brands b       ON b.Id = i.BrandId
    WHERE @Status IS NULL OR c.Status = @Status
    ORDER BY CASE WHEN c.Status = N'BelowMin' THEN 0 ELSE 1 END, c.MissingBase DESC, i.ItemCode;

    -- 2: the totals of the scope
    SELECT Items = COUNT(*), BelowMin = ISNULL(SUM(CASE WHEN c.Status = N'BelowMin' THEN 1 ELSE 0 END), 0)
    FROM #co c;

    -- 3: the scope
    SELECT BranchId = b.Id, BranchName = b.BranchName
    FROM (SELECT Id = @BranchId) s
    LEFT JOIN masterdata.Branches b ON b.Id = s.Id;
END
GO

-- Re-created (114) from the body of script 91: COLLATE DATABASE_DEFAULT on the text columns of its #tables (1).
CREATE OR ALTER PROCEDURE inventory.usp_StockLevel_Search
    @Search                    NVARCHAR(100) = NULL,
    @BranchId                  INT           = NULL,
    @WarehouseId               INT           = NULL,
    @ItemFamilyId              INT           = NULL,
    @BrandId                   INT           = NULL,
    @ItemId                    INT           = NULL,
    @Status                    NVARCHAR(20)  = NULL,
    @ActiveItemsOnly           BIT           = 1,
    @IncludeInactiveWarehouses BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @Status = NULLIF(LTRIM(RTRIM(@Status)), N'');
    SET @ActiveItemsOnly = ISNULL(@ActiveItemsOnly, 1);
    SET @IncludeInactiveWarehouses = ISNULL(@IncludeInactiveWarehouses, 0);

    IF @Status IS NOT NULL AND @Status NOT IN (N'BelowMin', N'Covered', N'AboveMax', N'Ok', N'NoLevel')
        THROW 56000, 'Unknown status: choose Below Min, Below Min covered, Above Max, OK or Without a level.', 1;

    -- The warehouses of the scope
    CREATE TABLE #wh (Id INT NOT NULL PRIMARY KEY);
    DECLARE @Under TABLE (Id INT NOT NULL PRIMARY KEY);
    IF @WarehouseId IS NOT NULL
        INSERT INTO @Under (Id) SELECT s.Id FROM masterdata.fn_Warehouse_Subtree(@WarehouseId) s;

    INSERT INTO #wh (Id)
    SELECT w.Id
    FROM masterdata.Warehouses w
    WHERE w.IsTransit = 0
      AND masterdata.fn_Warehouse_IsLeaf(w.Id) = 1
      AND (w.IsActive = 1 OR @IncludeInactiveWarehouses = 1)
      AND (@BranchId IS NULL OR w.BranchId = @BranchId)
      AND (@WarehouseId IS NULL OR w.Id IN (SELECT u.Id FROM @Under u));

    -- The items of the scope
    CREATE TABLE #it (Id INT NOT NULL PRIMARY KEY);
    INSERT INTO #it (Id)
    SELECT i.Id
    FROM inventory.Items i
    WHERE (@ActiveItemsOnly = 0 OR i.IsActive = 1)
      AND (@ItemId IS NULL OR i.Id = @ItemId)
      AND (@BrandId IS NULL OR i.BrandId = @BrandId)
      AND (@ItemFamilyId IS NULL OR i.ItemFamilyId IN (SELECT f.Id FROM masterdata.fn_ItemFamily_Subtree(@ItemFamilyId) f))
      AND (@Search IS NULL OR i.ItemCode LIKE N'%' + @Search + N'%' OR i.ItemName LIKE N'%' + @Search + N'%'
           OR EXISTS (SELECT 1 FROM inventory.ItemUnits u WHERE u.ItemId = i.Id AND u.Barcode = @Search));

    -- The pairs of the scope: every level, and (Without a level) the pairs without one that hold stock (a ledger balance
    -- other than 0) or appear on a released transfer order (as To with goods on the way or to dispatch, as From with
    -- goods to dispatch)
    CREATE TABLE #pr (ItemId INT NOT NULL, WarehouseId INT NOT NULL, PRIMARY KEY (ItemId, WarehouseId));
    INSERT INTO #pr (ItemId, WarehouseId)
    SELECT lv.ItemId, lv.WarehouseId
    FROM inventory.ItemWarehouseLevels lv
    INNER JOIN #wh w ON w.Id = lv.WarehouseId
    INNER JOIN #it i ON i.Id = lv.ItemId;

    -- What released transfer orders bring to and take from the scope's warehouses, every pair at once
    -- (fn_TransferPositions: fn_TransferPosition's sums, set-based - read once per pair they cost the item's whole
    -- transfer history each time)
    CREATE TABLE #tp
    (
        ItemId INT NOT NULL, WarehouseId INT NOT NULL, InOnTheWayBase INT NOT NULL, InToDispatchBase INT NOT NULL,
        OutToDispatchBase INT NOT NULL, PRIMARY KEY (ItemId, WarehouseId)
    );
    INSERT INTO #tp (ItemId, WarehouseId, InOnTheWayBase, InToDispatchBase, OutToDispatchBase)
    SELECT tp.ItemId, tp.WarehouseId, tp.InOnTheWayBase, tp.InToDispatchBase, tp.OutToDispatchBase
    FROM inventory.fn_TransferPositions(NULL) tp
    INNER JOIN #wh w ON w.Id = tp.WarehouseId
    INNER JOIN #it i ON i.Id = tp.ItemId;

    IF @Status = N'NoLevel'
        INSERT INTO #pr (ItemId, WarehouseId)
        SELECT x.ItemId, x.WarehouseId
        FROM
        (
            SELECT m.ItemId, m.WarehouseId
            FROM inventory.StockMovements m
            INNER JOIN #wh w ON w.Id = m.WarehouseId
            INNER JOIN #it i ON i.Id = m.ItemId
            GROUP BY m.ItemId, m.WarehouseId
            HAVING SUM(m.QuantityBase) <> 0
            UNION
            SELECT tp.ItemId, tp.WarehouseId
            FROM #tp tp
            WHERE tp.InOnTheWayBase + tp.InToDispatchBase > 0 OR tp.OutToDispatchBase > 0
        ) x
        WHERE NOT EXISTS (SELECT 1 FROM inventory.ItemWarehouseLevels lv WHERE lv.ItemId = x.ItemId AND lv.WarehouseId = x.WarehouseId);

    -- Where each pair stands, worked out once for every pair: the ledger's on hand, what released transfer orders bring
    -- and take (#tp), the level, and fn_StockLevelState's Projected and status (M6: the formula of fn_StockPosition)
    CREATE TABLE #pos
    (
        ItemId INT NOT NULL, WarehouseId INT NOT NULL, HasLevel BIT NOT NULL, MinQuantityBase INT NULL, MaxQuantityBase INT NULL,
        OnHandBase INT NOT NULL, InOnTheWayBase INT NOT NULL, InToDispatchBase INT NOT NULL, OutToDispatchBase INT NOT NULL,
        ProjectedBase INT NOT NULL, ToReachMaxBase INT NOT NULL, Status NVARCHAR(10) COLLATE DATABASE_DEFAULT NOT NULL,
        PRIMARY KEY (ItemId, WarehouseId)
    );

    INSERT INTO #pos (ItemId, WarehouseId, HasLevel, MinQuantityBase, MaxQuantityBase, OnHandBase, InOnTheWayBase,
                      InToDispatchBase, OutToDispatchBase, ProjectedBase, ToReachMaxBase, Status)
    SELECT pr.ItemId, pr.WarehouseId, CAST(CASE WHEN lv.ItemId IS NULL THEN 0 ELSE 1 END AS BIT), lv.MinQuantityBase, lv.MaxQuantityBase,
           q.OnHandBase, q.InOnTheWayBase, q.InToDispatchBase, q.OutToDispatchBase, st.ProjectedBase, st.ToReachMaxBase, st.Status
    FROM #pr pr
    LEFT JOIN inventory.ItemWarehouseLevels lv ON lv.ItemId = pr.ItemId AND lv.WarehouseId = pr.WarehouseId
    LEFT JOIN #tp tp ON tp.ItemId = pr.ItemId AND tp.WarehouseId = pr.WarehouseId
    LEFT JOIN (SELECT m.ItemId, m.WarehouseId, Qty = SUM(m.QuantityBase)
               FROM inventory.StockMovements m
               INNER JOIN #pr x ON x.ItemId = m.ItemId AND x.WarehouseId = m.WarehouseId
               GROUP BY m.ItemId, m.WarehouseId) oh ON oh.ItemId = pr.ItemId AND oh.WarehouseId = pr.WarehouseId
    CROSS APPLY (SELECT OnHandBase = ISNULL(oh.Qty, 0), InOnTheWayBase = ISNULL(tp.InOnTheWayBase, 0),
                        InToDispatchBase = ISNULL(tp.InToDispatchBase, 0), OutToDispatchBase = ISNULL(tp.OutToDispatchBase, 0)) q
    CROSS APPLY inventory.fn_StockLevelState(q.OnHandBase, q.InOnTheWayBase, q.InToDispatchBase, q.OutToDispatchBase,
                                             lv.MinQuantityBase, lv.MaxQuantityBase) st;

    -- 1: the rows
    SELECT p.ItemId, i.ItemCode, i.ItemName, ItemIsActive = i.IsActive, ItemFamilyName = f.FamilyName, b.BrandName,
           p.WarehouseId, w.WarehouseCode, w.WarehouseName, WarehouseIsActive = w.IsActive,
           w.BranchId, br.BranchCode, br.BranchName,
           p.HasLevel, p.MinQuantityBase, p.MaxQuantityBase,
           p.OnHandBase, p.InOnTheWayBase, p.InToDispatchBase, p.OutToDispatchBase, p.ProjectedBase, p.ToReachMaxBase, p.Status,
           lv.UpdatedAtUtc, UpdatedByName = u.FullName, RowVersion = CAST(lv.RowVersion AS BINARY(8))
    FROM #pos p
    INNER JOIN inventory.Items i            ON i.Id = p.ItemId
    INNER JOIN masterdata.Warehouses w      ON w.Id = p.WarehouseId
    INNER JOIN masterdata.Branches br       ON br.Id = w.BranchId
    LEFT  JOIN masterdata.ItemFamilies f    ON f.Id = i.ItemFamilyId
    LEFT  JOIN masterdata.Brands b          ON b.Id = i.BrandId
    LEFT  JOIN inventory.ItemWarehouseLevels lv ON lv.ItemId = p.ItemId AND lv.WarehouseId = p.WarehouseId
    LEFT  JOIN security.Users u             ON u.Id = lv.UpdatedBy
    WHERE @Status IS NULL OR p.Status = @Status
    ORDER BY CASE p.Status WHEN N'BelowMin' THEN 1 WHEN N'Covered' THEN 2 WHEN N'AboveMax' THEN 3 WHEN N'Ok' THEN 4 ELSE 5 END,
             i.ItemCode, w.WarehouseCode;

    -- 2: the scope's totals (levels only, the status filter ignored)
    SELECT Levels   = COUNT(*),
           BelowMin = ISNULL(SUM(CASE WHEN p.Status = N'BelowMin' THEN 1 ELSE 0 END), 0),
           Covered  = ISNULL(SUM(CASE WHEN p.Status = N'Covered'  THEN 1 ELSE 0 END), 0),
           AboveMax = ISNULL(SUM(CASE WHEN p.Status = N'AboveMax' THEN 1 ELSE 0 END), 0),
           Ok       = ISNULL(SUM(CASE WHEN p.Status = N'Ok'       THEN 1 ELSE 0 END), 0)
    FROM #pos p
    WHERE p.HasLevel = 1;
END
GO

-- Re-created (114) from the body of script 92: COLLATE DATABASE_DEFAULT on the text columns of its #tables (4).
CREATE OR ALTER PROCEDURE inventory.usp_ItemWarehouseLevel_Import
    @Rows     inventory.tvp_ItemWarehouseLevelImport READONLY,
    @FileName NVARCHAR(260) = NULL,
    @UserId   INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @FileName = NULLIF(LTRIM(RTRIM(@FileName)), N'');

    CREATE TABLE #j
    (
        RowNumber INT NOT NULL PRIMARY KEY, Status NVARCHAR(10) COLLATE DATABASE_DEFAULT NOT NULL, Action NVARCHAR(10) COLLATE DATABASE_DEFAULT NOT NULL, Message NVARCHAR(500) COLLATE DATABASE_DEFAULT NULL,
        ItemId INT NULL, WarehouseId INT NULL, MinQuantityBase INT NULL, MaxQuantityBase INT NULL, Outcome NVARCHAR(10) COLLATE DATABASE_DEFAULT NULL
    );
    CREATE TABLE #cur
    (
        ItemId INT NOT NULL, WarehouseId INT NOT NULL, MinQuantityBase INT NOT NULL, MaxQuantityBase INT NULL,
        PRIMARY KEY (ItemId, WarehouseId)
    );

    DECLARE @Added INT, @Changed INT, @Removed INT, @Unchanged INT, @Skipped INT, @Message NVARCHAR(400), @Done NVARCHAR(200), @Left NVARCHAR(200);

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO #j (RowNumber, Status, Action, Message, ItemId, WarehouseId, MinQuantityBase, MaxQuantityBase)
        SELECT j.RowNumber, j.Status, j.Action, j.Message, j.ItemId, j.WarehouseId, j.MinQuantityBase, j.MaxQuantityBase
        FROM inventory.fn_ItemWarehouseLevel_ImportJudge(@Rows) j;

        -- (92) the rows a restricted user may not import: Error, with the sentence (one call per warehouse)
        IF security.fn_User_IsUnrestricted(@UserId) = 0
        BEGIN
            DECLARE @Refused TABLE (WarehouseId INT NOT NULL PRIMARY KEY, Message NVARCHAR(400) NULL);
            INSERT INTO @Refused (WarehouseId, Message)
            SELECT d.WarehouseId, security.fn_User_WarehouseRefusal(@UserId, CAST(d.WarehouseId AS NVARCHAR(12)))
            FROM (SELECT DISTINCT WarehouseId FROM #j WHERE Status IN (N'Valid', N'Warning') AND WarehouseId IS NOT NULL) d;
            UPDATE j SET Status = N'Error', Action = N'None', Message = r.Message
            FROM #j j INNER JOIN @Refused r ON r.WarehouseId = j.WarehouseId
            WHERE j.Status IN (N'Valid', N'Warning') AND r.Message IS NOT NULL;
        END

        INSERT INTO #cur (ItemId, WarehouseId, MinQuantityBase, MaxQuantityBase)
        SELECT lv.ItemId, lv.WarehouseId, lv.MinQuantityBase, lv.MaxQuantityBase
        FROM inventory.ItemWarehouseLevels lv WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN #j j ON j.ItemId = lv.ItemId AND j.WarehouseId = lv.WarehouseId
        WHERE j.Status IN (N'Valid', N'Warning') AND j.Action IN (N'Set', N'Remove');

        UPDATE j
        SET Outcome = CASE WHEN j.Status = N'Error'                                   THEN N'Skipped'
                           WHEN j.Status NOT IN (N'Valid', N'Warning')                THEN N'Unchanged'
                           WHEN j.Action = N'Set' AND c.ItemId IS NULL                THEN N'Added'
                           WHEN j.Action = N'Set' AND (c.MinQuantityBase <> j.MinQuantityBase
                                                      OR ISNULL(c.MaxQuantityBase, -1) <> ISNULL(j.MaxQuantityBase, -1)) THEN N'Changed'
                           WHEN j.Action = N'Remove' AND c.ItemId IS NOT NULL         THEN N'Removed'
                           ELSE N'Unchanged' END
        FROM #j j
        LEFT JOIN #cur c ON c.ItemId = j.ItemId AND c.WarehouseId = j.WarehouseId;

        INSERT INTO inventory.ItemWarehouseLevelAudit (ItemId, WarehouseId, Action, OldMinBase, OldMaxBase, NewMinBase, NewMaxBase, Source, FileName, UserId)
        SELECT j.ItemId, j.WarehouseId, j.Outcome, c.MinQuantityBase, c.MaxQuantityBase,
               CASE WHEN j.Outcome = N'Removed' THEN NULL ELSE j.MinQuantityBase END,
               CASE WHEN j.Outcome = N'Removed' THEN NULL ELSE j.MaxQuantityBase END,
               N'Import', @FileName, @UserId
        FROM #j j
        LEFT JOIN #cur c ON c.ItemId = j.ItemId AND c.WarehouseId = j.WarehouseId
        WHERE j.Outcome IN (N'Added', N'Changed', N'Removed')
        ORDER BY j.RowNumber;

        MERGE inventory.ItemWarehouseLevels WITH (HOLDLOCK) AS t
        USING (SELECT j.ItemId, j.WarehouseId, j.MinQuantityBase, j.MaxQuantityBase FROM #j j WHERE j.Outcome IN (N'Added', N'Changed')) AS s
        ON t.ItemId = s.ItemId AND t.WarehouseId = s.WarehouseId
        WHEN MATCHED THEN
            UPDATE SET MinQuantityBase = s.MinQuantityBase, MaxQuantityBase = s.MaxQuantityBase,
                       UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (ItemId, WarehouseId, MinQuantityBase, MaxQuantityBase, CreatedBy, UpdatedBy)
            VALUES (s.ItemId, s.WarehouseId, s.MinQuantityBase, s.MaxQuantityBase, @UserId, @UserId);

        DELETE lv
        FROM inventory.ItemWarehouseLevels lv
        INNER JOIN #j j ON j.ItemId = lv.ItemId AND j.WarehouseId = lv.WarehouseId
        WHERE j.Outcome = N'Removed';

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT @Added     = ISNULL(SUM(CASE WHEN Outcome = N'Added'     THEN 1 ELSE 0 END), 0),
           @Changed   = ISNULL(SUM(CASE WHEN Outcome = N'Changed'   THEN 1 ELSE 0 END), 0),
           @Removed   = ISNULL(SUM(CASE WHEN Outcome = N'Removed'   THEN 1 ELSE 0 END), 0),
           @Unchanged = ISNULL(SUM(CASE WHEN Outcome = N'Unchanged' THEN 1 ELSE 0 END), 0),
           @Skipped   = ISNULL(SUM(CASE WHEN Outcome = N'Skipped'   THEN 1 ELSE 0 END), 0)
    FROM #j;

    -- "Stock levels imported: {a} added, {c} changed, {r} removed; {u} rows without a change and {e} rows with errors
    -- skipped." A part at 0 is left out; nothing imported: "Nothing was imported: ..."
    SET @Done = STUFF(  CASE WHEN @Added   > 0 THEN N', ' + CAST(@Added   AS NVARCHAR(10)) + N' added'   ELSE N'' END
                      + CASE WHEN @Changed > 0 THEN N', ' + CAST(@Changed AS NVARCHAR(10)) + N' changed' ELSE N'' END
                      + CASE WHEN @Removed > 0 THEN N', ' + CAST(@Removed AS NVARCHAR(10)) + N' removed' ELSE N'' END, 1, 2, N'');
    SET @Left = STUFF(  CASE WHEN @Unchanged > 0 THEN N' and ' + CAST(@Unchanged AS NVARCHAR(10))
                                                      + CASE WHEN @Unchanged = 1 THEN N' row' ELSE N' rows' END + N' without a change' ELSE N'' END
                      + CASE WHEN @Skipped   > 0 THEN N' and ' + CAST(@Skipped AS NVARCHAR(10))
                                                      + CASE WHEN @Skipped = 1 THEN N' row' ELSE N' rows' END + N' with errors' ELSE N'' END, 1, 5, N'');
    SET @Message = CASE WHEN @Done IS NULL THEN N'Nothing was imported: every row is unchanged or has an error.'
                        ELSE N'Stock levels imported: ' + @Done + ISNULL(N'; ' + @Left + N' skipped', N'') + N'.' END;

    -- 1: per row
    SELECT j.RowNumber, j.Outcome, j.Message
    FROM #j j
    ORDER BY j.RowNumber;

    -- 2: the counts and the sentence
    SELECT Added = @Added, Changed = @Changed, Removed = @Removed, Unchanged = @Unchanged, Skipped = @Skipped, Message = @Message;
END
GO

-- Re-created (114) from the body of script 103: COLLATE DATABASE_DEFAULT on the text columns of its #tables (3).
CREATE OR ALTER PROCEDURE reporting.usp_ItemBalance_Data
    @UserId       INT,
    @WarehouseIds NVARCHAR(MAX) = NULL,    -- comma separated; a parent takes every warehouse under it; NULL / empty = all the user's
    @ItemIds      NVARCHAR(MAX) = NULL,    -- comma separated
    @FamilyIds    NVARCHAR(MAX) = NULL,    -- comma separated; a family takes its sub-families. Items and families: either
    @DateFrom     DATE,
    @DateTo       DATE,
    @Detail       BIT = 0                  -- 1: the events carry their document (the drill-down)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Start DATETIME2(3) = CAST(@DateFrom AS DATETIME2(3));
    DECLARE @End   DATETIME2(3) = DATEADD(DAY, 1, CAST(@DateTo AS DATETIME2(3)));   -- Date To inclusive

    /* -- The warehouses: the user's, the chosen ones (and everything under them) among them ------------------------ */
    DECLARE @Refusal NVARCHAR(400) = security.fn_User_WarehouseRefusal(@UserId, NULLIF(LTRIM(RTRIM(@WarehouseIds)), N''));
    IF @Refusal IS NOT NULL THROW 50010, @Refusal, 1;

    CREATE TABLE #Usable (WarehouseId INT NOT NULL PRIMARY KEY);
    IF security.fn_User_IsUnrestricted(@UserId) = 1
        INSERT INTO #Usable (WarehouseId) SELECT Id FROM masterdata.Warehouses;
    ELSE
        INSERT INTO #Usable (WarehouseId)
        SELECT u.WarehouseId FROM security.fn_User_Warehouses(@UserId) u
        INNER JOIN masterdata.Warehouses w ON w.Id = u.WarehouseId
        WHERE w.IsTransit = 0;

    CREATE TABLE #Wh (WarehouseId INT NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@WarehouseIds)), N'') IS NULL
        INSERT INTO #Wh (WarehouseId) SELECT WarehouseId FROM #Usable;
    ELSE
        INSERT INTO #Wh (WarehouseId)
        SELECT DISTINCT s.Id
        FROM (SELECT DISTINCT Id = TRY_CAST(LTRIM(RTRIM(value)) AS INT) FROM STRING_SPLIT(@WarehouseIds, N',')) p
        CROSS APPLY masterdata.fn_Warehouse_Subtree(p.Id) s
        INNER JOIN #Usable u ON u.WarehouseId = s.Id
        WHERE p.Id IS NOT NULL;

    /* -- The items: the chosen ones and those of the chosen families (and their sub-families); none = every item --- */
    DECLARE @AllItems BIT = CASE WHEN NULLIF(LTRIM(RTRIM(@ItemIds)), N'') IS NULL AND NULLIF(LTRIM(RTRIM(@FamilyIds)), N'') IS NULL THEN 1 ELSE 0 END;
    CREATE TABLE #Chosen (ItemId INT NOT NULL PRIMARY KEY);
    IF @AllItems = 0
    BEGIN
        WITH fam AS
        (
            SELECT f.Id FROM masterdata.ItemFamilies f
            WHERE f.Id IN (SELECT TRY_CAST(LTRIM(RTRIM(value)) AS INT) FROM STRING_SPLIT(ISNULL(@FamilyIds, N''), N','))
            UNION ALL
            SELECT c.Id FROM masterdata.ItemFamilies c INNER JOIN fam ON c.ParentId = fam.Id
        )
        INSERT INTO #Chosen (ItemId)
        SELECT i.Id FROM inventory.Items i
        WHERE i.Id IN (SELECT TRY_CAST(LTRIM(RTRIM(value)) AS INT) FROM STRING_SPLIT(ISNULL(@ItemIds, N''), N','))
           OR i.ItemFamilyId IN (SELECT Id FROM fam);
    END

    /* -- The documents left out: cancelled or reversed (their posting and its reversal), as usp_Item_RebuildCosts -- */
    CREATE TABLE #Undone (DocumentFamily NVARCHAR(20) COLLATE DATABASE_DEFAULT NOT NULL, DocumentTypeCode NVARCHAR(20) COLLATE DATABASE_DEFAULT NOT NULL, DocumentId INT NOT NULL,
                          DocumentNumber NVARCHAR(30) COLLATE DATABASE_DEFAULT NOT NULL);
    INSERT INTO #Undone (DocumentFamily, DocumentTypeCode, DocumentId, DocumentNumber)
    SELECT DISTINCT r.DocumentFamily, r.DocumentTypeCode, r.DocumentId, r.DocumentNumber
    FROM inventory.StockMovements r
    WHERE r.IsReversal = 1 AND r.MovementDate < @End;
    CREATE INDEX IX_Undone ON #Undone (DocumentFamily, DocumentTypeCode, DocumentId);

    /* -- The items of the report: a movement (or a cost adjustment) in one of the warehouses before Date To ends --- */
    CREATE TABLE #Scope (ItemId INT NOT NULL PRIMARY KEY);
    INSERT INTO #Scope (ItemId)
    SELECT DISTINCT m.ItemId
    FROM inventory.StockMovements m
    INNER JOIN #Wh w ON w.WarehouseId = m.WarehouseId
    WHERE m.MovementDate < @End
      AND (@AllItems = 1 OR EXISTS (SELECT 1 FROM #Chosen c WHERE c.ItemId = m.ItemId));
    INSERT INTO #Scope (ItemId)
    SELECT DISTINCT a.ItemId
    FROM inventory.CostAdjustments a
    INNER JOIN #Wh w ON w.WarehouseId = a.WarehouseId
    WHERE a.Kind = N'Inventory' AND a.AdjustmentDate < @End
      AND (@AllItems = 1 OR EXISTS (SELECT 1 FROM #Chosen c WHERE c.ItemId = a.ItemId))
      AND NOT EXISTS (SELECT 1 FROM #Scope s WHERE s.ItemId = a.ItemId);

    /* -- 1) the items --------------------------------------------------------------------------------------------- */
    SELECT i.Id AS ItemId, i.ItemCode, i.ItemName,
           Unit = (SELECT TOP (1) ut.UnitTypeName FROM inventory.ItemUnits u
                   INNER JOIN masterdata.UnitTypes ut ON ut.Id = u.UnitTypeId
                   WHERE u.ItemId = i.Id AND u.IsBaseUnit = 1 ORDER BY u.Id),
           f.FamilyName
    FROM #Scope s
    INNER JOIN inventory.Items i            ON i.Id = s.ItemId
    LEFT  JOIN masterdata.ItemFamilies f    ON f.Id = i.ItemFamilyId;

    /* -- 2) the warehouses, each with the warehouse at the top of its tree ---------------------------------------- */
    WITH up AS
    (
        SELECT w.WarehouseId, AncestorId = w.WarehouseId, Depth = 0
        FROM #Wh w
        UNION ALL
        SELECT up.WarehouseId, p.ParentId, up.Depth + 1
        FROM up
        INNER JOIN masterdata.Warehouses p ON p.Id = up.AncestorId
        WHERE p.ParentId IS NOT NULL AND up.Depth < 20
    ),
    root AS
    (
        SELECT WarehouseId, AncestorId, Rn = ROW_NUMBER() OVER (PARTITION BY WarehouseId ORDER BY Depth DESC) FROM up
    )
    SELECT w.Id AS WarehouseId, w.WarehouseCode, w.WarehouseName, w.IsTransit, b.BranchCode,
           RootId = r.Id, RootCode = r.WarehouseCode, RootName = r.WarehouseName
    FROM root x
    INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
    INNER JOIN masterdata.Warehouses r ON r.Id = x.AncestorId
    INNER JOIN masterdata.Branches b   ON b.Id = w.BranchId
    WHERE x.Rn = 1;

    /* -- 3) the events, in the replay's order (usp_Item_RebuildCosts: the date, movements before adjustments, id) -- */
    SELECT e.ItemId, e.WarehouseId, e.EventDate, e.Qty, e.Cost, e.Amount, e.GroupCode,
           InScope  = CAST(CASE WHEN EXISTS (SELECT 1 FROM #Wh w WHERE w.WarehouseId = e.WarehouseId) THEN 1 ELSE 0 END AS BIT),
           InPeriod = CAST(CASE WHEN e.EventAt >= @Start THEN 1 ELSE 0 END AS BIT),
           -- the drill-down only
           EventAt          = CASE WHEN @Detail = 1 THEN e.EventAt END,
           DocumentTypeCode = CASE WHEN @Detail = 1 THEN e.DocumentTypeCode END,
           DocumentId       = CASE WHEN @Detail = 1 THEN e.DocumentId END,
           DocumentNumber   = CASE WHEN @Detail = 1 THEN e.DocumentNumber END,
           TransferOrderId  = CASE WHEN @Detail = 1 AND e.DocumentFamily = N'Transfer'
                                   THEN (SELECT tp.TransferOrderId FROM inventory.TransferPostings tp WHERE tp.Id = e.DocumentId) END
    FROM
    (
        SELECT m.ItemId, m.WarehouseId, EventAt = m.MovementDate, EventDate = CAST(m.MovementDate AS DATE), Src = 1, SrcId = m.Id,
               Qty = m.QuantityBase,
               -- (90) A TRANSFER MOVES NO COST: its incoming legs enter at the running average (NULL here).
               Cost = CASE WHEN m.DocumentFamily = N'Transfer' AND m.QuantityBase > 0 THEN NULL ELSE m.UnitCostBase END,
               Amount = CAST(NULL AS DECIMAL(18,2)),
               -- A container offload (CNT) or a local invoice (PINV) received goods before goods receipts: a purchase receipt.
               GroupCode = CASE WHEN m.DocumentTypeCode IN (N'CNT', N'PINV') AND m.QuantityBase > 0 THEN N'GRN+'
                                WHEN m.ReasonCode = N'TRF_LOSS' THEN N'TRF_LOSS'
                                WHEN m.DocumentFamily = N'Transfer' THEN CASE WHEN m.QuantityBase > 0 THEN N'TRF+' ELSE N'TRF-' END
                                ELSE m.DocumentTypeCode + CASE WHEN m.QuantityBase > 0 THEN N'+' ELSE N'-' END END,
               m.DocumentFamily, m.DocumentTypeCode, m.DocumentId, m.DocumentNumber
        FROM inventory.StockMovements m
        INNER JOIN #Scope s ON s.ItemId = m.ItemId
        WHERE m.MovementDate < @End
          AND NOT EXISTS (SELECT 1 FROM #Undone r WHERE r.DocumentFamily = m.DocumentFamily AND r.DocumentTypeCode = m.DocumentTypeCode
                                                    AND r.DocumentId = m.DocumentId
                                                    AND (m.DocumentTypeCode <> N'CNT' OR r.DocumentNumber = m.DocumentNumber))
        UNION ALL
        SELECT a.ItemId, a.WarehouseId, a.AdjustmentDate, CAST(a.AdjustmentDate AS DATE), 2, CAST(a.Id AS INT), 0, NULL, a.AmountBase,
               N'ADJ', N'CostAdjustment', a.SourceKind, a.SourceId, a.SourceNumber
        FROM inventory.CostAdjustments a
        INNER JOIN #Scope s ON s.ItemId = a.ItemId
        WHERE a.Kind = N'Inventory' AND a.AdjustmentDate < @End
    ) e
    ORDER BY e.ItemId, e.EventAt, e.Src, e.SrcId;

    /* -- 4) the ledger's quantity on Date To, every row counted (the integrity check) ----------------------------- */
    SELECT m.ItemId, m.WarehouseId, QuantityBase = SUM(CAST(m.QuantityBase AS BIGINT))
    FROM inventory.StockMovements m
    INNER JOIN #Scope s ON s.ItemId = m.ItemId
    INNER JOIN #Wh w    ON w.WarehouseId = m.WarehouseId
    WHERE m.MovementDate < @End
    GROUP BY m.ItemId, m.WarehouseId;
END
GO

-- Re-created (114) from the body of script 104: COLLATE DATABASE_DEFAULT on the text columns of its #tables (10).
CREATE OR ALTER PROCEDURE logistics.usp_Container_NextStepPreview
    @ContainerIds logistics.tvp_IdList READONLY,
    @CanConfirm   BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET @CanConfirm = ISNULL(@CanConfirm, 1);

    -- A PROPOSAL MISSING IS NOT A BLOCK: when the usual type of the next stage is inactive the container still moves on,
    -- its type to choose ("Choose the type"). It cannot move on only when no movement type is active at all.
    DECLARE @AnyActiveType BIT = CASE WHEN EXISTS (SELECT 1 FROM masterdata.MovementTypes WHERE IsActive = 1 AND Stage <> N'Origin')
                                      THEN 1 ELSE 0 END;

    -- 1. the step of each container (the reads of fn_Container_NextStep, without its suggestion)
    CREATE TABLE #Step
    (
        ContainerId INT NOT NULL PRIMARY KEY, Found BIT NOT NULL, ContainerRef NVARCHAR(30) COLLATE DATABASE_DEFAULT NULL, ContainerNo NVARCHAR(30) COLLATE DATABASE_DEFAULT NULL,
        Status TINYINT NULL, Kind NVARCHAR(12) COLLATE DATABASE_DEFAULT NULL, BlockedReason NVARCHAR(400) COLLATE DATABASE_DEFAULT NULL,
        MovementCount INT NULL, PlaceId INT NULL, PlaceName NVARCHAR(100) COLLATE DATABASE_DEFAULT NULL, PlaceKind NVARCHAR(10) COLLATE DATABASE_DEFAULT NULL, PlaceSince DATE NULL,
        LastStage NVARCHAR(10) COLLATE DATABASE_DEFAULT NULL, LastMovementId INT NULL, LastMovementNo NVARCHAR(30) COLLATE DATABASE_DEFAULT NULL, LastMovementEndDate DATE NULL,
        MovementId INT NULL, PlannedNotBefore DATE NULL,
        ActiveMovementId INT NULL, PlannedMovementId INT NULL, LastDeliveryMovementId INT NULL,
        GoodsReceiptId INT NULL, GoodsReceiptNumber NVARCHAR(30) COLLATE DATABASE_DEFAULT NULL, GoodsReceiptStatus TINYINT NULL,
        HistPlaceId INT NULL, HistStage NVARCHAR(10) COLLATE DATABASE_DEFAULT NULL      -- the (place, last stage) of its suggestion
    );

    INSERT INTO #Step (ContainerId, Found, ContainerRef, ContainerNo, Status, Kind, BlockedReason, MovementCount, PlaceId, PlaceName,
                       PlaceKind, PlaceSince, LastStage, LastMovementId, LastMovementNo, LastMovementEndDate, MovementId,
                       PlannedNotBefore, ActiveMovementId, PlannedMovementId, LastDeliveryMovementId,
                       GoodsReceiptId, GoodsReceiptNumber, GoodsReceiptStatus, HistPlaceId, HistStage)
    SELECT x.Id, CASE WHEN c.Id IS NULL THEN 0 ELSE 1 END, c.ContainerRef, c.ContainerNo, c.Status, k.Kind, k.BlockedReason,
           ss.MovementCount, ss.PlaceId, ss.PlaceName, pk.Kind, ss.PlaceSince, ls.Stage, ss.LastMovementId, ss.LastMovementNo,
           ss.LastMovementEndDate,
           CASE k.Kind WHEN N'Complete' THEN ss.ActiveMovementId WHEN N'StartPlanned' THEN ss.PlannedMovementId END,
           NULL, ss.ActiveMovementId, ss.PlannedMovementId, dl.MovementId,
           rb.GoodsReceiptId, rb.GoodsReceiptNumber, rb.GoodsReceiptStatus,
           CASE WHEN k.Kind IN (N'Ship', N'NextLeg') THEN ss.PlaceId END,
           CASE WHEN k.Kind = N'NextLeg' THEN ls.Stage END
    FROM @ContainerIds x
    LEFT JOIN logistics.Containers c ON c.Id = x.Id
    OUTER APPLY logistics.fn_Container_ShipState(c.Id) ss
    OUTER APPLY logistics.fn_Container_ReceivedBy(c.Id) rb
    OUTER APPLY logistics.fn_Container_LastDelivery(c.Id) dl
    OUTER APPLY logistics.fn_Container_NextStepKind(c.Id, c.Status, ss.MovementCount, ss.ActiveMovementId, ss.PlannedMovementId,
                                                    NULL, ss.LastMovementId, dl.MovementId, rb.GoodsReceiptStatus) k
    LEFT JOIN masterdata.Ports pk ON pk.Id = ss.PlaceId
    OUTER APPLY (SELECT lt.Stage
                 FROM logistics.Movements lm
                 INNER JOIN masterdata.MovementTypes lt ON lt.Id = lm.MovementTypeId
                 WHERE lm.Id = ss.LastMovementId) ls;

    -- the movement each step concerns (Complete, StartPlanned), once per movement
    SELECT m.Id, m.MovementNo, m.RowVersion, m.Status, m.MovementTypeId, mt.TypeCode, mt.TypeName, mt.Stage,
           m.FromPlaceId, FromName = fp.PortName, m.ToPlaceId, ToName = tp.PortName, m.PlannedDate, m.StartDate, m.Eta,
           Cnt = (SELECT COUNT(*) FROM logistics.MovementContainers x WHERE x.MovementId = m.Id)
    INTO #Mov
    FROM logistics.Movements m
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    INNER JOIN masterdata.Ports fp         ON fp.Id = m.FromPlaceId
    INNER JOIN masterdata.Ports tp         ON tp.Id = m.ToPlaceId
    WHERE m.Id IN (SELECT MovementId FROM #Step WHERE MovementId IS NOT NULL);

    -- why a planned movement cannot start yet, once per movement (read through each container it cost seconds), and
    -- the step's refusal with it (fn_Container_NextStepKind: a draft, or the movement's own refusal)
    SELECT b.MovementId, b.Reason, b.StartNotBefore
    INTO #Sb
    FROM (SELECT DISTINCT MovementId FROM #Step WHERE Kind = N'StartPlanned') p
    CROSS APPLY logistics.fn_Movement_StartBlock(p.MovementId) b;

    UPDATE s
    SET PlannedNotBefore = b.StartNotBefore,
        BlockedReason = k.BlockedReason
    FROM #Step s
    INNER JOIN #Sb b ON b.MovementId = s.MovementId
    CROSS APPLY logistics.fn_Container_NextStepKind(s.ContainerId, s.Status, s.MovementCount, s.ActiveMovementId,
                                                    s.PlannedMovementId, b.Reason, s.LastMovementId, s.LastDeliveryMovementId,
                                                    s.GoodsReceiptStatus) k
    WHERE s.Kind = N'StartPlanned';

    -- 2. THE SUGGESTION, ONCE PER (place, last stage): the next leg of a container from where it is, and the leg after a
    -- movement to complete from that movement's To (the "Then" box)
    SELECT g.PlaceId, g.LastStage, h.MovementTypeId, h.ToPlaceId, h.Legs
    INTO #Hist
    FROM (SELECT DISTINCT PlaceId = HistPlaceId, LastStage = HistStage FROM #Step WHERE HistPlaceId IS NOT NULL
          UNION
          SELECT DISTINCT mv.ToPlaceId, mv.Stage
          FROM #Step s INNER JOIN #Mov mv ON mv.Id = s.MovementId
          WHERE s.Kind = N'Complete' AND mv.Stage <> N'Delivery') g
    CROSS APPLY logistics.fn_Movement_NextLegHistory(g.PlaceId, g.LastStage) h;

    -- 3. every container with its proposal, its group and why it cannot move on
    SELECT s.ContainerId, s.Found, s.ContainerRef, s.ContainerNo, s.Status, s.Kind, s.BlockedReason,
           IsDraft = CAST(CASE WHEN s.Status = 1 THEN 1 ELSE 0 END AS BIT),
           HasContainerNo = CAST(CASE WHEN NULLIF(LTRIM(RTRIM(s.ContainerNo)), N'') IS NULL THEN 0 ELSE 1 END AS BIT),
           HasTypedDates = CAST(CASE WHEN s.MovementCount = 0 AND (c.DispatchDate IS NOT NULL OR c.ActualPortArrival IS NOT NULL
                                                                    OR c.BorderCrossingDate IS NOT NULL OR c.CustomsReleaseDate IS NOT NULL)
                                     THEN 1 ELSE 0 END AS BIT),
           s.MovementCount, s.PlaceId, s.PlaceName, s.PlaceKind, s.PlaceSince,
           s.LastStage, s.LastMovementId, s.LastMovementNo, s.LastMovementEndDate,
           MovementId = mv.Id, MovementNo = mv.MovementNo, MovementRowVersion = mv.RowVersion, MovementStatus = mv.Status,
           MovementTypeId = mv.MovementTypeId, MovementTypeCode = mv.TypeCode, MovementTypeName = mv.TypeName,
           MovementStage = mv.Stage, MovementFromPlaceId = mv.FromPlaceId, MovementFromName = mv.FromName,
           MovementToPlaceId = mv.ToPlaceId, MovementToName = mv.ToName,
           MovementPlannedDate = mv.PlannedDate, MovementStartDate = mv.StartDate, MovementEta = mv.Eta,
           MovementContainerCount = mv.Cnt,
           MovementNotBefore = CASE s.Kind WHEN N'Complete' THEN mv.StartDate WHEN N'StartPlanned' THEN s.PlannedNotBefore END,
           s.GoodsReceiptId, s.GoodsReceiptNumber, s.GoodsReceiptStatus,
           ProposedTypeId = pr.TypeId, ProposedTypeCode = pr.TypeCode, ProposedTypeName = pr.TypeName, ProposedStage = pr.Stage,
           ProposedFromPlaceId = pr.FromPlaceId, ProposedFromName = pr.FromName,
           ProposedToPlaceId = pr.ToPlaceId, ProposedToName = pr.ToName,
           ProposalSource = pr.Source, ProposalLegs = pr.Legs, ProposedIsStay = pr.IsStay,
           ProposedOnePerContainer = pr.OnePerContainer,
           ThenTypeId = tn.TypeId, ThenTypeCode = tn.TypeCode, ThenTypeName = tn.TypeName, ThenStage = tn.Stage,
           ThenFromPlaceId = tn.FromPlaceId, ThenFromName = tn.FromName, ThenToPlaceId = tn.ToPlaceId, ThenToName = tn.ToName,
           ThenSource = tn.Source, ThenLegs = tn.Legs, ThenIsStay = tn.IsStay,
           ThenDefault = CAST(CASE WHEN tn.TypeId IS NOT NULL AND (tn.IsStay = 1 OR mv.Stage IN (N'Customs', N'Border'))
                                   THEN 1 ELSE 0 END AS BIT),
           -- the shipping details a new leg starts from (Sea: vessel, voyage, B/L; a truck leg: the truck)
           c.VesselName, c.VoyageNo, c.ShippingLine, c.BlNo, c.BlDate, c.TruckNo, ContainerEta = c.Eta,
           OrderNumbers = CASE WHEN ISNULL(po.OrderCount, 0) = 0 THEN NULL
                               WHEN po.OrderCount = 1 THEN po.FirstOrder
                               ELSE po.FirstOrder + N' +' + CAST(po.OrderCount - 1 AS NVARCHAR(10)) END,
           SupplierNames = CASE WHEN ISNULL(po.SupplierCount, 0) = 0 THEN NULL
                                WHEN po.SupplierCount = 1 THEN po.FirstSupplier
                                ELSE po.FirstSupplier + N' +' + CAST(po.SupplierCount - 1 AS NVARCHAR(10)) END,
           b.BlockGroup,
           CanMove = CAST(CASE WHEN b.BlockGroup IS NULL THEN 1 ELSE 0 END AS BIT),
           -- (step, movement, type, From, To): containers at different places or bound elsewhere fall apart by themselves
           GroupKey = CASE WHEN b.BlockGroup IS NULL
                           THEN CONCAT(s.Kind, N'|', mv.Id, N'|', COALESCE(mv.MovementTypeId, pr.TypeId), N'|',
                                       COALESCE(mv.FromPlaceId, pr.FromPlaceId), N'|', COALESCE(mv.ToPlaceId, pr.ToPlaceId)) END,
           -- (82) only part of its movement arrived: can it be split off the movement in progress, and why not
           CanSplitOff = CAST(CASE WHEN s.Kind = N'Complete' AND sp.Reason IS NULL THEN 1 ELSE 0 END AS BIT),
           SplitOffBlockedReason = sp.Reason
    INTO #Row
    FROM #Step s
    LEFT JOIN logistics.Containers c ON c.Id = s.ContainerId
    LEFT JOIN #Mov mv                ON mv.Id = s.MovementId
    LEFT JOIN #Hist h                ON s.Kind IN (N'Ship', N'NextLeg') AND h.PlaceId = s.HistPlaceId
                                    AND ISNULL(h.LastStage, N'') = ISNULL(s.HistStage, N'')
    LEFT JOIN #Hist th               ON s.Kind = N'Complete' AND s.PlannedMovementId IS NULL
                                    AND th.PlaceId = mv.ToPlaceId AND th.LastStage = mv.Stage
    OUTER APPLY (SELECT p.*
                 FROM logistics.fn_Container_NextLegProposal(s.ContainerId, s.PlaceId,
                                                             CASE WHEN s.MovementCount = 0 THEN NULL ELSE s.LastStage END,
                                                             CASE WHEN s.Status = 5 THEN 1 ELSE 0 END,
                                                             h.MovementTypeId, h.ToPlaceId, h.Legs) p
                 WHERE s.Kind IN (N'Ship', N'NextLeg')) pr
    OUTER APPLY (SELECT p.*
                 FROM logistics.fn_Container_NextLegProposal(s.ContainerId, mv.ToPlaceId, mv.Stage,
                                                             CASE WHEN s.Status = 5 OR mv.Stage = N'Customs' THEN 1 ELSE 0 END,
                                                             th.MovementTypeId, th.ToPlaceId, th.Legs) p
                 -- no "Then" when its next leg is already planned (fn_Container_NextStep)
                 WHERE s.Kind = N'Complete' AND s.PlannedMovementId IS NULL) tn
    OUTER APPLY (SELECT OrderCount = COUNT(DISTINCT cl.PurchaseOrderId), SupplierCount = COUNT(DISTINCT d.SupplierId),
                        FirstOrder = MIN(d.DocumentNumber), FirstSupplier = MIN(sp.PartyName)
                 FROM logistics.ContainerLines cl
                 INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                 INNER JOIN masterdata.Parties sp        ON sp.Id = d.SupplierId
                 WHERE cl.ContainerId = s.ContainerId) po
    -- (82) why it cannot be split off its movement (fn_Movement_SplitBlock), for a movement to complete only
    OUTER APPLY (SELECT x.Reason
                 FROM logistics.fn_Movement_SplitBlock(mv.Id, mv.MovementNo, mv.Status, mv.Cnt, s.ContainerId, s.ContainerRef) x
                 WHERE s.Kind = N'Complete') sp
    CROSS APPLY (SELECT BlockGroup = CAST(CASE
                     WHEN s.Found = 0 THEN N'Not found'
                     WHEN s.Kind = N'Done' THEN N'Received, closed or cancelled'
                     -- a draft goods receipt waits: it is opened, not made again (Receive goods... refuses it, 63013)
                     WHEN s.Kind = N'OpenReceipt'
                         THEN N'A draft goods receipt waits: Open goods receipt (draft)'
                     WHEN s.Kind = N'Receive'
                         THEN N'Delivered: its goods are received next (Receive goods' + NCHAR(8230) + N')'
                     WHEN s.Kind = N'Ship' AND s.Status = 1 AND @CanConfirm = 0 THEN N'Draft - you may not confirm containers'
                     WHEN s.Kind IN (N'Ship', N'NextLeg') AND s.PlaceId IS NULL
                         THEN N'No port of loading: open the container to choose where it leaves from'
                     WHEN s.Kind IN (N'Ship', N'NextLeg') AND @AnyActiveType = 0
                         THEN N'No movement type is active: activate one in Master Data ' + NCHAR(8250) + N' Movement Types'
                     ELSE s.BlockedReason END AS NVARCHAR(400))) b;

    SELECT * FROM #Row ORDER BY CanMove DESC, GroupKey, LEN(ContainerRef), ContainerRef, ContainerId;

    -- 4. the groups (set 2), with the orders and suppliers of each, for information
    SELECT g.GroupKey, OrderCount = COUNT(DISTINCT cl.PurchaseOrderId), SupplierCount = COUNT(DISTINCT d.SupplierId),
           FirstOrder = MIN(d.DocumentNumber), FirstSupplier = MIN(sp.PartyName)
    INTO #GroupOrders
    FROM #Row g
    INNER JOIN logistics.ContainerLines cl  ON cl.ContainerId = g.ContainerId
    INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
    INNER JOIN masterdata.Parties sp        ON sp.Id = d.SupplierId
    WHERE g.CanMove = 1
    GROUP BY g.GroupKey;

    SELECT r.GroupKey, Kind = MIN(r.Kind),
           MovementId = MIN(r.MovementId), MovementNo = MIN(r.MovementNo), MovementRowVersion = MAX(r.MovementRowVersion),
           MovementTypeId = MIN(COALESCE(r.MovementTypeId, r.ProposedTypeId)),
           MovementTypeCode = MIN(COALESCE(r.MovementTypeCode, r.ProposedTypeCode)),
           MovementTypeName = MIN(COALESCE(r.MovementTypeName, r.ProposedTypeName)),
           MovementStage = MIN(COALESCE(r.MovementStage, r.ProposedStage)),
           FromPlaceId = MIN(COALESCE(r.MovementFromPlaceId, r.ProposedFromPlaceId)),
           FromName = MIN(COALESCE(r.MovementFromName, r.ProposedFromName)),
           ToPlaceId = MIN(COALESCE(r.MovementToPlaceId, r.ProposedToPlaceId)),
           ToName = MIN(COALESCE(r.MovementToName, r.ProposedToName)),
           IsNewLeg = CAST(MAX(CASE WHEN r.Kind IN (N'Ship', N'NextLeg') THEN 1 ELSE 0 END) AS BIT),
           IsStay = CAST(MAX(CASE WHEN COALESCE(r.MovementStage, r.ProposedStage) IN (N'Port', N'Customs', N'Border') THEN 1 ELSE 0 END) AS BIT),
           MovementStartDate = MIN(r.MovementStartDate), MovementPlannedDate = MIN(r.MovementPlannedDate), MovementEta = MIN(r.MovementEta),
           Containers = COUNT(*), MovementContainerCount = MAX(r.MovementContainerCount),
           -- the earliest date of the step for every container of the group: a new leg leaves once the last one arrived
           NotBefore = MAX(CASE WHEN r.Kind IN (N'Ship', N'NextLeg') THEN r.PlaceSince ELSE r.MovementNotBefore END),
           PlaceName = MIN(r.PlaceName),
           ProposalSource = MIN(r.ProposalSource), ProposalLegs = MAX(r.ProposalLegs),
           OnePerContainer = CAST(MAX(CAST(ISNULL(r.ProposedOnePerContainer, 0) AS INT)) AS BIT),
           Drafts = SUM(CAST(r.IsDraft AS INT)), WithoutContainerNo = SUM(1 - CAST(r.HasContainerNo AS INT)),
           WithTypedDates = SUM(CAST(r.HasTypedDates AS INT)),
           OrderCount = MAX(o.OrderCount), SupplierCount = MAX(o.SupplierCount),
           OrderNumbers = MAX(CASE WHEN o.OrderCount = 1 THEN o.FirstOrder
                                   WHEN o.OrderCount > 1 THEN o.FirstOrder + N' +' + CAST(o.OrderCount - 1 AS NVARCHAR(10)) END),
           SupplierNames = MAX(CASE WHEN o.SupplierCount = 1 THEN o.FirstSupplier
                                    WHEN o.SupplierCount > 1 THEN o.FirstSupplier + N' +' + CAST(o.SupplierCount - 1 AS NVARCHAR(10)) END),
           -- "Then": offered when the containers of the group get a next leg after it; its fields when they all get the same
           ThenContainers = SUM(CASE WHEN r.ThenTypeId IS NOT NULL THEN 1 ELSE 0 END),
           ThenSame = CAST(CASE WHEN COUNT(DISTINCT CONCAT(r.ThenTypeId, N'|', r.ThenToPlaceId)) = 1
                                 AND COUNT(r.ThenTypeId) = COUNT(*) THEN 1 ELSE 0 END AS BIT),
           ThenTypeId = MIN(r.ThenTypeId), ThenTypeName = MIN(r.ThenTypeName), ThenStage = MIN(r.ThenStage),
           ThenFromPlaceId = MIN(r.ThenFromPlaceId), ThenFromName = MIN(r.ThenFromName),
           ThenToPlaceId = MIN(r.ThenToPlaceId), ThenToName = MIN(r.ThenToName), ThenIsStay = CAST(MIN(CAST(r.ThenIsStay AS INT)) AS BIT),
           ThenSource = MIN(r.ThenSource), ThenLegs = MAX(r.ThenLegs),
           ThenDefault = CAST(MIN(CAST(r.ThenDefault AS INT)) AS BIT),
           -- (82) a Complete group of only part of its movement: the ticked ones can complete alone (they get their own
           -- movement), else why not - every container of the movement is ticked, or one of them has a later leg
           SplitPossible = CAST(CASE WHEN MIN(r.Kind) = N'Complete' AND COUNT(*) < MAX(r.MovementContainerCount)
                                          AND MIN(CAST(r.CanSplitOff AS INT)) = 1 THEN 1 ELSE 0 END AS BIT),
           SplitBlockedReason = CAST(CASE WHEN MIN(r.Kind) <> N'Complete' THEN NULL
                                          WHEN COUNT(*) >= MAX(r.MovementContainerCount)
                                              THEN N'Every container of ' + MIN(r.MovementNo) + N' is ticked: complete the movement itself.'
                                          ELSE MIN(r.SplitOffBlockedReason) END AS NVARCHAR(400))
    FROM #Row r
    LEFT JOIN #GroupOrders o ON o.GroupKey = r.GroupKey
    WHERE r.CanMove = 1
    GROUP BY r.GroupKey
    ORDER BY CASE MIN(r.Kind) WHEN N'Complete' THEN 1 WHEN N'StartPlanned' THEN 2 ELSE 3 END,
             MIN(COALESCE(r.MovementFromName, r.ProposedFromName)), r.GroupKey;

    -- 5. the containers that cannot move on, by reason (set 3)
    SELECT BlockGroup, Containers = COUNT(*),
           ContainerRefs = STRING_AGG(CAST(CASE WHEN rn <= 5 THEN ISNULL(ContainerRef, CAST(ContainerId AS NVARCHAR(12))) END AS NVARCHAR(MAX)), N', ')
                           WITHIN GROUP (ORDER BY rn)
    FROM (SELECT BlockGroup, ContainerRef, ContainerId,
                 rn = ROW_NUMBER() OVER (PARTITION BY BlockGroup ORDER BY LEN(ContainerRef), ContainerRef, ContainerId)
          FROM #Row WHERE CanMove = 0) z
    GROUP BY BlockGroup
    ORDER BY COUNT(*) DESC, BlockGroup;
END
GO

-- Re-created (114) from the body of script 105: COLLATE DATABASE_DEFAULT on the text columns of its #tables (8).
CREATE OR ALTER PROCEDURE reporting.usp_ContainerChargeReport
    @ChargeTypeIds NVARCHAR(MAX),                -- comma separated, in the order of the columns
    @DateBasis     NVARCHAR(10)  = N'Offload',   -- Offload | Dispatch
    @DateFrom      DATE          = NULL,
    @DateTo        DATE          = NULL,
    @Search        NVARCHAR(100) = NULL,         -- container ref or no., B/L
    @SupplierId    INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Today DATE = CAST(SYSUTCDATETIME() AS DATE);
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @Like NVARCHAR(110) = N'%' + REPLACE(REPLACE(REPLACE(@Search, N'[', N'[[]'), N'%', N'[%]'), N'_', N'[_]') + N'%';
    DECLARE @ByDispatch BIT = CASE WHEN @DateBasis = N'Dispatch' THEN 1 ELSE 0 END;

    DECLARE @Types TABLE (Id INT NOT NULL PRIMARY KEY, Seq INT NOT NULL);
    INSERT INTO @Types (Id, Seq)
    -- Seq: where the id stands in the list (STRING_SPLIT's ordinal needs compatibility level 160).
    SELECT t.Id, MIN(x.Seq)
    FROM (SELECT Id = TRY_CAST(LTRIM(RTRIM(value)) AS INT),
                 Seq = CHARINDEX(N',' + LTRIM(RTRIM(value)) + N',', N',' + REPLACE(@ChargeTypeIds, N' ', N'') + N',')
          FROM STRING_SPLIT(ISNULL(@ChargeTypeIds, N''), N',')) x
    INNER JOIN purchase.ChargeTypes t ON t.Id = x.Id
    GROUP BY t.Id;

    /* ---------------------------------------------------------------- the containers */
    CREATE TABLE #C (ContainerId INT NOT NULL PRIMARY KEY);
    INSERT INTO #C (ContainerId)
    SELECT c.Id
    FROM logistics.Containers c
    WHERE c.Status <> 8
      AND (@DateFrom IS NULL OR (@ByDispatch = 1 AND c.DispatchDate >= @DateFrom)
                             OR (@ByDispatch = 0 AND c.Status IN (6, 7) AND c.OffloadedDate >= @DateFrom))
      AND (@DateTo IS NULL OR (@ByDispatch = 1 AND c.DispatchDate <= @DateTo)
                           OR (@ByDispatch = 0 AND c.Status IN (6, 7) AND c.OffloadedDate <= @DateTo))
      AND (@Search IS NULL OR c.ContainerRef LIKE @Like OR ISNULL(c.ContainerNo, N'') LIKE @Like OR ISNULL(c.BlNo, N'') LIKE @Like)
      AND (@SupplierId IS NULL OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                                          INNER JOIN purchase.PurchaseDocuments po ON po.Id = cl.PurchaseOrderId
                                          WHERE cl.ContainerId = c.Id AND po.SupplierId = @SupplierId));

    /* ---------------------------------------------------------------- their legs (as script 100) */
    CREATE TABLE #Legs (
        ContainerId INT NOT NULL, MovementId INT NOT NULL, Status TINYINT NOT NULL, Stage NVARCHAR(10) COLLATE DATABASE_DEFAULT NOT NULL,
        TypeCode NVARCHAR(10) COLLATE DATABASE_DEFAULT NOT NULL, FromId INT NOT NULL, ToId INT NOT NULL, FromKind NVARCHAR(10) COLLATE DATABASE_DEFAULT NULL,
        ToKind NVARCHAR(10) COLLATE DATABASE_DEFAULT NULL, FromName NVARCHAR(100) COLLATE DATABASE_DEFAULT NULL, ToName NVARCHAR(100) COLLATE DATABASE_DEFAULT NULL, StartDate DATE NULL,
        EndDate DATE NULL, Seq INT NULL, IsVessel BIT NULL, IsStay BIT NULL, PRIMARY KEY (ContainerId, MovementId));

    INSERT INTO #Legs (ContainerId, MovementId, Status, Stage, TypeCode, FromId, ToId, FromKind, ToKind, FromName, ToName,
                       StartDate, EndDate)
    SELECT mc.ContainerId, m.Id, m.Status, mt.Stage, mt.TypeCode, m.FromPlaceId, m.ToPlaceId, pf.Kind, pt.Kind,
           pf.PortName, pt.PortName, m.StartDate, m.EndDate
    FROM logistics.MovementContainers mc
    INNER JOIN #C c ON c.ContainerId = mc.ContainerId
    INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    LEFT JOIN masterdata.Ports pf ON pf.Id = m.FromPlaceId
    LEFT JOIN masterdata.Ports pt ON pt.Id = m.ToPlaceId
    WHERE m.Status IN (2, 3);

    UPDATE l SET Seq = s.Seq,
                 IsVessel = CASE WHEN l.Stage = N'Sea' OR (l.Stage = N'Transit' AND l.TypeCode <> N'INLAND'
                                                            AND l.FromKind = N'Sea' AND l.ToKind = N'Sea') THEN 1 ELSE 0 END,
                 IsStay = CASE WHEN l.Stage IN (N'Port', N'Customs') OR l.FromId = l.ToId THEN 1 ELSE 0 END
    FROM #Legs l
    INNER JOIN (SELECT ContainerId, MovementId,
                       Seq = ROW_NUMBER() OVER (PARTITION BY ContainerId ORDER BY StartDate, MovementId)
                FROM #Legs) s ON s.ContainerId = l.ContainerId AND s.MovementId = l.MovementId;

    CREATE TABLE #J (
        ContainerId INT NOT NULL PRIMARY KEY, FinalDestination NVARCHAR(400) COLLATE DATABASE_DEFAULT NULL, DeliveredTo NVARCHAR(100) COLLATE DATABASE_DEFAULT NULL,
        ActiveMovementId INT NULL, LastMovementId INT NULL);

    INSERT INTO #J (ContainerId, DeliveredTo, ActiveMovementId, LastMovementId)
    SELECT c.ContainerId,
           (SELECT TOP (1) l.ToName FROM #Legs l WHERE l.ContainerId = c.ContainerId AND l.Stage = N'Delivery' AND l.Status = 3
            ORDER BY l.EndDate DESC, l.Seq DESC),
           (SELECT TOP (1) l.MovementId FROM #Legs l WHERE l.ContainerId = c.ContainerId AND l.Status = 2 ORDER BY l.Seq DESC),
           (SELECT TOP (1) l.MovementId FROM #Legs l WHERE l.ContainerId = c.ContainerId AND l.Status = 3
            ORDER BY l.EndDate DESC, l.Seq DESC)
    FROM #C c;

    -- The places after the port, in order ("Mokambo → Lubumbashi").
    UPDATE j SET FinalDestination = d.Places
    FROM #J j
    OUTER APPLY (SELECT Places = STRING_AGG(x.ToName, N' → ') WITHIN GROUP (ORDER BY x.FirstSeq)
                 FROM (SELECT l.ToName, FirstSeq = MIN(l.Seq) FROM #Legs l
                       WHERE l.ContainerId = j.ContainerId AND l.IsVessel = 0 AND l.IsStay = 0 AND ISNULL(l.ToKind, N'') <> N'Sea'
                       GROUP BY l.ToName) x) d;

    /* ---------------------------------------------------------------- 1. the containers */
    SELECT c.Id AS ContainerId, c.ContainerRef, c.ContainerNo, c.BlNo, ContainerStatus = c.Status,
           Items = it.Items, Pieces = ISNULL(it.Pieces, 0), Suppliers = sp.Names, Orders = po.Numbers,
           FinalDestination = COALESCE(j.FinalDestination, fd.PortName),
           st.StageSort, st.StageLabel,
           DispatchDate = c.DispatchDate,
           OffloadedDate = CASE WHEN c.Status IN (6, 7) THEN c.OffloadedDate END,
           BranchName = b.BranchName, WarehouseName = w.WarehouseName
    FROM #C x
    INNER JOIN logistics.Containers c ON c.Id = x.ContainerId
    LEFT JOIN masterdata.Branches b ON b.Id = c.BranchId
    LEFT JOIN masterdata.Warehouses w ON w.Id = c.WarehouseId
    LEFT JOIN masterdata.Ports fd ON fd.Id = c.FinalDestinationId
    LEFT JOIN #J j ON j.ContainerId = c.Id
    LEFT JOIN #Legs act ON act.ContainerId = c.Id AND act.MovementId = j.ActiveMovementId
    LEFT JOIN #Legs lst ON lst.ContainerId = c.Id AND lst.MovementId = j.LastMovementId
    OUTER APPLY (SELECT Items = STRING_AGG(z.ItemCode + N' ×' + CAST(z.Qty AS NVARCHAR(12)), N', ') WITHIN GROUP (ORDER BY z.ItemCode),
                        Pieces = SUM(z.Qty)
                 FROM (SELECT i.ItemCode, Qty = SUM(cl.QuantityBase)
                       FROM logistics.ContainerLines cl INNER JOIN inventory.Items i ON i.Id = cl.ItemId
                       WHERE cl.ContainerId = c.Id GROUP BY i.ItemCode) z) it
    OUTER APPLY (SELECT Names = STRING_AGG(z.PartyName, N', ') WITHIN GROUP (ORDER BY z.PartyName)
                 FROM (SELECT DISTINCT p.PartyName
                       FROM logistics.ContainerLines cl
                       INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                       INNER JOIN masterdata.Parties p ON p.Id = d.SupplierId
                       WHERE cl.ContainerId = c.Id) z) sp
    OUTER APPLY (SELECT Numbers = STRING_AGG(z.DocumentNumber, N', ') WITHIN GROUP (ORDER BY z.DocumentNumber)
                 FROM (SELECT DISTINCT d.DocumentNumber
                       FROM logistics.ContainerLines cl
                       INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                       WHERE cl.ContainerId = c.Id AND d.DocumentNumber IS NOT NULL) z) po
    -- the stage (script 100's, without the order lines still to load)
    CROSS APPLY (SELECT StageSort = CASE
                     WHEN c.Status IN (6, 7) THEN 90
                     WHEN act.MovementId IS NOT NULL AND act.IsVessel = 1 THEN 20
                     WHEN act.MovementId IS NOT NULL AND act.Stage = N'Port' THEN 30
                     WHEN act.MovementId IS NOT NULL AND act.IsStay = 1 THEN 50
                     WHEN act.MovementId IS NOT NULL AND act.FromKind = N'Sea' THEN 40
                     WHEN act.MovementId IS NOT NULL THEN 55
                     WHEN lst.MovementId IS NULL THEN 10
                     WHEN lst.Stage = N'Delivery' THEN 60
                     WHEN lst.ToKind = N'Sea' THEN 30
                     ELSE 50 END) s0
    CROSS APPLY (SELECT StageSort = CAST(s0.StageSort AS INT),
                        StageLabel = CASE s0.StageSort
                            WHEN 90 THEN N'Offloaded in ' + COALESCE(j.DeliveredTo, w.WarehouseName, N'the warehouse')
                            WHEN 20 THEN N'In transit ' + ISNULL(act.FromName, N'?') + N' → ' + ISNULL(act.ToName, N'?')
                            WHEN 30 THEN ISNULL(CASE WHEN act.MovementId IS NOT NULL THEN act.ToName ELSE lst.ToName END, N'At port')
                            WHEN 50 THEN ISNULL(CASE WHEN act.MovementId IS NOT NULL THEN act.ToName ELSE lst.ToName END, N'At border / customs')
                            WHEN 40 THEN ISNULL(act.FromName, N'?') + N' → ' + ISNULL(act.ToName, N'?')
                            WHEN 55 THEN ISNULL(act.FromName, N'?') + N' → ' + ISNULL(act.ToName, N'?')
                            WHEN 60 THEN N'Delivered to ' + ISNULL(lst.ToName, N'?') + N', to receive'
                            ELSE N'Not dispatched yet' END) st
    ORDER BY st.StageSort, st.StageLabel, c.ContainerRef;

    /* ---------------------------------------------------------------- 2. the charges of the asked types */
    SELECT ChargeId = ch.Id, ch.ContainerId, ch.ChargeTypeId, ch.Status, ch.ChargeDate, Reference = NULLIF(ch.Reference, N''),
           ProviderName = pr.PartyName, cu.CurrencyCode, ch.Amount, ch.AmountBase,
           PaidAmount = ISNULL(pay.Paid, 0), PaidBase = ISNULL(pay.PaidBase, 0),
           Payments = pay.List
    FROM logistics.ContainerCharges ch
    INNER JOIN #C c ON c.ContainerId = ch.ContainerId
    INNER JOIN @Types t ON t.Id = ch.ChargeTypeId
    LEFT JOIN masterdata.Parties pr ON pr.Id = ch.ProviderPartyId
    LEFT JOIN masterdata.Currencies cu ON cu.Id = ch.CurrencyId
    OUTER APPLY (SELECT Paid = SUM(z.Amount), PaidBase = SUM(z.AmountBase),
                        List = STRING_AGG(z.PaymentNumber + N' · ' + CONVERT(NVARCHAR(10), z.PaymentDate, 103)
                                          + N' · ' + FORMAT(z.Amount, N'N2', 'en-US'), N'; ')
                                   WITHIN GROUP (ORDER BY z.PaymentDate, z.PaymentNumber)
                 FROM (SELECT PaymentNumber = ISNULL(p.PaymentNumber, N'#' + CAST(p.Id AS NVARCHAR(12))), p.PaymentDate,
                              Amount = SUM(a.AmountDocCurrency), AmountBase = SUM(a.AmountBase)
                       FROM purchase.PaymentAllocations a
                       INNER JOIN purchase.Payments p ON p.Id = a.PaymentId
                       WHERE a.ContainerChargeId = ch.Id AND a.RemovedAtUtc IS NULL AND p.Status = 2
                       GROUP BY p.Id, p.PaymentNumber, p.PaymentDate) z) pay
    WHERE ch.Status IN (1, 2)
    ORDER BY ch.ContainerId, ch.ChargeTypeId, ch.ChargeDate, ch.Id;

    /* ---------------------------------------------------------------- 3. the charge types asked */
    SELECT ct.Id, ct.ChargeCode, ct.ChargeName, ct.IsDeduction
    FROM @Types t INNER JOIN purchase.ChargeTypes ct ON ct.Id = t.Id
    ORDER BY t.Seq;
END
GO

-- Re-created (114) from the body of script 110: COLLATE DATABASE_DEFAULT on the text columns of its #tables (14).
CREATE OR ALTER PROCEDURE logistics.usp_ContainerReport
    @Search          NVARCHAR(100) = NULL,   -- container ref or no., B/L, order number, PI no., invoice no.
    @SupplierId      INT           = NULL,
    @ItemId          INT           = NULL,
    @ItemFamilyId    INT           = NULL,   -- with the families under it
    @BranchId        INT           = NULL,
    @OrderDateFrom   DATE          = NULL,
    @OrderDateTo     DATE          = NULL,
    @OffloadedFrom   DATE          = NULL,
    @OffloadedTo     DATE          = NULL,
    @IncludePending  BIT           = 1,
    @IncludeReceived BIT           = 1,
    @DispatchFrom    DATE          = NULL,   -- (106) the container's dispatch date: only container lines, no order line
    @DispatchTo      DATE          = NULL,
    @LoadingCountry  NCHAR(2)      = NULL,   -- (106) its port of loading's country, else its country of origin
    @WithCharges     BIT           = 1       -- (110) 0: no charge is read - result sets 2 and 3 empty, no transport or
                                             --       charge figure and no total expenses on the rows
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Today DATE = CAST(SYSUTCDATETIME() AS DATE);
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @Like NVARCHAR(110) = N'%' + REPLACE(REPLACE(REPLACE(@Search, N'[', N'[[]'), N'%', N'[%]'), N'_', N'[_]') + N'%';

    DECLARE @Families TABLE (Id INT PRIMARY KEY);
    IF @ItemFamilyId IS NOT NULL INSERT INTO @Families (Id) SELECT Id FROM masterdata.fn_ItemFamily_Subtree(@ItemFamilyId);

    DECLARE @PoTypeId INT = (SELECT Id FROM inventory.DocumentTypes WHERE Code = N'PO');
    DECLARE @InvTypeId INT = (SELECT Id FROM inventory.DocumentTypes WHERE Code = N'PINV');

    /* ---------------------------------------------------------------- the rows */
    CREATE TABLE #R (
        RowKey NVARCHAR(20) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY, IsPending BIT NOT NULL,
        ContainerId INT NULL, ContainerLineId INT NULL, PoId INT NOT NULL, PoLineId INT NOT NULL, ItemId INT NOT NULL,
        Qty INT NOT NULL, OrderPriceBase DECIMAL(18,6) NULL);

    -- Container lines: every container not cancelled.
    INSERT INTO #R (RowKey, IsPending, ContainerId, ContainerLineId, PoId, PoLineId, ItemId, Qty, OrderPriceBase)
    SELECT N'C' + CAST(cl.Id AS NVARCHAR(12)), 0, c.Id, cl.Id, cl.PurchaseOrderId, cl.PoLineId, cl.ItemId,
           cl.QuantityBase, pol.LineTotal / NULLIF(po.ExchangeRate, 0) / NULLIF(pol.QuantityBase, 0)
    FROM logistics.ContainerLines cl
    INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
    INNER JOIN purchase.PurchaseDocuments po ON po.Id = cl.PurchaseOrderId
    INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = cl.PoLineId
    WHERE c.Status <> 8
      AND (@IncludeReceived = 1 OR c.Status NOT IN (6, 7))
      AND (@OffloadedFrom IS NULL OR c.Status NOT IN (6, 7) OR c.OffloadedDate >= @OffloadedFrom)
      AND (@OffloadedTo IS NULL OR c.Status NOT IN (6, 7) OR c.OffloadedDate <= @OffloadedTo)
      AND (@DispatchFrom IS NULL OR c.DispatchDate >= @DispatchFrom)
      AND (@DispatchTo IS NULL OR c.DispatchDate <= @DispatchTo)
      AND (@LoadingCountry IS NULL
           OR ISNULL((SELECT pl.CountryCode FROM masterdata.Ports pl WHERE pl.Id = c.PortOfLoadingId), c.CountryOfOrigin) = @LoadingCountry);

    -- Order lines still to load: approved orders (status 2), pieces not on a container, not received outside one, not
    -- settled short. (106) None when a dispatch date or a loading country is asked: an order line has neither.
    IF @IncludePending = 1 AND @DispatchFrom IS NULL AND @DispatchTo IS NULL AND @LoadingCountry IS NULL
        INSERT INTO #R (RowKey, IsPending, ContainerId, ContainerLineId, PoId, PoLineId, ItemId, Qty, OrderPriceBase)
        SELECT N'P' + CAST(pol.Id AS NVARCHAR(12)), 1, NULL, NULL, po.Id, pol.Id, pol.ItemId, x.ToLoad,
               pol.LineTotal / NULLIF(po.ExchangeRate, 0) / NULLIF(pol.QuantityBase, 0)
        FROM purchase.PurchaseDocumentLines pol
        INNER JOIN purchase.PurchaseDocuments po ON po.Id = pol.DocumentId
        OUTER APPLY (SELECT Qty = SUM(cl.QuantityBase)
                     FROM logistics.ContainerLines cl INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                     WHERE cl.PoLineId = pol.Id AND c.Status <> 8) ld
        OUTER APPLY (SELECT Qty = SUM(gl.QuantityBase)
                     FROM purchase.GoodsReceiptLines gl INNER JOIN purchase.GoodsReceipts g ON g.Id = gl.GoodsReceiptId
                     WHERE gl.PoLineId = pol.Id AND gl.ContainerLineId IS NULL AND g.Status = 2) rc
        CROSS APPLY (SELECT ToLoad = pol.QuantityBase - ISNULL(ld.Qty, 0) - ISNULL(rc.Qty, 0)
                                     - ISNULL(pol.GoodsShortBase, 0)) x
        WHERE po.DocumentTypeId = @PoTypeId AND po.Status = 2 AND x.ToLoad > 0;

    -- The filters.
    DELETE r FROM #R r
    INNER JOIN purchase.PurchaseDocuments po ON po.Id = r.PoId
    INNER JOIN inventory.Items i ON i.Id = r.ItemId
    LEFT JOIN logistics.Containers c ON c.Id = r.ContainerId
    WHERE (@SupplierId IS NOT NULL AND po.SupplierId <> @SupplierId)
       OR (@ItemId IS NOT NULL AND r.ItemId <> @ItemId)
       OR (@ItemFamilyId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM @Families f WHERE f.Id = i.ItemFamilyId))
       OR (@BranchId IS NOT NULL AND ISNULL(c.BranchId, po.BranchId) <> @BranchId)
       OR (@OrderDateFrom IS NOT NULL AND po.DocumentDate < @OrderDateFrom)
       OR (@OrderDateTo IS NOT NULL AND po.DocumentDate > @OrderDateTo)
       OR (@Search IS NOT NULL
           AND ISNULL(c.ContainerRef, N'') NOT LIKE @Like AND ISNULL(c.ContainerNo, N'') NOT LIKE @Like
           AND ISNULL(c.BlNo, N'') NOT LIKE @Like AND ISNULL(po.DocumentNumber, N'') NOT LIKE @Like
           AND ISNULL(po.SupplierReference, N'') NOT LIKE @Like
           AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines il
                           INNER JOIN purchase.PurchaseDocuments inv ON inv.Id = il.DocumentId
                           WHERE inv.DocumentTypeId = @InvTypeId AND inv.Status <> 3
                             AND (il.ContainerLineId = r.ContainerLineId OR (r.IsPending = 1 AND il.SourceLineId = r.PoLineId))
                             AND (ISNULL(inv.DocumentNumber, N'') LIKE @Like OR ISNULL(inv.CommercialInvoiceNo, N'') LIKE @Like
                                  OR ISNULL(inv.ExporterReference, N'') LIKE @Like)));

    /* ---------------------------------------------------------------- the legs of their containers */
    CREATE TABLE #Legs (
        ContainerId INT NOT NULL, MovementId INT NOT NULL, Status TINYINT NOT NULL, Stage NVARCHAR(10) COLLATE DATABASE_DEFAULT NOT NULL,
        TypeCode NVARCHAR(10) COLLATE DATABASE_DEFAULT NOT NULL, FromId INT NOT NULL, ToId INT NOT NULL, FromKind NVARCHAR(10) COLLATE DATABASE_DEFAULT NULL,
        ToKind NVARCHAR(10) COLLATE DATABASE_DEFAULT NULL, FromName NVARCHAR(100) COLLATE DATABASE_DEFAULT NULL, ToName NVARCHAR(100) COLLATE DATABASE_DEFAULT NULL, StartDate DATE NULL,
        EndDate DATE NULL, Eta DATE NULL, Vehicle NVARCHAR(100) COLLATE DATABASE_DEFAULT NULL, Seq INT NULL,
        IsVessel BIT NULL, IsStay BIT NULL, PRIMARY KEY (ContainerId, MovementId));

    INSERT INTO #Legs (ContainerId, MovementId, Status, Stage, TypeCode, FromId, ToId, FromKind, ToKind, FromName, ToName,
                       StartDate, EndDate, Eta, Vehicle)
    SELECT mc.ContainerId, m.Id, m.Status, mt.Stage, mt.TypeCode, m.FromPlaceId, m.ToPlaceId, pf.Kind, pt.Kind,
           pf.PortName, pt.PortName, m.StartDate, m.EndDate, m.Eta, NULLIF(LTRIM(RTRIM(m.VehicleOrVessel)), N'')
    FROM logistics.MovementContainers mc
    INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    LEFT JOIN masterdata.Ports pf ON pf.Id = m.FromPlaceId
    LEFT JOIN masterdata.Ports pt ON pt.Id = m.ToPlaceId
    WHERE m.Status IN (2, 3)
      AND mc.ContainerId IN (SELECT DISTINCT ContainerId FROM #R WHERE ContainerId IS NOT NULL);

    UPDATE l SET Seq = s.Seq,
                 IsVessel = CASE WHEN l.Stage = N'Sea' OR (l.Stage = N'Transit' AND l.TypeCode <> N'INLAND'
                                                            AND l.FromKind = N'Sea' AND l.ToKind = N'Sea') THEN 1 ELSE 0 END,
                 IsStay = CASE WHEN l.Stage IN (N'Port', N'Customs') OR l.FromId = l.ToId THEN 1 ELSE 0 END
    FROM #Legs l
    INNER JOIN (SELECT ContainerId, MovementId,
                       Seq = ROW_NUMBER() OVER (PARTITION BY ContainerId ORDER BY StartDate, MovementId)
                FROM #Legs) s ON s.ContainerId = l.ContainerId AND s.MovementId = l.MovementId;

    CREATE TABLE #J (
        ContainerId INT NOT NULL PRIMARY KEY, DispatchDate DATE NULL, ArrivedPortDate DATE NULL, LeftPortDate DATE NULL,
        FinalDestination NVARCHAR(400) COLLATE DATABASE_DEFAULT NULL, Trucks NVARCHAR(400) COLLATE DATABASE_DEFAULT NULL, DeliveredTo NVARCHAR(100) COLLATE DATABASE_DEFAULT NULL,
        ActiveMovementId INT NULL, LastMovementId INT NULL);

    INSERT INTO #J (ContainerId, DispatchDate, ArrivedPortDate, LeftPortDate, DeliveredTo, ActiveMovementId, LastMovementId)
    SELECT c.ContainerId,
           (SELECT MIN(l.StartDate) FROM #Legs l WHERE l.ContainerId = c.ContainerId AND l.Stage = N'Sea'),
           (SELECT MAX(l.EndDate) FROM #Legs l WHERE l.ContainerId = c.ContainerId AND l.Stage = N'Sea' AND l.Status = 3),
           (SELECT MIN(l.StartDate) FROM #Legs l WHERE l.ContainerId = c.ContainerId AND l.FromKind = N'Sea'
                                                     AND l.IsVessel = 0 AND l.IsStay = 0),
           (SELECT TOP (1) l.ToName FROM #Legs l WHERE l.ContainerId = c.ContainerId AND l.Stage = N'Delivery' AND l.Status = 3
            ORDER BY l.EndDate DESC, l.Seq DESC),
           (SELECT TOP (1) l.MovementId FROM #Legs l WHERE l.ContainerId = c.ContainerId AND l.Status = 2 ORDER BY l.Seq DESC),
           (SELECT TOP (1) l.MovementId FROM #Legs l WHERE l.ContainerId = c.ContainerId AND l.Status = 3
            ORDER BY l.EndDate DESC, l.Seq DESC)
    FROM (SELECT DISTINCT ContainerId FROM #R WHERE ContainerId IS NOT NULL) c;

    -- The places after the port, in order ("Mokambo → Lubumbashi"), and the vehicles that took them there.
    UPDATE j SET FinalDestination = d.Places, Trucks = t.Vehicles
    FROM #J j
    OUTER APPLY (SELECT Places = STRING_AGG(x.ToName, N' → ') WITHIN GROUP (ORDER BY x.FirstSeq)
                 FROM (SELECT l.ToName, FirstSeq = MIN(l.Seq) FROM #Legs l
                       WHERE l.ContainerId = j.ContainerId AND l.IsVessel = 0 AND l.IsStay = 0 AND ISNULL(l.ToKind, N'') <> N'Sea'
                       GROUP BY l.ToName) x) d
    OUTER APPLY (SELECT Vehicles = STRING_AGG(x.Vehicle, N' / ') WITHIN GROUP (ORDER BY x.FirstSeq)
                 FROM (SELECT l.Vehicle, FirstSeq = MIN(l.Seq) FROM #Legs l
                       WHERE l.ContainerId = j.ContainerId AND l.IsVessel = 0 AND l.Vehicle IS NOT NULL
                       GROUP BY l.Vehicle) x) t;

    /* ---------------------------------------------------------------- invoices and payments */
    CREATE TABLE #Inv (RowKey NVARCHAR(20) COLLATE DATABASE_DEFAULT NOT NULL, InvoiceId INT NOT NULL, PRIMARY KEY (RowKey, InvoiceId));
    INSERT INTO #Inv (RowKey, InvoiceId)
    SELECT DISTINCT r.RowKey, inv.Id
    FROM #R r
    INNER JOIN purchase.PurchaseDocumentLines il
            ON il.ContainerLineId = r.ContainerLineId OR (r.IsPending = 1 AND il.SourceLineId = r.PoLineId AND il.ContainerLineId IS NULL)
    INNER JOIN purchase.PurchaseDocuments inv ON inv.Id = il.DocumentId
    WHERE inv.DocumentTypeId = @InvTypeId AND inv.Status = 2;

    CREATE TABLE #Pay (InvoiceId INT NOT NULL, PaymentId INT NOT NULL, Amount DECIMAL(18,2) NOT NULL, PRIMARY KEY (InvoiceId, PaymentId));
    INSERT INTO #Pay (InvoiceId, PaymentId, Amount)
    SELECT a.PurchaseDocumentId, a.PaymentId, SUM(a.AmountDocCurrency)
    FROM purchase.PaymentAllocations a
    INNER JOIN purchase.Payments p ON p.Id = a.PaymentId
    WHERE p.Status = 2 AND a.RemovedAtUtc IS NULL AND a.PurchaseDocumentId IN (SELECT InvoiceId FROM #Inv)
    GROUP BY a.PurchaseDocumentId, a.PaymentId;

    /* ---------------------------------------------------------------- charges */
    CREATE TABLE #Ch (RowKey NVARCHAR(20) COLLATE DATABASE_DEFAULT NOT NULL, ChargeTypeId INT NOT NULL, AmountBase DECIMAL(18,2) NOT NULL,
                      PRIMARY KEY (RowKey, ChargeTypeId));
    -- (110) Read only when asked: left empty, the transport and charge figures below are empty too.
    IF @WithCharges = 1
        INSERT INTO #Ch (RowKey, ChargeTypeId, AmountBase)
        SELECT r.RowKey, ch.ChargeTypeId, SUM(a.AmountBase)
        FROM #R r
        INNER JOIN logistics.ContainerChargeAllocations a ON a.ContainerLineId = r.ContainerLineId
        INNER JOIN logistics.ContainerCharges ch ON ch.Id = a.ChargeId
        WHERE ch.Status = 2
        GROUP BY r.RowKey, ch.ChargeTypeId;

    DECLARE @Transport TABLE (Id INT PRIMARY KEY);
    INSERT INTO @Transport (Id) SELECT Id FROM purchase.ChargeTypes WHERE ChargeCode IN (N'FRE', N'TRP');

    -- (106) Each family's top family ("Main Items", "Maintenance and Accessories"): Dispatched Items counts its pieces apart.
    CREATE TABLE #Root (FamilyId INT NOT NULL PRIMARY KEY, RootName NVARCHAR(150) COLLATE DATABASE_DEFAULT NULL);
    WITH f AS (SELECT Id, RootId = Id FROM masterdata.ItemFamilies WHERE ParentId IS NULL
               UNION ALL
               SELECT ch.Id, f.RootId FROM masterdata.ItemFamilies ch INNER JOIN f ON ch.ParentId = f.Id)
    INSERT INTO #Root (FamilyId, RootName)
    SELECT f.Id, r.FamilyName FROM f INNER JOIN masterdata.ItemFamilies r ON r.Id = f.RootId;

    /* ---------------------------------------------------------------- 1. the rows */
    SELECT r.RowKey, r.IsPending,
           st.StageSort, st.StageLabel,
           OrderDate = po.DocumentDate, PurchaseOrderId = po.Id, PoNumber = po.DocumentNumber,
           OrderMonth = CASE WHEN c.OrderMonthKey IS NOT NULL
                             THEN LEFT(DATENAME(MONTH, DATEFROMPARTS(c.OrderMonthKey / 100, c.OrderMonthKey % 100, 1)), 3)
                                  + N'-' + RIGHT(CAST(c.OrderMonthKey / 100 AS NVARCHAR(4)), 2)
                             ELSE LEFT(DATENAME(MONTH, po.DocumentDate), 3) + N'-' + RIGHT(CAST(YEAR(po.DocumentDate) AS NVARCHAR(4)), 2) END,
           InvoiceDate = inv.FirstDate, InvoiceDates = inv.Dates, InvoiceNumbers = inv.Numbers,
           CommercialInvoiceNos = inv.CommercialNos, ExporterReferences = inv.ExporterRefs,
           r.ContainerId, c.ContainerRef, c.ContainerNo, ContainerStatus = c.Status,
           r.ItemId, i.ItemCode, Model = i.ItemName, Quantity = r.Qty,
           PiNumber = po.SupplierReference,
           SupplierId = po.SupplierId, SupplierName = sp.PartyName,
           BranchName = b.BranchName, WarehouseCode = w.WarehouseCode,
           FobAmountBase = CAST(r.Qty * fob.UnitFob AS DECIMAL(18,2)),
           FobIsEstimate = CAST(CASE WHEN cl.FobCostBase IS NULL THEN 1 ELSE 0 END AS BIT),
           OilQtyPerUnit = cl.OilQtyPerUnit,
           OilIncluded = cl.OilIncluded, TotalOilQty = NULLIF(cl.TotalOilQty, 0),
           ItemFamilyName = fam.FamilyName, RootFamilyName = rt.RootName,
           LoadingCountry = ISNULL(pl.CountryCode, c.CountryOfOrigin),
           PaidDates = pay.Dates, PaymentReferences = pay.Refs,
           PaymentStatus = CASE WHEN inv.FirstDate IS NULL THEN N'Not invoiced'
                                WHEN pay.Paid IS NULL THEN N'Not paid'
                                WHEN pay.Paid >= inv.Total - 0.005 THEN N'Paid'
                                ELSE N'Partly paid' END,
           -- (106) a container followed by typed dates (no Sea leg) shows them
           DispatchDate = COALESCE(j.DispatchDate, c.DispatchDate),
           ArrivedPortDate = COALESCE(j.ArrivedPortDate, c.ActualPortArrival), j.LeftPortDate,
           FinalDestination = COALESCE(j.FinalDestination, fd.PortName),
           Trucks = COALESCE(j.Trucks, NULLIF(LTRIM(RTRIM(c.TruckNo)), N'')),
           OffloadedDate = CASE WHEN c.Status IN (6, 7) THEN c.OffloadedDate END,
           GoodsReceiptNumbers = grn.Numbers,
           LeadTimeMonths = CAST(ROUND(DATEDIFF(DAY, po.DocumentDate,
                                CASE WHEN c.Status IN (6, 7) THEN c.OffloadedDate ELSE @Today END) / 30.0, 2) AS DECIMAL(9,2)),
           LeadTimeSoFar = CAST(CASE WHEN c.Status IN (6, 7) THEN 0 ELSE 1 END AS BIT),
           c.BlNo, c.FeriNo,
           TransportReferences = tr.Refs, TransportInvoices = tr.Invoices,
           TransportBase = trs.Amount,
           ChargesBase = chs.Amount,
           TotalExpensesBase = CASE WHEN @WithCharges = 1 THEN CAST(r.Qty * fob.UnitFob AS DECIMAL(18,2)) + ISNULL(chs.Amount, 0) END,
           CostPerUnitBase = CAST(CASE WHEN r.IsPending = 1 THEN r.OrderPriceBase
                                       ELSE COALESCE(cl.LandedCostBase, fob.UnitFob + cl.ChargesBase / NULLIF(cl.QuantityBase, 0)) END
                                  AS DECIMAL(18,4)),
           CostIsEstimate = CAST(CASE WHEN cl.LandedCostBase IS NOT NULL THEN 0 ELSE 1 END AS BIT),
           IsLate = CAST(CASE WHEN act.Eta < @Today THEN 1 ELSE 0 END AS BIT),
           IsFreeTimeOver = CAST(CASE WHEN c.Status IN (4, 5) AND c.LastFreeDay < @Today THEN 1 ELSE 0 END AS BIT)
    FROM #R r
    INNER JOIN purchase.PurchaseDocuments po ON po.Id = r.PoId
    INNER JOIN masterdata.Parties sp ON sp.Id = po.SupplierId
    INNER JOIN inventory.Items i ON i.Id = r.ItemId
    LEFT JOIN logistics.ContainerLines cl ON cl.Id = r.ContainerLineId
    LEFT JOIN logistics.Containers c ON c.Id = r.ContainerId
    LEFT JOIN masterdata.Branches b ON b.Id = ISNULL(c.BranchId, po.BranchId)
    LEFT JOIN masterdata.Warehouses w ON w.Id = ISNULL(c.WarehouseId, po.WarehouseId)
    LEFT JOIN masterdata.Ports fd ON fd.Id = c.FinalDestinationId
    LEFT JOIN masterdata.Ports pl ON pl.Id = c.PortOfLoadingId
    LEFT JOIN masterdata.ItemFamilies fam ON fam.Id = i.ItemFamilyId
    LEFT JOIN #Root rt ON rt.FamilyId = i.ItemFamilyId
    LEFT JOIN #J j ON j.ContainerId = r.ContainerId
    LEFT JOIN #Legs act ON act.ContainerId = r.ContainerId AND act.MovementId = j.ActiveMovementId
    LEFT JOIN #Legs lst ON lst.ContainerId = r.ContainerId AND lst.MovementId = j.LastMovementId
    -- the FOB per piece: the line's own once received, else the container page's estimate; the order price for an order
    -- line still to load
    OUTER APPLY (SELECT UnitFob = CASE WHEN r.IsPending = 1 THEN r.OrderPriceBase
                                       ELSE COALESCE(cl.FobCostBase,
                                                     (SELECT fe.EstimatedFobBase FROM logistics.fn_ContainerLine_FobEstimate(cl.Id) fe)) END) fob
    OUTER APPLY (SELECT FirstDate = MIN(d.DocumentDate),
                        Dates = STRING_AGG(CONVERT(NVARCHAR(10), d.DocumentDate, 103), N', ') WITHIN GROUP (ORDER BY d.DocumentDate),
                        Numbers = STRING_AGG(d.DocumentNumber, N', ') WITHIN GROUP (ORDER BY d.DocumentDate, d.Id),
                        CommercialNos = STRING_AGG(NULLIF(d.CommercialInvoiceNo, N''), N', ') WITHIN GROUP (ORDER BY d.DocumentDate, d.Id),
                        ExporterRefs = STRING_AGG(NULLIF(d.ExporterReference, N''), N', ') WITHIN GROUP (ORDER BY d.DocumentDate, d.Id),
                        Total = SUM(d.TotalAmount)
                 FROM #Inv x INNER JOIN purchase.PurchaseDocuments d ON d.Id = x.InvoiceId
                 WHERE x.RowKey = r.RowKey) inv
    OUTER APPLY (SELECT Paid = SUM(q.Amount),
                        Dates = STRING_AGG(CONVERT(NVARCHAR(10), q.PaymentDate, 103), N', ') WITHIN GROUP (ORDER BY q.PaymentDate),
                        Refs = STRING_AGG(q.Reference, N', ') WITHIN GROUP (ORDER BY q.PaymentDate)
                 FROM (SELECT p.Id, p.PaymentDate, Reference = NULLIF(p.Reference, N''), Amount = SUM(y.Amount)
                       FROM #Inv x
                       INNER JOIN #Pay y ON y.InvoiceId = x.InvoiceId
                       INNER JOIN purchase.Payments p ON p.Id = y.PaymentId
                       WHERE x.RowKey = r.RowKey
                       GROUP BY p.Id, p.PaymentDate, p.Reference) q) pay
    OUTER APPLY (SELECT Numbers = STRING_AGG(g.DocumentNumber, N', ') WITHIN GROUP (ORDER BY g.DocumentDate)
                 FROM purchase.GoodsReceipts g WHERE g.ContainerId = r.ContainerId AND g.Status = 2) grn
    -- the transport invoices of the container, at container level ("05/11/2025 · 2500323 · 10,000.00")
    OUTER APPLY (SELECT Refs = STRING_AGG(z.Reference, N', ') WITHIN GROUP (ORDER BY z.ChargeDate, z.Id),
                        Invoices = STRING_AGG(CONVERT(NVARCHAR(10), z.ChargeDate, 103) + ISNULL(N' · ' + z.Reference, N'')
                                              + N' · ' + FORMAT(z.AmountBase, N'N2', 'en-US'), N'; ')
                                   WITHIN GROUP (ORDER BY z.ChargeDate, z.Id)
                 FROM (SELECT ch.Id, ch.ChargeDate, Reference = NULLIF(ch.Reference, N''), ch.AmountBase
                       FROM logistics.ContainerCharges ch
                       WHERE @WithCharges = 1 AND ch.ContainerId = r.ContainerId AND ch.Status = 2
                         AND ch.ChargeTypeId IN (SELECT Id FROM @Transport)) z) tr
    OUTER APPLY (SELECT Amount = SUM(x.AmountBase) FROM #Ch x WHERE x.RowKey = r.RowKey AND x.ChargeTypeId IN (SELECT Id FROM @Transport)) trs
    OUTER APPLY (SELECT Amount = SUM(x.AmountBase) FROM #Ch x WHERE x.RowKey = r.RowKey) chs
    -- the stage (see the header, 2)
    CROSS APPLY (SELECT StageSort = CASE
                     WHEN c.Status IN (6, 7) THEN 90
                     WHEN act.MovementId IS NOT NULL AND act.IsVessel = 1 THEN 20
                     WHEN act.MovementId IS NOT NULL AND act.Stage = N'Port' THEN 30
                     WHEN act.MovementId IS NOT NULL AND act.IsStay = 1 THEN 50
                     WHEN act.MovementId IS NOT NULL AND act.FromKind = N'Sea' THEN 40
                     WHEN act.MovementId IS NOT NULL THEN 55
                     WHEN r.IsPending = 1 OR lst.MovementId IS NULL THEN 10
                     WHEN lst.Stage = N'Delivery' THEN 60
                     WHEN lst.ToKind = N'Sea' THEN 30
                     ELSE 50 END) s0
    CROSS APPLY (SELECT PendingMonth = CASE WHEN s0.StageSort = 10
                                            THEN ISNULL(c.OrderMonthKey, YEAR(po.DocumentDate) * 100 + MONTH(po.DocumentDate)) END) pm
    CROSS APPLY (SELECT StageSort = CASE WHEN s0.StageSort = 10 THEN 10 + (999999 - pm.PendingMonth) / 1000000.0
                                         ELSE CAST(s0.StageSort AS DECIMAL(12,6)) END,
                        StageLabel = CASE s0.StageSort
                            WHEN 90 THEN N'Offloaded in ' + COALESCE(j.DeliveredTo, w.WarehouseName, N'the warehouse')
                            WHEN 20 THEN N'In transit ' + ISNULL(act.FromName, N'?') + N' → ' + ISNULL(act.ToName, N'?')
                            WHEN 30 THEN ISNULL(CASE WHEN act.MovementId IS NOT NULL THEN act.ToName ELSE lst.ToName END, N'At port')
                            WHEN 50 THEN ISNULL(CASE WHEN act.MovementId IS NOT NULL THEN act.ToName ELSE lst.ToName END, N'At border / customs')
                            WHEN 40 THEN ISNULL(act.FromName, N'?') + N' → ' + ISNULL(act.ToName, N'?')
                            WHEN 55 THEN ISNULL(act.FromName, N'?') + N' → ' + ISNULL(act.ToName, N'?')
                            WHEN 60 THEN N'Delivered to ' + ISNULL(lst.ToName, N'?') + N', to receive'
                            ELSE N'Order pending - ' + DATENAME(MONTH, DATEFROMPARTS(pm.PendingMonth / 100, pm.PendingMonth % 100, 1))
                                 + N' ' + CAST(pm.PendingMonth / 100 AS NVARCHAR(4)) END) st
    ORDER BY st.StageSort, st.StageLabel, c.ContainerRef, po.DocumentDate, r.RowKey;

    /* ---------------------------------------------------------------- 2. the charges per type */
    SELECT RowKey, ChargeTypeId, AmountBase FROM #Ch ORDER BY RowKey, ChargeTypeId;

    /* ---------------------------------------------------------------- 3. the charge types */
    SELECT t.Id, t.ChargeCode, t.ChargeName,
           IsTransport = CAST(CASE WHEN t.Id IN (SELECT Id FROM @Transport) THEN 1 ELSE 0 END AS BIT),
           t.IsDeduction
    FROM purchase.ChargeTypes t
    WHERE @WithCharges = 1 AND (t.IsActive = 1 OR t.Id IN (SELECT ChargeTypeId FROM #Ch))
    ORDER BY t.Id;
END
GO

/* ================================================================== 2. Check */

-- The three collations: when the database's differs from the server's (testing's database since its restore), the
-- procedures above are the ones that needed this script.
SELECT DatabaseCollation = CAST(DATABASEPROPERTYEX(DB_NAME(), 'Collation') AS NVARCHAR(128)),
       ServerCollation   = CAST(SERVERPROPERTY('Collation') AS NVARCHAR(128)),
       TempdbCollation   = CAST(DATABASEPROPERTYEX(N'tempdb', 'Collation') AS NVARCHAR(128));

PRINT 'Script 114 applied: the temporary tables of 12 procedures take the database''s collation (COLLATE DATABASE_DEFAULT).';
GO
