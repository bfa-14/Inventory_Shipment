/* ================================================================== 4. Apply to other containers: every candidate */

-- Re-created (78) from the body of script 28: no TOP (500) any more, and the refs in number order (a ref past the
-- type's NumberLength, KTG-2026-10000, after KTG-2026-9999). Nothing else changes.
CREATE   PROCEDURE logistics.usp_ContainerCharge_CopyCandidates
    @ChargeId  INT,
    @Search    NVARCHAR(100) = NULL,    -- container ref / no.
    @SameOrder BIT           = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');

    DECLARE @SourceContainer INT, @GroupId UNIQUEIDENTIFIER, @SourceOrder INT;
    SELECT @SourceContainer = ch.ContainerId, @GroupId = ch.GroupId, @SourceOrder = c.PurchaseOrderId
    FROM logistics.ContainerCharges ch
    INNER JOIN logistics.Containers c ON c.Id = ch.ContainerId
    WHERE ch.Id = @ChargeId;
    IF @SourceContainer IS NULL THROW 70006, 'Charge not found.', 1;

    -- (78) every candidate: TOP (500) cut the list silently, and the newest containers were the ones missing
    SELECT c.Id AS ContainerId, c.ContainerRef, c.ContainerNo, ct.TypeCode AS ContainerTypeCode, c.Status, c.CurrentLocation,
           c.PurchaseOrderId, po.DocumentNumber AS PurchaseOrderNumber, c.TotalAllocatedBase,
           ItemSummary = CASE WHEN ISNULL(ln.ItemCount, 0) = 0 THEN NULL
                              WHEN ln.ItemCount = 1 THEN ln.FirstItem
                              ELSE N'Mixed - ' + CAST(ln.ItemCount AS NVARCHAR(10)) + N' items' END,
           IsSource      = CAST(CASE WHEN c.Id = @SourceContainer THEN 1 ELSE 0 END AS BIT),
           HasThisCharge = CAST(CASE WHEN c.Id = @SourceContainer
                                       OR (@GroupId IS NOT NULL AND EXISTS (SELECT 1 FROM logistics.ContainerCharges g
                                                                            WHERE g.GroupId = @GroupId AND g.ContainerId = c.Id AND g.Status <> 3))
                                     THEN 1 ELSE 0 END AS BIT)
    FROM logistics.Containers c
    INNER JOIN masterdata.ContainerTypes ct ON ct.Id = c.ContainerTypeId
    LEFT  JOIN purchase.PurchaseDocuments po ON po.Id = c.PurchaseOrderId
    OUTER APPLY (SELECT ItemCount = COUNT(DISTINCT cl.ItemId), FirstItem = MIN(i.ItemName)
                 FROM logistics.ContainerLines cl
                 INNER JOIN inventory.Items i ON i.Id = cl.ItemId
                 WHERE cl.ContainerId = c.Id) ln
    WHERE c.Status NOT IN (7, 8)
      AND (ISNULL(@SameOrder, 1) = 0 OR c.PurchaseOrderId = @SourceOrder OR c.Id = @SourceContainer)
      AND (@Search IS NULL OR c.ContainerRef LIKE N'%' + @Search + N'%' OR c.ContainerNo LIKE N'%' + @Search + N'%')
    ORDER BY LEN(c.ContainerRef), c.ContainerRef;   -- (78) number order: KTG-2026-9999 before KTG-2026-10000
END

GO

