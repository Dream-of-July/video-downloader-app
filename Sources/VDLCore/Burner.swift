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

        // 2. 临时目录：字幕转成 subs.ass 并把 ffmpeg 工作目录设到这里，
        //    规避 subtitles 滤镜对路径里冒号/引号/中文的转义问题。
        //    用 ASS 而非 SRT 是为了双语两种字号：中文（首行）正常字号，原文（次行）更小。
        let fm = FileManager.default
        let tempDir = URL(fileURLWithPath: "/tmp/vdl-burn-\(UUID().uuidString)", isDirectory: true)
        let filter: String
        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let srtText = try String(contentsOf: subtitle, encoding: .utf8)
            let cues = parseSRT(srtText)
            if cues.isEmpty {
                // 解析不出来就按原样走 SRT + force_style 的老路
                try fm.copyItem(at: subtitle, to: tempDir.appendingPathComponent("subs.srt"))
                filter = "subtitles=subs.srt:force_style="
                    + "'FontName=PingFang SC,FontSize=15,Outline=1,Shadow=0,MarginV=20'"
            } else {
                let ass = Self.makeASS(cues: cues)
                try ass.write(
                    to: tempDir.appendingPathComponent("subs.ass"),
                    atomically: true, encoding: .utf8
                )
                filter = "subtitles=subs.ass"
            }
        } catch let error as VDLError {
            try? fm.removeItem(at: tempDir)
            throw error
        } catch {
            try? fm.removeItem(at: tempDir)
            throw VDLError.burnFailed("无法准备字幕临时文件：\(error.localizedDescription)")
        }
        defer { try? fm.removeItem(at: tempDir) }

        // 3. 滤镜与参数
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

    // MARK: ASS 生成（双语两级字号）

    private static let chineseFontSize = 15
    private static let originalFontSize = 11

    /// 把 SRT 字幕转成 ASS：双语条目（首行含中日韩文字、其余行不含）首行用正常字号，
    /// 其余行（原文）用更小字号；普通条目整条统一字号。
    static func makeASS(cues: [SubtitleCue]) -> String {
        var dialogues: [String] = []
        for cue in cues {
            guard let start = assTimestamp(cue.start), let end = assTimestamp(cue.end) else {
                continue
            }
            let lines = cue.text
                .components(separatedBy: "\n")
                .map(escapeASSText)
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { continue }

            // 双语条目：含中日韩文字的行排上面（正常字号），其余原文行排下面（小字号）。
            // 不论源文件里两种语言的顺序如何，烧录出来都是中文在上。
            let text: String
            let cjkLines = lines.filter(Self.containsCJK)
            let otherLines = lines.filter { !Self.containsCJK($0) }
            if !cjkLines.isEmpty, !otherLines.isEmpty {
                text = cjkLines.joined(separator: "\\N")
                    + "\\N{\\fs\(originalFontSize)}"
                    + otherLines.joined(separator: "\\N")
            } else {
                text = lines.joined(separator: "\\N")
            }
            dialogues.append("Dialogue: 0,\(start),\(end),ZH,,0,0,0,,\(text)")
        }

        let header = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 384
        PlayResY: 288
        WrapStyle: 0
        ScaledBorderAndShadow: yes

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: ZH,PingFang SC,\(chineseFontSize),&H00FFFFFF,&H00FFFFFF,&H00000000,&H7F000000,0,0,0,0,100,100,0,0,1,1,0,2,12,12,20,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        """
        return header + "\n" + dialogues.joined(separator: "\n") + "\n"
    }

    /// "00:01:02,500" → "0:01:02.50"（ASS 用厘秒）
    private static func assTimestamp(_ srt: String) -> String? {
        let normalized = srt.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ":")
        guard parts.count == 3,
              let h = Int(parts[0]),
              let m = Int(parts[1]) else { return nil }
        let secParts = parts[2].split(separator: ".")
        guard let s = Int(secParts.first ?? ""), s < 60, m < 60 else { return nil }
        let msString = secParts.count > 1 ? String(secParts[1].prefix(3)) : "0"
        let ms = Int(msString.padding(toLength: 3, withPad: "0", startingAt: 0)) ?? 0
        return String(format: "%d:%02d:%02d.%02d", h, m, s, ms / 10)
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)        // CJK 统一表意
                || (0x3400...0x4DBF).contains(scalar.value) // 扩展 A
                || (0x3040...0x30FF).contains(scalar.value) // 日文假名
                || (0xAC00...0xD7AF).contains(scalar.value) // 谚文
        }
    }

    /// ASS 文本里 {} 是样式覆盖块定界符，替换为全角避免被解析
    private static func escapeASSText(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "{", with: "｛")
            .replacingOccurrences(of: "}", with: "｝")
            .replacingOccurrences(of: "\\", with: "＼")
    }
}
