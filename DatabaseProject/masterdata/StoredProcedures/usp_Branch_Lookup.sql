/* ------------------------------------------------------------------ 2. Lookups (dropdown data) */

-- Branches for dropdowns. @ActiveOnly = 1 returns active branches only; @IncludeId always includes that branch
-- (so an edit form can still show the currently assigned branch even if it was deactivated).
CREATE   PROCEDURE masterdata.usp_Branch_Lookup
    @ActiveOnly BIT = 1,
    @IncludeId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, BranchCode, BranchName, IsMainBranch, IsActive
    FROM masterdata.Branches
    WHERE (@ActiveOnly = 0 OR IsActive = 1 OR Id = @IncludeId)
    ORDER BY IsMainBranch DESC, BranchName;
END

GO

