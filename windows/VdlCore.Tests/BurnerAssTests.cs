using Vdl.Core;

namespace VdlCore.Tests;

public class AssGenerationTests
{
    private static SubtitleCue Cue(string text) =>
        new(1, "00:00:01,000", "00:00:02,500", text);

    [Fact]
    public void Header_UsesPlayRes288_AndChineseStyleSize15()
    {
        var ass = FFmpegBurner.MakeAss([Cue("你好")], fontName: FFmpegBurner.WindowsFontName);
        Assert.Contains("PlayResX: 384", ass);
        Assert.Contains("PlayResY: 288", ass);
        Assert.Contains($"Style: ZH,{FFmpegBurner.WindowsFontName},15,", ass);
    }

    [Fact]
    public void WindowsFontName_IsMicrosoftYaHei() =>
        Assert.Equal("Microsoft YaHei", FFmpegBurner.WindowsFontName);

    /// <summary>双语条目：中文行正常字号在上，原文行 {\fs11} 小字号在下。</summary>
    [Fact]
    public void BilingualCue_ChineseAboveWithSmallerOriginal()
    {
        var ass = FFmpegBurner.MakeAss([Cue("你好世界\nhello world")]);
        Assert.Contains(@"你好世界\N{\fs11}hello world", ass);
    }

    /// <summary>源文件里原文在上也重排为中文在上。</summary>
    [Fact]
    public void ReversedOrder_CjkLineStillOnTop()
    {
        var ass = FFmpegBurner.MakeAss([Cue("hello world\n你好世界")]);
        Assert.Contains(@"你好世界\N{\fs11}hello world", ass);
    }

    /// <summary>纯单语条目不加字号覆盖。</summary>
    [Fact]
    public void MonolingualCue_NoFontSizeOverride()
    {
        var ass = FFmpegBurner.MakeAss([Cue("plain english\nsecond line")]);
        Assert.Contains(@"plain english\Nsecond line", ass);
        Assert.DoesNotContain(@"{\fs11}", ass.Split("[Events]")[1]);
    }

    /// <summary>大括号与反斜杠转义为全角，避免被 libass 当样式块解析。</summary>
    [Fact]
    public void BracesAndBackslash_EscapedToFullWidth()
    {
        var ass = FFmpegBurner.MakeAss([Cue(@"{\an8}你好")]);
        Assert.Contains("｛＼an8｝你好", ass);
        Assert.DoesNotContain(@"{\an8}", ass);
    }

    [Fact]
    public void DialogueLine_TimestampsConverted()
    {
        var ass = FFmpegBurner.MakeAss([Cue("你好")]);
        Assert.Contains("Dialogue: 0,0:00:01.00,0:00:02.50,ZH,,0,0,0,,你好", ass);
    }

    [Fact]
    public void AssTimestamp_Conversion()
    {
        Assert.Equal("0:01:02.50", FFmpegBurner.AssTimestamp("00:01:02,500"));
        Assert.Equal("1:02:03.04", FFmpegBurner.AssTimestamp("01:02:03,045"));
        Assert.Equal("0:00:01.50", FFmpegBurner.AssTimestamp("00:00:01,5"));  // 右补零
        Assert.Null(FFmpegBurner.AssTimestamp("oops"));
        Assert.Null(FFmpegBurner.AssTimestamp("00:99:01,000"));  // 非法分钟
    }

    [Fact]
    public void InvalidTimestampCue_Skipped()
    {
        var ass = FFmpegBurner.MakeAss([new SubtitleCue(1, "bad", "worse", "text")]);
        Assert.DoesNotContain("Dialogue:", ass);
    }

    [Fact]
    public void ContainsCjk_CoversHanKanaHangul()
    {
        Assert.True(FFmpegBurner.ContainsCjk("你好"));
        Assert.True(FFmpegBurner.ContainsCjk("こんにちは"));
        Assert.True(FFmpegBurner.ContainsCjk("안녕"));
        Assert.False(FFmpegBurner.ContainsCjk("hello 123"));
    }
}

public class BurnerParameterTests
{
    [Fact]
    public void MaxrateK_NoScale_SourceBitrateTimesOnePointFive_CappedByTier()
    {
        // 4 Mbps 1080p 源：4000×1.5=6000，档位 6000 → 6000
        Assert.Equal(6000, FFmpegBurner.MaxrateK(4_000_000, 1080, null));
        // 2 Mbps 源：3000 < 6000 → 3000（不抬高低码率源）
        Assert.Equal(3000, FFmpegBurner.MaxrateK(2_000_000, 1080, null));
        // 缺源码率 → 档位上限
        Assert.Equal(16000, FFmpegBurner.MaxrateK(null, 2160, null));
        // 全缺 → 1080p 档默认
        Assert.Equal(6000, FFmpegBurner.MaxrateK(null, null, null));
    }

    [Fact]
    public void MaxrateK_Scaled_TierOfTargetHeight_MinWithSource()
    {
        // 4K 高码率源缩到 1080p：min(6000, 30000) = 6000
        Assert.Equal(6000, FFmpegBurner.MaxrateK(20_000_000, 2160, 1080));
        // 低码率 4K 源缩 1080p：min(6000, 1500) = 1500
        Assert.Equal(1500, FFmpegBurner.MaxrateK(1_000_000, 2160, 1080));
        // 缺源码率：目标档位
        Assert.Equal(6000, FFmpegBurner.MaxrateK(null, 2160, 1080));
    }

    [Fact]
    public void BitrateForHeight_Tiers()
    {
        Assert.Equal(16000, FFmpegBurner.BitrateForHeight(2160));
        Assert.Equal(10000, FFmpegBurner.BitrateForHeight(1440));
        Assert.Equal(6000, FFmpegBurner.BitrateForHeight(1080));
        Assert.Equal(3000, FFmpegBurner.BitrateForHeight(720));
        Assert.Equal(1500, FFmpegBurner.BitrateForHeight(480));
    }

    [Fact]
    public void ParseProgress_OutTimeMicroseconds()
    {
        Assert.Equal(0.5, FFmpegBurner.ParseProgress("out_time_ms=30000000", 60)!.Value, precision: 9);
        Assert.Equal(0.5, FFmpegBurner.ParseProgress("out_time_us=30000000", 60)!.Value, precision: 9);
        Assert.Equal(1.0, FFmpegBurner.ParseProgress("out_time_ms=999000000", 60)!.Value, precision: 9);  // 上限 1
        Assert.Null(FFmpegBurner.ParseProgress("frame=12", 60));
        Assert.Null(FFmpegBurner.ParseProgress("out_time_ms=1", null));  // 无总时长
    }

    [Fact]
    public void LastLine_TrimsAndTruncates()
    {
        Assert.Equal("real error", FFmpegBurner.LastLine("info\nreal error\n  \n"));
        Assert.Equal("未知错误", FFmpegBurner.LastLine(""));
    }
}
