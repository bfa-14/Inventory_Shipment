CREATE TABLE [masterdata].[ContainerTypes] (
    [Id]           INT             IDENTITY (1, 1) NOT NULL,
    [TypeCode]     NVARCHAR (10)   NOT NULL,
    [TypeName]     NVARCHAR (100)  NOT NULL,
    [MaxUnits]     INT             NULL,
    [MaxWeightKg]  DECIMAL (18, 3) NULL,
    [MaxVolumeCbm] DECIMAL (18, 3) NULL,
    [Description]  NVARCHAR (500)  NULL,
    [IsActive]     BIT             NOT NULL,
    [CreatedAtUtc] DATETIME2 (3)   NOT NULL,
    [CreatedBy]    INT             NULL,
    [UpdatedAtUtc] DATETIME2 (3)   NULL,
    [UpdatedBy]    INT             NULL,
    [RowVersion]   ROWVERSION      NOT NULL
);
GO

ALTER TABLE [masterdata].[ContainerTypes]
    ADD CONSTRAINT [CK_ContainerTypes_Weight] CHECK ([MaxWeightKg] IS NULL OR [MaxWeightKg]>(0));
GO

ALTER TABLE [masterdata].[ContainerTypes]
    ADD CONSTRAINT [CK_ContainerTypes_MaxUnits] CHECK ([MaxUnits] IS NULL OR [MaxUnits]>(0));
GO

ALTER TABLE [masterdata].[ContainerTypes]
    ADD CONSTRAINT [CK_ContainerTypes_Volume] CHECK ([MaxVolumeCbm] IS NULL OR [MaxVolumeCbm]>(0));
GO

ALTER TABLE [masterdata].[ContainerTypes]
    ADD CONSTRAINT [DF_ContainerTypes_CreatedAtUtc] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];
GO

ALTER TABLE [masterdata].[ContainerTypes]
    ADD CONSTRAINT [DF_ContainerTypes_IsActive] DEFAULT ((1)) FOR [IsActive];
GO

ALTER TABLE [masterdata].[ContainerTypes]
    ADD CONSTRAINT [PK_ContainerTypes] PRIMARY KEY CLUSTERED ([Id] ASC);
GO

ALTER TABLE [masterdata].[ContainerTypes]
    ADD CONSTRAINT [FK_ContainerTypes_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]);
GO

ALTER TABLE [masterdata].[ContainerTypes]
    ADD CONSTRAINT [FK_ContainerTypes_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id]);
GO

ALTER TABLE [masterdata].[ContainerTypes]
    ADD CONSTRAINT [UQ_ContainerTypes_Code] UNIQUE NONCLUSTERED ([TypeCode] ASC);
GO

