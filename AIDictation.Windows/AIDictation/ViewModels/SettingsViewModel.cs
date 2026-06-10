using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using AIDictation.Helpers;
using AIDictation.Models;
using AIDictation.Services;
using NAudio.Wave;

namespace AIDictation.ViewModels;

/// <summary>
/// ViewModel for the Settings window. Sections mirror the shipped design spec:
/// Account, Audio, Language, Dictionary, Shortcuts, Configuration, History.
/// </summary>
public partial class SettingsViewModel : ObservableObject
{
    // MARK: - Constants

    public static class Sections
    {
        public const int Account = 0;
        public const int Audio = 1;
        public const int Language = 2;
        public const int Dictionary = 3;
        public const int Shortcuts = 4;
        public const int Configuration = 5;
        public const int History = 6;
    }

    private static class Constants
    {
        public const Key DefaultDictationHotkey = Key.F8;
        public const ModifierKeys DefaultDictationModifiers = ModifierKeys.None;
    }

    // MARK: - Published Properties

    [ObservableProperty]
    private int _selectedSection = Sections.Account;

    // Account
    [ObservableProperty]
    private bool _isAuthenticated;

    [ObservableProperty]
    private string _accountEmail = string.Empty;

    [ObservableProperty]
    private string _accountInitial = "A";

    [ObservableProperty]
    private string _subscriptionLabel = string.Empty;

    [ObservableProperty]
    private string _memberSinceText = string.Empty;

    [ObservableProperty]
    private string _usageText = string.Empty;

    [ObservableProperty]
    private string _usageResetText = string.Empty;

    [ObservableProperty]
    private double _usagePercent;

    [ObservableProperty]
    private string? _authErrorMessage;

    public bool CanUpgrade => IsAuthenticated &&
        AuthService.Instance.CurrentUser?.SubscriptionTier == SubscriptionTier.Free &&
        !string.IsNullOrEmpty(BuildConfig.StripePaymentLink);

    // Audio
    [ObservableProperty]
    private ObservableCollection<AudioDeviceItem> _audioDevices = new();

    [ObservableProperty]
    private AudioDeviceItem? _selectedAudioDevice;

    [ObservableProperty]
    private bool _muteAudioWhenRecording = true;

    [ObservableProperty]
    private bool _enableLLMPostProcessing = true;

    // Language
    public ObservableCollection<LanguageItem> Languages { get; } = new();

    // Dictionary (plain word list)
    public ObservableCollection<DictionaryWordItem> Words { get; } = new();

    [ObservableProperty]
    private string _newWord = string.Empty;

    // Shortcuts
    public ObservableCollection<ShortcutItem> Shortcuts { get; } = new();

    [ObservableProperty]
    private string _newShortcutTrigger = string.Empty;

    [ObservableProperty]
    private string _newShortcutExpansion = string.Empty;

    // Configuration
    [ObservableProperty]
    private Key _dictationHotkey = Constants.DefaultDictationHotkey;

    [ObservableProperty]
    private ModifierKeys _dictationModifiers = Constants.DefaultDictationModifiers;

    [ObservableProperty]
    private bool _isRecordingDictationHotkey;

    public string DictationHotkeyText => FormatHotkey(DictationModifiers, DictationHotkey);

    [ObservableProperty]
    private bool _pushToTalk = true;

    public ObservableCollection<ModeItem> TranscriptionModes { get; } = new();

    [ObservableProperty]
    private ModeItem? _selectedTranscriptionMode;

    [ObservableProperty]
    private bool _showOverlayWhenIdle = true;

    public ObservableCollection<SwatchItem> OverlaySwatches { get; } = new();

    public ObservableCollection<OverlayPositionItem> OverlayPositions { get; } = new();

    [ObservableProperty]
    private OverlayPositionItem? _selectedOverlayPosition;

    [ObservableProperty]
    private bool _launchAtStartup;

    [ObservableProperty]
    private bool _isDownloadingModel;

