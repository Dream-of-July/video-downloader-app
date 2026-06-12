using System.Globalization;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Vdl.Core;

// MARK: - SRT 解析与序列化 + 清洗

/// <summary>SRT 解析、序列化与清洗（YouTube 滚动字幕去重叠 / 文本去重 / 按句合并）。</summary>
public static partial class SrtTools
{
    [GeneratedRegex(@"(\d{1,2}:\d{2}:\d{2}[,\.]\d{1,3})\s*-->\s*(\d{1,2}:\d{2}:\d{2}[,\.]\d{1,3})")]
    private static partial Regex TimeLineRegex();

    /// <summary>
    /// 解析 SRT 文本为字幕条。按时间行锚定切条（而非按空行切块）：
    /// YouTube 滚动字幕的文本里常夹空行/纯空白行，按空行切块会把后半句当成
    /// 没有时间行的孤块整体丢掉。容忍 BOM、CRLF、多行文本、序号缺失（按顺序补号）；
    /// 文本为空的条目直接丢弃。
    /// </summary>
    public static List<SubtitleCue> ParseSrt(string raw)
    {
        var text = raw;
        if (text.StartsWith('\uFEFF')) text = text[1..];
        var lines = text.Replace("\r\n", "\n").Replace("\r", "\n").Split('\n');

        // 先找出所有时间行的位置；上一行若是纯数字则视为该条的显式序号。
        var anchors = new List<(int LineIndex, string Start, string End, int? ExplicitIndex, bool HasIndexLine)>();
        for (var i = 0; i < lines.Length; i++)
        {
            var match = TimeLineRegex().Match(lines[i]);
            if (!match.Success) continue;
            int? explicitIndex = null;
            if (i > 0 && int.TryParse(lines[i - 1].Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed))
            {
                explicitIndex = parsed;
            }
            anchors.Add((i, match.Groups[1].Value, match.Groups[2].Value, explicitIndex, explicitIndex.HasValue));
        }

        var cues = new List<SubtitleCue>();
        var nextIndex = 1;
        for (var a = 0; a < anchors.Count; a++)
        {
            var anchor = anchors[a];
            // 文本范围：本条时间行之后 → 下一条的序号行（或时间行）之前
            var textEnd = lines.Length;
            if (a + 1 < anchors.Count)
            {
                var next = anchors[a + 1];
                textEnd = next.HasIndexLine ? next.LineIndex - 1 : next.LineIndex;
            }
            var textStart = anchor.LineIndex + 1;
            if (textStart > textEnd) continue;
            var textLines = lines[textStart..Math.Min(textEnd, lines.Length)]
                .Select(l => l.Trim())
                .Where(l => l.Length > 0)
                .ToList();
            if (textLines.Count == 0) continue;
            var index = anchor.ExplicitIndex ?? nextIndex;
            cues.Add(new SubtitleCue(index, anchor.Start, anchor.End, string.Join("\n", textLines)));
            nextIndex = index + 1;
        }
        return cues;
    }

    /// <summary>序列化为标准 SRT 文本。</summary>
    public static string SerializeSrt(IEnumerable<SubtitleCue> cues) =>
        string.Join("\n\n", cues.Select(c => $"{c.Index}\n{c.Start} --> {c.End}\n{c.Text}")) + "\n";

    /// <summary>把 "HH:MM:SS,mmm"（或用 "." 作毫秒分隔）解析为秒。失败返回 null。</summary>
    public static double? SrtTimeToSeconds(string s)
    {
        var normalized = s.Replace(',', '.');
        var parts = normalized.Split(':');
        if (parts.Length != 3) return null;
        if (!int.TryParse(parts[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out var h)) return null;
        if (!int.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var m)) return null;
        if (!double.TryParse(parts[2], NumberStyles.Float, CultureInfo.InvariantCulture, out var sec)) return null;
        return h * 3600.0 + m * 60.0 + sec;
    }

    /// <summary>秒转回 "HH:MM:SS,mmm"。</summary>
    public static string SecondsToSrtTime(double seconds)
    {
        var clamped = Math.Max(0, seconds);
        var totalMs = (long)Math.Round(clamped * 1000, MidpointRounding.AwayFromZero);
        var ms = totalMs % 1000;
        var totalSec = totalMs / 1000;
        var s = totalSec % 60;
        var m = totalSec / 60 % 60;
        var h = totalSec / 3600;
        return $"{h:00}:{m:00}:{s:00},{ms:000}";
    }

