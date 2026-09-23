CREATE TABLE [purchase].[ChargeTypes] (
    [Id]                  INT            IDENTITY (1, 1) NOT NULL,
    [ChargeCode]          NVARCHAR (10)  NOT NULL,
    [ChargeName]          NVARCHAR (100) NOT NULL,
    [AllocationMethod]    NVARCHAR (10)  NOT NULL,
    [IncludeInLandedCost] BIT            NOT NULL,
    [IsRecoverableTax]    BIT            NOT NULL,
    [Description]         NVARCHAR (500) NULL,
    [IsActive]            BIT            NOT NULL,
    [CreatedAtUtc]        DATETIME2 (3)  NOT NULL,
    [CreatedBy]           INT            NULL,
    [UpdatedAtUtc]        DATETIME2 (3)  NULL,
    [UpdatedBy]           INT            NULL,
    [RowVersion]          ROWVERSION     NOT NULL
);
GO

ALTER TABLE [purchase].[ChargeTypes]
    ADD CONSTRAINT [CK_ChargeTypes_TaxNotLanded] CHECK (NOT ([IsRecoverableTax]=(1) AND [IncludeInLandedCost]=(1)));
GO

ALTER TABLE [purchase].[ChargeTypes]
    ADD CONSTRAINT [CK_ChargeTypes_Method] CHECK ([AllocationMethod]=N'Manual' OR [AllocationMethod]=N'Volume' OR [AllocationMethod]=N'Weight' OR [AllocationMethod]=N'Quantity' OR [AllocationMethod]=N'Value');
GO

ALTER TABLE [purchase].[ChargeTypes]
    ADD CONSTRAINT [DF_ChargeTypes_CreatedAtUtc] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];
GO

ALTER TABLE [purchase].[ChargeTypes]
    ADD CONSTRAINT [DF_ChargeTypes_IsActive] DEFAULT ((1)) FOR [IsActive];
GO

ALTER TABLE [purchase].[ChargeTypes]
    ADD CONSTRAINT [DF_ChargeTypes_RecoverableTax] DEFAULT ((0)) FOR [IsRecoverableTax];
GO

ALTER TABLE [purchase].[ChargeTypes]
    ADD CONSTRAINT [DF_ChargeTypes_Landed] DEFAULT ((1)) FOR [IncludeInLandedCost];
GO

ALTER TABLE [purchase].[ChargeTypes]
    ADD CONSTRAINT [PK_ChargeTypes] PRIMARY KEY CLUSTERED ([Id] ASC);
GO

ALTER TABLE [purchase].[ChargeTypes]
    ADD CONSTRAINT [FK_ChargeTypes_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id]);
GO

ALTER TABLE [purchase].[ChargeTypes]
    ADD CONSTRAINT [FK_ChargeTypes_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]);
GO

ALTER TABLE [purchase].[ChargeTypes]
    ADD CONSTRAINT [UQ_ChargeTypes_Name] UNIQUE NONCLUSTERED ([ChargeName] ASC);
GO

ALTER TABLE [purchase].[ChargeTypes]
    ADD CONSTRAINT [UQ_ChargeTypes_Code] UNIQUE NONCLUSTERED ([ChargeCode] ASC);
GO

