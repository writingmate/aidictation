using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Input;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using AIDictation.Models;
using AIDictation.Services;
using NAudio.Wave;

namespace AIDictation.ViewModels;

/// <summary>
/// ViewModel for the Settings window that manages audio, text rules, and hotkey configuration.
/// </summary>
public partial class SettingsViewModel : ObservableObject
{
    // MARK: - Constants

    private static class Constants
    {
        public const Key DefaultDictationHotkey = Key.F8;
        public const Key DefaultCommandHotkey = Key.F9;
        public const ModifierKeys DefaultDictationModifiers = ModifierKeys.None;
        public const ModifierKeys DefaultCommandModifiers = ModifierKeys.Control;
        public const TranscriptionModel CurrentTranscriptionModel = TranscriptionModel.AIDictationCloud;
    }

    // MARK: - Published Properties

    [ObservableProperty]
    private int _selectedSection;

    // Audio
    [ObservableProperty]
    private ObservableCollection<AudioDeviceItem> _audioDevices = new();

    [ObservableProperty]
    private AudioDeviceItem? _selectedAudioDevice;

    [ObservableProperty]
    private Language _selectedLanguage = Language.Auto;

    public ObservableCollection<LanguageItem> Languages { get; } = new();

    // Transcription
    [ObservableProperty]
    private bool _isOfflineMode;

    [ObservableProperty]
    private bool _isDownloadingModel;

    [ObservableProperty]
    private double _modelDownloadProgress;

    [ObservableProperty]
    private bool _enableLLMPostProcessing = true;

    [ObservableProperty]
    private bool _launchAtStartup;

    // Account
    [ObservableProperty]
    private bool _isAuthenticated;

    [ObservableProperty]
    private string _accountEmail = string.Empty;

    [ObservableProperty]
    private string _subscriptionLabel = string.Empty;

    [ObservableProperty]
    private string _usageText = string.Empty;

    [ObservableProperty]
    private string? _authErrorMessage;

    public bool CanUpgrade => IsAuthenticated &&
        AuthService.Instance.CurrentUser?.SubscriptionTier == SubscriptionTier.Free &&
        !string.IsNullOrEmpty(Helpers.BuildConfig.StripePaymentLink);

    // Text Rules
    public ObservableCollection<DictionaryEntryItem> DictionaryEntries { get; } = new();
    public ObservableCollection<ShortcutItem> Shortcuts { get; } = new();
    public ObservableCollection<ContextRuleItem> ContextRules { get; } = new();

    [ObservableProperty]
    private string _newDictionaryTrigger = string.Empty;

    [ObservableProperty]
    private string _newDictionaryReplacement = string.Empty;

    [ObservableProperty]
    private string _newShortcutTrigger = string.Empty;

    [ObservableProperty]
    private string _newShortcutExpansion = string.Empty;

    [ObservableProperty]
    private string _newContextRuleName = string.Empty;

    [ObservableProperty]
    private string _newContextRuleInstructions = string.Empty;

    // Hotkeys
    [ObservableProperty]
    private Key _dictationHotkey = Constants.DefaultDictationHotkey;

    [ObservableProperty]
    private ModifierKeys _dictationModifiers = Constants.DefaultDictationModifiers;

    [ObservableProperty]
    private Key _commandHotkey = Constants.DefaultCommandHotkey;

    [ObservableProperty]
    private ModifierKeys _commandModifiers = Constants.DefaultCommandModifiers;

    [ObservableProperty]
    private bool _isRecordingDictationHotkey;

    [ObservableProperty]
    private bool _isRecordingCommandHotkey;

    public string DictationHotkeyText => FormatHotkey(DictationModifiers, DictationHotkey);
    public string CommandHotkeyText => FormatHotkey(CommandModifiers, CommandHotkey);

    // Overlay
    public ObservableCollection<OverlayPositionItem> OverlayPositions { get; } = new();
    public ObservableCollection<OverlayColorThemeItem> OverlayColorThemes { get; } = new();

    [ObservableProperty]
    private bool _showOverlayWhenIdle = true;

    [ObservableProperty]
    private OverlayPositionItem? _selectedOverlayPosition;

    [ObservableProperty]
    private OverlayColorThemeItem? _selectedOverlayColorTheme;

