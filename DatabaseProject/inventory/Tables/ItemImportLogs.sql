CREATE TABLE [inventory].[ItemImportLogs] (
    [Id]            INT            IDENTITY (1, 1) NOT NULL,
    [FileName]      NVARCHAR (255) NOT NULL,
    [TotalRows]     INT            NOT NULL,
    [ImportedRows]  INT            NOT NULL,
    [WarningRows]   INT            NOT NULL,
    [RejectedRows]  INT            NOT NULL,
    [ImportedBy]    INT            NULL,
    [ImportedAtUtc] DATETIME2 (3)  CONSTRAINT [DF_ItemImportLogs_At] DEFAULT (sysutcdatetime()) NOT NULL,
    CONSTRAINT [PK_ItemImportLogs] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [FK_ItemImportLogs_User] FOREIGN KEY ([ImportedBy]) REFERENCES [security].[Users] ([Id])
);


GO

