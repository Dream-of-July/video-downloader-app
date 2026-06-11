import Foundation

// MARK: - 默认翻译器

public func makeTranslator(settings: AppSettings) -> any SubtitleTranslator {
    AnthropicTranslator(settings: settings)
}

// MARK: - SRT 解析与序列化

/// 解析 SRT 文本为字幕条。容忍 BOM、CRLF、多行字幕文本、序号缺失（按顺序补号）；
/// 时间行解析失败的块整块跳过。
func parseSRT(_ raw: String) -> [SubtitleCue] {
    var text = raw
    if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
    let lines = text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .components(separatedBy: "\n")

    // 按空行切块
    var blocks: [[String]] = []
    var current: [String] = []
    for line in lines {
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            if !current.isEmpty {
                blocks.append(current)
                current = []
            }
        } else {
            current.append(line)
        }
    }
    if !current.isEmpty { blocks.append(current) }

    var cues: [SubtitleCue] = []
    var nextIndex = 1
    for block in blocks {
        var rest = block[...]
        // 首行是纯数字且第二行是时间行 → 显式序号；否则视为序号缺失
        var explicitIndex: Int?
        if rest.count >= 2,
           let first = rest.first,
           let number = Int(first.trimmingCharacters(in: .whitespaces)),
           block[1].contains("-->") {
            explicitIndex = number
            rest = rest.dropFirst()
        }
        guard let timeLine = rest.first,
              let (start, end) = parseSRTTimeLine(timeLine) else { continue }
        rest = rest.dropFirst()
        let index = explicitIndex ?? nextIndex
        cues.append(SubtitleCue(index: index, start: start, end: end, text: rest.joined(separator: "\n")))
        nextIndex = index + 1
    }
    return cues
}

/// 解析时间行 "HH:MM:SS,mmm --> HH:MM:SS,mmm"（毫秒分隔符容忍 "," 与 "."）。
private func parseSRTTimeLine(_ line: String) -> (start: String, end: String)? {
    let pattern = #"(\d{1,2}:\d{2}:\d{2}[,\.]\d{1,3})\s*-->\s*(\d{1,2}:\d{2}:\d{2}[,\.]\d{1,3})"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
          let startRange = Range(match.range(at: 1), in: line),
          let endRange = Range(match.range(at: 2), in: line) else { return nil }
    return (String(line[startRange]), String(line[endRange]))
}

/// 序列化为标准 SRT 文本。
func serializeSRT(_ cues: [SubtitleCue]) -> String {
    cues.map { "\($0.index)\n\($0.start) --> \($0.end)\n\($0.text)" }
        .joined(separator: "\n\n") + "\n"
}

// MARK: - Anthropic Messages API 请求

/// Messages API 一次调用的结果：text 块拼接后的文本 + stop_reason。
struct AnthropicReply {
    let text: String
    let stopReason: String?
}

