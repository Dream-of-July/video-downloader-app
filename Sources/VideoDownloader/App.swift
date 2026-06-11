import AppKit
import SwiftUI

@main
struct VideoDownloaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = ViewModel()

    var body: some Scene {
        // Window（非 WindowGroup）：单窗口，天然禁掉 Cmd+N 多窗。
        Window("视频下载器", id: "main") {
            ContentView(model: model)
                .background(WindowAccessor(model: model))
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 540, height: 700)
    }
}

/// 下载中关窗 / 退出前的确认弹窗。返回 true 表示用户选择中止下载。
@MainActor
private func confirmAbortDownload() -> Bool {
    let alert = NSAlert()
    alert.messageText = "正在下载，关闭窗口会中止下载。"
    alert.alertStyle = .warning
    alert.addButton(withTitle: "继续下载")
    alert.addButton(withTitle: "中止并关闭")
    return alert.runModal() == .alertSecondButtonReturn
}

/// 把 window.delegate 接到 Coordinator，下载中点关闭按钮时先确认。
struct WindowAccessor: NSViewRepresentable {
    let model: ViewModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.delegate = context.coordinator
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window, window.delegate !== context.coordinator {
                window.delegate = context.coordinator
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private let model: ViewModel

        init(model: ViewModel) { self.model = model }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard model.isDownloadingStage else { return true }
            guard confirmAbortDownload() else { return false }
            model.cancelDownload()
            return true
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: ViewModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isDownloadingStage else { return .terminateNow }
        guard confirmAbortDownload() else { return .terminateCancel }
        model.cancelDownload()
        return .terminateNow
    }
}
