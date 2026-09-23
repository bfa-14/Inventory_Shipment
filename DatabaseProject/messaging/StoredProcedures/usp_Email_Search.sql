
CREATE   PROCEDURE messaging.usp_Email_Search
    @Search            NVARCHAR(200) = NULL,    -- recipient or subject
    @Status            TINYINT       = NULL,
    @Category          NVARCHAR(40)  = NULL,
    @RelatedDocumentId INT           = NULL,
    @DateFrom          DATE          = NULL,
    @DateTo            DATE          = NULL,
    @PageNumber        INT           = 1,
    @PageSize          INT           = 20
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 20;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');

    SELECT e.Id, e.ToAddresses, e.CcAddresses, e.Subject, e.Category, e.RelatedDocumentId, e.Status, e.Attempts,
           e.NextAttemptAtUtc, e.LastError, e.CreatedAtUtc, e.SentAtUtc, e.AttachmentName,
           AttachmentSize = DATALENGTH(e.AttachmentContent),
           COUNT(*) OVER () AS TotalCount
    FROM messaging.EmailOutbox e
    WHERE (@Search IS NULL OR e.ToAddresses LIKE N'%' + @Search + N'%' OR e.Subject LIKE N'%' + @Search + N'%')
      AND (@Status IS NULL OR e.Status = @Status)
      AND (@Category IS NULL OR e.Category = @Category)
      AND (@RelatedDocumentId IS NULL OR e.RelatedDocumentId = @RelatedDocumentId)
      AND (@DateFrom IS NULL OR e.CreatedAtUtc >= @DateFrom)
      AND (@DateTo IS NULL OR e.CreatedAtUtc < DATEADD(DAY, 1, @DateTo))
    ORDER BY e.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

