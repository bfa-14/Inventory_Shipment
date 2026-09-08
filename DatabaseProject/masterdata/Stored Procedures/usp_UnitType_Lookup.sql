CREATE   PROCEDURE masterdata.usp_UnitType_Lookup
    @ActiveOnly BIT = 1,
    @IncludeId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, UnitTypeName, IsActive
    FROM masterdata.UnitTypes
    WHERE (@ActiveOnly = 0 OR IsActive = 1 OR Id = @IncludeId)
    ORDER BY UnitTypeName;
END