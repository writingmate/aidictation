<#
.SYNOPSIS
    Diagnostic test for text insertion failures with multiple approaches.
    
.DESCRIPTION
    This script tests multiple methods of inserting text to identify which
    approach works or fails:
    1. SendInput Ctrl+V (current app approach)
    2. SendInput with explicit scan codes
    3. SendInput with modifier key releases first
    4. Direct Unicode character injection
    5. keybd_event Ctrl+V
    6. SendKeys (WScript.Shell)
    
    This helps identify whether the failure is:
    - All synthetic input blocked (security software)
    - Only Ctrl+V blocked (keyboard shortcut policy)
    - Only SendInput blocked (but keybd_event works)
    - Focus/timing issue

.PARAMETER OutDir
    Directory for diagnostic output

.EXAMPLE
    .\repro-insert-diagnostic.ps1 -OutDir .\artifacts\diag
#>
param(
    [Parameter(Mandatory = $true)][string]$OutDir
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class InputDiag {
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    
    [DllImport("user32.dll")]
    public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    
    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();
    
    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);
    
    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    
    [DllImport("user32.dll")]
    public static extern IntPtr GetMessageExtraInfo();
    
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);
    
    [DllImport("user32.dll")]
    public static extern short GetKeyState(int nVirtKey);
    
    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    
    [DllImport("user32.dll")]
    public static extern uint MapVirtualKey(uint uCode, uint uMapType);
    
    public const int INPUT_KEYBOARD = 1;
    public const uint KEYEVENTF_KEYUP = 0x0002;
    public const uint KEYEVENTF_UNICODE = 0x0004;
    public const uint KEYEVENTF_SCANCODE = 0x0008;
    public const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
    
    public const ushort VK_CONTROL = 0x11;
    public const ushort VK_SHIFT = 0x10;
    public const ushort VK_MENU = 0x12;
    public const ushort VK_V = 0x56;
    public const ushort VK_LCONTROL = 0xA2;
    public const ushort VK_RCONTROL = 0xA3;
    
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT {
        public int type;
        public INPUTUNION u;
    }
    
    [StructLayout(LayoutKind.Explicit)]
    public struct INPUTUNION {
        [FieldOffset(0)]
        public MOUSEINPUT mi;
        [FieldOffset(0)]
        public KEYBDINPUT ki;
    }
    
    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }
    
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }
    
    // Method 1: SendInput Ctrl+V (current app implementation)
    public static uint SendPasteBasic() {
        var inputs = new INPUT[4];
        var size = Marshal.SizeOf<INPUT>();
        var extra = GetMessageExtraInfo();
        
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].u.ki.wVk = VK_CONTROL;
        inputs[0].u.ki.dwFlags = 0;
        inputs[0].u.ki.dwExtraInfo = extra;
        
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].u.ki.wVk = VK_V;
        inputs[1].u.ki.dwFlags = 0;
        inputs[1].u.ki.dwExtraInfo = extra;
        
        inputs[2].type = INPUT_KEYBOARD;
        inputs[2].u.ki.wVk = VK_V;
        inputs[2].u.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[2].u.ki.dwExtraInfo = extra;
        
        inputs[3].type = INPUT_KEYBOARD;
        inputs[3].u.ki.wVk = VK_CONTROL;
        inputs[3].u.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[3].u.ki.dwExtraInfo = extra;
        
        return SendInput(4, inputs, size);
    }
    
    // Method 2: SendInput with explicit scan codes
    public static uint SendPasteWithScanCodes() {
        var inputs = new INPUT[4];
        var size = Marshal.SizeOf<INPUT>();
        var extra = GetMessageExtraInfo();
        
        ushort ctrlScan = (ushort)MapVirtualKey(VK_CONTROL, 0);
        ushort vScan = (ushort)MapVirtualKey(VK_V, 0);
        
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].u.ki.wVk = VK_CONTROL;
        inputs[0].u.ki.wScan = ctrlScan;
        inputs[0].u.ki.dwFlags = KEYEVENTF_SCANCODE;
        inputs[0].u.ki.dwExtraInfo = extra;
        
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].u.ki.wVk = VK_V;
        inputs[1].u.ki.wScan = vScan;
        inputs[1].u.ki.dwFlags = KEYEVENTF_SCANCODE;
        inputs[1].u.ki.dwExtraInfo = extra;
        
        inputs[2].type = INPUT_KEYBOARD;
        inputs[2].u.ki.wVk = VK_V;
        inputs[2].u.ki.wScan = vScan;
        inputs[2].u.ki.dwFlags = KEYEVENTF_SCANCODE | KEYEVENTF_KEYUP;
        inputs[2].u.ki.dwExtraInfo = extra;
        
        inputs[3].type = INPUT_KEYBOARD;
        inputs[3].u.ki.wVk = VK_CONTROL;
        inputs[3].u.ki.wScan = ctrlScan;
        inputs[3].u.ki.dwFlags = KEYEVENTF_SCANCODE | KEYEVENTF_KEYUP;
        inputs[3].u.ki.dwExtraInfo = extra;
        
        return SendInput(4, inputs, size);
    }
    
    // Method 3: Release all modifiers first, then Ctrl+V
    public static uint SendPasteWithModifierRelease() {
        // First release any stuck modifiers
        var releases = new INPUT[6];
        var size = Marshal.SizeOf<INPUT>();
        var extra = GetMessageExtraInfo();
        
        // Release Ctrl, Shift, Alt
        releases[0].type = INPUT_KEYBOARD;
        releases[0].u.ki.wVk = VK_CONTROL;
        releases[0].u.ki.dwFlags = KEYEVENTF_KEYUP;
        releases[0].u.ki.dwExtraInfo = extra;
        
        releases[1].type = INPUT_KEYBOARD;
        releases[1].u.ki.wVk = VK_SHIFT;
        releases[1].u.ki.dwFlags = KEYEVENTF_KEYUP;
        releases[1].u.ki.dwExtraInfo = extra;
        
        releases[2].type = INPUT_KEYBOARD;
        releases[2].u.ki.wVk = VK_MENU;
        releases[2].u.ki.dwFlags = KEYEVENTF_KEYUP;
        releases[2].u.ki.dwExtraInfo = extra;
        
        releases[3].type = INPUT_KEYBOARD;
        releases[3].u.ki.wVk = VK_LCONTROL;
        releases[3].u.ki.dwFlags = KEYEVENTF_KEYUP;
        releases[3].u.ki.dwExtraInfo = extra;
        
        releases[4].type = INPUT_KEYBOARD;
        releases[4].u.ki.wVk = VK_RCONTROL;
        releases[4].u.ki.dwFlags = KEYEVENTF_KEYUP;
        releases[4].u.ki.dwExtraInfo = extra;
        
        releases[5].type = INPUT_KEYBOARD;
        releases[5].u.ki.wVk = 0x77; // F8
        releases[5].u.ki.dwFlags = KEYEVENTF_KEYUP;
        releases[5].u.ki.dwExtraInfo = extra;
        
        SendInput(6, releases, size);
        System.Threading.Thread.Sleep(50);
        
        // Now send Ctrl+V
        return SendPasteBasic();
    }
    
    // Method 4: Direct Unicode character injection (bypasses Ctrl+V entirely)
    public static uint SendUnicodeText(string text) {
        var inputs = new INPUT[text.Length * 2];
        var size = Marshal.SizeOf<INPUT>();
        
        for (int i = 0; i < text.Length; i++) {
            // Key down
            inputs[i * 2].type = INPUT_KEYBOARD;
            inputs[i * 2].u.ki.wVk = 0;
            inputs[i * 2].u.ki.wScan = (ushort)text[i];
            inputs[i * 2].u.ki.dwFlags = KEYEVENTF_UNICODE;
            inputs[i * 2].u.ki.time = 0;
            inputs[i * 2].u.ki.dwExtraInfo = IntPtr.Zero;
            
            // Key up
            inputs[i * 2 + 1].type = INPUT_KEYBOARD;
            inputs[i * 2 + 1].u.ki.wVk = 0;
            inputs[i * 2 + 1].u.ki.wScan = (ushort)text[i];
            inputs[i * 2 + 1].u.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
            inputs[i * 2 + 1].u.ki.time = 0;
            inputs[i * 2 + 1].u.ki.dwExtraInfo = IntPtr.Zero;
        }
        
        return SendInput((uint)inputs.Length, inputs, size);
    }
    
    // Method 5: keybd_event Ctrl+V
    public static void SendPasteKeybd() {
        keybd_event(0x11, 0, 0, UIntPtr.Zero);  // Ctrl down
        System.Threading.Thread.Sleep(10);
        keybd_event(0x56, 0, 0, UIntPtr.Zero);  // V down
        System.Threading.Thread.Sleep(10);
        keybd_event(0x56, 0, 2, UIntPtr.Zero);  // V up
        keybd_event(0x11, 0, 2, UIntPtr.Zero);  // Ctrl up
    }
    
    public static bool IsModifierDown(ushort vk) {
        return (GetAsyncKeyState(vk) & 0x8000) != 0;
    }
    
    public static bool TryFocusWindow(IntPtr hWnd) {
        if (GetForegroundWindow() == hWnd)
            return true;
        
        uint processId;
        var targetThread = GetWindowThreadProcessId(hWnd, out processId);
        var currentThread = GetCurrentThreadId();
        
        bool attached = targetThread != 0 && targetThread != currentThread &&
                        AttachThreadInput(currentThread, targetThread, true);
        
        bool requested;
        try {
            requested = SetForegroundWindow(hWnd);
        } finally {
            if (attached) {
                AttachThreadInput(currentThread, targetThread, false);
            }
        }
        
        return requested;
    }
}
"@

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$script:notepadProc = $null
$results = @{}

