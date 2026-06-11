#if canImport(VDLCore)
import VDLCore
#endif
import Foundation

// MARK: - 输出辅助

func printErr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

let usageText = """
用法：
  vdl-cli resolve <url>
  vdl-cli analyze <url>
  vdl-cli download <url> --video-id <id> --format <formatID> \
[--subs en,zh] [--auto-subs en] [--dest 路径]
"""

func splitLangs(_ value: String) -> [String] {
    value.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

/// 下载进度打印：下载中单行刷新，阶段切换时换行。
final class ProgressPrinter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPhase: DownloadProgress.Phase?
    private var lineOpen = false

    func handle(_ p: DownloadProgress) {
        lock.lock()
        defer { lock.unlock() }
        switch p.phase {
        case .preparing:
            if lastPhase != .preparing { print("准备中…") }
        case .downloading:
            var parts: [String] = ["下载中"]
            if let percent = p.percent { parts.append(String(format: "%5.1f%%", percent)) }
            if let speed = p.speedText { parts.append(speed) }
            if let eta = p.etaText { parts.append("剩余 \(eta)") }
            let line = parts.joined(separator: "  ")
            let padding = String(repeating: " ", count: max(0, 50 - line.count))
            print("\r\(line)\(padding)", terminator: "")
            fflush(stdout)
            lineOpen = true
        case .processing:
            if lastPhase != .processing {
                if lineOpen { print(""); lineOpen = false }
                print("处理中（合并 / 转换）…")
            }
        case .finished:
            if lineOpen { print(""); lineOpen = false }
            print("下载完成")
        }
        lastPhase = p.phase
    }
}

// MARK: - 入口

let cliArguments = Array(CommandLine.arguments.dropFirst())
guard let command = cliArguments.first else {
    printErr(usageText)
    exit(1)
}

let engine = makeDefaultEngine()

do {
    switch command {
    case "resolve":
        guard cliArguments.count >= 2 else {
            printErr("缺少链接参数。\n" + usageText)
            exit(1)
        }
        let candidates = try await engine.resolveCandidates(for: cliArguments[1])
        print("共找到 \(candidates.count) 个视频：")
        for (index, candidate) in candidates.enumerated() {
            print("[\(index + 1)] (\(candidate.kind.rawValue)) \(candidate.title)")
            print("    \(candidate.url)")
            if let detail = candidate.detail { print("    \(detail)") }
        }

    case "analyze":
        guard cliArguments.count >= 2 else {
            printErr("缺少链接参数。\n" + usageText)
            exit(1)
        }
        let info = try await engine.analyze(url: cliArguments[1])
        print("标题：\(info.title)")
        print("视频 ID：\(info.videoID)")
        if let duration = info.durationText { print("时长：\(duration)") }
        if let uploader = info.uploader { print("上传者：\(uploader)") }
        if let thumbnail = info.thumbnailURL { print("封面：\(thumbnail.absoluteString)") }
        print("格式：")
        for (index, format) in info.formats.enumerated() {
            var line = "  [\(index + 1)] \(format.label)"
            if let detail = format.detail { line += "（\(detail)）" }
            line += "   --format \(format.id)"
            print(line)
        }
        if info.subtitles.isEmpty {
            print("字幕：无")
        } else {
            print("字幕：")
            for subtitle in info.subtitles {
                let flag = subtitle.isAuto ? "--auto-subs" : "--subs"
                let mark = subtitle.isAuto ? "（自动生成）" : ""
                print("  - \(subtitle.label)\(mark)   \(flag) \(subtitle.id)")
            }
        }

    case "download":
        guard cliArguments.count >= 2 else {
            printErr("缺少链接参数。\n" + usageText)
            exit(1)
        }
        let url = cliArguments[1]
        var videoID: String?
        var formatID: String?
        var subs: [String] = []
        var autoSubs: [String] = []
        var destDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)

        var index = 2
        while index < cliArguments.count {
            let flag = cliArguments[index]
            guard index + 1 < cliArguments.count else {
                printErr("选项 \(flag) 缺少取值。")
                exit(1)
            }
            let value = cliArguments[index + 1]
            switch flag {
            case "--video-id":
                videoID = value
            case "--format":
                formatID = value
            case "--subs":
                subs = splitLangs(value)
            case "--auto-subs":
                autoSubs = splitLangs(value)
            case "--dest":
                destDir = URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
            default:
                printErr("未知选项：\(flag)\n" + usageText)
                exit(1)
            }
            index += 2
        }
        guard let videoID, let formatID else {
            printErr("download 需要 --video-id 与 --format。\n" + usageText)
            exit(1)
        }

        let request = DownloadRequest(
            url: url,
            videoID: videoID,
            formatID: formatID,
            subtitleLangs: subs,
            autoSubtitleLangs: autoSubs,
            destinationDirectory: destDir
        )
        let printer = ProgressPrinter()
        let result = try await engine.download(request) { printer.handle($0) }
        print("产出文件：")
        for file in result.files {
            print("  \(file.path)")
        }

    default:
        printErr("未知命令：\(command)\n" + usageText)
        exit(1)
    }
} catch {
    printErr(error.localizedDescription)
    exit(1)
}
