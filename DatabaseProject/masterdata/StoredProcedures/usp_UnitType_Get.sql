CREATE   PROCEDURE masterdata.usp_UnitType_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, UnitTypeName, IsActive, IsContainer, CreatedAtUtc, CreatedBy, UpdatedAtUtc, UpdatedBy, RowVersion
    FROM masterdata.UnitTypes WHERE Id = @Id;
END

GO

