CREATE   PROCEDURE masterdata.usp_ItemFamily_SetActive
    @Id       INT,
    @IsActive BIT,
    @UserId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM masterdata.ItemFamilies WHERE Id = @Id)
        THROW 54006, 'Item family not found.', 1;

    IF @IsActive = 1 AND EXISTS (SELECT 1 FROM masterdata.ItemFamilies c
                                 INNER JOIN masterdata.ItemFamilies p ON p.Id = c.ParentId
                                 WHERE c.Id = @Id AND p.IsActive = 0)
        THROW 54008, 'The parent family is inactive. Activate the parent first.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @IsActive = 1
        BEGIN
            UPDATE masterdata.ItemFamilies
            SET IsActive = 1, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id AND IsActive = 0;
        END
        ELSE
        BEGIN
            -- Deactivate the family AND its whole subtree.
            UPDATE f
            SET IsActive = 0, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            FROM masterdata.ItemFamilies f
            INNER JOIN masterdata.fn_ItemFamily_Subtree(@Id) s ON s.Id = f.Id
            WHERE f.IsActive = 1;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END