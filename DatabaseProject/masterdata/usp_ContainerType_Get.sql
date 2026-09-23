
CREATE   PROCEDURE masterdata.usp_ContainerType_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, TypeCode, TypeName, MaxUnits, MaxWeightKg, MaxVolumeCbm, Description, IsActive,
           CreatedAtUtc, CreatedBy, UpdatedAtUtc, UpdatedBy, RowVersion
    FROM masterdata.ContainerTypes WHERE Id = @Id;
END
GO

