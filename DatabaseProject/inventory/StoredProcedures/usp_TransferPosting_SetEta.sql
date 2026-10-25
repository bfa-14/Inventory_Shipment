/* 13.24 CHANGE A DISPATCH'S ETA (D12: trucks are late). The posting's order is locked and its RowVersion checked
   (@RowVersion is the ORDER's); the order's rule (Blocks, ChangeEta), then: a posted dispatch with goods on the way
   (62010), the ETA required and not before the dispatch date. Nothing changed: nothing written. Audit EtaChanged
   "{TRD}: ETA {old} -> {new}". */
CREATE   PROCEDURE inventory.usp_TransferPosting_SetEta
    @PostingId  INT,
    @RowVersion BINARY(8) = NULL,     -- the ORDER's
    @Eta        DATE      = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @OrderId INT, @Status TINYINT, @Kind NVARCHAR(10), @PStatus TINYINT,
            @Number NVARCHAR(30), @PostingDate DATE, @OldEta DATE, @OnTheWay INT, @Now DATETIME2(3) = SYSUTCDATETIME();

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @OrderId = TransferOrderId FROM inventory.TransferPostings WHERE Id = @PostingId;
        IF @OrderId IS NULL THROW 62006, 'Dispatch or receipt not found.', 1;

        SELECT @Status = Status FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @OrderId;
        IF @Status IS NOT NULL AND @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @OrderId AND RowVersion = @RowVersion)
            THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;

        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@OrderId, @UserId) b
        WHERE b.Action = N'ChangeEta' AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        SELECT @Kind = p.Kind, @PStatus = p.Status, @Number = p.DocumentNumber, @PostingDate = p.PostingDate, @OldEta = p.Eta,
               @OnTheWay = (SELECT ISNULL(SUM(pl.QuantityBase - pl.SettledBase), 0) FROM inventory.TransferPostingLines pl WHERE pl.PostingId = p.Id)
        FROM inventory.TransferPostings p WITH (UPDLOCK, HOLDLOCK)
        WHERE p.Id = @PostingId;

        IF NOT (@Kind = N'Dispatch' AND @PStatus = 2 AND @OnTheWay > 0)
            THROW 62010, 'Only a dispatch with goods on the way can change its ETA.', 1;
        IF @Eta IS NULL THROW 62000, 'The ETA is required.', 1;
        IF @Eta < @PostingDate THROW 62000, 'The ETA cannot be before the dispatch date.', 1;

        IF @Eta <> @OldEta
        BEGIN
            UPDATE inventory.TransferPostings SET Eta = @Eta WHERE Id = @PostingId;

            -- the order's RowVersion moves: Late and the page's figures follow the new ETA
            UPDATE inventory.TransferOrders SET UpdatedAtUtc = @Now, UpdatedBy = @UserId WHERE Id = @OrderId;

            INSERT INTO inventory.TransferOrderAudit (TransferOrderId, PostingId, Action, Details, UserId)
            VALUES (@OrderId, @PostingId, N'EtaChanged',
                    LEFT(@Number + N': ETA ' + ISNULL(CONVERT(NVARCHAR(10), @OldEta, 103), N'none') + N' -> '
                         + CONVERT(NVARCHAR(10), @Eta, 103), 500), @UserId);
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

