CREATE   PROCEDURE inventory.usp_ShortageDocument_Recalculate
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT = (SELECT Status FROM inventory.ShortageDocuments WHERE Id = @Id);
    IF @Status IS NULL THROW 66006, 'Shortage document not found.', 1;
    IF @Status <> 1 THROW 66005, 'Only draft shortage documents can be recalculated.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.ShortageDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 66004, 'This document was modified by another user. Reload the page and try again.', 1;

    DECLARE @Lines inventory.tvp_ShortageLine;
    INSERT INTO @Lines (LineNumber, ItemId, RequiredQty, ExpectedMonthlySalesManual, PcPerContainer, Notes)
    SELECT LineNumber, ItemId, RequiredQty, ExpectedMonthlySalesManual, PcPerContainer, Notes
    FROM inventory.ShortageDocumentLines WHERE DocumentId = @Id;

    BEGIN TRY
        BEGIN TRANSACTION;
        EXEC inventory.usp_ShortageDocument_WriteLines @Id, @Lines;
        UPDATE inventory.ShortageDocuments SET UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;
        INSERT INTO inventory.ShortageDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@Id, N'Recalculated', N'Live figures refreshed', @UserId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

