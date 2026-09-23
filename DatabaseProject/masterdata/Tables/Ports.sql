CREATE TABLE [masterdata].[Ports] (
    [Id]           INT            IDENTITY (1, 1) NOT NULL,
    [PortCode]     NVARCHAR (10)  NOT NULL,
    [PortName]     NVARCHAR (100) NOT NULL,
    [CountryCode]  NCHAR (2)      NULL,
    [Kind]         NVARCHAR (10)  NOT NULL,
    [IsActive]     BIT            NOT NULL,
    [CreatedAtUtc] DATETIME2 (3)  NOT NULL,
    [CreatedBy]    INT            NULL,
    [UpdatedAtUtc] DATETIME2 (3)  NULL,
    [UpdatedBy]    INT            NULL,
    [RowVersion]   ROWVERSION     NOT NULL
);
GO

ALTER TABLE [masterdata].[Ports]
    ADD CONSTRAINT [FK_Ports_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]);
GO

ALTER TABLE [masterdata].[Ports]
    ADD CONSTRAINT [FK_Ports_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id]);
GO

ALTER TABLE [masterdata].[Ports]
    ADD CONSTRAINT [DF_Ports_Kind] DEFAULT (N'Sea') FOR [Kind];
GO

ALTER TABLE [masterdata].[Ports]
    ADD CONSTRAINT [DF_Ports_CreatedAtUtc] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];
GO

ALTER TABLE [masterdata].[Ports]
    ADD CONSTRAINT [DF_Ports_IsActive] DEFAULT ((1)) FOR [IsActive];
GO

ALTER TABLE [masterdata].[Ports]
    ADD CONSTRAINT [CK_Ports_Kind] CHECK ([Kind]=N'Air' OR [Kind]=N'Border' OR [Kind]=N'Inland' OR [Kind]=N'Sea');
GO

ALTER TABLE [masterdata].[Ports]
    ADD CONSTRAINT [PK_Ports] PRIMARY KEY CLUSTERED ([Id] ASC);
GO

ALTER TABLE [masterdata].[Ports]
    ADD CONSTRAINT [UQ_Ports_Code] UNIQUE NONCLUSTERED ([PortCode] ASC);
GO

