using Vdl.Core;

namespace VdlCore.Tests;

/// <summary>可由测试控制完成时机的 fake 下载引擎。</summary>
internal sealed class FakeEngine : IDownloadEngine
{
    internal sealed class Call
    {
        public required DownloadRequest Request { get; init; }
        public TaskControlToken? Control { get; init; }
        public required Action<DownloadProgress> Progress { get; init; }
        public TaskCompletionSource<DownloadResult> Tcs { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public void Complete(params string[] files) =>
            Tcs.TrySetResult(new DownloadResult { Files = files });

        public void Fail(Exception e) => Tcs.TrySetException(e);
    }

    private readonly object _lock = new();
    private readonly List<Call> _calls = [];

    public IReadOnlyList<Call> Calls
    {
        get { lock (_lock) return [.. _calls]; }
    }

    public Task<IReadOnlyList<VideoCandidate>> ResolveCandidatesAsync(string input, CancellationToken ct = default) =>
        throw new NotSupportedException();

    public Task<VideoInfo> AnalyzeAsync(string url, CancellationToken ct = default) =>
        throw new NotSupportedException();

    public async Task<DownloadResult> DownloadAsync(
        DownloadRequest request, TaskControlToken? control,
        Action<DownloadProgress> progress, CancellationToken ct = default)
    {
        var call = new Call { Request = request, Control = control, Progress = progress };
        lock (_lock) _calls.Add(call);
        // 与真实引擎一致：取消（杀进程）→ 抛 Cancelled
        await using var registration = ct.Register(() => call.Tcs.TrySetException(VdlException.Cancelled()));
        return await call.Tcs.Task;
    }
}

internal sealed class FakeTranslator : ISubtitleTranslator
{
    public int CallCount;
    public Func<string, string>? OnTranslate { get; set; }
    public Exception? ThrowOnTranslate { get; set; }

    public Task<string> TranslateAsync(
        string srtFile, SubtitleStyle style, TaskControlToken? control,
        Action<double> progress, CancellationToken ct = default)
    {
        Interlocked.Increment(ref CallCount);
        if (ThrowOnTranslate is { } e) return Task.FromException<string>(e);
        var output = OnTranslate?.Invoke(srtFile) ?? srtFile[..^4] + ".zh.srt";
        return Task.FromResult(output);
    }
}

internal sealed class FakeBurner : ISubtitleBurner
{
    public int CallCount;
    public List<(string Video, string Subtitle)> Burns { get; } = [];
    public string? LastOutputTag;

    public Task<string> BurnAsync(
        string video, string subtitle, int? maxHeight, TaskControlToken? control,
        Action<double> progress, string? outputTag = null, CancellationToken ct = default)
    {
        Interlocked.Increment(ref CallCount);
        LastOutputTag = outputTag;
        lock (Burns) Burns.Add((video, subtitle));
        return Task.FromResult(video[..^4] + "（中文字幕）.mp4");
    }
}

public class QueueManagerTests
{
    private static async Task WaitUntilAsync(Func<bool> condition, string what, int timeoutMs = 8000)
    {
        var start = Environment.TickCount64;
        while (!condition())
        {
            if (Environment.TickCount64 - start > timeoutMs)
            {
                throw new TimeoutException($"等待超时：{what}");
            }
            await Task.Delay(20);
        }
    }

    private static VideoInfo Info(string videoId = "vid1", string title = "Test") => new()
    {
        SourceUrl = $"https://example.com/{videoId}",
        VideoId = videoId,
        Title = title,
        Formats = [new FormatChoice { Id = "bv*+ba/b", Label = "1080p · mp4" }],
        Subtitles = [],
    };

    private static DownloadRequest Request(
        string videoId = "vid1", IReadOnlyList<string>? subtitleLangs = null) => new()
    {
        Url = $"https://example.com/{videoId}",
        VideoId = videoId,
        FormatId = "bv*+ba/b",
        SubtitleLangs = subtitleLangs ?? [],
        DestinationDirectory = "/tmp/downloads",
    };

    private static AppSettings Settings(int downloads = 1, int burns = 1) => new()
    {
        MaxConcurrentDownloads = downloads,
        MaxConcurrentBurns = burns,
    };

