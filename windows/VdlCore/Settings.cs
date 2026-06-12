using System.Text.Json;

namespace Vdl.Core;

public enum TranslationProvider
{
    Anthropic,
    Openai,
}

public static class TranslationProviderExtensions
{
    public static string DefaultBaseUrl(this TranslationProvider provider) => provider switch
    {
        TranslationProvider.Anthropic => "https://api.anthropic.com",
        TranslationProvider.Openai => "https://api.openai.com",
        _ => "https://api.anthropic.com",
    };

    /// <summary>JSON 持久化值（与 Swift 版 rawValue 一致）。</summary>
    public static string RawValue(this TranslationProvider provider) => provider switch
    {
        TranslationProvider.Openai => "openai",
        _ => "anthropic",
    };

    public static TranslationProvider? FromRawValue(string? raw) => raw switch
    {
        "anthropic" => TranslationProvider.Anthropic,
        "openai" => TranslationProvider.Openai,
        _ => null,
    };
}

/// <summary>
/// App 设置。持久化在 %APPDATA%\VideoDownloader\settings.json。
/// 注意：AuthToken 属于敏感凭证，只落在本地配置文件，绝不写入代码、日志或版本库。
/// 字段名与 Swift 版 settings.json 完全一致，便于排查问题时对照。
/// </summary>
public sealed record AppSettings
{
    /// <summary>翻译接口协议。</summary>
    public TranslationProvider TranslationProvider { get; init; } = TranslationProvider.Anthropic;
    /// <summary>翻译服务地址（官方 API 或企业网关），不含 /v1/messages 或 /v1/responses 路径。</summary>
    public string TranslationBaseUrl { get; init; } = TranslationProvider.Anthropic.DefaultBaseUrl();
    /// <summary>模型名，例如 "claude-haiku-4-5" 或网关侧的模型标识。</summary>
    public string TranslationModel { get; init; } = "";
    /// <summary>API 凭证（x-api-key / Bearer token）。</summary>
    public string TranslationAuthToken { get; init; } = "";
    /// <summary>烧录字幕样式。</summary>
    public SubtitleStyle SubtitleStyle { get; init; } = SubtitleStyle.Bilingual;
    /// <summary>
    /// 烧录时限制最大分辨率高度：源高于此值则缩放到此值（既快又小，避开 4K60 的 H.264 上限）。
    /// null = 保持源分辨率。默认 1080。
    /// </summary>
    public int? MaxBurnHeight { get; init; } = 1080;
    /// <summary>同时进行的下载任务数（1...5，默认 3）。</summary>
    public int MaxConcurrentDownloads { get; init; } = 3;
    /// <summary>同时进行的压制（烧录）任务数（1...3，默认 2）。压制吃满 CPU，并行多了互相拖慢。</summary>
    public int MaxConcurrentBurns { get; init; } = 2;
    /// <summary>界面语言："auto"（跟随系统）、"zh-Hans"、"en"。</summary>
    public string AppLanguage { get; init; } = "auto";

    // MARK: 存储位置

    /// <summary>测试注入：非空时所有路径都以它为根目录（替代 %APPDATA%\VideoDownloader）。</summary>
    public static string? OverrideSupportDirectory { get; set; }

    public static string SupportDirectory
    {
        get
        {
            if (OverrideSupportDirectory is { Length: > 0 } overridden) return overridden;
            // Windows: %APPDATA%\VideoDownloader；非 Windows（开发/测试）退到用户配置目录下同名文件夹。
            var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            return Path.Combine(appData, "VideoDownloader");
        }
    }

    public static string SettingsFilePath => Path.Combine(SupportDirectory, "settings.json");

    /// <summary>站点登录后导出的 Netscape 格式 cookies 文件；存在时引擎自动以 --cookies 传给 yt-dlp。</summary>
    public static string CookieFilePath => Path.Combine(SupportDirectory, "cookies.txt");

    // MARK: 读写

    public static AppSettings Load()
    {
        try
        {
            return File.Exists(SettingsFilePath)
                ? FromJson(File.ReadAllText(SettingsFilePath))
                : new AppSettings();
        }
        catch
        {
            return new AppSettings();
        }
    }

    /// <summary>容错解析：缺字段按默认，非法值回退默认，并发数读入时夹回合法区间。</summary>
    public static AppSettings FromJson(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;

        static string? StringField(JsonElement root, string name) =>
            root.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
        static int? IntField(JsonElement root, string name) =>
            root.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out var i) ? i : null;

