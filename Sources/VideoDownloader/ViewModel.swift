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
    private var candidates: [VideoCandidate] = []
    private var retryAction: (@MainActor () -> Void)?
    /// 代际令牌：reset / 取消后，旧任务的回调全部作废
    private var session = 0

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
        guard urlText.isEmpty else { return }
        guard let clip = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            clip.lowercased().hasPrefix("http") else { return }
        urlText = clip
    }

    func parse() {
        let input = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !isParsing, !isDownloadingStage else { return }
        session += 1
        let token = session
        retryAction = nil
        stage = .resolving
        Task {
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

    func choose(_ candidate: VideoCandidate) {
        guard !isDownloadingStage else { return }
        session += 1
        let token = session
        retryAction = nil
        stage = .analyzing
        Task {
            do {
                let info = try await self.engine.analyze(url: candidate.url)
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
            destinationDirectory: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        )
        session += 1
        let token = session
        retryAction = nil
        stage = .downloading(info)
        progress = DownloadProgress(phase: .preparing)
        downloadTask = Task {
            do {
                let result = try await self.engine.download(request) { [weak self] p in
                    Task { @MainActor in
                        guard let self, self.session == token else { return }
                        self.progress = p
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
        urlText = ""
        stage = .idle
        selectedFormatID = nil
        selectedSubtitleIDs = []
        progress = nil
        candidates = []
        retryAction = nil
    }

    func revealInFinder() {
        guard case .done(_, let result) = stage else { return }
        NSWorkspace.shared.activateFileViewerSelecting(result.files)
    }

    // MARK: - 私有

    private func fail(_ error: Error, retry: @escaping @MainActor () -> Void) {
        retryAction = retry
        progress = nil
        downloadTask = nil
        stage = .failed(error.localizedDescription)
    }
}
