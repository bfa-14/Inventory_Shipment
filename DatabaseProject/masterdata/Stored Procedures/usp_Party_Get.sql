
CREATE   PROCEDURE masterdata.usp_Party_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT p.Id, p.PartyCode, p.PartyName, p.IsSupplier, p.IsClient, p.IsSalesman, p.IsEmployee,
           p.BranchId, b.BranchCode, b.BranchName, p.ContactPerson, p.Phone, p.Mobile, p.Email,
           p.Address, p.Country, p.TaxRegistrationNo, p.Notes,
           p.UserId, u.Username AS UserName, u.FullName AS UserFullName,
           p.DefaultPriceListId, pl.PriceListName AS DefaultPriceListName,
           p.DefaultCurrencyId, c.CurrencyCode AS DefaultCurrencyCode,
           p.IsActive, p.CreatedAtUtc, p.CreatedBy, p.UpdatedAtUtc, p.UpdatedBy, p.RowVersion
    FROM masterdata.Parties p
    LEFT JOIN masterdata.Branches b    ON b.Id  = p.BranchId
    LEFT JOIN security.Users u         ON u.Id  = p.UserId
    LEFT JOIN masterdata.PriceLists pl ON pl.Id = p.DefaultPriceListId
    LEFT JOIN masterdata.Currencies c  ON c.Id  = p.DefaultCurrencyId
    WHERE p.Id = @Id;
END