    /// <summary>并发槽上限：第二个任务等第一个释放下载槽后才开始。</summary>
    [Fact]
    public async Task DownloadSlots_LimitConcurrency()
    {
        var engine = new FakeEngine();
        var queue = new QueueManager(engine, settings: Settings(downloads: 1));

        var idA = queue.Enqueue(Info("a"), Request("a"), ChineseSubtitleMode.Off, Settings());
        await WaitUntilAsync(() => engine.Calls.Count == 1, "A 开始下载");
        var idB = queue.Enqueue(Info("b"), Request("b"), ChineseSubtitleMode.Off, Settings());

        // B 占不到槽：保持排队并提示等待
        await WaitUntilAsync(() => queue.Item(idB)?.StatusText == "排队中：等待下载空位", "B 显示排队中");
        Assert.Equal(ItemStageKind.Queued, queue.Item(idB)!.Stage.Kind);
        Assert.Single(engine.Calls);

        // A 完成 → B 自动开始
        engine.Calls[0].Complete("/tmp/downloads/a [a].mp4");
        await WaitUntilAsync(() => queue.Item(idA)?.Stage.Kind == ItemStageKind.Done, "A 完成");
        await WaitUntilAsync(() => engine.Calls.Count == 2, "B 开始下载");
        engine.Calls[1].Complete("/tmp/downloads/b [b].mp4");
        await WaitUntilAsync(() => queue.Item(idB)?.Stage.Kind == ItemStageKind.Done, "B 完成");
        Assert.Equal(new[] { "/tmp/downloads/b [b].mp4" }, queue.Item(idB)!.ResultFiles);
    }

    /// <summary>暂停让位：A 暂停后释放槽位，B 顶上；A 恢复时等空位再继续。</summary>
    [Fact]
    public async Task Pause_YieldsSlot_ResumeRequeues()
    {
        var engine = new FakeEngine();
        var queue = new QueueManager(engine, settings: Settings(downloads: 1));

        var idA = queue.Enqueue(Info("a"), Request("a"), ChineseSubtitleMode.Off, Settings());
        await WaitUntilAsync(() => engine.Calls.Count == 1, "A 开始下载");
        var idB = queue.Enqueue(Info("b"), Request("b"), ChineseSubtitleMode.Off, Settings());
        await WaitUntilAsync(() => queue.Item(idB)?.StatusText == "排队中：等待下载空位", "B 排队");

        // 暂停 A → 槽让给 B
        queue.Pause(idA);
        Assert.True(queue.Item(idA)!.IsPaused);
        await WaitUntilAsync(() => engine.Calls.Count == 2, "B 拿到槽开始下载");
        Assert.Equal(ItemStageKind.Downloading, queue.Item(idA)!.Stage.Kind);  // A 仍处下载阶段（被挂起）

        // 恢复 A：B 还占着槽 → A 等空位
        queue.Resume(idA);
        await WaitUntilAsync(() => queue.Item(idA)?.StatusText == "等待空位恢复…", "A 等空位");
        Assert.True(queue.Item(idA)!.Control.IsPaused);  // 槽没到手前进程保持挂起

        // B 完成 → A 重新领到槽并真正恢复
        engine.Calls[1].Complete("/tmp/downloads/b [b].mp4");
        await WaitUntilAsync(() => queue.Item(idB)?.Stage.Kind == ItemStageKind.Done, "B 完成");
        await WaitUntilAsync(() => queue.Item(idA)?.Control.IsPaused == false, "A 恢复运行");
        await WaitUntilAsync(() => queue.Item(idA)?.StatusText == null, "A 清除等待文案");

        engine.Calls[0].Complete("/tmp/downloads/a [a].mp4");
        await WaitUntilAsync(() => queue.Item(idA)?.Stage.Kind == ItemStageKind.Done, "A 完成");
    }

