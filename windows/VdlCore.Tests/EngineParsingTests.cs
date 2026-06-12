using System.Text.Json;
using Vdl.Core;

namespace VdlCore.Tests;

public class OutputTemplateTests
{
    private const string Fallback = "%(title).180B [%(id)s].%(ext)s";

    [Fact]
    public void NullTitle_UsesDefaultTemplate() =>
        Assert.Equal(Fallback, YtDlpEngine.OutputTemplate(null));

    [Fact]
    public void PercentEscaped()
    {
        Assert.Equal("100%% Done [%(id)s].%(ext)s", YtDlpEngine.OutputTemplate("100% Done"));
    }

    [Fact]
    public void PathSeparatorsAndNewlinesBecomeSpaces()
    {
        Assert.Equal("a b c d [%(id)s].%(ext)s", YtDlpEngine.OutputTemplate("a/b\\c:d"));
        Assert.Equal("line1 line2 [%(id)s].%(ext)s", YtDlpEngine.OutputTemplate("line1\nline2"));
    }

    [Fact]
    public void LongTitle_TruncatedTo120Chars()
    {
        var title = new string('x', 150);
        var template = YtDlpEngine.OutputTemplate(title);
        Assert.Equal(new string('x', 120) + " [%(id)s].%(ext)s", template);
    }

    [Fact]
    public void TitleReducedToEmpty_FallsBack()
    {
        Assert.Equal(Fallback, YtDlpEngine.OutputTemplate("///"));
        Assert.Equal(Fallback, YtDlpEngine.OutputTemplate("   "));
    }
}

public class ProgressLineTests
{
    [Fact]
    public void VdlpLine_ParsesPercentSpeedEta()
    {
        var progress = YtDlpEngine.ParseProgressLine("VDLP|  12.5%|  1.2MiB/s|00:45");
        Assert.NotNull(progress);
        Assert.Equal(DownloadProgress.ProgressPhase.Downloading, progress.Phase);
        Assert.Equal(12.5, progress.Percent);
        Assert.Equal("1.2MiB/s", progress.SpeedText);
        Assert.Equal("00:45", progress.EtaText);
    }

    [Fact]
    public void VdlpLine_UnknownFields_BecomeNull()
    {
        var progress = YtDlpEngine.ParseProgressLine("VDLP| N/A | N/A |Unknown");
        Assert.NotNull(progress);
        Assert.Null(progress.Percent);
        Assert.Null(progress.SpeedText);
        Assert.Null(progress.EtaText);
    }

    [Fact]
    public void VdlpLine_PercentClampedTo100()
    {
        var progress = YtDlpEngine.ParseProgressLine("VDLP|105.0%|x|y");
        Assert.Equal(100, progress!.Percent);
    }

    [Fact]
    public void PostprocessPrefixes_MapToProcessing()
    {
        foreach (var line in new[]
        {
            "[Merger] Merging formats into \"a.mp4\"",
            "[ExtractAudio] Destination: a.m4a",
            "[SubtitleConvertor] Converting subtitles",
            "[FixupM4a] Correcting container",
        })
        {
            var progress = YtDlpEngine.ParseProgressLine(line);
            Assert.NotNull(progress);
            Assert.Equal(DownloadProgress.ProgressPhase.Processing, progress.Phase);
        }
    }

    [Fact]
    public void OtherLines_ReturnNull() =>
        Assert.Null(YtDlpEngine.ParseProgressLine("[download] Destination: a.mp4"));
}

public class HlsSubtitleParsingTests
{
    [Fact]
    public void ParsesSubtitleMediaLines_ResolvesRelativeUris()
    {
        const string master = """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",LANGUAGE="en",URI="audio/en.m3u8"
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",DEFAULT=YES,LANGUAGE="en",URI="subtitles/eng/prog_index.m3u8"
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="简体中文",LANGUAGE="zh-Hans",URI="https://cdn.example.com/subs/zh.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=1000000,SUBTITLES="subs"
            video/1080p.m3u8
            """;
        var baseUrl = new Uri("https://events.example.com/wwdc/master.m3u8");
        var entries = YtDlpEngine.ParseHlsSubtitleEntries(master, baseUrl);

        Assert.Equal(2, entries.Count);
        Assert.Equal("en", entries[0].Lang);
        Assert.Equal("English", entries[0].Name);
        Assert.Equal("https://events.example.com/wwdc/subtitles/eng/prog_index.m3u8", entries[0].Url);
        Assert.Equal("zh-Hans", entries[1].Lang);
        Assert.Equal("https://cdn.example.com/subs/zh.m3u8", entries[1].Url);
    }

