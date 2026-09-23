CREATE   PROCEDURE masterdata.usp_AttachmentType_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, Category, SubType, SortOrder, IsActive, CreatedAtUtc, CreatedBy, UpdatedAtUtc, UpdatedBy, RowVersion
    FROM masterdata.AttachmentTypes WHERE Id = @Id;
END
GO

