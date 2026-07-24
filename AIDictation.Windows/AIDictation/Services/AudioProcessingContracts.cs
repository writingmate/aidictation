using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using AIDictation.Models;

namespace AIDictation.Services;

public sealed record RecorderStartResult(
    bool IsReady,
    string? ErrorMessage,
    bool KnownIncomplete = false)
{
    public static RecorderStartResult Ready() => new(true, null);
    public static RecorderStartResult Failure(
        string message,
        bool knownIncomplete = false) =>
        new(false, message, knownIncomplete);
}

public sealed record RecorderFinalizationResult(
    bool IsFinalized,
    string PartialSourcePath,
    string? ErrorMessage,
    bool TimedOut = false,
    bool KnownIncomplete = false);

public sealed class RecorderCaptureFailedEventArgs : EventArgs
{
    public AudioAttemptLease Lease { get; }
    public string Message { get; }

    public RecorderCaptureFailedEventArgs(AudioAttemptLease lease, string message)
    {
        Lease = lease;
        Message = message;
    }
}

public sealed class TranscriptionResult
{
    public bool IsSuccess { get; private set; }
    public string? Text { get; private set; }
    public string? RawText { get; private set; }
    public string? ErrorMessage { get; private set; }

    private TranscriptionResult() { }

    public static TranscriptionResult Success(string text, string? rawText = null) => new()
    {
        IsSuccess = true,
        Text = text,
        RawText = rawText ?? text
    };

    public static TranscriptionResult Failure(string errorMessage) => new()
    {
        IsSuccess = false,
        ErrorMessage = errorMessage
    };
}

public interface IAudioProcessingStore
{
    bool PersistenceHealthy { get; }
    Task<AudioStoreMutation> BeginCaptureAsync(
        TranscriptionAttemptSnapshot snapshot,
        Guid? requestedRecordingId = null,
        CancellationToken cancellationToken = default);
    Task<AudioStoreMutation> CaptureBecameReadyAsync(
        AudioAttemptLease lease,
        CancellationToken cancellationToken = default);
    Task<AudioStoreMutation> BeginFinalizationAsync(
        AudioAttemptLease lease,
        CancellationToken cancellationToken = default);
    Task<AudioStoreMutation> AdoptFinalizedCaptureAsync(
        AudioAttemptLease lease,
        RecorderFinalizationResult proof,
        CancellationToken cancellationToken = default);
    Task<AudioStoreMutation> RecordCaptureKnownIncompleteAsync(
        AudioAttemptLease lease,
        string message,
        CancellationToken cancellationToken = default);
    Task<AudioStoreMutation> BeginRecognitionAsync(
        Guid recordingId,
        TranscriptionAttemptSnapshot snapshot,
        CancellationToken cancellationToken = default);
    Task<AudioStoreMutation> SaveCheckpointAsync(
        AudioAttemptLease lease,
        string orderedText,
        int completedLeafCount,
        CancellationToken cancellationToken = default);
    Task<AudioStoreMutation> SaveRawResultAsync(
        AudioAttemptLease lease,
        string rawText,
        CancellationToken cancellationToken = default);
    Task<AudioStoreMutation> CompleteAsync(
        AudioAttemptLease lease,
        string finalText,
        CancellationToken cancellationToken = default);
    Task<AudioUsageClaim?> ClaimUsageAsync(
        Guid recordingId,
        CancellationToken cancellationToken = default);
    Task<AudioStoreMutation> FailAsync(
        AudioAttemptLease lease,
        string message,
        AudioSourceIntegrity? integrity = null,
        CancellationToken cancellationToken = default);
    Task<AudioStoreMutation> CancelAsync(
        AudioAttemptLease lease,
        string message,
        CancellationToken cancellationToken = default);
    Task<AudioStoreMutation> AbandonAttemptAsync(
        AudioAttemptLease lease,
        bool cancelled,
        string message,
        AudioSourceIntegrity integrity,
        CancellationToken cancellationToken = default);
    Task<AudioStoreMutation> TombstoneAsync(
        Guid recordingId,
        CancellationToken cancellationToken = default);
    Task<AudioStoreMutation> ClearAsync(CancellationToken cancellationToken = default);
    Task<IReadOnlyList<AudioProcessingEntry>> RecoverOnLaunchAsync(
        CancellationToken cancellationToken = default);
    Task<AudioStoreMutation> ImportLegacyFinalizedSourceAsync(
        Guid recordingId,
        string legacySourcePath,
        string? finalText,
        TranscriptionAttemptSnapshot snapshot,
        CancellationToken cancellationToken = default);
    Task<bool> AcceptLegacySourceOwnershipAsync(
        Guid recordingId,
        CancellationToken cancellationToken = default);
    Task<AudioProcessingEntry?> GetAsync(
        Guid recordingId,
        CancellationToken cancellationToken = default);
}

public interface IAudioRecorderService
{
    event EventHandler<RecorderCaptureFailedEventArgs>? CaptureTerminatedUnexpectedly;
    Task<RecorderStartResult> StartRecordingAsync(
        AudioAttemptLease lease,
        string partialSourcePath,
        string? selectedDeviceId,
        CancellationToken cancellationToken);
    Task<RecorderFinalizationResult> StopRecordingAsync(
        AudioAttemptLease lease,
        TimeSpan? deadline = null,
        CancellationToken cancellationToken = default);
    Task<RecorderFinalizationResult?> AbortRecordingAsync(
        AudioAttemptLease lease,
        string reason,
        TimeSpan? deadline = null,
        CancellationToken cancellationToken = default);
    Task<RecorderFinalizationResult?> ShutdownAsync(
        AudioAttemptLease? activeLease,
        TimeSpan deadline,
        CancellationToken cancellationToken = default);
}

public interface ITranscriptionPipeline
{
    TranscriptionAttemptSnapshot CaptureAttemptSnapshot(string? providerOverride = null);
    Task<TranscriptionResult> TranscribeAsync(
        string audioFilePath,
        TranscriptionAttemptSnapshot snapshot,
        Func<string, int, CancellationToken, Task<bool>> persistCheckpoint,
        Func<string, CancellationToken, Task<bool>> persistRawResult,
        CancellationToken cancellationToken);
    void AbandonLocalRecognition(TranscriptionAttemptSnapshot snapshot);
}

public interface IRecordingHistory
{
    bool PersistenceHealthy { get; }
    Recording? Get(Guid id);
    IReadOnlyList<Recording> GetAll();
    Task<bool> UpdateAsync(
        Recording recording,
        CancellationToken cancellationToken = default);
    Task<bool> UpsertAsync(
        Recording recording,
        CancellationToken cancellationToken = default);
    Task<bool> RemoveMetadataAfterTombstoneAsync(
        Guid id,
        CancellationToken cancellationToken = default);
    Task<bool> RemoveMetadataAfterTombstonesAsync(
        IReadOnlyCollection<Guid> ids,
        CancellationToken cancellationToken = default);
    Task<bool> ClearMetadataAfterTombstoneAsync(
        CancellationToken cancellationToken = default);
}

public interface ICompletedTranscriptionUsageReporter
{
    void Report(string text);
}

public interface IAudioAppState
{
    bool StartPreparing(bool isCommandMode = false);
    bool RecordingBecameReady();
    bool StartFinalizing();
    bool StartProcessing();
    bool StartRetrying();
    bool SetResult(string text);
    bool SetError(string message);
    void Reset();
}
