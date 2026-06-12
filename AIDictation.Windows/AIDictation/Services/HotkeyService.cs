using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using AIDictation.Models;
using NHotkey;
using NHotkey.Wpf;

namespace AIDictation.Services;

/// <summary>
/// Manages global hotkey registration and push-to-talk functionality for dictation modes.
/// Supports both keyboard hotkeys and mouse buttons with key down/up detection.
/// </summary>
public sealed class HotkeyService : IDisposable
{
    // MARK: - Singleton

    private static readonly Lazy<HotkeyService> _instance = new(() => new HotkeyService());
    public static HotkeyService Instance => _instance.Value;

    // MARK: - Events

    /// <summary>Fired when dictation hotkey is pressed down</summary>
    public event EventHandler? DictationHotkeyPressed;

    /// <summary>Fired when dictation hotkey is released (for push-to-talk)</summary>
    public event EventHandler? DictationHotkeyReleased;

    /// <summary>Fired when command mode hotkey is pressed down</summary>
    public event EventHandler? CommandHotkeyPressed;

    /// <summary>Fired when command mode hotkey is released (for push-to-talk)</summary>
    public event EventHandler? CommandHotkeyReleased;

    /// <summary>Fired when a hotkey registration fails due to conflict</summary>
    public event EventHandler<HotkeyConflictEventArgs>? HotkeyConflictDetected;

    // MARK: - Types

    public class HotkeyConflictEventArgs : EventArgs
    {
        public string HotkeyName { get; }
        public Hotkey Hotkey { get; }
        public string? ErrorMessage { get; }

        public HotkeyConflictEventArgs(string name, Hotkey hotkey, string? errorMessage = null)
        {
            HotkeyName = name;
            Hotkey = hotkey;
            ErrorMessage = errorMessage;
        }
    }

    // MARK: - Constants

    private static class HotkeyNames
    {
        public const string Dictation = "AIDictation_Dictation";
        public const string Command = "AIDictation_Command";
    }

    private static class WinApi
    {
        public const int WH_KEYBOARD_LL = 13;
        public const int WH_MOUSE_LL = 14;
        public const int WM_KEYDOWN = 0x0100;
        public const int WM_KEYUP = 0x0101;
        public const int WM_SYSKEYDOWN = 0x0104;
        public const int WM_SYSKEYUP = 0x0105;
        public const int WM_MBUTTONDOWN = 0x0207;
        public const int WM_MBUTTONUP = 0x0208;
        public const int WM_XBUTTONDOWN = 0x020B;
        public const int WM_XBUTTONUP = 0x020C;

