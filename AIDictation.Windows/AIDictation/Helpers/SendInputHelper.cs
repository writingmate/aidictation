using System.Runtime.InteropServices;

namespace AIDictation.Helpers;

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
    private const ushort VK_V = 0x56;

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

    // MARK: - Public API

    /// <summary>
    /// Simulates the Ctrl+V paste chord. Returns false when injection was
    /// rejected or blocked (e.g. UIPI against an elevated target window).
    /// </summary>
    public static bool SendPaste()
    {
        var inputs = new INPUT[4];

        // Ctrl down
        inputs[0] = CreateKeyInput(VK_CONTROL, 0);
        // V down
        inputs[1] = CreateKeyInput(VK_V, 0);
        // V up
        inputs[2] = CreateKeyInput(VK_V, KEYEVENTF_KEYUP);
        // Ctrl up
        inputs[3] = CreateKeyInput(VK_CONTROL, KEYEVENTF_KEYUP);

        return Dispatch(inputs);
    }

    // MARK: - Private Methods

    private static bool Dispatch(INPUT[] inputs)
    {
        var sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
        if (sent != inputs.Length)
        {
            System.Diagnostics.Debug.WriteLine(
                $"SendInput injected {sent}/{inputs.Length} events (error {Marshal.GetLastWin32Error()})");
            return false;
        }
        return true;
    }

    private static INPUT CreateKeyInput(ushort virtualKeyCode, uint flags)
    {
        return new INPUT
        {
            type = INPUT_KEYBOARD,
            u = new INPUTUNION
            {
                ki = new KEYBDINPUT
                {
                    wVk = virtualKeyCode,
                    wScan = 0,
                    dwFlags = flags,
                    time = 0,
                    dwExtraInfo = GetMessageExtraInfo()
                }
            }
        };
    }
}