function Read-NotepadText {
    $text = ""
    try {
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($script:notepadProc.MainWindowHandle)
        foreach ($ct in @([System.Windows.Automation.ControlType]::Document, [System.Windows.Automation.ControlType]::Edit)) {
            $cond = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty, $ct)
            $el = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
            if ($el) {
                try {
                    $tp = $el.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
                    $text = $tp.DocumentRange.GetText(100000)
                } catch {
                    try {
                        $vp = $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
                        $text = $vp.Current.Value
                    } catch { }
                }
                if ($text) { break }
            }
        }
    } catch { Write-Host "  UIA read failed: $_" }
    return $text.Trim()
}

function Clear-Notepad {
    # Select all and delete
    [InputDiag]::TryFocusWindow($script:notepadProc.MainWindowHandle) | Out-Null
    Start-Sleep -Milliseconds 100
    [System.Windows.Forms.SendKeys]::SendWait("^a")
    Start-Sleep -Milliseconds 50
    [System.Windows.Forms.SendKeys]::SendWait("{DELETE}")
    Start-Sleep -Milliseconds 100
}

function Test-Method([string]$Name, [string]$TestText, [scriptblock]$Action) {
    Write-Host ""
    Write-Host "=== Testing: $Name ==="
    
    Clear-Notepad
    [System.Windows.Forms.Clipboard]::SetText($TestText)
    Start-Sleep -Milliseconds 50
    
    [InputDiag]::TryFocusWindow($script:notepadProc.MainWindowHandle) | Out-Null
    Start-Sleep -Milliseconds 150
    
    $fg = [InputDiag]::GetForegroundWindow()
    Write-Host "  Foreground before: $fg (target: $($script:notepadProc.MainWindowHandle))"
    
    & $Action
    
    Start-Sleep -Milliseconds 300
    
    $fg = [InputDiag]::GetForegroundWindow()
    Write-Host "  Foreground after: $fg"
    
    $content = Read-NotepadText
    $success = $content -match [regex]::Escape($TestText)
    
    Write-Host "  Expected: $TestText"
    Write-Host "  Got: $content"
    Write-Host "  Result: $(if($success){'PASS'}else{'FAIL'})"
    
    $script:results[$Name] = @{
        Success = $success
        Expected = $TestText
        Got = $content
    }
    
    return $success
}