    // MARK: - Events

    public event EventHandler? CloseRequested;
    public event EventHandler? HotkeyChanged;

    // MARK: - Initialization

    public SettingsViewModel()
    {
        LoadAudioDevices();
        LoadLanguages();
        LoadOverlayOptions();
        LoadSettings();
        LoadTextRules();
        LoadAccountState();

        AuthService.Instance.AuthStateChanged += OnAuthStateChanged;
        WhisperLocalService.Instance.ModelDownloadProgress += OnModelDownloadProgress;
    }

    // MARK: - Commands

    [RelayCommand]
    private void SelectSection(int section)
    {
        SelectedSection = section;
    }

    [RelayCommand]
    private void SelectLanguage(LanguageItem? item)
    {
        if (item == null) return;
        if (!item.IsSelectable) return;

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

        SelectedLanguage = Languages.FirstOrDefault(l => l.IsSelected)?.Language ?? Language.Auto;
        SaveLanguageSelection();
    }

    [RelayCommand]
    private void SignIn()
    {
        AuthService.Instance.OpenLogin();
    }

    [RelayCommand]
    private async Task SignOutAsync()
    {
        await AuthService.Instance.SignOutAsync();
    }

    [RelayCommand]
    private void Upgrade()
    {
        AuthService.Instance.OpenUpgrade();
    }

    [RelayCommand]
    private void AddDictionaryEntry()
    {
        if (string.IsNullOrWhiteSpace(NewDictionaryTrigger)) return;

        var entry = new DictionaryEntry
        {
            Trigger = NewDictionaryTrigger.Trim(),
            Replacement = string.IsNullOrWhiteSpace(NewDictionaryReplacement) ? null : NewDictionaryReplacement.Trim(),
            IsEnabled = true
        };

        SettingsService.Instance.AddDictionaryEntry(entry);
        DictionaryEntries.Add(new DictionaryEntryItem(entry));

        NewDictionaryTrigger = string.Empty;
        NewDictionaryReplacement = string.Empty;
    }

    [RelayCommand]
    private void RemoveDictionaryEntry(DictionaryEntryItem? item)
    {
        if (item == null) return;

        SettingsService.Instance.RemoveDictionaryEntry(item.Id);
        DictionaryEntries.Remove(item);
    }

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

    [RelayCommand]
    private void AddContextRule()
    {
        if (string.IsNullOrWhiteSpace(NewContextRuleName)) return;

        var rule = new ContextRule
        {
            Name = NewContextRuleName.Trim(),
            Instructions = NewContextRuleInstructions.Trim(),
            IsEnabled = true
        };

        SettingsService.Instance.AddContextRule(rule);
        ContextRules.Add(new ContextRuleItem(rule));

        NewContextRuleName = string.Empty;
        NewContextRuleInstructions = string.Empty;
    }

    [RelayCommand]
    private void RemoveContextRule(ContextRuleItem? item)
    {
        if (item == null) return;

        SettingsService.Instance.RemoveContextRule(item.Id);
        ContextRules.Remove(item);
    }

    [RelayCommand]
    private void StartRecordingDictationHotkey()
    {
        IsRecordingDictationHotkey = true;
        IsRecordingCommandHotkey = false;
    }

    [RelayCommand]
    private void StartRecordingCommandHotkey()
    {
        IsRecordingCommandHotkey = true;
        IsRecordingDictationHotkey = false;
    }

    [RelayCommand]
    private void ClearDictationHotkey()
    {
        DictationHotkey = Constants.DefaultDictationHotkey;
        DictationModifiers = Constants.DefaultDictationModifiers;
        OnPropertyChanged(nameof(DictationHotkeyText));
        SaveHotkeys();
    }

    [RelayCommand]
    private void ClearCommandHotkey()
    {
        CommandHotkey = Constants.DefaultCommandHotkey;
        CommandModifiers = Constants.DefaultCommandModifiers;
        OnPropertyChanged(nameof(CommandHotkeyText));
        SaveHotkeys();
    }

    [RelayCommand]
    private void Close()
    {
        CloseRequested?.Invoke(this, EventArgs.Empty);
    }

    // MARK: - Public API

