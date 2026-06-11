import Foundation

/// 单个任务的暂停 / 取消令牌。下载（yt-dlp+ffmpeg）与烧录（ffmpeg）通过向进程树发
/// SIGSTOP/SIGCONT 实现真正的暂停；翻译（纯网络）在分块之间检查暂停闸门。
/// 一个 TaskControlToken 服务一个队列项的整条流水线，跨阶段复用。
public final class TaskControlToken: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var cancelled = false
    /// 当前阶段正在运行的子进程 pid（下载/烧录阶段非 0）
    private var activePID: Int32 = 0
    /// 暂停态下等待恢复的续延（翻译阶段用）
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return paused }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// 子进程启动后登记其 pid；阶段结束传 0 注销。
    public func setActivePID(_ pid: Int32) {
        lock.lock()
        activePID = pid
        let shouldPause = paused && pid != 0
        lock.unlock()
        if shouldPause { Self.signalTree(pid, SIGSTOP) }
    }

    public func pause() {
        lock.lock()
        guard !cancelled, !paused else { lock.unlock(); return }
        paused = true
        let pid = activePID
        lock.unlock()
        if pid != 0 { Self.signalTree(pid, SIGSTOP) }
    }

    public func resume() {
        lock.lock()
        guard paused else { lock.unlock(); return }
        paused = false
        let pid = activePID
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        if pid != 0 { Self.signalTree(pid, SIGCONT) }
        for w in pending { w.resume() }
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let pid = activePID
        let pending = waiters
        waiters.removeAll()
        // 取消时若处于暂停态，先 SIGCONT 让进程能响应后续 SIGINT/SIGKILL
        let wasPaused = paused
        paused = false
        lock.unlock()
        if pid != 0, wasPaused { Self.signalTree(pid, SIGCONT) }
        for w in pending { w.resume() }
    }

    /// 翻译等无子进程的阶段在每个工作单元前调用：暂停时挂起直到 resume，取消时抛出。
    public func gate() async throws {
        if Task.isCancelled || isCancelled { throw VDLError.cancelled }
        while true {
            let waitNeeded: Bool = {
                lock.lock(); defer { lock.unlock() }
                return paused && !cancelled
            }()
            if !waitNeeded { break }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if !paused || cancelled { lock.unlock(); c.resume(); return }
                waiters.append(c)
                lock.unlock()
            }
        }
        if Task.isCancelled || isCancelled { throw VDLError.cancelled }
    }

    /// 向 pid 及其全部子孙进程发信号（pgrep -P 递归）。暂停/恢复 yt-dlp 时
    /// 必须连同它派生的 ffmpeg 一起，否则只停了父进程、子进程仍在跑。
    static func signalTree(_ pid: Int32, _ sig: Int32) {
        guard pid > 0 else { return }
        // 后序：先对子孙发，再对自身发（恢复时顺序无关紧要，统一处理）
        for child in childPIDs(of: pid) { signalTree(child, sig) }
        kill(pid, sig)
    }

    private static func childPIDs(of pid: Int32) -> [Int32] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }
}