        public delegate IntPtr LowLevelProc(int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        public static extern IntPtr SetWindowsHookEx(int idHook, LowLevelProc lpfn, IntPtr hMod, uint dwThreadId);

        [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool UnhookWindowsHookEx(IntPtr hhk);

        [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        public static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        public static extern IntPtr GetModuleHandle(string? lpModuleName);

        [DllImport("user32.dll")]
        public static extern short GetAsyncKeyState(int vKey);

        [StructLayout(LayoutKind.Sequential)]
        public struct KBDLLHOOKSTRUCT
        {
            public uint vkCode;
            public uint scanCode;
            public uint flags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct MSLLHOOKSTRUCT
        {
            public Point pt;
            public uint mouseData;
            public uint flags;
            public uint time;
            public IntPtr dwExtraInfo;
        }
    }

    // MARK: - Private Properties

    private Hotkey? _dictationHotkey;
    private Hotkey? _commandHotkey;
    private bool _dictationKeyDown;
    private bool _commandKeyDown;
    private bool _disposed;

    private IntPtr _keyboardHookId = IntPtr.Zero;
    private IntPtr _mouseHookId = IntPtr.Zero;
    private WinApi.LowLevelProc? _keyboardProc;
    private WinApi.LowLevelProc? _mouseProc;

    // MARK: - Initialization

    private HotkeyService()
    {
        _keyboardProc = KeyboardHookCallback;
        _mouseProc = MouseHookCallback;
    }

    // MARK: - Public API

    /// <summary>
    /// Registers hotkeys for dictation and command modes.
    /// </summary>
    public void RegisterHotkeys(Hotkey? dictationHotkey, Hotkey? commandHotkey)
    {
        UnregisterAllHotkeys();

        _dictationHotkey = dictationHotkey;
        _commandHotkey = commandHotkey;

        var needsKeyboardHook = false;
        var needsMouseHook = false;

        // Register dictation hotkey
        if (dictationHotkey != null)
        {
            if (dictationHotkey.IsMouseButton)
            {
                needsMouseHook = true;
            }
            else if (dictationHotkey.Key != Key.None)
            {
                needsKeyboardHook = true;
                RegisterKeyboardHotkey(HotkeyNames.Dictation, dictationHotkey, OnDictationHotkeyPressed);
            }
            else
            {
                // A modifier-only keyboard hotkey can never be registered or
                // matched on release; surface it instead of silently ignoring.
                HotkeyConflictDetected?.Invoke(this, new HotkeyConflictEventArgs(
                    HotkeyNames.Dictation, dictationHotkey, "The hotkey needs a non-modifier key"));
            }
        }

        // Register command hotkey
        if (commandHotkey != null)
        {
            if (commandHotkey.IsMouseButton)
            {
                needsMouseHook = true;
            }
            else if (commandHotkey.Key != Key.None)
            {
                needsKeyboardHook = true;
                RegisterKeyboardHotkey(HotkeyNames.Command, commandHotkey, OnCommandHotkeyPressed);
            }
            else
            {
                HotkeyConflictDetected?.Invoke(this, new HotkeyConflictEventArgs(
                    HotkeyNames.Command, commandHotkey, "The hotkey needs a non-modifier key"));
            }
        }

        // Install low-level hooks if needed for push-to-talk detection
        if (needsKeyboardHook)
        {
            InstallKeyboardHook();
        }

        if (needsMouseHook)
        {
            InstallMouseHook();
        }
    }

    /// <summary>
    /// Updates only the dictation hotkey.
    /// </summary>
    public void UpdateDictationHotkey(Hotkey? hotkey)
    {
        RegisterHotkeys(hotkey, _commandHotkey);
    }

    /// <summary>
    /// Updates only the command hotkey.
    /// </summary>
    public void UpdateCommandHotkey(Hotkey? hotkey)
    {
        RegisterHotkeys(_dictationHotkey, hotkey);
    }

    /// <summary>
    /// Unregisters all hotkeys and removes hooks.
    /// </summary>
    public void UnregisterAllHotkeys()
    {
        try
        {
            HotkeyManager.Current.Remove(HotkeyNames.Dictation);
        }
        catch { /* Hotkey may not be registered */ }

        try
        {
            HotkeyManager.Current.Remove(HotkeyNames.Command);
        }
        catch { /* Hotkey may not be registered */ }

        RemoveKeyboardHook();
        RemoveMouseHook();

        _dictationKeyDown = false;
        _commandKeyDown = false;
    }

    /// <summary>
    /// Checks if the given hotkey conflicts with an already registered system hotkey.
    /// </summary>
    public bool IsHotkeyAvailable(Hotkey hotkey)
    {
        if (hotkey.IsMouseButton)
            return true; // Mouse buttons don't conflict with system hotkeys

        if (hotkey.Key == Key.None)
            return false;

        try
        {
            const string testName = "AIDictation_Test";
            HotkeyManager.Current.AddOrReplace(testName, hotkey.Key, hotkey.Modifiers, (_, _) => { });
            HotkeyManager.Current.Remove(testName);
            return true;
        }
        catch
        {
            return false;
        }
    }

    // MARK: - Private Methods

    private void RegisterKeyboardHotkey(string name, Hotkey hotkey, EventHandler<HotkeyEventArgs> handler)
    {
        try
        {
            HotkeyManager.Current.AddOrReplace(name, hotkey.Key, hotkey.Modifiers, handler);
        }
        catch (HotkeyAlreadyRegisteredException ex)
        {
            HotkeyConflictDetected?.Invoke(this, new HotkeyConflictEventArgs(name, hotkey, ex.Message));
        }
        catch (Exception ex)
        {
            HotkeyConflictDetected?.Invoke(this, new HotkeyConflictEventArgs(name, hotkey, ex.Message));
        }
    }

    private void OnDictationHotkeyPressed(object? sender, HotkeyEventArgs e)
    {
        e.Handled = true;
        if (!_dictationKeyDown)
        {
            _dictationKeyDown = true;
            DictationHotkeyPressed?.Invoke(this, EventArgs.Empty);
        }
    }

    private void OnCommandHotkeyPressed(object? sender, HotkeyEventArgs e)
    {
        e.Handled = true;
        if (!_commandKeyDown)
        {
            _commandKeyDown = true;
            CommandHotkeyPressed?.Invoke(this, EventArgs.Empty);
        }
    }

    private void InstallKeyboardHook()
    {
        if (_keyboardHookId != IntPtr.Zero)
            return;

        using var curProcess = System.Diagnostics.Process.GetCurrentProcess();
        using var curModule = curProcess.MainModule;
        _keyboardHookId = WinApi.SetWindowsHookEx(
            WinApi.WH_KEYBOARD_LL,
            _keyboardProc!,
            WinApi.GetModuleHandle(curModule?.ModuleName),
            0);
    }

    private void RemoveKeyboardHook()
    {
        if (_keyboardHookId != IntPtr.Zero)
        {
            WinApi.UnhookWindowsHookEx(_keyboardHookId);
            _keyboardHookId = IntPtr.Zero;
        }
    }

    private void InstallMouseHook()
    {
        if (_mouseHookId != IntPtr.Zero)
            return;

        using var curProcess = System.Diagnostics.Process.GetCurrentProcess();
        using var curModule = curProcess.MainModule;
        _mouseHookId = WinApi.SetWindowsHookEx(
            WinApi.WH_MOUSE_LL,
            _mouseProc!,
            WinApi.GetModuleHandle(curModule?.ModuleName),
            0);
    }

    private void RemoveMouseHook()
    {
        if (_mouseHookId != IntPtr.Zero)
        {
            WinApi.UnhookWindowsHookEx(_mouseHookId);
            _mouseHookId = IntPtr.Zero;
        }
    }

    private IntPtr KeyboardHookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            var hookStruct = Marshal.PtrToStructure<WinApi.KBDLLHOOKSTRUCT>(lParam);
            var key = KeyInterop.KeyFromVirtualKey((int)hookStruct.vkCode);
            var modifiers = GetCurrentModifiers();

            var isKeyDown = wParam == (IntPtr)WinApi.WM_KEYDOWN || wParam == (IntPtr)WinApi.WM_SYSKEYDOWN;
            var isKeyUp = wParam == (IntPtr)WinApi.WM_KEYUP || wParam == (IntPtr)WinApi.WM_SYSKEYUP;

            // Check dictation hotkey release
            if (_dictationHotkey != null && !_dictationHotkey.IsMouseButton && _dictationKeyDown)
            {
                if (isKeyUp && IsHotkeyMatch(_dictationHotkey, key, modifiers, isKeyUp: true))
                {
                    _dictationKeyDown = false;
                    Application.Current?.Dispatcher.BeginInvoke(() =>
                        DictationHotkeyReleased?.Invoke(this, EventArgs.Empty));
                }
            }

            // Check command hotkey release
            if (_commandHotkey != null && !_commandHotkey.IsMouseButton && _commandKeyDown)
            {
                if (isKeyUp && IsHotkeyMatch(_commandHotkey, key, modifiers, isKeyUp: true))
                {
                    _commandKeyDown = false;
                    Application.Current?.Dispatcher.BeginInvoke(() =>
                        CommandHotkeyReleased?.Invoke(this, EventArgs.Empty));
                }
            }
        }

        return WinApi.CallNextHookEx(_keyboardHookId, nCode, wParam, lParam);
    }

    private IntPtr MouseHookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            var hookStruct = Marshal.PtrToStructure<WinApi.MSLLHOOKSTRUCT>(lParam);
            int? mouseButton = null;
            var isDown = false;
            var isUp = false;

            switch ((int)wParam)
            {
                case WinApi.WM_MBUTTONDOWN:
                    mouseButton = 2;
                    isDown = true;
                    break;
                case WinApi.WM_MBUTTONUP:
                    mouseButton = 2;
                    isUp = true;
                    break;
                case WinApi.WM_XBUTTONDOWN:
                    mouseButton = GetXButton(hookStruct.mouseData);
                    isDown = true;
                    break;
                case WinApi.WM_XBUTTONUP:
                    mouseButton = GetXButton(hookStruct.mouseData);
                    isUp = true;
                    break;
            }

            if (mouseButton.HasValue)
            {
                // Check dictation hotkey (mouse)
                if (_dictationHotkey?.MouseButton == mouseButton)
                {
                    if (isDown && !_dictationKeyDown)
                    {
                        _dictationKeyDown = true;
                        Application.Current?.Dispatcher.BeginInvoke(() =>
                            DictationHotkeyPressed?.Invoke(this, EventArgs.Empty));
                    }
                    else if (isUp && _dictationKeyDown)
                    {
                        _dictationKeyDown = false;
                        Application.Current?.Dispatcher.BeginInvoke(() =>
                            DictationHotkeyReleased?.Invoke(this, EventArgs.Empty));
                    }
                }

                // Check command hotkey (mouse)
                if (_commandHotkey?.MouseButton == mouseButton)
                {
                    if (isDown && !_commandKeyDown)
                    {
                        _commandKeyDown = true;
                        Application.Current?.Dispatcher.BeginInvoke(() =>
                            CommandHotkeyPressed?.Invoke(this, EventArgs.Empty));
                    }
                    else if (isUp && _commandKeyDown)
                    {
                        _commandKeyDown = false;
                        Application.Current?.Dispatcher.BeginInvoke(() =>
                            CommandHotkeyReleased?.Invoke(this, EventArgs.Empty));
                    }
                }
            }
        }

