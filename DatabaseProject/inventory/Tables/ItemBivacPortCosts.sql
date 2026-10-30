CREATE TABLE [inventory].[ItemBivacPortCosts] (
    [Id]           INT             IDENTITY (1, 1) NOT NULL,
    [ItemId]       INT             NOT NULL,
    [PortId]       INT             NOT NULL,
    [CostBase]     DECIMAL (18, 2) NOT NULL,
    [UpdatedAtUtc] DATETIME2 (3)   CONSTRAINT [DF_ItemBivacPortCosts_Updated] DEFAULT (sysutcdatetime()) NOT NULL,
    [UpdatedBy]    INT             NULL,
    CONSTRAINT [PK_ItemBivacPortCosts] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_ItemBivacPortCosts_Cost] CHECK ([CostBase]>=(0)),
    CONSTRAINT [FK_ItemBivacPortCosts_Item] FOREIGN KEY ([ItemId]) REFERENCES [inventory].[Items] ([Id]) ON DELETE CASCADE,
    CONSTRAINT [FK_ItemBivacPortCosts_Port] FOREIGN KEY ([PortId]) REFERENCES [masterdata].[Ports] ([Id]),
    CONSTRAINT [UQ_ItemBivacPortCosts] UNIQUE NONCLUSTERED ([ItemId] ASC, [PortId] ASC)
);


GO

