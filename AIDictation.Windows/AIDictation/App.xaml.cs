using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using AIDictation.Models;
using AIDictation.Services;
using AIDictation.Views;
using H.NotifyIcon;
using Microsoft.Win32;

namespace AIDictation;

/// <summary>
/// Application entry point handling single instance enforcement, service initialization,
/// system tray setup, and custom URL scheme handling.
/// </summary>
public partial class App : Application
{
    // MARK: - Constants

    private static class Constants
    {
        public const string MutexName = "AIDictation_SingleInstance_Mutex";
        public const string UrlScheme = "aidictation";
        public const string UrlSchemeDescription = "AIDictation Protocol";
    }

    // MARK: - Private Properties

    private static Mutex? _singleInstanceMutex;
    private TaskbarIcon? _trayIcon;
    private readonly DispatcherTimer _recordingTimer = new();
    private DateTime _recordingStartedAt;
    private bool _isStoppingRecording;

    // MARK: - Application Lifecycle

    protected override async void OnStartup(StartupEventArgs e)
    {
        // Single instance enforcement
        if (!EnsureSingleInstance())
        {
            Shutdown();
            return;
        }

        base.OnStartup(e);

        // Setup global exception handlers
        SetupExceptionHandling();

        // Register URL scheme
        RegisterUrlScheme();

        // Handle URL activation if launched with protocol
        HandleUrlActivation(e.Args);

        // Initialize services
        await InitializeServicesAsync();

        // Setup system tray
        SetupSystemTray();

        // Check onboarding and show appropriate window
        await ShowStartupWindowAsync();

        SubscribeRuntimeEvents();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        SettingsService.Instance.SettingsChanged -= OnSettingsChanged;
        UnsubscribeRuntimeEvents();

        // Cleanup system tray
        _trayIcon?.Dispose();

        // Cleanup services
        CleanupServices();

        // Release mutex
        _singleInstanceMutex?.ReleaseMutex();
        _singleInstanceMutex?.Dispose();

        base.OnExit(e);
    }

    // MARK: - Single Instance

    private static bool EnsureSingleInstance()
    {
        _singleInstanceMutex = new Mutex(true, Constants.MutexName, out bool createdNew);

        if (!createdNew)
        {
            // Another instance is running - try to bring it to foreground
            BringExistingInstanceToForeground();
            return false;
        }

        return true;
    }

    private static void BringExistingInstanceToForeground()
    {
        // Find and activate existing window
        var currentProcess = Process.GetCurrentProcess();
        foreach (var process in Process.GetProcessesByName(currentProcess.ProcessName))
        {
            if (process.Id != currentProcess.Id && process.MainWindowHandle != IntPtr.Zero)
            {
                NativeMethods.SetForegroundWindow(process.MainWindowHandle);
                NativeMethods.ShowWindow(process.MainWindowHandle, NativeMethods.SW_RESTORE);
                break;
            }
        }
    }

    // MARK: - Exception Handling

    private void SetupExceptionHandling()
    {
        AppDomain.CurrentDomain.UnhandledException += (sender, args) =>
        {
            LogException("AppDomain.UnhandledException", args.ExceptionObject as Exception);
        };

        DispatcherUnhandledException += (sender, args) =>
        {
            LogException("DispatcherUnhandledException", args.Exception);
            args.Handled = true; // Prevent crash
        };

        TaskScheduler.UnobservedTaskException += (sender, args) =>
        {
            LogException("TaskScheduler.UnobservedTaskException", args.Exception);
            args.SetObserved();
        };
    }

    private static void LogException(string source, Exception? exception)
    {
        if (exception == null) return;

        try
        {
            var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            var logPath = Path.Combine(appData, "AIDictation", "error.log");
            var logDir = Path.GetDirectoryName(logPath);
            
            if (!string.IsNullOrEmpty(logDir) && !Directory.Exists(logDir))
            {
                Directory.CreateDirectory(logDir);
            }

            var logEntry = $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {source}\n{exception}\n\n";
            File.AppendAllText(logPath, logEntry);
        }
        catch
        {
            // Silently fail if logging fails
        }

#if DEBUG
        Debug.WriteLine($"[{source}] {exception}");
#endif
    }

