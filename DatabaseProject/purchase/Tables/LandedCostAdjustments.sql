CREATE TABLE [purchase].[LandedCostAdjustments] (
    [Id]                   INT             IDENTITY (1, 1) NOT NULL,
    [DocumentTypeId]       INT             NOT NULL,
    [DocumentNumber]       NVARCHAR (30)   NOT NULL,
    [DocumentDate]         DATE            NOT NULL,
    [BranchId]             INT             NOT NULL,
    [SourceInvoiceId]      INT             NOT NULL,
    [Notes]                NVARCHAR (1000) NULL,
    [Status]               TINYINT         NOT NULL,
    [TotalChargesBase]     DECIMAL (18, 2) NOT NULL,
    [InventoryPortionBase] DECIMAL (18, 2) NOT NULL,
    [CogsPortionBase]      DECIMAL (18, 2) NOT NULL,
    [PostedAtUtc]          DATETIME2 (3)   NULL,
    [PostedBy]             INT             NULL,
    [CancelledAtUtc]       DATETIME2 (3)   NULL,
    [CancelledBy]          INT             NULL,
    [CancelReason]         NVARCHAR (300)  NULL,
    [CreatedAtUtc]         DATETIME2 (3)   NOT NULL,
    [CreatedBy]            INT             NULL,
    [UpdatedAtUtc]         DATETIME2 (3)   NULL,
    [UpdatedBy]            INT             NULL,
    [RowVersion]           ROWVERSION      NOT NULL
);
GO

ALTER TABLE [purchase].[LandedCostAdjustments]
    ADD CONSTRAINT [UQ_LandedCostAdjustments_Number] UNIQUE NONCLUSTERED ([DocumentNumber] ASC);
GO

ALTER TABLE [purchase].[LandedCostAdjustments]
    ADD CONSTRAINT [DF_LandedCostAdjustments_CreatedAtUtc] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];
GO

ALTER TABLE [purchase].[LandedCostAdjustments]
    ADD CONSTRAINT [DF_LandedCostAdjustments_Total] DEFAULT ((0)) FOR [TotalChargesBase];
GO

ALTER TABLE [purchase].[LandedCostAdjustments]
    ADD CONSTRAINT [DF_LandedCostAdjustments_Status] DEFAULT ((1)) FOR [Status];
GO

ALTER TABLE [purchase].[LandedCostAdjustments]
    ADD CONSTRAINT [DF_LandedCostAdjustments_Cogs] DEFAULT ((0)) FOR [CogsPortionBase];
GO

ALTER TABLE [purchase].[LandedCostAdjustments]
    ADD CONSTRAINT [DF_LandedCostAdjustments_Inv] DEFAULT ((0)) FOR [InventoryPortionBase];
GO

ALTER TABLE [purchase].[LandedCostAdjustments]
    ADD CONSTRAINT [FK_LandedCostAdjustments_Branch] FOREIGN KEY ([BranchId]) REFERENCES [masterdata].[Branches] ([Id]);
GO

ALTER TABLE [purchase].[LandedCostAdjustments]
    ADD CONSTRAINT [FK_LandedCostAdjustments_Type] FOREIGN KEY ([DocumentTypeId]) REFERENCES [inventory].[DocumentTypes] ([Id]);
GO

ALTER TABLE [purchase].[LandedCostAdjustments]
    ADD CONSTRAINT [FK_LandedCostAdjustments_PostedBy] FOREIGN KEY ([PostedBy]) REFERENCES [security].[Users] ([Id]);
GO

ALTER TABLE [purchase].[LandedCostAdjustments]
    ADD CONSTRAINT [FK_LandedCostAdjustments_Invoice] FOREIGN KEY ([SourceInvoiceId]) REFERENCES [purchase].[PurchaseDocuments] ([Id]);
GO

ALTER TABLE [purchase].[LandedCostAdjustments]
    ADD CONSTRAINT [FK_LandedCostAdjustments_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]);
GO

CREATE NONCLUSTERED INDEX [IX_LandedCostAdjustments_Invoice]
    ON [purchase].[LandedCostAdjustments]([SourceInvoiceId] ASC, [Status] ASC);
GO

ALTER TABLE [purchase].[LandedCostAdjustments]
    ADD CONSTRAINT [PK_LandedCostAdjustments] PRIMARY KEY CLUSTERED ([Id] ASC);
GO

ALTER TABLE [purchase].[LandedCostAdjustments]
    ADD CONSTRAINT [CK_LandedCostAdjustments_Status] CHECK ([Status]=(3) OR [Status]=(2) OR [Status]=(1));
GO

