-- pieces are matched to posted invoices (69016, rule 20).
-- (65) ONE TRANSACTION, THE CONTAINER READ UNDER LOCK (UPDLOCK, HOLDLOCK) BEFORE ANY CHECK: goods receipt Post and
-- Cancel hold the container the same way while they change its status, so Close waits for them and checks what they
-- committed. Read without the lock, a Close that ran during the Cancel of the container's receipt read "Offloaded",
-- waited, then closed a container whose receipt was cancelled (no stock, no offload date, and taken from then on for an
-- offload of the old kind). The write is guarded as well (Status = 6).
CREATE   PROCEDURE logistics.usp_Container_Close
    @Id INT, @RowVersion BINARY(8) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT;
        SELECT @Status = Status FROM logistics.Containers WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NULL THROW 69006, 'Container not found.', 1;
        IF @Status <> 6 THROW 69010, 'Only an offloaded container can be closed.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 69004, 'This container was modified by another user. Reload the page and try again.', 1;
        -- Draft charges (70010), then (65) RULE 20: A CONTAINER RECEIVED WITH A GOODS RECEIPT CLOSES WHEN EVERY RECEIVED
        -- PIECE IS MATCHED TO A POSTED INVOICE (69016: the matches of its receipt's lines, per container line). Goods
        -- may now arrive before their invoice, and a closed container is frozen. An offload of the old kind needed the
        -- posted invoices before it: no check for those. Both from fn_Container_CloseBlock, which the container page and
        -- list read too.
        DECLARE @BlockNumber INT, @Msg NVARCHAR(400);
        SELECT @BlockNumber = b.ErrorNumber, @Msg = b.Reason FROM logistics.fn_Container_CloseBlock(@Id) b;
        IF @BlockNumber = 70010 THROW 70010, @Msg, 1;
        IF @BlockNumber = 69016 THROW 69016, @Msg, 1;

        UPDATE logistics.Containers
        SET Status = 7, ClosedAtUtc = SYSUTCDATETIME(), ClosedBy = @UserId, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id AND Status = 6;
        IF @@ROWCOUNT = 0 THROW 69010, 'Only an offloaded container can be closed.', 1;
        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId) VALUES (@Id, N'Closed', N'Container closed', @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

