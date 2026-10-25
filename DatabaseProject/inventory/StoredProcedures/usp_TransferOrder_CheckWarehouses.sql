CREATE   PROCEDURE inventory.usp_TransferOrder_CheckWarehouses
    @FromId INT,
    @ToId   INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @m NVARCHAR(400);
    SELECT TOP (1) @m = Message FROM inventory.fn_TransferOrder_WarehouseProblem(@FromId, @ToId);
    IF @m IS NOT NULL THROW 62000, @m, 1;
END

GO

