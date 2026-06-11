import AppKit
import SwiftUI
#if canImport(VDLCore)
import VDLCore
#endif

struct ContentView: View {
    @ObservedObject var model: ViewModel
    @FocusState private var urlFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 520, minHeight: 600)
        .onAppear {
            model.onAppear()
            urlFieldFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.prefillFromClipboardIfAppropriate()
        }
        .sheet(isPresented: $model.showSettings, onDismiss: { model.consumePendingLogin() }) {
            SettingsView(model: model)
        }
        .sheet(isPresented: loginSheetBinding) {
            if let site = model.loginSite {
                LoginSheet(
                    site: site,
                    onComplete: { model.loginCompleted() },
                    onCancel: { model.cancelLogin() }
                )
            }
        }
    }

    private var loginSheetBinding: Binding<Bool> {
        Binding(
            get: { model.loginSite != nil },
            set: { if !$0 { model.loginSite = nil } }
        )
    }

    // MARK: - 顶部输入区

    private var header: some View {
        HStack(spacing: 8) {
            TextField("粘贴视频链接", text: $model.urlText)
                .textFieldStyle(.roundedBorder)
                .focused($urlFieldFocused)
                .onSubmit { model.parse() }
            parseButton
                .disabled(
                    model.isParsing
                    || model.isDownloadingStage
                    || model.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            Button {
                model.showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.bordered)
            .help("设置")
        }
        .frame(maxWidth: 500)
    }

    /// 解析按钮：仅在 idle / failed 阶段作为主按钮，其余阶段降级为次按钮。
    @ViewBuilder
    private var parseButton: some View {
        let button = Button {
            model.parse()
        } label: {
            Group {
                if model.isParsing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("解析")
                }
            }
            .frame(minWidth: 36)
        }
        if parseButtonIsProminent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private var parseButtonIsProminent: Bool {
        switch model.stage {
        case .idle, .failed:
            return true
        default:
            return false
        }
    }

    // MARK: - 各阶段内容

    @ViewBuilder
    private var content: some View {
        switch model.stage {
        case .idle:
            emptyState
        case .resolving, .analyzing:
            loadingState
        case .choosing(let candidates):
            choosingState(candidates)
        case .ready(let info):
            readyState(info)
        case .downloading(let info):
            downloadingState(info)
        case .translating(let info):
            pipelineState(info, label: "正在翻译字幕…")
        case .burning(let info):
            pipelineState(info, label: "正在烧录字幕…")
        case .done(let info, let result):
            doneState(info, result)
        case .failed(let message):
            failedState(message)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tertiary)
            Text("粘贴链接，下载网页里的视频")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("正在解析…")
                .foregroundStyle(.secondary)
            Button("取消") {
                model.cancelParse()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func choosingState(_ candidates: [VideoCandidate]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("这个页面里有 \(candidates.count) 个视频")
                    .font(.headline)
                VStack(spacing: 0) {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                        Button {
                            model.choose(candidate)
                        } label: {
                            candidateRow(candidate)
                        }
                        .buttonStyle(.plain)
                        if index < candidates.count - 1 {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
                .background(cardBackground)
            }
            .frame(maxWidth: 500)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
        }
    }

    private func candidateRow(_ candidate: VideoCandidate) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: candidate.kind))
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title)
                    .lineLimit(2)
                    .help(candidate.title)
                if let detail = candidate.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func icon(for kind: VideoCandidate.Kind) -> String {
        switch kind {
        case .pageMain, .directFile:
            return "film"
        case .youtube, .vimeo, .supported:
            return "play.rectangle"
        }
    }

    private func readyState(_ info: VideoInfo) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.canReturnToList {
                        Button {
                            model.backToList()
                        } label: {
                            Label("返回列表", systemImage: "chevron.left")
                                .font(.callout)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    infoCard(info)
                    section("格式") {
                        formatRows(info)
                    }
                    section("字幕") {
                        subtitleRows(info)
                    }
                    section("中文字幕") {
                        chineseSubtitleRows(info)
                    }
                }
                .frame(maxWidth: 500)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
            }
            VStack(spacing: 6) {
                Button {
                    model.startDownload()
                } label: {
                    Text("下载")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                Text("保存到 ~/Downloads")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 500)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    /// 视频档位在前；其后用分隔线 + “音频”小节标渲染仅音频选项。
    @ViewBuilder
    private func formatRows(_ info: VideoInfo) -> some View {
        let videoFormats = info.formats.filter { !$0.isAudioOnly }
        let audioFormats = info.formats.filter { $0.isAudioOnly }
        ForEach(Array(videoFormats.enumerated()), id: \.element.id) { index, format in
            formatRow(format)
            if index < videoFormats.count - 1 {
                Divider().padding(.leading, 12)
            }
        }
        if !videoFormats.isEmpty && !audioFormats.isEmpty {
            Divider()
            Text("音频")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        ForEach(Array(audioFormats.enumerated()), id: \.element.id) { index, format in
            formatRow(format)
            if index < audioFormats.count - 1 {
                Divider().padding(.leading, 12)
            }
        }
    }

    private func formatRow(_ format: FormatChoice) -> some View {
        Button {
            model.selectedFormatID = format.id
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(format.label)
                    if let detail = format.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.selectedFormatID == format.id {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func subtitleRows(_ info: VideoInfo) -> some View {
        if info.subtitles.isEmpty {
            Text("这个视频没有字幕")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ForEach(Array(info.subtitles.enumerated()), id: \.element.id) { index, subtitle in
                Toggle(isOn: subtitleBinding(subtitle.id)) {
                    HStack(spacing: 6) {
                        Text(subtitle.label)
                        if subtitle.isAuto {
                            Text("自动生成")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.quaternary))
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                if index < info.subtitles.count - 1 {
                    Divider().padding(.leading, 12)
                }
            }
        }
    }

    private func subtitleBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { model.selectedSubtitleIDs.contains(id) },
            set: { isOn in
                if isOn {
                    model.selectedSubtitleIDs.insert(id)
                } else {
                    model.selectedSubtitleIDs.remove(id)
                }
            }
        )
    }

    /// 「中文字幕」分组：依赖上方至少勾选一条字幕；翻译服务未配置时给出入口。
    private func chineseSubtitleRows(_ info: VideoInfo) -> some View {
        let hasSubtitleSelected = !model.selectedSubtitleIDs.isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            Picker("中文字幕", selection: $model.chineseMode) {
                ForEach(ChineseSubtitleMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(!hasSubtitleSelected)
            if !hasSubtitleSelected {
                Text("先在上面勾选一条字幕")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !model.settings.isTranslationConfigured {
                HStack(spacing: 8) {
                    Text("未配置翻译服务")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("去设置") {
                        model.showSettings = true
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            } else if model.chineseMode != .off, model.selectedSubtitleIDs.count > 1,
                      let source = model.translationSourceSubtitle(in: info) {
                Text("将翻译：\(source.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func downloadingState(_ info: VideoInfo) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    infoCard(info)
                    progressCard
                }
                .frame(maxWidth: 500)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
            }
            Button("取消") {
                model.cancelDownload()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.vertical, 14)
        }
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let p = model.progress {
                switch p.phase {
                case .processing:
                    ProgressView()
                        .progressViewStyle(.linear)
                    Text("正在处理…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                default:
                    if let percent = p.percent {
                        ProgressView(value: min(max(percent, 0), 100), total: 100)
                        HStack(spacing: 12) {
                            Text(String(format: "%.0f%%", percent))
                            if let speed = p.speedText {
                                Text(speed)
                            }
                            Spacer()
                            if let eta = p.etaText {
                                Text("剩余 \(eta)")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                        Text(p.phase == .preparing ? "正在准备…" : "正在下载…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                Text("正在准备…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    /// 翻译 / 烧录阶段：保留信息卡 + 流水线进度 + 取消。
    private func pipelineState(_ info: VideoInfo, label: String) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    infoCard(info)
                    pipelineCard(label)
                }
                .frame(maxWidth: 500)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
            }
            Button("取消") {
                model.cancelDownload()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.vertical, 14)
        }
    }

    private func pipelineCard(_ label: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let p = model.pipelineProgress {
                let clamped = min(max(p, 0), 1)
                ProgressView(value: clamped)
                Text("\(label)（\(Int(clamped * 100))%）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("视频较长时需要几分钟…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private func doneState(_ info: VideoInfo, _ result: DownloadResult) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
                    .padding(.top, 24)
                Text("下载完成")
                    .font(.title3.weight(.semibold))
                if let notice = model.doneNotice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !result.files.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(result.files.enumerated()), id: \.element) { index, file in
                            HStack(spacing: 10) {
                                Image(systemName: fileIcon(for: file))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                Text(file.lastPathComponent)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            if index < result.files.count - 1 {
                                Divider().padding(.leading, 42)
                            }
                        }
                    }
                    .background(cardBackground)
                }
                HStack(spacing: 10) {
                    Button("在访达中显示") {
                        model.revealInFinder()
                    }
                    .buttonStyle(.borderedProminent)
                    if model.canRetryPostProcess {
                        Button("重试字幕处理") {
                            model.retryPostProcess()
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("下载新视频") {
                        model.reset()
                        urlFieldFocused = true
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
            }
            .frame(maxWidth: 500)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
        }
    }

    private func fileIcon(for file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "srt", "vtt", "ass":
            return "captions.bubble"
        case "m4a", "mp3", "opus", "aac":
            return "music.note"
        default:
            return "film"
        }
    }

    private func failedState(_ message: String) -> some View {
        // 两段式错误：第一行为中文主句，其余为原始错误详情。
        let parts = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
        let headline = parts.first.map(String.init) ?? message
        let detail = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
                    .padding(.top, 40)
                Text(headline)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 420)
                }
                HStack(spacing: 10) {
                    if model.failedNeedsLogin != nil {
                        Button("去登录") {
                            model.openLoginForFailure()
                        }
                        .buttonStyle(.borderedProminent)
                        Button("重试") {
                            model.retry()
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button("重试") {
                            model.retry()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button("重新开始") {
                        model.reset()
                        urlFieldFocused = true
                    }
                    .buttonStyle(.bordered)
                    if model.canReturnToList {
                        Button("返回列表") {
                            model.backToList()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .controlSize(.large)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 通用

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            VStack(spacing: 0, content: content)
                .background(cardBackground)
        }
    }

    private func infoCard(_ info: VideoInfo) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: info.thumbnailURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    Rectangle()
                        .fill(.quaternary)
                        .overlay(
                            Image(systemName: "film")
                                .foregroundStyle(.tertiary)
                        )
                }
            }
            .frame(width: 160, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(info.title)
                    .font(.headline)
                    .lineLimit(2)
                    .help(info.title)
                let meta = [info.durationText, info.uploader]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                if !meta.isEmpty {
                    Text(meta)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.quaternary.opacity(0.55))
    }
}
