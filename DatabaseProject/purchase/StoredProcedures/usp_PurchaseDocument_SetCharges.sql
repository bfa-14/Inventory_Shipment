CREATE   PROCEDURE purchase.usp_PurchaseDocument_SetCharges
    @DocumentId        INT,
    @Charges           purchase.tvp_PurchaseCharge READONLY,
    @ManualAllocations purchase.tvp_ManualAllocation READONLY,
    @RowVersion        BINARY(8) = NULL,
    @UserId            INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Date DATE, @CurrencyId INT;
    SELECT @Status = d.Status, @TypeCode = dt.Code, @Date = d.DocumentDate, @CurrencyId = d.CurrencyId
    FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId WHERE d.Id = @DocumentId;
    IF @Status IS NULL THROW 65006, 'Document not found.', 1;
    IF @TypeCode <> N'PINV' THROW 65010, 'Charges are entered on purchase invoices only (use a Landed Cost Adjustment after posting).', 1;
    IF @Status <> 1 THROW 65005, 'Charges can only be changed on a draft invoice.', 1;
    IF EXISTS (SELECT 1 FROM @Charges)
       AND EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines WHERE DocumentId = @DocumentId AND ContainerLineId IS NOT NULL)
        THROW 65020, 'This invoice comes from containers: its charges are entered on the containers (Container Charges).', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @DocumentId AND RowVersion = @RowVersion)
        THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        EXEC purchase.usp_PurchaseCharges_Write N'PINV', @DocumentId, @Date, @CurrencyId, @DocumentId, @Charges, @ManualAllocations, @UserId;
        UPDATE purchase.PurchaseDocuments SET UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @DocumentId;
        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@DocumentId, N'Updated', N'Charges saved: ' + CAST((SELECT COUNT(*) FROM @Charges) AS NVARCHAR(10)) + N' line(s)', @UserId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

