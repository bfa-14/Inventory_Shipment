/* ================================================================== 1. Numbers never cut */

-- Re-created (78) from the body of script 22: a sequence longer than the type's NumberLength keeps all its digits
-- (the numbers given so far, padded to the length, read the same).
CREATE   PROCEDURE inventory.usp_DocumentType_NextNumber
    @Code           NVARCHAR(20),
    @DocumentNumber NVARCHAR(30) OUTPUT,
    @BranchId       INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TypeId INT, @Prefix NVARCHAR(10), @Len TINYINT, @PerBranch BIT, @YearIn BIT;
    SELECT @TypeId = Id, @Prefix = NumberPrefix, @Len = NumberLength, @PerBranch = NumberPerBranch, @YearIn = YearInNumber
    FROM inventory.DocumentTypes WHERE Code = @Code AND IsActive = 1;
    IF @TypeId IS NULL THROW 62008, 'Document type not found or inactive.', 1;

    DECLARE @Year INT = YEAR(SYSUTCDATETIME());
    DECLARE @SeqYear INT = CASE WHEN @YearIn = 1 THEN @Year ELSE 0 END;
    DECLARE @Taken TABLE (Number INT);
    DECLARE @Middle NVARCHAR(20) = N'';

    IF @PerBranch = 1 AND @BranchId IS NOT NULL
    BEGIN
        DECLARE @BranchCode NVARCHAR(20) = (SELECT BranchCode FROM masterdata.Branches WHERE Id = @BranchId);
        IF @BranchCode IS NULL THROW 62008, 'Branch not found.', 1;

        MERGE inventory.DocumentSequences WITH (HOLDLOCK) AS t
        USING (SELECT @TypeId AS DocumentTypeId, @BranchId AS BranchId, @SeqYear AS [Year]) AS s
            ON t.DocumentTypeId = s.DocumentTypeId AND t.BranchId = s.BranchId AND t.[Year] = s.[Year]
        WHEN MATCHED THEN UPDATE SET NextNumber = t.NextNumber + 1
        WHEN NOT MATCHED THEN INSERT (DocumentTypeId, BranchId, [Year], NextNumber) VALUES (s.DocumentTypeId, s.BranchId, s.[Year], 2)
        OUTPUT ISNULL(deleted.NextNumber, 1) INTO @Taken (Number);

        SET @Middle = UPPER(LEFT(@BranchCode, 8)) + N'-';
    END
    ELSE
    BEGIN
        UPDATE inventory.DocumentTypes WITH (UPDLOCK, ROWLOCK)
        SET NextNumber     = CASE WHEN @YearIn = 1 AND ISNULL(NextNumberYear, 0) <> @Year THEN 2 ELSE NextNumber + 1 END,
            NextNumberYear = CASE WHEN @YearIn = 1 THEN @Year ELSE NextNumberYear END
        OUTPUT CASE WHEN @YearIn = 1 AND ISNULL(deleted.NextNumberYear, 0) <> @Year THEN 1 ELSE deleted.NextNumber END INTO @Taken (Number)
        WHERE Id = @TypeId;
    END

    IF @YearIn = 1 SET @Middle = @Middle + CAST(@Year AS NVARCHAR(4)) + N'-';

    -- (78) NEVER CUT THE SEQUENCE: padded to the type's length, but a sequence that has outgrown the length keeps all its
    -- digits (KTG-2026-10000). RIGHT(..., @Len) alone gave container 10,000 of a year KTG-2026-0000 and the next one a
    -- duplicate of KTG-2026-0001 (UQ_Containers_Ref), refusing every new container for the rest of the year.
    SELECT @DocumentNumber = @Prefix + @Middle
                           + CASE WHEN LEN(CAST(Number AS NVARCHAR(10))) >= @Len THEN CAST(Number AS NVARCHAR(10))
                                  ELSE RIGHT(REPLICATE(N'0', @Len) + CAST(Number AS NVARCHAR(10)), @Len) END
    FROM @Taken;
END

GO

