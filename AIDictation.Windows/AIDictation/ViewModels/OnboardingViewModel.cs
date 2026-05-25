using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Windows.Input;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using AIDictation.Models;
using AIDictation.Services;

namespace AIDictation.ViewModels;

/// <summary>
/// ViewModel for the onboarding window that guides users through initial setup.
/// Handles microphone permissions, language selection, and hotkey configuration.
/// </summary>
public partial class OnboardingViewModel : ObservableObject
{
    // MARK: - Constants

    private static class Constants
    {
        public const int TotalSteps = 4;
        public const Key DefaultHotkey = Key.F8;
        public const ModifierKeys DefaultModifiers = ModifierKeys.None;
        public const TranscriptionModel CurrentTranscriptionModel = TranscriptionModel.AIDictationCloud;
    }

    // MARK: - Published Properties

    [ObservableProperty]
    private int _currentStep = 0;

    [ObservableProperty]
    private bool _isRecordingHotkey;

    [ObservableProperty]
    private Key _selectedHotkey = Constants.DefaultHotkey;

    [ObservableProperty]
    private ModifierKeys _selectedModifiers = Constants.DefaultModifiers;

    [ObservableProperty]
    private Language _selectedLanguage = Language.Auto;

    public ObservableCollection<LanguageItem> Languages { get; } = new();

    public int TotalSteps => Constants.TotalSteps;

    public string HotkeyDisplayText => FormatHotkey(SelectedModifiers, SelectedHotkey);

    public bool CanGoBack => CurrentStep > 0;
    public bool CanSkip => CurrentStep < TotalSteps - 1;
    public bool IsLastStep => CurrentStep == TotalSteps - 1;

    // MARK: - Events

    public event EventHandler? OnboardingCompleted;
    public event EventHandler? OnboardingSkipped;

    // MARK: - Initialization

    public OnboardingViewModel()
    {
        LoadLanguages();
        LoadSavedSettings();
    }

    // MARK: - Commands

    [RelayCommand]
    private void NextStep()
    {
        if (CurrentStep < TotalSteps - 1)
        {
            CurrentStep++;
            NotifyNavigationChanged();
        }
    }

    [RelayCommand]
    private void PreviousStep()
    {
        if (CurrentStep > 0)
        {
            CurrentStep--;
            NotifyNavigationChanged();
        }
    }

    [RelayCommand]
    private void Skip()
    {
        OnboardingSkipped?.Invoke(this, EventArgs.Empty);
    }

    [RelayCommand]
    private void Complete()
    {
        SaveSettings();
        OnboardingCompleted?.Invoke(this, EventArgs.Empty);
    }

    [RelayCommand]
    private void OpenMicrophoneSettings()
    {
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = "ms-settings:privacy-microphone",
                UseShellExecute = true
            });
        }
        catch
        {
            // Silently fail if settings can't be opened
        }
    }

    [RelayCommand]
    private void StartRecordingHotkey()
    {
        IsRecordingHotkey = true;
    }

    [RelayCommand]
    private void ClearHotkey()
    {
        SelectedHotkey = Constants.DefaultHotkey;
        SelectedModifiers = Constants.DefaultModifiers;
        OnPropertyChanged(nameof(HotkeyDisplayText));
    }

    [RelayCommand]
    private void SelectLanguage(LanguageItem? item)
    {
        if (item == null) return;
        if (!item.IsSelectable) return;

        foreach (var lang in Languages)
        {
            lang.IsSelected = lang.Language == item.Language;
        }
        SelectedLanguage = item.Language;
    }

    // MARK: - Public API

    public void RecordHotkey(Key key, ModifierKeys modifiers)
    {
        if (!IsRecordingHotkey) return;

        // Ignore modifier-only presses
        if (key == Key.LeftCtrl || key == Key.RightCtrl ||
            key == Key.LeftShift || key == Key.RightShift ||
            key == Key.LeftAlt || key == Key.RightAlt ||
            key == Key.LWin || key == Key.RWin ||
            key == Key.System)
        {
            return;
        }

        SelectedHotkey = key;
        SelectedModifiers = modifiers;
        IsRecordingHotkey = false;
        OnPropertyChanged(nameof(HotkeyDisplayText));
    }

    public void CancelHotkeyRecording()
    {
        IsRecordingHotkey = false;
    }

    // MARK: - Private Methods

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

    private void LoadSavedSettings()
    {
        var settings = SettingsService.Instance;
        settings.Load();
        settings.Settings.TranscriptionProvider = AppSettings.CloudTranscriptionProvider;

        // Load saved language if any
        if (settings.Settings.SelectedLanguages.Count > 0)
        {
            var langCode = settings.Settings.SelectedLanguages[0];
            var lang = LanguageExtensions.FromCode(langCode);
            if (lang.HasValue)
            {
                SelectedLanguage = lang.Value;
                foreach (var item in Languages)
                {
                    item.IsSelected = item.Language == SelectedLanguage;
                }
            }
        }

        // Load saved hotkey if any
        if (settings.Settings.Hotkey != null)
        {
            SelectedHotkey = settings.Settings.Hotkey.Key;
            SelectedModifiers = settings.Settings.Hotkey.Modifiers;
            OnPropertyChanged(nameof(HotkeyDisplayText));
        }
    }

    private void SaveSettings()
    {
        var settings = SettingsService.Instance;
        settings.Settings.TranscriptionProvider = AppSettings.CloudTranscriptionProvider;
        settings.Settings.SelectedLanguages = new List<string> { SelectedLanguage.GetCode() };
        settings.Settings.Hotkey = new Hotkey(SelectedHotkey, SelectedModifiers);
        settings.Settings.OnboardingCompleted = true;
        settings.SaveSettings();
    }

    private void NotifyNavigationChanged()
    {
        OnPropertyChanged(nameof(CanGoBack));
        OnPropertyChanged(nameof(CanSkip));
        OnPropertyChanged(nameof(IsLastStep));
    }

    private static string FormatHotkey(ModifierKeys modifiers, Key key)
    {
        var parts = new System.Collections.Generic.List<string>();

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
}

/// <summary>
/// Represents a language item for display in the language selection grid.
/// </summary>
public partial class LanguageItem : ObservableObject
{
    public Language Language { get; set; }
    public string DisplayName { get; set; } = string.Empty;
    public string Flag { get; set; } = string.Empty;
    public bool IsSelectable { get; set; } = true;
    public string SupportText { get; set; } = string.Empty;

    [ObservableProperty]
    private bool _isSelected;
}
