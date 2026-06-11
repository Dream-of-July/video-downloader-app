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
        .defaultSize(width: 560, height: 780)
    }
}

/// 关窗 / 退出确认文案：队列里有进行中（非暂停 / 完成 / 失败 / 取消）任务时给出提示，否则返回 nil。
@MainActor
private func abortConfirmationMessage(for model: ViewModel) -> String? {
    let count = model.queue.activeTaskCount
    guard count > 0 else { return nil }
    return "队列中还有 \(count) 个任务在进行，关闭会全部中止。"
}

/// 关窗 / 退出前的确认弹窗。返回 true 表示用户选择中止。
@MainActor
private func confirmAbortDownload(message: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: "继续")
    alert.addButton(withTitle: "全部中止并关闭")
    return alert.runModal() == .alertSecondButtonReturn
}

/// 中止队列所有进行中的任务。
@MainActor
private func abortAllTasks(_ model: ViewModel) {
    for item in model.queue.items {
        model.queue.cancel(item.id)
    }
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
            abortAllTasks(model)
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
        abortAllTasks(model)
        return .terminateNow
    }
}
