import SwiftUI
#if canImport(VDLCore)
import VDLCore
#endif

/// 队列区。直接 @ObservedObject 观察 QueueManager —— 这是队列 UI 唯一的订阅点：
/// 进度 tick 只触发本子树重绘，不会放大成整窗刷新；也修复了此前
/// 「ViewModel 不转发 queue.objectWillChange 导致进度条冻结」的断裂。
struct QueueSectionView: View {
    @ObservedObject var queue: QueueManager

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("下载队列")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if queue.hasFinishedItems {
                    Button("清除已完成") {
                        queue.clearFinished()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
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
