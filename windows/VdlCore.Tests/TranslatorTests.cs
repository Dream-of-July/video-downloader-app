using System.Net;
using System.Text;
using System.Text.Json;
using Vdl.Core;

namespace VdlCore.Tests;

/// <summary>记录请求形状并按脚本应答的 fake handler（不发真网络请求）。</summary>
internal sealed class FakeHttpHandler : HttpMessageHandler
{
    internal sealed record CapturedRequest(
        HttpMethod Method, Uri Uri, Dictionary<string, string> Headers, string Body);

    private readonly object _lock = new();
    public List<CapturedRequest> Requests { get; } = [];
    /// <summary>按捕获的请求生成响应；默认 200 空对象。</summary>
    public Func<CapturedRequest, HttpResponseMessage> Responder { get; set; } =
        _ => Json(200, "{}");

    public static HttpResponseMessage Json(int status, string body) => new((HttpStatusCode)status)
    {
        Content = new StringContent(body, Encoding.UTF8, "application/json"),
    };

    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var body = request.Content is null
            ? ""
            : await request.Content.ReadAsStringAsync(cancellationToken);
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var header in request.Headers)
        {
            headers[header.Key] = string.Join(",", header.Value);
        }
        var captured = new CapturedRequest(request.Method, request.RequestUri!, headers, body);
        lock (_lock) Requests.Add(captured);
        return Responder(captured);
    }
}

public class TranslationApiTests
{
    private static AppSettings GatewaySettings(TranslationProvider provider = TranslationProvider.Anthropic) => new()
    {
        TranslationProvider = provider,
        TranslationBaseUrl = "https://gateway.example.com",
        TranslationModel = "test-model",
        TranslationAuthToken = "secret-token",
    };

    private static string AnthropicReply(string text, string stopReason = "end_turn") =>
        JsonSerializer.Serialize(new
        {
            content = new[] { new { type = "text", text } },
            stop_reason = stopReason,
        });

    [Fact]
    public async Task Anthropic_Gateway_SendsBothAuthHeaders()
    {
        var handler = new FakeHttpHandler
        {
            Responder = _ => FakeHttpHandler.Json(200, AnthropicReply("ok")),
        };
        var reply = await TranslationApi.SendAnthropicMessageAsync(
            GatewaySettings(), "sys", "1|hello", 100, handler, CancellationToken.None);

        Assert.Equal("ok", reply.Text);
        Assert.False(reply.ReachedOutputLimit);
        var request = Assert.Single(handler.Requests);
        Assert.Equal("https://gateway.example.com/v1/messages", request.Uri.ToString());
        Assert.Equal("secret-token", request.Headers["x-api-key"]);
        Assert.Equal("Bearer secret-token", request.Headers["Authorization"]);
        Assert.Equal("2023-06-01", request.Headers["anthropic-version"]);
        // 请求体形状
        using var doc = JsonDocument.Parse(request.Body);
        Assert.Equal("test-model", doc.RootElement.GetProperty("model").GetString());
        Assert.Equal(100, doc.RootElement.GetProperty("max_tokens").GetInt32());
        Assert.Equal("sys", doc.RootElement.GetProperty("system").GetString());
        Assert.Equal("1|hello", doc.RootElement.GetProperty("messages")[0].GetProperty("content").GetString());
    }

    /// <summary>官方 api.anthropic.com 只发 x-api-key（双头会被拒）。</summary>
    [Fact]
    public async Task Anthropic_OfficialHost_OmitsAuthorizationHeader()
    {
        var handler = new FakeHttpHandler
        {
            Responder = _ => FakeHttpHandler.Json(200, AnthropicReply("ok")),
        };
        var settings = GatewaySettings() with { TranslationBaseUrl = "https://api.anthropic.com" };
        await TranslationApi.SendAnthropicMessageAsync(
            settings, null, "hi", 100, handler, CancellationToken.None);

        var request = Assert.Single(handler.Requests);
        Assert.Equal("secret-token", request.Headers["x-api-key"]);
        Assert.False(request.Headers.ContainsKey("Authorization"));
    }

