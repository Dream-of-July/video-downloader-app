namespace Vdl.Core;

/// <summary>字幕处理方式（ready 页「字幕处理」分组的选项）。</summary>
public enum ChineseSubtitleMode
{
    Off,
    SrtOnly,
    BurnIn,
    /// <summary>不翻译，把所选源字幕原样烧录进视频（无论语言、无需配置翻译服务）。</summary>
    BurnOriginal,
}

/// <summary>
/// 阶段槽位池：限制同一阶段（下载 / 压制 / 翻译）的并发任务数。
/// 线程安全（锁 + 票据续延）；排队者被唤醒后重新竞争（队列规模小，开销可忽略）。
/// </summary>
public sealed class StageSlotPool
{
    private readonly object _lock = new();
    private readonly Func<int> _capacity;
    private int _inUse;
    private readonly List<(Guid Id, TaskCompletionSource Tcs)> _parked = [];

    public StageSlotPool(Func<int> capacity)
    {
        _capacity = capacity;
    }

    public bool HasFreeSlot
    {
        get { lock (_lock) return _inUse < Math.Max(1, _capacity()); }
    }

    /// <summary>
    /// 等待并占用一个槽位。control 取消时抛 Cancelled。
    /// respectPause=true 时，暂停中的任务不抢槽（等恢复后再竞争）；
    /// 恢复重排队的路径传 false（item 已恢复但 token 仍处暂停态，等槽到手才真正恢复进程）。
    /// </summary>
    public async Task AcquireAsync(
        Guid id, TaskControlToken control, bool respectPause = true, CancellationToken ct = default)
    {
        while (true)
        {
            if (ct.IsCancellationRequested || control.IsCancelled) throw VdlException.Cancelled();
            if (respectPause && control.IsPaused)
            {
                await control.GateAsync(ct).ConfigureAwait(false);
                continue;
            }
            TaskCompletionSource tcs;
            lock (_lock)
            {
                if (_inUse < Math.Max(1, _capacity()))
                {
                    _inUse++;
                    return;
                }
                tcs = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                _parked.Add((id, tcs));
            }
            await tcs.Task.ConfigureAwait(false);
        }
    }

    /// <summary>释放一个槽位并唤醒全部排队者重新竞争。</summary>
    public void Release()
    {
        List<(Guid, TaskCompletionSource)> waiting;
        lock (_lock)
        {
            _inUse = Math.Max(0, _inUse - 1);
            waiting = [.. _parked];
            _parked.Clear();
        }
        foreach (var (_, tcs) in waiting) tcs.TrySetResult();
    }

    /// <summary>容量调大（设置变更）后让排队者重新竞争。</summary>
    public void WakeAll()
    {
        List<(Guid, TaskCompletionSource)> waiting;
        lock (_lock)
        {
            waiting = [.. _parked];
            _parked.Clear();
        }
        foreach (var (_, tcs) in waiting) tcs.TrySetResult();
    }

    /// <summary>取消某项时把它从排队里唤出（AcquireAsync 循环会自行检查取消并抛出）。</summary>
    public void Wake(Guid id)
    {
        TaskCompletionSource? tcs = null;
        lock (_lock)
        {
            var index = _parked.FindIndex(p => p.Id == id);
            if (index >= 0)
            {
                tcs = _parked[index].Tcs;
                _parked.RemoveAt(index);
            }
        }
        tcs?.TrySetResult();
    }
}

/// <summary>队列项当前所处阶段。暂停态不单列，由 QueueItem.IsPaused 叠加表示。</summary>
public enum ItemStageKind
{
    Queued,
    Downloading,
    Translating,
    Burning,
    Done,
    Failed,
    Cancelled,
}

public sealed record ItemStage(ItemStageKind Kind, string? FailureReason = null)
{
    public static readonly ItemStage Queued = new(ItemStageKind.Queued);
    public static readonly ItemStage Downloading = new(ItemStageKind.Downloading);
    public static readonly ItemStage Translating = new(ItemStageKind.Translating);
    public static readonly ItemStage Burning = new(ItemStageKind.Burning);
    public static readonly ItemStage Done = new(ItemStageKind.Done);
    public static readonly ItemStage Cancelled = new(ItemStageKind.Cancelled);
    public static ItemStage Failed(string reason) => new(ItemStageKind.Failed, reason);
}

