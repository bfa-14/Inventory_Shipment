-- entered rate is safe and allowed.
CREATE   PROCEDURE masterdata.usp_ExchangeRate_Delete
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM masterdata.ExchangeRates WHERE Id = @Id)
        THROW 53006, 'Exchange rate not found.', 1;

    DELETE FROM masterdata.ExchangeRates WHERE Id = @Id;
END