using System.Drawing;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Windows.Forms;

namespace CrossMouse.Windows.App;

/// <summary>
/// Ordinary Windows desktop app with Start / Stop / Exit controls.
/// Minimize and X close only hide to tray; only an explicit Exit fully stops.
/// </summary>
internal sealed class CrossMouseWindow : Form
{
    private readonly Label _status = NewLabel("시작 중…", 12, true);
    private readonly Label _detail = NewLabel("Mac에서 연결하면 마우스·키보드를 공유합니다.", 10);
    private readonly Button _start = NewButton("연결 시작");
    private readonly Button _stop = NewButton("연결 중지");
    private readonly Button _exit = NewButton("앱 종료");
    private readonly CheckBox _smoothing = new()
    {
        Text = "부드러운 마우스 이동 (기본 사용)",
        Checked = true,
        AutoSize = true
    };
    private readonly Label _motionStats = NewLabel("마우스를 움직이면 수신 간격을 표시합니다.", 9);
    private readonly System.Windows.Forms.Timer _statsTimer = new() { Interval = 2000 };
    private readonly NotifyIcon _tray;
    private ReceiverService? _receiver;
    private readonly string _keyPath;
    private readonly byte[]? _pairingKey;
    private bool _closing;

    // Unlike ordinary Close(), only QuitAsync is allowed to destroy the main
    // form. Application.Run(form) would otherwise exit and kill the receiver.
    // Tests inject a temporary key/ephemeral port instead of touching the
    // user's saved pairing key or an existing live TCP listener.
    internal bool ReceiverRunningForTest => _receiver?.IsRunning ?? false;
    internal bool RemoteActiveForTest => _receiver?.IsRemotelyActive ?? false;
    internal int ListeningPortForTest => _receiver?.ListeningPort ?? 0;
    internal void RestoreForTest() => RestoreWindow();
    internal Task QuitForTestAsync() => QuitAsync();

    public CrossMouseWindow(byte[]? selfTestKey = null, int port = 49431)
    {
        string version = typeof(CrossMouseWindow).Assembly.GetName().Version?.ToString(3) ?? "unknown";
        Text = $"CrossMouse - Windows v{version}";
        ClientSize = new Size(540, 435);
        MinimumSize = new Size(510, 450);
        MaximumSize = new Size(770, 600);
        AutoScaleMode = AutoScaleMode.Dpi;
        Font = new Font("Segoe UI", 10F);
        StartPosition = FormStartPosition.CenterScreen;
        Icon = SystemIcons.Application;

        _keyPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "CrossMouse", "key"
        );
        try
        {
            _pairingKey = selfTestKey ?? LoadOrCreateKey(_keyPath);
            _receiver = new ReceiverService(_pairingKey, port);
            _receiver.StatusChanged += UpdateStatus;
        }
        catch (Exception error)
        {
            _status.Text = "키 파일을 읽을 수 없습니다";
            _detail.Text = error.Message;
            _start.Enabled = false;
        }

        var title = NewLabel($"CrossMouse v{version}", 23, true);
        var subtitle = NewLabel("Windows PC · 입력 수신기", 10);
        subtitle.ForeColor = SystemColors.GrayText;
        var address = NewLabel($"이 PC 주소: {LocalAddresses()}    ·    TCP 49431", 10);
        var instruction = NewLabel(
            "맥북에서 CrossMouse를 실행하고 ‘Windows 사용 (HDMI)’을 선택하세요. " +
            "필립스 화면은 모니터 버튼으로 HDMI로 변경해야 합니다.", 10
        );
        instruction.MaximumSize = new Size(490, 0);
        instruction.AutoSize = true;
        var privacy = NewLabel(
            "키보드·마우스는 페어링된 Mac과만 암호화하여 공유합니다. " +
            "X 버튼은 창만 숨깁니다. 작업 표시줄 알림 영역에서 다시 열 수 있고, ‘앱 종료’는 완전히 종료합니다.", 9
        );
        privacy.ForeColor = SystemColors.GrayText;
        privacy.MaximumSize = new Size(490, 0);
        privacy.AutoSize = true;

