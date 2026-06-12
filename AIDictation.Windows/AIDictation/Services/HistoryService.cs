using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using AIDictation.Models;
using Newtonsoft.Json;

namespace AIDictation.Services;

/// <summary>
/// Manages recording history persistence and retrieval.
/// Stores recordings in %APPDATA%\AIDictation\history.json with auto-save on changes.
/// </summary>
public sealed class HistoryService
{
    // MARK: - Singleton

    public static HistoryService Instance { get; } = new();

    // MARK: - Constants

    private static class Constants
    {
        public const string AppFolderName = "AIDictation";
        public const string HistoryFileName = "history.json";
        public const string AudioFolderName = "recordings";
        public const int MaxRecordings = 100;
        public const long MaxAudioBytes = 500L * 1024 * 1024;
    }

    // MARK: - Public Properties

    /// <summary>
    /// Observable collection of recordings for UI binding.
    /// </summary>
    public ObservableCollection<Recording> Recordings { get; } = new();

    // MARK: - Events

    public event EventHandler? HistoryChanged;

    // MARK: - Private Properties

    private readonly string _appDataPath;
    private readonly string _historyPath;
    private readonly string _audioPath;
    private readonly JsonSerializerSettings _jsonSettings;
    private readonly object _lock = new();
    private bool _isLoaded;

    // MARK: - Initialization

    private HistoryService()
    {
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        _appDataPath = Path.Combine(appData, Constants.AppFolderName);
        _historyPath = Path.Combine(_appDataPath, Constants.HistoryFileName);
        _audioPath = Path.Combine(_appDataPath, Constants.AudioFolderName);

        _jsonSettings = new JsonSerializerSettings
        {
            Formatting = Formatting.Indented,
            NullValueHandling = NullValueHandling.Ignore
        };

        EnsureDirectoriesExist();
    }

    // MARK: - Public API

    /// <summary>
    /// Loads history from disk. Safe to call multiple times.
    /// </summary>
    public void Load()
    {
        RunOnUiThread(() =>
        {
            lock (_lock)
            {
                if (_isLoaded) return;

                var recordings = LoadFromFile();
                Recordings.Clear();
                foreach (var recording in recordings.OrderByDescending(r => r.Timestamp))
                {
                    Recordings.Add(recording);
                }

                _isLoaded = true;
            }
        });

        CleanupOrphanedAudioFiles();
        EnforceAudioStorageCap();
    }

