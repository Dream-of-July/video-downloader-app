using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Vdl.Core;

/// <summary>
/// 单个任务的暂停 / 取消令牌。下载（yt-dlp+ffmpeg）与烧录（ffmpeg）通过挂起/恢复进程树
/// 实现真正的暂停（Windows: NtSuspendProcess/NtResumeProcess）；翻译（纯网络）在分块之间
/// 检查暂停闸门。一个 TaskControlToken 服务一个队列项的整条流水线，跨阶段复用。
/// 非 Windows 平台进程级暂停为 no-op（本库的运行时目标是 Windows，mac 上只为可测试编译）。
/// </summary>
public sealed class TaskControlToken
{
    private readonly object _lock = new();
    private bool _paused;
    private bool _cancelled;
    /// <summary>当前阶段正在运行的子进程 pid（下载/烧录阶段非 0）。</summary>
    private int _activePid;
    /// <summary>暂停态下等待恢复的续延（翻译阶段用）；带票据以支持 CancellationToken 取消时摘除。</summary>
    private readonly List<(Guid Ticket, TaskCompletionSource Tcs)> _waiters = [];

    /// <summary>
    /// 信号发送统一走串行链：进程树枚举有可感耗时，不能卡调用线程；
    /// 串行保证 pause→resume 连点时信号顺序不乱（等价 Swift 的串行 DispatchQueue）。
    /// </summary>
    private static readonly object ChainLock = new();
    private static Task _signalChain = Task.CompletedTask;

    private static void EnqueueSignal(Action action)
    {
        lock (ChainLock)
        {
            _signalChain = _signalChain.ContinueWith(
                _ => { try { action(); } catch { /* 信号失败不影响主流程 */ } },
                CancellationToken.None,
                TaskContinuationOptions.RunContinuationsAsynchronously,
                TaskScheduler.Default);
        }
    }

    public bool IsPaused { get { lock (_lock) return _paused; } }
    public bool IsCancelled { get { lock (_lock) return _cancelled; } }

    /// <summary>子进程启动后登记其 pid；阶段结束传 0 注销。已处于暂停态时立即挂起新进程。</summary>
    public void SetActivePid(int pid)
    {
        bool shouldPause;
        lock (_lock)
        {
            _activePid = pid;
            shouldPause = _paused && pid != 0;
        }
        if (shouldPause)
        {
            EnqueueSignal(() => ProcessTree.SuspendTree(pid));
        }
    }

    public void Pause()
    {
        int pid;
        lock (_lock)
        {
            if (_cancelled || _paused) return;
            _paused = true;
            pid = _activePid;
        }
        if (pid != 0)
        {
            EnqueueSignal(() => ProcessTree.SuspendTree(pid));
        }
    }

    public void Resume()
    {
        int pid;
        List<(Guid, TaskCompletionSource)> pending;
        lock (_lock)
        {
            if (!_paused) return;
            _paused = false;
            pid = _activePid;
            pending = [.. _waiters];
            _waiters.Clear();
        }
        if (pid != 0)
        {
            EnqueueSignal(() => ProcessTree.ResumeTree(pid));
        }
        foreach (var (_, tcs) in pending) tcs.TrySetResult();
    }

    public void Cancel()
    {
        int pid;
        bool wasPaused;
        List<(Guid, TaskCompletionSource)> pending;
        lock (_lock)
        {
            _cancelled = true;
            pid = _activePid;
            pending = [.. _waiters];
            _waiters.Clear();
            // 取消时若处于暂停态，先恢复让进程能正常退出清理
            wasPaused = _paused;
            _paused = false;
        }
        if (pid != 0)
        {
            EnqueueSignal(() =>
            {
                if (wasPaused) ProcessTree.ResumeTree(pid);
                // 令牌取消独立生效（不依赖调用方配对 CancellationToken）：
                // Process.Kill(entireProcessTree: true) 一次连子进程终止。
                ProcessTree.KillTree(pid);
            });
        }
        foreach (var (_, tcs) in pending) tcs.TrySetResult();
    }

    /// <summary>
    /// 翻译等无子进程的阶段在每个工作单元前调用：暂停时挂起直到 Resume，取消时抛出。
    /// 同时响应 CancellationToken（外部取消会唤醒挂起者并抛出，不会永远卡在闸门里）。
    /// 令牌取消抛 VdlException(Cancelled)，ct 取消抛 OperationCanceledException。
    /// </summary>
    public async Task GateAsync(CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        if (IsCancelled) throw VdlException.Cancelled();
        while (true)
        {
            TaskCompletionSource? tcs = null;
            var ticket = Guid.Empty;
            lock (_lock)
            {
                // 挂起前再查一次：已恢复 / 已取消都不入队，直接放行（由循环外检查抛出）。
                if (_paused && !_cancelled && !ct.IsCancellationRequested)
                {
                    ticket = Guid.NewGuid();
                    tcs = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                    _waiters.Add((ticket, tcs));
                }
            }
            if (tcs is null) break;
            // ct 取消时摘除并唤醒对应票据的挂起者（等价 Swift 的 withTaskCancellationHandler）。
            await using (ct.Register(() => WakeWaiter(ticket)).ConfigureAwait(false))
            {
                await tcs.Task.ConfigureAwait(false);
            }
            ct.ThrowIfCancellationRequested();
            if (IsCancelled) throw VdlException.Cancelled();
        }
        ct.ThrowIfCancellationRequested();
        if (IsCancelled) throw VdlException.Cancelled();
    }

