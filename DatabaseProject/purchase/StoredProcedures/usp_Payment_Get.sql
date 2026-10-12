/* ================================================================== 9. Get */

-- Five result sets: the payment, its lines, its allocations, its files, its audit trail (newest first).
CREATE   PROCEDURE purchase.usp_Payment_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT p.Id, p.PaymentNumber, p.PaymentDate, p.PayeeId, py.PartyCode AS PayeeCode, py.PartyName AS PayeeName, py.Address AS PayeeAddress,
           p.BranchId, b.BranchCode, b.BranchName, p.PaymentType,
           p.CurrencyId, c.CurrencyCode, c.CurrencyName, c.Symbol AS CurrencySymbol, c.DecimalPlaces, c.IsBaseCurrency,
           p.Amount, p.ExchangeRate, p.AmountBase, bc.CurrencyCode AS BaseCurrencyCode,
           p.Reference, p.Notes, p.Status,
           LinesTotal     = ISNULL(ln.Total, 0),
           AllocatedTotal = ISNULL(al.Total, 0),
           -- Only a posted FREE payment holds an advance; an allocated one is spent by definition.
           UnappliedAmount = CASE WHEN p.Status = 2 AND p.PaymentType = 1 THEN p.Amount - ISNULL(al.Total, 0) ELSE 0 END,
           AllocationKind = al.Kind,
           p.PostedAtUtc, p.PostedBy, pu.FullName AS PostedByName,
           p.ReversedAtUtc, p.ReversedBy, ru.FullName AS ReversedByName, p.ReverseReason,
           p.CreatedAtUtc, p.CreatedBy, cu.FullName AS CreatedByName, p.UpdatedAtUtc, p.UpdatedBy, uu.FullName AS UpdatedByName,
           p.RowVersion
    FROM purchase.Payments p
    INNER JOIN masterdata.Parties py    ON py.Id = p.PayeeId
    INNER JOIN masterdata.Branches b    ON b.Id = p.BranchId
    INNER JOIN masterdata.Currencies c  ON c.Id = p.CurrencyId
    LEFT  JOIN masterdata.Currencies bc ON bc.IsBaseCurrency = 1 AND bc.IsActive = 1
    OUTER APPLY (SELECT Total = SUM(AmountPaymentCurrency) FROM purchase.PaymentLines WHERE PaymentId = p.Id) ln
    OUTER APPLY (SELECT Total = SUM(AmountPaymentCurrency), Kind = MIN(DocumentKind)
                 FROM purchase.PaymentAllocations WHERE PaymentId = p.Id AND RemovedAtUtc IS NULL) al
    LEFT  JOIN security.Users pu ON pu.Id = p.PostedBy
    LEFT  JOIN security.Users ru ON ru.Id = p.ReversedBy
    LEFT  JOIN security.Users cu ON cu.Id = p.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = p.UpdatedBy
    WHERE p.Id = @Id;

    SELECT l.Id, l.PaymentId, l.LineNumber, l.PaymentMethodId, pm.MethodCode, pm.MethodName,
           IsCheque = CAST(CASE WHEN pm.MethodCode = N'CHQ' THEN 1 ELSE 0 END AS BIT),
           l.CurrencyId, cu.CurrencyCode, cu.DecimalPlaces, l.Amount, l.RateToPayment, l.AmountPaymentCurrency, l.AmountBase,
           l.CashBankAccountId, a.AccountCode, a.AccountName, l.Reference,
           l.ChequeNo, l.ChequeDate, l.ChequeDueDate, l.ClearanceStatus,
           ClearanceStatusName = CASE l.ClearanceStatus WHEN 1 THEN N'Pending' WHEN 2 THEN N'Cleared' WHEN 3 THEN N'Returned' END,
           l.ClearanceUpdatedAtUtc, xu.FullName AS ClearanceUpdatedByName
    FROM purchase.PaymentLines l
    INNER JOIN masterdata.PaymentMethods pm  ON pm.Id = l.PaymentMethodId
    INNER JOIN masterdata.Currencies cu      ON cu.Id = l.CurrencyId
    INNER JOIN masterdata.CashBankAccounts a ON a.Id = l.CashBankAccountId
    LEFT  JOIN security.Users xu ON xu.Id = l.ClearanceUpdatedBy
    WHERE l.PaymentId = @Id
    ORDER BY l.LineNumber;

    /* PreviouslyPaid is what OTHER posted payments have paid the document: this payment's own share is
       taken out when it is posted and still live, so a draft and a posted payment read the same. */
    SELECT al.Id, al.PaymentId, al.DocumentKind, DocumentId = ISNULL(al.PurchaseDocumentId, al.ContainerChargeId),
           pd.DocumentNumber, pd.DocumentDate, pd.ContainerRef, pd.ChargeTypeName, pd.Reference AS DocumentReference,
           pd.CurrencyId AS DocumentCurrencyId, pd.CurrencyCode AS DocumentCurrencyCode, pd.DecimalPlaces AS DocumentDecimalPlaces,
           pd.DocumentTotal, pd.ReturnedAmount,
           PreviouslyPaid = pd.PaidAmount - CASE WHEN p.Status = 2 AND al.RemovedAtUtc IS NULL THEN al.AmountDocCurrency ELSE 0 END,
           pd.OutstandingAmount, pd.PaymentStatus,
           al.AmountDocCurrency, al.DocExchangeRate, al.RateToPayment, al.AmountPaymentCurrency, al.AmountBase,
           al.AllocatedAtUtc, au.FullName AS AllocatedByName, al.RemovedAtUtc, xu.FullName AS RemovedByName
    FROM purchase.PaymentAllocations al
    INNER JOIN purchase.Payments p ON p.Id = al.PaymentId
    CROSS APPLY purchase.fn_PayableDocument(al.DocumentKind, ISNULL(al.PurchaseDocumentId, al.ContainerChargeId)) pd
    LEFT  JOIN security.Users au ON au.Id = al.AllocatedBy
    LEFT  JOIN security.Users xu ON xu.Id = al.RemovedBy
    WHERE al.PaymentId = @Id
    ORDER BY al.AllocatedAtUtc, al.Id;

    SELECT f.Id, f.PaymentId, f.AttachmentTypeId, t.Category, t.SubType, f.Note, f.FileName, f.ContentType, f.SizeBytes,
           f.CreatedAtUtc, u.FullName AS CreatedByName
    FROM purchase.PaymentFiles f
    LEFT JOIN masterdata.AttachmentTypes t ON t.Id = f.AttachmentTypeId
    LEFT JOIN security.Users u ON u.Id = f.CreatedBy
    WHERE f.PaymentId = @Id
    ORDER BY f.CreatedAtUtc, f.Id;

    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM purchase.PaymentAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.PaymentId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;
END

GO

