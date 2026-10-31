/* ================================================================== 7. A light container lookup for the pickers */

-- (78) NEW. The container pickers (New charge, the Container Charges filter) searched a preloaded page of the 200 newest
-- containers, and a preset selection outside it was read one container at a time (GET per container: 400 calls for a
-- selection of 600). This answers both in one call:
--   @Ids given     those containers, whatever their number (the preset selection);
--   else           at most @Top (1-200, default 50) matching @Search on the ref or the container no., newest first.
-- @MaxStatus keeps the containers up to that status (6 = Offloaded: the ones a charge can still be typed for).
CREATE   PROCEDURE logistics.usp_Container_Lookup
    @Ids       logistics.tvp_IdList READONLY,
    @Search    NVARCHAR(100) = NULL,
    @MaxStatus TINYINT       = NULL,
    @Top       INT           = 50
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @Top IS NULL OR @Top < 1 OR @Top > 200 SET @Top = 50;

    IF EXISTS (SELECT 1 FROM @Ids)
        SELECT c.Id, c.ContainerRef, c.ContainerNo, c.Status, Pieces = c.TotalAllocatedBase, c.PurchaseOrderId
        FROM logistics.Containers c
        INNER JOIN @Ids i ON i.Id = c.Id
        WHERE @MaxStatus IS NULL OR c.Status <= @MaxStatus
        ORDER BY LEN(c.ContainerRef), c.ContainerRef;   -- number order: KTG-2026-9999 before KTG-2026-10000
    ELSE
        SELECT TOP (@Top) c.Id, c.ContainerRef, c.ContainerNo, c.Status, Pieces = c.TotalAllocatedBase, c.PurchaseOrderId
        FROM logistics.Containers c
        WHERE (@MaxStatus IS NULL OR c.Status <= @MaxStatus)
          AND (@Search IS NULL OR c.ContainerRef LIKE N'%' + @Search + N'%' OR c.ContainerNo LIKE N'%' + @Search + N'%')
        ORDER BY c.Id DESC;
END

GO

