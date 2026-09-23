CREATE   PROCEDURE purchase.usp_LandedCostAdjustment_Search
    @Search          NVARCHAR(100) = NULL,   -- number, invoice number, supplier
    @SourceInvoiceId INT          = NULL,
    @BranchId        INT          = NULL,
    @Status          TINYINT      = NULL,
    @DateFrom        DATE         = NULL,
    @DateTo          DATE         = NULL,
    @PageNumber      INT          = 1,
    @PageSize        INT          = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');

    SELECT a.Id, a.DocumentNumber, a.DocumentDate, a.BranchId, b.BranchName, a.SourceInvoiceId, inv.DocumentNumber AS SourceInvoiceNumber,
           inv.SupplierId, sp.PartyName AS SupplierName, a.Status, a.TotalChargesBase, a.InventoryPortionBase, a.CogsPortionBase,
           a.PostedAtUtc, pu.FullName AS PostedByName, a.CreatedAtUtc, cu.FullName AS CreatedByName, a.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM purchase.LandedCostAdjustments a
    INNER JOIN masterdata.Branches b ON b.Id = a.BranchId
    INNER JOIN purchase.PurchaseDocuments inv ON inv.Id = a.SourceInvoiceId
    INNER JOIN masterdata.Parties sp ON sp.Id = inv.SupplierId
    LEFT  JOIN security.Users cu ON cu.Id = a.CreatedBy
    LEFT  JOIN security.Users pu ON pu.Id = a.PostedBy
    WHERE (@Search IS NULL OR a.DocumentNumber LIKE N'%' + @Search + N'%' OR inv.DocumentNumber LIKE N'%' + @Search + N'%' OR sp.PartyName LIKE N'%' + @Search + N'%')
      AND (@SourceInvoiceId IS NULL OR a.SourceInvoiceId = @SourceInvoiceId)
      AND (@BranchId IS NULL OR a.BranchId = @BranchId)
      AND (@Status IS NULL OR a.Status = @Status)
      AND (@DateFrom IS NULL OR a.DocumentDate >= @DateFrom)
      AND (@DateTo IS NULL OR a.DocumentDate <= @DateTo)
    ORDER BY a.DocumentDate DESC, a.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END

GO

