import Foundation

// MARK: - 默认烧录器

public func makeBurner() -> any SubtitleBurner {
    FFmpegBurner()
}

// MARK: - FFmpegBurner

/// ffmpeg subtitles 滤镜硬烧录中文字幕：优先 h264_videotoolbox 硬编码，失败回退 libx264。
public struct FFmpegBurner: SubtitleBurner {

    public init() {}

    // 烧录需要带 libass 的 ffmpeg（subtitles 滤镜）。Homebrew 镜像的 ffmpeg 可能是
    // 无 libass 的精简版，因此优先找 keg-only 的 ffmpeg-full。
    private static let searchPaths = [
        "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg",
        "/usr/local/opt/ffmpeg-full/bin/ffmpeg",
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
    ]

    private static func locate(_ name: String) -> String? {
        if name == "ffmpeg" {
            if let custom = ProcessInfo.processInfo.environment["VDL_BURN_FFMPEG_PATH"],
               !custom.isEmpty, FileManager.default.isExecutableFile(atPath: custom) {
                return custom
            }
            for path in searchPaths where FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
            return nil
        }
        for dir in ["/opt/homebrew/bin", "/usr/local/bin"] {
            let path = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    public func burn(
        video: URL,
        subtitle: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard let ffmpeg = Self.locate("ffmpeg") else {
            throw VDLError.binaryNotFound("ffmpeg")
        }

        // 1. ffprobe 取时长与码率（取不到不阻塞烧录，只影响进度显示与码率档位）
        let probe = await Self.probe(video: video)
        let bitrateK = Self.clampedBitrateK(probe.bitRateBPS)

        // 2. 临时目录：字幕拷成 subs.srt 并把 ffmpeg 工作目录设到这里，
        //    规避 subtitles 滤镜对路径里冒号/引号/中文的转义问题。
        let fm = FileManager.default
        let tempDir = URL(fileURLWithPath: "/tmp/vdl-burn-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            try fm.copyItem(at: subtitle, to: tempDir.appendingPathComponent("subs.srt"))
        } catch {
            try? fm.removeItem(at: tempDir)
            throw VDLError.burnFailed("无法准备临时目录：\(error.localizedDescription)")
        }
        defer { try? fm.removeItem(at: tempDir) }

        // 3. 滤镜与参数
        let filter = "subtitles=subs.srt:force_style="
            + "'FontName=PingFang SC,FontSize=15,Outline=1,Shadow=0,MarginV=20'"
        let head = ["-y", "-i", video.path, "-vf", filter]
        func tail(audio: [String]) -> [String] {
            audio + ["-movflags", "+faststart", "-nostats", "-progress", "pipe:1", "out.mp4"]
        }
        let copyAudio = ["-c:a", "copy"]
        let aacAudio = ["-c:a", "aac", "-b:a", "192k"]
        let hardwareVideo = ["-c:v", "h264_videotoolbox", "-b:v", "\(bitrateK)k"]
        let softwareVideo = ["-c:v", "libx264", "-crf", "20", "-preset", "veryfast"]

        // 4. 跑 ffmpeg，stdout 的 -progress 输出换算进度
        let totalSeconds = probe.duration
        func run(_ arguments: [String]) async throws -> (status: Int32, stderrTail: String) {
            try await YtDlpEngine.runStreamingProcess(
                executable: ffmpeg,
                arguments: arguments,
                currentDirectory: tempDir
            ) { line in
                if let fraction = Self.parseProgress(line: line, totalSeconds: totalSeconds) {
                    progress(fraction)
                }
            }
        }

        var videoCodecArgs = hardwareVideo
        var (status, stderrTail) = try await run(head + videoCodecArgs + tail(audio: copyAudio))

        // 5. videotoolbox 编码器初始化失败 → libx264 重试一次（判据收窄到硬编码自身的报错）
        if status != 0 {
            let lower = stderrTail.lowercased()
            if lower.contains("videotoolbox") || lower.contains("cannot create compression session") {
                videoCodecArgs = softwareVideo
                try? fm.removeItem(at: tempDir.appendingPathComponent("out.mp4"))
                (status, stderrTail) = try await run(head + videoCodecArgs + tail(audio: copyAudio))
            }
        }
        // 5b. 原音轨无法直接 copy 进 mp4 容器 → 转码 aac 重试一次
        if status != 0 {
            let lower = stderrTail.lowercased()
            let audioCopyFailed = lower.contains("could not find tag")
                || lower.contains("incompatible")
                || lower.contains("codec not currently supported in container")
            if audioCopyFailed {
                try? fm.removeItem(at: tempDir.appendingPathComponent("out.mp4"))
                (status, stderrTail) = try await run(head + videoCodecArgs + tail(audio: aacAudio))
            }
        }
        guard status == 0 else {
            let lower = stderrTail.lowercased()
            if lower.contains("error parsing filterchain") || lower.contains("no such filter") {
                throw VDLError.burnFailed(
                    "当前 ffmpeg 不带字幕渲染组件（libass）。请安装完整版后重试：brew install ffmpeg-full"
                )
            }
            throw VDLError.burnFailed(Self.lastLine(of: stderrTail))
        }
        let produced = tempDir.appendingPathComponent("out.mp4")
        guard fm.fileExists(atPath: produced.path) else {
            throw VDLError.burnFailed("ffmpeg 已退出，但没有生成输出文件。")
        }
        progress(1)

        // 6. 移到视频同目录："<原名>（中文字幕）.mp4"，重名时加 " 2"、" 3"…
        let stem = video.deletingPathExtension().lastPathComponent
        let directory = video.deletingLastPathComponent()
        var destination = directory.appendingPathComponent("\(stem)（中文字幕）.mp4")
        var serial = 2
        while fm.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(stem)（中文字幕） \(serial).mp4")
            serial += 1
        }
        do {
            try fm.moveItem(at: produced, to: destination)
        } catch {
            throw VDLError.burnFailed("无法移动输出文件：\(error.localizedDescription)")
        }
        return destination
    }

    // MARK: ffprobe

    private struct ProbeResult {
        var duration: Double?
        var bitRateBPS: Double?
    }

    /// 收集 ffprobe 的多行 JSON 输出（onLine 回调线程并发追加）。
    private final class LineSink: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func append(_ line: String) {
            lock.lock()
            lines.append(line)
            lock.unlock()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return lines.joined(separator: "\n")
        }
    }

