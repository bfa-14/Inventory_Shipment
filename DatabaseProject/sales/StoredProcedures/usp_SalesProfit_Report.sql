/* ================================================================== 11. Sales profit report (frozen costs) */

-- Net Sales, COGS, Gross Profit and GP % in the base currency from the posted invoice lines (returns subtract),
-- plus the COGS adjustments of landed cost adjustments in the period (separate column - they belong to no invoice).
CREATE   PROCEDURE sales.usp_SalesProfit_Report
    @DateFrom     DATE         = NULL,
    @DateTo       DATE         = NULL,
    @BranchId     INT          = NULL,
    @ClientId     INT          = NULL,
    @SalesmanId   INT          = NULL,
    @ItemFamilyId INT          = NULL,
    @BrandId      INT          = NULL,
    @ItemId       INT          = NULL,
    @GroupBy      NVARCHAR(20) = N'Invoice'   -- Invoice | Item | Family | Brand | Client | Salesman | Branch | Month | All
AS
BEGIN
    SET NOCOUNT ON;
    IF @GroupBy IS NULL OR @GroupBy NOT IN (N'Invoice', N'Item', N'Family', N'Brand', N'Client', N'Salesman', N'Branch', N'Month', N'All') SET @GroupBy = N'Invoice';

    ;WITH lines AS
    (
        SELECT d.Id AS DocumentId, d.DocumentNumber, d.DocumentDate, d.BranchId, b.BranchName, d.ClientId, cl.PartyName AS ClientName,
               d.SalesmanId, sm.PartyName AS SalesmanName, l.ItemId, i.ItemCode, i.ItemName, i.ItemFamilyId, f.FamilyName, i.BrandId, br.BrandName,
               Sign = CASE WHEN dt.Code = N'SRET' THEN -1 ELSE 1 END,
               l.QuantityBase, GrossBase = ROUND(l.Quantity * l.UnitPrice / d.ExchangeRate, 2), l.NetSalesBase, l.CogsBase, l.GrossProfitBase
        FROM sales.SalesDocumentLines l
        INNER JOIN sales.SalesDocuments d ON d.Id = l.DocumentId
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        INNER JOIN masterdata.ItemFamilies f ON f.Id = i.ItemFamilyId
        INNER JOIN masterdata.Brands br ON br.Id = i.BrandId
        INNER JOIN masterdata.Branches b ON b.Id = d.BranchId
        INNER JOIN masterdata.Parties cl ON cl.Id = d.ClientId
        LEFT  JOIN masterdata.Parties sm ON sm.Id = d.SalesmanId
        WHERE d.Status = 2 AND dt.Code IN (N'SINV', N'SRET')
          AND (@DateFrom IS NULL OR d.DocumentDate >= @DateFrom)
          AND (@DateTo IS NULL OR d.DocumentDate <= @DateTo)
          AND (@BranchId IS NULL OR d.BranchId = @BranchId)
          AND (@ClientId IS NULL OR d.ClientId = @ClientId)
          AND (@SalesmanId IS NULL OR d.SalesmanId = @SalesmanId)
          AND (@ItemFamilyId IS NULL OR i.ItemFamilyId IN (SELECT Id FROM masterdata.fn_ItemFamily_Subtree(@ItemFamilyId)))
          AND (@BrandId IS NULL OR i.BrandId = @BrandId)
          AND (@ItemId IS NULL OR l.ItemId = @ItemId)
    ),
    keyed AS
    (
        SELECT *,
               GroupKey = CASE @GroupBy WHEN N'Invoice' THEN CAST(DocumentId AS NVARCHAR(30)) WHEN N'Item' THEN CAST(ItemId AS NVARCHAR(30))
                                        WHEN N'Family' THEN CAST(ItemFamilyId AS NVARCHAR(30)) WHEN N'Brand' THEN CAST(BrandId AS NVARCHAR(30))
                                        WHEN N'Client' THEN CAST(ClientId AS NVARCHAR(30)) WHEN N'Salesman' THEN CAST(ISNULL(SalesmanId, 0) AS NVARCHAR(30))
                                        WHEN N'Branch' THEN CAST(BranchId AS NVARCHAR(30)) WHEN N'Month' THEN CONVERT(NVARCHAR(7), DocumentDate, 120) ELSE N'ALL' END,
               GroupLabel = CASE @GroupBy WHEN N'Invoice' THEN DocumentNumber WHEN N'Item' THEN ItemCode + N' - ' + ItemName WHEN N'Family' THEN FamilyName
                                          WHEN N'Brand' THEN BrandName WHEN N'Client' THEN ClientName WHEN N'Salesman' THEN ISNULL(SalesmanName, N'(no salesman)')
                                          WHEN N'Branch' THEN BranchName WHEN N'Month' THEN CONVERT(NVARCHAR(7), DocumentDate, 120) ELSE N'All' END
        FROM lines
    )
    SELECT k.GroupKey, k.GroupLabel,
           InvoiceCount   = COUNT(DISTINCT CASE WHEN k.Sign = 1 THEN k.DocumentId END),
           ReturnCount    = COUNT(DISTINCT CASE WHEN k.Sign = -1 THEN k.DocumentId END),
           QuantityBase   = SUM(k.Sign * k.QuantityBase),
           GrossSalesBase = SUM(k.Sign * k.GrossBase),
           DiscountBase   = SUM(k.Sign * (k.GrossBase - ISNULL(k.NetSalesBase, 0))),
           NetSalesBase   = SUM(k.Sign * ISNULL(k.NetSalesBase, 0)),
           CogsBase       = SUM(k.Sign * ISNULL(k.CogsBase, 0)),
           GrossProfitBase = SUM(k.Sign * ISNULL(k.GrossProfitBase, 0)),
           GrossProfitPct = CASE WHEN SUM(k.Sign * ISNULL(k.NetSalesBase, 0)) <> 0
                                 THEN ROUND(100.0 * SUM(k.Sign * ISNULL(k.GrossProfitBase, 0)) / SUM(k.Sign * ISNULL(k.NetSalesBase, 0)), 2) END,
           CogsAdjustmentsBase = CASE WHEN @GroupBy IN (N'All', N'Month', N'Branch', N'Item', N'Family', N'Brand')
                                      THEN ISNULL((SELECT SUM(c.AmountBase) FROM inventory.CostAdjustments c
                                                   INNER JOIN inventory.Items ci ON ci.Id = c.ItemId
                                                   WHERE c.Kind = N'COGS'
                                                     AND (@DateFrom IS NULL OR CAST(c.AdjustmentDate AS DATE) >= @DateFrom)
                                                     AND (@DateTo IS NULL OR CAST(c.AdjustmentDate AS DATE) <= @DateTo)
                                                     AND (@BranchId IS NULL OR c.BranchId = @BranchId)
                                                     AND (@ItemFamilyId IS NULL OR ci.ItemFamilyId IN (SELECT Id FROM masterdata.fn_ItemFamily_Subtree(@ItemFamilyId)))
                                                     AND (@BrandId IS NULL OR ci.BrandId = @BrandId)
                                                     AND (@ItemId IS NULL OR c.ItemId = @ItemId)
                                                     AND (@GroupBy <> N'Month' OR CONVERT(NVARCHAR(7), c.AdjustmentDate, 120) = k.GroupKey)
                                                     AND (@GroupBy <> N'Branch' OR CAST(c.BranchId AS NVARCHAR(30)) = k.GroupKey)
                                                     AND (@GroupBy <> N'Item' OR CAST(c.ItemId AS NVARCHAR(30)) = k.GroupKey)
                                                     AND (@GroupBy <> N'Family' OR CAST(ci.ItemFamilyId AS NVARCHAR(30)) = k.GroupKey)
                                                     AND (@GroupBy <> N'Brand' OR CAST(ci.BrandId AS NVARCHAR(30)) = k.GroupKey)), 0)
                                      ELSE 0 END
    FROM keyed k
    GROUP BY k.GroupKey, k.GroupLabel
    ORDER BY CASE WHEN @GroupBy IN (N'Invoice', N'Month') THEN k.GroupKey END DESC, k.GroupLabel;
END
GO