    /// <summary>
    /// 清洗字幕：
    /// (a) 解析时间戳为秒，按 start 稳定升序；
    /// (b) 去重叠：每条 end 截断到 min(自身 end, 下一条 start)，截断后 &lt;0.3s 则设为 start+0.3s；
    /// (c) 按句合并（仅对滚动字幕启用）：相邻碎条拼接，遇句末标点 / 累积≥6s / 累积≥84 字符断句；
    /// (d) 防误伤：合并后条数 ≥ 原条数则放弃合并，只返回去重叠结果；
    /// (e) 滚动判定（满足其一即按句合并）：时间戳重叠率 &gt; 50%（样式 A），
    ///     或相邻条文本重复率 &gt; 30%（样式 B：两行滚动窗口，先做文本去重再合并）。
    /// </summary>
    public static List<SubtitleCue> CleanCues(List<SubtitleCue> input)
    {
        if (input.Count == 0) return input;

        // (a) 解析时间 + 稳定升序排序
        var timed = new List<TimedCue>();
        for (var i = 0; i < input.Count; i++)
        {
            var start = SrtTimeToSeconds(input[i].Start);
            var end = SrtTimeToSeconds(input[i].End);
            if (start is null || end is null) continue;
            timed.Add(new TimedCue(start.Value, Math.Max(end.Value, start.Value), input[i].Text, i));
        }
        if (timed.Count == 0) return input;
        timed.Sort((x, y) => x.Start != y.Start ? x.Start.CompareTo(y.Start) : x.Order.CompareTo(y.Order));

        // (e) 滚动判定一：时间戳重叠（样式 A）——相邻条 start < 上一条 end 的比例 > 50%
        var overlapCount = 0;
        for (var i = 1; i < timed.Count; i++)
        {
            if (timed[i].Start < timed[i - 1].End) overlapCount++;
        }
        var overlapRatio = timed.Count >= 2 ? (double)overlapCount / (timed.Count - 1) : 0;

        // (e2) 滚动判定二：文本重复（样式 B）——每条开头重复上一条的尾行
        //（两行滚动窗口 + 10ms 过渡条，时间戳首尾相接不重叠，靠时间戳判不出来）。
        var textRepeatPairs = 0;
        for (var i = 1; i < timed.Count; i++)
        {
            var prev = timed[i - 1].Text.Split('\n');
            var cur = timed[i].Text.Split('\n');
            if (OverlapPrefixCount(prev, cur) > 0) textRepeatPairs++;
        }
        var textRepeatRatio = timed.Count >= 2 ? (double)textRepeatPairs / (timed.Count - 1) : 0;

        var isRolling = overlapRatio > 0.5 || textRepeatRatio > 0.3;

        // (a2) 样式 B 先做文本去重：删掉每条开头与上一条结尾重复的行，只留新增内容；
        //      删空的条目（纯过渡条）整条丢弃。对照对象用上一条的「原始」行，因为
        //      滚动窗口重复的是原文而非去重后的残句。阈值 0.3 防止误伤歌词等合法重复。
        if (textRepeatRatio > 0.3)
        {
            var deduped = new List<TimedCue>();
            var prevOriginalLines = Array.Empty<string>();
            foreach (var item in timed)
            {
                var curLines = item.Text.Split('\n');
                var k = OverlapPrefixCount(prevOriginalLines, curLines);
                prevOriginalLines = curLines;
                var newLines = curLines.Skip(k).ToArray();
                if (newLines.Length == 0) continue;
                deduped.Add(item with { Text = string.Join("\n", newLines) });
            }
            if (deduped.Count > 0) timed = deduped;
        }

        // (b) 去重叠：end 截断到下一条 start，过短则补到 start+0.3s（但不越过下一条 start）
        const double minDuration = 0.3;
        for (var i = 0; i < timed.Count; i++)
        {
            double? nextStart = i + 1 < timed.Count ? timed[i + 1].Start : null;
            var item = timed[i];
            if (nextStart is { } ns1)
            {
                item = item with { End = Math.Min(item.End, ns1) };
            }
            if (item.End - item.Start < minDuration)
            {
                var compensated = item.Start + minDuration;
                if (nextStart is { } ns2) compensated = Math.Min(compensated, ns2);
                item = item with { End = compensated };
            }
            timed[i] = item;
        }

        // 非滚动字幕：只做去重叠，不合并
        if (!isRolling) return MakeCues(timed);

        // (c) 按句合并：把碎条文本规整空白后用空格累积，满足任一断句条件即收一条
        var merged = new List<TimedCue>();
        var curText = "";
        var curStart = 0.0;
        var curEnd = 0.0;
        var hasCurrent = false;

        void Flush()
        {
            if (!hasCurrent) return;
            merged.Add(new TimedCue(curStart, curEnd, curText, merged.Count));
            hasCurrent = false;
            curText = "";
        }

        foreach (var t in timed)
        {
            var piece = NormalizeWhitespace(t.Text);
            if (!hasCurrent)
            {
                curText = piece;
                curStart = t.Start;
                curEnd = t.End;
                hasCurrent = true;
            }
            else
            {
                curText = NormalizeWhitespace(curText + " " + piece);
                curEnd = t.End;
            }
            var longEnough = curEnd - curStart >= 6.0;
            var charsEnough = curText.Length >= 84;
            if (EndsSentence(curText) || longEnough || charsEnough)
            {
                Flush();
            }
        }
        Flush();

        // (d) 防误伤：合并后条数没减少则放弃合并
        return merged.Count < timed.Count ? MakeCues(merged) : MakeCues(timed);
    }

