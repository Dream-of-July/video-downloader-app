using System.IO.Compression;

namespace Vdl.Core;

/// <summary>一项待下载的依赖。Kind=Zip 时按 ZipEntries 提取（entry 后缀 → 目标文件名）。</summary>
public sealed record DependencyDownload
{
    public enum DownloadKind { Executable, Zip }

    /// <summary>展示名（如 "yt-dlp"）。</summary>
    public required string Name { get; init; }
    public required string Url { get; init; }
    public required DownloadKind Kind { get; init; }
    /// <summary>提供的目标文件名（bin 目录下）。</summary>
    public required IReadOnlyList<string> ProvidesFiles { get; init; }
    /// <summary>Zip 内 entry 路径后缀 → 目标文件名；Executable 时为空。</summary>
    public IReadOnlyDictionary<string, string> ZipEntries { get; init; } =
        new Dictionary<string, string>();
}

/// <summary>
/// 依赖管理：检查 %LOCALAPPDATA%\VideoDownloader\bin 下的 yt-dlp.exe / ffmpeg.exe /
/// ffprobe.exe / deno.exe，缺哪个下哪个。下载到 .tmp 再原子改名，避免半截文件被当成可用。
/// deno 是 yt-dlp 解 YouTube n-challenge 所需的 JS 运行时。
/// </summary>
public sealed class DependencyManager
{
    private const string YtDlpUrl =
        "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe";
    private const string FfmpegZipUrl =
        "https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip";
    private const string DenoZipUrl =
        "https://github.com/denoland/deno/releases/latest/download/deno-x86_64-pc-windows-msvc.zip";

    private readonly string _binDirectory;
    private readonly HttpClient _client;

    public DependencyManager(string? binDirectory = null, HttpMessageHandler? handler = null)
    {
        _binDirectory = binDirectory ?? BinaryLocator.BinDirectory;
        _client = handler is null
            ? new HttpClient() { Timeout = TimeSpan.FromMinutes(10) }
            : new HttpClient(handler, disposeHandler: false) { Timeout = TimeSpan.FromMinutes(10) };
    }

    /// <summary>受管的全部依赖（Windows 文件名）。</summary>
    internal static readonly string[] RequiredFiles = ["yt-dlp.exe", "ffmpeg.exe", "ffprobe.exe", "deno.exe"];

    /// <summary>检查 bin 目录，返回缺失依赖的下载计划（缺什么下什么）。</summary>
    public IReadOnlyList<DependencyDownload> PlanMissing() => PlanMissing(_binDirectory);

    internal static List<DependencyDownload> PlanMissing(string binDirectory)
    {
        bool Missing(string file) => !File.Exists(Path.Combine(binDirectory, file));

        var plans = new List<DependencyDownload>();
        if (Missing("yt-dlp.exe"))
        {
            plans.Add(new DependencyDownload
            {
                Name = "yt-dlp",
                Url = YtDlpUrl,
                Kind = DependencyDownload.DownloadKind.Executable,
                ProvidesFiles = ["yt-dlp.exe"],
            });
        }
        // ffmpeg 与 ffprobe 同包：任一缺失都重新下 zip（两个一起提取）。
        if (Missing("ffmpeg.exe") || Missing("ffprobe.exe"))
        {
            plans.Add(new DependencyDownload
            {
                Name = "ffmpeg",
                Url = FfmpegZipUrl,
                Kind = DependencyDownload.DownloadKind.Zip,
                ProvidesFiles = ["ffmpeg.exe", "ffprobe.exe"],
                ZipEntries = new Dictionary<string, string>
                {
                    ["bin/ffmpeg.exe"] = "ffmpeg.exe",
                    ["bin/ffprobe.exe"] = "ffprobe.exe",
                },
            });
        }
        if (Missing("deno.exe"))
        {
            plans.Add(new DependencyDownload
            {
                Name = "deno",
                Url = DenoZipUrl,
                Kind = DependencyDownload.DownloadKind.Zip,
                ProvidesFiles = ["deno.exe"],
                ZipEntries = new Dictionary<string, string> { ["deno.exe"] = "deno.exe" },
            });
        }
        return plans;
    }

