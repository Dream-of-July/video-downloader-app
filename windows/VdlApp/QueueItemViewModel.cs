using System.Diagnostics;
using System.IO;
using Vdl.Core;

namespace Vdl.App;

/// <summary>
/// 队列中的一行。字段在 UI 线程上从 QueueManager.Item(id) 的最新快照复制
/// （不长期缓存 QueueItem 引用跨线程读）；SetProperty 等值短路抑制高频进度回调下的多余重绘。
/// </summary>
public sealed class QueueItemViewModel : ObservableObject
{
    private readonly QueueManager _queue;
    private IReadOnlyList<string> _resultFiles = [];

    public Guid Id { get; }
    public string Title { get; }

    public RelayCommand PauseCommand { get; }
    public RelayCommand ResumeCommand { get; }
    public RelayCommand CancelCommand { get; }
    public RelayCommand RetryCommand { get; }
    public RelayCommand RemoveCommand { get; }
    public RelayCommand RevealCommand { get; }

    public QueueItemViewModel(QueueManager queue, QueueManager.QueueItem item)
    {
        _queue = queue;
        Id = item.Id;
        Title = item.Title;
        PauseCommand = new RelayCommand(() => _queue.Pause(Id));
        ResumeCommand = new RelayCommand(() => _queue.Resume(Id));
        CancelCommand = new RelayCommand(() => _queue.Cancel(Id));
        RetryCommand = new RelayCommand(() => _queue.Retry(Id));
        RemoveCommand = new RelayCommand(() => _queue.Remove(Id));
        RevealCommand = new RelayCommand(OpenInExplorer);
        Refresh(item);
    }

    // MARK: - 展示状态

    private string _statusText = "";
    public string StatusText { get => _statusText; private set => SetProperty(ref _statusText, value); }

    private bool _isFailed;
    public bool IsFailed { get => _isFailed; private set => SetProperty(ref _isFailed, value); }

    private bool _isPaused;
    public bool IsPaused { get => _isPaused; private set => SetProperty(ref _isPaused, value); }

    private bool _showProgress;
    public bool ShowProgress { get => _showProgress; private set => SetProperty(ref _showProgress, value); }

    private double _progressValue;
    public double ProgressValue { get => _progressValue; private set => SetProperty(ref _progressValue, value); }

    private bool _progressIndeterminate;
    public bool ProgressIndeterminate { get => _progressIndeterminate; private set => SetProperty(ref _progressIndeterminate, value); }

    // MARK: - 按钮组（按阶段变化）

    private bool _showPause;
    public bool ShowPause { get => _showPause; private set => SetProperty(ref _showPause, value); }

    private bool _showResume;
    public bool ShowResume { get => _showResume; private set => SetProperty(ref _showResume, value); }

    private bool _showCancel;
    public bool ShowCancel { get => _showCancel; private set => SetProperty(ref _showCancel, value); }

    private bool _showRetry;
    public bool ShowRetry { get => _showRetry; private set => SetProperty(ref _showRetry, value); }

    private bool _showRetrySubtitle;
    public bool ShowRetrySubtitle { get => _showRetrySubtitle; private set => SetProperty(ref _showRetrySubtitle, value); }

    private bool _showReveal;
    public bool ShowReveal { get => _showReveal; private set => SetProperty(ref _showReveal, value); }

    private bool _showRemove;
    public bool ShowRemove { get => _showRemove; private set => SetProperty(ref _showRemove, value); }

    // MARK: - 刷新

    /// <summary>用最新队列项快照刷新本行（UI 线程调用；项已被移除时安全跳过）。</summary>
    public void Refresh(QueueManager.QueueItem? item)
    {
        if (item is null || item.Id != Id) return;
        var kind = item.Stage.Kind;
        var open = kind is ItemStageKind.Queued or ItemStageKind.Downloading
            or ItemStageKind.Translating or ItemStageKind.Burning;

        IsPaused = item.IsPaused;
        StatusText = ComputeStatusText(item, open);
        IsFailed = kind == ItemStageKind.Failed;
        ShowProgress = open;
        ProgressValue = item.Progress is { } progress ? Math.Min(Math.Max(progress, 0), 1) : 0;
        ProgressIndeterminate = open && item.Progress is null;

        ShowPause = open && !item.IsPaused;
        ShowResume = open && item.IsPaused;
        ShowCancel = open;
        ShowRetry = kind is ItemStageKind.Failed or ItemStageKind.Cancelled;
        // 部分成功（视频已下载、字幕处理失败）：只重跑字幕处理，不重新下载
        ShowRetrySubtitle = kind == ItemStageKind.Done && item.PartialFailure;
        ShowReveal = kind is ItemStageKind.Done or ItemStageKind.Cancelled && item.ResultFiles.Count > 0;
        ShowRemove = !open;
        _resultFiles = item.ResultFiles;
    }

    private static string ComputeStatusText(QueueManager.QueueItem item, bool open)
    {
        if (open && item.IsPaused) return Loc.S("L.Status.Paused");
        return item.Stage.Kind switch
        {
            // 等槽位/等待恢复等具体原因（QueueManager 写入），没有就显示通用文案
            ItemStageKind.Queued => item.StatusText ?? Loc.S("L.Status.Queued"),
            ItemStageKind.Downloading when item.IsPostDownloadProcessing => Loc.S("L.Status.Processing"),
            ItemStageKind.Downloading => item.Progress is { } p
                ? Loc.F("L.Status.DownloadingFmt", (int)(p * 100))
                : Loc.S("L.Status.Downloading"),
            ItemStageKind.Translating => item.Progress is { } p
                ? Loc.F("L.Status.TranslatingFmt", (int)(p * 100))
                : Loc.S("L.Status.Translating"),
            ItemStageKind.Burning => item.Progress is { } p
                ? Loc.F("L.Status.BurningFmt", (int)(p * 100))
                : Loc.S("L.Status.Burning"),
            ItemStageKind.Done => item.StatusText ?? Loc.S("L.Status.Done"),
            ItemStageKind.Cancelled => item.StatusText ?? Loc.S("L.Status.Cancelled"),
            ItemStageKind.Failed => Loc.F("L.Status.FailedFmt", item.Stage.FailureReason ?? Loc.S("L.Status.Unknown")),
            _ => item.StatusText ?? "",
        };
    }

    /// <summary>在资源管理器中选中产物（烧录视频排第一）。</summary>
    private void OpenInExplorer()
    {
        try
        {
            var file = _resultFiles.FirstOrDefault(File.Exists) ?? _resultFiles.FirstOrDefault();
            if (file is null || !OperatingSystem.IsWindows()) return;
            Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{file}\"") { UseShellExecute = true });
        }
        catch
        {
            // 打不开资源管理器不影响任务状态
        }
    }
}
