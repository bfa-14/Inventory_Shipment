/* ================================================================== 4. The leg proposed to a container */

-- At most one row: the next leg proposed to a container at @PlaceId (its place: the end of its latest movement, its port
-- of loading when it never moved) whose last leg had the stage @LastStage (NULL = never moved), @IsCleared once it
-- cleared customs, with the history of its (place, last stage) worked out by the caller (fn_Movement_NextLegHistory:
-- @HistTypeId, @HistToPlaceId, @HistLegs). None after a Delivery: its goods are received next.
--   1. Never moved, with a port of destination: Sea freight from the port of loading to it ("Ports"). The container
--      says where it goes: its own ports come before the history of other containers.
--   2. The history (fn_Movement_NextLegHistory): "History", {n} earlier legs. A Delivery goes to the container's own
--      final destination when it has one ("Ports" when that is not the usual To).
--   3. The stage order ("Stages"): never moved without a port of destination -> Sea freight, To to choose; after a
--      Loading at the supplier -> Sea freight to the port of destination; cleared (or after Customs) -> Warehouse
--      delivery to the final destination; after a Sea or Port leg -> Inland transport, To to choose; after a Transit
--      or Border leg -> Customs clearance at a border or inland place, Inland transport at a sea port (a transshipment).
--   The type of a stage is the active one with the usual code (SEA, INLAND, CUSTOMS, DELIVERY), else the first by sort
--   order: never an id. A stay (Port, Customs, Border) takes To = the place; an inactive place is never proposed (To to
--   choose). Source "None" when the stage's types are all inactive: the type is then left to choose ("Choose the type"),
--   the container still moves on (usp_Container_NextStepPreview blocks it only when no movement type is active at all).
-- OnePerContainer: the default of the bulk dialog - one movement for the group for a vessel or a stay at the port
-- (Sea, Port, a transshipment, Origin), one per container for a truck (Inland transport, Border, Customs, Delivery):
-- each truck arrives on its own day.
CREATE   FUNCTION logistics.fn_Container_NextLegProposal
(
    @ContainerId   INT,
    @PlaceId       INT,
    @LastStage     NVARCHAR(10),
    @IsCleared     BIT,
    @HistTypeId    INT,
    @HistToPlaceId INT,
    @HistLegs      INT
)
RETURNS TABLE
AS
RETURN
SELECT TypeId = t.Id, TypeCode = t.TypeCode, TypeName = t.TypeName, Stage = t.Stage,
       FromPlaceId = @PlaceId, FromName = fp.PortName,
       ToPlaceId = tp.Id, ToName = tp.PortName,
       Source = sr.Source,
       Legs = CASE WHEN sr.Source = N'History' THEN @HistLegs END,
       IsStay = CAST(CASE WHEN t.Stage IN (N'Port', N'Customs', N'Border') THEN 1 ELSE 0 END AS BIT),
       OnePerContainer = CAST(CASE WHEN t.Id IS NULL OR t.Stage IN (N'Sea', N'Port', N'Origin') OR t.TypeCode = N'TRANSHIP'
                                   THEN 0 ELSE 1 END AS BIT)
FROM logistics.Containers c
LEFT JOIN masterdata.Ports pk ON pk.Id = @PlaceId
LEFT JOIN masterdata.Ports fp ON fp.Id = @PlaceId
CROSS APPLY (SELECT Mode = CASE WHEN @LastStage IS NULL AND c.PortOfDestinationId IS NOT NULL THEN N'Ports'
                                WHEN @HistTypeId IS NOT NULL THEN N'History'
                                WHEN @LastStage IS NULL OR @LastStage = N'Origin' THEN N'Sea'
                                WHEN @IsCleared = 1 OR @LastStage = N'Customs' THEN N'Delivery'
                                WHEN @LastStage IN (N'Sea', N'Port') OR pk.Kind = N'Sea' THEN N'Inland'
                                ELSE N'Customs' END) m
CROSS APPLY (SELECT WantStage = CASE m.Mode WHEN N'Ports' THEN N'Sea' WHEN N'Sea' THEN N'Sea' WHEN N'Delivery' THEN N'Delivery'
                                            WHEN N'Inland' THEN N'Transit' WHEN N'Customs' THEN N'Customs' END,
                    WantCode  = CASE m.Mode WHEN N'Ports' THEN N'SEA' WHEN N'Sea' THEN N'SEA' WHEN N'Delivery' THEN N'DELIVERY'
                                            WHEN N'Inland' THEN N'INLAND' WHEN N'Customs' THEN N'CUSTOMS' END) w
OUTER APPLY (SELECT TOP (1) x.Id, x.TypeCode, x.TypeName, x.Stage
             FROM masterdata.MovementTypes x
             WHERE x.IsActive = 1
               AND ((m.Mode = N'History' AND x.Id = @HistTypeId) OR (m.Mode <> N'History' AND x.Stage = w.WantStage))
             ORDER BY CASE WHEN x.TypeCode = w.WantCode THEN 0 ELSE 1 END, x.SortOrder, x.Id) t
CROSS APPLY (SELECT Source = CAST(CASE WHEN t.Id IS NULL THEN N'None'
                                       WHEN m.Mode = N'History' AND t.Stage = N'Delivery' AND c.FinalDestinationId IS NOT NULL
                                            AND c.FinalDestinationId <> ISNULL(@HistToPlaceId, 0) THEN N'Ports'
                                       WHEN m.Mode = N'History' THEN N'History'
                                       WHEN m.Mode = N'Ports' OR (m.Mode = N'Sea' AND c.PortOfDestinationId IS NOT NULL) THEN N'Ports'
                                       ELSE N'Stages' END AS NVARCHAR(10))) sr
LEFT JOIN masterdata.Ports tp
       ON tp.IsActive = 1
      AND tp.Id = CASE WHEN t.Stage IN (N'Port', N'Customs', N'Border') THEN @PlaceId
                       WHEN m.Mode = N'History' AND t.Stage = N'Delivery' THEN ISNULL(c.FinalDestinationId, @HistToPlaceId)
                       WHEN m.Mode = N'History' THEN @HistToPlaceId
                       WHEN m.Mode IN (N'Ports', N'Sea') THEN c.PortOfDestinationId
                       WHEN m.Mode = N'Delivery' THEN c.FinalDestinationId END
WHERE c.Id = @ContainerId AND ISNULL(@LastStage, N'') <> N'Delivery';

GO

