CREATE TABLE [inventory].[ShortageDocuments] (
    [Id]                      INT             IDENTITY (1, 1) NOT NULL,
    [DocumentTypeId]          INT             NOT NULL,
    [DocumentNumber]          NVARCHAR (30)   NOT NULL,
    [Description]             NVARCHAR (200)  NOT NULL,
    [DocumentDate]            DATE            NOT NULL,
    [BranchId]                INT             NOT NULL,
    [WarehouseId]             INT             NOT NULL,
    [SupplierId]              INT             NOT NULL,
    [LeadTimeMonths]          DECIMAL (6, 2)  NOT NULL,
    [MonthsOfHistory]         INT             NOT NULL,
    [Notes]                   NVARCHAR (1000) NULL,
    [Status]                  TINYINT         NOT NULL,
    [TotalLines]              INT             NOT NULL,
    [TotalShortageBase]       INT             NOT NULL,
    [TotalRequiredBase]       INT             NOT NULL,
    [TotalContainers]         DECIMAL (9, 2)  NOT NULL,
    [ContainersRounded]       INT             NOT NULL,
    [ContainerUtilizationPct] DECIMAL (5, 2)  NULL,
    [CalculatedAtUtc]         DATETIME2 (3)   NULL,
    [PostedAtUtc]             DATETIME2 (3)   NULL,
    [PostedBy]                INT             NULL,
    [CreatedAtUtc]            DATETIME2 (3)   NOT NULL,
    [CreatedBy]               INT             NULL,
    [UpdatedAtUtc]            DATETIME2 (3)   NULL,
    [UpdatedBy]               INT             NULL,
    [RowVersion]              ROWVERSION      NOT NULL
);
GO

CREATE NONCLUSTERED INDEX [IX_ShortageDocuments_Date]
    ON [inventory].[ShortageDocuments]([DocumentDate] DESC);
GO

CREATE NONCLUSTERED INDEX [IX_ShortageDocuments_Warehouse]
    ON [inventory].[ShortageDocuments]([WarehouseId] ASC, [Status] ASC);
GO

CREATE NONCLUSTERED INDEX [IX_ShortageDocuments_Supplier]
    ON [inventory].[ShortageDocuments]([SupplierId] ASC);
GO

ALTER TABLE [inventory].[ShortageDocuments]
    ADD CONSTRAINT [FK_ShortageDocuments_Type] FOREIGN KEY ([DocumentTypeId]) REFERENCES [inventory].[DocumentTypes] ([Id]);
GO

ALTER TABLE [inventory].[ShortageDocuments]
    ADD CONSTRAINT [FK_ShortageDocuments_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]);
GO

ALTER TABLE [inventory].[ShortageDocuments]
    ADD CONSTRAINT [FK_ShortageDocuments_Warehouse] FOREIGN KEY ([WarehouseId]) REFERENCES [masterdata].[Warehouses] ([Id]);
GO

ALTER TABLE [inventory].[ShortageDocuments]
    ADD CONSTRAINT [FK_ShortageDocuments_PostedBy] FOREIGN KEY ([PostedBy]) REFERENCES [security].[Users] ([Id]);
GO

ALTER TABLE [inventory].[ShortageDocuments]
    ADD CONSTRAINT [FK_ShortageDocuments_Branch] FOREIGN KEY ([BranchId]) REFERENCES [masterdata].[Branches] ([Id]);
GO

ALTER TABLE [inventory].[ShortageDocuments]
    ADD CONSTRAINT [FK_ShortageDocuments_Supplier] FOREIGN KEY ([SupplierId]) REFERENCES [masterdata].[Parties] ([Id]);
GO

ALTER TABLE [inventory].[ShortageDocuments]
    ADD CONSTRAINT [FK_ShortageDocuments_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id]);
GO

ALTER TABLE [inventory].[ShortageDocuments]
    ADD CONSTRAINT [CK_ShortageDocuments_History] CHECK ([MonthsOfHistory]>=(1) AND [MonthsOfHistory]<=(36));
GO

ALTER TABLE [inventory].[ShortageDocuments]
    ADD CONSTRAINT [CK_ShortageDocuments_LeadTime] CHECK ([LeadTimeMonths]>(0));
GO

ALTER TABLE [inventory].[ShortageDocuments]
    ADD CONSTRAINT [CK_ShortageDocuments_Status] CHECK ([Status]=(2) OR [Status]=(1));
GO

ALTER TABLE [inventory].[ShortageDocuments]
    ADD CONSTRAINT [DF_ShortageDocuments_Containers] DEFAULT ((0)) FOR [TotalContainers];
GO

ALTER TABLE [inventory].[ShortageDocuments]
    ADD CONSTRAINT [DF_ShortageDocuments_ContainersRounded] DEFAULT ((0)) FOR [ContainersRounded];
GO

ALTER TABLE [inventory].[ShortageDocuments]
    ADD CONSTRAINT [DF_ShortageDocuments_History] DEFAULT ((3)) FOR [MonthsOfHistory];
GO

ALTER TABLE [inventory].[ShortageDocuments]
    ADD CONSTRAINT [DF_ShortageDocuments_Lines] DEFAULT ((0)) FOR [TotalLines];
GO

ALTER TABLE [inventory].[ShortageDocuments]
    ADD CONSTRAINT [DF_ShortageDocuments_Shortage] DEFAULT ((0)) FOR [TotalShortageBase];
GO

ALTER TABLE [inventory].[ShortageDocuments]
    ADD CONSTRAINT [DF_ShortageDocuments_Required] DEFAULT ((0)) FOR [TotalRequiredBase];
GO

ALTER TABLE [inventory].[ShortageDocuments]
    ADD CONSTRAINT [DF_ShortageDocuments_CreatedAtUtc] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];
GO

ALTER TABLE [inventory].[ShortageDocuments]
    ADD CONSTRAINT [DF_ShortageDocuments_Status] DEFAULT ((1)) FOR [Status];
GO

ALTER TABLE [inventory].[ShortageDocuments]
    ADD CONSTRAINT [PK_ShortageDocuments] PRIMARY KEY CLUSTERED ([Id] ASC);
GO

ALTER TABLE [inventory].[ShortageDocuments]
    ADD CONSTRAINT [UQ_ShortageDocuments_Number] UNIQUE NONCLUSTERED ([DocumentNumber] ASC);
GO

