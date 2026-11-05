SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 109: REPORTING - THE GOODS ON ORDER REPORT

   Reports › Goods on Order: everything ordered and not received yet, one row per item and one Qty / Containers pair per
   stage of the journey - the purchasing team's "MOVEMENT SUMMARY". Its rows are the Container Report's
   (logistics.usp_ContainerReport, scripts 100 and 106, without the received containers), so the two reports never
   disagree; THE COLUMNS ARE THE STAGES THE GOODS ARE AT NOW, worked out from the containers' movements by that
   procedure: Order pending (every order month in one column), In transit {From} → {To}, a port, a border or inland
   place, {From} → {To} on the road, Delivered to {place}, to receive - in the order of the journey, a stage nobody is at
   is no column.

     1. THE PERMISSION reports.goodsonorder.view "View Goods on Order Report" (module Reports, 1540). Not granted to any
        role here: the start-up sync gives every permission to the system roles, and the others get it in Role
        Permissions.

   Errors: no new number. Requires script 106 (Schema.sql runs it first). Idempotent, additive.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

/* ================================================================== 1. reports.goodsonorder.view */

-- The texts are PermissionCatalog.cs's, so the start-up sync changes nothing.
MERGE security.Permissions AS target
USING (VALUES (N'reports.goodsonorder.view', N'View Goods on Order Report', N'Reports',
               N'Reports › Goods on Order: everything ordered and not received yet, per item and per stage of the journey.',
               1540)) AS source (Code, Name, Module, Description, SortOrder)
ON target.Code = source.Code
WHEN MATCHED AND (target.Name <> source.Name OR target.Module <> source.Module
                  OR ISNULL(target.Description, N'') <> source.Description OR target.SortOrder <> source.SortOrder) THEN
    UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Module, Description, SortOrder)
    VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder);
GO

PRINT 'Script 109 applied: the Goods on Order Report (reports.goodsonorder.view).';
GO
