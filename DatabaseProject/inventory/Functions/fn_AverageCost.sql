CREATE   FUNCTION inventory.fn_AverageCost (@ItemId INT)
RETURNS DECIMAL(18,6)
AS
BEGIN
    RETURN (SELECT AverageCost FROM inventory.Items WHERE Id = @ItemId);
END