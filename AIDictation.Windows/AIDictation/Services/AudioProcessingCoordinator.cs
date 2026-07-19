using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using AIDictation.Models;

namespace AIDictation.Services;

public sealed record CaptureStartOutcome(bool Started, Guid? RecordingId, string? ErrorMessage);

public sealed record AudioCoordinatorDeadlines(
    TimeSpan StoreOperation,
    TimeSpan MinimumRecognition,
    TimeSpan MaximumRecognition)
{
    public static AudioCoordinatorDeadlines Production { get; } = new(
        TimeSpan.FromSeconds(5),
        TimeSpan.FromSeconds(150),
        TimeSpan.FromMinutes(10));
}

/// <summary>
/// The only owner of the Windows audio-processing workflow. UI callers request
/// transitions; recorder/network callbacks never write History directly.
/// </summary>
public sealed class AudioProcessingCoordinator
{
    private sealed class ActiveAttempt
    {
        public required AudioAttemptLease Lease;
        public required TranscriptionAttemptSnapshot Snapshot;
        public required string SourcePath;
        public required DateTimeOffset StartedUtc;
        public required bool IsCommandMode;
        public AudioSourceIntegrity SourceIntegrity;
        public volatile bool IsRecognition;
        public volatile bool UserCancelled;
        public volatile string? DurableRawText;
        public int Abandoned;
        public int PipelineFenced;
        public required CancellationTokenSource Cancellation;
        public SemaphoreSlim MutationGate { get; } = new(1, 1);
    }

    private sealed class PendingStart
    {
        public CancellationTokenSource Cancellation { get; } = new();
        public volatile bool UserCancelled;
    }

    // Leaves have a 45-second request deadline; 150 seconds leaves room for
    // all three attempts plus bounded backoff without allowing an endless UI.
    private readonly IAudioProcessingStore _store;
    private readonly IAudioRecorderService _recorder;
    private readonly ITranscriptionPipeline _transcription;
    private readonly IRecordingHistory _history;
    private readonly IAudioAppState _appState;
    private readonly ICompletedTranscriptionUsageReporter _usageReporter;
    private readonly AudioCoordinatorDeadlines _deadlines;
    private readonly SemaphoreSlim _lifecycleGate = new(1, 1);
    private readonly object _activeLock = new();
    private ActiveAttempt? _active;
    private PendingStart? _pendingStart;

    public static AudioProcessingCoordinator Instance { get; } = new(
        AudioProcessingStore.Instance,
        AudioRecorderService.Instance,
        TranscriptionService.Instance,
        HistoryService.Instance,
        AppState.Shared,
        usageReporter: CompletedTranscriptionUsageReporter.Instance);

    public AudioProcessingCoordinator(
        IAudioProcessingStore store,
        IAudioRecorderService recorder,
        ITranscriptionPipeline transcription,
        IRecordingHistory history,
        IAudioAppState appState,
        AudioCoordinatorDeadlines? deadlines = null,
        ICompletedTranscriptionUsageReporter? usageReporter = null)
    {
        _store = store;
        _recorder = recorder;
        _transcription = transcription;
        _history = history;
        _appState = appState;
        _usageReporter = usageReporter ?? CompletedTranscriptionUsageReporter.Instance;
        _deadlines = deadlines ?? AudioCoordinatorDeadlines.Production;
        _recorder.CaptureTerminatedUnexpectedly += OnCaptureTerminatedUnexpectedly;
    }

    public bool HasActiveAttempt
    {
        get { lock (_activeLock) return _active != null; }
    }

    public bool IsCapturing
    {
        get { lock (_activeLock) return _active is { IsRecognition: false }; }
    }

    public async Task RecoverOnLaunchAsync(CancellationToken cancellationToken = default)
    {
        var historyReady = _history.PersistenceHealthy;
        System.Collections.Generic.List<AudioProcessingEntry> entries;
        try
        {
            entries = (await _store.RecoverOnLaunchAsync(cancellationToken).ConfigureAwait(false)).ToList();
        }
        catch (Exception ex)
        {
            _appState.SetError(ex.Message);
            return;
        }
        var knownIds = entries.Select(entry => entry.RecordingId).ToHashSet();
        var migrationSnapshot = _transcription.CaptureAttemptSnapshot();
        foreach (var legacy in _history.GetAll().Where(recording => !knownIds.Contains(recording.Id)))
        {
            if (string.IsNullOrWhiteSpace(legacy.AudioFilePath) || !File.Exists(legacy.AudioFilePath))
                continue;
            AudioStoreMutation imported;
            try
            {
                imported = await _store.ImportLegacyFinalizedSourceAsync(
                        legacy.Id,
                        legacy.AudioFilePath,
                        legacy.Transcription,
                        migrationSnapshot,
                        cancellationToken)
                    .ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                imported = new AudioStoreMutation(false, null, null, ex.Message);
            }
            if (imported.Applied && imported.Entry != null)
            {
                entries.Add(imported.Entry);
                knownIds.Add(legacy.Id);
            }
            else
            {
                legacy.Status = TranscriptionStatus.Failed;
                legacy.SourceIntegrity = RecordingSourceIntegrity.KnownIncomplete;
                legacy.ErrorMessage = imported.RejectionReason ??
                                      "This older recording is incomplete and cannot be retried safely.";
                historyReady &= await TryRunHistoryWithDeadlineAsync(
                        token => _history.UpdateAsync(legacy, token),
                        cancellationToken)
                    .ConfigureAwait(false);
            }
        }
        foreach (var entry in entries.OrderBy(item => item.CreatedUtc))
        {
            if (entry.Stage == AudioProcessingStage.Deleted)
            {
                historyReady &= await TryRunHistoryWithDeadlineAsync(
                        token => _history.RemoveMetadataAfterTombstoneAsync(entry.RecordingId, token),
                        cancellationToken)
                    .ConfigureAwait(false);
                continue;
            }
            var repointed = await TryRunHistoryWithDeadlineAsync(
                    token => _history.UpsertAsync(
                        ToHistoryRecording(entry, _history.Get(entry.RecordingId)),
                        token),
                    cancellationToken)
                .ConfigureAwait(false);
            historyReady &= repointed;
            if (repointed && entry.LegacySourceOwned)
            {
                try
                {
                    _ = await _store.AcceptLegacySourceOwnershipAsync(entry.RecordingId, cancellationToken)
                        .ConfigureAwait(false);
                }
                catch
                {
                    // Ownership remains journaled and is retried on launch or
                    // when the recording is deleted/History is cleared.
                }
            }
        }
        if (historyReady)
            _appState.Reset();
        else
            _appState.SetError("History could not be restored. Your recovery audio was kept on disk.");
    }