    [ObservableProperty]
    private double _modelDownloadProgress;

    public string VersionText => $"v{System.Reflection.Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "0.0.1"} · win-x64";

    // History
    public ObservableCollection<HistoryRowItem> HistoryRows { get; } = new();

    [ObservableProperty]
    private string _historySearchQuery = string.Empty;

    [ObservableProperty]
    private string _historyStatsText = string.Empty;

    // MARK: - Events

    public event EventHandler? CloseRequested;
    public event EventHandler? HotkeyChanged;

    // MARK: - Initialization

    public SettingsViewModel()
    {
        LoadAudioDevices();
        LoadLanguages();
        LoadModes();
        LoadOverlayOptions();
        LoadSettings();
        LoadWords();
        LoadShortcuts();
        LoadAccountState();
        RebuildHistory();

        AuthService.Instance.AuthStateChanged += OnAuthStateChanged;
        WhisperLocalService.Instance.ModelDownloadProgress += OnModelDownloadProgress;
        HistoryService.Instance.HistoryChanged += OnHistoryChanged;
    }

    // MARK: - Commands: navigation

    [RelayCommand]
    private void SelectSection(string? section)
    {
        if (int.TryParse(section, out var index))
        {
            SelectedSection = index;
        }
    }

    [RelayCommand]
    private void Close() => CloseRequested?.Invoke(this, EventArgs.Empty);

    // MARK: - Commands: account

    [RelayCommand]
    private void SignIn() => AuthService.Instance.OpenLogin();

    [RelayCommand]
    private async Task SignOutAsync() => await AuthService.Instance.SignOutAsync();

    [RelayCommand]
    private void Upgrade() => AuthService.Instance.OpenUpgrade();

    [RelayCommand]
    private void CopyInviteLink()
    {
        var userId = AuthService.Instance.CurrentUser?.UserId;
        var link = userId != null
            ? $"{BuildConfig.AuthWebUrl}?ref={userId}"
            : BuildConfig.AuthWebUrl;
        TrySetClipboard(link);
    }

    // MARK: - Commands: language

    [RelayCommand]
    private void SelectLanguage(LanguageItem? item)
    {
        if (item == null || !item.IsSelectable) return;

        // Multi-select like macOS: "Auto" is exclusive with explicit languages.
        if (item.Language == Language.Auto)
        {
            foreach (var lang in Languages)
            {
                lang.IsSelected = lang.Language == Language.Auto;
            }
        }
        else
        {
            item.IsSelected = !item.IsSelected;
            var autoItem = Languages.FirstOrDefault(l => l.Language == Language.Auto);
            var anyExplicit = Languages.Any(l => l.Language != Language.Auto && l.IsSelected);
            if (autoItem != null)
            {
                autoItem.IsSelected = !anyExplicit;
            }
        }

        SaveLanguageSelection();
    }

    // MARK: - Commands: dictionary

    [RelayCommand]
    private void AddWord()
    {
        var word = NewWord.Trim();
        if (string.IsNullOrEmpty(word)) return;

        var entry = new DictionaryEntry { Trigger = word, Replacement = null, IsEnabled = true };
        SettingsService.Instance.AddDictionaryEntry(entry);
        Words.Add(new DictionaryWordItem(entry.Id, word));
        NewWord = string.Empty;
    }

    [RelayCommand]
    private void RemoveWord(DictionaryWordItem? item)
    {
        if (item == null) return;
        SettingsService.Instance.RemoveDictionaryEntry(item.Id);
        Words.Remove(item);
    }

    // MARK: - Commands: shortcuts

    [RelayCommand]
    private void AddShortcut()
    {
        if (string.IsNullOrWhiteSpace(NewShortcutTrigger) || string.IsNullOrWhiteSpace(NewShortcutExpansion)) return;

        var shortcut = new Shortcut
        {
            VoiceTrigger = NewShortcutTrigger.Trim(),
            Expansion = NewShortcutExpansion.Trim(),
            IsEnabled = true
        };
        SettingsService.Instance.AddShortcut(shortcut);
        Shortcuts.Add(new ShortcutItem(shortcut));
        NewShortcutTrigger = string.Empty;
        NewShortcutExpansion = string.Empty;
    }

