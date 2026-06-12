using System.IO;
using Vdl.Core;

namespace Vdl.App;

/// <summary>
/// 设置窗口的草稿模型：所有编辑落在本对象，点「完成」才写回 AppSettings 并保存；
/// 例外是并发数（任务要求改动实时 SyncConcurrency 生效，取消时由窗口关闭回滚为磁盘值）。
/// </summary>
public sealed class SettingsViewModel : ObservableObject
{
    /// <summary>占位项按打开窗口时的语言取一次（设置窗每次打开都新建，无陈旧问题）。</summary>
    private readonly string _modelPlaceholder = Loc.S("L.Settings.ModelPlaceholder");

    private readonly QueueManager _queue;
    private CancellationTokenSource? _testCts;
    private CancellationTokenSource? _fetchCts;
    private List<string> _fetchedModels = [];

    public RelayCommand FetchModelsCommand { get; }
    public RelayCommand TestConnectionCommand { get; }
    public RelayCommand DownloadsMinusCommand { get; }
    public RelayCommand DownloadsPlusCommand { get; }
    public RelayCommand BurnsMinusCommand { get; }
    public RelayCommand BurnsPlusCommand { get; }

    public SettingsViewModel(AppSettings current, QueueManager queue, string? initialNotice)
    {
        _queue = queue;
        _provider = current.TranslationProvider;
        _baseUrl = current.TranslationBaseUrl;
        _authToken = current.TranslationAuthToken;
        _model = current.TranslationModel;
        _styleIndex = current.SubtitleStyle == SubtitleStyle.ChineseOnly ? 1 : 0;
        _languageIndex = current.AppLanguage switch { "zh-Hans" => 1, "en" => 2, _ => 0 };
        _limitBurnTo1080 = current.MaxBurnHeight is not null;
        _maxDownloads = current.MaxConcurrentDownloads;
        _maxBurns = current.MaxConcurrentBurns;
        _notice = initialNotice;

        FetchModelsCommand = new RelayCommand(() => _ = FetchModelsAsync(), () => !IsFetchingModels && CanFetchModels);
        TestConnectionCommand = new RelayCommand(
            () => _ = TestConnectionAsync(), () => !IsTesting && BuildSettings().IsTranslationConfigured);
        DownloadsMinusCommand = new RelayCommand(() => MaxDownloads -= 1, () => MaxDownloads > 1);
        DownloadsPlusCommand = new RelayCommand(() => MaxDownloads += 1, () => MaxDownloads < 5);
        BurnsMinusCommand = new RelayCommand(() => MaxBurns -= 1, () => MaxBurns > 1);
        BurnsPlusCommand = new RelayCommand(() => MaxBurns += 1, () => MaxBurns < 3);

        RefreshLoginStatus();
        RefreshDependencyStatus();
    }

    // MARK: - 翻译服务

    private TranslationProvider _provider;
    /// <summary>0 = Anthropic 兼容，1 = OpenAI 兼容。</summary>
    public int ProviderIndex
    {
        get => _provider == TranslationProvider.Openai ? 1 : 0;
        set
        {
            var next = value == 1 ? TranslationProvider.Openai : TranslationProvider.Anthropic;
            if (_provider == next) return;
            _provider = next;
            // 地址为空或还是另一协议的默认值时带成新协议默认。
            var trimmed = BaseUrl.Trim();
            if (trimmed.Length == 0
                || trimmed == TranslationProvider.Anthropic.DefaultBaseUrl()
                || trimmed == TranslationProvider.Openai.DefaultBaseUrl())
            {
                BaseUrl = next.DefaultBaseUrl();
            }
            // 切换协议后清空模型：不同协议/端点的模型列表不同，强制重新「拉取模型」选择。
            if (Model.Length > 0) Model = "";
            ResetTestState();
            ResetModelFetch();
            RaisePropertyChanged();
            RaisePropertyChanged(nameof(CredentialHelpText));
            RaiseActionEnables();
        }
    }

    public string CredentialHelpText => _provider == TranslationProvider.Openai
        ? Loc.S("L.Settings.CredHelpOpenAi")
        : Loc.S("L.Settings.CredHelpAnthropic");

