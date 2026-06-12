namespace Vdl.Core;

/// <summary>一条待导出的 cookie（来自 GUI 层 WebView2 登录会话）。</summary>
public sealed record CookieRecord
{
    public required string Domain { get; init; }
    public required string Path { get; init; }
    public required string Name { get; init; }
    public required string Value { get; init; }
    public bool IsSecure { get; init; }
    /// <summary>过期时间（Unix 秒）；null 表示 session cookie（落盘写 0）。</summary>
    public long? ExpiresEpochSeconds { get; init; }
}

/// <summary>
/// 把 App 内 WebView 登录后取到的 cookies 导出成 yt-dlp 可读的 Netscape 格式文件。
/// 文件属于登录凭证，只落在本地应用数据目录。
/// </summary>
public static class NetscapeCookieFile
{
    /// <summary>
    /// 写入 Netscape 格式 cookies 文件（覆盖旧内容）。
    /// - 首行固定 "# Netscape HTTP Cookie File"。
    /// - 每行 7 个制表符分隔字段：domain、includeSubdomains、path、secure、expiry、name、value；
    ///   domain 以 "." 开头时 includeSubdomains 为 TRUE。
    /// - session cookie 的 expiry 写 0。
    /// - 字段里含制表符或换行会破坏行格式，这类 cookie 直接跳过。
    /// - 自动创建父目录。
    /// </summary>
    public static void Write(IEnumerable<CookieRecord> cookies, string path)
    {
        var lines = new List<string> { "# Netscape HTTP Cookie File" };
        foreach (var cookie in cookies)
        {
            var textFields = new[] { cookie.Domain, cookie.Path, cookie.Name, cookie.Value };
            if (textFields.Any(f => f.Contains('\t') || f.Contains('\n') || f.Contains('\r')))
            {
                continue;
            }
            var includeSubdomains = cookie.Domain.StartsWith('.') ? "TRUE" : "FALSE";
            var secure = cookie.IsSecure ? "TRUE" : "FALSE";
            var expiry = cookie.ExpiresEpochSeconds is { } epoch ? Math.Max(0, epoch) : 0;
            lines.Add(string.Join('\t',
                cookie.Domain, includeSubdomains, cookie.Path,
                secure, expiry.ToString(), cookie.Name, cookie.Value));
        }

        var parent = System.IO.Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(parent)) Directory.CreateDirectory(parent);
        File.WriteAllText(path, string.Join('\n', lines) + "\n");
    }

    /// <summary>删除 cookies 文件（清除登录态）；文件不存在时静默忽略。</summary>
    public static void Clear(string path)
    {
        try { File.Delete(path); } catch { /* 忽略 */ }
    }
}
