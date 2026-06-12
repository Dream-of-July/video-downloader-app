using Vdl.Core;

namespace VdlCore.Tests;

public class SettingsTests
{
    [Fact]
    public void Defaults()
    {
        var settings = new AppSettings();
        Assert.Equal(TranslationProvider.Anthropic, settings.TranslationProvider);
        Assert.Equal("https://api.anthropic.com", settings.TranslationBaseUrl);
        Assert.Equal(SubtitleStyle.Bilingual, settings.SubtitleStyle);
        Assert.Equal(1080, settings.MaxBurnHeight);
        Assert.Equal(3, settings.MaxConcurrentDownloads);
        Assert.Equal(2, settings.MaxConcurrentBurns);
    }

    /// <summary>缺字段容错：空 JSON 全部回默认（maxBurnHeight 缺失按 1080 而非「保持源」）。</summary>
    [Fact]
    public void FromJson_EmptyObject_AllDefaults()
    {
        var settings = AppSettings.FromJson("{}");
        Assert.Equal(new AppSettings(), settings);
        Assert.Equal(1080, settings.MaxBurnHeight);
    }

    /// <summary>显式 null 的 maxBurnHeight 表示「保持源分辨率」。</summary>
    [Fact]
    public void FromJson_ExplicitNullBurnHeight_MeansKeepSource()
    {
        var settings = AppSettings.FromJson("""{"maxBurnHeight": null}""");
        Assert.Null(settings.MaxBurnHeight);
    }

    [Fact]
    public void FromJson_ConcurrencyClampedToValidRange()
    {
        var settings = AppSettings.FromJson("""{"maxConcurrentDownloads": 99, "maxConcurrentBurns": 0}""");
        Assert.Equal(5, settings.MaxConcurrentDownloads);
        Assert.Equal(1, settings.MaxConcurrentBurns);
    }

    /// <summary>旧版配置没有 provider 键：按 baseURL / 模型名推断。</summary>
    [Fact]
    public void FromJson_MissingProvider_InferredFromBaseUrlOrModel()
    {
        var byBase = AppSettings.FromJson("""{"translationBaseURL": "https://api.openai.com"}""");
        Assert.Equal(TranslationProvider.Openai, byBase.TranslationProvider);

        var byModel = AppSettings.FromJson("""{"translationBaseURL": "https://gw.corp.com", "translationModel": "gpt-4o"}""");
        Assert.Equal(TranslationProvider.Openai, byModel.TranslationProvider);

        var anthropic = AppSettings.FromJson("""{"translationBaseURL": "https://gw.corp.com", "translationModel": "claude-haiku"}""");
        Assert.Equal(TranslationProvider.Anthropic, anthropic.TranslationProvider);
    }

    [Fact]
    public void FromJson_SubtitleStyleParsed()
    {
        Assert.Equal(SubtitleStyle.ChineseOnly,
            AppSettings.FromJson("""{"subtitleStyle": "chineseOnly"}""").SubtitleStyle);
        Assert.Equal(SubtitleStyle.Bilingual,
            AppSettings.FromJson("""{"subtitleStyle": "bogus"}""").SubtitleStyle);
    }

    [Fact]
    public void SaveLoad_RoundTrip_AtomicWrite()
    {
        var dir = Path.Combine(Path.GetTempPath(), $"vdl-settings-{Guid.NewGuid():N}");
        AppSettings.OverrideSupportDirectory = dir;
        try
        {
            var settings = new AppSettings
            {
                TranslationProvider = TranslationProvider.Openai,
                TranslationBaseUrl = "https://gw.corp.com",
                TranslationModel = "gpt-4o-mini",
                TranslationAuthToken = "tok-123",
                SubtitleStyle = SubtitleStyle.ChineseOnly,
                MaxBurnHeight = null,
                MaxConcurrentDownloads = 5,
                MaxConcurrentBurns = 1,
            };
            settings.Save();
            Assert.True(File.Exists(AppSettings.SettingsFilePath));
            // 临时文件不残留
            Assert.Empty(Directory.GetFiles(dir, "*.tmp-*"));

            var loaded = AppSettings.Load();
            Assert.Equal(settings, loaded);
        }
        finally
        {
            AppSettings.OverrideSupportDirectory = null;
            try { Directory.Delete(dir, true); } catch { /* 忽略 */ }
        }
    }

    [Fact]
    public void Load_CorruptedFile_ReturnsDefaults()
    {
        var dir = Path.Combine(Path.GetTempPath(), $"vdl-settings-{Guid.NewGuid():N}");
        AppSettings.OverrideSupportDirectory = dir;
        try
        {
            Directory.CreateDirectory(dir);
            File.WriteAllText(AppSettings.SettingsFilePath, "not json at all");
            Assert.Equal(new AppSettings(), AppSettings.Load());
        }
        finally
        {
            AppSettings.OverrideSupportDirectory = null;
            try { Directory.Delete(dir, true); } catch { /* 忽略 */ }
        }
    }

