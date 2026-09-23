CREATE   PROCEDURE masterdata.usp_Currency_SetActive
    @Id       INT,
    @IsActive BIT,
    @UserId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @Id)
        THROW 53006, 'Currency not found.', 1;

    IF @IsActive = 0 AND EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @Id AND IsBaseCurrency = 1)
        THROW 53005, 'The Base Currency cannot be deactivated. Designate another currency as the Base Currency first.', 1;

    UPDATE masterdata.Currencies
    SET IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
END

GO

