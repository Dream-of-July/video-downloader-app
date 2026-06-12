namespace Vdl.Core;

// MARK: - 错误

/// <summary>错误种类。与 Swift 版 VDLError 各 case 一一对应。</summary>
public enum VdlErrorKind
{
    BinaryNotFound,
    SniffFailed,
    AnalyzeFailed,
    DownloadFailed,
    /// <summary>站点风控/会员限制，需要用户在 App 内登录该站点后重试。Detail 为站点 host（如 "youtube.com"）。</summary>
    LoginRequired,
    TranslateFailed,
    BurnFailed,
    Cancelled,
}

/// <summary>
/// 统一业务异常。中文消息与 Swift 版保持一致（BinaryNotFound 例外：Windows 没有 Homebrew，
/// 改为指引用户重新下载依赖组件，由 DependencyManager 负责落地）。
/// </summary>
public sealed class VdlException : Exception
{
    public VdlErrorKind Kind { get; }
    /// <summary>原因文本或站点 host（LoginRequired 时）。</summary>
    public string Detail { get; }

    private VdlException(VdlErrorKind kind, string detail, string message) : base(message)
    {
        Kind = kind;
        Detail = detail;
    }

    public static VdlException BinaryNotFound(string name) => new(
        VdlErrorKind.BinaryNotFound, name,
        L10n.T($"找不到 {name}。请在「设置」里重新下载依赖组件后重试。",
            $"Could not find {name}. Re-download the components in Settings and try again."));

    public static VdlException SniffFailed(string reason) => new(
        VdlErrorKind.SniffFailed, reason,
        L10n.T($"没有在这个页面里找到可下载的视频。{reason}",
            $"No downloadable video was found on this page. {reason}"));

    public static VdlException AnalyzeFailed(string reason) => new(
        VdlErrorKind.AnalyzeFailed, reason,
        L10n.T($"解析视频信息失败：{reason}", $"Failed to analyze the video: {reason}"));

    public static VdlException DownloadFailed(string reason) => new(
        VdlErrorKind.DownloadFailed, reason,
        L10n.T($"下载失败：{reason}", $"Download failed: {reason}"));

    public static VdlException LoginRequired(string site) => new(
        VdlErrorKind.LoginRequired, site,
        L10n.T($"{site} 需要登录后才能下载。点击「去登录」，在弹出的页面里登录账号后重试。",
            $"{site} requires sign-in before downloading. Click \"Sign in\", log in on the page that opens, then retry."));

    public static VdlException TranslateFailed(string reason) => new(
        VdlErrorKind.TranslateFailed, reason,
        L10n.T($"字幕翻译失败：{reason}", $"Subtitle translation failed: {reason}"));

    public static VdlException BurnFailed(string reason) => new(
        VdlErrorKind.BurnFailed, reason,
        L10n.T($"字幕烧录失败：{reason}", $"Subtitle burn-in failed: {reason}"));

    public static VdlException Cancelled() => new(
        VdlErrorKind.Cancelled, "", L10n.T("已取消", "Cancelled"));
}

// MARK: - 链接解析候选

/// <summary>
/// 一条用户粘贴的链接背后可能藏着多个视频（例如页面主视频 + 内嵌的 YouTube 轮播）。
/// ResolveCandidatesAsync 把它们全部找出来，交给用户选择。
/// </summary>
public sealed record VideoCandidate
{
    public enum CandidateKind
    {
        PageMain,    // 页面的主视频（直链文件等）
        DirectFile,  // 直链视频文件（mp4 / m3u8 / webm …）
        Youtube,     // 内嵌 YouTube 视频
        Vimeo,       // 内嵌 Vimeo 视频
        Supported,   // yt-dlp 原生支持的链接（无需嗅探）
    }

