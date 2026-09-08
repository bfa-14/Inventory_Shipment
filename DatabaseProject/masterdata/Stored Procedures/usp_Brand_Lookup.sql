CREATE   PROCEDURE masterdata.usp_Brand_Lookup
    @ActiveOnly BIT = 1,
    @IncludeId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, BrandCode, BrandName, IsActive
    FROM masterdata.Brands
    WHERE (@ActiveOnly = 0 OR IsActive = 1 OR Id = @IncludeId)
    ORDER BY BrandName;
END