    [Fact]
    public void MissingLanguageOrUri_Skipped()
    {
        const string master = """
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="NoLang",URI="x.m3u8"
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="NoUri",LANGUAGE="ja"
            """;
        var entries = YtDlpEngine.ParseHlsSubtitleEntries(master, new Uri("https://a.com/m.m3u8"));
        Assert.Empty(entries);
    }

    [Fact]
    public void UnquotedAttribute_Parsed()
    {
        Assert.Equal("subs", YtDlpEngine.HlsAttribute("GROUP-ID", "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=subs,LANGUAGE=\"en\""));
        Assert.Equal("en", YtDlpEngine.HlsAttribute("LANGUAGE", "#EXT-X-MEDIA:LANGUAGE=\"en\",URI=\"a\""));
    }
}

public class DetectLoginRequiredTests
{
    private const string YoutubeUrl = "https://www.youtube.com/watch?v=abc";

    [Fact]
    public void SignInToConfirm_NoCookies_LoginRequired()
    {
        var error = YtDlpEngine.DetectLoginRequired(
            "ERROR: Sign in to confirm you're not a bot", YoutubeUrl, hasCookies: false);
        Assert.NotNull(error);
        Assert.Equal(VdlErrorKind.LoginRequired, error.Kind);
        Assert.Equal("youtube.com", error.Detail);
    }

    [Fact]
    public void SignInToConfirm_WithCookies_SuggestsRelogin()
    {
        var error = YtDlpEngine.DetectLoginRequired(
            "ERROR: Sign in to confirm you're not a bot", YoutubeUrl, hasCookies: true);
        Assert.NotNull(error);
        Assert.Equal(VdlErrorKind.DownloadFailed, error.Kind);
        Assert.Contains("登录信息可能已过期", error.Detail);
    }

    [Fact]
    public void Youtube403InLastErrorLine_NoCookies_LoginRequired()
    {
        var error = YtDlpEngine.DetectLoginRequired(
            "WARNING: something\nERROR: unable to download video data: HTTP Error 403: Forbidden",
            YoutubeUrl, hasCookies: false);
        Assert.NotNull(error);
        Assert.Equal(VdlErrorKind.LoginRequired, error.Kind);
    }

    [Fact]
    public void Youtube403_WithCookies_SuggestsRelogin()
    {
        var error = YtDlpEngine.DetectLoginRequired(
            "ERROR: HTTP Error 403: Forbidden", YoutubeUrl, hasCookies: true);
        Assert.NotNull(error);
        Assert.Equal(VdlErrorKind.DownloadFailed, error.Kind);
        Assert.Contains("403", error.Detail);
    }

    /// <summary>只看最后一条 ERROR 行：中间分片的瞬时 403 不触发登录判定。</summary>
    [Fact]
    public void Youtube403OnlyInMiddleErrorLine_NotLogin()
    {
        var error = YtDlpEngine.DetectLoginRequired(
            "ERROR: fragment 3: HTTP Error 403: Forbidden\nERROR: unable to continue without fragment",
            YoutubeUrl, hasCookies: false);
        Assert.Null(error);
    }

    [Fact]
    public void NonYoutube403_NotLogin()
    {
        var error = YtDlpEngine.DetectLoginRequired(
            "ERROR: HTTP Error 403: Forbidden", "https://example.com/v.mp4", hasCookies: false);
        Assert.Null(error);
    }

    [Fact]
    public void MembersOnlyPattern_LoginRequiredWithSite()
    {
        var error = YtDlpEngine.DetectLoginRequired(
            "ERROR: This video is members-only content", "https://www.example.com/v", hasCookies: false);
        Assert.NotNull(error);
        Assert.Equal(VdlErrorKind.LoginRequired, error.Kind);
        Assert.Equal("example.com", error.Detail);  // www. 前缀剥掉
    }

