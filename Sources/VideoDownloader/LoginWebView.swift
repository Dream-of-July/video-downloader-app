import SwiftUI
import WebKit
#if canImport(VDLCore)
import VDLCore
#endif

/// 站点登录 sheet：内嵌 WKWebView 让用户登录，点「完成登录」后把
/// WKWebsiteDataStore.default() 的 cookies 导出为 Netscape 格式供 yt-dlp 使用。
/// 使用持久化的 default 数据存储，登录状态跨 App 重启保留。
struct LoginSheet: View {
    /// 站点 host，如 "youtube.com"
    let site: String
    /// cookies 写入成功后调用（由调用方关窗并触发重试）
    let onComplete: () -> Void
    let onCancel: () -> Void

    @State private var currentURL: String = ""
    @State private var errorText: String?
    @State private var loadErrorText: String?
    @State private var isExporting = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            LoginWebView(
                startURL: Self.startURL(for: site),
                currentURL: $currentURL,
                loadError: $loadErrorText
            )
        }
        .frame(width: 920, height: 640)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("登录 \(siteDisplayName)")
                    .font(.headline)
                Text("在下方页面完成登录，然后点右上角「完成登录」")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !currentURL.isEmpty {
                    Text(currentURL)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            if let displayError = errorText ?? loadErrorText {
                Text(displayError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .frame(maxWidth: 260, alignment: .trailing)
            }
            Button("取消") {
                onCancel()
            }
            .buttonStyle(.bordered)
            Button("完成登录") {
                exportCookies()
            }
            .buttonStyle(.borderedProminent)
            .disabled(isExporting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var siteDisplayName: String {
        let s = site.lowercased()
        if s.contains("youtube") { return "YouTube" }
        if s.contains("bilibili") { return "哔哩哔哩" }
        return site
    }

    /// 各站点的登录入口页。
    static func startURL(for site: String) -> URL {
        let s = site.lowercased()
        if s.contains("youtube.com") {
            return URL(string: "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fwww.youtube.com")!
        }
        if s.contains("bilibili.com") {
            return URL(string: "https://passport.bilibili.com/login")!
        }
        return URL(string: "https://\(site)") ?? URL(string: "https://www.bing.com")!
    }

    private func exportCookies() {
        isExporting = true
        errorText = nil
        let fileURL = AppSettings.cookieFileURL
        // httpCookieStore 要求主线程使用，回调也在主队列。
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            var failureText: String?
            do {
                try NetscapeCookieFile.write(cookies: cookies, to: fileURL)
            } catch {
                failureText = "保存登录信息失败：\(error.localizedDescription)"
            }
            finishExport(failureText)
        }
    }

    private func finishExport(_ failureText: String?) {
        isExporting = false
        if let failureText {
            errorText = failureText
        } else {
            onComplete()
        }
    }
}

/// WKWebView 的 SwiftUI 包装。用 WKWebsiteDataStore.default()（持久存储），
/// 登录产生的 cookies 跨重启保留。
struct LoginWebView: NSViewRepresentable {
    let startURL: URL
    @Binding var currentURL: String
    @Binding var loadError: String?

    /// 桌面 Safari 的 UA：降低 Google 等站点对内嵌 WebView 的拦截概率。
    private static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    func makeCoordinator() -> Coordinator {
        Coordinator(currentURL: $currentURL, loadError: $loadError)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Self.safariUserAgent
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: startURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.currentURL = $currentURL
        context.coordinator.loadError = $loadError
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var currentURL: Binding<String>
        var loadError: Binding<String?>

        init(currentURL: Binding<String>, loadError: Binding<String?>) {
            self.currentURL = currentURL
            self.loadError = loadError
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            currentURL.wrappedValue = webView.url?.absoluteString ?? ""
            loadError.wrappedValue = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            currentURL.wrappedValue = webView.url?.absoluteString ?? ""
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            reportLoadFailure(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            reportLoadFailure(error)
        }

        /// 登录流程的重定向会频繁打断在途请求（NSURLErrorCancelled），不算失败。
        private func reportLoadFailure(_ error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            loadError.wrappedValue = "页面加载失败，请检查网络后重试"
        }

        /// 弹窗 / target=_blank：直接在当前 webView 里打开，不创建新窗口。
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
    }
}
