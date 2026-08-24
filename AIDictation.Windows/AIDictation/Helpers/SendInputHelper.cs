using System.Runtime.InteropServices;

namespace AIDictation.Helpers;

/// <summary>
/// Result of a SendInput operation with detailed failure information.
/// </summary>
public readonly record struct SendInputResult(bool Success, string? ErrorMessage = null, int? Win32Error = null)
{
    public static SendInputResult Succeeded { get; } = new(true);

    public static SendInputResult Failed(string message, int? win32Error = null) =>
        new(false, message, win32Error);
}

/// <summary>
/// Provides P/Invoke wrappers for user32.dll SendInput API to simulate keyboard input
/// </summary>
public static class SendInputHelper
{
    // MARK: - Constants

    private const int INPUT_KEYBOARD = 1;
    private const uint KEYEVENTF_KEYUP = 0x0002;

    // Virtual key codes
    private const ushort VK_CONTROL = 0x11;
    private const ushort VK_SHIFT = 0x10;
    private const ushort VK_MENU = 0x12;  // Alt
    private const ushort VK_LCONTROL = 0xA2;
    private const ushort VK_RCONTROL = 0xA3;
    private const ushort VK_LSHIFT = 0xA0;
    private const ushort VK_RSHIFT = 0xA1;
    private const ushort VK_LMENU = 0xA4;
    private const ushort VK_RMENU = 0xA5;
    private const ushort VK_V = 0x56;

    // MapVirtualKey map type for VK to scan code
    private const uint MAPVK_VK_TO_VSC = 0;

    // Common Win32 error codes for SendInput failures
    private const int ERROR_ACCESS_DENIED = 5;

    // MARK: - Structures

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public int type;
        public INPUTUNION u;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct INPUTUNION
    {
        [FieldOffset(0)]
        public MOUSEINPUT mi;

        [FieldOffset(0)]
        public KEYBDINPUT ki;
    }

    // Declared even though only keyboard input is sent: the union must be
    // sized for MOUSEINPUT or Marshal.SizeOf<INPUT>() is 32 instead of the
    // native 40 on x64, and SendInput rejects every call with cbSize mismatch.
    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    // MARK: - P/Invoke

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll")]
    private static extern IntPtr GetMessageExtraInfo();

    [DllImport("user32.dll")]
    private static extern uint MapVirtualKey(uint uCode, uint uMapType);

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);

    // MARK: - Public API

    /// <summary>
    /// Simulates the Ctrl+V paste chord. Returns false when injection was
    /// rejected or blocked (e.g. UIPI against an elevated target window).
    /// </summary>
    public static bool SendPaste() => SendPasteWithResult().Success;

    /// <summary>
    /// Simulates the Ctrl+V paste chord with detailed result information.
    /// Returns success or the specific Win32 error that blocked injection.
    /// </summary>
    public static SendInputResult SendPasteWithResult()
    {
        // First, release any stuck modifier keys that could interfere with Ctrl+V.
        // This handles cases where F8 release didn't fully clear the keyboard state,
        // or where security software has left modifiers in an inconsistent state.
        ReleaseStuckModifiers();

        var inputs = new INPUT[4];

        // Ctrl down
        inputs[0] = CreateKeyInput(VK_CONTROL, 0);
        // V down
        inputs[1] = CreateKeyInput(VK_V, 0);
        // V up
        inputs[2] = CreateKeyInput(VK_V, KEYEVENTF_KEYUP);
        // Ctrl up
        inputs[3] = CreateKeyInput(VK_CONTROL, KEYEVENTF_KEYUP);

        return DispatchWithResult(inputs);
    }

    /// <summary>
    /// Releases any modifier keys that appear to be stuck down.
    /// This can happen when hotkey handling or security software leaves keys
    /// in an inconsistent state.
    /// </summary>
    private static void ReleaseStuckModifiers()
    {
        var modifiers = new ushort[]
        {
            VK_CONTROL, VK_SHIFT, VK_MENU,
            VK_LCONTROL, VK_RCONTROL,
            VK_LSHIFT, VK_RSHIFT,
            VK_LMENU, VK_RMENU
        };

        var releases = new List<INPUT>();
        foreach (var vk in modifiers)
        {
            // Check if the key appears to be down
            if ((GetAsyncKeyState(vk) & 0x8000) != 0)
            {
                System.Diagnostics.Debug.WriteLine($"Releasing stuck modifier: 0x{vk:X2}");
                releases.Add(CreateKeyInput(vk, KEYEVENTF_KEYUP));
            }
        }

        if (releases.Count > 0)
        {
            SendInput((uint)releases.Count, releases.ToArray(), Marshal.SizeOf<INPUT>());
            // Small delay to let the releases process
            Thread.Sleep(10);
        }
    }

    // MARK: - Private Methods

    private static bool Dispatch(INPUT[] inputs) => DispatchWithResult(inputs).Success;

    private static SendInputResult DispatchWithResult(INPUT[] inputs)
    {
        var sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
        if (sent != inputs.Length)
        {
            var errorCode = Marshal.GetLastWin32Error();
            System.Diagnostics.Debug.WriteLine(
                $"SendInput injected {sent}/{inputs.Length} events (error {errorCode})");

            var message = errorCode switch
            {
                ERROR_ACCESS_DENIED =>
                    "Input was blocked. The target application may be running as administrator, or security software is blocking keyboard input.",
                0 when sent == 0 =>
                    "Input injection failed. A security application may be blocking simulated keyboard input.",
                _ =>
                    $"Input injection failed (error code {errorCode}). Security software may be blocking keyboard input."
            };

            return SendInputResult.Failed(message, errorCode);
        }
        return SendInputResult.Succeeded;
    }

    private static INPUT CreateKeyInput(ushort virtualKeyCode, uint flags)
    {
        // Get the hardware scan code for better compatibility with applications
        // that process raw input or use DirectInput.
        var scanCode = (ushort)MapVirtualKey(virtualKeyCode, MAPVK_VK_TO_VSC);

        return new INPUT
        {
            type = INPUT_KEYBOARD,
            u = new INPUTUNION
            {
                ki = new KEYBDINPUT
                {
                    wVk = virtualKeyCode,
                    wScan = scanCode,
                    dwFlags = flags,
                    time = 0,
                    dwExtraInfo = GetMessageExtraInfo()
                }
            }
        };
    }
}