    /// <summary>取消唤醒：排队等槽位的任务被取消时立即收敛为已取消。</summary>
    [Fact]
    public async Task Cancel_WakesParkedWaiter()
    {
        var engine = new FakeEngine();
        var queue = new QueueManager(engine, settings: Settings(downloads: 1));

        var idA = queue.Enqueue(Info("a"), Request("a"), ChineseSubtitleMode.Off, Settings());
        await WaitUntilAsync(() => engine.Calls.Count == 1, "A 开始下载");
        var idB = queue.Enqueue(Info("b"), Request("b"), ChineseSubtitleMode.Off, Settings());
        await WaitUntilAsync(() => queue.Item(idB)?.StatusText == "排队中：等待下载空位", "B 排队");

        queue.Cancel(idB);
        await WaitUntilAsync(() => queue.Item(idB)?.Stage.Kind == ItemStageKind.Cancelled, "B 取消收敛");
        Assert.Equal("已取消", queue.Item(idB)!.StatusText);
        Assert.Single(engine.Calls);  // B 从未开始下载

        // A 不受影响
        engine.Calls[0].Complete("/tmp/downloads/a [a].mp4");
        await WaitUntilAsync(() => queue.Item(idA)?.Stage.Kind == ItemStageKind.Done, "A 完成");
    }

    /// <summary>代际守卫：retry 之后旧代际的进度/结果写回被丢弃。</summary>
    [Fact]
    public async Task GenerationGuard_StaleCallbacksDropped()
    {
        var engine = new FakeEngine();
        var queue = new QueueManager(engine, settings: Settings(downloads: 2));

        var id = queue.Enqueue(Info("a"), Request("a"), ChineseSubtitleMode.Off, Settings());
        await WaitUntilAsync(() => engine.Calls.Count == 1, "第一代开始下载");
        var oldCall = engine.Calls[0];

        // 重试（无产物 → 整条重跑，代际 +1）
        queue.Retry(id);
        await WaitUntilAsync(() => engine.Calls.Count == 2, "第二代开始下载");
        Assert.Equal(1, queue.Item(id)!.Generation);

        // 旧代际的进度回调被代际校验拦下
        oldCall.Progress(new DownloadProgress
        {
            Phase = DownloadProgress.ProgressPhase.Downloading,
            Percent = 55,
        });
        await Task.Delay(100);
        Assert.Null(queue.Item(id)!.Progress);

        // 旧代际的下载结果同样作废：状态仍由新代际主导
        oldCall.Complete("/tmp/downloads/stale [a].mp4");
        await Task.Delay(100);
        Assert.Equal(ItemStageKind.Downloading, queue.Item(id)!.Stage.Kind);
        Assert.Empty(queue.Item(id)!.ResultFiles);

        // 新代际正常完成
        engine.Calls[1].Complete("/tmp/downloads/fresh [a].mp4");
        await WaitUntilAsync(() => queue.Item(id)?.Stage.Kind == ItemStageKind.Done, "新代际完成");
        Assert.Equal(new[] { "/tmp/downloads/fresh [a].mp4" }, queue.Item(id)!.ResultFiles);
    }

    /// <summary>中文软字幕：源字幕是中文（zh-Hans）时跳过 LLM 翻译。</summary>
    [Fact]
    public async Task ChineseSourceSubtitle_SkipsTranslation()
    {
        var engine = new FakeEngine();
        var translator = new FakeTranslator();
        var queue = new QueueManager(engine, _ => translator, settings: Settings());

        var id = queue.Enqueue(
            Info("a"), Request("a", subtitleLangs: ["zh-Hans"]),
            ChineseSubtitleMode.SrtOnly, Settings());
        await WaitUntilAsync(() => engine.Calls.Count == 1, "开始下载");
        engine.Calls[0].Complete(
            "/tmp/downloads/v [a].mp4",
            "/tmp/downloads/v [a].zh-Hans.srt");

        await WaitUntilAsync(() => queue.Item(id)?.Stage.Kind == ItemStageKind.Done, "完成");
        Assert.Equal("使用视频自带中文字幕，已跳过翻译", queue.Item(id)!.StatusText);
        Assert.Equal(0, translator.CallCount);  // 从未调用翻译
        Assert.False(queue.Item(id)!.PartialFailure);
    }

