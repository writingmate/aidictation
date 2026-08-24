using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Text;
using AIDictation.Helpers;

namespace AIDictation.Services;

/// <summary>
/// Result of a paste operation with detailed failure information.
/// </summary>
public sealed record PasteResult(
    bool Success,
    PasteFailureReason FailureReason = PasteFailureReason.None,
    string? ErrorMessage = null)
{
    public static PasteResult Succeeded { get; } = new(true);
    public static PasteResult Empty { get; } = new(true);

    public static PasteResult Failed(PasteFailureReason reason, string message) =>
        new(false, reason, message);
}

/// <summary>
/// Categorizes paste failures for user-facing guidance.
/// </summary>
public enum PasteFailureReason
{
    None,
    ClipboardLocked,
    TargetWindowGone,
    FocusBlocked,
    InputInjectionBlocked,
    ElevatedTargetWindow
}

/// <summary>
/// Inserts transcribed text into the target application via clipboard +
/// synthesized Ctrl+V, preserving the user's clipboard content.
/// </summary>
public sealed class ClipboardService
{
    // MARK: - Singleton

    public static ClipboardService Instance { get; } = new();

    private ClipboardService() { }

    // MARK: - Constants

    private static class Constants
    {
        public const int ClipboardDelayMs = 50;
        public const int PasteDelayMs = 30;
        public const int ClipboardRestoreDelayMs = 500;
        public const int FocusRestoreDelayMs = 150;
        public const int ClipboardWriteAttempts = 5;
    }

    // MARK: - P/Invoke

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    private static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    private static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern IntPtr SetFocus(IntPtr hWnd);

    private const uint WM_PASTE = 0x0302;

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetTokenInformation(
        IntPtr TokenHandle,
        int TokenInformationClass,
        IntPtr TokenInformation,
        int TokenInformationLength,
        out int ReturnLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hHandle);

    private const uint TOKEN_QUERY = 0x0008;
    private const int TokenElevation = 20;

    // MARK: - Public API

    /// <summary>
    /// Copies text to the clipboard and pastes it into the target window via
    /// Ctrl+V. Returns false when the text could not be delivered (clipboard
    /// locked, target window gone, or injection blocked); the transcript is
    /// left on the clipboard in that case so the user can paste manually.
    /// </summary>
    public async Task<bool> PasteTextAsync(string text, IntPtr targetWindow = default, bool smartSpacing = true)
    {
        var result = await PasteTextWithResultAsync(text, targetWindow, smartSpacing);
        return result.Success;
    }