    public async Task<CaptureStartOutcome> StartCaptureAsync(
        bool isCommandMode,
        string? selectedDeviceId,
        CancellationToken cancellationToken = default)
    {
        // Capture foreground context/settings before the first await.
        var snapshot = _transcription.CaptureAttemptSnapshot();
        if (!_appState.StartPreparing(isCommandMode))
            return new CaptureStartOutcome(false, null, "Another recording is already active.");

        var pending = new PendingStart();
        lock (_activeLock) _pendingStart = pending;
        using var linkedStartCancellation = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken,
            pending.Cancellation.Token);
        var startToken = linkedStartCancellation.Token;
        var lifecycleHeld = false;
        ActiveAttempt? active = null;
        try
        {
            await _lifecycleGate.WaitAsync(startToken).ConfigureAwait(false);
            lifecycleHeld = true;
            if (GetActive() != null)
            {
                _appState.SetError("Another recording is already active.");
                return new CaptureStartOutcome(false, null, "Another recording is already active.");
            }

            AudioStoreMutation begin;
            var requestedRecordingId = Guid.NewGuid();
            try
            {
                begin = await RunStoreWithDeadlineAsync(
                        () => _store.BeginCaptureAsync(
                            snapshot,
                            requestedRecordingId,
                            startToken),
                        startToken,
                        result => ReconcileLateCaptureStartAsync(
                            result,
                            pending.UserCancelled || startToken.IsCancellationRequested))
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (pending.UserCancelled || startToken.IsCancellationRequested)
            {
                if (OwnsPendingStart(pending)) _appState.Reset();
                return new CaptureStartOutcome(false, null, "Recording startup was cancelled.");
            }
            catch (Exception ex)
            {
                if (pending.UserCancelled)
                {
                    return new CaptureStartOutcome(false, null, "Recording startup was cancelled.");
                }
                if (OwnsPendingStart(pending)) _appState.SetError(ex.Message);
                return new CaptureStartOutcome(false, null, ex.Message);
            }
            if (!OwnsPendingStart(pending) || pending.UserCancelled || startToken.IsCancellationRequested)
            {
                _ = ReconcileLateCaptureStartAsync(begin, cancelled: true);
                return new CaptureStartOutcome(false, begin.Entry?.RecordingId, "Recording startup was cancelled.");
            }
            if (!begin.Applied || begin.Lease == null || begin.Entry == null)
            {
                var message = begin.RejectionReason ?? "The recording could not be prepared.";
                _appState.SetError(message);
                return new CaptureStartOutcome(false, null, message);
            }

            active = new ActiveAttempt
            {
                Lease = begin.Lease,
                Snapshot = snapshot,
                SourcePath = begin.Entry.PartialSourcePath,
                StartedUtc = DateTimeOffset.UtcNow,
                IsCommandMode = isCommandMode,
                SourceIntegrity = AudioSourceIntegrity.Unfinalized,
                Cancellation = pending.Cancellation
            };
            if (!TrySetActiveForPending(pending, active))
            {
                active.UserCancelled = true;
                AbandonForegroundAttempt(
                    active,
                    "Recording startup was cancelled.",
                    cancelled: true,
                    AudioSourceIntegrity.Unfinalized,
                    duration: null,
                    publishState: false);
                return new CaptureStartOutcome(false, active.Lease.RecordingId, "Recording startup was cancelled.");
            }
            if (pending.UserCancelled || startToken.IsCancellationRequested)
            {
                active.UserCancelled = true;
                AbandonForegroundAttempt(
                    active,
                    "Recording startup was cancelled.",
                    cancelled: true,
                    AudioSourceIntegrity.Unfinalized,
                    duration: null);
                return new CaptureStartOutcome(false, active.Lease.RecordingId, "Recording startup was cancelled.");
            }
            if (!await RunHistoryWithDeadlineAsync(
                    token => _history.UpsertAsync(ToHistoryRecording(begin.Entry, null), token),
                    startToken)
                .ConfigureAwait(false))
            {
                AbandonForegroundAttempt(
                    active,
                    "The recording could not be added to History. Check available storage.",
                    cancelled: false,
                    AudioSourceIntegrity.Unfinalized,
                    duration: null);
                return new CaptureStartOutcome(false, begin.Entry.RecordingId,
                    "The recording could not be saved. Check available storage.");
            }

            if (pending.UserCancelled || startToken.IsCancellationRequested || IsAbandoned(active))
            {
                active.UserCancelled = true;
                AbandonForegroundAttempt(
                    active,
                    "Recording startup was cancelled.",
                    cancelled: true,
                    AudioSourceIntegrity.Unfinalized,
                    duration: null);
                return new CaptureStartOutcome(false, active.Lease.RecordingId, "Recording startup was cancelled.");
            }

            var start = await _recorder.StartRecordingAsync(
                    active.Lease,
                    begin.Entry.PartialSourcePath,
                    selectedDeviceId,
                    active.Cancellation.Token)
                .ConfigureAwait(false);
            if (!start.IsReady)
            {
                var message = start.ErrorMessage ?? "The microphone could not start.";
                AbandonForegroundAttempt(
                    active,
                    message,
                    cancelled: false,
                    AudioSourceIntegrity.Unfinalized,
                    duration: null);
                return new CaptureStartOutcome(false, active.Lease.RecordingId, message);
            }

            var ready = await RunStoreWithDeadlineAsync(
                    () => _store.CaptureBecameReadyAsync(active.Lease, startToken),
                    startToken)
                .ConfigureAwait(false);
            if (!ready.Applied || ready.Lease == null)
            {
                AbandonForegroundAttempt(
                    active,
                    "The recording could not be saved safely. Try again.",
                    cancelled: false,
                    AudioSourceIntegrity.Unfinalized,
                    duration: null);
                return new CaptureStartOutcome(false, active.Lease.RecordingId,
                    "The recording could not be saved safely. Try again.");
            }
            active.Lease = ready.Lease;
            if (pending.UserCancelled || startToken.IsCancellationRequested || IsAbandoned(active))
            {
                active.UserCancelled = true;
                AbandonForegroundAttempt(
                    active,
                    "Recording startup was cancelled.",
                    cancelled: true,
                    AudioSourceIntegrity.Unfinalized,
                    duration: null);
                return new CaptureStartOutcome(false, active.Lease.RecordingId, "Recording startup was cancelled.");
            }
            _appState.RecordingBecameReady();
            return new CaptureStartOutcome(true, active.Lease.RecordingId, null);
        }
        catch (OperationCanceledException)
        {
            if (active != null)
            {
                active.UserCancelled = true;
                AbandonForegroundAttempt(
                    active,
                    "Recording startup was cancelled.",
                    cancelled: true,
                    AudioSourceIntegrity.Unfinalized,
                    duration: null);
            }
            if (OwnsPendingStart(pending)) _appState.Reset();
            return new CaptureStartOutcome(false, active?.Lease.RecordingId, "Recording startup was cancelled.");
        }
        catch (Exception ex)
        {
            if (pending.UserCancelled)
            {
                if (active != null)
                {
                    active.UserCancelled = true;
                    AbandonForegroundAttempt(
                        active,
                        "Recording startup was cancelled.",
                        cancelled: true,
                        AudioSourceIntegrity.Unfinalized,
                        duration: null);
                }
                return new CaptureStartOutcome(false, active?.Lease.RecordingId, "Recording startup was cancelled.");
            }

            var message = ex is TimeoutException
                ? "Preparing the recording took too long. Any recoverable audio was kept."
                : "The microphone could not start. Check microphone access and available storage.";
            if (active != null)
            {
                AbandonForegroundAttempt(
                    active,
                    message,
                    cancelled: false,
                    AudioSourceIntegrity.Unfinalized,
                    duration: null);
            }
            else if (OwnsPendingStart(pending))
            {
                _appState.SetError(message);
            }
            return new CaptureStartOutcome(false, active?.Lease.RecordingId, message);
        }
        finally
        {
            lock (_activeLock)
            {
                if (ReferenceEquals(_pendingStart, pending)) _pendingStart = null;
            }
            if (lifecycleHeld) _lifecycleGate.Release();
        }
    }

