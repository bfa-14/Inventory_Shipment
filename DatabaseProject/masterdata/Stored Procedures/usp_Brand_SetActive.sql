CREATE   PROCEDURE masterdata.usp_Brand_SetActive
    @Id       INT,
    @IsActive BIT,
    @UserId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Brands WHERE Id = @Id)
        THROW 55006, 'Brand not found.', 1;

    UPDATE masterdata.Brands
    SET IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
END