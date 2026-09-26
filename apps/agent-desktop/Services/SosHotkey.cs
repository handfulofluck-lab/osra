using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace FamilyShield.Agent.Services;

/// <summary>
/// Feature #14 SOS hotkey: Shift+F11 posts a critical 'sos' alert to the parent and shows a
/// short topmost confirmation. The hotkey lives on a message-only window (HWND_MESSAGE) whose
/// thread runs a classic GetMessage loop. NOTE: RegisterHotKey is Windows-integration, so the
/// service is only registered when FS_SOS_HOTKEY=1 — the same env-gate pattern as
/// FS_HTTPS_INSPECT (Feature #3).
/// </summary>
public sealed class SosHotkey : BackgroundService
{
    /// <summary>Env gate: only "1" enables the SOS hotkey (Windows-integration).</summary>
    public const string EnvVar = "FS_SOS_HOTKEY";

    private const int HotkeyId = 0x4653; // 'FS'
    private const uint ModShift = 0x0004; // MOD_SHIFT
    private const uint VkF11 = 0x7A; // VK_F11
    private const uint WmQuit = 0x0012;
    private const uint WmHotkey = 0x0312;
    private static readonly IntPtr HwndMessage = new(-3); // HWND_MESSAGE

    private readonly ILogger<SosHotkey> _log;
    private readonly ApiClient _api;
    private readonly AgentConfig _config;

    /// <summary>Creates the worker.</summary>
    public SosHotkey(ILogger<SosHotkey> log, ApiClient api, AgentConfig config)
    {
        _log = log;
        _api = api;
        _config = config;
    }

    /// <summary>True when FS_SOS_HOTKEY=1.</summary>
    public static bool IsEnabled =>
        string.Equals(Environment.GetEnvironmentVariable(EnvVar), "1", StringComparison.Ordinal);

    /// <summary>Builds the SOS alert payload; the pure seam the unit tests assert against.</summary>
    internal static AlertDto BuildAlert(AgentConfig config) => new()
    {
        DeviceId = config.DeviceId,
        ChildId = config.ChildId,
        Severity = "critical",
        Category = "sos",
        Title = $"SOS from {Environment.MachineName}",
        Body = "The SOS hotkey (Shift+F11) was pressed",
        Metadata = new Dictionary<string, object>
        {
            ["deviceId"] = config.DeviceId ?? "",
        },
    };

