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
using AIDictation.Models;
using AIDictation.Services;

namespace AIDictation.ViewModels;

/// <summary>
/// ViewModel for the onboarding wizard. Steps mirror the macOS flow:
/// permissions, languages, transcription mode, overlay color, hotkey,
/// first recording, account — then the animated completion finale.
/// </summary>
public partial class OnboardingViewModel : ObservableObject
{
    // MARK: - Constants

    public static class Steps
    {
        public const int Permissions = 0;
        public const int Languages = 1;
        public const int Mode = 2;
        public const int Color = 3;
        public const int Hotkey = 4;
        public const int FirstRecording = 5;
        public const int Account = 6;
        public const int Count = 7;
    }

    private static class Constants
    {
        public const Key DefaultHotkey = Key.F8;
        public const ModifierKeys DefaultModifiers = ModifierKeys.None;
    }

    // MARK: - Published Properties

    [ObservableProperty]
    private int _currentStep;

    public ObservableCollection<LanguageItem> Languages { get; } = new();

    // Transcription mode (mac parity: cloud / on-device / automatic with status line)
    [ObservableProperty]
    private string _selectedModeKey = AppSettings.CloudTranscriptionProvider;

    [ObservableProperty]
    private string _modelStatusText = "Offline model downloads on first use (~470 MB)";

    [ObservableProperty]
    private bool _isModelDownloading;

    [ObservableProperty]
    private bool _isModelReady;

    // Overlay color
    public ObservableCollection<ThemeOption> ThemeOptions { get; } = new();

    [ObservableProperty]
    private Brush _previewBrush = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#F16E00"));

    // Hotkey
    [ObservableProperty]
    private bool _isRecordingHotkey;

    [ObservableProperty]
    private Key _selectedHotkey = Constants.DefaultHotkey;

    [ObservableProperty]
    private ModifierKeys _selectedModifiers = Constants.DefaultModifiers;

    public string HotkeyDisplayText => FormatHotkey(SelectedModifiers, SelectedHotkey);

    // Account
    [ObservableProperty]
    private bool _isAuthenticated;

    [ObservableProperty]
    private string _accountEmail = string.Empty;

    public bool CanGoBack => CurrentStep > 0;
    public bool IsLastStep => CurrentStep == Steps.Count - 1;
    public string NextButtonText => IsLastStep ? "Finish" : "Next";

    // MARK: - Events

    public event EventHandler? OnboardingCompleted;
    public event EventHandler? FinaleRequested;

    // MARK: - Initialization

    public OnboardingViewModel()
    {
        LoadLanguages();
        LoadThemes();
        LoadSavedSettings();
        LoadAccountState();

        AuthService.Instance.AuthStateChanged += OnAuthStateChanged;
    }

    // MARK: - Commands

    [RelayCommand]
    private void NextStep()
    {
        if (IsLastStep)
        {
            SaveSettings();
            FinaleRequested?.Invoke(this, EventArgs.Empty);
            return;
        }

        CurrentStep++;
        NotifyNavigationChanged();
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
    }

    [RelayCommand]
    private void SelectMode(string? key)
    {
        if (string.IsNullOrEmpty(key)) return;
        SelectedModeKey = key;

        if (key == AppSettings.CloudTranscriptionProvider)
        {
            if (!IsModelDownloading)
            {
                ModelStatusText = "Offline model downloads on first use (~470 MB)";
            }
            return;
        }

        if (WhisperLocalService.Instance.IsModelDownloaded)
        {
            IsModelReady = true;
            ModelStatusText = "Offline model ready";
            return;
        }

        _ = DownloadModelAsync();
    }

    [RelayCommand]
    private void SelectTheme(ThemeOption? option)
    {
        if (option == null) return;
        foreach (var theme in ThemeOptions) theme.IsSelected = theme.Theme == option.Theme;
        PreviewBrush = option.Brush;
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
    private void SignIn()
    {
        AuthService.Instance.OpenLogin();
    }

    // MARK: - Public API

    public void RecordHotkey(Key key, ModifierKeys modifiers)
    {
        if (!IsRecordingHotkey) return;
        if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftShift or Key.RightShift
            or Key.LeftAlt or Key.RightAlt or Key.LWin or Key.RWin or Key.System)
        {
            return;
        }

        SelectedHotkey = key;
        SelectedModifiers = modifiers;
        IsRecordingHotkey = false;
        OnPropertyChanged(nameof(HotkeyDisplayText));
    }

    public void CancelHotkeyRecording() => IsRecordingHotkey = false;

