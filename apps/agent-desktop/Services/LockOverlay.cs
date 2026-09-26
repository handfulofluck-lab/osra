using System.Drawing;
using System.Windows.Forms;

namespace FamilyShield.Agent.Services;

/// <summary>
/// Process-wide topmost full-screen PIN overlay used for parent-initiated locks and the
/// screen-time limit. Unlike LockWorkStation it is owned by the agent, so "unlock" works.
/// NOTE: simplest overlay per spec — a topmost full-screen borderless WinForms form that
/// blocks interaction until the parent PIN is entered; true low-level input blocking
/// (BlockInput) is intentionally not used.
/// </summary>
internal static class LockOverlay
{
    private static readonly OverlayController Instance = new();

    /// <summary>Shows the overlay (no-op when already visible).</summary>
    public static void Show(string pin, string title, string message) => Instance.Show(pin, title, message);

    /// <summary>Hides the overlay when visible.</summary>
    public static void Hide() => Instance.Hide();

    private sealed class OverlayController : IDisposable
    {
        private readonly ManualResetEventSlim _ready = new();
        private readonly object _startGate = new();
        private SynchronizationContext? _context;
        private OverlayForm? _form;
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
                if (_form is { IsDisposed: false }) return;
                _form = new OverlayForm(pin, title, message);
                _form.FormClosed += (_, __) => _form = null;
                _form.Show();
            }, null);
        }

        public void Hide()
        {
            if (_context is null) return;
            _context.Send(_ =>
            {
                try
                {
                    _form?.Close();
                }
                catch (Exception)
                {
                    // already closed
                }
                _form = null;
            }, null);
        }

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
        public OverlayForm(string pin, string title, string message)
        {
            Text = title;
            FormBorderStyle = FormBorderStyle.None;
            WindowState = FormWindowState.Maximized;
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

            var pinBox = new TextBox { PasswordChar = '*', Width = 180 };
            var unlockButton = new Button { Text = "Unlock" };
            unlockButton.Click += (_, __) =>
            {
                if (pinBox.Text == pin) Close();
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

            Controls.Add(messageLabel);
            Controls.Add(inputPanel);
        }
    }
}
