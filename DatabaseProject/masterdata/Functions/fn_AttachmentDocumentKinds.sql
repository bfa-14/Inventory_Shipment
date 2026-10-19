/* ================================================================== 1. The document kinds: + ITEM */

-- Re-created (67) from the body of script 66: + ITEM (Item Definition's documents), after the stock documents.
CREATE   FUNCTION masterdata.fn_AttachmentDocumentKinds ()
RETURNS TABLE
AS
RETURN
SELECT k.Code, k.Name, k.Noun, k.SortOrder
FROM (VALUES (N'CONTAINER', N'Containers',        N'containers',              10),
             (N'PO',        N'Purchase orders',   N'purchase orders',         20),
             (N'PINV',      N'Purchase invoices', N'purchase invoices',       30),
             (N'PRET',      N'Purchase returns',  N'purchase returns',        40),
             (N'GRN',       N'Goods receipts',    N'goods receipts',          45),   -- (64)
             (N'SO',        N'Sales orders',      N'sales orders',            50),
             (N'SINV',      N'Sales invoices',    N'sales invoices',          60),
             (N'SRET',      N'Sales returns',     N'sales returns',           70),
             (N'RCPT',      N'Customer receipts', N'customer receipts',       80),
             (N'PAY',       N'Supplier payments', N'supplier payments',       85),
             (N'INV_IN',    N'Inventory In',      N'Inventory In documents',  90),
             (N'INV_OUT',   N'Inventory Out',     N'Inventory Out documents', 100),
             (N'BIV_OUT',   N'BIVAC Out',         N'BIVAC Out documents',     105),   -- (66)
             (N'ITEM',      N'Items',             N'items',                   120)) k (Code, Name, Noun, SortOrder);   -- (67)

GO

