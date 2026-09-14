CREATE TABLE [inventory].[DocumentSequences] (
    [DocumentTypeId] INT NOT NULL,
    [BranchId]       INT NOT NULL,
    [NextNumber]     INT CONSTRAINT [DF_DocumentSequences_Next] DEFAULT ((1)) NOT NULL,
    CONSTRAINT [PK_DocumentSequences] PRIMARY KEY CLUSTERED ([DocumentTypeId] ASC, [BranchId] ASC),
    CONSTRAINT [FK_DocumentSequences_Branch] FOREIGN KEY ([BranchId]) REFERENCES [masterdata].[Branches] ([Id]),
    CONSTRAINT [FK_DocumentSequences_Type] FOREIGN KEY ([DocumentTypeId]) REFERENCES [inventory].[DocumentTypes] ([Id])
);

