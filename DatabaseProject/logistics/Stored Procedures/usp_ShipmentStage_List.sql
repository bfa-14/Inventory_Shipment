/* ================================================================== 5. The stages: list, save, delete */

CREATE   PROCEDURE logistics.usp_ShipmentStage_List
    @ActiveOnly BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SELECT s.Id, s.StageName, s.Kind, s.MovementTypeId, MovementTypeName = mt.TypeName, MovementTypeStage = mt.Stage,
           s.FromPlaceId, FromPlaceName = fp.PortName, s.ToPlaceId, ToPlaceName = tp.PortName,
           s.SortOrder, s.IsActive, s.RowVersion
    FROM logistics.ShipmentStages s
    LEFT JOIN masterdata.MovementTypes mt ON mt.Id = s.MovementTypeId
    LEFT JOIN masterdata.Ports fp ON fp.Id = s.FromPlaceId
    INNER JOIN masterdata.Ports tp ON tp.Id = s.ToPlaceId
    WHERE @ActiveOnly = 0 OR s.IsActive = 1
    ORDER BY s.SortOrder, s.StageName;
END