    public void RecordHotkey(Key key, ModifierKeys modifiers)
    {
        // Ignore modifier-only presses
        if (key == Key.LeftCtrl || key == Key.RightCtrl ||
            key == Key.LeftShift || key == Key.RightShift ||
            key == Key.LeftAlt || key == Key.RightAlt ||
            key == Key.LWin || key == Key.RWin ||
            key == Key.System)
        {
            return;
        }

        if (IsRecordingDictationHotkey)
        {
            DictationHotkey = key;
            DictationModifiers = modifiers;
            IsRecordingDictationHotkey = false;
            OnPropertyChanged(nameof(DictationHotkeyText));
            SaveHotkeys();
        }
        else if (IsRecordingCommandHotkey)
        {
            CommandHotkey = key;
            CommandModifiers = modifiers;
            IsRecordingCommandHotkey = false;
            OnPropertyChanged(nameof(CommandHotkeyText));
            SaveHotkeys();
        }
    }

    public void CancelHotkeyRecording()
    {
        IsRecordingDictationHotkey = false;
        IsRecordingCommandHotkey = false;
    }

    /// <summary>
    /// Detaches singleton event subscriptions; call when the owning window closes.
    /// </summary>
    public void Cleanup()
    {
        AuthService.Instance.AuthStateChanged -= OnAuthStateChanged;
        WhisperLocalService.Instance.ModelDownloadProgress -= OnModelDownloadProgress;
    }

    // MARK: - Private Methods

    partial void OnIsOfflineModeChanged(bool value)
    {
        var settings = SettingsService.Instance;
        settings.Settings.TranscriptionProvider = value
            ? AppSettings.LocalTranscriptionProvider
            : AppSettings.CloudTranscriptionProvider;
        settings.SaveSettings();

        if (value && !WhisperLocalService.Instance.IsModelDownloaded)
        {
            _ = DownloadWhisperModelAsync();
        }
    }

    partial void OnEnableLLMPostProcessingChanged(bool value)
    {
        var settings = SettingsService.Instance;
        settings.Settings.EnableLLMPostProcessing = value;
        settings.SaveSettings();
    }