function Stop-Procs {
    if ($script:notepadProc -and -not $script:notepadProc.HasExited) {
        Stop-Process -Id $script:notepadProc.Id -Force -ErrorAction SilentlyContinue
    }
}

try {
    Write-Host "=== AIDictation Insert Diagnostic ==="
    Write-Host "Testing multiple input injection methods..."
    Write-Host ""
    
    # Check modifier state
    $ctrlDown = [InputDiag]::IsModifierDown([InputDiag]::VK_CONTROL)
    $shiftDown = [InputDiag]::IsModifierDown([InputDiag]::VK_SHIFT)
    $altDown = [InputDiag]::IsModifierDown([InputDiag]::VK_MENU)
    Write-Host "Initial modifier state: Ctrl=$ctrlDown Shift=$shiftDown Alt=$altDown"
    
    # Open Notepad
    Write-Host "[Setup] Opening Notepad..."
    $script:notepadProc = Start-Process notepad -PassThru
    Start-Sleep -Seconds 2
    $script:notepadProc.Refresh()
    
    if ($script:notepadProc.HasExited) {
        throw "Notepad failed to start"
    }
    
    $targetHwnd = $script:notepadProc.MainWindowHandle
    Write-Host "  Notepad HWND: $targetHwnd"
    
    # Test 1: Current app implementation (SendInput basic)
    Test-Method "SendInput_Basic" "TEST_BASIC" {
        $sent = [InputDiag]::SendPasteBasic()
        Write-Host "  SendInput returned: $sent/4"
    }
    
    # Test 2: SendInput with scan codes
    Test-Method "SendInput_ScanCodes" "TEST_SCAN" {
        $sent = [InputDiag]::SendPasteWithScanCodes()
        Write-Host "  SendInput returned: $sent/4"
    }
    
    # Test 3: Release modifiers first
    Test-Method "SendInput_ModRelease" "TEST_MODREL" {
        $sent = [InputDiag]::SendPasteWithModifierRelease()
        Write-Host "  SendInput returned: $sent/4"
    }
    
    # Test 4: Direct Unicode injection (no clipboard)
    Test-Method "Unicode_Direct" "UNICODE_TEST" {
        Clear-Notepad
        [InputDiag]::TryFocusWindow($script:notepadProc.MainWindowHandle) | Out-Null
        Start-Sleep -Milliseconds 150
        $sent = [InputDiag]::SendUnicodeText("UNICODE_TEST")
        Write-Host "  SendInput returned: $sent/22"
    }
    
    # Test 5: keybd_event
    Test-Method "KeybdEvent" "TEST_KEYBD" {
        [InputDiag]::SendPasteKeybd()
    }
    
    # Test 6: SendKeys (WScript.Shell approach)
    Test-Method "SendKeys" "TEST_SENDKEYS" {
        [System.Windows.Forms.SendKeys]::SendWait("^v")
    }
    
    # Summary
    Write-Host ""
    Write-Host "=== SUMMARY ==="
    $anySuccess = $false
    foreach ($name in $results.Keys) {
        $r = $results[$name]
        $status = if ($r.Success) { "PASS" } else { "FAIL" }
        Write-Host "$name : $status"
        if ($r.Success) { $anySuccess = $true }
    }
    
    Write-Host ""
    if ($anySuccess) {
        Write-Host "At least one method works. The issue may be specific to our SendInput implementation."
        exit 0
    }
    else {
        Write-Host "ALL methods failed. This is an environmental issue:"
        Write-Host "  - Headless CI runner (no real input queue)"
        Write-Host "  - Security software blocking synthetic input"
        Write-Host "  - Windows policy restricting input injection"
        exit 1
    }
}
finally {
    Stop-Procs
    
    # Write results to file
    $results | ConvertTo-Json -Depth 3 | Out-File (Join-Path $OutDir "results.json")
}
