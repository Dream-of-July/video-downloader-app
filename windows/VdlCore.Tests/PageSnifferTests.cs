using Vdl.Core;

namespace VdlCore.Tests;

public class PageSnifferTests
{
    /// <summary>所有网络钩子注入替身的嗅探器。</summary>
    private static PageSniffer OfflineSniffer(
        bool nintendoValid = true,
        Func<string, string?>? youtubeTitle = null) => new()
    {
        ValidateNintendoHook = (_, _) => Task.FromResult(nintendoValid),
        FetchYouTubeTitleHook = (id, _) => Task.FromResult(youtubeTitle?.Invoke(id)),
    };

    /// <summary>Nintendo 规则：assets.nintendo.com/video/upload + data-videoid + .mp4。</summary>
    [Fact]
    public async Task Nintendo_DataVideoId_BuildsCdnUrl()
    {
        const string html = """
            <html><head><title>Splatoon Trailer | Nintendo</title></head>
            <body><div class="player" data-videoid="/Splatoon/trailer_01"></div></body></html>
            """;
        var candidates = await OfflineSniffer().ExtractCandidatesAsync(
            html, new Uri("https://www.nintendo.com/whatsnew/"));

        var candidate = Assert.Single(candidates);
        Assert.Equal("https://assets.nintendo.com/video/upload/Splatoon/trailer_01.mp4", candidate.Url);
        Assert.Equal(VideoCandidate.CandidateKind.PageMain, candidate.Kind);
        Assert.Equal("Splatoon Trailer", candidate.Title);  // 页面标题去站名尾巴
        Assert.Equal("assets.nintendo.com · mp4 直链", candidate.Detail);
    }

    /// <summary>HEAD 验证失败的任天堂直链不收录。</summary>
    [Fact]
    public async Task Nintendo_ValidationFails_Excluded()
    {
        const string html = """<div data-videoid="/dead/link"></div>""";
        var candidates = await OfflineSniffer(nintendoValid: false).ExtractCandidatesAsync(
            html, new Uri("https://www.nintendo.com/"));
        Assert.Empty(candidates);
    }

    /// <summary>非任天堂站点的 data-videoid 路径值不按任天堂规则处理。</summary>
    [Fact]
    public async Task NonNintendoHost_PathVideoId_Ignored()
    {
        const string html = """<div data-videoid="/some/path"></div>""";
        var candidates = await OfflineSniffer().ExtractCandidatesAsync(
            html, new Uri("https://www.example.com/"));
        Assert.Empty(candidates);
    }

    [Fact]
    public async Task OgVideo_BecomesDirectFileCandidate()
    {
        const string html = """
            <html><head>
            <title>Cool Page</title>
            <meta property="og:video:secure_url" content="https://cdn.example.com/v/movie.mp4">
            </head></html>
            """;
        var candidates = await OfflineSniffer().ExtractCandidatesAsync(
            html, new Uri("https://www.example.com/page"));

        var candidate = Assert.Single(candidates);
        Assert.Equal("https://cdn.example.com/v/movie.mp4", candidate.Url);
        Assert.Equal(VideoCandidate.CandidateKind.DirectFile, candidate.Kind);
        Assert.Equal("movie", candidate.Title);  // 直链优先用文件名
        Assert.Equal("cdn.example.com · mp4", candidate.Detail);
    }

    /// <summary>YouTube ID 正则：embed/shorts/live/v 路径 + 11 位边界。</summary>
    [Fact]
    public async Task YouTubeEmbeds_ExtractedWithOEmbedTitle()
    {
        const string html = """
            <iframe src="https://www.youtube.com/embed/dQw4w9WgXcQ"></iframe>
            <a href="https://www.youtube.com/shorts/abcdefghijk">short</a>
            <iframe src="https://www.youtube.com/embed/dQw4w9WgXcQ?rel=0"></iframe>
            """;
        var candidates = await OfflineSniffer(youtubeTitle: id =>
            id == "dQw4w9WgXcQ" ? "Never Gonna Give You Up" : null)
            .ExtractCandidatesAsync(html, new Uri("https://blog.example.com/"));

        Assert.Equal(2, candidates.Count);  // 重复 id 去重
        Assert.Equal("https://www.youtube.com/watch?v=dQw4w9WgXcQ", candidates[0].Url);
        Assert.Equal("Never Gonna Give You Up", candidates[0].Title);
        Assert.Equal(VideoCandidate.CandidateKind.Youtube, candidates[0].Kind);
        Assert.Equal("https://www.youtube.com/watch?v=abcdefghijk", candidates[1].Url);
        Assert.Equal("YouTube 视频 abcdefghijk", candidates[1].Title);  // oEmbed 失败用占位名
    }

