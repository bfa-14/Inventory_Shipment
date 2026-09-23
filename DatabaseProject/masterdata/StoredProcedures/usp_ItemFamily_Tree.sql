/* ------------------------------------------------------------------ 3. Procedures */

-- The WHOLE tree in one flat result set (the page builds the hierarchy client-side; the
-- table is small, so there is no server paging on purpose - paging cannot work on a tree).
CREATE   PROCEDURE masterdata.usp_ItemFamily_Tree
AS
BEGIN
    SET NOCOUNT ON;

    SELECT f.Id, f.ParentId, f.FamilyCode, f.FamilyName, f.Description, f.[Level], f.IsActive,
           f.CreatedAtUtc, f.CreatedBy, f.UpdatedAtUtc, f.UpdatedBy, f.RowVersion,
           ChildCount = (SELECT COUNT(*) FROM masterdata.ItemFamilies c WHERE c.ParentId = f.Id)
    FROM masterdata.ItemFamilies f
    ORDER BY f.[Level], f.FamilyCode;
END

GO

