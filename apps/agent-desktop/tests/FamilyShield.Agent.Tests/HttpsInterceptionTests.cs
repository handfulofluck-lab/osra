using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using FamilyShield.Agent.Services;
using Titanium.Web.Proxy;
using Xunit;

namespace FamilyShield.Agent.Tests;

/// <summary>
/// Tests for <see cref="HttpsInterception"/> (Feature #3). Pure env-gate/behavior checks run
/// always; the root-CA generation + CurrentUser\Root installation test is integration-only and
/// runs only when FS_HTTPS_INTEGRATION=1 (it touches the user's certificate store).
/// </summary>
[Collection("Environment variables")]
public sealed class HttpsInterceptionTests
{
    [Fact]
    public void DefaultPfxPathLivesUnderLocalAppDataOsra()
    {
        var expectedDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OSRA");
        Assert.Equal(Path.Combine(expectedDir, "rootCert.pfx"), HttpsInterception.PfxPath);
    }

    [Fact]
    public void RootCertSubjectIsOsraTestRoot()
    {
        // User-visible subject shown in certmgr.msc; the mutant is any other subject string.
        Assert.Equal("OSRA Test Root", HttpsInterception.RootCertSubject);
    }

    [Fact]
    public void DisabledUnlessEnvVarIsExactlyOne()
    {
        var original = Environment.GetEnvironmentVariable(HttpsInterception.EnvVar);
        try
        {
            Environment.SetEnvironmentVariable(HttpsInterception.EnvVar, null);
            Assert.False(HttpsInterception.IsEnabled);
            Environment.SetEnvironmentVariable(HttpsInterception.EnvVar, "true");
            Assert.False(HttpsInterception.IsEnabled);
            Environment.SetEnvironmentVariable(HttpsInterception.EnvVar, "1");
            Assert.True(HttpsInterception.IsEnabled);
        }
        finally
        {
            Environment.SetEnvironmentVariable(HttpsInterception.EnvVar, original);
        }
    }

    [Fact]
    public void ProxyDecryptionIsNotConfiguredWhenDisabled()
    {
        var original = Environment.GetEnvironmentVariable(HttpsInterception.EnvVar);
        try
        {
            Environment.SetEnvironmentVariable(HttpsInterception.EnvVar, null);
            using var proxy = new ProxyServer();
            Assert.False(HttpsInterception.TryConfigureDecryption(proxy));
            Assert.Null(proxy.CertificateManager.RootCertificate);
        }
        finally
        {
            Environment.SetEnvironmentVariable(HttpsInterception.EnvVar, original);
        }
    }

    [Fact]
    public void InsecureUpstreamOptOutIsOffByDefault()
    {
        var original = Environment.GetEnvironmentVariable(HttpsInterception.InsecureEnvVar);
        try
        {
            Environment.SetEnvironmentVariable(HttpsInterception.InsecureEnvVar, null);
            Assert.False(HttpsInterception.AllowInsecureUpstream);

            Environment.SetEnvironmentVariable(HttpsInterception.InsecureEnvVar, "true");
            Assert.False(HttpsInterception.AllowInsecureUpstream);

            Environment.SetEnvironmentVariable(HttpsInterception.InsecureEnvVar, "1");
            Assert.True(HttpsInterception.AllowInsecureUpstream);
        }
        finally
        {
            Environment.SetEnvironmentVariable(HttpsInterception.InsecureEnvVar, original);
        }
    }

    [Fact]
    public void SelfSignedUpstreamCertificateIsRejectedByDefault()
    {
        using var cert = SelfSignedCertificate();

        // A real handshake reports the untrusted chain; a chain error must reject.
        Assert.False(HttpsInterception.ValidateUpstreamCertificate(
            cert, SslPolicyErrors.RemoteCertificateChainErrors, allowInsecure: false));

        // Even with no reported error the certificate must build a chain against the Windows
        // trust store — IsValid is never simply forced true.
        Assert.False(HttpsInterception.ValidateUpstreamCertificate(
            cert, SslPolicyErrors.None, allowInsecure: false));
    }

    [Fact]
    public void InsecureOptOutAcceptsTheSameSelfSignedUpstreamCertificate()
    {
        using var cert = SelfSignedCertificate();

        Assert.True(HttpsInterception.ValidateUpstreamCertificate(
            cert, SslPolicyErrors.RemoteCertificateChainErrors, allowInsecure: true));
        Assert.True(HttpsInterception.ValidateUpstreamCertificate(
            cert, SslPolicyErrors.RemoteCertificateNameMismatch, allowInsecure: true));
    }

    [Fact]
    public void MissingUpstreamCertificateIsRejectedEvenWithoutOptOut()
    {
        Assert.False(HttpsInterception.ValidateUpstreamCertificate(
            null, SslPolicyErrors.RemoteCertificateNotAvailable, allowInsecure: false));
    }

    private const string OldRootSubject = "FamilyShield" + " Test Root";

