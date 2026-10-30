/* ================================================================== 4. The item's lead time in months */

-- (98) Written the way usp_Item_SetTracking writes its fields: the API calls it after the item is created or updated.
-- LeadTimeDays follows (months x 30) for the readers of the days. Nothing written when nothing differs.
CREATE   PROCEDURE inventory.usp_Item_SetLeadTime
    @Id             INT,
    @LeadTimeMonths DECIMAL(5,1) = NULL,
    @UserId         INT          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inventory.Items WHERE Id = @Id) THROW 56006, 'Item not found.', 1;
    IF @LeadTimeMonths IS NOT NULL AND (@LeadTimeMonths < 0 OR @LeadTimeMonths > 60)
        THROW 56000, 'Lead time must be between 0 and 60 months.', 1;
    UPDATE inventory.Items
    SET LeadTimeMonths = @LeadTimeMonths,
        LeadTimeDays = CASE WHEN @LeadTimeMonths IS NULL THEN NULL ELSE CAST(ROUND(@LeadTimeMonths * 30, 0) AS INT) END,
        UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id
      AND (ISNULL(LeadTimeMonths, -1) <> ISNULL(@LeadTimeMonths, -1)
           OR ISNULL(LeadTimeDays, -1) <> ISNULL(CAST(ROUND(@LeadTimeMonths * 30, 0) AS INT), -1));
END

GO

