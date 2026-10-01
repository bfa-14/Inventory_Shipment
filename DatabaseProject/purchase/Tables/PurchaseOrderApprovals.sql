CREATE TABLE [purchase].[PurchaseOrderApprovals] (
    [Id]              INT            IDENTITY (1, 1) NOT NULL,
    [DocumentId]      INT            NOT NULL,
    [RequestNo]       INT            NOT NULL,
    [ApproverUserId]  INT            NOT NULL,
    [TokenHash]       VARBINARY (32) NOT NULL,
    [ExpiresAtUtc]    DATETIME2 (3)  NOT NULL,
    [Status]          TINYINT        CONSTRAINT [DF_PurchaseOrderApprovals_Status] DEFAULT ((1)) NOT NULL,
    [DecidedAtUtc]    DATETIME2 (3)  NULL,
    [DecisionNote]    NVARCHAR (300) NULL,
    [Channel]         NVARCHAR (10)  NULL,
    [RequestedBy]     INT            NULL,
    [RequestedAtUtc]  DATETIME2 (3)  CONSTRAINT [DF_PurchaseOrderApprovals_RequestedAt] DEFAULT (sysutcdatetime()) NOT NULL,
    [ClosedByEventId] BIGINT         NULL,
    CONSTRAINT [PK_PurchaseOrderApprovals] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_PurchaseOrderApprovals_Status] CHECK ([Status]>=(1) AND [Status]<=(4)),
    CONSTRAINT [FK_PurchaseOrderApprovals_Approver] FOREIGN KEY ([ApproverUserId]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_PurchaseOrderApprovals_Document] FOREIGN KEY ([DocumentId]) REFERENCES [purchase].[PurchaseDocuments] ([Id]),
    CONSTRAINT [FK_PurchaseOrderApprovals_Requested] FOREIGN KEY ([RequestedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [UQ_PurchaseOrderApprovals_Token] UNIQUE NONCLUSTERED ([TokenHash] ASC)
);


GO

CREATE NONCLUSTERED INDEX [IX_PurchaseOrderApprovals_Document]
    ON [purchase].[PurchaseOrderApprovals]([DocumentId] ASC, [Status] ASC);


GO