    private string _baseUrl;
    public string BaseUrl
    {
        get => _baseUrl;
        set
        {
            if (!SetProperty(ref _baseUrl, value)) return;
            ResetTestState();
            ResetModelFetch();
            RaiseActionEnables();
        }
    }

    private string _authToken;
    public string AuthToken
    {
        get => _authToken;
        set
        {
            if (!SetProperty(ref _authToken, value)) return;
            ResetTestState();
            ResetModelFetch();
            RaiseActionEnables();
        }
    }

    private string _model;
    public string Model
    {
        get => _model;
        set
        {
            if (!SetProperty(ref _model, value)) return;
            // 任一字段被改动：上一次的测试结果不再可信，回到初始态（模型改动不影响已拉取的列表）。
            ResetTestState();
            if (ShowModelPicker) RebuildModelOptions();
            RaisePropertyChanged(nameof(SelectedModelOption));
            RaiseActionEnables();
        }
    }

    // MARK: 拉取模型

    private bool _isFetchingModels;
    public bool IsFetchingModels
    {
        get => _isFetchingModels;
        private set
        {
            if (SetProperty(ref _isFetchingModels, value)) RaiseActionEnables();
        }
    }

    private string? _fetchStatusText;
    public string? FetchStatusText { get => _fetchStatusText; private set => SetProperty(ref _fetchStatusText, value); }

    private bool _fetchStatusIsError;
    public bool FetchStatusIsError { get => _fetchStatusIsError; private set => SetProperty(ref _fetchStatusIsError, value); }

    private bool _showModelPicker;
    public bool ShowModelPicker { get => _showModelPicker; private set => SetProperty(ref _showModelPicker, value); }

    private List<string> _modelOptions = [];
    public List<string> ModelOptions { get => _modelOptions; private set => SetProperty(ref _modelOptions, value); }

    /// <summary>ComboBox 选中值。空模型映射到「请选择」占位项。</summary>
    public string SelectedModelOption
    {
        get => _model.Length == 0 ? _modelPlaceholder : _model;
        set
        {
            // 选项列表重建瞬间 ComboBox 会把 SelectedItem 置 null，忽略。
            if (string.IsNullOrEmpty(value)) return;
            Model = value == _modelPlaceholder ? "" : value;
        }
    }

    private bool CanFetchModels => BaseUrl.Trim().Length > 0 && AuthToken.Trim().Length > 0;

    private async Task FetchModelsAsync()
    {
        _fetchCts?.Cancel();
        var cts = new CancellationTokenSource();
        _fetchCts = cts;
        IsFetchingModels = true;
        FetchStatusText = Loc.S("L.Settings.Fetching");
        FetchStatusIsError = false;
        ShowModelPicker = false;
        var settings = BuildSettings();
        try
        {
            var models = await TranslationApi.ListModelsAsync(settings, ct: cts.Token);
            if (cts.Token.IsCancellationRequested) return;
            _fetchedModels = [.. models];
            // 当前模型不在列表里就清空，促使用户从列表选一个网关真有的模型。
            if (Model.Length > 0 && !_fetchedModels.Contains(Model)) Model = "";
            RebuildModelOptions();
            ShowModelPicker = true;
            FetchStatusText = Loc.F("L.Settings.FetchedFmt", models.Count);
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception error)
        {
            if (cts.Token.IsCancellationRequested) return;
            FetchStatusText = Loc.F("L.Settings.FetchFailedFmt", ReasonOf(error));
            FetchStatusIsError = true;
        }
        finally
        {
            if (_fetchCts == cts) IsFetchingModels = false;
        }
    }

    /// <summary>手填了列表外的模型名时，把它并入选项，避免下拉选中值无对应项。</summary>
    private void RebuildModelOptions()
    {
        var options = new List<string> { _modelPlaceholder };
        options.AddRange(_fetchedModels);
        if (_model.Length > 0 && !_fetchedModels.Contains(_model)) options.Add(_model);
        ModelOptions = options;
    }

    private void ResetModelFetch()
    {
        _fetchCts?.Cancel();
        if (!ShowModelPicker && FetchStatusText is null && !IsFetchingModels) return;
        IsFetchingModels = false;
        ShowModelPicker = false;
        FetchStatusText = null;
        FetchStatusIsError = false;
    }

