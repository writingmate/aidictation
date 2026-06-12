using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Text;
using AIDictation.Helpers;

namespace AIDictation.Services;

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

    // MARK: - Public API

    /// <summary>
    /// Copies text to the clipboard and pastes it into the target window via
    /// Ctrl+V. Returns false when the text could not be delivered (clipboard
    /// locked, target window gone, or injection blocked); the transcript is
    /// left on the clipboard in that case so the user can paste manually.
    /// </summary>
    public async Task<bool> PasteTextAsync(string text, IntPtr targetWindow = default, bool smartSpacing = true)
    {
        if (string.IsNullOrEmpty(text))
            return true;

        // Save original clipboard content
        var originalClipboard = await GetClipboardContentAsync();
        var pasted = false;

        try
        {
            var textToInsert = smartSpacing ? ApplySmartSpacing(text) : text;

            if (!await SetClipboardTextAsync(textToInsert))
            {
                System.Diagnostics.Debug.WriteLine("PasteTextAsync: clipboard write failed");
                return false;
            }

            await Task.Delay(Constants.ClipboardDelayMs);

            // Re-focus the window the user dictated into; pasting into whatever
            // happens to be foreground would send the text to the wrong app.
            if (targetWindow != IntPtr.Zero && !await TryFocusWindowAsync(targetWindow))
            {
                System.Diagnostics.Debug.WriteLine(
                    "PasteTextAsync: target window not focusable; transcript left on clipboard");
                return false;
            }

            pasted = SendInputHelper.SendPaste();

            // Wait for paste to complete
            await Task.Delay(Constants.PasteDelayMs);
            return pasted;
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

    // MARK: - Private Methods

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
        try
        {
            SetForegroundWindow(hWnd);
        }
        finally
        {
            if (attached)
            {
                AttachThreadInput(currentThread, targetThread, false);
            }
        }

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

            // Collapse the selection to the caret, then widen one character left.
            var range = selection[0].Clone();
            range.MoveEndpointByRange(TextPatternRangeEndpoint.End, range, TextPatternRangeEndpoint.Start);
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