    /// <summary>
    /// Copies text to the clipboard and pastes it into the target window via
    /// Ctrl+V. Returns a detailed result indicating success or the specific
    /// failure reason. On failure, the transcript is left on the clipboard
    /// so the user can paste manually.
    /// </summary>
    public async Task<PasteResult> PasteTextWithResultAsync(
        string text,
        IntPtr targetWindow = default,
        bool smartSpacing = true)
    {
        if (string.IsNullOrEmpty(text))
            return PasteResult.Empty;

        // Save original clipboard content
        var originalClipboard = await GetClipboardContentAsync();
        var pasted = false;

        try
        {
            var textToInsert = smartSpacing ? ApplySmartSpacing(text) : text;

            if (!await SetClipboardTextAsync(textToInsert))
            {
                System.Diagnostics.Debug.WriteLine("PasteTextAsync: clipboard write failed");
                return PasteResult.Failed(
                    PasteFailureReason.ClipboardLocked,
                    "Could not write to the clipboard. Another application may be holding it.");
            }

            await Task.Delay(Constants.ClipboardDelayMs);

            // Re-focus the window the user dictated into; pasting into whatever
            // happens to be foreground would send the text to the wrong app.
            if (targetWindow != IntPtr.Zero)
            {
                if (!IsWindow(targetWindow))
                {
                    System.Diagnostics.Debug.WriteLine(
                        "PasteTextAsync: target window no longer exists");
                    return PasteResult.Failed(
                        PasteFailureReason.TargetWindowGone,
                        "The window you were typing into has closed.");
                }

                // Check if target is an elevated process (UIPI blocks SendInput)
                if (IsTargetWindowElevated(targetWindow))
                {
                    System.Diagnostics.Debug.WriteLine(
                        "PasteTextAsync: target window belongs to an elevated process");
                    return PasteResult.Failed(
                        PasteFailureReason.ElevatedTargetWindow,
                        "The target application is running as administrator. Press Ctrl+V to paste.");
                }

                // Focus the window and send the paste command while keeping thread
                // attachment. This improves reliability on some systems where input
                // injection fails if we detach before sending.
                var (focusOk, sendResult) = await FocusAndSendPasteAsync(targetWindow);

                if (!focusOk)
                {
                    System.Diagnostics.Debug.WriteLine(
                        "PasteTextAsync: target window not focusable; transcript left on clipboard");
                    return PasteResult.Failed(
                        PasteFailureReason.FocusBlocked,
                        "Could not bring the target window to the foreground. Press Ctrl+V to paste.");
                }

                if (!sendResult.Success)
                {
                    System.Diagnostics.Debug.WriteLine(
                        $"PasteTextAsync: SendInput failed - {sendResult.ErrorMessage}");
                    return PasteResult.Failed(
                        PasteFailureReason.InputInjectionBlocked,
                        sendResult.ErrorMessage ?? "Keyboard input was blocked. Press Ctrl+V to paste.");
                }
            }
            else
            {
                // No target window - send to whatever is foreground
                var sendResult = SendInputHelper.SendPasteWithResult();
                if (!sendResult.Success)
                {
                    System.Diagnostics.Debug.WriteLine(
                        $"PasteTextAsync: SendInput failed - {sendResult.ErrorMessage}");
                    return PasteResult.Failed(
                        PasteFailureReason.InputInjectionBlocked,
                        sendResult.ErrorMessage ?? "Keyboard input was blocked. Press Ctrl+V to paste.");
                }
            }

            pasted = true;
            await Task.Delay(Constants.PasteDelayMs);
            return PasteResult.Succeeded;
        }
        finally
        {
            // The target app processes the injected Ctrl+V asynchronously;
            // restoring the clipboard too soon erases the payload before the
            // paste lands. Restore only after a successful paste - on failure
            // the transcript intentionally stays on the clipboard.
            if (originalClipboard != null && pasted)
            {
                await Task.Delay(Constants.ClipboardRestoreDelayMs);
                await RestoreClipboardAsync(originalClipboard);
            }
        }
    }

    /// <summary>
    /// Checks if the window belongs to a process running with elevated privileges
    /// WHILE we are not elevated. SendInput cannot inject into elevated windows
    /// from a non-elevated process due to UIPI. But if we're also elevated,
    /// SendInput will work.
    /// </summary>
    private static bool IsTargetWindowElevated(IntPtr hWnd)
    {
        try
        {
            // First check if WE are elevated - if so, we can inject into anything
            if (IsCurrentProcessElevated())
            {
                System.Diagnostics.Debug.WriteLine("IsTargetWindowElevated: we are elevated, SendInput should work");
                return false; // Don't block - we're elevated too
            }

            GetWindowThreadProcessId(hWnd, out var processId);
            if (processId == 0) return false;

            using var process = System.Diagnostics.Process.GetProcessById((int)processId);
            if (!OpenProcessToken(process.Handle, TOKEN_QUERY, out var tokenHandle))
                return false;

            try
            {
                var elevationSize = Marshal.SizeOf<int>();
                var elevationPtr = Marshal.AllocHGlobal(elevationSize);
                try
                {
                    if (GetTokenInformation(tokenHandle, TokenElevation, elevationPtr, elevationSize, out _))
                    {
                        var elevation = Marshal.ReadInt32(elevationPtr);
                        return elevation != 0;
                    }
                }
                finally
                {
                    Marshal.FreeHGlobal(elevationPtr);
                }
            }
            finally
            {
                CloseHandle(tokenHandle);
            }
        }
        catch
        {
            // If we can't determine elevation status, assume not elevated
        }

        return false;
    }

