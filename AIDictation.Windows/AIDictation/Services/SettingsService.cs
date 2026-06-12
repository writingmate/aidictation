using System;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;
using AIDictation.Models;
using Microsoft.Win32;
using Newtonsoft.Json;

namespace AIDictation.Services;

/// <summary>
/// Manages application settings persistence and launch-at-startup configuration.
/// Settings are stored in %APPDATA%\AIDictation\ as JSON files.
/// </summary>
public sealed class SettingsService
{
    // MARK: - Singleton

    public static SettingsService Instance { get; } = new();

    // MARK: - Constants

    private static class Constants
    {
        public const string AppFolderName = "AIDictation";
        public const string SettingsFileName = "settings.json";
        public const string DictionaryFileName = "dictionary.json";
        public const string ShortcutsFileName = "shortcuts.json";
        public const string ContextRulesFileName = "context_rules.json";
        public const string RegistryRunKey = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Run";
        public const string RegistryAppName = "AIDictation";
    }

    // MARK: - Public Properties

    public AppSettings Settings { get; private set; } = new();
    public List<DictionaryEntry> DictionaryEntries { get; private set; } = new();
    public List<Shortcut> Shortcuts { get; private set; } = new();
    public List<ContextRule> ContextRules { get; private set; } = new();

    // MARK: - Events

    public event EventHandler? SettingsChanged;
    public event EventHandler? DictionaryChanged;
    public event EventHandler? ShortcutsChanged;
    public event EventHandler? ContextRulesChanged;

    // MARK: - Private Properties

    private readonly string _appDataPath;
    private readonly string _settingsPath;
    private readonly string _dictionaryPath;
    private readonly string _shortcutsPath;
    private readonly string _contextRulesPath;
    private readonly JsonSerializerSettings _jsonSettings;
    private readonly object _loadLock = new();
    private bool _isLoaded;

    // MARK: - Initialization

    private SettingsService()
    {
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        _appDataPath = Path.Combine(appData, Constants.AppFolderName);
        _settingsPath = Path.Combine(_appDataPath, Constants.SettingsFileName);
        _dictionaryPath = Path.Combine(_appDataPath, Constants.DictionaryFileName);
        _shortcutsPath = Path.Combine(_appDataPath, Constants.ShortcutsFileName);
        _contextRulesPath = Path.Combine(_appDataPath, Constants.ContextRulesFileName);

        _jsonSettings = new JsonSerializerSettings
        {
            Formatting = Formatting.Indented,
            NullValueHandling = NullValueHandling.Ignore
        };

        EnsureAppDataDirectoryExists();
    }

    // MARK: - Public API

    /// <summary>
    /// Loads all settings from disk. Safe to call multiple times.
    /// </summary>
    public void Load()
    {
        lock (_loadLock)
        {
            if (_isLoaded) return;

            Settings = LoadFromFile<AppSettings>(_settingsPath) ?? new AppSettings();
            DictionaryEntries = LoadFromFile<List<DictionaryEntry>>(_dictionaryPath) ?? new List<DictionaryEntry>();
            Shortcuts = LoadFromFile<List<Shortcut>>(_shortcutsPath) ?? new List<Shortcut>();
            ContextRules = LoadFromFile<List<ContextRule>>(_contextRulesPath) ?? new List<ContextRule>();

            _isLoaded = true;
        }
    }

    /// <summary>
    /// Saves all settings to disk.
    /// </summary>
    public void SaveAll()
    {
        SaveSettings();
        SaveDictionary();
        SaveShortcuts();
        SaveContextRules();
    }

