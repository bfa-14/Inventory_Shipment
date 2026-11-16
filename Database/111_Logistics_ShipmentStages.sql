SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 111: LOGISTICS - SHIPMENT STAGES

   The owner: "the movement process is complicated". The purchasing team follows a few fixed stages - Pending,
   dispatched to Dar es Salaam, at port in Dar es Salaam, Dar es Salaam → Mokambo or Dar es Salaam → Lubumbashi (two
   routes, chosen by cost), offloaded in Lubumbashi - and updates its containers from the forwarder's list. So a
   container now moves by choosing its NEW STAGE; the movements are still made, behind it, by the movement procedures
   (every rule of scripts 80-83 holds: one leg at a time, from where it is, no date in the future or before the
   previous leg), and they are always started at once (never planned).

     1. logistics.ShipmentStages (NEW): the stages, kept by an administrator (Backoffice › Master Data › Shipment
        Stages), one of three kinds:
          1 Leg       a leg FromPlaceId → ToPlaceId of MovementTypeId, started on the stage's date. FromPlaceId NULL:
                      the container's port of loading (its first leg: "Dispatched to Dar es Salaam" from India or China)
          2 Arrive    the leg reaching ToPlaceId is completed ("At port Dar es Salaam")
          3 Offload   the container's last leg is completed - with one more leg of MovementTypeId to ToPlaceId, started
                      and completed on the same day, when it is not there yet (Mokambo → Lubumbashi) - and its goods
                      receipt is made and POSTED for the full quantity loaded ("Offloaded in Lubumbashi"). A short or
                      damaged container is the rare case: its goods receipt is cancelled and made again by hand.
        "Pending" is no row: a container that never moved. Customs is a charge, not a stage.
        Seeded once (step 111.ShipmentStages) on a database whose movements know Dar es Salaam and Lubumbashi.
     2. THE PERMISSIONS:
          masterdata.shipmentstages.manage  "Manage shipment stages" (Master Data, 1475)
          containers.movements.advanced     "Show Shipments, Movements and Tracking" (Containers, 1409): the three
                                            menus are hidden from everyone else (the owner's decision); the pages and
                                            their own permissions are unchanged, for an administrator's corrections.
        Not granted to any role here: the start-up sync gives every permission to the system roles.
     3. logistics.fn_Container_Stage (NEW): where a container stands, worked out from its movements and status - the
        stage whose leg it travels on, the Arrive stage of the place its last leg reached, the Offload stage once
        received (or delivered there and waiting for its goods receipt: ReceiptPending), Pending when it never moved,
        else "Not on a stage" (FitsStages 0: a route the stages do not describe).
     4. logistics.usp_ShipmentStage_Preview (NEW): what moving containers to a stage does to each - the action
        (StartLeg, Complete, CompleteThenDeliver, Deliver, Receive), or why it cannot, or that it is already there.
        logistics.usp_ShipmentStage_MatchNumbers (NEW): the containers of the forwarder's list, by container no. (each
        box of a "two boxes" no. too) or ref, the open ones first.
        logistics.usp_ShipmentStage_Check (NEW): how many containers stand at each stage, and the containers whose
        route the stages do not describe, with their legs - the list to decide on.
     5. Stage CRUD: logistics.usp_ShipmentStage_List / _Save / _Delete. masterdata.usp_Port_Delete and
        masterdata.usp_MovementType_Delete re-created from their last bodies: a place or type a stage names stays.
     6. logistics.usp_Container_Search re-created from script 108's body: + @StageId (a stage, 0 Pending, -1 not on a
        stage) and the row's StageId, StageName, StageReceiptPending.

   Errors: no new number (70000 validation, 70001 duplicate, 70004 changed by another user, 70006 not found, 69014 /
   70014 in use). Requires script 108 (Schema.sql runs it first). Idempotent.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'purchase.fn_Container_PaymentStatus') IS NULL OR OBJECT_ID(N'logistics.usp_Movement_AddLeg', N'P') IS NULL
    THROW 50000, 'Script 111 requires scripts 81 and 108: apply them first.', 1;
GO

/* ================================================================== 1. logistics.ShipmentStages */

IF OBJECT_ID(N'logistics.ShipmentStages', N'U') IS NULL
BEGIN
    CREATE TABLE logistics.ShipmentStages
    (
        Id             INT IDENTITY(1,1) NOT NULL,
        StageName      NVARCHAR(100) NOT NULL,
        Kind           TINYINT       NOT NULL,      -- 1 Leg | 2 Arrive | 3 Offload
        MovementTypeId INT           NULL,          -- Leg: the leg's type; Offload: the last leg's, when one is needed
        FromPlaceId    INT           NULL,          -- Leg only; NULL = the container's port of loading (its first leg)
        ToPlaceId      INT           NOT NULL,
        SortOrder      INT           NOT NULL CONSTRAINT DF_ShipmentStages_Sort DEFAULT (0),
        IsActive       BIT           NOT NULL CONSTRAINT DF_ShipmentStages_IsActive DEFAULT (1),
        CreatedAtUtc   DATETIME2(3)  NOT NULL CONSTRAINT DF_ShipmentStages_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy      INT           NULL,
        UpdatedAtUtc   DATETIME2(3)  NULL,
        UpdatedBy      INT           NULL,
        RowVersion     ROWVERSION    NOT NULL,
        CONSTRAINT PK_ShipmentStages PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_ShipmentStages_Name UNIQUE (StageName),
        CONSTRAINT CK_ShipmentStages_Kind CHECK (Kind IN (1, 2, 3)),
        CONSTRAINT CK_ShipmentStages_Type CHECK ((Kind = 2 AND MovementTypeId IS NULL) OR (Kind <> 2 AND MovementTypeId IS NOT NULL)),
        CONSTRAINT CK_ShipmentStages_From CHECK (Kind = 1 OR FromPlaceId IS NULL),
        CONSTRAINT FK_ShipmentStages_Type FOREIGN KEY (MovementTypeId) REFERENCES masterdata.MovementTypes (Id),
        CONSTRAINT FK_ShipmentStages_From FOREIGN KEY (FromPlaceId) REFERENCES masterdata.Ports (Id),
        CONSTRAINT FK_ShipmentStages_To FOREIGN KEY (ToPlaceId) REFERENCES masterdata.Ports (Id),
        CONSTRAINT FK_ShipmentStages_CreatedBy FOREIGN KEY (CreatedBy) REFERENCES security.Users (Id),
        CONSTRAINT FK_ShipmentStages_UpdatedBy FOREIGN KEY (UpdatedBy) REFERENCES security.Users (Id)
    );
    PRINT 'Created logistics.ShipmentStages';
END
GO

