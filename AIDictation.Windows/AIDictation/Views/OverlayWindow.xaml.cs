using System;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using System.Windows.Threading;
using AIDictation.Models;
using AIDictation.Services;

namespace AIDictation.Views;

/// <summary>
/// Morphing recording pill, ported from the macOS RecordingOverlayView:
/// a hairline strip when idle that morphs into the accent capsule with
/// idle dots, a live waveform (with hover cancel/stop controls), or the
/// 10-dot processing sweep. No text — pure graphic.
/// </summary>
public partial class OverlayWindow : Window
{
    // MARK: - Constants (mac metrics at 0.75 scale)

    private static class Metrics
    {
        public const int ElementCount = 10;
        public const double DotSize = 4;
        public const double DotSpacing = 4.75;
        public const double MaxBarHeight = 17.5;

        public const double CollapsedWidth = 53;
        public const double CollapsedHeight = 7;
        public const double ActiveWidth = 112;
        public const double ControlsWidth = 146;
        public const double ActiveHeight = 30;

        public const int MorphMs = 260;
        public const int CollapseMs = 150;
        public const int ContentFadeMs = 140;
        public const int ContentRevealDelayMs = 260;
        public const int ButtonRevealDelayMs = 90;
        public const double SweepCycleSeconds = 2.2;
    }

    private enum PillState
    {
        Collapsed,
        IdleExpanded,
        Recording,
        RecordingControls,
        Processing
    }

    // MARK: - Private Properties

    private readonly AppState _appState;
    private readonly DispatcherTimer _waveTimer;
    private readonly DispatcherTimer _sweepTimer;
    private readonly DispatcherTimer _resetTimer;
    private readonly Rectangle[] _bars = new Rectangle[Metrics.ElementCount];
    private readonly Ellipse[] _sweep = new Ellipse[Metrics.ElementCount];
    private readonly double[] _waveValues = new double[Metrics.ElementCount];
    private readonly Random _random = new();
    private readonly SolidColorBrush _pillBrush = new(Color.FromArgb(0xF0, 0x78, 0x6E, 0x61));

    private PillState _state = PillState.Collapsed;
    private OverlayPosition _position = OverlayPosition.Bottom;
    private OverlayColorTheme _colorTheme = OverlayColorTheme.Orange;
    private bool _hideWhenIdle;
    private bool _isHovering;
    private DateTime _sweepStart = DateTime.Now;
    private DispatcherOperation? _pendingReveal;

    private static readonly KeySpline MorphSpline = new(0.2, 0.8, 0.2, 1);

    // MARK: - Initialization

    public OverlayWindow()
    {
        InitializeComponent();

        _appState = AppState.Shared;
        Pill.Background = _pillBrush;
        Pill.BorderBrush = new SolidColorBrush(Color.FromArgb(0x3D, 0xFF, 0xFF, 0xFF));
        Pill.BorderThickness = new Thickness(0.75);

        BuildElements();

        _waveTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(50) };
        _waveTimer.Tick += (_, _) => UpdateWave(_appState.CurrentAudioLevel);

