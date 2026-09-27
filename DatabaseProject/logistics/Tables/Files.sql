CREATE TABLE [logistics].[Files] (
    [Id]           INT             IDENTITY (1, 1) NOT NULL,
    [FileName]     NVARCHAR (255)  NOT NULL,
    [ContentType]  NVARCHAR (100)  NOT NULL,
    [SizeBytes]    INT             NOT NULL,
    [Content]      VARBINARY (MAX) NOT NULL,
    [CreatedAtUtc] DATETIME2 (3)   CONSTRAINT [DF_LogisticsFiles_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]    INT             NULL,
    CONSTRAINT [PK_LogisticsFiles] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_LogisticsFiles_Size] CHECK ([SizeBytes]>(0)),
    CONSTRAINT [FK_LogisticsFiles_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id])
);


GO

