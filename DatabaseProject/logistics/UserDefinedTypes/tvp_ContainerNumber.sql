CREATE TYPE [logistics].[tvp_ContainerNumber] AS TABLE (
    [ContainerId] INT           NOT NULL,
    [ContainerNo] NVARCHAR (20) NULL,
    [SealNo]      NVARCHAR (30) NULL,
    PRIMARY KEY CLUSTERED ([ContainerId] ASC));


GO