    [Fact]
    public void ChinesePattern_Bilibili_LoginRequired()
    {
        var error = YtDlpEngine.DetectLoginRequired(
            "ERROR: 大会员专享，请登录后重试", "https://www.bilibili.com/video/BV1x", hasCookies: false);
        Assert.NotNull(error);
        Assert.Equal(VdlErrorKind.LoginRequired, error.Kind);
        Assert.Equal("bilibili.com", error.Detail);
    }

    [Fact]
    public void InvalidUrl_EmptyHost_FallbackSiteName()
    {
        var error = YtDlpEngine.DetectLoginRequired("ERROR: login required", "not a url", hasCookies: false);
        Assert.NotNull(error);
        Assert.Equal("该站点", error.Detail);
    }
}

public class StderrSummaryTests
{
    [Fact]
    public void SummarizeStderr_PrefersLastErrorLine()
    {
        var summary = YtDlpEngine.SummarizeStderr(
            "WARNING: a\nERROR: first\nWARNING: b\nERROR: second problem\nINFO: tail");
        Assert.Equal("ERROR: second problem", summary);
    }

    [Fact]
    public void SummarizeStderr_FallsBackToLastLineOrUnknown()
    {
        Assert.Equal("plain tail", YtDlpEngine.SummarizeStderr("first\nplain tail\n"));
        Assert.Equal("未知错误", YtDlpEngine.SummarizeStderr("  \n  "));
    }

    [Fact]
    public void FriendlyDownloadReason_403GetsAntiLeechHint()
    {
        var reason = YtDlpEngine.FriendlyDownloadReason("ERROR: HTTP Error 403: Forbidden");
        Assert.StartsWith("资源拒绝访问（403）", reason);
        Assert.Contains("ERROR: HTTP Error 403: Forbidden", reason);
    }

    [Fact]
    public void FriendlyAnalyzeMessage_FormatNotAvailable_GetsRetryHint()
    {
        var message = YtDlpEngine.FriendlyAnalyzeMessage("ERROR: Requested format is not available");
        Assert.Contains("临时风控", message);
    }
}

public class BuildVideoInfoTests
{
    private static JsonElement ParseJson(string json)
    {
        using var doc = JsonDocument.Parse(json);
        return doc.RootElement.Clone();
    }

    /// <summary>测试替身：屏蔽网络/子进程钩子。</summary>
    private sealed class OfflineEngine : YtDlpEngine
    {
        protected override Task<string?> FetchTextAsync(Uri url, CancellationToken ct) =>
            Task.FromResult<string?>(null);
        protected override Task<ProbeInfo?> RunFfProbeAsync(string urlString, CancellationToken ct) =>
            Task.FromResult<ProbeInfo?>(null);
        protected override Task<double?> HeadContentLengthAsync(string urlString, CancellationToken ct) =>
            Task.FromResult<double?>(null);
    }

    [Fact]
    public async Task FormatTiers_SortedDescending_TopUsesWildcard()
    {
        var json = ParseJson("""
            {
              "id": "abc123",
              "title": "Test Video",
              "duration": 151,
              "uploader": "Someone",
              "language": "fr",
              "formats": [
                {"format_id":"137","vcodec":"avc1","acodec":"none","height":1080,"tbr":4000,"filesize":104857600},
                {"format_id":"136","vcodec":"avc1","acodec":"none","height":720,"tbr":2000,"filesize_approx":52428800},
                {"format_id":"140","vcodec":"none","acodec":"mp4a","abr":128,"filesize":10485760}
              ],
              "subtitles": {"en": [{}], "live_chat": [{}]},
              "automatic_captions": {"en": [{}], "ja": [{}], "fr": [{}], "xx": [{}]}
            }
            """);
        var info = await new OfflineEngine().BuildVideoInfoAsync("https://www.youtube.com/watch?v=abc123", json);

        Assert.Equal("abc123", info.VideoId);
        Assert.Equal("Test Video", info.Title);
        Assert.Equal("2:31", info.DurationText);
        Assert.Equal("Someone", info.Uploader);

        // 1080p 推荐档（通配串）、720p 限高档、末尾音频档
        Assert.Equal(3, info.Formats.Count);
        Assert.Equal("bv*+ba/b", info.Formats[0].Id);
        Assert.Equal("1080p · mp4", info.Formats[0].Label);
        Assert.Equal("≈ 110 MB", info.Formats[0].Detail);  // 100MB 视频 + 10MB 最佳音轨
        Assert.Equal("bv*[height<=720]+ba/b[height<=720]", info.Formats[1].Id);
        Assert.Equal("≈ 60 MB", info.Formats[1].Detail);
        Assert.True(info.Formats[^1].IsAudioOnly);
        Assert.Equal("audio", info.Formats[^1].Id);

        // 字幕：真实 en（live_chat 剔除）在前；自动字幕滤白名单+视频语言（fr），en 因重复剔除
        Assert.Equal(3, info.Subtitles.Count);
        Assert.Equal("en", info.Subtitles[0].Id);
        Assert.False(info.Subtitles[0].IsAuto);
        Assert.Equal("ja", info.Subtitles[1].Id);  // 白名单 ja 排自动字幕首位（rank 2 < fr rank 3）
        Assert.True(info.Subtitles[1].IsAuto);
        Assert.Equal("fr", info.Subtitles[2].Id);  // 视频语言前缀命中
        Assert.True(info.Subtitles[2].IsAuto);
    }

