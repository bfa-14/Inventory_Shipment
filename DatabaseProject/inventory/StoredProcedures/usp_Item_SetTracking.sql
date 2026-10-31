--      item is created (always) or updated (only when the request carries trackingMode). A change applies to the next
--      dispatches (B10): goods on the way keep what they left with. "Item not found." is 56006 on purpose (404). Nothing
--      written when nothing differs.
CREATE   PROCEDURE inventory.usp_Item_SetTracking
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