-- THE TEAM'S STAGES, ONCE: on a database whose places know Dar es Salaam and Lubumbashi (the one its movements use
-- most, else the first active one of that name). Mokambo's route only where the place exists. An administrator
-- changes them afterwards on the page; a database without these places gets none and its administrator adds them.
IF NOT EXISTS (SELECT 1 FROM inventory.OneTimeSteps WHERE StepCode = N'111.ShipmentStages')
BEGIN
    DECLARE @Dar INT = (SELECT TOP (1) p.Id FROM masterdata.Ports p WHERE p.PortName = N'Dar es Salaam'
                        ORDER BY (SELECT COUNT(*) FROM logistics.Movements m WHERE m.FromPlaceId = p.Id OR m.ToPlaceId = p.Id) DESC,
                                 p.IsActive DESC, p.Id);
    DECLARE @Lub INT = (SELECT TOP (1) p.Id FROM masterdata.Ports p WHERE p.PortName = N'Lubumbashi'
                        ORDER BY (SELECT COUNT(*) FROM logistics.Movements m WHERE m.FromPlaceId = p.Id OR m.ToPlaceId = p.Id) DESC,
                                 p.IsActive DESC, p.Id);
    DECLARE @Mok INT = (SELECT TOP (1) p.Id FROM masterdata.Ports p WHERE p.PortName = N'Mokambo'
                        ORDER BY (SELECT COUNT(*) FROM logistics.Movements m WHERE m.FromPlaceId = p.Id OR m.ToPlaceId = p.Id) DESC,
                                 p.IsActive DESC, p.Id);
    DECLARE @Sea INT = (SELECT Id FROM masterdata.MovementTypes WHERE TypeCode = N'SEA');
    DECLARE @Inland INT = (SELECT Id FROM masterdata.MovementTypes WHERE TypeCode = N'INLAND');
    DECLARE @Delivery INT = (SELECT Id FROM masterdata.MovementTypes WHERE TypeCode = N'DELIVERY');
    DECLARE @Seeded INT = 0;

    BEGIN TRANSACTION;
    IF @Dar IS NOT NULL AND @Lub IS NOT NULL AND @Sea IS NOT NULL AND @Delivery IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM logistics.ShipmentStages)
    BEGIN
        INSERT INTO logistics.ShipmentStages (StageName, Kind, MovementTypeId, FromPlaceId, ToPlaceId, SortOrder)
        VALUES (N'Dispatched to Dar es Salaam', 1, @Sea, NULL, @Dar, 10),
               (N'At port Dar es Salaam', 2, NULL, NULL, @Dar, 20);
        IF @Mok IS NOT NULL AND @Inland IS NOT NULL
            INSERT INTO logistics.ShipmentStages (StageName, Kind, MovementTypeId, FromPlaceId, ToPlaceId, SortOrder)
            VALUES (N'Dar es Salaam → Mokambo', 1, @Inland, @Dar, @Mok, 30);
        INSERT INTO logistics.ShipmentStages (StageName, Kind, MovementTypeId, FromPlaceId, ToPlaceId, SortOrder)
        VALUES (N'Dar es Salaam → Lubumbashi', 1, @Delivery, @Dar, @Lub, 40),
               (N'Offloaded in Lubumbashi', 3, @Delivery, NULL, @Lub, 50);
        SET @Seeded = (SELECT COUNT(*) FROM logistics.ShipmentStages);
    END
    INSERT INTO inventory.OneTimeSteps (StepCode, DoneAtUtc, Progress, Details)
    VALUES (N'111.ShipmentStages', SYSUTCDATETIME(), @Seeded, N'The shipment stages seeded once (none without Dar es Salaam and Lubumbashi).');
    COMMIT TRANSACTION;
    PRINT 'Shipment stages seeded: ' + CAST(@Seeded AS NVARCHAR(10)) + '.';
END
GO

/* ================================================================== 2. The permissions */

-- The texts are PermissionCatalog.cs's, so the start-up sync changes nothing.
MERGE security.Permissions AS target
USING (VALUES (N'masterdata.shipmentstages.manage', N'Manage shipment stages', N'Master Data',
               N'Define the stages a container moves through (Update stage…, the import of stages) and the leg each one records.',
               1475),
              (N'containers.movements.advanced', N'Show Shipments, Movements and Tracking', N'Containers',
               N'Show the Shipments, Movements and Tracking menus (hidden from everyone else: containers move by their stage).',
               1409)) AS source (Code, Name, Module, Description, SortOrder)
ON target.Code = source.Code
WHEN MATCHED AND (target.Name <> source.Name OR target.Module <> source.Module
                  OR ISNULL(target.Description, N'') <> source.Description OR target.SortOrder <> source.SortOrder) THEN
    UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Module, Description, SortOrder)
    VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder);
GO

/* ================================================================== 3. Where a container stands */

-- (111) ONE ROW PER CONTAINER. Its legs are its movements started or completed (planned and cancelled ones do not
-- count). The stage, the first that applies:
--   received (6, 7)                 the Offload stage of the place its last leg reached, else any Offload stage
--   a leg in progress               the Leg stage of the same type and To, from the same From - or from the port of
--                                   loading (FromPlaceId NULL) when it is its first leg
--   its last leg completed          the Arrive stage of that place, else its Offload stage (delivered, waiting for its
--                                   goods receipt: ReceiptPending)
--   no leg                          Pending (StageKind 0) - "Followed by typed dates" when its status moved without one
--   else                            "Not on a stage" (FitsStages 0)
-- Inactive stages still name where a container stands.
CREATE OR ALTER FUNCTION logistics.fn_Container_Stage (@ContainerId INT)
RETURNS TABLE
AS
RETURN
SELECT c.Id AS ContainerId,
       StageId = s.Id,
       StageName = CAST(CASE WHEN c.Status = 8 THEN NULL
                             WHEN s.Id IS NOT NULL THEN s.StageName
                             WHEN c.Status IN (6, 7) THEN N'Offloaded'
                             WHEN ISNULL(n.Cnt, 0) = 0 AND c.Status IN (1, 2) THEN N'Pending'
                             WHEN ISNULL(n.Cnt, 0) = 0 THEN N'Followed by typed dates'
                             ELSE N'Not on a stage' END AS NVARCHAR(100)),
       StageKind = CAST(CASE WHEN c.Status = 8 THEN NULL
                             WHEN s.Id IS NOT NULL THEN s.Kind
                             WHEN c.Status IN (6, 7) THEN 3
                             WHEN ISNULL(n.Cnt, 0) = 0 THEN 0 END AS TINYINT),
       FitsStages = CAST(CASE WHEN c.Status = 8 OR s.Id IS NOT NULL OR c.Status IN (6, 7) OR ISNULL(n.Cnt, 0) = 0
                              THEN 1 ELSE 0 END AS BIT),
       ReceiptPending = CAST(CASE WHEN s.Kind = 3 AND c.Status < 6 THEN 1 ELSE 0 END AS BIT),
       MovementCount = ISNULL(n.Cnt, 0),
       ActiveMovementId = act.Id, ActiveMovementNo = act.MovementNo, ActiveToPlaceId = act.ToPlaceId,
       -- where it stands: its last leg's To once arrived, its port of loading before its first leg, none while travelling
       PlaceId = CASE WHEN act.Id IS NOT NULL THEN NULL WHEN lst.Id IS NULL THEN c.PortOfLoadingId ELSE lst.ToPlaceId END,
       LastLegToPlaceId = lst.ToPlaceId,
       StageSince = CASE WHEN c.Status IN (6, 7) THEN c.OffloadedDate WHEN act.Id IS NOT NULL THEN act.StartDate ELSE lst.EndDate END
FROM logistics.Containers c
OUTER APPLY (SELECT Cnt = COUNT(*)
             FROM logistics.MovementContainers mc
             INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
             WHERE mc.ContainerId = c.Id AND m.Status IN (2, 3)) n
OUTER APPLY (SELECT TOP (1) m.Id, m.MovementNo, m.MovementTypeId, m.FromPlaceId, m.ToPlaceId, m.StartDate
             FROM logistics.MovementContainers mc
             INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
             WHERE mc.ContainerId = c.Id AND m.Status = 2
             ORDER BY m.Id DESC) act
OUTER APPLY (SELECT TOP (1) m.Id, m.ToPlaceId, m.EndDate
             FROM logistics.MovementContainers mc
             INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
             WHERE mc.ContainerId = c.Id AND m.Status IN (2, 3)
             ORDER BY m.Id DESC) lst
