CREATE TABLE [masterdata].[PaymentMethods] (
    [Id]           INT            IDENTITY (1, 1) NOT NULL,
    [MethodCode]   NVARCHAR (10)  NOT NULL,
    [MethodName]   NVARCHAR (100) NOT NULL,
    [Description]  NVARCHAR (500) NULL,
    [IsActive]     BIT            CONSTRAINT [DF_PaymentMethods_IsActive] DEFAULT ((1)) NOT NULL,
    [CreatedAtUtc] DATETIME2 (3)  CONSTRAINT [DF_PaymentMethods_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]    INT            NULL,
    [UpdatedAtUtc] DATETIME2 (3)  NULL,
    [UpdatedBy]    INT            NULL,
    [RowVersion]   ROWVERSION     NOT NULL,
    CONSTRAINT [PK_PaymentMethods] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_PaymentMethods_Code_NotBlank] CHECK (len(ltrim(rtrim([MethodCode])))>(0)),
    CONSTRAINT [CK_PaymentMethods_Name_NotBlank] CHECK (len(ltrim(rtrim([MethodName])))>(0)),
    CONSTRAINT [FK_PaymentMethods_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_PaymentMethods_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [UQ_PaymentMethods_Code] UNIQUE NONCLUSTERED ([MethodCode] ASC)
);


GO

