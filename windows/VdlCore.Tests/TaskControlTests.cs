using Vdl.Core;

namespace VdlCore.Tests;

public class TaskControlTests
{
    [Fact]
    public async Task Gate_PassesWhenNotPaused()
    {
        var token = new TaskControlToken();
        await token.GateAsync();  // 不应阻塞或抛出
    }

    [Fact]
    public async Task Gate_BlocksWhilePaused_ResumeReleases()
    {
        var token = new TaskControlToken();
        token.Pause();
        Assert.True(token.IsPaused);

        var gate = token.GateAsync();
        await Task.Delay(100);
        Assert.False(gate.IsCompleted);  // 暂停中挂起

        token.Resume();
        await gate.WaitAsync(TimeSpan.FromSeconds(5));  // 恢复后放行
        Assert.False(token.IsPaused);
    }

    [Fact]
    public async Task Gate_CancelWhilePaused_ThrowsCancelled()
    {
        var token = new TaskControlToken();
        token.Pause();
        var gate = token.GateAsync();
        await Task.Delay(50);
        token.Cancel();
        var ex = await Assert.ThrowsAsync<VdlException>(() => gate.WaitAsync(TimeSpan.FromSeconds(5)));
        Assert.Equal(VdlErrorKind.Cancelled, ex.Kind);
        Assert.True(token.IsCancelled);
        Assert.False(token.IsPaused);  // 取消会清除暂停态
    }

    [Fact]
    public async Task Gate_AlreadyCancelled_ThrowsImmediately()
    {
        var token = new TaskControlToken();
        token.Cancel();
        var ex = await Assert.ThrowsAsync<VdlException>(() => token.GateAsync());
        Assert.Equal(VdlErrorKind.Cancelled, ex.Kind);
    }

    [Fact]
    public async Task Gate_ExternalCancellationToken_WakesWaiterAndThrows()
    {
        var token = new TaskControlToken();
        token.Pause();
        using var cts = new CancellationTokenSource();
        var gate = token.GateAsync(cts.Token);
        await Task.Delay(50);
        cts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => gate.WaitAsync(TimeSpan.FromSeconds(5)));
    }

    [Fact]
    public void Pause_AfterCancel_Ignored()
    {
        var token = new TaskControlToken();
        token.Cancel();
        token.Pause();
        Assert.False(token.IsPaused);
    }

    [Fact]
    public async Task Gate_MultipleWaiters_AllReleasedOnResume()
    {
        var token = new TaskControlToken();
        token.Pause();
        var gates = Enumerable.Range(0, 5).Select(_ => token.GateAsync()).ToArray();
        await Task.Delay(100);
        Assert.All(gates, g => Assert.False(g.IsCompleted));
        token.Resume();
        await Task.WhenAll(gates).WaitAsync(TimeSpan.FromSeconds(5));
    }
}