    partial void OnLaunchAtStartupChanged(bool value)
    {
        SettingsService.Instance.SetLaunchAtStartup(value);
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
            // Download failed - fall back to cloud so dictation keeps working.
            IsOfflineMode = false;
        }
        finally
        {
            IsDownloadingModel = false;
        }
    }

    private void OnModelDownloadProgress(object? sender, double progress)
    {
        Application.Current?.Dispatcher.Invoke(() =>
        {
            ModelDownloadProgress = progress * 100;
        });
    }

    private void OnAuthStateChanged(object? sender, EventArgs e)
    {
        Application.Current?.Dispatcher.Invoke(LoadAccountState);
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
            SubscriptionLabel = user.SubscriptionTier.GetDisplayName();
            UsageText = user.SubscriptionTier == SubscriptionTier.Pro
                ? $"{user.MonthlyWordCount:N0} words this month"
                : $"{user.MonthlyWordCount:N0} of {SubscriptionTierExtensions.FreeMonthlyWordLimit:N0} words used this month";
        }
        else
        {
            AccountEmail = string.Empty;
            SubscriptionLabel = string.Empty;
            UsageText = string.Empty;
        }

        OnPropertyChanged(nameof(CanUpgrade));
    }

    partial void OnSelectedAudioDeviceChanged(AudioDeviceItem? value)
    {
        if (value != null)
        {
            var settings = SettingsService.Instance;
            settings.Settings.SelectedAudioDeviceId = value.DeviceId;
            settings.SaveSettings();
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

    partial void OnSelectedOverlayColorThemeChanged(OverlayColorThemeItem? value)
    {
        if (value == null) return;

        var settings = SettingsService.Instance;
        settings.Settings.OverlayColorTheme = value.ColorTheme;
        settings.SaveSettings();
        OverlayService.Shared.ApplySettings(settings.Settings);
    }

    private void LoadAudioDevices()
    {
        AudioDevices.Clear();

        // Add default device
        AudioDevices.Add(new AudioDeviceItem
        {
            DeviceId = null,
            DisplayName = "Default Input Device"
        });

        try
        {
            for (int i = 0; i < WaveIn.DeviceCount; i++)
            {
                var capabilities = WaveIn.GetCapabilities(i);
                AudioDevices.Add(new AudioDeviceItem
                {
                    DeviceId = i.ToString(),
                    DisplayName = capabilities.ProductName
                });
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
                IsSelectable = language.SupportsModel(Constants.CurrentTranscriptionModel),
                SupportText = GetLanguageSupportText(language),
                IsSelected = language == Language.Auto
            });
        }
    }

    private void LoadOverlayOptions()
    {
        OverlayPositions.Clear();
        OverlayPositions.Add(new OverlayPositionItem(OverlayPosition.Bottom, "Bottom"));
        OverlayPositions.Add(new OverlayPositionItem(OverlayPosition.Top, "Top"));

        OverlayColorThemes.Clear();
        OverlayColorThemes.Add(new OverlayColorThemeItem(OverlayColorTheme.Orange, "Orange"));
        OverlayColorThemes.Add(new OverlayColorThemeItem(OverlayColorTheme.Blue, "Blue"));
        OverlayColorThemes.Add(new OverlayColorThemeItem(OverlayColorTheme.Green, "Green"));
        OverlayColorThemes.Add(new OverlayColorThemeItem(OverlayColorTheme.Purple, "Purple"));
        OverlayColorThemes.Add(new OverlayColorThemeItem(OverlayColorTheme.Pink, "Pink"));
        OverlayColorThemes.Add(new OverlayColorThemeItem(OverlayColorTheme.Graphite, "Graphite"));
    }

    private void LoadSettings()
    {
        var settings = SettingsService.Instance;
        settings.Load();

        IsOfflineMode = settings.Settings.TranscriptionProvider == AppSettings.LocalTranscriptionProvider;
        EnableLLMPostProcessing = settings.Settings.EnableLLMPostProcessing;
        LaunchAtStartup = settings.GetLaunchAtStartup();

        // Load selected audio device
        var deviceId = settings.Settings.SelectedAudioDeviceId;
        if (deviceId != null)
        {
            foreach (var device in AudioDevices)
            {
                if (device.DeviceId == deviceId)
                {
                    SelectedAudioDevice = device;
                    break;
                }
            }
        }
        else
        {
            SelectedAudioDevice = AudioDevices.Count > 0 ? AudioDevices[0] : null;
        }

        // Load selected languages (multi-select)
        if (settings.Settings.SelectedLanguages.Count > 0)
        {
            var selected = settings.Settings.SelectedLanguages
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
                SelectedLanguage = Languages.FirstOrDefault(l => l.IsSelected)?.Language ?? Language.Auto;
            }
        }

        // Load hotkeys
        if (settings.Settings.Hotkey != null)
        {
            DictationHotkey = settings.Settings.Hotkey.Key;
            DictationModifiers = settings.Settings.Hotkey.Modifiers;
        }

        if (settings.Settings.CommandHotkey != null)
        {
            CommandHotkey = settings.Settings.CommandHotkey.Key;
            CommandModifiers = settings.Settings.CommandHotkey.Modifiers;
        }

        ShowOverlayWhenIdle = !settings.Settings.HideIdleOverlay;
        SelectedOverlayPosition = FindOverlayPosition(settings.Settings.OverlayPosition);
        SelectedOverlayColorTheme = FindOverlayColorTheme(settings.Settings.OverlayColorTheme);
        OverlayService.Shared.ApplySettings(settings.Settings);

        OnPropertyChanged(nameof(DictationHotkeyText));
        OnPropertyChanged(nameof(CommandHotkeyText));
    }

    private void LoadTextRules()
    {
        var settings = SettingsService.Instance;

        DictionaryEntries.Clear();
        foreach (var entry in settings.DictionaryEntries)
        {
            DictionaryEntries.Add(new DictionaryEntryItem(entry));
        }

        Shortcuts.Clear();
        foreach (var shortcut in settings.Shortcuts)
        {
            Shortcuts.Add(new ShortcutItem(shortcut));
        }

        ContextRules.Clear();
        foreach (var rule in settings.ContextRules)
        {
            ContextRules.Add(new ContextRuleItem(rule));
        }
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

    private static string GetLanguageSupportText(Language language)
    {
        if (language.SupportsModel(Constants.CurrentTranscriptionModel))
        {
            return "Available in cloud mode";
        }

        return language.SupportsModel(TranscriptionModel.Parakeet)
            ? "Available in offline mode"
            : "Not available for this mode";
    }

    private void SaveHotkeys()
    {
        var settings = SettingsService.Instance;
        settings.Settings.Hotkey = new Hotkey(DictationHotkey, DictationModifiers);
        settings.Settings.CommandHotkey = new Hotkey(CommandHotkey, CommandModifiers);
        settings.SaveSettings();
        HotkeyChanged?.Invoke(this, EventArgs.Empty);
    }

    private static string FormatHotkey(ModifierKeys modifiers, Key key)
    {
        var parts = new List<string>();

        if (modifiers.HasFlag(ModifierKeys.Control))
            parts.Add("Ctrl");
        if (modifiers.HasFlag(ModifierKeys.Alt))
            parts.Add("Alt");
        if (modifiers.HasFlag(ModifierKeys.Shift))
            parts.Add("Shift");
        if (modifiers.HasFlag(ModifierKeys.Windows))
            parts.Add("Win");

        parts.Add(FormatKey(key));

        return string.Join(" + ", parts);
    }

    private static string FormatKey(Key key)
    {
        return key switch
        {
            Key.OemPlus => "+",
            Key.OemMinus => "-",
            Key.OemQuestion => "?",
            Key.OemPeriod => ".",
            Key.OemComma => ",",
            Key.OemTilde => "~",
            Key.OemOpenBrackets => "[",
            Key.OemCloseBrackets => "]",
            Key.OemPipe => "|",
            Key.OemSemicolon => ";",
            Key.OemQuotes => "'",
            _ => key.ToString()
        };
    }

    private OverlayPositionItem? FindOverlayPosition(OverlayPosition position)
    {
        foreach (var item in OverlayPositions)
        {
            if (item.Position == position) return item;
        }

        return OverlayPositions.Count > 0 ? OverlayPositions[0] : null;
    }

    private OverlayColorThemeItem? FindOverlayColorTheme(OverlayColorTheme colorTheme)
    {
        foreach (var item in OverlayColorThemes)
        {
            if (item.ColorTheme == colorTheme) return item;
        }

        return OverlayColorThemes.Count > 0 ? OverlayColorThemes[0] : null;
    }
}