/// <summary>
/// 下载队列。每个 QueueItem 是一条「下载 →[翻译]→[烧录]」完整流水线，
/// 持有独立的 TaskControlToken，可随时独立暂停 / 恢复 / 取消，并发执行互不阻塞；
/// 三个阶段各有并发上限（下载/压制可在设置里调，翻译固定 2 防网关限流），
/// 暂停会让出占用的下载/压制槽位给其它任务，恢复时重新排队领取。
/// 本类无 UI 依赖、线程安全；对外通过 ItemsChanged/ItemUpdated 事件通知，UI 层自行封送到主线程。
/// 状态读取请经 Items / Item(id)（带锁建立内存屏障），不要长期缓存 QueueItem 引用跨线程读。
/// </summary>
public sealed class QueueManager
{
    public sealed class QueueItem
    {
        public required Guid Id { get; init; }
        public required string Title { get; init; }
        public string? ThumbnailUrl { get; init; }
        public required VideoInfo Info { get; init; }
        public required DownloadRequest Request { get; init; }
        public required ChineseSubtitleMode ChineseMode { get; init; }
        /// <summary>本项使用的设置快照（字幕样式、烧录画质、翻译凭证）。</summary>
        public required AppSettings Settings { get; init; }
        public ItemStage Stage { get; internal set; } = ItemStage.Queued;
        /// <summary>0...1；null 表示不确定（处理 / 翻译启动等）。</summary>
        public double? Progress { get; internal set; }
        /// <summary>暂停 / 部分成功 / 失败原因等附加说明。</summary>
        public string? StatusText { get; internal set; }
        /// <summary>已落盘的产物（下载文件、译文、烧录视频）。</summary>
        public IReadOnlyList<string> ResultFiles { get; internal set; } = [];
        public bool IsPaused { get; internal set; }
        /// <summary>
        /// 下载已 100%、正在合并/转码/字幕转换（Progress 为 null 但仍处于 Downloading）。
        /// UI 据此显示「处理中…」而非「下载中…」（避免像卡死）。
        /// </summary>
        public bool IsPostDownloadProcessing { get; internal set; }
        /// <summary>部分成功：视频已下载但字幕处理失败（Done 态显示「重试字幕处理」按钮）。</summary>
        public bool PartialFailure { get; internal set; }
        /// <summary>本项流水线的控制令牌；Retry 时换新的（旧的已 Cancel）。</summary>
        public TaskControlToken Control { get; internal set; } = new();
        /// <summary>流水线代际：每次 enqueue/retry 递增；写回前校验，作废陈旧回调。</summary>
        public int Generation { get; internal set; }
        internal CancellationTokenSource Cts { get; set; } = new();
        internal Task? RunTask { get; set; }
    }

    private readonly object _lock = new();
    private readonly List<QueueItem> _items = [];
    private readonly IDownloadEngine _engine;
    private readonly Func<AppSettings, ISubtitleTranslator> _translatorFactory;
    private readonly Func<ISubtitleBurner> _burnerFactory;

    /// <summary>列表增删时触发（任意线程）。</summary>
    public event Action? ItemsChanged;
    /// <summary>单项字段变化时触发（任意线程）。</summary>
    public event Action<Guid>? ItemUpdated;

    private int _maxConcurrentDownloads;
    private int _maxConcurrentBurns;

    /// <summary>同时下载数（设置变更时由 UI 层同步；调大即时生效）。</summary>
    public int MaxConcurrentDownloads
    {
        get { lock (_lock) return _maxConcurrentDownloads; }
        set
        {
            lock (_lock) _maxConcurrentDownloads = value;
            _downloadPool.WakeAll();
        }
    }

    /// <summary>同时压制数。</summary>
    public int MaxConcurrentBurns
    {
        get { lock (_lock) return _maxConcurrentBurns; }
        set
        {
            lock (_lock) _maxConcurrentBurns = value;
            _burnPool.WakeAll();
        }
    }

    private readonly StageSlotPool _downloadPool;
    private readonly StageSlotPool _burnPool;
    /// <summary>翻译并发固定 2（每项内部还有 3 路分块并行，再高容易撞网关限流）。</summary>
    private readonly StageSlotPool _translatePool;
    /// <summary>
    /// 正在占用槽位的项（暂停让位 / 阶段结束释放用）。带代际：重试后旧流水线的
    /// 延迟释放不得动新代际刚领到的槽位。
    /// </summary>
    private readonly Dictionary<Guid, (int Generation, StageSlotPool Pool)> _holdingPool = [];
    /// <summary>暂停时让出的槽位池：恢复时需先重新领到槽位再恢复进程。</summary>
    private readonly Dictionary<Guid, (int Generation, StageSlotPool Pool)> _resumePool = [];

    /// <summary>视频文件后缀（用于在产物里识别可烧录的视频）。</summary>
    internal static readonly HashSet<string> VideoExtensions =
    [
        "mp4", "mov", "mkv", "webm", "m4v", "avi", "flv", "ts",
    ];

    public QueueManager(
        IDownloadEngine engine,
        Func<AppSettings, ISubtitleTranslator>? translatorFactory = null,
        Func<ISubtitleBurner>? burnerFactory = null,
        AppSettings? settings = null)
    {
        _engine = engine;
        _translatorFactory = translatorFactory ?? (s => new ConfiguredTranslator(s));
        _burnerFactory = burnerFactory ?? (() => new FFmpegBurner());
        var loaded = settings ?? AppSettings.Load();
        _maxConcurrentDownloads = loaded.MaxConcurrentDownloads;
        _maxConcurrentBurns = loaded.MaxConcurrentBurns;
        _downloadPool = new StageSlotPool(() => MaxConcurrentDownloads);
        _burnPool = new StageSlotPool(() => MaxConcurrentBurns);
        _translatePool = new StageSlotPool(() => 2);
    }

