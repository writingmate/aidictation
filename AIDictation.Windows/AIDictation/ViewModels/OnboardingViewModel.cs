using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
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
        // 0 Mic, 1 Languages, 2 Transcription mode, 3 Hotkey, 4 Sign in, 5 Complete
        public const int TotalSteps = 6;
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

    // Transcription mode
    [ObservableProperty]
    private bool _isOfflineMode;

    [ObservableProperty]
    private bool _isDownloadingModel;

    [ObservableProperty]
    private double _modelDownloadProgress;

    // Account
    [ObservableProperty]
    private bool _isAuthenticated;

    [ObservableProperty]
    private string _accountEmail = string.Empty;

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
        LoadAccountState();

        AuthService.Instance.AuthStateChanged += OnAuthStateChanged;
        WhisperLocalService.Instance.ModelDownloadProgress += OnModelDownloadProgress;
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
    }

    [RelayCommand]
    private void SelectCloudMode()
    {
        IsOfflineMode = false;
    }

    [RelayCommand]
    private void SelectOfflineMode()
    {
        IsOfflineMode = true;

        if (!WhisperLocalService.Instance.IsModelDownloaded)
        {
            _ = DownloadWhisperModelAsync();
        }
    }

    [RelayCommand]
    private void SignIn()
    {
        AuthService.Instance.OpenLogin();
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

    /// <summary>
    /// Detaches singleton event subscriptions; call when the owning window closes.
    /// </summary>
    public void Cleanup()
    {
        AuthService.Instance.AuthStateChanged -= OnAuthStateChanged;
        WhisperLocalService.Instance.ModelDownloadProgress -= OnModelDownloadProgress;
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

        IsOfflineMode = settings.Settings.TranscriptionProvider == AppSettings.LocalTranscriptionProvider;

        // Load saved languages if any (multi-select)
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
        settings.Settings.TranscriptionProvider = IsOfflineMode
            ? AppSettings.LocalTranscriptionProvider
            : AppSettings.CloudTranscriptionProvider;

        var selectedCodes = Languages
            .Where(l => l.IsSelected)
            .Select(l => l.Language.GetCode())
            .ToList();
        settings.Settings.SelectedLanguages = selectedCodes.Count > 0
            ? selectedCodes
            : new List<string> { "auto" };

        settings.Settings.Hotkey = new Hotkey(SelectedHotkey, SelectedModifiers);
        settings.Settings.OnboardingCompleted = true;
        settings.SaveSettings();
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
        AccountEmail = auth.CurrentUser?.Email ?? string.Empty;
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