    // MARK: 测试连接

    private bool _isTesting;
    public bool IsTesting
    {
        get => _isTesting;
        private set
        {
            if (SetProperty(ref _isTesting, value)) RaiseActionEnables();
        }
    }

    private string? _testStatusText;
    public string? TestStatusText { get => _testStatusText; private set => SetProperty(ref _testStatusText, value); }

    private bool _testStatusIsError;
    public bool TestStatusIsError { get => _testStatusIsError; private set => SetProperty(ref _testStatusIsError, value); }

    private bool _testStatusIsSuccess;
    public bool TestStatusIsSuccess { get => _testStatusIsSuccess; private set => SetProperty(ref _testStatusIsSuccess, value); }

    private async Task TestConnectionAsync()
    {
        _testCts?.Cancel();
        var cts = new CancellationTokenSource();
        _testCts = cts;
        IsTesting = true;
        TestStatusText = Loc.S("L.Settings.Testing");
        TestStatusIsError = false;
        TestStatusIsSuccess = false;
        var settings = BuildSettings();
        try
        {
            _ = await TranslationApi.TestConnectionAsync(settings, ct: cts.Token);
            if (cts.Token.IsCancellationRequested) return;
            TestStatusText = Loc.S("L.Settings.TestOk");
            TestStatusIsSuccess = true;
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception error)
        {
            if (cts.Token.IsCancellationRequested) return;
            TestStatusText = Loc.F("L.Settings.TestFailedFmt", ReasonOf(error));
            TestStatusIsError = true;
        }
        finally
        {
            if (_testCts == cts) IsTesting = false;
        }
    }

    private void ResetTestState()
    {
        _testCts?.Cancel();
        if (TestStatusText is null && !IsTesting) return;
        IsTesting = false;
        TestStatusText = null;
        TestStatusIsError = false;
        TestStatusIsSuccess = false;
    }

    private static string ReasonOf(Exception error) =>
        error is VdlException { Kind: VdlErrorKind.TranslateFailed } vdl ? vdl.Detail : error.Message;

    private void RaiseActionEnables()
    {
        FetchModelsCommand.RaiseCanExecuteChanged();
        TestConnectionCommand.RaiseCanExecuteChanged();
    }

    // MARK: - 字幕样式 / 烧录画质

    private int _styleIndex;
    /// <summary>0 = 双语（原文 + 中文），1 = 仅中文。</summary>
    public int StyleIndex { get => _styleIndex; set => SetProperty(ref _styleIndex, value); }

    private int _languageIndex;
    /// <summary>界面语言：0 = 跟随系统（auto），1 = 简体中文，2 = English。点「完成」后生效。</summary>
    public int LanguageIndex { get => _languageIndex; set => SetProperty(ref _languageIndex, value); }

    private bool _limitBurnTo1080;
    /// <summary>勾选 = MaxBurnHeight 1080；关闭 = null（保持源分辨率）。</summary>
    public bool LimitBurnTo1080 { get => _limitBurnTo1080; set => SetProperty(ref _limitBurnTo1080, value); }

    // MARK: - 性能（改动实时生效）

    private int _maxDownloads;
    public int MaxDownloads
    {
        get => _maxDownloads;
        set
        {
            var clamped = Math.Clamp(value, 1, 5);
            if (!SetProperty(ref _maxDownloads, clamped)) return;
            DownloadsMinusCommand.RaiseCanExecuteChanged();
            DownloadsPlusCommand.RaiseCanExecuteChanged();
            SyncConcurrencyLive();
        }
    }

    private int _maxBurns;
    public int MaxBurns
    {
        get => _maxBurns;
        set
        {
            var clamped = Math.Clamp(value, 1, 3);
            if (!SetProperty(ref _maxBurns, clamped)) return;
            BurnsMinusCommand.RaiseCanExecuteChanged();
            BurnsPlusCommand.RaiseCanExecuteChanged();
            SyncConcurrencyLive();
        }
    }

    private void SyncConcurrencyLive() => _queue.SyncConcurrency(BuildSettings());

    // MARK: - 站点登录

    private string _loginStatusText = "";
    public string LoginStatusText { get => _loginStatusText; private set => SetProperty(ref _loginStatusText, value); }

