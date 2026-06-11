import AppKit
import Combine
import Foundation
#if canImport(VDLCore)
import VDLCore
#endif

/// 下载队列。每个 QueueItem 是一条「下载 →[翻译]→[烧录]」完整流水线，
/// 持有独立的 TaskControlToken，可随时独立暂停 / 恢复 / 取消，并发执行互不阻塞。
@MainActor
final class QueueManager: ObservableObject {

    /// 队列项当前所处阶段。暂停态不单列，由 QueueItem.isPaused 叠加表示。
    enum ItemStage: Equatable {
        case queued
        case downloading
        case translating
        case burning
        case done
        case failed(String)
        case cancelled
    }

    struct QueueItem: Identifiable {
        let id: UUID
        let title: String
        let thumbnailURL: URL?
        let info: VideoInfo
        let request: DownloadRequest
        let chineseMode: ChineseSubtitleMode
        /// 本项使用的设置快照（字幕样式、烧录画质、翻译凭证）
        let settings: AppSettings
        var stage: ItemStage
        /// 0...1；nil 表示不确定（处理 / 翻译启动等）
        var progress: Double?
        /// 暂停 / 部分成功 / 失败原因等附加说明
        var statusText: String?
        /// 已落盘的产物（下载文件、译文、烧录视频）
        var resultFiles: [URL]
        var isPaused: Bool
        /// 本项流水线的控制令牌；retry 时换新的（旧的已 cancel）。
        var control: TaskControlToken
        var task: Task<Void, Never>?
    }

    @Published var items: [QueueItem] = []

    private let engine: any DownloadEngine

