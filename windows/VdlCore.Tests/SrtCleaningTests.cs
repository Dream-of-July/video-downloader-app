using Vdl.Core;

namespace VdlCore.Tests;

public class SrtParsingTests
{
    [Fact]
    public void ParseSrt_NormalFile_ParsesAllFields()
    {
        const string srt = """
            1
            00:00:01,000 --> 00:00:02,500
            First line.

            2
            00:00:03,000 --> 00:00:04,500
            Second line
            continued.
            """;
        var cues = SrtTools.ParseSrt(srt);
        Assert.Equal(2, cues.Count);
        Assert.Equal(1, cues[0].Index);
        Assert.Equal("00:00:01,000", cues[0].Start);
        Assert.Equal("00:00:02,500", cues[0].End);
        Assert.Equal("First line.", cues[0].Text);
        Assert.Equal("Second line\ncontinued.", cues[1].Text);
    }

    [Fact]
    public void ParseSrt_BomCrlfAndDotMilliseconds_Tolerated()
    {
        var srt = "﻿1\r\n00:00:01.000 --> 00:00:02.000\r\nhello\r\n";
        var cues = SrtTools.ParseSrt(srt);
        Assert.Single(cues);
        Assert.Equal("00:00:01.000", cues[0].Start);
        Assert.Equal("hello", cues[0].Text);
    }

    [Fact]
    public void ParseSrt_MissingIndexLines_AutoNumbers()
    {
        const string srt = """
            00:00:01,000 --> 00:00:02,000
            a

            00:00:03,000 --> 00:00:04,000
            b
            """;
        var cues = SrtTools.ParseSrt(srt);
        Assert.Equal(2, cues.Count);
        Assert.Equal(1, cues[0].Index);
        Assert.Equal(2, cues[1].Index);
    }

    [Fact]
    public void ParseSrt_EmptyTextEntry_Dropped()
    {
        const string srt = """
            1
            00:00:01,000 --> 00:00:02,000

            2
            00:00:03,000 --> 00:00:04,000
            real text
            """;
        var cues = SrtTools.ParseSrt(srt);
        Assert.Single(cues);
        Assert.Equal(2, cues[0].Index);
        Assert.Equal("real text", cues[0].Text);
    }

    /// <summary>样式 B 关键回归：时间行锚定切条，条目里夹空行不丢后续内容。</summary>
    [Fact]
    public void ParseSrt_RollingStyleB_BlankLinesInsideEntries_NoContentLost()
    {
        var cues = SrtTools.ParseSrt(StyleBSample);
        Assert.Equal(5, cues.Count);
        Assert.Equal("hey everyone welcome back to the channel", cues[1].Text);
        Assert.Equal("hey everyone welcome back to the channel\ntoday we are looking at the new device", cues[2].Text);
        Assert.Equal("today we are looking at the new device\nit is really impressive.", cues[4].Text);
    }

    /// <summary>
    /// 真实 YouTube 滚动字幕样式 B 形态：两行滚动窗口（每条首行重复上一条尾行）、
    /// 10ms 过渡条、条目文本中夹空白行、时间戳首尾相接（不重叠）。
    /// </summary>
    internal const string StyleBSample =
        "1\n" +
        "00:00:00,080 --> 00:00:02,389\n" +
        "hey everyone welcome back to the channel\n" +
        "\n" +
        "2\n" +
        "00:00:02,389 --> 00:00:02,399\n" +
        "hey everyone welcome back to the channel\n" +
        " \n" +
        "\n" +
        "3\n" +
        "00:00:02,399 --> 00:00:04,830\n" +
        "hey everyone welcome back to the channel\n" +
        "today we are looking at the new device\n" +
        "\n" +
        "4\n" +
        "00:00:04,830 --> 00:00:04,840\n" +
        "today we are looking at the new device\n" +
        " \n" +
        "\n" +
        "5\n" +
        "00:00:04,840 --> 00:00:07,160\n" +
        "today we are looking at the new device\n" +
        "it is really impressive.\n";
}

public class CleanCuesTests
{
    private static SubtitleCue Cue(int index, string start, string end, string text) =>
        new(index, start, end, text);

    /// <summary>样式 A：时间戳大面积重叠的碎句 → 去重叠 + 按句合并。</summary>
    [Fact]
    public void CleanCues_StyleA_OverlappingFragments_MergedIntoSentence()
    {
        var input = new List<SubtitleCue>
        {
            Cue(1, "00:00:01,000", "00:00:04,000", "so this is"),
            Cue(2, "00:00:02,000", "00:00:06,000", "the first sentence"),
            Cue(3, "00:00:03,500", "00:00:08,000", "we ever wrote."),
        };
        var cleaned = SrtTools.CleanCues(input);
        var cue = Assert.Single(cleaned);
        Assert.Equal("so this is the first sentence we ever wrote.", cue.Text);
        Assert.Equal("00:00:01,000", cue.Start);
        Assert.Equal("00:00:08,000", cue.End);
    }

    /// <summary>样式 B：文本重复 + 时间戳相接 → 行级去重、丢纯过渡条、按句合并。</summary>
    [Fact]
    public void CleanCues_StyleB_TextRepeats_DedupedAndMerged()
    {
        var parsed = SrtTools.ParseSrt(SrtParsingTests.StyleBSample);
        var cleaned = SrtTools.CleanCues(parsed);
        var cue = Assert.Single(cleaned);
        Assert.Equal(
            "hey everyone welcome back to the channel today we are looking at the new device it is really impressive.",
            cue.Text);
        Assert.Equal("00:00:00,080", cue.Start);
        Assert.Equal("00:00:07,160", cue.End);
    }