    /// <summary>设置保存后同步并发上限（setter 会唤醒排队者）。</summary>
    public void SyncConcurrency(AppSettings settings)
    {
        if (MaxConcurrentDownloads != settings.MaxConcurrentDownloads)
        {
            MaxConcurrentDownloads = settings.MaxConcurrentDownloads;
        }
        if (MaxConcurrentBurns != settings.MaxConcurrentBurns)
        {
            MaxConcurrentBurns = settings.MaxConcurrentBurns;
        }
    }

    // MARK: - 状态读取

    public IReadOnlyList<QueueItem> Items
    {
        get { lock (_lock) return [.. _items]; }
    }

    public QueueItem? Item(Guid id)
    {
        lock (_lock) return _items.FirstOrDefault(i => i.Id == id);
    }

    private int GenerationOf(Guid id)
    {
        lock (_lock) return _items.FirstOrDefault(i => i.Id == id)?.Generation ?? -1;
    }

    // MARK: - 槽位辅助

    /// <summary>等槽位（满员时先把状态文案改成等待提示），拿到后按代际登记为持有。</summary>
    private async Task AcquireSlotAsync(
        StageSlotPool pool, Guid id, int generation,
        TaskControlToken control, string waitingText, CancellationToken ct)
    {
        if (!pool.HasFreeSlot)
        {
            Update(id, generation, item => item.StatusText = waitingText);
        }
        await pool.AcquireAsync(id, control, respectPause: true, ct).ConfigureAwait(false);
        // 等待期间可能已被 retry 换代：旧代际拿到的槽立即归还，避免错记到新代际名下。
        if (GenerationOf(id) != generation)
        {
            pool.Release();
            throw VdlException.Cancelled();
        }
        lock (_lock) _holdingPool[id] = (generation, pool);
        Update(id, generation, item =>
        {
            if (item.StatusText == waitingText) item.StatusText = null;
        });
    }

    /// <summary>阶段结束（成功或失败）释放槽位；只释放本代际登记的，暂停已让位时自然空操作。</summary>
    private void ReleaseSlot(Guid id, int generation)
    {
        StageSlotPool? pool = null;
        lock (_lock)
        {
            if (_holdingPool.TryGetValue(id, out var holding) && holding.Generation == generation)
            {
                _holdingPool.Remove(id);
                pool = holding.Pool;
            }
        }
        pool?.Release();
    }

    private void WakeFromAllPools(Guid id)
    {
        _downloadPool.Wake(id);
        _burnPool.Wake(id);
        _translatePool.Wake(id);
    }

    // MARK: - 派生状态

    /// <summary>
    /// 未到终态的任务数（queued/downloading/translating/burning，含已暂停）。
    /// 关窗确认据此统计，避免「只剩暂停任务」时静默丢弃。
    /// </summary>
    public int OpenTaskCount
    {
        get { lock (_lock) return _items.Count(i => IsOpen(i.Stage.Kind)); }
    }

    /// <summary>其中处于暂停态的数量。</summary>
    public int PausedOpenTaskCount
    {
        get { lock (_lock) return _items.Count(i => i.IsPaused && IsOpen(i.Stage.Kind)); }
    }

    internal static bool IsOpen(ItemStageKind stage) => stage switch
    {
        ItemStageKind.Queued or ItemStageKind.Downloading
            or ItemStageKind.Translating or ItemStageKind.Burning => true,
        _ => false,
    };

    /// <summary>存在已到终态（done/failed/cancelled）的项，「清除已完成」入口据此显示。</summary>
    public bool HasFinishedItems
    {
        get { lock (_lock) return _items.Any(i => !IsOpen(i.Stage.Kind)); }
    }

    // MARK: - 入队

    /// <summary>去重键：优先 videoID，取不到用 sourceURL + formatID。</summary>
    internal static string DedupeKey(string videoId, string sourceUrl, string formatId)
    {
        var id = videoId.Trim();
        if (id.Length > 0 && id != "video") return "id:" + id;
        return "url:" + sourceUrl + "|" + formatId;
    }

    /// <summary>队列里是否已有同源且未到终态（非 done/failed/cancelled）的任务。</summary>
    public bool HasOpenDuplicate(string videoId, string sourceUrl, string formatId)
    {
        var key = DedupeKey(videoId, sourceUrl, formatId);
        lock (_lock)
        {
            return _items.Any(item =>
                IsOpen(item.Stage.Kind)
                && DedupeKey(item.Info.VideoId, item.Request.Url, item.Request.FormatId) == key);
        }
    }

