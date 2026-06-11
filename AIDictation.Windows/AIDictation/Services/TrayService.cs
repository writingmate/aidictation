using System;
using System.Windows;
using H.NotifyIcon;
using H.NotifyIcon.Core;

namespace AIDictation.Services;

/// <summary>
/// Manages system tray icon, context menu, and tray-related interactions.
/// Provides show/hide, settings, history access, and quit functionality.
/// </summary>
public sealed class TrayService : IDisposable
{
    // MARK: - Singleton

    public static TrayService Instance { get; } = new();

    // MARK: - Constants

    private static class Constants
    {
        public const string DefaultTooltip = "AIDictation";
        public const string RecordingTooltip = "AIDictation - Recording...";
        public const string ProcessingTooltip = "AIDictation - Processing...";
    }

    // MARK: - Events

    public event EventHandler? ShowHideRequested;
    public event EventHandler? SettingsRequested;
    public event EventHandler? HistoryRequested;
    public event EventHandler? QuitRequested;

    // MARK: - Private Properties

    private TaskbarIcon? _trayIcon;
    private bool _isDisposed;
    private RecordingState _currentState = RecordingState.Idle;

    // MARK: - Types

    public enum RecordingState
    {
        Idle,
        Recording,
        Processing
    }

    // MARK: - Initialization

    private TrayService()
    {
    }

    // MARK: - Public API

    /// <summary>
    /// Initializes the tray icon. Must be called from UI thread after app startup.
    /// </summary>
    public void Initialize()
    {
        if (_trayIcon != null) return;

        _trayIcon = new TaskbarIcon
        {
            ToolTipText = Constants.DefaultTooltip,
            ContextMenu = CreateContextMenu(),
            MenuActivation = PopupActivationMode.RightClick
        };

        // Set default icon
        UpdateIcon(RecordingState.Idle);

        // Handle double-click to show/hide
        _trayIcon.TrayMouseDoubleClick += OnTrayDoubleClick;
    }

    /// <summary>
    /// Updates the tray icon and tooltip based on recording state.
    /// </summary>
    public void UpdateState(RecordingState state)
    {
        _currentState = state;
        UpdateIcon(state);
        UpdateTooltip(state);
    }

    /// <summary>
    /// Sets a custom tooltip message.
    /// </summary>
    public void SetTooltip(string tooltip)
    {
        if (_trayIcon != null)
        {
            _trayIcon.ToolTipText = tooltip;
        }
    }

    /// <summary>
    /// Shows a balloon notification.
    /// </summary>
    public void ShowNotification(string title, string message, NotificationIcon icon = NotificationIcon.Info)
    {
        _trayIcon?.ShowNotification(title, message, icon);
    }

    /// <summary>
    /// Disposes the tray icon resources.
    /// </summary>
    public void Dispose()
    {
        if (_isDisposed) return;

        if (_trayIcon != null)
        {
            _trayIcon.TrayMouseDoubleClick -= OnTrayDoubleClick;
            _trayIcon.Dispose();
            _trayIcon = null;
        }

        _isDisposed = true;
    }

    // MARK: - Private Methods

    private System.Windows.Controls.ContextMenu CreateContextMenu()
    {
        var menu = new System.Windows.Controls.ContextMenu();

        // Show/Hide
        var showHideItem = new System.Windows.Controls.MenuItem { Header = "Show/Hide" };
        showHideItem.Click += (_, _) => ShowHideRequested?.Invoke(this, EventArgs.Empty);
        menu.Items.Add(showHideItem);

        // Settings
        var settingsItem = new System.Windows.Controls.MenuItem { Header = "Settings" };
        settingsItem.Click += (_, _) => SettingsRequested?.Invoke(this, EventArgs.Empty);
        menu.Items.Add(settingsItem);

        // History
        var historyItem = new System.Windows.Controls.MenuItem { Header = "History" };
        historyItem.Click += (_, _) => HistoryRequested?.Invoke(this, EventArgs.Empty);
        menu.Items.Add(historyItem);

        // Separator
        menu.Items.Add(new System.Windows.Controls.Separator());

        // Quit
        var quitItem = new System.Windows.Controls.MenuItem { Header = "Quit" };
        quitItem.Click += (_, _) => QuitRequested?.Invoke(this, EventArgs.Empty);
        menu.Items.Add(quitItem);

        return menu;
    }

    private void UpdateIcon(RecordingState state)
    {
        if (_trayIcon == null) return;

        // Use the packaged app icon until state-specific tray icons are added.
        var iconPath = state switch
        {
            RecordingState.Recording => "pack://application:,,,/Assets/app.ico",
            RecordingState.Processing => "pack://application:,,,/Assets/app.ico",
            _ => "pack://application:,,,/Assets/app.ico"
        };

        try
        {
            var iconUri = new Uri(iconPath, UriKind.Absolute);
            _trayIcon.IconSource = new System.Windows.Media.Imaging.BitmapImage(iconUri);
        }
        catch
        {
            // Fallback: try to use app icon if state-specific icons don't exist
            try
            {
                var fallbackUri = new Uri("pack://application:,,,/Assets/app.ico", UriKind.Absolute);
                _trayIcon.IconSource = new System.Windows.Media.Imaging.BitmapImage(fallbackUri);
            }
            catch
            {
                // Icon loading failed - tray will show default icon
            }
        }
    }

    private void UpdateTooltip(RecordingState state)
    {
        if (_trayIcon == null) return;

        _trayIcon.ToolTipText = state switch
        {
            RecordingState.Recording => Constants.RecordingTooltip,
            RecordingState.Processing => Constants.ProcessingTooltip,
            _ => Constants.DefaultTooltip
        };
    }

    private void OnTrayDoubleClick(object? sender, RoutedEventArgs e)
    {
        ShowHideRequested?.Invoke(this, EventArgs.Empty);
    }
}