    /// <summary>
    /// Checks if the current process is running with elevated privileges.
    /// </summary>
    private static bool IsCurrentProcessElevated()
    {
        try
        {
            using var identity = System.Security.Principal.WindowsIdentity.GetCurrent();
            var principal = new System.Security.Principal.WindowsPrincipal(identity);
            return principal.IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
        }
        catch
        {
            return false;
        }
    }

    // MARK: - Private Methods

    /// <summary>
    /// Focuses the target window and sends the paste command while maintaining
    /// thread attachment. This improves reliability by keeping the input queue
    /// connected during the entire operation.
    /// </summary>
    private async Task<(bool FocusOk, SendInputResult SendResult)> FocusAndSendPasteAsync(IntPtr hWnd)
    {
        if (GetForegroundWindow() == hWnd)
        {
            // Already focused, just send the paste
            var result = SendInputHelper.SendPasteWithResult();
            return (true, result);
        }

        // SetForegroundWindow is restricted for background processes; attaching
        // to the target window's input thread lifts the restriction.
        var targetThread = GetWindowThreadProcessId(hWnd, out _);
        var currentThread = GetCurrentThreadId();
        var attached = targetThread != 0 && targetThread != currentThread &&
                       AttachThreadInput(currentThread, targetThread, true);

        try
        {
            var requested = SetForegroundWindow(hWnd);
            if (!requested)
            {
                System.Diagnostics.Debug.WriteLine("FocusAndSendPasteAsync: SetForegroundWindow returned false");
                // Fallback: try posting WM_PASTE directly to the window
                System.Diagnostics.Debug.WriteLine("FocusAndSendPasteAsync: trying WM_PASTE fallback");
                if (TrySendPasteMessage(hWnd))
                {
                    return (true, SendInputResult.Succeeded);
                }
                return (false, SendInputResult.Succeeded);
            }

            // Wait for focus to settle - use a longer delay for reliability
            await Task.Delay(Constants.FocusRestoreDelayMs + 100);

            // Verify focus before sending input
            var currentForeground = GetForegroundWindow();
            if (currentForeground != hWnd)
            {
                System.Diagnostics.Debug.WriteLine(
                    $"FocusAndSendPasteAsync: focus shifted to {currentForeground:X}, expected {hWnd:X}");
                // Fallback: try posting WM_PASTE directly
                System.Diagnostics.Debug.WriteLine("FocusAndSendPasteAsync: trying WM_PASTE fallback");
                if (TrySendPasteMessage(hWnd))
                {
                    return (true, SendInputResult.Succeeded);
                }
                return (false, SendInputResult.Succeeded);
            }

            // Also try setting keyboard focus explicitly within the attached thread
            SetFocus(hWnd);

            // Send paste while still attached to the target's input queue.
            // This may improve delivery on some systems.
            var sendResult = SendInputHelper.SendPasteWithResult();
            return (true, sendResult);
        }
        finally
        {
            if (attached)
            {
                AttachThreadInput(currentThread, targetThread, false);
            }
        }
    }

    /// <summary>
    /// Tries to send WM_PASTE directly to the window. This bypasses the input
    /// queue and works even when SendInput cannot deliver keystrokes to the
    /// target window (e.g., focus issues or security restrictions).
    /// </summary>
    private static bool TrySendPasteMessage(IntPtr hWnd)
    {
        if (hWnd == IntPtr.Zero || !IsWindow(hWnd))
            return false;

        // Many edit controls, including standard Windows Edit controls and
        // RichEdit, respond to WM_PASTE directly.
        return PostMessage(hWnd, WM_PASTE, IntPtr.Zero, IntPtr.Zero);
    }

    private async Task<bool> TryFocusWindowAsync(IntPtr hWnd)
    {
        if (GetForegroundWindow() == hWnd)
            return true;

        // SetForegroundWindow is restricted for background processes; attaching
        // to the target window's input thread lifts the restriction.
        var targetThread = GetWindowThreadProcessId(hWnd, out _);
        var currentThread = GetCurrentThreadId();
        var attached = targetThread != 0 && targetThread != currentThread &&
                       AttachThreadInput(currentThread, targetThread, true);
        bool requested;
        try
        {
            requested = SetForegroundWindow(hWnd);
        }
        finally
        {
            if (attached)
            {
                AttachThreadInput(currentThread, targetThread, false);
            }
        }

        if (!requested) return false;

        await Task.Delay(Constants.FocusRestoreDelayMs);
        return GetForegroundWindow() == hWnd;
    }

