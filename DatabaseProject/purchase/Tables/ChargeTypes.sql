CREATE TABLE [purchase].[ChargeTypes] (
    [Id]                  INT            IDENTITY (1, 1) NOT NULL,
    [ChargeCode]          NVARCHAR (10)  NOT NULL,
    [ChargeName]          NVARCHAR (100) NOT NULL,
    [AllocationMethod]    NVARCHAR (10)  NOT NULL,
    [IncludeInLandedCost] BIT            CONSTRAINT [DF_ChargeTypes_Landed] DEFAULT ((1)) NOT NULL,
    [IsRecoverableTax]    BIT            CONSTRAINT [DF_ChargeTypes_RecoverableTax] DEFAULT ((0)) NOT NULL,
    [Description]         NVARCHAR (500) NULL,
    [IsActive]            BIT            CONSTRAINT [DF_ChargeTypes_IsActive] DEFAULT ((1)) NOT NULL,
    [CreatedAtUtc]        DATETIME2 (3)  CONSTRAINT [DF_ChargeTypes_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]           INT            NULL,
    [UpdatedAtUtc]        DATETIME2 (3)  NULL,
    [UpdatedBy]           INT            NULL,
    [RowVersion]          ROWVERSION     NOT NULL,
    CONSTRAINT [PK_ChargeTypes] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_ChargeTypes_Method] CHECK ([AllocationMethod]=N'Manual' OR [AllocationMethod]=N'Volume' OR [AllocationMethod]=N'Weight' OR [AllocationMethod]=N'Quantity' OR [AllocationMethod]=N'Value'),
    CONSTRAINT [CK_ChargeTypes_TaxNotLanded] CHECK (NOT ([IsRecoverableTax]=(1) AND [IncludeInLandedCost]=(1))),
    CONSTRAINT [FK_ChargeTypes_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_ChargeTypes_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [UQ_ChargeTypes_Code] UNIQUE NONCLUSTERED ([ChargeCode] ASC),
    CONSTRAINT [UQ_ChargeTypes_Name] UNIQUE NONCLUSTERED ([ChargeName] ASC)
);


GO

