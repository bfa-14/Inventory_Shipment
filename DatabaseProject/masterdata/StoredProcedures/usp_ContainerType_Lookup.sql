CREATE   PROCEDURE masterdata.usp_ContainerType_Lookup
    @ActiveOnly BIT = 1,
    @IncludeId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, TypeCode, TypeName, MaxUnits, MaxWeightKg, MaxVolumeCbm, IsActive
    FROM masterdata.ContainerTypes
    WHERE (@ActiveOnly = 0 OR IsActive = 1 OR Id = @IncludeId)
    ORDER BY TypeCode;
END
GO

