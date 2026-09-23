CREATE TABLE [masterdata].[Parties] (
    [Id]                 INT             IDENTITY (1, 1) NOT NULL,
    [PartyCode]          NVARCHAR (20)   NOT NULL,
    [PartyName]          NVARCHAR (200)  NOT NULL,
    [IsSupplier]         BIT             CONSTRAINT [DF_Parties_IsSupplier] DEFAULT ((0)) NOT NULL,
    [IsClient]           BIT             CONSTRAINT [DF_Parties_IsClient] DEFAULT ((0)) NOT NULL,
    [IsSalesman]         BIT             CONSTRAINT [DF_Parties_IsSalesman] DEFAULT ((0)) NOT NULL,
    [IsEmployee]         BIT             CONSTRAINT [DF_Parties_IsEmployee] DEFAULT ((0)) NOT NULL,
    [BranchId]           INT             NULL,
    [ContactPerson]      NVARCHAR (150)  NULL,
    [Phone]              NVARCHAR (50)   NULL,
    [Mobile]             NVARCHAR (50)   NULL,
    [Email]              NVARCHAR (150)  NULL,
    [Address]            NVARCHAR (500)  NULL,
    [Country]            NVARCHAR (2)    NULL,
    [TaxRegistrationNo]  NVARCHAR (50)   NULL,
    [Notes]              NVARCHAR (1000) NULL,
    [UserId]             INT             NULL,
    [DefaultPriceListId] INT             NULL,
    [DefaultCurrencyId]  INT             NULL,
    [IsActive]           BIT             CONSTRAINT [DF_Parties_IsActive] DEFAULT ((1)) NOT NULL,
    [CreatedAtUtc]       DATETIME2 (3)   CONSTRAINT [DF_Parties_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]          INT             NULL,
    [UpdatedAtUtc]       DATETIME2 (3)   NULL,
    [UpdatedBy]          INT             NULL,
    [RowVersion]         ROWVERSION      NOT NULL,
    CONSTRAINT [PK_Parties] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_Parties_AtLeastOneType] CHECK ([IsSupplier]=(1) OR [IsClient]=(1) OR [IsSalesman]=(1) OR [IsEmployee]=(1)),
    CONSTRAINT [CK_Parties_PartyCode_NotBlank] CHECK (len(ltrim(rtrim([PartyCode])))>(0)),
    CONSTRAINT [CK_Parties_PartyName_NotBlank] CHECK (len(ltrim(rtrim([PartyName])))>(0)),
    CONSTRAINT [FK_Parties_Branch] FOREIGN KEY ([BranchId]) REFERENCES [masterdata].[Branches] ([Id]),
    CONSTRAINT [FK_Parties_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_Parties_Currency] FOREIGN KEY ([DefaultCurrencyId]) REFERENCES [masterdata].[Currencies] ([Id]),
    CONSTRAINT [FK_Parties_PriceList] FOREIGN KEY ([DefaultPriceListId]) REFERENCES [masterdata].[PriceLists] ([Id]),
    CONSTRAINT [FK_Parties_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_Parties_User] FOREIGN KEY ([UserId]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [UQ_Parties_PartyCode] UNIQUE NONCLUSTERED ([PartyCode] ASC)
);


GO

CREATE UNIQUE NONCLUSTERED INDEX [UX_Parties_UserId]
    ON [masterdata].[Parties]([UserId] ASC) WHERE ([UserId] IS NOT NULL);


GO

CREATE NONCLUSTERED INDEX [IX_Parties_Types]
    ON [masterdata].[Parties]([IsSupplier] ASC, [IsClient] ASC, [IsSalesman] ASC, [IsEmployee] ASC)
    INCLUDE([PartyCode], [PartyName], [IsActive]);


GO

CREATE NONCLUSTERED INDEX [IX_Parties_PartyName]
    ON [masterdata].[Parties]([PartyName] ASC);


GO

CREATE NONCLUSTERED INDEX [IX_Parties_Branch]
    ON [masterdata].[Parties]([BranchId] ASC);


GO

