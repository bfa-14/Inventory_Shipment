CREATE TABLE [masterdata].[ContainerTypes] (
    [Id]           INT             IDENTITY (1, 1) NOT NULL,
    [TypeCode]     NVARCHAR (10)   NOT NULL,
    [TypeName]     NVARCHAR (100)  NOT NULL,
    [MaxUnits]     INT             NULL,
    [MaxWeightKg]  DECIMAL (18, 3) NULL,
    [MaxVolumeCbm] DECIMAL (18, 3) NULL,
    [Description]  NVARCHAR (500)  NULL,
    [IsActive]     BIT             CONSTRAINT [DF_ContainerTypes_IsActive] DEFAULT ((1)) NOT NULL,
    [CreatedAtUtc] DATETIME2 (3)   CONSTRAINT [DF_ContainerTypes_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]    INT             NULL,
    [UpdatedAtUtc] DATETIME2 (3)   NULL,
    [UpdatedBy]    INT             NULL,
    [RowVersion]   ROWVERSION      NOT NULL,
    CONSTRAINT [PK_ContainerTypes] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_ContainerTypes_MaxUnits] CHECK ([MaxUnits] IS NULL OR [MaxUnits]>(0)),
    CONSTRAINT [CK_ContainerTypes_Volume] CHECK ([MaxVolumeCbm] IS NULL OR [MaxVolumeCbm]>(0)),
    CONSTRAINT [CK_ContainerTypes_Weight] CHECK ([MaxWeightKg] IS NULL OR [MaxWeightKg]>(0)),
    CONSTRAINT [FK_ContainerTypes_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_ContainerTypes_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [UQ_ContainerTypes_Code] UNIQUE NONCLUSTERED ([TypeCode] ASC)
);


GO

