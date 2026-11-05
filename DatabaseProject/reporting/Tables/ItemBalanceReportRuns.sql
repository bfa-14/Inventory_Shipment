CREATE TABLE [reporting].[ItemBalanceReportRuns] (
    [Id]           BIGINT         IDENTITY (1, 1) NOT NULL,
    [UserId]       INT            NOT NULL,
    [RunAtUtc]     DATETIME2 (3)  CONSTRAINT [DF_ItemBalanceReportRuns_At] DEFAULT (sysutcdatetime()) NOT NULL,
    [OutputKind]   NVARCHAR (10)  NOT NULL,
    [DateFrom]     DATE           NOT NULL,
    [DateTo]       DATE           NOT NULL,
    [CurrencyId]   INT            NULL,
    [RateType]     TINYINT        NULL,
    [Criteria]     NVARCHAR (MAX) NULL,
    [RowsReturned] INT            NOT NULL,
    [DurationMs]   INT            NOT NULL,
    CONSTRAINT [PK_ItemBalanceReportRuns] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [FK_ItemBalanceReportRuns_User] FOREIGN KEY ([UserId]) REFERENCES [security].[Users] ([Id])
);

