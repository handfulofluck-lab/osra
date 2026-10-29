using System.Net;
using System.Text;
using FamilyShield.Agent.Services;
using Xunit;

namespace FamilyShield.Agent.Tests;

/// <summary>
/// Plan 2.7: the parent approves each new device. The claim answers 202 and the token arrives on the
/// poll after Allow; these pin what <see cref="PairingService.ClaimAsync"/> does with every answer.
/// The server side is <c>services/api/test/pairing.test.ts</c>.
/// </summary>
public sealed class PairingServiceTests
{
    private const string Api = "http://api.test";
    private const string Pin = "4821";
    private const string Ticket = """{"claimId":"c-1","pollSecret":"s-1","expiresAt":"2026-10-27T21:00:00Z"}""";
    private const string Paired = """{"device":{"id":"dev-9"},"token":"jwt-9","childId":"child-1","familyId":"fam-1","hmacSecret":"ab12"}""";

    /// <summary>Answers each request with the next (status, body) and records the paths it was asked for.</summary>
    private sealed class ScriptedHandler(params (int Status, string Body)[] answers) : HttpMessageHandler
    {
        private readonly Queue<(int Status, string Body)> _answers = new(answers);
        public List<string> Paths { get; } = new();
        public List<string> Bodies { get; } = new();

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Paths.Add(request.RequestUri!.AbsolutePath);
            Bodies.Add(request.Content is null ? "" : await request.Content.ReadAsStringAsync(ct));
            var (status, body) = _answers.Count > 0 ? _answers.Dequeue() : (202, """{"status":"pending"}""");
            return new HttpResponseMessage((HttpStatusCode)status) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
        }
    }

    private static readonly Func<TimeSpan, CancellationToken, Task> NoDelay = (_, _) => Task.CompletedTask;

    [Fact]
    public async Task Waits_for_the_parent_then_maps_the_polled_token_to_a_config()
    {
        var handler = new ScriptedHandler((202, Ticket), (202, """{"status":"pending"}"""), (201, Paired));
        var waited = false;
        var config = await PairingService.ClaimAsync(Api, "123456", parentPin: Pin, onWaiting: () => waited = true, handler: handler, delay: NoDelay);

        Assert.True(waited);
        Assert.NotNull(config);
        Assert.Equal("jwt-9", config!.DeviceJwt);
        Assert.Equal("dev-9", config.DeviceId);
        Assert.Equal("child-1", config.ChildId);
        Assert.Equal("ab12", config.HmacSecret);
        Assert.Equal(new[] { "/v1/devices/pair/claim", "/v1/devices/pair/claims/c-1/poll", "/v1/devices/pair/claims/c-1/poll" }, handler.Paths);
        Assert.Contains("\"pollSecret\":\"s-1\"", handler.Bodies[1]);
    }

    [Fact]
    public async Task A_Deny_ends_the_wait_with_a_message()
    {
        var handler = new ScriptedHandler((202, Ticket), (410, """{"error":"claim_denied"}"""));
        var ex = await Assert.ThrowsAsync<PairingRefusedException>(() =>
            PairingService.ClaimAsync(Api, "123456", parentPin: Pin, handler: handler, delay: NoDelay));
        Assert.Contains("declined", ex.Message);
        Assert.Equal(2, handler.Paths.Count);
    }

    [Fact]
    public async Task An_expired_claim_and_a_code_already_in_use_say_what_to_do()
    {
        var expired = await Assert.ThrowsAsync<PairingRefusedException>(() =>
            PairingService.ClaimAsync(Api, "123456", parentPin: Pin, handler: new ScriptedHandler((202, Ticket), (404, "{}")), delay: NoDelay));
        Assert.Contains("expired", expired.Message);

        var inUse = await Assert.ThrowsAsync<PairingRefusedException>(() =>
            PairingService.ClaimAsync(Api, "123456", parentPin: Pin, handler: new ScriptedHandler((409, """{"error":"claim_pending"}""")), delay: NoDelay));
        Assert.Contains("already being used", inUse.Message);
    }

    [Fact]
    public async Task An_unknown_code_is_null_and_never_polls()
    {
        var handler = new ScriptedHandler((404, """{"error":"invalid_or_expired_code"}"""));
        Assert.Null(await PairingService.ClaimAsync(Api, "123456", parentPin: Pin, handler: handler, delay: NoDelay));
        Assert.Single(handler.Paths);
    }

    [Fact]
    public async Task The_old_201_from_the_claim_itself_is_not_a_pairing()
    {
        var handler = new ScriptedHandler((201, Paired));
        Assert.Null(await PairingService.ClaimAsync(Api, "123456", parentPin: Pin, handler: handler, delay: NoDelay));
    }

    [Fact]
    public async Task Polls_every_two_seconds()
    {
        var handler = new ScriptedHandler((202, Ticket), (202, "{}"), (202, "{}"), (201, Paired));
        var delays = new List<TimeSpan>();
        await PairingService.ClaimAsync(Api, "123456", parentPin: Pin, handler: handler,
            delay: (d, _) => { delays.Add(d); return Task.CompletedTask; });
        Assert.Equal(new[] { TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2) }, delays);
    }
}
