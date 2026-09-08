CREATE TABLE [masterdata].[UnitPriceHistory] (
    [Id]            BIGINT          IDENTITY (1, 1) NOT NULL,
    [UnitPriceId]   INT             NULL,
    [BranchId]      INT             NULL,
    [BranchName]    NVARCHAR (150)  NOT NULL,
    [ItemId]        INT             NOT NULL,
    [ItemCode]      NVARCHAR (30)   NOT NULL,
    [ItemName]      NVARCHAR (200)  NOT NULL,
    [ItemUnitId]    INT             NOT NULL,
    [UnitTypeName]  NVARCHAR (50)   NOT NULL,
    [PriceListId]   INT             NOT NULL,
    [PriceListName] NVARCHAR (100)  NOT NULL,
    [CurrencyCode]  NVARCHAR (3)    NOT NULL,
    [OldPrice]      DECIMAL (18, 4) NULL,
    [NewPrice]      DECIMAL (18, 4) NULL,
    [ChangeType]    TINYINT         NOT NULL,
    [ChangedBy]     INT             NULL,
    [ChangedByName] NVARCHAR (100)  NOT NULL,
    [ChangedAtUtc]  DATETIME2 (3)   CONSTRAINT [DF_UnitPriceHistory_ChangedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    CONSTRAINT [PK_UnitPriceHistory] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_UnitPriceHistory_ChangeType] CHECK ([ChangeType]>=(1) AND [ChangeType]<=(5)),
    CONSTRAINT [FK_UnitPriceHistory_ChangedBy] FOREIGN KEY ([ChangedBy]) REFERENCES [security].[Users] ([Id])
);


GO
CREATE NONCLUSTERED INDEX [IX_UnitPriceHistory_Key]
    ON [masterdata].[UnitPriceHistory]([ItemUnitId] ASC, [PriceListId] ASC, [BranchId] ASC, [ChangedAtUtc] DESC);