/// 调一次 Messages API，返回回复里所有 type=="text" 块拼接的文本与 stop_reason。
/// 429/5xx 指数退避重试最多 2 次（2s、8s）；其余错误映射为 VDLError。
func sendAnthropicMessage(
    settings: AppSettings,
    system: String?,
    userContent: String,
    maxTokens: Int
) async throws -> AnthropicReply {
    let model = settings.translationModel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty else {
        throw VDLError.translateFailed("尚未配置模型，请在设置里填写模型名称。")
    }
    var token = settings.translationAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
    // 用户误把 "Bearer xxx" 整段贴进凭证框时剥掉前缀，避免双重 Bearer。
    if token.lowercased().hasPrefix("bearer ") {
        token = String(token.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
    }
    guard !token.isEmpty else {
        throw VDLError.translateFailed("尚未配置 API 凭证，请在设置里填写。")
    }

    var base = settings.translationBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") { base.removeLast() }
    guard !base.isEmpty,
          let url = URL(string: base + "/v1/messages"),
          let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
          let host = url.host else {
        throw VDLError.translateFailed("服务地址无效")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    // 官方 API 只认 x-api-key（两个鉴权头同时发会被拒）；其他网关两个都发以求兼容。
    request.setValue(token, forHTTPHeaderField: "x-api-key")
    if host.lowercased() != "api.anthropic.com" {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    struct Message: Encodable {
        let role: String
        let content: String
    }
    struct Payload: Encodable {
        let model: String
        let max_tokens: Int
        let system: String?
        let messages: [Message]
    }
    do {
        request.httpBody = try JSONEncoder().encode(Payload(
            model: model,
            max_tokens: maxTokens,
            system: system,
            messages: [Message(role: "user", content: userContent)]
        ))
    } catch {
        throw VDLError.translateFailed("无法构造请求体：\(error.localizedDescription)")
    }

    let backoffNanoseconds: [UInt64] = [2_000_000_000, 8_000_000_000]
    var attempt = 0
    while true {
        if Task.isCancelled { throw VDLError.cancelled }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw VDLError.translateFailed("服务返回了无法识别的响应。")
            }
            if http.statusCode == 200 {
                struct Block: Decodable {
                    let type: String
                    let text: String?
                }
                struct Reply: Decodable {
                    let content: [Block]
                    let stop_reason: String?
                }
                guard let reply = try? JSONDecoder().decode(Reply.self, from: data),
                      reply.content.contains(where: { $0.type == "text" }) else {
                    throw VDLError.translateFailed("服务响应不符合 Anthropic Messages 协议，请检查服务地址。")
                }
                let text = reply.content.filter { $0.type == "text" }.compactMap(\.text).joined()
                return AnthropicReply(text: text, stopReason: reply.stop_reason)
            }
            let retryable = http.statusCode == 429 || (500...599).contains(http.statusCode)
            if retryable, attempt < backoffNanoseconds.count {
                try await Task.sleep(nanoseconds: backoffNanoseconds[attempt])
                attempt += 1
                continue
            }
            struct ErrorBody: Decodable {
                struct Inner: Decodable {
                    let type: String?
                    let message: String?
                }
                let error: Inner?
            }
            let decoded = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error?.message
            let fallback = String(decoding: data.prefix(200), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = decoded ?? (fallback.isEmpty ? "请求失败" : fallback)
            throw VDLError.translateFailed("HTTP \(http.statusCode)：\(message)")
        } catch let error as VDLError {
            throw error
        } catch is CancellationError {
            throw VDLError.cancelled
        } catch let error as URLError {
            if error.code == .cancelled { throw VDLError.cancelled }
            throw VDLError.translateFailed("无法连接到翻译服务，请检查服务地址和网络。")
        } catch {
            throw VDLError.translateFailed(error.localizedDescription)
        }
    }
}

// MARK: - 连接测试

/// 设置面板「测试连接」：发一条迷你请求，返回模型回复文本。
public func testTranslationConnection(settings: AppSettings) async throws -> String {
    let reply = try await sendAnthropicMessage(
        settings: settings,
        system: nil,
        userContent: "请只回复两个字：正常",
        maxTokens: 16
    )
    return reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - AnthropicTranslator

/// 通过 Anthropic Messages API 协议翻译字幕。服务地址、模型、凭证全部来自 AppSettings。
public struct AnthropicTranslator: SubtitleTranslator {
    private let settings: AppSettings

    /// 每次请求翻译的字幕条数
    private static let chunkSize = 30

    private static let systemPrompt = """
        你是专业字幕翻译。把用户给出的字幕逐条翻译成简体中文。\
        输入每行格式为 编号|原文。输出必须严格逐行 编号|中文译文，\
        行数与输入一致，不要输出任何其他内容。口语自然、简洁，保留专有名词。
        """

    public init(settings: AppSettings) {
        self.settings = settings
    }

    public func translate(
        srtFile: URL,
        style: SubtitleStyle,
        control: TaskControlToken?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let raw: String
        do {
            raw = try String(contentsOf: srtFile, encoding: .utf8)
        } catch {
            throw VDLError.translateFailed("无法读取字幕文件：\(srtFile.lastPathComponent)")
        }
        let cues = parseSRT(raw)
        guard !cues.isEmpty else {
            throw VDLError.translateFailed("字幕文件里没有可识别的字幕内容。")
        }

        // 逐块顺序请求；编号用全局序号（1 起）保证块内唯一、回贴不串行。
        var output = cues
        var position = 0
        while position < cues.count {
            if Task.isCancelled { throw VDLError.cancelled }
            let upper = min(position + Self.chunkSize, cues.count)
            let chunk = cues[position..<upper]
            let translated = try await translateChunk(chunk, startNumber: position + 1, depth: 0)
            for offset in 0..<chunk.count {
                let cueIndex = position + offset
                // 某条缺失就保留原文（output 初始即原文）
                guard let chinese = translated[cueIndex + 1], !chinese.isEmpty else { continue }
                switch style {
                case .bilingual:
                    // 中文在上、原文在下（烧录时原文用更小字号）
                    output[cueIndex].text = chinese + "\n" + cues[cueIndex].text
                case .chineseOnly:
                    output[cueIndex].text = chinese
                }
            }
            progress(Double(upper) / Double(cues.count))
            position = upper
        }

        // 写 "<原文件名去.srt>.zh.srt"
        let name = srtFile.lastPathComponent
        let stem = name.lowercased().hasSuffix(".srt") ? String(name.dropLast(4)) : name
        let outputURL = srtFile.deletingLastPathComponent()
            .appendingPathComponent(stem + ".zh.srt")
        do {
            try serializeSRT(output).write(to: outputURL, atomically: true, encoding: .utf8)
        } catch {
            throw VDLError.translateFailed("无法写入译文文件：\(error.localizedDescription)")
        }
        return outputURL
    }

    /// 翻译一块字幕，返回 [全局编号: 译文]。
    /// stop_reason 为 "max_tokens"（译文被截断）时按减半的条数自动重试：
    /// 最多再分两层、每块最小 8 条；仍截断则抛错。
    /// 译文缺失行数超过 40% 视为模型返回格式异常，抛错而不是静默保留原文。
    private func translateChunk(
        _ chunk: ArraySlice<SubtitleCue>,
        startNumber: Int,
        depth: Int
    ) async throws -> [Int: String] {
        if Task.isCancelled { throw VDLError.cancelled }
        let userContent = chunk.enumerated().map { offset, cue in
            "\(startNumber + offset)|\(Self.flattened(cue.text))"
        }.joined(separator: "\n")

        let reply = try await sendAnthropicMessage(
            settings: settings,
            system: Self.systemPrompt,
            userContent: userContent,
            maxTokens: 8000
        )
        if reply.stopReason == "max_tokens" {
            let half = chunk.count / 2
            guard depth < 2, half >= 8 else {
                throw VDLError.translateFailed("译文超出模型输出上限，请减小每块字幕条数或检查模型 max_tokens 限制")
            }
            let mid = chunk.startIndex + half
            var merged = try await translateChunk(
                chunk[chunk.startIndex..<mid], startNumber: startNumber, depth: depth + 1
            )
            let second = try await translateChunk(
                chunk[mid..<chunk.endIndex], startNumber: startNumber + half, depth: depth + 1
            )
            merged.merge(second) { _, new in new }
            return merged
        }

        let map = Self.parseReply(reply.text)
        let missing = (startNumber..<startNumber + chunk.count)
            .filter { (map[$0] ?? "").isEmpty }
            .count
        if Double(missing) > Double(chunk.count) * 0.4 {
            throw VDLError.translateFailed("模型返回格式异常，缺失过多译文行")
        }
        return map
    }

    /// 字幕条内部换行折叠成 " / "，保证一条占一行。
    private static func flattened(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
    }

    /// 把模型回复按行解析为 [编号: 译文]；不合规的行忽略。
    private static func parseReply(_ reply: String) -> [Int: String] {
        var map: [Int: String] = [:]
        for line in reply.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: "|") else { continue }
            guard let number = Int(line[..<separator].trimmingCharacters(in: .whitespaces)) else { continue }
            let text = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            map[number] = text
        }
        return map
    }
}
