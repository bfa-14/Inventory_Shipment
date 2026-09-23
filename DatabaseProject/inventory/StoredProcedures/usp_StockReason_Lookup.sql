CREATE   PROCEDURE inventory.usp_StockReason_Lookup
    @Direction SMALLINT = NULL,    -- 1 = In, -1 = Out, NULL = all
    @IncludeId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, ReasonCode, ReasonName, AppliesTo, IsActive
    FROM inventory.StockReasons
    WHERE (IsActive = 1 OR Id = @IncludeId)
      AND (@Direction IS NULL OR AppliesTo = N'Both'
           OR (@Direction = 1 AND AppliesTo = N'In') OR (@Direction = -1 AND AppliesTo = N'Out'))
    ORDER BY ReasonName;
END

GO