OUTER APPLY (SELECT TOP (1) st.Id, st.StageName, st.Kind
             FROM logistics.ShipmentStages st
             WHERE c.Status <> 8
               AND ((c.Status IN (6, 7) AND st.Kind = 3)
                    OR (c.Status < 6 AND act.Id IS NOT NULL AND st.Kind = 1 AND st.MovementTypeId = act.MovementTypeId
                        AND st.ToPlaceId = act.ToPlaceId
                        AND (st.FromPlaceId = act.FromPlaceId OR (st.FromPlaceId IS NULL AND n.Cnt = 1)))
                    OR (c.Status < 6 AND act.Id IS NULL AND lst.Id IS NOT NULL AND st.Kind IN (2, 3) AND st.ToPlaceId = lst.ToPlaceId))
             ORDER BY CASE WHEN st.ToPlaceId = lst.ToPlaceId THEN 0 ELSE 1 END,
                      CASE WHEN st.Kind = 2 THEN 0 ELSE 1 END,
                      CASE WHEN st.FromPlaceId IS NOT NULL THEN 0 ELSE 1 END,
                      st.IsActive DESC, st.SortOrder, st.Id) s
WHERE c.Id = @ContainerId;
GO

/* ================================================================== 4. Moving containers to a stage: what it does */

-- (111) ONE ROW PER ID ASKED (an unknown one too, Found 0). Action, when the container can go to the stage:
--   StartLeg              a Leg stage: the leg from where it stands
--   Complete              an Arrive stage, or an Offload stage reached by the leg it travels on: that leg is completed
--   CompleteThenDeliver   an Offload stage whose place its leg does not reach (Mokambo): completed, then the last leg
--   Deliver               an Offload stage, arrived elsewhere: the last leg, started and completed
--   Receive               an Offload stage, delivered there already: only its goods receipt
-- Reason says why it cannot (NULL when it can); AlreadyThere marks a container already at the stage (skipped, not
-- refused). The dates are the movement procedures' to judge (no future, never before the previous leg).
CREATE OR ALTER PROCEDURE logistics.usp_ShipmentStage_Preview
    @StageId      INT,
    @ContainerIds logistics.tvp_IdList READONLY,
    @CanConfirm   BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Kind TINYINT, @FromId INT, @ToId INT, @Active BIT, @FromName NVARCHAR(100), @ToName NVARCHAR(100);
    SELECT @Kind = s.Kind, @FromId = s.FromPlaceId, @ToId = s.ToPlaceId, @Active = s.IsActive,
           @FromName = fp.PortName, @ToName = tp.PortName
    FROM logistics.ShipmentStages s
    LEFT JOIN masterdata.Ports fp ON fp.Id = s.FromPlaceId
    LEFT JOIN masterdata.Ports tp ON tp.Id = s.ToPlaceId
    WHERE s.Id = @StageId;
    IF @Kind IS NULL THROW 70006, 'Shipment stage not found.', 1;
    IF @Active = 0 THROW 70000, 'This stage is inactive: an administrator may turn it on again in Shipment Stages.', 1;

    SELECT ContainerId = x.Id,
           Found = CAST(CASE WHEN c.Id IS NULL THEN 0 ELSE 1 END AS BIT),
           c.ContainerRef, c.ContainerNo, ContainerStatus = c.Status,
           IsDraft = CAST(CASE WHEN c.Status = 1 THEN 1 ELSE 0 END AS BIT),
           CurrentStageId = st.StageId, CurrentStageName = st.StageName,
           Action = CASE WHEN r.Reason IS NULL THEN a.Action END,
           CanMove = CAST(CASE WHEN r.Reason IS NULL THEN 1 ELSE 0 END AS BIT),
           AlreadyThere = t.AlreadyThere,
           r.Reason,
           MovementId = st.ActiveMovementId, MovementNo = st.ActiveMovementNo,
           MovementContainerCount = (SELECT COUNT(*) FROM logistics.MovementContainers mc WHERE mc.MovementId = st.ActiveMovementId),
           st.PlaceId, PlaceName = pp.PortName,
           WarehouseCode = w.WarehouseCode,
           ReceiveWarning = CASE WHEN @Kind = 3 AND r.Reason IS NULL AND c.WarehouseId IS NULL
                                 THEN N'No warehouse on the container: its goods receipt will wait for one.' END
    FROM @ContainerIds x
    LEFT JOIN logistics.Containers c ON c.Id = x.Id
    OUTER APPLY logistics.fn_Container_Stage(c.Id) st
    LEFT JOIN masterdata.Ports pp ON pp.Id = st.PlaceId
    LEFT JOIN masterdata.Ports ap ON ap.Id = st.ActiveToPlaceId
    LEFT JOIN masterdata.Warehouses w ON w.Id = c.WarehouseId
    CROSS APPLY (SELECT AlreadyThere = CAST(CASE WHEN c.Status <> 8
                                                  AND ((st.StageId = @StageId AND st.ReceiptPending = 0)
                                                       OR (@Kind = 3 AND c.Status IN (6, 7))) THEN 1 ELSE 0 END AS BIT)) t
    CROSS APPLY (SELECT Action = CAST(CASE @Kind
                     WHEN 1 THEN N'StartLeg'
                     WHEN 2 THEN N'Complete'
                     ELSE CASE WHEN st.ActiveMovementId IS NOT NULL
                               THEN CASE WHEN st.ActiveToPlaceId = @ToId THEN N'Complete' ELSE N'CompleteThenDeliver' END
                               WHEN st.LastLegToPlaceId = @ToId THEN N'Receive'
                               ELSE N'Deliver' END END AS NVARCHAR(20))) a
    CROSS APPLY (SELECT Reason = CAST(CASE
                     WHEN c.Id IS NULL THEN N'Container not found.'
                     WHEN c.Status = 8 THEN N'It is cancelled.'
                     WHEN t.AlreadyThere = 1 THEN N'Already at this stage.'
                     WHEN c.Status IN (6, 7) THEN N'Its goods are received: its journey is over.'
                     -- a Leg stage
                     WHEN @Kind = 1 AND st.ActiveMovementId IS NOT NULL
                         THEN N'It is on its way (' + st.StageName + N', ' + st.ActiveMovementNo + N'): record its arrival first.'
                     WHEN @Kind = 1 AND st.ReceiptPending = 1
                         THEN N'It is delivered and waits for its goods receipt: choose ' + st.StageName + N'.'
                     WHEN @Kind = 1 AND @FromId IS NULL AND st.MovementCount > 0 THEN N'It has already left its port of loading.'
                     WHEN @Kind = 1 AND @FromId IS NULL AND c.PortOfLoadingId IS NULL
                         THEN N'It has no port of loading: set it on the container first.'
                     WHEN @Kind = 1 AND @FromId IS NOT NULL AND st.MovementCount = 0
                         THEN N'It is not dispatched yet: it leaves from ' + @FromName + N' only after it got there.'
                     WHEN @Kind = 1 AND @FromId IS NOT NULL AND ISNULL(st.PlaceId, -1) <> @FromId
                         THEN N'It is at ' + ISNULL(pp.PortName, N'another place') + N', not at ' + @FromName + N'.'
                     WHEN @Kind = 1 AND c.Status = 1 AND @CanConfirm = 0
                         THEN N'It is a draft: someone who may confirm containers must confirm it first.'
                     -- an Arrive stage
                     WHEN @Kind = 2 AND st.MovementCount = 0 THEN N'It is not dispatched yet.'
                     WHEN @Kind = 2 AND st.ActiveMovementId IS NULL
                         THEN N'It is not on its way to ' + @ToName + N': it is at ' + ISNULL(pp.PortName, N'another place') + N'.'
                     WHEN @Kind = 2 AND st.ActiveToPlaceId <> @ToId
                         THEN N'It is on its way to ' + ISNULL(ap.PortName, N'another place') + N', not to ' + @ToName + N'.'
                     -- an Offload stage
                     WHEN @Kind = 3 AND st.MovementCount = 0 THEN N'It is not dispatched yet.'
                     END AS NVARCHAR(400))) r
    ORDER BY c.ContainerRef, x.Id;
