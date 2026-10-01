CREATE   PROCEDURE sales.usp_Receipt_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT r.Id, r.ReceiptNumber, r.ReceiptDate, r.ClientId, cl.PartyCode AS ClientCode, cl.PartyName AS ClientName, cl.Address AS ClientAddress,
           r.BranchId, b.BranchCode, b.BranchName, r.PaymentType,
           r.CurrencyId, c.CurrencyCode, c.CurrencyName, c.Symbol AS CurrencySymbol, c.DecimalPlaces, c.IsBaseCurrency,
           r.Amount, r.ExchangeRate, r.AmountBase, bc.CurrencyCode AS BaseCurrencyCode,
           r.Notes, r.Status,
           r.SourceSalesDocumentId, SourceInvoiceNumber = sd.DocumentNumber,
           LinesBase = ISNULL(ln.Base, 0),
           AllocatedBase = ISNULL(al.Base, 0),
           -- Only a posted FREE receipt holds credit; a Sales Allocation one is spent by definition.
           UnappliedBase = CASE WHEN r.Status = 2 AND r.PaymentType = 1 THEN r.AmountBase - ISNULL(al.Base, 0) ELSE 0 END,
           r.PostedAtUtc, r.PostedBy, pu.FullName AS PostedByName,
           r.ReversedAtUtc, r.ReversedBy, ru.FullName AS ReversedByName, r.ReverseReason,
           r.CreatedAtUtc, r.CreatedBy, cu.FullName AS CreatedByName, r.UpdatedAtUtc, r.UpdatedBy, uu.FullName AS UpdatedByName,
           r.RowVersion
    FROM sales.Receipts r
    INNER JOIN masterdata.Parties cl    ON cl.Id = r.ClientId
    INNER JOIN masterdata.Branches b    ON b.Id = r.BranchId
    INNER JOIN masterdata.Currencies c  ON c.Id = r.CurrencyId
    LEFT  JOIN masterdata.Currencies bc ON bc.IsBaseCurrency = 1 AND bc.IsActive = 1
    OUTER APPLY (SELECT Base = SUM(AmountBase) FROM sales.ReceiptLines WHERE ReceiptId = r.Id) ln
    OUTER APPLY (SELECT Base = SUM(AmountBase) FROM sales.ReceiptAllocations WHERE ReceiptId = r.Id AND RemovedAtUtc IS NULL) al
    LEFT  JOIN security.Users pu ON pu.Id = r.PostedBy
    LEFT  JOIN security.Users ru ON ru.Id = r.ReversedBy
    LEFT  JOIN security.Users cu ON cu.Id = r.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = r.UpdatedBy
    LEFT  JOIN sales.SalesDocuments sd ON sd.Id = r.SourceSalesDocumentId
    WHERE r.Id = @Id;

    SELECT l.Id, l.ReceiptId, l.LineNumber, l.PaymentMethodId, pm.MethodCode, pm.MethodName,
           l.CurrencyId, cu.CurrencyCode, cu.DecimalPlaces, l.Amount, l.ExchangeRate, l.AmountBase,
           l.CashBankAccountId, a.AccountCode, a.AccountName, l.Reference
    FROM sales.ReceiptLines l
    INNER JOIN masterdata.PaymentMethods pm  ON pm.Id = l.PaymentMethodId
    INNER JOIN masterdata.Currencies cu      ON cu.Id = l.CurrencyId
    INNER JOIN masterdata.CashBankAccounts a ON a.Id = l.CashBankAccountId
    WHERE l.ReceiptId = @Id
    ORDER BY l.LineNumber;

    SELECT al.Id, al.ReceiptId, al.SalesDocumentId, d.DocumentNumber AS InvoiceNumber, d.DocumentDate AS InvoiceDate,
           d.CurrencyId AS InvoiceCurrencyId, ic.CurrencyCode AS InvoiceCurrencyCode, ic.DecimalPlaces AS InvoiceDecimalPlaces,
           InvoiceTotal = d.TotalAmount,
           al.AmountInvoiceCurrency, al.InvoiceExchangeRate, al.AmountBase,
           al.AllocatedAtUtc, au.FullName AS AllocatedByName, al.RemovedAtUtc, xu.FullName AS RemovedByName
    FROM sales.ReceiptAllocations al
    INNER JOIN sales.SalesDocuments d ON d.Id = al.SalesDocumentId
    INNER JOIN masterdata.Currencies ic ON ic.Id = d.CurrencyId
    LEFT  JOIN security.Users au ON au.Id = al.AllocatedBy
    LEFT  JOIN security.Users xu ON xu.Id = al.RemovedBy
    WHERE al.ReceiptId = @Id
    ORDER BY al.AllocatedAtUtc, al.Id;

    SELECT f.Id, f.ReceiptId, f.AttachmentTypeId, t.Category, t.SubType, f.Note, f.FileName, f.ContentType, f.SizeBytes,
           f.CreatedAtUtc, u.FullName AS CreatedByName
    FROM sales.ReceiptFiles f
    LEFT JOIN masterdata.AttachmentTypes t ON t.Id = f.AttachmentTypeId
    LEFT JOIN security.Users u ON u.Id = f.CreatedBy
    WHERE f.ReceiptId = @Id
    ORDER BY f.CreatedAtUtc, f.Id;

    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM sales.ReceiptAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.ReceiptId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;
END

GO

