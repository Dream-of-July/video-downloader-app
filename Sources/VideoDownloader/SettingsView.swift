import SwiftUI
import WebKit
#if canImport(VDLCore)
import VDLCore
#endif

/// 设置面板（sheet）：翻译服务、字幕样式、站点登录。
struct SettingsView: View {
    @ObservedObject var model: ViewModel

    private enum TestState: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    @State private var testState: TestState = .idle
    @State private var testTask: Task<Void, Never>?
    @State private var clearFeedback: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                translationSection
                styleSection
                loginSection
            }
            .formStyle(.grouped)
            Divider()
            bottomBar
        }
        .frame(width: 480, height: 560)
        .onDisappear {
            testTask?.cancel()
        }
    }

    // MARK: - 翻译服务

    private var translationSection: some View {
        Section("翻译服务") {
            TextField(
                "服务地址",
                text: $model.settings.translationBaseURL,
                prompt: Text("https://api.anthropic.com 或企业网关地址")
            )
            .autocorrectionDisabled()
            TextField(
                "模型名",
                text: $model.settings.translationModel,
                prompt: Text("例如 claude-haiku-4-5 / 网关模型名")
            )
            .autocorrectionDisabled()
            SecureField("API 凭证", text: $model.settings.translationAuthToken)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button("测试连接") {
                    runConnectionTest()
                }
                .buttonStyle(.bordered)
                .disabled(testState == .testing || !model.settings.isTranslationConfigured)
                switch testState {
                case .idle:
                    EmptyView()
                case .testing:
                    ProgressView()
                        .controlSize(.small)
                case .success(let reply):
                    Text("连接正常：\(reply)")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .lineLimit(2)
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

    private func runConnectionTest() {
        testTask?.cancel()
        testState = .testing
        let settings = model.settings
        testTask = Task {
            do {
                let reply = try await testTranslationConnection(settings: settings)
                guard !Task.isCancelled else { return }
                testState = .success(reply)
            } catch {
                guard !Task.isCancelled else { return }
                testState = .failure(error.localizedDescription)
            }
        }
    }

    // MARK: - 字幕样式

    private var styleSection: some View {
        Section("字幕样式") {
            Picker("中文字幕样式", selection: $model.settings.subtitleStyle) {
                Text("双语（原文 + 中文）").tag(SubtitleStyle.bilingual)
                Text("仅中文").tag(SubtitleStyle.chineseOnly)
            }
        }
    }

    // MARK: - 站点登录

    private var loginSection: some View {
        Section("站点登录") {
            HStack(spacing: 10) {
                Button("登录 YouTube") {
                    model.requestLogin(site: "youtube.com")
                }
                Button("登录哔哩哔哩") {
                    model.requestLogin(site: "bilibili.com")
                }
            }
            HStack(spacing: 10) {
                Button("清除所有登录", role: .destructive) {
                    clearAllLogins()
                }
                .buttonStyle(.bordered)
                if let feedback = clearFeedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func clearAllLogins() {
        clearFeedback = nil
        NetscapeCookieFile.clear(at: AppSettings.cookieFileURL)
        WKWebsiteDataStore.default().removeData(
            ofTypes: [WKWebsiteDataTypeCookies],
            modifiedSince: .distantPast
        ) {
            clearFeedback = "已清除"
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
            Button("完成") {
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
