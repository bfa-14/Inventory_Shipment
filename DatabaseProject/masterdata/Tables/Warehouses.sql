CREATE TABLE [masterdata].[Warehouses] (
    [Id]              INT            IDENTITY (1, 1) NOT NULL,
    [WarehouseCode]   NVARCHAR (20)  NOT NULL,
    [WarehouseName]   NVARCHAR (150) NOT NULL,
    [BranchId]        INT            NOT NULL,
    [Address]         NVARCHAR (500) NULL,
    [IsMainWarehouse] BIT            CONSTRAINT [DF_Warehouses_IsMainWarehouse] DEFAULT ((0)) NOT NULL,
    [IsActive]        BIT            CONSTRAINT [DF_Warehouses_IsActive] DEFAULT ((1)) NOT NULL,
    [CreatedAtUtc]    DATETIME2 (3)  CONSTRAINT [DF_Warehouses_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]       INT            NULL,
    [UpdatedAtUtc]    DATETIME2 (3)  NULL,
    [UpdatedBy]       INT            NULL,
    [RowVersion]      ROWVERSION     NOT NULL,
    CONSTRAINT [PK_Warehouses] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_Warehouses_MainIsActive] CHECK ([IsMainWarehouse]=(0) OR [IsActive]=(1)),
    CONSTRAINT [CK_Warehouses_WarehouseCode_NotBlank] CHECK (len(ltrim(rtrim([WarehouseCode])))>(0)),
    CONSTRAINT [CK_Warehouses_WarehouseName_NotBlank] CHECK (len(ltrim(rtrim([WarehouseName])))>(0)),
    CONSTRAINT [FK_Warehouses_Branches] FOREIGN KEY ([BranchId]) REFERENCES [masterdata].[Branches] ([Id]),
    CONSTRAINT [FK_Warehouses_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_Warehouses_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [UQ_Warehouses_WarehouseCode] UNIQUE NONCLUSTERED ([WarehouseCode] ASC)
);


GO

CREATE NONCLUSTERED INDEX [IX_Warehouses_BranchId]
    ON [masterdata].[Warehouses]([BranchId] ASC);


GO

CREATE UNIQUE NONCLUSTERED INDEX [UX_Warehouses_ActiveMainWarehouse]
    ON [masterdata].[Warehouses]([IsMainWarehouse] ASC) WHERE ([IsMainWarehouse]=(1) AND [IsActive]=(1));


GO

CREATE NONCLUSTERED INDEX [IX_Warehouses_WarehouseName]
    ON [masterdata].[Warehouses]([WarehouseName] ASC);


GO

