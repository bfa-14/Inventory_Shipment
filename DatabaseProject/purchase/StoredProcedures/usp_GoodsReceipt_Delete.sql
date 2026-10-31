/* ================================================================== 17. Delete a draft */

-- A DRAFT ONLY (63005), with RowVersion (63004): its files, lines and audit go with it (nothing was in stock). The
-- container of a container receipt keeps a history line: it then waits without a receipt ("Receive goods..." again).
CREATE   PROCEDURE purchase.usp_GoodsReceipt_Delete
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT, @ContainerId INT, @IsAuto BIT, @MovNo NVARCHAR(30);
    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = g.Status, @ContainerId = g.ContainerId, @IsAuto = g.IsAuto, @MovNo = m.MovementNo
        FROM purchase.GoodsReceipts g WITH (UPDLOCK, HOLDLOCK)
        LEFT JOIN logistics.Movements m ON m.Id = g.MovementId
        WHERE g.Id = @Id;
        IF @Status IS NULL THROW 63006, 'Goods receipt not found.', 1;
        IF @Status <> 1 THROW 63005, 'Only a draft goods receipt can be changed or deleted.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.GoodsReceipts WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 63004, 'This goods receipt was modified by another user. Reload the page and try again.', 1;

        DELETE m FROM purchase.GoodsReceiptInvoiceMatches m
        INNER JOIN purchase.GoodsReceiptLines l ON l.Id = m.GoodsReceiptLineId
        WHERE l.GoodsReceiptId = @Id;
        DELETE FROM purchase.GoodsReceiptFiles WHERE GoodsReceiptId = @Id;
        DELETE FROM purchase.GoodsReceiptLines WHERE GoodsReceiptId = @Id;
        DELETE FROM purchase.GoodsReceiptAudit WHERE GoodsReceiptId = @Id;
        DELETE FROM purchase.GoodsReceipts WHERE Id = @Id;

        IF @ContainerId IS NOT NULL
            INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
            VALUES (@ContainerId, N'Event',
                    LEFT(N'Draft goods receipt deleted' + CASE WHEN @IsAuto = 1 THEN ISNULL(N' (created when ' + @MovNo + N' was completed)', N'') ELSE N'' END
                         + N': receive the container again with Receive goods' + NCHAR(8230), 500), @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

