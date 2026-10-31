-- provider), outside the group @GroupId and other than @ChargeId, with the sentence of the refusal.
CREATE   FUNCTION logistics.fn_ContainerCharge_ReferenceClash
(
    @ProviderPartyId INT,
    @Reference       NVARCHAR(100),
    @GroupId         UNIQUEIDENTIFIER,
    @ChargeId        INT
)
RETURNS TABLE
AS
RETURN
SELECT TOP (1) ch.Id, ch.ContainerId, c.ContainerRef,
       Message = CAST(N'Reference ' + LTRIM(RTRIM(@Reference))
                      + ISNULL(N' of ' + p.PartyName, N' (no provider)')
                      + N' is already entered: ' + t.ChargeName + N' on ' + c.ContainerRef
                      + N' (' + CONVERT(NVARCHAR(10), ch.ChargeDate, 103) + N'). A provider''s invoice is entered once - one charge'
                      + N' for all its containers (Apply to other containers..., or one group of rows in Import charges from Excel).'
                      AS NVARCHAR(400))
FROM logistics.ContainerCharges ch
INNER JOIN logistics.Containers c  ON c.Id = ch.ContainerId
INNER JOIN purchase.ChargeTypes t  ON t.Id = ch.ChargeTypeId
LEFT  JOIN masterdata.Parties p    ON p.Id = ch.ProviderPartyId
WHERE ch.Reference = LTRIM(RTRIM(@Reference))
  AND NULLIF(LTRIM(RTRIM(@Reference)), N'') IS NOT NULL
  AND ch.Status <> 3
  AND ((@ProviderPartyId IS NULL AND ch.ProviderPartyId IS NULL) OR ch.ProviderPartyId = @ProviderPartyId)
  AND (@GroupId IS NULL OR ch.GroupId IS NULL OR ch.GroupId <> @GroupId)
  AND (@ChargeId IS NULL OR ch.Id <> @ChargeId)
ORDER BY ch.Id;

GO

