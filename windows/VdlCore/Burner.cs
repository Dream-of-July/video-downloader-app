using System.Globalization;
using System.Text.Json;

namespace Vdl.Core;

/// <summary>
/// ffmpeg subtitles 滤镜硬烧录中文字幕：libx264 + CRF 恒定质量（体积不超源），
/// 可选 scale 缩放到 maxHeight（避开 4K60 的 H.264 编码上限、又快又小）。
/// </summary>
public sealed class FFmpegBurner : ISubtitleBurner
{
    /// <summary>Windows 平台中文字体名（官方 ffmpeg full 构建自带 libass，按系统字体名渲染）。</summary>
    public const string WindowsFontName = "Microsoft YaHei";

    /// <summary>平台中文字体：Windows 微软雅黑；非 Windows（开发机）退回苹方。</summary>
    internal static string ChineseFontName => OperatingSystem.IsWindows() ? WindowsFontName : "PingFang SC";

    private static string? Locate(string name)
    {
        if (name == "ffmpeg"
            && Environment.GetEnvironmentVariable("VDL_BURN_FFMPEG_PATH") is { Length: > 0 } custom
            && File.Exists(custom))
        {
            return custom;
        }
        return BinaryLocator.Locate(name);
    }

    public async Task<string> BurnAsync(
        string video,
        string subtitle,
        int? maxHeight,
        TaskControlToken? control,
        Action<double> progress,
        string? outputTag = null,
        CancellationToken ct = default)
    {
        var ffmpeg = Locate("ffmpeg") ?? throw VdlException.BinaryNotFound("ffmpeg");
        if (control?.IsCancelled == true) throw VdlException.Cancelled();

        // 1. ffprobe 取时长、整体码率与源尺寸（取不到不阻塞烧录，只影响进度与缩放/码率）
        var probe = await ProbeAsync(video, ct).ConfigureAwait(false);

        // 「最大 1080p」语义按短边算：横屏限高、竖屏限宽。
        // 旧规则只看高度，竖屏 1080×1920 会被压成 608×1080（短边掉到 608）。
        var isPortrait = probe is { Width: { } pw, Height: { } ph } && pw < ph;
        var sourceShortSide = ShortSide(probe.Width, probe.Height);
        // 缩放目标：maxHeight 非空且源短边更大时把短边缩到 maxHeight，否则保持源。
        int? targetShortSide = maxHeight is { } mh && mh > 0 && sourceShortSide is { } shortSide && shortSide > mh
            ? mh
            : null;
        // -maxrate 上限：缩放后按目标档位推算；不缩放时取源整体码率，缺失再按源档位推算。
        // 档位维度同样用短边（竖屏 1080×1920 是 1080p 档，不是 4K 档）。
        var maxrateK = MaxrateK(probe.BitRateBps, sourceShortSide, targetShortSide);

        // 2. 临时目录：字幕转成 subs.ass 并把 ffmpeg 工作目录设到这里，
        //    规避 subtitles 滤镜对路径里冒号/引号/中文的转义问题。
        //    用 ASS 而非 SRT 是为了双语两种字号：中文（首行）正常字号，原文（次行）更小。
        var tempDir = Path.Combine(Path.GetTempPath(), $"vdl-burn-{Guid.NewGuid():N}");
        // 缩放滤镜：-2 让另一边自动按比例取偶数，避免 H.264 要求偶数边长报错。
        // 横屏限高（scale=-2:H）、竖屏限宽（scale=W:-2）。
        var scaleFilter = ScaleFilter(isPortrait, targetShortSide);
        string filter;
        try
        {
            Directory.CreateDirectory(tempDir);
            var srtText = await File.ReadAllTextAsync(subtitle, ct).ConfigureAwait(false);
            var cues = SrtTools.ParseSrt(srtText);
            string subtitleFilter;
            if (cues.Count == 0)
            {
                // 解析不出来就按原样走 SRT + force_style 的老路
                File.Copy(subtitle, Path.Combine(tempDir, "subs.srt"));
                subtitleFilter = "subtitles=subs.srt:force_style="
                    + $"'FontName={ChineseFontName},FontSize=15,Outline=1,Shadow=0,MarginV=20'";
            }
            else
            {
                // 字幕坐标系/字号按视频长宽比自适应（缩放不改变比例，用源尺寸即可）
                var aspect = probe is { Width: { } w, Height: { } h } && w > 0 && h > 0
                    ? (double)w / h
                    : 16.0 / 9.0;
                var ass = MakeAss(cues, aspect);
                await File.WriteAllTextAsync(Path.Combine(tempDir, "subs.ass"), ass, ct).ConfigureAwait(false);
                subtitleFilter = "subtitles=subs.ass";
            }
            // 先缩放再烧字幕：字幕按目标分辨率渲染，清晰度与位置都正确。
            // 同一条 -vf filterchain 用逗号连接。
            filter = scaleFilter is not null ? scaleFilter + "," + subtitleFilter : subtitleFilter;
        }
        catch (VdlException)
        {
            TryRemoveDirectory(tempDir);
            throw;
        }
        catch (OperationCanceledException)
        {
            TryRemoveDirectory(tempDir);
            throw;
        }
        catch (Exception e)
        {
            TryRemoveDirectory(tempDir);
            throw VdlException.BurnFailed(L10n.T($"无法准备字幕临时文件：{e.Message}",
                $"Could not prepare subtitle temp files: {e.Message}"));
        }

        try
        {
            // 3. 滤镜与参数
            var head = new List<string> { "-y", "-i", video, "-vf", filter };
            List<string> Tail(IReadOnlyList<string> audio) =>
                [.. audio, "-movflags", "+faststart", "-nostats", "-progress", "pipe:1", "out.mp4"];
            string[] copyAudio = ["-c:a", "copy"];
            string[] aacAudio = ["-c:a", "aac", "-b:a", "192k"];
            // 质量优先、体积不超源：libx264 + CRF 恒定质量；-maxrate/-bufsize 给一个不低于源的
            // 上限封顶，避免高复杂度片段码率失控。
            string[] softwareVideo =
            [
                "-c:v", "libx264", "-crf", "20", "-preset", "medium",
                "-pix_fmt", "yuv420p",
                "-maxrate", $"{maxrateK}k", "-bufsize", $"{maxrateK * 2}k",
            ];

            // 4. 跑 ffmpeg，stdout 的 -progress 输出换算进度。
            //    onStart 登记 pid 到 control：暂停时挂起 ffmpeg 进程树。
            var totalSeconds = probe.Duration;
            async Task<(int Status, string StderrTail)> Run(List<string> arguments)
            {
                try
                {
                    return await ProcessRunner.RunStreamingProcessAsync(
                        ffmpeg, arguments,
                        currentDirectory: tempDir,
                        // ffmpeg 的 -progress 每约 0.5s 必有输出；2 分钟静默 = 真挂死。
                        stallTimeout: TimeSpan.FromSeconds(120),
                        isSuspended: () => control?.IsPaused ?? false,
                        onStart: pid =>
                        {
                            if (control?.IsCancelled == true)
                            {
                                // 启动瞬间已取消：立即终止进程树。
                                ProcessTree.KillTree(pid);
                            }
                            else
                            {
                                control?.SetActivePid(pid);
                            }
                        },
                        onLine: line =>
                        {
                            if (ParseProgress(line, totalSeconds) is { } fraction) progress(fraction);
                        },
                        ct: ct).ConfigureAwait(false);
                }
                catch (ProcessStalledException)
                {
                    throw VdlException.BurnFailed(L10n.T(
                        "烧录进程超过 2 分钟没有任何输出，疑似挂死，已自动中止（可重试）。",
                        "The encoder produced no output for 2 minutes and was stopped (you can retry)."));
                }
            }

            var (status, stderrTail) = await Run([.. head, .. softwareVideo, .. Tail(copyAudio)]).ConfigureAwait(false);
            control?.SetActivePid(0);

            // 5. 首跑失败 → 用 aac 音轨重试一次（音轨 copy 不进 mp4 容器是最常见原因，
            //    字符串匹配 ffmpeg 文案会随版本漂移，干脆除不可修复错误外都重试，代价小）。
            if (status != 0 && control?.IsCancelled != true)
            {
                var lower = stderrTail.ToLowerInvariant();
                var unfixable = lower.Contains("error parsing filterchain")
                    || lower.Contains("no such filter")
                    || lower.Contains("no such file");
                if (!unfixable)
                {
                    try { File.Delete(Path.Combine(tempDir, "out.mp4")); } catch { /* 忽略 */ }
                    (status, stderrTail) = await Run([.. head, .. softwareVideo, .. Tail(aacAudio)]).ConfigureAwait(false);
                    control?.SetActivePid(0);
                }
            }
            if (status != 0)
            {
                // 取消归一化：onStart 在取消时杀了进程树，ffmpeg 以非 0 退出，
                // 这里识别为取消（抛 Cancelled）而不是 BurnFailed，避免误报「烧录失败」。
                if (control?.IsCancelled == true) throw VdlException.Cancelled();
                var lower = stderrTail.ToLowerInvariant();
                if (lower.Contains("error parsing filterchain") || lower.Contains("no such filter"))
                {
                    throw VdlException.BurnFailed(L10n.T(
                        "当前 ffmpeg 不带字幕渲染组件（libass）。请在「设置」里重新下载完整版 ffmpeg 后重试。",
                        "This ffmpeg build lacks the subtitle renderer (libass). Re-download ffmpeg in Settings and retry."));
                }
                throw VdlException.BurnFailed(LastLine(stderrTail));
            }
            var produced = Path.Combine(tempDir, "out.mp4");
            if (!File.Exists(produced))
            {
                throw VdlException.BurnFailed(L10n.T("ffmpeg 已退出，但没有生成输出文件。",
                    "ffmpeg exited without producing an output file."));
            }
            progress(1);

            // 6. 移到视频同目录："<原名>（中文字幕）.mp4"（标签可由 outputTag 定制），重名时加 " 2"、" 3"…
            var stem = Path.GetFileNameWithoutExtension(video);
            var directory = Path.GetDirectoryName(video) ?? ".";
            var tag = outputTag ?? L10n.T("（中文字幕）", " (Chinese subtitles)");
            var destination = Path.Combine(directory, $"{stem}{tag}.mp4");
            var serial = 2;
            while (File.Exists(destination))
            {
                destination = Path.Combine(directory, $"{stem}{tag} {serial}.mp4");
                serial++;
            }
            try
            {
                File.Move(produced, destination);
            }
            catch (Exception e)
            {
                throw VdlException.BurnFailed(L10n.T($"无法移动输出文件：{e.Message}",
                    $"Could not move the output file: {e.Message}"));
            }
            return destination;
        }
        finally
        {
            TryRemoveDirectory(tempDir);
        }
    }