    /// <summary>中文软字幕 + 烧录：直接拿原中文 srt 烧录，不经翻译。</summary>
    [Fact]
    public async Task ChineseSourceSubtitle_BurnIn_BurnsDirectly()
    {
        var engine = new FakeEngine();
        var translator = new FakeTranslator();
        var burner = new FakeBurner();
        var queue = new QueueManager(engine, _ => translator, () => burner, Settings());

        var id = queue.Enqueue(
            Info("a"), Request("a", subtitleLangs: ["zh"]),
            ChineseSubtitleMode.BurnIn, Settings());
        await WaitUntilAsync(() => engine.Calls.Count == 1, "开始下载");
        engine.Calls[0].Complete(
            "/tmp/downloads/v [a].mp4",
            "/tmp/downloads/v [a].zh.srt");

        await WaitUntilAsync(() => queue.Item(id)?.Stage.Kind == ItemStageKind.Done, "完成");
        Assert.Equal(0, translator.CallCount);
        Assert.Equal(1, burner.CallCount);
        Assert.Equal(("/tmp/downloads/v [a].mp4", "/tmp/downloads/v [a].zh.srt"), burner.Burns[0]);
        Assert.Equal("已烧录视频自带中文字幕", queue.Item(id)!.StatusText);
        // 烧录产物排在结果第一位
        Assert.Equal("/tmp/downloads/v [a]（中文字幕）.mp4", queue.Item(id)!.ResultFiles[0]);
    }

    /// <summary>partialFailure：视频已下载但翻译失败 → Done + 部分失败标记（可重试字幕处理）。</summary>
    [Fact]
    public async Task TranslateFails_AfterDownload_PartialFailure()
    {
        var engine = new FakeEngine();
        var translator = new FakeTranslator
        {
            ThrowOnTranslate = VdlException.TranslateFailed("接口超时"),
        };
        var queue = new QueueManager(engine, _ => translator, settings: Settings());

        var id = queue.Enqueue(
            Info("a"), Request("a", subtitleLangs: ["en"]),
            ChineseSubtitleMode.SrtOnly, Settings());
        await WaitUntilAsync(() => engine.Calls.Count == 1, "开始下载");
        engine.Calls[0].Complete(
            "/tmp/downloads/v [a].mp4",
            "/tmp/downloads/v [a].en.srt");

        await WaitUntilAsync(() => queue.Item(id)?.Stage.Kind == ItemStageKind.Done, "结算");
        var item = queue.Item(id)!;
        Assert.True(item.PartialFailure);
        Assert.Equal("视频已下载，字幕翻译失败：接口超时", item.StatusText);
        Assert.Contains("/tmp/downloads/v [a].mp4", item.ResultFiles);
    }

    /// <summary>下载本身失败（无产物）→ Failed。</summary>
    [Fact]
    public async Task DownloadFails_NoFiles_Failed()
    {
        var engine = new FakeEngine();
        var queue = new QueueManager(engine, settings: Settings());

        var id = queue.Enqueue(Info("a"), Request("a"), ChineseSubtitleMode.Off, Settings());
        await WaitUntilAsync(() => engine.Calls.Count == 1, "开始下载");
        engine.Calls[0].Fail(VdlException.DownloadFailed("网络中断"));

        await WaitUntilAsync(() => queue.Item(id)?.Stage.Kind == ItemStageKind.Failed, "失败收敛");
        var item = queue.Item(id)!;
        Assert.Equal("网络中断", item.Stage.FailureReason);
        Assert.Equal("失败：网络中断", item.StatusText);
    }

    /// <summary>无字幕文件时直接完成并提示跳过翻译。</summary>
    [Fact]
    public async Task NoSubtitleFile_SkipsTranslationWithNotice()
    {
        var engine = new FakeEngine();
        var translator = new FakeTranslator();
        var queue = new QueueManager(engine, _ => translator, settings: Settings());

        var id = queue.Enqueue(
            Info("a"), Request("a", subtitleLangs: ["en"]),
            ChineseSubtitleMode.SrtOnly, Settings());
        await WaitUntilAsync(() => engine.Calls.Count == 1, "开始下载");
        engine.Calls[0].Complete("/tmp/downloads/v [a].mp4");  // 只有视频

        await WaitUntilAsync(() => queue.Item(id)?.Stage.Kind == ItemStageKind.Done, "完成");
        Assert.Equal("没有字幕文件，已跳过翻译", queue.Item(id)!.StatusText);
        Assert.Equal(0, translator.CallCount);
    }

