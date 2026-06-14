using System;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media.Animation;
using AIDictation.Models;
using AIDictation.ViewModels;

namespace AIDictation.Views;

/// <summary>
/// Code-behind for the onboarding wizard: hotkey capture, mode/theme row clicks,
/// and the macOS-parity completion finale (gradient panel expands over the window,
/// then card, checkmark and button reveal in staggered phases).
/// </summary>
public partial class OnboardingWindow : Window
{
    private OnboardingViewModel ViewModel => (OnboardingViewModel)DataContext;

    public OnboardingWindow()
    {
        InitializeComponent();

        ViewModel.OnboardingCompleted += OnOnboardingCompleted;
        ViewModel.FinaleRequested += OnFinaleRequested;
    }

    // MARK: - Step interactions

    private void ModeCloud_Click(object sender, MouseButtonEventArgs e) => SelectMode(AppSettings.CloudTranscriptionProvider, "\uE753");
    private void ModeLocal_Click(object sender, MouseButtonEventArgs e) => SelectMode(AppSettings.LocalTranscriptionProvider, "\uE72E");
    private void ModeAuto_Click(object sender, MouseButtonEventArgs e) => SelectMode(AppSettings.AutoTranscriptionProvider, "\uE774");

    private void SelectMode(string key, string glyph)
    {
        ViewModel.SelectModeCommand.Execute(key);
        ModeGlyph.Text = glyph;
    }

    private void ThemeOption_Click(object sender, MouseButtonEventArgs e)
    {
        if (sender is FrameworkElement { Tag: ThemeOption option })
        {
            ViewModel.SelectThemeCommand.Execute(option);
        }
    }

    private void HotkeyRecorder_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        ViewModel.StartRecordingHotkeyCommand.Execute(null);
        if (sender is FrameworkElement element)
        {
            element.Focus();
            Keyboard.Focus(element);
        }
    }

    protected override void OnPreviewKeyDown(KeyEventArgs e)
    {
        base.OnPreviewKeyDown(e);

        if (!ViewModel.IsRecordingHotkey) return;
        e.Handled = true;

        if (e.Key == Key.Escape)
        {
            ViewModel.CancelHotkeyRecording();
            return;
        }

        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        ViewModel.RecordHotkey(key, Keyboard.Modifiers);
    }

    // MARK: - Finale (mac OnboardingView phases: 0.1s expand, 0.5s card, 0.8s check, 1.1s button)

    private void OnFinaleRequested(object? sender, EventArgs e)
    {
        FinaleLayer.Visibility = Visibility.Visible;

        var spring = new KeySpline(0.3, 1.18, 0.35, 1);

        var expand = new DoubleAnimationUsingKeyFrames { BeginTime = TimeSpan.FromMilliseconds(100) };
        expand.KeyFrames.Add(new SplineDoubleKeyFrame(ActualWidth,
            KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(550)), spring));
        FinaleLayer.BeginAnimation(WidthProperty, expand);

        AnimateIn(FinaleCard, FinaleCardScale, fromScale: 0.8, beginMs: 500, durationMs: 420, spring);

        var pop = new KeySpline(0.3, 1.6, 0.4, 1);
        AnimateIn(FinaleCheck, FinaleCheckScale, fromScale: 0.0, beginMs: 800, durationMs: 450, pop);

        FadeIn(FinaleTitle, beginMs: 850);
        FadeIn(FinaleBody, beginMs: 900);
        AnimateIn(FinaleButton, FinaleButtonScale, fromScale: 0.9, beginMs: 1100, durationMs: 300, spring);
    }

    private static void AnimateIn(UIElement element, System.Windows.Media.ScaleTransform scale,
        double fromScale, int beginMs, int durationMs, KeySpline spline)
    {
        var begin = TimeSpan.FromMilliseconds(beginMs);
        var keyTime = KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(durationMs));

        var opacity = new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(Math.Min(durationMs, 250)))
        {
            BeginTime = begin
        };
        element.BeginAnimation(OpacityProperty, opacity);

        var sx = new DoubleAnimationUsingKeyFrames { BeginTime = begin };
        sx.KeyFrames.Add(new DiscreteDoubleKeyFrame(fromScale, KeyTime.FromTimeSpan(TimeSpan.Zero)));
        sx.KeyFrames.Add(new SplineDoubleKeyFrame(1, keyTime, spline));
        var sy = sx.Clone();

        scale.BeginAnimation(System.Windows.Media.ScaleTransform.ScaleXProperty, sx);
        scale.BeginAnimation(System.Windows.Media.ScaleTransform.ScaleYProperty, sy);
    }

    private static void FadeIn(UIElement element, int beginMs)
    {
        element.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(350))
        {
            BeginTime = TimeSpan.FromMilliseconds(beginMs)
        });
    }

    // MARK: - Lifecycle

    private void OnOnboardingCompleted(object? sender, EventArgs e)
    {
        Close();
    }

    protected override void OnClosed(EventArgs e)
    {
        ViewModel.OnboardingCompleted -= OnOnboardingCompleted;
        ViewModel.FinaleRequested -= OnFinaleRequested;
        ViewModel.Cleanup();
        base.OnClosed(e);
    }
}
