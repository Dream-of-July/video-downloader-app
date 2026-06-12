import SwiftUI
#if canImport(VDLCore)
import VDLCore
#endif

/// 队列区。直接 @ObservedObject 观察 QueueManager —— 这是队列 UI 唯一的订阅点：
/// 进度 tick 只触发本子树重绘，不会放大成整窗刷新；也修复了此前
/// 「ViewModel 不转发 queue.objectWillChange 导致进度条冻结」的断裂。
struct QueueSectionView: View {
    @ObservedObject var queue: QueueManager
    /// 非 nil 时头部显示「收起」按钮（铺满态收回成底部小把手）。
    var onCollapse: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("下载队列")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(queue.items.count) 个任务")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                if queue.hasFinishedItems {
                    Button("清除已完成") {
                        queue.clearFinished()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                if let onCollapse {
                    Button {
                        onCollapse()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("收起队列")
                    .accessibilityLabel("收起队列")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                // Lazy：批量粘贴上百条时只实体化可见行
                LazyVStack(spacing: 0) {
                    ForEach(queue.items) { item in
                        QueueItemView(
                            item: item,
                            onPause: { queue.pause(item.id) },
                            onResume: { queue.resume(item.id) },
                            onCancel: { queue.cancel(item.id) },
                            onRetry: { queue.retry(item.id) },
                            onRemove: { queue.remove(item.id) },
                            onReveal: { queue.revealInFinder(item.id) }
                        )
                        Divider().padding(.leading, 86)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}