    /// <summary>凭证里误带 "Bearer " 前缀时剥掉，避免双重 Bearer。</summary>
    [Fact]
    public async Task TokenNormalization_StripsBearerPrefix()
    {
        var handler = new FakeHttpHandler
        {
            Responder = _ => FakeHttpHandler.Json(200, AnthropicReply("ok")),
        };
        var settings = GatewaySettings() with { TranslationAuthToken = "  Bearer secret-token  " };
        await TranslationApi.SendAnthropicMessageAsync(
            settings, null, "hi", 100, handler, CancellationToken.None);

        var request = Assert.Single(handler.Requests);
        Assert.Equal("secret-token", request.Headers["x-api-key"]);
        Assert.Equal("Bearer secret-token", request.Headers["Authorization"]);
    }

    [Fact]
    public async Task OpenAi_PostsToResponsesEndpoint_AndJoinsOutputText()
    {
        var responseBody = JsonSerializer.Serialize(new
        {
            output = new object[]
            {
                new { type = "reasoning", content = Array.Empty<object>() },
                new
                {
                    type = "message",
                    content = new object[]
                    {
                        new { type = "output_text", text = "1|你" },
                        new { type = "text", text = "好" },
                    },
                },
            },
            status = "completed",
        });
        var handler = new FakeHttpHandler { Responder = _ => FakeHttpHandler.Json(200, responseBody) };
        var reply = await TranslationApi.SendOpenAiResponseAsync(
            GatewaySettings(TranslationProvider.Openai), "inst", "1|hi", 256, handler, CancellationToken.None);

        Assert.Equal("1|你好", reply.Text);
        Assert.False(reply.ReachedOutputLimit);
        var request = Assert.Single(handler.Requests);
        Assert.Equal("https://gateway.example.com/v1/responses", request.Uri.ToString());
        Assert.Equal("Bearer secret-token", request.Headers["Authorization"]);
        using var doc = JsonDocument.Parse(request.Body);
        Assert.Equal(256, doc.RootElement.GetProperty("max_output_tokens").GetInt32());
        Assert.False(doc.RootElement.GetProperty("store").GetBoolean());
        Assert.Equal("inst", doc.RootElement.GetProperty("instructions").GetString());
    }

    [Fact]
    public async Task OpenAi_IncompleteMaxOutputTokens_FlagsOutputLimit()
    {
        var responseBody = JsonSerializer.Serialize(new
        {
            output = new object[]
            {
                new
                {
                    type = "message",
                    content = new object[] { new { type = "output_text", text = "partial" } },
                },
            },
            status = "incomplete",
            incomplete_details = new { reason = "max_output_tokens" },
        });
        var handler = new FakeHttpHandler { Responder = _ => FakeHttpHandler.Json(200, responseBody) };
        var reply = await TranslationApi.SendOpenAiResponseAsync(
            GatewaySettings(TranslationProvider.Openai), null, "x", 16, handler, CancellationToken.None);
        Assert.True(reply.ReachedOutputLimit);
    }

    [Fact]
    public void EndpointUrl_HandlesTrailingSlashAndV1Suffix()
    {
        Assert.Equal("https://a.com/v1/messages",
            TranslationApi.EndpointUrl("https://a.com/", "/v1/messages").ToString());
        Assert.Equal("https://a.com/v1/messages",
            TranslationApi.EndpointUrl("https://a.com/v1", "/v1/messages").ToString());
        Assert.Equal("https://a.com/v1/messages",
            TranslationApi.EndpointUrl("https://a.com/v1/messages", "/v1/messages").ToString());
        Assert.Throws<VdlException>(() => TranslationApi.EndpointUrl("not a url", "/v1/messages"));
    }

