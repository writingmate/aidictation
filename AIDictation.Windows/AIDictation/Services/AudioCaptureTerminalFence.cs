using System.Threading;

namespace AIDictation.Services;

/// <summary>
/// A capture session has one terminal owner. A write failure can fence frames
/// and release foreground state without calling a potentially blocking native
/// stop; a later native callback observes that it lost.
/// </summary>
public sealed class AudioCaptureTerminalFence
{
    private int _terminal;
    private int _acceptingFrames = 1;
    private int _stopRequested;

    public bool IsTerminal => Volatile.Read(ref _terminal) != 0;
    public bool IsAcceptingFrames => Volatile.Read(ref _acceptingFrames) != 0;
    public bool StopWasRequested => Volatile.Read(ref _stopRequested) != 0;

    public void MarkStopRequested() => Volatile.Write(ref _stopRequested, 1);
    public void StopAcceptingFrames() => Volatile.Write(ref _acceptingFrames, 0);

    public bool TryClaimTerminal()
    {
        var won = Interlocked.CompareExchange(ref _terminal, 1, 0) == 0;
        StopAcceptingFrames();
        return won;
    }
}
