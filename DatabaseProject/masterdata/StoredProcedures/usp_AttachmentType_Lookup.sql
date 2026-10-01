CREATE   PROCEDURE masterdata.usp_AttachmentType_Lookup
    @ActiveOnly BIT          = 1,
    @IncludeId  INT          = NULL,
    /* WHICH LIST. Logistics is the default so the container upload modal, which passes nothing,
       sees exactly what it always saw; the receipt page asks for Receipt. */
    @AppliesTo  NVARCHAR(12) = N'Logistics'
AS
BEGIN
    SET NOCOUNT ON;
    SET @AppliesTo = ISNULL(NULLIF(LTRIM(RTRIM(@AppliesTo)), N''), N'Logistics');
    SELECT Id, Category, SubType, DisplayName = Category + N' / ' + SubType, SortOrder, IsActive
    FROM masterdata.AttachmentTypes
    WHERE (@ActiveOnly = 0 OR IsActive = 1 OR Id = @IncludeId)
      AND (AppliesTo = @AppliesTo OR Id = @IncludeId)
    ORDER BY SortOrder, Category, SubType;
END

GO

