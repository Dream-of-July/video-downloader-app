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
    /// 翻译 / 烧录失败或取消后为 true：done 页显示「重试字幕处理」
    @Published var canRetryPostProcess = false
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
    /// 部分成功建模：下载已成功的中间产物，翻译 / 烧录失败后据此重试，绝不重新下载
    private var downloadedInfo: VideoInfo?
    private var downloadedResult: DownloadResult?
    /// 选定的翻译源字幕
    private var sourceSrtURL: URL?
    /// 翻译完成的中文字幕；重试烧录时不再调 LLM
    private var zhSrtURL: URL?
    /// 本次流水线的中文字幕模式（重试字幕处理沿用它）
    private var postProcessMode: ChineseSubtitleMode = .off
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
        canRetryPostProcess = false
        downloadedInfo = nil
        downloadedResult = nil
        sourceSrtURL = nil
        zhSrtURL = nil
        burnedVideoURL = nil
        stage = .downloading(info)
        lastProgressPhase = .preparing
        lastProgressPercent = nil
        progress = DownloadProgress(phase: .preparing)
        pipelineProgress = nil
        let mode = chineseMode
        postProcessMode = mode
        let preferredSubtitleLang = request.subtitleLangs.first ?? request.autoSubtitleLangs.first
        downloadTask = Task {
            let result: DownloadResult
            do {
                result = try await self.engine.download(request) { [weak self] p in
                    Task { @MainActor in
                        guard let self, self.session == token else { return }
                        self.applyProgress(p)
                    }
                }
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
                return
            }
            guard token == self.session, !Task.isCancelled else { return }
            self.progress = nil
            self.downloadedInfo = info
            self.downloadedResult = result
            guard mode != .off else {
                self.downloadTask = nil
                self.stage = .done(info, result)
                return
            }

            // 找翻译源字幕（按勾选语言匹配）；没有就跳过翻译直接完成
            guard let srtFile = Self.pickSourceSubtitle(from: result.files, preferredLang: preferredSubtitleLang) else {
                self.downloadTask = nil
                self.doneNotice = "没有字幕文件，已跳过翻译"
                self.stage = .done(info, result)
                return
            }
            self.sourceSrtURL = srtFile
            await self.runPostProcess(info: info, token: token, mode: mode)
        }
    }

    /// 翻译（zhSrtURL 已存在时跳过）+ 按模式烧录。
    /// 失败 / 取消都不丢已下载的视频：落到 .done 并允许「重试字幕处理」。
    private func runPostProcess(info: VideoInfo, token: Int, mode: ChineseSubtitleMode) async {
        // 1. 翻译（重试烧录时已有译文，不再调 LLM）
        if zhSrtURL == nil {
            guard let srtFile = sourceSrtURL else {
                settleDone(info: info, notice: "没有字幕文件，已跳过翻译", canRetry: false)
                return
            }
            stage = .translating(info)
            pipelineProgress = nil
            let translator = makeTranslator(settings: settings)
            do {
                let zhSrt = try await translator.translate(
                    srtFile: srtFile,
                    style: settings.subtitleStyle
                ) { [weak self] p in
                    Task { @MainActor in
                        guard let self, self.session == token else { return }
                        self.pipelineProgress = p
                    }
                }
                guard token == self.session, !Task.isCancelled else { return }
                zhSrtURL = zhSrt
            } catch {
                guard token == self.session, !Task.isCancelled else { return }
                settleDone(
                    info: info,
                    notice: "视频已下载，但字幕翻译失败：\(Self.shortReason(of: error))",
                    canRetry: true
                )
                return
            }
        }

        // 2. 烧录（仅 burnIn；已有烧录产物时跳过）
        if mode == .burnIn, burnedVideoURL == nil {
            if let video = downloadedResult?.files.first(where: {
                Self.videoExtensions.contains($0.pathExtension.lowercased())
            }), let zhSrt = zhSrtURL {
                stage = .burning(info)
                pipelineProgress = nil
                let burner = makeBurner()
                do {
                    let burned = try await burner.burn(video: video, subtitle: zhSrt) { [weak self] p in
                        Task { @MainActor in
                            guard let self, self.session == token else { return }
                            self.pipelineProgress = p
                        }
                    }
                    guard token == self.session, !Task.isCancelled else { return }
                    burnedVideoURL = burned
                } catch {
                    guard token == self.session, !Task.isCancelled else { return }
                    settleDone(
                        info: info,
                        notice: "视频已下载，但字幕烧录失败：\(Self.shortReason(of: error))",
                        canRetry: true
                    )
                    return
                }
            } else {
                settleDone(info: info, notice: "没有找到视频文件，已跳过烧录", canRetry: false)
                return
            }
        }

        settleDone(info: info, notice: nil, canRetry: false)
    }

    /// done 页「重试字幕处理」：从已有中间产物续跑，绝不重新下载、不重复翻译已成功的部分。
    func retryPostProcess() {
        guard case .done = stage, canRetryPostProcess,
              let info = downloadedInfo, downloadedResult != nil else { return }
        session += 1
        let token = session
        canRetryPostProcess = false
        doneNotice = nil
        let mode = postProcessMode
        downloadTask = Task {
            await self.runPostProcess(info: info, token: token, mode: mode)
        }
    }

    /// 统一落到 .done：文件列表由中间产物拼出（烧录视频排第一）。
    private func settleDone(info: VideoInfo, notice: String?, canRetry: Bool) {
        downloadTask = nil
        progress = nil
        pipelineProgress = nil
        doneNotice = notice
        canRetryPostProcess = canRetry
        stage = .done(info, DownloadResult(files: composedDoneFiles()))
    }

    /// 当前 done 页应展示的文件：下载产物 + 译文 + 烧录视频（排第一）。
    private func composedDoneFiles() -> [URL] {
        var files = downloadedResult?.files ?? []
        if let zhSrt = zhSrtURL, !files.contains(zhSrt) { files.append(zhSrt) }
        if let burned = burnedVideoURL {
            files.removeAll { $0 == burned }
            files.insert(burned, at: 0)
        }
        return files
    }

    /// 按用户勾选的语言挑翻译源字幕（文件名形如 "标题 [id].en-US.srt"）。
    /// lang 大小写不敏感、允许前缀匹配（en 匹配 en-US）；匹配不到回退第一个 .srt。
    private static func pickSourceSubtitle(from files: [URL], preferredLang: String?) -> URL? {
        let srtFiles = files.filter { $0.pathExtension.lowercased() == "srt" }
        guard let lang = preferredLang?.lowercased(), !lang.isEmpty else { return srtFiles.first }
        func langCode(of file: URL) -> String? {
            let stem = file.deletingPathExtension().lastPathComponent
            guard let dotIndex = stem.lastIndex(of: ".") else { return nil }
            return String(stem[stem.index(after: dotIndex)...]).lowercased()
        }
        if let matched = srtFiles.first(where: { file in
            guard let code = langCode(of: file) else { return false }
            return code == lang || code.hasPrefix(lang + "-") || lang.hasPrefix(code + "-")
        }) {
            return matched
        }
        return srtFiles.first
    }

    /// ready 页提示用：勾选多条字幕时实际作为翻译源的那条（真实字幕优先、按解析顺序取第一条）。
    func translationSourceSubtitle(in info: VideoInfo) -> SubtitleChoice? {
        let chosen = info.subtitles.filter { selectedSubtitleIDs.contains($0.id) }
        return chosen.first(where: { !$0.isAuto }) ?? chosen.first
    }

    /// 去掉 VDLError 文案里的「字幕翻译失败：」「字幕烧录失败：」前缀，留短句给 doneNotice。
    private static func shortReason(of error: Error) -> String {
        if case VDLError.translateFailed(let reason) = error { return reason }
        if case VDLError.burnFailed(let reason) = error { return reason }
        return error.localizedDescription
    }

    /// 取消：下载阶段回到 ready；翻译 / 烧录阶段视频已保存，落到 done 并允许重试字幕处理。
    func cancelDownload() {
        switch stage {
        case .downloading(let info):
            session += 1
            downloadTask?.cancel()
            downloadTask = nil
            progress = nil
            pipelineProgress = nil
            stage = .ready(info)
        case .translating(let info), .burning(let info):
            session += 1
            downloadTask?.cancel()
            settleDone(info: info, notice: "已取消字幕处理，视频已保存", canRetry: true)
        default:
            return
        }
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
        canRetryPostProcess = false
        downloadedInfo = nil
        downloadedResult = nil
        sourceSrtURL = nil
        zhSrtURL = nil
        postProcessMode = .off
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
