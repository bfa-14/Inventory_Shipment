CREATE TABLE [inventory].[StockReasons] (
    [Id]         INT            IDENTITY (1, 1) NOT NULL,
    [ReasonCode] NVARCHAR (20)  NOT NULL,
    [ReasonName] NVARCHAR (100) NOT NULL,
    [AppliesTo]  NVARCHAR (10)  NOT NULL,
    [IsActive]   BIT            CONSTRAINT [DF_StockReasons_IsActive] DEFAULT ((1)) NOT NULL,
    CONSTRAINT [PK_StockReasons] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_StockReasons_AppliesTo] CHECK ([AppliesTo]=N'Both' OR [AppliesTo]=N'Out' OR [AppliesTo]=N'In'),
    CONSTRAINT [UQ_StockReasons_Code] UNIQUE NONCLUSTERED ([ReasonCode] ASC)
);