        _sweepTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(33) };
        _sweepTimer.Tick += (_, _) => UpdateSweep();

        _resetTimer = new DispatcherTimer();
        _resetTimer.Tick += (_, _) => { _resetTimer.Stop(); _appState.Reset(); };

        _appState.StateChanged += OnAppStateChanged;
        _appState.AudioLevelUpdated += OnAudioLevel;

        Loaded += (_, _) =>
        {
            UpdateWindowPosition();
            SyncToAppState();
        };
    }

    // MARK: - Public API

    public void SetPosition(OverlayPosition position)
    {
        _position = position;
        UpdateWindowPosition();
    }

    public void SetHideWhenIdle(bool hide)
    {
        _hideWhenIdle = hide;
        SyncToAppState();
    }

    public void SetColorTheme(OverlayColorTheme colorTheme)
    {
        _colorTheme = colorTheme;
        if (_state != PillState.Collapsed)
        {
            AnimatePillColor(ActiveColor());
        }
    }

    internal void SetValidationHover(bool hovering)
    {
        _isHovering = hovering;
        SyncToAppState();
    }

    public void ShowOverlay()
    {
        if (!IsVisible) Show();
    }

    public void HideOverlay()
    {
        if (IsVisible) Hide();
    }

    // MARK: - Element construction

    private void BuildElements()
    {
        for (int i = 0; i < Metrics.ElementCount; i++)
        {
            var dot = new Ellipse
            {
                Width = Metrics.DotSize,
                Height = Metrics.DotSize,
                Fill = new SolidColorBrush(Color.FromArgb(0xEB, 0xFF, 0xFF, 0xFF)),
                Margin = new Thickness(0, 0, i == Metrics.ElementCount - 1 ? 0 : Metrics.DotSpacing, 0)
            };
            IdleDots.Children.Add(dot);

            var bar = new Rectangle
            {
                Width = Metrics.DotSize,
                Height = Metrics.DotSize,
                RadiusX = 2,
                RadiusY = 2,
                Fill = new SolidColorBrush(Color.FromArgb(0xF2, 0xFF, 0xFF, 0xFF)),
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0, 0, i == Metrics.ElementCount - 1 ? 0 : Metrics.DotSpacing, 0)
            };
            _bars[i] = bar;
            _waveValues[i] = Metrics.DotSize;
            WaveBars.Children.Add(bar);

            var sweepDot = new Ellipse
            {
                Width = Metrics.DotSize,
                Height = Metrics.DotSize,
                Fill = new SolidColorBrush(Color.FromArgb(0xB8, 0xFF, 0xFF, 0xFF)),
                Opacity = 0.28,
                Margin = new Thickness(0, 0, i == Metrics.ElementCount - 1 ? 0 : Metrics.DotSpacing, 0)
            };
            _sweep[i] = sweepDot;
            SweepDots.Children.Add(sweepDot);
        }
    }

    // MARK: - State machine

    private void SyncToAppState()
    {
        switch (_appState.CurrentState)
        {
            case AppState.State.Recording:
                ApplyState(_isHovering ? PillState.RecordingControls : PillState.Recording);
                break;
            case AppState.State.Processing:
                ApplyState(PillState.Processing);
                break;
            case AppState.State.Result:
            case AppState.State.Error:
                ApplyState(PillState.Collapsed);
                _resetTimer.Interval = TimeSpan.FromSeconds(1.5);
                _resetTimer.Start();
                break;
            default:
                ApplyState(_isHovering ? PillState.IdleExpanded : PillState.Collapsed);
                break;
        }
    }

    private void ApplyState(PillState target)
    {
        if (_state == target) return;
        var previous = _state;
        _state = target;

        // Idle visibility handling
        if (target == PillState.Collapsed && _hideWhenIdle &&
            _appState.CurrentState is AppState.State.Idle or AppState.State.Result or AppState.State.Error)
        {
            HideOverlay();
            return;
        }
        ShowOverlay();

        _waveTimer.Stop();
        _sweepTimer.Stop();

        var expanding = previous == PillState.Collapsed && target != PillState.Collapsed;
        var collapsing = target == PillState.Collapsed;

        // Geometry
        double width = target switch
        {
            PillState.Collapsed => Metrics.CollapsedWidth,
            PillState.RecordingControls => Metrics.ControlsWidth,
            _ => Metrics.ActiveWidth
        };
        double height = collapsing ? Metrics.CollapsedHeight : Metrics.ActiveHeight;
        Pill.CornerRadius = new CornerRadius(height / 2);
        Pill.BorderThickness = new Thickness(collapsing ? 0.75 : 0);

        AnimateSize(width, height, collapsing ? Metrics.CollapseMs : Metrics.MorphMs, collapsing);

        // Background color
        AnimatePillColor(collapsing
            ? Color.FromArgb(0xF0, 0x78, 0x6E, 0x61)
            : ActiveColor());

        // Content swap
        _pendingReveal?.Abort();
        PillContent.BeginAnimation(OpacityProperty, new DoubleAnimation(0, TimeSpan.FromMilliseconds(60)));

        if (collapsing) return;

        var revealDelay = expanding ? Metrics.ContentRevealDelayMs : 80;
        _pendingReveal = Dispatcher.BeginInvoke(DispatcherPriority.Background, new Action(() =>
        {
            // State may have changed while waiting
            if (_state != target) return;

            IdleDots.Visibility = target == PillState.IdleExpanded ? Visibility.Visible : Visibility.Collapsed;
            WaveBars.Visibility = target is PillState.Recording or PillState.RecordingControls
                ? Visibility.Visible : Visibility.Collapsed;
            SweepDots.Visibility = target == PillState.Processing ? Visibility.Visible : Visibility.Collapsed;
            ControlsRow.Visibility = target == PillState.RecordingControls ? Visibility.Visible : Visibility.Collapsed;

            if (target is PillState.Recording or PillState.RecordingControls)
            {
                _waveTimer.Start();
            }
            if (target == PillState.Processing)
            {
                _sweepStart = DateTime.Now;
                _sweepTimer.Start();
            }
            if (target == PillState.RecordingControls)
            {
                RevealButton(CancelScale, CancelButton);
                RevealButton(StopScale, StopButton);
            }

            var fade = new DoubleAnimation(1, TimeSpan.FromMilliseconds(Metrics.ContentFadeMs))
            {
                BeginTime = TimeSpan.FromMilliseconds(revealDelay)
            };
            PillContent.BeginAnimation(OpacityProperty, fade);
        }));
    }

    private void AnimateSize(double width, double height, int durationMs, bool easeOut)
    {
        var widthAnim = new DoubleAnimationUsingKeyFrames();
        var heightAnim = new DoubleAnimationUsingKeyFrames();
        var keyTime = KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(durationMs));

        if (easeOut)
        {
            var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
            widthAnim.KeyFrames.Add(new EasingDoubleKeyFrame(width, keyTime, ease));
            heightAnim.KeyFrames.Add(new EasingDoubleKeyFrame(height, keyTime, ease));
        }
        else
        {
            widthAnim.KeyFrames.Add(new SplineDoubleKeyFrame(width, keyTime, MorphSpline));
            heightAnim.KeyFrames.Add(new SplineDoubleKeyFrame(height, keyTime, MorphSpline));
        }

        Pill.BeginAnimation(WidthProperty, widthAnim);
        Pill.BeginAnimation(HeightProperty, heightAnim);
    }

    private void AnimatePillColor(Color target)
    {
        _pillBrush.BeginAnimation(SolidColorBrush.ColorProperty,
            new ColorAnimation(target, TimeSpan.FromMilliseconds(200)));
    }

    private static void RevealButton(ScaleTransform scale, UIElement element)
    {
        element.Opacity = 0;
        var begin = TimeSpan.FromMilliseconds(Metrics.ButtonRevealDelayMs);

        element.BeginAnimation(OpacityProperty,
            new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(160)) { BeginTime = begin });

        var anim = new DoubleAnimation(0.74, 1, TimeSpan.FromMilliseconds(160))
        {
            BeginTime = begin,
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
        };
        scale.BeginAnimation(ScaleTransform.ScaleXProperty, anim);
        scale.BeginAnimation(ScaleTransform.ScaleYProperty, anim);
    }

    private Color ActiveColor()
    {
        if (_appState.IsCommandMode && _appState.CurrentState == AppState.State.Recording)
        {
            return Color.FromRgb(0x2F, 0x6B, 0xFF);
        }

        return _colorTheme switch
        {
            OverlayColorTheme.Blue => Color.FromRgb(0x3B, 0x82, 0xF6),
            OverlayColorTheme.Green => Color.FromRgb(0x3B, 0xC4, 0x5A),
            OverlayColorTheme.Purple => Color.FromRgb(0xA8, 0x55, 0xF7),
            OverlayColorTheme.Pink => Color.FromRgb(0xFF, 0x7E, 0xC7),
            OverlayColorTheme.Graphite => Color.FromRgb(0x6E, 0x6E, 0x6E),
            _ => Color.FromRgb(0xF1, 0x6E, 0x00)
        };
    }

    // MARK: - Wave / sweep animation

    private void UpdateWave(float audioLevel)
    {
        for (int i = 0; i < Metrics.ElementCount - 1; i++)
        {
            _waveValues[i] = _waveValues[i + 1];
        }

        double target = Metrics.DotSize +
            (Metrics.MaxBarHeight - Metrics.DotSize) * Math.Clamp(audioLevel, 0f, 1f);
        target *= 0.8 + _random.NextDouble() * 0.4;
        _waveValues[Metrics.ElementCount - 1] =
            Math.Clamp(target, Metrics.DotSize, Metrics.MaxBarHeight);

        for (int i = 0; i < Metrics.ElementCount; i++)
        {
            _bars[i].Height = _waveValues[i];
        }
    }

    /// <summary>Exact port of the macOS OverlayLoadingDotsView lit-range sweep.</summary>
    private void UpdateSweep()
    {
        var progress = (DateTime.Now - _sweepStart).TotalSeconds % Metrics.SweepCycleSeconds
                       / Metrics.SweepCycleSeconds;
        var (lo, hi) = LitRange(progress);

        for (int i = 0; i < Metrics.ElementCount; i++)
        {
            _sweep[i].Opacity = i >= lo && i <= hi ? 1.0 : 0.28;
        }
    }

    private static (int, int) LitRange(double progress)
    {
        const int last = Metrics.ElementCount - 1;

        if (progress < 0.32)
        {
            return (0, (int)Math.Round(EaseInOut(progress / 0.32) * last));
        }
        if (progress < 0.5)
        {
            return ((int)Math.Round(EaseInOut((progress - 0.32) / 0.18) * last), last);
        }
        if (progress < 0.82)
        {
            return ((int)Math.Round((1 - EaseInOut((progress - 0.5) / 0.32)) * last), last);
        }
        return (0, (int)Math.Round((1 - EaseInOut((progress - 0.82) / 0.18)) * last));
    }

    private static double EaseInOut(double v) =>
        v < 0.5 ? 2 * v * v : 1 - Math.Pow(-2 * v + 2, 2) / 2;

    // MARK: - Positioning

    private void UpdateWindowPosition()
    {
        // Before the first Show() there is no PresentationSource, so the
        // pixel->DIP transform is unavailable; the Loaded handler repositions.
        if (!IsLoaded) return;

        var workArea = GetActiveMonitorWorkArea();
        Left = workArea.Left + (workArea.Width - Width) / 2;
        Top = _position == OverlayPosition.Top
            ? workArea.Top + 8
            : workArea.Bottom - Height - 8;
    }

    /// <summary>
    /// Work area (in device-independent units) of the monitor under the cursor,
    /// so the overlay follows the user on multi-monitor setups instead of
    /// sticking to the primary display.
    /// </summary>
    private Rect GetActiveMonitorWorkArea()
    {
        try
        {
            if (!NativeMonitor.GetCursorPos(out var point))
            {
                return SystemParameters.WorkArea;
            }

            var monitor = NativeMonitor.MonitorFromPoint(point, NativeMonitor.MONITOR_DEFAULTTONEAREST);
            var info = new NativeMonitor.MONITORINFO
            {
                cbSize = System.Runtime.InteropServices.Marshal.SizeOf<NativeMonitor.MONITORINFO>()
            };
            if (monitor == IntPtr.Zero || !NativeMonitor.GetMonitorInfo(monitor, ref info))
            {
                return SystemParameters.WorkArea;
            }

            // Native work-area pixels -> WPF device-independent units.
            var topLeft = new Point(info.rcWork.left, info.rcWork.top);
            var bottomRight = new Point(info.rcWork.right, info.rcWork.bottom);
            var transform = PresentationSource.FromVisual(this)?.CompositionTarget?.TransformFromDevice;
            if (transform.HasValue)
            {
                topLeft = transform.Value.Transform(topLeft);
                bottomRight = transform.Value.Transform(bottomRight);
            }
            return new Rect(topLeft, bottomRight);
        }
        catch
        {
            return SystemParameters.WorkArea;
        }
    }

    private static class NativeMonitor
    {
        public const uint MONITOR_DEFAULTTONEAREST = 2;

        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        public struct POINT
        {
            public int x;
            public int y;
        }

        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        public struct RECT
        {
            public int left;
            public int top;
            public int right;
            public int bottom;
        }

        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        public struct MONITORINFO
        {
            public int cbSize;
            public RECT rcMonitor;
            public RECT rcWork;
            public uint dwFlags;
        }

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern bool GetCursorPos(out POINT lpPoint);

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern IntPtr MonitorFromPoint(POINT pt, uint dwFlags);

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);
    }

    // MARK: - Event Handlers

    private void OnAppStateChanged(object? sender, AppState.StateChangedEventArgs e)
    {
        Dispatcher.Invoke(SyncToAppState);
    }

    private void OnAudioLevel(object? sender, float level)
    {
        // Wave is driven by the 50ms timer; level is read from AppState there.
    }

    private void Pill_MouseEnter(object sender, MouseEventArgs e)
    {
        _isHovering = true;
        SyncToAppState();
    }

    private void Pill_MouseLeave(object sender, MouseEventArgs e)
    {
        _isHovering = false;
        SyncToAppState();
    }

    private void Pill_MouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (_appState.CurrentState is AppState.State.Idle or AppState.State.Result or AppState.State.Error)
        {
            OverlayService.Shared.RequestRecordingStart();
        }
    }

    private void CancelButton_Click(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        OverlayService.Shared.RequestRecordingCancel();
    }

    private void StopButton_Click(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        if (_appState.IsRecording)
        {
            OverlayService.Shared.RequestRecordingStop();
        }
    }

    // MARK: - Cleanup

    protected override void OnClosed(EventArgs e)
    {
        _appState.StateChanged -= OnAppStateChanged;
        _appState.AudioLevelUpdated -= OnAudioLevel;
        _waveTimer.Stop();
        _sweepTimer.Stop();
        _resetTimer.Stop();
        base.OnClosed(e);
    }
}
