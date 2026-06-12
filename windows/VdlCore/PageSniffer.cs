using System.Text.Json;
using System.Text.RegularExpressions;

namespace Vdl.Core;

/// <summary>
/// 页面嗅探：抓取 HTML，按正则提取页面里的视频候选。
/// 用于 yt-dlp 报 "Unsupported URL" 的普通网页。
/// 网络请求（HTML 抓取 / 任天堂直链验证 / oEmbed 标题）均可注入替身，HTML 解析纯逻辑可单测。
/// </summary>
public sealed class PageSniffer
{
    public const string UserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15";

    /// <summary>共享 HttpClient：每次嗅探新建会随批量解析成批泄漏，故全局复用一个。</summary>
    private static readonly HttpClient SharedClient = new(new SocketsHttpHandler
    {
        PooledConnectionLifetime = TimeSpan.FromMinutes(5),
    })
    { Timeout = TimeSpan.FromSeconds(20) };

    private readonly HttpClient _client;

    /// <summary>测试注入：任天堂直链 HEAD 验证（默认真网络请求）。</summary>
    internal Func<string, CancellationToken, Task<bool>>? ValidateNintendoHook { get; set; }
    /// <summary>测试注入：YouTube oEmbed 标题获取（默认真网络请求）。</summary>
    internal Func<string, CancellationToken, Task<string?>>? FetchYouTubeTitleHook { get; set; }

    public PageSniffer(HttpMessageHandler? handler = null)
    {
        _client = handler is null
            ? SharedClient
            : new HttpClient(handler, disposeHandler: false) { Timeout = TimeSpan.FromSeconds(20) };
    }

    // MARK: - 入口

    public async Task<IReadOnlyList<VideoCandidate>> SniffAsync(Uri pageUrl, CancellationToken ct = default)
    {
        string html;
        try
        {
            html = await FetchHtmlAsync(pageUrl, ct).ConfigureAwait(false);
        }
        catch (VdlException)
        {
            throw;
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            throw VdlException.SniffFailed(L10n.T("页面加载失败，请检查网络后重试。",
                "The page failed to load. Check your network and retry."));
        }
        return await ExtractCandidatesAsync(html, pageUrl, ct).ConfigureAwait(false);
    }

