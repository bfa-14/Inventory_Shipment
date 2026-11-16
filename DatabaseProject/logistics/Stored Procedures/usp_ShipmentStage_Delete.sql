CREATE   PROCEDURE logistics.usp_ShipmentStage_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM logistics.ShipmentStages WHERE Id = @Id) THROW 70006, 'Shipment stage not found.', 1;
    DELETE FROM logistics.ShipmentStages WHERE Id = @Id;
END