using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Automation;
using AIDictation.Helpers;

namespace AIDictation.Services;

/// <summary>
/// Manages clipboard operations including copying, pasting, and smart text insertion
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
    }

    // MARK: - P/Invoke

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    private static extern IntPtr GetFocus();

    [DllImport("user32.dll")]
    private static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    // MARK: - Public API

    /// <summary>
    /// Copies text to clipboard and simulates Ctrl+V paste
    /// Preserves and restores original clipboard content
    /// </summary>
    public async Task PasteTextAsync(string text, bool smartSpacing = true)
    {
        if (string.IsNullOrEmpty(text))
            return;

        // Save original clipboard content
        var originalClipboard = await GetClipboardContentAsync();

        try
        {
            // Apply smart spacing if enabled
            var textToInsert = text;
            if (smartSpacing)
            {
                textToInsert = await ApplySmartSpacingAsync(text);
            }

            // Set new text to clipboard
            await SetClipboardTextAsync(textToInsert);

            // Small delay to ensure clipboard is ready
            await Task.Delay(Constants.ClipboardDelayMs);

            // Simulate Ctrl+V
            SendInputHelper.SendPaste();

            // Wait for paste to complete
            await Task.Delay(Constants.PasteDelayMs);
        }
        finally
        {
            // The target app processes the injected Ctrl+V asynchronously;
            // restoring (or clearing) the clipboard too soon erases the payload
            // before the paste lands. Wait, and when there was no original
            // content keep the payload instead of clearing it.
            if (originalClipboard != null)
            {
                await Task.Delay(Constants.ClipboardRestoreDelayMs);
                await RestoreClipboardAsync(originalClipboard);
            }
        }
    }

    /// <summary>
    /// Gets currently selected text from the focused application
    /// Uses UI Automation first, falls back to Ctrl+C
    /// </summary>
    public async Task<string?> GetSelectedTextAsync()
    {
        // Try UI Automation first
        var text = GetSelectedTextViaAutomation();
        if (!string.IsNullOrEmpty(text))
            return text;

        // Fallback to Ctrl+C method
        return await GetSelectedTextViaCopyAsync();
    }

    /// <summary>
    /// Gets the character immediately before the cursor position
    /// Returns null if unable to determine
    /// </summary>
    public async Task<char?> GetCharacterBeforeCursorAsync()
    {
        // Save original clipboard
        var originalClipboard = await GetClipboardContentAsync();

        try
        {
            // Clear clipboard
            await ClearClipboardAsync();

            // Select character to the left using Shift+Left
            SendInputHelper.SendShiftLeft();
            await Task.Delay(Constants.ClipboardDelayMs);

            // Copy the selection
            SendInputHelper.SendCopy();
            await Task.Delay(Constants.ClipboardDelayMs);

            // Get the character
            var selectedChar = await GetClipboardTextAsync();

            // Move cursor back to original position (deselect by pressing Right)
            SendInputHelper.SendRight();

            if (!string.IsNullOrEmpty(selectedChar) && selectedChar.Length == 1)
            {
                return selectedChar[0];
            }

            return null;
        }
        finally
        {
            await Task.Delay(Constants.ClipboardDelayMs);
            await RestoreClipboardAsync(originalClipboard);
        }
    }

    /// <summary>
    /// Checks if a space should be inserted before the text
    /// </summary>
    public async Task<bool> ShouldInsertSpaceBeforeAsync()
    {
        var charBefore = await GetCharacterBeforeCursorAsync();

        // Insert space if there's a character before and it's not a space, newline, or common punctuation that doesn't need trailing space
        if (charBefore.HasValue)
        {
            var c = charBefore.Value;
            return !char.IsWhiteSpace(c) && c != '(' && c != '[' && c != '{' && c != '"' && c != '\'' && c != '`';
        }

        // No character before (start of document) - no space needed
        return false;
    }

    // MARK: - Private Methods

    private async Task<string> ApplySmartSpacingAsync(string text)
    {
        if (await ShouldInsertSpaceBeforeAsync())
        {
            return " " + text;
        }
        return text;
    }

    private string? GetSelectedTextViaAutomation()
    {
        try
        {
            var focusedElement = AutomationElement.FocusedElement;
            if (focusedElement == null)
                return null;

            if (focusedElement.TryGetCurrentPattern(TextPattern.Pattern, out var pattern) &&
                pattern is TextPattern textPattern)
            {
                var selection = textPattern.GetSelection();
                if (selection.Length > 0)
                {
                    return selection[0].GetText(-1);
                }
            }

            // Try value pattern for simple text fields
            if (focusedElement.TryGetCurrentPattern(ValuePattern.Pattern, out var valuePattern) &&
                valuePattern is ValuePattern vp)
            {
                // ValuePattern doesn't give us selection, so return null to trigger fallback
                return null;
            }
        }
        catch
        {
            // UI Automation failed, will fall back to Ctrl+C
        }

        return null;
    }

    private async Task<string?> GetSelectedTextViaCopyAsync()
    {
        // Save original clipboard
        var originalClipboard = await GetClipboardContentAsync();

        try
        {
            // Clear clipboard to detect if copy succeeded
            await ClearClipboardAsync();

            // Simulate Ctrl+C
            SendInputHelper.SendCopy();

            // Wait for copy to complete
            await Task.Delay(Constants.ClipboardDelayMs);

            // Get copied text
            var text = await GetClipboardTextAsync();

            return text;
        }
        finally
        {
            // Restore original clipboard
            await Task.Delay(Constants.ClipboardDelayMs);
            await RestoreClipboardAsync(originalClipboard);
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

    private async Task<string?> GetClipboardTextAsync()
    {
        return await RunOnStaThreadAsync(() =>
        {
            try
            {
                if (Clipboard.ContainsText())
                {
                    return Clipboard.GetText();
                }
            }
            catch
            {
                // Clipboard access failed
            }
            return null;
        });
    }

    private async Task SetClipboardTextAsync(string text)
    {
        await RunOnStaThreadAsync(() =>
        {
            try
            {
                Clipboard.SetText(text);
            }
            catch
            {
                // Clipboard access failed, retry once
                try
                {
                    Thread.Sleep(10);
                    Clipboard.SetText(text);
                }
                catch
                {
                    // Give up
                }
            }
            return (object?)null;
        });
    }

    private async Task ClearClipboardAsync()
    {
        await RunOnStaThreadAsync(() =>
        {
            try
            {
                Clipboard.Clear();
            }
            catch
            {
                // Ignore
            }
            return (object?)null;
        });
    }

    private async Task RestoreClipboardAsync(IDataObject? dataObject)
    {
        if (dataObject == null)
        {
            await ClearClipboardAsync();
            return;
        }

        await RunOnStaThreadAsync(() =>
        {
            try
            {
                // Try to restore text content
                if (dataObject.GetDataPresent(DataFormats.UnicodeText))
                {
                    var text = dataObject.GetData(DataFormats.UnicodeText) as string;
                    if (text != null)
                    {
                        Clipboard.SetText(text);
                        return (object?)null;
                    }
                }
                else if (dataObject.GetDataPresent(DataFormats.Text))
                {
                    var text = dataObject.GetData(DataFormats.Text) as string;
                    if (text != null)
                    {
                        Clipboard.SetText(text);
                        return (object?)null;
                    }
                }

                // For other data types, try to set the data object directly
                Clipboard.SetDataObject(dataObject, true);
            }
            catch
            {
                // Clipboard restoration failed
            }
            return (object?)null;
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
