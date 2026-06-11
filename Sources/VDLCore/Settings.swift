import Foundation

public enum TranslationProvider: String, Codable, Sendable, Equatable, CaseIterable {
    case anthropic
    case openai

    public var defaultBaseURL: String {
        switch self {
        case .anthropic:
            return "https://api.anthropic.com"
        case .openai:
            return "https://api.openai.com"
        }
    }

}

/// App 设置。持久化在 ~/Library/Application Support/视频下载器/settings.json（0600）。
/// 注意：authToken 属于敏感凭证，只落在本地配置文件，绝不写入代码、日志或版本库。
public struct AppSettings: Codable, Sendable, Equatable {
    /// 翻译接口协议
    public var translationProvider: TranslationProvider
    /// 翻译服务地址（官方 API 或企业网关），不含 /v1/messages 或 /v1/responses 路径
    public var translationBaseURL: String
    /// 模型名，例如 "claude-haiku-4-5" 或网关侧的模型标识
    public var translationModel: String
    /// API 凭证（x-api-key / Bearer token）
    public var translationAuthToken: String
    /// 烧录字幕样式
    public var subtitleStyle: SubtitleStyle
    /// 烧录时限制最大分辨率高度：源高于此值则缩放到此值（既快又小，避开 4K60 的 H.264 上限）。
    /// nil = 保持源分辨率。默认 1080。
    public var maxBurnHeight: Int?

    public init(
        translationProvider: TranslationProvider = .anthropic,
        translationBaseURL: String = TranslationProvider.anthropic.defaultBaseURL,
        translationModel: String = "",
        translationAuthToken: String = "",
        subtitleStyle: SubtitleStyle = .bilingual,
        maxBurnHeight: Int? = 1080
    ) {
        self.translationProvider = translationProvider
        self.translationBaseURL = translationBaseURL
        self.translationModel = translationModel
        self.translationAuthToken = translationAuthToken
        self.subtitleStyle = subtitleStyle
        self.maxBurnHeight = maxBurnHeight
    }

    // MARK: 存储位置

    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("视频下载器", isDirectory: true)
    }

    public static var settingsFileURL: URL {
        supportDirectory.appendingPathComponent("settings.json")
    }

    /// 站点登录后导出的 Netscape 格式 cookies 文件；存在时引擎自动以 --cookies 传给 yt-dlp
    public static var cookieFileURL: URL {
        supportDirectory.appendingPathComponent("cookies.txt")
    }

    // MARK: 读写

    private enum CodingKeys: String, CodingKey {
        case translationProvider, translationBaseURL, translationModel, translationAuthToken, subtitleStyle, maxBurnHeight
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        translationBaseURL = try c.decodeIfPresent(String.self, forKey: .translationBaseURL)
            ?? TranslationProvider.anthropic.defaultBaseURL
        translationModel = try c.decodeIfPresent(String.self, forKey: .translationModel) ?? ""
        let rawProvider = try c.decodeIfPresent(String.self, forKey: .translationProvider)
        translationProvider = rawProvider.flatMap { TranslationProvider(rawValue: $0) }
            ?? Self.inferProvider(baseURL: translationBaseURL, model: translationModel)
        translationAuthToken = try c.decodeIfPresent(String.self, forKey: .translationAuthToken) ?? ""
        subtitleStyle = try c.decodeIfPresent(SubtitleStyle.self, forKey: .subtitleStyle) ?? .bilingual
        // 旧版 settings.json 没有这个键：缺失时按默认 1080 处理，而非「保持源分辨率」
        if c.contains(.maxBurnHeight) {
            maxBurnHeight = try c.decodeIfPresent(Int.self, forKey: .maxBurnHeight)
        } else {
            maxBurnHeight = 1080
        }
    }

    public static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsFileURL),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    public func save() throws {
        let dir = Self.supportDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let url = Self.settingsFileURL
        // 一步创建并带 0600 权限，避免「先 0644 落盘再收紧」的窗口（文件含凭证）
        guard FileManager.default.createFile(
            atPath: url.path, contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            try? FileManager.default.removeItem(at: url)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// 翻译功能是否已配置完整
    public var isTranslationConfigured: Bool {
        !translationBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !translationModel.trimmingCharacters(in: .whitespaces).isEmpty
            && !translationAuthToken.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 已填好服务地址和凭证，但模型可以稍后从候选菜单里选择。
    public var isTranslationEndpointConfigured: Bool {
        !translationBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !translationAuthToken.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func inferProvider(baseURL: String, model: String) -> TranslationProvider {
        let normalizedBase = baseURL.lowercased()
        let normalizedModel = model.lowercased()
        if normalizedBase.contains("api.openai.com")
            || normalizedModel.hasPrefix("gpt-")
            || normalizedModel.hasPrefix("o1")
            || normalizedModel.hasPrefix("o3")
            || normalizedModel.hasPrefix("o4")
            || normalizedModel.hasPrefix("o5") {
            return .openai
        }
        return .anthropic
    }
}
