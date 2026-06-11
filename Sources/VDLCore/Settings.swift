import Foundation

/// App 设置。持久化在 ~/Library/Application Support/视频下载器/settings.json（0600）。
/// 注意：authToken 属于敏感凭证，只落在本地配置文件，绝不写入代码、日志或版本库。
public struct AppSettings: Codable, Sendable, Equatable {
    /// Anthropic 协议服务地址（官方 API 或企业网关），不含 /v1/messages 路径
    public var translationBaseURL: String
    /// 模型名，例如 "claude-haiku-4-5" 或网关侧的模型标识
    public var translationModel: String
    /// API 凭证（x-api-key / Bearer token）
    public var translationAuthToken: String
    /// 烧录字幕样式
    public var subtitleStyle: SubtitleStyle

    public init(
        translationBaseURL: String = "https://api.anthropic.com",
        translationModel: String = "",
        translationAuthToken: String = "",
        subtitleStyle: SubtitleStyle = .bilingual
    ) {
        self.translationBaseURL = translationBaseURL
        self.translationModel = translationModel
        self.translationAuthToken = translationAuthToken
        self.subtitleStyle = subtitleStyle
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
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// 翻译功能是否已配置完整
    public var isTranslationConfigured: Bool {
        !translationBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !translationModel.trimmingCharacters(in: .whitespaces).isEmpty
            && !translationAuthToken.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