    [Fact]
    public void IsTranslationConfigured_RequiresAllThreeFields()
    {
        var ready = new AppSettings { TranslationModel = "m", TranslationAuthToken = "t" };
        Assert.True(ready.IsTranslationConfigured);
        Assert.True(ready.IsTranslationEndpointConfigured);

        var noModel = ready with { TranslationModel = " " };
        Assert.False(noModel.IsTranslationConfigured);
        Assert.True(noModel.IsTranslationEndpointConfigured);
    }

    /// <summary>界面语言：默认 auto，未知值容错回 auto，合法值原样保留并随 JSON 往返。</summary>
    [Fact]
    public void AppLanguage_DefaultAuto_ToleratesUnknown_RoundTrips()
    {
        Assert.Equal("auto", new AppSettings().AppLanguage);
        Assert.Equal("auto", AppSettings.FromJson("{}").AppLanguage);
        Assert.Equal("auto", AppSettings.FromJson("""{"appLanguage": "klingon"}""").AppLanguage);
        Assert.Equal("en", AppSettings.FromJson("""{"appLanguage": "en"}""").AppLanguage);
        Assert.Equal("zh-Hans", AppSettings.FromJson("""{"appLanguage": "zh-Hans"}""").AppLanguage);

        var settings = new AppSettings { AppLanguage = "en" };
        Assert.Equal("en", AppSettings.FromJson(settings.ToJson()).AppLanguage);
    }

    /// <summary>L10n：默认中文；Pick 按显式语言取文案（不动全局开关，避免并行用例互扰）。</summary>
    [Fact]
    public void L10n_DefaultsToChinese_PickIsExplicit()
    {
        Assert.Equal(CoreLanguage.Chinese, L10n.Language);
        Assert.Equal("你好", L10n.Pick(CoreLanguage.Chinese, "你好", "hello"));
        Assert.Equal("hello", L10n.Pick(CoreLanguage.English, "你好", "hello"));
    }

    [Fact]
    public void CookieFilePath_SameDirectoryAsSettings()
    {
        AppSettings.OverrideSupportDirectory = "/tmp/vdl-x";
        try
        {
            Assert.Equal(Path.Combine("/tmp/vdl-x", "cookies.txt"), AppSettings.CookieFilePath);
            Assert.Equal(Path.Combine("/tmp/vdl-x", "settings.json"), AppSettings.SettingsFilePath);
        }
        finally
        {
            AppSettings.OverrideSupportDirectory = null;
        }
    }
}

public class CookieFileTests
{
    [Fact]
    public void Write_NetscapeFormat()
    {
        var path = Path.Combine(Path.GetTempPath(), $"vdl-cookies-{Guid.NewGuid():N}", "cookies.txt");
        try
        {
            NetscapeCookieFile.Write(
            [
                new CookieRecord
                {
                    Domain = ".youtube.com", Path = "/", Name = "SID", Value = "abc123",
                    IsSecure = true, ExpiresEpochSeconds = 1893456000,
                },
                new CookieRecord
                {
                    Domain = "example.com", Path = "/x", Name = "session", Value = "s1",
                    IsSecure = false, ExpiresEpochSeconds = null,  // session cookie
                },
                new CookieRecord
                {
                    Domain = "bad.com", Path = "/", Name = "evil", Value = "a\tb",  // 含制表符 → 跳过
                    IsSecure = false, ExpiresEpochSeconds = 0,
                },
            ], path);

            var lines = File.ReadAllLines(path);
            Assert.Equal("# Netscape HTTP Cookie File", lines[0]);
            Assert.Equal(3, lines.Length);  // 头 + 两条（坏 cookie 跳过）
            Assert.Equal(".youtube.com\tTRUE\t/\tTRUE\t1893456000\tSID\tabc123", lines[1]);
            Assert.Equal("example.com\tFALSE\t/x\tFALSE\t0\tsession\ts1", lines[2]);
        }
        finally
        {
            try { Directory.Delete(Path.GetDirectoryName(path)!, true); } catch { /* 忽略 */ }
        }
    }

    [Fact]
    public void Write_NegativeExpiry_ClampedToZero()
    {
        var path = Path.Combine(Path.GetTempPath(), $"vdl-cookies-{Guid.NewGuid():N}.txt");
        try
        {
            NetscapeCookieFile.Write(
            [
                new CookieRecord
                {
                    Domain = "a.com", Path = "/", Name = "n", Value = "v",
                    ExpiresEpochSeconds = -5,
                },
            ], path);
            Assert.Contains("a.com\tFALSE\t/\tFALSE\t0\tn\tv", File.ReadAllText(path));
        }
        finally
        {
            try { File.Delete(path); } catch { /* 忽略 */ }
        }
    }

    [Fact]
    public void Clear_MissingFile_Silent()
    {
        NetscapeCookieFile.Clear("/tmp/definitely-not-there-" + Guid.NewGuid());
    }
}
