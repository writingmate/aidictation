using System;

namespace AIDictation.Services;

/// <summary>
/// Reports usage only after the coordinator has committed the transcript,
/// durably updated History, delivered the result, and released foreground
/// ownership. AuthService owns its bounded network behavior.
/// </summary>
public sealed class CompletedTranscriptionUsageReporter : ICompletedTranscriptionUsageReporter
{
    public static CompletedTranscriptionUsageReporter Instance { get; } = new();

    private CompletedTranscriptionUsageReporter() { }

    public void Report(string text)
    {
        var words = text.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length;
        if (words > 0 && AuthService.Instance.IsAuthenticated)
            _ = AuthService.Instance.UpdateWordCountAsync(words);
    }
}
