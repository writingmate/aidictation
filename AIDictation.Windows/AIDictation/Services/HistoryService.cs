using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using AIDictation.Models;
using Newtonsoft.Json;

namespace AIDictation.Services;

/// <summary>
/// Persists History away from the WPF dispatcher. A mutation becomes visible
/// to readers and the bound collection only after its write-then-rename has
/// completed. Revisions and publication generations fence late completions.
/// </summary>
public sealed class HistoryService : IRecordingHistory
{
    public static HistoryService Instance { get; } = new();

    private static class Constants
    {
        public const string AppFolderName = "AIDictation";
        public const string HistoryFileName = "history.json";
    }

    public ObservableCollection<Recording> Recordings { get; } = new();
    public event EventHandler? HistoryChanged;

    private readonly string _appDataPath;
    private readonly string _historyPath;
    private readonly JsonSerializerSettings _jsonSettings;
    private readonly object _lock = new();
    private readonly SemaphoreSlim _mutationGate = new(1, 1);
    private readonly HistoryTombstoneFence _tombstoneFence = new();
    private List<Recording> _durableRecordings = new();
    private bool _isLoaded;
    private volatile bool _persistenceHealthy = true;
    private long _publicationGeneration;
    private long _publishedGeneration;

    public bool PersistenceHealthy => _persistenceHealthy;

    private HistoryService()
    {
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        _appDataPath = Path.Combine(appData, Constants.AppFolderName);
        _historyPath = Path.Combine(_appDataPath, Constants.HistoryFileName);
        _jsonSettings = new JsonSerializerSettings
        {
            Formatting = Formatting.Indented,
            NullValueHandling = NullValueHandling.Ignore
        };

        try { EnsureDirectoriesExist(); }
        catch { _persistenceHealthy = false; }
    }

