CREATE TABLE [logistics].[ContainerCharges] (
    [Id]                   INT              IDENTITY (1, 1) NOT NULL,
    [ContainerId]          INT              NOT NULL,
    [MovementId]           INT              NULL,
    [GroupId]              UNIQUEIDENTIFIER NULL,
    [ChargeTypeId]         INT              NOT NULL,
    [Description]          NVARCHAR (200)   NULL,
    [ProviderPartyId]      INT              NULL,
    [Reference]            NVARCHAR (100)   NULL,
    [ChargeDate]           DATE             NOT NULL,
    [CurrencyId]           INT              NOT NULL,
    [RateType]             TINYINT          CONSTRAINT [DF_ContainerCharges_RateType] DEFAULT ((1)) NOT NULL,
    [ExchangeRate]         DECIMAL (18, 6)  NOT NULL,
    [Amount]               DECIMAL (18, 2)  NOT NULL,
    [AmountBase]           DECIMAL (18, 2)  NOT NULL,
    [AllocationMethod]     NVARCHAR (10)    NOT NULL,
    [IncludeInLandedCost]  BIT              NOT NULL,
    [Status]               TINYINT          CONSTRAINT [DF_ContainerCharges_Status] DEFAULT ((1)) NOT NULL,
    [AppliedAtOffload]     BIT              CONSTRAINT [DF_ContainerCharges_AtOffload] DEFAULT ((0)) NOT NULL,
    [AdjustedAfterOffload] BIT              CONSTRAINT [DF_ContainerCharges_Adjusted] DEFAULT ((0)) NOT NULL,
    [Notes]                NVARCHAR (300)   NULL,
    [PostedAtUtc]          DATETIME2 (3)    NULL,
    [PostedBy]             INT              NULL,
    [CancelledAtUtc]       DATETIME2 (3)    NULL,
    [CancelledBy]          INT              NULL,
    [CancelReason]         NVARCHAR (300)   NULL,
    [CreatedAtUtc]         DATETIME2 (3)    CONSTRAINT [DF_ContainerCharges_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]            INT              NULL,
    [UpdatedAtUtc]         DATETIME2 (3)    NULL,
    [UpdatedBy]            INT              NULL,
    [RowVersion]           ROWVERSION       NOT NULL,
    CONSTRAINT [PK_ContainerCharges] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_ContainerCharges_Amount] CHECK ([Amount]>=(0)),
    CONSTRAINT [CK_ContainerCharges_Method] CHECK ([AllocationMethod]=N'Manual' OR [AllocationMethod]=N'Volume' OR [AllocationMethod]=N'Weight' OR [AllocationMethod]=N'Quantity' OR [AllocationMethod]=N'Value'),
    CONSTRAINT [CK_ContainerCharges_Rate] CHECK ([ExchangeRate]>(0)),
    CONSTRAINT [CK_ContainerCharges_Status] CHECK ([Status]>=(1) AND [Status]<=(3)),
    CONSTRAINT [FK_ContainerCharges_CancelledBy] FOREIGN KEY ([CancelledBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_ContainerCharges_Container] FOREIGN KEY ([ContainerId]) REFERENCES [logistics].[Containers] ([Id]),
    CONSTRAINT [FK_ContainerCharges_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_ContainerCharges_Currency] FOREIGN KEY ([CurrencyId]) REFERENCES [masterdata].[Currencies] ([Id]),
    CONSTRAINT [FK_ContainerCharges_Movement] FOREIGN KEY ([MovementId]) REFERENCES [logistics].[Movements] ([Id]),
    CONSTRAINT [FK_ContainerCharges_PostedBy] FOREIGN KEY ([PostedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_ContainerCharges_Provider] FOREIGN KEY ([ProviderPartyId]) REFERENCES [masterdata].[Parties] ([Id]),
    CONSTRAINT [FK_ContainerCharges_Type] FOREIGN KEY ([ChargeTypeId]) REFERENCES [purchase].[ChargeTypes] ([Id]),
    CONSTRAINT [FK_ContainerCharges_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id])
);


GO

CREATE NONCLUSTERED INDEX [IX_ContainerCharges_Container]
    ON [logistics].[ContainerCharges]([ContainerId] ASC, [Status] ASC);


GO

CREATE NONCLUSTERED INDEX [IX_ContainerCharges_Group]
    ON [logistics].[ContainerCharges]([GroupId] ASC) WHERE ([GroupId] IS NOT NULL);


GO

CREATE NONCLUSTERED INDEX [IX_ContainerCharges_Movement]
    ON [logistics].[ContainerCharges]([MovementId] ASC) WHERE ([MovementId] IS NOT NULL);


GO

