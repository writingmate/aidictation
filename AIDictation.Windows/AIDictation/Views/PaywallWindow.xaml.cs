using System;
using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;
using AIDictation.Models;
using AIDictation.Services;

namespace AIDictation.Views;

public partial class PaywallWindow : Window
{
    private enum StatusKind
    {
        Loading,
        Success,
        Notice,
        Error
    }

    public PaywallWindow()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            ConstrainToWorkArea();
            OpenCheckoutButton.Focus();
        };
    }

    private async void Continue_Click(object sender, RoutedEventArgs e)
    {
        SetBusy(true);
        ShowStatus(StatusKind.Loading, "Opening secure checkout…");

        // Yield once so the loading state is visible before Windows hands off
        // to the user's default browser.
        await Dispatcher.Yield(DispatcherPriority.Background);

        if (!AuthService.Instance.TryOpenUpgrade(out var errorMessage))
        {
            ShowStatus(
                StatusKind.Error,
                errorMessage ?? "Checkout could not be opened. Please try again.");
            SetBusy(false);
            OpenCheckoutButton.Focus();
            return;
        }

        ShowStatus(
            StatusKind.Success,
            "Checkout opened in your browser. When you finish, come back and check your access.");
        OpenCheckoutButton.Content = "Open checkout again";
        CheckAccessButton.Visibility = Visibility.Visible;
        CancelButton.Content = "Close";
        SetBusy(false);
        CheckAccessButton.Focus();
    }

    private async void CheckAccess_Click(object sender, RoutedEventArgs e)
    {
        SetBusy(true);
        ShowStatus(StatusKind.Loading, "Checking your account…");

        await AuthService.Instance.RefreshUserAsync();

        if (AuthService.Instance.CurrentUser?.SubscriptionTier.IsPaid() == true)
        {
            ShowStatus(StatusKind.Success, "You’re all set — Pro is active on this account.");
            OpenCheckoutButton.Visibility = Visibility.Collapsed;
            CheckAccessButton.Visibility = Visibility.Collapsed;
            CancelButton.Content = "Close";
            SetBusy(false);
            CancelButton.Focus();
            return;
        }

        ShowStatus(
            StatusKind.Notice,
            "Pro isn’t showing yet. If you just finished checkout, wait a moment and check again.");
        SetBusy(false);
        CheckAccessButton.Focus();
    }

    private void SetBusy(bool isBusy)
    {
        OpenCheckoutButton.IsEnabled = !isBusy;
        CheckAccessButton.IsEnabled = !isBusy;
    }

    private void ShowStatus(StatusKind kind, string message)
    {
        StatusPanel.Visibility = Visibility.Visible;
        StatusText.Text = message;
        StatusProgress.Visibility = kind == StatusKind.Loading
            ? Visibility.Visible
            : Visibility.Collapsed;
        StatusGlyph.Visibility = kind == StatusKind.Loading
            ? Visibility.Collapsed
            : Visibility.Visible;

        var (glyph, foregroundKey, borderKey, backgroundKey) = kind switch
        {
            StatusKind.Success => ("\uE73E", "SuccessBrush", "SuccessBrush", "SurfaceBrush"),
            StatusKind.Notice => ("\uE946", "PrimaryBrush", "PrimaryBrush", "SelectedChipBrush"),
            StatusKind.Error => ("\uEA39", "ErrorBrush", "ErrorBrush", "DangerSoftBrush"),
            _ => (string.Empty, "TextSecondaryBrush", "BorderHiBrush", "SurfaceBrush")
        };

        StatusGlyph.Text = glyph;
        StatusGlyph.Foreground = ResourceBrush(foregroundKey);
        StatusPanel.BorderBrush = ResourceBrush(borderKey);
        StatusPanel.Background = ResourceBrush(backgroundKey);
        StatusPanel.BringIntoView();
    }

    private Brush ResourceBrush(string key) =>
        TryFindResource(key) as Brush ?? Brushes.Transparent;

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        Close();
    }

    private void ConstrainToWorkArea()
    {
        const double workAreaMargin = 48;
        var workArea = SystemParameters.WorkArea;
        MaxWidth = Math.Max(MinWidth, workArea.Width - workAreaMargin);
        MaxHeight = Math.Max(MinHeight, workArea.Height - workAreaMargin);
        Width = Math.Min(Width, MaxWidth);
        Height = Math.Min(Height, MaxHeight);
    }
}
