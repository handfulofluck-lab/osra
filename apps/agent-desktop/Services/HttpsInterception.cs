using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Titanium.Web.Proxy;

namespace FamilyShield.Agent.Services;

/// <summary>
/// Feature #3 HTTPS inspection, enabled only when FS_HTTPS_INSPECT=1. Generates (once) a
/// self-signed "FamilyShield Test Root" RSA-2048 CA, exports it to
/// %LOCALAPPDATA%\FamilyShield\rootCert.pfx, and installs the public key into the
/// CurrentUser\Root store so browsers trust the per-site certs the proxy mints.
/// </summary>
/// <remarks>
/// TRUST IMPLICATION (test build): anything signed by this root is trusted for the current
/// Windows user, for all purposes, until removed from certmgr.msc — that is the documented
/// risk of HTTPS inspection per SPEC-ADDENDUM Feature #3. The private key lives in the PFX
/// beside the agent database. NOTE: the first install into CurrentUser\Root makes Windows show
/// a one-time interactive "Security Warning" dialog (per root cert per user) that must be
/// confirmed by the logged-in user; idempotent re-adds hit the thumbprint check and do not
/// re-prompt.
/// Upstream certificates are validated by default (see <see cref="ValidateUpstreamCertificate"/>);
/// <c>FS_HTTPS_INSPECT_ALLOW_INSECURE=1</c> is the explicit, logged, test-machine opt-out.
/// </remarks>
public static class HttpsInterception
{
    /// <summary>Env gate: only "1" enables HTTPS inspection (SPEC-ADDENDUM Feature #3).</summary>
    public const string EnvVar = "FS_HTTPS_INSPECT";

    /// <summary>
    /// Test-machine escape hatch: when exactly "1", upstream server certificates are accepted
    /// without validation. Off by default; using it logs a loud warning. Never set it on a family
    /// PC — it turns inspection into a machine-in-the-middle for every HTTPS site.
    /// </summary>
    public const string InsecureEnvVar = "FS_HTTPS_INSPECT_ALLOW_INSECURE";

    /// <summary>Subject simple name stamped on the generated root CA.</summary>
    public const string RootCertSubject = "FamilyShield Test Root";

