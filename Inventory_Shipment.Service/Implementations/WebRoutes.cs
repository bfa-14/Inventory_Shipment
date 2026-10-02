namespace Inventory_Shipment.Service.Implementations;

/// <summary>
/// THE ONLY PLACE THAT KNOWS THE ROUTES OF THE WEB APPLICATION (Inventory_Shipment.Web/src/App.tsx): the
/// links put in emails. When a page moves there, it moves here - nowhere else builds a URL of the web app.
/// </summary>
public static class WebRoutes
{
    /// <summary>The purchase order page: /purchase/orders/{id} (App.tsx, PURCHASE_ORDER.route).</summary>
    public static string PurchaseOrder(string publicBaseUrl, int id) => $"{publicBaseUrl}/purchase/orders/{id}";

    /// <summary>The public approval page of a personal link; <paramref name="approve"/> chooses the button the page puts first.</summary>
    public static string PurchaseApproval(string publicBaseUrl, string token, bool approve)
        => $"{publicBaseUrl}/purchase-approval/{token}?action={(approve ? "approve" : "reject")}";
}
