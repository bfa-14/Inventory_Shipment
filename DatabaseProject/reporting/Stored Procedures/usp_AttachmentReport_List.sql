/* ================================================================== 5. reporting.usp_AttachmentReport_List */

CREATE   PROCEDURE reporting.usp_AttachmentReport_List
    @Kinds       NVARCHAR(400),            -- the document kinds the reader may open, comma separated (the API's)
    @TypeIds     NVARCHAR(MAX) = NULL,     -- attachment type ids, comma separated; empty = every type
    @DocFrom     DATE = NULL,
    @DocTo       DATE = NULL,
    @UploadFrom  DATE = NULL,
    @UploadTo    DATE = NULL,
    @Page        INT = 1,
    @PageSize    INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    IF @Page IS NULL OR @Page < 1 SET @Page = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 50;
    IF @PageSize > 500 SET @PageSize = 500;

    DECLARE @K TABLE (Kind NVARCHAR(12) NOT NULL PRIMARY KEY);
    INSERT INTO @K (Kind) SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(ISNULL(@Kinds, N''), N',') WHERE LTRIM(RTRIM(value)) <> N'';
    DECLARE @T TABLE (Id INT NOT NULL PRIMARY KEY);
    INSERT INTO @T (Id) SELECT DISTINCT TRY_CAST(value AS INT) FROM STRING_SPLIT(ISNULL(@TypeIds, N''), N',') WHERE LTRIM(RTRIM(value)) <> N'' AND TRY_CAST(value AS INT) IS NOT NULL;
    DECLARE @AnyType BIT = CASE WHEN EXISTS (SELECT 1 FROM @T) THEN 0 ELSE 1 END;
    -- Upload dates are UTC timestamps: a day runs to the next midnight.
    DECLARE @UploadToNext DATETIME2(3) = CASE WHEN @UploadTo IS NULL THEN NULL ELSE DATEADD(DAY, 1, CAST(@UploadTo AS DATETIME2(3))) END;

    SELECT a.Source, a.Id, a.DocumentKind, a.OwnerId, a.Reference, a.AttachmentTypeId,
           at.Category AS TypeCategory, at.SubType AS TypeSubType,
           a.FileName, a.ContentType, a.SizeBytes, a.DocumentDate, a.UploadedAtUtc, u.FullName AS UploadedByName
    INTO #M
    FROM reporting.fn_Attachments() a
    INNER JOIN @K k ON k.Kind = a.DocumentKind
    LEFT  JOIN masterdata.AttachmentTypes at ON at.Id = a.AttachmentTypeId
    LEFT  JOIN security.Users u ON u.Id = a.UploadedBy
    WHERE (@AnyType = 1 OR a.AttachmentTypeId IN (SELECT Id FROM @T))
      AND (@DocFrom IS NULL OR a.DocumentDate >= @DocFrom)
      AND (@DocTo IS NULL OR a.DocumentDate <= @DocTo)
      AND (@UploadFrom IS NULL OR a.UploadedAtUtc >= CAST(@UploadFrom AS DATETIME2(3)))
      AND (@UploadToNext IS NULL OR a.UploadedAtUtc < @UploadToNext);

    -- Newest first: by the document's own date, else the day it was uploaded.
    -- The document date goes out as plain yyyy-MM-dd text: a calendar date, never a timestamp.
    SELECT m.Source, m.Id, m.DocumentKind, m.OwnerId, m.Reference, m.AttachmentTypeId, m.TypeCategory, m.TypeSubType,
           m.FileName, m.ContentType, m.SizeBytes, DocumentDate = CONVERT(CHAR(10), m.DocumentDate, 23), m.UploadedAtUtc,
           m.UploadedByName
    FROM #M m
    ORDER BY ISNULL(m.DocumentDate, CAST(m.UploadedAtUtc AS DATE)) DESC, m.UploadedAtUtc DESC, m.Source, m.Id
    OFFSET (@Page - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;

    SELECT TotalCount = COUNT(*), TotalBytes = ISNULL(SUM(CAST(SizeBytes AS BIGINT)), 0) FROM #M;
END