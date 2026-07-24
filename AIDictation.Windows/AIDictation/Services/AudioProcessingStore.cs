using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;

namespace AIDictation.Services;

public enum AudioProcessingStage
{
    Preparing,
    Recording,
    Finalizing,
    ReadyForRecognition,
    Recognizing,
    ResultReady,
    Succeeded,
    Failed,
    Cancelled,
    Deleted
}

public enum AudioSourceIntegrity
{
    Complete,
    KnownIncomplete,
    Unfinalized
}

public enum UsageAccountingState
{
    Pending,
    Claimed
}

public sealed record AudioUsageClaim(Guid RecordingId, string Text);

/// <summary>
/// Immutable settings captured before an attempt starts. A running attempt never
/// observes later changes made in Settings.
/// </summary>
public sealed record TranscriptionAttemptSnapshot(
    string Provider,
    IReadOnlyList<string> LanguageCodes,
    string? RecognitionPrompt,
    string? PostProcessingPrompt,
    bool CleanupEnabled,
    IReadOnlyList<TextReplacementSnapshot> Replacements,
    IReadOnlyList<TextReplacementSnapshot> Expansions,
    string? ContextInstructions,
    IReadOnlyList<string>? Vocabulary = null,
    string? CleanupReferenceBlock = null);

public sealed record TextReplacementSnapshot(string Trigger, string Replacement);

public sealed record AudioAttemptLease(
    Guid RecordingId,
    Guid AttemptId,
    long DeletionGeneration,
    long ClearGeneration,
    long Revision);

public sealed class AudioProcessingEntry
{
    public Guid RecordingId { get; set; }
    public Guid? AttemptId { get; set; }
    public long DeletionGeneration { get; set; }
    public long ClearGeneration { get; set; }
    public long Revision { get; set; }
    public AudioProcessingStage Stage { get; set; }
    public AudioSourceIntegrity SourceIntegrity { get; set; } = AudioSourceIntegrity.Unfinalized;
    public string PartialSourcePath { get; set; } = string.Empty;
    public string FinalSourcePath { get; set; } = string.Empty;
    public string? RawText { get; set; }
    public string? CheckpointText { get; set; }
    public int CompletedLeafCount { get; set; }
    public string? FinalText { get; set; }
    public string? ErrorMessage { get; set; }
    public string? LegacySourcePath { get; set; }
    public bool LegacySourceOwned { get; set; }
    public bool LegacySourceDeletionPending { get; set; }
    public bool FinalizationStarted { get; set; }
    public UsageAccountingState? UsageAccounting { get; set; }
    public DateTimeOffset CreatedUtc { get; set; }
    public DateTimeOffset UpdatedUtc { get; set; }
    public TranscriptionAttemptSnapshot? SettingsSnapshot { get; set; }

    [JsonIgnore]
    public bool IsActive => Stage is AudioProcessingStage.Preparing
        or AudioProcessingStage.Recording
        or AudioProcessingStage.Finalizing
        or AudioProcessingStage.ReadyForRecognition
        or AudioProcessingStage.Recognizing
        or AudioProcessingStage.ResultReady;
}

public sealed record AudioStoreMutation(
    bool Applied,
    AudioAttemptLease? Lease,
    AudioProcessingEntry? Entry,
    string? RejectionReason = null,
    long? ClearGeneration = null);

public sealed class AudioStoreException : Exception
{
    public AudioStoreException(string message, Exception? inner = null) : base(message, inner) { }
}

/// <summary>
/// Durable, compare-and-swap journal for the Windows capture/recognition state
/// machine. The journal is the authority for attempt ownership and deletion.
/// Audio is only addressed by derived stable-id paths, never by an arbitrary path
/// read from JSON.
/// </summary>
public sealed class AudioProcessingStore : IAudioProcessingStore
{
    private sealed class JournalDocument
    {
        public int SchemaVersion { get; set; } = 1;
        public long ClearGeneration { get; set; }
        public Dictionary<Guid, AudioProcessingEntry> Entries { get; set; } = new();
    }

