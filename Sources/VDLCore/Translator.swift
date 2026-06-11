import Foundation

// MARK: - 默认翻译器

public func makeTranslator(settings: AppSettings) -> any SubtitleTranslator {
    ConfiguredTranslator(settings: settings)
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

// MARK: - 字幕清洗（去重叠 + 按句合并）

/// 把 "HH:MM:SS,mmm"（或用 "." 作毫秒分隔）解析为秒。失败返回 nil。
func srtTimeToSeconds(_ s: String) -> Double? {
    let normalized = s.replacingOccurrences(of: ",", with: ".")
    let parts = normalized.split(separator: ":")
    guard parts.count == 3, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
    guard let sec = Double(parts[2]) else { return nil }
    return Double(h) * 3600 + Double(m) * 60 + sec
}

/// 秒转回 "HH:MM:SS,mmm"。
func secondsToSRTTime(_ seconds: Double) -> String {
    let clamped = max(0, seconds)
    let totalMS = Int((clamped * 1000).rounded())
    let ms = totalMS % 1000
    let totalSec = totalMS / 1000
    let s = totalSec % 60
    let m = (totalSec / 60) % 60
    let h = totalSec / 3600
    return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
}

/// 清洗字幕：
/// (a) 解析时间戳为秒，按 start 稳定升序；
/// (b) 去重叠：每条 end 截断到 min(自身 end, 下一条 start)，截断后 <0.3s 则设为 start+0.3s；
/// (c) 按句合并（仅对滚动字幕启用）：相邻碎条拼接，遇句末标点 / 累积≥6s / 累积≥84 字符断句；
/// (d) 防误伤：合并后条数 ≥ 原条数则放弃合并，只返回去重叠结果；
/// (e) 滚动判定：原始相邻重叠率 > 50% 才启用合并，非滚动只去重叠。
func cleanCues(_ input: [SubtitleCue]) -> [SubtitleCue] {
    guard !input.isEmpty else { return input }

    // (a) 解析时间 + 稳定升序排序
    struct Timed { var start: Double; var end: Double; var text: String; var order: Int }
    var timed: [Timed] = []
    for (i, cue) in input.enumerated() {
        guard let start = srtTimeToSeconds(cue.start), let end = srtTimeToSeconds(cue.end) else {
            continue
        }
        timed.append(Timed(start: start, end: max(end, start), text: cue.text, order: i))
    }
    guard !timed.isEmpty else { return input }
    timed.sort { $0.start != $1.start ? $0.start < $1.start : $0.order < $1.order }

    // (e) 滚动判定：相邻条 start < 上一条 end 的比例 > 50%
    var overlapCount = 0
    if timed.count >= 2 {
        for i in 1..<timed.count where timed[i].start < timed[i - 1].end {
            overlapCount += 1
        }
    }
    let overlapRatio = timed.count >= 2 ? Double(overlapCount) / Double(timed.count - 1) : 0
    let isRolling = overlapRatio > 0.5

    // (b) 去重叠：end 截断到下一条 start，过短则补到 start+0.3s（但不越过下一条 start）
    let minDuration = 0.3
    for i in 0..<timed.count {
        let nextStart = i + 1 < timed.count ? timed[i + 1].start : nil
        if let nextStart {
            timed[i].end = min(timed[i].end, nextStart)
        }
        if timed[i].end - timed[i].start < minDuration {
            var compensated = timed[i].start + minDuration
            if let nextStart { compensated = min(compensated, nextStart) }
            timed[i].end = compensated
        }
    }

    func makeCues(_ items: [Timed]) -> [SubtitleCue] {
        items.enumerated().map { idx, t in
            SubtitleCue(index: idx + 1, start: secondsToSRTTime(t.start),
                        end: secondsToSRTTime(t.end), text: t.text)
        }
    }

    // 非滚动字幕：只做去重叠，不合并
    guard isRolling else { return makeCues(timed) }

    // (c) 按句合并：把碎条文本规整空白后用空格累积，满足任一断句条件即收一条
    func normalizeWhitespace(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
    let sentenceEnders: Set<Character> = [".", "!", "?", "。", "！", "？"]
    let trailingAllowed: Set<Character> = ["\"", "'", "”", "’", ")", "）", "」", "』", "]"]
    func endsSentence(_ text: String) -> Bool {
        var chars = Array(text)
        // 跳过尾部的引号 / 括号
        while let last = chars.last, trailingAllowed.contains(last) || last == " " {
            chars.removeLast()
        }
        guard let last = chars.last else { return false }
        return sentenceEnders.contains(last)
    }

    var merged: [Timed] = []
    var curText = ""
    var curStart = 0.0
    var curEnd = 0.0
    var hasCurrent = false

    func flush() {
        guard hasCurrent else { return }
        merged.append(Timed(start: curStart, end: curEnd, text: curText, order: merged.count))
        hasCurrent = false
        curText = ""
    }

    for t in timed {
        let piece = normalizeWhitespace(t.text)
        if !hasCurrent {
            curText = piece
            curStart = t.start
            curEnd = t.end
            hasCurrent = true
        } else {
            curText = normalizeWhitespace(curText + " " + piece)
            curEnd = t.end
        }
        let longEnough = (curEnd - curStart) >= 6.0
        let charsEnough = curText.count >= 84
        if endsSentence(curText) || longEnough || charsEnough {
            flush()
        }
    }
    flush()

    // (d) 防误伤：合并后条数没减少则放弃合并
    guard merged.count < timed.count else { return makeCues(timed) }
    return makeCues(merged)
}

// MARK: - LLM API 请求

/// 一次模型调用的结果：文本 + 是否因为输出上限被截断。
struct ModelReply {
    let text: String
    let reachedOutputLimit: Bool
}

func sendConfiguredMessage(
    settings: AppSettings,
    system: String?,
    userContent: String,
    maxTokens: Int
) async throws -> ModelReply {
    switch settings.translationProvider {
    case .anthropic:
        return try await sendAnthropicMessage(
            settings: settings,
            system: system,
            userContent: userContent,
            maxTokens: maxTokens
        )
    case .openai:
        return try await sendOpenAIResponse(
            settings: settings,
            instructions: system,
            input: userContent,
            maxOutputTokens: maxTokens
        )
    }
}

private func normalizedToken(_ raw: String) -> String {
    var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    // 用户误把 "Bearer xxx" 整段贴进凭证框时剥掉前缀，避免双重 Bearer。
    if token.lowercased().hasPrefix("bearer ") {
        token = String(token.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
    }
    return token
}

private func endpointURL(baseURL: String, endpointPath: String) throws -> URL {
    var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") { base.removeLast() }

    let path = endpointPath.hasPrefix("/") ? endpointPath : "/" + endpointPath
    let lowerBase = base.lowercased()
    let lowerPath = path.lowercased()
    let urlString: String
    if lowerBase.hasSuffix(lowerPath) {
        urlString = base
    } else if lowerBase.hasSuffix("/v1"), lowerPath.hasPrefix("/v1/") {
        urlString = base + String(path.dropFirst("/v1".count))
    } else {
        urlString = base + path
    }

    guard !base.isEmpty,
          let url = URL(string: urlString),
          let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
          url.host != nil else {
        throw VDLError.translateFailed("服务地址无效")
    }
    return url
}

private func responseErrorMessage(from data: Data) -> String {
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
    return decoded ?? (fallback.isEmpty ? "请求失败" : fallback)
}

private func requestFailureMessage(statusCode: Int, data: Data, settings: AppSettings) -> String {
    let message = responseErrorMessage(from: data)
    let lowerMessage = message.lowercased()
    guard statusCode == 503 || lowerMessage.contains("no available accounts") else {
        return "HTTP \(statusCode)：\(message)"
    }

    let model = settings.translationModel.trimmingCharacters(in: .whitespacesAndNewlines)
    return "HTTP \(statusCode)：网关没有可用账号或模型映射未命中。请确认模型名 \(model.isEmpty ? "已填写" : "「\(model)」") 在公司网关里已登记——点「拉取模型」选一个网关实际提供的模型。原始错误：\(message)"
}

/// 调一次 Anthropic Messages API，返回回复里所有 type=="text" 块拼接后的文本。
/// 429/5xx 指数退避重试最多 2 次（2s、8s）；其余错误映射为 VDLError。
func sendAnthropicMessage(
    settings: AppSettings,
    system: String?,
    userContent: String,
    maxTokens: Int
) async throws -> ModelReply {
    let model = settings.translationModel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty else {
        throw VDLError.translateFailed("尚未配置模型，请在设置里填写模型名称。")
    }
    let token = normalizedToken(settings.translationAuthToken)
    guard !token.isEmpty else {
        throw VDLError.translateFailed("尚未配置 API 凭证，请在设置里填写。")
    }

    let url = try endpointURL(baseURL: settings.translationBaseURL, endpointPath: "/v1/messages")
    let host = url.host ?? ""

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
                return ModelReply(text: text, reachedOutputLimit: reply.stop_reason == "max_tokens")
            }
            let retryable = http.statusCode == 429 || (500...599).contains(http.statusCode)
            if retryable, attempt < backoffNanoseconds.count {
                try await Task.sleep(nanoseconds: backoffNanoseconds[attempt])
                attempt += 1
                continue
            }
            throw VDLError.translateFailed(requestFailureMessage(
                statusCode: http.statusCode,
                data: data,
                settings: settings
            ))
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

/// 调一次 OpenAI Responses API，返回 output_text 块拼接后的文本。
/// 429/5xx 指数退避重试最多 2 次（2s、8s）；其余错误映射为 VDLError。
func sendOpenAIResponse(
    settings: AppSettings,
    instructions: String?,
    input: String,
    maxOutputTokens: Int
) async throws -> ModelReply {
    let model = settings.translationModel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty else {
        throw VDLError.translateFailed("尚未配置模型，请在设置里填写模型名称。")
    }
    let token = normalizedToken(settings.translationAuthToken)
    guard !token.isEmpty else {
        throw VDLError.translateFailed("尚未配置 API 凭证，请在设置里填写。")
    }

    let url = try endpointURL(baseURL: settings.translationBaseURL, endpointPath: "/v1/responses")

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

    struct Payload: Encodable {
        let model: String
        let instructions: String?
        let input: String
        let max_output_tokens: Int
        let store: Bool
    }
    do {
        request.httpBody = try JSONEncoder().encode(Payload(
            model: model,
            instructions: instructions,
            input: input,
            max_output_tokens: maxOutputTokens,
            store: false
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
                struct Content: Decodable {
                    let type: String
                    let text: String?
                }
                struct OutputItem: Decodable {
                    let type: String
                    let content: [Content]?
                }
                struct IncompleteDetails: Decodable {
                    let reason: String?
                }
                struct Reply: Decodable {
                    let output: [OutputItem]
                    let status: String?
                    let incomplete_details: IncompleteDetails?
                }
                guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
                    throw VDLError.translateFailed("服务响应不符合 OpenAI Responses 协议，请检查服务地址。")
                }
                let messageItems: [OutputItem] = reply.output.filter { $0.type == "message" }
                var textParts: [String] = []
                for item in messageItems {
                    let blocks = item.content ?? []
                    for block in blocks where block.type == "output_text" || block.type == "text" {
                        if let t = block.text { textParts.append(t) }
                    }
                }
                let text = textParts.joined()
                guard !text.isEmpty else {
                    throw VDLError.translateFailed("OpenAI 响应里没有文本内容，请检查模型或服务地址。")
                }
                return ModelReply(
                    text: text,
                    reachedOutputLimit: reply.status == "incomplete"
                        && reply.incomplete_details?.reason == "max_output_tokens"
                )
            }
            let retryable = http.statusCode == 429 || (500...599).contains(http.statusCode)
            if retryable, attempt < backoffNanoseconds.count {
                try await Task.sleep(nanoseconds: backoffNanoseconds[attempt])
                attempt += 1
                continue
            }
            throw VDLError.translateFailed(requestFailureMessage(
                statusCode: http.statusCode,
                data: data,
                settings: settings
            ))
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
    let reply = try await sendConfiguredMessage(
        settings: settings,
        system: nil,
        userContent: "请只回复两个字：正常",
        maxTokens: 16
    )
    return reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// 拉取服务端可用模型列表（GET {baseURL}/v1/models）。
/// 官方 Anthropic 与 OpenAI、以及大多数企业网关都暴露这个端点；返回模型 id 数组。
/// 只需服务地址 + 凭证，不需要先填模型。
public func listTranslationModels(settings: AppSettings) async throws -> [String] {
    let token = normalizedToken(settings.translationAuthToken)
    guard !token.isEmpty else {
        throw VDLError.translateFailed("尚未配置 API 凭证，请先填写凭证再拉取模型。")
    }
    let url = try endpointURL(baseURL: settings.translationBaseURL, endpointPath: "/v1/models")
    let host = (url.host ?? "").lowercased()

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 20
    // 同时带两种鉴权头以兼容网关；官方 Anthropic 只认 x-api-key + version。
    request.setValue(token, forHTTPHeaderField: "x-api-key")
    if host != "api.anthropic.com" {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VDLError.translateFailed("拉取模型列表失败：无效响应。")
        }
        guard http.statusCode == 200 else {
            throw VDLError.translateFailed(requestFailureMessage(
                statusCode: http.statusCode, data: data, settings: settings
            ))
        }
        let ids = parseModelIDs(from: data)
        guard !ids.isEmpty else {
            throw VDLError.translateFailed("服务返回的模型列表为空，请手动填写模型名。")
        }
        return ids
    } catch let error as VDLError {
        throw error
    } catch let error as URLError {
        if error.code == .cancelled { throw VDLError.cancelled }
        throw VDLError.translateFailed("无法连接到翻译服务，请检查服务地址和网络。")
    } catch {
        throw VDLError.translateFailed(error.localizedDescription)
    }
}

/// 解析 /v1/models 响应。兼容 OpenAI 风格 {"data":[{"id":...}]} 与 Anthropic 风格
/// {"data":[{"id":...,"type":"model"}]}，以及个别网关的 {"models":[...]} / 纯数组。
private func parseModelIDs(from data: Data) -> [String] {
    guard let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
    func ids(from arr: [Any]) -> [String] {
        arr.compactMap { entry in
            if let s = entry as? String { return s }
            if let d = entry as? [String: Any] {
                return (d["id"] as? String) ?? (d["name"] as? String) ?? (d["model"] as? String)
            }
            return nil
        }
    }
    if let dict = obj as? [String: Any] {
        if let arr = dict["data"] as? [Any] { return dedupePreservingOrder(ids(from: arr)) }
        if let arr = dict["models"] as? [Any] { return dedupePreservingOrder(ids(from: arr)) }
    }
    if let arr = obj as? [Any] { return dedupePreservingOrder(ids(from: arr)) }
    return []
}

private func dedupePreservingOrder(_ items: [String]) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for item in items where !item.isEmpty && seen.insert(item).inserted {
        out.append(item)
    }
    return out
}

// MARK: - ConfiguredTranslator

/// 通过设置里选择的协议翻译字幕。服务地址、模型、凭证全部来自 AppSettings。
public struct ConfiguredTranslator: SubtitleTranslator {
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
        let parsed = parseSRT(raw)
        guard !parsed.isEmpty else {
            throw VDLError.translateFailed("字幕文件里没有可识别的字幕内容。")
        }
        // 翻译前清洗：消除 YouTube 自动字幕的重叠滚动碎句、按句合并，减少疯狂刷新。
        let cues = cleanCues(parsed)

        // 逐块顺序请求；编号用全局序号（1 起）保证块内唯一、回贴不串行。
        var output = cues
        var position = 0
        while position < cues.count {
            if Task.isCancelled { throw VDLError.cancelled }
            // 分块前请求闸门：暂停时挂起、取消时抛出（与上面的 Task.isCancelled 并存）。
            try await control?.gate()
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

        let reply = try await sendConfiguredMessage(
            settings: settings,
            system: Self.systemPrompt,
            userContent: userContent,
            maxTokens: 8000
        )
        if reply.reachedOutputLimit {
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

@available(*, deprecated, renamed: "ConfiguredTranslator")
public typealias AnthropicTranslator = ConfiguredTranslator
