CREATE   PROCEDURE purchase.usp_PurchaseDocument_MarkShipped
    @Id         INT,
    @Lines      purchase.tvp_ShippedLine READONLY,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT, @TypeCode NVARCHAR(20);
    SELECT @Status = d.Status, @TypeCode = dt.Code
    FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId WHERE d.Id = @Id;
    IF @Status IS NULL THROW 65006, 'Document not found.', 1;
    IF @TypeCode <> N'PO' OR @Status <> 2 THROW 65010, 'Shipped quantities can only be recorded on an open (posted) purchase order.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
    IF EXISTS (SELECT 1 FROM @Lines s LEFT JOIN purchase.PurchaseDocumentLines l ON l.Id = s.LineId AND l.DocumentId = @Id
               WHERE l.Id IS NULL OR s.ShippedQuantityBase < 0 OR s.ShippedQuantityBase > l.QuantityBase)
        THROW 65000, 'A shipped quantity is negative, above the ordered quantity, or refers to a line of another document.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        IF EXISTS (SELECT 1 FROM @Lines)
            UPDATE l SET ShippedQuantityBase = s.ShippedQuantityBase
            FROM purchase.PurchaseDocumentLines l INNER JOIN @Lines s ON s.LineId = l.Id;
        ELSE
            UPDATE purchase.PurchaseDocumentLines SET ShippedQuantityBase = QuantityBase WHERE DocumentId = @Id;

        UPDATE purchase.PurchaseDocuments SET UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;
        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@Id, N'Updated', N'Shipped quantities recorded: ' + CAST((SELECT SUM(ShippedQuantityBase) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id) AS NVARCHAR(20)) + N' base unit(s) in transit', @UserId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

