import AppKit
import SwiftUI
#if canImport(VDLCore)
import VDLCore
#endif

/// 一键安装依赖：体检 → `brew install` 缺失项（流式日志）→ 完成后回到业务流程。
/// Homebrew 不存在时不静默装（curl|bash 不可接受），引导用户去 brew.sh。
@MainActor
final class DependencyInstaller: ObservableObject {
    @Published var components: [DependencySetup.Component] = DependencySetup.check()
    @Published var isRunning = false
    @Published var log = ""
    @Published var errorText: String?

    private var process: Process?

    var brewAvailable: Bool { DependencySetup.brewPath() != nil }
    var missing: [DependencySetup.Component] { DependencySetup.missing(from: components) }
    var allInstalled: Bool { missing.isEmpty }

    func refresh() {
        components = DependencySetup.check()
    }

    func install() {
        guard !isRunning, let brew = DependencySetup.brewPath() else { return }
        let formulas = missing.map(\.formula)
        guard !formulas.isEmpty else { return }
        isRunning = true
        errorText = nil
        log = "$ brew install " + formulas.joined(separator: " ") + "\n"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: brew)
        task.arguments = ["install"] + formulas
        // GUI App 的 PATH 只有系统目录，brew 自身与其子工具都需要 Homebrew 路径
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        task.environment = env
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.append(text) }
        }
        task.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in self?.finish(status: status) }
        }
        do {
            try task.run()
            process = task
        } catch {
            isRunning = false
            errorText = "无法启动 Homebrew：\(error.localizedDescription)"
        }
    }

    func cancel() {
        process?.terminate()
    }

    private func append(_ text: String) {
        log += text
        // 防长日志膨胀：只留尾部
        if log.count > 20_000 { log = String(log.suffix(20_000)) }
    }

    private func finish(status: Int32) {
        isRunning = false
        process = nil
        refresh()
        if !allInstalled {
            errorText = status == 0
                ? "安装命令执行完成，但仍有组件未就绪，请查看日志。"
                : "安装未完成（退出码 \(status)），请查看日志。"
        }
    }
}

struct DependencySetupSheet: View {
    @ObservedObject var model: ViewModel
    @StateObject private var installer = DependencyInstaller()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("安装依赖组件")
                .font(.title3.weight(.semibold))
            Text("App 调用系统里的命令行工具完成下载与压制，缺失的组件可以在这里一键装好。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(installer.components) { component in
                    HStack(spacing: 10) {
                        Image(systemName: component.isInstalled
                              ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(component.isInstalled ? .green : .orange)
                        Text(component.id)
                            .font(.body.monospaced())
                        Text(component.purpose)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(component.isInstalled ? "已安装" : "缺失")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    if component.id != installer.components.last?.id {
                        Divider().padding(.leading, 12)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary.opacity(0.55))
            )

            if installer.brewAvailable {
                if !installer.log.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(installer.log)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .id("tail")
                        }
                        .frame(height: 140)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.quaternary.opacity(0.35))
                        )
                        .onChange(of: installer.log) {
                            proxy.scrollTo("tail", anchor: .bottom)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("这台 Mac 还没有 Homebrew（macOS 的包管理器），需要先装它：")
                        .font(.callout)
                    Text("打开 brew.sh，复制首页的安装命令到「终端」执行；装好后回来点「重新检测」。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("打开 brew.sh") {
                        NSWorkspace.shared.open(URL(string: "https://brew.sh/zh-cn/")!)
                    }
                    .buttonStyle(.bordered)
                }
            }

            if let errorText = installer.errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("重新检测") {
                    installer.refresh()
                }
                .disabled(installer.isRunning)
                Spacer()
                Button("关闭") {
                    installer.cancel()
                    model.closeDependencySetup()
                }
                if installer.allInstalled {
                    Button("完成") {
                        model.completeDependencySetup()
                    }
                    .buttonStyle(.borderedProminent)
                } else if installer.brewAvailable {
                    Button {
                        installer.install()
                    } label: {
                        if installer.isRunning {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("安装中…")
                            }
                        } else {
                            Text("一键安装缺失组件")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(installer.isRunning)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { installer.refresh() }
    }
}