    private sealed record TimedCue(double Start, double End, string Text, int Order);

    private static List<SubtitleCue> MakeCues(List<TimedCue> items) =>
        items.Select((t, idx) => new SubtitleCue(
            idx + 1, SecondsToSrtTime(t.Start), SecondsToSrtTime(t.End), t.Text)).ToList();

    /// <summary>cur 开头与 prev 结尾重复的最大行数（两行滚动窗口的核心判据）。</summary>
    private static int OverlapPrefixCount(IReadOnlyList<string> prev, IReadOnlyList<string> cur)
    {
        var k = Math.Min(prev.Count, cur.Count);
        while (k > 0)
        {
            var equal = true;
            for (var i = 0; i < k; i++)
            {
                if (prev[prev.Count - k + i] != cur[i]) { equal = false; break; }
            }
            if (equal) return k;
            k--;
        }
        return 0;
    }

    private static string NormalizeWhitespace(string s) =>
        string.Join(' ', s.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));

    private static readonly HashSet<char> SentenceEnders = ['.', '!', '?', '。', '！', '？'];
    private static readonly HashSet<char> TrailingAllowed = ['"', '\'', '”', '’', ')', '）', '」', '』', ']'];

    private static bool EndsSentence(string text)
    {
        var end = text.Length;
        // 跳过尾部的引号 / 括号
        while (end > 0 && (TrailingAllowed.Contains(text[end - 1]) || text[end - 1] == ' '))
        {
            end--;
        }
        return end > 0 && SentenceEnders.Contains(text[end - 1]);
    }

    /// <summary>
    /// 调试辅助：只清洗不翻译（解析 → CleanCues → 序列化），输出 "&lt;名&gt;.clean.srt"。
    /// 在不调 LLM 的情况下验证字幕清洗效果。
    /// </summary>
    public static (int Parsed, int Cleaned, string OutputPath) CleanSrtFile(string path)
    {
        string raw;
        try
        {
            raw = File.ReadAllText(path);
        }
        catch
        {
            throw VdlException.TranslateFailed(L10n.T($"无法读取字幕文件：{Path.GetFileName(path)}",
                $"Could not read the subtitle file: {Path.GetFileName(path)}"));
        }
        var parsed = ParseSrt(raw);
        if (parsed.Count == 0)
        {
            throw VdlException.TranslateFailed(L10n.T("字幕文件里没有可识别的字幕内容。",
                "No recognizable subtitles in this file."));
        }
        var cleaned = CleanCues(parsed);
        var name = Path.GetFileName(path);
        var stem = name.EndsWith(".srt", StringComparison.OrdinalIgnoreCase) ? name[..^4] : name;
        var output = Path.Combine(Path.GetDirectoryName(path) ?? ".", stem + ".clean.srt");
        File.WriteAllText(output, SerializeSrt(cleaned));
        return (parsed.Count, cleaned.Count, output);
    }
}

// MARK: - LLM API 请求

/// <summary>一次模型调用的结果：文本 + 是否因为输出上限被截断。</summary>
internal sealed record ModelReply(string Text, bool ReachedOutputLimit);

/// <summary>
/// 翻译服务的 HTTP 协议层：Anthropic Messages 与 OpenAI Responses。
/// 全部方法接受可注入的 HttpMessageHandler（测试用 fake handler 断言请求形状与模拟响应）。
/// </summary>
public static class TranslationApi
{
    private static readonly HttpMessageHandler SharedHandler = new SocketsHttpHandler
    {
        PooledConnectionLifetime = TimeSpan.FromMinutes(5),
    };

    private static HttpClient MakeClient(HttpMessageHandler? handler, TimeSpan timeout) =>
        new(handler ?? SharedHandler, disposeHandler: false) { Timeout = timeout };

