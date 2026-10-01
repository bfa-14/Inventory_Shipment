using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.MasterData;
using Inventory_Shipment.Model.Entities;

namespace Inventory_Shipment.Service.Mapping;

public static class PartyMapper
{
    public static PartyDto ToDto(this Party party) => new()
    {
        Id = party.Id,
        PartyCode = party.PartyCode,
        PartyName = party.PartyName,
        IsSupplier = party.IsSupplier,
        IsClient = party.IsClient,
        IsSalesman = party.IsSalesman,
        IsEmployee = party.IsEmployee,
        BranchId = party.BranchId,
        BranchCode = party.BranchCode,
        BranchName = party.BranchName,
        ContactPerson = party.ContactPerson,
        Phone = party.Phone,
        Mobile = party.Mobile,
        Email = party.Email,
        Address = party.Address,
        Country = party.Country,
        TaxRegistrationNo = party.TaxRegistrationNo,
        Notes = party.Notes,
        UserId = party.UserId,
        UserName = party.UserName,
        UserFullName = party.UserFullName,
        DefaultPriceListId = party.DefaultPriceListId,
        DefaultPriceListName = party.DefaultPriceListName,
        DefaultCurrencyId = party.DefaultCurrencyId,
        DefaultCurrencyCode = party.DefaultCurrencyCode,
        IsActive = party.IsActive,
        CreatedAtUtc = party.CreatedAtUtc.AsUtc(),
        UpdatedAtUtc = party.UpdatedAtUtc.AsUtc(),
        RowVersion = Convert.ToBase64String(party.RowVersion)
    };

    public static PartyLookupDto ToDto(this PartyLookup party) => new()
    {
        Id = party.Id,
        PartyCode = party.PartyCode,
        PartyName = party.PartyName,
        IsSupplier = party.IsSupplier,
        IsClient = party.IsClient,
        IsSalesman = party.IsSalesman,
        IsEmployee = party.IsEmployee,
        BranchId = party.BranchId,
        DefaultPriceListId = party.DefaultPriceListId,
        DefaultCurrencyId = party.DefaultCurrencyId,
        UserId = party.UserId,
        IsActive = party.IsActive,
        Address = party.Address
    };
}
