import Foundation

// MARK: - 默认引擎

public func makeDefaultEngine() -> any DownloadEngine {
    YtDlpEngine()
}

// MARK: - 跨线程小工具

/// 进程输出缓冲（多队列并发写入时加锁）。
private final class DataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// 持有子进程引用，支持跨任务取消与超时标记。
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOutFlag = false

    /// 返回 true 表示注册前已请求取消，调用方需立即终止子进程。
    func register(_ p: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        process = p
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let p = process
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func markTimedOut() {
        lock.lock()
        timedOutFlag = true
        lock.unlock()
    }

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOutFlag
    }
}

/// 流式下载进程的共享状态：stdout 行缓冲（半行拼接）、stderr 尾部、单次 resume 保护。
private final class StreamingState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var resumed = false
    private var lineBuffer = Data()
    private var stderrData = Data()
    private let stderrLimit = 16 * 1024

    func register(_ p: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        process = p
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let p = process
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func appendStderr(_ data: Data) {
        lock.lock()
        stderrData.append(data)
        if stderrData.count > stderrLimit {
            stderrData.removeFirst(stderrData.count - stderrLimit)
        }
        lock.unlock()
    }

    var stderrTail: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: stderrData, as: UTF8.self)
    }

    /// 追加 stdout 数据，返回新凑齐的完整行（不含换行符）。
    func consumeLines(appending data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        lineBuffer.append(data)
        var lines: [String] = []
        while let index = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<index)
            lineBuffer.removeSubrange(lineBuffer.startIndex...index)
            var line = String(decoding: lineData, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }

    func flushRemainder() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard !lineBuffer.isEmpty else { return [] }
        let line = String(decoding: lineBuffer, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        lineBuffer.removeAll()
        return line.isEmpty ? [] : [line]
    }

    func resumeOnce(_ body: () -> Void) {
        lock.lock()
        let shouldRun = !resumed
        resumed = true
        lock.unlock()
        if shouldRun { body() }
    }
}

private struct ProcessOutput {
    let status: Int32
    let stdout: Data
    let stderr: Data
    let timedOut: Bool
}

// MARK: - YtDlpEngine

public final class YtDlpEngine: DownloadEngine, @unchecked Sendable {

    private let cacheLock = NSLock()
    private var infoCache: [String: [String: Any]] = [:]

    public init() {}

    // MARK: 二进制定位

    private static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    private static func locateBinary(named name: String, envVar: String) -> String? {
        let fm = FileManager.default
        if let custom = ProcessInfo.processInfo.environment[envVar],
           !custom.isEmpty, fm.isExecutableFile(atPath: custom) {
            return custom
        }
        for dir in searchDirectories {
            let path = dir + "/" + name
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private func ytDlpPath() throws -> String {
        guard let path = Self.locateBinary(named: "yt-dlp", envVar: "VDL_YTDLP_PATH") else {
            throw VDLError.binaryNotFound("yt-dlp")
        }
        return path
    }

    private func ffmpegDirectory() throws -> String {
        guard let path = Self.locateBinary(named: "ffmpeg", envVar: "VDL_FFMPEG_PATH") else {
            throw VDLError.binaryNotFound("ffmpeg")
        }
        return (path as NSString).deletingLastPathComponent
    }

    private func ffprobePath() -> String? {
        Self.locateBinary(named: "ffprobe", envVar: "VDL_FFPROBE_PATH")
    }

    // MARK: 信息缓存

    private func cachedInfo(for url: String) -> [String: Any]? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return infoCache[url]
    }

    private func setCachedInfo(_ info: [String: Any], for url: String) {
        cacheLock.lock()
        infoCache[url] = info
        cacheLock.unlock()
    }

    // MARK: - 第一步：解析候选

    public func resolveCandidates(for input: String) async throws -> [VideoCandidate] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            throw VDLError.sniffFailed("请检查链接格式。")
        }

