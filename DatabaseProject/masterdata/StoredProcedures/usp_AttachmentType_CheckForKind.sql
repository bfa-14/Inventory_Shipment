/* ================================================================== 4. The check of every upload and edit */

-- One place for the rule: a type is chosen, exists, is active and is used for the document's kind. @ErrorNumber is
-- the module's (62011, 64017, 65032, 70017, 71016), so each module classifies the refusal as its own.
CREATE   PROCEDURE masterdata.usp_AttachmentType_CheckForKind
    @AttachmentTypeId INT,
    @DocumentKind     NVARCHAR(20),
    @ErrorNumber      INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Msg NVARCHAR(400), @Name NVARCHAR(60), @Active BIT;
    IF @AttachmentTypeId IS NULL THROW @ErrorNumber, 'Choose the attachment type.', 1;
    SELECT @Name = SubType, @Active = IsActive FROM masterdata.AttachmentTypes WHERE Id = @AttachmentTypeId;
    IF @Name IS NULL THROW @ErrorNumber, 'The attachment type was not found.', 1;
    IF @Active = 0
    BEGIN
        SET @Msg = N'The attachment type ' + @Name + N' is inactive.';
        THROW @ErrorNumber, @Msg, 1;
    END
    IF NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypeUsages WHERE AttachmentTypeId = @AttachmentTypeId AND DocumentKind = @DocumentKind)
    BEGIN
        SET @Msg = N'The attachment type ' + @Name + N' is not used for '
                 + ISNULL((SELECT Noun FROM masterdata.fn_AttachmentDocumentKinds() WHERE Code = @DocumentKind), @DocumentKind) + N'.';
        THROW @ErrorNumber, @Msg, 1;
    END
END

GO