    /// <summary>翻译成功路径：译文加入产物列表。</summary>
    [Fact]
    public async Task TranslateSucceeds_ZhSrtAppended()
    {
        var engine = new FakeEngine();
        var translator = new FakeTranslator();
        var queue = new QueueManager(engine, _ => translator, settings: Settings());

        var id = queue.Enqueue(
            Info("a"), Request("a", subtitleLangs: ["en"]),
            ChineseSubtitleMode.SrtOnly, Settings());
        await WaitUntilAsync(() => engine.Calls.Count == 1, "开始下载");
        engine.Calls[0].Complete(
            "/tmp/downloads/v [a].mp4",
            "/tmp/downloads/v [a].en.srt");

        await WaitUntilAsync(() => queue.Item(id)?.Stage.Kind == ItemStageKind.Done, "完成");
        var item = queue.Item(id)!;
        Assert.Equal(1, translator.CallCount);
        Assert.Contains("/tmp/downloads/v [a].en.zh.srt", item.ResultFiles);
        Assert.False(item.PartialFailure);
        Assert.Null(item.StatusText);
    }

    [Fact]
    public void HasOpenDuplicate_MatchesByVideoId()
    {
        var engine = new FakeEngine();
        var queue = new QueueManager(engine, settings: Settings(downloads: 2));
        queue.Enqueue(Info("vidX"), Request("vidX"), ChineseSubtitleMode.Off, Settings());

        Assert.True(queue.HasOpenDuplicate("vidX", "https://other.url", "whatever"));  // videoID 优先
        Assert.False(queue.HasOpenDuplicate("vidY", "https://example.com/vidY", "f"));
    }

    [Fact]
    public void DedupeKey_FallsBackToUrlWhenNoVideoId()
    {
        Assert.Equal("id:abc", QueueManager.DedupeKey("abc", "u", "f"));
        // "video" 是引擎兜底 id，不可作去重键
        Assert.Equal("url:u|f", QueueManager.DedupeKey("video", "u", "f"));
        Assert.Equal("url:u|f", QueueManager.DedupeKey("  ", "u", "f"));
    }

    [Fact]
    public void PickSourceSubtitle_PreferredLangMatches_IncludingZh()
    {
        string[] files =
        [
            "/d/v [a].mp4",
            "/d/v [a].en.srt",
            "/d/v [a].zh.srt",
        ];
        // preferredLang 命中含 .zh.srt（自带中文字幕当源）
        Assert.Equal("/d/v [a].zh.srt", QueueManager.PickSourceSubtitle(files, "zh"));
        Assert.Equal("/d/v [a].en.srt", QueueManager.PickSourceSubtitle(files, "en"));
        // 前缀匹配：zh-Hans 请求命中 zh 文件
        Assert.Equal("/d/v [a].zh.srt", QueueManager.PickSourceSubtitle(files, "zh-Hans"));
        // 无 preferredLang → 第一个非译文 srt
        Assert.Equal("/d/v [a].en.srt", QueueManager.PickSourceSubtitle(files, null));
        // 只有译文时兜底返回它
        Assert.Equal("/d/v [a].zh.srt", QueueManager.PickSourceSubtitle(["/d/v [a].zh.srt"], null));
        Assert.Null(QueueManager.PickSourceSubtitle(["/d/v.mp4"], "en"));
    }

    [Fact]
    public void IsChineseLang_PrefixBased()
    {
        Assert.True(QueueManager.IsChineseLang("zh"));
        Assert.True(QueueManager.IsChineseLang("zh-Hans"));
        Assert.True(QueueManager.IsChineseLang("ZH-TW"));
        Assert.False(QueueManager.IsChineseLang("en"));
        Assert.False(QueueManager.IsChineseLang(null));
        Assert.False(QueueManager.IsChineseLang("zhx"));
    }

    /// <summary>直压模式：不翻译，把所选源字幕（非中文也行）原样烧录进视频。</summary>
    [Fact]
    public async Task BurnOriginalMode_BurnsSourceSubtitleWithoutTranslation()
    {
        var engine = new FakeEngine();
        var translator = new FakeTranslator();
        var burner = new FakeBurner();
        var queue = new QueueManager(engine, _ => translator, () => burner, Settings());

        var id = queue.Enqueue(
            Info("a"), Request("a", subtitleLangs: ["en"]),
            ChineseSubtitleMode.BurnOriginal, Settings());
        await WaitUntilAsync(() => engine.Calls.Count == 1, "开始下载");
        engine.Calls[0].Complete(
            "/tmp/downloads/v [a].mp4",
            "/tmp/downloads/v [a].en.srt");

        await WaitUntilAsync(() => queue.Item(id)?.Stage.Kind == ItemStageKind.Done, "完成");
        Assert.Equal(0, translator.CallCount);  // 全程不调翻译
        Assert.Equal(1, burner.CallCount);
        Assert.Equal(("/tmp/downloads/v [a].mp4", "/tmp/downloads/v [a].en.srt"), burner.Burns[0]);
        Assert.Equal("（字幕版）", burner.LastOutputTag);  // 直压输出名用「（字幕版）」标签
        Assert.Equal("已烧录字幕（未翻译）", queue.Item(id)!.StatusText);
        Assert.False(queue.Item(id)!.PartialFailure);
    }

