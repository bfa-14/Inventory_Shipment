CREATE   PROCEDURE masterdata.usp_Brand_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, BrandCode, BrandName, Description, IsActive,
           CreatedAtUtc, CreatedBy, UpdatedAtUtc, UpdatedBy, RowVersion
    FROM masterdata.Brands
    WHERE Id = @Id;
END