    // MARK: - URL Scheme Registration

    private static void RegisterUrlScheme()
    {
        try
        {
            var exePath = Environment.ProcessPath;
            if (string.IsNullOrEmpty(exePath)) return;

            using var key = Registry.CurrentUser.CreateSubKey($@"Software\Classes\{Constants.UrlScheme}");
            key?.SetValue("", $"URL:{Constants.UrlSchemeDescription}");
            key?.SetValue("URL Protocol", "");

            using var iconKey = key?.CreateSubKey("DefaultIcon");
            iconKey?.SetValue("", $"\"{exePath}\",0");

            using var commandKey = key?.CreateSubKey(@"shell\open\command");
            commandKey?.SetValue("", $"\"{exePath}\" \"%1\"");
        }
        catch
        {
            // Silently fail if registry access is denied
        }
    }

    private void HandleUrlActivation(string[] args)
    {
        if (args.Length == 0) return;

        var url = args[0];
        if (!url.StartsWith($"{Constants.UrlScheme}://", StringComparison.OrdinalIgnoreCase)) return;

        // Parse and handle the URL
        try
        {
            var uri = new Uri(url);
            var path = uri.Host + uri.AbsolutePath;

            // Handle auth callback
            if (path.StartsWith("auth/callback", StringComparison.OrdinalIgnoreCase))
            {
                // Process OAuth callback
                _ = AuthService.Instance.HandleOAuthCallbackAsync(uri);
            }
        }
        catch
        {
            // Invalid URL format
        }
    }

    // MARK: - Service Initialization

    private static async Task InitializeServicesAsync()
    {
        // Load settings first
        SettingsService.Instance.Load();
        HistoryService.Instance.Load();

        // Initialize authentication
        await AuthService.Instance.InitializeAsync();

        // Register hotkeys based on settings
        var settings = SettingsService.Instance.Settings;
        HotkeyService.Instance.RegisterHotkeys(settings.Hotkey, settings.CommandHotkey);
        OverlayService.Shared.ApplySettings(settings);
        OverlayService.Shared.Initialize();
    }

    private void SubscribeRuntimeEvents()
    {
        HotkeyService.Instance.DictationHotkeyPressed += OnDictationHotkeyPressed;
        HotkeyService.Instance.DictationHotkeyReleased += OnDictationHotkeyReleased;
        HotkeyService.Instance.CommandHotkeyPressed += OnCommandHotkeyPressed;
        HotkeyService.Instance.CommandHotkeyReleased += OnCommandHotkeyReleased;
        AudioRecorderService.Instance.AudioLevelChanged += OnAudioLevelChanged;
        AudioRecorderService.Instance.RecordingCompleted += OnRecordingCompleted;
        AudioRecorderService.Instance.RecordingError += OnRecordingError;
        OverlayService.Shared.RecordingStartRequested += OnOverlayRecordingStartRequested;
        OverlayService.Shared.RecordingStopRequested += OnOverlayRecordingStopRequested;

        _recordingTimer.Interval = TimeSpan.FromMilliseconds(100);
        _recordingTimer.Tick += OnRecordingTimerTick;
    }

    private void UnsubscribeRuntimeEvents()
    {
        HotkeyService.Instance.DictationHotkeyPressed -= OnDictationHotkeyPressed;
        HotkeyService.Instance.DictationHotkeyReleased -= OnDictationHotkeyReleased;
        HotkeyService.Instance.CommandHotkeyPressed -= OnCommandHotkeyPressed;
        HotkeyService.Instance.CommandHotkeyReleased -= OnCommandHotkeyReleased;
        AudioRecorderService.Instance.AudioLevelChanged -= OnAudioLevelChanged;
        AudioRecorderService.Instance.RecordingCompleted -= OnRecordingCompleted;
        AudioRecorderService.Instance.RecordingError -= OnRecordingError;
        OverlayService.Shared.RecordingStartRequested -= OnOverlayRecordingStartRequested;
        OverlayService.Shared.RecordingStopRequested -= OnOverlayRecordingStopRequested;
        _recordingTimer.Tick -= OnRecordingTimerTick;
        _recordingTimer.Stop();
    }

