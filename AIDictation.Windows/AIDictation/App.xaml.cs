using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
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
    private SettingsWindow? _settingsWindow;

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
    }

    protected override void OnExit(ExitEventArgs e)
    {
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

        // Initialize authentication
        await AuthService.Instance.InitializeAsync();

        // Register hotkeys based on settings
        var settings = SettingsService.Instance.Settings;
        HotkeyService.Instance.RegisterHotkeys(settings.Hotkey, settings.CommandHotkey);
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

        // Save settings
        SettingsService.Instance.SaveAll();
    }

    // MARK: - System Tray

    private void SetupSystemTray()
    {
        _trayIcon = (TaskbarIcon)FindResource("TrayIcon");
        _trayIcon.TrayMouseDoubleClick += (s, e) => ShowSettingsWindow();
    }

    private void TraySettings_Click(object sender, RoutedEventArgs e)
    {
        ShowSettingsWindow();
    }

    private void TrayExit_Click(object sender, RoutedEventArgs e)
    {
        Shutdown();
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
        var onboarding = new OnboardingWindow();
        MainWindow = onboarding;

        onboarding.ShowDialog();

        if (SettingsService.Instance.Settings.OnboardingCompleted)
        {
            ShowLoginWindow();
        }
    }

    private void ShowLoginWindow()
    {
        // The Windows login/account flow is not implemented yet.
        // Open settings so the user still lands in a visible, configurable surface.
        ShowSettingsWindow();
    }

    private void ShowSettingsWindow()
    {
        if (_settingsWindow is { IsLoaded: true })
        {
            if (!_settingsWindow.IsVisible)
            {
                _settingsWindow.Show();
            }

            _settingsWindow.Activate();
            MainWindow = _settingsWindow;
            return;
        }

        _settingsWindow = new SettingsWindow();
        _settingsWindow.Closed += (_, _) => _settingsWindow = null;
        MainWindow = _settingsWindow;
        _settingsWindow.Show();
        _settingsWindow.Activate();
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
