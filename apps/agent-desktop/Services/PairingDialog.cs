using System.Drawing;
using System.Windows.Forms;

namespace FamilyShield.Agent.Services;

/// <summary>
/// First-run pairing dialog shown when no agent.config.json exists. Mirrors the overlay-thread
/// pattern used by <see cref="ScreenTimeEnforcer"/>: a dedicated STA thread runs a WinForms loop.
/// </summary>
internal static class PairingDialog
{
    /// <summary>
    /// Shows the dialog and blocks until it closes. Returns the paired config on success,
    /// or null when the user cancels or dismisses the dialog without pairing.
    /// </summary>
    public static AgentConfig? Show()
    {
        AgentConfig? result = null;
        var thread = new Thread(() =>
        {
            var form = new PairingForm();
            form.PairCompleted += config => result = config;
            Application.Run(form);
        })
        {
            IsBackground = false,
            Name = "FamilyShieldPairing",
        };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        return result;
    }

    private sealed class PairingForm : Form
    {
        private readonly TextBox _serverBox;
        private readonly TextBox _codeBox;
        private readonly TextBox _pinBox;
        private readonly TextBox _pinConfirmBox;
        private readonly Label _status;
        private readonly Button _pairButton;

        /// <summary>Raised on the UI thread with the claimed config, before the form closes.</summary>
        public event Action<AgentConfig>? PairCompleted;

        public PairingForm()
        {
            Text = "OSRA — Pair this device";
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(400, 225);

            var serverLabel = new Label { Text = "Server URL:", Location = new Point(12, 15), AutoSize = true };
            // Intentionally blank: the server URL must always come from the parent running
            // the test — never pre-filled with a built-in guess (localhost included).
            _serverBox = new TextBox { Text = "", Location = new Point(100, 12), Width = 285 };
            var codeLabel = new Label { Text = "Pairing code:", Location = new Point(12, 45), AutoSize = true };
            _codeBox = new TextBox { Location = new Point(100, 42), Width = 120 };
            // Desktop audit finding 1: there is no default PIN. The parent chooses the per-install
            // PIN here; until one exists, lock/bedtime/screen-time refuse to arm.
            var pinLabel = new Label { Text = "Parent PIN:", Location = new Point(12, 75), AutoSize = true };
            _pinBox = new TextBox { Location = new Point(100, 72), Width = 120, PasswordChar = '*' };
            var pinConfirmLabel = new Label { Text = "Repeat PIN:", Location = new Point(12, 105), AutoSize = true };
            _pinConfirmBox = new TextBox { Location = new Point(100, 102), Width = 120, PasswordChar = '*' };
            _status = new Label { Location = new Point(12, 135), Width = 375, ForeColor = Color.Firebrick, Text = "" };
            _pairButton = new Button { Text = "Pair", Location = new Point(218, 165), Width = 80 };
            var cancelButton = new Button { Text = "Cancel", Location = new Point(305, 165), Width = 80 };

            _pairButton.Click += OnPair;
            cancelButton.Click += (_, __) => Close();
            AcceptButton = _pairButton;
            CancelButton = cancelButton;

            Controls.Add(serverLabel);
            Controls.Add(_serverBox);
            Controls.Add(codeLabel);
            Controls.Add(_codeBox);
            Controls.Add(pinLabel);
            Controls.Add(_pinBox);
            Controls.Add(pinConfirmLabel);
            Controls.Add(_pinConfirmBox);
            Controls.Add(_status);
            Controls.Add(_pairButton);
            Controls.Add(cancelButton);
        }

        private async void OnPair(object? sender, EventArgs e)
        {
            var apiBase = _serverBox.Text.Trim();
            var code = _codeBox.Text.Trim();
            var pin = ParentPinPolicy.Normalize(_pinBox.Text);
            if (apiBase.Length == 0 || code.Length == 0)
            {
                _status.Text = "Enter the server URL and the 6-digit pairing code.";
                return;
            }

            if (pin is null)
            {
                _status.Text = $"Choose a {ParentPinPolicy.MinLength}–{ParentPinPolicy.MaxLength} digit parent PIN (0000 is not allowed).";
                return;
            }

            if (!string.Equals(pin, _pinConfirmBox.Text.Trim(), StringComparison.Ordinal))
            {
                _status.Text = "The two PIN entries do not match.";
                return;
            }

            _pairButton.Enabled = false;
            _status.ForeColor = Color.DarkSlateGray;
            _status.Text = "Pairing…";
            try
            {
                var config = await PairingService.ClaimAsync(apiBase, code, platform: "windows", parentPin: pin);
                if (config is null)
                {
                    _status.ForeColor = Color.Firebrick;
                    _status.Text = "Pairing rejected — check the code and server URL.";
                    return;
                }

                PairingService.Save(config);
                PairCompleted?.Invoke(config);
                Close();
            }
            catch (Exception ex)
            {
                // NOTE: network errors (server unreachable, bad URL scheme) land here with a message.
                _status.ForeColor = Color.Firebrick;
                _status.Text = $"Pairing failed: {ex.Message}";
            }
            finally
            {
                _pairButton.Enabled = true;
            }
        }
    }
}