        return WinApi.CallNextHookEx(_mouseHookId, nCode, wParam, lParam);
    }

    private static int GetXButton(uint mouseData)
    {
        // XBUTTON1 = 1, XBUTTON2 = 2 in high word
        var button = (mouseData >> 16) & 0xFFFF;
        return button == 1 ? 3 : 4; // Map to our button numbers
    }

    private static ModifierKeys GetCurrentModifiers()
    {
        // Keyboard.Modifiers reads WPF's cached input state, which lags behind
        // events arriving in a low-level hook callback; query the live key
        // state instead so modifier matching stays accurate during press/release.
        var modifiers = ModifierKeys.None;

        if (IsKeyDown(0x11)) modifiers |= ModifierKeys.Control; // VK_CONTROL
        if (IsKeyDown(0x10)) modifiers |= ModifierKeys.Shift;   // VK_SHIFT
        if (IsKeyDown(0x12)) modifiers |= ModifierKeys.Alt;     // VK_MENU
        if (IsKeyDown(0x5B) || IsKeyDown(0x5C)) modifiers |= ModifierKeys.Windows;

        return modifiers;
    }

    private static bool IsKeyDown(int vKey) => (WinApi.GetAsyncKeyState(vKey) & 0x8000) != 0;

    private static bool IsHotkeyMatch(Hotkey hotkey, Key key, ModifierKeys modifiers, bool isKeyUp)
    {
        // For key up, we only check the main key since modifiers may already be released
        if (isKeyUp)
            return hotkey.Key == key;

        return hotkey.Key == key && hotkey.Modifiers == modifiers;
    }

    // MARK: - IDisposable

    public void Dispose()
    {
        if (_disposed)
            return;

        UnregisterAllHotkeys();
        _disposed = true;
    }
}
