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

    /// 解析与选档的前半段；下载之后的流水线全部交给 QueueManager。
    enum Stage {
        case idle
        case resolving
        case choosing([VideoCandidate])
        case analyzing
        case ready(VideoInfo)
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
    @Published var chineseMode: ChineseSubtitleMode = .off
    @Published var settings = AppSettings.load() {
        didSet { queue.syncConcurrency(from: settings) }
    }
    @Published var showSettings = false
    /// 非 nil 时弹出站点登录窗（值为站点 host，如 "youtube.com"）
    @Published var loginSite: String?
    /// 失败原因是需要登录时记录站点，failed 页据此把主按钮换成「去登录」
    @Published var failedNeedsLogin: String?
    /// 设置窗里的提示（保存失败 / 请先配置翻译服务）
    @Published var settingsNotice: String?
    /// 入队成功后的一行轻提示（如「已加入队列」）
    @Published var enqueueNotice: String?
    /// 批量粘贴多链接时的进度文案（解析中显示，如「批量解析中（2/5）」）
    @Published var batchStatusText: String?
    /// 触发器：自增时 ContentView 重新聚焦链接输入框（入队后方便继续粘贴）。
    @Published var requestUrlFocus = 0
    /// 队列浮层形态：true=铺满内容区，false=缩成底部小把手。
    /// 开始解析新链接时自动收起（让位给下载设置），入队完成/回到空闲时自动铺满。
    @Published var queueExpanded = false

    /// 并发下载队列，贯穿整个 App 生命周期。
    let queue: QueueManager

    private let engine: any DownloadEngine
    private var parseTask: Task<Void, Never>?
    private var candidates: [VideoCandidate] = []
    private var chosenCandidate: VideoCandidate?
    private var retryAction: (@MainActor () -> Void)?
    /// 设置窗里点了「登录 ××」：先收起设置 sheet，再由其 onDismiss 弹出登录窗
    private var pendingLoginSite: String?
    /// 代际令牌：reset / 取消后，旧解析任务的回调全部作废
    private var session = 0

    init(engine: any DownloadEngine = makeDefaultEngine(), queue: QueueManager? = nil) {
        self.engine = engine
        self.queue = queue ?? QueueManager(engine: engine)
    }

    // MARK: - 派生状态

    var isParsing: Bool {
        switch stage {
        case .resolving, .analyzing: return true
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
        case .idle, .ready:
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

    /// 「一键粘贴」：直接读剪贴板（绕过输入框对多行粘贴的处理差异），填入后立即解析。
    func pasteAndParse() {
        guard !isParsing else { return }
        guard let clip = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !clip.isEmpty else {
            enqueueNotice = "剪贴板里没有内容"
            return
        }
        urlText = clip
        parse()
    }

    func parse() {
        let input = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !isParsing else { return }

        // 一次粘贴多条链接：逐个解析并按默认选项（最高画质）自动加入队列
        let urls = Self.extractURLs(from: input)
        if urls.count > 1 {
            processBatch(urls)
            return
        }

        // 单链接也用提取结果（容忍尾随标点/前后杂字），提不出再退回原始输入
        let target = urls.first ?? input
        guard let url = URL(string: target),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            session += 1
            retryAction = nil
            failedNeedsLogin = nil
            queueExpanded = false
            stage = .failed("这不是一个网址。请粘贴以 http 或 https 开头的视频链接。")
            return
        }
        session += 1
        let token = session
        retryAction = nil
        failedNeedsLogin = nil
        enqueueNotice = nil
        queueExpanded = false
        stage = .resolving
        chosenCandidate = nil
        parseTask?.cancel()
        parseTask = Task {
            do {
                let found = try await self.engine.resolveCandidates(for: target)
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

    /// 下载目的地：会产出多个文件（字幕/译文/烧录件）时在 Downloads 下按视频标题建文件夹，
    /// 单视频文件直接放 Downloads（避免一个视频三四个文件把下载目录搅乱）。
    static func destinationDirectory(forTitle title: String, multiFile: Bool) -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        guard multiFile else { return downloads }
        return downloads.appendingPathComponent(sanitizedFolderName(title), isDirectory: true)
    }

    /// 标题转安全文件夹名：去路径分隔/控制字符、截长、去结尾点号（兼容 Windows）。
    static func sanitizedFolderName(_ title: String) -> String {
        var name = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:\0").union(.newlines))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.count > 80 {
            name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces)
        }
        while name.hasSuffix(".") { name.removeLast() }
        return name.isEmpty ? "视频" : name
    }

    /// 从粘贴文本里提取全部 http(s) 链接，保序去重。
    /// 按 `http(s)://` 锚点切分而非只按空白：单行输入框粘贴多行时换行可能被吞掉、
    /// 多条链接首尾相接，按空白分隔会整段当成一条导致「只解析出一个地址」。
    static func extractURLs(from input: String) -> [String] {
        var seen = Set<String>()
        var urls: [String] = []
        // 每个字符既非空白、也不是下一条链接的开头（负向前瞻保证相接的链接被切开）
        let pattern = #"(?i)https?://(?:(?!https?://)\S)+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = input as NSString
        for match in regex.matches(in: input, range: NSRange(location: 0, length: ns.length)) {
            let raw = ns.substring(with: match.range)
            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: ",;，；、。.)）]》〉>」』\"'"))
            guard let url = URL(string: token),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host != nil,
                  seen.insert(token).inserted else { continue }
            urls.append(token)
        }
        return urls
    }

    /// 批量模式：逐个解析（多候选页取第一个，即页面主视频），按最高画质自动入队。
    /// 当前已选「中文字幕」模式会沿用，并自动挑一条字幕作翻译源（真实字幕优先）。
    private func processBatch(_ urls: [String]) {
        let mode = chineseMode
        if mode != .off, !settings.isTranslationConfigured {
            settingsNotice = "请先配置翻译服务"
            showSettings = true
            return
        }
        session += 1
        let token = session
        retryAction = nil
        failedNeedsLogin = nil
        enqueueNotice = nil
        candidates = []
        chosenCandidate = nil
        queueExpanded = false
        stage = .resolving
        let currentSettings = settings
        parseTask?.cancel()
        parseTask = Task {
            var added = 0
            var duplicated = 0
            var failedHosts: [String] = []
            for (index, urlString) in urls.enumerated() {
                guard token == self.session else { return }
                self.batchStatusText = "批量解析中（\(index + 1)/\(urls.count)）"
                do {
                    let found = try await self.engine.resolveCandidates(for: urlString)
                    guard token == self.session else { return }
                    guard let candidate = found.first else { throw VDLError.sniffFailed("") }
                    var info = try await self.engine.analyze(url: candidate.url)
                    guard token == self.session else { return }
                    if candidate.kind == .pageMain || candidate.kind == .directFile,
                       !candidate.title.isEmpty, candidate.title != info.title {
                        info = VideoInfo(
                            sourceURL: info.sourceURL, videoID: info.videoID, title: candidate.title,
                            durationText: info.durationText, thumbnailURL: info.thumbnailURL,
                            uploader: info.uploader, formats: info.formats, subtitles: info.subtitles
                        )
                    }
                    guard let formatID = info.formats.first?.id else {
                        throw VDLError.analyzeFailed("没有可用格式")
                    }
                    if self.queue.hasOpenDuplicate(
                        videoID: info.videoID, sourceURL: info.sourceURL, formatID: formatID
                    ) {
                        duplicated += 1
                        continue
                    }
                    // 中文字幕模式开启时自动选一条字幕作翻译源（真实字幕优先）
                    var subtitleLangs: [String] = []
                    var autoSubtitleLangs: [String] = []
                    if mode != .off,
                       let sub = info.subtitles.first(where: { !$0.isAuto }) ?? info.subtitles.first {
                        if sub.isAuto {
                            autoSubtitleLangs = [sub.id]
                        } else {
                            subtitleLangs = [sub.id]
                        }
                    }
                    let multiFile = mode != .off
                        || !subtitleLangs.isEmpty || !autoSubtitleLangs.isEmpty
                    let request = DownloadRequest(
                        url: info.sourceURL,
                        videoID: info.videoID,
                        formatID: formatID,
                        subtitleLangs: subtitleLangs,
                        autoSubtitleLangs: autoSubtitleLangs,
                        destinationDirectory: Self.destinationDirectory(
                            forTitle: info.title, multiFile: multiFile
                        ),
                        preferredTitle: (candidate.kind == .pageMain || candidate.kind == .directFile)
                            ? info.title : nil
                    )
                    self.queue.enqueue(
                        info: info, request: request, chineseMode: mode, settings: currentSettings
                    )
                    added += 1
                } catch is CancellationError {
                    return
                } catch {
                    guard token == self.session else { return }
                    if case VDLError.cancelled = error { return }
                    failedHosts.append(URL(string: urlString)?.host ?? urlString)
                }
            }
            guard token == self.session else { return }
            self.batchStatusText = nil
            self.urlText = ""
            self.selectedFormatID = nil
            self.selectedSubtitleIDs = []
            self.chineseMode = .off
            self.stage = .idle
            var parts: [String] = ["已加入 \(added) 个任务"]
            if duplicated > 0 { parts.append("\(duplicated) 个已在队列") }
            if !failedHosts.isEmpty {
                let sample = failedHosts.prefix(2).joined(separator: "、")
                parts.append("\(failedHosts.count) 个解析失败：\(sample)\(failedHosts.count > 2 ? " 等" : "")")
            }
            self.enqueueNotice = parts.joined(separator: "；")
            self.queueExpanded = true
            self.requestUrlFocus += 1
        }
    }

    func cancelParse() {
        switch stage {
        case .resolving:
            session += 1
            parseTask?.cancel()
            parseTask = nil
            batchStatusText = nil
            stage = .idle
            queueExpanded = true
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
        session += 1
        let token = session
        retryAction = nil
        failedNeedsLogin = nil
        chosenCandidate = candidate
        stage = .analyzing
        parseTask?.cancel()
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

    /// ready 页「加入队列」：构造 DownloadRequest 入队，然后清空回可输入态以便继续添加下一条。
    func startDownload() {
        guard case .ready(let info) = stage else { return }
        if chineseMode != .off, !settings.isTranslationConfigured {
            settingsNotice = "请先配置翻译服务"
            showSettings = true
            return
        }
        guard let formatID = selectedFormatID ?? info.formats.first?.id else { return }
        // 去重：队列里已有同源未完成任务时不再起新任务，只给一行提示。
        if queue.hasOpenDuplicate(videoID: info.videoID, sourceURL: info.sourceURL, formatID: formatID) {
            enqueueNotice = "该视频已在队列中"
            return
        }
        let chosen = info.subtitles.filter { selectedSubtitleIDs.contains($0.id) }
        // 会产出多个文件（字幕 / 翻译 / 烧录件）时按视频建独立文件夹；单视频直接放 Downloads。
        let multiFile = !chosen.isEmpty || chineseMode != .off
        let request = DownloadRequest(
            url: info.sourceURL,
            videoID: info.videoID,
            formatID: formatID,
            subtitleLangs: chosen.filter { !$0.isAuto }.map(\.id),
            autoSubtitleLangs: chosen.filter { $0.isAuto }.map(\.id),
            destinationDirectory: Self.destinationDirectory(forTitle: info.title, multiFile: multiFile),
            preferredTitle: {
                guard let kind = chosenCandidate?.kind, kind == .pageMain || kind == .directFile else { return nil }
                return info.title
            }()
        )
        queue.enqueue(info: info, request: request, chineseMode: chineseMode, settings: settings)

        // 回到可输入态，方便粘贴下一条
        session += 1
        parseTask?.cancel()
        parseTask = nil
        urlText = ""
        selectedFormatID = nil
        selectedSubtitleIDs = []
        chineseMode = .off
        candidates = []
        chosenCandidate = nil
        retryAction = nil
        failedNeedsLogin = nil
        enqueueNotice = "已加入队列：\(info.title)"
        stage = .idle
        // 入队即铺满队列（新任务落位可见），重新聚焦输入框方便直接粘贴下一条。
        queueExpanded = true
        requestUrlFocus += 1
    }

    /// ready 页提示用：勾选多条字幕时实际作为翻译源的那条（真实字幕优先、按解析顺序取第一条）。
    func translationSourceSubtitle(in info: VideoInfo) -> SubtitleChoice? {
        let chosen = info.subtitles.filter { selectedSubtitleIDs.contains($0.id) }
        return chosen.first(where: { !$0.isAuto }) ?? chosen.first
    }

    /// 实际翻译源字幕是否已是中文（lang code 以 zh 开头）。中文源会跳过翻译、直接使用/烧录。
    func translationSourceIsChinese(in info: VideoInfo) -> Bool {
        guard let source = translationSourceSubtitle(in: info) else { return false }
        let prefix = source.id.lowercased().split(separator: "-").first.map(String.init)
        return prefix == "zh"
    }

    func backToList() {
        guard candidates.count > 1 else { return }
        session += 1
        parseTask?.cancel()
        parseTask = nil
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
        parseTask?.cancel()
        parseTask = nil
        urlText = ""
        stage = .idle
        queueExpanded = true
        selectedFormatID = nil
        selectedSubtitleIDs = []
        chineseMode = .off
        candidates = []
        chosenCandidate = nil
        retryAction = nil
        failedNeedsLogin = nil
        enqueueNotice = nil
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

    private func fail(_ error: Error, retry: @escaping @MainActor () -> Void) {
        retryAction = retry
        if case VDLError.loginRequired(let site) = error {
            failedNeedsLogin = site
        } else {
            failedNeedsLogin = nil
        }
        stage = .failed(error.localizedDescription)
    }
}
