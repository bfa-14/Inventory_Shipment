/* ================================================================== 8. Settings procedures */

-- 8.1 Settings > Purchase approval: 1) the rules, 2) every active user and their approval rights.
CREATE   PROCEDURE purchase.usp_ApprovalSettings_Get
AS
BEGIN
    SET NOCOUNT ON;

    SELECT s.Id, s.RequireApproval, s.ApprovalLimitBase, s.AllowSelfApproval, s.LinkValidHours, s.ReminderHours,
           s.NotifyAppApprovers, s.EmailSupplierOnApproval, s.CopyToOwners, s.CopyToEmails, s.UpdatedAtUtc, s.UpdatedBy,
           BaseCurrencyCode = (SELECT TOP (1) CurrencyCode FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1),
           UpdatedByName = u.FullName,
           s.RowVersion
    FROM purchase.ApprovalSettings s
    LEFT JOIN security.Users u ON u.Id = s.UpdatedBy
    WHERE s.Id = 1;

    SELECT UserId = u.Id, u.FullName, UserName = u.Username, e.Email,
           Roles = (SELECT STRING_AGG(r.Name, N', ') WITHIN GROUP (ORDER BY r.Name)
                    FROM security.UserRoles ur INNER JOIN security.Roles r ON r.Id = ur.RoleId
                    WHERE ur.UserId = u.Id),
           IsAdministrator = CAST(CASE WHEN EXISTS (SELECT 1 FROM security.UserRoles ur INNER JOIN security.Roles r ON r.Id = ur.RoleId
                                                    WHERE ur.UserId = u.Id AND r.IsSystem = 1) THEN 1 ELSE 0 END AS BIT),
           CanApproveInApp = CAST(ISNULL(a.CanApproveInApp, 0) AS BIT),
           CanApproveByEmail = CAST(CASE WHEN a.CanApproveByEmail = 1 AND e.Email IS NOT NULL THEN 1 ELSE 0 END AS BIT)
    FROM security.Users u
    CROSS APPLY (SELECT Email = NULLIF(LTRIM(RTRIM(u.Email)), N'')) e
    LEFT JOIN purchase.OrderApprovers a ON a.UserId = u.Id
    WHERE u.IsActive = 1
    ORDER BY IsAdministrator DESC, u.FullName;
END

GO

