CREATE TABLE [logistics].[Containers] (
    [Id]                  INT             IDENTITY (1, 1) NOT NULL,
    [DocumentTypeId]      INT             NOT NULL,
    [ContainerRef]        NVARCHAR (30)   NOT NULL,
    [ContainerNo]         NVARCHAR (20)   NULL,
    [ContainerTypeId]     INT             NOT NULL,
    [SealNo]              NVARCHAR (30)   NULL,
    [CustomsSealNo]       NVARCHAR (30)   NULL,
    [Description]         NVARCHAR (500)  NULL,
    [OrderDate]           DATE            NOT NULL,
    [OrderMonthKey]       AS              (datepart(year,[OrderDate])*(100)+datepart(month,[OrderDate])) PERSISTED,
    [ShippingMethod]      NVARCHAR (10)   CONSTRAINT [DF_Containers_Method] DEFAULT (N'Sea') NOT NULL,
    [CountryOfOrigin]     NCHAR (2)       NULL,
    [ForwarderId]         INT             NULL,
    [TransporterId]       INT             NULL,
    [ShippingLine]        NVARCHAR (100)  NULL,
    [VesselName]          NVARCHAR (100)  NULL,
    [VoyageNo]            NVARCHAR (30)   NULL,
    [BookingNo]           NVARCHAR (30)   NULL,
    [PortOfLoadingId]     INT             NULL,
    [PortOfDestinationId] INT             NULL,
    [FinalDestinationId]  INT             NULL,
    [DispatchDate]        DATE            NULL,
    [Eta]                 DATE            NULL,
    [FreeDays]            INT             NULL,
    [GrossWeightKg]       DECIMAL (18, 3) NULL,
    [VolumeCbm]           DECIMAL (18, 3) NULL,
    [Packages]            INT             NULL,
    [BlNo]                NVARCHAR (30)   NULL,
    [BlDate]              DATE            NULL,
    [BlNotes]             NVARCHAR (500)  NULL,
    [MaxUnits]            INT             NULL,
    [TotalLines]          INT             CONSTRAINT [DF_Containers_Lines] DEFAULT ((0)) NOT NULL,
    [TotalAllocatedBase]  INT             CONSTRAINT [DF_Containers_Allocated] DEFAULT ((0)) NOT NULL,
    [TotalReceivedBase]   INT             CONSTRAINT [DF_Containers_Received] DEFAULT ((0)) NOT NULL,
    [TotalOilQty]         DECIMAL (18, 2) CONSTRAINT [DF_Containers_Oil] DEFAULT ((0)) NOT NULL,
    [UtilizationPct]      AS              (case when [MaxUnits]>(0) then CONVERT([decimal](9,2),((100.0)*[TotalAllocatedBase])/[MaxUnits])  end) PERSISTED,
    [BranchId]            INT             NOT NULL,
    [WarehouseId]         INT             NULL,
    [TruckNo]             NVARCHAR (30)   NULL,
    [WaybillNo]           NVARCHAR (30)   NULL,
    [DeclarationNo]       NVARCHAR (30)   NULL,
    [FeriNo]              NVARCHAR (30)   NULL,
    [ActualPortArrival]   DATE            NULL,
    [BorderCrossingDate]  DATE            NULL,
    [CustomsReleaseDate]  DATE            NULL,
    [LastFreeDay]         AS              (case when [FreeDays] IS NOT NULL AND [ActualPortArrival] IS NOT NULL then dateadd(day,[FreeDays],[ActualPortArrival])  end) PERSISTED,
    [OffloadedDate]       DATE            NULL,
    [OffloadedAtUtc]      DATETIME2 (3)   NULL,
    [OffloadedBy]         INT             NULL,
    [Status]              TINYINT         CONSTRAINT [DF_Containers_Status] DEFAULT ((1)) NOT NULL,
    [StatusNote]          NVARCHAR (200)  NULL,
    [CurrentLocation]     NVARCHAR (100)  NULL,
    [ConfirmedAtUtc]      DATETIME2 (3)   NULL,
    [ConfirmedBy]         INT             NULL,
    [ClosedAtUtc]         DATETIME2 (3)   NULL,
    [ClosedBy]            INT             NULL,
    [CancelledAtUtc]      DATETIME2 (3)   NULL,
    [CancelledBy]         INT             NULL,
    [CancelReason]        NVARCHAR (300)  NULL,
    [Notes]               NVARCHAR (1000) NULL,
    [CreatedAtUtc]        DATETIME2 (3)   CONSTRAINT [DF_Containers_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]           INT             NULL,
    [UpdatedAtUtc]        DATETIME2 (3)   NULL,
    [UpdatedBy]           INT             NULL,
    [RowVersion]          ROWVERSION      NOT NULL,
    [PurchaseOrderId]     INT             NULL,
    [DatesFromMovements]  BIT             CONSTRAINT [DF_Containers_DatesFromMovements] DEFAULT ((0)) NOT NULL,
    CONSTRAINT [PK_Containers] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_Containers_FreeDays] CHECK ([FreeDays] IS NULL OR [FreeDays]>=(0)),
    CONSTRAINT [CK_Containers_MaxUnits] CHECK ([MaxUnits] IS NULL OR [MaxUnits]>(0)),
    CONSTRAINT [CK_Containers_Method] CHECK ([ShippingMethod]=N'Road' OR [ShippingMethod]=N'Air' OR [ShippingMethod]=N'Sea'),
    CONSTRAINT [CK_Containers_Status] CHECK ([Status]>=(1) AND [Status]<=(8)),
    CONSTRAINT [FK_Containers_Branch] FOREIGN KEY ([BranchId]) REFERENCES [masterdata].[Branches] ([Id]),
    CONSTRAINT [FK_Containers_Cancelled] FOREIGN KEY ([CancelledBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_Containers_Closed] FOREIGN KEY ([ClosedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_Containers_Confirmed] FOREIGN KEY ([ConfirmedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_Containers_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_Containers_CtType] FOREIGN KEY ([ContainerTypeId]) REFERENCES [masterdata].[ContainerTypes] ([Id]),
    CONSTRAINT [FK_Containers_FinalDest] FOREIGN KEY ([FinalDestinationId]) REFERENCES [masterdata].[Ports] ([Id]),
    CONSTRAINT [FK_Containers_Forwarder] FOREIGN KEY ([ForwarderId]) REFERENCES [masterdata].[Parties] ([Id]),
    CONSTRAINT [FK_Containers_Offloaded] FOREIGN KEY ([OffloadedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_Containers_Order] FOREIGN KEY ([PurchaseOrderId]) REFERENCES [purchase].[PurchaseDocuments] ([Id]),
    CONSTRAINT [FK_Containers_PortDest] FOREIGN KEY ([PortOfDestinationId]) REFERENCES [masterdata].[Ports] ([Id]),
    CONSTRAINT [FK_Containers_PortLoad] FOREIGN KEY ([PortOfLoadingId]) REFERENCES [masterdata].[Ports] ([Id]),
    CONSTRAINT [FK_Containers_Transporter] FOREIGN KEY ([TransporterId]) REFERENCES [masterdata].[Parties] ([Id]),
    CONSTRAINT [FK_Containers_Type] FOREIGN KEY ([DocumentTypeId]) REFERENCES [inventory].[DocumentTypes] ([Id]),
    CONSTRAINT [FK_Containers_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_Containers_Warehouse] FOREIGN KEY ([WarehouseId]) REFERENCES [masterdata].[Warehouses] ([Id]),
    CONSTRAINT [UQ_Containers_Ref] UNIQUE NONCLUSTERED ([ContainerRef] ASC)
);


GO

CREATE UNIQUE NONCLUSTERED INDEX [UX_Containers_ContainerNo]
    ON [logistics].[Containers]([ContainerNo] ASC) WHERE ([ContainerNo] IS NOT NULL AND [Status]<(7));


GO

CREATE NONCLUSTERED INDEX [IX_Containers_OrderMonth]
    ON [logistics].[Containers]([OrderMonthKey] ASC);


GO

CREATE NONCLUSTERED INDEX [IX_Containers_Warehouse]
    ON [logistics].[Containers]([WarehouseId] ASC, [Status] ASC);


GO

CREATE NONCLUSTERED INDEX [IX_Containers_Status]
    ON [logistics].[Containers]([Status] ASC, [OrderDate] DESC);


GO

CREATE NONCLUSTERED INDEX [IX_Containers_Order]
    ON [logistics].[Containers]([PurchaseOrderId] ASC);


GO