        var buttons = new FlowLayoutPanel
        {
            AutoSize = true,
            FlowDirection = FlowDirection.LeftToRight,
            WrapContents = false,
            Margin = new Padding(0, 4, 0, 4)
        };
        _start.Click += (_, _) => StartReceiver();
        _stop.Click += async (_, _) => await StopReceiverAsync();
        _exit.Click += async (_, _) => await QuitAsync();
        _smoothing.CheckedChanged += (_, _) =>
        {
            var receiver = _receiver;
            bool enabled = _smoothing.Checked;
            if (receiver is not null)
                _ = Task.Run(() => receiver.SetSmoothingEnabled(enabled));
        };
        _motionStats.ForeColor = SystemColors.GrayText;
        _motionStats.MaximumSize = new Size(490, 0);
        _motionStats.AutoSize = true;
        _statsTimer.Tick += async (_, _) => await UpdateMouseStatsAsync();
        _stop.Enabled = false;
        var copyKey = NewButton("페어링 키 복사");
        copyKey.Click += (_, _) => CopyPairingKey();
        if (_pairingKey is null) copyKey.Enabled = false;
        buttons.Controls.AddRange([_start, _stop, copyKey, _exit]);

        var stack = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(23, 18, 23, 18),
            ColumnCount = 1,
            AutoScroll = true
        };
        stack.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        foreach (Control control in new Control[]
        {
            title, subtitle, address, _status, _detail, instruction,
            _smoothing, _motionStats, buttons, privacy
        })
        {
            control.Margin = new Padding(0, 0, 0, 13);
            control.Dock = DockStyle.Top;
            stack.Controls.Add(control);
        }
        Controls.Add(stack);

        var trayMenu = new ContextMenuStrip();
        trayMenu.Items.Add("창 열기", null, (_, _) => RestoreWindow());
        trayMenu.Items.Add("연결 시작", null, (_, _) => StartReceiver());
        trayMenu.Items.Add("연결 중지", null, async (_, _) => await StopReceiverAsync());
        trayMenu.Items.Add(new ToolStripSeparator());
        trayMenu.Items.Add("완전 종료", null, async (_, _) => await QuitAsync());
        _tray = new NotifyIcon
        {
            Icon = SystemIcons.Application,
            Text = $"CrossMouse v{version} (Windows)",
            Visible = true,
            ContextMenuStrip = trayMenu
        };
        _tray.DoubleClick += (_, _) => RestoreWindow();

        // Keep one-click launch behavior. If the previous console receiver is
        // still running the UI shows a clear port-in-use error instead.
        Shown += (_, _) =>
        {
            StartReceiver();
            _statsTimer.Start();
        };
        Resize += (_, _) =>
        {
            if (WindowState == FormWindowState.Minimized) Hide();
        };
        FormClosed += (_, _) =>
        {
            _statsTimer.Stop();
            _statsTimer.Dispose();
            _tray.Visible = false;
            _tray.Dispose();
            trayMenu.Dispose();
        };
    }

    private static Button NewButton(string title) => new()
    {
        Text = title,
        AutoSize = true,
        MinimumSize = new Size(95, 33),
        Margin = new Padding(0, 0, 9, 0)
    };

    private static Label NewLabel(string title, float size, bool bold = false) => new()
    {
        Text = title,
        Font = new Font("Segoe UI", size, bold ? FontStyle.Bold : FontStyle.Regular),
        AutoSize = true
    };

    private static byte[] LoadOrCreateKey(string path)
    {
        if (!File.Exists(path))
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            // LocalAppData is private to the Windows user by default.
            // Do not replace the key already used by a paired Mac.
            var generated = Convert.ToHexString(RandomNumberGenerator.GetBytes(32));
            using var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write);
            using var writer = new StreamWriter(stream);
            writer.WriteLine(generated);
        }
        var bytes = Convert.FromHexString(File.ReadAllText(path).Trim());
        if (bytes.Length != 32) throw new InvalidDataException("페어링 키는 32바이트여야 합니다.");
        return bytes;
    }

    private static string LocalAddresses()
    {
        try
        {
            return string.Join(", ",
                NetworkInterface.GetAllNetworkInterfaces()
                    .Where(n => n.OperationalStatus == OperationalStatus.Up
                                && n.NetworkInterfaceType != NetworkInterfaceType.Loopback)
                    .SelectMany(n => n.GetIPProperties().UnicastAddresses)
                    .Select(a => a.Address)
                    .Where(a => a.AddressFamily == AddressFamily.InterNetwork
                                && !IPAddress.IsLoopback(a)
                                && !a.ToString().StartsWith("169.254.", StringComparison.Ordinal))
                    .Distinct()
                    .Take(3)
            ) is { Length: > 0 } addresses ? addresses : "ipconfig에서 IPv4 확인";
        }
        catch { return "ipconfig에서 IPv4 확인"; }
    }

    private void StartReceiver()
    {
        if (_receiver is null || _closing || _receiver.IsRunning) return;
        try
        {
            _receiver.Start();
            _start.Enabled = false;
            _stop.Enabled = true;
        }
        catch (SocketException)
        {
            _status.Text = "연결 시작 실패";
            _detail.Text = "TCP 49431 사용 중입니다. 기존 CrossMouse.Windows.exe 창을 종료한 후 ‘연결 시작’을 눌러주세요.";
            _start.Enabled = true;
            _stop.Enabled = false;
        }
        catch (Exception error)
        {
            _status.Text = "연결 시작 실패";
            _detail.Text = error.Message;
        }
    }

    private async Task StopReceiverAsync()
    {
        var receiver = _receiver;
        if (receiver is null || !receiver.IsRunning) return;
        _stop.Enabled = false;
        try { await Task.Run(receiver.StopAsync); }
        catch (Exception error) { _detail.Text = $"연결 종료 오류: {error.Message}"; }
        _start.Enabled = !_closing;
    }

    private void CopyPairingKey()
    {
        if (_pairingKey is null) return;
        try
        {
            Clipboard.SetText(Convert.ToHexString(_pairingKey).ToLowerInvariant());
            _detail.Text = "페어링 키를 복사했어요. Mac에 등록한 후 클립보드에서 지워주세요. 채팅이나 GitHub에 공개하지 마세요.";
        }
        catch (System.Runtime.InteropServices.ExternalException)
        {
            _detail.Text = "클립보드가 다른 앱에서 사용 중입니다. 잠시 뒤 다시 시도하세요.";
        }
    }

    private async Task UpdateMouseStatsAsync()
    {
        // Input injection can synchronously dispatch Windows GUI messages
        // while holding its lock. The Windows UI must NEVER wait for that
        // lock, including the stats timer or checkbox callbacks.
        var receiver = _receiver;
        if (receiver is null) return;
        var stats = await Task.Run(receiver.TakeMotionGapStats);
        if (IsDisposed || Disposing || _closing) return;
        _motionStats.Text = stats.MovePackets == 0
            ? "최근 2초: 마우스 입력 없음"
            : $"최근 2초: 수신 {stats.MovePackets}회 · 25ms 넘는 간격 {stats.GapsOver25Ms}회" +
              (stats.MaxGapMs > 0 ? $" · 최대 {stats.MaxGapMs}ms" : "");
    }

    private void UpdateStatus(ReceiverState state, string message)
    {
        if (IsDisposed || Disposing || _closing) return;
        if (InvokeRequired)
        {
            if (IsHandleCreated) BeginInvoke(new Action(() => UpdateStatus(state, message)));
            return;
        }
        _status.Text = state switch
        {
            ReceiverState.Connected => "연결됨",
            ReceiverState.Waiting => "Mac 연결 대기 중",
            ReceiverState.Stopped => "중지됨",
            ReceiverState.Faulted => "오류 발생",
            _ => "상태 확인 중"
        };
        _detail.Text = message;
        _start.Enabled = state is ReceiverState.Stopped or ReceiverState.Faulted;
        _stop.Enabled = state is ReceiverState.Waiting or ReceiverState.Connected;
    }

    private void RestoreWindow()
    {
        Show();
        WindowState = FormWindowState.Normal;
        Activate();
    }

    private async Task QuitAsync()
    {
        if (_closing) return;
        _closing = true;
        _tray.Visible = false;
        try
        {
            var receiver = _receiver;
            if (receiver is not null)
                await Task.Run(receiver.StopAsync);
        }
        catch (Exception error)
        {
            System.Diagnostics.Debug.WriteLine($"CrossMouse shutdown: {error.Message}");
        }
        Close();
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        // This callback runs on the Windows UI thread. The close may have
        // been triggered by SendInput on the receiver's background thread.
        // NEVER synchronously acquire InputInjector's lock here: that thread
        // might be waiting for the UI to process the injected mouse-up, and
        // taking the same lock here would deadlock both threads at the X.
        // Cancel and hide first; return the Mac cursor on another thread.
        // Never block actual Windows shutdown or Task Manager termination.
        if (!_closing && e.CloseReason != CloseReason.WindowsShutDown &&
            e.CloseReason != CloseReason.TaskManagerClosing)
        {
            e.Cancel = true;
            Hide();
            _tray.Visible = true;
            var receiver = _receiver;
            if (receiver is not null)
            {
                _ = Task.Run(async () =>
                {
                    try { await receiver.ReturnCursorToMacAsync().ConfigureAwait(false); }
                    catch (Exception error)
                    {
                        // A failed return must never freeze the UI thread.
                        System.Diagnostics.Debug.WriteLine(
                            $"CrossMouse background cursor return: {error.Message}");
                    }
                });
            }
            return;
        }
        // Explicit Exit already released the receiver. Never grab the input
        // lock on the GUI thread, even during shutdown.
        base.OnFormClosing(e);
    }
}
