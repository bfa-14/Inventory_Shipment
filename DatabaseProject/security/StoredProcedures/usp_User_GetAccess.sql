CREATE   PROCEDURE security.usp_User_GetAccess
    @UserId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT Id, Name FROM security.fn_UserRoles(@UserId) ORDER BY Name;
    SELECT Code FROM security.fn_UserPermissions(@UserId) ORDER BY Code;
END

GO

