
CREATE   PROCEDURE masterdata.usp_AttachmentType_Save
    @Id         INT          = NULL,
    @Category   NVARCHAR(30),
    @SubType    NVARCHAR(60),
    @SortOrder  INT          = 0,
    @IsActive   BIT          = 1,
    @RowVersion BINARY(8)    = NULL,
    @UserId     INT          = NULL,
    @NewId      INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Category = NULLIF(LTRIM(RTRIM(@Category)), N'');
    SET @SubType = NULLIF(LTRIM(RTRIM(@SubType)), N'');
    IF @Category IS NULL THROW 69000, 'Category is required.', 1;
    IF @SubType IS NULL THROW 69000, 'Sub type is required.', 1;
    IF EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Category = @Category AND SubType = @SubType AND (@Id IS NULL OR Id <> @Id))
        THROW 69013, 'This category and sub type already exist.', 1;

    IF @Id IS NULL
    BEGIN
        INSERT INTO masterdata.AttachmentTypes (Category, SubType, SortOrder, IsActive, CreatedBy)
        VALUES (@Category, @SubType, ISNULL(@SortOrder, 0), ISNULL(@IsActive, 1), @UserId);
        SET @NewId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Id = @Id) THROW 69006, 'Attachment type not found.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 69004, 'This attachment type was modified by another user. Reload the page and try again.', 1;
        UPDATE masterdata.AttachmentTypes
        SET Category = @Category, SubType = @SubType, SortOrder = ISNULL(@SortOrder, 0), IsActive = ISNULL(@IsActive, 1),
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;
        SET @NewId = @Id;
    END
END
GO

