-- indents by Level / builds paths from ParentId. @ActiveOnly = 1 hides inactive families;
-- @IncludeId keeps one inactive row visible (the value already saved on the record being edited).
CREATE   PROCEDURE masterdata.usp_ItemFamily_Lookup
    @ActiveOnly BIT = 1,
    @IncludeId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, ParentId, FamilyCode, FamilyName, [Level], IsActive
    FROM masterdata.ItemFamilies
    WHERE (@ActiveOnly = 0 OR IsActive = 1 OR Id = @IncludeId)
    ORDER BY [Level], FamilyCode;
END

GO

