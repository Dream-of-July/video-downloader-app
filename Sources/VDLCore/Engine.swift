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

/// 收集 yt-dlp --print 输出的产出文件路径（输出回调线程并发追加）。
private final class PathCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    func append(_ path: String) {
        lock.lock()
        if !paths.contains(path) { paths.append(path) }
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
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
        guard let p, p.isRunning else { return }
        // 先发 SIGINT，让 yt-dlp 走自身的 KeyboardInterrupt 清理逻辑；
        // 3 秒后仍未退出则先杀 ffmpeg 等子进程，再强杀 yt-dlp 本身。
        p.interrupt()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            guard p.isRunning else { return }
            let pid = p.processIdentifier
            for child in Self.childProcessIDs(of: pid) {
                kill(child, SIGKILL)
            }
            if p.isRunning { kill(pid, SIGKILL) }
        }
    }

    /// 用 pgrep 找直接子进程（ffmpeg 等）。
    private static func childProcessIDs(of pid: Int32) -> [Int32] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice
        do { try pgrep.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        pgrep.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
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
    /// analyze 阶段从 HLS master m3u8 解析出的字幕表：sourceURL -> [langCode: 字幕 m3u8 绝对 URL]。
    /// download 阶段据此用 ffmpeg 取这些 yt-dlp 拿不到的 HLS 内嵌字幕。
    private var hlsSubtitleCache: [String: [String: String]] = [:]

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

    /// HLS 字幕转 srt 用的 ffmpeg：与 Burner 一致优先 ffmpeg-full，其次 Homebrew ffmpeg。
    /// （转 srt 不需要 libass，但统一定位逻辑、避免精简版边角问题。）
    private static func locateSubtitleFFmpeg() -> String? {
        let fm = FileManager.default
        let candidates = [
            "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg",
            "/usr/local/opt/ffmpeg-full/bin/ffmpeg",
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) { return path }
        return locateBinary(named: "ffmpeg", envVar: "VDL_FFMPEG_PATH")
    }

    private func ffprobePath() -> String? {
        Self.locateBinary(named: "ffprobe", envVar: "VDL_FFPROBE_PATH")
    }

    /// 子进程环境。GUI App 从 Finder 启动时 PATH 只有系统目录，而 yt-dlp 解
    /// YouTube 的 n-challenge 必须能找到 Homebrew 里的 deno/node（JS 运行时），
    /// 否则所有视频格式都会被跳过（"Requested format is not available"）。
    static func subprocessEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        var parts = (env["PATH"] ?? "/usr/bin:/bin").components(separatedBy: ":")
        for dir in ["/usr/local/bin", "/opt/homebrew/bin"] where !parts.contains(dir) {
            parts.insert(dir, at: 0)
        }
        env["PATH"] = parts.joined(separator: ":")
        return env
    }

    // MARK: 站点登录 cookies

    /// 站点登录导出的 cookies 文件存在时，所有 yt-dlp 调用都带上 --cookies。
    private static func cookieArguments() -> [String] {
        let cookieFile = AppSettings.cookieFileURL
        guard FileManager.default.fileExists(atPath: cookieFile.path) else { return [] }
        return ["--cookies", cookieFile.path]
    }

    /// 识别"需要登录"类错误。命中返回 loginRequired（或已登录时的过期文案），否则返回 nil 走常规文案。
    private static func detectLoginRequired(stderr: String, url urlString: String) -> VDLError? {
        let hasCookies = FileManager.default.fileExists(atPath: AppSettings.cookieFileURL.path)
        if stderr.contains("Sign in to confirm") {
            // 已登录过仍被风控：再弹登录窗没有意义，提示重新登录或稍后重试。
            if hasCookies {
                return .downloadFailed("YouTube 要求确认登录状态。登录信息可能已过期，可在设置里重新登录，或稍后重试。")
            }
            return .loginRequired("youtube.com")
        }
        let host = (URL(string: urlString)?.host ?? "").lowercased()
        // YouTube 的 403 实质是 PO token / 未登录，登录 cookies 是正解；其他站点的 403 保持防盗链文案。
        // 只看最后一条 ERROR 行，避免中间分片的瞬时 403 被误判成需要登录。
        if isYouTubeHost(host), summarizeStderr(stderr).contains("HTTP Error 403") {
            if hasCookies {
                return .downloadFailed("YouTube 拒绝了请求（403）。登录信息可能已过期，可在设置里重新登录，或稍后重试。")
            }
            return .loginRequired("youtube.com")
        }
        let pattern = "login required|need to log ?in|account cookies|members?[- ]only|大会员|请登录"
        if stderr.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            var site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            if site.isEmpty { site = "该站点" }
            return .loginRequired(site)
        }
        return nil
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

    private func cachedHLSSubtitles(for url: String) -> [String: String]? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return hlsSubtitleCache[url]
    }

    private func setCachedHLSSubtitles(_ table: [String: String], for url: String) {
        cacheLock.lock()
        hlsSubtitleCache[url] = table
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
            if let loginError = Self.detectLoginRequired(stderr: stderr, url: trimmed) {
                throw loginError
            }
            if Self.isYouTubeHost(url.host ?? "") {
                throw VDLError.analyzeFailed(Self.friendlyAnalyzeMessage(stderr))
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
                if let loginError = Self.detectLoginRequired(stderr: stderr, url: trimmed) {
                    throw loginError
                }
                throw VDLError.analyzeFailed(Self.friendlyAnalyzeMessage(stderr))
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
        var lastStderr = ""
        for attempt in 0..<2 {
            let output = try await Self.runProcess(
                executable: ytdlp,
                arguments: ["-J", "--no-playlist", "--ffmpeg-location", ffmpegDir]
                    + Self.cookieArguments() + [url],
                timeout: 60
            )
            if output.timedOut {
                throw VDLError.analyzeFailed("解析超时，请检查网络后重试")
            }
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
            lastStderr = String(decoding: output.stderr, as: UTF8.self)
            // YouTube 偶发返回空格式列表（"Requested format is not available"），
            // 属临时风控，隔 2 秒自动重试一次。
            if attempt == 0, lastStderr.contains("Requested format is not available") {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { throw VDLError.cancelled }
                continue
            }
            break
        }
        return .failure(stderr: lastStderr)
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

            // 最高档直接排第一（formats[0] 为推荐项），用通配格式串拿最佳画质。
            for (index, height) in heights.prefix(6).enumerated() {
                let formatID = index == 0
                    ? "bv*+ba/b"
                    : "bv*[height<=\(height)]+ba/b[height<=\(height)]"
                formats.append(FormatChoice(
                    id: formatID,
                    label: "\(height)p · mp4",
                    detail: tierDetail(height)
                ))
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

        var subtitles = Self.parseSubtitles(json: json)
        // yt-dlp 没给字幕时（如 Apple WWDC 等走 generic/HLS 提取器的页面，字幕只存在于
        // HLS master manifest 里且被 yt-dlp 主动忽略），从 manifest 兜底解析内嵌字幕。
        if subtitles.isEmpty {
            let (choices, table) = await discoverHLSSubtitles(in: rawFormats)
            if !choices.isEmpty {
                subtitles = choices
                setCachedHLSSubtitles(table, for: sourceURL)
            }
        }

        return VideoInfo(
            sourceURL: sourceURL,
            videoID: videoID,
            title: title,
            durationText: durationText,
            thumbnailURL: thumbnailURL,
            uploader: uploader,
            formats: formats,
            subtitles: subtitles
        )
    }

    // MARK: HLS manifest 内嵌字幕兜底

    /// 从 formats 的 manifest_url 抓取 HLS master m3u8，解析其中的 EXT-X-MEDIA:TYPE=SUBTITLES，
    /// 返回（SubtitleChoice 列表, [langCode: 字幕 m3u8 绝对 URL]）。失败返回空，绝不抛错（不能让 analyze 失败）。
    private func discoverHLSSubtitles(
        in formats: [[String: Any]]
    ) async -> (choices: [SubtitleChoice], table: [String: String]) {
        guard let manifest = formats.compactMap({ $0["manifest_url"] as? String })
            .first(where: { !$0.isEmpty }),
              let masterURL = URL(string: manifest),
              let text = await Self.fetchText(url: masterURL) else {
            return ([], [:])
        }
        let entries = Self.parseHLSSubtitleEntries(master: text, baseURL: masterURL)
        guard !entries.isEmpty else { return ([], [:]) }

        var table: [String: String] = [:]
        var seen = Set<String>()
        var choices: [SubtitleChoice] = []
        // 中文优先排序，最多保留 30 条。
        let sorted = entries.sorted { Self.subtitleSortKey($0.lang) < Self.subtitleSortKey($1.lang) }
        for entry in sorted.prefix(30) {
            guard !seen.contains(entry.lang) else { continue }
            seen.insert(entry.lang)
            table[entry.lang] = entry.url
            let label: String
            let localized = Self.subtitleLabel(for: entry.lang)
            // subtitleLabel 认得的语言用本地化名，否则退回 manifest 里的 NAME。
            if localized != entry.lang {
                label = localized
            } else if let name = entry.name, !name.isEmpty {
                label = "\(name) (\(entry.lang))"
            } else {
                label = entry.lang
            }
            choices.append(SubtitleChoice(id: entry.lang, label: label, isAuto: false))
        }
        return (choices, table)
    }

    private struct HLSSubtitleEntry {
        let lang: String
        let name: String?
        let url: String
    }

    /// 解析 master m3u8 文本里所有 TYPE=SUBTITLES 的媒体行；URI 相对 baseURL 解析为绝对地址。
    private static func parseHLSSubtitleEntries(master: String, baseURL: URL) -> [HLSSubtitleEntry] {
        var entries: [HLSSubtitleEntry] = []
        for line in master.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#EXT-X-MEDIA:"), trimmed.contains("TYPE=SUBTITLES") else { continue }
            guard let lang = attribute("LANGUAGE", in: trimmed), !lang.isEmpty,
                  let uri = attribute("URI", in: trimmed), !uri.isEmpty else { continue }
            let resolved: String
            if let abs = URL(string: uri), abs.scheme != nil {
                resolved = abs.absoluteString
            } else if let rel = URL(string: uri, relativeTo: baseURL) {
                resolved = rel.absoluteString
            } else {
                continue
            }
            entries.append(HLSSubtitleEntry(lang: lang, name: attribute("NAME", in: trimmed), url: resolved))
        }
        return entries
    }

    /// 从 EXT-X-MEDIA 行里取属性值（支持带引号与不带引号）。
    private static func attribute(_ key: String, in line: String) -> String? {
        guard let range = line.range(of: key + "=") else { return nil }
        let rest = line[range.upperBound...]
        if rest.first == "\"" {
            let afterQuote = rest.dropFirst()
            guard let end = afterQuote.firstIndex(of: "\"") else { return nil }
            return String(afterQuote[..<end])
        }
        let end = rest.firstIndex(of: ",") ?? rest.endIndex
        return String(rest[..<end]).trimmingCharacters(in: .whitespaces)
    }

    /// 同步等待的文本抓取（Safari UA、15s 超时）。失败返回 nil。
    private static func fetchText(url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(PageSniffer.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return String(decoding: data, as: UTF8.self)
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

    /// preferredTitle 作为字面量进入 yt-dlp 输出模板：需转义 %、去掉路径分隔符并限长。
    private static func outputTemplate(preferredTitle: String?) -> String {
        guard let raw = preferredTitle else { return "%(title).180B [%(id)s].%(ext)s" }
        var clean = raw.replacingOccurrences(of: "%", with: "%%")
        clean = clean
            .components(separatedBy: CharacterSet(charactersIn: "/\\:\0"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.count > 120 { clean = String(clean.prefix(120)) }
        guard !clean.isEmpty else { return "%(title).180B [%(id)s].%(ext)s" }
        return "\(clean) [%(id)s].%(ext)s"
    }

    public func download(
        _ request: DownloadRequest,
        control: TaskControlToken?,
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
            "-o", Self.outputTemplate(preferredTitle: request.preferredTitle),
        ]
        args += Self.cookieArguments()
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
        // --print 默认隐含 simulate/quiet，必须配 --no-simulate / --no-quiet 抵消。
        args += ["--print", "after_move:filepath", "--no-simulate", "--no-quiet"]
        args.append(request.url)

        progress(DownloadProgress(phase: .preparing))

        // control 已请求取消：不必启动子进程。
        if control?.isCancelled == true { throw VDLError.cancelled }

        let destPrefix = destDir.path.hasSuffix("/") ? destDir.path : destDir.path + "/"
        let printedPaths = PathCollector()
        let status: Int32
        let stderrTail: String
        do {
            (status, stderrTail) = try await Self.runStreamingProcess(
                executable: ytdlp,
                arguments: args,
                onStart: { pid in
                    // 登记主下载进程 pid：暂停时 TaskControlToken 向其进程树
                    // （含派生的 ffmpeg）发 SIGSTOP/SIGCONT。
                    control?.setActivePID(pid)
                }
            ) { line in
                Self.handleOutputLine(line, progress: progress)
                if line.hasPrefix(destPrefix) { printedPaths.append(line) }
            }
            control?.setActivePID(0)
        } catch {
            control?.setActivePID(0)
            // 取消路径：进程已确认退出，先清掉残留的临时文件再上抛。
            if case VDLError.cancelled = error {
                Self.cleanupTemporaryFiles(in: destDir, videoID: request.videoID)
            }
            throw error
        }

        guard status == 0 else {
            if let loginError = Self.detectLoginRequired(stderr: stderrTail, url: request.url) {
                throw loginError
            }
            throw VDLError.downloadFailed(Self.friendlyDownloadReason(stderrTail: stderrTail))
        }
        progress(DownloadProgress(phase: .finished, percent: 100))

        // 优先用 --print after_move:filepath 的精确产出；目录扫描降级为兜底。
        let fm = FileManager.default
        var files = printedPaths.values
            .map { URL(fileURLWithPath: $0) }
            .filter { fm.fileExists(atPath: $0.path) }
        if files.isEmpty {
            files = Self.collectOutputFiles(in: destDir, videoID: request.videoID)
        } else if !allSubLangs.isEmpty {
            // --print 不会打印字幕文件，用目录扫描补齐字幕。
            let known = Set(files.map(\.path))
            files += Self.collectOutputFiles(in: destDir, videoID: request.videoID).filter {
                Self.subtitleExtensions.contains($0.pathExtension.lowercased()) && !known.contains($0.path)
            }
        }
        guard !files.isEmpty else {
            throw VDLError.downloadFailed("下载进程已结束，但在目标目录里没有找到产出文件。")
        }

        // yt-dlp 取不到的字幕（如 Apple WWDC 等只存在于 HLS manifest 里的字幕）：
        // 检测请求的字幕里哪些没落地 .srt，对缺失的 lang 用 ffmpeg 从 HLS 字幕 m3u8 转出。
        if !allSubLangs.isEmpty {
            let videoFile = files.first {
                !Self.subtitleExtensions.contains($0.pathExtension.lowercased())
            }
            if let videoFile {
                let presentLangs = Set(files
                    .filter { $0.pathExtension.lowercased() == "srt" }
                    .compactMap { Self.langCode(ofSubtitle: $0) })
                let missing = allSubLangs.filter { !presentLangs.contains($0.lowercased()) }
                if !missing.isEmpty {
                    let table = await hlsSubtitleTable(for: request.url)
                    for lang in missing {
                        guard let m3u8 = table[lang] else { continue }
                        if let srt = await Self.fetchHLSSubtitle(
                            m3u8: m3u8, lang: lang, videoFile: videoFile
                        ), !files.contains(srt) {
                            files.append(srt)
                        }
                    }
                }
            }
        }
        return DownloadResult(files: files)
    }

    /// 取 sourceURL 的 HLS 字幕表：优先用 analyze 阶段缓存（GUI 同一引擎实例命中）；
    /// 缓存缺失（如 CLI download 独立进程）时按需重新拉 JSON + 解析 manifest。
    private func hlsSubtitleTable(for url: String) async -> [String: String] {
        if let cached = cachedHLSSubtitles(for: url) { return cached }
        let json: [String: Any]
        if let info = cachedInfo(for: url) {
            json = info
        } else if case .success(let dict) = (try? await runYtDlpJSON(for: url)) ?? .failure(stderr: "") {
            json = dict
        } else {
            return [:]
        }
        let rawFormats = (json["formats"] as? [[String: Any]]) ?? []
        let (_, table) = await discoverHLSSubtitles(in: rawFormats)
        if !table.isEmpty { setCachedHLSSubtitles(table, for: url) }
        return table
    }

    /// 从字幕文件名 "<名>.<lang>.srt" 解析出 lang code（小写）。
    private static func langCode(ofSubtitle file: URL) -> String? {
        let stem = file.deletingPathExtension().lastPathComponent
        guard let dotIndex = stem.lastIndex(of: ".") else { return nil }
        return String(stem[stem.index(after: dotIndex)...]).lowercased()
    }

    /// 用 ffmpeg 把单语 HLS 字幕 m3u8 转成 srt，输出 "<视频名去扩展>.<lang>.srt"。
    /// 失败返回 nil（记日志、跳过该 lang，不影响整体下载）。
    private static func fetchHLSSubtitle(m3u8: String, lang: String, videoFile: URL) async -> URL? {
        let ffmpeg = locateSubtitleFFmpeg()
        guard let ffmpeg else {
            FileHandle.standardError.write(Data("HLS 字幕转换跳过（找不到 ffmpeg）：\(lang)\n".utf8))
            return nil
        }
        let stem = videoFile.deletingPathExtension().lastPathComponent
        let output = videoFile.deletingLastPathComponent()
            .appendingPathComponent("\(stem).\(lang).srt")
        try? FileManager.default.removeItem(at: output)
        let result = try? await runStreamingProcess(
            executable: ffmpeg,
            arguments: ["-y", "-i", m3u8, output.path],
            onLine: { _ in }
        )
        if let result, result.status == 0,
           FileManager.default.fileExists(atPath: output.path) {
            return output
        }
        FileHandle.standardError.write(Data("HLS 字幕转换失败，已跳过：\(lang)\n".utf8))
        return nil
    }

    /// 取消后清理 yt-dlp 留下的临时文件（.part / .ytdl / 分片 .part-Frag…）。
    private static func cleanupTemporaryFiles(in directory: URL, videoID: String) {
        let marker = "[\(videoID)]"
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for file in contents {
            let name = file.lastPathComponent
            guard name.contains(marker) else { continue }
            let ext = file.pathExtension.lowercased()
            if ext == "part" || ext == "ytdl" || name.contains(".part-Frag") {
                try? FileManager.default.removeItem(at: file)
            }
        }
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

    /// 两段式文案：中文主句 + 换行 + 原始 ERROR 行（截断 200 字符），UI 分层展示。
    /// 需要登录的情况已在上游由 detectLoginRequired 拦截为 loginRequired。
    private static func friendlyDownloadReason(stderrTail: String) -> String {
        let rawLine = summarizeStderr(stderrTail)
        if stderrTail.contains("HTTP Error 403") || stderrTail.contains("403 Forbidden") {
            return "资源拒绝访问（403），可能存在防盗链或地区限制。可先在浏览器确认视频能正常播放，或换一个候选来源。\n" + rawLine
        }
        return "下载过程中出现错误。\n" + rawLine
    }

    private static let subtitleExtensions: Set<String> = ["srt", "vtt", "ass", "ssa", "lrc", "ttml"]

    private static func collectOutputFiles(in directory: URL, videoID: String) -> [URL] {
        let marker = "[\(videoID)]"
        let tempExts: Set<String> = ["part", "ytdl", "temp"]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }
        let matched = contents.filter {
            $0.lastPathComponent.contains(marker) && !tempExts.contains($0.pathExtension.lowercased())
        }
        let videos = matched.filter { !subtitleExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let subs = matched.filter { subtitleExtensions.contains($0.pathExtension.lowercased()) }
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
                    process.environment = Self.subprocessEnvironment()
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
    /// internal：Burner 复用它跑 ffmpeg/ffprobe。currentDirectory 为 nil 时不改工作目录。
    /// onStart 非空时在子进程成功启动后回调其 pid（用于登记到 TaskControlToken 实现暂停）；
    /// 默认 nil 不改变现有调用行为。
    static func runStreamingProcess(
        executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        onStart: (@Sendable (Int32) -> Void)? = nil,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> (status: Int32, stderrTail: String) {
        let state = StreamingState()
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = Self.subprocessEnvironment()
                if let currentDirectory { process.currentDirectoryURL = currentDirectory }
                process.standardInput = FileHandle.nullDevice
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                // 两条管道各自读到 EOF 后 leave；收尾统一等待，
                // 消除 terminationHandler 与在途回调并发读同一管道的竞态。
                let ioGroup = DispatchGroup()
                ioGroup.enter()
                ioGroup.enter()

                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        ioGroup.leave()
                        return
                    }
                    for line in state.consumeLines(appending: data) { onLine(line) }
                }
                errPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        ioGroup.leave()
                        return
                    }
                    state.appendStderr(data)
                }
                process.terminationHandler = { finished in
                    let status = finished.terminationStatus
                    DispatchQueue.global().async {
                        // 等两条管道 EOF（带兜底超时，防极端情况下挂起）再收尾。
                        _ = ioGroup.wait(timeout: .now() + 5)
                        outPipe.fileHandleForReading.readabilityHandler = nil
                        errPipe.fileHandleForReading.readabilityHandler = nil
                        for line in state.flushRemainder() { onLine(line) }
                        state.resumeOnce { continuation.resume(returning: status) }
                    }
                }

                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    // 子进程未启动，管道不会有数据/EOF，手动配平 ioGroup。
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    ioGroup.leave()
                    ioGroup.leave()
                    state.resumeOnce {
                        continuation.resume(throwing: VDLError.downloadFailed("无法启动 yt-dlp：\(error.localizedDescription)"))
                    }
                    return
                }
                if state.register(process) { state.cancel() }
                else { onStart?(process.processIdentifier) }
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

    /// 解析阶段错误的中文化（自动重试一次后仍失败才会走到这里）。
    private static func friendlyAnalyzeMessage(_ stderr: String) -> String {
        if stderr.contains("Requested format is not available") {
            return "站点暂时没有返回可用的清晰度（多为临时风控），请稍后重试；若反复出现，可在设置里重新登录。"
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