        var baseUrl = StringField(root, "translationBaseURL")
            ?? TranslationProvider.Anthropic.DefaultBaseUrl();
        var model = StringField(root, "translationModel") ?? "";
        // provider 键缺失（旧版配置）时按 baseURL/模型名推断
        var provider = TranslationProviderExtensions.FromRawValue(StringField(root, "translationProvider"))
            ?? InferProvider(baseUrl, model);
        var style = StringField(root, "subtitleStyle") switch
        {
            "chineseOnly" => SubtitleStyle.ChineseOnly,
            _ => SubtitleStyle.Bilingual,
        };
        // 旧版 settings.json 没有 maxBurnHeight 键：缺失时按默认 1080 处理，而非「保持源分辨率」；
        // 显式 null 才表示保持源分辨率。
        int? maxBurnHeight = 1080;
        if (root.TryGetProperty("maxBurnHeight", out var heightValue))
        {
            maxBurnHeight = heightValue.ValueKind == JsonValueKind.Number && heightValue.TryGetInt32(out var h)
                ? h
                : null;
        }

        // 语言：未知值按 auto 容错
        var appLanguage = StringField(root, "appLanguage") switch
        {
            "zh-Hans" => "zh-Hans",
            "en" => "en",
            _ => "auto",
        };

        return new AppSettings
        {
            TranslationProvider = provider,
            TranslationBaseUrl = baseUrl,
            TranslationModel = model,
            TranslationAuthToken = StringField(root, "translationAuthToken") ?? "",
            SubtitleStyle = style,
            MaxBurnHeight = maxBurnHeight,
            MaxConcurrentDownloads = Math.Clamp(IntField(root, "maxConcurrentDownloads") ?? 3, 1, 5),
            MaxConcurrentBurns = Math.Clamp(IntField(root, "maxConcurrentBurns") ?? 2, 1, 3),
            AppLanguage = appLanguage,
        };
    }

    public string ToJson()
    {
        // 手写字段映射保证键名与 Swift 版一致（枚举存 rawValue 字符串、null 显式落盘）。
        var payload = new Dictionary<string, object?>
        {
            ["translationProvider"] = TranslationProvider.RawValue(),
            ["translationBaseURL"] = TranslationBaseUrl,
            ["translationModel"] = TranslationModel,
            ["translationAuthToken"] = TranslationAuthToken,
            ["subtitleStyle"] = SubtitleStyle == SubtitleStyle.ChineseOnly ? "chineseOnly" : "bilingual",
            ["maxBurnHeight"] = MaxBurnHeight,
            ["maxConcurrentDownloads"] = MaxConcurrentDownloads,
            ["maxConcurrentBurns"] = MaxConcurrentBurns,
            ["appLanguage"] = AppLanguage,
        };
        return JsonSerializer.Serialize(payload, new JsonSerializerOptions { WriteIndented = true });
    }

    /// <summary>
    /// 原子写：先写临时文件再替换。写失败时旧配置（含凭证）原样保留，
    /// 不能删旧文件导致磁盘满/权限问题时配置全丢。
    /// </summary>
    public void Save()
    {
        var dir = SupportDirectory;
        Directory.CreateDirectory(dir);
        var temp = Path.Combine(dir, $"settings.json.tmp-{Guid.NewGuid():N}");
        try
        {
            File.WriteAllText(temp, ToJson());
            // File.Move(overwrite: true) 在同一卷上是原子替换
            File.Move(temp, SettingsFilePath, overwrite: true);
        }
        catch
        {
            try { File.Delete(temp); } catch { /* 忽略 */ }
            throw;
        }
    }

    // MARK: 派生状态

    /// <summary>翻译功能是否已配置完整。</summary>
    public bool IsTranslationConfigured =>
        !string.IsNullOrWhiteSpace(TranslationBaseUrl)
        && !string.IsNullOrWhiteSpace(TranslationModel)
        && !string.IsNullOrWhiteSpace(TranslationAuthToken);

    /// <summary>已填好服务地址和凭证，但模型可以稍后从候选菜单里选择。</summary>
    public bool IsTranslationEndpointConfigured =>
        !string.IsNullOrWhiteSpace(TranslationBaseUrl)
        && !string.IsNullOrWhiteSpace(TranslationAuthToken);

    internal static TranslationProvider InferProvider(string baseUrl, string model)
    {
        var normalizedBase = baseUrl.ToLowerInvariant();
        var normalizedModel = model.ToLowerInvariant();
        if (normalizedBase.Contains("api.openai.com")
            || normalizedModel.StartsWith("gpt-")
            || normalizedModel.StartsWith("o1")
            || normalizedModel.StartsWith("o3")
            || normalizedModel.StartsWith("o4")
            || normalizedModel.StartsWith("o5"))
        {
            return TranslationProvider.Openai;
        }
        return TranslationProvider.Anthropic;
    }
}
