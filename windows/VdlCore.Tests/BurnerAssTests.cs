using Vdl.Core;

namespace VdlCore.Tests;

public class AssGenerationTests
{
    private static SubtitleCue Cue(string text) =>
        new(1, "00:00:01,000", "00:00:02,500", text);

    [Fact]
    public void Header_DefaultAspect_UsesPlayRes512x288_AndChineseStyleSize15()
    {
        var ass = FFmpegBurner.MakeAss([Cue("你好")], fontName: FFmpegBurner.WindowsFontName);
        Assert.Contains("PlayResX: 512", ass);
        Assert.Contains("PlayResY: 288", ass);
        Assert.Contains($"Style: ZH,{FFmpegBurner.WindowsFontName},15,", ass);
        Assert.Contains(",2,61,61,20,1", ass);  // Alignment 2 + readable MarginL/R + MarginV 20
    }

    /// <summary>竖屏 9:16：坐标系收窄、字号边距整体缩小，双语小字号同步用 6。</summary>
    [Fact]
    public void Header_PortraitAspect_ShrinksLayoutAndSmallFont()
    {
        var ass = FFmpegBurner.MakeAss(
            [Cue("你好世界\nhello world")], aspect: 9.0 / 16.0, fontName: FFmpegBurner.WindowsFontName);
        Assert.Contains("PlayResX: 162", ass);
        Assert.Contains("PlayResY: 288", ass);
        Assert.Contains($"Style: ZH,{FFmpegBurner.WindowsFontName},8,", ass);
        Assert.Contains(",2,5,5,20,1", ass);
        Assert.Contains(@"你好世界\N{\fs6}hello world", ass);
    }

    /// <summary>竖屏下超长中文行在生成 ASS 时就预换行（部分 libass 只在空格断行）。</summary>
    [Fact]
    public void LongChineseLine_PreWrappedInPortraitDialogue()
    {
        var line = "那么，你想找一款能在Nintendo Switch 2上和朋友一起玩的派对游戏。让我";
        var ass = FFmpegBurner.MakeAss([Cue(line)], aspect: 9.0 / 16.0);
        Assert.Contains(@"那么，你想找一款能在Nintendo\NSwitch 2上和朋友一起\N玩的派对游戏。让我", ass);
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

public class AssLayoutTests
{
    /// <summary>竖屏 9:16：坐标系按比例收窄、字号按 sqrt 缩小、边距下限 5、预换行容量 19。</summary>
    [Fact]
    public void Portrait916_Layout()
    {
        var layout = new FFmpegBurner.AssLayout(9.0 / 16.0);
        Assert.Equal(162, layout.PlayResX);
        Assert.Equal(288, layout.PlayResY);
        Assert.Equal(8, layout.ChineseSize);
        Assert.Equal(6, layout.OriginalSize);
        Assert.Equal(5, layout.MarginH);
        Assert.Equal(20, layout.MarginV);
        Assert.Equal(19, layout.CjkWrapCapacity);
    }

    [Fact]
    public void Landscape169_Layout()
    {
        var layout = new FFmpegBurner.AssLayout(16.0 / 9.0);
        Assert.Equal(512, layout.PlayResX);
        Assert.Equal(15, layout.ChineseSize);
        Assert.Equal(11, layout.OriginalSize);
        Assert.Equal(61, layout.MarginH);
        Assert.Equal(26, layout.CjkWrapCapacity);
    }

    [Fact]
    public void Landscape169_LongChineseLine_PreWrappedForReadableWidth()
    {
        var ass = FFmpegBurner.MakeAss([
            new SubtitleCue(
                1,
                "00:00:01,000",
                "00:00:02,500",
                "今天，我会介绍如何使用Xcode中的一些强大新工具，在早期探索应用设计时快速尝试不同的界面方向。")
        ]);

        Assert.Contains(@"今天，我会介绍如何使用Xcode中的一些强大新工具，\N在早期探索应用设计时快速尝试不同的界面方向。", ass);
    }

    /// <summary>非法长宽比（0/NaN）回退 16:9；超宽封顶 4.0。</summary>
    [Fact]
    public void InvalidAspect_FallsBackTo169_UltraWideCapped()
    {
        foreach (var aspect in new[] { 0.0, double.NaN })
        {
            var layout = new FFmpegBurner.AssLayout(aspect);
            Assert.Equal(512, layout.PlayResX);
            Assert.Equal(15, layout.ChineseSize);
            Assert.Equal(61, layout.MarginH);
            Assert.Equal(26, layout.CjkWrapCapacity);
        }
        var ultraWide = new FFmpegBurner.AssLayout(10.0);
        Assert.Equal(1152, ultraWide.PlayResX);   // 288 × 4.0（封顶）
        Assert.Equal(15, ultraWide.ChineseSize);  // 横屏不缩字号
        Assert.Equal(351, ultraWide.MarginH);
        Assert.Equal(30, ultraWide.CjkWrapCapacity);
    }
}

public class WrapCjkLineTests
{
    /// <summary>均衡断行：42 字 ÷ 容量 19 → 3 行，且不切进 Nintendo/Switch 单词中间。</summary>
    [Fact]
    public void RealCaption_BalancedThreeLines_NoMidWordCut()
    {
        var wrapped = FFmpegBurner.WrapCjkLine(
            "那么，你想找一款能在Nintendo Switch 2上和朋友一起玩的派对游戏。让我", 19);
        Assert.Equal(
            new[] { "那么，你想找一款能在Nintendo", "Switch 2上和朋友一起", "玩的派对游戏。让我" },
            wrapped);
    }

    [Fact]
    public void ShortLine_NotWrapped() =>
        Assert.Equal(new[] { "你好世界" }, FFmpegBurner.WrapCjkLine("你好世界", 19));

    /// <summary>容量过小（&lt;6）不预换行，交还 libass。</summary>
    [Fact]
    public void TinyCapacity_NotWrapped()
    {
        var line = "这一行明显超过五个字的容量";
        Assert.Equal(new[] { line }, FFmpegBurner.WrapCjkLine(line, 5));
    }
}

public class BurnerParameterTests
{
    /// <summary>竖屏限宽 scale=W:-2，横屏限高 scale=-2:H；无缩放目标返回 null。</summary>
    [Fact]
    public void ScaleFilter_PortraitLimitsWidth_LandscapeLimitsHeight()
    {
        Assert.Equal("scale=1080:-2", FFmpegBurner.ScaleFilter(isPortrait: true, 1080));
        Assert.Equal("scale=-2:1080", FFmpegBurner.ScaleFilter(isPortrait: false, 1080));
        Assert.Null(FFmpegBurner.ScaleFilter(isPortrait: true, null));
    }

    /// <summary>短边：竖屏 1080×1920 视作 1080p——码率档位 6000（1080p），不是 16000（4K）。</summary>
    [Fact]
    public void ShortSide_PortraitVideo_DrivesTierByShortSide()
    {
        Assert.Equal(1080, FFmpegBurner.ShortSide(1080, 1920));
        Assert.Equal(1080, FFmpegBurner.ShortSide(1920, 1080));
        Assert.Equal(1080, FFmpegBurner.ShortSide(null, 1080));
        Assert.Equal(1080, FFmpegBurner.ShortSide(1080, null));
        Assert.Null(FFmpegBurner.ShortSide(null, null));
        Assert.Equal(6000, FFmpegBurner.MaxrateK(20_000_000, FFmpegBurner.ShortSide(1080, 1920), null));
    }

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
