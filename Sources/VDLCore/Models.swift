import Foundation

// MARK: - 错误

public enum VDLError: LocalizedError, Sendable {
    case binaryNotFound(String)
    case sniffFailed(String)
    case analyzeFailed(String)
    case downloadFailed(String)
    /// 站点风控/会员限制，需要用户在 App 内登录该站点后重试。关联值为站点 host（如 "youtube.com"）。
    case loginRequired(String)
    case translateFailed(String)
    case burnFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound(let name):
            return "找不到 \(name)。请确认已通过 Homebrew 安装（brew install \(name)）。"
        case .sniffFailed(let reason):
            return "没有在这个页面里找到可下载的视频。\(reason)"
        case .analyzeFailed(let reason):
            return "解析视频信息失败：\(reason)"
        case .downloadFailed(let reason):
            return "下载失败：\(reason)"
        case .loginRequired(let site):
            return "\(site) 需要登录后才能下载。点击「去登录」，在弹出的页面里登录账号后重试。"
        case .translateFailed(let reason):
            return "字幕翻译失败：\(reason)"
        case .burnFailed(let reason):
            return "字幕烧录失败：\(reason)"
        case .cancelled:
            return "已取消"
        }
    }
}

// MARK: - 链接解析候选

/// 一条用户粘贴的链接背后可能藏着多个视频（例如页面主视频 + 内嵌的 YouTube 轮播）。
/// `resolveCandidates` 把它们全部找出来，交给用户选择。
public struct VideoCandidate: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case pageMain    // 页面的主视频（直链文件等）
        case directFile  // 直链视频文件（mp4 / m3u8 / webm …）
        case youtube     // 内嵌 YouTube 视频
        case vimeo       // 内嵌 Vimeo 视频
        case supported   // yt-dlp 原生支持的链接（无需嗅探）
    }

    /// 稳定标识：解析后的最终 URL 字符串
    public var id: String { url }
    /// 交给 `analyze(url:)` 的 URL
    public let url: String
    public let kind: Kind
    /// 尽力获取的标题（YouTube 走 oEmbed；直链用文件名；主视频用页面标题）
    public var title: String
    /// 补充说明，例如 "assets.nintendo.com · mp4 直链" 或 "YouTube"
    public var detail: String?

    public init(url: String, kind: Kind, title: String, detail: String? = nil) {
        self.url = url
        self.kind = kind
        self.title = title
        self.detail = detail
    }
}

// MARK: - 解析结果

public struct FormatChoice: Identifiable, Hashable, Sendable {
    /// yt-dlp 的 -f 格式选择串（例如 "bv*[height<=720]+ba/b[height<=720]"），
    /// 音频选项用特殊值 "audio"（引擎据此改用 -x 提取音频）。
    public let id: String
    /// 例如 "1080p · mp4" / "原始文件 · mp4" / "仅音频 · m4a"
    public let label: String
    /// 例如 "≈ 42 MB"、编码信息；未知则为 nil
    public let detail: String?
    public let isAudioOnly: Bool

    public init(id: String, label: String, detail: String? = nil, isAudioOnly: Bool = false) {
        self.id = id
        self.label = label
        self.detail = detail
        self.isAudioOnly = isAudioOnly
    }
}

public struct SubtitleChoice: Identifiable, Hashable, Sendable {
    /// 语言代码，如 "en"、"zh-Hans"
    public let id: String
    /// 中文展示名，如 "英文 (en)"
    public let label: String
    /// 是否为自动生成字幕（YouTube 自动字幕等）
    public let isAuto: Bool

    public init(id: String, label: String, isAuto: Bool) {
        self.id = id
        self.label = label
        self.isAuto = isAuto
    }
}

public struct VideoInfo: Sendable {
    public let sourceURL: String
    /// yt-dlp 信息里的视频 id（用于定位产出文件）
    public let videoID: String
    public let title: String
    /// 形如 "2:31"；未知为 nil
    public let durationText: String?
    public let thumbnailURL: URL?
    public let uploader: String?
    /// 按推荐顺序排列（第一个为推荐档），保证至少一个元素
    public let formats: [FormatChoice]
    /// 真实字幕在前、自动字幕在后；可能为空
    public let subtitles: [SubtitleChoice]

    public init(
        sourceURL: String, videoID: String, title: String,
        durationText: String?, thumbnailURL: URL?, uploader: String?,
        formats: [FormatChoice], subtitles: [SubtitleChoice]
    ) {
        self.sourceURL = sourceURL
        self.videoID = videoID
        self.title = title
        self.durationText = durationText
        self.thumbnailURL = thumbnailURL
        self.uploader = uploader
        self.formats = formats
        self.subtitles = subtitles
    }
}

// MARK: - 下载

public struct DownloadRequest: Sendable {
    public let url: String
    /// 视频 id（来自 VideoInfo.videoID），用于在目标目录中识别产出文件
    public let videoID: String
    /// FormatChoice.id
    public let formatID: String
    /// 选中的真实字幕语言代码
    public let subtitleLangs: [String]
    /// 选中的自动字幕语言代码
    public let autoSubtitleLangs: [String]
    public let destinationDirectory: URL
    /// 期望的文件名标题。直链/页面主视频的 yt-dlp 标题往往是 CDN 文件名
    /// （如 "homepage_trailer"），此时用嗅探得到的页面标题命名更友好；nil 用 yt-dlp 默认标题。
    public let preferredTitle: String?

