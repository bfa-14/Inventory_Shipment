CREATE TABLE [masterdata].[Branches] (
    [Id]           INT            IDENTITY (1, 1) NOT NULL,
    [BranchCode]   NVARCHAR (20)  NOT NULL,
    [BranchName]   NVARCHAR (150) NOT NULL,
    [Address]      NVARCHAR (500) NULL,
    [IsMainBranch] BIT            CONSTRAINT [DF_Branches_IsMainBranch] DEFAULT ((0)) NOT NULL,
    [IsActive]     BIT            CONSTRAINT [DF_Branches_IsActive] DEFAULT ((1)) NOT NULL,
    [CreatedAtUtc] DATETIME2 (3)  CONSTRAINT [DF_Branches_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]    INT            NULL,
    [UpdatedAtUtc] DATETIME2 (3)  NULL,
    [UpdatedBy]    INT            NULL,
    [RowVersion]   ROWVERSION     NOT NULL,
    CONSTRAINT [PK_Branches] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_Branches_BranchCode_NotBlank] CHECK (len(ltrim(rtrim([BranchCode])))>(0)),
    CONSTRAINT [CK_Branches_BranchName_NotBlank] CHECK (len(ltrim(rtrim([BranchName])))>(0)),
    CONSTRAINT [CK_Branches_MainIsActive] CHECK ([IsMainBranch]=(0) OR [IsActive]=(1)),
    CONSTRAINT [FK_Branches_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_Branches_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [UQ_Branches_BranchCode] UNIQUE NONCLUSTERED ([BranchCode] ASC)
);


GO

CREATE NONCLUSTERED INDEX [IX_Branches_BranchName]
    ON [masterdata].[Branches]([BranchName] ASC);


GO

CREATE UNIQUE NONCLUSTERED INDEX [UX_Branches_ActiveMainBranch]
    ON [masterdata].[Branches]([IsMainBranch] ASC) WHERE ([IsMainBranch]=(1) AND [IsActive]=(1));


GO

