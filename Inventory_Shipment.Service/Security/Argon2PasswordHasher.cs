using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Inventory_Shipment.Model.Options;
using Inventory_Shipment.Service.Interfaces;
using Konscious.Security.Cryptography;
using Microsoft.Extensions.Options;

namespace Inventory_Shipment.Service.Security;

/// <summary>
/// Argon2id password hashing (RFC 9106) using Konscious.Security.Cryptography.
/// Hash format: <c>$argon2id$v=19$m=&lt;kb&gt;,t=&lt;iterations&gt;,p=&lt;lanes&gt;$&lt;salt-base64&gt;$&lt;hash-base64&gt;</c>.
/// Parameters are embedded in the hash, so they can be raised later and old hashes still verify
/// (and are upgraded on the next successful login via <see cref="NeedsRehash"/>).
/// </summary>
public sealed class Argon2PasswordHasher : IPasswordHasher
{
    private const string Prefix = "$argon2id$";
    private const int Version = 19;
    private const int SaltSize = 16;
    private const int HashSize = 32;

    private readonly Argon2Options _options;
    private readonly Lazy<string> _dummyHash;

    public Argon2PasswordHasher(IOptions<SecurityOptions> options)
    {
        _options = options.Value.Argon2;
        _dummyHash = new Lazy<string>(() => Hash(Convert.ToBase64String(RandomNumberGenerator.GetBytes(24))));
    }

    public string Hash(string password)
    {
        ArgumentException.ThrowIfNullOrEmpty(password);

        var salt = RandomNumberGenerator.GetBytes(SaltSize);
        var hash = Compute(password, salt, _options.MemoryKb, _options.Iterations, _options.Parallelism);

        return string.Create(CultureInfo.InvariantCulture,
            $"{Prefix}v={Version}$m={_options.MemoryKb},t={_options.Iterations},p={_options.Parallelism}${Convert.ToBase64String(salt)}${Convert.ToBase64String(hash)}");
    }

    public bool Verify(string password, string encodedHash)
    {
        if (string.IsNullOrEmpty(password) || !TryParse(encodedHash, out var parsed))
        {
            return false;
        }

        var computed = Compute(password, parsed.Salt, parsed.MemoryKb, parsed.Iterations, parsed.Parallelism);
        return CryptographicOperations.FixedTimeEquals(computed, parsed.Hash);
    }

    public bool NeedsRehash(string encodedHash)
    {
        if (!TryParse(encodedHash, out var parsed))
        {
            return true;
        }

        return parsed.MemoryKb != _options.MemoryKb
            || parsed.Iterations != _options.Iterations
            || parsed.Parallelism != _options.Parallelism;
    }

    public void SimulateVerify(string password)
    {
        // Same cost as a real verification, result deliberately ignored.
        _ = Verify(string.IsNullOrEmpty(password) ? "x" : password, _dummyHash.Value);
    }

    private static byte[] Compute(string password, byte[] salt, int memoryKb, int iterations, int parallelism)
    {
        using var argon2 = new Argon2id(Encoding.UTF8.GetBytes(password))
        {
            Salt = salt,
            MemorySize = memoryKb,
            Iterations = iterations,
            DegreeOfParallelism = parallelism
        };

        return argon2.GetBytes(HashSize);
    }

    private static bool TryParse(string? encoded, out ParsedHash parsed)
    {
        parsed = default;

        if (string.IsNullOrEmpty(encoded) || !encoded.StartsWith(Prefix, StringComparison.Ordinal))
        {
            return false;
        }

        // ["", "argon2id", "v=19", "m=..,t=..,p=..", salt, hash]
        var parts = encoded.Split('$');
        if (parts.Length != 6 || parts[2] != $"v={Version}")
        {
            return false;
        }

        int memoryKb = 0, iterations = 0, parallelism = 0;
        foreach (var kv in parts[3].Split(','))
        {
            var eq = kv.IndexOf('=');
            if (eq <= 0 || !int.TryParse(kv.AsSpan(eq + 1), NumberStyles.None, CultureInfo.InvariantCulture, out var value))
            {
                return false;
            }

            switch (kv[..eq])
            {
                case "m": memoryKb = value; break;
                case "t": iterations = value; break;
                case "p": parallelism = value; break;
                default: return false;
            }
        }

        if (memoryKb <= 0 || iterations <= 0 || parallelism <= 0)
        {
            return false;
        }

        try
        {
            var salt = Convert.FromBase64String(parts[4]);
            var hash = Convert.FromBase64String(parts[5]);
            if (salt.Length == 0 || hash.Length == 0)
            {
                return false;
            }

            parsed = new ParsedHash(memoryKb, iterations, parallelism, salt, hash);
            return true;
        }
        catch (FormatException)
        {
            return false;
        }
    }

    private readonly record struct ParsedHash(int MemoryKb, int Iterations, int Parallelism, byte[] Salt, byte[] Hash);
}