    private static readonly JsonSerializerOptions PayloadOptions = new()
    {
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    // MARK: 工具

    internal static string NormalizedToken(string raw)
    {
        var token = raw.Trim();
        // 用户误把 "Bearer xxx" 整段贴进凭证框时剥掉前缀，避免双重 Bearer。
        if (token.StartsWith("bearer ", StringComparison.OrdinalIgnoreCase))
        {
            token = token["bearer ".Length..].Trim();
        }
        return token;
    }

    internal static Uri EndpointUrl(string baseUrl, string endpointPath)
    {
        var b = baseUrl.Trim();
        while (b.EndsWith('/')) b = b[..^1];

        var path = endpointPath.StartsWith('/') ? endpointPath : "/" + endpointPath;
        var lowerBase = b.ToLowerInvariant();
        var lowerPath = path.ToLowerInvariant();
        string urlString;
        if (lowerBase.EndsWith(lowerPath))
        {
            urlString = b;
        }
        else if (lowerBase.EndsWith("/v1") && lowerPath.StartsWith("/v1/"))
        {
            urlString = b + path["/v1".Length..];
        }
        else
        {
            urlString = b + path;
        }

        if (b.Length == 0
            || !Uri.TryCreate(urlString, UriKind.Absolute, out var url)
            || (url.Scheme != "http" && url.Scheme != "https")
            || string.IsNullOrEmpty(url.Host))
        {
            throw VdlException.TranslateFailed(L10n.T("服务地址无效", "Invalid service URL"));
        }
        return url;
    }

    private static string ResponseErrorMessage(string body)
    {
        string? decoded = null;
        try
        {
            using var doc = JsonDocument.Parse(body);
            if (doc.RootElement.ValueKind == JsonValueKind.Object
                && doc.RootElement.TryGetProperty("error", out var error)
                && error.ValueKind == JsonValueKind.Object
                && error.TryGetProperty("message", out var message)
                && message.ValueKind == JsonValueKind.String)
            {
                decoded = message.GetString();
            }
        }
        catch
        {
            // 非 JSON 响应：走 fallback
        }
        var fallback = body.Length > 200 ? body[..200].Trim() : body.Trim();
        return decoded ?? (fallback.Length == 0 ? L10n.T("请求失败", "Request failed") : fallback);
    }

    internal static string RequestFailureMessage(int statusCode, string body, AppSettings settings)
    {
        var message = ResponseErrorMessage(body);
        var lowerMessage = message.ToLowerInvariant();
        if (statusCode != 503 && !lowerMessage.Contains("no available accounts"))
        {
            return L10n.T($"HTTP {statusCode}：{message}", $"HTTP {statusCode}: {message}");
        }

        var model = settings.TranslationModel.Trim();
        var modelTextZh = model.Length == 0 ? "已填写" : $"「{model}」";
        var modelTextEn = model.Length == 0 ? "(empty)" : $"\"{model}\"";
        return L10n.T(
            $"HTTP {statusCode}：网关没有可用账号或模型映射未命中。请确认模型名 {modelTextZh} 在公司网关里已登记——点「拉取模型」选一个网关实际提供的模型。原始错误：{message}",
            $"HTTP {statusCode}: the gateway has no available account or the model mapping was not found. Make sure model {modelTextEn} is registered on your gateway — use \"Fetch models\" to pick one it actually serves. Original error: {message}");
    }

    // MARK: 协议分发

    internal static Task<ModelReply> SendConfiguredMessageAsync(
        AppSettings settings, string? system, string userContent, int maxTokens,
        HttpMessageHandler? handler, CancellationToken ct) => settings.TranslationProvider switch
    {
        TranslationProvider.Anthropic => SendAnthropicMessageAsync(settings, system, userContent, maxTokens, handler, ct),
        _ => SendOpenAiResponseAsync(settings, system, userContent, maxTokens, handler, ct),
    };

    private static (string Model, string Token) RequireModelAndToken(AppSettings settings)
    {
        var model = settings.TranslationModel.Trim();
        if (model.Length == 0)
        {
            throw VdlException.TranslateFailed(L10n.T("尚未配置模型，请在设置里填写模型名称。",
                "No model configured. Enter a model name in Settings."));
        }
        var token = NormalizedToken(settings.TranslationAuthToken);
        if (token.Length == 0)
        {
            throw VdlException.TranslateFailed(L10n.T("尚未配置 API 凭证，请在设置里填写。",
                "No API credential configured. Enter it in Settings."));
        }
        return (model, token);
    }

    /// <summary>
    /// 调一次 Anthropic Messages API，返回回复里所有 type=="text" 块拼接后的文本。
    /// 429/5xx 指数退避重试最多 2 次（2s、8s）；其余错误映射为 VdlException。
    /// </summary>
    internal static async Task<ModelReply> SendAnthropicMessageAsync(
        AppSettings settings, string? system, string userContent, int maxTokens,
        HttpMessageHandler? handler, CancellationToken ct)
    {
        var (model, token) = RequireModelAndToken(settings);
        var url = EndpointUrl(settings.TranslationBaseUrl, "/v1/messages");
        var isOfficialAnthropic = string.Equals(url.Host, "api.anthropic.com", StringComparison.OrdinalIgnoreCase);

        var payload = new Dictionary<string, object?>
        {
            ["model"] = model,
            ["max_tokens"] = maxTokens,
            ["system"] = system,
            ["messages"] = new[] { new Dictionary<string, string> { ["role"] = "user", ["content"] = userContent } },
        };
        var body = JsonSerializer.Serialize(payload, PayloadOptions);

        HttpRequestMessage MakeRequest()
        {
            var request = new HttpRequestMessage(HttpMethod.Post, url)
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json"),
            };
            request.Headers.Add("anthropic-version", "2023-06-01");
            // 官方 API 只认 x-api-key（两个鉴权头同时发会被拒）；其他网关两个都发以求兼容。
            request.Headers.Add("x-api-key", token);
            if (!isOfficialAnthropic)
            {
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            }
            return request;
        }

        using var client = MakeClient(handler, TimeSpan.FromSeconds(120));
        return await SendWithRetryAsync(client, MakeRequest, settings, ParseAnthropicReply, ct).ConfigureAwait(false);
    }