    /// <summary>
    /// Prepends a space when the character before the caret needs one. Read-only:
    /// uses UI Automation and never injects keystrokes (a probe that sends
    /// Ctrl+C would, for example, kill the foreground process in a terminal).
    /// </summary>
    private static string ApplySmartSpacing(string text)
    {
        var charBefore = GetCharacterBeforeCaret();
        if (charBefore is char c &&
            !char.IsWhiteSpace(c) &&
            c != '(' && c != '[' && c != '{' && c != '"' && c != '\'' && c != '`')
        {
            return " " + text;
        }
        return text;
    }

    private static char? GetCharacterBeforeCaret()
    {
        try
        {
            var focused = AutomationElement.FocusedElement;
            if (focused == null)
                return null;

            if (!focused.TryGetCurrentPattern(TextPattern.Pattern, out var pattern) ||
                pattern is not TextPattern textPattern)
            {
                return null;
            }

            var selection = textPattern.GetSelection();
            if (selection.Length == 0)
                return null;

            // Collapse the selection to its end (where the caret sits after a
            // typical selection), then widen one character left.
            var range = selection[0].Clone();
            range.MoveEndpointByRange(TextPatternRangeEndpoint.Start, range, TextPatternRangeEndpoint.End);
            range.MoveEndpointByUnit(TextPatternRangeEndpoint.Start, TextUnit.Character, -1);
            var textBefore = range.GetText(1);
            return textBefore.Length == 1 ? textBefore[0] : null;
        }
        catch
        {
            return null;
        }
    }

    private async Task<IDataObject?> GetClipboardContentAsync()
    {
        return await RunOnStaThreadAsync(() =>
        {
            try
            {
                if (Clipboard.ContainsText() || Clipboard.ContainsImage() || Clipboard.ContainsFileDropList())
                {
                    return Clipboard.GetDataObject();
                }
            }
            catch
            {
                // Clipboard access failed
            }
            return null;
        });
    }

    private async Task<bool> SetClipboardTextAsync(string text)
    {
        return await RunOnStaThreadAsync(() =>
        {
            // Another process (clipboard manager, RDP, antivirus) may hold the
            // clipboard lock; back off and retry instead of silently pasting
            // whatever was on the clipboard before.
            for (var attempt = 0; attempt < Constants.ClipboardWriteAttempts; attempt++)
            {
                try
                {
                    Clipboard.SetText(text);
                    return true;
                }
                catch
                {
                    Thread.Sleep(10 << attempt);
                }
            }
            return false;
        });
    }

    private async Task RestoreClipboardAsync(IDataObject dataObject)
    {
        await RunOnStaThreadAsync<object?>(() =>
        {
            try
            {
                // Restoring the full data object preserves rich content
                // (images, file lists, HTML) instead of just the text view.
                Clipboard.SetDataObject(dataObject, true);
                return null;
            }
            catch
            {
                // Fall back to the text representation below.
            }

            try
            {
                if (dataObject.GetDataPresent(DataFormats.UnicodeText) &&
                    dataObject.GetData(DataFormats.UnicodeText) is string text)
                {
                    Clipboard.SetText(text);
                }
            }
            catch
            {
                // Clipboard restoration failed
            }
            return null;
        });
    }

    private async Task<T?> RunOnStaThreadAsync<T>(Func<T?> action)
    {
        if (Thread.CurrentThread.GetApartmentState() == ApartmentState.STA)
        {
            return action();
        }

        T? result = default;
        var tcs = new TaskCompletionSource<bool>();

        var thread = new Thread(() =>
        {
            try
            {
                result = action();
                tcs.SetResult(true);
            }
            catch (Exception ex)
            {
                tcs.SetException(ex);
            }
        });

        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();

        await tcs.Task;
        return result;
    }
}