    /// <summary>Detaches singleton event subscriptions; call when the owning window closes.</summary>
    public void Cleanup()
    {
        AuthService.Instance.AuthStateChanged -= OnAuthStateChanged;
    }

    // MARK: - Private Methods

    partial void OnCurrentStepChanged(int value)
    {
        NotifyNavigationChanged();

        // Make sure the global hotkey works for the first-recording test step.
        if (value == Steps.FirstRecording)
        {
            var settings = SettingsService.Instance.Settings;
            HotkeyService.Instance.RegisterHotkeys(
                new Hotkey(SelectedHotkey, SelectedModifiers),
                settings.CommandHotkey);
        }
    }

    private async Task DownloadModelAsync()
    {
        IsModelDownloading = true;
        ModelStatusText = "Downloading offline model…";
        try
        {
            await WhisperLocalService.Instance.EnsureModelAsync();
            IsModelReady = true;
            ModelStatusText = "Offline model ready";
        }
        catch (Exception)
        {
            ModelStatusText = "Download failed — using Cloud for now";
            SelectedModeKey = AppSettings.CloudTranscriptionProvider;
        }
        finally
        {
            IsModelDownloading = false;
        }
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

    private void LoadThemes()
    {
        ThemeOptions.Clear();
        ThemeOptions.Add(new ThemeOption(OverlayColorTheme.Orange, "Orange", "#F16E00") { IsSelected = true });
        ThemeOptions.Add(new ThemeOption(OverlayColorTheme.Blue, "Blue", "#3B82F6"));
        ThemeOptions.Add(new ThemeOption(OverlayColorTheme.Green, "Green", "#3BC45A"));
        ThemeOptions.Add(new ThemeOption(OverlayColorTheme.Purple, "Purple", "#A855F7"));
        ThemeOptions.Add(new ThemeOption(OverlayColorTheme.Pink, "Pink", "#FF7EC7"));
        ThemeOptions.Add(new ThemeOption(OverlayColorTheme.Graphite, "Graphite", "#6E6E6E"));
    }

    private void LoadSavedSettings()
    {
        var settings = SettingsService.Instance;
        settings.Load();
        var s = settings.Settings;

        SelectedModeKey = s.TranscriptionProvider;
        if (SelectedModeKey != AppSettings.CloudTranscriptionProvider &&
            WhisperLocalService.Instance.IsModelDownloaded)
        {
            IsModelReady = true;
            ModelStatusText = "Offline model ready";
        }

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

        var savedTheme = ThemeOptions.FirstOrDefault(t => t.Theme == s.OverlayColorTheme);
        if (savedTheme != null)
        {
            SelectTheme(savedTheme);
        }

        if (s.Hotkey != null)
        {
            SelectedHotkey = s.Hotkey.Key;
            SelectedModifiers = s.Hotkey.Modifiers;
            OnPropertyChanged(nameof(HotkeyDisplayText));
        }
    }

    private void SaveSettings()
    {
        var settings = SettingsService.Instance;
        var s = settings.Settings;

        s.TranscriptionProvider = SelectedModeKey;

        var selectedCodes = Languages
            .Where(l => l.IsSelected)
            .Select(l => l.Language.GetCode())
            .ToList();
        s.SelectedLanguages = selectedCodes.Count > 0 ? selectedCodes : new List<string> { "auto" };

        s.OverlayColorTheme = ThemeOptions.FirstOrDefault(t => t.IsSelected)?.Theme ?? OverlayColorTheme.Orange;
        s.Hotkey = new Hotkey(SelectedHotkey, SelectedModifiers);
        s.OnboardingCompleted = true;
        settings.SaveSettings();
    }

    private void NotifyNavigationChanged()
    {
        OnPropertyChanged(nameof(CanGoBack));
        OnPropertyChanged(nameof(IsLastStep));
        OnPropertyChanged(nameof(NextButtonText));
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

/// <summary>Language entry in the selection grids.</summary>
public partial class LanguageItem : ObservableObject
{
    public Language Language { get; set; }
    public string DisplayName { get; set; } = string.Empty;
    public string Flag { get; set; } = string.Empty;
    public bool IsSelectable { get; set; } = true;

    [ObservableProperty]
    private bool _isSelected;
}

/// <summary>Overlay color choice with live preview brush.</summary>
public partial class ThemeOption : ObservableObject
{
    public OverlayColorTheme Theme { get; }
    public string Name { get; }
    public Brush Brush { get; }

    [ObservableProperty]
    private bool _isSelected;

    public ThemeOption(OverlayColorTheme theme, string name, string hex)
    {
        Theme = theme;
        Name = name;
        Brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));
    }
}
