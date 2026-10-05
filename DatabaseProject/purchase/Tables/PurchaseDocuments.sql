CREATE TABLE [purchase].[PurchaseDocuments] (
    [Id]                     INT             IDENTITY (1, 1) NOT NULL,
    [DocumentTypeId]         INT             NOT NULL,
    [DocumentNumber]         NVARCHAR (30)   NULL,
    [DocumentDate]           DATE            NOT NULL,
    [ExpectedDate]           DATE            NULL,
    [BranchId]               INT             NOT NULL,
    [WarehouseId]            INT             NOT NULL,
    [SupplierId]             INT             NOT NULL,
    [CurrencyId]             INT             NOT NULL,
    [RateType]               TINYINT         CONSTRAINT [DF_PurchaseDocuments_RateType] DEFAULT ((1)) NOT NULL,
    [ExchangeRate]           DECIMAL (18, 6) CONSTRAINT [DF_PurchaseDocuments_Rate] DEFAULT ((1)) NOT NULL,
    [SupplierReference]      NVARCHAR (100)  NULL,
    [Notes]                  NVARCHAR (1000) NULL,
    [Status]                 TINYINT         CONSTRAINT [DF_PurchaseDocuments_Status] DEFAULT ((1)) NOT NULL,
    [TotalItems]             INT             CONSTRAINT [DF_PurchaseDocuments_TotalItems] DEFAULT ((0)) NOT NULL,
    [TotalQuantity]          INT             CONSTRAINT [DF_PurchaseDocuments_TotalQuantity] DEFAULT ((0)) NOT NULL,
    [Subtotal]               DECIMAL (18, 2) CONSTRAINT [DF_PurchaseDocuments_Subtotal] DEFAULT ((0)) NOT NULL,
    [TotalDiscount]          DECIMAL (18, 2) CONSTRAINT [DF_PurchaseDocuments_TotalDiscount] DEFAULT ((0)) NOT NULL,
    [TotalAmount]            DECIMAL (18, 2) CONSTRAINT [DF_PurchaseDocuments_TotalAmount] DEFAULT ((0)) NOT NULL,
    [TotalAmountBase]        DECIMAL (18, 2) CONSTRAINT [DF_PurchaseDocuments_TotalAmountBase] DEFAULT ((0)) NOT NULL,
    [SourceDocumentId]       INT             NULL,
    [PostedAtUtc]            DATETIME2 (3)   NULL,
    [PostedBy]               INT             NULL,
    [CancelledAtUtc]         DATETIME2 (3)   NULL,
    [CancelledBy]            INT             NULL,
    [CancelReason]           NVARCHAR (300)  NULL,
    [ClosedAtUtc]            DATETIME2 (3)   NULL,
    [ClosedBy]               INT             NULL,
    [CloseReason]            NVARCHAR (300)  NULL,
    [CreatedAtUtc]           DATETIME2 (3)   CONSTRAINT [DF_PurchaseDocuments_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]              INT             NULL,
    [UpdatedAtUtc]           DATETIME2 (3)   NULL,
    [UpdatedBy]              INT             NULL,
    [RowVersion]             ROWVERSION      NOT NULL,
    [SourceShortageId]       INT             NULL,
    [TotalChargesBase]       DECIMAL (18, 2) CONSTRAINT [DF_PurchaseDocuments_Charges] DEFAULT ((0)) NOT NULL,
    [TotalLandedCostBase]    DECIMAL (18, 2) CONSTRAINT [DF_PurchaseDocuments_Landed] DEFAULT ((0)) NOT NULL,
    [ReceiptMode]            TINYINT         CONSTRAINT [DF_PurchaseDocuments_ReceiptMode] DEFAULT ((1)) NOT NULL,
    [ExporterReference]      NVARCHAR (50)   NULL,
    [CommercialInvoiceNo]    NVARCHAR (50)   NULL,
    [ApprovalRequestedAtUtc] DATETIME2 (3)   NULL,
    [ApprovalRequestedBy]    INT             NULL,
    [ApprovedAtUtc]          DATETIME2 (3)   NULL,
    [ApprovedBy]             INT             NULL,
    [ApprovalChannel]        NVARCHAR (10)   NULL,
    [RejectedAtUtc]          DATETIME2 (3)   NULL,
    [RejectedBy]             INT             NULL,
    [RejectReason]           NVARCHAR (300)  NULL,
    CONSTRAINT [PK_PurchaseDocuments] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_PurchaseDocuments_Rate] CHECK ([ExchangeRate]>(0)),
    CONSTRAINT [CK_PurchaseDocuments_RateType] CHECK ([RateType]=(3) OR [RateType]=(2) OR [RateType]=(1)),
    CONSTRAINT [CK_PurchaseDocuments_ReceiptMode] CHECK ([ReceiptMode]=(2) OR [ReceiptMode]=(1)),
    CONSTRAINT [CK_PurchaseDocuments_Status] CHECK ([Status]=(5) OR [Status]=(4) OR [Status]=(3) OR [Status]=(2) OR [Status]=(1)),
    CONSTRAINT [FK_PurchaseDocuments_ApprovalRequestedBy] FOREIGN KEY ([ApprovalRequestedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_PurchaseDocuments_ApprovedBy] FOREIGN KEY ([ApprovedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_PurchaseDocuments_Branch] FOREIGN KEY ([BranchId]) REFERENCES [masterdata].[Branches] ([Id]),
    CONSTRAINT [FK_PurchaseDocuments_CancelledBy] FOREIGN KEY ([CancelledBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_PurchaseDocuments_ClosedBy] FOREIGN KEY ([ClosedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_PurchaseDocuments_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_PurchaseDocuments_Currency] FOREIGN KEY ([CurrencyId]) REFERENCES [masterdata].[Currencies] ([Id]),
    CONSTRAINT [FK_PurchaseDocuments_PostedBy] FOREIGN KEY ([PostedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_PurchaseDocuments_RejectedBy] FOREIGN KEY ([RejectedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_PurchaseDocuments_Shortage] FOREIGN KEY ([SourceShortageId]) REFERENCES [inventory].[ShortageDocuments] ([Id]),
    CONSTRAINT [FK_PurchaseDocuments_Source] FOREIGN KEY ([SourceDocumentId]) REFERENCES [purchase].[PurchaseDocuments] ([Id]),
    CONSTRAINT [FK_PurchaseDocuments_Supplier] FOREIGN KEY ([SupplierId]) REFERENCES [masterdata].[Parties] ([Id]),
    CONSTRAINT [FK_PurchaseDocuments_Type] FOREIGN KEY ([DocumentTypeId]) REFERENCES [inventory].[DocumentTypes] ([Id]),
    CONSTRAINT [FK_PurchaseDocuments_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_PurchaseDocuments_Warehouse] FOREIGN KEY ([WarehouseId]) REFERENCES [masterdata].[Warehouses] ([Id])
);


GO

CREATE NONCLUSTERED INDEX [IX_PurchaseDocuments_TypeStatus]
    ON [purchase].[PurchaseDocuments]([DocumentTypeId] ASC, [Status] ASC);


GO

CREATE NONCLUSTERED INDEX [IX_PurchaseDocuments_Source]
    ON [purchase].[PurchaseDocuments]([SourceDocumentId] ASC) WHERE ([SourceDocumentId] IS NOT NULL);


GO

CREATE NONCLUSTERED INDEX [IX_PurchaseDocuments_Supplier]
    ON [purchase].[PurchaseDocuments]([SupplierId] ASC, [DocumentDate] DESC);


GO

CREATE UNIQUE NONCLUSTERED INDEX [UX_PurchaseDocuments_Number]
    ON [purchase].[PurchaseDocuments]([DocumentNumber] ASC) WHERE ([DocumentNumber] IS NOT NULL);


GO

CREATE NONCLUSTERED INDEX [IX_PurchaseDocuments_TypeDate]
    ON [purchase].[PurchaseDocuments]([DocumentTypeId] ASC, [DocumentDate] DESC);


GO

