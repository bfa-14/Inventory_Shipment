CREATE TABLE [inventory].[ShortageDocumentLines] (
    [Id]                         INT             IDENTITY (1, 1) NOT NULL,
    [DocumentId]                 INT             NOT NULL,
    [LineNumber]                 INT             NOT NULL,
    [ItemId]                     INT             NOT NULL,
    [CurrentInventoryBase]       INT             NOT NULL,
    [TransitBase]                INT             NOT NULL,
    [OutstandingOrderBase]       INT             NOT NULL,
    [ExpectedMonthlySalesBase]   DECIMAL (18, 2) NOT NULL,
    [ExpectedMonthlySalesManual] DECIMAL (18, 2) NULL,
    [LeadTimeMonths]             DECIMAL (6, 2)  NOT NULL,
    [StockPlusTransitBase]       AS              ([CurrentInventoryBase]+[TransitBase]) PERSISTED,
    [TotalExpectedStockBase]     AS              (([CurrentInventoryBase]+[TransitBase])+[OutstandingOrderBase]) PERSISTED,
    [EffectiveMonthlySales]      AS              (isnull([ExpectedMonthlySalesManual],[ExpectedMonthlySalesBase])) PERSISTED NOT NULL,
    [ExpectedRequirementBase]    AS              (CONVERT([decimal](18,2),isnull([ExpectedMonthlySalesManual],[ExpectedMonthlySalesBase])*[LeadTimeMonths])) PERSISTED,
    [ShortageBase]               AS              (case when (isnull([ExpectedMonthlySalesManual],[ExpectedMonthlySalesBase])*[LeadTimeMonths]-(([CurrentInventoryBase]+[TransitBase])+[OutstandingOrderBase]))>(0) then CONVERT([int],ceiling(isnull([ExpectedMonthlySalesManual],[ExpectedMonthlySalesBase])*[LeadTimeMonths]-(([CurrentInventoryBase]+[TransitBase])+[OutstandingOrderBase]))) else (0) end) PERSISTED,
    [CoverageMonths]             AS              (case when isnull([ExpectedMonthlySalesManual],[ExpectedMonthlySalesBase])>(0) then CONVERT([decimal](9,2),(([CurrentInventoryBase]+[TransitBase])+[OutstandingOrderBase])/isnull([ExpectedMonthlySalesManual],[ExpectedMonthlySalesBase]))  end) PERSISTED,
    [PurchaseItemUnitId]         INT             NOT NULL,
    [PurchasePackingFormula]     INT             NOT NULL,
    [RequiredQty]                INT             CONSTRAINT [DF_ShortageDocumentLines_Required] DEFAULT ((0)) NOT NULL,
    [RequiredBase]               AS              ([RequiredQty]*[PurchasePackingFormula]) PERSISTED,
    [PcPerContainer]             INT             NULL,
    [ContainerRequirement]       AS              (case when [PcPerContainer]>(0) then CONVERT([decimal](9,2),(([RequiredQty]*[PurchasePackingFormula])*(1.0))/[PcPerContainer])  end) PERSISTED,
    [MinQuantity]                INT             NULL,
    [MaxQuantity]                INT             NULL,
    [LastCost]                   DECIMAL (18, 6) NULL,
    [Notes]                      NVARCHAR (300)  NULL,
    [PcPerContainerFromUnit]     BIT             CONSTRAINT [DF_ShortageDocumentLines_PcFromUnit] DEFAULT ((0)) NOT NULL,
    CONSTRAINT [PK_ShortageDocumentLines] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_ShortageDocumentLines_Container] CHECK ([PcPerContainer] IS NULL OR [PcPerContainer]>(0)),
    CONSTRAINT [CK_ShortageDocumentLines_Required] CHECK ([RequiredQty]>=(0)),
    CONSTRAINT [CK_ShortageDocumentLines_Sales] CHECK ([ExpectedMonthlySalesManual] IS NULL OR [ExpectedMonthlySalesManual]>=(0)),
    CONSTRAINT [FK_ShortageDocumentLines_Document] FOREIGN KEY ([DocumentId]) REFERENCES [inventory].[ShortageDocuments] ([Id]),
    CONSTRAINT [FK_ShortageDocumentLines_Item] FOREIGN KEY ([ItemId]) REFERENCES [inventory].[Items] ([Id]),
    CONSTRAINT [FK_ShortageDocumentLines_Unit] FOREIGN KEY ([PurchaseItemUnitId]) REFERENCES [inventory].[ItemUnits] ([Id]),
    CONSTRAINT [UQ_ShortageDocumentLines_Item] UNIQUE NONCLUSTERED ([DocumentId] ASC, [ItemId] ASC),
    CONSTRAINT [UQ_ShortageDocumentLines_LineNo] UNIQUE NONCLUSTERED ([DocumentId] ASC, [LineNumber] ASC)
);


GO

CREATE NONCLUSTERED INDEX [IX_ShortageDocumentLines_Document]
    ON [inventory].[ShortageDocumentLines]([DocumentId] ASC);


GO

