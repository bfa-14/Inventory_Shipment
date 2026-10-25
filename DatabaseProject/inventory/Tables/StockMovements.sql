CREATE TABLE [inventory].[StockMovements] (
    [Id]               BIGINT          IDENTITY (1, 1) NOT NULL,
    [MovementDate]     DATETIME2 (3)   NOT NULL,
    [ItemId]           INT             NOT NULL,
    [WarehouseId]      INT             NOT NULL,
    [BranchId]         INT             NOT NULL,
    [QuantityBase]     INT             NOT NULL,
    [UnitCostBase]     DECIMAL (18, 6) NULL,
    [DocumentFamily]   NVARCHAR (20)   NOT NULL,
    [DocumentTypeCode] NVARCHAR (20)   NOT NULL,
    [DocumentId]       INT             NOT NULL,
    [DocumentLineId]   INT             NOT NULL,
    [DocumentNumber]   NVARCHAR (30)   NOT NULL,
    [ReasonCode]       NVARCHAR (20)   NULL,
    [ExpiryDate]       DATE            NULL,
    [IsReversal]       BIT             CONSTRAINT [DF_StockMovements_IsReversal] DEFAULT ((0)) NOT NULL,
    [CreatedAtUtc]     DATETIME2 (3)   CONSTRAINT [DF_StockMovements_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]        INT             NULL,
    CONSTRAINT [PK_StockMovements] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_StockMovements_Qty] CHECK ([QuantityBase]<>(0)),
    CONSTRAINT [FK_StockMovements_Branch] FOREIGN KEY ([BranchId]) REFERENCES [masterdata].[Branches] ([Id]),
    CONSTRAINT [FK_StockMovements_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_StockMovements_Item] FOREIGN KEY ([ItemId]) REFERENCES [inventory].[Items] ([Id]),
    CONSTRAINT [FK_StockMovements_Warehouse] FOREIGN KEY ([WarehouseId]) REFERENCES [masterdata].[Warehouses] ([Id])
);


GO

/* ================================================================== 5. The net: the ledger trigger */

-- (92) THE NET UNDER EVERY DOCUMENT THAT MOVES STOCK. A restricted user (security.Users.AllWarehouses = 0, not a system
--      administrator) can never write a ledger row into or out of a warehouse that is not theirs, whatever wrote it: a
--      posting, a cancellation, a reversal, an import, a bulk action, the receipt an invoice makes when it is posted, a
--      family added later. It trusts CreatedBy, which every writer stamps with the acting user (W16). The first
--      statement leaves at once when no row is a restricted user's. A refusal aborts the statement and dooms the
--      writer's transaction; the writer's CATCH rethrows 50010 with this sentence (inside "Receive the goods now" it
--      becomes the invoice's warning). AFTER INSERT only (the one DELETE, script 31's, is untouched); it writes
--      nothing, so it never recurses and keeps the writer's @@ROWCOUNT and SCOPE_IDENTITY().
CREATE   TRIGGER inventory.TR_StockMovements_WarehouseAccess
ON inventory.StockMovements
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;
    -- The first statement: leave when no inserted row is a restricted user's. It reads only the users who WROTE the
    -- rows, one primary-key seek per distinct CreatedBy (FORCESEEK), the row the foreign-key check on CreatedBy already
    -- reads: never a scan of security.Users, which under locking READ COMMITTED would make every posting wait for any
    -- open change to any user (a sign-in stamping LastLoginAtUtc, a role edit, the Warehouses dialog, an SSMS session).
    -- The writers below read the same way.
    IF NOT EXISTS (SELECT 1
                   FROM (SELECT DISTINCT CreatedBy FROM inserted WHERE CreatedBy IS NOT NULL) i
                   INNER JOIN security.Users u WITH (FORCESEEK) ON u.Id = i.CreatedBy
                   WHERE u.AllWarehouses = 0)
        RETURN;
    DECLARE @UserId INT, @Ids NVARCHAR(MAX), @Refusal NVARCHAR(400);
    SET @UserId = (SELECT MIN(i.CreatedBy)
                   FROM (SELECT DISTINCT CreatedBy FROM inserted WHERE CreatedBy IS NOT NULL) i
                   INNER JOIN security.Users u WITH (FORCESEEK) ON u.Id = i.CreatedBy
                   WHERE u.AllWarehouses = 0);
    WHILE @UserId IS NOT NULL
    BEGIN
        SET @Ids = (SELECT STRING_AGG(CAST(x.WarehouseId AS NVARCHAR(MAX)), N',')
                    FROM (SELECT DISTINCT WarehouseId FROM inserted WHERE CreatedBy = @UserId) x);
        SET @Refusal = security.fn_User_WarehouseRefusal(@UserId, @Ids);
        IF @Refusal IS NOT NULL THROW 50010, @Refusal, 1;
        SET @UserId = (SELECT MIN(i.CreatedBy)
                       FROM (SELECT DISTINCT CreatedBy FROM inserted WHERE CreatedBy > @UserId) i
                       INNER JOIN security.Users u WITH (FORCESEEK) ON u.Id = i.CreatedBy
                       WHERE u.AllWarehouses = 0);
    END
END

GO

CREATE NONCLUSTERED INDEX [IX_StockMovements_Document]
    ON [inventory].[StockMovements]([DocumentFamily] ASC, [DocumentId] ASC);


GO

CREATE NONCLUSTERED INDEX [IX_StockMovements_ItemWarehouseDate]
    ON [inventory].[StockMovements]([ItemId] ASC, [WarehouseId] ASC, [MovementDate] ASC)
    INCLUDE([QuantityBase], [UnitCostBase]);


GO

CREATE NONCLUSTERED INDEX [IX_StockMovements_WarehouseDate]
    ON [inventory].[StockMovements]([WarehouseId] ASC, [MovementDate] ASC)
    INCLUDE([ItemId], [QuantityBase]);


GO

