using System.Text;
using FamilyShield.Agent.Services;
using Xunit;

namespace FamilyShield.Agent.Tests;

/// <summary>v2 internal signing (ADR-0014) — pinned to the same reference vector as the API and Android tests.</summary>
public sealed class InternalSignerTests
{
    [Fact]
    public void SigningBytes_IsTimestampDotNonceDotBody()
    {
        var bytes = InternalSigner.SigningBytes("1800000000", "0123456789abcdef0123456789abcdef", Encoding.UTF8.GetBytes("{\"a\":1}"));
        Assert.Equal("1800000000.0123456789abcdef0123456789abcdef.{\"a\":1}", Encoding.UTF8.GetString(bytes));
    }

    [Fact]
    public void Signature_MatchesServerReferenceVector()
    {
        // services/api/test/internal-signing.test.ts and the Android SignatureInterceptorTest assert this exact value.
        var body = Encoding.UTF8.GetBytes("{\"childId\":\"child-1\",\"deviceId\":\"dev-1\",\"title\":\"x\"}");
        var (signature, timestamp, nonce) = InternalSigner.Sign("device-secret-1", body, 1800000000, "nonce-0123456789abcdef");
        Assert.Equal("ce725cf93f36fb43a586bcae590b3faab54afa4976347b859c9ca9259c220508", signature);
        Assert.Equal("1800000000", timestamp);
        Assert.Equal("nonce-0123456789abcdef", nonce);
    }

    [Fact]
    public void Nonce_Is32LowercaseHexAndUnique()
    {
        var a = InternalSigner.NewNonce();
        var b = InternalSigner.NewNonce();
        Assert.Equal(32, a.Length);
        Assert.Matches("^[0-9a-f]+$", a);
        Assert.NotEqual(a, b);
    }
}