    [Fact]
    public void ExistingPfxWithLegacySubjectIsLoadedUnchangedAfterFolderMove()
    {
        var root = Path.Combine(Path.GetTempPath(), "osra-cert-tests", Guid.NewGuid().ToString("N"));
        var legacy = Path.Combine(root, DataFolder.LegacyFolderName);
        var current = Path.Combine(root, DataFolder.FolderName);
        var legacyPfx = Path.Combine(legacy, "rootCert.pfx");
        try
        {
            CreateLegacySubjectPfx(legacyPfx);
            var beforeBytes = File.ReadAllBytes(legacyPfx);

            string beforeThumbprint;
            using (var before = new X509Certificate2(legacyPfx))
            {
                Assert.Equal(OldRootSubject, before.GetNameInfo(X509NameType.SimpleName, false));
                beforeThumbprint = before.Thumbprint;
            }

            Assert.True(DataFolder.MigrateOnce(legacy, current));
            var currentPfx = Path.Combine(current, "rootCert.pfx");
            Assert.True(File.Exists(currentPfx));
            // The move itself must preserve the file byte-for-byte.
            Assert.Equal(beforeBytes, File.ReadAllBytes(currentPfx));

            // The existing PFX must be loaded unchanged — same thumbprint, still the legacy
            // subject, private key intact — never deleted, replaced or regenerated.
            using var loaded = HttpsInterception.LoadOrGenerate(currentPfx);
            Assert.Equal(beforeThumbprint, loaded.Thumbprint);
            Assert.Equal(OldRootSubject, loaded.GetNameInfo(X509NameType.SimpleName, false));
            Assert.True(loaded.HasPrivateKey);
            // Loading must not rewrite the file either.
            Assert.Equal(beforeBytes, File.ReadAllBytes(currentPfx));
        }
        finally
        {
            try { Directory.Delete(root, recursive: true); } catch (Exception) { }
        }
    }

    [Fact]
    public void FreshlyGeneratedRootUsesOsraTestRoot()
    {
        var pfx = Path.Combine(Path.GetTempPath(), "osra-cert-tests", Guid.NewGuid().ToString("N"), "rootCert.pfx");
        try
        {
            using var cert = HttpsInterception.LoadOrGenerate(pfx);
            Assert.Equal("OSRA Test Root", cert.GetNameInfo(X509NameType.SimpleName, false));
            Assert.True(cert.HasPrivateKey);
            Assert.True(File.Exists(pfx));
        }
        finally
        {
            try { Directory.Delete(Path.GetDirectoryName(pfx)!, recursive: true); } catch (Exception) { }
        }
    }

    private static void CreateLegacySubjectPfx(string path)
    {
        using var rsa = RSA.Create(2048);
        var request = new CertificateRequest(
            $"CN={OldRootSubject}", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(true, false, 0, true));
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.KeyCertSign | X509KeyUsageFlags.CrlSign, true));
        request.CertificateExtensions.Add(new X509SubjectKeyIdentifierExtension(request.PublicKey, false));
        using var cert = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(5));
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, cert.Export(X509ContentType.Pfx));
    }

    private static X509Certificate2 SelfSignedCertificate()
    {
        using var rsa = RSA.Create(2048);
        var request = new CertificateRequest(
            "CN=selfsigned.example", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        return request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(1));
    }

    [Fact]
    public void RootCertificateRoundTripGenerationInstallAndCleanup()
    {
        // NOTE: integration-only — touches %LOCALAPPDATA% and the real CurrentUser\Root store.
        // xunit 2.8 has no dynamic Skip, so the guard is a runtime return: without
        // FS_HTTPS_INTEGRATION=1 the test body does nothing (env check + skip).
        if (Environment.GetEnvironmentVariable("FS_HTTPS_INTEGRATION") != "1") return;

        var dir = Path.Combine(Path.GetTempPath(), "familyshield-tests", Guid.NewGuid().ToString("N"));
        var pfxPath = Path.Combine(dir, "rootCert.pfx");
        X509Certificate2? cert = null;
        try
        {
            cert = HttpsInterception.EnsureRootCertificate(pfxPath);
            Assert.NotNull(cert);
            Assert.True(File.Exists(pfxPath));

            Assert.Equal(HttpsInterception.RootCertSubject, cert!.GetNameInfo(X509NameType.SimpleName, false));
            Assert.True(cert.GetRSAPublicKey()?.KeySize >= 2048);
            Assert.True(DateTime.UtcNow > cert.NotBefore && DateTime.UtcNow < cert.NotAfter);

            // Idempotent: a second run loads the very same cert (same thumbprint) instead of
            // generating a new one, and does not duplicate the store entry.
            var again = HttpsInterception.EnsureRootCertificate(pfxPath);
            Assert.Equal(cert.Thumbprint, again!.Thumbprint);
            using (var store = new X509Store(StoreName.Root, StoreLocation.CurrentUser))
            {
                store.Open(OpenFlags.ReadOnly);
                var found = store.Certificates.Find(X509FindType.FindByThumbprint, cert.Thumbprint, false);
                Assert.Single(found);
            }
        }
        finally
        {
            if (cert is not null) HttpsInterception.RemoveFromUserRootStore(cert);
            try
            {
                Directory.Delete(dir, recursive: true);
            }
            catch (Exception)
            {
                // temp cleanup is best-effort
            }
        }
    }
}
