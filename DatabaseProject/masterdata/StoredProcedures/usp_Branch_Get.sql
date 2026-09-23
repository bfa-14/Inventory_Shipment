CREATE   PROCEDURE masterdata.usp_Branch_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, BranchCode, BranchName, Address, IsMainBranch, IsActive,
           CreatedAtUtc, CreatedBy, UpdatedAtUtc, UpdatedBy, RowVersion
    FROM masterdata.Branches
    WHERE Id = @Id;
END

GO