    public Guid Enqueue(VideoInfo info, DownloadRequest request, ChineseSubtitleMode chineseMode, AppSettings settings)
    {
        var id = Guid.NewGuid();
        var item = new QueueItem
        {
            Id = id,
            Title = info.Title,
            ThumbnailUrl = info.ThumbnailUrl,
            Info = info,
            Request = request,
            ChineseMode = chineseMode,
            Settings = settings,
        };
        lock (_lock) _items.Add(item);
        ItemsChanged?.Invoke();
        var ct = item.Cts.Token;
        var task = Task.Run(() => RunPipelineAsync(id, skipDownload: false, ct), CancellationToken.None);
        lock (_lock) item.RunTask = task;
        return id;
    }

    // MARK: - 流水线

    /// <summary>跑完整条流水线。skipDownload=true 用于重试：已下载产物在 ResultFiles 里，跳过下载阶段。</summary>
    private async Task RunPipelineAsync(Guid id, bool skipDownload, CancellationToken ct)
    {
        var current = Item(id);
        if (current is null) return;
        var control = current.Control;
        var settings = current.Settings;
        var mode = current.ChineseMode;
        // 启动代际：每次写回前校验，作废重试后陈旧回调的写入。
        var generation = current.Generation;

        // 1. 下载
        List<string> downloadFiles;
        if (skipDownload)
        {
            downloadFiles = [.. current.ResultFiles];
        }
        else
        {
            try
            {
                await AcquireSlotAsync(_downloadPool, id, generation, control, L10n.T("排队中：等待下载空位", "Queued: waiting for a download slot"), ct).ConfigureAwait(false);
                try
                {
                    Update(id, generation, item =>
                    {
                        item.Stage = ItemStage.Downloading;
                        item.Progress = null;
                        item.StatusText = null;
                        item.IsPostDownloadProcessing = false;
                    });
                    var result = await _engine.DownloadAsync(
                        current.Request, control,
                        p => ApplyDownloadProgress(id, generation, p),
                        ct).ConfigureAwait(false);
                    if (GenerationOf(id) != generation) return;
                    downloadFiles = [.. result.Files];
                    Update(id, generation, item =>
                    {
                        item.ResultFiles = [.. result.Files];
                        item.Progress = null;
                    });
                }
                finally
                {
                    ReleaseSlot(id, generation);
                }
            }
            catch (Exception error)
            {
                if (GenerationOf(id) != generation) return;
                if (IsCancellation(error))
                {
                    Update(id, generation, item =>
                    {
                        item.Stage = ItemStage.Cancelled;
                        item.IsPaused = false;
                        item.Progress = null;
                        item.StatusText = L10n.T("已取消", "Cancelled");
                    });
                }
                else
                {
                    var reason = ShortReason(error);
                    Update(id, generation, item =>
                    {
                        item.Stage = ItemStage.Failed(reason);
                        item.IsPaused = false;
                        item.Progress = null;
                        item.StatusText = L10n.T($"失败：{reason}", $"Failed: {reason}");
                    });
                }
                return;
            }
        }

        // 下载完成，无需中文字幕：直接完成
        if (mode == ChineseSubtitleMode.Off)
        {
            FinishDone(id, generation, downloadFiles, null);
            return;
        }

        // 找翻译源字幕；没有就完成并提示已跳过
        var preferredLang = current.Request.SubtitleLangs.FirstOrDefault()
            ?? current.Request.AutoSubtitleLangs.FirstOrDefault();
        var srtFile = PickSourceSubtitle(downloadFiles, preferredLang);
        if (srtFile is null)
        {
            FinishDone(id, generation, downloadFiles, mode == ChineseSubtitleMode.BurnOriginal
                ? L10n.T("没有字幕文件，已跳过烧录", "No subtitle file; burn-in skipped")
                : L10n.T("没有字幕文件，已跳过翻译", "No subtitle file; translation skipped"));
            return;
        }

        // 直接烧录模式：跳过翻译，把所选源字幕原样压进视频（无论语言、无需配置翻译服务）。
        if (mode == ChineseSubtitleMode.BurnOriginal)
        {
            var rawVideo = downloadFiles.FirstOrDefault(f => VideoExtensions.Contains(ExtensionOf(f)));
            if (rawVideo is null)
            {
                FinishDone(id, generation, downloadFiles,
                    L10n.T("没有找到视频文件，已跳过烧录", "No video file found; burn-in skipped"));
                return;
            }
            try
            {
                await AcquireSlotAsync(_burnPool, id, generation, control,
                    L10n.T("排队中：等待压制空位", "Queued: waiting for an encoding slot"), ct).ConfigureAwait(false);
                try
                {
                    Update(id, generation, item =>
                    {
                        item.Stage = ItemStage.Burning;
                        item.Progress = null;
                        item.StatusText = L10n.T("直接烧录字幕（不翻译）", "Burning subtitle as-is (no translation)");
                    });
                    var burner = _burnerFactory();
                    var burned = await burner.BurnAsync(
                        rawVideo, srtFile, settings.MaxBurnHeight, control,
                        p => Update(id, generation, item =>
                        {
                            if (item.Stage.Kind != ItemStageKind.Burning) return;
                            item.Progress = p;
                        }),
                        outputTag: L10n.T("（字幕版）", " (subtitled)"),
                        ct: ct).ConfigureAwait(false);
                    if (GenerationOf(id) != generation) return;
                    Update(id, generation, item =>
                    {
                        var files = item.ResultFiles.Where(f => f != burned).ToList();
                        files.Insert(0, burned);
                        item.ResultFiles = files;
                    });
                    FinishDone(id, generation, Item(id)?.ResultFiles?.ToList() ?? downloadFiles,
                        L10n.T("已烧录字幕（未翻译）", "Subtitle burned in (no translation)"));
                }
                finally
                {
                    ReleaseSlot(id, generation);
                }
            }
            catch (Exception error)
            {
                if (GenerationOf(id) != generation) return;
                SettlePartial(id, generation, Item(id)?.ResultFiles?.ToList() ?? downloadFiles, error,
                    L10n.T("烧录", "burn-in"));
            }
            return;
        }

        // 成熟的中文软字幕：源字幕本身就是中文时直接当中文字幕用，跳过 LLM 翻译。
        // 判定优先用 request 里记录的 lang，回退按所选文件名 ".<lang>.srt" 解析。
        var sourceIsChinese = IsChineseLang(preferredLang) || IsChineseLang(LangCode(srtFile));
        if (sourceIsChinese)
        {
            // srtOnly：原中文 srt 即结果（已在 downloadFiles 里），不再生成 .zh.srt。
            if (mode != ChineseSubtitleMode.BurnIn)
            {
                FinishDone(id, generation, downloadFiles,
                    L10n.T("使用视频自带中文字幕，已跳过翻译", "Using built-in Chinese subtitle; translation skipped"));
                return;
            }
            // burnIn：直接拿原中文 srt 去烧录。
            var chineseVideo = downloadFiles.FirstOrDefault(f => VideoExtensions.Contains(ExtensionOf(f)));
            if (chineseVideo is null)
            {
                FinishDone(id, generation, downloadFiles,
                    L10n.T("没有找到视频文件，已跳过烧录", "No video file found; burn-in skipped"));
                return;
            }
            try
            {
                await AcquireSlotAsync(_burnPool, id, generation, control,
                    L10n.T("排队中：等待压制空位", "Queued: waiting for an encoding slot"), ct).ConfigureAwait(false);
                try
                {
                    Update(id, generation, item =>
                    {
                        item.Stage = ItemStage.Burning;
                        item.Progress = null;
                        item.StatusText = L10n.T("使用视频自带中文字幕，直接烧录（不翻译）",
                            "Built-in Chinese subtitle; burning directly (no translation)");
                    });
                    var burner = _burnerFactory();
                    var burned = await burner.BurnAsync(
                        chineseVideo, srtFile, settings.MaxBurnHeight, control,
                        p => Update(id, generation, item =>
                        {
                            if (item.Stage.Kind != ItemStageKind.Burning) return;
                            item.Progress = p;
                        }),
                        ct: ct).ConfigureAwait(false);
                    if (GenerationOf(id) != generation) return;
                    Update(id, generation, item =>
                    {
                        var files = item.ResultFiles.Where(f => f != burned).ToList();
                        files.Insert(0, burned);
                        item.ResultFiles = files;
                    });
                    FinishDone(id, generation, Item(id)?.ResultFiles?.ToList() ?? downloadFiles,
                        L10n.T("已烧录视频自带中文字幕", "Burned built-in Chinese subtitle"));
                }
                finally
                {
                    ReleaseSlot(id, generation);
                }
            }
            catch (Exception error)
            {
                if (GenerationOf(id) != generation) return;
                SettlePartial(id, generation, Item(id)?.ResultFiles?.ToList() ?? downloadFiles, error,
                    L10n.T("烧录", "burn-in"));
            }
            return;
        }

        // 2. 翻译
        string zhSrt;
        try
        {
            await AcquireSlotAsync(_translatePool, id, generation, control,
                L10n.T("排队中：等待翻译空位", "Queued: waiting for a translation slot"), ct).ConfigureAwait(false);
            try
            {
                Update(id, generation, item =>
                {
                    item.Stage = ItemStage.Translating;
                    item.Progress = null;
                    item.StatusText = null;
                });
                var translator = _translatorFactory(settings);
                zhSrt = await translator.TranslateAsync(
                    srtFile, settings.SubtitleStyle, control,
                    p => Update(id, generation, item =>
                    {
                        if (item.Stage.Kind != ItemStageKind.Translating) return;
                        item.Progress = p;
                    }),
                    ct).ConfigureAwait(false);
                if (GenerationOf(id) != generation) return;
                Update(id, generation, item =>
                {
                    item.Progress = null;
                    if (!item.ResultFiles.Contains(zhSrt))
                    {
                        item.ResultFiles = [.. item.ResultFiles, zhSrt];
                    }
                });
            }
            finally
            {
                ReleaseSlot(id, generation);
            }
        }
        catch (Exception error)
        {
            if (GenerationOf(id) != generation) return;
            SettlePartial(id, generation, downloadFiles, error, L10n.T("翻译", "translation"));
            return;
        }

        // 3. 烧录（仅 burnIn）
        if (mode != ChineseSubtitleMode.BurnIn)
        {
            FinishDone(id, generation, Item(id)?.ResultFiles?.ToList() ?? downloadFiles, null);
            return;
        }
        var video = downloadFiles.FirstOrDefault(f => VideoExtensions.Contains(ExtensionOf(f)));
        if (video is null)
        {
            FinishDone(id, generation, Item(id)?.ResultFiles?.ToList() ?? downloadFiles,
                L10n.T("没有找到视频文件，已跳过烧录", "No video file found; burn-in skipped"));
            return;
        }

        try
        {
            await AcquireSlotAsync(_burnPool, id, generation, control,
                L10n.T("排队中：等待压制空位", "Queued: waiting for an encoding slot"), ct).ConfigureAwait(false);
            try
            {
                Update(id, generation, item =>
                {
                    item.Stage = ItemStage.Burning;
                    item.Progress = null;
                    item.StatusText = null;
                });
                var burner = _burnerFactory();
                var burned = await burner.BurnAsync(
                    video, zhSrt, settings.MaxBurnHeight, control,
                    p => Update(id, generation, item =>
                    {
                        if (item.Stage.Kind != ItemStageKind.Burning) return;
                        item.Progress = p;
                    }),
                    ct: ct).ConfigureAwait(false);
                if (GenerationOf(id) != generation) return;
                Update(id, generation, item =>
                {
                    var files = item.ResultFiles.Where(f => f != burned).ToList();
                    files.Insert(0, burned);
                    item.ResultFiles = files;
                });
                FinishDone(id, generation, Item(id)?.ResultFiles?.ToList() ?? downloadFiles, null);
            }
            finally
            {
                ReleaseSlot(id, generation);
            }
        }
        catch (Exception error)
        {
            if (GenerationOf(id) != generation) return;
            SettlePartial(id, generation, Item(id)?.ResultFiles?.ToList() ?? downloadFiles, error,
                L10n.T("烧录", "burn-in"));
        }
    }