    private static void TryRemoveDirectory(string path)
    {
        try { Directory.Delete(path, recursive: true); } catch { /* 忽略 */ }
    }

    // MARK: ffprobe

    internal sealed record ProbeResult(double? Duration, double? BitRateBps, int? Width, int? Height);

    private static async Task<ProbeResult> ProbeAsync(string video, CancellationToken ct)
    {
        var ffprobe = Locate("ffprobe");
        if (ffprobe is null) return new ProbeResult(null, null, null, null);
        var lines = new List<string>();
        var linesLock = new object();
        int status;
        try
        {
            (status, _) = await ProcessRunner.RunStreamingProcessAsync(
                ffprobe,
                ["-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", video],
                onLine: line => { lock (linesLock) lines.Add(line); },
                ct: ct).ConfigureAwait(false);
        }
        catch (VdlException)
        {
            return new ProbeResult(null, null, null, null);
        }
        if (status != 0) return new ProbeResult(null, null, null, null);
        string text;
        lock (linesLock) text = string.Join("\n", lines);
        try
        {
            using var doc = JsonDocument.Parse(text);
            var root = doc.RootElement;
            double? duration = null, bitRate = null;
            int? width = null, height = null;
            if (root.TryGetProperty("format", out var format) && format.ValueKind == JsonValueKind.Object)
            {
                duration = YtDlpEngine.DoubleField(format, "duration");
                bitRate = YtDlpEngine.DoubleField(format, "bit_rate");
            }
            if (root.TryGetProperty("streams", out var streams) && streams.ValueKind == JsonValueKind.Array)
            {
                foreach (var stream in streams.EnumerateArray())
                {
                    if (YtDlpEngine.StringField(stream, "codec_type") != "video") continue;
                    width = YtDlpEngine.IntField(stream, "width");
                    height = YtDlpEngine.IntField(stream, "height");
                    bitRate ??= YtDlpEngine.DoubleField(stream, "bit_rate");
                    break;
                }
            }
            return new ProbeResult(duration, bitRate, width, height);
        }
        catch (JsonException)
        {
            return new ProbeResult(null, null, null, null);
        }
    }