    [Fact]
    public async Task ListModels_AppendsLimitQuery_AndParsesIds()
    {
        var handler = new FakeHttpHandler
        {
            Responder = _ => FakeHttpHandler.Json(200,
                """{"data":[{"id":"m1"},{"id":"m2"},{"id":"m1"},{"id":""}]}"""),
        };
        var models = await TranslationApi.ListModelsAsync(GatewaySettings(), handler);

        Assert.Equal(["m1", "m2"], models);
        var request = Assert.Single(handler.Requests);
        Assert.Equal(HttpMethod.Get, request.Method);
        Assert.Equal("https://gateway.example.com/v1/models?limit=1000", request.Uri.ToString());
        Assert.Equal("secret-token", request.Headers["x-api-key"]);
        Assert.Equal("Bearer secret-token", request.Headers["Authorization"]);
    }

    [Fact]
    public async Task ListModels_OfficialAnthropic_OmitsAuthorization()
    {
        var handler = new FakeHttpHandler
        {
            Responder = _ => FakeHttpHandler.Json(200, """{"data":[{"id":"claude-x"}]}"""),
        };
        var settings = GatewaySettings() with { TranslationBaseUrl = "https://api.anthropic.com" };
        await TranslationApi.ListModelsAsync(settings, handler);
        var request = Assert.Single(handler.Requests);
        Assert.False(request.Headers.ContainsKey("Authorization"));
    }

    [Fact]
    public void ParseModelIds_ToleratesVariousShapes()
    {
        Assert.Equal(["a", "b"], TranslationApi.ParseModelIds("""{"data":["a","b"]}"""));
        Assert.Equal(["a"], TranslationApi.ParseModelIds("""{"models":[{"name":"a"}]}"""));
        Assert.Equal(["a"], TranslationApi.ParseModelIds("""[{"model":"a"}]"""));
        Assert.Empty(TranslationApi.ParseModelIds("not json"));
    }

    [Fact]
    public async Task TestConnection_SendsMiniMessageWith1024Tokens()
    {
        var handler = new FakeHttpHandler
        {
            Responder = _ => FakeHttpHandler.Json(200, AnthropicReply("  正常  ")),
        };
        var text = await TranslationApi.TestConnectionAsync(GatewaySettings(), handler);
        Assert.Equal("正常", text);
        var request = Assert.Single(handler.Requests);
        using var doc = JsonDocument.Parse(request.Body);
        Assert.Equal(1024, doc.RootElement.GetProperty("max_tokens").GetInt32());
        Assert.Equal("请只回复两个字：正常", doc.RootElement.GetProperty("messages")[0].GetProperty("content").GetString());
    }

    [Fact]
    public void RequestFailureMessage_503_GivesGatewayHint()
    {
        var message = TranslationApi.RequestFailureMessage(
            503, """{"error":{"message":"no available accounts"}}""", GatewaySettings());
        Assert.Contains("网关没有可用账号或模型映射未命中", message);
        Assert.Contains("test-model", message);

        var plain = TranslationApi.RequestFailureMessage(401, """{"error":{"message":"bad key"}}""", GatewaySettings());
        Assert.Equal("HTTP 401：bad key", plain);
    }

    [Fact]
    public async Task MissingModelOrToken_ThrowsActionableError()
    {
        var noModel = GatewaySettings() with { TranslationModel = " " };
        var ex1 = await Assert.ThrowsAsync<VdlException>(() =>
            TranslationApi.SendAnthropicMessageAsync(noModel, null, "x", 16, new FakeHttpHandler(), CancellationToken.None));
        Assert.Contains("尚未配置模型", ex1.Detail);

        var noToken = GatewaySettings() with { TranslationAuthToken = "" };
        var ex2 = await Assert.ThrowsAsync<VdlException>(() =>
            TranslationApi.SendAnthropicMessageAsync(noToken, null, "x", 16, new FakeHttpHandler(), CancellationToken.None));
        Assert.Contains("尚未配置 API 凭证", ex2.Detail);
    }
}

public class ConfiguredTranslatorTests : IDisposable
{
    private readonly string _tempDir;