    [Fact]
    public void YoutubeIdRegex_Boundary()
    {
        Assert.Equal("dQw4w9WgXcQ", PageSniffer.YoutubeId("https://youtu.be/dQw4w9WgXcQ"));
        Assert.Equal("dQw4w9WgXcQ", PageSniffer.YoutubeId("https://www.youtube.com/watch?t=1&v=dQw4w9WgXcQ"));
        Assert.Equal("dQw4w9WgXcQ", PageSniffer.YoutubeId("https://www.youtube.com/live/dQw4w9WgXcQ"));
        // 12 个合法字符：11 位后还跟 id 字符 → 不匹配（负向断言）
        Assert.Null(PageSniffer.YoutubeId("https://youtu.be/dQw4w9WgXcQx"));
        Assert.Null(PageSniffer.YoutubeId("https://example.com/v/dQw4w9WgXcQ"));
    }

    /// <summary>JSON 转义的直链（https:\/\/…\/a.mp4）反转义后归类。</summary>
    [Fact]
    public async Task JsonEscapedDirectUrl_Unescaped()
    {
        const string html = """
            <script>var player = {"video":{"url":"https:\/\/cdn.example.com\/clip\/intro.mp4"}};</script>
            """;
        var candidates = await OfflineSniffer().ExtractCandidatesAsync(
            html, new Uri("https://www.example.com/"));

        var candidate = Assert.Single(candidates);
        Assert.Equal("https://cdn.example.com/clip/intro.mp4", candidate.Url);
        Assert.Equal(VideoCandidate.CandidateKind.DirectFile, candidate.Kind);
    }

    [Fact]
    public async Task VideoSourceTag_RelativeUrl_ResolvedAgainstPage()
    {
        const string html = """<video><source src="/media/clip.webm"></video>""";
        var candidates = await OfflineSniffer().ExtractCandidatesAsync(
            html, new Uri("https://www.example.com/articles/1"));
        var candidate = Assert.Single(candidates);
        Assert.Equal("https://www.example.com/media/clip.webm", candidate.Url);
    }

    [Fact]
    public async Task DataAndJavascriptUrls_Skipped()
    {
        const string html = """
            <video src="data:video/mp4;base64,AAAA"></video>
            <video src="javascript:void(0)"></video>
            """;
        var candidates = await OfflineSniffer().ExtractCandidatesAsync(
            html, new Uri("https://www.example.com/"));
        Assert.Empty(candidates);
    }

    /// <summary>排序：任天堂主视频 rank 0 &lt; 直链 rank 1 &lt; YouTube rank 2。</summary>
    [Fact]
    public async Task Ordering_PageMainFirst_ThenDirect_ThenEmbeds()
    {
        const string html = """
            <iframe src="https://www.youtube.com/embed/dQw4w9WgXcQ"></iframe>
            <meta property="og:video" content="https://cdn.example.com/main.mp4">
            <div data-videoid="/zelda/trailer"></div>
            """;
        var candidates = await OfflineSniffer().ExtractCandidatesAsync(
            html, new Uri("https://www.nintendo.com/page"));

        Assert.Equal(3, candidates.Count);
        Assert.Equal(VideoCandidate.CandidateKind.PageMain, candidates[0].Kind);
        Assert.Equal(VideoCandidate.CandidateKind.DirectFile, candidates[1].Kind);
        Assert.Equal(VideoCandidate.CandidateKind.Youtube, candidates[2].Kind);
    }

    [Fact]
    public void PageTitle_StripsSiteNameSuffix()
    {
        Assert.Equal("My Video", PageSniffer.PageTitle("<title>My Video | SiteName</title>"));
        Assert.Equal("A &amp; B", PageSniffer.PageTitle("<title>A &amp;amp; B</title>"));  // 实体解码一次
        Assert.Null(PageSniffer.PageTitle("<body>no title</body>"));
    }

    [Fact]
    public void VimeoId_Extraction()
    {
        Assert.Equal("12345", PageSniffer.VimeoId("https://player.vimeo.com/video/12345?h=x"));
        Assert.Null(PageSniffer.VimeoId("https://vimeo.com/12345"));
    }
}
