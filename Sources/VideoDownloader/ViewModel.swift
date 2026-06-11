import AppKit
import Combine
import Foundation
#if canImport(VDLCore)
import VDLCore
#endif

/// 中文字幕处理方式（ready 页「中文字幕」分组的三个选项）
enum ChineseSubtitleMode: String, CaseIterable {
    case off
    case srtOnly
    case burnIn

    var label: String {
        switch self {
        case .off: return "不需要"
        case .srtOnly: return "只生成中文字幕文件"
        case .burnIn: return "翻译并烧录进视频"
        }
    }
}

@MainActor
final class ViewModel: ObservableObject {

    enum Stage {
        case idle
        case resolving
        case choosing([VideoCandidate])
        case analyzing
        case ready(VideoInfo)
        case downloading(VideoInfo)
        case translating(VideoInfo)
        case burning(VideoInfo)
        case done(VideoInfo, DownloadResult)
        case failed(String)
    }

    @Published var urlText: String = ""
    @Published var stage: Stage = .idle
    @Published var selectedFormatID: String?
    @Published var selectedSubtitleIDs: Set<String> = [] {
        didSet {
            // 中文字幕依赖至少勾选一条字幕；全部取消勾选时强制回「不需要」
            if selectedSubtitleIDs.isEmpty, chineseMode != .off {
                chineseMode = .off
            }
        }
    }
    @Published var progress: DownloadProgress?
    /// 翻译 / 烧录阶段的进度（0...1）；nil 表示不确定
    @Published var pipelineProgress: Double?
    @Published var chineseMode: ChineseSubtitleMode = .off
    @Published var settings = AppSettings.load()
    @Published var showSettings = false
    /// 非 nil 时弹出站点登录窗（值为站点 host，如 "youtube.com"）
    @Published var loginSite: String?
    /// 失败原因是需要登录时记录站点，failed 页据此把主按钮换成「去登录」
    @Published var failedNeedsLogin: String?
    /// done 页的一行灰字提示（如「没有字幕文件，已跳过翻译」）
    @Published var doneNotice: String?
    /// 设置窗里的提示（保存失败 / 请先配置翻译服务）
    @Published var settingsNotice: String?

