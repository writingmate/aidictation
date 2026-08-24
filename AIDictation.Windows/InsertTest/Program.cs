using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using AIDictation.Services;

namespace InsertTest;

/// <summary>
/// Tests the real ClipboardService.PasteTextWithResultAsync path on a GitHub Windows VM.
/// This is NOT a harness - it uses the exact same code the app uses.
/// </summary>
class Program
{
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

    [DllImport("kernel32.dll")]
    private static extern uint WTSGetActiveConsoleSessionId();

    [DllImport("kernel32.dll")]
    private static extern bool ProcessIdToSessionId(uint dwProcessId, out uint pSessionId);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentProcessId();

    private static string _outDir = ".";

    [STAThread]
    static int Main(string[] args)
    {
        if (args.Length > 0)
            _outDir = args[0];

        Directory.CreateDirectory(_outDir);

        Log("=== AIDictation Insert Test (Real App Code) ===");
        Log($"Output directory: {_outDir}");
        Log($"Timestamp: {DateTime.Now:yyyy-MM-dd HH:mm:ss}");
        Log("");

        // Session info
        uint sessionId;
        ProcessIdToSessionId(GetCurrentProcessId(), out sessionId);
        var consoleSession = WTSGetActiveConsoleSessionId();

        Log("[Session Info]");
        Log($"  Current session: {sessionId}");
        Log($"  Console session: {consoleSession}");
        Log($"  Running as: {Environment.UserName}");
        Log($"  Interactive: {Environment.UserInteractive}");
        Log("");

        // Run the test
        var result = RunTestAsync().GetAwaiter().GetResult();

        Log("");
        Log($"=== FINAL RESULT: {(result ? "SUCCESS" : "FAILURE")} ===");

        return result ? 0 : 1;
    }

    static async Task<bool> RunTestAsync()
    {
        Process? notepad = null;
        var testText = $"REALAPP_TEST_{DateTime.Now:HHmmss}";

        try
        {
            // 1. Open Notepad
            Log("[1] Opening Notepad...");
            notepad = Process.Start("notepad.exe");
            if (notepad == null)
            {
                Log("  ERROR: Failed to start Notepad");
                return false;
            }

            // Wait for window
            for (int i = 0; i < 30; i++)
            {
                await Task.Delay(100);
                notepad.Refresh();
                if (notepad.MainWindowHandle != IntPtr.Zero)
                    break;
            }

            var targetHwnd = notepad.MainWindowHandle;
            Log($"  Notepad PID: {notepad.Id}");
            Log($"  Notepad HWND: {targetHwnd}");

            if (targetHwnd == IntPtr.Zero)
            {
                Log("  ERROR: Notepad has no window handle");
                return false;
            }

            TakeScreenshot("01-notepad-opened");

            // 2. Focus Notepad (the way the app does it)
            Log("");
            Log("[2] Focusing Notepad...");
            var focused = await TryFocusWindowAsync(targetHwnd);
            Log($"  Focus result: {focused}");

            var fgWindow = GetForegroundWindow();
            Log($"  Foreground window: {fgWindow} (target: {targetHwnd})");

            if (fgWindow != targetHwnd)
            {
                Log("  WARNING: Focus did not land on Notepad!");
            }

            TakeScreenshot("02-before-paste");

            // 3. Call the REAL ClipboardService.PasteTextWithResultAsync
            Log("");
            Log("[3] Calling ClipboardService.PasteTextWithResultAsync...");
            Log($"  Test text: {testText}");

            var pasteResult = await ClipboardService.Instance.PasteTextWithResultAsync(
                testText,
                targetHwnd,
                smartSpacing: false);

            Log($"  Success: {pasteResult.Success}");
            Log($"  FailureReason: {pasteResult.FailureReason}");
            if (!string.IsNullOrEmpty(pasteResult.ErrorMessage))
                Log($"  ErrorMessage: {pasteResult.ErrorMessage}");

            await Task.Delay(500);
            TakeScreenshot("03-after-paste");

            // 4. Read Notepad content
            Log("");
            Log("[4] Reading Notepad content...");
            var content = ReadNotepadText(notepad);
            Log($"  Content: '{content}'");

            TakeScreenshot("04-final");

            // 5. Verdict
            Log("");
            Log("[5] Verdict:");
            var textFound = content.Contains(testText);
            Log($"  Test text found in Notepad: {textFound}");

            // Write results file
            WriteResults(testText, content, pasteResult, sessionId, consoleSession);

            if (textFound)
            {
                Log("");
                Log("SUCCESS: Real app insert path works on GitHub Windows VM!");
                return true;
            }
            else
            {
                Log("");
                Log("FAILURE: Real app insert path did NOT deliver text.");
                Log("This reproduces Sean's issue with the actual product code.");
                return false;
            }
        }
        finally
        {
            if (notepad != null && !notepad.HasExited)
            {
                try { notepad.Kill(); } catch { }
            }
        }
    }

