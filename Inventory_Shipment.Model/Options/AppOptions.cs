namespace Inventory_Shipment.Model.Options;

/// <summary>Bound from the "App" configuration section: facts about where the application runs.</summary>
public sealed class AppOptions
{
    public const string SectionName = "App";

    public const string ProductionEnvironment = "production";
    public const string TestingEnvironment = "testing";

    /// <summary>
    /// The address of the web application (https://erp.example.com), used in the links put in emails.
    ///
    /// A FALLBACK ONLY: the address saved in Settings > Email wins. It lives in configuration too so
    /// that an installation can ship with the right address before anybody opens the page; empty here
    /// and on the page means no link can be built, and the procedures that would email one refuse.
    /// </summary>
    public string PublicBaseUrl { get; set; } = string.Empty;

    /// <summary>
    /// Which of the installations on the server this API is: "production" (the default, also when the
    /// setting is absent or empty) or "testing". The deployment sets it as App__Environment.
    ///
    /// TESTING NEVER EMAILS REAL PEOPLE: its database is usually a copy of production, with the real
    /// suppliers' and approvers' addresses in it, so the email outbox there either keeps every email
    /// Pending or sends it to <see cref="TestEmailRedirectTo"/> only. ANY OTHER VALUE COUNTS AS TESTING
    /// (see <see cref="IsTesting"/>): a typo must hold the emails back, not send them to real people.
    /// </summary>
    public string Environment { get; set; } = ProductionEnvironment;

    /// <summary>
    /// The testing environment only: the one address that receives every email instead of its recipients
    /// (App__TestEmailRedirectTo, TEST_EMAIL_REDIRECT_TO in deploy/.env). Empty, or not a valid address,
    /// means nothing is sent at all. Ignored in production.
    /// </summary>
    public string TestEmailRedirectTo { get; set; } = string.Empty;

    /// <summary>
    /// False only for "production" (any case) or an empty value; "testing" - and anything unexpected - is
    /// true, so that a mistyped environment can never email the real recipients of a copied database.
    /// </summary>
    public bool IsTesting
        => !string.IsNullOrWhiteSpace(Environment)
           && !string.Equals(Environment.Trim(), ProductionEnvironment, StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// Neither "production" nor "testing" (nor empty): most likely a typo, counted as testing all the same.
    /// The email outbox warns about it by name, because on a production server the cure is to correct
    /// ENVIRONMENT in deploy/.env, not to send every email to a test address.
    /// </summary>
    public bool IsUnexpectedEnvironment
        => IsTesting && !string.Equals(Environment.Trim(), TestingEnvironment, StringComparison.OrdinalIgnoreCase);
}
