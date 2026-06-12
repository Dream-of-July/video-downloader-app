import SwiftUI
#if canImport(VDLCore)
import VDLCore
#endif

/// 队列浮层：有任务时要么铺满内容区（expanded），要么缩成右下角小把手。
/// 直接观察 QueueManager（与 QueueSectionView 同理）：任务增删、进度 tick
/// 只重绘本子树；空队列时整层消失、不挡下层点击。
struct QueueOverlayView: View {
    @ObservedObject var queue: QueueManager
    @Binding var expanded: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if !queue.items.isEmpty {
                if expanded {
                    QueueSectionView(queue: queue) {
                        expanded = false
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.regularMaterial)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    handle
                        .padding([.bottom, .trailing], 14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: expanded)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: queue.items.isEmpty)
    }

    // MARK: - 小把手

    private var openCount: Int { queue.openTaskCount }

    /// 队列整体完成度：终态算 1，进行中按各自进度（未知进度按 0 计）。
    private var overallProgress: Double {
        guard !queue.items.isEmpty else { return 0 }
        let total = queue.items.reduce(0.0) { sum, item in
            switch item.stage {
            case .done, .failed, .cancelled:
                return sum + 1
            default:
                return sum + (item.progress ?? 0)
            }
        }
        return min(1, max(0, total / Double(queue.items.count)))
    }

    private var handleLabel: String {
        if openCount == 0 { return "全部完成" }
        if queue.pausedOpenTaskCount == openCount { return "\(openCount) 个已暂停" }
        return "\(openCount) 个进行中"
    }

    private var handle: some View {
        Button {
            expanded = true
        } label: {
            HStack(spacing: 8) {
                ProgressRingView(progress: overallProgress, finished: openCount == 0)
                Text(handleLabel)
                    .font(.callout)
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("展开下载队列")
        .accessibilityLabel("展开下载队列：\(handleLabel)")
    }
}

/// 小把手上的圆形整体进度环；全部到终态后换成对勾。
struct ProgressRingView: View {
    let progress: Double
    let finished: Bool

    var body: some View {
        ZStack {
            if finished {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.green)
            } else {
                Circle()
                    .stroke(.quaternary, lineWidth: 3)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: progress)
            }
        }
        .frame(width: 18, height: 18)
    }
}
