CREATE TYPE [purchase].[tvp_OrderApprover] AS TABLE (
    [UserId]            INT NOT NULL,
    [CanApproveInApp]   BIT NOT NULL,
    [CanApproveByEmail] BIT NOT NULL,
    PRIMARY KEY CLUSTERED ([UserId] ASC));


GO

