CREATE TABLE [logistics].[Movements] (
    [Id]              INT             IDENTITY (1, 1) NOT NULL,
    [DocumentTypeId]  INT             NOT NULL,
    [MovementNo]      NVARCHAR (30)   NOT NULL,
    [MovementTypeId]  INT             NOT NULL,
    [FromPlaceId]     INT             NOT NULL,
    [ToPlaceId]       INT             NOT NULL,
    [PlannedDate]     DATE            NULL,
    [StartDate]       DATE            NULL,
    [Eta]             DATE            NULL,
    [EndDate]         DATE            NULL,
    [CarrierPartyId]  INT             NULL,
    [VehicleOrVessel] NVARCHAR (100)  NULL,
    [VoyageNo]        NVARCHAR (30)   NULL,
    [Reference]       NVARCHAR (50)   NULL,
    [Status]          TINYINT         CONSTRAINT [DF_Movements_Status] DEFAULT ((1)) NOT NULL,
    [CancelReason]    NVARCHAR (300)  NULL,
    [Notes]           NVARCHAR (1000) NULL,
    [StartedAtUtc]    DATETIME2 (3)   NULL,
    [StartedBy]       INT             NULL,
    [CompletedAtUtc]  DATETIME2 (3)   NULL,
    [CompletedBy]     INT             NULL,
    [CancelledAtUtc]  DATETIME2 (3)   NULL,
    [CancelledBy]     INT             NULL,
    [CreatedAtUtc]    DATETIME2 (3)   CONSTRAINT [DF_Movements_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]       INT             NULL,
    [UpdatedAtUtc]    DATETIME2 (3)   NULL,
    [UpdatedBy]       INT             NULL,
    [RowVersion]      ROWVERSION      NOT NULL,
    CONSTRAINT [PK_Movements] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_Movements_Dates] CHECK ([EndDate] IS NULL OR [StartDate] IS NULL OR [EndDate]>=[StartDate]),
    CONSTRAINT [CK_Movements_Status] CHECK ([Status]>=(1) AND [Status]<=(4)),
    CONSTRAINT [FK_Movements_CancelledBy] FOREIGN KEY ([CancelledBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_Movements_Carrier] FOREIGN KEY ([CarrierPartyId]) REFERENCES [masterdata].[Parties] ([Id]),
    CONSTRAINT [FK_Movements_CompletedBy] FOREIGN KEY ([CompletedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_Movements_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_Movements_DocType] FOREIGN KEY ([DocumentTypeId]) REFERENCES [inventory].[DocumentTypes] ([Id]),
    CONSTRAINT [FK_Movements_From] FOREIGN KEY ([FromPlaceId]) REFERENCES [masterdata].[Ports] ([Id]),
    CONSTRAINT [FK_Movements_StartedBy] FOREIGN KEY ([StartedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_Movements_To] FOREIGN KEY ([ToPlaceId]) REFERENCES [masterdata].[Ports] ([Id]),
    CONSTRAINT [FK_Movements_Type] FOREIGN KEY ([MovementTypeId]) REFERENCES [masterdata].[MovementTypes] ([Id]),
    CONSTRAINT [FK_Movements_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [UQ_Movements_No] UNIQUE NONCLUSTERED ([MovementNo] ASC)
);


GO

CREATE NONCLUSTERED INDEX [IX_Movements_Status]
    ON [logistics].[Movements]([Status] ASC, [StartDate] DESC);


GO