END
GO

-- (111) THE FORWARDER'S LIST: one row per number given (RowNo kept), the container it names - by container no. (each
-- box of "MRSU8190808 , CAAU9368456" too) or by ref, spaces, dashes, dots and slashes ignored; an open container
-- before a received or cancelled one. Matches > 1 among the open ones: found twice, none chosen.
CREATE OR ALTER PROCEDURE logistics.usp_ShipmentStage_MatchNumbers
    @Numbers logistics.tvp_TextList READONLY
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Rows TABLE (RowNo INT NOT NULL PRIMARY KEY, InputNumber NVARCHAR(100) NULL, NumberKey NVARCHAR(100) NOT NULL);
    INSERT INTO @Rows (RowNo, InputNumber, NumberKey)
    SELECT n.RowNo, LTRIM(RTRIM(n.Value)), k.NumberKey
    FROM @Numbers n
    CROSS APPLY logistics.fn_ContainerNumberKey(n.Value) k;

    DECLARE @Hits TABLE (RowNo INT NOT NULL, ContainerId INT NOT NULL, Rank TINYINT NOT NULL, PRIMARY KEY (RowNo, ContainerId));
    INSERT INTO @Hits (RowNo, ContainerId, Rank)
    SELECT DISTINCT r.RowNo, c.Id, CASE WHEN c.Status < 6 THEN 1 WHEN c.Status IN (6, 7) THEN 2 ELSE 3 END
    FROM @Rows r
    INNER JOIN (SELECT c.Id, c.Status, k.NumberKey
                FROM logistics.Containers c
                CROSS APPLY (SELECT c.ContainerRef AS V UNION ALL SELECT c.ContainerNo
                             UNION ALL SELECT LTRIM(RTRIM(b.value)) FROM STRING_SPLIT(c.ContainerNo, N',') b
                             WHERE c.ContainerNo LIKE N'%,%') v
                CROSS APPLY logistics.fn_ContainerNumberKey(v.V) k
                WHERE k.NumberKey <> N'') c ON c.NumberKey = r.NumberKey
    WHERE r.NumberKey <> N'';

    SELECT r.RowNo, r.InputNumber,
           ContainerId = CASE WHEN b.Cnt = 1 THEN b.ContainerId END,
           ContainerRef = CASE WHEN b.Cnt = 1 THEN c.ContainerRef END,
           ContainerNo = CASE WHEN b.Cnt = 1 THEN c.ContainerNo END,
           Matches = ISNULL(b.Cnt, 0)
    FROM @Rows r
    OUTER APPLY (SELECT Cnt = COUNT(*), ContainerId = MIN(h.ContainerId)
                 FROM @Hits h
                 WHERE h.RowNo = r.RowNo AND h.Rank = (SELECT MIN(h2.Rank) FROM @Hits h2 WHERE h2.RowNo = r.RowNo)) b
    LEFT JOIN logistics.Containers c ON c.Id = b.ContainerId AND b.Cnt = 1
    ORDER BY r.RowNo;
END
GO

-- (111) THE CHECK: 1. how many containers (not cancelled) stand at each stage; 2. the ones whose route the stages do
-- not describe, with their legs ("Sea freight Chennai → Dar es Salaam (completed) | ..."), to decide on.
CREATE OR ALTER PROCEDURE logistics.usp_ShipmentStage_Check
AS
BEGIN
    SET NOCOUNT ON;
    SELECT st.StageId, st.StageName, st.StageKind, st.FitsStages, Containers = COUNT(*),
           SortOrder = MIN(s.SortOrder)
    FROM logistics.Containers c
    CROSS APPLY logistics.fn_Container_Stage(c.Id) st
    LEFT JOIN logistics.ShipmentStages s ON s.Id = st.StageId
    WHERE c.Status <> 8
    GROUP BY st.StageId, st.StageName, st.StageKind, st.FitsStages
    ORDER BY CASE WHEN st.StageKind = 0 THEN 0 WHEN st.FitsStages = 0 THEN 2 ELSE 1 END, MIN(s.SortOrder), st.StageName;

    SELECT ContainerId = c.Id, c.ContainerRef, c.ContainerNo, ContainerStatus = c.Status,
           Legs = (SELECT STRING_AGG(CAST(mt.TypeName + N' ' + fp.PortName
                                          + CASE WHEN m.FromPlaceId = m.ToPlaceId THEN N'' ELSE N' → ' + tp.PortName END
                                          + CASE m.Status WHEN 2 THEN N' (in progress)' ELSE N'' END AS NVARCHAR(MAX)), N' | ')
                          WITHIN GROUP (ORDER BY m.Id)
                   FROM logistics.MovementContainers mc
                   INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
                   INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
                   INNER JOIN masterdata.Ports fp ON fp.Id = m.FromPlaceId
                   INNER JOIN masterdata.Ports tp ON tp.Id = m.ToPlaceId
                   WHERE mc.ContainerId = c.Id AND m.Status IN (2, 3))
    FROM logistics.Containers c
    CROSS APPLY logistics.fn_Container_Stage(c.Id) st
    WHERE c.Status <> 8 AND st.FitsStages = 0
    ORDER BY c.ContainerRef;
END
GO

/* ================================================================== 5. The stages: list, save, delete */

CREATE OR ALTER PROCEDURE logistics.usp_ShipmentStage_List
    @ActiveOnly BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SELECT s.Id, s.StageName, s.Kind, s.MovementTypeId, MovementTypeName = mt.TypeName, MovementTypeStage = mt.Stage,
           s.FromPlaceId, FromPlaceName = fp.PortName, s.ToPlaceId, ToPlaceName = tp.PortName,
           s.SortOrder, s.IsActive, s.RowVersion
    FROM logistics.ShipmentStages s
    LEFT JOIN masterdata.MovementTypes mt ON mt.Id = s.MovementTypeId
    LEFT JOIN masterdata.Ports fp ON fp.Id = s.FromPlaceId
    INNER JOIN masterdata.Ports tp ON tp.Id = s.ToPlaceId
    WHERE @ActiveOnly = 0 OR s.IsActive = 1
    ORDER BY s.SortOrder, s.StageName;
END
GO

