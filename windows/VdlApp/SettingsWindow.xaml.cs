using System.IO;
using System.Windows;
using Vdl.Core;

namespace Vdl.App;

/// <summary>
/// 设置窗口（模态，草稿模式）：点「完成」才保存；取消 / Esc 不落任何修改。
/// 并发数改动实时生效，关窗时统一回滚/确认为磁盘值（对齐 macOS onDisappear 行为）。
/// </summary>
public partial class SettingsWindow : Window
{
    private readonly MainViewModel _main;
    private readonly SettingsViewModel _vm;

    /// <summary>点了「登录 ××」关窗后由主窗口接力弹出登录窗（值为站点 host）。</summary>
    public string? PendingLoginSite { get; private set; }

    public SettingsWindow(MainViewModel main)
    {
        _main = main;
        _vm = new SettingsViewModel(main.Settings, main.Queue, main.ConsumePendingSettingsNotice());
        DataContext = _vm;
        InitializeComponent();
        // PasswordBox 不支持数据绑定，初值与变更都走代码同步。
        TokenBox.Password = _vm.AuthToken;
        Closed += (_, _) =>
        {
            _vm.CancelOperations();
            // 未保存的并发数改动回滚为磁盘值；已保存时等价于当前值，无副作用。
            _main.Settings = AppSettings.Load();
        };
    }

    private void OnTokenChanged(object sender, RoutedEventArgs e)
    {
        _vm.AuthToken = TokenBox.Password;
    }

    private void OnCancelClick(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
    }

    private void OnDoneClick(object sender, RoutedEventArgs e)
    {
        if (_vm.TrySave(out var error))
        {
            var saved = _vm.BuildSettings();
            _main.Settings = saved;
            // 界面语言点「完成」后生效（XAML 文案即时换装，代码侧派生文案随事件重算）。
            LocalizationManager.Apply(saved.AppLanguage);
            DialogResult = true;
        }
        else
        {
            _vm.Notice = Loc.F("L.Settings.SaveFailedFmt", error ?? "");
        }
    }

    // MARK: - 站点登录

    private void OnLoginYouTubeClick(object sender, RoutedEventArgs e) => RequestLogin("youtube.com");

    private void OnLoginBilibiliClick(object sender, RoutedEventArgs e) => RequestLogin("bilibili.com");

    /// <summary>点「登录 ××」：先把草稿保存下来再走登录流程（设置窗即将收起）。</summary>
    private void RequestLogin(string site)
    {
        if (_vm.TrySave(out _))
        {
            var saved = _vm.BuildSettings();
            _main.Settings = saved;
            LocalizationManager.Apply(saved.AppLanguage);
        }
        PendingLoginSite = site;
        DialogResult = true;
    }

    private void OnClearLoginsClick(object sender, RoutedEventArgs e)
    {
        var confirmed = ConfirmWindow.Show(
            this,
            Loc.S("L.Settings.ClearLoginsConfirm"),
            Loc.S("L.Settings.ClearLoginsDetail"),
            confirmText: Loc.S("L.Settings.ClearLogins"));
        if (!confirmed) return;
        _vm.ClearAllLogins();
    }

    // MARK: - 依赖组件

    private void OnRedownloadClick(object sender, RoutedEventArgs e)
    {
        try
        {
            // 先删旧文件再走 EnsureAsync（缺什么下什么）；被占用删不掉的会跳过重下。
            var bin = BinaryLocator.BinDirectory;
            foreach (var file in new[] { "yt-dlp.exe", "ffmpeg.exe", "ffprobe.exe", "deno.exe" })
            {
                try { File.Delete(Path.Combine(bin, file)); } catch { /* 占用中跳过 */ }
            }
            var manager = new DependencyManager();
            var window = new DependencyWindow(
                Loc.S("L.Settings.RedownloadTitle"),
                Loc.S("L.Settings.RedownloadCaption"),
                (progress, ct) => manager.EnsureAsync(progress, ct))
            {
                Owner = this,
            };
            window.ShowDialog();
        }
        catch (Exception error)
        {
            _vm.Notice = Loc.F("L.Common.OperationFailedFmt", error.Message);
        }
        finally
        {
            _vm.RefreshDependencyStatus();
        }
    }

    private void OnUpdateYtDlpClick(object sender, RoutedEventArgs e)
    {
        try
        {
            var manager = new DependencyManager();
            var window = new DependencyWindow(
                Loc.S("L.Settings.UpdateYtDlp"),
                Loc.S("L.Settings.UpdateYtDlpCaption"),
                (progress, ct) => manager.UpdateYtDlpAsync(progress, ct))
            {
                Owner = this,
            };
            window.ShowDialog();
        }
        catch (Exception error)
        {
            _vm.Notice = Loc.F("L.Common.OperationFailedFmt", error.Message);
        }
        finally
        {
            _vm.RefreshDependencyStatus();
        }
    }
}