    /// <summary>
    /// 下载进度上报：转 0...1（processing 阶段进度不确定，置 null）。
    /// 节流：进度变化 &lt; 1% 时不写回，避免高频事件在长队列时拖累 UI。
    /// </summary>
    private void ApplyDownloadProgress(Guid id, int generation, DownloadProgress p)
    {
        Update(id, generation, item =>
        {
            // 进入烧录/翻译后不再被迟到的下载回调覆盖
            if (item.Stage.Kind != ItemStageKind.Downloading) return;
            switch (p.Phase)
            {
                case DownloadProgress.ProgressPhase.Downloading:
                    double? newValue = p.Percent is { } percent ? Math.Min(Math.Max(percent / 100, 0), 1) : null;
                    if (newValue is { } nv && item.Progress is { } old && nv < 1 && Math.Abs(nv - old) < 0.01)
                    {
                        return;
                    }
                    item.Progress = newValue;
                    item.IsPostDownloadProcessing = false;
                    break;
                case DownloadProgress.ProgressPhase.Preparing:
                case DownloadProgress.ProgressPhase.Finished:
                    item.Progress = null;
                    item.IsPostDownloadProcessing = false;
                    break;
                case DownloadProgress.ProgressPhase.Processing:
                    // 下载 100% 后的合并/转码：进度不确定，标记为「处理中」避免像卡死。
                    item.Progress = null;
                    item.IsPostDownloadProcessing = true;
                    break;
            }
        });
    }

