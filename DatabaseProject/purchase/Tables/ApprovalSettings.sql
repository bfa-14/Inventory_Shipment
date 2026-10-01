CREATE TABLE [purchase].[ApprovalSettings] (
    [Id]                      TINYINT         NOT NULL,
    [RequireApproval]         BIT             CONSTRAINT [DF_ApprovalSettings_RequireApproval] DEFAULT ((1)) NOT NULL,
    [ApprovalLimitBase]       DECIMAL (19, 4) CONSTRAINT [DF_ApprovalSettings_ApprovalLimitBase] DEFAULT ((0)) NOT NULL,
    [AllowSelfApproval]       BIT             CONSTRAINT [DF_ApprovalSettings_AllowSelfApproval] DEFAULT ((1)) NOT NULL,
    [LinkValidHours]          INT             CONSTRAINT [DF_ApprovalSettings_LinkValidHours] DEFAULT ((72)) NOT NULL,
    [ReminderHours]           INT             CONSTRAINT [DF_ApprovalSettings_ReminderHours] DEFAULT ((24)) NOT NULL,
    [NotifyAppApprovers]      BIT             CONSTRAINT [DF_ApprovalSettings_NotifyAppApprovers] DEFAULT ((1)) NOT NULL,
    [EmailSupplierOnApproval] BIT             CONSTRAINT [DF_ApprovalSettings_EmailSupplier] DEFAULT ((1)) NOT NULL,
    [CopyToOwners]            BIT             CONSTRAINT [DF_ApprovalSettings_CopyToOwners] DEFAULT ((1)) NOT NULL,
    [CopyToEmails]            NVARCHAR (1000) NULL,
    [UpdatedAtUtc]            DATETIME2 (0)   NULL,
    [UpdatedBy]               INT             NULL,
    [RowVersion]              ROWVERSION      NOT NULL,
    CONSTRAINT [PK_ApprovalSettings] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_ApprovalSettings_Id] CHECK ([Id]=(1)),
    CONSTRAINT [CK_ApprovalSettings_Limit] CHECK ([ApprovalLimitBase]>=(0)),
    CONSTRAINT [CK_ApprovalSettings_LinkValidHours] CHECK ([LinkValidHours]>=(1) AND [LinkValidHours]<=(720)),
    CONSTRAINT [CK_ApprovalSettings_ReminderHours] CHECK ([ReminderHours]>=(0) AND [ReminderHours]<=(168)),
    CONSTRAINT [FK_ApprovalSettings_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id])
);


GO

