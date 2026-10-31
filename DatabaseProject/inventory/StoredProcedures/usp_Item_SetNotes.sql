/* ================================================================== 3. usp_Item_SetNotes */

CREATE   PROCEDURE inventory.usp_Item_SetNotes
    @Id     INT,
    @Note   NVARCHAR(2000) = NULL,
    @Link   NVARCHAR(500)  = NULL,
    @UserId INT            = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inventory.Items WHERE Id = @Id) THROW 56000, 'Item not found.', 1;

    -- Blank is "no note" / "no link".
    SET @Note = NULLIF(LTRIM(RTRIM(@Note)), N'');
    SET @Link = NULLIF(LTRIM(RTRIM(@Link)), N'');

    /* THE LINK IS OPENED IN A NEW TAB, so only a real web address is kept: http:// or https://, something after it,
       no spaces. Anything else (javascript:, a file path, a typo) is refused rather than stored. */
    IF @Link IS NOT NULL
       AND (NOT (@Link LIKE N'http://_%' OR @Link LIKE N'https://_%')
            OR @Link LIKE N'% %' OR @Link LIKE N'%' + CHAR(9) + N'%' OR @Link LIKE N'%' + CHAR(10) + N'%' OR @Link LIKE N'%' + CHAR(13) + N'%')
        THROW 56000, 'The link must be a web address starting with http:// or https://, without spaces.', 1;

    UPDATE inventory.Items
    SET Note = @Note, Link = @Link,
        UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
END

GO