CREATE OR ALTER PROCEDURE logistics.usp_ShipmentStage_Save
    @Id             INT           = NULL,
    @StageName      NVARCHAR(100),
    @Kind           TINYINT,
    @MovementTypeId INT           = NULL,
    @FromPlaceId    INT           = NULL,
    @ToPlaceId      INT,
    @SortOrder      INT           = 0,
    @IsActive       BIT           = 1,
    @RowVersion     BINARY(8)     = NULL,
    @UserId         INT           = NULL,
    @NewId          INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @StageName = NULLIF(LTRIM(RTRIM(@StageName)), N'');
    IF @StageName IS NULL THROW 70000, 'The stage name is required.', 1;
    IF @Kind IS NULL OR @Kind NOT IN (1, 2, 3) THROW 70000, 'Choose what the stage does: a leg, an arrival or the offload.', 1;
    IF @ToPlaceId IS NULL OR NOT EXISTS (SELECT 1 FROM masterdata.Ports WHERE Id = @ToPlaceId)
        THROW 70000, 'Choose the place the stage reaches.', 1;
    IF @Kind = 2 SELECT @MovementTypeId = NULL, @FromPlaceId = NULL;
    IF @Kind = 3 SET @FromPlaceId = NULL;
    IF @Kind <> 2 AND (@MovementTypeId IS NULL OR NOT EXISTS (SELECT 1 FROM masterdata.MovementTypes WHERE Id = @MovementTypeId))
        THROW 70000, 'Choose the movement type the stage records.', 1;
    IF @FromPlaceId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Ports WHERE Id = @FromPlaceId)
        THROW 70000, 'The place the stage leaves from was not found.', 1;
    IF EXISTS (SELECT 1 FROM logistics.ShipmentStages WHERE StageName = @StageName AND (@Id IS NULL OR Id <> @Id))
        THROW 70001, 'A stage of this name already exists.', 1;

    IF @Id IS NULL
    BEGIN
        INSERT INTO logistics.ShipmentStages (StageName, Kind, MovementTypeId, FromPlaceId, ToPlaceId, SortOrder, IsActive, CreatedBy)
        VALUES (@StageName, @Kind, @MovementTypeId, @FromPlaceId, @ToPlaceId, ISNULL(@SortOrder, 0), ISNULL(@IsActive, 1), @UserId);
        SET @NewId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM logistics.ShipmentStages WHERE Id = @Id) THROW 70006, 'Shipment stage not found.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.ShipmentStages WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 70004, 'This stage was changed by another user. Reload the page and try again.', 1;
        UPDATE logistics.ShipmentStages
        SET StageName = @StageName, Kind = @Kind, MovementTypeId = @MovementTypeId, FromPlaceId = @FromPlaceId,
            ToPlaceId = @ToPlaceId, SortOrder = ISNULL(@SortOrder, 0), IsActive = ISNULL(@IsActive, 1),
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;
        SET @NewId = @Id;
    END
END
GO

-- A stage owns nothing: the movements it made stay, and where a container stands is worked out again.
CREATE OR ALTER PROCEDURE logistics.usp_ShipmentStage_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM logistics.ShipmentStages WHERE Id = @Id) THROW 70006, 'Shipment stage not found.', 1;
    DELETE FROM logistics.ShipmentStages WHERE Id = @Id;
END
GO

-- Re-created (111) from its last body: a place a shipment stage names stays too.
CREATE OR ALTER PROCEDURE masterdata.usp_Port_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Ports WHERE Id = @Id) THROW 69006, 'Port not found.', 1;
    IF EXISTS (SELECT 1 FROM logistics.Containers WHERE PortOfLoadingId = @Id OR PortOfDestinationId = @Id OR FinalDestinationId = @Id)
       OR EXISTS (SELECT 1 FROM logistics.Movements WHERE FromPlaceId = @Id OR ToPlaceId = @Id)
       OR EXISTS (SELECT 1 FROM logistics.ShipmentStages WHERE FromPlaceId = @Id OR ToPlaceId = @Id)
        THROW 69014, 'This place is used by containers, movements or shipment stages and cannot be deleted. Deactivate it instead.', 1;
    DELETE FROM masterdata.Ports WHERE Id = @Id;
END
GO

-- Re-created (111) from its last body: a movement type a shipment stage records stays too.
CREATE OR ALTER PROCEDURE masterdata.usp_MovementType_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.MovementTypes WHERE Id = @Id) THROW 70006, 'Movement type not found.', 1;
    IF EXISTS (SELECT 1 FROM logistics.Movements WHERE MovementTypeId = @Id)
       OR EXISTS (SELECT 1 FROM logistics.ShipmentStages WHERE MovementTypeId = @Id)
        THROW 70014, 'This movement type is used by movements or shipment stages and cannot be deleted. Deactivate it instead.', 1;
    DELETE FROM masterdata.MovementTypes WHERE Id = @Id;
END
GO

/* ================================================================== 6. The containers list by stage */