    private static func probe(video: URL) async -> ProbeResult {
        guard let ffprobe = locate("ffprobe") else { return ProbeResult() }
        let sink = LineSink()
        guard let (status, _) = try? await YtDlpEngine.runStreamingProcess(
            executable: ffprobe,
            arguments: ["-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", video.path],
            onLine: { sink.append($0) }
        ), status == 0,
        let object = try? JSONSerialization.jsonObject(with: Data(sink.text.utf8)),
        let dict = object as? [String: Any] else { return ProbeResult() }

        var result = ProbeResult()
        if let format = dict["format"] as? [String: Any] {
            result.duration = double(format["duration"])
            result.bitRateBPS = double(format["bit_rate"])
        }
        if result.bitRateBPS == nil,
           let streams = dict["streams"] as? [[String: Any]],
           let videoStream = streams.first(where: { ($0["codec_type"] as? String) == "video" }) {
            result.bitRateBPS = double(videoStream["bit_rate"])
        }
        return result
    }

    private static func double(_ any: Any?) -> Double? {
        if let number = any as? NSNumber { return number.doubleValue }
        if let string = any as? String { return Double(string) }
        return nil
    }

    // MARK: 进度与参数

    /// 源码率换算 -b:v 的 k 值：缺省 5000，夹在 2000...12000。
    private static func clampedBitrateK(_ bps: Double?) -> Int {
        guard let bps, bps > 0 else { return 5000 }
        return min(max(Int(bps / 1000), 2000), 12000)
    }

    /// 解析 -progress pipe:1 输出。out_time_ms 与 out_time_us 的值都是微秒。
    private static func parseProgress(line: String, totalSeconds: Double?) -> Double? {
        guard let total = totalSeconds, total > 0 else { return nil }
        for prefix in ["out_time_ms=", "out_time_us="] where line.hasPrefix(prefix) {
            let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            guard let microseconds = Double(value) else { return nil }
            return min(max((microseconds / 1_000_000) / total, 0), 1)
        }
        return nil
    }

    private static func lastLine(of stderr: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return String((lines.last ?? "未知错误").prefix(200))
    }
}
