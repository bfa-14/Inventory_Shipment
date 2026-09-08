CREATE   PROCEDURE inventory.usp_Item_SetActive
    @Id INT, @IsActive BIT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inventory.Items WHERE Id = @Id)
        THROW 56006, 'Item not found.', 1;
    UPDATE inventory.Items SET IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;
END