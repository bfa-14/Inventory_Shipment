-- the API needs for the follow-up emails. Columns of script 26 first, the new ones at the end.
CREATE   PROCEDURE purchase.usp_PurchaseOrder_DecisionResult
    @PurchaseDocumentId INT,
    @Approve            BIT,
    @UserId             INT,
    @Note               NVARCHAR(500) = NULL,
    @Channel            TINYINT,
    @Direct             BIT           = 0       -- approved directly: there is no request, so no requester
AS
BEGIN
    SET NOCOUNT ON;
    SELECT d.Id AS DocumentId, d.DocumentNumber,
           Decision = CASE WHEN @Approve = 1 THEN N'Approved' ELSE N'Rejected' END,
           DecidedByName = du.FullName, DecisionNote = @Note, Channel = CASE WHEN @Channel = 2 THEN N'Email' ELSE N'App' END,
           sp.PartyName AS SupplierName, sp.Email AS SupplierEmail,
           cu.FullName AS CreatorName, cu.Email AS CreatorEmail,
           RequestedByName = CASE WHEN @Direct = 0 THEN rq.FullName END,
           RequestedByEmail = CASE WHEN @Direct = 0 THEN rq.Email END,
           OwnerEmails = STUFF((SELECT N';' + u.Email
                                FROM security.Users u
                                INNER JOIN security.UserRoles ur ON ur.UserId = u.Id
                                INNER JOIN security.Roles r ON r.Id = ur.RoleId AND r.Name = N'Owner'
                                WHERE u.IsActive = 1 AND NULLIF(LTRIM(RTRIM(u.Email)), N'') IS NOT NULL
                                FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, N''),
           -- script 42
           d.Status, d.RowVersion,
           DecidedBy = @UserId, DecidedByEmail = NULLIF(LTRIM(RTRIM(du.Email)), N''),
           d.CreatedBy, RequestedBy = CASE WHEN @Direct = 0 THEN d.ApprovalRequestedBy END,
           d.SupplierId, ChannelId = @Channel, Direct = @Direct,
           EmailSupplierOnApproval = CAST(ISNULL(s.EmailSupplierOnApproval, 1) AS BIT),
           CopyToOwners = CAST(ISNULL(s.CopyToOwners, 1) AS BIT),
           s.CopyToEmails
    FROM purchase.PurchaseDocuments d
    INNER JOIN masterdata.Parties sp ON sp.Id = d.SupplierId
    LEFT  JOIN purchase.ApprovalSettings s ON s.Id = 1
    LEFT  JOIN security.Users du ON du.Id = @UserId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users rq ON rq.Id = d.ApprovalRequestedBy
    WHERE d.Id = @PurchaseDocumentId;
END

GO