    // MARK: 进度与参数

    /// <summary>源短边：缩放上限与码率档位都按短边算（竖屏 1080×1920 视作 1080p）。</summary>
    internal static int? ShortSide(int? width, int? height) =>
        height is { } h ? (width is { } w ? Math.Min(w, h) : h) : width;

    /// <summary>缩放滤镜：横屏限高（scale=-2:H）、竖屏限宽（scale=W:-2）；目标为空不缩放。</summary>
    internal static string? ScaleFilter(bool isPortrait, int? targetShortSide) =>
        targetShortSide is { } th ? (isPortrait ? $"scale={th}:-2" : $"scale=-2:{th}") : null;

    /// <summary>
    /// 计算 -maxrate 的 k 值（CRF 编码下仅作封顶，防高复杂度片段码率失控、体积膨胀）。
    /// 实测校准：目标是体积压回源附近，不再用任何下限抬高低码率源。
    /// - 不缩放：min(源整体码率 × 1.5, 按源高度档位上限)；缺源码率时退回档位上限。
    /// - 缩放：min(目标高度档位上限, 源整体码率 × 1.5)；源更小时不浪费。
    /// 档位上限：2160p≈16000，1440p≈10000，1080p≈6000，720p≈3000，480p≈1500。
    /// </summary>
    internal static int MaxrateK(double? sourceBitRateBps, int? sourceHeight, int? targetHeight)
    {
        int? sourceK = sourceBitRateBps is { } bps && bps > 0 ? (int)(bps / 1000 * 1.5) : null;
        if (targetHeight is { } target)
        {
            // 缩放场景：按目标分辨率封顶，并与源码率×1.5 取 min（源更小时不浪费）。
            var tier = BitrateForHeight(target);
            return Math.Min(tier, sourceK ?? tier);
        }
        // 不缩放：以源码率×1.5 为上限，并按源高度档位封顶；缺源码率退回档位。
        var tierK = sourceHeight is { } height ? BitrateForHeight(height) : 6000;
        return sourceK is { } k ? Math.Min(k, tierK) : tierK;
    }

