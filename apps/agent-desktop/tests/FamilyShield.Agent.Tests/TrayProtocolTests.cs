using System.Text.Json;
using FamilyShield.Agent.Services;
using Xunit;

namespace FamilyShield.Agent.Tests;

public sealed class TrayProtocolTests
{
    [Fact]
    public void FrameAndTimeoutBoundsAreExplicit()
    {
        Assert.Equal(65_536, TrayProtocol.MaxFrameBytes);
        Assert.Equal(TimeSpan.FromSeconds(15), TrayProtocol.ReadTimeout);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(-1)]
    public void PipeNamesRejectInvalidSessions(int sessionId)
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => TrayPipeName.ForSession(sessionId));
    }

    [Fact]
    public void PipeNameContainsOnlyTheValidatedSession()
    {
        Assert.Equal("osra-tray-7", TrayPipeName.ForSession(7));
    }

    [Fact]
    public async Task OneByteOverTheBoundIsRejectedBeforeBodyAllocation()
    {
        await using var stream = new MemoryStream(BitConverter.GetBytes(TrayProtocol.MaxFrameBytes + 1));
        await Assert.ThrowsAsync<InvalidDataException>(() => TrayProtocol.ReadAsync(stream, TrayDirection.ToService));
    }

    [Fact]
    public async Task TruncatedFramesAreRejected()
    {
        await using var stream = new MemoryStream([20, 0, 0, 0, 1, 2, 3]);
        await Assert.ThrowsAsync<EndOfStreamException>(() => TrayProtocol.ReadAsync(stream, TrayDirection.ToService));
    }

    [Fact]
    public async Task MalformedJsonIsRejected()
    {
        await using var stream = Frame("{not-json");
        await Assert.ThrowsAsync<JsonException>(() => TrayProtocol.ReadAsync(stream, TrayDirection.ToService));
    }

    [Fact]
    public async Task UnknownFieldsAndKindsAreRejected()
    {
        await using var unknownField = Frame("{\"kind\":\"lock\",\"unexpected\":true}");
        await Assert.ThrowsAsync<JsonException>(() => TrayProtocol.ReadAsync(unknownField, TrayDirection.ToTray));
        await using var unknownKind = Frame("{\"kind\":\"reset_everything\"}");
        await Assert.ThrowsAsync<JsonException>(() => TrayProtocol.ReadAsync(unknownKind, TrayDirection.ToTray));
    }

    [Fact]
    public async Task ParentCommandsCannotBeInjectedByATray()
    {
        await using var stream = Frame("{\"kind\":\"unlock\"}");
        await Assert.ThrowsAsync<UnauthorizedAccessException>(() => TrayProtocol.ReadAsync(stream, TrayDirection.ToService));
    }

    [Fact]
    public async Task CredentialFieldsNeverEnterTheProtocol()
    {
        await using var stream = new MemoryStream();
        var message = new TrayMessage(TrayMessageKind.sos, Payload("{\"parentPin\":\"unused\"}"));
        await Assert.ThrowsAsync<InvalidDataException>(() => TrayProtocol.WriteAsync(stream, message, TrayDirection.ToService));
        Assert.Equal(0, stream.Length);
    }

    [Fact]
    public async Task PayloadShapesAreValidated()
    {
        await using var noPayload = new MemoryStream();
        await Assert.ThrowsAsync<InvalidDataException>(() => TrayProtocol.WriteAsync(
            noPayload, new TrayMessage(TrayMessageKind.hello, Payload("{}")), TrayDirection.ToService));
        await using var badMinutes = new MemoryStream();
        await Assert.ThrowsAsync<InvalidDataException>(() => TrayProtocol.WriteAsync(
            badMinutes, new TrayMessage(TrayMessageKind.wind_down, Payload("{\"minutes\":0}")), TrayDirection.ToTray));
        await using var badProcess = new MemoryStream();
        await Assert.ThrowsAsync<InvalidDataException>(() => TrayProtocol.WriteAsync(
            badProcess, new TrayMessage(TrayMessageKind.foreground_sample, Payload("{\"processName\":\"\"}")), TrayDirection.ToService));
    }

    [Fact]
    public async Task CurrentServerRuleFieldsSurviveWithoutWeakeningTheFrame()
    {
        const string rules = "{\"screenTime\":{\"dailyLimitMinutes\":45,\"schoolHoursStart\":\"08:00\",\"schoolHoursEnd\":\"15:00\",\"schoolDays\":[1,2,3,4,5]},\"appGroupRules\":[],\"socialMonitoring\":{},\"contactAllowlist\":[]}";
        await using var stream = new MemoryStream();
        await TrayProtocol.WriteAsync(stream, new TrayMessage(TrayMessageKind.rules, Payload(rules)), TrayDirection.ToTray);
        stream.Position = 0;
        var message = await TrayProtocol.ReadAsync(stream, TrayDirection.ToTray);
        var screenTime = message.Payload!.Value.GetProperty("screenTime");
        Assert.Equal(45, screenTime.GetProperty("dailyLimitMinutes").GetInt32());
        Assert.Equal("08:00", screenTime.GetProperty("schoolHoursStart").GetString());
        Assert.Equal("15:00", screenTime.GetProperty("schoolHoursEnd").GetString());
        Assert.Equal(5, screenTime.GetProperty("schoolDays").GetArrayLength());
    }

    [Fact]
    public async Task ValidWindDownRoundTripsExactly()
    {
        await using var stream = new MemoryStream();
        await TrayProtocol.WriteAsync(stream,
            new TrayMessage(TrayMessageKind.wind_down, Payload("{\"minutes\":15}")), TrayDirection.ToTray);
        stream.Position = 0;
        var message = await TrayProtocol.ReadAsync(stream, TrayDirection.ToTray);
        Assert.Equal(TrayMessageKind.wind_down, message.Kind);
        Assert.Equal(15, message.Payload!.Value.GetProperty("minutes").GetInt32());
    }

    [Fact]
    public async Task ReadTimeoutIsEnforced()
    {
        await using var stream = new HangingReadStream();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => TrayProtocol.ReadAsync(
            stream, TrayDirection.ToService, TimeSpan.FromMilliseconds(20)));
    }

    private static JsonElement Payload(string json) => JsonDocument.Parse(json).RootElement.Clone();

    private static MemoryStream Frame(string json)
    {
        var body = System.Text.Encoding.UTF8.GetBytes(json);
        var stream = new MemoryStream();
        stream.Write(BitConverter.GetBytes(body.Length));
        stream.Write(body);
        stream.Position = 0;
        return stream;
    }

    private sealed class HangingReadStream : Stream
    {
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => 0;
        public override long Position { get; set; }
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override async Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken)
        {
            await Task.Delay(Timeout.Infinite, cancellationToken);
            return 0;
        }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