        switch try await runYtDlpJSON(for: trimmed) {
        case .success(let json):
            setCachedInfo(json, for: trimmed)
            let title = (json["title"] as? String) ?? trimmed
            let detail = json["extractor_key"] as? String
            return [VideoCandidate(url: trimmed, kind: .supported, title: title, detail: detail)]

        case .failure(let stderr):
            if Self.isYouTubeHost(url.host ?? "") {
                throw VDLError.analyzeFailed(Self.friendlyAnalyzeReason(stderr: stderr))
            }
            let candidates: [VideoCandidate]
            do {
                candidates = try await PageSniffer().sniff(pageURL: url)
            } catch let error as VDLError {
                throw error
            } catch {
                throw VDLError.sniffFailed("页面加载失败，请稍后重试。")
            }
            guard !candidates.isEmpty else {
                throw VDLError.sniffFailed("可以换个页面，或直接粘贴视频文件地址。")
            }
            return candidates
        }
    }

    // MARK: - 第二步：解析格式与字幕

    public func analyze(url: String) async throws -> VideoInfo {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let json: [String: Any]
        if let cached = cachedInfo(for: trimmed) {
            json = cached
        } else {
            switch try await runYtDlpJSON(for: trimmed) {
            case .success(let dict):
                setCachedInfo(dict, for: trimmed)
                json = dict
            case .failure(let stderr):
                throw VDLError.analyzeFailed(Self.friendlyAnalyzeReason(stderr: stderr))
            }
        }
        return await buildVideoInfo(sourceURL: trimmed, json: json)
    }

    private enum YtDlpJSONResult {
        case success([String: Any])
        case failure(stderr: String)
    }

    private func runYtDlpJSON(for url: String) async throws -> YtDlpJSONResult {
        let ytdlp = try ytDlpPath()
        let ffmpegDir = try ffmpegDirectory()
        let output = try await Self.runProcess(
            executable: ytdlp,
            arguments: ["-J", "--no-playlist", "--ffmpeg-location", ffmpegDir, url],
            timeout: nil
        )
        if output.status == 0,
           let object = try? JSONSerialization.jsonObject(with: output.stdout),
           var dict = object as? [String: Any] {
            // --no-playlist 之下仍可能拿到 playlist 包装，取第一个条目兜底。
            if dict["_type"] as? String == "playlist",
               let entries = dict["entries"] as? [[String: Any]],
               let first = entries.first {
                dict = first
            }
            return .success(dict)
        }
        return .failure(stderr: String(decoding: output.stderr, as: UTF8.self))
    }

    private func buildVideoInfo(sourceURL: String, json: [String: Any]) async -> VideoInfo {
        let videoID = (json["id"] as? String) ?? (json["display_id"] as? String) ?? "video"
        let title = (json["title"] as? String) ?? sourceURL
        var durationText = Self.doubleValue(json["duration"]).map(Self.formatDuration)
        let thumbnailURL = (json["thumbnail"] as? String).flatMap(URL.init(string:))
        let uploader = (json["uploader"] as? String) ?? (json["channel"] as? String)

        let rawFormats = (json["formats"] as? [[String: Any]]) ?? []
        let videoFormats = rawFormats.filter { format in
            (format["vcodec"] as? String) != "none" && (Self.intValue(format["height"]) ?? 0) > 0
        }

        var formats: [FormatChoice] = []

        if !videoFormats.isEmpty {
            let heights = Array(Set(videoFormats.compactMap { Self.intValue($0["height"]) }))
                .sorted(by: >)
            let audioBytes = Self.bestAudioSizeBytes(in: rawFormats)

            func tierDetail(_ height: Int) -> String? {
                let tier = videoFormats.filter { Self.intValue($0["height"]) == height }
                let best = tier.max {
                    (Self.doubleValue($0["tbr"]) ?? 0) < (Self.doubleValue($1["tbr"]) ?? 0)
                }
                let videoBytes = best.flatMap {
                    Self.doubleValue($0["filesize"]) ?? Self.doubleValue($0["filesize_approx"])
                } ?? tier.compactMap {
                    Self.doubleValue($0["filesize"]) ?? Self.doubleValue($0["filesize_approx"])
                }.max()
                guard let videoBytes else { return nil }
                return Self.sizeText(bytes: videoBytes + (audioBytes ?? 0))
            }

            if let maxHeight = heights.first {
                formats.append(FormatChoice(
                    id: "bv*+ba/b",
                    label: "最佳画质（\(maxHeight)p）",
                    detail: tierDetail(maxHeight)
                ))
                for height in heights.prefix(6) {
                    formats.append(FormatChoice(
                        id: "bv*[height<=\(height)]+ba/b[height<=\(height)]",
                        label: "\(height)p · mp4",
                        detail: tierDetail(height)
                    ))
                }
            }
        } else {
            // 直链文件：单一格式，无分档信息。
            let urlExt = URL(string: sourceURL)?.pathExtension ?? ""
            let ext = (json["ext"] as? String) ?? (urlExt.isEmpty ? "mp4" : urlExt)
            var label = "原始文件 · \(ext)"
            var sizeDetail: String?
            if let first = rawFormats.first,
               let bytes = Self.doubleValue(first["filesize"]) ?? Self.doubleValue(first["filesize_approx"]) {
                sizeDetail = Self.sizeText(bytes: bytes)
            }
            let mediaURL = (json["url"] as? String)
                ?? rawFormats.first.flatMap { $0["url"] as? String }
                ?? sourceURL
            if let probe = await runFFProbe(on: mediaURL) {
                if let height = probe.height { label += " · \(height)p" }
                if durationText == nil, let seconds = probe.duration {
                    durationText = Self.formatDuration(seconds)
                }
                if sizeDetail == nil, let bytes = probe.sizeBytes {
                    sizeDetail = Self.sizeText(bytes: bytes)
                }
            }
            if sizeDetail == nil, let bytes = await headContentLength(of: mediaURL) {
                sizeDetail = Self.sizeText(bytes: bytes)
            }
            formats.append(FormatChoice(id: "best", label: label, detail: sizeDetail))
        }

        formats.append(FormatChoice(id: "audio", label: "仅音频 · m4a", detail: nil, isAudioOnly: true))

        return VideoInfo(
            sourceURL: sourceURL,
            videoID: videoID,
            title: title,
            durationText: durationText,
            thumbnailURL: thumbnailURL,
            uploader: uploader,
            formats: formats,
            subtitles: Self.parseSubtitles(json: json)
        )
    }

    // MARK: ffprobe / HEAD 补充信息

    private struct ProbeInfo {
        var height: Int?
        var duration: Double?
        var sizeBytes: Double?
    }

    private func runFFProbe(on urlString: String) async -> ProbeInfo? {
        guard let ffprobe = ffprobePath() else { return nil }
        guard let output = try? await Self.runProcess(
            executable: ffprobe,
            arguments: ["-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", urlString],
            timeout: 20
        ), output.status == 0,
        let object = try? JSONSerialization.jsonObject(with: output.stdout),
        let dict = object as? [String: Any] else { return nil }

        var info = ProbeInfo()
        if let streams = dict["streams"] as? [[String: Any]],
           let video = streams.first(where: { ($0["codec_type"] as? String) == "video" }) {
            info.height = Self.intValue(video["height"])
        }
        if let format = dict["format"] as? [String: Any] {
            info.duration = Self.doubleValue(format["duration"])
            info.sizeBytes = Self.doubleValue(format["size"])
        }
        return info
    }

    private func headContentLength(of urlString: String) async -> Double? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 15
        request.setValue(PageSniffer.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        let length = http.expectedContentLength
        return length > 0 ? Double(length) : nil
    }

    // MARK: 字幕

    private static let autoCaptionAllowList: Set<String> = ["zh-Hans", "zh-Hant", "zh", "en", "en-orig", "ja"]

    private static func parseSubtitles(json: [String: Any]) -> [SubtitleChoice] {
        let videoLangPrefix = (json["language"] as? String)?
            .split(separator: "-").first.map { String($0).lowercased() }

        let realDict = (json["subtitles"] as? [String: Any]) ?? [:]
        let realCodes = realDict.keys.filter { $0 != "live_chat" && $0 != "rechat" }
        var real = realCodes.map { SubtitleChoice(id: $0, label: subtitleLabel(for: $0), isAuto: false) }
        real.sort { subtitleSortKey($0.id) < subtitleSortKey($1.id) }

        let autoDict = (json["automatic_captions"] as? [String: Any]) ?? [:]
        let realSet = Set(realCodes)
        var autoCodes = autoDict.keys.filter { code in
            guard !realSet.contains(code) else { return false }
            if autoCaptionAllowList.contains(code) { return true }
            if let prefix = videoLangPrefix,
               code.split(separator: "-").first.map({ String($0).lowercased() }) == prefix {
                return true
            }
            return false
        }
        autoCodes.sort { subtitleSortKey($0) < subtitleSortKey($1) }
        let auto = autoCodes.prefix(8).map {
            SubtitleChoice(id: $0, label: subtitleLabel(for: $0), isAuto: true)
        }
        return real + auto
    }

    private static func subtitleLabel(for code: String) -> String {
        let locale = Locale(identifier: "zh_CN")
        if let name = locale.localizedString(forLanguageCode: code), !name.isEmpty {
            return "\(name) (\(code))"
        }
        return code
    }

    private static func subtitleSortKey(_ code: String) -> (Int, String) {
        let lower = code.lowercased()
        let rank: Int
        if lower.hasPrefix("zh") {
            rank = 0
        } else if lower == "en" || lower.hasPrefix("en-") {
            rank = 1
        } else if lower == "ja" || lower.hasPrefix("ja-") {
            rank = 2
        } else {
            rank = 3
        }
        return (rank, lower)
    }

    // MARK: - 第三步：下载

    public func download(
        _ request: DownloadRequest,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadResult {
        let ytdlp = try ytDlpPath()
        let ffmpegDir = try ffmpegDirectory()
        let destDir = request.destinationDirectory
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        var args: [String] = [
            "--no-playlist", "--newline", "--no-mtime",
            "--progress-template",
            "download:VDLP|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
            "--ffmpeg-location", ffmpegDir,
            "-P", destDir.path,
            "-o", "%(title).180B [%(id)s].%(ext)s",
        ]
        if request.formatID == "audio" {
            args += ["-f", "ba/b", "-x", "--audio-format", "m4a"]
        } else {
            args += ["-f", request.formatID, "--merge-output-format", "mp4"]
        }
        let allSubLangs = request.subtitleLangs + request.autoSubtitleLangs
        if !allSubLangs.isEmpty {
            args += ["--sub-langs", allSubLangs.joined(separator: ",")]
            if !request.subtitleLangs.isEmpty { args.append("--write-subs") }
            if !request.autoSubtitleLangs.isEmpty { args.append("--write-auto-subs") }
            args += ["--convert-subs", "srt"]
        }
        args.append(request.url)

        progress(DownloadProgress(phase: .preparing))

        let (status, stderrTail) = try await Self.runStreamingProcess(
            executable: ytdlp,
            arguments: args
        ) { line in
            Self.handleOutputLine(line, progress: progress)
        }

        guard status == 0 else {
            throw VDLError.downloadFailed(Self.friendlyDownloadReason(stderrTail: stderrTail))
        }
        progress(DownloadProgress(phase: .finished, percent: 100))

        let files = Self.collectOutputFiles(in: destDir, videoID: request.videoID)
        guard !files.isEmpty else {
            throw VDLError.downloadFailed("下载进程已结束，但在目标目录里没有找到产出文件。")
        }
        return DownloadResult(files: files)
    }

    private static let processingPrefixes = [
        "[Merger]", "[ExtractAudio]", "[SubtitleConvertor]", "[VideoConvertor]", "[Fixup",
    ]

    private static func handleOutputLine(
        _ line: String,
        progress: @Sendable (DownloadProgress) -> Void
    ) {
        if line.hasPrefix("VDLP|") {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            var percent: Double?
            if parts.count > 1 {
                percent = Double(parts[1].replacingOccurrences(of: "%", with: ""))
            }
            let speed = parts.count > 2 ? normalizeField(parts[2]) : nil
            let eta = parts.count > 3 ? normalizeField(parts[3]) : nil
            progress(DownloadProgress(
                phase: .downloading,
                percent: percent.map { min(max($0, 0), 100) },
                speedText: speed,
                etaText: eta
            ))
        } else if processingPrefixes.contains(where: { line.hasPrefix($0) }) {
            progress(DownloadProgress(phase: .processing))
        }
    }

    private static func normalizeField(_ value: String) -> String? {
        if value.isEmpty || value == "N/A" || value == "Unknown" { return nil }
        return value
    }

    private static func friendlyDownloadReason(stderrTail: String) -> String {
        if stderrTail.contains("Sign in to confirm") {
            return "YouTube 触发了风控验证，建议升级 yt-dlp（brew upgrade yt-dlp）后重试"
        }
        if stderrTail.contains("HTTP Error 403") || stderrTail.contains("403") {
            return "资源拒绝访问（403），可能存在防盗链或地区限制"
        }
        return summarizeStderr(stderrTail)
    }

    private static func collectOutputFiles(in directory: URL, videoID: String) -> [URL] {
        let marker = "[\(videoID)]"
        let subtitleExts: Set<String> = ["srt", "vtt", "ass", "ssa", "lrc", "ttml"]
        let tempExts: Set<String> = ["part", "ytdl", "temp"]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }
        let matched = contents.filter {
            $0.lastPathComponent.contains(marker) && !tempExts.contains($0.pathExtension.lowercased())
        }
        let videos = matched.filter { !subtitleExts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let subs = matched.filter { subtitleExts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return videos + subs
    }

    // MARK: - 进程执行

    /// 一次性进程：整体收集 stdout/stderr，可选超时；支持任务取消。
    private static func runProcess(
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async throws -> ProcessOutput {
        let box = ProcessBox()
        let output: ProcessOutput = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessOutput, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments
                    process.standardInput = FileHandle.nullDevice
                    let outPipe = Pipe()
                    let errPipe = Pipe()
                    process.standardOutput = outPipe
                    process.standardError = errPipe

                    do {
                        try process.run()
                    } catch {
                        let name = (executable as NSString).lastPathComponent
                        continuation.resume(throwing: VDLError.analyzeFailed("无法启动 \(name)：\(error.localizedDescription)"))
                        return
                    }
                    if box.register(process) { process.terminate() }

                    var timeoutItem: DispatchWorkItem?
                    if let timeout {
                        let item = DispatchWorkItem {
                            if process.isRunning {
                                box.markTimedOut()
                                process.terminate()
                            }
                        }
                        timeoutItem = item
                        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
                    }

                    // 并发读两个管道，避免输出过大时互相阻塞。
                    let outBuf = DataBuffer()
                    let errBuf = DataBuffer()
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global().async {
                        outBuf.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                        group.leave()
                    }
                    group.enter()
                    DispatchQueue.global().async {
                        errBuf.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                        group.leave()
                    }
                    process.waitUntilExit()
                    group.wait()
                    timeoutItem?.cancel()

                    continuation.resume(returning: ProcessOutput(
                        status: process.terminationStatus,
                        stdout: outBuf.data,
                        stderr: errBuf.data,
                        timedOut: box.timedOut
                    ))
                }
            }
        } onCancel: {
            box.cancel()
        }
        if box.isCancelled { throw VDLError.cancelled }
        return output
    }

    /// 流式进程：stdout 按行回调（处理半行到达），stderr 保留尾部 16KB。
    private static func runStreamingProcess(
        executable: String,
        arguments: [String],
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> (status: Int32, stderrTail: String) {
        let state = StreamingState()
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardInput = FileHandle.nullDevice
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        return
                    }
                    for line in state.consumeLines(appending: data) { onLine(line) }
                }
                errPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        return
                    }
                    state.appendStderr(data)
                }
                process.terminationHandler = { finished in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    if let rest = try? outPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                        for line in state.consumeLines(appending: rest) { onLine(line) }
                    }
                    for line in state.flushRemainder() { onLine(line) }
                    if let rest = try? errPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                        state.appendStderr(rest)
                    }
                    let status = finished.terminationStatus
                    state.resumeOnce { continuation.resume(returning: status) }
                }

                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    state.resumeOnce {
                        continuation.resume(throwing: VDLError.downloadFailed("无法启动 yt-dlp：\(error.localizedDescription)"))
                    }
                    return
                }
                if state.register(process) { process.terminate() }
            }
        } onCancel: {
            state.cancel()
        }
        if state.isCancelled { throw VDLError.cancelled }
        return (status, state.stderrTail)
    }

    // MARK: - 杂项

    private static func isYouTubeHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "youtu.be"
            || h == "youtube.com" || h.hasSuffix(".youtube.com")
            || h == "youtube-nocookie.com" || h.hasSuffix(".youtube-nocookie.com")
    }

    private static func friendlyAnalyzeReason(stderr: String) -> String {
        if stderr.contains("Sign in to confirm") {
            return "YouTube 触发了风控验证，建议升级 yt-dlp（brew upgrade yt-dlp）后重试"
        }
        return summarizeStderr(stderr)
    }

    private static func summarizeStderr(_ text: String) -> String {
        let lines = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let errorLine = lines.last(where: { $0.hasPrefix("ERROR") }) ?? lines.last ?? "未知错误"
        return String(errorLine.prefix(200))
    }

    private static func intValue(_ any: Any?) -> Int? {
        (any as? NSNumber)?.intValue
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let number = any as? NSNumber { return number.doubleValue }
        if let string = any as? String { return Double(string) }
        return nil
    }

    private static func bestAudioSizeBytes(in formats: [[String: Any]]) -> Double? {
        let audioOnly = formats.filter { format in
            let acodec = format["acodec"] as? String
            let vcodec = format["vcodec"] as? String
            return acodec != nil && acodec != "none" && (vcodec == nil || vcodec == "none")
        }
        let best = audioOnly.max {
            (doubleValue($0["abr"]) ?? doubleValue($0["tbr"]) ?? 0)
                < (doubleValue($1["abr"]) ?? doubleValue($1["tbr"]) ?? 0)
        }
        guard let best else { return nil }
        return doubleValue(best["filesize"]) ?? doubleValue(best["filesize_approx"])
    }

    private static func sizeText(bytes: Double) -> String {
        let mb = bytes / 1_048_576
        return "≈ \(max(1, Int(mb.rounded()))) MB"
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