    /// <summary>
    /// Adds a new recording to history.
    /// </summary>
    public void Add(Recording recording)
    {
        RunOnUiThread(() =>
        {
            lock (_lock)
            {
                // Insert at the beginning (most recent first)
                Recordings.Insert(0, recording);

                // Enforce max limit
                while (Recordings.Count > Constants.MaxRecordings)
                {
                    var oldest = Recordings[^1];
                    DeleteAudioFile(oldest.AudioFilePath);
                    Recordings.RemoveAt(Recordings.Count - 1);
                }

                Save();
            }
        });

        HistoryChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>
    /// Gets a recording by its ID.
    /// </summary>
    public Recording? Get(Guid id)
    {
        lock (_lock)
        {
            return Recordings.FirstOrDefault(r => r.Id == id);
        }
    }

    /// <summary>
    /// Gets all recordings.
    /// </summary>
    public IReadOnlyList<Recording> GetAll()
    {
        lock (_lock)
        {
            return Recordings.ToList().AsReadOnly();
        }
    }

    /// <summary>
    /// Updates an existing recording.
    /// </summary>
    public void Update(Recording recording)
    {
        RunOnUiThread(() =>
        {
            lock (_lock)
            {
                var index = IndexOf(recording.Id);
                if (index >= 0)
                {
                    Recordings[index] = recording;
                    Save();
                }
            }
        });

        HistoryChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>
    /// Deletes a recording by its ID.
    /// </summary>
    public bool Delete(Guid id)
    {
        var deleted = false;
        RunOnUiThread(() =>
        {
            lock (_lock)
            {
                var recording = Recordings.FirstOrDefault(r => r.Id == id);
                if (recording == null) return;

                DeleteAudioFile(recording.AudioFilePath);
                Recordings.Remove(recording);
                Save();
                deleted = true;
            }
        });

        if (deleted)
        {
            HistoryChanged?.Invoke(this, EventArgs.Empty);
        }
        return deleted;
    }

    /// <summary>
    /// Clears all recordings and their audio files.
    /// </summary>
    public void Clear()
    {
        RunOnUiThread(() =>
        {
            lock (_lock)
            {
                foreach (var recording in Recordings)
                {
                    DeleteAudioFile(recording.AudioFilePath);
                }

                Recordings.Clear();
                Save();
            }
        });

        HistoryChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>
    /// Searches recordings by transcription text.
    /// </summary>
    public IReadOnlyList<Recording> Search(string query)
    {
        if (string.IsNullOrWhiteSpace(query))
        {
            return GetAll();
        }

        lock (_lock)
        {
            return Recordings
                .Where(r => r.Transcription?.Contains(query, StringComparison.OrdinalIgnoreCase) == true)
                .ToList()
                .AsReadOnly();
        }
    }

    /// <summary>
    /// Gets the path for storing audio files.
    /// </summary>
    public string GetAudioStoragePath()
    {
        return _audioPath;
    }

    /// <summary>
    /// Generates a unique audio file path for a new recording.
    /// </summary>
    public string GenerateAudioFilePath(string extension = ".wav")
    {
        EnsureDirectoriesExist();
        var fileName = $"{Guid.NewGuid()}{extension}";
        return Path.Combine(_audioPath, fileName);
    }

    // MARK: - Private Methods

    private void EnsureDirectoriesExist()
    {
        if (!Directory.Exists(_appDataPath))
        {
            Directory.CreateDirectory(_appDataPath);
        }

        if (!Directory.Exists(_audioPath))
        {
            Directory.CreateDirectory(_audioPath);
        }
    }

    private List<Recording> LoadFromFile()
    {
        try
        {
            if (!File.Exists(_historyPath)) return new List<Recording>();
            var json = File.ReadAllText(_historyPath);
            return JsonConvert.DeserializeObject<List<Recording>>(json, _jsonSettings) ?? new List<Recording>();
        }
        catch (IOException)
        {
            return new List<Recording>();
        }
        catch
        {
            // Keep the corrupt file as evidence instead of overwriting it.
            try { File.Copy(_historyPath, _historyPath + ".bak", overwrite: true); } catch { }
            return new List<Recording>();
        }
    }

    private void Save()
    {
        try
        {
            var json = JsonConvert.SerializeObject(Recordings.ToList(), _jsonSettings);
            // Write-then-rename keeps a crash mid-write from truncating the file.
            var tempPath = _historyPath + ".tmp";
            File.WriteAllText(tempPath, json);
            File.Move(tempPath, _historyPath, overwrite: true);
        }
        catch
        {
            // Silently fail - could add logging here
        }
    }

    private static void RunOnUiThread(Action action)
    {
        // The Recordings collection is bound to WPF views; mutating it off the
        // dispatcher thread throws NotSupportedException in CollectionView.
        var dispatcher = System.Windows.Application.Current?.Dispatcher;
        if (dispatcher == null || dispatcher.CheckAccess())
        {
            action();
        }
        else
        {
            dispatcher.Invoke(action);
        }
    }

    private int IndexOf(Guid id)
    {
        for (int i = 0; i < Recordings.Count; i++)
        {
            if (Recordings[i].Id == id) return i;
        }
        return -1;
    }

    private static void DeleteAudioFile(string? path)
    {
        if (string.IsNullOrEmpty(path)) return;

        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch
        {
            // Silently fail - file may be in use or already deleted
        }
    }

    /// <summary>
    /// Removes audio files that are not referenced by any recording.
    /// </summary>
    private void CleanupOrphanedAudioFiles()
    {
        try
        {
            if (!Directory.Exists(_audioPath)) return;

            var referencedFiles = new HashSet<string>(
                Recordings
                    .Where(r => !string.IsNullOrEmpty(r.AudioFilePath))
                    .Select(r => Path.GetFullPath(r.AudioFilePath!)),
                StringComparer.OrdinalIgnoreCase
            );

            var audioFiles = Directory.GetFiles(_audioPath);
            foreach (var file in audioFiles)
            {
                var fullPath = Path.GetFullPath(file);
                if (!referencedFiles.Contains(fullPath))
                {
                    try
                    {
                        File.Delete(file);
                    }
                    catch
                    {
                        // Skip files that can't be deleted
                    }
                }
            }
        }
        catch
        {
            // Silently fail cleanup - non-critical operation
        }
    }

    /// <summary>
    /// Deletes the oldest audio files once the recordings folder exceeds the
    /// storage cap; the count cap alone lets 100 long WAVs grow unbounded.
    /// </summary>
    private void EnforceAudioStorageCap()
    {
        try
        {
            if (!Directory.Exists(_audioPath)) return;

            long total = 0;
            foreach (var file in new DirectoryInfo(_audioPath).GetFiles()
                         .OrderByDescending(f => f.LastWriteTimeUtc))
            {
                total += file.Length;
                if (total > Constants.MaxAudioBytes)
                {
                    try { file.Delete(); } catch { }
                }
            }
        }
        catch
        {
            // Silently fail cleanup - non-critical operation
        }
    }
}
