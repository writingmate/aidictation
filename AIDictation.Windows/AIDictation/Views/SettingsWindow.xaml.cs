using System.Windows;
using System.Windows.Controls;
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

    /// <summary>Navigates to a settings section (e.g. History from the tray menu).</summary>
    public void NavigateTo(int section)
    {
        ViewModel.NavigateTo(section);
    }

    private void OnCloseRequested(object? sender, System.EventArgs e)
    {
        Close();
    }

    private void Window_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (ViewModel.IsRecordingDictationHotkey)
        {
            e.Handled = true;

            if (e.Key == Key.Escape)
            {
                ViewModel.CancelHotkeyRecording();
                return;
            }

            var key = e.Key == Key.System ? e.SystemKey : e.Key;
            ViewModel.RecordHotkey(key, Keyboard.Modifiers);
        }
    }

    private void NewWord_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && ViewModel.AddWordCommand.CanExecute(null))
        {
            ViewModel.AddWordCommand.Execute(null);
        }
    }

    private void HistoryRow_Click(object sender, MouseButtonEventArgs e)
    {
        // Left click opens the same action flyout as right click.
        if (sender is Border border && border.ContextMenu != null)
        {
            border.ContextMenu.PlacementTarget = border;
            border.ContextMenu.IsOpen = true;
        }
    }

    protected override void OnClosed(System.EventArgs e)
    {
        ViewModel.CloseRequested -= OnCloseRequested;
        ViewModel.Cleanup();
        base.OnClosed(e);
    }
}
