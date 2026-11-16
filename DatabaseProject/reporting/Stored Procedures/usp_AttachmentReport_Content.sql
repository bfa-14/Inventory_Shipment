/* ================================================================== 7. reporting.usp_AttachmentReport_Content */

-- The bytes of the chosen files, one row each: Source, Id, Content. The API asks only for keys usp_AttachmentReport_Files
-- has just answered for the reader, and reads the content as a stream (one file at a time, never the whole set at once).
CREATE   PROCEDURE reporting.usp_AttachmentReport_Content
    @Keys NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Chosen TABLE (Source NVARCHAR(4) NOT NULL, Id INT NOT NULL, PRIMARY KEY (Source, Id));
    INSERT INTO @Chosen (Source, Id)
    SELECT DISTINCT LEFT(k.v, CHARINDEX(N':', k.v) - 1), TRY_CAST(SUBSTRING(k.v, CHARINDEX(N':', k.v) + 1, 20) AS INT)
    FROM (SELECT v = LTRIM(RTRIM(value)) FROM STRING_SPLIT(ISNULL(@Keys, N''), N',')) k
    WHERE CHARINDEX(N':', k.v) > 1 AND TRY_CAST(SUBSTRING(k.v, CHARINDEX(N':', k.v) + 1, 20) AS INT) IS NOT NULL;

    SELECT c.Source, c.Id, Content = COALESCE(cf.Content, pd.Content, gr.Content, py.Content, sd.Content, rc.Content,
                                              st.Content, tr.Content, it.Content)
    FROM @Chosen c
    LEFT JOIN logistics.ContainerAttachments ca ON c.Source = N'CNT'  AND ca.Id = c.Id
    LEFT JOIN logistics.Files cf                ON cf.Id = ca.FileId
    LEFT JOIN purchase.PurchaseDocumentFiles pd ON c.Source = N'PDOC' AND pd.Id = c.Id
    LEFT JOIN purchase.GoodsReceiptFiles gr     ON c.Source = N'GRN'  AND gr.Id = c.Id
    LEFT JOIN purchase.PaymentFiles py          ON c.Source = N'PAY'  AND py.Id = c.Id
    LEFT JOIN sales.SalesDocumentFiles sd       ON c.Source = N'SDOC' AND sd.Id = c.Id
    LEFT JOIN sales.ReceiptFiles rc             ON c.Source = N'RCPT' AND rc.Id = c.Id
    LEFT JOIN inventory.StockDocumentFiles st   ON c.Source = N'STK'  AND st.Id = c.Id
    LEFT JOIN inventory.TransferOrderFiles tr   ON c.Source = N'TRO'  AND tr.Id = c.Id
    LEFT JOIN inventory.ItemFiles it            ON c.Source = N'ITEM' AND it.Id = c.Id AND it.IsItemImage = 0
    ORDER BY c.Source, c.Id;
END