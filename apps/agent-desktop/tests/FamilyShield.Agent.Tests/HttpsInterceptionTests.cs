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
    public void DefaultPfxPathLivesUnderLocalAppDataFamilyShield()
    {
        var expectedDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "FamilyShield");
        Assert.Equal(Path.Combine(expectedDir, "rootCert.pfx"), HttpsInterception.PfxPath);
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
