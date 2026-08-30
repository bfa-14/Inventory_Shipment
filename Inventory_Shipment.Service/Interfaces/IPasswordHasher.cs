namespace Inventory_Shipment.Service.Interfaces;

public interface IPasswordHasher
{
    /// <summary>Returns a self-describing hash string ($argon2id$v=19$m=...,t=...,p=...$salt$hash).</summary>
    string Hash(string password);

    /// <summary>Constant-time verification. Returns false for malformed hashes instead of throwing.</summary>
    bool Verify(string password, string encodedHash);

    /// <summary>True when the hash was produced with weaker parameters than currently configured.</summary>
    bool NeedsRehash(string encodedHash);

    /// <summary>
    /// Burns the same CPU time as a real verification without a real hash. Called when the
    /// username does not exist, so response time cannot be used to enumerate accounts.
    /// </summary>
    void SimulateVerify(string password);
}