    public async Task<TranscriptionResult> StopAndTranscribeAsync(
        TimeSpan recordedDuration,
        CancellationToken cancellationToken = default)
    {
        ActiveAttempt? active = null;
        var lifecycleHeld = false;
        try
        {
            await _lifecycleGate.WaitAsync(cancellationToken).ConfigureAwait(false);
            lifecycleHeld = true;
            active = GetActive();
            if (active == null || active.IsRecognition)
                return TranscriptionResult.Failure("No recording is active.");

            using var flowCancellation = CancellationTokenSource.CreateLinkedTokenSource(
                cancellationToken,
                active.Cancellation.Token);
            var flowToken = flowCancellation.Token;
            _appState.StartFinalizing();
            var finalizing = await RunStoreWithDeadlineAsync(
                    () => _store.BeginFinalizationAsync(active.Lease, flowToken),
                    flowToken)
                .ConfigureAwait(false);
            if (IsAbandoned(active)) return CancelledResult();
            if (!finalizing.Applied || finalizing.Lease == null)
            {
                const string message = "The recording attempt is no longer current.";
                AbandonForegroundAttempt(
                    active,
                    message,
                    cancelled: false,
                    active.SourceIntegrity,
                    recordedDuration);
                return TranscriptionResult.Failure(message);
            }
            active.Lease = finalizing.Lease;

            var recorderResult = await _recorder.StopRecordingAsync(
                    active.Lease,
                    cancellationToken: flowToken)
                .ConfigureAwait(false);
            if (IsAbandoned(active)) return CancelledResult();
            if (!recorderResult.IsFinalized)
            {
                var message = recorderResult.TimedOut
                    ? "The microphone did not finish saving in time. The recoverable source was kept."
                    : recorderResult.ErrorMessage ?? "The recording could not be finalized.";
                AbandonForegroundAttempt(
                    active,
                    message,
                    cancelled: false,
                    recorderResult.TimedOut ? AudioSourceIntegrity.Unfinalized : AudioSourceIntegrity.KnownIncomplete,
                    recordedDuration);
                return TranscriptionResult.Failure(message);
            }

            var accepted = await RunStoreWithDeadlineAsync(
                    () => _store.AcceptFinalizedSourceAsync(active.Lease, flowToken),
                    flowToken)
                .ConfigureAwait(false);
            if (IsAbandoned(active)) return CancelledResult();
            if (!accepted.Applied || accepted.Lease == null || accepted.Entry == null ||
                accepted.Entry.Stage != AudioProcessingStage.ReadyForRecognition)
            {
                var message = accepted.Entry?.ErrorMessage ?? accepted.RejectionReason ??
                              "The recording did not finish saving correctly.";
                await UpdateHistoryFromEntryAsync(accepted.Entry, recordedDuration, flowToken)
                    .ConfigureAwait(false);
                AbandonForegroundAttempt(
                    active,
                    message,
                    cancelled: false,
                    accepted.Entry?.SourceIntegrity ?? AudioSourceIntegrity.KnownIncomplete,
                    recordedDuration);
                return TranscriptionResult.Failure(message);
            }
            active.Lease = accepted.Lease;
            active.SourcePath = accepted.Entry.FinalSourcePath;
            active.SourceIntegrity = AudioSourceIntegrity.Complete;
            if (!await UpdateHistoryFromEntryAsync(accepted.Entry, recordedDuration, flowToken)
                    .ConfigureAwait(false))
            {
                const string message =
                    "History could not be updated. The managed recording was kept for recovery.";
                AbandonForegroundAttempt(
                    active,
                    message,
                    cancelled: false,
                    AudioSourceIntegrity.Complete,
                    recordedDuration);
                return TranscriptionResult.Failure("History could not be updated.");
            }

            if (IsAbandoned(active)) return CancelledResult();
            _appState.StartProcessing();
            var recognition = await RunStoreWithDeadlineAsync(
                    () => _store.BeginRecognitionAsync(
                        active.Lease.RecordingId,
                        active.Snapshot,
                        flowToken),
                    flowToken,
                    result => ReconcileLateInitialRecognitionStartAsync(
                        result,
                        recordedDuration))
                .ConfigureAwait(false);
            if (IsAbandoned(active)) return CancelledResult();
            if (!recognition.Applied || recognition.Lease == null || recognition.Entry == null)
            {
                var message = recognition.RejectionReason ?? "The recording could not start processing.";
                AbandonForegroundAttempt(
                    active,
                    message,
                    cancelled: false,
                    AudioSourceIntegrity.Complete,
                    recordedDuration);
                return TranscriptionResult.Failure(message);
            }
            active.Lease = recognition.Lease;
            active.IsRecognition = true;
        }
        catch (OperationCanceledException) when (active != null &&
                                                 (active.UserCancelled || IsAbandoned(active)))
        {
            return CancelledResult();
        }
        catch (OperationCanceledException)
        {
            const string message =
                "Audio processing was interrupted. The saved recording was kept for recovery.";
            if (active != null)
                AbandonForegroundAttempt(active, message, false, active.SourceIntegrity, recordedDuration);
            else
                _appState.SetError(message);
            return TranscriptionResult.Failure(message);
        }
        catch (Exception ex)
        {
            var message = ex is TimeoutException
                ? active?.SourceIntegrity == AudioSourceIntegrity.Complete
                    ? "Preparing the saved recording for transcription took too long. It was kept for retry."
                    : "Saving the recording took too long. The recoverable source was kept."
                : "Audio processing stopped unexpectedly. Restart the app to recover the saved recording.";
            if (active != null)
                AbandonForegroundAttempt(active, message, false, active.SourceIntegrity, recordedDuration);
            else
                _appState.SetError(message);
            return TranscriptionResult.Failure(message);
        }
        finally
        {
            if (lifecycleHeld) _lifecycleGate.Release();
        }

        return await RunRecognitionAsync(active!, recordedDuration, cancellationToken).ConfigureAwait(false);
    }