    /// <summary>正常字幕 1:1 不变（不滚动 → 不合并、不改时间）。</summary>
    [Fact]
    public void CleanCues_NormalFile_Unchanged()
    {
        var input = new List<SubtitleCue>
        {
            Cue(1, "00:00:01,000", "00:00:02,500", "First line."),
            Cue(2, "00:00:03,000", "00:00:04,500", "Second line."),
            Cue(3, "00:00:05,000", "00:00:06,500", "第三句。"),
        };
        var cleaned = SrtTools.CleanCues(input);
        Assert.Equal(3, cleaned.Count);
        for (var i = 0; i < 3; i++)
        {
            Assert.Equal(input[i].Index, cleaned[i].Index);
            Assert.Equal(input[i].Start, cleaned[i].Start);
            Assert.Equal(input[i].End, cleaned[i].End);
            Assert.Equal(input[i].Text, cleaned[i].Text);
        }
    }

    /// <summary>句合并断点：累积 ≥6s 也会断句（即便没有句末标点）。</summary>
    [Fact]
    public void CleanCues_MergeBreaksAtSixSeconds()
    {
        var input = new List<SubtitleCue>
        {
            Cue(1, "00:00:00,000", "00:00:03,000", "alpha beta"),
            Cue(2, "00:00:02,000", "00:00:07,000", "gamma delta"),
            Cue(3, "00:00:06,500", "00:00:09,000", "epsilon zeta"),
        };
        var cleaned = SrtTools.CleanCues(input);
        Assert.Equal(2, cleaned.Count);
        Assert.Equal("alpha beta gamma delta", cleaned[0].Text);
        Assert.Equal("00:00:00,000", cleaned[0].Start);
        Assert.Equal("00:00:06,500", cleaned[0].End);
        Assert.Equal("epsilon zeta", cleaned[1].Text);
    }

    /// <summary>句合并断点：累积 ≥84 字符也会断句。</summary>
    [Fact]
    public void CleanCues_MergeBreaksAtCharacterBudget()
    {
        // 三条无标点碎句，前两条合计 84+ 字符 → 在第二条后断句
        var long1 = new string('a', 50);
        var long2 = new string('b', 40);
        var input = new List<SubtitleCue>
        {
            Cue(1, "00:00:00,000", "00:00:02,000", long1),
            Cue(2, "00:00:01,500", "00:00:03,500", long2),
            Cue(3, "00:00:03,000", "00:00:05,000", "tail"),
        };
        var cleaned = SrtTools.CleanCues(input);
        Assert.Equal(2, cleaned.Count);
        Assert.Equal(long1 + " " + long2, cleaned[0].Text);
        Assert.Equal("tail", cleaned[1].Text);
    }

    /// <summary>去重叠：end 截到下一条 start；截剩过短补到 0.3s 但不越下一条 start。</summary>
    [Fact]
    public void CleanCues_DeoverlapClampsEndToNextStart()
    {
        // 重叠率 1/2 = 50% 不算滚动（>50% 才算）→ 只去重叠
        var input = new List<SubtitleCue>
        {
            Cue(1, "00:00:01,000", "00:00:05,000", "one"),
            Cue(2, "00:00:02,000", "00:00:03,000", "two."),
            Cue(3, "00:00:10,000", "00:00:11,000", "three."),
        };
        var cleaned = SrtTools.CleanCues(input);
        Assert.Equal(3, cleaned.Count);
        Assert.Equal("00:00:02,000", cleaned[0].End);  // 截到下一条 start
        Assert.Equal("one", cleaned[0].Text);          // 没有按句合并
    }

    /// <summary>防误判守卫：歌词等少量重复不触发滚动清洗（重复率 ≤30%）。</summary>
    [Fact]
    public void CleanCues_LowRepeatRatio_NotTreatedAsRolling()
    {
        var input = new List<SubtitleCue>
        {
            Cue(1, "00:00:01,000", "00:00:02,000", "la la la"),
            Cue(2, "00:00:03,000", "00:00:04,000", "la la la"),  // 整条重复（1 对）
            Cue(3, "00:00:05,000", "00:00:06,000", "different"),
            Cue(4, "00:00:07,000", "00:00:08,000", "lines"),
        };
        // 重复对 1/3 = 33% > 30%？是 — 调整为 1/4 对：再加一条
        input.Add(Cue(5, "00:00:09,000", "00:00:10,000", "ending"));
        // 1/4 = 25% ≤ 30% → 不滚动，5 条原样保留
        var cleaned = SrtTools.CleanCues(input);
        Assert.Equal(5, cleaned.Count);
        Assert.Equal("la la la", cleaned[1].Text);
    }

    [Fact]
    public void SrtTimeRoundTrip()
    {
        Assert.Equal(3723.5, SrtTools.SrtTimeToSeconds("01:02:03,500"));
        Assert.Equal(3723.5, SrtTools.SrtTimeToSeconds("01:02:03.500"));
        Assert.Null(SrtTools.SrtTimeToSeconds("oops"));
        Assert.Equal("01:02:03,500", SrtTools.SecondsToSrtTime(3723.5));
        Assert.Equal("00:00:00,000", SrtTools.SecondsToSrtTime(-1));
    }

    [Fact]
    public void SerializeSrt_RoundTripsThroughParse()
    {
        var cues = new List<SubtitleCue>
        {
            Cue(1, "00:00:01,000", "00:00:02,000", "hello\nworld"),
            Cue(2, "00:00:03,000", "00:00:04,000", "again"),
        };
        var text = SrtTools.SerializeSrt(cues);
        var reparsed = SrtTools.ParseSrt(text);
        Assert.Equal(2, reparsed.Count);
        Assert.Equal("hello\nworld", reparsed[0].Text);
    }
}
