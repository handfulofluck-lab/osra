using System.Drawing;
using System.Windows.Forms;

namespace FamilyShield.Agent.Services;

/// <summary>
/// Process-wide topmost full-screen PIN overlay used for parent-initiated locks, bedtime, and the
/// screen-time limit. Covers all monitors (WIN-01), suppresses Alt+F4 / SC_CLOSE, and unlocks
/// only when the parent PIN is verified or the parent sends an unlock command.
/// </summary>
internal static class LockOverlay
{
    private static readonly OverlayController Instance = new();

    /// <summary>
    /// Shows the overlay across all screens (re-asserts when already visible) only when a valid
    /// parent PIN is configured. Returns false and shows nothing otherwise: a lock with no PIN
    /// (or the legacy <c>0000</c>) would be dismissable by anyone, so it must not arm.
    /// </summary>
    public static bool ShowIfPinned(string pin, string title, string message)
    {
        if (ParentPinPolicy.Normalize(pin) is null) return false;
        Instance.Show(pin, title, message);
        return true;
    }

    /// <summary>Hides the overlay when visible.</summary>
    public static void Hide() => Instance.Hide();

    private sealed class OverlayController : IDisposable
    {
        private readonly ManualResetEventSlim _ready = new();
        private readonly object _startGate = new();
        private readonly List<OverlayForm> _forms = new();
        private SynchronizationContext? _context;
        private Thread? _thread;

        public void EnsureStarted()
        {
            // NOTE: Show can race from several worker threads; only one STA message loop may start.
            lock (_startGate)
            {
                if (_thread is not null) return;
                _thread = new Thread(RunMessageLoop)
                {
                    IsBackground = true,
                    Name = "FamilyShieldOverlay",
                };
                _thread.SetApartmentState(ApartmentState.STA);
                _thread.Start();
                _ready.Wait();
            }
        }

        public void Show(string pin, string title, string message)
        {
            EnsureStarted();
            if (_context is null) return;
            _context.Send(_ =>
            {
                lock (_forms)
                {
                    // Re-assert if already open
                    if (_forms.Count > 0 && _forms.All(f => !f.IsDisposed))
                    {
                        foreach (var f in _forms)
                        {
                            f.TopMost = true;
                            f.BringToFront();
                        }
                        return;
                    }

                    CloseAllInternal();

                    var screens = Screen.AllScreens;
                    if (screens.Length == 0) return;

                    foreach (var screen in screens)
                    {
                        var isPrimary = screen.Primary;
                        var form = new OverlayForm(this, pin, title, message, screen, showPinInput: isPrimary || screens.Length == 1);
                        _forms.Add(form);
                        form.Show();
                    }
                }
            }, null);
        }

        public void CloseAll()
        {
            if (_context is null) return;
            _context.Send(_ =>
            {
                lock (_forms)
                {
                    CloseAllInternal();
                }
            }, null);
        }

        private void CloseAllInternal()
        {
            foreach (var f in _forms)
            {
                try
                {
                    f.AllowCloseAndClose();
                }
                catch (Exception)
                {
                    // already closed
                }
            }
            _forms.Clear();
        }

        public void Hide() => CloseAll();

        public void Dispose()
        {
            try
            {
                _context?.Post(_ => Application.ExitThread(), null);
            }
            catch (Exception)
            {
                // message loop already gone; the thread is background and dies with the process
            }
        }

        private void RunMessageLoop()
        {
            _context = new WindowsFormsSynchronizationContext();
            _ready.Set();
            Application.Run(new ApplicationContext());
        }
    }

    private sealed class OverlayForm : Form
    {
        private const int WM_SYSCOMMAND = 0x0112;
        private const int SC_CLOSE = 0xF060;

        private readonly OverlayController _controller;
        private bool _allowClose;

        public OverlayForm(OverlayController controller, string pin, string title, string message, Screen screen, bool showPinInput)
        {
            _controller = controller;
            Text = title;
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            Bounds = screen.Bounds;
            TopMost = true;
            ShowInTaskbar = false;
            BackColor = Color.FromArgb(0x1F, 0x2A, 0x44);

            var messageLabel = new Label
            {
                Dock = DockStyle.Fill,
                TextAlign = ContentAlignment.MiddleCenter,
                ForeColor = Color.White,
                Font = new Font(FontFamily.GenericSansSerif, 20f, FontStyle.Bold),
                Text = message,
            };
            Controls.Add(messageLabel);

            if (showPinInput)
            {
                var pinBox = new TextBox { PasswordChar = '*', Width = 180 };
                var unlockButton = new Button { Text = "Unlock" };
                unlockButton.Click += (_, __) =>
                {
                    if (ParentPinPolicy.Matches(pin, pinBox.Text))
                    {
                        _controller.CloseAll();
                    }
                    else
                    {
                        pinBox.Clear();
                        System.Media.SystemSounds.Beep.Play();
                    }
                };
                pinBox.KeyDown += (_, e) =>
                {
                    if (e.KeyCode == Keys.Enter) unlockButton.PerformClick();
                };

                var inputPanel = new FlowLayoutPanel
                {
                    Dock = DockStyle.Bottom,
                    Height = 60,
                    FlowDirection = FlowDirection.LeftToRight,
                    Padding = new Padding(0, 10, 0, 10),
                };
                inputPanel.Controls.Add(pinBox);
                inputPanel.Controls.Add(unlockButton);
                Controls.Add(inputPanel);
            }
        }

        public void AllowCloseAndClose()
        {
            _allowClose = true;
            Close();
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            // Intercept Alt+F4 and close requests by child (WIN-01)
            if (!_allowClose && e.CloseReason == CloseReason.UserClosing)
            {
                e.Cancel = true;
                return;
            }
            base.OnFormClosing(e);
        }

        protected override void WndProc(ref Message m)
        {
            // Suppress Alt+F4 / SC_CLOSE command
            if (m.Msg == WM_SYSCOMMAND && (m.WParam.ToInt32() & 0xFFF0) == SC_CLOSE && !_allowClose)
            {
                return;
            }
            base.WndProc(ref m);
        }
    }
}
