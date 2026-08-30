namespace Inventory_Shipment.Model.Entities;

/// <summary>
/// One row per login attempt (table security.LoginAudit) - useful for spotting brute-force attempts.
/// </summary>
public class LoginAudit
{
    public long Id { get; set; }
    public string Username { get; set; } = string.Empty;
    public int? UserId { get; set; }
    public bool Succeeded { get; set; }
    public string? FailureReason { get; set; }
    public string? IpAddress { get; set; }
    public string? UserAgent { get; set; }
    public DateTime AttemptedAtUtc { get; set; }
}
