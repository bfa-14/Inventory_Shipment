SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ==================================================================================================
   58: Item stock statement
   --------------------------------------------------------------------------------------------------
   The item card's "Stock Movement" quick link: every movement of one item, oldest first, as a
   statement - what came in, what went out, and the balance after each line - across every warehouse,
   optionally for a date range. A range that starts after the first movement opens with the balance
   brought forward, so the running balance is the real one and not a balance from zero.

     inventory.usp_Item_StockStatement   @ItemId, @DateFrom / @DateTo = NULL
       result 1: OpeningBase   the balance before @DateFrom (0 without one)
       result 2: the movements, each with its document (family, type, id, number), counterparty,
                 warehouse, in / out, the running balance, unit cost and who posted it

   A cancelled document shows twice - the movement and its reversal (IsReversal = 1) - because that
   is what happened to the stock.
   ================================================================================================== */

IF OBJECT_ID(N'inventory.StockMovements', N'U') IS NULL
BEGIN
    RAISERROR ('The inventory scripts must run before script 58.', 16, 1);
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_Item_StockStatement
    @ItemId      INT,
    @DateFrom    DATE = NULL,
    @DateTo      DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Opening INT =
        CASE WHEN @DateFrom IS NULL THEN 0 ELSE
            (SELECT ISNULL(SUM(m.QuantityBase), 0) FROM inventory.StockMovements m
             WHERE m.ItemId = @ItemId AND m.MovementDate < @DateFrom) END;

    SELECT OpeningBase = @Opening;

    SELECT m.Id, m.MovementDate, m.DocumentFamily, m.DocumentTypeCode, DocumentTypeName = dt.Name,
           m.DocumentId, m.DocumentNumber, m.IsReversal, m.ReasonCode, m.ExpiryDate,
           m.WarehouseId, w.WarehouseCode, w.WarehouseName, br.BranchName,
           QuantityIn  = CASE WHEN m.QuantityBase > 0 THEN m.QuantityBase ELSE 0 END,
           QuantityOut = CASE WHEN m.QuantityBase < 0 THEN -m.QuantityBase ELSE 0 END,
           Balance     = @Opening + SUM(m.QuantityBase) OVER (ORDER BY m.MovementDate, m.Id ROWS UNBOUNDED PRECEDING),
           m.UnitCostBase,
           -- who the stock went to or came from: the client of a sale, the supplier of a purchase
           Counterparty = COALESCE(cl.PartyName, sp.PartyName),
           CreatedByName = u.FullName
    FROM inventory.StockMovements m
    INNER JOIN masterdata.Warehouses w ON w.Id = m.WarehouseId
    INNER JOIN masterdata.Branches br  ON br.Id = w.BranchId
    LEFT JOIN inventory.DocumentTypes dt ON dt.Code = m.DocumentTypeCode
    LEFT JOIN sales.SalesDocuments sd ON m.DocumentFamily = N'Sales' AND sd.Id = m.DocumentId
    LEFT JOIN masterdata.Parties cl ON cl.Id = sd.ClientId
    LEFT JOIN purchase.PurchaseDocuments pd ON m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode <> N'CNT' AND pd.Id = m.DocumentId
    LEFT JOIN masterdata.Parties sp ON sp.Id = pd.SupplierId
    LEFT JOIN security.Users u ON u.Id = m.CreatedBy
    WHERE m.ItemId = @ItemId
      AND (@DateFrom IS NULL OR m.MovementDate >= @DateFrom)
      AND (@DateTo IS NULL OR m.MovementDate < DATEADD(DAY, 1, @DateTo))
    ORDER BY m.MovementDate, m.Id;
END
GO

PRINT 'Script 58 applied: item stock statement.';
GO

SET NOEXEC OFF;
GO