    /// <summary>交给 AnalyzeAsync 的 URL（同时作为稳定标识）。</summary>
    public required string Url { get; init; }
    public required CandidateKind Kind { get; init; }
    /// <summary>尽力获取的标题（YouTube 走 oEmbed；直链用文件名；主视频用页面标题）。</summary>
    public required string Title { get; init; }
    /// <summary>补充说明，例如 "assets.nintendo.com · mp4 直链" 或 "YouTube"。</summary>
    public string? Detail { get; init; }
}

// MARK: - 解析结果

public sealed record FormatChoice
{
    /// <summary>
    /// yt-dlp 的 -f 格式选择串（例如 "bv*[height&lt;=720]+ba/b[height&lt;=720]"），
    /// 音频选项用特殊值 "audio"（引擎据此改用 -x 提取音频）。
    /// </summary>
    public required string Id { get; init; }
    /// <summary>例如 "1080p · mp4" / "原始文件 · mp4" / "仅音频 · m4a"。</summary>
    public required string Label { get; init; }
    /// <summary>例如 "≈ 42 MB"、编码信息；未知则为 null。</summary>
    public string? Detail { get; init; }
    public bool IsAudioOnly { get; init; }
}

public sealed record SubtitleChoice
{
    /// <summary>语言代码，如 "en"、"zh-Hans"。</summary>
    public required string Id { get; init; }
    /// <summary>中文展示名，如 "英语 (en)"。</summary>
    public required string Label { get; init; }
    /// <summary>是否为自动生成字幕（YouTube 自动字幕等）。</summary>
    public required bool IsAuto { get; init; }
}

public sealed record VideoInfo
{
    public required string SourceUrl { get; init; }
    /// <summary>yt-dlp 信息里的视频 id（用于定位产出文件）。</summary>
    public required string VideoId { get; init; }
    public required string Title { get; init; }
    /// <summary>形如 "2:31"；未知为 null。</summary>
    public string? DurationText { get; init; }
    public string? ThumbnailUrl { get; init; }
    public string? Uploader { get; init; }
    /// <summary>按推荐顺序排列（第一个为推荐档），保证至少一个元素。</summary>
    public required IReadOnlyList<FormatChoice> Formats { get; init; }
    /// <summary>真实字幕在前、自动字幕在后；可能为空。</summary>
    public required IReadOnlyList<SubtitleChoice> Subtitles { get; init; }
}

// MARK: - 下载

public sealed record DownloadRequest
{
    public required string Url { get; init; }
    /// <summary>视频 id（来自 VideoInfo.VideoId），用于在目标目录中识别产出文件。</summary>
    public required string VideoId { get; init; }
    /// <summary>FormatChoice.Id。</summary>
    public required string FormatId { get; init; }
    /// <summary>选中的真实字幕语言代码。</summary>
    public IReadOnlyList<string> SubtitleLangs { get; init; } = [];
    /// <summary>选中的自动字幕语言代码。</summary>
    public IReadOnlyList<string> AutoSubtitleLangs { get; init; } = [];
    public required string DestinationDirectory { get; init; }
    /// <summary>
    /// 期望的文件名标题。直链/页面主视频的 yt-dlp 标题往往是 CDN 文件名
    /// （如 "homepage_trailer"），此时用嗅探得到的页面标题命名更友好；null 用 yt-dlp 默认标题。
    /// </summary>
    public string? PreferredTitle { get; init; }
}

public sealed record DownloadProgress
{
    public enum ProgressPhase
    {
        Preparing,      // 启动 yt-dlp、握手中
        Downloading,    // 主体下载
        Processing,     // 合并 / 转码 / 字幕转换
        Finished,
    }

    public required ProgressPhase Phase { get; init; }
    /// <summary>0...100；未知为 null。</summary>
    public double? Percent { get; init; }
    public string? SpeedText { get; init; }
    public string? EtaText { get; init; }
}

public sealed record DownloadResult
{
    /// <summary>实际写入磁盘的文件（视频 + 字幕），绝对路径。</summary>
    public required IReadOnlyList<string> Files { get; init; }
}

// MARK: - 中文字幕（翻译与烧录）