    private void WakeWaiter(Guid ticket)
    {
        TaskCompletionSource? tcs = null;
        lock (_lock)
        {
            var index = _waiters.FindIndex(w => w.Ticket == ticket);
            if (index >= 0)
            {
                tcs = _waiters[index].Tcs;
                _waiters.RemoveAt(index);
            }
        }
        tcs?.TrySetResult();
    }
}

/// <summary>
/// 进程树挂起 / 恢复 / 终止。Windows 用 NtSuspendProcess/NtResumeProcess（ntdll）+
/// CreateToolhelp32Snapshot（kernel32）枚举子进程递归；其他平台为 no-op（Kill 除外）。
/// 所有 P/Invoke 调用点都有 OperatingSystem.IsWindows() 守卫，mac 上只编译不执行。
/// </summary>
internal static class ProcessTree
{
    /// <summary>
    /// 挂起 pid 及其全部子孙进程。先停父进程再停子孙：防止枚举与挂起之间
    /// fork 出的新子进程逃逸继续跑（与 Swift signalTree(SIGSTOP) 一致）。
    /// </summary>
    internal static void SuspendTree(int pid)
    {
        if (!OperatingSystem.IsWindows() || pid <= 0) return;
        SuspendProcess(pid);
        foreach (var child in ChildPids(pid))
        {
            SuspendTree(child);
        }
    }

    /// <summary>恢复 pid 及其子孙。先子后父（与 Swift signalTree 非 SIGSTOP 分支一致）。</summary>
    internal static void ResumeTree(int pid)
    {
        if (!OperatingSystem.IsWindows() || pid <= 0) return;
        foreach (var child in ChildPids(pid))
        {
            ResumeTree(child);
        }
        ResumeProcess(pid);
    }

    /// <summary>终止 pid 及其整棵进程树。跨平台（Process.Kill 自带子进程枚举）。</summary>
    internal static void KillTree(int pid)
    {
        if (pid <= 0) return;
        try
        {
            using var process = Process.GetProcessById(pid);
            process.Kill(entireProcessTree: true);
        }
        catch
        {
            // 进程已退出 / 无权限：忽略
        }
    }

    // MARK: Windows P/Invoke

    private const uint ProcessSuspendResume = 0x0800;
    private const uint Th32CsSnapProcess = 0x00000002;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ProcessEntry32W
    {
        public uint dwSize;
        public uint cntUsage;
        public uint th32ProcessID;
        public IntPtr th32DefaultHeapID;
        public uint th32ModuleID;
        public uint cntThreads;
        public uint th32ParentProcessID;
        public int pcPriClassBase;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string szExeFile;
    }

    [DllImport("ntdll.dll")]
    private static extern int NtSuspendProcess(IntPtr processHandle);

    [DllImport("ntdll.dll")]
    private static extern int NtResumeProcess(IntPtr processHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint desiredAccess, bool inheritHandle, int processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint th32ProcessId);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool Process32FirstW(IntPtr snapshot, ref ProcessEntry32W entry);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool Process32NextW(IntPtr snapshot, ref ProcessEntry32W entry);

    private static void SuspendProcess(int pid)
    {
        if (!OperatingSystem.IsWindows()) return;
        var handle = OpenProcess(ProcessSuspendResume, false, pid);
        if (handle == IntPtr.Zero) return;
        try { _ = NtSuspendProcess(handle); }
        finally { CloseHandle(handle); }
    }

    private static void ResumeProcess(int pid)
    {
        if (!OperatingSystem.IsWindows()) return;
        var handle = OpenProcess(ProcessSuspendResume, false, pid);
        if (handle == IntPtr.Zero) return;
        try { _ = NtResumeProcess(handle); }
        finally { CloseHandle(handle); }
    }

    /// <summary>用 Toolhelp 快照枚举 pid 的直接子进程。非 Windows 返回空。</summary>
    private static List<int> ChildPids(int pid)
    {
        var children = new List<int>();
        if (!OperatingSystem.IsWindows()) return children;
        var snapshot = CreateToolhelp32Snapshot(Th32CsSnapProcess, 0);
        if (snapshot == IntPtr.Zero || snapshot == new IntPtr(-1)) return children;
        try
        {
            var entry = new ProcessEntry32W { dwSize = (uint)Marshal.SizeOf<ProcessEntry32W>() };
            if (!Process32FirstW(snapshot, ref entry)) return children;
            do
            {
                if (entry.th32ParentProcessID == (uint)pid)
                {
                    children.Add((int)entry.th32ProcessID);
                }
            }
            while (Process32NextW(snapshot, ref entry));
        }
        finally
        {
            CloseHandle(snapshot);
        }
        return children;
    }
}
