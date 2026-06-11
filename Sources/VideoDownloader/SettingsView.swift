import SwiftUI
import WebKit
#if canImport(VDLCore)
import VDLCore
#endif

/// 设置面板（sheet）：翻译服务、字幕样式、站点登录。
/// 草稿模式：输入框绑定 draft，点「完成」才回写并保存；取消 / Esc 不落任何修改。
struct SettingsView: View {
    @ObservedObject var model: ViewModel

    private enum TestState: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    private enum ModelFetchState: Equatable {
        case idle
        case fetching
        case loaded([String])
        case failure(String)
    }

    @State private var draft = AppSettings()
    @State private var testState: TestState = .idle
    @State private var testTask: Task<Void, Never>?
    @State private var modelFetchState: ModelFetchState = .idle
    @State private var modelFetchTask: Task<Void, Never>?
    @State private var clearFeedback: String?
    @State private var showClearConfirm = false
    /// cookies.txt 的修改日期；nil 表示尚未登录任何站点
    @State private var cookieDate: Date?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                translationSection
                styleSection
                burnQualitySection
                loginSection
            }
            .formStyle(.grouped)
            // 任一字段被改动：上一次的测试结果不再可信，回到初始态。
            .onChange(of: draft.translationProvider) {
                updateBaseURLForProviderChange()
                clearModelIfNeeded()
                resetTestState()
                resetModelFetch()
            }
            .onChange(of: draft.translationBaseURL) { resetTestState(); resetModelFetch() }
            .onChange(of: draft.translationModel) { resetTestState() }
            .onChange(of: draft.translationAuthToken) { resetTestState(); resetModelFetch() }
            Divider()
            bottomBar
        }
        .frame(width: 480, height: 560)
        .onAppear {
            draft = model.settings
            refreshLoginStatus()
        }
        .onDisappear {
            testTask?.cancel()
            modelFetchTask?.cancel()
            // 未点「完成」时回滚为磁盘值；已保存时 reload 等价于当前值，无副作用。
            model.settings = AppSettings.load()
        }
    }

    // MARK: - 翻译服务

    private var translationSection: some View {
        Section("翻译服务") {
            Picker("接口协议", selection: $draft.translationProvider) {
                Text("Anthropic-compatible").tag(TranslationProvider.anthropic)
                Text("OpenAI-compatible").tag(TranslationProvider.openai)
            }
            TextField(
                "服务地址",
                text: $draft.translationBaseURL,
                prompt: Text(baseURLPrompt)
            )
            .autocorrectionDisabled()
            VStack(alignment: .leading, spacing: 4) {
                SecureField("API 凭证", text: $draft.translationAuthToken)
                Text(credentialHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // 模型：先填地址+凭证，点「拉取模型」从服务端取真实可用列表再选。
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button("拉取模型") { fetchModels() }
                    .buttonStyle(.bordered)
                    .disabled(modelFetchState == .fetching
                        || draft.translationBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
                        || draft.translationAuthToken.trimmingCharacters(in: .whitespaces).isEmpty)
                switch modelFetchState {
                case .idle:
                    EmptyView()
                case .fetching:
                    ProgressView().controlSize(.small)
                case .loaded(let models):
                    Text("已拉取 \(models.count) 个模型")
                        .font(.caption).foregroundStyle(.secondary)
                case .failure(let message):
                    Text(message)
                        .font(.caption).foregroundStyle(.red).lineLimit(3)
                }
                Spacer(minLength: 0)
            }
            if case .loaded(let models) = modelFetchState, !models.isEmpty {
                // 手填了列表外的模型名时，把它并入选项，避免 Picker 选中值无对应 tag
                let current = draft.translationModel
                let options = (current.isEmpty || models.contains(current)) ? models : models + [current]
                Picker("选择模型", selection: $draft.translationModel) {
                    Text("请选择").tag("")
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
            }
            // 拉不到列表时仍允许手填
            TextField(
                "模型名（也可手动填写）",
                text: $draft.translationModel,
                prompt: Text(modelPrompt)
            )
            .autocorrectionDisabled()
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button("测试连接") {
                    runConnectionTest()
                }
                .buttonStyle(.bordered)
                .disabled(testState == .testing || !draft.isTranslationConfigured)
                switch testState {
                case .idle:
                    EmptyView()
                case .testing:
                    ProgressView()
                        .controlSize(.small)
                case .success:
                    Text("连接正常")
                        .font(.caption)
                        .foregroundStyle(.green)
                case .failure(let message):
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var baseURLPrompt: String {
        switch draft.translationProvider {
        case .anthropic:
            return "Anthropic 兼容地址或企业网关地址"
        case .openai:
            return "https://api.openai.com"
        }
    }

    private var modelPrompt: String {
        switch draft.translationProvider {
        case .anthropic:
            return "可先留空，填完地址和凭证后选择"
        case .openai:
            return "可先留空，填完地址和凭证后选择"
        }
    }

    private var credentialHelpText: String {
        switch draft.translationProvider {
        case .anthropic:
            return "公司网关按 ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN 填写；DeepSeek 映射也选这个协议。"
        case .openai:
            return "OpenAI 使用 Responses API。服务地址填 https://api.openai.com；凭证填 OpenAI API key，不要带 Bearer 前缀。"
        }
    }

    private func updateBaseURLForProviderChange() {
        let trimmed = draft.translationBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultURLs = Set(TranslationProvider.allCases.map(\.defaultBaseURL))
        guard trimmed.isEmpty || defaultURLs.contains(trimmed) else { return }
        draft.translationBaseURL = draft.translationProvider.defaultBaseURL
    }

    /// 切换协议后清空模型：不同协议/端点的模型列表不同，强制重新「拉取模型」选择，
    /// 避免拿着上一个协议的模型名去撞 503。
    private func clearModelIfNeeded() {
        guard !draft.translationModel.isEmpty else { return }
        draft.translationModel = ""
    }

    /// 任一字段被改动：上一次的测试结果不再可信，回到初始态。
    private func resetTestState() {
        guard testState != .idle else { return }
        testTask?.cancel()
        testState = .idle
    }

    private func runConnectionTest() {
        testTask?.cancel()
        testState = .testing
        let settings = draft
        testTask = Task {
            do {
                _ = try await testTranslationConnection(settings: settings)
                guard !Task.isCancelled else { return }
                testState = .success
            } catch {
                guard !Task.isCancelled else { return }
                let reason: String
                if case VDLError.translateFailed(let detail) = error {
                    reason = detail
                } else {
                    reason = error.localizedDescription
                }
                testState = .failure("连接失败：\(reason)")
            }
        }
    }

    private func resetModelFetch() {
        guard modelFetchState != .idle else { return }
        modelFetchTask?.cancel()
        modelFetchState = .idle
    }

    private func fetchModels() {
        modelFetchTask?.cancel()
        modelFetchState = .fetching
        let settings = draft
        modelFetchTask = Task {
            do {
                let models = try await listTranslationModels(settings: settings)
                guard !Task.isCancelled else { return }
                modelFetchState = .loaded(models)
                // 当前模型不在列表里就清空，促使用户从列表选一个网关真有的模型。
                if !draft.translationModel.isEmpty, !models.contains(draft.translationModel) {
                    draft.translationModel = ""
                }
            } catch {
                guard !Task.isCancelled else { return }
                let reason: String
                if case VDLError.translateFailed(let detail) = error {
                    reason = detail
                } else {
                    reason = error.localizedDescription
                }
                modelFetchState = .failure("拉取失败：\(reason)")
            }
        }
    }

    // MARK: - 字幕样式

    private var styleSection: some View {
        Section("字幕样式") {
            Picker("中文字幕样式", selection: $draft.subtitleStyle) {
                Text("双语（原文 + 中文）").tag(SubtitleStyle.bilingual)
                Text("仅中文").tag(SubtitleStyle.chineseOnly)
            }
        }
    }

    // MARK: - 烧录画质

    private var burnQualitySection: some View {
        Section("烧录画质") {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(
                    "高清视频烧录时缩放到 1080p（更快更省空间，推荐）",
                    isOn: Binding(
                        get: { draft.maxBurnHeight != nil },
                        set: { draft.maxBurnHeight = $0 ? 1080 : nil }
                    )
                )
                Text("关闭则按源分辨率烧录（4K 会明显更慢、文件更大）。此设置只影响烧录字幕，不影响普通下载。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 站点登录

    private var loginSection: some View {
        Section("站点登录") {
            Text(loginStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("登录 YouTube") {
                    requestLogin(site: "youtube.com")
                }
                Button("登录哔哩哔哩") {
                    requestLogin(site: "bilibili.com")
                }
            }
            HStack(spacing: 10) {
                Button("清除所有登录", role: .destructive) {
                    showClearConfirm = true
                }
                .buttonStyle(.bordered)
                .disabled(cookieDate == nil)
                if let feedback = clearFeedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .confirmationDialog(
                "确定要清除所有登录吗？",
                isPresented: $showClearConfirm
            ) {
                Button("清除所有登录", role: .destructive) {
                    clearAllLogins()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("清除后需要重新登录才能下载会员/受限视频。")
            }
        }
    }

    private var loginStatusText: String {
        guard let cookieDate else { return "尚未登录任何站点" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return "已保存登录信息（\(formatter.string(from: cookieDate))导出）"
    }

    /// 登录状态行的数据源：cookies.txt 的修改日期。
    private func refreshLoginStatus() {
        let path = AppSettings.cookieFileURL.path
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        cookieDate = attributes?[.modificationDate] as? Date
    }

    /// 点「登录 ××」：先把草稿保存下来再走登录流程（设置窗即将收起）。
    private func requestLogin(site: String) {
        clearFeedback = nil
        model.settings = draft
        model.requestLogin(site: site)
    }

    private func clearAllLogins() {
        clearFeedback = nil
        NetscapeCookieFile.clear(at: AppSettings.cookieFileURL)
        WKWebsiteDataStore.default().removeData(
            ofTypes: [WKWebsiteDataTypeCookies],
            modifiedSince: .distantPast
        ) {
            clearFeedback = "已清除"
            refreshLoginStatus()
        }
    }

    // MARK: - 底栏

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if let notice = model.settingsNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            Spacer()
            Button("取消") {
                model.showSettings = false
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)
            Button("完成") {
                model.settings = draft
                if model.saveSettings() {
                    model.showSettings = false
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
