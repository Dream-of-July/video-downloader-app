using System.IO.Compression;
using System.Text;
using Vdl.Core;

namespace VdlCore.Tests;

public class DependencyPlanTests : IDisposable
{
    private readonly string _binDir;

    public DependencyPlanTests()
    {
        _binDir = Path.Combine(Path.GetTempPath(), $"vdl-bin-{Guid.NewGuid():N}");
        Directory.CreateDirectory(_binDir);
    }

    public void Dispose()
    {
        try { Directory.Delete(_binDir, true); } catch { /* 忽略 */ }
    }

    private void Touch(string fileName) =>
        File.WriteAllText(Path.Combine(_binDir, fileName), "stub");

    [Fact]
    public void EmptyDirectory_PlansAllThreeDownloads()
    {
        var plans = DependencyManager.PlanMissing(_binDir);
        Assert.Equal(3, plans.Count);
        Assert.Equal(new[] { "yt-dlp", "ffmpeg", "deno" }, plans.Select(p => p.Name).ToArray());

        var ytdlp = plans[0];
        Assert.Equal(DependencyDownload.DownloadKind.Executable, ytdlp.Kind);
        Assert.Equal("https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe", ytdlp.Url);

        var ffmpeg = plans[1];
        Assert.Equal(DependencyDownload.DownloadKind.Zip, ffmpeg.Kind);
        Assert.Contains("BtbN/FFmpeg-Builds", ffmpeg.Url);
        Assert.Equal(2, ffmpeg.ZipEntries.Count);
        Assert.Equal("ffmpeg.exe", ffmpeg.ZipEntries["bin/ffmpeg.exe"]);
        Assert.Equal("ffprobe.exe", ffmpeg.ZipEntries["bin/ffprobe.exe"]);

        var deno = plans[2];
        Assert.Equal(DependencyDownload.DownloadKind.Zip, deno.Kind);
        Assert.Contains("denoland/deno", deno.Url);
    }

    [Fact]
    public void AllPresent_NoPlans()
    {
        foreach (var file in new[] { "yt-dlp.exe", "ffmpeg.exe", "ffprobe.exe", "deno.exe" })
        {
            Touch(file);
        }
        Assert.Empty(DependencyManager.PlanMissing(_binDir));
    }

    /// <summary>ffmpeg/ffprobe 同包：任一缺失都重下整个 zip。</summary>
    [Fact]
    public void FfprobeMissing_PlansFfmpegZip()
    {
        Touch("yt-dlp.exe");
        Touch("ffmpeg.exe");
        Touch("deno.exe");
        var plans = DependencyManager.PlanMissing(_binDir);
        var plan = Assert.Single(plans);
        Assert.Equal("ffmpeg", plan.Name);
    }

    [Fact]
    public void OnlyYtDlpMissing_PlansSingleExecutable()
    {
        Touch("ffmpeg.exe");
        Touch("ffprobe.exe");
        Touch("deno.exe");
        var plans = DependencyManager.PlanMissing(_binDir);
        var plan = Assert.Single(plans);
        Assert.Equal("yt-dlp", plan.Name);
        Assert.Equal(DependencyDownload.DownloadKind.Executable, plan.Kind);
    }
}

public class ZipExtractionTests : IDisposable
{
    private readonly string _binDir;

    public ZipExtractionTests()
    {
        _binDir = Path.Combine(Path.GetTempPath(), $"vdl-zip-{Guid.NewGuid():N}");
        Directory.CreateDirectory(_binDir);
    }

    public void Dispose()
    {
        try { Directory.Delete(_binDir, true); } catch { /* 忽略 */ }
    }

    private static MemoryStream BuildZip(params (string EntryName, string Content)[] entries)
    {
        var stream = new MemoryStream();
        using (var archive = new ZipArchive(stream, ZipArchiveMode.Create, leaveOpen: true))
        {
            foreach (var (name, content) in entries)
            {
                var entry = archive.CreateEntry(name);
                using var writer = new StreamWriter(entry.Open(), Encoding.UTF8);
                writer.Write(content);
            }
        }
        stream.Position = 0;
        return stream;
    }

    /// <summary>BtbN zip 顶层带版本号目录：按 entry 后缀匹配提取。</summary>
    [Fact]
    public void ExtractsBySuffix_IntoBinDirectory()
    {
        using var zip = BuildZip(
            ("ffmpeg-master-latest-win64-gpl/README.txt", "readme"),
            ("ffmpeg-master-latest-win64-gpl/bin/ffmpeg.exe", "FFMPEG_BINARY"),
            ("ffmpeg-master-latest-win64-gpl/bin/ffprobe.exe", "FFPROBE_BINARY"));

        DependencyManager.ExtractZipEntries(zip, new Dictionary<string, string>
        {
            ["bin/ffmpeg.exe"] = "ffmpeg.exe",
            ["bin/ffprobe.exe"] = "ffprobe.exe",
        }, _binDir);

        Assert.Equal("FFMPEG_BINARY", File.ReadAllText(Path.Combine(_binDir, "ffmpeg.exe")));
        Assert.Equal("FFPROBE_BINARY", File.ReadAllText(Path.Combine(_binDir, "ffprobe.exe")));
        // 不提取无关条目，也不残留临时文件
        Assert.Equal(2, Directory.GetFiles(_binDir).Length);
    }

    [Fact]
    public void TopLevelEntry_DenoStyle_Extracted()
    {
        using var zip = BuildZip(("deno.exe", "DENO_BINARY"));
        DependencyManager.ExtractZipEntries(zip, new Dictionary<string, string>
        {
            ["deno.exe"] = "deno.exe",
        }, _binDir);
        Assert.Equal("DENO_BINARY", File.ReadAllText(Path.Combine(_binDir, "deno.exe")));
    }

    [Fact]
    public void MissingExpectedEntry_Throws()
    {
        using var zip = BuildZip(("readme.txt", "x"));
        Assert.Throws<InvalidDataException>(() =>
            DependencyManager.ExtractZipEntries(zip, new Dictionary<string, string>
            {
                ["bin/ffmpeg.exe"] = "ffmpeg.exe",
            }, _binDir));
    }
}