    /// <summary>Runs the hotkey loop until stopped; every failure is swallowed, never thrown.</summary>
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var loop = new HotkeyLoop(_log, OnHotkeyPressed);
        try
        {
            loop.Start();
            await Task.Delay(Timeout.InfiniteTimeSpan, stoppingToken);
        }
        catch (OperationCanceledException)
        {
            // normal shutdown
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "SOS hotkey worker failed");
        }
        finally
        {
            loop.Stop();
        }
    }

    private void OnHotkeyPressed()
    {
        try
        {
            _ = SendSosAsync();
            SosToast.Show();
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "SOS hotkey handling failed");
        }
    }

    private async Task SendSosAsync()
    {
        try
        {
            var ok = await _api.PostAlert(BuildAlert(_config));
            _log.LogInformation("SOS alert posted to parent (accepted: {Accepted})", ok);
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Failed to post SOS alert");
        }
    }

    /// <summary>Message-only window + GetMessage loop on a dedicated STA thread.</summary>
    private sealed class HotkeyLoop
    {
        private readonly ILogger _log;
        private readonly Action _onHotkey;
        private readonly ManualResetEventSlim _ready = new();
        private Thread? _thread;
        private IntPtr _hwnd;

        public HotkeyLoop(ILogger log, Action onHotkey)
        {
            _log = log;
            _onHotkey = onHotkey;
        }

        public void Start()
        {
            _thread = new Thread(Run)
            {
                IsBackground = true,
                Name = "FamilyShieldSosHotkey",
            };
            _thread.SetApartmentState(ApartmentState.STA);
            _thread.Start();
            _ready.Wait(); // released even when registration fails, so Start never hangs
        }

        public void Stop()
        {
            try
            {
                // WM_QUIT makes GetMessage return 0; the loop's finally unregisters the hotkey.
                if (_hwnd != IntPtr.Zero) PostMessage(_hwnd, WmQuit, IntPtr.Zero, IntPtr.Zero);
                _thread?.Join(millisecondsTimeout: 2000);
            }
            catch (Exception)
            {
                // the thread is background and dies with the process
            }
        }

        private void Run()
        {
            IntPtr hwnd = IntPtr.Zero;
            try
            {
                hwnd = CreateWindowEx(0, "Message", "FamilyShieldSOS", 0, 0, 0, 0, 0,
                    HwndMessage, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                _hwnd = hwnd;
                if (hwnd == IntPtr.Zero || !RegisterHotKey(hwnd, HotkeyId, ModShift, VkF11))
                {
                    _log.LogWarning("SOS hotkey registration failed (win32 {Error}); SOS hotkey disabled",
                        Marshal.GetLastWin32Error());
                    return;
                }
                _log.LogInformation("SOS hotkey registered: Shift+F11");
                _ready.Set();
                while (GetMessage(out var msg, IntPtr.Zero, 0, 0))
                {
                    if (msg.Message == WmHotkey)
                    {
                        try
                        {
                            _onHotkey();
                        }
                        catch (Exception ex)
                        {
                            _log.LogError(ex, "SOS hotkey callback failed");
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                _log.LogError(ex, "SOS hotkey message loop crashed");
            }
            finally
            {
                try
                {
                    if (hwnd != IntPtr.Zero)
                    {
                        UnregisterHotKey(hwnd, HotkeyId);
                        DestroyWindow(hwnd);
                    }
                }
                catch (Exception)
                {
                    // best-effort cleanup
                }
                _ready.Set();
            }
        }

        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr CreateWindowEx(int dwExStyle, string lpClassName, string lpWindowName,
            int dwStyle, int x, int y, int nWidth, int nHeight, IntPtr hWndParent, IntPtr hMenu,
            IntPtr hInstance, IntPtr lpParam);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DestroyWindow(IntPtr hWnd);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetMessage(out NativeMessage lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);

        [StructLayout(LayoutKind.Sequential)]
        private struct NativeMessage
        {
            public IntPtr Hwnd;
            public uint Message;
            public IntPtr WParam;
            public IntPtr LParam;
            public uint Time;
            public int PtX;
            public int PtY;
        }
    }

    /// <summary>
    /// Topmost confirmation shown after an SOS; auto-dismisses after 10 s so the child is never
    /// left with a stuck topmost window. NOTE: unlike LockOverlay this runs entirely on the
    /// hotkey message-loop thread (its only caller), so no SynchronizationContext marshalling.
    /// </summary>
    private static class SosToast
    {
        private static SosToastForm? _open;

        public static void Show()
        {
            try
            {
                _open?.Close();
                _open = new SosToastForm();
                _open.FormClosed += (_, __) => _open = null;
                _open.Show();
            }
            catch (Exception)
            {
                // never break the hotkey loop over a confirmation window
            }
        }
    }

    private sealed class SosToastForm : Form
    {
        public SosToastForm()
        {
            Text = "OSRA SOS";
            FormBorderStyle = FormBorderStyle.FixedDialog;
            StartPosition = FormStartPosition.CenterScreen;
            TopMost = true;
            ShowInTaskbar = false;
            MaximizeBox = false;
            MinimizeBox = false;
            Width = 380;
            Height = 150;
            BackColor = Color.FromArgb(0x1F, 0x2A, 0x44);

            var messageLabel = new Label
            {
                Dock = DockStyle.Fill,
                TextAlign = ContentAlignment.MiddleCenter,
                ForeColor = Color.White,
                Font = new Font(FontFamily.GenericSansSerif, 14f, FontStyle.Bold),
                Text = "SOS sent to your parent",
            };
            var okButton = new Button { Text = "OK", Dock = DockStyle.Bottom, Height = 34 };
            okButton.Click += (_, __) => Close();

            Controls.Add(messageLabel);
            Controls.Add(okButton);

            // WinForms Timer ticks on this thread's message loop; auto-dismiss after 10 s.
            var autoClose = new System.Windows.Forms.Timer { Interval = 10_000 };
            autoClose.Tick += (_, __) => { autoClose.Stop(); Close(); };
            FormClosed += (_, __) => autoClose.Dispose();
            autoClose.Start();
        }
    }
}
