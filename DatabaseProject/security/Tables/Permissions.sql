CREATE TABLE [security].[Permissions] (
    [Id]          INT            IDENTITY (1, 1) NOT NULL,
    [Code]        NVARCHAR (100) NOT NULL,
    [Name]        NVARCHAR (100) NOT NULL,
    [Module]      NVARCHAR (50)  NOT NULL,
    [Description] NVARCHAR (250) NULL,
    [SortOrder]   INT            CONSTRAINT [DF_Permissions_SortOrder] DEFAULT ((0)) NOT NULL,
    CONSTRAINT [PK_Permissions] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [UQ_Permissions_Code] UNIQUE NONCLUSTERED ([Code] ASC)
);