    [RelayCommand]
    private void RemoveShortcut(ShortcutItem? item)
    {
        if (item == null) return;
        SettingsService.Instance.RemoveShortcut(item.Id);
        Shortcuts.Remove(item);
    }

    // MARK: - Commands: configuration

    [RelayCommand]
    private void StartRecordingDictationHotkey()
    {
        IsRecordingDictationHotkey = true;
    }

    [RelayCommand]
    private void SelectSwatch(SwatchItem? item)
    {
        if (item == null) return;
        foreach (var sw in OverlaySwatches) sw.IsSelected = sw.Theme == item.Theme;

        var settings = SettingsService.Instance;
        settings.Settings.OverlayColorTheme = item.Theme;
        settings.SaveSettings();
        OverlayService.Shared.ApplySettings(settings.Settings);
    }

    [RelayCommand]
    private void CheckForUpdates()
    {
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = "https://github.com/writingmate/aidictation/releases",
                UseShellExecute = true
            });
        }
        catch { }
    }

    // MARK: - Commands: history

    [RelayCommand]
    private void CopyHistoryText(HistoryRowItem? row)
    {
        if (row?.Text == null) return;
        TrySetClipboard(row.Text);
    }

    [RelayCommand]
    private void DeleteHistoryRow(HistoryRowItem? row)
    {
        if (row == null) return;
        HistoryService.Instance.Delete(row.Id);
    }

    [RelayCommand]
    private async Task RetranscribeCloudAsync(HistoryRowItem? row) =>
        await RetranscribeAsync(row, AppSettings.CloudTranscriptionProvider);

    [RelayCommand]
    private async Task RetranscribeLocalAsync(HistoryRowItem? row) =>
        await RetranscribeAsync(row, AppSettings.LocalTranscriptionProvider);

    [RelayCommand]
    private void ClearHistory()
    {
        var confirm = MessageBox.Show(
            "Delete all recordings and transcriptions?", "Clear History",
            MessageBoxButton.YesNo, MessageBoxImage.Warning);
        if (confirm == MessageBoxResult.Yes)
        {
            HistoryService.Instance.Clear();
        }
    }

    [RelayCommand]
    private void ExportHistory()
    {
        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            FileName = "AIDictation-history.txt",
            Filter = "Text files (*.txt)|*.txt"
        };
        if (dialog.ShowDialog() == true)
        {
            var lines = HistoryService.Instance.GetAll()
                .Where(r => !string.IsNullOrWhiteSpace(r.Transcription))
                .Select(r => $"[{r.Timestamp:g}] {r.Transcription}");
            System.IO.File.WriteAllLines(dialog.FileName, lines);
        }
    }

    private async Task RetranscribeAsync(HistoryRowItem? row, string provider)
    {
        if (row == null) return;
        var recording = HistoryService.Instance.Get(row.Id);
        if (recording == null || string.IsNullOrEmpty(recording.AudioFilePath) ||
            !System.IO.File.Exists(recording.AudioFilePath))
        {
            return;
        }

        row.IsBusy = true;
        try
        {
            var result = await TranscriptionService.Instance.TranscribeAsync(
                recording.AudioFilePath, default, provider);

            if (result.IsSuccess && !string.IsNullOrWhiteSpace(result.Text))
            {
                recording.Transcription = result.Text;
                recording.Status = TranscriptionStatus.Success;
                recording.ErrorMessage = null;
                recording.WordCount = result.Text.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length;
                HistoryService.Instance.Update(recording);
                TrySetClipboard(result.Text);
            }
        }
        finally
        {
            row.IsBusy = false;
        }
    }

    // MARK: - Public API

    public void NavigateTo(int section) => SelectedSection = section;

    public void RecordHotkey(Key key, ModifierKeys modifiers)
    {
        if (!IsRecordingDictationHotkey) return;
        if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftShift or Key.RightShift
            or Key.LeftAlt or Key.RightAlt or Key.LWin or Key.RWin or Key.System)
        {
            return;
        }

        DictationHotkey = key;
        DictationModifiers = modifiers;
        IsRecordingDictationHotkey = false;
        OnPropertyChanged(nameof(DictationHotkeyText));
        SaveHotkeys();
    }

    public void CancelHotkeyRecording() => IsRecordingDictationHotkey = false;

    /// <summary>Detaches singleton event subscriptions; call when the owning window closes.</summary>
    public void Cleanup()
    {
        AuthService.Instance.AuthStateChanged -= OnAuthStateChanged;
        WhisperLocalService.Instance.ModelDownloadProgress -= OnModelDownloadProgress;
        HistoryService.Instance.HistoryChanged -= OnHistoryChanged;
    }

    // MARK: - Property change handlers

    partial void OnSelectedAudioDeviceChanged(AudioDeviceItem? value)
    {
        if (value == null) return;
        var settings = SettingsService.Instance;
        settings.Settings.SelectedAudioDeviceId = value.DeviceId;
        settings.SaveSettings();
    }

    partial void OnMuteAudioWhenRecordingChanged(bool value)
    {
        var settings = SettingsService.Instance;
        settings.Settings.MuteAudioWhenRecording = value;
        settings.SaveSettings();
    }

    partial void OnEnableLLMPostProcessingChanged(bool value)
    {
        var settings = SettingsService.Instance;
        settings.Settings.EnableLLMPostProcessing = value;
        settings.SaveSettings();
    }

    partial void OnPushToTalkChanged(bool value)
    {
        var settings = SettingsService.Instance;
        settings.Settings.PushToTalk = value;
        settings.SaveSettings();
    }

    partial void OnSelectedTranscriptionModeChanged(ModeItem? value)
    {
        if (value == null) return;
        var settings = SettingsService.Instance;
        settings.Settings.TranscriptionProvider = value.Key;
        settings.SaveSettings();

        if (value.Key != AppSettings.CloudTranscriptionProvider &&
            !WhisperLocalService.Instance.IsModelDownloaded)
        {
            _ = DownloadWhisperModelAsync();
        }
    }

    partial void OnShowOverlayWhenIdleChanged(bool value)
    {
        var settings = SettingsService.Instance;
        settings.Settings.HideIdleOverlay = !value;
        settings.SaveSettings();
        OverlayService.Shared.ApplySettings(settings.Settings);
    }

    partial void OnSelectedOverlayPositionChanged(OverlayPositionItem? value)
    {
        if (value == null) return;
        var settings = SettingsService.Instance;
        settings.Settings.OverlayPosition = value.Position;
        settings.SaveSettings();
        OverlayService.Shared.ApplySettings(settings.Settings);
    }

    partial void OnLaunchAtStartupChanged(bool value)
    {
        SettingsService.Instance.SetLaunchAtStartup(value);
    }

    partial void OnHistorySearchQueryChanged(string value)
    {
        RebuildHistory();
    }

    // MARK: - Private Methods

    private void OnAuthStateChanged(object? sender, EventArgs e)
    {
        Application.Current?.Dispatcher.Invoke(LoadAccountState);
    }

    private void OnHistoryChanged(object? sender, EventArgs e)
    {
        Application.Current?.Dispatcher.Invoke(RebuildHistory);
    }

    private void OnModelDownloadProgress(object? sender, double progress)
    {
        Application.Current?.Dispatcher.Invoke(() => ModelDownloadProgress = progress * 100);
    }

    private async Task DownloadWhisperModelAsync()
    {
        IsDownloadingModel = true;
        ModelDownloadProgress = 0;
        try
        {
            await WhisperLocalService.Instance.EnsureModelAsync();
        }
        catch (Exception)
        {
            // Fall back to cloud so dictation keeps working.
            SelectedTranscriptionMode = TranscriptionModes.FirstOrDefault(m => m.Key == AppSettings.CloudTranscriptionProvider);
        }
        finally
        {
            IsDownloadingModel = false;
        }
    }

    private void LoadAccountState()
    {
        var auth = AuthService.Instance;
        IsAuthenticated = auth.IsAuthenticated;
        AuthErrorMessage = auth.ErrorMessage;

        var user = auth.CurrentUser;
        if (user != null)
        {
            AccountEmail = user.Email;
            AccountInitial = string.IsNullOrEmpty(user.Email) ? "A" : user.Email[..1].ToUpperInvariant();
            SubscriptionLabel = user.SubscriptionTier.GetDisplayName();
            MemberSinceText = user.CreatedAt != null ? $"Member since {user.CreatedAt:MMMM yyyy}" : string.Empty;

            var limit = user.SubscriptionTier.GetWordLimit();
            if (limit == int.MaxValue)
            {
                UsageText = $"{user.MonthlyWordCount:N0} words this month";
                UsagePercent = 0;
            }
            else
            {
                UsageText = $"{user.MonthlyWordCount:N0} / {limit:N0}";
                UsagePercent = Math.Clamp((double)user.MonthlyWordCount / limit, 0, 1);
            }

            UsageResetText = user.WordCountResetAt != null
                ? $"Resets {user.WordCountResetAt:MMMM d}"
                : "Monthly words";
        }
        else
        {
            AccountEmail = string.Empty;
            SubscriptionLabel = string.Empty;
            MemberSinceText = string.Empty;
            UsageText = string.Empty;
            UsageResetText = string.Empty;
            UsagePercent = 0;
        }

        OnPropertyChanged(nameof(CanUpgrade));
    }

    private void LoadAudioDevices()
    {
        AudioDevices.Clear();
        AudioDevices.Add(new AudioDeviceItem { DeviceId = null, DisplayName = "Default Input Device" });
        try
        {
            for (int i = 0; i < WaveIn.DeviceCount; i++)
            {
                var capabilities = WaveIn.GetCapabilities(i);
                AudioDevices.Add(new AudioDeviceItem { DeviceId = i.ToString(), DisplayName = capabilities.ProductName });
            }
        }
        catch
        {
            // Silently fail if audio devices can't be enumerated
        }
    }

    private void LoadLanguages()
    {
        Languages.Clear();
        foreach (var language in LanguageExtensions.GetAll())
        {
            Languages.Add(new LanguageItem
            {
                Language = language,
                DisplayName = language.GetDisplayName(),
                Flag = language.GetFlag(),
                IsSelectable = true,
                IsSelected = language == Language.Auto
            });
        }
    }

    private void LoadModes()
    {
        TranscriptionModes.Clear();
        TranscriptionModes.Add(new ModeItem(AppSettings.CloudTranscriptionProvider, "Cloud"));
        TranscriptionModes.Add(new ModeItem(AppSettings.LocalTranscriptionProvider, "On-device"));
        TranscriptionModes.Add(new ModeItem(AppSettings.AutoTranscriptionProvider, "Automatic"));
    }

    private void LoadOverlayOptions()
    {
        OverlayPositions.Clear();
        OverlayPositions.Add(new OverlayPositionItem(OverlayPosition.Bottom, "Bottom"));
        OverlayPositions.Add(new OverlayPositionItem(OverlayPosition.Top, "Top"));

        OverlaySwatches.Clear();
        OverlaySwatches.Add(new SwatchItem(OverlayColorTheme.Orange, "#F16E00"));
        OverlaySwatches.Add(new SwatchItem(OverlayColorTheme.Blue, "#3B82F6"));
        OverlaySwatches.Add(new SwatchItem(OverlayColorTheme.Green, "#3BC45A"));
        OverlaySwatches.Add(new SwatchItem(OverlayColorTheme.Purple, "#A855F7"));
        OverlaySwatches.Add(new SwatchItem(OverlayColorTheme.Pink, "#FF7EC7"));
        OverlaySwatches.Add(new SwatchItem(OverlayColorTheme.Graphite, "#6E6E6E"));
    }

    private void LoadSettings()
    {
        var settings = SettingsService.Instance;
        settings.Load();

        var s = settings.Settings;

        SelectedTranscriptionMode = TranscriptionModes.FirstOrDefault(m => m.Key == s.TranscriptionProvider)
                                    ?? TranscriptionModes[0];
        EnableLLMPostProcessing = s.EnableLLMPostProcessing;
        MuteAudioWhenRecording = s.MuteAudioWhenRecording;
        PushToTalk = s.PushToTalk;
        LaunchAtStartup = settings.GetLaunchAtStartup();

        var deviceId = s.SelectedAudioDeviceId;
        SelectedAudioDevice = deviceId != null
            ? AudioDevices.FirstOrDefault(d => d.DeviceId == deviceId) ?? AudioDevices.FirstOrDefault()
            : AudioDevices.FirstOrDefault();

        if (s.SelectedLanguages.Count > 0)
        {
            var selected = s.SelectedLanguages
                .Select(LanguageExtensions.FromCode)
                .Where(l => l.HasValue)
                .Select(l => l!.Value)
                .ToHashSet();
            if (selected.Count > 0)
            {
                foreach (var item in Languages)
                {
                    item.IsSelected = selected.Contains(item.Language);
                }
            }
        }

        if (s.Hotkey != null)
        {
            DictationHotkey = s.Hotkey.Key;
            DictationModifiers = s.Hotkey.Modifiers;
        }

        ShowOverlayWhenIdle = !s.HideIdleOverlay;
        SelectedOverlayPosition = OverlayPositions.FirstOrDefault(p => p.Position == s.OverlayPosition) ?? OverlayPositions[0];
        foreach (var sw in OverlaySwatches) sw.IsSelected = sw.Theme == s.OverlayColorTheme;

        OverlayService.Shared.ApplySettings(s);
        OnPropertyChanged(nameof(DictationHotkeyText));
    }

    private void LoadWords()
    {
        Words.Clear();
        foreach (var entry in SettingsService.Instance.DictionaryEntries)
        {
            Words.Add(new DictionaryWordItem(entry.Id, entry.Trigger));
        }
    }

    private void LoadShortcuts()
    {
        Shortcuts.Clear();
        foreach (var shortcut in SettingsService.Instance.Shortcuts)
        {
            Shortcuts.Add(new ShortcutItem(shortcut));
        }
    }

    private void RebuildHistory()
    {
        HistoryRows.Clear();

        var recordings = string.IsNullOrWhiteSpace(HistorySearchQuery)
            ? HistoryService.Instance.GetAll()
            : HistoryService.Instance.Search(HistorySearchQuery);

        string? lastGroup = null;
        foreach (var rec in recordings.OrderByDescending(r => r.Timestamp))
        {
            var group = FormatGroup(rec.Timestamp);
            var row = new HistoryRowItem(rec)
            {
                GroupLabel = group,
                ShowGroup = group != lastGroup
            };
            lastGroup = group;
            HistoryRows.Add(row);
        }

        var all = HistoryService.Instance.GetAll();
        var totalWords = all.Sum(r => r.WordCount ?? 0);
        HistoryStatsText = $"{all.Count} recordings · {totalWords:N0} words dictated";
    }

    private static string FormatGroup(DateTime timestamp)
    {
        var date = timestamp.Date;
        if (date == DateTime.Today) return "TODAY";
        if (date == DateTime.Today.AddDays(-1)) return "YESTERDAY";
        return timestamp.ToString("MMMM d").ToUpperInvariant();
    }

    private void SaveLanguageSelection()
    {
        var settings = SettingsService.Instance;
        var selectedCodes = Languages
            .Where(l => l.IsSelected)
            .Select(l => l.Language.GetCode())
            .ToList();
        settings.Settings.SelectedLanguages = selectedCodes.Count > 0
            ? selectedCodes
            : new List<string> { "auto" };
        settings.SaveSettings();
    }

    private void SaveHotkeys()
    {
        var settings = SettingsService.Instance;
        settings.Settings.Hotkey = new Hotkey(DictationHotkey, DictationModifiers);
        settings.SaveSettings();
        HotkeyChanged?.Invoke(this, EventArgs.Empty);
    }

    private static void TrySetClipboard(string text)
    {
        try { Clipboard.SetText(text); } catch { }
    }

    private static string FormatHotkey(ModifierKeys modifiers, Key key)
    {
        var parts = new List<string>();
        if (modifiers.HasFlag(ModifierKeys.Control)) parts.Add("Ctrl");
        if (modifiers.HasFlag(ModifierKeys.Alt)) parts.Add("Alt");
        if (modifiers.HasFlag(ModifierKeys.Shift)) parts.Add("Shift");
        if (modifiers.HasFlag(ModifierKeys.Windows)) parts.Add("Win");
        parts.Add(key.ToString());
        return string.Join(" + ", parts);
    }
}