    private static ModelReply ParseAnthropicReply(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.TryGetProperty("content", out var content) && content.ValueKind == JsonValueKind.Array)
            {
                var parts = new List<string>();
                var sawText = false;
                foreach (var block in content.EnumerateArray())
                {
                    if (block.TryGetProperty("type", out var type) && type.GetString() == "text")
                    {
                        sawText = true;
                        if (block.TryGetProperty("text", out var text) && text.ValueKind == JsonValueKind.String)
                        {
                            parts.Add(text.GetString() ?? "");
                        }
                    }
                }
                if (sawText)
                {
                    var stopReason = root.TryGetProperty("stop_reason", out var sr) && sr.ValueKind == JsonValueKind.String
                        ? sr.GetString() : null;
                    return new ModelReply(string.Concat(parts), stopReason == "max_tokens");
                }
            }
        }
        catch (JsonException)
        {
            // 落到下面的协议错误
        }
        throw VdlException.TranslateFailed(L10n.T("服务响应不符合 Anthropic Messages 协议，请检查服务地址。",
            "The response does not match the Anthropic Messages protocol. Check the service URL."));
    }

    /// <summary>
    /// 调一次 OpenAI Responses API，返回 output_text 块拼接后的文本。
    /// 429/5xx 指数退避重试最多 2 次（2s、8s）；其余错误映射为 VdlException。
    /// </summary>
    internal static async Task<ModelReply> SendOpenAiResponseAsync(
        AppSettings settings, string? instructions, string input, int maxOutputTokens,
        HttpMessageHandler? handler, CancellationToken ct)
    {
        var (model, token) = RequireModelAndToken(settings);
        var url = EndpointUrl(settings.TranslationBaseUrl, "/v1/responses");

        var payload = new Dictionary<string, object?>
        {
            ["model"] = model,
            ["instructions"] = instructions,
            ["input"] = input,
            ["max_output_tokens"] = maxOutputTokens,
            ["store"] = false,
        };
        var body = JsonSerializer.Serialize(payload, PayloadOptions);

        HttpRequestMessage MakeRequest()
        {
            var request = new HttpRequestMessage(HttpMethod.Post, url)
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json"),
            };
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            return request;
        }

        using var client = MakeClient(handler, TimeSpan.FromSeconds(120));
        return await SendWithRetryAsync(client, MakeRequest, settings, ParseOpenAiReply, ct).ConfigureAwait(false);
    }

    private static ModelReply ParseOpenAiReply(string json)
    {
        JsonDocument doc;
        try
        {
            doc = JsonDocument.Parse(json);
        }
        catch (JsonException)
        {
            throw VdlException.TranslateFailed(L10n.T("服务响应不符合 OpenAI Responses 协议，请检查服务地址。",
                "The response does not match the OpenAI Responses protocol. Check the service URL."));
        }
        using (doc)
        {
            var root = doc.RootElement;
            if (!root.TryGetProperty("output", out var output) || output.ValueKind != JsonValueKind.Array)
            {
                throw VdlException.TranslateFailed(L10n.T("服务响应不符合 OpenAI Responses 协议，请检查服务地址。",
                    "The response does not match the OpenAI Responses protocol. Check the service URL."));
            }
            var textParts = new List<string>();
            foreach (var item in output.EnumerateArray())
            {
                if (!item.TryGetProperty("type", out var itemType) || itemType.GetString() != "message") continue;
                if (!item.TryGetProperty("content", out var content) || content.ValueKind != JsonValueKind.Array) continue;
                foreach (var block in content.EnumerateArray())
                {
                    var blockType = block.TryGetProperty("type", out var bt) ? bt.GetString() : null;
                    if (blockType != "output_text" && blockType != "text") continue;
                    if (block.TryGetProperty("text", out var text) && text.ValueKind == JsonValueKind.String)
                    {
                        textParts.Add(text.GetString() ?? "");
                    }
                }
            }
            var joined = string.Concat(textParts);
            if (joined.Length == 0)
            {
                throw VdlException.TranslateFailed(L10n.T("OpenAI 响应里没有文本内容，请检查模型或服务地址。",
                    "The OpenAI response contains no text. Check the model or service URL."));
            }
            var status = root.TryGetProperty("status", out var st) && st.ValueKind == JsonValueKind.String ? st.GetString() : null;
            string? incompleteReason = null;
            if (root.TryGetProperty("incomplete_details", out var details) && details.ValueKind == JsonValueKind.Object
                && details.TryGetProperty("reason", out var reason) && reason.ValueKind == JsonValueKind.String)
            {
                incompleteReason = reason.GetString();
            }
            return new ModelReply(joined, status == "incomplete" && incompleteReason == "max_output_tokens");
        }
    }

    /// <summary>共用的发送 + 429/5xx 退避重试（2s、8s）+ 错误归一化。</summary>
    private static async Task<ModelReply> SendWithRetryAsync(
        HttpClient client,
        Func<HttpRequestMessage> makeRequest,
        AppSettings settings,
        Func<string, ModelReply> parse,
        CancellationToken ct)
    {
        var backoff = new[] { TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(8) };
        var attempt = 0;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            string responseBody;
            int statusCode;
            try
            {
                using var request = makeRequest();
                using var response = await client.SendAsync(request, ct).ConfigureAwait(false);
                statusCode = (int)response.StatusCode;
                responseBody = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                throw;
            }
            catch (OperationCanceledException)
            {
                // HttpClient 超时（非外部取消）
                throw VdlException.TranslateFailed(L10n.T("无法连接到翻译服务，请检查服务地址和网络。",
                    "Could not reach the translation service. Check the service URL and your network."));
            }
            catch (HttpRequestException)
            {
                throw VdlException.TranslateFailed(L10n.T("无法连接到翻译服务，请检查服务地址和网络。",
                    "Could not reach the translation service. Check the service URL and your network."));
            }

            if (statusCode == 200)
            {
                return parse(responseBody);
            }
            var retryable = statusCode == 429 || statusCode is >= 500 and <= 599;
            if (retryable && attempt < backoff.Length)
            {
                await Task.Delay(backoff[attempt], ct).ConfigureAwait(false);
                attempt++;
                continue;
            }
            throw VdlException.TranslateFailed(RequestFailureMessage(statusCode, responseBody, settings));
        }
    }

    // MARK: 连接测试 / 模型列表

    /// <summary>设置面板「测试连接」：发一条迷你请求，返回模型回复文本。</summary>
    public static async Task<string> TestConnectionAsync(
        AppSettings settings, HttpMessageHandler? handler = null, CancellationToken ct = default)
    {
        // 上限别给太小：推理型模型（gpt-5 / o 系列等）会先消耗思考 token，
        // 太小会导致可见输出为空、把"连接正常"误报成失败。
        var reply = await SendConfiguredMessageAsync(
            settings, system: null, userContent: "请只回复两个字：正常", maxTokens: 1024,
            handler, ct).ConfigureAwait(false);
        return reply.Text.Trim();
    }

    /// <summary>
    /// 拉取服务端可用模型列表（GET {baseURL}/v1/models）。
    /// 官方 Anthropic 与 OpenAI、以及大多数企业网关都暴露这个端点；返回模型 id 数组。
    /// 只需服务地址 + 凭证，不需要先填模型。
    /// </summary>
    public static async Task<IReadOnlyList<string>> ListModelsAsync(
        AppSettings settings, HttpMessageHandler? handler = null, CancellationToken ct = default)
    {
        var token = NormalizedToken(settings.TranslationAuthToken);
        if (token.Length == 0)
        {
            throw VdlException.TranslateFailed(L10n.T("尚未配置 API 凭证，请先填写凭证再拉取模型。",
                "No API credential configured. Enter it before fetching models."));
        }
        var url = EndpointUrl(settings.TranslationBaseUrl, "/v1/models");
        // Anthropic 协议的 /v1/models 默认每页只回 20 条，不带 limit 会漏模型；
        // OpenAI 与多数网关会忽略未知查询参数，统一加上无副作用。
        if (string.IsNullOrEmpty(url.Query))
        {
            url = new UriBuilder(url) { Query = "limit=1000" }.Uri;
        }
        var isOfficialAnthropic = string.Equals(url.Host, "api.anthropic.com", StringComparison.OrdinalIgnoreCase);

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        // 同时带两种鉴权头以兼容网关；官方 Anthropic 只认 x-api-key + version。
        request.Headers.Add("x-api-key", token);
        if (!isOfficialAnthropic)
        {
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        }
        request.Headers.Add("anthropic-version", "2023-06-01");

        using var client = MakeClient(handler, TimeSpan.FromSeconds(20));
        string body;
        int statusCode;
        try
        {
            using var response = await client.SendAsync(request, ct).ConfigureAwait(false);
            statusCode = (int)response.StatusCode;
            body = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception e) when (e is HttpRequestException or OperationCanceledException)
        {
            throw VdlException.TranslateFailed(L10n.T("无法连接到翻译服务，请检查服务地址和网络。",
                "Could not reach the translation service. Check the service URL and your network."));
        }

        if (statusCode != 200)
        {
            throw VdlException.TranslateFailed(RequestFailureMessage(statusCode, body, settings));
        }
        var ids = ParseModelIds(body);
        if (ids.Count == 0)
        {
            throw VdlException.TranslateFailed(L10n.T("服务返回的模型列表为空，请手动填写模型名。",
                "The service returned an empty model list. Enter a model name manually."));
        }
        return ids;
    }

    /// <summary>
    /// 解析 /v1/models 响应。兼容 OpenAI 风格 {"data":[{"id":...}]} 与 Anthropic 风格
    /// {"data":[{"id":...,"type":"model"}]}，以及个别网关的 {"models":[...]} / 纯数组。
    /// </summary>
    internal static List<string> ParseModelIds(string json)
    {
        JsonDocument doc;
        try
        {
            doc = JsonDocument.Parse(json);
        }
        catch (JsonException)
        {
            return [];
        }
        using (doc)
        {
            static List<string> Ids(JsonElement arr)
            {
                var result = new List<string>();
                foreach (var entry in arr.EnumerateArray())
                {
                    if (entry.ValueKind == JsonValueKind.String)
                    {
                        result.Add(entry.GetString() ?? "");
                    }
                    else if (entry.ValueKind == JsonValueKind.Object)
                    {
                        foreach (var key in new[] { "id", "name", "model" })
                        {
                            if (entry.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String)
                            {
                                result.Add(v.GetString() ?? "");
                                break;
                            }
                        }
                    }
                }
                return result;
            }

            var root = doc.RootElement;
            if (root.ValueKind == JsonValueKind.Object)
            {
                if (root.TryGetProperty("data", out var data) && data.ValueKind == JsonValueKind.Array)
                {
                    return DedupePreservingOrder(Ids(data));
                }
                if (root.TryGetProperty("models", out var models) && models.ValueKind == JsonValueKind.Array)
                {
                    return DedupePreservingOrder(Ids(models));
                }
            }
            if (root.ValueKind == JsonValueKind.Array)
            {
                return DedupePreservingOrder(Ids(root));
            }
            return [];
        }
    }

    private static List<string> DedupePreservingOrder(List<string> items)
    {
        var seen = new HashSet<string>();
        var output = new List<string>();
        foreach (var item in items)
        {
            if (item.Length > 0 && seen.Add(item)) output.Add(item);
        }
        return output;
    }
}

