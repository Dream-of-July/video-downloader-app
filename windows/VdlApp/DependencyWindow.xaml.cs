using System.ComponentModel;
using System.Windows;

namespace Vdl.App;

/// <summary>
/// 依赖下载进度窗（模态）：逐项下载缺失组件，失败可重试。
/// 下载进行中禁止关闭（首次启动场景下主窗口因此保持不可用直到完成）。
/// </summary>
public partial class DependencyWindow : Window
{
    private readonly Func<IProgress<string>, CancellationToken, Task> _work;
    private bool _running;

    public DependencyWindow(string title, string caption, Func<IProgress<string>, CancellationToken, Task> work)
    {
        _work = work;
        InitializeComponent();
        Title = title;
        CaptionText.Text = caption;
        Loaded += (_, _) => _ = RunAsync();
    }

    private async Task RunAsync()
    {
        _running = true;
        RetryButton.Visibility = Visibility.Collapsed;
        CloseButton.Visibility = Visibility.Collapsed;
        ErrorText.Visibility = Visibility.Collapsed;
        Bar.IsIndeterminate = true;
        StatusText.Text = Loc.S("L.Dep.Checking");
        // Progress<string> 在 UI 线程创建：回调自动回到 UI 线程更新文案。
        var progress = new Progress<string>(text => StatusText.Text = text);
        try
        {
            await _work(progress, CancellationToken.None);
            _running = false;
            DialogResult = true;
        }
        catch (Exception error)
        {
            _running = false;
            Bar.IsIndeterminate = false;
            StatusText.Text = Loc.S("L.Dep.DownloadFailed");
            ErrorText.Text = error.Message;
            ErrorText.Visibility = Visibility.Visible;
            RetryButton.Visibility = Visibility.Visible;
            CloseButton.Visibility = Visibility.Visible;
        }
    }

    private void OnRetryClick(object sender, RoutedEventArgs e)
    {
        _ = RunAsync();
    }

    private void OnCloseClick(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        // 下载进行中不允许关窗（半截文件由 DependencyManager 的 .tmp 机制兜底，但中断没有意义）。
        if (_running) e.Cancel = true;
        base.OnClosing(e);
    }
}
