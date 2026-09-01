-- roots get FAM-### . Only a suggestion - the user may edit it; uniqueness is enforced on save.
CREATE   PROCEDURE masterdata.usp_ItemFamily_NextChildCode
    @ParentId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Prefix NVARCHAR(60), @Seq INT = 1, @Digits INT, @Code NVARCHAR(60);

    IF @ParentId IS NULL
    BEGIN
        SET @Prefix = N'FAM-';
        SET @Digits = 3;
    END
    ELSE
    BEGIN
        SELECT @Prefix = FamilyCode + N'-' FROM masterdata.ItemFamilies WHERE Id = @ParentId;
        IF @Prefix IS NULL
            THROW 54006, 'Parent family not found.', 1;
        SET @Digits = 2;
    END

    SET @Code = @Prefix + RIGHT(REPLICATE(N'0', @Digits) + CAST(@Seq AS NVARCHAR(10)), @Digits);
    WHILE EXISTS (SELECT 1 FROM masterdata.ItemFamilies WHERE FamilyCode = @Code) AND @Seq < 100000
    BEGIN
        SET @Seq += 1;
        SET @Code = @Prefix + RIGHT(REPLICATE(N'0', @Digits) + CAST(@Seq AS NVARCHAR(10)), @Digits);
    END

    SELECT SuggestedCode = LEFT(@Code, 50);
END