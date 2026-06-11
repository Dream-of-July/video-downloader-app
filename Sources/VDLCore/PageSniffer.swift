import Foundation

/// 页面嗅探：抓取 HTML，按正则提取页面里的视频候选。
/// 用于 yt-dlp 报 "Unsupported URL" 的普通网页。
public struct PageSniffer {

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    /// 共享会话：URLSession 在显式 invalidate 前由系统强持有，
    /// 每次嗅探新建会随批量解析成批泄漏，故全局复用一个。
    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    private var session: URLSession { Self.sharedSession }

    public init() {}

    // MARK: - 入口

    public func sniff(pageURL: URL) async throws -> [VideoCandidate] {
        let html: String
        do {
            html = try await fetchHTML(from: pageURL)
        } catch let error as VDLError {
            throw error
        } catch {
            throw VDLError.sniffFailed("页面加载失败，请检查网络后重试。")
        }
        return await extractCandidates(from: html, pageURL: pageURL)
    }

    private func fetchHTML(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        // 大文件防护：用户可能把可直接 GET 的大媒体文件链接粘进来（yt-dlp 拿不下时
        // 会走到嗅探兜底）。非文本类型或超过 8MB 的响应不当 HTML 解析。
        if let mime = response.mimeType?.lowercased(),
           !(mime.contains("html") || mime.contains("text") || mime.contains("xml")) {
            throw VDLError.sniffFailed("这个链接指向的是媒体文件而非网页（\(mime)），无法嗅探。")
        }
        guard data.count <= 8 * 1024 * 1024 else {
            throw VDLError.sniffFailed("页面过大（\(data.count / 1024 / 1024)MB），已停止嗅探。")
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    // MARK: - 提取

    private enum Finding {
        case media(URL)
        case youtube(String)
        case vimeo(String)
        case nintendoMain(String) // data-videoid 以 "/" 开头的值
    }

    private func extractCandidates(from html: String, pageURL: URL) async -> [VideoCandidate] {
        let ns = html as NSString
        var findings: [(offset: Int, finding: Finding)] = []

        func matches(_ pattern: String) -> [NSTextCheckingResult] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return []
            }
            return regex.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length))
        }
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String? {
            guard match.numberOfRanges > index, match.range(at: index).location != NSNotFound else {
                return nil
            }
            return ns.substring(with: match.range(at: index))
        }
        // 把一个 URL 字符串归类为 youtube / vimeo / 直链媒体。
        func classify(_ raw: String, at offset: Int) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "\\/", with: "/")
            guard !value.isEmpty else { return }
            let lower = value.lowercased()
            if lower.hasPrefix("data:") || lower.hasPrefix("blob:") || lower.hasPrefix("javascript:") {
                return
            }
            if let id = Self.youtubeID(in: value) {
                findings.append((offset, .youtube(id)))
                return
            }
            if let id = Self.vimeoID(in: value) {
                findings.append((offset, .vimeo(id)))
                return
            }
            guard let resolved = URL(string: value, relativeTo: pageURL)?.absoluteURL,
                  let scheme = resolved.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return }
            findings.append((offset, .media(resolved)))
        }

        // 1. og:video / twitter:player:stream（属性顺序两种写法都覆盖）
        let metaPatterns = [
            #"<meta\b[^>]*?(?:property|name)\s*=\s*["'](?:og:video(?::(?:secure_)?url)?|twitter:player:stream)["'][^>]*?content\s*=\s*["']([^"']+)["']"#,
            #"<meta\b[^>]*?content\s*=\s*["']([^"']+)["'][^>]*?(?:property|name)\s*=\s*["'](?:og:video(?::(?:secure_)?url)?|twitter:player:stream)["']"#,
        ]
        for pattern in metaPatterns {
            for match in matches(pattern) {
                if let value = group(match, 1) { classify(value, at: match.range.location) }
            }
        }

        // 2. <video src> 与 <source src>
        for match in matches(#"<(?:video|source)\b[^>]*?src\s*=\s*["']([^"']+)["']"#) {
            if let value = group(match, 1) { classify(value, at: match.range.location) }
        }

        // 3. YouTube / Vimeo 嵌入（iframe、链接、脚本里出现的都算）
        for match in matches(Self.youtubeIDPattern) {
            if let id = group(match, 1) { findings.append((match.range.location, .youtube(id))) }
        }
        for match in matches(Self.vimeoIDPattern) {
            if let id = group(match, 1) { findings.append((match.range.location, .vimeo(id))) }
        }

        // 4/5. data-videoid 系列属性
        let isNintendo = Self.isNintendoHost(pageURL.host)
        for match in matches(#"data-(?:videoid|video-id|youtube-id)\s*=\s*["']([^"']+)["']"#) {
            guard let value = group(match, 1) else { continue }
            if value.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil {
                findings.append((match.range.location, .youtube(value)))
            } else if isNintendo, value.hasPrefix("/") {
                findings.append((match.range.location, .nintendoMain(value)))
            }
        }

        // 6. HTML 里裸的绝对媒体地址
        for match in matches(#"https?://[^\s"'<>\\]+?\.(?:mp4|m3u8|webm|mov)(?:\?[^\s"'<>]*)?"#) {
            classify(ns.substring(with: match.range), at: match.range.location)
        }

        // 7. JSON 转义的直链（https:\/\/…\/a.mp4），classify 会把 \/ 反转义后归类
        for match in matches(#"https?:(?:\\/|/){2}[^\s"'<>]+?\.(?:mp4|m3u8|webm|mov)(?:\?[^\s"'<>]*)?"#) {
            classify(ns.substring(with: match.range), at: match.range.location)
        }

        findings.sort { $0.offset < $1.offset }
        return await buildCandidates(from: findings, html: html)
    }

    // MARK: - 组装候选

    private func buildCandidates(
        from findings: [(offset: Int, finding: Finding)],
        html: String
    ) async -> [VideoCandidate] {
        let pageTitle = Self.pageTitle(in: html)

        // 任天堂主视频：拼地址后用 HEAD 验证再收录。
        var nintendoOrdered: [(offset: Int, url: String)] = []
        var seenNintendo = Set<String>()
        for (offset, finding) in findings {
            if case .nintendoMain(let path) = finding {
                let urlString = "https://assets.nintendo.com/video/upload" + path + ".mp4"
                if seenNintendo.insert(urlString).inserted {
                    nintendoOrdered.append((offset, urlString))
                }
            }
        }

        var prepared: [(rank: Int, offset: Int, candidate: VideoCandidate)] = []
        var seenMedia = Set<String>()

        for (offset, urlString) in nintendoOrdered {
            guard await validateNintendoAsset(urlString) else { continue }
            seenMedia.insert(urlString)
            let title = pageTitle ?? Self.fileBaseName(of: urlString) ?? urlString
            prepared.append((0, offset, VideoCandidate(
                url: urlString,
                kind: .pageMain,
                title: title,
                detail: "assets.nintendo.com · mp4 直链"
            )))
        }

        var youtubeOrdered: [(offset: Int, id: String)] = []
        var vimeoOrdered: [(offset: Int, id: String)] = []
        var seenYouTube = Set<String>()
        var seenVimeo = Set<String>()

        for (offset, finding) in findings {
            switch finding {
            case .media(let url):
                let urlString = url.absoluteString
                guard seenMedia.insert(urlString).inserted else { continue }
                let ext = url.pathExtension.lowercased()
                let host = url.host ?? ""
                let detail = ext.isEmpty ? host : "\(host) · \(ext)"
                let base = Self.fileBaseName(of: urlString)
                let title = base ?? pageTitle ?? urlString
                prepared.append((1, offset, VideoCandidate(
                    url: urlString,
                    kind: .directFile,
                    title: title,
                    detail: detail
                )))
            case .youtube(let id):
                if seenYouTube.insert(id).inserted { youtubeOrdered.append((offset, id)) }
            case .vimeo(let id):
                if seenVimeo.insert(id).inserted { vimeoOrdered.append((offset, id)) }
            case .nintendoMain:
                continue
            }
        }

        // YouTube 标题：oEmbed 并发获取，失败用占位名。
        var youtubeTitles: [String: String] = [:]
        if !youtubeOrdered.isEmpty {
            await withTaskGroup(of: (String, String?).self) { group in
                for (_, id) in youtubeOrdered {
                    group.addTask { (id, await self.fetchYouTubeTitle(id: id)) }
                }
                for await (id, title) in group {
                    if let title { youtubeTitles[id] = title }
                }
            }
        }
        for (offset, id) in youtubeOrdered {
            prepared.append((2, offset, VideoCandidate(
                url: "https://www.youtube.com/watch?v=\(id)",
                kind: .youtube,
                title: youtubeTitles[id] ?? "YouTube 视频 \(id)",
                detail: "YouTube"
            )))
        }
        for (offset, id) in vimeoOrdered {
            prepared.append((2, offset, VideoCandidate(
                url: "https://vimeo.com/\(id)",
                kind: .vimeo,
                title: "Vimeo 视频 \(id)",
                detail: "Vimeo"
            )))
        }

        prepared.sort { ($0.rank, $0.offset) < ($1.rank, $1.offset) }
        return prepared.map { $0.candidate }
    }

    // MARK: - 网络辅助

    private func validateNintendoAsset(_ urlString: String) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 20
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        return http.statusCode == 200 && contentType.hasPrefix("video/")
    }

    private func fetchYouTubeTitle(id: String) async -> String? {
        guard var components = URLComponents(string: "https://www.youtube.com/oembed") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(id)"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let title = dict["title"] as? String, !title.isEmpty else { return nil }
        return title
    }

    // MARK: - 静态辅助

    private static let youtubeIDPattern =
        #"(?:youtube(?:-nocookie)?\.com/(?:embed|shorts|live|v)/|youtube\.com/watch\?[^"'<>\s]*?v=|youtu\.be/)([A-Za-z0-9_-]{11})(?![A-Za-z0-9_-])"#
    private static let vimeoIDPattern = #"player\.vimeo\.com/video/(\d+)"#

    private static func youtubeID(in text: String) -> String? {
        firstCapture(of: youtubeIDPattern, in: text)
    }

    private static func vimeoID(in text: String) -> String? {
        firstCapture(of: vimeoIDPattern, in: text)
    }

    private static func firstCapture(of pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else {
            return nil
        }
        return ns.substring(with: match.range(at: 1))
    }

    private static func isNintendoHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return h == "nintendo.com" || h.hasSuffix(".nintendo.com")
    }

    /// 页面 <title>，去掉 " | Play Nintendo" 之类站名尾巴。
    private static func pageTitle(in html: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "<title[^>]*>([\\s\\S]*?)</title>",
            options: [.caseInsensitive]
        ) else { return nil }
        let ns = html as NSString
        guard let match = regex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        var title = decodeEntities(ns.substring(with: match.range(at: 1)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for separator in [" | ", " – ", " — ", " - "] {
            if let range = title.range(of: separator, options: .backwards) {
                title = String(title[..<range.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return title.isEmpty ? nil : title
    }

    private static func fileBaseName(of urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        let base = url.deletingPathExtension().lastPathComponent
        guard !base.isEmpty, base != "/" else { return nil }
        return base.removingPercentEncoding ?? base
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        let map = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " ",
        ]
        for (entity, plain) in map {
            result = result.replacingOccurrences(of: entity, with: plain)
        }
        return result
    }
}
