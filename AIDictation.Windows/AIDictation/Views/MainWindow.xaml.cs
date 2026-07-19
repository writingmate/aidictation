using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using System.Windows.Threading;
using AIDictation.Services;

namespace AIDictation.Views;

/// <summary>
/// Main window for the AIDictation application.
/// Displays recording states, waveform visualization, and transcription results.
/// </summary>
public partial class MainWindow : Window
{
    // MARK: - Constants
    
    private static class Constants
    {
        public const int WaveformBarCount = 30;
        public const double WaveformBarWidth = 6;
        public const double WaveformBarSpacing = 4;
        public const double WaveformMaxHeight = 80;
        public const double WaveformMinHeight = 4;
    }
    
    // MARK: - Private Properties
    
    private readonly AppState _appState;
    private readonly DispatcherTimer _waveformTimer;
    private readonly Random _random = new();
    private readonly Rectangle[] _waveformBars;
    
    // MARK: - Initialization
    
    public MainWindow()
    {
        InitializeComponent();
        
        _appState = AppState.Shared;
        _waveformBars = new Rectangle[Constants.WaveformBarCount];
        
        // Initialize waveform visualization
        InitializeWaveform();
        
        // Set up waveform animation timer
        _waveformTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(50)
        };
        _waveformTimer.Tick += WaveformTimer_Tick;
        
        // Subscribe to state changes
        _appState.StateChanged += AppState_StateChanged;
        _appState.PropertyChanged += AppState_PropertyChanged;
        