    /// <summary>
    /// 部分成功：下载产物已落盘 → Done + 失败说明（可重试字幕处理）；否则视为 Failed。
    /// 取消 → Cancelled，保留已下产物。
    /// </summary>
    private void SettlePartial(Guid id, int generation, List<string> files, Exception error, string phase)
    {
        if (IsCancellation(error))
        {
            Update(id, generation, item =>
            {
                item.Stage = ItemStage.Cancelled;
                item.IsPaused = false;
                item.Progress = null;
                item.StatusText = files.Count == 0
                    ? L10n.T("已取消", "Cancelled")
                    : L10n.T("已取消，视频已保存", "Cancelled; downloaded video kept");
            });
            return;
        }
        var reason = ShortReason(error);
        if (files.Count > 0)
        {
            Update(id, generation, item =>
            {
                item.Stage = ItemStage.Done;
                item.IsPaused = false;
                item.Progress = null;
                item.PartialFailure = true;
                item.StatusText = L10n.T($"视频已下载，字幕{phase}失败：{reason}",
                    $"Video saved; subtitle {phase} failed: {reason}");
            });
        }
        else
        {
            Update(id, generation, item =>
            {
                item.Stage = ItemStage.Failed(reason);
                item.IsPaused = false;
                item.Progress = null;
                item.StatusText = L10n.T($"失败：{reason}", $"Failed: {reason}");
            });
        }
    }

