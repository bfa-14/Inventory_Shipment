CREATE   PROCEDURE masterdata.usp_AttachmentType_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT a.Id, a.Category, a.SubType, a.AppliesTo, a.SortOrder, a.IsActive,
           UsedFor = (SELECT STRING_AGG(k.Code, N',') WITHIN GROUP (ORDER BY k.SortOrder)
                      FROM masterdata.AttachmentTypeUsages u
                      INNER JOIN masterdata.fn_AttachmentDocumentKinds() k ON k.Code = u.DocumentKind
                      WHERE u.AttachmentTypeId = a.Id),
           a.CreatedAtUtc, a.CreatedBy, a.UpdatedAtUtc, a.UpdatedBy, a.RowVersion
    FROM masterdata.AttachmentTypes a WHERE a.Id = @Id;
END

GO

