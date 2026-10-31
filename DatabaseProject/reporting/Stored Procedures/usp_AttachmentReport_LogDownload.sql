/* ================================================================== 8. reporting.usp_AttachmentReport_LogDownload */

CREATE   PROCEDURE reporting.usp_AttachmentReport_LogDownload
    @UserId     INT,
    @Mode       NVARCHAR(20),
    @FileCount  INT,
    @TotalBytes BIGINT,
    @Criteria   NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO reporting.AttachmentDownloads (UserId, Mode, FileCount, TotalBytes, Criteria)
    VALUES (@UserId, @Mode, @FileCount, @TotalBytes, @Criteria);
END