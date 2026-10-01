/* ================================================================== 12. What a customer still owes */

/* The invoices the allocation panel lists: this customer's POSTED sales invoices with something
   left to pay, oldest first. Outstanding is in the invoice's currency, and OutstandingBase is what
   it is worth in the base currency at the invoice's own rate - the figure the receipt's allocation
   total is balanced against. */
CREATE   PROCEDURE sales.usp_Receipt_OpenInvoices
    @ClientId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT d.Id, d.DocumentNumber, d.DocumentDate, d.DueDate, d.CurrencyId, c.CurrencyCode, c.DecimalPlaces, d.ExchangeRate,
           InvoiceTotal = d.TotalAmount, st.PaidAmount, st.OutstandingAmount, st.PaymentStatus,
           OutstandingBase = CONVERT(DECIMAL(18,2), st.OutstandingAmount / d.ExchangeRate)
    FROM sales.SalesDocuments d
    INNER JOIN masterdata.Currencies c ON c.Id = d.CurrencyId
    CROSS APPLY sales.fn_InvoiceSettlement(d.Id) st
    WHERE d.ClientId = @ClientId AND st.PaymentStatus IN (N'Unpaid', N'Partial')
    ORDER BY d.DocumentDate, d.Id;
END

GO

