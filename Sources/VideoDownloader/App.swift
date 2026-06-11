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

/// 关窗 / 退出确认文案：按流水线阶段区分；非进行中阶段返回 nil（无需确认）。
@MainActor
private func abortConfirmationMessage(for model: ViewModel) -> String? {
    switch model.stage {
    case .downloading:
        return "正在下载，关闭窗口会中止下载。"
    case .translating:
        return "正在翻译字幕，关闭会丢弃已完成的翻译进度。"
    case .burning:
        return "正在烧录字幕，关闭会中止烧录（视频已下载，不受影响）。"
    default:
        return nil
    }
}

/// 关窗 / 退出前的确认弹窗。返回 true 表示用户选择中止。
@MainActor
private func confirmAbortDownload(message: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: "继续")
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
            guard let message = abortConfirmationMessage(for: model) else { return true }
            guard confirmAbortDownload(message: message) else { return false }
            model.cancelDownload()
            return true
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: ViewModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, let message = abortConfirmationMessage(for: model) else { return .terminateNow }
        guard confirmAbortDownload(message: message) else { return .terminateCancel }
        model.cancelDownload()
        return .terminateNow
    }
}