// MARK: - ConfiguredTranslator

/// <summary>
/// 通过设置里选择的协议翻译字幕。服务地址、模型、凭证全部来自 AppSettings。
/// handler 供测试注入 fake HTTP。
/// </summary>
public sealed class ConfiguredTranslator : ISubtitleTranslator
{
    private readonly AppSettings _settings;
    private readonly HttpMessageHandler? _handler;

    /// <summary>每次请求翻译的字幕条数。</summary>
    private const int ChunkSize = 30;
    /// <summary>最多同时在途的分块请求数。</summary>
    private const int MaxInFlight = 3;

    private const string SystemPrompt =
        "你是专业字幕翻译。把用户给出的字幕逐条翻译成简体中文。" +
        "输入每行格式为 编号|原文。输出必须严格逐行 编号|中文译文，" +
        "行数与输入一致，不要输出任何其他内容。口语自然、简洁，保留专有名词。";

    public ConfiguredTranslator(AppSettings settings, HttpMessageHandler? handler = null)
    {
        _settings = settings;
        _handler = handler;
    }

    public async Task<string> TranslateAsync(
        string srtFile,
        SubtitleStyle style,
        TaskControlToken? control,
        Action<double> progress,
        CancellationToken ct = default)
    {
        string raw;
        try
        {
            raw = await File.ReadAllTextAsync(srtFile, ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch
        {
            throw VdlException.TranslateFailed(L10n.T($"无法读取字幕文件：{Path.GetFileName(srtFile)}",
                $"Could not read the subtitle file: {Path.GetFileName(srtFile)}"));
        }
        var parsed = SrtTools.ParseSrt(raw);
        if (parsed.Count == 0)
        {
            throw VdlException.TranslateFailed(L10n.T("字幕文件里没有可识别的字幕内容。",
                "No recognizable subtitles in this file."));
        }
        // 翻译前清洗：消除 YouTube 自动字幕的重叠滚动碎句、按句合并，减少疯狂刷新。
        var cues = SrtTools.CleanCues(parsed);

        // 分块并行请求（最多 3 个在途）：编号用全局序号（1 起），回贴与完成顺序无关。
        // 每调度一个新块前过一次 gate（暂停挂起 / 取消抛出）；在途块自然跑完。
        var chunkRanges = new List<(int Start, int Count)>();
        var rangeStart = 0;
        while (rangeStart < cues.Count)
        {
            var upper = Math.Min(rangeStart + ChunkSize, cues.Count);
            chunkRanges.Add((rangeStart, upper - rangeStart));
            rangeStart = upper;
        }

        var merged = new Dictionary<int, string>();
        var completedCues = 0;
        // 某块失败时取消兄弟块（等价 Swift TaskGroup 的隐式取消），避免白白烧 token。
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var inFlight = new List<Task<((int Start, int Count) Range, Dictionary<int, string> Map)>>();
        var nextChunk = 0;

        async Task ScheduleNextAsync()
        {
            if (nextChunk >= chunkRanges.Count) return;
            ct.ThrowIfCancellationRequested();
            if (control is not null) await control.GateAsync(ct).ConfigureAwait(false);
            var range = chunkRanges[nextChunk];
            nextChunk++;
            var token = linked.Token;
            inFlight.Add(Task.Run(async () =>
            {
                var mapping = await TranslateChunkAsync(
                    cues, range.Start, range.Count, range.Start + 1, depth: 0, token).ConfigureAwait(false);
                return (range, mapping);
            }, token));
        }

        try
        {
            for (var i = 0; i < Math.Min(MaxInFlight, chunkRanges.Count); i++)
            {
                await ScheduleNextAsync().ConfigureAwait(false);
            }
            while (inFlight.Count > 0)
            {
                var done = await Task.WhenAny(inFlight).ConfigureAwait(false);
                inFlight.Remove(done);
                var (range, mapping) = await done.ConfigureAwait(false);
                foreach (var pair in mapping) merged[pair.Key] = pair.Value;
                completedCues += range.Count;
                progress((double)completedCues / cues.Count);
                await ScheduleNextAsync().ConfigureAwait(false);
            }
        }
        catch
        {
            linked.Cancel();
            // 等在途块收敛，避免悬挂任务在测试/退出时乱抛
            try { await Task.WhenAll(inFlight).ConfigureAwait(false); } catch { /* 已取消 */ }
            throw;
        }

        var output = cues.Select(c => new SubtitleCue(c.Index, c.Start, c.End, c.Text)).ToList();
        for (var cueIndex = 0; cueIndex < cues.Count; cueIndex++)
        {
            // 某条缺失就保留原文（output 初始即原文）
            if (!merged.TryGetValue(cueIndex + 1, out var chinese) || chinese.Length == 0) continue;
            output[cueIndex].Text = style switch
            {
                // 中文在上、原文在下（烧录时原文用更小字号）
                SubtitleStyle.Bilingual => chinese + "\n" + cues[cueIndex].Text,
                _ => chinese,
            };
        }

        // 写 "<原文件名去.srt>.zh.srt"
        var name = Path.GetFileName(srtFile);
        var stem = name.EndsWith(".srt", StringComparison.OrdinalIgnoreCase) ? name[..^4] : name;
        var outputPath = Path.Combine(Path.GetDirectoryName(srtFile) ?? ".", stem + ".zh.srt");
        try
        {
            await File.WriteAllTextAsync(outputPath, SrtTools.SerializeSrt(output), ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception e)
        {
            throw VdlException.TranslateFailed(L10n.T($"无法写入译文文件：{e.Message}",
                $"Could not write the translated file: {e.Message}"));
        }
        return outputPath;
    }

    /// <summary>
    /// 翻译一块字幕，返回 [全局编号: 译文]。
    /// 译文被输出上限截断时按减半的条数自动重试：最多再分两层、每块最小 8 条；仍截断则抛错。
    /// 译文缺失行数超过 40% 视为模型返回格式异常，抛错而不是静默保留原文。
    /// </summary>
    private async Task<Dictionary<int, string>> TranslateChunkAsync(
        IReadOnlyList<SubtitleCue> allCues, int offset, int count, int startNumber, int depth,
        CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        var userContent = string.Join("\n", Enumerable.Range(0, count)
            .Select(i => $"{startNumber + i}|{Flattened(allCues[offset + i].Text)}"));

        var reply = await TranslationApi.SendConfiguredMessageAsync(
            _settings, SystemPrompt, userContent, maxTokens: 8000, _handler, ct).ConfigureAwait(false);
        if (reply.ReachedOutputLimit)
        {
            var half = count / 2;
            if (depth >= 2 || half < 8)
            {
                throw VdlException.TranslateFailed(L10n.T(
                    "译文超出模型输出上限，请减小每块字幕条数或检查模型 max_tokens 限制",
                    "Translation exceeded the model output limit. Reduce the chunk size or check the model's max_tokens limit"));
            }
            var mergedMap = await TranslateChunkAsync(
                allCues, offset, half, startNumber, depth + 1, ct).ConfigureAwait(false);
            var second = await TranslateChunkAsync(
                allCues, offset + half, count - half, startNumber + half, depth + 1, ct).ConfigureAwait(false);
            foreach (var pair in second) mergedMap[pair.Key] = pair.Value;
            return mergedMap;
        }

        var map = ParseReply(reply.Text);
        var missing = Enumerable.Range(startNumber, count)
            .Count(n => !map.TryGetValue(n, out var v) || v.Length == 0);
        if (missing > count * 0.4)
        {
            throw VdlException.TranslateFailed(L10n.T("模型返回格式异常，缺失过多译文行",
                "Malformed model reply: too many translation lines are missing"));
        }
        return map;
    }

    /// <summary>字幕条内部换行折叠成 " / "，保证一条占一行。</summary>
    internal static string Flattened(string text) =>
        string.Join(" / ", text.Split('\n')
            .Select(l => l.Trim())
            .Where(l => l.Length > 0));

    /// <summary>把模型回复按行解析为 [编号: 译文]；不合规的行忽略。</summary>
    internal static Dictionary<int, string> ParseReply(string reply)
    {
        var map = new Dictionary<int, string>();
        foreach (var line in reply.Split('\n', '\r'))
        {
            if (line.Length == 0) continue;
            var separator = line.IndexOf('|');
            if (separator < 0) continue;
            if (!int.TryParse(line[..separator].Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var number)) continue;
            map[number] = line[(separator + 1)..].Trim();
        }
        return map;
    }
}
