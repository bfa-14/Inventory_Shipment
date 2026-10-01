CREATE TABLE [purchase].[OrderApprovers] (
    [UserId]            INT           NOT NULL,
    [CanApproveInApp]   BIT           NOT NULL,
    [CanApproveByEmail] BIT           NOT NULL,
    [UpdatedAtUtc]      DATETIME2 (0) CONSTRAINT [DF_OrderApprovers_UpdatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [UpdatedBy]         INT           NULL,
    CONSTRAINT [PK_OrderApprovers] PRIMARY KEY CLUSTERED ([UserId] ASC),
    CONSTRAINT [CK_OrderApprovers_AnyRight] CHECK ([CanApproveInApp]=(1) OR [CanApproveByEmail]=(1)),
    CONSTRAINT [FK_OrderApprovers_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_OrderApprovers_User] FOREIGN KEY ([UserId]) REFERENCES [security].[Users] ([Id])
);


GO

