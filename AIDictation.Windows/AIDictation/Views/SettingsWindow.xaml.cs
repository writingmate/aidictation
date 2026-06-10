using System.Windows;
using System.Windows.Input;
using AIDictation.ViewModels;

namespace AIDictation.Views;

/// <summary>
/// Interaction logic for SettingsWindow.xaml
/// </summary>
public partial class SettingsWindow : Window
{
    private SettingsViewModel ViewModel => (SettingsViewModel)DataContext;

    public SettingsWindow()
    {
        InitializeComponent();
        ViewModel.CloseRequested += OnCloseRequested;
    }

    private void OnCloseRequested(object? sender, System.EventArgs e)
    {
        Close();
    }

    private void Window_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (ViewModel.IsRecordingDictationHotkey || ViewModel.IsRecordingCommandHotkey)
        {
            e.Handled = true;

            // Handle escape to cancel
            if (e.Key == Key.Escape)
            {
                ViewModel.CancelHotkeyRecording();
                return;
            }

            ViewModel.RecordHotkey(e.Key, Keyboard.Modifiers);
        }
    }

    protected override void OnClosed(System.EventArgs e)
    {
        ViewModel.CloseRequested -= OnCloseRequested;
        ViewModel.Cleanup();
        base.OnClosed(e);
    }
}
