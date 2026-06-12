using System.Windows;
using System.Windows.Threading;
using Vdl.Core;

namespace Vdl.App;

/// <summary>应用入口：界面语言装载 + 未捕获异常兜底 + 首次启动依赖引导。</summary>
public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        // 先按设置装载界面语言（含核心库 L10n），再建窗口。
        LocalizationManager.Apply(AppSettings.Load().AppLanguage);

        DispatcherUnhandledException += OnDispatcherUnhandledException;
        TaskScheduler.UnobservedTaskException += (_, args) => args.SetObserved();
        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
        {
            if (args.ExceptionObject is Exception error)
            {
                try
                {
                    MessageBox.Show(
                        Loc.F("L.App.FatalFmt", error.Message),
                        Loc.S("L.App.Title"), MessageBoxButton.OK, MessageBoxImage.Error);
                }
                catch
                {
                    // 崩溃路径上弹窗失败就算了
                }
            }
        };

        var main = new MainWindow();
        MainWindow = main;
        main.Show();
        RunFirstLaunchDependencyCheck(main);
    }

    /// <summary>未捕获异常兜底：展示错误而非闪退。</summary>
    private void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        e.Handled = true;
        MessageBox.Show(
            Loc.F("L.Common.OperationFailedFmt", e.Exception.Message),
            Loc.S("L.App.Title"), MessageBoxButton.OK, MessageBoxImage.Error);
    }

    /// <summary>启动时检查依赖：缺失则弹模态进度窗逐项下载，完成前主窗口不可用。</summary>
    private static void RunFirstLaunchDependencyCheck(Window owner)
    {
        try
        {
            var manager = new DependencyManager();
            if (manager.PlanMissing().Count == 0) return;
            var window = new DependencyWindow(
                Loc.S("L.Dep.FirstRunTitle"),
                Loc.S("L.Dep.FirstRunCaption"),
                (progress, ct) => manager.EnsureAsync(progress, ct))
            {
                Owner = owner,
            };
            window.ShowDialog();
        }
        catch (Exception error)
        {
            MessageBox.Show(
                Loc.F("L.Dep.CheckFailedFmt", error.Message),
                Loc.S("L.App.Title"), MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }
}