    [Fact]
    public async Task DirectFile_SingleBestFormat()
    {
        var json = ParseJson("""
            {
              "id": "trailer",
              "title": "homepage_trailer",
              "ext": "mp4",
              "url": "https://cdn.example.com/trailer.mp4",
              "formats": [{"format_id":"0","url":"https://cdn.example.com/trailer.mp4","filesize":31457280}]
            }
            """);
        var info = await new OfflineEngine().BuildVideoInfoAsync("https://cdn.example.com/trailer.mp4", json);

        Assert.Equal(2, info.Formats.Count);
        Assert.Equal("best", info.Formats[0].Id);
        Assert.Equal("原始文件 · mp4", info.Formats[0].Label);
        Assert.Equal("≈ 30 MB", info.Formats[0].Detail);
        Assert.True(info.Formats[1].IsAudioOnly);
        Assert.Empty(info.Subtitles);
    }

    [Fact]
    public void SubtitleSortKey_ChineseFirstThenEnglishJapanese()
    {
        var codes = new[] { "fr", "ja", "en", "zh-Hans", "en-orig", "zh" };
        var sorted = codes
            .OrderBy(c => YtDlpEngine.SubtitleSortKey(c).Rank)
            .ThenBy(c => YtDlpEngine.SubtitleSortKey(c).Lower, StringComparer.Ordinal)
            .ToArray();
        Assert.Equal(new[] { "zh", "zh-Hans", "en", "en-orig", "ja", "fr" }, sorted);
    }

    [Fact]
    public void FormatDurationAndSizeText()
    {
        Assert.Equal("2:31", YtDlpEngine.FormatDuration(151));
        Assert.Equal("1:00:05", YtDlpEngine.FormatDuration(3605));
        Assert.Equal("≈ 1 MB", YtDlpEngine.SizeText(100));  // 不足 1MB 取下限 1
        Assert.Equal("≈ 30 MB", YtDlpEngine.SizeText(31457280));
    }

    [Fact]
    public void IsYouTubeHost_Boundaries()
    {
        Assert.True(YtDlpEngine.IsYouTubeHost("youtu.be"));
        Assert.True(YtDlpEngine.IsYouTubeHost("www.youtube.com"));
        Assert.True(YtDlpEngine.IsYouTubeHost("youtube-nocookie.com"));
        Assert.False(YtDlpEngine.IsYouTubeHost("notyoutube.com"));
        Assert.False(YtDlpEngine.IsYouTubeHost("youtube.com.evil.com"));
    }

    [Fact]
    public void LangCodeOfSubtitle_ParsesFromFileName()
    {
        Assert.Equal("en", YtDlpEngine.LangCodeOfSubtitle("/tmp/Video [abc].en.srt"));
        Assert.Equal("zh-hans", YtDlpEngine.LangCodeOfSubtitle("/tmp/Video [abc].zh-Hans.srt"));
        Assert.Null(YtDlpEngine.LangCodeOfSubtitle("/tmp/video.srt"));
    }
}
