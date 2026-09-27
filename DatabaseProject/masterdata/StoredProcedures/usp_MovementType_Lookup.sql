CREATE   PROCEDURE masterdata.usp_MovementType_Lookup
    @ActiveOnly BIT = 1,
    @IncludeId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, TypeCode, TypeName, Stage, SortOrder, IsActive
    FROM masterdata.MovementTypes
    WHERE @ActiveOnly = 0 OR IsActive = 1 OR Id = @IncludeId
    ORDER BY SortOrder, TypeName;
END

GO

