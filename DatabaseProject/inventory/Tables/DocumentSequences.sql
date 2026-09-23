CREATE TABLE [inventory].[DocumentSequences] (
    [DocumentTypeId] INT NOT NULL,
    [BranchId]       INT NOT NULL,
    [NextNumber]     INT NOT NULL,
    [Year]           INT NOT NULL
);
GO

ALTER TABLE [inventory].[DocumentSequences]
    ADD CONSTRAINT [PK_DocumentSequences] PRIMARY KEY CLUSTERED ([DocumentTypeId] ASC, [BranchId] ASC, [Year] ASC);
GO

ALTER TABLE [inventory].[DocumentSequences]
    ADD CONSTRAINT [FK_DocumentSequences_Type] FOREIGN KEY ([DocumentTypeId]) REFERENCES [inventory].[DocumentTypes] ([Id]);
GO

ALTER TABLE [inventory].[DocumentSequences]
    ADD CONSTRAINT [FK_DocumentSequences_Branch] FOREIGN KEY ([BranchId]) REFERENCES [masterdata].[Branches] ([Id]);
GO

ALTER TABLE [inventory].[DocumentSequences]
    ADD CONSTRAINT [DF_DocumentSequences_Next] DEFAULT ((1)) FOR [NextNumber];
GO

ALTER TABLE [inventory].[DocumentSequences]
    ADD CONSTRAINT [DF_DocumentSequences_Year] DEFAULT ((0)) FOR [Year];
GO

