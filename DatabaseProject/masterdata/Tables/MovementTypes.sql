CREATE TABLE [masterdata].[MovementTypes] (
    [Id]           INT            IDENTITY (1, 1) NOT NULL,
    [TypeCode]     NVARCHAR (10)  NOT NULL,
    [TypeName]     NVARCHAR (100) NOT NULL,
    [Stage]        NVARCHAR (10)  NOT NULL,
    [SortOrder]    INT            CONSTRAINT [DF_MovementTypes_Sort] DEFAULT ((0)) NOT NULL,
    [IsActive]     BIT            CONSTRAINT [DF_MovementTypes_IsActive] DEFAULT ((1)) NOT NULL,
    [CreatedAtUtc] DATETIME2 (3)  CONSTRAINT [DF_MovementTypes_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]    INT            NULL,
    [UpdatedAtUtc] DATETIME2 (3)  NULL,
    [UpdatedBy]    INT            NULL,
    [RowVersion]   ROWVERSION     NOT NULL,
    CONSTRAINT [PK_MovementTypes] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_MovementTypes_Stage] CHECK ([Stage]=N'Delivery' OR [Stage]=N'Customs' OR [Stage]=N'Border' OR [Stage]=N'Port' OR [Stage]=N'Transit' OR [Stage]=N'Sea' OR [Stage]=N'Origin'),
    CONSTRAINT [FK_MovementTypes_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_MovementTypes_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [UQ_MovementTypes_Code] UNIQUE NONCLUSTERED ([TypeCode] ASC)
);


GO