/// <summary>烧录/输出字幕的样式。JSON 序列化值与 Swift 版一致（bilingual / chineseOnly）。</summary>
public enum SubtitleStyle
{
    /// <summary>中文在上、原文在下。</summary>
    Bilingual,
    /// <summary>仅中文。</summary>
    ChineseOnly,
}

/// <summary>一条 SRT 字幕。</summary>
public sealed class SubtitleCue
{
    public int Index { get; }
    /// <summary>SRT 原始时间戳，如 "00:01:02,500"。</summary>
    public string Start { get; }
    public string End { get; }
    public string Text { get; set; }

    public SubtitleCue(int index, string start, string end, string text)
    {
        Index = index;
        Start = start;
        End = end;
        Text = text;
    }
}

// MARK: - 接口

/// <summary>
/// 三步流水线：Resolve（一条链接里找出所有视频）→ Analyze（取格式与字幕）→ Download。
/// 默认实现 YtDlpEngine（Engine.cs）。
/// </summary>
public interface IDownloadEngine
{
    /// <summary>
    /// 第一步：解析用户粘贴的链接。
    /// yt-dlp 原生支持的 URL 直接返回单个 Supported 候选；不支持的页面抓取 HTML 嗅探内嵌视频；
    /// 一个都找不到时抛 SniffFailed。
    /// </summary>
    Task<IReadOnlyList<VideoCandidate>> ResolveCandidatesAsync(string input, CancellationToken ct = default);

    /// <summary>第二步：完整解析单个候选，返回格式与字幕选项。实现可缓存第一步信息避免重复请求。</summary>
    Task<VideoInfo> AnalyzeAsync(string url, CancellationToken ct = default);

    /// <summary>
    /// 第三步：按用户选择下载。进度经回调上报（任意线程）；
    /// control 非空时支持暂停（挂起进程树）与取消；引擎需负责终止子进程、不留僵尸进程。
    /// </summary>
    Task<DownloadResult> DownloadAsync(
        DownloadRequest request,
        TaskControlToken? control,
        Action<DownloadProgress> progress,
        CancellationToken ct = default);
}

/// <summary>
/// 字幕翻译器。默认实现 ConfiguredTranslator（Translator.cs）：
/// 按设置选择 Anthropic Messages API 或 OpenAI Responses API 调用配置的模型。
/// </summary>
public interface ISubtitleTranslator
{
    /// <summary>
    /// 把 srt 文件翻译成中文，按 style 生成新 srt（双语：中文在上原文在下；仅中文：替换原文），
    /// 写到 srt 同目录、文件名加 ".zh" 后缀；progress 为 0...1。
    /// YouTube 自动字幕的重叠滚动碎句会先被清洗、按句合并再翻译。
    /// control 非空时支持暂停（分块间挂起）与取消；失败抛 TranslateFailed。返回译文文件路径。
    /// </summary>
    Task<string> TranslateAsync(
        string srtFile,
        SubtitleStyle style,
        TaskControlToken? control,
        Action<double> progress,
        CancellationToken ct = default);
}

/// <summary>字幕烧录器。默认实现 FFmpegBurner（Burner.cs）：ffmpeg subtitles 滤镜硬烧录。</summary>
public interface ISubtitleBurner
{
    /// <summary>
    /// 把 subtitle 烧录进 video，输出 "&lt;原名&gt;（中文字幕）.mp4" 风格的新文件（不覆盖原片）；
    /// outputTag 自定义文件名后缀标签（null 用默认「（中文字幕）」；直压原文字幕模式传「（字幕版）」）；
    /// maxHeight 非空且源更高时缩放到该高度；progress 为 0...1。
    /// control 非空时支持暂停/取消（挂起/终止 ffmpeg 进程树）。失败抛 BurnFailed。返回输出文件路径。
    /// </summary>
    Task<string> BurnAsync(
        string video,
        string subtitle,
        int? maxHeight,
        TaskControlToken? control,
        Action<double> progress,
        string? outputTag = null,
        CancellationToken ct = default);
}
