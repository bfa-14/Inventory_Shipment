/* =====================================================================
   Inventory_Shipment - 01: database + [security] schema (users, refresh tokens, login audit)
   Run this in SSMS (it is safe to run more than once - every object is
   guarded with an existence check).
   The application also applies this same schema automatically on start-up,
   so running it by hand is optional.
   ===================================================================== */

IF DB_ID(N'Inventory_Shipment') IS NULL
BEGIN
    CREATE DATABASE [Inventory_Shipment];
END
GO

USE [Inventory_Shipment];
GO

/* Every module gets its own schema: security (this script), inventory, shipment. */
IF SCHEMA_ID(N'security') IS NULL
    EXEC (N'CREATE SCHEMA [security] AUTHORIZATION [dbo];');
GO

IF OBJECT_ID(N'security.Users', N'U') IS NULL
BEGIN
    CREATE TABLE security.Users
    (
        Id                  INT IDENTITY(1,1) NOT NULL,
        Username            NVARCHAR(50)      NOT NULL,
        Email               NVARCHAR(256)     NOT NULL,
        FullName            NVARCHAR(100)     NOT NULL,
        PasswordHash        NVARCHAR(512)     NOT NULL,
        Role                NVARCHAR(30)      NOT NULL CONSTRAINT DF_Users_Role DEFAULT (N'User'),
        IsActive            BIT               NOT NULL CONSTRAINT DF_Users_IsActive DEFAULT (1),
        FailedLoginAttempts INT               NOT NULL CONSTRAINT DF_Users_FailedLoginAttempts DEFAULT (0),
        LockoutEndUtc       DATETIME2(3)      NULL,
        LastLoginAtUtc      DATETIME2(3)      NULL,
        CreatedAtUtc        DATETIME2(3)      NOT NULL CONSTRAINT DF_Users_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        UpdatedAtUtc        DATETIME2(3)      NULL,
        CONSTRAINT PK_Users PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_Users_Username UNIQUE (Username),
        CONSTRAINT UQ_Users_Email UNIQUE (Email),
        CONSTRAINT CK_Users_Role CHECK (Role IN (N'Admin', N'Manager', N'User'))
    );
    PRINT 'Created table security.Users';
END
GO

IF OBJECT_ID(N'security.RefreshTokens', N'U') IS NULL
BEGIN
    CREATE TABLE security.RefreshTokens
    (
        Id                  BIGINT IDENTITY(1,1) NOT NULL,
        UserId              INT           NOT NULL,
        TokenHash           NVARCHAR(64)  NOT NULL,   -- SHA-256 (hex) of the raw token; the raw token is never stored
        ExpiresAtUtc        DATETIME2(3)  NOT NULL,
        CreatedAtUtc        DATETIME2(3)  NOT NULL CONSTRAINT DF_RefreshTokens_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedByIp         NVARCHAR(45)  NULL,
        RevokedAtUtc        DATETIME2(3)  NULL,
        RevokedByIp         NVARCHAR(45)  NULL,
        ReplacedByTokenHash NVARCHAR(64)  NULL,
        RevokeReason        NVARCHAR(100) NULL,
        CONSTRAINT PK_RefreshTokens PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_RefreshTokens_TokenHash UNIQUE (TokenHash),
        CONSTRAINT FK_RefreshTokens_Users FOREIGN KEY (UserId) REFERENCES security.Users (Id) ON DELETE CASCADE
    );

    CREATE NONCLUSTERED INDEX IX_RefreshTokens_UserId ON security.RefreshTokens (UserId);
    PRINT 'Created table security.RefreshTokens';
END
GO

IF OBJECT_ID(N'security.LoginAudit', N'U') IS NULL
BEGIN
    CREATE TABLE security.LoginAudit
    (
        Id             BIGINT IDENTITY(1,1) NOT NULL,
        Username       NVARCHAR(256) NOT NULL,
        UserId         INT           NULL,
        Succeeded      BIT           NOT NULL,
        FailureReason  NVARCHAR(100) NULL,
        IpAddress      NVARCHAR(45)  NULL,
        UserAgent      NVARCHAR(512) NULL,
        AttemptedAtUtc DATETIME2(3)  NOT NULL CONSTRAINT DF_LoginAudit_AttemptedAtUtc DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_LoginAudit PRIMARY KEY CLUSTERED (Id)
    );

    CREATE NONCLUSTERED INDEX IX_LoginAudit_Username_AttemptedAtUtc ON security.LoginAudit (Username, AttemptedAtUtc DESC);
    PRINT 'Created table security.LoginAudit';
END
GO

PRINT 'security schema is ready.';
GO
