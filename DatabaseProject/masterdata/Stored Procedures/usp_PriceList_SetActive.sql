CREATE   PROCEDURE masterdata.usp_PriceList_SetActive
    @Id INT, @IsActive BIT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE Id = @Id)
        THROW 58006, 'Price list not found.', 1;
    UPDATE masterdata.PriceLists SET IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;
END