// MARK: - Supporting Types

public class AudioDeviceItem
{
    public string? DeviceId { get; set; }
    public string DisplayName { get; set; } = string.Empty;
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

public class OverlayColorThemeItem
{
    public OverlayColorTheme ColorTheme { get; }
    public string DisplayName { get; }

    public OverlayColorThemeItem(OverlayColorTheme colorTheme, string displayName)
    {
        ColorTheme = colorTheme;
        DisplayName = displayName;
    }
}

public partial class DictionaryEntryItem : ObservableObject
{
    public string Id { get; }
    public string Trigger { get; }
    public string? Replacement { get; }

    [ObservableProperty]
    private bool _isEnabled;

    public DictionaryEntryItem(DictionaryEntry entry)
    {
        Id = entry.Id;
        Trigger = entry.Trigger;
        Replacement = entry.Replacement;
        IsEnabled = entry.IsEnabled;
    }

    partial void OnIsEnabledChanged(bool value)
    {
        var entries = SettingsService.Instance.DictionaryEntries;
        var entry = entries.Find(e => e.Id == Id);
        if (entry != null)
        {
            entry.IsEnabled = value;
            SettingsService.Instance.SaveDictionary();
        }
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

public partial class ContextRuleItem : ObservableObject
{
    public string Id { get; }
    public string Name { get; }
    public string Instructions { get; }

    [ObservableProperty]
    private bool _isEnabled;

    public ContextRuleItem(ContextRule rule)
    {
        Id = rule.Id;
        Name = rule.Name;
        Instructions = rule.Instructions;
        IsEnabled = rule.IsEnabled;
    }

    partial void OnIsEnabledChanged(bool value)
    {
        var rules = SettingsService.Instance.ContextRules;
        var rule = rules.Find(r => r.Id == Id);
        if (rule != null)
        {
            rule.IsEnabled = value;
            SettingsService.Instance.SaveContextRules();
        }
    }
}
