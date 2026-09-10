CREATE   PROCEDURE inventory.usp_DocumentType_NextNumber
    @Code           NVARCHAR(20),
    @DocumentNumber NVARCHAR(30) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Taken TABLE (Prefix NVARCHAR(10), Number INT, Len TINYINT);

    UPDATE inventory.DocumentTypes WITH (UPDLOCK, ROWLOCK)
    SET NextNumber = NextNumber + 1
    OUTPUT deleted.NumberPrefix, deleted.NextNumber, deleted.NumberLength INTO @Taken
    WHERE Code = @Code AND IsActive = 1;

    IF NOT EXISTS (SELECT 1 FROM @Taken)
        THROW 62008, 'Document type not found or inactive.', 1;

    SELECT @DocumentNumber = Prefix + RIGHT(REPLICATE(N'0', Len) + CAST(Number AS NVARCHAR(10)), Len) FROM @Taken;
END