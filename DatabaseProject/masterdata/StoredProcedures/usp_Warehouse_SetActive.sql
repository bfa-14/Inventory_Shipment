CREATE   PROCEDURE masterdata.usp_Warehouse_SetActive
    @Id       INT,
    @IsActive BIT,
    @UserId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @Id)
        THROW 52006, 'Warehouse not found.', 1;

    IF @IsActive = 0 AND EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @Id AND IsMainWarehouse = 1)
        THROW 52005, 'The Main Warehouse cannot be deactivated. Designate another warehouse as the Main Warehouse first.', 1;

    -- Re-activating a warehouse whose branch is inactive is not allowed (rule 3).
    IF @IsActive = 1 AND NOT EXISTS (SELECT 1 FROM masterdata.Warehouses w INNER JOIN masterdata.Branches b ON b.Id = w.BranchId
                                     WHERE w.Id = @Id AND b.IsActive = 1)
        THROW 52007, 'The warehouse cannot be activated because its Branch / Site is inactive.', 1;

    UPDATE masterdata.Warehouses
    SET IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
END

GO