    private readonly string _rootPath;
    private readonly string _sourcesPath;
    private readonly string _workspacesPath;
    private readonly string _journalPath;
    private readonly string _legacyRecordingsPath;
    private readonly string _trustedRootPath;
    private readonly string _trustedLegacyRootPath;
    private readonly Func<DateTimeOffset> _utcNow;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly JsonSerializerOptions _jsonOptions = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true,
        Converters = { new JsonStringEnumConverter() }
    };
    private bool _persistenceHealthy = true;

    public static AudioProcessingStore Instance { get; } = new(
        DefaultRootPath(),
        trustedRootPath: DefaultAppDataPath(),
        trustedLegacyRootPath: DefaultAppDataPath());

    public AudioProcessingStore(
        string rootPath,
        Func<DateTimeOffset>? utcNow = null,
        string? legacyRecordingsPath = null,
        string? trustedRootPath = null,
        string? trustedLegacyRootPath = null)
    {
        _rootPath = Path.GetFullPath(rootPath);
        _sourcesPath = Path.Combine(_rootPath, "Sources");
        _workspacesPath = Path.Combine(_rootPath, "Workspaces");
        _journalPath = Path.Combine(_rootPath, "journal.json");
        _legacyRecordingsPath = Path.GetFullPath(legacyRecordingsPath ?? DefaultLegacyRecordingsPath());
        _trustedRootPath = Path.GetFullPath(
            trustedRootPath ?? Directory.GetParent(_rootPath)?.FullName ??
            throw new ArgumentException("Audio processing root needs a trusted parent.", nameof(rootPath)));
        _trustedLegacyRootPath = Path.GetFullPath(
            trustedLegacyRootPath ?? Directory.GetParent(_legacyRecordingsPath)?.FullName ??
            throw new ArgumentException("Legacy recording root needs a trusted parent.", nameof(legacyRecordingsPath)));
        _utcNow = utcNow ?? (() => DateTimeOffset.UtcNow);
    }

    public bool PersistenceHealthy => _persistenceHealthy;
    public string SourcesPath => _sourcesPath;

    public async Task<AudioStoreMutation> BeginCaptureAsync(
        TranscriptionAttemptSnapshot snapshot,
        Guid? requestedRecordingId = null,
        CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var document = LoadDocument();
            var recordingId = requestedRecordingId ?? Guid.NewGuid();
            if (document.Entries.TryGetValue(recordingId, out var existing) &&
                existing.Stage != AudioProcessingStage.Deleted)
            {
                return new AudioStoreMutation(false, null, Clone(existing), "Recording already exists");
            }

            var attemptId = Guid.NewGuid();
            var now = _utcNow();
            var deletionGeneration = existing?.DeletionGeneration ?? 0;
            var entry = new AudioProcessingEntry
            {
                RecordingId = recordingId,
                AttemptId = attemptId,
                DeletionGeneration = deletionGeneration,
                ClearGeneration = document.ClearGeneration,
                Revision = (existing?.Revision ?? 0) + 1,
                Stage = AudioProcessingStage.Preparing,
                SourceIntegrity = AudioSourceIntegrity.Unfinalized,
                PartialSourcePath = PartialPath(recordingId),
                FinalSourcePath = FinalPath(recordingId),
                CreatedUtc = now,
                UpdatedUtc = now,
                SettingsSnapshot = snapshot
            };
            document.Entries[recordingId] = entry;

            // The journal commit deliberately happens before the capture file is
            // opened. A crash at either boundary leaves a recoverable row.
            SaveDocument(document);
            try
            {
                EnsureManagedSourceFile(entry.PartialSourcePath, mustExist: false);
                await using var stream = new FileStream(
                    entry.PartialSourcePath,
                    FileMode.Create,
                    FileAccess.Write,
                    FileShare.Read,
                    4096,
                    FileOptions.Asynchronous | FileOptions.WriteThrough);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
                stream.Flush(flushToDisk: true);
            }
            catch (Exception ex)
            {
                entry.Stage = AudioProcessingStage.Failed;
                entry.ErrorMessage = "The recording could not be saved. Check available storage and try again.";
                entry.UpdatedUtc = _utcNow();
                entry.Revision++;
                SaveDocument(document);
                throw new AudioStoreException(entry.ErrorMessage, ex);
            }

            return Applied(entry, document.ClearGeneration);
        }
        finally
        {
            _gate.Release();
        }
    }

    public Task<AudioStoreMutation> CaptureBecameReadyAsync(
        AudioAttemptLease lease,
        CancellationToken cancellationToken = default) =>
        AdvanceAsync(lease, new[] { AudioProcessingStage.Preparing }, entry =>
        {
            entry.Stage = AudioProcessingStage.Recording;
            entry.ErrorMessage = null;
        }, cancellationToken);

    public Task<AudioStoreMutation> BeginFinalizationAsync(
        AudioAttemptLease lease,
        CancellationToken cancellationToken = default) =>
        AdvanceAsync(lease, new[] { AudioProcessingStage.Recording }, entry =>
        {
            entry.Stage = AudioProcessingStage.Finalizing;
            entry.FinalizationStarted = true;
        }, cancellationToken);

    public async Task<AudioStoreMutation> AcceptFinalizedSourceAsync(
        AudioAttemptLease lease,
        CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var document = LoadDocument();
            var match = Match(document, lease, AudioProcessingStage.Finalizing);
            if (!match.Applied || match.Entry == null)
                return match;

            var entry = match.Entry;
            EnsureManagedSourceFile(entry.PartialSourcePath, mustExist: true);
            EnsureManagedSourceFile(entry.FinalSourcePath, mustExist: false);
            var validation = AudioContainerValidator.ValidateFinalizedWave(entry.PartialSourcePath);
            if (!validation.IsValid)
            {
                entry.Stage = AudioProcessingStage.Failed;
                entry.SourceIntegrity = AudioSourceIntegrity.KnownIncomplete;
                entry.ErrorMessage = validation.ErrorMessage;
                Touch(entry);
                SaveDocument(document);
                return Applied(entry, document.ClearGeneration);
            }

            // Closing/validating precedes promotion. Move is same-volume and
            // atomic; the original is never deleted before the destination wins.
            File.Move(entry.PartialSourcePath, entry.FinalSourcePath, overwrite: true);
            entry.Stage = AudioProcessingStage.ReadyForRecognition;
            entry.SourceIntegrity = AudioSourceIntegrity.Complete;
            entry.ErrorMessage = null;
            Touch(entry);
            SaveDocument(document);
            return Applied(entry, document.ClearGeneration);
        }
        catch (IOException ex)
        {
            throw new AudioStoreException(
                "The recording was finalized but could not be committed to storage. The source was kept for recovery.", ex);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<AudioStoreMutation> BeginRecognitionAsync(
        Guid recordingId,
        TranscriptionAttemptSnapshot snapshot,
        CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var document = LoadDocument();
            if (!document.Entries.TryGetValue(recordingId, out var entry))
                return new AudioStoreMutation(false, null, null, "Recording was not found");
            if (entry.Stage == AudioProcessingStage.Deleted)
                return new AudioStoreMutation(false, null, Clone(entry), "Recording was deleted");
            if (entry.IsActive && entry.Stage != AudioProcessingStage.ReadyForRecognition)
                return new AudioStoreMutation(false, null, Clone(entry), "Another attempt already owns this recording");
            var finalPath = FinalPath(recordingId);
            EnsureManagedSourceFile(finalPath, mustExist: false);
            if (entry.SourceIntegrity != AudioSourceIntegrity.Complete ||
                !ManagedAudioPathPolicy.EntryExistsNoFollow(finalPath))
                return new AudioStoreMutation(false, null, Clone(entry), "The saved audio is not complete");
            EnsureManagedSourceFile(finalPath, mustExist: true);
            var validation = AudioContainerValidator.ValidateFinalizedWave(finalPath);
            if (!validation.IsValid)
            {
                entry.Stage = AudioProcessingStage.Failed;
                entry.SourceIntegrity = AudioSourceIntegrity.KnownIncomplete;
                entry.ErrorMessage = validation.ErrorMessage;
                Touch(entry);
                SaveDocument(document);
                return new AudioStoreMutation(false, null, Clone(entry), validation.ErrorMessage);
            }

            entry.AttemptId = Guid.NewGuid();
            entry.Stage = AudioProcessingStage.Recognizing;
            // Keep the last complete result (and its raw/checkpoint evidence)
            // visible until this retry commits a replacement success. New
            // checkpoints may advance below, but a failed retry must never
            // erase a transcript the user already had.
            entry.CompletedLeafCount = 0;
            entry.ErrorMessage = null;
            entry.SettingsSnapshot = snapshot;
            Touch(entry);
            SaveDocument(document);
            return Applied(entry, document.ClearGeneration);
        }
        finally
        {
            _gate.Release();
        }
    }

    public Task<AudioStoreMutation> SaveCheckpointAsync(
        AudioAttemptLease lease,
        string orderedText,
        int completedLeafCount,
        CancellationToken cancellationToken = default) =>
        AdvanceAsync(lease, new[] { AudioProcessingStage.Recognizing }, entry =>
        {
            if (completedLeafCount <= entry.CompletedLeafCount)
                throw new InvalidOperationException("Checkpoints must advance in order");
            if (string.IsNullOrWhiteSpace(orderedText))
                throw new InvalidOperationException("A completed leaf cannot have empty text");
            entry.CheckpointText = orderedText;
            entry.CompletedLeafCount = completedLeafCount;
        }, cancellationToken);

    public Task<AudioStoreMutation> SaveRawResultAsync(
        AudioAttemptLease lease,
        string rawText,
        CancellationToken cancellationToken = default) =>
        AdvanceAsync(lease, new[] { AudioProcessingStage.Recognizing }, entry =>
        {
            if (string.IsNullOrWhiteSpace(rawText))
                throw new InvalidOperationException("Raw transcription cannot be empty");
            entry.RawText = rawText;
            entry.Stage = AudioProcessingStage.ResultReady;
        }, cancellationToken);

    public Task<AudioStoreMutation> CompleteAsync(
        AudioAttemptLease lease,
        string finalText,
        CancellationToken cancellationToken = default) =>
        AdvanceAsync(lease, new[] { AudioProcessingStage.ResultReady }, entry =>
        {
            if (string.IsNullOrWhiteSpace(finalText))
                throw new InvalidOperationException("Final transcription cannot be empty");
            entry.FinalText = finalText;
            entry.Stage = AudioProcessingStage.Succeeded;
            entry.ErrorMessage = null;
            entry.UsageAccounting ??= UsageAccountingState.Pending;
        }, cancellationToken);

    public async Task<AudioUsageClaim?> ClaimUsageAsync(
        Guid recordingId,
        CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var document = LoadDocument();
            if (!document.Entries.TryGetValue(recordingId, out var entry) ||
                entry.Stage != AudioProcessingStage.Succeeded ||
                entry.UsageAccounting != UsageAccountingState.Pending ||
                string.IsNullOrWhiteSpace(entry.FinalText))
                return null;

            // Persist the one-way claim before invoking the non-idempotent usage
            // sink. An ambiguous network result is intentionally never retried.
            entry.UsageAccounting = UsageAccountingState.Claimed;
            entry.UpdatedUtc = _utcNow();
            SaveDocument(document);
            return new AudioUsageClaim(recordingId, entry.FinalText);
        }
        finally
        {
            _gate.Release();
        }
    }

    public Task<AudioStoreMutation> FailAsync(
        AudioAttemptLease lease,
        string message,
        AudioSourceIntegrity? integrity = null,
        CancellationToken cancellationToken = default) =>
        AdvanceAsync(lease, new[]
        {
            AudioProcessingStage.Preparing,
            AudioProcessingStage.Recording,
            AudioProcessingStage.Finalizing,
            AudioProcessingStage.ReadyForRecognition,
            AudioProcessingStage.Recognizing,
            AudioProcessingStage.ResultReady
        }, entry =>
        {
            entry.Stage = AudioProcessingStage.Failed;
            entry.ErrorMessage = message;
            if (integrity.HasValue) entry.SourceIntegrity = integrity.Value;
        }, cancellationToken);

    public Task<AudioStoreMutation> CancelAsync(
        AudioAttemptLease lease,
        string message,
        CancellationToken cancellationToken = default) =>
        AdvanceAsync(lease, new[]
        {
            AudioProcessingStage.Preparing,
            AudioProcessingStage.Recording,
            AudioProcessingStage.Finalizing,
            AudioProcessingStage.ReadyForRecognition,
            AudioProcessingStage.Recognizing,
            AudioProcessingStage.ResultReady
        }, entry =>
        {
            entry.Stage = AudioProcessingStage.Cancelled;
            entry.ErrorMessage = message;
        }, cancellationToken);

    /// <summary>
    /// Terminalizes an attempt after its foreground owner has abandoned it.
    /// Revision is intentionally ignored because an already-running checkpoint
    /// may commit first; attempt/deletion/clear generations still fence every
    /// newer retry, delete, and clear operation.
    /// </summary>
    public async Task<AudioStoreMutation> AbandonAttemptAsync(
        AudioAttemptLease lease,
        bool cancelled,
        string message,
        AudioSourceIntegrity integrity,
        CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var document = LoadDocument();
            if (!document.Entries.TryGetValue(lease.RecordingId, out var entry))
                return new AudioStoreMutation(false, null, null, "Recording was not found");
            if (document.ClearGeneration != lease.ClearGeneration ||
                entry.DeletionGeneration != lease.DeletionGeneration ||
                entry.AttemptId != lease.AttemptId ||
                entry.Stage == AudioProcessingStage.Deleted)
                return new AudioStoreMutation(false, null, Clone(entry), "Attempt is stale");
            if (!entry.IsActive)
                return new AudioStoreMutation(false, null, Clone(entry), $"Attempt is already {entry.Stage}");

            var sourceIsComplete = TryRecoverFinalizedSource(
                entry,
                allowPartialPromotion: entry.FinalizationStarted &&
                                       entry.SourceIntegrity != AudioSourceIntegrity.KnownIncomplete &&
                                       integrity != AudioSourceIntegrity.KnownIncomplete);
            entry.Stage = cancelled ? AudioProcessingStage.Cancelled : AudioProcessingStage.Failed;
            entry.ErrorMessage = message;
            // A late caller may still hold the pre-promotion lease/integrity.
            // Terminalization must never downgrade a source already validated
            // and atomically promoted by an earlier in-flight transition.
            if (sourceIsComplete)
            {
                entry.SourceIntegrity = AudioSourceIntegrity.Complete;
            }
            else if (entry.SourceIntegrity != AudioSourceIntegrity.Complete)
            {
                entry.SourceIntegrity = entry.SourceIntegrity == AudioSourceIntegrity.KnownIncomplete
                    ? AudioSourceIntegrity.KnownIncomplete
                    : integrity;
            }
            Touch(entry);
            SaveDocument(document);
            return Applied(entry, document.ClearGeneration);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<AudioStoreMutation> TombstoneAsync(
        Guid recordingId,
        CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var document = LoadDocument();
            if (!document.Entries.TryGetValue(recordingId, out var entry))
                return new AudioStoreMutation(false, null, null, "Recording was not found");
            if (entry.IsActive)
                return new AudioStoreMutation(false, null, Clone(entry), "Wait for audio processing to finish before deleting this recording.");

            entry.AttemptId = null;
            entry.DeletionGeneration++;
            entry.Stage = AudioProcessingStage.Deleted;
            entry.ErrorMessage = null;
            Touch(entry);
            SaveDocument(document);
            DeleteDerivedSources(recordingId);
            if (TryDeleteTrackedLegacySource(entry))
            {
                ClearLegacySourceTracking(entry);
                Touch(entry);
                SaveDocument(document);
            }
            return new AudioStoreMutation(
                true,
                null,
                Clone(entry),
                ClearGeneration: document.ClearGeneration);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<AudioStoreMutation> ClearAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var document = LoadDocument();
            if (document.Entries.Values.Any(entry => entry.IsActive))
                return new AudioStoreMutation(false, null, null, "Wait for audio processing to finish before clearing History.");

            document.ClearGeneration++;
            foreach (var entry in document.Entries.Values)
            {
                entry.AttemptId = null;
                entry.DeletionGeneration++;
                entry.Stage = AudioProcessingStage.Deleted;
                Touch(entry);
            }
            SaveDocument(document);
            var clearedLegacyTracking = false;
            foreach (var recordingId in document.Entries.Keys)
            {
                DeleteDerivedSources(recordingId);
                var entry = document.Entries[recordingId];
                if (TryDeleteTrackedLegacySource(entry))
                {
                    ClearLegacySourceTracking(entry);
                    Touch(entry);
                    clearedLegacyTracking = true;
                }
            }
            if (clearedLegacyTracking) SaveDocument(document);
            return new AudioStoreMutation(
                true,
                null,
                null,
                ClearGeneration: document.ClearGeneration);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<IReadOnlyList<AudioProcessingEntry>> RecoverOnLaunchAsync(
        CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var document = LoadDocument();
            ManagedAudioWorkspace.Sweep(_rootPath, _workspacesPath);
            var changed = false;
            foreach (var entry in document.Entries.Values)
            {
                if (entry.Stage == AudioProcessingStage.Deleted)
                {
                    DeleteDerivedSources(entry.RecordingId);
                    if (TryDeleteTrackedLegacySource(entry))
                    {
                        ClearLegacySourceTracking(entry);
                        Touch(entry);
                        changed = true;
                    }
                    continue;
                }
                if (entry.LegacySourceDeletionPending &&
                    ManagedSourceIsRegular(entry.RecordingId, final: true) &&
                    AudioContainerValidator.ValidateFinalizedWave(FinalPath(entry.RecordingId)).IsValid &&
                    TryDeleteTrackedLegacySource(entry))
                {
                    ClearLegacySourceTracking(entry);
                    Touch(entry);
                    changed = true;
                }
                var canPromoteLateFinalization = entry.FinalizationStarted &&
                                                  entry.SourceIntegrity != AudioSourceIntegrity.KnownIncomplete;
                var finalIsValid = TryRecoverFinalizedSource(
                    entry,
                    allowPartialPromotion: canPromoteLateFinalization);
                if (!entry.IsActive)
                {
                    if (entry.SourceIntegrity == AudioSourceIntegrity.Unfinalized && finalIsValid)
                    {
                        entry.SourceIntegrity = AudioSourceIntegrity.Complete;
                        entry.ErrorMessage = entry.Stage == AudioProcessingStage.Cancelled
                            ? "Recording was cancelled after its audio finished saving. You can retry it from History."
                            : "The audio finished saving after processing stopped. Retry from History.";
                        Touch(entry);
                        changed = true;
                    }
                    continue;
                }
                if (entry.Stage == AudioProcessingStage.ResultReady && !string.IsNullOrWhiteSpace(entry.RawText))
                {
                    entry.FinalText = entry.RawText;
                    entry.Stage = AudioProcessingStage.Succeeded;
                    entry.ErrorMessage = null;
                    entry.UsageAccounting ??= UsageAccountingState.Pending;
                }
                else
                {
                    entry.Stage = AudioProcessingStage.Failed;
                    entry.SourceIntegrity = finalIsValid
                        ? AudioSourceIntegrity.Complete
                        : entry.SourceIntegrity is AudioSourceIntegrity.Complete or
                            AudioSourceIntegrity.KnownIncomplete
                            ? AudioSourceIntegrity.KnownIncomplete
                            : AudioSourceIntegrity.Unfinalized;
                    entry.ErrorMessage = finalIsValid
                        ? "Audio processing was interrupted. Retry from History."
                        : "Recording was interrupted before the audio file finished closing.";
                }
                entry.AttemptId = null;
                Touch(entry);
                changed = true;
            }

            if (changed) SaveDocument(document);
            return document.Entries.Values.Select(Clone).ToList();
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>
    /// One-time migration for recordings created before the recovery journal.
    /// The legacy source is copied, never removed, until the managed copy and
    /// journal entry have both committed.
    /// </summary>
    public async Task<AudioStoreMutation> ImportLegacyFinalizedSourceAsync(
        Guid recordingId,
        string legacySourcePath,
        string? finalText,
        TranscriptionAttemptSnapshot snapshot,
        CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var document = LoadDocument();
            if (document.Entries.TryGetValue(recordingId, out var existing))
                return new AudioStoreMutation(true, null, Clone(existing));
            if (!TryValidateOwnedLegacySource(legacySourcePath, mustExist: true, out var safeLegacySource))
                return new AudioStoreMutation(
                    false,
                    null,
                    null,
                    "This older recording is outside the app's managed recording folder.");
            var validation = AudioContainerValidator.ValidateFinalizedWave(safeLegacySource);
            if (!validation.IsValid)
                return new AudioStoreMutation(false, null, null, validation.ErrorMessage);

            var destination = FinalPath(recordingId);
            var temporary = destination + ".import";
            EnsureManagedSourceFile(destination, mustExist: false);
            EnsureManagedSourceFile(temporary, mustExist: false);
            File.Copy(safeLegacySource, temporary, overwrite: true);
            var copiedValidation = AudioContainerValidator.ValidateFinalizedWave(temporary);
            if (!copiedValidation.IsValid)
            {
                try { File.Delete(temporary); } catch { }
                return new AudioStoreMutation(false, null, null, copiedValidation.ErrorMessage);
            }
            File.Move(temporary, destination, overwrite: true);
            var now = _utcNow();
            var entry = new AudioProcessingEntry
            {
                RecordingId = recordingId,
                AttemptId = null,
                DeletionGeneration = 0,
                Revision = 1,
                Stage = string.IsNullOrWhiteSpace(finalText)
                    ? AudioProcessingStage.Failed
                    : AudioProcessingStage.Succeeded,
                SourceIntegrity = AudioSourceIntegrity.Complete,
                PartialSourcePath = PartialPath(recordingId),
                FinalSourcePath = destination,
                RawText = finalText,
                FinalText = finalText,
                ErrorMessage = string.IsNullOrWhiteSpace(finalText)
                    ? "This recording is ready to retry."
                    : null,
                LegacySourcePath = safeLegacySource,
                LegacySourceOwned = true,
                LegacySourceDeletionPending = false,
                FinalizationStarted = true,
                CreatedUtc = now,
                UpdatedUtc = now,
                SettingsSnapshot = snapshot
            };
            document.Entries[recordingId] = entry;
            SaveDocument(document);
            return new AudioStoreMutation(true, null, Clone(entry));
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>
    /// Called only after History has durably repointed the row to the managed
    /// copy. Ownership is committed before deletion so a crash retries safely.
    /// </summary>
    public async Task<bool> AcceptLegacySourceOwnershipAsync(
        Guid recordingId,
        CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var document = LoadDocument();
            if (!document.Entries.TryGetValue(recordingId, out var entry)) return false;
            if (!entry.LegacySourceOwned || string.IsNullOrWhiteSpace(entry.LegacySourcePath)) return true;

            // History has repointed to this managed source, so validate it
            // again immediately before deleting the only other valid copy.
            // A crash, disk cleanup, or corruption between import and repoint
            // must leave the legacy source untouched.
            EnsureManagedSourceFile(FinalPath(recordingId), mustExist: true);
            var managedValidation = AudioContainerValidator.ValidateFinalizedWave(FinalPath(recordingId));
            if (!managedValidation.IsValid) return false;

            if (!entry.LegacySourceDeletionPending)
            {
                entry.LegacySourceDeletionPending = true;
                Touch(entry);
                SaveDocument(document);
            }
            if (!TryDeleteTrackedLegacySource(entry)) return false;

            ClearLegacySourceTracking(entry);
            Touch(entry);
            SaveDocument(document);
            return true;
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<AudioProcessingEntry?> GetAsync(Guid recordingId, CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var document = LoadDocument();
            return document.Entries.TryGetValue(recordingId, out var entry) ? Clone(entry) : null;
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task<AudioStoreMutation> AdvanceAsync(
        AudioAttemptLease lease,
        IReadOnlyCollection<AudioProcessingStage> allowedStages,
        Action<AudioProcessingEntry> mutate,
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var document = LoadDocument();
            var match = Match(document, lease, allowedStages.ToArray());
            if (!match.Applied || match.Entry == null)
                return match;

            mutate(match.Entry);
            Touch(match.Entry);
            SaveDocument(document);
            return Applied(match.Entry, document.ClearGeneration);
        }
        finally
        {
            _gate.Release();
        }
    }

    private AudioStoreMutation Match(
        JournalDocument document,
        AudioAttemptLease lease,
        params AudioProcessingStage[] allowedStages)
    {
        if (!document.Entries.TryGetValue(lease.RecordingId, out var entry))
            return new AudioStoreMutation(false, null, null, "Recording was not found");
        if (document.ClearGeneration != lease.ClearGeneration ||
            entry.DeletionGeneration != lease.DeletionGeneration ||
            entry.AttemptId != lease.AttemptId ||
            entry.Revision != lease.Revision ||
            entry.Stage == AudioProcessingStage.Deleted)
        {
            return new AudioStoreMutation(false, null, Clone(entry), "Attempt is stale");
        }
        if (!allowedStages.Contains(entry.Stage))
            return new AudioStoreMutation(false, null, Clone(entry), $"Invalid transition from {entry.Stage}");
        return new AudioStoreMutation(true, lease, entry);
    }

    private void Touch(AudioProcessingEntry entry)
    {
        entry.Revision++;
        entry.UpdatedUtc = _utcNow();
    }

    private static AudioStoreMutation Applied(AudioProcessingEntry entry, long clearGeneration)
    {
        var lease = entry.AttemptId.HasValue
            ? new AudioAttemptLease(
                entry.RecordingId,
                entry.AttemptId.Value,
                entry.DeletionGeneration,
                clearGeneration,
                entry.Revision)
            : null;
        return new AudioStoreMutation(true, lease, Clone(entry), ClearGeneration: clearGeneration);
    }

    private JournalDocument LoadDocument()
    {
        if (!_persistenceHealthy)
            throw new AudioStoreException("Audio recovery storage is unavailable. Restart the app after repairing the file.");

        try
        {
            EnsureManagedLayout();
            ManagedAudioPathPolicy.EnsureDirectRegularFile(
                _rootPath,
                _journalPath,
                mustExist: false);
            if (!ManagedAudioPathPolicy.EntryExistsNoFollow(_journalPath))
                return new JournalDocument();
            var json = File.ReadAllText(_journalPath);
            var document = JsonSerializer.Deserialize<JournalDocument>(json, _jsonOptions);
            if (document == null || document.SchemaVersion != 1 || document.Entries == null)
                throw new JsonException("Unsupported or empty audio journal");
            foreach (var pair in document.Entries)
            {
                if (pair.Value == null || pair.Key == Guid.Empty ||
                    pair.Value.RecordingId != pair.Key)
                    throw new JsonException("Audio journal recording identity is invalid");

                // Paths in JSON are never an authority. Derive both managed
                // locations from the validated stable ID on every read.
                pair.Value.PartialSourcePath = PartialPath(pair.Key);
                pair.Value.FinalSourcePath = FinalPath(pair.Key);
                pair.Value.ClearGeneration = document.ClearGeneration;
            }
            return document;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
        {
            _persistenceHealthy = false;
            try
            {
                if (!ManagedAudioPathPolicy.IsReparsePoint(_journalPath))
                {
                    ManagedAudioPathPolicy.EnsureDirectRegularFile(
                        _rootPath,
                        _journalPath + ".corrupt",
                        mustExist: false);
                    File.Copy(_journalPath, _journalPath + ".corrupt", overwrite: true);
                }
            }
            catch { }
            throw new AudioStoreException(
                "Audio recovery data could not be read. It was preserved and will not be overwritten.", ex);
        }
    }

    private void SaveDocument(JournalDocument document)
    {
        if (!_persistenceHealthy)
            throw new AudioStoreException("Audio recovery storage is unavailable.");

        try
        {
            EnsureManagedLayout();
            var tempPath = _journalPath + ".tmp";
            ManagedAudioPathPolicy.EnsureDirectRegularFile(
                _rootPath,
                _journalPath,
                mustExist: false);
            ManagedAudioPathPolicy.EnsureDirectRegularFile(
                _rootPath,
                tempPath,
                mustExist: false);
            var bytes = JsonSerializer.SerializeToUtf8Bytes(document, _jsonOptions);
            using (var stream = new FileStream(
                       tempPath,
                       FileMode.Create,
                       FileAccess.Write,
                       FileShare.None,
                       16 * 1024,
                       FileOptions.WriteThrough))
            {
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
            }
            File.Move(tempPath, _journalPath, overwrite: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            throw new AudioStoreException("Audio recovery data could not be saved.", ex);
        }
    }

    private string PartialPath(Guid recordingId) =>
        Path.Combine(_sourcesPath, $"{recordingId:N}.partial.wav");

    private string FinalPath(Guid recordingId) =>
        Path.Combine(_sourcesPath, $"{recordingId:N}.wav");

    private bool TryRecoverFinalizedSource(
        AudioProcessingEntry entry,
        bool allowPartialPromotion)
    {
        var finalPath = FinalPath(entry.RecordingId);
        EnsureManagedSourceFile(finalPath, mustExist: false);
        if (AudioContainerValidator.ValidateFinalizedWave(finalPath).IsValid)
            return true;
        if (!allowPartialPromotion) return false;

        var partialPath = PartialPath(entry.RecordingId);
        EnsureManagedSourceFile(partialPath, mustExist: false);
        if (!AudioContainerValidator.ValidateFinalizedWave(partialPath).IsValid)
            return false;
        try
        {
            File.Move(partialPath, finalPath, overwrite: true);
            return AudioContainerValidator.ValidateFinalizedWave(finalPath).IsValid;
        }
        catch
        {
            // Preserve the complete partial. Abandonment or a later launch can
            // retry same-volume promotion after storage access recovers.
            return false;
        }
    }

    private void DeleteDerivedSources(Guid recordingId)
    {
        foreach (var path in new[] { PartialPath(recordingId), FinalPath(recordingId) })
        {
            EnsureManagedSourceFile(path, mustExist: false);
            if (ManagedAudioPathPolicy.EntryExistsNoFollow(path)) File.Delete(path);
        }
    }

    private bool TryDeleteTrackedLegacySource(AudioProcessingEntry entry)
    {
        if (!entry.LegacySourceOwned || string.IsNullOrWhiteSpace(entry.LegacySourcePath)) return false;
        if (!TryValidateOwnedLegacySource(entry.LegacySourcePath, mustExist: false, out var safePath))
            return false;
        try
        {
            if (ManagedAudioPathPolicy.EntryExistsNoFollow(safePath)) File.Delete(safePath);
            return !ManagedAudioPathPolicy.EntryExistsNoFollow(safePath);
        }
        catch
        {
            return false;
        }
    }

    private bool TryValidateOwnedLegacySource(
        string path,
        bool mustExist,
        out string safePath)
    {
        safePath = string.Empty;
        try
        {
            var fullPath = Path.GetFullPath(path);
            if (!ManagedAudioPathPolicy.PathEquals(
                    _legacyRecordingsPath,
                    Path.GetDirectoryName(fullPath) ?? string.Empty))
                return false;
            var name = Path.GetFileName(fullPath);
            if (!name.StartsWith("recording_", StringComparison.OrdinalIgnoreCase) ||
                !name.EndsWith(".wav", StringComparison.OrdinalIgnoreCase) ||
                !long.TryParse(name["recording_".Length..^".wav".Length], out _))
                return false;
            ManagedAudioPathPolicy.EnsureDirectoryChain(
                _trustedLegacyRootPath,
                _legacyRecordingsPath,
                create: false);
            safePath = ManagedAudioPathPolicy.EnsureDirectRegularFile(
                _legacyRecordingsPath,
                fullPath,
                mustExist);
            return true;
        }
        catch
        {
            return false;
        }
    }

    private void EnsureManagedLayout()
    {
        ManagedAudioPathPolicy.EnsureDirectoryChain(
            _trustedRootPath,
            _rootPath,
            create: true);
        ManagedAudioPathPolicy.EnsureDirectoryChain(
            _rootPath,
            _sourcesPath,
            create: true);
        ManagedAudioPathPolicy.EnsureDirectoryChain(
            _rootPath,
            _workspacesPath,
            create: true);
    }

    private void EnsureManagedSourceFile(string path, bool mustExist)
    {
        EnsureManagedLayout();
        _ = ManagedAudioPathPolicy.EnsureDirectRegularFile(
            _sourcesPath,
            path,
            mustExist);
    }

    private bool ManagedSourceIsRegular(Guid recordingId, bool final)
    {
        try
        {
            EnsureManagedSourceFile(
                final ? FinalPath(recordingId) : PartialPath(recordingId),
                mustExist: true);
            return true;
        }
        catch
        {
            return false;
        }
    }

    private static void ClearLegacySourceTracking(AudioProcessingEntry entry)
    {
        entry.LegacySourcePath = null;
        entry.LegacySourceOwned = false;
        entry.LegacySourceDeletionPending = false;
    }

    private static string DefaultRootPath()
    {
        return Path.Combine(DefaultAppDataPath(), "AIDictation", "AudioProcessing");
    }

    private static string DefaultLegacyRecordingsPath()
    {
        return Path.Combine(DefaultAppDataPath(), "AIDictation", "Recordings");
    }

    private static string DefaultAppDataPath() =>
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);

    private static AudioProcessingEntry Clone(AudioProcessingEntry entry)
    {
        return new AudioProcessingEntry
        {
            RecordingId = entry.RecordingId,
            AttemptId = entry.AttemptId,
            DeletionGeneration = entry.DeletionGeneration,
            ClearGeneration = entry.ClearGeneration,
            Revision = entry.Revision,
            Stage = entry.Stage,
            SourceIntegrity = entry.SourceIntegrity,
            PartialSourcePath = entry.PartialSourcePath,
            FinalSourcePath = entry.FinalSourcePath,
            RawText = entry.RawText,
            CheckpointText = entry.CheckpointText,
            CompletedLeafCount = entry.CompletedLeafCount,
            FinalText = entry.FinalText,
            ErrorMessage = entry.ErrorMessage,
            LegacySourcePath = entry.LegacySourcePath,
            LegacySourceOwned = entry.LegacySourceOwned,
            LegacySourceDeletionPending = entry.LegacySourceDeletionPending,
            FinalizationStarted = entry.FinalizationStarted,
            UsageAccounting = entry.UsageAccounting,
            CreatedUtc = entry.CreatedUtc,
            UpdatedUtc = entry.UpdatedUtc,
            SettingsSnapshot = entry.SettingsSnapshot
        };
    }
}
