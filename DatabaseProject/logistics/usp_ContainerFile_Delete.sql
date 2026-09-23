
CREATE   PROCEDURE logistics.usp_ContainerFile_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ContainerId INT, @FileName NVARCHAR(255);
    SELECT @ContainerId = ContainerId, @FileName = FileName FROM logistics.ContainerFiles WHERE Id = @Id;
    IF @ContainerId IS NULL THROW 69006, 'File not found.', 1;
    DELETE FROM logistics.ContainerFiles WHERE Id = @Id;
    INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
    VALUES (@ContainerId, N'Updated', N'Attachment removed: ' + @FileName, @UserId);
END
GO

