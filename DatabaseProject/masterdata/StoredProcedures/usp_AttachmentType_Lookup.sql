/* ================================================================== 7. Master data: attachment types */

-- Re-created (55) from the body of script 52: @AppliesTo, which the pages written before still pass, answers as
-- before - Logistics = containers, Receipt = receipts - and Payment = supplier payments.
CREATE   PROCEDURE masterdata.usp_AttachmentType_Lookup
    @ActiveOnly   BIT          = 1,
    @IncludeId    INT          = NULL,
    @AppliesTo    NVARCHAR(12) = N'Logistics',
    @DocumentKind NVARCHAR(20) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @DocumentKind = ISNULL(NULLIF(LTRIM(RTRIM(@DocumentKind)), N''),
                               CASE LTRIM(RTRIM(@AppliesTo)) WHEN N'Receipt' THEN N'RCPT' WHEN N'Payment' THEN N'PAY' ELSE N'CONTAINER' END);
    SELECT a.Id, a.Category, a.SubType, DisplayName = a.Category + N' / ' + a.SubType, a.SortOrder, a.IsActive
    FROM masterdata.AttachmentTypes a
    WHERE (@ActiveOnly = 0 OR a.IsActive = 1 OR a.Id = @IncludeId)
      AND (EXISTS (SELECT 1 FROM masterdata.AttachmentTypeUsages u WHERE u.AttachmentTypeId = a.Id AND u.DocumentKind = @DocumentKind)
           OR a.Id = @IncludeId)
    ORDER BY a.SortOrder, a.Category, a.SubType;
END

GO