    private let engine: any DownloadEngine
    private var downloadTask: Task<Void, Never>?
    private var parseTask: Task<Void, Never>?
    private var candidates: [VideoCandidate] = []
    private var chosenCandidate: VideoCandidate?
    private var retryAction: (@MainActor () -> Void)?
    /// 设置窗里点了「登录 ××」：先收起设置 sheet，再由其 onDismiss 弹出登录窗
    private var pendingLoginSite: String?
    /// 本次流水线烧录出的视频；revealInFinder 优先选中它
    private var burnedVideoURL: URL?
    /// 代际令牌：reset / 取消后，旧任务的回调全部作废
    private var session = 0
    /// 进度单调化：记录最近相位与百分比，丢弃回退事件
    private var lastProgressPhase: DownloadProgress.Phase?
    private var lastProgressPercent: Double?

    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "mkv", "webm", "m4v", "avi", "flv", "ts",
    ]

    init(engine: any DownloadEngine = makeDefaultEngine()) {
        self.engine = engine
    }

    // MARK: - 派生状态

    var isParsing: Bool {
        switch stage {
        case .resolving, .analyzing: return true
        default: return false
        }
    }

    /// 下载流水线（下载 / 翻译 / 烧录）是否进行中；关窗确认与输入禁用都依赖它
    var isDownloadingStage: Bool {
        switch stage {
        case .downloading, .translating, .burning: return true
        default: return false
        }
    }

    var canReturnToList: Bool { candidates.count > 1 }

    // MARK: - 行为

    func onAppear() {
        prefillFromClipboardIfAppropriate()
    }

    /// 视图出现或 App 激活时：处于可输入阶段且输入框为空，用剪贴板里的链接预填（不自动解析）。
    func prefillFromClipboardIfAppropriate() {
        switch stage {
        case .idle, .done:
            break
        default:
            return
        }
        guard urlText.isEmpty else { return }
        guard let clip = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            clip.lowercased().hasPrefix("http") else { return }
        urlText = clip
    }

    func parse() {
        let input = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !isParsing, !isDownloadingStage else { return }
        guard let url = URL(string: input),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            session += 1
            retryAction = nil
            failedNeedsLogin = nil
            stage = .failed("这不是一个网址。请粘贴以 http 或 https 开头的视频链接。")
            return
        }
        session += 1
        let token = session
        retryAction = nil
        failedNeedsLogin = nil
        stage = .resolving
        chosenCandidate = nil
        parseTask = Task {
            do {
                let found = try await self.engine.resolveCandidates(for: input)
                guard token == self.session else { return }
                guard !found.isEmpty else { throw VDLError.sniffFailed("") }
                self.candidates = found
                if found.count == 1 {
                    self.choose(found[0])
                } else {
                    self.stage = .choosing(found)
                }
            } catch {
                guard token == self.session else { return }
                self.fail(error) { [weak self] in self?.parse() }
            }
        }
    }

    func cancelParse() {
        switch stage {
        case .resolving:
            session += 1
            parseTask?.cancel()
            parseTask = nil
            stage = .idle
        case .analyzing:
            session += 1
            parseTask?.cancel()
            parseTask = nil
            stage = candidates.count > 1 ? .choosing(candidates) : .idle
        default:
            break
        }
    }

    func choose(_ candidate: VideoCandidate) {
        guard !isDownloadingStage else { return }
        session += 1
        let token = session
        retryAction = nil
        failedNeedsLogin = nil
        chosenCandidate = candidate
        stage = .analyzing
        parseTask = Task {
            do {
                var info = try await self.engine.analyze(url: candidate.url)
                // 直链/页面主视频的 yt-dlp 标题往往是 CDN 文件名，换成嗅探到的页面标题
                if candidate.kind == .pageMain || candidate.kind == .directFile,
                   !candidate.title.isEmpty, candidate.title != info.title {
                    info = VideoInfo(
                        sourceURL: info.sourceURL, videoID: info.videoID, title: candidate.title,
                        durationText: info.durationText, thumbnailURL: info.thumbnailURL,
                        uploader: info.uploader, formats: info.formats, subtitles: info.subtitles
                    )
                }
                guard token == self.session else { return }
                self.selectedFormatID = info.formats.first?.id
                self.selectedSubtitleIDs = []
                self.stage = .ready(info)
            } catch {
                guard token == self.session else { return }
                self.fail(error) { [weak self] in self?.choose(candidate) }
            }
        }
    }

    func startDownload() {
        guard case .ready(let info) = stage else { return }
        if chineseMode != .off, !settings.isTranslationConfigured {
            settingsNotice = "请先配置翻译服务"
            showSettings = true
            return
        }
        performDownload(info)
    }

    private func performDownload(_ info: VideoInfo) {
        guard let formatID = selectedFormatID ?? info.formats.first?.id else { return }
        let chosen = info.subtitles.filter { selectedSubtitleIDs.contains($0.id) }
        let request = DownloadRequest(
            url: info.sourceURL,
            videoID: info.videoID,
            formatID: formatID,
            subtitleLangs: chosen.filter { !$0.isAuto }.map(\.id),
            autoSubtitleLangs: chosen.filter { $0.isAuto }.map(\.id),
            destinationDirectory: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0],
            preferredTitle: {
                guard let kind = chosenCandidate?.kind, kind == .pageMain || kind == .directFile else { return nil }
                return info.title
            }()
        )
        session += 1
        let token = session
        retryAction = nil
        failedNeedsLogin = nil
        doneNotice = nil
        burnedVideoURL = nil
        stage = .downloading(info)
        lastProgressPhase = .preparing
        lastProgressPercent = nil
        progress = DownloadProgress(phase: .preparing)
        pipelineProgress = nil
        let mode = chineseMode
        downloadTask = Task {
            do {
                let result = try await self.engine.download(request) { [weak self] p in
                    Task { @MainActor in
                        guard let self, self.session == token else { return }
                        self.applyProgress(p)
                    }
                }
                guard token == self.session, !Task.isCancelled else { return }
                self.progress = nil
                guard mode != .off else {
                    self.downloadTask = nil
                    self.stage = .done(info, result)
                    return
                }

                // 1. 找字幕文件；没有就跳过翻译直接完成
                guard let srtFile = result.files.first(where: { $0.pathExtension.lowercased() == "srt" }) else {
                    self.downloadTask = nil
                    self.doneNotice = "没有字幕文件，已跳过翻译"
                    self.stage = .done(info, result)
                    return
                }

                // 2. 翻译
                self.stage = .translating(info)
                self.pipelineProgress = 0
                let translator = makeTranslator(settings: self.settings)
                let zhSrt = try await translator.translate(
                    srtFile: srtFile,
                    style: self.settings.subtitleStyle
                ) { [weak self] p in
                    Task { @MainActor in
                        guard let self, self.session == token else { return }
                        self.pipelineProgress = p
                    }
                }
                guard token == self.session, !Task.isCancelled else { return }
                var files = result.files + [zhSrt]

                // 3. 烧录（仅 burnIn）
                if mode == .burnIn {
                    if let video = result.files.first(where: {
                        Self.videoExtensions.contains($0.pathExtension.lowercased())
                    }) {
                        self.stage = .burning(info)
                        self.pipelineProgress = 0
                        let burner = makeBurner()
                        let burned = try await burner.burn(video: video, subtitle: zhSrt) { [weak self] p in
                            Task { @MainActor in
                                guard let self, self.session == token else { return }
                                self.pipelineProgress = p
                            }
                        }
                        guard token == self.session, !Task.isCancelled else { return }
                        files.insert(burned, at: 0)
                        self.burnedVideoURL = burned
                    } else {
                        self.doneNotice = "没有找到视频文件，已跳过烧录"
                    }
                }

                self.downloadTask = nil
                self.pipelineProgress = nil
                self.stage = .done(info, DownloadResult(files: files))
            } catch {
                guard token == self.session, !Task.isCancelled else { return }
                self.downloadTask = nil
                if case VDLError.cancelled = error {
                    self.progress = nil
                    self.pipelineProgress = nil
                    self.stage = .ready(info)
                    return
                }
                self.fail(error) { [weak self] in self?.performDownload(info) }
            }
        }
    }

    /// 下载 / 翻译 / 烧录任一阶段都可取消，统一回到 ready。
    func cancelDownload() {
        let info: VideoInfo
        switch stage {
        case .downloading(let i), .translating(let i), .burning(let i):
            info = i
        default:
            return
        }
        session += 1
        downloadTask?.cancel()
        downloadTask = nil
        progress = nil
        pipelineProgress = nil
        stage = .ready(info)
    }

    func backToList() {
        guard candidates.count > 1 else { return }
        session += 1
        downloadTask?.cancel()
        downloadTask = nil
        progress = nil
        pipelineProgress = nil
        retryAction = nil
        failedNeedsLogin = nil
        stage = .choosing(candidates)
    }

    func retry() {
        guard case .failed = stage else { return }
        if let action = retryAction {
            action()
        } else {
            reset()
        }
    }

    func reset() {
        session += 1
        downloadTask?.cancel()
        downloadTask = nil
        parseTask?.cancel()
        parseTask = nil
        urlText = ""
        stage = .idle
        selectedFormatID = nil
        selectedSubtitleIDs = []
        chineseMode = .off
        progress = nil
        pipelineProgress = nil
        candidates = []
        chosenCandidate = nil
        retryAction = nil
        failedNeedsLogin = nil
        doneNotice = nil
        burnedVideoURL = nil
        lastProgressPhase = nil
        lastProgressPercent = nil
    }

    func revealInFinder() {
        guard case .done(_, let result) = stage else { return }
        if let burned = burnedVideoURL {
            NSWorkspace.shared.activateFileViewerSelecting([burned])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(result.files)
        }
    }

    // MARK: - 设置与站点登录

    /// 保存设置；失败时把原因写进 settingsNotice。
    @discardableResult
    func saveSettings() -> Bool {
        do {
            try settings.save()
            settingsNotice = nil
            return true
        } catch {
            settingsNotice = "设置保存失败：\(error.localizedDescription)"
            return false
        }
    }

    /// 设置窗里点「登录 ××」：先保存设置并收起设置窗，等 sheet 收起后再弹登录窗。
    func requestLogin(site: String) {
        saveSettings()
        pendingLoginSite = site
        showSettings = false
    }

    /// 设置 sheet 的 onDismiss 调用：若有待弹出的登录站点则弹出登录窗。
    func consumePendingLogin() {
        guard let site = pendingLoginSite else { return }
        pendingLoginSite = nil
        loginSite = site
    }

    /// failed 页点「去登录」。
    func openLoginForFailure() {
        guard let site = failedNeedsLogin else { return }
        loginSite = site
    }

    /// 登录窗导出 cookies 成功后调用：关窗并自动重试上次失败的操作。
    func loginCompleted() {
        loginSite = nil
        if case .failed = stage, let action = retryAction {
            action()
        }
    }

    func cancelLogin() {
        loginSite = nil
    }

    // MARK: - 私有

    /// 进度单调化：丢弃 percent 回退的下载事件；进入 processing 后不再被 downloading 覆盖。
    private func applyProgress(_ p: DownloadProgress) {
        if p.phase == .downloading {
            if lastProgressPhase == .processing || lastProgressPhase == .finished { return }
            if let percent = p.percent, let last = lastProgressPercent, percent < last { return }
            if let percent = p.percent { lastProgressPercent = percent }
        }
        lastProgressPhase = p.phase
        progress = p
    }

    private func fail(_ error: Error, retry: @escaping @MainActor () -> Void) {
        retryAction = retry
        progress = nil
        pipelineProgress = nil
        downloadTask = nil
        if case VDLError.loginRequired(let site) = error {
            failedNeedsLogin = site
        } else {
            failedNeedsLogin = nil
        }
        stage = .failed(error.localizedDescription)
    }
}
