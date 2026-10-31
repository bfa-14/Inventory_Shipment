CREATE TABLE [reporting].[AttachmentDownloads] (
    [Id]              BIGINT         IDENTITY (1, 1) NOT NULL,
    [UserId]          INT            NOT NULL,
    [DownloadedAtUtc] DATETIME2 (3)  CONSTRAINT [DF_AttachmentDownloads_At] DEFAULT (sysutcdatetime()) NOT NULL,
    [Mode]            NVARCHAR (20)  NOT NULL,
    [FileCount]       INT            NOT NULL,
    [TotalBytes]      BIGINT         NOT NULL,
    [Criteria]        NVARCHAR (MAX) NULL,
    CONSTRAINT [PK_AttachmentDownloads] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_AttachmentDownloads_Mode] CHECK ([Mode]=N'All' OR [Mode]=N'Selected')
);