    private static void CleanupServices()
    {
        // Stop any active recording
        if (AppState.Shared.IsRecording)
        {
            AudioRecorderService.Instance.StopRecording();
        }

        // Cleanup hotkey service
        HotkeyService.Instance.UnregisterAllHotkeys();

        // Cleanup overlay
        OverlayService.Shared.Shutdown();

        // Save settings
        SettingsService.Instance.SaveAll();
    }

    // MARK: - System Tray

    private void SetupSystemTray()
    {
        _trayIcon = (TaskbarIcon)FindResource("TrayIcon");
        _trayIcon.TrayMouseDoubleClick += (s, e) => ShowSettingsWindow();
        SettingsService.Instance.SettingsChanged += OnSettingsChanged;
    }

    private void TraySettings_Click(object sender, RoutedEventArgs e)
    {
        ShowSettingsWindow();
    }

    private void TrayHistory_Click(object sender, RoutedEventArgs e)
    {
        ShowHistoryWindow();
    }

    private void TrayExit_Click(object sender, RoutedEventArgs e)
    {
        Shutdown();
    }

    private void OnSettingsChanged(object? sender, EventArgs e)
    {
        var settings = SettingsService.Instance.Settings;
        HotkeyService.Instance.RegisterHotkeys(settings.Hotkey, settings.CommandHotkey);
        OverlayService.Shared.ApplySettings(settings);
    }

    // MARK: - Recording Lifecycle

    private void OnDictationHotkeyPressed(object? sender, EventArgs e)
    {
        StartRecording(false);
    }

    private void OnDictationHotkeyReleased(object? sender, EventArgs e)
    {
        StopRecording();
    }

    private void OnCommandHotkeyPressed(object? sender, EventArgs e)
    {
        StartRecording(true);
    }

    private void OnCommandHotkeyReleased(object? sender, EventArgs e)
    {
        StopRecording();
    }

    private void OnOverlayRecordingStartRequested(object? sender, bool isCommandMode)
    {
        StartRecording(isCommandMode);
    }

    private void OnOverlayRecordingStopRequested(object? sender, EventArgs e)
    {
        StopRecording();
    }

    private void StartRecording(bool isCommandMode)
    {
        if (!AppState.Shared.StartRecording(isCommandMode)) return;

        AudioRecorderService.Instance.SelectedDeviceId = SettingsService.Instance.Settings.SelectedAudioDeviceId;
        _recordingStartedAt = DateTime.Now;
        _isStoppingRecording = false;
        _recordingTimer.Start();

        if (!AudioRecorderService.Instance.StartRecording())
        {
            _recordingTimer.Stop();
            AppState.Shared.SetError("Unable to start recording");
        }
    }

    private void StopRecording()
    {
        if (!AppState.Shared.IsRecording || _isStoppingRecording) return;

        _isStoppingRecording = true;
        _recordingTimer.Stop();
        AppState.Shared.StartProcessing();
        AudioRecorderService.Instance.StopRecording();
    }

    private void OnRecordingTimerTick(object? sender, EventArgs e)
    {
        if (AppState.Shared.IsRecording)
        {
            AppState.Shared.UpdateRecordingDuration(DateTime.Now - _recordingStartedAt);
        }
    }

    private void OnAudioLevelChanged(object? sender, float level)
    {
        Dispatcher.Invoke(() => AppState.Shared.UpdateAudioLevel(level));
    }

    private void OnRecordingError(object? sender, string message)
    {
        Dispatcher.Invoke(() =>
        {
            _recordingTimer.Stop();
            _isStoppingRecording = false;
            AppState.Shared.SetError(message);
            HistoryService.Instance.Add(new Recording
            {
                Timestamp = DateTime.Now,
                Status = TranscriptionStatus.Failed,
                ErrorMessage = message,
                Duration = AppState.Shared.RecordingDuration.TotalSeconds
            });
        });
    }