    /// <summary>
    /// Saves the main application settings.
    /// </summary>
    public void SaveSettings()
    {
        SaveToFile(_settingsPath, Settings);
        SyncLaunchAtStartup();
        SettingsChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>
    /// Saves dictionary entries.
    /// </summary>
    public void SaveDictionary()
    {
        SaveToFile(_dictionaryPath, DictionaryEntries);
        DictionaryChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>
    /// Saves shortcuts.
    /// </summary>
    public void SaveShortcuts()
    {
        SaveToFile(_shortcutsPath, Shortcuts);
        ShortcutsChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>
    /// Saves context rules.
    /// </summary>
    public void SaveContextRules()
    {
        SaveToFile(_contextRulesPath, ContextRules);
        ContextRulesChanged?.Invoke(this, EventArgs.Empty);
    }

    // MARK: - Dictionary Entry Management

    public void AddDictionaryEntry(DictionaryEntry entry)
    {
        DictionaryEntries.Add(entry);
        SaveDictionary();
    }

    public void UpdateDictionaryEntry(DictionaryEntry entry)
    {
        var index = DictionaryEntries.FindIndex(e => e.Id == entry.Id);
        if (index >= 0)
        {
            DictionaryEntries[index] = entry;
            SaveDictionary();
        }
    }

    public void RemoveDictionaryEntry(string id)
    {
        DictionaryEntries.RemoveAll(e => e.Id == id);
        SaveDictionary();
    }

    // MARK: - Shortcut Management

    public void AddShortcut(Shortcut shortcut)
    {
        Shortcuts.Add(shortcut);
        SaveShortcuts();
    }

    public void UpdateShortcut(Shortcut shortcut)
    {
        var index = Shortcuts.FindIndex(s => s.Id == shortcut.Id);
        if (index >= 0)
        {
            Shortcuts[index] = shortcut;
            SaveShortcuts();
        }
    }

    public void RemoveShortcut(string id)
    {
        Shortcuts.RemoveAll(s => s.Id == id);
        SaveShortcuts();
    }

    // MARK: - Context Rule Management

    public void AddContextRule(ContextRule rule)
    {
        ContextRules.Add(rule);
        SaveContextRules();
    }

    public void UpdateContextRule(ContextRule rule)
    {
        var index = ContextRules.FindIndex(r => r.Id == rule.Id);
        if (index >= 0)
        {
            ContextRules[index] = rule;
            SaveContextRules();
        }
    }

    public void RemoveContextRule(string id)
    {
        ContextRules.RemoveAll(r => r.Id == id);
        SaveContextRules();
    }

    // MARK: - Launch at Startup

    /// <summary>
    /// Gets whether the app is configured to launch at Windows startup.
    /// </summary>
    public bool GetLaunchAtStartup()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(Constants.RegistryRunKey, false);
            return key?.GetValue(Constants.RegistryAppName) != null;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// Sets whether the app should launch at Windows startup.
    /// </summary>
    public void SetLaunchAtStartup(bool enabled)
    {
        Settings.LaunchAtStartup = enabled;
        SyncLaunchAtStartup();
        SaveSettings();
    }

    // MARK: - Private Methods

    private void EnsureAppDataDirectoryExists()
    {
        if (!Directory.Exists(_appDataPath))
        {
            Directory.CreateDirectory(_appDataPath);
        }
    }

    private T? LoadFromFile<T>(string path) where T : class
    {
        try
        {
            if (!File.Exists(path)) return null;
            var json = File.ReadAllText(path);
            return JsonConvert.DeserializeObject<T>(json, _jsonSettings);
        }
        catch (IOException)
        {
            // Transient read failure - not corruption.
            return null;
        }
        catch
        {
            // Keep the corrupt file as evidence instead of silently letting
            // the next save overwrite it with defaults.
            try { File.Copy(path, path + ".bak", overwrite: true); } catch { }
            return null;
        }
    }

    private void SaveToFile<T>(string path, T data)
    {
        try
        {
            var json = JsonConvert.SerializeObject(data, _jsonSettings);
            // Write-then-rename keeps a crash mid-write from truncating the file.
            var tempPath = path + ".tmp";
            File.WriteAllText(tempPath, json);
            File.Move(tempPath, path, overwrite: true);
        }
        catch
        {
            // Silently fail - could add logging here
        }
    }

    private void SyncLaunchAtStartup()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(Constants.RegistryRunKey, true);
            if (key == null) return;

            if (Settings.LaunchAtStartup)
            {
                var exePath = Environment.ProcessPath;
                if (!string.IsNullOrEmpty(exePath))
                {
                    key.SetValue(Constants.RegistryAppName, $"\"{exePath}\"");
                }
            }
            else
            {
                key.DeleteValue(Constants.RegistryAppName, false);
            }
        }
        catch
        {
            // Silently fail if registry access is denied
        }
    }
}
