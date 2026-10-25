CREATE TABLE [inventory].[TransferOrders] (
    [Id]                     INT             IDENTITY (1, 1) NOT NULL,
    [DocumentTypeId]         INT             NOT NULL,
    [DocumentNumber]         NVARCHAR (30)   NULL,
    [DocumentDate]           DATE            NOT NULL,
    [BranchId]               INT             NOT NULL,
    [FromWarehouseId]        INT             NOT NULL,
    [ToWarehouseId]          INT             NOT NULL,
    [ExpectedArrival]        DATE            NULL,
    [ReferenceNo]            NVARCHAR (100)  NULL,
    [Notes]                  NVARCHAR (1000) NULL,
    [Status]                 TINYINT         CONSTRAINT [DF_TransferOrders_Status] DEFAULT ((1)) NOT NULL,
    [ReturnOfOrderId]        INT             NULL,
    [TotalLines]             INT             CONSTRAINT [DF_TransferOrders_TotalLines] DEFAULT ((0)) NOT NULL,
    [TotalOrderedBase]       INT             CONSTRAINT [DF_TransferOrders_TotalOrdered] DEFAULT ((0)) NOT NULL,
    [ApprovalRequestedAtUtc] DATETIME2 (3)   NULL,
    [ApprovalRequestedBy]    INT             NULL,
    [ApprovedAtUtc]          DATETIME2 (3)   NULL,
    [ApprovedBy]             INT             NULL,
    [ApprovedDirectly]       BIT             CONSTRAINT [DF_TransferOrders_ApprovedDirectly] DEFAULT ((0)) NOT NULL,
    [RejectedAtUtc]          DATETIME2 (3)   NULL,
    [RejectedBy]             INT             NULL,
    [RejectReason]           NVARCHAR (300)  NULL,
    [ReleasedAtUtc]          DATETIME2 (3)   NULL,
    [ReleasedBy]             INT             NULL,
    [NotSentAtUtc]           DATETIME2 (3)   NULL,
    [NotSentBy]              INT             NULL,
    [NotSentReason]          NVARCHAR (300)  NULL,
    [CancelledAtUtc]         DATETIME2 (3)   NULL,
    [CancelledBy]            INT             NULL,
    [CancelReason]           NVARCHAR (300)  NULL,
    [CreatedAtUtc]           DATETIME2 (3)   CONSTRAINT [DF_TransferOrders_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]              INT             NULL,
    [UpdatedAtUtc]           DATETIME2 (3)   NULL,
    [UpdatedBy]              INT             NULL,
    [RowVersion]             ROWVERSION      NOT NULL,
    CONSTRAINT [PK_TransferOrders] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_TransferOrders_Cancelled] CHECK ([Status]<>(3) OR [CancelledAtUtc] IS NOT NULL),
    CONSTRAINT [CK_TransferOrders_NotSent] CHECK ([NotSentAtUtc] IS NULL OR ([Status]=(3) OR [Status]=(2))),
    CONSTRAINT [CK_TransferOrders_Released] CHECK (NOT ([Status]=(3) OR [Status]=(2)) OR [DocumentNumber] IS NOT NULL),
    CONSTRAINT [CK_TransferOrders_Return] CHECK ([ReturnOfOrderId] IS NULL OR [ReturnOfOrderId]<>[Id]),
    CONSTRAINT [CK_TransferOrders_Status] CHECK ([Status]=(4) OR [Status]=(3) OR [Status]=(2) OR [Status]=(1)),
    CONSTRAINT [CK_TransferOrders_Warehouses] CHECK ([FromWarehouseId]<>[ToWarehouseId]),
    CONSTRAINT [FK_TransferOrders_ApprovedBy] FOREIGN KEY ([ApprovedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_TransferOrders_Branch] FOREIGN KEY ([BranchId]) REFERENCES [masterdata].[Branches] ([Id]),
    CONSTRAINT [FK_TransferOrders_CancelledBy] FOREIGN KEY ([CancelledBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_TransferOrders_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_TransferOrders_From] FOREIGN KEY ([FromWarehouseId]) REFERENCES [masterdata].[Warehouses] ([Id]),
    CONSTRAINT [FK_TransferOrders_NotSentBy] FOREIGN KEY ([NotSentBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_TransferOrders_RejectedBy] FOREIGN KEY ([RejectedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_TransferOrders_ReleasedBy] FOREIGN KEY ([ReleasedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_TransferOrders_RequestedBy] FOREIGN KEY ([ApprovalRequestedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_TransferOrders_ReturnOf] FOREIGN KEY ([ReturnOfOrderId]) REFERENCES [inventory].[TransferOrders] ([Id]),
    CONSTRAINT [FK_TransferOrders_To] FOREIGN KEY ([ToWarehouseId]) REFERENCES [masterdata].[Warehouses] ([Id]),
    CONSTRAINT [FK_TransferOrders_Type] FOREIGN KEY ([DocumentTypeId]) REFERENCES [inventory].[DocumentTypes] ([Id]),
    CONSTRAINT [FK_TransferOrders_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id])
);


GO

CREATE NONCLUSTERED INDEX [IX_TransferOrders_From]
    ON [inventory].[TransferOrders]([FromWarehouseId] ASC, [Status] ASC);


GO

CREATE NONCLUSTERED INDEX [IX_TransferOrders_ReturnOf]
    ON [inventory].[TransferOrders]([ReturnOfOrderId] ASC) WHERE ([ReturnOfOrderId] IS NOT NULL);


GO

CREATE NONCLUSTERED INDEX [IX_TransferOrders_StatusDate]
    ON [inventory].[TransferOrders]([Status] ASC, [DocumentDate] DESC);


GO

CREATE NONCLUSTERED INDEX [IX_TransferOrders_To]
    ON [inventory].[TransferOrders]([ToWarehouseId] ASC, [Status] ASC);


GO

CREATE UNIQUE NONCLUSTERED INDEX [UX_TransferOrders_Number]
    ON [inventory].[TransferOrders]([DocumentNumber] ASC) WHERE ([DocumentNumber] IS NOT NULL);


GO