    /// <summary>Default PFX path: %LOCALAPPDATA%\FamilyShield\rootCert.pfx.</summary>
    public static string PfxPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "FamilyShield", "rootCert.pfx");

    /// <summary>True when FS_HTTPS_INSPECT=1.</summary>
    public static bool IsEnabled =>
        string.Equals(Environment.GetEnvironmentVariable(EnvVar), "1", StringComparison.Ordinal);

    /// <summary>True when inspection is enabled and the root cert PFX already exists (healthy).</summary>
    public static bool IsActive => IsEnabled && File.Exists(PfxPath);

    /// <summary>
    /// True only when <see cref="InsecureEnvVar"/> is exactly "1". Default false: upstream
    /// certificates are validated against the Windows trust store.
    /// </summary>
    public static bool AllowInsecureUpstream =>
        string.Equals(Environment.GetEnvironmentVariable(InsecureEnvVar), "1", StringComparison.Ordinal);

    /// <summary>
    /// Wires a Titanium proxy for TLS termination: loads (or generates + exports + trust-installs)
    /// the root CA, hands it to the proxy and validates every upstream server certificate.
    /// Returns false when inspection is disabled or anything fails — the caller then keeps
    /// decryptSsl:false (plain-HTTP-only filtering).
    /// </summary>
    /// <param name="proxy">Proxy to configure.</param>
    /// <param name="pfxPath">Root-CA PFX path; defaults to <see cref="PfxPath"/>.</param>
    /// <param name="warn">Receives the loud warning when the insecure opt-out is on; defaults to stderr.</param>
    public static bool TryConfigureDecryption(ProxyServer proxy, string? pfxPath = null, Action<string>? warn = null)
    {
        if (!IsEnabled) return false;
        var root = EnsureRootCertificate(pfxPath);
        if (root is null) return false;
        proxy.CertificateManager.RootCertificate = root;

        var allowInsecure = AllowInsecureUpstream;
        if (allowInsecure)
        {
            (warn ?? Console.Error.WriteLine)(
                $"OSRA SECURITY WARNING: {InsecureEnvVar}=1 — HTTPS inspection accepts ANY upstream " +
                "certificate (no chain or host-name validation). Use only on a disposable test machine.");
        }

        proxy.ServerCertificateValidationCallback += (_, e) =>
        {
            e.IsValid = ValidateUpstreamCertificate(e.Certificate, e.SslPolicyErrors, allowInsecure);
            return Task.CompletedTask;
        };
        return true;
    }

    /// <summary>
    /// Upstream certificate policy (audit finding 2). With the insecure opt-out on everything is
    /// accepted; otherwise the certificate must be present, have no platform errors and build a
    /// chain against the Windows trust store. Revocation is not fetched (offline test PCs would
    /// otherwise reject every site); the chain, expiry and host name are still checked.
    /// </summary>
    public static bool ValidateUpstreamCertificate(
        X509Certificate? certificate,
        SslPolicyErrors errors,
        bool allowInsecure)
    {
        if (allowInsecure) return true;
        if (certificate is null || errors != SslPolicyErrors.None) return false;

        try
        {
            var cert2 = certificate as X509Certificate2;
            if (cert2 is null)
            {
                using var copy = new X509Certificate2(certificate);
                cert2 = new X509Certificate2(copy.RawData);
            }

            using var chain = new X509Chain();
            chain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
            return chain.Build(cert2);
        }
        catch (Exception)
        {
            // A certificate that cannot be read or chained is not trusted.
            return false;
        }
    }

    /// <summary>
    /// Returns the root CA, generating and exporting the PFX on first use and installing the
    /// public key into CurrentUser\Root (idempotent by thumbprint). Null on failure.
    /// </summary>
    public static X509Certificate2? EnsureRootCertificate(string? pfxPath = null)
    {
        var path = string.IsNullOrWhiteSpace(pfxPath) ? PfxPath : pfxPath;
        try
        {
            var cert = File.Exists(path) ? Load(path) : GenerateAndExport(path);
            InstallToUserRootStore(cert);
            return cert;
        }
        catch (Exception)
        {
            // NOTE: fail-soft — without a usable root CA the proxy simply stays decryptSsl:false.
            return null;
        }
    }

    /// <summary>Loads the root CA from the PFX (private key included).</summary>
    private static X509Certificate2 Load(string path) => new(path);

    /// <summary>Creates the self-signed RSA-2048 root CA and exports it as PFX.</summary>
    private static X509Certificate2 GenerateAndExport(string path)
    {
        using var rsa = RSA.Create(2048);
        var req = new CertificateRequest($"CN={RootCertSubject}", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        req.CertificateExtensions.Add(new X509BasicConstraintsExtension(true, false, 0, true));
        req.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.KeyCertSign | X509KeyUsageFlags.CrlSign, true));
        req.CertificateExtensions.Add(new X509SubjectKeyIdentifierExtension(req.PublicKey, false));
        // NOTE: backdated one day so freshly-minted per-site certs are never rejected for
        // not-yet-valid skew on the child's clock.
        using var cert = req.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(5));
        var pfx = cert.Export(X509ContentType.Pfx);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, pfx);
        return new X509Certificate2(pfx);
    }

    /// <summary>Adds the cert to CurrentUser\Root when not already present (idempotent).</summary>
    private static void InstallToUserRootStore(X509Certificate2 cert)
    {
        using var store = new X509Store(StoreName.Root, StoreLocation.CurrentUser);
        store.Open(OpenFlags.ReadWrite);
        var existing = store.Certificates.Find(X509FindType.FindByThumbprint, cert.Thumbprint, false);
        if (existing.Count == 0) store.Add(cert);
    }

    /// <summary>Removes the cert from CurrentUser\Root (used by integration tests and uninstall paths).</summary>
    public static void RemoveFromUserRootStore(X509Certificate2 cert)
    {
        try
        {
            using var store = new X509Store(StoreName.Root, StoreLocation.CurrentUser);
            store.Open(OpenFlags.ReadWrite);
            var existing = store.Certificates.Find(X509FindType.FindByThumbprint, cert.Thumbprint, false);
            store.RemoveRange(existing);
        }
        catch (Exception)
        {
            // best effort
        }
    }
}