    private void OnRecordingCompleted(object? sender, string filePath)
    {
        _ = Dispatcher.InvokeAsync(async () => await CompleteRecordingAsync(filePath));
    }

    private async Task CompleteRecordingAsync(string filePath)
    {
        try
        {
            var result = await TranscriptionService.Instance.TranscribeAsync(filePath);
            if (!result.IsSuccess || string.IsNullOrWhiteSpace(result.Text))
            {
                var message = result.ErrorMessage ?? "Transcription failed";
                AppState.Shared.SetError(message);
                HistoryService.Instance.Add(CreateRecording(filePath, null, TranscriptionStatus.Failed, message));
                return;
            }

            AppState.Shared.SetResult(result.Text);
            HistoryService.Instance.Add(CreateRecording(filePath, result.Text, TranscriptionStatus.Success, null));
            await ClipboardService.Instance.PasteTextAsync(result.Text);
        }
        catch (Exception ex)
        {
            LogException("CompleteRecordingAsync", ex);
            AppState.Shared.SetError(ex.Message);
            HistoryService.Instance.Add(CreateRecording(filePath, null, TranscriptionStatus.Failed, ex.Message));
        }
        finally
        {
            _isStoppingRecording = false;
        }
    }

    private static Recording CreateRecording(
        string filePath,
        string? transcription,
        TranscriptionStatus status,
        string? errorMessage)
    {
        return new Recording
        {
            Timestamp = DateTime.Now,
            AudioFilePath = filePath,
            Transcription = transcription,
            Status = status,
            ErrorMessage = errorMessage,
            Duration = AppState.Shared.RecordingDuration.TotalSeconds,
            WordCount = string.IsNullOrWhiteSpace(transcription)
                ? 0
                : transcription.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length
        };
    }

    // MARK: - Window Management

    private Task ShowStartupWindowAsync()
    {
        var settings = SettingsService.Instance.Settings;

        if (!settings.OnboardingCompleted)
        {
            ShowOnboardingWindow();
        }
        else if (!AuthService.Instance.IsAuthenticated)
        {
            ShowLoginWindow();
        }
        // If authenticated and onboarded, app runs in tray only

        return Task.CompletedTask;
    }

    private void ShowOnboardingWindow()
    {
        var onboarding = ShowOrActivateWindow<OnboardingWindow>();
        onboarding.Closed -= OnOnboardingClosed;
        onboarding.Closed += OnOnboardingClosed;
    }

    private void ShowLoginWindow()
    {
        ShowSettingsWindow();
    }

    private void ShowSettingsWindow()
    {
        ShowOrActivateWindow<SettingsWindow>();
    }

    private void ShowHistoryWindow()
    {
        ShowOrActivateWindow<HistoryWindow>();
    }

    private void OnOnboardingClosed(object? sender, EventArgs e)
    {
        if (sender is OnboardingWindow onboarding)
        {
            onboarding.Closed -= OnOnboardingClosed;
        }

        if (SettingsService.Instance.Settings.OnboardingCompleted && !AuthService.Instance.IsAuthenticated)
        {
            ShowLoginWindow();
        }
    }

    private TWindow ShowOrActivateWindow<TWindow>() where TWindow : Window, new()
    {
        var existing = Windows.OfType<TWindow>().FirstOrDefault();
        if (existing != null)
        {
            RestoreAndActivate(existing);
            return existing;
        }

        var window = new TWindow();
        RestoreAndActivate(window);
        return window;
    }

    private static void RestoreAndActivate(Window window)
    {
        if (window.WindowState == WindowState.Minimized)
        {
            window.WindowState = WindowState.Normal;
        }

        window.Show();
        window.Activate();
    }

    // MARK: - Native Methods

    private static class NativeMethods
    {
        public const int SW_RESTORE = 9;

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hWnd);

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    }
}
