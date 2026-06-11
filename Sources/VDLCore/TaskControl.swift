import Foundation

#if os(Windows)
/// Windows 没有 POSIX 信号。给出同名占位常量让共享代码编译；
/// 语义映射：SIGSTOP/SIGCONT → 不支持（no-op，进程级暂停不可用）；
/// SIGINT/SIGKILL → taskkill 终止（/T 连子进程）。详见 docs/WINDOWS.md。
let SIGSTOP: Int32 = 17
let SIGCONT: Int32 = 19
let SIGINT: Int32 = 2
let SIGKILL: Int32 = 9
#endif

/// 单个任务的暂停 / 取消令牌。下载（yt-dlp+ffmpeg）与烧录（ffmpeg）通过向进程树发
/// SIGSTOP/SIGCONT 实现真正的暂停；翻译（纯网络）在分块之间检查暂停闸门。
/// 一个 TaskControlToken 服务一个队列项的整条流水线，跨阶段复用。
/// Windows 上进程级暂停不可用（SIGSTOP/SIGCONT 为 no-op），取消仍有效。
public final class TaskControlToken: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var cancelled = false
    /// 当前阶段正在运行的子进程 pid（下载/烧录阶段非 0）
    private var activePID: Int32 = 0
    /// 暂停态下等待恢复的续延（翻译阶段用）；带票据以支持 Task 取消时摘除
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []

    /// 信号发送统一走串行后台队列：pgrep 枚举进程树有可感耗时，不能卡主线程；
    /// 串行保证 pause→resume 连点时信号顺序不乱。
    private static let signalQueue = DispatchQueue(label: "vdl.taskcontrol.signal", qos: .userInitiated)

    public init() {}

    public var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return paused }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// 子进程启动后登记其 pid；阶段结束传 0 注销。
    public func setActivePID(_ pid: Int32) {
        lock.lock()
        activePID = pid
        let shouldPause = paused && pid != 0
        lock.unlock()
        if shouldPause {
            Self.signalQueue.async { Self.signalTree(pid, SIGSTOP) }
        }
    }

    public func pause() {
        lock.lock()
        guard !cancelled, !paused else { lock.unlock(); return }
        paused = true
        let pid = activePID
        lock.unlock()
        if pid != 0 {
            Self.signalQueue.async { Self.signalTree(pid, SIGSTOP) }
        }
    }

    public func resume() {
        lock.lock()
        guard paused else { lock.unlock(); return }
        paused = false
        let pid = activePID
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        if pid != 0 {
            Self.signalQueue.async { Self.signalTree(pid, SIGCONT) }
        }
        for waiter in pending { waiter.continuation.resume() }
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
        if pid != 0 {
            Self.signalQueue.async {
                if wasPaused { Self.signalTree(pid, SIGCONT) }
                // 令牌取消独立生效（不依赖调用方配对 Task.cancel）：
                // 先 SIGINT 走子进程自身清理，3 秒未退则进程树 SIGKILL 兜底。
                #if os(Windows)
                Self.signalTree(pid, SIGINT)
                #else
                kill(pid, SIGINT)
                #endif
                Self.signalQueue.asyncAfter(deadline: .now() + 3) {
                    Self.signalTree(pid, SIGKILL)
                }
            }
        }
        for waiter in pending { waiter.continuation.resume() }
    }

    /// 翻译等无子进程的阶段在每个工作单元前调用：暂停时挂起直到 resume，取消时抛出。
    /// 同时响应 Swift Task 取消（任务组某块抛错隐式取消兄弟任务时，挂起者会被唤醒并抛出，
    /// 不会永远卡在闸门里）。
    public func gate() async throws {
        if Task.isCancelled || isCancelled { throw VDLError.cancelled }
        while true {
            let waitNeeded: Bool = {
                lock.lock(); defer { lock.unlock() }
                return paused && !cancelled
            }()
            if !waitNeeded { break }
            let ticket = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    lock.lock()
                    // 挂起前再查一次：取消（含 Task 取消）/已恢复 都不入队，直接放行。
                    if !paused || cancelled || Task.isCancelled {
                        lock.unlock()
                        c.resume()
                        return
                    }
                    waiters.append((ticket, c))
                    lock.unlock()
                }
            } onCancel: {
                self.wakeWaiter(ticket)
            }
            if Task.isCancelled || isCancelled { throw VDLError.cancelled }
        }
        if Task.isCancelled || isCancelled { throw VDLError.cancelled }
    }

    private func wakeWaiter(_ ticket: UUID) {
        lock.lock()
        guard let index = waiters.firstIndex(where: { $0.id == ticket }) else {
            lock.unlock()
            return
        }
        let continuation = waiters[index].continuation
        waiters.remove(at: index)
        lock.unlock()
        continuation.resume()
    }

    #if os(Windows)
    /// Windows：暂停/恢复不支持（no-op）；SIGINT/SIGKILL 用 taskkill /T 连子进程终止。
    static func signalTree(_ pid: Int32, _ sig: Int32) {
        guard pid > 0 else { return }
        guard sig == SIGINT || sig == SIGKILL else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\taskkill.exe")
        p.arguments = ["/PID", String(pid), "/T", "/F"]
        try? p.run()
        p.waitUntilExit()
    }
    #else
    /// 向 pid 及其全部子孙进程发信号。SIGSTOP 先停父进程再停子孙（防止枚举与暂停之间
    /// fork 出的新子进程逃逸继续跑）；其余信号先子后父。
    static func signalTree(_ pid: Int32, _ sig: Int32) {
        guard pid > 0 else { return }
        if sig == SIGSTOP {
            kill(pid, sig)
            for child in childPIDs(of: pid) { signalTree(child, sig) }
        } else {
            for child in childPIDs(of: pid) { signalTree(child, sig) }
            kill(pid, sig)
        }
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
    #endif
}
