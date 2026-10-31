CREATE TYPE [logistics].[tvp_LegContainer] AS TABLE (
    [ContainerId]     INT            NOT NULL,
    [VehicleOrVessel] NVARCHAR (100) NULL,
    [Eta]             DATE           NULL,
    PRIMARY KEY CLUSTERED ([ContainerId] ASC));


GO

