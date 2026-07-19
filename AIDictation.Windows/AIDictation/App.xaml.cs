using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
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
        public const string PipeName = "AIDictation_SingleInstance_Pipe";
        public const string UrlScheme = "aidictation";
        public const string UrlSchemeDescription = "AIDictation Protocol";

        // Caps the upload below the transcription API's file-size limit.
        public static readonly TimeSpan MaxRecordingDuration = TimeSpan.FromMinutes(4);
    }

    // MARK: - Private Properties

    private static Mutex? _singleInstanceMutex;
    private TaskbarIcon? _trayIcon;
    private readonly DispatcherTimer _recordingTimer = new();
    private DateTime _recordingStartedAt;
    private bool _mutedSystemAudioForRecording;
    private IntPtr _dictationTargetWindow;
    private Task<CaptureStartOutcome>? _captureStartTask;
    private bool _isValidationOnly;
    private bool _servicesReady;
    private bool _ownsMutex;
    private CancellationTokenSource? _pipeCts;

    // MARK: - Application Lifecycle

    protected override async void OnStartup(StartupEventArgs e)
    {
        // Single instance enforcement; forward our launch URL (e.g. the
        // aidictation://auth-callback from the browser) to the running instance.
        if (!EnsureSingleInstance())
        {
            ForwardArgsToRunningInstance(e.Args);
            Shutdown();
            return;
        }

        _ownsMutex = true;

        base.OnStartup(e);

        // Setup global exception handlers
        SetupExceptionHandling();
        ApplyWindowsAppTheme();

        if (IsOverlayValidationRun(e.Args))
        {
            _isValidationOnly = true;
            await RunOverlayValidationAsync();
            return;
        }

        // Listen for URLs forwarded by subsequent instances
        StartPipeServer();

        // Register URL scheme
        RegisterUrlScheme();

        // Handle URL activation if launched with protocol
        HandleUrlActivation(e.Args);

        // Initialize services
        await InitializeServicesAsync();
        _servicesReady = true;

        // Setup system tray
        SetupSystemTray();

        // Check onboarding and show appropriate window
        await ShowStartupWindowAsync();

        SubscribeRuntimeEvents();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _pipeCts?.Cancel();

        // A second (forwarding) instance — e.g. the OAuth callback launch or a
        // re-launch while running — never initialized services or called Load(),
        // so running cleanup here would overwrite the user's settings,
        // dictionary, shortcuts and context rules with empty in-memory defaults.
        if (!_isValidationOnly && _servicesReady)
        {
            SettingsService.Instance.SettingsChanged -= OnSettingsChanged;
            UnsubscribeRuntimeEvents();

            // Cleanup system tray
            _trayIcon?.Dispose();

            // Cleanup services
            CleanupServices();
        }

        // Only the instance that created the mutex owns it; releasing an
        // unowned mutex throws.
        if (_ownsMutex)
        {
            try { _singleInstanceMutex?.ReleaseMutex(); } catch { }
        }
        _singleInstanceMutex?.Dispose();

        base.OnExit(e);
    }

    // MARK: - Theme

    private void ApplyWindowsAppTheme()
    {
        if (UsesLightWindowsTheme())
        {
            SetThemeColor("BackgroundColor", "#F7F7F7");
            SetThemeColor("SurfaceColor", "#FFFFFF");
            SetThemeColor("SurfaceHoverColor", "#FAFAFA");
            SetThemeColor("BorderColor", "#15000000");
            SetThemeColor("BorderHiColor", "#26000000");
            SetThemeColor("TextPrimaryColor", "#1A1A1A");
            SetThemeColor("TextSecondaryColor", "#5F5F5F");
            SetThemeColor("TextMutedColor", "#7A7A7A");
            SetThemeColor("SubtleControlColor", "#08000000");
            SetThemeColor("SubtleControlHoverColor", "#10000000");
            SetThemeColor("NavHoverColor", "#08000000");
            SetThemeColor("NavSelectedColor", "#0C000000");
            SetThemeColor("SelectedChipColor", "#1AF16E00");
            SetThemeColor("SelectedChipTextColor", "#9A4A00");
            SetThemeColor("InputBackgroundColor", "#FFFFFF");
            SetThemeColor("MenuBackgroundColor", "#FFFFFF");
            SetThemeColor("DangerSoftColor", "#18E5484D");
            return;
        }

        SetThemeColor("BackgroundColor", "#202020");
        SetThemeColor("SurfaceColor", "#2B2B2B");
        SetThemeColor("SurfaceHoverColor", "#323232");
        SetThemeColor("BorderColor", "#15FFFFFF");
        SetThemeColor("BorderHiColor", "#29FFFFFF");
        SetThemeColor("TextPrimaryColor", "#FFFFFF");
        SetThemeColor("TextSecondaryColor", "#C9C9C9");
        SetThemeColor("TextMutedColor", "#8A8A8A");
        SetThemeColor("SubtleControlColor", "#0FFFFFFF");
        SetThemeColor("SubtleControlHoverColor", "#17FFFFFF");
        SetThemeColor("NavHoverColor", "#0EFFFFFF");
        SetThemeColor("NavSelectedColor", "#0FFFFFFF");
        SetThemeColor("SelectedChipColor", "#1FF16E00");
        SetThemeColor("SelectedChipTextColor", "#FFC093");
        SetThemeColor("InputBackgroundColor", "#0FFFFFFF");
        SetThemeColor("MenuBackgroundColor", "#2E2E2E");
        SetThemeColor("DangerSoftColor", "#2EE5484D");
    }

    private static bool UsesLightWindowsTheme()
    {
        try
        {
            var value = Registry.GetValue(
                @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                "AppsUseLightTheme",
                1);
            return value is not int intValue || intValue != 0;
        }
        catch
        {
            return true;
        }
    }

    private void SetThemeColor(string key, string hex)
    {
        var color = (Color)ColorConverter.ConvertFromString(hex);
        Resources[key] = color;

        var brushKey = key.Replace("Color", "Brush", StringComparison.Ordinal);
        if (Resources[brushKey] is SolidColorBrush brush && !brush.IsFrozen)
        {
            brush.Color = color;
        }
        else
        {
            Resources[brushKey] = new SolidColorBrush(color);
        }
    }

    // MARK: - UI Validation

    private static bool IsOverlayValidationRun(string[] args) =>
        args.Any(arg => arg.Equals("--validate-overlay", StringComparison.OrdinalIgnoreCase));

    private async Task RunOverlayValidationAsync()
    {
        var overlay = new OverlayWindow();
        overlay.SetPosition(OverlayPosition.Top);
        overlay.SetHideWhenIdle(false);
        overlay.SetColorTheme(OverlayColorTheme.Orange);
        overlay.Show();

        await Task.Delay(1100);

        overlay.SetValidationHover(true);
        await Task.Delay(1500);

        overlay.SetValidationHover(false);
        AppState.Shared.StartRecording();
        for (var i = 0; i < 34; i++)
        {
            var wave = 0.18f + (float)(Math.Abs(Math.Sin(i * 0.45)) * 0.78);
            AppState.Shared.UpdateAudioLevel(wave);
            await Task.Delay(65);
        }

        overlay.SetValidationHover(true);
        for (var i = 0; i < 24; i++)
        {
            var wave = 0.22f + (float)(Math.Abs(Math.Sin(i * 0.58)) * 0.7);
            AppState.Shared.UpdateAudioLevel(wave);
            await Task.Delay(65);
        }

        overlay.SetValidationHover(false);
        AppState.Shared.StartProcessing();
        await Task.Delay(2400);

        AppState.Shared.SetResult("Ready");
        await Task.Delay(1800);

        overlay.Close();
        Shutdown();
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
        using var currentProcess = Process.GetCurrentProcess();
        var activated = false;
        foreach (var process in Process.GetProcessesByName(currentProcess.ProcessName))
        {
            using (process)
            {
                if (!activated && process.Id != currentProcess.Id && process.MainWindowHandle != IntPtr.Zero)
                {
                    NativeMethods.SetForegroundWindow(process.MainWindowHandle);
                    NativeMethods.ShowWindow(process.MainWindowHandle, NativeMethods.SW_RESTORE);
                    activated = true;
                }
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

            // Handle auth callback (aidictation://auth-callback, legacy auth/callback)
            if (uri.Host.Equals("auth-callback", StringComparison.OrdinalIgnoreCase) ||
                path.StartsWith("auth/callback", StringComparison.OrdinalIgnoreCase))
            {
                _ = Dispatcher.InvokeAsync(async () =>
                {
                    var success = await AuthService.Instance.HandleOAuthCallbackAsync(uri);

                    // During onboarding the wizard reflects the signed-in state itself;
                    // only surface Settings once setup is done.
                    if (success && SettingsService.Instance.Settings.OnboardingCompleted)
                    {
                        ShowSettingsWindow();
                    }
                });
            }
        }
        catch
        {
            // Invalid URL format
        }
    }

    // MARK: - Single Instance Messaging

    private void StartPipeServer()
    {
        _pipeCts = new CancellationTokenSource();
        var token = _pipeCts.Token;

        _ = Task.Run(async () =>
        {
            while (!token.IsCancellationRequested)
            {
                try
                {
                    await using var server = new System.IO.Pipes.NamedPipeServerStream(
                        Constants.PipeName,
                        System.IO.Pipes.PipeDirection.In,
                        1,
                        System.IO.Pipes.PipeTransmissionMode.Byte,
                        System.IO.Pipes.PipeOptions.Asynchronous);

                    await server.WaitForConnectionAsync(token);

                    using var reader = new StreamReader(server);
                    var message = (await reader.ReadToEndAsync()).Trim();

                    await Dispatcher.InvokeAsync(() => HandleForwardedMessage(message));
                }
                catch (OperationCanceledException)
                {
                    break;
                }
                catch
                {
                    // Keep listening; a malformed client connection should not kill the server.
                }
            }
        }, token);
    }

    private void HandleForwardedMessage(string message)
    {
        if (!string.IsNullOrWhiteSpace(message) &&
            message.StartsWith($"{Constants.UrlScheme}://", StringComparison.OrdinalIgnoreCase))
        {
            HandleUrlActivation(new[] { message });
        }
        else
        {
            // Plain activation - bring the app to the foreground.
            ShowSettingsWindow();
        }
    }

    private static void ForwardArgsToRunningInstance(string[] args)
    {
        try
        {
            using var client = new System.IO.Pipes.NamedPipeClientStream(
                ".", Constants.PipeName, System.IO.Pipes.PipeDirection.Out);
            client.Connect(2000);

            using var writer = new StreamWriter(client);
            writer.Write(args.Length > 0 ? args[0] : string.Empty);
            writer.Flush();
        }
        catch
        {
            // Running instance is not listening; fall back to window activation.
            BringExistingInstanceToForeground();
        }
    }

    // MARK: - Service Initialization

    private static async Task InitializeServicesAsync()
    {
        // Load settings first
        SettingsService.Instance.Load();
        await HistoryService.Instance.LoadAsync();
        await AudioProcessingCoordinator.Instance.RecoverOnLaunchAsync();

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
        AppState.Shared.StateChanged += OnRuntimeStateChanged;
        OverlayService.Shared.RecordingStartRequested += OnOverlayRecordingStartRequested;
        OverlayService.Shared.RecordingStopRequested += OnOverlayRecordingStopRequested;
        OverlayService.Shared.RecordingCancelRequested += OnOverlayRecordingCancelRequested;

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
        AppState.Shared.StateChanged -= OnRuntimeStateChanged;
        OverlayService.Shared.RecordingStartRequested -= OnOverlayRecordingStartRequested;
        OverlayService.Shared.RecordingStopRequested -= OnOverlayRecordingStopRequested;
        OverlayService.Shared.RecordingCancelRequested -= OnOverlayRecordingCancelRequested;
        _recordingTimer.Tick -= OnRecordingTimerTick;
        _recordingTimer.Stop();
    }

    private void CleanupServices()
    {
        // Stop any active recording
        if (AudioProcessingCoordinator.Instance.HasActiveAttempt)
        {
            // Do not block the WPF dispatcher waiting for callbacks that may
            // themselves dispatch UI work. The durable active journal is
            // normalized to a recoverable failure on the next launch.
            try { AudioRecorderService.Instance.Dispose(); } catch { }
        }
        RestoreSystemAudioAfterRecording();

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
        HandleHotkeyPressed(isCommandMode: false);
    }

    private void OnDictationHotkeyReleased(object? sender, EventArgs e)
    {
        HandleHotkeyReleased();
    }

    private void OnCommandHotkeyPressed(object? sender, EventArgs e)
    {
        HandleHotkeyPressed(isCommandMode: true);
    }

    private void OnCommandHotkeyReleased(object? sender, EventArgs e)
    {
        HandleHotkeyReleased();
    }

    private void HandleHotkeyPressed(bool isCommandMode)
    {
        // Toggle mode: the same press starts and stops; releases are ignored.
        if (!SettingsService.Instance.Settings.PushToTalk &&
            AppState.Shared.CurrentState is AppState.State.Starting or AppState.State.Recording)
        {
            StopRecording();
            return;
        }

        StartRecording(isCommandMode);
    }

    private void HandleHotkeyReleased()
    {
        if (!SettingsService.Instance.Settings.PushToTalk) return;
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

    private void OnOverlayRecordingCancelRequested(object? sender, EventArgs e)
    {
        _ = CancelRecordingAsync();
    }

    private void StartRecording(bool isCommandMode)
    {
        // A rejected start must not overwrite the foreground window captured
        // by the attempt that is currently being finalized or transcribed.
        if (AppState.Shared.IsBusy || AudioProcessingCoordinator.Instance.HasActiveAttempt)
            return;

        if (!TranscriptionService.Instance.IsConfigured)
        {
            AppState.Shared.SetError("Transcription is not configured in this build");
            return;
        }

        if (AuthService.Instance.CurrentUser?.HasReachedLimit == true)
        {
            AppState.Shared.SetError("Monthly word limit reached. Upgrade to keep dictating.");
            return;
        }

        // Remember where the user is dictating so the paste cannot land in a
        // window focused later (e.g. after Alt-Tab during transcription).
        _dictationTargetWindow = Helpers.ForegroundWindowHelper.GetForegroundWindowHandle();
        _recordingStartedAt = DateTime.Now;
        _captureStartTask = StartRecordingCoreAsync(isCommandMode);
    }

    private async Task<CaptureStartOutcome> StartRecordingCoreAsync(bool isCommandMode)
    {
        try
        {
            var outcome = await AudioProcessingCoordinator.Instance.StartCaptureAsync(
                isCommandMode,
                SettingsService.Instance.Settings.SelectedAudioDeviceId);
            if (outcome.Started && AudioProcessingCoordinator.Instance.IsCapturing)
            {
                _recordingTimer.Start();
                MuteSystemAudioForRecording();
            }
            return outcome;
        }
        catch (Exception ex)
        {
            LogException("StartRecordingCoreAsync", ex);
            try { await AudioProcessingCoordinator.Instance.CancelAsync("Recording was interrupted during startup."); }
            catch { }
            AppState.Shared.SetError("The microphone could not start. Check microphone access and available storage.");
            return new CaptureStartOutcome(false, null, ex.Message);
        }
    }

    /// <summary>
    /// Mutes the default playback device while recording (when enabled) so
    /// speaker output does not bleed into the dictation. A device the user
    /// muted themselves is left alone.
    /// </summary>
    private void MuteSystemAudioForRecording()
    {
        if (!SettingsService.Instance.Settings.MuteAudioWhenRecording) return;

        try
        {
            using var enumerator = new NAudio.CoreAudioApi.MMDeviceEnumerator();
            using var device = enumerator.GetDefaultAudioEndpoint(
                NAudio.CoreAudioApi.DataFlow.Render, NAudio.CoreAudioApi.Role.Multimedia);
            if (!device.AudioEndpointVolume.Mute)
            {
                device.AudioEndpointVolume.Mute = true;
                _mutedSystemAudioForRecording = true;
            }
        }
        catch
        {
            // No render device or access denied - recording proceeds unmuted.
        }
    }

    private void RestoreSystemAudioAfterRecording()
    {
        if (!_mutedSystemAudioForRecording) return;
        _mutedSystemAudioForRecording = false;

        try
        {
            using var enumerator = new NAudio.CoreAudioApi.MMDeviceEnumerator();
            using var device = enumerator.GetDefaultAudioEndpoint(
                NAudio.CoreAudioApi.DataFlow.Render, NAudio.CoreAudioApi.Role.Multimedia);
            device.AudioEndpointVolume.Mute = false;
        }
        catch
        {
            // Device gone; nothing to restore.
        }
    }

    private void StopRecording()
    {
        if (AppState.Shared.CurrentState == AppState.State.Starting)
        {
            // No audio has become durable yet. Treat the stop gesture as an
            // immediate startup cancellation instead of waiting for a native
            // microphone call that may ignore cancellation.
            _ = CancelRecordingAsync();
            return;
        }
        if (AppState.Shared.CurrentState != AppState.State.Recording) return;
        _ = StopRecordingAsync();
    }

    private async Task StopRecordingAsync()
    {
        var dictationTargetWindow = _dictationTargetWindow;
        var pendingStart = _captureStartTask;
        if (pendingStart != null)
        {
            try { await pendingStart; } catch (OperationCanceledException) { return; }
        }
        if (!AudioProcessingCoordinator.Instance.IsCapturing) return;
        _recordingTimer.Stop();
        RestoreSystemAudioAfterRecording();
        var duration = DateTime.Now - _recordingStartedAt;
        try
        {
            var result = await AudioProcessingCoordinator.Instance.StopAndTranscribeAsync(duration);
            if (!result.IsSuccess || string.IsNullOrWhiteSpace(result.Text)) return;

            var pasted = await ClipboardService.Instance.PasteTextAsync(result.Text, dictationTargetWindow);
            if (!pasted)
            {
                LogException("StopRecordingAsync",
                    new InvalidOperationException("Paste was not delivered; transcript left on clipboard"));
            }
        }
        catch (OperationCanceledException)
        {
            // A concurrent CancelAsync owns the persisted cancellation and UI
            // reset. Do not replace that user action with a generic error.
        }
        catch (Exception ex)
        {
            LogException("StopRecordingAsync", ex);
            try { await AudioProcessingCoordinator.Instance.CancelAsync("Audio processing was interrupted."); }
            catch { }
            AppState.Shared.SetError("Audio processing stopped unexpectedly. The recording was kept for recovery.");
        }
    }

    private async Task CancelRecordingAsync()
    {
        _recordingTimer.Stop();
        RestoreSystemAudioAfterRecording();
        // Cancellation owns the workflow immediately. The coordinator fences a
        // late first buffer/start completion; waiting here would leave the UI in
        // Starting while a microphone call ignores cancellation.
        await AudioProcessingCoordinator.Instance.CancelAsync(
            "Recording was cancelled. The recoverable audio was kept in History.");
        var pendingStart = _captureStartTask;
        _captureStartTask = null;
        if (pendingStart != null)
        {
            _ = pendingStart.ContinueWith(
                completed => _ = completed.Exception,
                CancellationToken.None,
                TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously,
                TaskScheduler.Default);
        }
    }

    private void OnRecordingTimerTick(object? sender, EventArgs e)
    {
        if (!AppState.Shared.IsRecording) return;

        var elapsed = DateTime.Now - _recordingStartedAt;
        AppState.Shared.UpdateRecordingDuration(elapsed);

        // Stop before the recording outgrows what the transcription API accepts.
        if (elapsed >= Constants.MaxRecordingDuration)
        {
            StopRecording();
        }
    }

    private void OnAudioLevelChanged(object? sender, float level)
    {
        _ = Dispatcher.BeginInvoke(() => AppState.Shared.UpdateAudioLevel(level));
    }

    private void OnRuntimeStateChanged(object? sender, AppState.StateChangedEventArgs args)
    {
        if (args.NewState is AppState.State.Starting or AppState.State.Recording) return;
        _ = Dispatcher.BeginInvoke(() =>
        {
            _recordingTimer.Stop();
            RestoreSystemAudioAfterRecording();
        });
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
        ApplyWindowsAppTheme();
        ShowOrActivateWindow<SettingsWindow>();
    }

    private void ShowHistoryWindow()
    {
        // History lives inside Settings now.
        ApplyWindowsAppTheme();
        var settings = ShowOrActivateWindow<SettingsWindow>();
        settings.NavigateTo(ViewModels.SettingsViewModel.Sections.History);
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
