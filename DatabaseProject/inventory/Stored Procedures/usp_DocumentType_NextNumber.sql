-- The third parameter is optional so older callers keep working (they get the company-wide format).
CREATE   PROCEDURE inventory.usp_DocumentType_NextNumber
    @Code           NVARCHAR(20),
    @DocumentNumber NVARCHAR(30) OUTPUT,
    @BranchId       INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TypeId INT, @Prefix NVARCHAR(10), @Len TINYINT, @PerBranch BIT;
    SELECT @TypeId = Id, @Prefix = NumberPrefix, @Len = NumberLength, @PerBranch = NumberPerBranch
    FROM inventory.DocumentTypes WHERE Code = @Code AND IsActive = 1;
    IF @TypeId IS NULL THROW 62008, 'Document type not found or inactive.', 1;

    DECLARE @Taken TABLE (Number INT);

    IF @PerBranch = 1 AND @BranchId IS NOT NULL
    BEGIN
        DECLARE @BranchCode NVARCHAR(20) = (SELECT BranchCode FROM masterdata.Branches WHERE Id = @BranchId);
        IF @BranchCode IS NULL THROW 62008, 'Branch not found.', 1;

        MERGE inventory.DocumentSequences WITH (HOLDLOCK) AS t
        USING (SELECT @TypeId AS DocumentTypeId, @BranchId AS BranchId) AS s
            ON t.DocumentTypeId = s.DocumentTypeId AND t.BranchId = s.BranchId
        WHEN MATCHED THEN UPDATE SET NextNumber = t.NextNumber + 1
        WHEN NOT MATCHED THEN INSERT (DocumentTypeId, BranchId, NextNumber) VALUES (s.DocumentTypeId, s.BranchId, 2)
        OUTPUT ISNULL(deleted.NextNumber, 1) INTO @Taken (Number);

        SELECT @DocumentNumber = @Prefix + UPPER(LEFT(@BranchCode, 8)) + N'-' + RIGHT(REPLICATE(N'0', @Len) + CAST(Number AS NVARCHAR(10)), @Len)
        FROM @Taken;
    END
    ELSE
    BEGIN
        UPDATE inventory.DocumentTypes WITH (UPDLOCK, ROWLOCK)
        SET NextNumber = NextNumber + 1
        OUTPUT deleted.NextNumber INTO @Taken (Number)
        WHERE Id = @TypeId;

        SELECT @DocumentNumber = @Prefix + RIGHT(REPLICATE(N'0', @Len) + CAST(Number AS NVARCHAR(10)), @Len) FROM @Taken;
    END
END