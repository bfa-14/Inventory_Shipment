/* ================================================================== 7. Containers: who received one, and its latest Delivery */

-- THE ONLY TEST FOR "OFFLOADED BEFORE GOODS RECEIPTS". One row, always (NULL columns for a NULL or unknown id, so
-- callers may CROSS APPLY it on an outer-joined container):
--   ReceivedBy  'GRN' when a posted goods receipt of the container exists; 'Offload' when the container is Offloaded
--               or Closed (6, 7) without one (the offload of script 27); NULL otherwise.
--   GoodsReceipt*  the container's open receipt - a draft or the posted one (one at most, UX_GoodsReceipts_OpenContainer).
CREATE   FUNCTION logistics.fn_Container_ReceivedBy (@ContainerId INT)
RETURNS TABLE
AS
RETURN
    SELECT ReceivedBy         = CAST(CASE WHEN g.Status = 2 THEN N'GRN'
                                          WHEN c.Status IN (6, 7) THEN N'Offload' END AS NVARCHAR(10)),
           GoodsReceiptId     = g.Id,
           GoodsReceiptNumber = g.DocumentNumber,
           GoodsReceiptStatus = g.Status
    FROM (SELECT ContainerId = @ContainerId) k
    LEFT  JOIN logistics.Containers c ON c.Id = k.ContainerId
    OUTER APPLY (SELECT TOP (1) gr.Id, gr.DocumentNumber, gr.Status
                 FROM purchase.GoodsReceipts gr
                 WHERE gr.ContainerId = k.ContainerId AND gr.Status < 3
                 ORDER BY gr.Status DESC, gr.Id DESC) g;

GO

