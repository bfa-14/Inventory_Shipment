-- Re-created (114) from the body of script 42: COLLATE DATABASE_DEFAULT on the text columns of its #tables (4).
CREATE   PROCEDURE purchase.usp_PurchaseOrder_Resend
    @PurchaseDocumentId INT,
    @RowVersion         BINARY(8) = NULL,
    @UserId             INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #IssuedLinks
    (
        PurchaseDocumentId INT NOT NULL, UserId INT NOT NULL, FullName NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL, Email NVARCHAR(256) COLLATE DATABASE_DEFAULT NULL,
        Token VARCHAR(64) COLLATE DATABASE_DEFAULT NULL, ExpiresAtUtc DATETIME2(3) NULL, RequestNo INT NOT NULL, Channel NVARCHAR(10) COLLATE DATABASE_DEFAULT NOT NULL,
        CanApproveInApp BIT NOT NULL, SendEmail BIT NOT NULL
    );

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Current BINARY(8);
        SELECT @Status = d.Status, @TypeCode = dt.Code, @Current = d.RowVersion
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @PurchaseDocumentId;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @TypeCode <> N'PO' OR @Status <> 5 THROW 65010, 'Only a purchase order waiting for approval can be sent again.', 1;
        IF @RowVersion IS NOT NULL AND @Current <> @RowVersion
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;

        EXEC purchase.usp_PurchaseOrder_IssueLinks @PurchaseDocumentId = @PurchaseDocumentId, @EventType = 3, @UserId = @UserId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT UserId, FullName, Email, Token, ExpiresAtUtc, RequestNo, Channel, CanApproveInApp, SendEmail
    FROM #IssuedLinks
    ORDER BY FullName;
END

GO

