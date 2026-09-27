CREATE   PROCEDURE masterdata.usp_MovementType_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, TypeCode, TypeName, Stage, SortOrder, IsActive, CreatedAtUtc, CreatedBy, UpdatedAtUtc, UpdatedBy, RowVersion
    FROM masterdata.MovementTypes WHERE Id = @Id;
END

GO

