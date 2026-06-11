import AppKit
import SwiftUI
#if canImport(VDLCore)
import VDLCore
#endif

/// 队列中的一行：缩略图 + 标题 + 阶段文案 + 进度条 + 右侧按钮组。
struct QueueItemView: View {
    let item: QueueManager.QueueItem
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onRemove: () -> Void
    let onReveal: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            thumbnail
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.title)
                statusLine
                if showsProgressBar {
                    progressBar
                }
            }
            Spacer(minLength: 8)
            buttons
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - 缩略图

    private var thumbnail: some View {
        AsyncImage(url: item.thumbnailURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                Rectangle()
                    .fill(.quaternary)
                    .overlay(Image(systemName: "film").foregroundStyle(.tertiary))
            }
        }
        .frame(width: 64, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    // MARK: - 文案

    private var statusLine: some View {
        Text(statusText)
            .font(.caption)
            .foregroundStyle(isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .lineLimit(2)
    }

    private var statusText: String {
        if item.isPaused { return "已暂停" }
        switch item.stage {
        case .queued:
            // 等槽位/等待恢复等具体原因（QueueManager 写入），没有就显示通用文案
            return item.statusText ?? "排队中…"
        case .downloading:
            if item.isPostDownloadProcessing { return "处理中…" }
            if let p = item.progress { return "下载中 \(Int(p * 100))%" }
            return "下载中…"
        case .translating:
            if let p = item.progress { return "翻译字幕中 \(Int(p * 100))%" }
            return "翻译字幕中…"
        case .burning:
            if let p = item.progress { return "烧录中 \(Int(p * 100))%" }
            return "烧录中…"
        case .done:
            return item.statusText ?? "已完成"
        case .cancelled:
            return item.statusText ?? "已取消"
        case .failed(let reason):
            return "失败：\(reason)"
        }
    }

    private var isFailed: Bool {
        if case .failed = item.stage { return true }
        return false
    }

    // MARK: - 进度条

    private var showsProgressBar: Bool {
        switch item.stage {
        case .queued, .downloading, .translating, .burning:
            return true
        case .done, .failed, .cancelled:
            return false
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if let p = item.progress {
            ProgressView(value: min(max(p, 0), 1))
                .tint(item.isPaused ? .gray : nil)
        } else {
            ProgressView()
                .progressViewStyle(.linear)
                .tint(item.isPaused ? .gray : nil)
        }
    }

    // MARK: - 按钮组

    @ViewBuilder
    private var buttons: some View {
        switch item.stage {
        case .queued, .downloading, .translating, .burning:
            HStack(spacing: 6) {
                if item.isPaused {
                    iconButton("play.fill", help: "继续", action: onResume)
                } else {
                    iconButton("pause.fill", help: "暂停", action: onPause)
                }
                iconButton("xmark", help: "取消", action: onCancel)
            }
        case .done:
            HStack(spacing: 6) {
                if item.partialFailure {
                    // 部分成功（视频已下载、字幕处理失败）：只重跑字幕处理，不重新下载
                    iconButton("arrow.clockwise", help: "重试字幕处理", action: onRetry)
                }
                if !item.resultFiles.isEmpty {
                    iconButton("folder", help: "在访达中显示", action: onReveal)
                }
                iconButton("trash", help: "移除", action: onRemove)
            }
        case .failed:
            HStack(spacing: 6) {
                iconButton("arrow.clockwise", help: "重试", action: onRetry)
                iconButton("trash", help: "移除", action: onRemove)
            }
        case .cancelled:
            HStack(spacing: 6) {
                iconButton("arrow.clockwise", help: "重试", action: onRetry)
                if !item.resultFiles.isEmpty {
                    iconButton("folder", help: "在访达中显示", action: onReveal)
                }
                iconButton("trash", help: "移除", action: onRemove)
            }
        }
    }

    private func iconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.bordered)
        .help(help)
        .accessibilityLabel(help)
    }
}