    public async Task<TranscriptionResult> RetryAsync(
        Guid recordingId,
        string provider,
        CancellationToken cancellationToken = default)
    {
        var snapshot = _transcription.CaptureAttemptSnapshot(provider);
        ActiveAttempt? active = null;
        PendingStart? pending = null;
        var lifecycleHeld = false;
        try
        {
            await _lifecycleGate.WaitAsync(cancellationToken).ConfigureAwait(false);
            lifecycleHeld = true;
            if (GetActive() != null)
                return TranscriptionResult.Failure("Wait for the current audio processing to finish.");
            var row = _history.Get(recordingId);
            if (row == null || !row.CanRetry)
                return TranscriptionResult.Failure("This recording does not have a complete saved audio file.");

            pending = new PendingStart();
            lock (_activeLock)
            {
                if (_active != null || _pendingStart != null)
                    return TranscriptionResult.Failure("Wait for the current audio processing to finish.");
                _pendingStart = pending;
            }
            if (!_appState.StartRetrying())
                return TranscriptionResult.Failure("Wait for the current audio processing to finish.");

            using var linkedRetryCancellation = CancellationTokenSource.CreateLinkedTokenSource(
                cancellationToken,
                pending.Cancellation.Token);
            var retryToken = linkedRetryCancellation.Token;
            retryToken.ThrowIfCancellationRequested();

            var begin = await RunStoreWithDeadlineAsync(
                    () => _store.BeginRecognitionAsync(recordingId, snapshot, retryToken),
                    retryToken,
                    ReconcileLateRetryStartAsync)
                .ConfigureAwait(false);
            if (!OwnsPendingStart(pending) || pending.UserCancelled || retryToken.IsCancellationRequested)
            {
                _ = ReconcileLateRetryStartAsync(begin);
                return TranscriptionResult.Failure("Retry was cancelled.");
            }
            if (!begin.Applied || begin.Lease == null || begin.Entry == null)
            {
                var message = begin.RejectionReason ?? "Retry could not start.";
                await UpdateHistoryFromEntryAsync(begin.Entry, cancellationToken: retryToken)
                    .ConfigureAwait(false);
                _appState.SetError(message);
                return TranscriptionResult.Failure(message);
            }

            active = new ActiveAttempt
            {
                Lease = begin.Lease,
                Snapshot = snapshot,
                SourcePath = begin.Entry.FinalSourcePath,
                StartedUtc = DateTimeOffset.UtcNow,
                IsCommandMode = false,
                IsRecognition = true,
                SourceIntegrity = AudioSourceIntegrity.Complete,
                Cancellation = pending.Cancellation
            };
            if (!TrySetActiveForPending(pending, active))
            {
                _ = ReconcileLateRetryStartAsync(begin);
                return TranscriptionResult.Failure("Retry was cancelled.");
            }
            row.Status = TranscriptionStatus.Retrying;
            row.RetryCount++;
            row.ErrorMessage = null;
            row.Revision = begin.Entry.Revision;
            if (!await RunHistoryWithDeadlineAsync(
                    token => _history.UpdateAsync(row, token),
                    retryToken)
                .ConfigureAwait(false))
            {
                const string message = "Retry stopped because History could not be updated.";
                AbandonForegroundAttempt(
                    active,
                    message,
                    cancelled: false,
                    AudioSourceIntegrity.Complete,
                    duration: null);
                return TranscriptionResult.Failure(message);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested ||
                                                  pending?.UserCancelled == true)
        {
            if (active != null)
            {
                active.UserCancelled = true;
                AbandonForegroundAttempt(
                    active,
                    "Retry was cancelled.",
                    cancelled: true,
                    AudioSourceIntegrity.Complete,
                    duration: null);
            }
            else if (pending == null || OwnsPendingStart(pending))
                _appState.Reset();
            return TranscriptionResult.Failure("Retry was cancelled.");
        }
        catch (Exception ex)
        {
            if (pending?.UserCancelled == true)
                return TranscriptionResult.Failure("Retry was cancelled.");
            var message = ex is TimeoutException
                ? "Retry took too long to start. The complete recording was kept so you can try again."
                : "Retry stopped unexpectedly. The complete recording was kept so you can try again.";
            if (active != null)
                AbandonForegroundAttempt(
                    active,
                    message,
                    cancelled: false,
                    AudioSourceIntegrity.Complete,
                    duration: null);
            else if (pending == null || OwnsPendingStart(pending))
                _appState.SetError(message);
            return TranscriptionResult.Failure(message);
        }
        finally
        {
            if (pending != null)
            {
                lock (_activeLock)
                {
                    if (ReferenceEquals(_pendingStart, pending)) _pendingStart = null;
                }
            }
            if (lifecycleHeld) _lifecycleGate.Release();
        }

        var duration = TimeSpan.FromSeconds(_history.Get(recordingId)?.Duration ?? 0);
        return await RunRecognitionAsync(active!, duration, cancellationToken).ConfigureAwait(false);
    }

    public Task CancelAsync(string reason, CancellationToken cancellationToken = default)
    {
        PendingStart? pending;
        ActiveAttempt? active;
        lock (_activeLock)
        {
            pending = _pendingStart;
            if (pending != null) pending.UserCancelled = true;
            _pendingStart = null;
            active = _active;
        }
        if (pending != null) RequestCancellation(pending.Cancellation);

        if (active == null)
        {
            _appState.Reset();
            return Task.CompletedTask;
        }

        active.UserCancelled = true;
        AbandonForegroundAttempt(
            active,
            reason,
            cancelled: true,
            active.SourceIntegrity,
            duration: null);
        return Task.CompletedTask;
    }

    public async Task<(bool Deleted, string? ErrorMessage)> DeleteAsync(
        Guid recordingId,
        CancellationToken cancellationToken = default)
    {
        var lifecycleHeld = false;
        try
        {
            await _lifecycleGate.WaitAsync(cancellationToken).ConfigureAwait(false);
            lifecycleHeld = true;
            if (GetActive() != null)
                return (false, "Wait for audio processing to finish before deleting a recording.");
            var result = await RunStoreWithDeadlineAsync(
                    () => _store.TombstoneAsync(recordingId, cancellationToken),
                    cancellationToken,
                    async lateResult =>
                    {
                        if (lateResult.Applied)
                            _ = await _history.RemoveMetadataAfterTombstoneAsync(
                                    recordingId,
                                    CancellationToken.None)
                                .ConfigureAwait(false);
                    })
                .ConfigureAwait(false);
            if (!result.Applied) return (false, result.RejectionReason);
            return await RunHistoryWithDeadlineAsync(
                    token => _history.RemoveMetadataAfterTombstoneAsync(recordingId, token),
                    cancellationToken)
                .ConfigureAwait(false)
                ? (true, null)
                : (false, "The recording was deleted, but History could not be refreshed. Restart the app.");
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return (false,
                "Cancellation was requested. If deletion had already committed, History will update automatically.");
        }
        catch (TimeoutException)
        {
            return (false,
                "Deletion is still finishing in the background. The row will disappear when the durable deletion commits.");
        }
        catch (Exception)
        {
            return (false, "The recording could not be deleted. Its recovery data was kept.");
        }
        finally { if (lifecycleHeld) _lifecycleGate.Release(); }
    }

    public async Task<(bool Cleared, string? ErrorMessage)> ClearAsync(
        CancellationToken cancellationToken = default)
    {
        var lifecycleHeld = false;
        try
        {
            await _lifecycleGate.WaitAsync(cancellationToken).ConfigureAwait(false);
            lifecycleHeld = true;
            if (GetActive() != null)
                return (false, "Wait for audio processing to finish before clearing History.");
            var rowsBeforeClear = _history.GetAll().Select(row => row.Id).ToArray();
            var result = await RunStoreWithDeadlineAsync(
                    () => _store.ClearAsync(cancellationToken),
                    cancellationToken,
                    async lateResult =>
                    {
                        if (lateResult.Applied)
                        {
                            foreach (var id in rowsBeforeClear)
                                _ = await _history.RemoveMetadataAfterTombstoneAsync(
                                        id,
                                        CancellationToken.None)
                                    .ConfigureAwait(false);
                        }
                    })
                .ConfigureAwait(false);
            if (!result.Applied) return (false, result.RejectionReason);
            return await RunHistoryWithDeadlineAsync(
                    token => _history.ClearMetadataAfterTombstoneAsync(token),
                    cancellationToken)
                .ConfigureAwait(false)
                ? (true, null)
                : (false, "Recordings were deleted, but History could not be refreshed. Restart the app.");
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return (false,
                "Cancellation was requested. If Clear had already committed, History will update automatically.");
        }
        catch (TimeoutException)
        {
            return (false,
                "Clear is still finishing in the background. History will refresh when the durable deletion commits.");
        }
        catch (Exception)
        {
            return (false, "History could not be cleared. Recovery data was kept.");
        }
        finally { if (lifecycleHeld) _lifecycleGate.Release(); }
    }

    private async Task<TranscriptionResult> RunRecognitionAsync(
        ActiveAttempt active,
        TimeSpan duration,
        CancellationToken callerCancellation)
    {
        if (active.UserCancelled || IsAbandoned(active)) return CancelledResult();
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(
            callerCancellation,
            active.Cancellation.Token);
        var deadline = AttemptRecognitionDeadline(duration);
        var task = Task.Run(
            () => _transcription.TranscribeAsync(
                active.SourcePath,
                active.Snapshot,
                async (text, count, token) =>
                {
                    var mutation = await MutateAttemptWithDeadlineAsync(
                            active,
                            (lease, operationToken) =>
                                _store.SaveCheckpointAsync(lease, text, count, operationToken),
                            token)
                        .ConfigureAwait(false);
                    if (!mutation.Applied || mutation.Lease == null) return false;
                    if (Volatile.Read(ref active.PipelineFenced) != 0) return false;
                    return true;
                },
                async (raw, token) =>
                {
                    var mutation = await MutateAttemptWithDeadlineAsync(
                            active,
                            (lease, operationToken) =>
                                _store.SaveRawResultAsync(lease, raw, operationToken),
                            token)
                        .ConfigureAwait(false);
                    if (!mutation.Applied || mutation.Lease == null) return false;
                    active.DurableRawText = raw;
                    if (Volatile.Read(ref active.PipelineFenced) != 0) return false;
                    return true;
                },
                linked.Token),
            CancellationToken.None);

        TranscriptionResult result;
        var completingDurableRawFallback = false;
        try
        {
            result = await task.WaitAsync(deadline, linked.Token).ConfigureAwait(false);
        }
        catch (TimeoutException)
        {
            ObserveLateTask(task);
            if (!string.IsNullOrWhiteSpace(active.DurableRawText))
            {
                // Recognition is already complete and durably journaled. Only
                // optional cleanup/late pipeline work timed out, so cancel it
                // and commit the raw transcript instead of marking failure.
                Interlocked.Exchange(ref active.PipelineFenced, 1);
                RequestCancellation(active.Cancellation);
                _ = Task.Run(() =>
                {
                    try { _transcription.AbandonLocalRecognition(active.Snapshot); }
                    catch { }
                });
                result = TranscriptionResult.Success(
                    active.DurableRawText,
                    active.DurableRawText);
                completingDurableRawFallback = true;
            }
            else
            {
                const string message = "Transcription took too long. The recording was kept so you can retry from History.";
                AbandonForegroundAttempt(active, message, cancelled: false, AudioSourceIntegrity.Complete, duration);
                return TranscriptionResult.Failure(message);
            }
        }
        catch (OperationCanceledException) when (active.UserCancelled)
        {
            ObserveLateTask(task);
            return TranscriptionResult.Failure("Audio processing was cancelled.");
        }
        catch (OperationCanceledException)
        {
            ObserveLateTask(task);
            const string message = "Transcription was interrupted. The recording was kept for retry.";
            AbandonForegroundAttempt(active, message, cancelled: false, AudioSourceIntegrity.Complete, duration);
            return TranscriptionResult.Failure(message);
        }

        if (!result.IsSuccess || string.IsNullOrWhiteSpace(result.Text))
        {
            var message = result.ErrorMessage ?? "Transcription failed. The recording was kept for retry.";
            AbandonForegroundAttempt(active, message, cancelled: false, AudioSourceIntegrity.Complete, duration);
            return TranscriptionResult.Failure(message);
        }

        if (IsAbandoned(active)) return CancelledResult();
        AudioStoreMutation completed;
        try
        {
            completed = await MutateAttemptWithDeadlineAsync(
                    active,
                    (lease, token) => _store.CompleteAsync(lease, result.Text, token),
                    completingDurableRawFallback ? CancellationToken.None : linked.Token)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (active.UserCancelled || IsAbandoned(active))
        {
            return CancelledResult();
        }
        catch (Exception ex)
        {
            var message = ex is TimeoutException
                ? "Saving the transcript took too long. The recording was kept for launch recovery."
                : "The transcript could not be committed to History. The recording was kept for launch recovery.";
            AbandonForegroundAttempt(
                active,
                message,
                cancelled: false,
                AudioSourceIntegrity.Complete,
                duration);
            return TranscriptionResult.Failure(message);
        }

        if (active.UserCancelled || IsAbandoned(active)) return CancelledResult();
        if (!completed.Applied || completed.Entry == null)
        {
            const string message =
                "This transcription finished after its recording was replaced or deleted.";
            AbandonForegroundAttempt(
                active,
                message,
                cancelled: false,
                AudioSourceIntegrity.Complete,
                duration);
            return TranscriptionResult.Failure(message);
        }
        bool historyUpdated;
        try
        {
            historyUpdated = await UpdateHistoryFromEntryAsync(
                    completed.Entry,
                    duration,
                    completingDurableRawFallback ? CancellationToken.None : linked.Token)
                .ConfigureAwait(false);
        }
        catch
        {
            historyUpdated = false;
        }
        if (active.UserCancelled || IsAbandoned(active)) return CancelledResult();
        if (!historyUpdated)
        {
            const string message =
                "The transcript was recovered, but History could not be updated. Restart the app to restore it.";
            ClearActive(active);
            _appState.SetError(message);
            return TranscriptionResult.Failure(message);
        }
        if (active.UserCancelled || IsAbandoned(active)) return CancelledResult();
        if (!_appState.SetResult(result.Text))
        {
            ClearActive(active);
            return TranscriptionResult.Failure(
                "The transcript was saved in History, but could not be delivered to the current window.");
        }
        ClearActive(active);
        try { _usageReporter.Report(result.Text); }
        catch { }
        return result;
    }

    private void AbandonForegroundAttempt(
        ActiveAttempt active,
        string message,
        bool cancelled,
        AudioSourceIntegrity integrity,
        TimeSpan? duration,
        bool publishState = true)
    {
        if (Interlocked.Exchange(ref active.Abandoned, 1) != 0) return;
        Interlocked.Exchange(ref active.PipelineFenced, 1);
        active.UserCancelled |= cancelled;
        RequestCancellation(active.Cancellation);
        ClearActive(active);
        if (publishState)
        {
            if (cancelled) _appState.Reset();
            else _appState.SetError(message);
        }

        // Native generation reset may wait for an old factory/setup lock or a
        // native Dispose. Foreground ownership and UI are already released.
        _ = Task.Run(() =>
        {
            try { _transcription.AbandonLocalRecognition(active.Snapshot); }
            catch { }
        });

        if (!active.IsRecognition)
        {
            _ = Task.Run(async () =>
            {
                try
                {
                    await _recorder.AbortRecordingAsync(active.Lease, message, CancellationToken.None)
                        .ConfigureAwait(false);
                }
                catch { }
            });
        }

        _ = Task.Run(() => PersistAbandonedAttemptAsync(
            active,
            cancelled,
            message,
            integrity,
            duration));
    }

    private async Task PersistAbandonedAttemptAsync(
        ActiveAttempt active,
        bool cancelled,
        string message,
        AudioSourceIntegrity integrity,
        TimeSpan? duration)
    {
        await active.MutationGate.WaitAsync(CancellationToken.None).ConfigureAwait(false);
        try
        {
            var terminal = await _store.AbandonAttemptAsync(
                    active.Lease,
                    cancelled,
                    message,
                    integrity,
                    CancellationToken.None)
                .ConfigureAwait(false);
            if (terminal.Applied && terminal.Lease != null) active.Lease = terminal.Lease;
            _ = await UpdateHistoryFromEntryWithoutDeadlineAsync(terminal.Entry, duration)
                .ConfigureAwait(false);
        }
        catch
        {
            // The active journal/source remains launch-recoverable. Foreground
            // state was already released before this detached persistence.
        }
        finally
        {
            active.MutationGate.Release();
        }
    }

    private async Task ReconcileLateCaptureStartAsync(
        AudioStoreMutation result,
        bool cancelled)
    {
        if (!result.Applied || result.Lease == null) return;
        try
        {
            var terminal = await _store.AbandonAttemptAsync(
                    result.Lease,
                    cancelled,
                    cancelled
                        ? "Recording startup was cancelled."
                        : "Recording startup took too long.",
                    AudioSourceIntegrity.Unfinalized,
                    CancellationToken.None)
                .ConfigureAwait(false);
            if (terminal.Entry is { IsActive: false })
                _ = await _store.TombstoneAsync(result.Lease.RecordingId, CancellationToken.None)
                    .ConfigureAwait(false);
        }
        catch
        {
            // Launch recovery terminalizes any row whose late cleanup could not
            // be persisted. No microphone was opened for this recording ID.
        }
    }

    private async Task ReconcileLateRetryStartAsync(AudioStoreMutation result)
    {
        if (!result.Applied || result.Lease == null) return;
        try
        {
            var terminal = await _store.AbandonAttemptAsync(
                    result.Lease,
                    false,
                    "Retry took too long to start. The previous transcript and audio were kept.",
                    AudioSourceIntegrity.Complete,
                    CancellationToken.None)
                .ConfigureAwait(false);
            _ = await UpdateHistoryFromEntryWithoutDeadlineAsync(terminal.Entry)
                .ConfigureAwait(false);
        }
        catch
        {
            // The complete source and prior transcript remain launch-recoverable.
        }
    }

    private async Task ReconcileLateInitialRecognitionStartAsync(
        AudioStoreMutation result,
        TimeSpan duration)
    {
        if (!result.Applied || result.Lease == null) return;
        try
        {
            var terminal = await _store.AbandonAttemptAsync(
                    result.Lease,
                    false,
                    "Transcription took too long to start. The complete recording was kept for retry.",
                    AudioSourceIntegrity.Complete,
                    CancellationToken.None)
                .ConfigureAwait(false);
            _ = await UpdateHistoryFromEntryWithoutDeadlineAsync(terminal.Entry, duration)
                .ConfigureAwait(false);
        }
        catch
        {
            // Launch recovery terminalizes an eventual recognizing row. The
            // complete managed source remains authoritative in the meantime.
        }
    }

    private Task<bool> UpdateHistoryFromEntryAsync(
        AudioProcessingEntry? entry,
        TimeSpan? duration = null,
        CancellationToken cancellationToken = default)
    {
        if (entry == null || entry.Stage == AudioProcessingStage.Deleted)
            return Task.FromResult(false);
        return RunHistoryWithDeadlineAsync(
            token => _history.UpsertAsync(
                ToHistoryRecording(entry, _history.Get(entry.RecordingId), duration),
                token),
            cancellationToken);
    }

    private Task<bool> UpdateHistoryFromEntryWithoutDeadlineAsync(
        AudioProcessingEntry? entry,
        TimeSpan? duration = null)
    {
        if (entry == null || entry.Stage == AudioProcessingStage.Deleted)
            return Task.FromResult(false);
        return _history.UpsertAsync(
            ToHistoryRecording(entry, _history.Get(entry.RecordingId), duration),
            CancellationToken.None);
    }

    private static Recording ToHistoryRecording(
        AudioProcessingEntry entry,
        Recording? existing,
        TimeSpan? duration = null)
    {
        var text = entry.FinalText ?? entry.RawText ?? entry.CheckpointText ?? existing?.Transcription;
        return new Recording
        {
            Id = entry.RecordingId,
            Timestamp = existing?.Timestamp ?? entry.CreatedUtc.LocalDateTime,
            AudioFilePath = entry.SourceIntegrity == AudioSourceIntegrity.Complete
                ? entry.FinalSourcePath
                : entry.PartialSourcePath,
            Transcription = text,
            RawTranscription = entry.RawText,
            CheckpointTranscription = entry.CheckpointText,
            Status = entry.Stage switch
            {
                AudioProcessingStage.Succeeded => TranscriptionStatus.Success,
                AudioProcessingStage.Cancelled => TranscriptionStatus.Cancelled,
                AudioProcessingStage.Failed => TranscriptionStatus.Failed,
                _ when existing?.Status == TranscriptionStatus.Retrying => TranscriptionStatus.Retrying,
                _ => TranscriptionStatus.Processing
            },
            ErrorMessage = entry.ErrorMessage,
            RetryCount = existing?.RetryCount ?? 0,
            SourceIntegrity = entry.SourceIntegrity switch
            {
                AudioSourceIntegrity.Complete => RecordingSourceIntegrity.Complete,
                AudioSourceIntegrity.KnownIncomplete => RecordingSourceIntegrity.KnownIncomplete,
                _ => RecordingSourceIntegrity.Unfinalized
            },
            Revision = entry.Revision,
            Duration = duration?.TotalSeconds ?? existing?.Duration,
            WordCount = string.IsNullOrWhiteSpace(text)
                ? 0
                : text.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length
        };
    }

    private ActiveAttempt? GetActive()
    {
        lock (_activeLock) return _active;
    }

    private bool TrySetActiveForPending(PendingStart pending, ActiveAttempt active)
    {
        lock (_activeLock)
        {
            if (!ReferenceEquals(_pendingStart, pending) || pending.UserCancelled || _active != null)
                return false;
            _active = active;
            return true;
        }
    }

    private bool OwnsPendingStart(PendingStart pending)
    {
        lock (_activeLock) return ReferenceEquals(_pendingStart, pending);
    }

    private void ClearActive(ActiveAttempt active)
    {
        lock (_activeLock)
        {
            if (ReferenceEquals(_active, active)) _active = null;
        }
    }

    private static bool IsAbandoned(ActiveAttempt active) =>
        Volatile.Read(ref active.Abandoned) != 0;

    private static TranscriptionResult CancelledResult() =>
        TranscriptionResult.Failure("Audio processing was cancelled.");

    private static void RequestCancellation(CancellationTokenSource cancellation)
    {
        // CancelAsync marks the token cancelled before returning, while running
        // arbitrary user/native callbacks asynchronously. This closes the
        // first-buffer race without letting a callback block the UI thread.
        try
        {
            ObserveLateTask(cancellation.CancelAsync());
        }
        catch (ObjectDisposedException) { }
    }

    private TimeSpan AttemptRecognitionDeadline(TimeSpan duration)
    {
        var seconds = Math.Clamp(duration.TotalSeconds * 2 + 60,
            _deadlines.MinimumRecognition.TotalSeconds,
            _deadlines.MaximumRecognition.TotalSeconds);
        return TimeSpan.FromSeconds(seconds);
    }

    private async Task<T> RunStoreWithDeadlineAsync<T>(
        Func<Task<T>> operation,
        CancellationToken cancellationToken,
        Func<T, Task>? reconcileLateResult = null)
    {
        var task = Task.Run(operation, CancellationToken.None);
        try
        {
            return await task.WaitAsync(_deadlines.StoreOperation, cancellationToken)
                .ConfigureAwait(false);
        }
        catch
        {
            if (reconcileLateResult == null)
                ObserveLateTask(task);
            else
                _ = ReconcileLateStoreOperationAsync(task, reconcileLateResult);
            throw;
        }
    }

    private async Task<bool> RunHistoryWithDeadlineAsync(
        Func<CancellationToken, Task<bool>> operation,
        CancellationToken cancellationToken)
    {
        // History owns eventual completion and revision reconciliation. The
        // coordinator only bounds how long foreground state waits for it.
        var task = Task.Run(() => operation(CancellationToken.None), CancellationToken.None);
        try
        {
            return await task.WaitAsync(_deadlines.StoreOperation, cancellationToken)
                .ConfigureAwait(false);
        }
        catch
        {
            ObserveLateTask(task);
            throw;
        }
    }

    private async Task<bool> TryRunHistoryWithDeadlineAsync(
        Func<CancellationToken, Task<bool>> operation,
        CancellationToken cancellationToken)
    {
        try
        {
            return await RunHistoryWithDeadlineAsync(operation, cancellationToken)
                .ConfigureAwait(false);
        }
        catch
        {
            return false;
        }
    }

    private static async Task ReconcileLateStoreOperationAsync<T>(
        Task<T> operation,
        Func<T, Task> reconcile)
    {
        try
        {
            var result = await operation.ConfigureAwait(false);
            await reconcile(result).ConfigureAwait(false);
        }
        catch
        {
            // A fault/cancel has no committed result to reconcile. Durable
            // recovery remains authoritative for any unknown filesystem state.
        }
    }

    private async Task<AudioStoreMutation> MutateAttemptWithDeadlineAsync(
        ActiveAttempt active,
        Func<AudioAttemptLease, CancellationToken, Task<AudioStoreMutation>> mutation,
        CancellationToken cancellationToken)
    {
        if (Volatile.Read(ref active.Abandoned) != 0)
            return new AudioStoreMutation(false, null, null, "Attempt was abandoned");

        await active.MutationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        var releaseGate = true;
        var operationCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        operationCancellation.CancelAfter(_deadlines.StoreOperation);
        var operation = Task.Run(
            () => mutation(active.Lease, operationCancellation.Token),
            CancellationToken.None);
        try
        {
            var result = await operation
                .WaitAsync(_deadlines.StoreOperation, cancellationToken)
                .ConfigureAwait(false);
            if (result.Applied && result.Lease != null) active.Lease = result.Lease;
            return Volatile.Read(ref active.Abandoned) == 0
                ? result
                : new AudioStoreMutation(false, null, result.Entry, "Attempt was abandoned");
        }
        catch
        {
            operationCancellation.Cancel();
            if (!operation.IsCompleted)
            {
                releaseGate = false;
                _ = CompleteDetachedMutationAsync(operation, active, operationCancellation);
            }
            throw;
        }
        finally
        {
            if (releaseGate)
            {
                operationCancellation.Dispose();
                active.MutationGate.Release();
            }
        }
    }

    private static async Task CompleteDetachedMutationAsync(
        Task<AudioStoreMutation> operation,
        ActiveAttempt active,
        CancellationTokenSource operationCancellation)
    {
        try
        {
            var result = await operation.ConfigureAwait(false);
            if (result.Applied && result.Lease != null) active.Lease = result.Lease;
        }
        catch { }
        finally
        {
            operationCancellation.Dispose();
            active.MutationGate.Release();
        }
    }

    private static void ObserveLateTask(Task task)
    {
        _ = task.ContinueWith(
            completed => _ = completed.Exception,
            CancellationToken.None,
            TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
    }

    private void OnCaptureTerminatedUnexpectedly(object? sender, RecorderCaptureFailedEventArgs args)
    {
        var active = GetActive();
        if (active == null || active.IsRecognition ||
            active.Lease.RecordingId != args.Lease.RecordingId ||
            active.Lease.AttemptId != args.Lease.AttemptId ||
            active.Lease.DeletionGeneration != args.Lease.DeletionGeneration ||
            active.Lease.ClearGeneration != args.Lease.ClearGeneration)
            return;

        // Never queue behind finalization or a blocked journal write. The
        // foreground attempt is fenced first; terminal persistence is detached.
        AbandonForegroundAttempt(
            active,
            args.Message,
            cancelled: false,
            AudioSourceIntegrity.KnownIncomplete,
            duration: null);
    }
}