    private void FinishDone(Guid id, int generation, List<string> files, string? statusText)
    {
        Update(id, generation, item =>
        {
            item.Stage = ItemStage.Done;
            item.IsPaused = false;
            item.Progress = null;
            item.PartialFailure = false;
            item.ResultFiles = files.Count == 0 ? item.ResultFiles : files;
            item.StatusText = statusText;
        });
    }

    // MARK: - 单项控制

    public void Pause(Guid id)
    {
        TaskControlToken control;
        StageSlotPool? releasePool = null;
        lock (_lock)
        {
            var target = _items.FirstOrDefault(i => i.Id == id);
            if (target is null || !IsOpen(target.Stage.Kind) || target.IsPaused) return;
            control = target.Control;
            // 让出占用的下载/压制槽位给其它任务；恢复时重新排队领取。
            if (_holdingPool.TryGetValue(id, out var holding) && holding.Generation == target.Generation)
            {
                _holdingPool.Remove(id);
                _resumePool[id] = holding;
                releasePool = holding.Pool;
            }
            target.IsPaused = true;
        }
        control.Pause();
        releasePool?.Release();
        ItemUpdated?.Invoke(id);
    }

    public void Resume(Guid id)
    {
        TaskControlToken control;
        int generation;
        CancellationToken ct;
        (int Generation, StageSlotPool Pool)? parked = null;
        lock (_lock)
        {
            var target = _items.FirstOrDefault(i => i.Id == id);
            if (target is null || !target.IsPaused) return;
            target.IsPaused = false;
            control = target.Control;
            generation = target.Generation;
            ct = target.Cts.Token;
            if (_resumePool.Remove(id, out var entry) && entry.Generation == generation)
            {
                parked = entry;
            }
        }
        if (parked is not { } parkedEntry)
        {
            // 没让过位（翻译阶段 / 排队中暂停）：直接恢复，acquire 循环或 gate 会接着走。
            control.Resume();
            ItemUpdated?.Invoke(id);
            return;
        }
        // 让过位的：先重新领到槽位再恢复进程，避免恢复瞬间超出并发上限。
        var resumeWaitingText = L10n.T("等待空位恢复…", "Waiting for a free slot to resume…");
        Update(id, generation, item => item.StatusText = resumeWaitingText);
        _ = Task.Run(async () =>
        {
            try
            {
                await parkedEntry.Pool.AcquireAsync(id, control, respectPause: false, ct).ConfigureAwait(false);
                if (GenerationOf(id) != generation)
                {
                    parkedEntry.Pool.Release();
                    return;
                }
                lock (_lock) _holdingPool[id] = (generation, parkedEntry.Pool);
                Update(id, generation, item =>
                {
                    if (item.StatusText == resumeWaitingText) item.StatusText = null;
                });
                control.Resume();
            }
            catch
            {
                // 等槽期间被取消：流水线任务自会收敛，这里不动状态。
            }
        }, CancellationToken.None);
    }

    public void Cancel(Guid id)
    {
        TaskControlToken control;
        CancellationTokenSource cts;
        lock (_lock)
        {
            var target = _items.FirstOrDefault(i => i.Id == id);
            if (target is null) return;
            _resumePool.Remove(id);
            control = target.Control;
            cts = target.Cts;
        }
        control.Cancel();
        cts.Cancel();
        // 还在排队等槽位的，唤出来让 acquire 循环抛出取消。
        WakeFromAllPools(id);
    }

    public void Remove(Guid id)
    {
        TaskControlToken control;
        CancellationTokenSource cts;
        lock (_lock)
        {
            var target = _items.FirstOrDefault(i => i.Id == id);
            if (target is null) return;
            _resumePool.Remove(id);
            control = target.Control;
            cts = target.Cts;
        }
        control.Cancel();
        cts.Cancel();
        WakeFromAllPools(id);
        lock (_lock) _items.RemoveAll(i => i.Id == id);
        ItemsChanged?.Invoke();
    }

