using AIDictation.Models;

namespace AIDictation.Services;

// The contract executable injects fakes into AudioProcessingCoordinator. These
// minimal singleton names let the production coordinator source compile without
// pulling WPF or WASAPI into the portable test target.
public sealed class AudioRecorderService : IAudioRecorderService
{
    public static AudioRecorderService Instance { get; } = new();
    public event EventHandler<RecorderCaptureFailedEventArgs>? CaptureTerminatedUnexpectedly
    {
        add { }
        remove { }
    }
    public Task<RecorderStartResult> StartRecordingAsync(
        AudioAttemptLease lease,
        string partialSourcePath,
        string? selectedDeviceId,
        CancellationToken cancellationToken) =>
        Task.FromResult(RecorderStartResult.Failure("contract singleton is not used"));
    public Task<RecorderFinalizationResult> StopRecordingAsync(
        AudioAttemptLease lease,
        TimeSpan? deadline = null,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new RecorderFinalizationResult(false, string.Empty, "contract singleton is not used"));
    public Task AbortRecordingAsync(
        AudioAttemptLease lease,
        string reason,
        CancellationToken cancellationToken = default) => Task.CompletedTask;
}

public sealed class TranscriptionService : ITranscriptionPipeline
{
    public static TranscriptionService Instance { get; } = new();
    public TranscriptionAttemptSnapshot CaptureAttemptSnapshot(string? providerOverride = null) =>
        new(providerOverride ?? "cloud", new[] { "en" }, null, null, true,
            Array.Empty<TextReplacementSnapshot>(), Array.Empty<TextReplacementSnapshot>(), null);
    public Task<TranscriptionResult> TranscribeAsync(
        string audioFilePath,
        TranscriptionAttemptSnapshot snapshot,
        Func<string, int, CancellationToken, Task<bool>> persistCheckpoint,
        Func<string, CancellationToken, Task<bool>> persistRawResult,
        CancellationToken cancellationToken) =>
        Task.FromResult(TranscriptionResult.Failure("contract singleton is not used"));
    public void AbandonLocalRecognition(TranscriptionAttemptSnapshot snapshot) { }
}

public sealed class HistoryService : IRecordingHistory
{
    public static HistoryService Instance { get; } = new();
    public bool PersistenceHealthy => true;
    public Recording? Get(Guid id) => null;
    public IReadOnlyList<Recording> GetAll() => Array.Empty<Recording>();
    public Task<bool> UpdateAsync(Recording recording, CancellationToken cancellationToken = default) =>
        Task.FromResult(true);
    public Task<bool> UpsertAsync(Recording recording, CancellationToken cancellationToken = default) =>
        Task.FromResult(true);
    public Task<bool> RemoveMetadataAfterTombstoneAsync(Guid id, CancellationToken cancellationToken = default) =>
        Task.FromResult(true);
    public Task<bool> ClearMetadataAfterTombstoneAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult(true);
}

public sealed class CompletedTranscriptionUsageReporter : ICompletedTranscriptionUsageReporter
{
    public static CompletedTranscriptionUsageReporter Instance { get; } = new();
    public void Report(string text) { }
}

public sealed class AppState : IAudioAppState
{
    public static AppState Shared { get; } = new();
    public bool StartPreparing(bool isCommandMode = false) => true;
    public bool RecordingBecameReady() => true;
    public bool StartFinalizing() => true;
    public bool StartProcessing() => true;
    public bool StartRetrying() => true;
    public bool SetResult(string text) => true;
    public bool SetError(string message) => true;
    public void Reset() { }
}