    /// 视频文件后缀（用于在产物里识别可烧录的视频）
    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "mkv", "webm", "m4v", "avi", "flv", "ts",
    ]

    init(engine: any DownloadEngine = makeDefaultEngine()) {
        self.engine = engine
    }

    // MARK: - 派生状态

    /// 有进行中（非暂停 / 完成 / 失败 / 取消）的任务，关窗确认据此判断。
    var hasActiveTasks: Bool {
        items.contains { item in
            guard !item.isPaused else { return false }
            switch item.stage {
            case .queued, .downloading, .translating, .burning:
                return true
            case .done, .failed, .cancelled:
                return false
            }
        }
    }

    var activeTaskCount: Int {
        items.filter { item in
            guard !item.isPaused else { return false }
            switch item.stage {
            case .queued, .downloading, .translating, .burning:
                return true
            case .done, .failed, .cancelled:
                return false
            }
        }.count
    }

    // MARK: - 入队

    func enqueue(info: VideoInfo, request: DownloadRequest, chineseMode: ChineseSubtitleMode, settings: AppSettings) {
        let id = UUID()
        let control = TaskControlToken()
        let item = QueueItem(
            id: id,
            title: info.title,
            thumbnailURL: info.thumbnailURL,
            info: info,
            request: request,
            chineseMode: chineseMode,
            settings: settings,
            stage: .queued,
            progress: nil,
            statusText: nil,
            resultFiles: [],
            isPaused: false,
            control: control
        )
        items.append(item)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runPipeline(id: id, skipDownload: false)
        }
        update(id) { $0.task = task }
    }

    // MARK: - 流水线

    /// 跑完整条流水线。skipDownload=true 用于重试：已下载产物在 resultFiles 里，跳过下载阶段。
    private func runPipeline(id: UUID, skipDownload: Bool) async {
        guard let current = item(id) else { return }
        let control = current.control
        let settings = current.settings
        let mode = current.chineseMode

        // 1. 下载
        var downloadFiles: [URL]
        if skipDownload {
            downloadFiles = current.resultFiles
        } else {
            update(id) { $0.stage = .downloading; $0.progress = nil; $0.statusText = nil }
            do {
                let result = try await engine.download(current.request, control: control) { [weak self] p in
                    Task { @MainActor in
                        self?.applyDownloadProgress(id: id, p)
                    }
                }
                guard item(id) != nil else { return }
                downloadFiles = result.files
                update(id) { $0.resultFiles = result.files; $0.progress = nil }
            } catch {
                guard item(id) != nil else { return }
                if isCancellation(error) {
                    update(id) {
                        $0.stage = .cancelled
                        $0.isPaused = false
                        $0.progress = nil
                        $0.statusText = "已取消"
                    }
                } else {
                    update(id) {
                        $0.stage = .failed(Self.shortReason(of: error))
                        $0.isPaused = false
                        $0.progress = nil
                        $0.statusText = "失败：\(Self.shortReason(of: error))"
                    }
                }
                return
            }
        }

        // 下载完成，无需中文字幕：直接完成
        guard mode != .off else {
            finishDone(id, files: downloadFiles, statusText: nil)
            return
        }

        // 找翻译源字幕；没有就完成并提示已跳过
        let preferredLang = current.request.subtitleLangs.first ?? current.request.autoSubtitleLangs.first
        guard let srtFile = Self.pickSourceSubtitle(from: downloadFiles, preferredLang: preferredLang) else {
            finishDone(id, files: downloadFiles, statusText: "没有字幕文件，已跳过翻译")
            return
        }

        // 2. 翻译
        update(id) { $0.stage = .translating; $0.progress = nil; $0.statusText = nil }
        let zhSrt: URL
        do {
            let translator = makeTranslator(settings: settings)
            zhSrt = try await translator.translate(
                srtFile: srtFile,
                style: settings.subtitleStyle,
                control: control
            ) { [weak self] p in
                Task { @MainActor in
                    self?.update(id) { $0.progress = p }
                }
            }
            guard item(id) != nil else { return }
            update(id) {
                $0.progress = nil
                if !$0.resultFiles.contains(zhSrt) { $0.resultFiles.append(zhSrt) }
            }
        } catch {
            guard item(id) != nil else { return }
            settlePartial(id, files: downloadFiles, error: error, phase: "翻译")
            return
        }

        // 3. 烧录（仅 burnIn）
        guard mode == .burnIn else {
            finishDone(id, files: item(id)?.resultFiles ?? downloadFiles, statusText: nil)
            return
        }
        guard let video = downloadFiles.first(where: {
            Self.videoExtensions.contains($0.pathExtension.lowercased())
        }) else {
            finishDone(id, files: item(id)?.resultFiles ?? downloadFiles, statusText: "没有找到视频文件，已跳过烧录")
            return
        }

        update(id) { $0.stage = .burning; $0.progress = nil; $0.statusText = nil }
        do {
            let burner = makeBurner()
            let burned = try await burner.burn(
                video: video,
                subtitle: zhSrt,
                maxHeight: settings.maxBurnHeight,
                control: control
            ) { [weak self] p in
                Task { @MainActor in
                    self?.update(id) { $0.progress = p }
                }
            }
            guard item(id) != nil else { return }
            update(id) {
                $0.resultFiles.removeAll { $0 == burned }
                $0.resultFiles.insert(burned, at: 0)
            }
            finishDone(id, files: item(id)?.resultFiles ?? downloadFiles, statusText: nil)
        } catch {
            guard item(id) != nil else { return }
            settlePartial(id, files: item(id)?.resultFiles ?? downloadFiles, error: error, phase: "烧录")
        }
    }

    /// 下载进度单调上报：转 0...1（processing 阶段进度不确定，置 nil）。
    private func applyDownloadProgress(id: UUID, _ p: DownloadProgress) {
        guard item(id) != nil else { return }
        update(id) {
            // 进入烧录/翻译后不再被迟到的下载回调覆盖
            guard $0.stage == .downloading else { return }
            switch p.phase {
            case .downloading:
                $0.progress = p.percent.map { min(max($0 / 100, 0), 1) }
            case .preparing, .processing, .finished:
                $0.progress = nil
            }
        }
    }

    /// 部分成功：下载产物已落盘 → .done + 失败说明；否则视为 .failed。
    /// 取消（VDLError.cancelled / Task 取消）→ .cancelled，保留已下产物。
    private func settlePartial(_ id: UUID, files: [URL], error: Error, phase: String) {
        if isCancellation(error) {
            update(id) {
                $0.stage = .cancelled
                $0.isPaused = false
                $0.progress = nil
                $0.statusText = files.isEmpty ? "已取消" : "已取消，视频已保存"
            }
            return
        }
        let reason = Self.shortReason(of: error)
        if !files.isEmpty {
            update(id) {
                $0.stage = .done
                $0.isPaused = false
                $0.progress = nil
                $0.statusText = "视频已下载，字幕\(phase)失败：\(reason)"
            }
        } else {
            update(id) {
                $0.stage = .failed(reason)
                $0.isPaused = false
                $0.progress = nil
                $0.statusText = "失败：\(reason)"
            }
        }
    }

    private func finishDone(_ id: UUID, files: [URL], statusText: String?) {
        update(id) {
            $0.stage = .done
            $0.isPaused = false
            $0.progress = nil
            $0.resultFiles = files.isEmpty ? $0.resultFiles : files
            $0.statusText = statusText
        }
    }

    // MARK: - 单项控制

    func pause(_ id: UUID) {
        guard let target = item(id) else { return }
        target.control.pause()
        update(id) { $0.isPaused = true }
    }

    func resume(_ id: UUID) {
        guard let target = item(id) else { return }
        target.control.resume()
        update(id) { $0.isPaused = false }
    }

    func cancel(_ id: UUID) {
        guard let target = item(id) else { return }
        target.control.cancel()
        target.task?.cancel()
    }

    func remove(_ id: UUID) {
        guard let target = item(id) else { return }
        target.control.cancel()
        target.task?.cancel()
        items.removeAll { $0.id == id }
    }

    /// 重试：保留已下载产物则跳过下载，仅重跑字幕处理；无产物则整条重跑。
    func retry(_ id: UUID) {
        guard let old = item(id) else { return }
        // 旧 control 若仍登记着进程，确保释放
        old.control.cancel()
        old.task?.cancel()

        let hasVideo = old.resultFiles.contains {
            Self.videoExtensions.contains($0.pathExtension.lowercased())
        }
        let skipDownload = hasVideo && old.chineseMode != .off
        let newControl = TaskControlToken()
        update(id) {
            $0.control = newControl
            $0.stage = .queued
            $0.isPaused = false
            $0.progress = nil
            $0.statusText = skipDownload ? nil : "重新下载并处理"
            if !skipDownload { $0.resultFiles = [] }
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runPipeline(id: id, skipDownload: skipDownload)
        }
        update(id) { $0.task = task }
    }

    /// 在访达中选中该项的产物（烧录视频排第一）。
    func revealInFinder(_ id: UUID) {
        guard let target = item(id), !target.resultFiles.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(target.resultFiles)
    }

    // MARK: - 工具

    private func index(of id: UUID) -> Int? {
        items.firstIndex { $0.id == id }
    }

    private func item(_ id: UUID) -> QueueItem? {
        guard let i = index(of: id) else { return nil }
        return items[i]
    }

    /// 按 id 定位并就地修改；项已被移除时安全跳过。
    private func update(_ id: UUID, _ mutate: (inout QueueItem) -> Void) {
        guard let i = index(of: id) else { return }
        mutate(&items[i])
    }

    private func isCancellation(_ error: Error) -> Bool {
        if case VDLError.cancelled = error { return true }
        return error is CancellationError
    }

    private static func shortReason(of error: Error) -> String {
        switch error {
        case VDLError.translateFailed(let r), VDLError.burnFailed(let r), VDLError.downloadFailed(let r):
            return r
        default:
            return error.localizedDescription
        }
    }

    /// 按勾选语言挑翻译源字幕（与 ViewModel 旧逻辑一致）：大小写不敏感、允许前缀匹配，回退第一个 .srt。
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
}
