SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 99: INVENTORY - A SHORT LEAD TIME IS NEVER CONVERTED TO 0 MONTHS

     Script 98 converted the days typed before into months rounded to the half month, so a lead time under 8 days
     (7 days -> 0.23 -> 0.0) became 0 months, which Shortages read as "no lead time of its own" and replaced by the
     plan's. Such an item gets its days in months to one decimal instead, at least 0.1 (7 days -> 0.2; 2 days -> 0.1).

     Which rows: LeadTimeMonths = 0 while LeadTimeDays is above 0. Those are only the rows script 98 converted this way
     and nobody saved since: a lead time saved from Item Definition writes the days as months x 30, so 0 months has
     0 days. Run at every start, it finds nothing a second time (no one-time step needed).

   Requires script 98. Idempotent: re-applied at every API start-up, and builds an empty database.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF COL_LENGTH(N'inventory.Items', N'LeadTimeMonths') IS NULL
    THROW 56000, 'Script 99 requires script 98: apply it first.', 1;
GO

UPDATE inventory.Items
SET LeadTimeMonths = CASE WHEN ROUND(LeadTimeDays / 30.0, 1) < 0.1 THEN 0.1
                          WHEN LeadTimeDays / 30.0 > 60 THEN 60
                          ELSE CAST(ROUND(LeadTimeDays / 30.0, 1) AS DECIMAL(5,1)) END
WHERE LeadTimeMonths = 0 AND LeadTimeDays > 0;
IF @@ROWCOUNT > 0 PRINT 'Short lead times corrected: ' + CAST(@@ROWCOUNT AS NVARCHAR(10)) + ' item(s).';
GO

/* ================================================================== Check */

-- 99a: items whose lead time is 0 months but whose days are not 0 (expected: none)
SELECT ItemCode, LeadTimeDays, LeadTimeMonths FROM inventory.Items WHERE LeadTimeMonths = 0 AND LeadTimeDays > 0;
PRINT 'Script 99 applied: a short lead time is never converted to 0 months.';
GO
