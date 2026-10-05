/* ================================================================== 10. Master data: attachment types */

-- The document kinds, for the "Used for" lists of the pages (api/masterdata/attachment-types/document-kinds).
CREATE   PROCEDURE masterdata.usp_AttachmentType_DocumentKinds
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Code, Name FROM masterdata.fn_AttachmentDocumentKinds() ORDER BY SortOrder;
END

GO

