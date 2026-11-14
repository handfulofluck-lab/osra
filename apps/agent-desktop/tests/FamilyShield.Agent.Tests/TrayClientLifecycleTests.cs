using System.Text.Json;
using System.Threading.Channels;
using FamilyShield.Agent.Services;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace FamilyShield.Agent.Tests;

public sealed class TrayClientLifecycleTests
{
    [Fact]
    public async Task PostConnectMessagesAreSentAndQuietConnectionsStayAlive()
    {
        var stream = new DuplexStream();
        var state = new TrayConnectionState();
        var store = NewStore(out var directory);
        try
        {
            using var worker = new TrayPipeClientWorker(new FakeClient(stream), NewActions(store),
                NullLogger<TrayPipeClientWorker>.Instance, state);
            await worker.StartAsync(CancellationToken.None);
            await Task.Delay(TimeSpan.FromSeconds(16));
            await worker.SendAsync(new TrayMessage(TrayMessageKind.sos));

            var message = await ReadFrame(stream, index: 1);
            Assert.Equal(TrayMessageKind.sos, message.Kind);
            Assert.True(state.IsConnected);
        }
        finally
        {
            store.Dispose();
            try { Directory.Delete(directory, recursive: true); } catch (Exception) { }
        }
    }

    [Fact]
    public async Task SosIsNeverDroppedBehindOrdinaryMessages()
    {
        var stream = new DuplexStream();
        var store = NewStore(out var directory);
        try
        {
            using var worker = new TrayPipeClientWorker(new FakeClient(stream), NewActions(store),
                NullLogger<TrayPipeClientWorker>.Instance);
            await worker.StartAsync(CancellationToken.None);
            for (var index = 0; index < 40; index++)
            {
                await worker.SendAsync(new TrayMessage(TrayMessageKind.foreground_sample,
                    JsonSerializer.SerializeToElement(new { processName = $"app-{index}" })));
            }
            await worker.SendAsync(new TrayMessage(TrayMessageKind.sos));

            var message = await ReadFrame(stream, index: 1);
            Assert.Equal(TrayMessageKind.sos, message.Kind);
        }
        finally
        {
            store.Dispose();
            try { Directory.Delete(directory, recursive: true); } catch (Exception) { }
        }
    }

    [Fact]
    public async Task ReconnectStartsWithHelloBeforeQueuedMessages()
    {
        var first = new DuplexStream { CloseAfterFirstFrame = true };
        var second = new DuplexStream();
        var client = new FakeClient(first, second);
        var store = NewStore(out var directory);
        try
        {
            using var worker = new TrayPipeClientWorker(client, NewActions(store),
                NullLogger<TrayPipeClientWorker>.Instance);
            await worker.StartAsync(CancellationToken.None);
            Assert.Equal(TrayMessageKind.hello, (await ReadFrame(first)).Kind);
            await worker.SendAsync(new TrayMessage(TrayMessageKind.sos));

            var message = await ReadFrame(second);
            Assert.Equal(TrayMessageKind.hello, message.Kind);
            Assert.Equal(2, client.Connections);
        }
        finally
        {
            store.Dispose();
            try { Directory.Delete(directory, recursive: true); } catch (Exception) { }
        }
    }

    private static TrayUserActions NewActions(LocalRuleStore store) =>
        new(new AgentConfig(), store, NullLogger<TrayUserActions>.Instance);

    private static async Task<TrayMessage> ReadFrame(DuplexStream stream, int index = 0)
    {
        for (var attempt = 0; attempt < 400; attempt++)
        {
            var bytes = stream.Snapshot();
            using var reading = new MemoryStream(bytes);
            var frames = new List<TrayMessage>();
            while (reading.Position < reading.Length)
            {
                if (reading.Length - reading.Position < 4) break;
                var length = BitConverter.ToInt32(bytes, (int)reading.Position);
                if (reading.Length - reading.Position < 4 + length) break;
                frames.Add(await TrayProtocol.ReadAsync(reading, TrayDirection.ToService,
                    TimeSpan.FromSeconds(1), CancellationToken.None));
            }
            if (frames.Count > index) return frames[index];
            await Task.Delay(10);
        }
        throw new TimeoutException($"The client did not write frame {index}.");
    }

    private static LocalRuleStore NewStore(out string directory)
    {
        directory = Path.Combine(Path.GetTempPath(), "osra-client-lifecycle", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        return new LocalRuleStore(NullLogger<LocalRuleStore>.Instance,
            Path.Combine(directory, "rules.db"), Path.Combine(directory, "status.json"));
    }

    private sealed class FakeClient(params DuplexStream[] streams) : ITrayClient
    {
        private int _index;
        public int Connections { get; private set; }
        public Task<TrayPipeConnection> ConnectAsync(int sessionId, CancellationToken cancellationToken = default)
        {
            var stream = streams[Math.Min(_index++, streams.Length - 1)];
            Connections++;
            return Task.FromResult(new TrayPipeConnection(stream, sessionId, "user"));
        }
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private sealed class DuplexStream : Stream
    {
        private readonly Channel<byte> _incoming = Channel.CreateUnbounded<byte>();
        private readonly MemoryStream _outgoing = new();
        private readonly object _gate = new();
        private bool _closed;
        public bool CloseAfterFirstFrame { get; init; }
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => true;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) =>
            WriteAsync(buffer.AsMemory(offset, count), CancellationToken.None).AsTask().GetAwaiter().GetResult();
        public override async Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken)
        {
            try
            {
                buffer[offset] = await _incoming.Reader.ReadAsync(cancellationToken);
                return 1;
            }
            catch (ChannelClosedException)
            {
                return 0;
            }
        }
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            var one = new byte[1];
            var read = await ReadAsync(one, 0, 1, cancellationToken);
            if (read == 1) buffer.Span[0] = one[0];
            return read;
        }
        public override Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
            WriteAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();
        public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken = default)
        {
            lock (_gate)
            {
                _outgoing.Write(buffer.Span);
                if (CloseAfterFirstFrame && !_closed && _outgoing.Length >= 4)
                {
                    var length = BitConverter.ToInt32(_outgoing.GetBuffer(), 0);
                    if (_outgoing.Length >= 4 + length)
                    {
                        _closed = true;
                        _incoming.Writer.TryComplete();
                    }
                }
            }
            return ValueTask.CompletedTask;
        }
        public byte[] Snapshot()
        {
            lock (_gate) return _outgoing.ToArray();
        }
    }
}