    /// <summary>直压模式：没有字幕文件时跳过烧录并提示。</summary>
    [Fact]
    public async Task BurnOriginalMode_NoSubtitle_SkipsWithNotice()
    {
        var engine = new FakeEngine();
        var burner = new FakeBurner();
        var queue = new QueueManager(engine, burnerFactory: () => burner, settings: Settings());

        var id = queue.Enqueue(
            Info("a"), Request("a", subtitleLangs: ["en"]),
            ChineseSubtitleMode.BurnOriginal, Settings());
        await WaitUntilAsync(() => engine.Calls.Count == 1, "开始下载");
        engine.Calls[0].Complete("/tmp/downloads/v [a].mp4");

        await WaitUntilAsync(() => queue.Item(id)?.Stage.Kind == ItemStageKind.Done, "完成");
        Assert.Equal("没有字幕文件，已跳过烧录", queue.Item(id)!.StatusText);
        Assert.Equal(0, burner.CallCount);
    }

    /// <summary>直压模式：烧录失败 → 部分成功（视频已保存，可重试字幕处理）。</summary>
    [Fact]
    public async Task BurnOriginalMode_BurnFails_PartialFailure()
    {
        var engine = new FakeEngine();
        var burner = new ThrowingBurner(VdlException.BurnFailed("编码器崩溃"));
        var queue = new QueueManager(engine, burnerFactory: () => burner, settings: Settings());

        var id = queue.Enqueue(
            Info("a"), Request("a", subtitleLangs: ["en"]),
            ChineseSubtitleMode.BurnOriginal, Settings());
        await WaitUntilAsync(() => engine.Calls.Count == 1, "开始下载");
        engine.Calls[0].Complete(
            "/tmp/downloads/v [a].mp4",
            "/tmp/downloads/v [a].en.srt");

        await WaitUntilAsync(() => queue.Item(id)?.Stage.Kind == ItemStageKind.Done, "结算");
        var item = queue.Item(id)!;
        Assert.True(item.PartialFailure);
        Assert.Equal("视频已下载，字幕烧录失败：编码器崩溃", item.StatusText);
    }

    private sealed class ThrowingBurner(Exception error) : ISubtitleBurner
    {
        public Task<string> BurnAsync(
            string video, string subtitle, int? maxHeight, TaskControlToken? control,
            Action<double> progress, string? outputTag = null, CancellationToken ct = default) =>
            Task.FromException<string>(error);
    }

    [Fact]
    public async Task ClearFinished_RemovesOnlyTerminalItems()
    {
        var engine = new FakeEngine();
        var queue = new QueueManager(engine, settings: Settings(downloads: 2));
        var idDone = queue.Enqueue(Info("a"), Request("a"), ChineseSubtitleMode.Off, Settings());
        var idRunning = queue.Enqueue(Info("b"), Request("b"), ChineseSubtitleMode.Off, Settings());
        await WaitUntilAsync(() => engine.Calls.Count == 2, "两项都开始");
        // 两条流水线并发起跑，引擎调用顺序不定：按 videoId 匹配而非下标
        var callA = engine.Calls.First(c => c.Request.VideoId == "a");
        var callB = engine.Calls.First(c => c.Request.VideoId == "b");
        callA.Complete("/tmp/downloads/a [a].mp4");
        await WaitUntilAsync(() => queue.Item(idDone)?.Stage.Kind == ItemStageKind.Done, "A 完成");

        Assert.True(queue.HasFinishedItems);
        Assert.Equal(1, queue.OpenTaskCount);
        queue.ClearFinished();
        Assert.Null(queue.Item(idDone));
        Assert.NotNull(queue.Item(idRunning));

        callB.Complete("/tmp/downloads/b [b].mp4");
        await WaitUntilAsync(() => queue.Item(idRunning)?.Stage.Kind == ItemStageKind.Done, "B 完成");
    }
}