    internal static int BitrateForHeight(int height) => height switch
    {
        >= 1801 => 16000,          // 4K (2160p) 及以上
        >= 1201 and <= 1800 => 10000, // 1440p
        >= 901 and <= 1200 => 6000,   // 1080p
        >= 601 and <= 900 => 3000,    // 720p
        _ => 1500,                    // 480p 及以下
    };

    /// <summary>解析 -progress pipe:1 输出。out_time_ms 与 out_time_us 的值都是微秒。</summary>
    internal static double? ParseProgress(string line, double? totalSeconds)
    {
        if (totalSeconds is not { } total || total <= 0) return null;
        foreach (var prefix in new[] { "out_time_ms=", "out_time_us=" })
        {
            if (!line.StartsWith(prefix, StringComparison.Ordinal)) continue;
            var value = line[prefix.Length..].Trim();
            if (!double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var microseconds))
            {
                return null;
            }
            return Math.Min(Math.Max(microseconds / 1_000_000 / total, 0), 1);
        }
        return null;
    }

    internal static string LastLine(string stderr)
    {
        var lines = stderr.Split('\n', '\r')
            .Select(l => l.Trim())
            .Where(l => l.Length > 0)
            .ToList();
        var last = lines.Count > 0 ? lines[^1] : L10n.T("未知错误", "Unknown error");
        return last.Length > 200 ? last[..200] : last;
    }

    // MARK: ASS 生成（双语两级字号，按视频长宽比自适应）

    private const int ChineseFontSize = 15;
    private const int OriginalFontSize = 11;

    /// <summary>
    /// 按视频长宽比推导的 ASS 布局参数。
    /// 字号历来按「高度的固定比例」调校（横屏 16:9 下 15/288≈5.2% 视频高），
    /// 竖屏时宽度变窄、同比例字号一行只装得下十来个字还会顶边。
    /// 竖屏改按 sqrt(aspect / (16/9)) 缩小字号——高度占比与每行字数的折中
    /// （纯按宽度缩会太小，不缩会溢出），9:16 时中文一行约 19 字。
    /// </summary>
    internal readonly struct AssLayout
    {
        public int PlayResX { get; }
        public int PlayResY => 288;
        public int ChineseSize { get; }
        public int OriginalSize { get; }
        public int MarginH { get; }
        public int MarginV => 20;
        /// <summary>中文行预换行容量（字符数）；null 表示不预换行（交给 libass）。</summary>
        public int? CjkWrapCapacity { get; }

        public AssLayout(double aspect)
        {
            var safeAspect = double.IsFinite(aspect) && aspect > 0.1 ? Math.Min(aspect, 4.0) : 16.0 / 9.0;
            // 脚本坐标系与视频同比例（取偶数），横向边距/字号的单位才不会被拉伸
            PlayResX = Math.Max(120, (int)Math.Round(288.0 * safeAspect / 2, MidpointRounding.AwayFromZero) * 2);
            if (safeAspect >= 1)
            {
                ChineseSize = ChineseFontSize;
                OriginalSize = OriginalFontSize;
            }
            else
            {
                var scale = Math.Sqrt(safeAspect / (16.0 / 9.0));
                ChineseSize = Math.Max(8, (int)Math.Round(ChineseFontSize * scale, MidpointRounding.AwayFromZero));
                OriginalSize = Math.Max(6, (int)Math.Round(OriginalFontSize * scale, MidpointRounding.AwayFromZero));
            }
            MarginH = Math.Max(5, (int)Math.Round(PlayResX * 0.03, MidpointRounding.AwayFromZero));
            // 中文无空格，部分 libass 构建只在空格处断行，长行会横向溢出；
            // 一律自己按容量预换行（同时把行切得均衡，避免「一长一短」的难看断行）。
            var capacity = (PlayResX - MarginH * 2) / Math.Max(ChineseSize, 1);
            CjkWrapCapacity = capacity >= 6 ? capacity : null;
        }
    }

    /// <summary>
    /// 把 SRT 字幕转成 ASS：双语条目（含中日韩文字的行 + 不含的行）中日韩行用正常字号排上面，
    /// 其余行（原文）用更小字号排下面；普通条目整条统一字号。
    /// aspect = 视频宽/高；fontName 供测试注入，null 用平台默认。
    /// </summary>
    internal static string MakeAss(IReadOnlyList<SubtitleCue> cues, double aspect = 16.0 / 9.0, string? fontName = null)
    {
        var font = fontName ?? ChineseFontName;
        var layout = new AssLayout(aspect);
        var dialogues = new List<string>();
        foreach (var cue in cues)
        {
            var start = AssTimestamp(cue.Start);
            var end = AssTimestamp(cue.End);
            if (start is null || end is null) continue;
            var lines = cue.Text.Split('\n')
                .Select(EscapeAssText)
                .Where(l => l.Length > 0)
                .ToList();
            if (lines.Count == 0) continue;

            // 双语条目：含中日韩文字的行排上面（正常字号），其余原文行排下面（小字号）。
            // 不论源文件里两种语言的顺序如何，烧录出来都是中文在上。
            string text;
            var cjkLines = new List<string>();
            foreach (var cjk in lines.Where(ContainsCjk))
            {
                if (layout.CjkWrapCapacity is { } capacity) cjkLines.AddRange(WrapCjkLine(cjk, capacity));
                else cjkLines.Add(cjk);
            }
            var otherLines = lines.Where(l => !ContainsCjk(l)).ToList();
            if (cjkLines.Count > 0 && otherLines.Count > 0)
            {
                text = string.Join("\\N", cjkLines)
                    + $"\\N{{\\fs{layout.OriginalSize}}}"
                    + string.Join("\\N", otherLines);
            }
            else
            {
                text = cjkLines.Count == 0
                    ? string.Join("\\N", lines)
                    : string.Join("\\N", cjkLines);
            }
            dialogues.Add($"Dialogue: 0,{start},{end},ZH,,0,0,0,,{text}");
        }

        var header = $"""
            [Script Info]
            ScriptType: v4.00+
            PlayResX: {layout.PlayResX}
            PlayResY: {layout.PlayResY}
            WrapStyle: 0
            ScaledBorderAndShadow: yes

            [V4+ Styles]
            Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
            Style: ZH,{font},{layout.ChineseSize},&H00FFFFFF,&H00FFFFFF,&H00000000,&H7F000000,0,0,0,0,100,100,0,0,1,1,0,2,{layout.MarginH},{layout.MarginH},{layout.MarginV},1

            [Events]
            Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
            """;
        return header + "\n" + string.Join("\n", dialogues) + "\n";
    }

    /// <summary>
    /// 超过容量的中文行均衡预换行：行数取最少、各行长度尽量接近；
    /// 切点优先标点之后 &gt; 空格处 &gt; 任意中日韩字界（绝不切进英文单词/数字中间）。
    /// </summary>
    internal static List<string> WrapCjkLine(string line, int capacity)
    {
        var chars = line.ToCharArray();
        if (capacity < 6 || chars.Length <= capacity) return [line];
        var lineCount = (int)Math.Ceiling((double)chars.Length / capacity);
        var target = (int)Math.Ceiling((double)chars.Length / lineCount);
        var result = new List<string>();
        var start = 0;
        while (chars.Length - start > capacity)
        {
            var idealEnd = Math.Min(start + target, chars.Length - 1);
            // 在理想切点前后各 6 个字符内找切点（切点 = 新行的起点下标），
            // 上限不超过容量保证本行装得下；同级里取离理想点最近的。
            var low = Math.Max(start + 1, idealEnd - 6);
            var high = Math.Min(start + capacity, Math.Min(idealEnd + 6, chars.Length - 1));
            int? bestPunct = null, bestSpace = null, bestCjkBoundary = null;
            int Better(int? current, int candidate) =>
                current is { } cur && Math.Abs(candidate - idealEnd) >= Math.Abs(cur - idealEnd)
                    ? cur
                    : candidate;
            for (var i = low; i <= high; i++)
            {
                var prev = chars[i - 1];
                if (CjkBreakAfter.Contains(prev)) bestPunct = Better(bestPunct, i);
                else if (prev == ' ' || chars[i] == ' ') bestSpace = Better(bestSpace, i);
                else if (IsCjkChar(prev) || IsCjkChar(chars[i])) bestCjkBoundary = Better(bestCjkBoundary, i);
            }
            var cut = bestPunct ?? bestSpace ?? bestCjkBoundary ?? idealEnd;
            var piece = new string(chars, start, cut - start).Trim();
            if (piece.Length > 0) result.Add(piece);
            start = cut;
            // 跳过切点处的空格，避免新行以空格开头
            while (start < chars.Length && chars[start] == ' ') start++;
        }
        var last = new string(chars, start, chars.Length - start).Trim();
        if (last.Length > 0) result.Add(last);
        return result.Count == 0 ? [line] : result;
    }

    /// <summary>切行时允许出现在行尾的标点（其后断行不破坏语感）。</summary>
    private static readonly HashSet<char> CjkBreakAfter =
        ['，', '。', '！', '？', '、', '；', '：', '…', ',', '.', '!', '?', ';', ':'];

    /// <summary>"00:01:02,500" → "0:01:02.50"（ASS 用厘秒）。</summary>
    internal static string? AssTimestamp(string srt)
    {
        var normalized = srt.Replace(',', '.');
        var parts = normalized.Split(':');
        if (parts.Length != 3) return null;
        if (!int.TryParse(parts[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out var h)) return null;
        if (!int.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var m)) return null;
        var secParts = parts[2].Split('.');
        if (!int.TryParse(secParts[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out var s)) return null;
        if (s >= 60 || m >= 60) return null;
        var msString = secParts.Length > 1 ? secParts[1] : "0";
        msString = msString.Length > 3 ? msString[..3] : msString.PadRight(3, '0');
        var ms = int.TryParse(msString, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsedMs) ? parsedMs : 0;
        return $"{h}:{m:00}:{s:00}.{ms / 10:00}";
    }

    internal static bool ContainsCjk(string text) =>
        text.EnumerateRunes().Any(rune =>
            rune.Value is >= 0x4E00 and <= 0x9FFF        // CJK 统一表意
                or >= 0x3400 and <= 0x4DBF               // 扩展 A
                or >= 0x3040 and <= 0x30FF               // 日文假名
                or >= 0xAC00 and <= 0xD7AF);             // 谚文

    /// <summary>切行用的单字符判定；四个区段都在 BMP，按 char 比较即可（与 ContainsCjk 同区段）。</summary>
    private static bool IsCjkChar(char c) =>
        (int)c is >= 0x4E00 and <= 0x9FFF        // CJK 统一表意
            or >= 0x3400 and <= 0x4DBF           // 扩展 A
            or >= 0x3040 and <= 0x30FF           // 日文假名
            or >= 0xAC00 and <= 0xD7AF;          // 谚文

    /// <summary>ASS 文本里 {} 是样式覆盖块定界符，替换为全角避免被解析。</summary>
    internal static string EscapeAssText(string line) =>
        line.Trim()
            .Replace("{", "｛")
            .Replace("}", "｝")
            .Replace("\\", "＼");
}