    static async Task<bool> TryFocusWindowAsync(IntPtr hWnd)
    {
        if (GetForegroundWindow() == hWnd)
            return true;

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
                AttachThreadInput(currentThread, targetThread, false);
        }

        if (!requested) return false;

        await Task.Delay(200);
        return GetForegroundWindow() == hWnd;
    }

    static string ReadNotepadText(Process notepad)
    {
        try
        {
            var root = AutomationElement.FromHandle(notepad.MainWindowHandle);
            var editCondition = new PropertyCondition(
                AutomationElement.ControlTypeProperty, ControlType.Edit);
            var docCondition = new PropertyCondition(
                AutomationElement.ControlTypeProperty, ControlType.Document);

            // Try Document first (Windows 11 Notepad), then Edit (older)
            var el = root.FindFirst(TreeScope.Descendants, docCondition) ??
                     root.FindFirst(TreeScope.Descendants, editCondition);

            if (el != null)
            {
                if (el.TryGetCurrentPattern(TextPattern.Pattern, out var pattern) &&
                    pattern is TextPattern textPattern)
                {
                    return textPattern.DocumentRange.GetText(100000).Trim();
                }

                if (el.TryGetCurrentPattern(ValuePattern.Pattern, out var vpattern) &&
                    vpattern is ValuePattern valuePattern)
                {
                    return valuePattern.Current.Value.Trim();
                }
            }
        }
        catch (Exception ex)
        {
            Log($"  UIA read error: {ex.Message}");
        }

        return "";
    }

    static void TakeScreenshot(string name)
    {
        try
        {
            var bounds = System.Windows.Forms.Screen.PrimaryScreen?.Bounds;
            if (bounds == null || bounds.Value.Width == 0) return;

            using var bmp = new Bitmap(bounds.Value.Width, bounds.Value.Height);
            using var gfx = Graphics.FromImage(bmp);
            gfx.CopyFromScreen(bounds.Value.Left, bounds.Value.Top, 0, 0, bmp.Size);
            var path = Path.Combine(_outDir, $"{name}.png");
            bmp.Save(path, ImageFormat.Png);
            Log($"  Screenshot: {name}.png");
        }
        catch (Exception ex)
        {
            Log($"  Screenshot {name} failed: {ex.Message}");
        }
    }

    static void WriteResults(string testText, string notepadContent, PasteResult result,
                             uint sessionId, uint consoleSession)
    {
        var lines = new[]
        {
            "=== AIDictation Insert Test Results (REAL APP CODE) ===",
            $"Timestamp: {DateTime.Now:yyyy-MM-dd HH:mm:ss}",
            "",
            "[Session Info]",
            $"  Current session: {sessionId}",
            $"  Console session: {consoleSession}",
            $"  Running as: {Environment.UserName}",
            "",
            "[Test]",
            $"  Test text: {testText}",
            $"  Notepad content: '{notepadContent}'",
            "",
            "[ClipboardService.PasteTextWithResultAsync]",
            $"  Success: {result.Success}",
            $"  FailureReason: {result.FailureReason}",
            $"  ErrorMessage: {result.ErrorMessage ?? "(none)"}",
            "",
            "=== VERDICT ===",
            notepadContent.Contains(testText)
                ? "SUCCESS: Real app insert path works."
                : "FAILURE: Real app insert path did NOT deliver text."
        };

        File.WriteAllLines(Path.Combine(_outDir, "test-results.txt"), lines);
    }

    static void Log(string message)
    {
        Console.WriteLine(message);
        try
        {
            File.AppendAllText(Path.Combine(_outDir, "log.txt"), message + Environment.NewLine);
        }
        catch { }
    }
}