    public ConfiguredTranslatorTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), $"vdl-test-{Guid.NewGuid():N}");
        Directory.CreateDirectory(_tempDir);
    }

    public void Dispose()
    {
        try { Directory.Delete(_tempDir, true); } catch { /* 忽略 */ }
    }

    private static AppSettings Settings => new()
    {
        TranslationProvider = TranslationProvider.Anthropic,
        TranslationBaseUrl = "https://gateway.example.com",
        TranslationModel = "test-model",
        TranslationAuthToken = "tok",
    };

    private string WriteSrt(string name, IEnumerable<SubtitleCue> cues)
    {
        var path = Path.Combine(_tempDir, name);
        File.WriteAllText(path, SrtTools.SerializeSrt(cues));
        return path;
    }

    /// <summary>从请求体里取出 user content（messages[0].content），按行回贴 "N|中N"。</summary>
    private static string TranslateAllLines(string requestBody)
    {
        using var doc = JsonDocument.Parse(requestBody);
        var content = doc.RootElement.GetProperty("messages")[0].GetProperty("content").GetString()!;
        var replyLines = content.Split('\n').Select(line =>
        {
            var number = line.Split('|')[0];
            return $"{number}|中{number}";
        });
        return string.Join("\n", replyLines);
    }

    private static string AnthropicReply(string text, string stopReason = "end_turn") =>
        JsonSerializer.Serialize(new
        {
            content = new[] { new { type = "text", text } },
            stop_reason = stopReason,
        });

    [Fact]
    public async Task Translate_Bilingual_ChineseAboveOriginal_WritesZhSrt()
    {
        var srt = WriteSrt("video.en.srt",
        [
            new SubtitleCue(1, "00:00:01,000", "00:00:02,000", "Hello there."),
            new SubtitleCue(2, "00:00:03,000", "00:00:04,000", "Bye now."),
        ]);
        var handler = new FakeHttpHandler
        {
            Responder = captured => FakeHttpHandler.Json(200, AnthropicReply(TranslateAllLines(captured.Body))),
        };
        var translator = new ConfiguredTranslator(Settings, handler);
        var output = await translator.TranslateAsync(srt, SubtitleStyle.Bilingual, null, _ => { });

        Assert.Equal(Path.Combine(_tempDir, "video.en.zh.srt"), output);
        var cues = SrtTools.ParseSrt(File.ReadAllText(output));
        Assert.Equal(2, cues.Count);
        Assert.Equal("中1\nHello there.", cues[0].Text);  // 双语：中文在上、原文在下
        Assert.Equal("中2\nBye now.", cues[1].Text);
    }

    [Fact]
    public async Task Translate_ChineseOnly_ReplacesText()
    {
        var srt = WriteSrt("v.srt",
        [
            new SubtitleCue(1, "00:00:01,000", "00:00:02,000", "Hello."),
        ]);
        var handler = new FakeHttpHandler
        {
            Responder = captured => FakeHttpHandler.Json(200, AnthropicReply(TranslateAllLines(captured.Body))),
        };
        var translator = new ConfiguredTranslator(Settings, handler);
        var output = await translator.TranslateAsync(srt, SubtitleStyle.ChineseOnly, null, _ => { });

        var cues = SrtTools.ParseSrt(File.ReadAllText(output));
        Assert.Equal("中1", Assert.Single(cues).Text);
    }

    /// <summary>译文被输出上限截断 → 30 条块减半成 15+15 重试；最终全部翻完。</summary>
    [Fact]
    public async Task Translate_TruncatedChunk_RetriesWithHalvedChunks()
    {
        var cues = Enumerable.Range(1, 40).Select(i => new SubtitleCue(
            i, SrtTools.SecondsToSrtTime(i * 10), SrtTools.SecondsToSrtTime(i * 10 + 2), $"Sentence {i}."));
        var srt = WriteSrt("long.srt", cues);

        var handler = new FakeHttpHandler();
        handler.Responder = captured =>
        {
            using var doc = JsonDocument.Parse(captured.Body);
            var content = doc.RootElement.GetProperty("messages")[0].GetProperty("content").GetString()!;
            var lineCount = content.Split('\n').Length;
            // 30 条的大块：模拟输出截断（stop_reason=max_tokens）；其余正常回贴
            return lineCount == 30
                ? FakeHttpHandler.Json(200, AnthropicReply("1|不完整", "max_tokens"))
                : FakeHttpHandler.Json(200, AnthropicReply(TranslateAllLines(captured.Body)));
        };
        var translator = new ConfiguredTranslator(Settings, handler);
        var progressValues = new List<double>();
        var progressLock = new object();
        var output = await translator.TranslateAsync(srt, SubtitleStyle.ChineseOnly, null,
            p => { lock (progressLock) progressValues.Add(p); });

        // 请求：30 条块 ×1（截断）→ 15 条块 ×2 + 10 条块 ×1 = 4 次
        Assert.Equal(4, handler.Requests.Count);
        var result = SrtTools.ParseSrt(File.ReadAllText(output));
        Assert.Equal(40, result.Count);
        for (var i = 0; i < 40; i++)
        {
            Assert.Equal($"中{i + 1}", result[i].Text);
        }
        lock (progressLock)
        {
            Assert.Equal(1.0, progressValues[^1], precision: 9);
        }
    }

    /// <summary>译文缺失行数 &gt;40% → 抛错而不是静默保留原文。</summary>
    [Fact]
    public async Task Translate_TooManyMissingLines_Throws()
    {
        var cues = Enumerable.Range(1, 10).Select(i => new SubtitleCue(
            i, SrtTools.SecondsToSrtTime(i * 10), SrtTools.SecondsToSrtTime(i * 10 + 2), $"Sentence {i}."));
        var srt = WriteSrt("missing.srt", cues);
        var handler = new FakeHttpHandler
        {
            // 只回 1-5 行（缺 50% > 40%）
            Responder = _ => FakeHttpHandler.Json(200,
                AnthropicReply(string.Join("\n", Enumerable.Range(1, 5).Select(i => $"{i}|中{i}")))),
        };
        var translator = new ConfiguredTranslator(Settings, handler);
        var ex = await Assert.ThrowsAsync<VdlException>(() =>
            translator.TranslateAsync(srt, SubtitleStyle.ChineseOnly, null, _ => { }));
        Assert.Equal(VdlErrorKind.TranslateFailed, ex.Kind);
        Assert.Equal("模型返回格式异常，缺失过多译文行", ex.Detail);
    }

    /// <summary>某条缺失（≤40%）时保留原文，不报错。</summary>
    [Fact]
    public async Task Translate_FewMissingLines_KeepsOriginalText()
    {
        var srt = WriteSrt("few.srt",
        [
            new SubtitleCue(1, "00:00:01,000", "00:00:02,000", "One."),
            new SubtitleCue(2, "00:00:03,000", "00:00:04,000", "Two."),
            new SubtitleCue(3, "00:00:05,000", "00:00:06,000", "Three."),
        ]);
        var handler = new FakeHttpHandler
        {
            Responder = _ => FakeHttpHandler.Json(200, AnthropicReply("1|一\n3|三")),  // 缺第 2 条（33% ≤ 40%）
        };
        var translator = new ConfiguredTranslator(Settings, handler);
        var output = await translator.TranslateAsync(srt, SubtitleStyle.ChineseOnly, null, _ => { });
        var cues = SrtTools.ParseSrt(File.ReadAllText(output));
        Assert.Equal("一", cues[0].Text);
        Assert.Equal("Two.", cues[1].Text);  // 缺失 → 保留原文
        Assert.Equal("三", cues[2].Text);
    }

    [Fact]
    public void ParseReply_IgnoresMalformedLines()
    {
        var map = ConfiguredTranslator.ParseReply("1|你好\nnoise\n2| 世界 \nx|bad\n3|");
        Assert.Equal("你好", map[1]);
        Assert.Equal("世界", map[2]);
        Assert.Equal("", map[3]);
        Assert.Equal(3, map.Count);
    }

    [Fact]
    public void Flattened_JoinsLinesWithSlash()
    {
        Assert.Equal("a / b", ConfiguredTranslator.Flattened(" a \n\n b "));
    }
}