    /// <summary>重试：保留已下载产物则跳过下载，仅重跑字幕处理；无产物则整条重跑。</summary>
    public void Retry(Guid id)
    {
        TaskControlToken oldControl;
        CancellationTokenSource oldCts;
        bool skipDownload;
        CancellationToken newCt;
        lock (_lock)
        {
            var old = _items.FirstOrDefault(i => i.Id == id);
            if (old is null) return;
            // 旧 control 若仍登记着进程，确保释放；清掉旧代际的槽位记账。
            _resumePool.Remove(id);
            oldControl = old.Control;
            oldCts = old.Cts;
            var hasVideo = old.ResultFiles.Any(f => VideoExtensions.Contains(ExtensionOf(f)));
            skipDownload = hasVideo && old.ChineseMode != ChineseSubtitleMode.Off;
            old.Control = new TaskControlToken();
            old.Cts = new CancellationTokenSource();
            old.Generation += 1;
            old.Stage = ItemStage.Queued;
            old.IsPaused = false;
            old.Progress = null;
            old.IsPostDownloadProcessing = false;
            old.PartialFailure = false;
            old.StatusText = skipDownload ? null : L10n.T("重新下载并处理", "Re-downloading and processing");
            if (!skipDownload) old.ResultFiles = [];
            newCt = old.Cts.Token;
        }
        oldControl.Cancel();
        oldCts.Cancel();
        WakeFromAllPools(id);
        ItemUpdated?.Invoke(id);
        var task = Task.Run(() => RunPipelineAsync(id, skipDownload, newCt), CancellationToken.None);
        lock (_lock)
        {
            var item = _items.FirstOrDefault(i => i.Id == id);
            if (item is not null) item.RunTask = task;
        }
    }

    /// <summary>一次移除所有已到终态（done/failed/cancelled）的项。</summary>
    public void ClearFinished()
    {
        lock (_lock) _items.RemoveAll(i => !IsOpen(i.Stage.Kind));
        ItemsChanged?.Invoke();
    }

    // MARK: - 工具

    /// <summary>代际校验版写回：仅当当前 Generation 与捕获值一致时才写回，作废重试后的陈旧回调。</summary>
    private void Update(Guid id, int generation, Action<QueueItem> mutate)
    {
        var changed = false;
        lock (_lock)
        {
            var item = _items.FirstOrDefault(i => i.Id == id);
            if (item is not null && item.Generation == generation)
            {
                mutate(item);
                changed = true;
            }
        }
        if (changed) ItemUpdated?.Invoke(id);
    }

    private static bool IsCancellation(Exception error) =>
        error is VdlException { Kind: VdlErrorKind.Cancelled } or OperationCanceledException;

    internal static string ShortReason(Exception error) => error switch
    {
        VdlException
        {
            Kind: VdlErrorKind.TranslateFailed or VdlErrorKind.BurnFailed or VdlErrorKind.DownloadFailed,
        } vdl => vdl.Detail,
        _ => error.Message,
    };

    private static string ExtensionOf(string path) =>
        Path.GetExtension(path).TrimStart('.').ToLowerInvariant();

    /// <summary>lang code 以 zh 开头视为中文（zh / zh-Hans / zh-Hant / zh-CN / zh-TW 等）。</summary>
    internal static bool IsChineseLang(string? lang)
    {
        if (string.IsNullOrEmpty(lang)) return false;
        var lower = lang.ToLowerInvariant();
        var prefix = lower.Split('-')[0];
        return prefix == "zh";
    }

    /// <summary>从字幕文件名 "&lt;名&gt;.&lt;lang&gt;.srt" 解析出 lang code（无法解析返回 null）。</summary>
    internal static string? LangCode(string file)
    {
        var stem = Path.GetFileNameWithoutExtension(file);
        var dotIndex = stem.LastIndexOf('.');
        if (dotIndex < 0) return null;
        return stem[(dotIndex + 1)..].ToLowerInvariant();
    }

    /// <summary>
    /// 按勾选语言挑翻译源字幕：大小写不敏感、允许前缀匹配。
    /// preferredLang 命中时直接返回该文件（含 ".zh.srt"，以支持视频自带中文字幕作为源）；
    /// 没有 preferredLang 时回退第一个非译文（不以 ".zh.srt" 结尾）的 .srt，避免把上次译文当源二次翻译。
    /// </summary>
    internal static string? PickSourceSubtitle(IReadOnlyList<string> files, string? preferredLang)
    {
        var srtFiles = files.Where(f => ExtensionOf(f) == "srt").ToList();
        if (preferredLang is { Length: > 0 })
        {
            var lang = preferredLang.ToLowerInvariant();
            var matched = srtFiles.FirstOrDefault(file =>
            {
                var code = LangCode(file);
                if (code is null) return false;
                return code == lang || code.StartsWith(lang + "-") || lang.StartsWith(code + "-");
            });
            if (matched is not null) return matched;
        }
        var nonTranslated = srtFiles
            .Where(f => !Path.GetFileName(f).ToLowerInvariant().EndsWith(".zh.srt"))
            .ToList();
        return nonTranslated.FirstOrDefault() ?? srtFiles.FirstOrDefault();
    }
}
