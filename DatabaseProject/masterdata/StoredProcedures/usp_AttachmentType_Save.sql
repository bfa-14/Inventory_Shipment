-- least one; NULL = unchanged on an update, and on an insert the kind of @AppliesTo (Receipt = RCPT, else CONTAINER).
CREATE   PROCEDURE masterdata.usp_AttachmentType_Save
    @Id         INT          = NULL,
    @Category   NVARCHAR(30),
    @SubType    NVARCHAR(60),
    @SortOrder  INT          = 0,
    @IsActive   BIT          = 1,
    @RowVersion BINARY(8)    = NULL,
    @UserId     INT          = NULL,
    @NewId      INT OUTPUT,
    /* NULL = leave it alone on an update, and Logistics on an insert: every caller that predates the
       column keeps doing exactly what it did. */
    @AppliesTo  NVARCHAR(12) = NULL,
    @UsedFor    NVARCHAR(400) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Category = NULLIF(LTRIM(RTRIM(@Category)), N'');
    SET @SubType = NULLIF(LTRIM(RTRIM(@SubType)), N'');
    SET @AppliesTo = NULLIF(LTRIM(RTRIM(@AppliesTo)), N'');
    IF @Category IS NULL THROW 69000, 'Category is required.', 1;
    IF @SubType IS NULL THROW 69000, 'Sub type is required.', 1;
    IF @AppliesTo IS NOT NULL AND @AppliesTo NOT IN (N'Logistics', N'Receipt') THROW 69000, 'Applies to must be Logistics or Receipt.', 1;
    IF EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Category = @Category AND SubType = @SubType AND (@Id IS NULL OR Id <> @Id))
        THROW 69013, 'This category and sub type already exist.', 1;

    DECLARE @Kinds TABLE (Code NVARCHAR(20) PRIMARY KEY);
    IF @UsedFor IS NOT NULL
    BEGIN
        INSERT INTO @Kinds (Code)
        SELECT DISTINCT UPPER(LTRIM(RTRIM(value))) FROM STRING_SPLIT(@UsedFor, N',') WHERE LTRIM(RTRIM(value)) <> N'';
        IF NOT EXISTS (SELECT 1 FROM @Kinds) THROW 69000, 'Choose at least one document kind the type is used for.', 1;
        DECLARE @Unknown NVARCHAR(20) = (SELECT TOP (1) x.Code FROM @Kinds x
                                         WHERE NOT EXISTS (SELECT 1 FROM masterdata.fn_AttachmentDocumentKinds() k WHERE k.Code = x.Code));
        IF @Unknown IS NOT NULL
        BEGIN
            DECLARE @Msg NVARCHAR(200) = N'Unknown document kind: ' + @Unknown + N'.';
            THROW 69000, @Msg, 1;
        END
    END
    ELSE IF @Id IS NULL
        INSERT INTO @Kinds (Code) VALUES (CASE WHEN @AppliesTo = N'Receipt' THEN N'RCPT' ELSE N'CONTAINER' END);

    BEGIN TRY
        BEGIN TRANSACTION;
        IF @Id IS NULL
        BEGIN
            INSERT INTO masterdata.AttachmentTypes (Category, SubType, SortOrder, IsActive, AppliesTo, CreatedBy)
            VALUES (@Category, @SubType, ISNULL(@SortOrder, 0), ISNULL(@IsActive, 1), ISNULL(@AppliesTo, N'Logistics'), @UserId);
            SET @NewId = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Id = @Id) THROW 69006, 'Attachment type not found.', 1;
            IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Id = @Id AND RowVersion = @RowVersion)
                THROW 69004, 'This attachment type was modified by another user. Reload the page and try again.', 1;
            UPDATE masterdata.AttachmentTypes
            SET Category = @Category, SubType = @SubType, SortOrder = ISNULL(@SortOrder, 0), IsActive = ISNULL(@IsActive, 1),
                AppliesTo = ISNULL(@AppliesTo, AppliesTo),
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;
            SET @NewId = @Id;
        END

        IF EXISTS (SELECT 1 FROM @Kinds)
        BEGIN
            DELETE FROM masterdata.AttachmentTypeUsages
            WHERE AttachmentTypeId = @NewId AND DocumentKind NOT IN (SELECT Code FROM @Kinds);
            INSERT INTO masterdata.AttachmentTypeUsages (AttachmentTypeId, DocumentKind)
            SELECT @NewId, x.Code FROM @Kinds x
            WHERE NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypeUsages u WHERE u.AttachmentTypeId = @NewId AND u.DocumentKind = x.Code);
        END
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

