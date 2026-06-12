using System.Globalization;
using System.Windows;
using Vdl.Core;

namespace Vdl.App;

/// <summary>代码侧取界面文案（XAML 侧用 DynamicResource 直接引用同一批 key）。</summary>
internal static class Loc
{
    /// <summary>取字符串资源；缺 key 时回退 key 本身（便于发现遗漏，不崩溃）。</summary>
    public static string S(string key) =>
        Application.Current?.TryFindResource(key) as string ?? key;

    public static string F(string key, params object[] args) => string.Format(S(key), args);
}

/// <summary>
/// 界面语言管理：按设置（auto / zh-Hans / en）换装字符串资源字典并同步核心库 L10n。
/// XAML 用 DynamicResource 的文案即时切换；代码侧已生成的字符串在下次刷新时切换。
/// </summary>
public static class LocalizationManager
{
    /// <summary>语言切换后触发（UI 线程）：ViewModel 据此重算代码侧派生文案。</summary>
    public static event Action? LanguageChanged;

    public static bool IsEnglish { get; private set; }

    /// <summary>appLanguage："auto"（跟随系统 UI 语言）| "zh-Hans" | "en"。</summary>
    public static void Apply(string appLanguage)
    {
        IsEnglish = appLanguage switch
        {
            "en" => true,
            "zh-Hans" => false,
            // auto：系统界面语言是中文则用中文，其余一律英文
            _ => !CultureInfo.CurrentUICulture.TwoLetterISOLanguageName
                .Equals("zh", StringComparison.OrdinalIgnoreCase),
        };
        // 核心库的状态文案、错误消息跟随同一语言
        L10n.Language = IsEnglish ? CoreLanguage.English : CoreLanguage.Chinese;

        var app = Application.Current;
        if (app is not null)
        {
            var source = new Uri(IsEnglish ? "Strings.en.xaml" : "Strings.zh.xaml", UriKind.Relative);
            var dict = new ResourceDictionary { Source = source };
            var existing = app.Resources.MergedDictionaries
                .FirstOrDefault(d => d.Source?.OriginalString.Contains("Strings.") == true);
            if (existing is not null)
            {
                app.Resources.MergedDictionaries.Remove(existing);
            }
            app.Resources.MergedDictionaries.Add(dict);
        }
        LanguageChanged?.Invoke();
    }
}