    /// <summary>确保所有依赖就位：缺失的逐个下载安装。progress 上报人话进度文案。</summary>
    public async Task EnsureAsync(IProgress<string>? progress = null, CancellationToken ct = default)
    {
        var plans = PlanMissing(_binDirectory);
        if (plans.Count == 0) return;
        Directory.CreateDirectory(_binDirectory);
        foreach (var plan in plans)
        {
            ct.ThrowIfCancellationRequested();
            progress?.Report(L10n.T($"正在下载 {plan.Name}…", $"Downloading {plan.Name}…"));
            await DownloadAndInstallAsync(plan, ct).ConfigureAwait(false);
        }
        progress?.Report(L10n.T("依赖组件已就绪", "All components are ready"));
    }

    /// <summary>单独更新 yt-dlp（站点规则频繁变化，提供手动更新入口）。</summary>
    public async Task UpdateYtDlpAsync(IProgress<string>? progress = null, CancellationToken ct = default)
    {
        Directory.CreateDirectory(_binDirectory);
        progress?.Report(L10n.T("正在下载 yt-dlp…", "Downloading yt-dlp…"));
        await DownloadAndInstallAsync(new DependencyDownload
        {
            Name = "yt-dlp",
            Url = YtDlpUrl,
            Kind = DependencyDownload.DownloadKind.Executable,
            ProvidesFiles = ["yt-dlp.exe"],
        }, ct).ConfigureAwait(false);
        progress?.Report(L10n.T("yt-dlp 已更新", "yt-dlp updated"));
    }

    private async Task DownloadAndInstallAsync(DependencyDownload plan, CancellationToken ct)
    {
        // 先全部下到 .tmp，校验/提取成功后原子改名，失败不留半截产物。
        var tempPath = Path.Combine(_binDirectory, $"{plan.Name}-{Guid.NewGuid():N}.tmp");
        try
        {
            using (var response = await _client.GetAsync(
                plan.Url, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false))
            {
                response.EnsureSuccessStatusCode();
                await using var fileStream = File.Create(tempPath);
                await response.Content.CopyToAsync(fileStream, ct).ConfigureAwait(false);
            }

            if (plan.Kind == DependencyDownload.DownloadKind.Executable)
            {
                var target = Path.Combine(_binDirectory, plan.ProvidesFiles[0]);
                File.Move(tempPath, target, overwrite: true);
            }
            else
            {
                await using var zipStream = File.OpenRead(tempPath);
                ExtractZipEntries(zipStream, plan.ZipEntries, _binDirectory);
                File.Delete(tempPath);
            }
        }
        catch
        {
            try { File.Delete(tempPath); } catch { /* 忽略 */ }
            throw;
        }
    }

    /// <summary>
    /// 从 zip 流中按 entry 路径后缀提取目标文件到 binDirectory（提取到 .tmp 后原子改名）。
    /// BtbN 的 ffmpeg zip 顶层有版本号目录，所以按后缀匹配 "bin/ffmpeg.exe" 而非全路径。
    /// </summary>
    internal static void ExtractZipEntries(
        Stream zipStream, IReadOnlyDictionary<string, string> entrySuffixToTarget, string binDirectory)
    {
        using var archive = new ZipArchive(zipStream, ZipArchiveMode.Read, leaveOpen: true);
        var remaining = new Dictionary<string, string>(entrySuffixToTarget);
        foreach (var entry in archive.Entries)
        {
            if (entry.FullName.EndsWith('/')) continue;
            var normalized = entry.FullName.Replace('\\', '/');
            var hit = remaining.FirstOrDefault(pair =>
                normalized.EndsWith(pair.Key, StringComparison.OrdinalIgnoreCase));
            if (hit.Key is null) continue;
            remaining.Remove(hit.Key);

            var target = Path.Combine(binDirectory, hit.Value);
            var temp = target + $".extract-{Guid.NewGuid():N}.tmp";
            try
            {
                using (var entryStream = entry.Open())
                using (var output = File.Create(temp))
                {
                    entryStream.CopyTo(output);
                }
                File.Move(temp, target, overwrite: true);
            }
            catch
            {
                try { File.Delete(temp); } catch { /* 忽略 */ }
                throw;
            }
            if (remaining.Count == 0) break;
        }
        if (remaining.Count > 0)
        {
            throw new InvalidDataException(L10n.T(
                $"压缩包里缺少预期文件：{string.Join(", ", remaining.Keys)}",
                $"The archive is missing expected files: {string.Join(", ", remaining.Keys)}"));
        }
    }
}
