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
    @Published var settings = AppSettings.load()
    @Published var showSettings = false
    /// 非 nil 时弹出站点登录窗（值为站点 host，如 "youtube.com"）
    @Published var loginSite: String?
    /// 失败原因是需要登录时记录站点，failed 页据此把主按钮换成「去登录」
    @Published var failedNeedsLogin: String?
    /// 设置窗里的提示（保存失败 / 请先配置翻译服务）
    @Published var settingsNotice: String?
    /// 入队成功后的一行轻提示（如「已加入队列」）
    @Published var enqueueNotice: String?
    /// 触发器：自增时 ContentView 重新聚焦链接输入框（入队后方便继续粘贴）。
    @Published var requestUrlFocus = 0

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

    func parse() {
        let input = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !isParsing else { return }
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
        enqueueNotice = nil
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
        // 回到 idle 后重新聚焦输入框，方便直接 Cmd+V 粘贴下一条。
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
