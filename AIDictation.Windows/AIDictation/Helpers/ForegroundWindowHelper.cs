using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace AIDictation.Helpers;

/// <summary>
/// Resolves the foreground window's process name and title so context rules
/// can target specific applications, mirroring the macOS AppContextHelper.
/// </summary>
public static class ForegroundWindowHelper
{
    // MARK: - Types

    public readonly record struct ForegroundApp(string ProcessName, string WindowTitle);

    // MARK: - Public API

    /// <summary>
    /// Returns the current foreground application, or null when it cannot be resolved
    /// (e.g. the desktop or a protected system window is focused).
    /// </summary>
    public static ForegroundApp? GetForegroundApp()
    {
        try
        {
            var hwnd = GetForegroundWindow();
            if (hwnd == IntPtr.Zero) return null;

            GetWindowThreadProcessId(hwnd, out var processId);
            if (processId == 0) return null;

            string processName;
            using (var process = Process.GetProcessById((int)processId))
            {
                processName = process.ProcessName;
            }

            var titleBuilder = new StringBuilder(512);
            GetWindowText(hwnd, titleBuilder, titleBuilder.Capacity);

            return new ForegroundApp(processName, titleBuilder.ToString());
        }
        catch
        {
            return null;
        }
    }

    // MARK: - Native Methods

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
}
