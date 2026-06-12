using Vdl.Core;

namespace VdlCore.Tests;

public class SanitizedFolderNameTests
{
    [Fact]
    public void PathSeparators_BecomeSpaces() =>
        Assert.Equal("a b c d", DownloadPaths.SanitizedFolderName("a/b\\c:d"));

    [Fact]
    public void WindowsForbiddenChars_Removed()
    {
        var name = DownloadPaths.SanitizedFolderName("Tips <Best?> *Ever* \"quoted\" x|y");
        foreach (var forbidden in "<>:\"|?*\\/")
        {
            Assert.DoesNotContain(forbidden, name);
        }
        Assert.StartsWith("Tips", name);
    }

    [Fact]
    public void Newlines_BecomeSpaces() =>
        Assert.Equal("line1 line2", DownloadPaths.SanitizedFolderName("line1\nline2"));

    [Fact]
    public void LongTitle_TruncatedTo80()
    {
        var name = DownloadPaths.SanitizedFolderName(new string('x', 100));
        Assert.Equal(80, name.Length);
    }

    [Fact]
    public void TrailingDots_Removed() =>
        Assert.Equal("name", DownloadPaths.SanitizedFolderName("name..."));

    [Fact]
    public void EmptyResult_FallsBackToDefault()
    {
        Assert.Equal("视频", DownloadPaths.SanitizedFolderName("///"));
        Assert.Equal("视频", DownloadPaths.SanitizedFolderName("..."));
        Assert.Equal("视频", DownloadPaths.SanitizedFolderName("   "));
    }

    [Fact]
    public void ChineseTitle_Preserved() =>
        Assert.Equal("任天堂直面会 2026", DownloadPaths.SanitizedFolderName("任天堂直面会 2026"));
}

public class DestinationDirectoryTests
{
    [Fact]
    public void SingleFile_GoesToDownloadsRoot()
    {
        var root = Path.Combine(Path.GetTempPath(), "DownloadsRoot");
        Assert.Equal(root, DownloadPaths.DestinationDirectory("My Video", multiFile: false, root));
    }

    /// <summary>多文件（选了字幕或开了中文模式）→ 按净化标题建子文件夹。</summary>
    [Fact]
    public void MultiFile_GoesToSanitizedSubfolder()
    {
        var root = Path.Combine(Path.GetTempPath(), "DownloadsRoot");
        // 与 Swift components-join 行为一致：":" 替换为空格（"My: Video" → "My  Video"）
        Assert.Equal(
            Path.Combine(root, "My  Video"),
            DownloadPaths.DestinationDirectory("My: Video", multiFile: true, root));
    }

    [Fact]
    public void DownloadsDirectory_EndsWithDownloads()
    {
        var dir = DownloadPaths.DownloadsDirectory();
        Assert.EndsWith("Downloads", dir);
    }
}