-- Re-created (111) from the body of script 108: + @StageId (a stage's Id, 0 Pending or followed by typed dates, -1 not
-- on a stage) and the row's StageId, StageName, StageReceiptPending (fn_Container_Stage). Every other column, filter
-- and sort is unchanged.
CREATE OR ALTER PROCEDURE logistics.usp_Container_Search
    @Search              NVARCHAR(100) = NULL,   -- ref, container no., B/L, vessel, PO / PI no., commercial invoice, supplier
    @ContainerRef        NVARCHAR(30)  = NULL,
    @ContainerNo         NVARCHAR(30)  = NULL,
    @SupplierId          INT           = NULL,
    @PurchaseDocumentId  INT           = NULL,   -- a purchase ORDER or a purchase INVOICE linked to the container
    @PurchaseOrderId     INT           = NULL,   -- containers carrying lines of this order
    @CommercialInvoiceNo NVARCHAR(50)  = NULL,
    @ItemId              INT           = NULL,
    @BlNo                NVARCHAR(30)  = NULL,
    @Status              TINYINT       = NULL,
    @PortId              INT           = NULL,
    @WarehouseId         INT           = NULL,
    @BranchId            INT           = NULL,
    @MovementId          INT           = NULL,   -- containers of this movement
    @OrderMonthKey       INT           = NULL,   -- e.g. 202601
    @DateFrom            DATE          = NULL,   -- order date
    @DateTo              DATE          = NULL,
    @SortColumn          NVARCHAR(30)  = N'OrderDate',  -- ContainerRef | ContainerNo | OrderDate | DispatchDate | Eta | Status | CreatedAtUtc
    @SortDirection       NVARCHAR(4)   = N'DESC',
    @PageNumber          INT           = 1,
    @PageSize            INT           = 10,
    @DeliveredNotReceived BIT          = 0,      -- (65) 1 = delivered (or with a draft receipt) and not received yet
    @NextStep            NVARCHAR(20)  = NULL,   -- (81) Ship | StartPlanned | Complete | NextLeg | Receive (the to-do list)
    @Journey             NVARCHAR(20)  = NULL,   -- (95) NotDispatched | OnTheWay | Arrived | Received (fn_Container_Journey)
    @PaymentStatus       NVARCHAR(20)  = NULL,   -- (108) Unpaid | Partial | Paid | NotInvoiced (fn_Container_PaymentStatus)
    @StageId             INT           = NULL    -- (111) a shipment stage; 0 Pending (never moved), -1 not on a stage
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    -- (78) PAGES OF UP TO 5,000 (200 before): every container's figures are worked out before the OFFSET, so each page
    -- costs about the whole search - the 2,000 containers of one order took ten calls of 2 s each. The order's Containers
    -- card and a movement's list now ask for them in one page; the grids keep asking for pages of 200 or less.
    -- (81) Since the page is found first (step 1), only the page's rows are worked out; the cap stays.
    IF @PageSize > 5000 SET @PageSize = 5000;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @ContainerRef = NULLIF(LTRIM(RTRIM(@ContainerRef)), N'');
    SET @ContainerNo = NULLIF(LTRIM(RTRIM(@ContainerNo)), N'');
    SET @CommercialInvoiceNo = NULLIF(LTRIM(RTRIM(@CommercialInvoiceNo)), N'');
    SET @BlNo = NULLIF(LTRIM(RTRIM(@BlNo)), N'');
    SET @NextStep = NULLIF(LTRIM(RTRIM(@NextStep)), N'');
    SET @Journey = NULLIF(LTRIM(RTRIM(@Journey)), N'');
    SET @PaymentStatus = NULLIF(LTRIM(RTRIM(@PaymentStatus)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'ContainerRef', N'ContainerNo', N'OrderDate', N'DispatchDate', N'Eta', N'Status', N'CreatedAtUtc')
        SET @SortColumn = N'OrderDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);

    -- (81) 1. THE PAGE FIRST: the filters and the order of before, on what they read only (the container, who received
    -- it, its latest Delivery, its next step for @NextStep), then every figure of the list for the page's rows only.
    -- They were worked out for every container before the OFFSET: 9.5 s a page on 50,000 containers. RECOMPILE: an
    -- empty filter costs nothing (the next step of every container is read only for @NextStep, the latest Delivery
    -- only for @DeliveredNotReceived).
    CREATE TABLE #Pg (Ord INT NOT NULL PRIMARY KEY, Id INT NOT NULL, TotalCount INT NOT NULL);
    INSERT INTO #Pg (Ord, Id, TotalCount)
    SELECT Ord = ROW_NUMBER() OVER (ORDER BY
        -- (78) a ref sorts by its length first: KTG-2026-9999 before KTG-2026-10000 (numbers past NumberLength)
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'ContainerRef' THEN LEN(c.ContainerRef) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'ContainerRef' THEN LEN(c.ContainerRef) END DESC,
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'ContainerRef' THEN c.ContainerRef WHEN N'ContainerNo' THEN c.ContainerNo END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'ContainerRef' THEN c.ContainerRef WHEN N'ContainerNo' THEN c.ContainerNo END END DESC,
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'OrderDate' THEN c.OrderDate WHEN N'DispatchDate' THEN c.DispatchDate WHEN N'Eta' THEN c.Eta END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'OrderDate' THEN c.OrderDate WHEN N'DispatchDate' THEN c.DispatchDate WHEN N'Eta' THEN c.Eta END END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Status' THEN CAST(c.Status AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Status' THEN CAST(c.Status AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN c.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN c.CreatedAtUtc END DESC,
        c.OrderDate DESC, c.Id DESC), c.Id, COUNT(*) OVER ()
    FROM logistics.Containers c
    -- one row each for a container: OUTER, so that the ones a filter does not read are not read at all
    OUTER APPLY logistics.fn_Container_ReceivedBy(c.Id) rb
    OUTER APPLY logistics.fn_Container_LastDelivery(c.Id) dl
    OUTER APPLY logistics.fn_Container_ShipState(c.Id) ss
    OUTER APPLY logistics.fn_Container_NextStepKind(c.Id, c.Status, ss.MovementCount, ss.ActiveMovementId, ss.PlannedMovementId,
                                                    NULL, ss.LastMovementId, dl.MovementId, rb.GoodsReceiptStatus) nk
    OUTER APPLY logistics.fn_Container_Journey(c.Id) jr                 -- (95) read only for @Journey
    OUTER APPLY purchase.fn_Container_PaymentStatus(c.Id) pys           -- (108) read only for @PaymentStatus
    OUTER APPLY (SELECT f.StageId, f.StageKind, f.FitsStages
                 FROM logistics.fn_Container_Stage(c.Id) f WHERE @StageId IS NOT NULL) stf   -- (111) read only for @StageId
    WHERE (@Search IS NULL OR c.ContainerRef LIKE N'%' + @Search + N'%' OR c.ContainerNo LIKE N'%' + @Search + N'%'
           OR c.BlNo LIKE N'%' + @Search + N'%' OR c.VesselName LIKE N'%' + @Search + N'%'
           OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                      INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                      INNER JOIN masterdata.Parties sp        ON sp.Id = d.SupplierId
                      WHERE cl.ContainerId = c.Id AND (d.DocumentNumber LIKE N'%' + @Search + N'%' OR sp.PartyName LIKE N'%' + @Search + N'%'))
           OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                      INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
                      INNER JOIN purchase.PurchaseDocuments d        ON d.Id = pil.DocumentId
                      WHERE cl.ContainerId = c.Id AND d.Status <> 3
                        AND (d.DocumentNumber LIKE N'%' + @Search + N'%' OR d.CommercialInvoiceNo LIKE N'%' + @Search + N'%'
                             OR d.ExporterReference LIKE N'%' + @Search + N'%')))
      AND (@ContainerRef IS NULL OR c.ContainerRef LIKE N'%' + @ContainerRef + N'%')
      AND (@ContainerNo IS NULL OR c.ContainerNo LIKE N'%' + @ContainerNo + N'%')
      AND (@BlNo IS NULL OR c.BlNo LIKE N'%' + @BlNo + N'%')
      AND (@Status IS NULL OR c.Status = @Status)
      AND (@BranchId IS NULL OR c.BranchId = @BranchId)
      AND (@WarehouseId IS NULL OR c.WarehouseId = @WarehouseId)
      AND (@PortId IS NULL OR c.PortOfLoadingId = @PortId OR c.PortOfDestinationId = @PortId OR c.FinalDestinationId = @PortId)
      AND (@OrderMonthKey IS NULL OR c.OrderMonthKey = @OrderMonthKey)
      AND (@DateFrom IS NULL OR c.OrderDate >= @DateFrom)
      AND (@DateTo IS NULL OR c.OrderDate <= @DateTo)
      AND (@SupplierId IS NULL OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                                          INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                                          WHERE cl.ContainerId = c.Id AND d.SupplierId = @SupplierId))
      AND (@PurchaseOrderId IS NULL OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl WHERE cl.ContainerId = c.Id AND cl.PurchaseOrderId = @PurchaseOrderId))
      AND (@PurchaseDocumentId IS NULL
           OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl WHERE cl.ContainerId = c.Id AND cl.PurchaseOrderId = @PurchaseDocumentId)
           OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                      INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
                      WHERE cl.ContainerId = c.Id AND pil.DocumentId = @PurchaseDocumentId))
      AND (@CommercialInvoiceNo IS NULL OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                                                   INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
                                                   INNER JOIN purchase.PurchaseDocuments d        ON d.Id = pil.DocumentId
                                                   WHERE cl.ContainerId = c.Id AND d.Status <> 3
                                                     AND d.CommercialInvoiceNo LIKE N'%' + @CommercialInvoiceNo + N'%'))
      AND (@ItemId IS NULL OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl WHERE cl.ContainerId = c.Id AND cl.ItemId = @ItemId))
      AND (@MovementId IS NULL OR EXISTS (SELECT 1 FROM logistics.MovementContainers mc WHERE mc.ContainerId = c.Id AND mc.MovementId = @MovementId))
      AND (ISNULL(@DeliveredNotReceived, 0) = 0
           OR (c.Status BETWEEN 2 AND 5 AND ISNULL(rb.ReceivedBy, N'') <> N'GRN'
               AND (dl.MovementId IS NOT NULL OR rb.GoodsReceiptStatus = 1)))
      AND (@NextStep IS NULL OR nk.Kind = @NextStep                                     -- (81) the to-do list
           OR (@NextStep = N'Receive' AND nk.Kind = N'OpenReceipt'))
      AND (@Journey IS NULL OR jr.JourneyStatus = @Journey)                       -- (95)
      AND (@PaymentStatus IS NULL OR pys.PaymentStatus = @PaymentStatus)          -- (108)
      AND (@StageId IS NULL                                                       -- (111)
           OR (@StageId > 0 AND stf.StageId = @StageId)
           OR (@StageId = 0 AND stf.StageKind = 0)
           OR (@StageId = -1 AND stf.FitsStages = 0))
    ORDER BY Ord
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY
    OPTION (RECOMPILE);

    -- 2. the list's figures, for the page's rows. Why a planned movement cannot start yet (fn_Movement_StartBlock) is
    -- read once per planned movement of the page, apart: read through each row's ship state it cost seconds a page.
    SELECT p.MovementId, b.Reason, b.StartNotBefore
    INTO #Sb
    FROM (SELECT DISTINCT MovementId = ss.PlannedMovementId
          FROM #Pg pg CROSS APPLY logistics.fn_Container_ShipState(pg.Id) ss
          WHERE ss.PlannedMovementId IS NOT NULL) p
    CROSS APPLY logistics.fn_Movement_StartBlock(p.MovementId) b;

    SELECT c.Id, c.ContainerRef, c.ContainerNo, ct.TypeCode AS ContainerTypeCode, ct.TypeName AS ContainerTypeName,
           c.OrderDate, c.OrderMonthKey, OrderMonth = FORMAT(c.OrderDate, N'MMM-yyyy', N'en-US'),
           c.BranchId, b.BranchCode, b.BranchName, c.WarehouseId, w.WarehouseCode, w.WarehouseName,
           c.PurchaseOrderId, mpo.DocumentNumber AS PurchaseOrderNumber,
           OrderCount = ISNULL(po.OrderCount, 0),
           OrderNumbers = CASE WHEN ISNULL(po.OrderCount, 0) = 0 THEN NULL
                               WHEN po.OrderCount = 1 THEN po.FirstOrder
                               ELSE po.FirstOrder + N' +' + CAST(po.OrderCount - 1 AS NVARCHAR(10)) END,
           SupplierCount = ISNULL(po.SupplierCount, 0),
           SupplierNames = CASE WHEN ISNULL(po.SupplierCount, 0) = 0 THEN NULL
                                WHEN po.SupplierCount = 1 THEN po.FirstSupplier
                                ELSE po.FirstSupplier + N' +' + CAST(po.SupplierCount - 1 AS NVARCHAR(10)) END,
           InvoiceCount = ISNULL(inv.InvoiceCount, 0),
           InvoiceNumbers = CASE WHEN ISNULL(inv.InvoiceCount, 0) = 0 THEN NULL
                                 WHEN inv.InvoiceCount = 1 THEN inv.FirstInvoice
                                 ELSE inv.FirstInvoice + N' +' + CAST(inv.InvoiceCount - 1 AS NVARCHAR(10)) END,
           CommercialInvoiceNos = CASE WHEN inv.CiCount = 1 THEN inv.FirstCi
                                       WHEN inv.CiCount > 1 THEN inv.FirstCi + N' +' + CAST(inv.CiCount - 1 AS NVARCHAR(10)) END,
           ExporterReferences = CASE WHEN inv.ErCount = 1 THEN inv.FirstEr
                                     WHEN inv.ErCount > 1 THEN inv.FirstEr + N' +' + CAST(inv.ErCount - 1 AS NVARCHAR(10)) END,
           ItemCount = ISNULL(ln.ItemCount, 0),
           ItemSummary = CASE WHEN ISNULL(ln.ItemCount, 0) = 0 THEN NULL
                              WHEN ln.ItemCount = 1 THEN ln.FirstItem
                              ELSE N'Mixed - ' + CAST(ln.ItemCount AS NVARCHAR(10)) + N' items' END,
           TotalQtyBase = ISNULL(ln.Qty, 0),
           InvoicedQtyBase = ISNULL(inv.PostedQty, 0),
           InvoicingStatus = CASE WHEN ISNULL(inv.PostedQty, 0) = 0 THEN 0
                                  WHEN inv.PostedQty >= ISNULL(ln.Qty, 0) THEN 2 ELSE 1 END,     -- 0 none, 1 partly, 2 fully (posted)
           TotalReceivedBase = c.TotalReceivedBase, c.TotalOilQty,
           fl.FillPct, fl.CapacityKnown, fl.MissingContainerUnitItems, fl.RemainingPcs, fl.IsOverCapacity,
           c.BlNo, c.BlDate, c.DispatchDate, c.Eta, c.ActualPortArrival, c.CustomsReleaseDate, c.OffloadedDate,
           c.FreeDays, c.LastFreeDay,
           DaysAtPort = CASE WHEN c.ActualPortArrival IS NOT NULL      -- (65) up to the receipt, else the Delivery, else today
                             THEN DATEDIFF(DAY, c.ActualPortArrival, COALESCE(c.OffloadedDate, dl.EndDate, CAST(SYSUTCDATETIME() AS DATE))) END,
           c.CurrentLocation, c.Status, c.StatusNote,
           CurrentMovementId = mv.Id, CurrentMovementNo = mv.MovementNo, CurrentMovementStatus = mv.Status,
           ChargesPostedBase = ISNULL(chg.Posted, 0), ChargesDraftBase = ISNULL(chg.Draft, 0),
           AttachmentCount = (SELECT COUNT(*) FROM logistics.ContainerAttachments a WHERE a.ContainerId = c.Id),
           pl.PortName AS PortOfLoadingName, pd.PortName AS PortOfDestinationName,
           c.CreatedAtUtc, c.CreatedBy, cu.FullName AS CreatedByName, c.UpdatedAtUtc, c.RowVersion,
           pg.TotalCount,                                              -- (81) of the search (step 1)
           -- (65) goods receipts
           rb.ReceivedBy, rb.GoodsReceiptId, rb.GoodsReceiptNumber, rb.GoodsReceiptStatus,
           DeliveredDate = dl.EndDate,
           -- (95) Receive goods... only once delivered (fn_Container_ReceiveBlock: one place for the rule and its words)
           CanReceive = CAST(CASE WHEN rbk.Reason IS NULL THEN 1 ELSE 0 END AS BIT), ReceiveBlockedReason = rbk.Reason,
           -- (95) the journey: the latest leg's From -> To and whether it is on its way or arrived there
           jr.JourneyStatus, jr.JourneyFromName, jr.JourneyToName, jr.JourneySince, jr.JourneyMovementNo,
           CloseBlockedReason = cb.Reason,
           -- (80) the shipment (fn_Container_ShipState): where it is, the movement in progress carrying it, its next
           -- planned movement (why it cannot start yet, its earliest start) and its last completed one
           ss.MovementCount, ss.PlaceId, ss.PlaceName, ss.PlaceSince,
           ss.ActiveMovementId, ss.ActiveMovementNo, ss.ActiveMovementTypeName, ss.ActiveMovementStage,
           ss.ActiveMovementFromName, ss.ActiveMovementToName, ss.ActiveMovementStartDate, ss.ActiveMovementEta,
           ss.ActiveMovementContainerCount,
           ss.PlannedMovementId, ss.PlannedMovementNo, ss.PlannedMovementTypeName, ss.PlannedMovementStage,
           ss.PlannedMovementFromName, ss.PlannedMovementToName, ss.PlannedMovementDate, ss.PlannedMovementContainerCount,
           PlannedMovementBlockedReason = sb.Reason, PlannedMovementNotBefore = sb.StartNotBefore,   -- (81) once per movement
           ss.LastMovementId, ss.LastMovementNo, ss.LastMovementEndDate,
           -- (81) its next step (fn_Container_NextStepKind), and the planned movement's refusal for this page's rows
           NextStepKind = nk.Kind, NextStepBlockedReason = nk.BlockedReason,
           -- (108) what its posted supplier invoices are paid, its share of them (fn_InvoiceContainerSettlement, 73)
           PaymentStatus = pys.PaymentStatus, InvoicedAmountBase = pys.InvoicedAmountBase, PaidAmountBase = pys.PaidAmountBase,
           -- (111) where it stands (fn_Container_Stage)
           StageId = stg.StageId, StageName = stg.StageName, StageReceiptPending = stg.ReceiptPending,
           SortOrd = pg.Ord
    INTO #Page
    FROM #Pg pg
    INNER JOIN logistics.Containers c       ON c.Id = pg.Id      -- (81) the page's rows only
    INNER JOIN masterdata.ContainerTypes ct ON ct.Id = c.ContainerTypeId
    INNER JOIN masterdata.Branches b        ON b.Id = c.BranchId
    LEFT  JOIN masterdata.Warehouses w      ON w.Id = c.WarehouseId
    LEFT  JOIN masterdata.Ports pl          ON pl.Id = c.PortOfLoadingId
    LEFT  JOIN masterdata.Ports pd          ON pd.Id = c.PortOfDestinationId
    LEFT  JOIN purchase.PurchaseDocuments mpo ON mpo.Id = c.PurchaseOrderId
    LEFT  JOIN security.Users cu            ON cu.Id = c.CreatedBy
    CROSS APPLY logistics.fn_ContainerFill(c.Id) fl
    CROSS APPLY logistics.fn_Container_ReceivedBy(c.Id) rb      -- (65) who received it; its open goods receipt
    OUTER APPLY logistics.fn_Container_LastDelivery(c.Id) dl    -- (65) its latest completed Delivery
    OUTER APPLY (SELECT b.Reason FROM logistics.fn_Container_CloseBlock(c.Id) b WHERE c.Status = 6) cb  -- (65) why not Close
    CROSS APPLY logistics.fn_Container_ShipState(c.Id) ss       -- (80) the shipment
    LEFT  JOIN #Sb sb                       ON sb.MovementId = ss.PlannedMovementId          -- (81)
    CROSS APPLY logistics.fn_Container_ReceiveBlock(c.Id) rbk   -- (95)
    CROSS APPLY logistics.fn_Container_Journey(c.Id) jr         -- (95)
    CROSS APPLY purchase.fn_Container_PaymentStatus(c.Id) pys   -- (108)
    CROSS APPLY logistics.fn_Container_Stage(c.Id) stg          -- (111)
    CROSS APPLY logistics.fn_Container_NextStepKind(c.Id, c.Status, ss.MovementCount, ss.ActiveMovementId, ss.PlannedMovementId,
                                                    sb.Reason, ss.LastMovementId, dl.MovementId,
                                                    rb.GoodsReceiptStatus) nk   -- (81) its next step
    OUTER APPLY (SELECT OrderCount = COUNT(DISTINCT cl.PurchaseOrderId), SupplierCount = COUNT(DISTINCT d.SupplierId),
                        FirstOrder = MIN(d.DocumentNumber), FirstSupplier = MIN(sp.PartyName)
                 FROM logistics.ContainerLines cl
                 INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                 INNER JOIN masterdata.Parties sp        ON sp.Id = d.SupplierId
                 WHERE cl.ContainerId = c.Id) po
    OUTER APPLY (SELECT InvoiceCount = COUNT(DISTINCT d.Id),
                        CiCount = COUNT(DISTINCT d.CommercialInvoiceNo), ErCount = COUNT(DISTINCT d.ExporterReference),
                        FirstInvoice = MIN(d.DocumentNumber), FirstCi = MIN(d.CommercialInvoiceNo), FirstEr = MIN(d.ExporterReference),
                        PostedQty = SUM(CASE WHEN d.Status IN (2, 4) THEN pil.QuantityBase ELSE 0 END)
                 FROM logistics.ContainerLines cl
                 INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
                 INNER JOIN purchase.PurchaseDocuments d        ON d.Id = pil.DocumentId
                 WHERE cl.ContainerId = c.Id AND d.Status <> 3) inv
    OUTER APPLY (SELECT ItemCount = COUNT(DISTINCT cl.ItemId), Qty = SUM(cl.QuantityBase), FirstItem = MIN(i.ItemName)
                 FROM logistics.ContainerLines cl
                 INNER JOIN inventory.Items i ON i.Id = cl.ItemId
                 WHERE cl.ContainerId = c.Id) ln
    OUTER APPLY (SELECT Posted = SUM(CASE WHEN ch.Status = 2 THEN ch.AmountBase END),
                        Draft  = SUM(CASE WHEN ch.Status = 1 THEN ch.AmountBase END)
                 FROM logistics.ContainerCharges ch WHERE ch.ContainerId = c.Id) chg
    OUTER APPLY (SELECT TOP (1) m.Id, m.MovementNo, m.Status
                 FROM logistics.MovementContainers mc
                 INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
                 WHERE mc.ContainerId = c.Id AND m.Status IN (2, 3)
                 ORDER BY CASE WHEN m.Status = 2 THEN 0 ELSE 1 END, COALESCE(m.EndDate, m.StartDate) DESC, m.Id DESC) mv;

    -- 3. THE PROPOSED NEXT LEG (Ship, NextLeg: "Inland transport to Kasumbalesa..."), the usual leg from a place worked
    -- out once per (place, last stage) of the page, not once per row.
    SELECT p.Id AS ContainerId, p.PlaceId, LastStage = CASE WHEN p.MovementCount = 0 THEN NULL ELSE lt.Stage END,
           IsCleared = CAST(CASE WHEN p.Status = 5 THEN 1 ELSE 0 END AS BIT)
    INTO #Leg
    FROM #Page p
    LEFT JOIN logistics.Movements lm      ON lm.Id = p.LastMovementId
    LEFT JOIN masterdata.MovementTypes lt ON lt.Id = lm.MovementTypeId
    WHERE p.NextStepKind IN (N'Ship', N'NextLeg');

    SELECT g.PlaceId, g.LastStage, h.MovementTypeId, h.ToPlaceId, h.Legs
    INTO #Hist
    FROM (SELECT DISTINCT PlaceId, LastStage FROM #Leg WHERE PlaceId IS NOT NULL) g
    CROSS APPLY logistics.fn_Movement_NextLegHistory(g.PlaceId, g.LastStage) h;

    SELECT p.*,
           ProposedTypeId = pr.TypeId, ProposedTypeCode = pr.TypeCode, ProposedTypeName = pr.TypeName, ProposedStage = pr.Stage,
           ProposedFromPlaceId = pr.FromPlaceId, ProposedFromName = pr.FromName,
           ProposedToPlaceId = pr.ToPlaceId, ProposedToName = pr.ToName,
           ProposalSource = pr.Source, ProposalLegs = pr.Legs, ProposedIsStay = pr.IsStay
    FROM #Page p
    LEFT JOIN #Leg l  ON l.ContainerId = p.Id
    LEFT JOIN #Hist h ON h.PlaceId = l.PlaceId AND ISNULL(h.LastStage, N'') = ISNULL(l.LastStage, N'')
    OUTER APPLY (SELECT x.*
                 FROM logistics.fn_Container_NextLegProposal(p.Id, l.PlaceId, l.LastStage, l.IsCleared,
                                                             h.MovementTypeId, h.ToPlaceId, h.Legs) x
                 WHERE l.ContainerId IS NOT NULL) pr
    ORDER BY p.SortOrd;
END
GO

PRINT 'Script 111 applied: shipment stages (logistics.ShipmentStages, Update stage, the containers list by stage).';
GO
