namespace Vdl.Core;

/// <summary>核心库文案语言。默认中文（与 macOS 版一致，单测也按中文断言）。</summary>
public enum CoreLanguage
{
    Chinese,
    English,
}

/// <summary>
/// 核心库用户可见文案的双语开关。GUI 启动/切换语言时设置 Language，
/// 之后产生的状态文案、错误消息按该语言生成（已生成的字符串不回溯改写）。
/// 文案保留在调用点（T(zh, en) 内联双语），不引入 key 间接层，便于对照评审。
/// </summary>
public static class L10n
{
    /// <summary>当前语言。简单静态开关：写入仅发生在启动/设置变更，读多写少，无需加锁。</summary>
    public static CoreLanguage Language { get; set; } = CoreLanguage.Chinese;

    /// <summary>按当前语言取文案。</summary>
    public static string T(string zh, string en) => Language == CoreLanguage.English ? en : zh;

    /// <summary>显式指定语言取文案（测试用，避免改全局状态影响并行用例）。</summary>
    public static string Pick(CoreLanguage language, string zh, string en) =>
        language == CoreLanguage.English ? en : zh;
}
