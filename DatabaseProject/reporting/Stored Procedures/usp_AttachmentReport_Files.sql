/* ================================================================== 6. reporting.usp_AttachmentReport_Files */

CREATE   PROCEDURE reporting.usp_AttachmentReport_Files
    @Kinds       NVARCHAR(400),
    @Keys        NVARCHAR(MAX) = NULL,     -- "CNT:12,PDOC:3": the chosen files; NULL = everything matching the filters
    @TypeIds     NVARCHAR(MAX) = NULL,
    @DocFrom     DATE = NULL,
    @DocTo       DATE = NULL,
    @UploadFrom  DATE = NULL,
    @UploadTo    DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @K TABLE (Kind NVARCHAR(12) NOT NULL PRIMARY KEY);
    INSERT INTO @K (Kind) SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(ISNULL(@Kinds, N''), N',') WHERE LTRIM(RTRIM(value)) <> N'';
    DECLARE @T TABLE (Id INT NOT NULL PRIMARY KEY);
    INSERT INTO @T (Id) SELECT DISTINCT TRY_CAST(value AS INT) FROM STRING_SPLIT(ISNULL(@TypeIds, N''), N',') WHERE LTRIM(RTRIM(value)) <> N'' AND TRY_CAST(value AS INT) IS NOT NULL;
    DECLARE @AnyType BIT = CASE WHEN EXISTS (SELECT 1 FROM @T) THEN 0 ELSE 1 END;
    DECLARE @UploadToNext DATETIME2(3) = CASE WHEN @UploadTo IS NULL THEN NULL ELSE DATEADD(DAY, 1, CAST(@UploadTo AS DATETIME2(3))) END;

    DECLARE @Chosen TABLE (Source NVARCHAR(4) NOT NULL, Id INT NOT NULL, PRIMARY KEY (Source, Id));
    IF @Keys IS NOT NULL
        INSERT INTO @Chosen (Source, Id)
        SELECT DISTINCT LEFT(k.v, CHARINDEX(N':', k.v) - 1), TRY_CAST(SUBSTRING(k.v, CHARINDEX(N':', k.v) + 1, 20) AS INT)
        FROM (SELECT v = LTRIM(RTRIM(value)) FROM STRING_SPLIT(@Keys, N',')) k
        WHERE CHARINDEX(N':', k.v) > 1 AND TRY_CAST(SUBSTRING(k.v, CHARINDEX(N':', k.v) + 1, 20) AS INT) IS NOT NULL;

    -- A key of a kind the reader may not open is simply not found: the same rule as the list.
    SELECT a.Source, a.Id, a.DocumentKind, a.Reference, a.AttachmentTypeId,
           at.Category AS TypeCategory, at.SubType AS TypeSubType,
           a.FileName, a.ContentType, a.SizeBytes, DocumentDate = CONVERT(CHAR(10), a.DocumentDate, 23), a.UploadedAtUtc
    FROM reporting.fn_Attachments() a
    INNER JOIN @K k ON k.Kind = a.DocumentKind
    LEFT  JOIN masterdata.AttachmentTypes at ON at.Id = a.AttachmentTypeId
    WHERE (@Keys IS NOT NULL AND EXISTS (SELECT 1 FROM @Chosen c WHERE c.Source = a.Source AND c.Id = a.Id))
       OR (@Keys IS NULL
           AND (@AnyType = 1 OR a.AttachmentTypeId IN (SELECT Id FROM @T))
           AND (@DocFrom IS NULL OR a.DocumentDate >= @DocFrom)
           AND (@DocTo IS NULL OR a.DocumentDate <= @DocTo)
           AND (@UploadFrom IS NULL OR a.UploadedAtUtc >= CAST(@UploadFrom AS DATETIME2(3)))
           AND (@UploadToNext IS NULL OR a.UploadedAtUtc < @UploadToNext))
    ORDER BY a.Reference, ISNULL(a.DocumentDate, CAST(a.UploadedAtUtc AS DATE)), a.Source, a.Id;
END