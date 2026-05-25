using System.Windows;
using System.Windows.Input;
using AIDictation.ViewModels;

namespace AIDictation.Views;

/// <summary>
/// Code-behind for the OnboardingWindow that handles user input events
/// and coordinates with the OnboardingViewModel.
/// </summary>
public partial class OnboardingWindow : Window
{
    // MARK: - Properties

    private OnboardingViewModel ViewModel => (OnboardingViewModel)DataContext;

    // MARK: - Initialization

    public OnboardingWindow()
    {
        InitializeComponent();

        ViewModel.OnboardingCompleted += OnOnboardingCompleted;
        ViewModel.OnboardingSkipped += OnOnboardingSkipped;
    }

    // MARK: - Event Handlers

    private void OnOnboardingCompleted(object? sender, System.EventArgs e)
    {
        Close();
    }

    private void OnOnboardingSkipped(object? sender, System.EventArgs e)
    {
        Close();
    }

    private void HotkeyRecorder_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        ViewModel.StartRecordingHotkeyCommand.Execute(null);
        
        // Focus the border so it can receive keyboard input
        if (sender is FrameworkElement element)
        {
            element.Focus();
            Keyboard.Focus(element);
        }
    }

    private void HotkeyRecorder_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (!ViewModel.IsRecordingHotkey)
            return;

        e.Handled = true;

        // Allow Escape to cancel
        if (e.Key == Key.Escape)
        {
            ViewModel.CancelHotkeyRecording();
            return;
        }

        // Get the actual key (handle system key for Alt combinations)
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        var modifiers = Keyboard.Modifiers;

        ViewModel.RecordHotkey(key, modifiers);
    }

    // MARK: - Window Events

    protected override void OnPreviewKeyDown(KeyEventArgs e)
    {
        base.OnPreviewKeyDown(e);

        // If recording hotkey, handle globally
        if (ViewModel.IsRecordingHotkey)
        {
            e.Handled = true;

            if (e.Key == Key.Escape)
            {
                ViewModel.CancelHotkeyRecording();
                return;
            }

            var key = e.Key == Key.System ? e.SystemKey : e.Key;
            var modifiers = Keyboard.Modifiers;
            ViewModel.RecordHotkey(key, modifiers);
        }
    }

    protected override void OnClosed(System.EventArgs e)
    {
        ViewModel.OnboardingCompleted -= OnOnboardingCompleted;
        ViewModel.OnboardingSkipped -= OnOnboardingSkipped;
        base.OnClosed(e);
    }
}
