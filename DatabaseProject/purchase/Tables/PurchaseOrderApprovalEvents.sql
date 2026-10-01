CREATE TABLE [purchase].[PurchaseOrderApprovalEvents] (
    [Id]                 BIGINT          IDENTITY (1, 1) NOT NULL,
    [PurchaseDocumentId] INT             NOT NULL,
    [EventType]          TINYINT         NOT NULL,
    [Channel]            TINYINT         NULL,
    [UserId]             INT             NULL,
    [Recipients]         NVARCHAR (1000) NULL,
    [Reason]             NVARCHAR (500)  NULL,
    [Note]               NVARCHAR (200)  NULL,
    [AtUtc]              DATETIME2 (0)   CONSTRAINT [DF_PurchaseOrderApprovalEvents_AtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    CONSTRAINT [PK_PurchaseOrderApprovalEvents] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_PurchaseOrderApprovalEvents_Channel] CHECK ([Channel] IS NULL OR ([Channel]=(2) OR [Channel]=(1))),
    CONSTRAINT [CK_PurchaseOrderApprovalEvents_Type] CHECK ([EventType]>=(1) AND [EventType]<=(9)),
    CONSTRAINT [FK_PurchaseOrderApprovalEvents_Document] FOREIGN KEY ([PurchaseDocumentId]) REFERENCES [purchase].[PurchaseDocuments] ([Id]) ON DELETE CASCADE,
    CONSTRAINT [FK_PurchaseOrderApprovalEvents_User] FOREIGN KEY ([UserId]) REFERENCES [security].[Users] ([Id])
);


GO

CREATE NONCLUSTERED INDEX [IX_PurchaseOrderApprovalEvents_Document]
    ON [purchase].[PurchaseOrderApprovalEvents]([PurchaseDocumentId] ASC, [AtUtc] ASC);


GO