// MARK: - Supporting Types

public class AudioDeviceItem
{
    public string? DeviceId { get; set; }
    public string DisplayName { get; set; } = string.Empty;
}

public class ModeItem
{
    public string Key { get; }
    public string Label { get; }

    public ModeItem(string key, string label)
    {
        Key = key;
        Label = label;
    }
}

public class OverlayPositionItem
{
    public OverlayPosition Position { get; }
    public string DisplayName { get; }

    public OverlayPositionItem(OverlayPosition position, string displayName)
    {
        Position = position;
        DisplayName = displayName;
    }
}

public partial class SwatchItem : ObservableObject
{
    public OverlayColorTheme Theme { get; }
    public Brush Brush { get; }

    [ObservableProperty]
    private bool _isSelected;

    public SwatchItem(OverlayColorTheme theme, string hex)
    {
        Theme = theme;
        Brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));
    }
}

public class DictionaryWordItem
{
    public string Id { get; }
    public string Word { get; }

    public DictionaryWordItem(string id, string word)
    {
        Id = id;
        Word = word;
    }
}

public partial class ShortcutItem : ObservableObject
{
    public string Id { get; }
    public string VoiceTrigger { get; }
    public string Expansion { get; }

    [ObservableProperty]
    private bool _isEnabled;

    public ShortcutItem(Shortcut shortcut)
    {
        Id = shortcut.Id;
        VoiceTrigger = shortcut.VoiceTrigger;
        Expansion = shortcut.Expansion;
        IsEnabled = shortcut.IsEnabled;
    }

    partial void OnIsEnabledChanged(bool value)
    {
        var shortcuts = SettingsService.Instance.Shortcuts;
        var shortcut = shortcuts.Find(s => s.Id == Id);
        if (shortcut != null)
        {
            shortcut.IsEnabled = value;
            SettingsService.Instance.SaveShortcuts();
        }
    }
}

public partial class HistoryRowItem : ObservableObject
{
    public Guid Id { get; }
    public string TimeText { get; }
    public string MetaText { get; }
    public string Text { get; }
    public bool IsFailed { get; }
    public string GroupLabel { get; set; } = string.Empty;
    public bool ShowGroup { get; set; }

    [ObservableProperty]
    private bool _isBusy;

    public HistoryRowItem(Recording recording)
    {
        Id = recording.Id;
        TimeText = recording.Timestamp.ToString("h:mm tt");
        IsFailed = recording.IsFailed;
        MetaText = IsFailed
            ? "failed"
            : $"{recording.FormattedDuration ?? "—"} · {recording.WordCount ?? 0} words";
        Text = IsFailed
            ? (recording.ErrorMessage ?? "Transcription failed — click to retry.")
            : (recording.Transcription ?? string.Empty);
    }
}