    public init(
        url: String, videoID: String, formatID: String,
        subtitleLangs: [String], autoSubtitleLangs: [String],
        destinationDirectory: URL, preferredTitle: String? = nil
    ) {
        self.url = url
        self.videoID = videoID
        self.formatID = formatID
        self.subtitleLangs = subtitleLangs
        self.autoSubtitleLangs = autoSubtitleLangs
        self.destinationDirectory = destinationDirectory
        self.preferredTitle = preferredTitle
    }
}

public struct DownloadProgress: Sendable {
    public enum Phase: Sendable, Equatable {
        case preparing      // 启动 yt-dlp、握手中
        case downloading    // 主体下载
        case processing     // 合并 / 转码 / 字幕转换
        case finished
    }

    public let phase: Phase
    /// 0...100；未知为 nil
    public let percent: Double?
    public let speedText: String?
    public let etaText: String?

    public init(phase: Phase, percent: Double? = nil, speedText: String? = nil, etaText: String? = nil) {
        self.phase = phase
        self.percent = percent
        self.speedText = speedText
        self.etaText = etaText
    }
}

public struct DownloadResult: Sendable {
    /// 实际写入磁盘的文件（视频 + 字幕）
    public let files: [URL]

    public init(files: [URL]) {
        self.files = files
    }
}

// MARK: - 中文字幕（翻译与烧录）

/// 烧录/输出字幕的样式
public enum SubtitleStyle: String, Codable, Sendable {
    /// 原文在上、中文在下
    case bilingual
    /// 仅中文
    case chineseOnly
}

/// 一条 SRT 字幕
public struct SubtitleCue: Sendable {
    public let index: Int
    /// SRT 原始时间戳，如 "00:01:02,500"
    public let start: String
    public let end: String
    public var text: String

    public init(index: Int, start: String, end: String, text: String) {
        self.index = index
        self.start = start
        self.end = end
        self.text = text
    }
}

/// 字幕翻译器。默认实现 `ConfiguredTranslator`（Translator.swift）：
/// 按设置选择 Anthropic/DeepSeek Messages API 或 OpenAI Responses API 调用配置的模型。
/// 用 `makeTranslator(settings:)` 获取实例。
public protocol SubtitleTranslator: Sendable {
    /// 把 srt 文件翻译成中文，按 style 生成新 srt（双语：中文在上原文在下；仅中文：替换原文），
    /// 写到 srt 同目录、文件名加 ".zh" 后缀；progress 为 0...1。
    /// YouTube 自动字幕的重叠滚动碎句会先被清洗、按句合并再翻译。
    /// control 非空时支持暂停（分块间挂起）与取消；失败抛 VDLError.translateFailed。
    func translate(
        srtFile: URL,
        style: SubtitleStyle,
        control: TaskControlToken?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL
}

public extension SubtitleTranslator {
    func translate(
        srtFile: URL,
        style: SubtitleStyle,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try await translate(srtFile: srtFile, style: style, control: nil, progress: progress)
    }
}

/// 字幕烧录器。默认实现 `FFmpegBurner`（Burner.swift）：ffmpeg subtitles 滤镜硬烧录。
/// 用 `makeBurner()` 获取实例。
public protocol SubtitleBurner: Sendable {
    /// 把 subtitle 烧录进 video，输出 "<原名>（中文字幕).mp4" 风格的新文件（不覆盖原片）；
    /// maxHeight 非空且源更高时缩放到该高度；progress 为 0...1。
    /// control 非空时支持暂停/取消（向 ffmpeg 进程树发 SIGSTOP/SIGCONT、取消时终止）。
    /// 失败抛 VDLError.burnFailed。
    func burn(
        video: URL,
        subtitle: URL,
        maxHeight: Int?,
        control: TaskControlToken?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL
}

public extension SubtitleBurner {
    func burn(
        video: URL,
        subtitle: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try await burn(video: video, subtitle: subtitle, maxHeight: nil, control: nil, progress: progress)
    }
}

// MARK: - 引擎协议

/// 三步流水线：resolve（一条链接里找出所有视频）→ analyze（取格式与字幕）→ download。
/// 实现位于 Engine.swift 的 `YtDlpEngine`；用 `makeDefaultEngine()` 获取默认实例。
public protocol DownloadEngine: Sendable {
    /// 第一步：解析用户粘贴的链接。
    /// - yt-dlp 原生支持的 URL：直接返回单个 `.supported` 候选（不发起网络请求也可以）。
    /// - 不支持的页面：抓取 HTML 嗅探内嵌视频（og:video、video/source 标签、
    ///   YouTube/Vimeo iframe、data-videoid、裸 mp4/m3u8 链接等），返回带标题的候选列表。
    /// - 一个都找不到时抛 `VDLError.sniffFailed`。
    func resolveCandidates(for input: String) async throws -> [VideoCandidate]

    /// 第二步：完整解析单个候选，返回格式与字幕选项。
    /// 实现可以缓存第一步已经取得的信息避免重复请求。
    func analyze(url: String) async throws -> VideoInfo

    /// 第三步：按用户选择下载。进度经回调上报（任意线程）；
    /// control 非空时支持暂停（SIGSTOP/SIGCONT 进程树）与取消；
    /// 也可通过 Swift 任务取消中止，引擎需负责终止子进程、不留僵尸进程。
    func download(
        _ request: DownloadRequest,
        control: TaskControlToken?,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadResult
}

public extension DownloadEngine {
    func download(
        _ request: DownloadRequest,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadResult {
        try await download(request, control: nil, progress: progress)
    }
}
