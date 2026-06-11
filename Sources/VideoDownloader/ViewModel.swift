import AppKit
import Combine
import Foundation
#if canImport(VDLCore)
import VDLCore
#endif

@MainActor
final class ViewModel: ObservableObject {

    enum Stage {
        case idle
        case resolving
        case choosing([VideoCandidate])
        case analyzing
        case ready(VideoInfo)
        case downloading(VideoInfo)
        case done(VideoInfo, DownloadResult)
        case failed(String)
    }

    @Published var urlText: String = ""
    @Published var stage: Stage = .idle
    @Published var selectedFormatID: String?
    @Published var selectedSubtitleIDs: Set<String> = []
    @Published var progress: DownloadProgress?

    private let engine: any DownloadEngine
    private var downloadTask: Task<Void, Never>?
    private var parseTask: Task<Void, Never>?
    private var candidates: [VideoCandidate] = []
    private var chosenCandidate: VideoCandidate?
    private var retryAction: (@MainActor () -> Void)?
    /// 代际令牌：reset / 取消后，旧任务的回调全部作废
    private var session = 0
    /// 进度单调化：记录最近相位与百分比，丢弃回退事件
    private var lastProgressPhase: DownloadProgress.Phase?
    private var lastProgressPercent: Double?

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

    var isDownloadingStage: Bool {
        if case .downloading = stage { return true }
        return false
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
            stage = .failed("这不是一个网址。请粘贴以 http 或 https 开头的视频链接。")
            return
        }
        session += 1
        let token = session
        retryAction = nil
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
        stage = .downloading(info)
        lastProgressPhase = .preparing
        lastProgressPercent = nil
        progress = DownloadProgress(phase: .preparing)
        downloadTask = Task {
            do {
                let result = try await self.engine.download(request) { [weak self] p in
                    Task { @MainActor in
                        guard let self, self.session == token else { return }
                        self.applyProgress(p)
                    }
                }
                guard token == self.session, !Task.isCancelled else { return }
                self.downloadTask = nil
                self.progress = nil
                self.stage = .done(info, result)
            } catch {
                guard token == self.session, !Task.isCancelled else { return }
                self.downloadTask = nil
                if case VDLError.cancelled = error {
                    self.progress = nil
                    self.stage = .ready(info)
                    return
                }
                self.fail(error) { [weak self] in self?.performDownload(info) }
            }
        }
    }

    func cancelDownload() {
        guard case .downloading(let info) = stage else { return }
        session += 1
        downloadTask?.cancel()
        downloadTask = nil
        progress = nil
        stage = .ready(info)
    }

    func backToList() {
        guard candidates.count > 1 else { return }
        session += 1
        downloadTask?.cancel()
        downloadTask = nil
        progress = nil
        retryAction = nil
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
        progress = nil
        candidates = []
        chosenCandidate = nil
        retryAction = nil
        lastProgressPhase = nil
        lastProgressPercent = nil
    }

    func revealInFinder() {
        guard case .done(_, let result) = stage else { return }
        NSWorkspace.shared.activateFileViewerSelecting(result.files)
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
        downloadTask = nil
        stage = .failed(error.localizedDescription)
    }
}
