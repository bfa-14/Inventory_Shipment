CREATE   PROCEDURE masterdata.usp_AttachmentType_Lookup
    @ActiveOnly BIT = 1,
    @IncludeId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, Category, SubType, DisplayName = Category + N' / ' + SubType, SortOrder, IsActive
    FROM masterdata.AttachmentTypes
    WHERE (@ActiveOnly = 0 OR IsActive = 1 OR Id = @IncludeId)
    ORDER BY SortOrder, Category, SubType;
END

GO

