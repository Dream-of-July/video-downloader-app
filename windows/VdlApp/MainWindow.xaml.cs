using System.ComponentModel;
using System.Windows;
using System.Windows.Media.Animation;

namespace Vdl.App;

/// <summary>主窗口：输入框聚焦 / 多链接粘贴拦截 / 设置与登录窗口的转场 / 关窗确认 / 队列展开收起动画。</summary>
public partial class MainWindow : Window
{
    private const double QueueCollapsedHeight = 44;
    private const double QueueExpandedHeight = 288;

    private readonly MainViewModel _vm;

    public MainWindow()
    {
        _vm = new MainViewModel();
        DataContext = _vm;
        InitializeComponent();
        _vm.FocusUrlRequested += FocusUrlBox;
        _vm.OpenSettingsRequested += OpenSettingsWindow;
        _vm.OpenLoginRequested += OpenLoginWindow;
        _vm.PropertyChanged += OnViewModelPropertyChanged;
        DataObject.AddPastingHandler(UrlBox, OnUrlBoxPaste);
        Loaded += (_, _) =>
        {
            _vm.PrefillFromClipboardIfAppropriate();
            FocusUrlBox();
        };
        // 等价 macOS didBecomeActive：切回 App 时用剪贴板里的链接预填
        Activated += (_, _) => _vm.PrefillFromClipboardIfAppropriate();
    }

    private void FocusUrlBox()
    {
        UrlBox.Focus();
        UrlBox.SelectAll();
    }

    private void OnViewModelPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(MainViewModel.IsQueueExpanded))
        {
            AnimateQueuePanel(_vm.IsQueueExpanded);
        }
    }

    /// <summary>
    /// 队列展开 / 收起动画：高度 + 主体淡入淡出（约 220ms，缓出）。
    /// 收起完成后把主体设为 Collapsed，摘要栏独占点击与键盘焦点。
    /// </summary>
    private void AnimateQueuePanel(bool expand)
    {
        QueueBody.Visibility = Visibility.Visible;
        var duration = TimeSpan.FromMilliseconds(220);
        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };

        var height = new DoubleAnimation(expand ? QueueExpandedHeight : QueueCollapsedHeight, duration)
        {
            EasingFunction = ease,
        };
        if (!expand)
        {
            height.Completed += (_, _) =>
            {
                // 动画期间用户又点了展开：保持可见
                if (!_vm.IsQueueExpanded) QueueBody.Visibility = Visibility.Collapsed;
            };
        }
        QueuePanel.BeginAnimation(HeightProperty, height);

        var fade = new DoubleAnimation(expand ? 1 : 0, TimeSpan.FromMilliseconds(expand ? 220 : 140))
        {
            EasingFunction = ease,
        };
        QueueBody.BeginAnimation(OpacityProperty, fade);
    }

    /// <summary>Ctrl+V 粘贴多条链接时不进输入框逐字编辑，直接整体交给批量解析入队。</summary>
    private void OnUrlBoxPaste(object sender, DataObjectPastingEventArgs e)
    {
        try
        {
            if (!e.DataObject.GetDataPresent(DataFormats.UnicodeText)) return;
            var text = e.DataObject.GetData(DataFormats.UnicodeText) as string ?? "";
            if (MainViewModel.ExtractUrls(text).Count <= 1) return; // 单链接走默认粘贴
            e.CancelCommand();
            _vm.UrlText = text.Trim();
            _vm.Parse();
        }
        catch
        {
            // 剪贴板数据异常时退回默认粘贴行为
        }
    }

    private void OpenSettingsWindow()
    {
        var window = new SettingsWindow(_vm) { Owner = this };
        window.ShowDialog();
        // 设置窗里点了「登录 ××」：先收起设置窗，再弹登录窗（对齐 macOS sheet 转场）。
        if (window.PendingLoginSite is { } site) OpenLoginWindow(site);
    }

    private void OpenLoginWindow(string site)
    {
        var login = new LoginWindow(site) { Owner = this };
        if (login.ShowDialog() == true) _vm.LoginCompleted();
    }

    /// <summary>关窗且有未完成任务（含已暂停）→ 确认对话框，确认则全部中止。</summary>
    protected override void OnClosing(CancelEventArgs e)
    {
        if (_vm.AbortConfirmationMessage() is { } message)
        {
            var confirmed = ConfirmWindow.Show(
                this, message, detail: null,
                confirmText: Loc.S("L.Confirm.AbortAndClose"),
                cancelText: Loc.S("L.Confirm.KeepRunning"));
            if (!confirmed)
            {
                e.Cancel = true;
                return;
            }
            _vm.AbortAllTasks();
        }
        base.OnClosing(e);
    }
}
