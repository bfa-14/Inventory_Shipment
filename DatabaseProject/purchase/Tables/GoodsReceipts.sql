CREATE TABLE [purchase].[GoodsReceipts] (
    [Id]                 INT             IDENTITY (1, 1) NOT NULL,
    [DocumentTypeId]     INT             NOT NULL,
    [DocumentNumber]     NVARCHAR (30)   NULL,
    [DocumentDate]       DATE            NOT NULL,
    [BranchId]           INT             NOT NULL,
    [WarehouseId]        INT             NULL,
    [SupplierId]         INT             NULL,
    [SourceKind]         NVARCHAR (10)   NOT NULL,
    [ContainerId]        INT             NULL,
    [PurchaseOrderId]    INT             NULL,
    [PurchaseInvoiceId]  INT             NULL,
    [MovementId]         INT             NULL,
    [IsAuto]             BIT             CONSTRAINT [DF_GoodsReceipts_IsAuto] DEFAULT ((0)) NOT NULL,
    [SupplierReference]  NVARCHAR (100)  NULL,
    [Notes]              NVARCHAR (1000) NULL,
    [Status]             TINYINT         CONSTRAINT [DF_GoodsReceipts_Status] DEFAULT ((1)) NOT NULL,
    [TotalExpectedBase]  INT             CONSTRAINT [DF_GoodsReceipts_Expected] DEFAULT ((0)) NOT NULL,
    [TotalReceivedBase]  INT             CONSTRAINT [DF_GoodsReceipts_Received] DEFAULT ((0)) NOT NULL,
    [ValueAtReceiptBase] DECIMAL (18, 2) CONSTRAINT [DF_GoodsReceipts_Value] DEFAULT ((0)) NOT NULL,
    [PostedAtUtc]        DATETIME2 (3)   NULL,
    [PostedBy]           INT             NULL,
    [CancelledAtUtc]     DATETIME2 (3)   NULL,
    [CancelledBy]        INT             NULL,
    [CancelReason]       NVARCHAR (300)  NULL,
    [CreatedAtUtc]       DATETIME2 (3)   CONSTRAINT [DF_GoodsReceipts_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]          INT             NULL,
    [UpdatedAtUtc]       DATETIME2 (3)   NULL,
    [UpdatedBy]          INT             NULL,
    [RowVersion]         ROWVERSION      NOT NULL,
    CONSTRAINT [PK_GoodsReceipts] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_GoodsReceipts_Auto] CHECK ([IsAuto]=(0) OR [SourceKind]=N'Container' AND [MovementId] IS NOT NULL),
    CONSTRAINT [CK_GoodsReceipts_Cancelled] CHECK ([Status]<>(3) OR [CancelledAtUtc] IS NOT NULL),
    CONSTRAINT [CK_GoodsReceipts_Container] CHECK ([SourceKind]=N'Container' AND [ContainerId] IS NOT NULL OR [SourceKind]<>N'Container' AND [ContainerId] IS NULL),
    CONSTRAINT [CK_GoodsReceipts_Invoice] CHECK ([SourceKind]<>N'Invoice' OR [PurchaseInvoiceId] IS NOT NULL),
    CONSTRAINT [CK_GoodsReceipts_Manual] CHECK ([SourceKind]<>N'Manual' OR [SupplierId] IS NOT NULL),
    CONSTRAINT [CK_GoodsReceipts_Posted] CHECK ([Status]=(1) OR [DocumentNumber] IS NOT NULL AND [PostedAtUtc] IS NOT NULL),
    CONSTRAINT [CK_GoodsReceipts_Source] CHECK ([SourceKind]=N'Manual' OR [SourceKind]=N'Invoice' OR [SourceKind]=N'Order' OR [SourceKind]=N'Container'),
    CONSTRAINT [CK_GoodsReceipts_Status] CHECK ([Status]=(3) OR [Status]=(2) OR [Status]=(1)),
    CONSTRAINT [FK_GoodsReceipts_Branch] FOREIGN KEY ([BranchId]) REFERENCES [masterdata].[Branches] ([Id]),
    CONSTRAINT [FK_GoodsReceipts_CancelledBy] FOREIGN KEY ([CancelledBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_GoodsReceipts_Container] FOREIGN KEY ([ContainerId]) REFERENCES [logistics].[Containers] ([Id]),
    CONSTRAINT [FK_GoodsReceipts_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_GoodsReceipts_Invoice] FOREIGN KEY ([PurchaseInvoiceId]) REFERENCES [purchase].[PurchaseDocuments] ([Id]),
    CONSTRAINT [FK_GoodsReceipts_Movement] FOREIGN KEY ([MovementId]) REFERENCES [logistics].[Movements] ([Id]),
    CONSTRAINT [FK_GoodsReceipts_Order] FOREIGN KEY ([PurchaseOrderId]) REFERENCES [purchase].[PurchaseDocuments] ([Id]),
    CONSTRAINT [FK_GoodsReceipts_PostedBy] FOREIGN KEY ([PostedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_GoodsReceipts_Supplier] FOREIGN KEY ([SupplierId]) REFERENCES [masterdata].[Parties] ([Id]),
    CONSTRAINT [FK_GoodsReceipts_Type] FOREIGN KEY ([DocumentTypeId]) REFERENCES [inventory].[DocumentTypes] ([Id]),
    CONSTRAINT [FK_GoodsReceipts_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_GoodsReceipts_Warehouse] FOREIGN KEY ([WarehouseId]) REFERENCES [masterdata].[Warehouses] ([Id])
);


GO

CREATE NONCLUSTERED INDEX [IX_GoodsReceipts_StatusDate]
    ON [purchase].[GoodsReceipts]([Status] ASC, [DocumentDate] DESC);


GO

CREATE NONCLUSTERED INDEX [IX_GoodsReceipts_Order]
    ON [purchase].[GoodsReceipts]([PurchaseOrderId] ASC) WHERE ([PurchaseOrderId] IS NOT NULL);


GO

CREATE NONCLUSTERED INDEX [IX_GoodsReceipts_Supplier]
    ON [purchase].[GoodsReceipts]([SupplierId] ASC, [DocumentDate] DESC);


GO

CREATE NONCLUSTERED INDEX [IX_GoodsReceipts_Invoice]
    ON [purchase].[GoodsReceipts]([PurchaseInvoiceId] ASC) WHERE ([PurchaseInvoiceId] IS NOT NULL);


GO

CREATE UNIQUE NONCLUSTERED INDEX [UX_GoodsReceipts_Number]
    ON [purchase].[GoodsReceipts]([DocumentNumber] ASC) WHERE ([DocumentNumber] IS NOT NULL);


GO

CREATE UNIQUE NONCLUSTERED INDEX [UX_GoodsReceipts_OpenContainer]
    ON [purchase].[GoodsReceipts]([ContainerId] ASC) WHERE ([ContainerId] IS NOT NULL AND [Status]<(3));


GO

CREATE NONCLUSTERED INDEX [IX_GoodsReceipts_Movement]
    ON [purchase].[GoodsReceipts]([MovementId] ASC) WHERE ([MovementId] IS NOT NULL);


GO