        // Set initial state
        UpdateUIForState(_appState.CurrentState);
    }
    
    // MARK: - Waveform Initialization
    
    private void InitializeWaveform()
    {
        var accentBrush = FindResource("AccentBrush") as SolidColorBrush ?? Brushes.DodgerBlue;
        var totalWidth = Constants.WaveformBarCount * (Constants.WaveformBarWidth + Constants.WaveformBarSpacing);
        var startX = (WaveformCanvas.Width - totalWidth) / 2;
        
        for (int i = 0; i < Constants.WaveformBarCount; i++)
        {
            var bar = new Rectangle
            {
                Width = Constants.WaveformBarWidth,
                Height = Constants.WaveformMinHeight,
                Fill = accentBrush,
                RadiusX = Constants.WaveformBarWidth / 2,
                RadiusY = Constants.WaveformBarWidth / 2
            };
            
            Canvas.SetLeft(bar, startX + i * (Constants.WaveformBarWidth + Constants.WaveformBarSpacing));
            Canvas.SetTop(bar, (WaveformCanvas.Height - Constants.WaveformMinHeight) / 2);
            
            WaveformCanvas.Children.Add(bar);
            _waveformBars[i] = bar;
        }
    }
    
    // MARK: - Event Handlers
    
    private void Window_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        DragMove();
    }
    
    private void CopyButton_Click(object sender, RoutedEventArgs e)
    {
        if (!string.IsNullOrEmpty(ResultTextBox.Text))
        {
            try
            {
                Clipboard.SetText(ResultTextBox.Text);
            }
            catch (Exception)
            {
                // Clipboard operation failed, ignore
            }
        }
    }
    
    private void MinimizeButton_Click(object sender, RoutedEventArgs e)
    {
        WindowState = WindowState.Minimized;
    }
    
    private void AppState_StateChanged(object? sender, AppState.StateChangedEventArgs e)
    {
        _ = Dispatcher.BeginInvoke(() => UpdateUIForState(e.NewState));
    }
    
    private void AppState_PropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(AppState.TranscriptionText))
        {
            _ = Dispatcher.BeginInvoke(() =>
            {
                ResultTextBox.Text = _appState.TranscriptionText;
            });
        }
        else if (e.PropertyName == nameof(AppState.ErrorMessage))
        {
            _ = Dispatcher.BeginInvoke(() =>
            {
                ErrorText.Text = _appState.ErrorMessage;
            });
        }
    }
    
    private void WaveformTimer_Tick(object? sender, EventArgs e)
    {
        UpdateWaveform(_appState.CurrentAudioLevel);
    }
    
    // MARK: - UI State Management
    
    private void UpdateUIForState(AppState.State state)
    {
        // Hide all panels
        IdlePanel.Visibility = Visibility.Collapsed;
        RecordingPanel.Visibility = Visibility.Collapsed;
        ProcessingPanel.Visibility = Visibility.Collapsed;
        ResultPanel.Visibility = Visibility.Collapsed;
        ErrorPanel.Visibility = Visibility.Collapsed;
        
        // Stop animations
        StopAnimations();
        
        switch (state)
        {
            case AppState.State.Idle:
                IdlePanel.Visibility = Visibility.Visible;
                CopyButton.Visibility = Visibility.Collapsed;
                HotkeyHint.Text = "Press Fn to record";
                break;

            case AppState.State.Starting:
                IdlePanel.Visibility = Visibility.Visible;
                CopyButton.Visibility = Visibility.Collapsed;
                HotkeyHint.Text = "Starting microphone…";
                break;
                
            case AppState.State.Recording:
                RecordingPanel.Visibility = Visibility.Visible;
                CopyButton.Visibility = Visibility.Collapsed;
                HotkeyHint.Text = "Release Fn to stop";
                StartRecordingAnimations();
                break;

            case AppState.State.Finalizing:
                RecordingPanel.Visibility = Visibility.Visible;
                CopyButton.Visibility = Visibility.Collapsed;
                HotkeyHint.Text = "Finishing recording…";
                break;
                
            case AppState.State.Processing:
                ProcessingPanel.Visibility = Visibility.Visible;
                CopyButton.Visibility = Visibility.Collapsed;
                HotkeyHint.Text = "";
                StartSpinnerAnimation();
                break;
                
            case AppState.State.Result:
                ResultPanel.Visibility = Visibility.Visible;
                CopyButton.Visibility = Visibility.Visible;
                ResultTextBox.Text = _appState.TranscriptionText;
                HotkeyHint.Text = "Press Fn to record";
                break;
                
            case AppState.State.Error:
                ErrorPanel.Visibility = Visibility.Visible;
                CopyButton.Visibility = Visibility.Collapsed;
                ErrorText.Text = _appState.ErrorMessage;
                HotkeyHint.Text = "Press Fn to retry";
                break;
        }
    }
    
    // MARK: - Animations
    
    private void StartRecordingAnimations()
    {
        // Start waveform timer
        _waveformTimer.Start();
        
        // Start pulsing animation
        var pulsingStoryboard = FindResource("PulsingAnimation") as Storyboard;
        pulsingStoryboard?.Begin();
    }
    
    private void StartSpinnerAnimation()
    {
        var spinnerStoryboard = FindResource("SpinnerAnimation") as Storyboard;
        spinnerStoryboard?.Begin();
    }
    
    private void StopAnimations()
    {
        _waveformTimer.Stop();
        
        var pulsingStoryboard = FindResource("PulsingAnimation") as Storyboard;
        pulsingStoryboard?.Stop();
        
        var spinnerStoryboard = FindResource("SpinnerAnimation") as Storyboard;
        spinnerStoryboard?.Stop();
        
        // Reset waveform bars
        ResetWaveform();
    }
    
    private void UpdateWaveform(float audioLevel)
    {
        for (int i = 0; i < _waveformBars.Length; i++)
        {
            // Create a more organic wave pattern
            var baseHeight = audioLevel * Constants.WaveformMaxHeight;
            var variation = _random.NextDouble() * 0.6 + 0.4; // 40-100% variation
            var height = Math.Max(Constants.WaveformMinHeight, baseHeight * variation);
            
            _waveformBars[i].Height = height;
            Canvas.SetTop(_waveformBars[i], (WaveformCanvas.Height - height) / 2);
        }
    }
    
    private void ResetWaveform()
    {
        foreach (var bar in _waveformBars)
        {
            bar.Height = Constants.WaveformMinHeight;
            Canvas.SetTop(bar, (WaveformCanvas.Height - Constants.WaveformMinHeight) / 2);
        }
    }
    
    // MARK: - Public API
    
    /// <summary>
    /// Updates the hotkey hint text displayed at the bottom of the window.
    /// </summary>
    public void UpdateHotkeyHint(string hotkeyName)
    {
        HotkeyHint.Text = $"Press {hotkeyName} to record";
    }
    
    // MARK: - Cleanup
    
    protected override void OnClosed(EventArgs e)
    {
        _appState.StateChanged -= AppState_StateChanged;
        _appState.PropertyChanged -= AppState_PropertyChanged;
        _waveformTimer.Stop();
        base.OnClosed(e);
    }
}
