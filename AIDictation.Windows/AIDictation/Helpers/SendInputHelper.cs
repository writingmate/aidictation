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
    private const uint KEYEVENTF_EXTENDEDKEY = 0x0001;

    // Virtual key codes
    public const ushort VK_CONTROL = 0x11;
    public const ushort VK_SHIFT = 0x10;
    public const ushort VK_V = 0x56;
    public const ushort VK_C = 0x43;
    public const ushort VK_LEFT = 0x25;
    public const ushort VK_RIGHT = 0x27;

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
    /// Simulates a key press (down and up)
    /// </summary>
    public static void SendKey(ushort virtualKeyCode, bool extended = false)
    {
        var inputs = new INPUT[2];
        var flags = extended ? KEYEVENTF_EXTENDEDKEY : 0u;

        inputs[0] = CreateKeyInput(virtualKeyCode, flags);
        inputs[1] = CreateKeyInput(virtualKeyCode, flags | KEYEVENTF_KEYUP);

        Dispatch(inputs);
    }

    /// <summary>
    /// Simulates pressing a key down
    /// </summary>
    public static void SendKeyDown(ushort virtualKeyCode, bool extended = false)
    {
        var inputs = new INPUT[1];
        var flags = extended ? KEYEVENTF_EXTENDEDKEY : 0u;
        inputs[0] = CreateKeyInput(virtualKeyCode, flags);
        Dispatch(inputs);
    }

    /// <summary>
    /// Simulates releasing a key
    /// </summary>
    public static void SendKeyUp(ushort virtualKeyCode, bool extended = false)
    {
        var inputs = new INPUT[1];
        var flags = (extended ? KEYEVENTF_EXTENDEDKEY : 0u) | KEYEVENTF_KEYUP;
        inputs[0] = CreateKeyInput(virtualKeyCode, flags);
        Dispatch(inputs);
    }

    /// <summary>
    /// Simulates Ctrl+V paste keystroke
    /// </summary>
    public static void SendPaste()
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

        Dispatch(inputs);
    }

    /// <summary>
    /// Simulates Ctrl+C copy keystroke
    /// </summary>
    public static void SendCopy()
    {
        var inputs = new INPUT[4];

        // Ctrl down
        inputs[0] = CreateKeyInput(VK_CONTROL, 0);
        // C down
        inputs[1] = CreateKeyInput(VK_C, 0);
        // C up
        inputs[2] = CreateKeyInput(VK_C, KEYEVENTF_KEYUP);
        // Ctrl up
        inputs[3] = CreateKeyInput(VK_CONTROL, KEYEVENTF_KEYUP);

        Dispatch(inputs);
    }

    /// <summary>
    /// Simulates Shift+Left Arrow to select character to the left
    /// </summary>
    public static void SendShiftLeft()
    {
        var inputs = new INPUT[4];

        // Shift down
        inputs[0] = CreateKeyInput(VK_SHIFT, 0);
        // Left down (extended key)
        inputs[1] = CreateKeyInput(VK_LEFT, KEYEVENTF_EXTENDEDKEY);
        // Left up
        inputs[2] = CreateKeyInput(VK_LEFT, KEYEVENTF_EXTENDEDKEY | KEYEVENTF_KEYUP);
        // Shift up
        inputs[3] = CreateKeyInput(VK_SHIFT, KEYEVENTF_KEYUP);

        Dispatch(inputs);
    }

    /// <summary>
    /// Simulates Right Arrow to deselect and move cursor right
    /// </summary>
    public static void SendRight()
    {
        SendKey(VK_RIGHT, extended: true);
    }

    // MARK: - Private Methods

    private static void Dispatch(INPUT[] inputs)
    {
        var sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
        if (sent != inputs.Length)
        {
            System.Diagnostics.Debug.WriteLine(
                $"SendInput injected {sent}/{inputs.Length} events (error {Marshal.GetLastWin32Error()})");
        }
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
