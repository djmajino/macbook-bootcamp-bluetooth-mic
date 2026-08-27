using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

[assembly: AssemblyTitle("Bluetooth Mic Mac Setup")]
[assembly: AssemblyDescription("Windows 10/11 Boot Camp Bluetooth HFP microphone setup for MacBookPro16,1")]
[assembly: AssemblyCompany("Bluetooth Mic Mac")]
[assembly: AssemblyProduct("Bluetooth Mic Mac Setup")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

namespace BluetoothMicMacInstaller
{
    internal static class Program
    {
        internal const string ProductName = "Bluetooth Mic Mac";
        internal static readonly string ProgramRoot = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            "BluetoothMicMacInstaller");
        internal static readonly string PayloadRoot = Path.Combine(ProgramRoot, "payload");
        internal static readonly string InstalledExecutable = Path.Combine(
            ProgramRoot, "BluetoothMicMacInstaller.exe");

        [STAThread]
        private static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            bool ownsMutex;
            using (Mutex mutex = new Mutex(
                       true,
                       @"Global\BluetoothMicMacInstaller-4C4A495F-1BA0-48BC-8319-20260827",
                       out ownsMutex))
            {
                if (!ownsMutex)
                {
                    MessageBox.Show(
                        "Bluetooth Mic Mac Setup is already running.",
                        ProductName,
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Information);
                    return;
                }

                try
                {
                    if (!IsAdministrator())
                    {
                        MessageBox.Show(
                            "This installer requires administrator privileges.",
                            ProductName,
                            MessageBoxButtons.OK,
                            MessageBoxIcon.Error);
                        return;
                    }

                    Directory.CreateDirectory(ProgramRoot);
                    ExtractEmbeddedPayload();
                    PersistInstallerExecutable();
                    bool resume = args.Length > 0 &&
                        string.Equals(args[0], "--resume", StringComparison.OrdinalIgnoreCase);
                    Application.Run(new InstallerForm(resume));
                }
                catch (Exception exception)
                {
                    MessageBox.Show(
                        "The installer could not start:\n\n" + exception.Message,
                        ProductName,
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Error);
                }
                finally
                {
                    mutex.ReleaseMutex();
                }
            }
        }

        private static bool IsAdministrator()
        {
            WindowsPrincipal principal = new WindowsPrincipal(WindowsIdentity.GetCurrent());
            return principal.IsInRole(WindowsBuiltInRole.Administrator);
        }

        private static void PersistInstallerExecutable()
        {
            string source = Assembly.GetExecutingAssembly().Location;
            if (string.Equals(
                    Path.GetFullPath(source),
                    Path.GetFullPath(InstalledExecutable),
                    StringComparison.OrdinalIgnoreCase))
            {
                return;
            }

            string temporary = InstalledExecutable + ".new";
            File.Copy(source, temporary, true);
            File.Copy(temporary, InstalledExecutable, true);
            File.Delete(temporary);
        }

        private static void ExtractEmbeddedPayload()
        {
            Assembly assembly = Assembly.GetExecutingAssembly();
            using (Stream stream = assembly.GetManifestResourceStream(
                       "BluetoothMicMac.Payload.zip"))
            {
                if (stream == null)
                {
                    throw new InvalidOperationException("The embedded payload is missing from the EXE.");
                }

                Directory.CreateDirectory(PayloadRoot);
                string rootPrefix = Path.GetFullPath(PayloadRoot)
                    .TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
                using (ZipArchive archive = new ZipArchive(stream, ZipArchiveMode.Read))
                {
                    foreach (ZipArchiveEntry entry in archive.Entries)
                    {
                        string relative = entry.FullName.Replace('/', Path.DirectorySeparatorChar);
                        string destination = Path.GetFullPath(Path.Combine(PayloadRoot, relative));
                        if (!destination.StartsWith(rootPrefix, StringComparison.OrdinalIgnoreCase))
                        {
                            throw new InvalidDataException(
                                "The payload contains an invalid path: " + entry.FullName);
                        }
                        if (string.IsNullOrEmpty(entry.Name))
                        {
                            Directory.CreateDirectory(destination);
                            continue;
                        }

                        string parent = Path.GetDirectoryName(destination);
                        if (!string.IsNullOrEmpty(parent))
                        {
                            Directory.CreateDirectory(parent);
                        }
                        using (Stream input = entry.Open())
                        using (FileStream output = new FileStream(
                                   destination,
                                   FileMode.Create,
                                   FileAccess.Write,
                                   FileShare.None))
                        {
                            input.CopyTo(output);
                        }
                    }
                }
            }
        }
    }

    internal sealed class InstallerForm : Form
    {
        private readonly bool resumeMode;
        private readonly Label headline;
        private readonly Label status;
        private readonly Label detail;
        private readonly ProgressBar progress;
        private readonly ListView checklist;
        private readonly Dictionary<int, ListViewItem> checklistItems;
        private readonly CheckBox verboseMode;
        private readonly RichTextBox log;
        private readonly CheckBox testModeConsent;
        private readonly Button uninstallButton;
        private readonly Button primaryButton;
        private readonly Button closeButton;
        private bool operationRunning;
        private bool rebootScheduled;
        private string inspectionResult;

        internal InstallerForm(bool resume)
        {
            resumeMode = resume;
            checklistItems = new Dictionary<int, ListViewItem>();
            Text = "Bluetooth Mic Mac - Setup";
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(800, 560);
            MinimumSize = new Size(760, 590);
            MaximizeBox = false;
            BackColor = Color.FromArgb(246, 248, 251);
            Font = new Font("Segoe UI", 9F);
            Icon = Icon.ExtractAssociatedIcon(Assembly.GetExecutingAssembly().Location);

            Panel header = new Panel
            {
                Dock = DockStyle.Top,
                Height = 105,
                BackColor = Color.FromArgb(28, 39, 58)
            };
            Controls.Add(header);

            headline = new Label
            {
                AutoSize = true,
                Location = new Point(28, 20),
                ForeColor = Color.White,
                Font = new Font("Segoe UI Semibold", 20F),
                Text = "Bluetooth microphone for MacBook"
            };
            header.Controls.Add(headline);

            Label subtitle = new Label
            {
                AutoSize = true,
                Location = new Point(31, 65),
                ForeColor = Color.FromArgb(205, 216, 232),
                Font = new Font("Segoe UI", 10F),
                Text = "MacBook Pro 16,1 | Windows 10/11 Boot Camp | HFP voice + audio"
            };
            header.Controls.Add(subtitle);

            status = new Label
            {
                AutoSize = false,
                Location = new Point(30, 128),
                Size = new Size(740, 30),
                Font = new Font("Segoe UI Semibold", 13F),
                ForeColor = Color.FromArgb(33, 52, 78),
                Text = resume ? "Automatically resuming setup..." : "Checking the system..."
            };
            Controls.Add(status);

            detail = new Label
            {
                AutoSize = false,
                Location = new Point(31, 164),
                Size = new Size(735, 44),
                ForeColor = Color.FromArgb(75, 86, 103),
                Text = "Verifying the model, Bluetooth devices, Test Mode, and driver versions."
            };
            Controls.Add(detail);

            progress = new ProgressBar
            {
                Location = new Point(33, 216),
                Size = new Size(733, 18),
                Style = ProgressBarStyle.Continuous,
                Minimum = 0,
                Maximum = 100
            };
            Controls.Add(progress);

            testModeConsent = new CheckBox
            {
                AutoSize = false,
                Location = new Point(33, 239),
                Size = new Size(733, 36),
                Text = "I agree to enable Windows Test Mode and to the automatic restarts required to complete setup.",
                Visible = false
            };
            testModeConsent.CheckedChanged += delegate
            {
                if (!operationRunning &&
                    (inspectionResult == "NeedsTestMode" || inspectionResult == "NeedsTestModeRepair"))
                {
                    primaryButton.Enabled = testModeConsent.Checked;
                }
            };
            Controls.Add(testModeConsent);

            Label checklistLabel = new Label
            {
                AutoSize = true,
                Location = new Point(32, 278),
                Font = new Font("Segoe UI Semibold", 9.5F),
                ForeColor = Color.FromArgb(48, 61, 79),
                Text = "System readiness checklist"
            };
            Controls.Add(checklistLabel);

            checklist = new ListView
            {
                Location = new Point(33, 299),
                Size = new Size(733, 160),
                Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right,
                View = View.Details,
                FullRowSelect = true,
                GridLines = true,
                HeaderStyle = ColumnHeaderStyle.Nonclickable,
                HideSelection = false,
                MultiSelect = false
            };
            checklist.Columns.Add("Status", 105, HorizontalAlignment.Left);
            checklist.Columns.Add("Requirement", 205, HorizontalAlignment.Left);
            checklist.Columns.Add("What this means", 415, HorizontalAlignment.Left);
            Controls.Add(checklist);
            InitializeChecklist();

            verboseMode = new CheckBox
            {
                AutoSize = true,
                Location = new Point(33, 469),
                Text = "Show verbose technical log",
                Checked = false
            };
            verboseMode.CheckedChanged += delegate { ToggleVerboseMode(); };
            Controls.Add(verboseMode);

            log = new RichTextBox
            {
                Location = new Point(33, 505),
                Size = new Size(733, 115),
                Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right,
                ReadOnly = true,
                BackColor = Color.White,
                BorderStyle = BorderStyle.FixedSingle,
                Font = new Font("Consolas", 8.5F),
                DetectUrls = false,
                WordWrap = false,
                Visible = false
            };
            Controls.Add(log);

            uninstallButton = new Button
            {
                Location = new Point(33, 510),
                Size = new Size(190, 38),
                Anchor = AnchorStyles.Bottom | AnchorStyles.Left,
                Text = "Uninstall / restore Windows",
                Enabled = false
            };
            uninstallButton.Click += async delegate { await StartUninstallationAsync(); };
            Controls.Add(uninstallButton);

            primaryButton = new Button
            {
                Location = new Point(506, 510),
                Size = new Size(126, 38),
                Anchor = AnchorStyles.Bottom | AnchorStyles.Right,
                Text = "Install",
                Enabled = false,
                BackColor = Color.FromArgb(34, 112, 190),
                ForeColor = Color.White,
                FlatStyle = FlatStyle.Flat
            };
            primaryButton.FlatAppearance.BorderSize = 0;
            primaryButton.EnabledChanged += delegate { ApplyPrimaryButtonVisual(); };
            primaryButton.Click += async delegate { await StartInstallationAsync(); };
            Controls.Add(primaryButton);
            ApplyPrimaryButtonVisual();

            closeButton = new Button
            {
                Location = new Point(640, 510),
                Size = new Size(126, 38),
                Anchor = AnchorStyles.Bottom | AnchorStyles.Right,
                Text = "Close"
            };
            closeButton.Click += delegate { Close(); };
            Controls.Add(closeButton);

            FormClosing += OnFormClosing;
            Shown += async delegate
            {
                if (resumeMode)
                {
                    await RunInstallerAsync("Resume", false);
                }
                else
                {
                    await InspectAsync();
                }
            };
        }

        private void InitializeChecklist()
        {
            string[] titles =
            {
                "Apple Boot Camp base drivers",
                "Windows Test Mode",
                "Self-signed driver certificate",
                "UART H4 Bluetooth filter",
                "HFP microphone + audio endpoint",
                "Final full-duplex readiness"
            };
            for (int index = 0; index < titles.Length; index++)
            {
                ListViewItem item = new ListViewItem("CHECKING");
                item.UseItemStyleForSubItems = false;
                item.SubItems.Add(titles[index]);
                item.SubItems.Add("Waiting for the system scan...");
                item.SubItems[0].ForeColor = Color.FromArgb(33, 86, 145);
                item.SubItems[0].Font = new Font(checklist.Font, FontStyle.Bold);
                checklist.Items.Add(item);
                checklistItems[index + 1] = item;
            }
        }

        private void ToggleVerboseMode()
        {
            int targetHeight = verboseMode.Checked ? 690 : 560;
            int heightDelta = targetHeight - ClientSize.Height;
            Rectangle workingArea = Screen.FromControl(this).WorkingArea;
            int targetTop = Top - (heightDelta / 2);
            targetTop = Math.Max(workingArea.Top, targetTop);
            targetTop = Math.Min(targetTop, workingArea.Bottom - targetHeight - (Height - ClientSize.Height));
            ClientSize = new Size(ClientSize.Width, targetHeight);
            Top = Math.Max(workingArea.Top, targetTop);
            log.Visible = verboseMode.Checked;
        }

        private async Task InspectAsync()
        {
            operationRunning = true;
            closeButton.Enabled = true;
            ProcessResult result = await RunPowerShellAsync("Inspect", false);
            operationRunning = false;
            ApplyResult(result, true);
        }

        private async Task StartInstallationAsync()
        {
            bool allowTestMode =
                (inspectionResult == "NeedsTestMode" || inspectionResult == "NeedsTestModeRepair") &&
                testModeConsent.Checked;
            await RunInstallerAsync("Start", allowTestMode);
        }

        private async Task StartUninstallationAsync()
        {
            DialogResult answer = MessageBox.Show(
                "This will remove the Bluetooth Mic Mac drivers and root device, remove the test certificate, disable Windows Test Mode, and restart Windows automatically.\n\nDisabling Test Mode can also affect other test-signed drivers. Continue?",
                Program.ProductName,
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Warning,
                MessageBoxDefaultButton.Button2);
            if (answer != DialogResult.Yes)
            {
                return;
            }
            await RunInstallerAsync("Uninstall", false);
        }

        private async Task RunInstallerAsync(string mode, bool allowTestMode)
        {
            operationRunning = true;
            primaryButton.Enabled = false;
            uninstallButton.Enabled = false;
            testModeConsent.Enabled = false;
            closeButton.Enabled = false;
            status.Text = mode == "Resume"
                ? "Resuming after restart..."
                : mode == "Uninstall" ? "Restoring the original Windows configuration..." : "Installing...";

            ProcessResult result = await RunPowerShellAsync(mode, allowTestMode);
            operationRunning = false;
            ApplyResult(result, false);
        }

        private async Task<ProcessResult> RunPowerShellAsync(string mode, bool allowTestMode)
        {
            string script = Path.Combine(Program.PayloadRoot, "install.ps1");
            StringBuilder arguments = new StringBuilder();
            arguments.Append("-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ");
            arguments.Append(Quote(script));
            arguments.Append(" -Mode ");
            arguments.Append(mode);
            if (allowTestMode)
            {
                arguments.Append(" -AllowTestSigning");
            }

            ProcessStartInfo startInfo = new ProcessStartInfo
            {
                FileName = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.System),
                    "WindowsPowerShell\\v1.0\\powershell.exe"),
                Arguments = arguments.ToString(),
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
                WorkingDirectory = Program.PayloadRoot
            };

            ProcessResult result = new ProcessResult();
            using (Process process = new Process { StartInfo = startInfo })
            {
                process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs eventArgs)
                {
                    if (eventArgs.Data != null)
                    {
                        HandleOutputLine(eventArgs.Data, result);
                    }
                };
                process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs eventArgs)
                {
                    if (!string.IsNullOrWhiteSpace(eventArgs.Data))
                    {
                        AppendLog("PowerShell: " + eventArgs.Data);
                    }
                };
                process.Start();
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
                await Task.Run(delegate { process.WaitForExit(); });
                process.WaitForExit();
                result.ExitCode = process.ExitCode;
            }
            return result;
        }

        private void HandleOutputLine(string line, ProcessResult result)
        {
            if (line.StartsWith("@@CHECK|", StringComparison.Ordinal))
            {
                string[] parts = line.Split(new[] { '|' }, 5);
                int order;
                if (parts.Length == 5 && int.TryParse(parts[1], out order))
                {
                    UpdateChecklist(order, parts[2], parts[3], parts[4]);
                }
                return;
            }
            if (line.StartsWith("@@STATUS|", StringComparison.Ordinal))
            {
                SetStatus(line.Substring(9));
                return;
            }
            if (line.StartsWith("@@PROGRESS|", StringComparison.Ordinal))
            {
                int value;
                if (int.TryParse(line.Substring(11), out value))
                {
                    SetProgress(value);
                }
                return;
            }
            if (line.StartsWith("@@LOG|", StringComparison.Ordinal))
            {
                AppendLog(line.Substring(6));
                return;
            }
            if (line.StartsWith("@@RESULT|", StringComparison.Ordinal))
            {
                string[] parts = line.Split(new[] { '|' }, 3);
                if (parts.Length == 3)
                {
                    result.Kind = parts[1];
                    result.Message = parts[2];
                }
                return;
            }
            if (!string.IsNullOrWhiteSpace(line))
            {
                AppendLog(line);
            }
        }

        private void UpdateChecklist(int order, string state, string title, string details)
        {
            if (InvokeRequired)
            {
                BeginInvoke(new Action<int, string, string, string>(UpdateChecklist),
                    order, state, title, details);
                return;
            }
            ListViewItem item;
            if (!checklistItems.TryGetValue(order, out item))
            {
                return;
            }
            item.Text = state;
            item.SubItems[1].Text = title;
            item.SubItems[2].Text = details;
            switch (state)
            {
                case "READY":
                    item.SubItems[0].ForeColor = Color.FromArgb(25, 122, 74);
                    break;
                case "ACTION REQUIRED":
                    item.SubItems[0].ForeColor = Color.FromArgb(185, 105, 20);
                    break;
                case "MISSING":
                case "BLOCKED":
                    item.SubItems[0].ForeColor = Color.FromArgb(178, 50, 52);
                    break;
                default:
                    item.SubItems[0].ForeColor = Color.FromArgb(91, 99, 112);
                    break;
            }
        }

        private void ApplyResult(ProcessResult result, bool inspection)
        {
            inspectionResult = result.Kind ?? string.Empty;
            string message = string.IsNullOrWhiteSpace(result.Message)
                ? "The process ended without a final status. Exit code: " + result.ExitCode
                : result.Message;
            detail.Text = message;

            switch (inspectionResult)
            {
                case "AlreadyInstalled":
                    status.Text = "Everything required is already installed";
                    status.ForeColor = Color.FromArgb(25, 122, 74);
                    progress.Value = 100;
                    primaryButton.Enabled = false;
                    uninstallButton.Enabled = true;
                    testModeConsent.Visible = false;
                    closeButton.Enabled = true;
                    break;

                case "NeedsTestMode":
                    status.Text = "Windows Test Mode must be enabled";
                    status.ForeColor = Color.FromArgb(185, 105, 20);
                    testModeConsent.Visible = true;
                    testModeConsent.Enabled = true;
                    primaryButton.Text = "Install";
                    primaryButton.Enabled = testModeConsent.Checked;
                    uninstallButton.Enabled = false;
                    closeButton.Enabled = true;
                    break;

                case "NeedsTestModeRepair":
                    status.Text = "Windows Test Mode must be enabled to repair setup";
                    status.ForeColor = Color.FromArgb(185, 105, 20);
                    testModeConsent.Visible = true;
                    testModeConsent.Enabled = true;
                    primaryButton.Text = "Repair / update";
                    primaryButton.Enabled = testModeConsent.Checked;
                    uninstallButton.Enabled = true;
                    closeButton.Enabled = true;
                    break;

                case "Ready":
                    status.Text = "The system is ready for setup";
                    status.ForeColor = Color.FromArgb(33, 86, 145);
                    testModeConsent.Visible = false;
                    primaryButton.Text = "Install";
                    primaryButton.Enabled = true;
                    uninstallButton.Enabled = false;
                    closeButton.Enabled = true;
                    break;

                case "ReadyRepair":
                    status.Text = "An incomplete or older installation was found";
                    status.ForeColor = Color.FromArgb(185, 105, 20);
                    testModeConsent.Visible = false;
                    primaryButton.Text = "Repair / update";
                    primaryButton.Enabled = true;
                    uninstallButton.Enabled = true;
                    closeButton.Enabled = true;
                    break;

                case "RebootScheduled":
                    status.Text = "Restart scheduled";
                    status.ForeColor = Color.FromArgb(33, 86, 145);
                    rebootScheduled = true;
                    primaryButton.Enabled = false;
                    uninstallButton.Enabled = false;
                    closeButton.Enabled = false;
                    break;

                case "Installed":
                    status.Text = "Setup is complete";
                    status.ForeColor = Color.FromArgb(25, 122, 74);
                    progress.Value = 100;
                    primaryButton.Enabled = false;
                    uninstallButton.Enabled = true;
                    testModeConsent.Visible = false;
                    closeButton.Enabled = true;
                    break;

                case "Uninstalled":
                    status.Text = "Original Windows Bluetooth configuration restored";
                    status.ForeColor = Color.FromArgb(25, 122, 74);
                    progress.Value = 100;
                    primaryButton.Enabled = false;
                    uninstallButton.Enabled = false;
                    testModeConsent.Visible = false;
                    closeButton.Enabled = true;
                    break;

                case "BlockedInstalled":
                    status.Text = "Setup cannot proceed, but installed components can be removed";
                    status.ForeColor = Color.FromArgb(178, 50, 52);
                    primaryButton.Enabled = false;
                    uninstallButton.Enabled = true;
                    testModeConsent.Visible = false;
                    closeButton.Enabled = true;
                    break;

                case "Blocked":
                case "Error":
                default:
                    status.Text = inspectionResult == "Blocked"
                        ? "Setup cannot proceed safely"
                        : "Setup was stopped";
                    status.ForeColor = Color.FromArgb(178, 50, 52);
                    primaryButton.Enabled = false;
                    uninstallButton.Enabled = false;
                    testModeConsent.Visible = false;
                    closeButton.Enabled = true;
                    if (!inspection && inspectionResult == "Error")
                    {
                        MessageBox.Show(
                            message,
                            Program.ProductName,
                            MessageBoxButtons.OK,
                            MessageBoxIcon.Error);
                    }
                    break;
            }
        }

        private void SetStatus(string value)
        {
            if (InvokeRequired)
            {
                BeginInvoke(new Action<string>(SetStatus), value);
                return;
            }
            status.Text = value;
        }

        private void SetProgress(int value)
        {
            if (InvokeRequired)
            {
                BeginInvoke(new Action<int>(SetProgress), value);
                return;
            }
            progress.Value = Math.Max(progress.Minimum, Math.Min(progress.Maximum, value));
        }

        private void AppendLog(string value)
        {
            if (InvokeRequired)
            {
                BeginInvoke(new Action<string>(AppendLog), value);
                return;
            }
            log.AppendText(value + Environment.NewLine);
            log.SelectionStart = log.TextLength;
            log.ScrollToCaret();
        }

        private void OnFormClosing(object sender, FormClosingEventArgs eventArgs)
        {
            if (operationRunning && !rebootScheduled && eventArgs.CloseReason == CloseReason.UserClosing)
            {
                eventArgs.Cancel = true;
                MessageBox.Show(
                    "A protected setup phase is currently running. Please wait for it to finish.",
                    Program.ProductName,
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
            }
        }

        private void ApplyPrimaryButtonVisual()
        {
            if (primaryButton.Enabled)
            {
                primaryButton.FlatStyle = FlatStyle.Flat;
                primaryButton.FlatAppearance.BorderSize = 0;
                primaryButton.BackColor = Color.FromArgb(34, 112, 190);
                primaryButton.ForeColor = Color.White;
                primaryButton.UseVisualStyleBackColor = false;
            }
            else
            {
                primaryButton.FlatStyle = FlatStyle.Standard;
                primaryButton.BackColor = SystemColors.Control;
                primaryButton.ForeColor = SystemColors.GrayText;
                primaryButton.UseVisualStyleBackColor = true;
            }
        }

        private static string Quote(string value)
        {
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }

        private sealed class ProcessResult
        {
            internal int ExitCode;
            internal string Kind;
            internal string Message;
        }
    }
}