    private bool _hasLogin;
    public bool HasLogin { get => _hasLogin; private set => SetProperty(ref _hasLogin, value); }

    private string? _clearFeedback;
    public string? ClearFeedback { get => _clearFeedback; private set => SetProperty(ref _clearFeedback, value); }

    /// <summary>登录状态行的数据源：cookies.txt 的修改日期。</summary>
    public void RefreshLoginStatus()
    {
        try
        {
            var path = AppSettings.CookieFilePath;
            if (File.Exists(path))
            {
                var date = File.GetLastWriteTime(path);
                HasLogin = true;
                var dateText = LocalizationManager.IsEnglish
                    ? date.ToString("MMM d", System.Globalization.CultureInfo.GetCultureInfo("en-US"))
                    : $"{date.Month}月{date.Day}日";
                LoginStatusText = Loc.F("L.Settings.LoginStatusFmt", dateText);
            }
            else
            {
                HasLogin = false;
                LoginStatusText = Loc.S("L.Settings.LoginStatusNone");
            }
        }
        catch
        {
            HasLogin = false;
            LoginStatusText = Loc.S("L.Settings.LoginStatusNone");
        }
    }

    /// <summary>清除导出的 cookies 文件，并尽力删掉 WebView2 的持久化数据目录。</summary>
    public void ClearAllLogins()
    {
        NetscapeCookieFile.Clear(AppSettings.CookieFilePath);
        try
        {
            // 登录窗本次会话用过时目录可能被占用，删不掉就留给下次（cookies.txt 已清，yt-dlp 不再带登录态）。
            var dataFolder = Path.Combine(AppSettings.SupportDirectory, "WebView2");
            if (Directory.Exists(dataFolder)) Directory.Delete(dataFolder, recursive: true);
        }
        catch
        {
            // 忽略
        }
        ClearFeedback = Loc.S("L.Settings.Cleared");
        RefreshLoginStatus();
    }

    // MARK: - 依赖组件

    private string _dependencyStatusText = "";
    public string DependencyStatusText { get => _dependencyStatusText; private set => SetProperty(ref _dependencyStatusText, value); }

    public void RefreshDependencyStatus()
    {
        static string Status(bool installed) =>
            installed ? Loc.S("L.Settings.Installed") : Loc.S("L.Settings.Missing");
        var bin = BinaryLocator.BinDirectory;
        var ytDlp = File.Exists(Path.Combine(bin, "yt-dlp.exe"));
        var ffmpeg = File.Exists(Path.Combine(bin, "ffmpeg.exe")) && File.Exists(Path.Combine(bin, "ffprobe.exe"));
        var deno = File.Exists(Path.Combine(bin, "deno.exe"));
        DependencyStatusText = Loc.F("L.Settings.DepStatusFmt", Status(ytDlp), Status(ffmpeg), Status(deno));
    }

    // MARK: - 底栏

    private string? _notice;
    /// <summary>底栏提示（保存失败 / 请先配置翻译服务）。</summary>
    public string? Notice { get => _notice; set => SetProperty(ref _notice, value); }

    // MARK: - 保存

    public AppSettings BuildSettings() => new()
    {
        TranslationProvider = _provider,
        TranslationBaseUrl = BaseUrl,
        TranslationModel = Model,
        TranslationAuthToken = AuthToken,
        SubtitleStyle = StyleIndex == 1 ? SubtitleStyle.ChineseOnly : SubtitleStyle.Bilingual,
        MaxBurnHeight = LimitBurnTo1080 ? 1080 : null,
        MaxConcurrentDownloads = MaxDownloads,
        MaxConcurrentBurns = MaxBurns,
        AppLanguage = LanguageIndex switch { 1 => "zh-Hans", 2 => "en", _ => "auto" },
    };

    public bool TrySave(out string? error)
    {
        try
        {
            BuildSettings().Save();
            error = null;
            return true;
        }
        catch (Exception e)
        {
            error = e.Message;
            return false;
        }
    }

    /// <summary>窗口关闭时取消在途的测试 / 拉取请求。</summary>
    public void CancelOperations()
    {
        _testCts?.Cancel();
        _fetchCts?.Cancel();
    }
}
