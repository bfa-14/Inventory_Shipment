-- pages written before still pass, answers as before (Logistics = containers, Receipt = receipts).
CREATE   PROCEDURE masterdata.usp_AttachmentType_Lookup
    @ActiveOnly   BIT          = 1,
    @IncludeId    INT          = NULL,
    @AppliesTo    NVARCHAR(12) = N'Logistics',
    @DocumentKind NVARCHAR(20) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @DocumentKind = ISNULL(NULLIF(LTRIM(RTRIM(@DocumentKind)), N''),
                               CASE WHEN LTRIM(RTRIM(@AppliesTo)) = N'Receipt' THEN N'RCPT' ELSE N'CONTAINER' END);
    SELECT a.Id, a.Category, a.SubType, DisplayName = a.Category + N' / ' + a.SubType, a.SortOrder, a.IsActive
    FROM masterdata.AttachmentTypes a
    WHERE (@ActiveOnly = 0 OR a.IsActive = 1 OR a.Id = @IncludeId)
      AND (EXISTS (SELECT 1 FROM masterdata.AttachmentTypeUsages u WHERE u.AttachmentTypeId = a.Id AND u.DocumentKind = @DocumentKind)
           OR a.Id = @IncludeId)
    ORDER BY a.SortOrder, a.Category, a.SubType;
END

GO

