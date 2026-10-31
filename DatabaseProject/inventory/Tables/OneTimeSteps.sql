CREATE TABLE [inventory].[OneTimeSteps] (
    [StepCode]     NVARCHAR (60)  NOT NULL,
    [StartedAtUtc] DATETIME2 (3)  CONSTRAINT [DF_OneTimeSteps_Started] DEFAULT (sysutcdatetime()) NOT NULL,
    [DoneAtUtc]    DATETIME2 (3)  NULL,
    [Progress]     INT            NULL,
    [Details]      NVARCHAR (400) NULL,
    CONSTRAINT [PK_OneTimeSteps] PRIMARY KEY CLUSTERED ([StepCode] ASC)
);


GO