    /// <summary>Loads and normalizes History without blocking the dispatcher.</summary>
    public async Task LoadAsync(CancellationToken cancellationToken = default)
    {
        await _mutationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            lock (_lock)
            {
                if (_isLoaded) return;
            }

            var recordings = await Task.Run(LoadFromFile, CancellationToken.None)
                .ConfigureAwait(false);
            var normalized = false;
            foreach (var recording in recordings)
            {
                if (recording.Status is not (TranscriptionStatus.Processing or TranscriptionStatus.Retrying))
                    continue;
                recording.Status = TranscriptionStatus.Failed;
                recording.ErrorMessage = "Audio processing was interrupted. Retry from History.";
                normalized = true;
            }
            recordings = recordings.OrderByDescending(recording => recording.Timestamp).ToList();

            if (normalized && _persistenceHealthy &&
                !await SaveSnapshotAsync(recordings, cancellationToken).ConfigureAwait(false))
            {
                return;
            }

            long generation;
            lock (_lock)
            {
                _durableRecordings = recordings.Select(CloneRecording).ToList();
                _isLoaded = true;
                generation = ++_publicationGeneration;
            }
            await PublishSnapshotAsync(recordings, generation).ConfigureAwait(false);
        }
        finally
        {
            _mutationGate.Release();
        }
    }

    public Recording? Get(Guid id)
    {
        lock (_lock)
        {
            var recording = _durableRecordings.FirstOrDefault(item => item.Id == id);
            return recording == null ? null : CloneRecording(recording);
        }
    }

    public IReadOnlyList<Recording> GetAll()
    {
        lock (_lock)
            return _durableRecordings.Select(CloneRecording).ToList().AsReadOnly();
    }

    public Task<bool> UpdateAsync(
        Recording recording,
        CancellationToken cancellationToken = default) =>
        PersistMutationAsync(rows =>
        {
            if (!_tombstoneFence.CanPublish(recording.Id)) return Mutation.Rejected;
            var index = rows.FindIndex(item => item.Id == recording.Id);
            if (index < 0) return Mutation.Rejected;
            if (rows[index].Revision > recording.Revision) return Mutation.AcceptedUnchanged;
            rows[index] = CloneRecording(recording);
            return Mutation.AcceptedChanged;
        }, cancellationToken);

    public Task<bool> UpsertAsync(
        Recording recording,
        CancellationToken cancellationToken = default) =>
        PersistMutationAsync(rows =>
        {
            if (!_tombstoneFence.CanPublish(recording.Id)) return Mutation.Rejected;
            var index = rows.FindIndex(item => item.Id == recording.Id);
            if (index >= 0 && rows[index].Revision > recording.Revision)
                return Mutation.AcceptedUnchanged;
            if (index >= 0) rows[index] = CloneRecording(recording);
            else rows.Insert(0, CloneRecording(recording));
            return Mutation.AcceptedChanged;
        }, cancellationToken);

    public Task<bool> RemoveMetadataAfterTombstoneAsync(
        Guid id,
        CancellationToken cancellationToken = default) =>
        PersistMutationAsync(rows =>
        {
            var removed = rows.RemoveAll(item => item.Id == id) > 0;
            return removed ? Mutation.AcceptedChanged : Mutation.AcceptedUnchanged;
        }, cancellationToken, () => _tombstoneFence.Commit(id));

    public async Task<bool> ClearMetadataAfterTombstoneAsync(
        CancellationToken cancellationToken = default)
    {
        IReadOnlyList<Guid> clearedIds = Array.Empty<Guid>();
        return await PersistMutationAsync(rows =>
        {
            if (rows.Count == 0) return Mutation.AcceptedUnchanged;
            clearedIds = rows.Select(item => item.Id).ToArray();
            rows.Clear();
            return Mutation.AcceptedChanged;
        }, cancellationToken, () => _tombstoneFence.Commit(clearedIds)).ConfigureAwait(false);
    }

    public IReadOnlyList<Recording> Search(string query)
    {
        if (string.IsNullOrWhiteSpace(query)) return GetAll();
        lock (_lock)
        {
            return _durableRecordings
                .Where(recording => recording.Transcription?.Contains(
                    query,
                    StringComparison.OrdinalIgnoreCase) == true)
                .Select(CloneRecording)
                .ToList()
                .AsReadOnly();
        }
    }

    private async Task<bool> PersistMutationAsync(
        Func<List<Recording>, Mutation> mutation,
        CancellationToken cancellationToken,
        Action? onCommitted = null)
    {
        await _mutationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (!_persistenceHealthy) return false;
            List<Recording> candidate;
            lock (_lock)
                candidate = _durableRecordings.Select(CloneRecording).ToList();

            var decision = mutation(candidate);
            if (!decision.Accepted) return false;
            if (!decision.Changed)
            {
                onCommitted?.Invoke();
                return true;
            }
            if (!await SaveSnapshotAsync(candidate, cancellationToken).ConfigureAwait(false))
                return false;

            long generation;
            lock (_lock)
            {
                _durableRecordings = candidate.Select(CloneRecording).ToList();
                generation = ++_publicationGeneration;
            }
            onCommitted?.Invoke();

            // Dispatcher publication is deliberately detached: coordinator
            // deadlines cover durable I/O, never a blocked UI message pump.
            ObserveLateTask(PublishSnapshotAsync(candidate, generation));
            return true;
        }
        finally
        {
            _mutationGate.Release();
        }
    }

    private async Task<bool> SaveSnapshotAsync(
        IReadOnlyList<Recording> recordings,
        CancellationToken cancellationToken)
    {
        if (!_persistenceHealthy) return false;
        var snapshot = recordings.Select(CloneRecording).ToList();
        try
        {
            return await Task.Run(async () =>
            {
                cancellationToken.ThrowIfCancellationRequested();
                EnsureDirectoriesExist();
                var json = JsonConvert.SerializeObject(snapshot, _jsonSettings);
                var tempPath = _historyPath + ".tmp";
                await using (var stream = new FileStream(
                                 tempPath,
                                 FileMode.Create,
                                 FileAccess.Write,
                                 FileShare.None,
                                 16 * 1024,
                                 FileOptions.Asynchronous | FileOptions.WriteThrough))
                await using (var writer = new StreamWriter(stream))
                {
                    await writer.WriteAsync(json.AsMemory(), cancellationToken).ConfigureAwait(false);
                    await writer.FlushAsync(cancellationToken).ConfigureAwait(false);
                    await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
                    // Flush-to-disk is synchronous on Windows; it runs only on
                    // this owned background worker, never on the dispatcher.
                    stream.Flush(flushToDisk: true);
                }
                File.Move(tempPath, _historyPath, overwrite: true);
                return true;
            }, CancellationToken.None).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch
        {
            _persistenceHealthy = false;
            return false;
        }
    }

    private async Task PublishSnapshotAsync(
        IReadOnlyList<Recording> recordings,
        long generation)
    {
        var snapshot = recordings.Select(CloneRecording).ToArray();
        void Apply()
        {
            if (generation < Volatile.Read(ref _publishedGeneration)) return;
            Volatile.Write(ref _publishedGeneration, generation);
            Recordings.Clear();
            foreach (var recording in snapshot) Recordings.Add(recording);
            HistoryChanged?.Invoke(this, EventArgs.Empty);
        }

        var dispatcher = System.Windows.Application.Current?.Dispatcher;
        if (dispatcher == null || dispatcher.CheckAccess())
        {
            Apply();
            return;
        }
        await dispatcher.InvokeAsync(Apply).Task.ConfigureAwait(false);
    }

    private void EnsureDirectoriesExist()
    {
        if (!Directory.Exists(_appDataPath)) Directory.CreateDirectory(_appDataPath);
    }

    private List<Recording> LoadFromFile()
    {
        try
        {
            if (!File.Exists(_historyPath)) return new List<Recording>();
            var json = File.ReadAllText(_historyPath);
            return JsonConvert.DeserializeObject<List<Recording>>(json, _jsonSettings) ?? new();
        }
        catch (IOException)
        {
            _persistenceHealthy = false;
            return new List<Recording>();
        }
        catch
        {
            try { File.Copy(_historyPath, _historyPath + ".bak", overwrite: true); }
            catch { }
            _persistenceHealthy = false;
            return new List<Recording>();
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

    private readonly record struct Mutation(bool Accepted, bool Changed)
    {
        public static Mutation Rejected => new(false, false);
        public static Mutation AcceptedUnchanged => new(true, false);
        public static Mutation AcceptedChanged => new(true, true);
    }

    private static Recording CloneRecording(Recording recording) => new()
    {
        Id = recording.Id,
        Timestamp = recording.Timestamp,
        AudioFilePath = recording.AudioFilePath,
        Transcription = recording.Transcription,
        RawTranscription = recording.RawTranscription,
        CheckpointTranscription = recording.CheckpointTranscription,
        Status = recording.Status,
        ErrorMessage = recording.ErrorMessage,
        RetryCount = recording.RetryCount,
        SourceIntegrity = recording.SourceIntegrity,
        Revision = recording.Revision,
        Duration = recording.Duration,
        WordCount = recording.WordCount
    };
}