    private async Task<string> FetchHtmlAsync(Uri url, CancellationToken ct)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.TryAddWithoutValidation("User-Agent", UserAgent);
        using var response = await _client.SendAsync(request, ct).ConfigureAwait(false);
        var status = (int)response.StatusCode;
        if (status is < 200 or > 299)
        {
            throw new HttpRequestException($"HTTP {status}");
        }
        // 大文件防护：用户可能把可直接 GET 的大媒体文件链接粘进来（yt-dlp 拿不下时
        // 会走到嗅探兜底）。非文本类型或超过 8MB 的响应不当 HTML 解析。
        var mime = response.Content.Headers.ContentType?.MediaType?.ToLowerInvariant();
        if (mime is not null
            && !(mime.Contains("html") || mime.Contains("text") || mime.Contains("xml")))
        {
            throw VdlException.SniffFailed(L10n.T($"这个链接指向的是媒体文件而非网页（{mime}），无法嗅探。",
                $"This link points to a media file, not a web page ({mime}); nothing to sniff."));
        }
        var data = await response.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
        if (data.Length > 8 * 1024 * 1024)
        {
            throw VdlException.SniffFailed(L10n.T($"页面过大（{data.Length / 1024 / 1024}MB），已停止嗅探。",
                $"The page is too large ({data.Length / 1024 / 1024}MB); sniffing stopped."));
        }
        return System.Text.Encoding.UTF8.GetString(data);
    }

    // MARK: - 提取

    private abstract record Finding
    {
        internal sealed record Media(Uri Url) : Finding;
        internal sealed record Youtube(string Id) : Finding;
        internal sealed record Vimeo(string Id) : Finding;
        internal sealed record NintendoMain(string Path) : Finding;  // data-videoid 以 "/" 开头的值
    }

    internal async Task<IReadOnlyList<VideoCandidate>> ExtractCandidatesAsync(
        string html, Uri pageUrl, CancellationToken ct = default)
    {
        var findings = new List<(int Offset, Finding Finding)>();

        IEnumerable<Match> Matches(string pattern) =>
            Regex.Matches(html, pattern, RegexOptions.IgnoreCase);
        // 把一个 URL 字符串归类为 youtube / vimeo / 直链媒体。
        void Classify(string raw, int offset)
        {
            var value = raw.Trim()
                .Replace("&amp;", "&")
                .Replace("\\/", "/");
            if (value.Length == 0) return;
            var lower = value.ToLowerInvariant();
            if (lower.StartsWith("data:") || lower.StartsWith("blob:") || lower.StartsWith("javascript:"))
            {
                return;
            }
            if (YoutubeId(value) is { } youtubeId)
            {
                findings.Add((offset, new Finding.Youtube(youtubeId)));
                return;
            }
            if (VimeoId(value) is { } vimeoId)
            {
                findings.Add((offset, new Finding.Vimeo(vimeoId)));
                return;
            }
            if (!Uri.TryCreate(pageUrl, value, out var resolved)
                || (resolved.Scheme != "http" && resolved.Scheme != "https"))
            {
                return;
            }
            findings.Add((offset, new Finding.Media(resolved)));
        }

        // 1. og:video / twitter:player:stream（属性顺序两种写法都覆盖）
        string[] metaPatterns =
        [
            """<meta\b[^>]*?(?:property|name)\s*=\s*["'](?:og:video(?::(?:secure_)?url)?|twitter:player:stream)["'][^>]*?content\s*=\s*["']([^"']+)["']""",
            """<meta\b[^>]*?content\s*=\s*["']([^"']+)["'][^>]*?(?:property|name)\s*=\s*["'](?:og:video(?::(?:secure_)?url)?|twitter:player:stream)["']""",
        ];
        foreach (var pattern in metaPatterns)
        {
            foreach (var match in Matches(pattern))
            {
                if (match.Groups[1].Success) Classify(match.Groups[1].Value, match.Index);
            }
        }

        // 2. <video src> 与 <source src>
        foreach (var match in Matches("""<(?:video|source)\b[^>]*?src\s*=\s*["']([^"']+)["']"""))
        {
            if (match.Groups[1].Success) Classify(match.Groups[1].Value, match.Index);
        }

        // 3. YouTube / Vimeo 嵌入（iframe、链接、脚本里出现的都算）
        foreach (var match in Matches(YoutubeIdPattern))
        {
            if (match.Groups[1].Success) findings.Add((match.Index, new Finding.Youtube(match.Groups[1].Value)));
        }
        foreach (var match in Matches(VimeoIdPattern))
        {
            if (match.Groups[1].Success) findings.Add((match.Index, new Finding.Vimeo(match.Groups[1].Value)));
        }

        // 4/5. data-videoid 系列属性
        var isNintendo = IsNintendoHost(pageUrl.Host);
        foreach (var match in Matches("""data-(?:videoid|video-id|youtube-id)\s*=\s*["']([^"']+)["']"""))
        {
            if (!match.Groups[1].Success) continue;
            var value = match.Groups[1].Value;
            if (Regex.IsMatch(value, "^[A-Za-z0-9_-]{11}$"))
            {
                findings.Add((match.Index, new Finding.Youtube(value)));
            }
            else if (isNintendo && value.StartsWith('/'))
            {
                findings.Add((match.Index, new Finding.NintendoMain(value)));
            }
        }

        // 6. HTML 里裸的绝对媒体地址
        foreach (var match in Matches("""https?://[^\s"'<>\\]+?\.(?:mp4|m3u8|webm|mov)(?:\?[^\s"'<>]*)?"""))
        {
            Classify(match.Value, match.Index);
        }

        // 7. JSON 转义的直链（https:\/\/…\/a.mp4），Classify 会把 \/ 反转义后归类
        foreach (var match in Matches("""https?:(?:\\/|/){2}[^\s"'<>]+?\.(?:mp4|m3u8|webm|mov)(?:\?[^\s"'<>]*)?"""))
        {
            Classify(match.Value, match.Index);
        }

        findings.Sort((x, y) => x.Offset.CompareTo(y.Offset));
        return await BuildCandidatesAsync(findings, html, ct).ConfigureAwait(false);
    }

    // MARK: - 组装候选

    private async Task<IReadOnlyList<VideoCandidate>> BuildCandidatesAsync(
        List<(int Offset, Finding Finding)> findings, string html, CancellationToken ct)
    {
        var pageTitle = PageTitle(html);

        // 任天堂主视频：拼地址后用 HEAD 验证再收录。
        var nintendoOrdered = new List<(int Offset, string Url)>();
        var seenNintendo = new HashSet<string>();
        foreach (var (offset, finding) in findings)
        {
            if (finding is Finding.NintendoMain nintendo)
            {
                var urlString = "https://assets.nintendo.com/video/upload" + nintendo.Path + ".mp4";
                if (seenNintendo.Add(urlString))
                {
                    nintendoOrdered.Add((offset, urlString));
                }
            }
        }

        var prepared = new List<(int Rank, int Offset, VideoCandidate Candidate)>();
        var seenMedia = new HashSet<string>();

        foreach (var (offset, urlString) in nintendoOrdered)
        {
            if (!await ValidateNintendoAssetAsync(urlString, ct).ConfigureAwait(false)) continue;
            seenMedia.Add(urlString);
            var title = pageTitle ?? FileBaseName(urlString) ?? urlString;
            prepared.Add((0, offset, new VideoCandidate
            {
                Url = urlString,
                Kind = VideoCandidate.CandidateKind.PageMain,
                Title = title,
                Detail = "assets.nintendo.com · mp4 直链",
            }));
        }

        var youtubeOrdered = new List<(int Offset, string Id)>();
        var vimeoOrdered = new List<(int Offset, string Id)>();
        var seenYouTube = new HashSet<string>();
        var seenVimeo = new HashSet<string>();

        foreach (var (offset, finding) in findings)
        {
            switch (finding)
            {
                case Finding.Media media:
                {
                    var urlString = media.Url.AbsoluteUri;
                    if (!seenMedia.Add(urlString)) continue;
                    var ext = Path.GetExtension(media.Url.AbsolutePath).TrimStart('.').ToLowerInvariant();
                    var host = media.Url.Host;
                    var detail = ext.Length == 0 ? host : $"{host} · {ext}";
                    var baseName = FileBaseName(urlString);
                    var title = baseName ?? pageTitle ?? urlString;
                    prepared.Add((1, offset, new VideoCandidate
                    {
                        Url = urlString,
                        Kind = VideoCandidate.CandidateKind.DirectFile,
                        Title = title,
                        Detail = detail,
                    }));
                    break;
                }
                case Finding.Youtube youtube:
                    if (seenYouTube.Add(youtube.Id)) youtubeOrdered.Add((offset, youtube.Id));
                    break;
                case Finding.Vimeo vimeo:
                    if (seenVimeo.Add(vimeo.Id)) vimeoOrdered.Add((offset, vimeo.Id));
                    break;
                case Finding.NintendoMain:
                    break;
            }
        }

        // YouTube 标题：oEmbed 并发获取，失败用占位名。
        var youtubeTitles = new Dictionary<string, string>();
        if (youtubeOrdered.Count > 0)
        {
            var titleTasks = youtubeOrdered.Select(async pair =>
                (pair.Id, Title: await FetchYouTubeTitleAsync(pair.Id, ct).ConfigureAwait(false)));
            foreach (var (id, title) in await Task.WhenAll(titleTasks).ConfigureAwait(false))
            {
                if (title is not null) youtubeTitles[id] = title;
            }
        }
        foreach (var (offset, id) in youtubeOrdered)
        {
            prepared.Add((2, offset, new VideoCandidate
            {
                Url = $"https://www.youtube.com/watch?v={id}",
                Kind = VideoCandidate.CandidateKind.Youtube,
                Title = youtubeTitles.TryGetValue(id, out var title) ? title : L10n.T($"YouTube 视频 {id}", $"YouTube video {id}"),
                Detail = "YouTube",
            }));
        }
        foreach (var (offset, id) in vimeoOrdered)
        {
            prepared.Add((2, offset, new VideoCandidate
            {
                Url = $"https://vimeo.com/{id}",
                Kind = VideoCandidate.CandidateKind.Vimeo,
                Title = L10n.T($"Vimeo 视频 {id}", $"Vimeo video {id}"),
                Detail = "Vimeo",
            }));
        }

        prepared.Sort((x, y) => x.Rank != y.Rank ? x.Rank.CompareTo(y.Rank) : x.Offset.CompareTo(y.Offset));
        return prepared.Select(p => p.Candidate).ToList();
    }

    // MARK: - 网络辅助

    private Task<bool> ValidateNintendoAssetAsync(string urlString, CancellationToken ct) =>
        ValidateNintendoHook?.Invoke(urlString, ct) ?? DefaultValidateNintendoAssetAsync(urlString, ct);

    private async Task<bool> DefaultValidateNintendoAssetAsync(string urlString, CancellationToken ct)
    {
        if (!Uri.TryCreate(urlString, UriKind.Absolute, out var url)) return false;
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Head, url);
            request.Headers.TryAddWithoutValidation("User-Agent", UserAgent);
            using var response = await _client.SendAsync(request, ct).ConfigureAwait(false);
            var contentType = response.Content.Headers.ContentType?.MediaType?.ToLowerInvariant() ?? "";
            return (int)response.StatusCode == 200 && contentType.StartsWith("video/");
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            return false;
        }
    }

    private Task<string?> FetchYouTubeTitleAsync(string id, CancellationToken ct) =>
        FetchYouTubeTitleHook?.Invoke(id, ct) ?? DefaultFetchYouTubeTitleAsync(id, ct);

    private async Task<string?> DefaultFetchYouTubeTitleAsync(string id, CancellationToken ct)
    {
        var url = $"https://www.youtube.com/oembed?url={Uri.EscapeDataString($"https://www.youtube.com/watch?v={id}")}&format=json";
        try
        {
            using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeoutCts.CancelAfter(TimeSpan.FromSeconds(8));
            using var response = await _client.GetAsync(url, timeoutCts.Token).ConfigureAwait(false);
            if ((int)response.StatusCode != 200) return null;
            var body = await response.Content.ReadAsStringAsync(timeoutCts.Token).ConfigureAwait(false);
            using var doc = JsonDocument.Parse(body);
            if (doc.RootElement.ValueKind == JsonValueKind.Object
                && doc.RootElement.TryGetProperty("title", out var title)
                && title.ValueKind == JsonValueKind.String
                && title.GetString() is { Length: > 0 } value)
            {
                return value;
            }
            return null;
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            return null;
        }
    }

    // MARK: - 静态辅助

    internal const string YoutubeIdPattern =
        """(?:youtube(?:-nocookie)?\.com/(?:embed|shorts|live|v)/|youtube\.com/watch\?[^"'<>\s]*?v=|youtu\.be/)([A-Za-z0-9_-]{11})(?![A-Za-z0-9_-])""";
    internal const string VimeoIdPattern = """player\.vimeo\.com/video/(\d+)""";

    internal static string? YoutubeId(string text) => FirstCapture(YoutubeIdPattern, text);

    internal static string? VimeoId(string text) => FirstCapture(VimeoIdPattern, text);

    private static string? FirstCapture(string pattern, string text)
    {
        var match = Regex.Match(text, pattern, RegexOptions.IgnoreCase);
        return match.Success && match.Groups[1].Success ? match.Groups[1].Value : null;
    }

    internal static bool IsNintendoHost(string? host)
    {
        if (host is null) return false;
        var h = host.ToLowerInvariant();
        return h == "nintendo.com" || h.EndsWith(".nintendo.com");
    }

    /// <summary>页面 &lt;title&gt;，去掉 " | Play Nintendo" 之类站名尾巴。</summary>
    internal static string? PageTitle(string html)
    {
        var match = Regex.Match(html, "<title[^>]*>([\\s\\S]*?)</title>", RegexOptions.IgnoreCase);
        if (!match.Success || !match.Groups[1].Success) return null;
        var title = DecodeEntities(match.Groups[1].Value).Trim();
        foreach (var separator in new[] { " | ", " – ", " — ", " - " })
        {
            var range = title.LastIndexOf(separator, StringComparison.Ordinal);
            if (range >= 0)
            {
                title = title[..range].Trim();
                break;
            }
        }
        return title.Length == 0 ? null : title;
    }

    internal static string? FileBaseName(string urlString)
    {
        if (!Uri.TryCreate(urlString, UriKind.Absolute, out var url)) return null;
        var last = url.AbsolutePath.Split('/').LastOrDefault(s => s.Length > 0) ?? "";
        var baseName = Path.GetFileNameWithoutExtension(last);
        if (baseName.Length == 0 || baseName == "/") return null;
        return Uri.UnescapeDataString(baseName);
    }

    internal static string DecodeEntities(string text)
    {
        var result = text;
        var map = new Dictionary<string, string>
        {
            ["&amp;"] = "&", ["&lt;"] = "<", ["&gt;"] = ">",
            ["&quot;"] = "\"", ["&#39;"] = "'", ["&apos;"] = "'", ["&nbsp;"] = " ",
        };
        foreach (var (entity, plain) in map)
        {
            result = result.Replace(entity, plain);
        }
        return result;
    }
}
