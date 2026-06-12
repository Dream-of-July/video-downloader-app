using System.IO;
using System.Windows;
using Microsoft.Web.WebView2.Core;
using Vdl.Core;

namespace Vdl.App;

/// <summary>
/// 站点登录窗：内嵌 WebView2 让用户登录，点「完成登录」后把会话 cookies 导出为
/// Netscape 格式供 yt-dlp 使用。WebView2 用户数据落在应用数据目录，登录状态跨重启保留。
/// </summary>
public partial class LoginWindow : Window
{
    private readonly string _site;
    private bool _exporting;

    public LoginWindow(string site)
    {
        _site = site;
        InitializeComponent();
        HeadlineText.Text = Loc.F("L.Login.HeadlineFmt", SiteDisplayName(site));
        Loaded += OnLoadedAsync;
    }

    private async void OnLoadedAsync(object sender, RoutedEventArgs e)
    {
        try
        {
            var dataFolder = Path.Combine(AppSettings.SupportDirectory, "WebView2");
            var environment = await CoreWebView2Environment.CreateAsync(null, dataFolder);
            await WebView.EnsureCoreWebView2Async(environment);
            var core = WebView.CoreWebView2;
            core.SourceChanged += (_, _) => UrlText.Text = core.Source;
            core.NavigationCompleted += OnNavigationCompleted;
            // 弹窗 / target=_blank：直接在当前页打开，不创建新窗口。
            core.NewWindowRequested += (_, args) =>
            {
                args.Handled = true;
                core.Navigate(args.Uri);
            };
            InitText.Visibility = Visibility.Collapsed;
            core.Navigate(StartUrl(_site));
        }
        catch (WebView2RuntimeNotFoundException)
        {
            MessageBox.Show(
                this,
                Loc.S("L.Login.WebView2MissingBody"),
                Loc.S("L.Login.WebView2MissingTitle"), MessageBoxButton.OK, MessageBoxImage.Information);
            Close();
        }
        catch (Exception error)
        {
            MessageBox.Show(
                this, Loc.F("L.Login.InitFailedFmt", error.Message),
                Loc.S("L.App.Title"), MessageBoxButton.OK, MessageBoxImage.Error);
            Close();
        }
    }

    private void OnNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        // 登录流程的重定向会频繁打断在途请求（OperationCanceled），不算失败。
        if (e.IsSuccess || e.WebErrorStatus == CoreWebView2WebErrorStatus.OperationCanceled)
        {
            ErrorText.Visibility = Visibility.Collapsed;
            return;
        }
        ErrorText.Text = Loc.S("L.Login.PageLoadFailed");
        ErrorText.Visibility = Visibility.Visible;
    }

    private void OnCancelClick(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
    }

    /// <summary>导出当前会话全部 cookies 为 Netscape 文件；成功即关窗（由调用方触发重试）。</summary>
    private async void OnFinishLoginClick(object sender, RoutedEventArgs e)
    {
        if (_exporting) return;
        _exporting = true;
        FinishButton.IsEnabled = false;
        ErrorText.Visibility = Visibility.Collapsed;
        try
        {
            if (WebView.CoreWebView2 is not { } core)
            {
                throw new InvalidOperationException(Loc.S("L.Login.NotReady"));
            }
            var cookies = await core.CookieManager.GetCookiesAsync(null);
            var records = new List<CookieRecord>(cookies.Count);
            foreach (var cookie in cookies)
            {
                records.Add(new CookieRecord
                {
                    Domain = cookie.Domain,
                    Path = cookie.Path,
                    Name = cookie.Name,
                    Value = cookie.Value,
                    IsSecure = cookie.IsSecure,
                    ExpiresEpochSeconds = ExpiryEpochSeconds(cookie),
                });
            }
            NetscapeCookieFile.Write(records, AppSettings.CookieFilePath);
            DialogResult = true;
        }
        catch (Exception error)
        {
            ErrorText.Text = Loc.F("L.Login.SaveFailedFmt", error.Message);
            ErrorText.Visibility = Visibility.Visible;
        }
        finally
        {
            _exporting = false;
            FinishButton.IsEnabled = true;
        }
    }

    /// <summary>cookie 过期时间转 Unix 秒；session cookie 或取不到时返回 null（落盘写 0）。</summary>
    private static long? ExpiryEpochSeconds(CoreWebView2Cookie cookie)
    {
        try
        {
            if (cookie.IsSession) return null;
            var expires = cookie.Expires;
            if (expires == DateTime.MaxValue || expires == DateTime.MinValue) return null;
            var utc = expires.Kind == DateTimeKind.Utc ? expires : expires.ToUniversalTime();
            var seconds = (long)(utc - DateTime.UnixEpoch).TotalSeconds;
            return seconds > 0 ? seconds : null;
        }
        catch
        {
            return null;
        }
    }

    /// <summary>各站点的登录入口页。</summary>
    internal static string StartUrl(string site)
    {
        var s = site.ToLowerInvariant();
        if (s.Contains("youtube.com"))
        {
            return "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fwww.youtube.com";
        }
        if (s.Contains("bilibili.com"))
        {
            return "https://passport.bilibili.com/login";
        }
        return "https://" + site;
    }

    internal static string SiteDisplayName(string site)
    {
        var s = site.ToLowerInvariant();
        if (s.Contains("youtube")) return "YouTube";
        if (s.Contains("bilibili")) return Loc.S("L.Login.Bilibili");
        return site;
    }
}
