CREATE TABLE [purchase].[GoodsReceiptSwitch] (
    [Id]            TINYINT       NOT NULL,
    [SwitchedAtUtc] DATETIME2 (3) CONSTRAINT [DF_GoodsReceiptSwitch_At] DEFAULT (sysutcdatetime()) NOT NULL,
    CONSTRAINT [PK_GoodsReceiptSwitch] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_GoodsReceiptSwitch_One] CHECK ([Id]=(1))
);


GO

