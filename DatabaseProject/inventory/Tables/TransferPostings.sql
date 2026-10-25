CREATE TABLE [inventory].[TransferPostings] (
    [Id]                 INT             IDENTITY (1, 1) NOT NULL,
    [TransferOrderId]    INT             NOT NULL,
    [DocumentTypeId]     INT             NOT NULL,
    [Kind]               NVARCHAR (10)   NOT NULL,
    [DocumentNumber]     NVARCHAR (30)   NOT NULL,
    [PostingDate]        DATE            NOT NULL,
    [Eta]                DATE            NULL,
    [BranchId]           INT             NOT NULL,
    [FromWarehouseId]    INT             NOT NULL,
    [ToWarehouseId]      INT             NOT NULL,
    [TransitWarehouseId] INT             NULL,
    [ReferenceNo]        NVARCHAR (100)  NULL,
    [Notes]              NVARCHAR (1000) NULL,
    [PostedWithId]       INT             NULL,
    [Status]             TINYINT         CONSTRAINT [DF_TransferPostings_Status] DEFAULT ((2)) NOT NULL,
    [TotalQuantityBase]  INT             CONSTRAINT [DF_TransferPostings_Quantity] DEFAULT ((0)) NOT NULL,
    [TotalLostBase]      INT             CONSTRAINT [DF_TransferPostings_Lost] DEFAULT ((0)) NOT NULL,
    [ValueBase]          DECIMAL (18, 2) CONSTRAINT [DF_TransferPostings_Value] DEFAULT ((0)) NOT NULL,
    [LostValueBase]      DECIMAL (18, 2) CONSTRAINT [DF_TransferPostings_LostValue] DEFAULT ((0)) NOT NULL,
    [PostedAtUtc]        DATETIME2 (3)   CONSTRAINT [DF_TransferPostings_PostedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [PostedBy]           INT             NULL,
    [ReversedAtUtc]      DATETIME2 (3)   NULL,
    [ReversedBy]         INT             NULL,
    [ReverseDate]        DATE            NULL,
    [ReverseReason]      NVARCHAR (300)  NULL,
    CONSTRAINT [PK_TransferPostings] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_TransferPostings_Eta] CHECK ([Kind]=N'Dispatch' AND [Eta] IS NOT NULL AND [Eta]>=[PostingDate] OR [Kind]=N'Receipt' AND [Eta] IS NULL),
    CONSTRAINT [CK_TransferPostings_Kind] CHECK ([Kind]=N'Receipt' OR [Kind]=N'Dispatch'),
    CONSTRAINT [CK_TransferPostings_Reversed] CHECK ([Status]=(2) OR [ReversedAtUtc] IS NOT NULL AND [ReverseDate] IS NOT NULL AND [ReverseReason] IS NOT NULL),
    CONSTRAINT [CK_TransferPostings_Status] CHECK ([Status]=(3) OR [Status]=(2)),
    CONSTRAINT [CK_TransferPostings_Transit] CHECK ([Kind]=N'Dispatch' AND [TransitWarehouseId] IS NOT NULL OR [Kind]=N'Receipt'),
    CONSTRAINT [FK_TransferPostings_Branch] FOREIGN KEY ([BranchId]) REFERENCES [masterdata].[Branches] ([Id]),
    CONSTRAINT [FK_TransferPostings_From] FOREIGN KEY ([FromWarehouseId]) REFERENCES [masterdata].[Warehouses] ([Id]),
    CONSTRAINT [FK_TransferPostings_Order] FOREIGN KEY ([TransferOrderId]) REFERENCES [inventory].[TransferOrders] ([Id]),
    CONSTRAINT [FK_TransferPostings_PostedBy] FOREIGN KEY ([PostedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_TransferPostings_PostedWith] FOREIGN KEY ([PostedWithId]) REFERENCES [inventory].[TransferPostings] ([Id]),
    CONSTRAINT [FK_TransferPostings_ReversedBy] FOREIGN KEY ([ReversedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_TransferPostings_To] FOREIGN KEY ([ToWarehouseId]) REFERENCES [masterdata].[Warehouses] ([Id]),
    CONSTRAINT [FK_TransferPostings_Transit] FOREIGN KEY ([TransitWarehouseId]) REFERENCES [masterdata].[Warehouses] ([Id]),
    CONSTRAINT [FK_TransferPostings_Type] FOREIGN KEY ([DocumentTypeId]) REFERENCES [inventory].[DocumentTypes] ([Id])
);


GO

CREATE UNIQUE NONCLUSTERED INDEX [UX_TransferPostings_Number]
    ON [inventory].[TransferPostings]([DocumentNumber] ASC);


GO

CREATE NONCLUSTERED INDEX [IX_TransferPostings_Order]
    ON [inventory].[TransferPostings]([TransferOrderId] ASC, [Kind] ASC, [Status] ASC)
    INCLUDE([Eta], [PostingDate], [DocumentNumber]);


GO

CREATE NONCLUSTERED INDEX [IX_TransferPostings_PostedWith]
    ON [inventory].[TransferPostings]([PostedWithId] ASC) WHERE ([PostedWithId] IS NOT NULL);


GO

