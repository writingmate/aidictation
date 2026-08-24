<#
.SYNOPSIS
    Runs the insert test in an interactive desktop session.
    
.DESCRIPTION
    GitHub Actions typically runs in session 0 (service session). This script
    ensures we run in an interactive session with a real desktop.
    
    Approaches tried:
    1. Check if we're already in an interactive session
    2. Use PsExec -i to run in the interactive session
    3. Use a Scheduled Task with INTERACTIVE logon type
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
using System.Text;

public static class SessionInfo {
    [DllImport("kernel32.dll")]
    public static extern uint WTSGetActiveConsoleSessionId();
    
    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentProcessId();
    
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool ProcessIdToSessionId(uint dwProcessId, out uint pSessionId);
    
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
    public static extern uint MapVirtualKey(uint uCode, uint uMapType);
    
    [DllImport("user32.dll")]
    public static extern IntPtr GetDesktopWindow();
    
    [DllImport("user32.dll")]
    public static extern IntPtr OpenInputDesktop(uint dwFlags, bool fInherit, uint dwDesiredAccess);
    
    [DllImport("user32.dll")]
    public static extern bool CloseDesktop(IntPtr hDesktop);
    
    [DllImport("user32.dll")]
    public static extern bool SetThreadDesktop(IntPtr hDesktop);
    
    [DllImport("user32.dll")]
    public static extern IntPtr GetThreadDesktop(uint dwThreadId);
    
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern bool GetUserObjectInformation(IntPtr hObj, int nIndex, StringBuilder pvInfo, int nLength, out int lpnLengthNeeded);
    
    public const int INPUT_KEYBOARD = 1;
    public const uint KEYEVENTF_KEYUP = 0x0002;
    public const ushort VK_CONTROL = 0x11;
    public const ushort VK_V = 0x56;
    
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
    
    public static uint GetCurrentSessionId() {
        uint sessionId;
        ProcessIdToSessionId(GetCurrentProcessId(), out sessionId);
        return sessionId;
    }
    
    public static string GetCurrentDesktopName() {
        IntPtr hDesk = GetThreadDesktop(GetCurrentThreadId());
        if (hDesk == IntPtr.Zero) return "unknown";
        
        StringBuilder name = new StringBuilder(256);
        int needed;
        if (GetUserObjectInformation(hDesk, 2, name, 256, out needed)) {
            return name.ToString();
        }
        return "unknown";
    }
    
    public static bool TryAttachToInputDesktop() {
        IntPtr hDesk = OpenInputDesktop(0, false, 0x0100 | 0x0080 | 0x0040); // DESKTOP_READOBJECTS | DESKTOP_CREATEWINDOW | DESKTOP_CREATEMENU
        if (hDesk == IntPtr.Zero) return false;
        
        bool result = SetThreadDesktop(hDesk);
        CloseDesktop(hDesk);
        return result;
    }
    
    public static uint SendPaste() {
        var inputs = new INPUT[4];
        var size = Marshal.SizeOf<INPUT>();
        var extra = GetMessageExtraInfo();
        
        ushort ctrlScan = (ushort)MapVirtualKey(VK_CONTROL, 0);
        ushort vScan = (ushort)MapVirtualKey(VK_V, 0);
        
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].u.ki.wVk = VK_CONTROL;
        inputs[0].u.ki.wScan = ctrlScan;
        inputs[0].u.ki.dwFlags = 0;
        inputs[0].u.ki.dwExtraInfo = extra;
        
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].u.ki.wVk = VK_V;
        inputs[1].u.ki.wScan = vScan;
        inputs[1].u.ki.dwFlags = 0;
        inputs[1].u.ki.dwExtraInfo = extra;
        
        inputs[2].type = INPUT_KEYBOARD;
        inputs[2].u.ki.wVk = VK_V;
        inputs[2].u.ki.wScan = vScan;
        inputs[2].u.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[2].u.ki.dwExtraInfo = extra;
        
        inputs[3].type = INPUT_KEYBOARD;
        inputs[3].u.ki.wVk = VK_CONTROL;
        inputs[3].u.ki.wScan = ctrlScan;
        inputs[3].u.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[3].u.ki.dwExtraInfo = extra;
        
        return SendInput(4, inputs, size);
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
$testText = "INTERACTIVE_TEST_$(Get-Date -Format 'HHmmss')"

function Take-Screenshot([string]$Name) {
    try {
        Add-Type -AssemblyName System.Drawing
        $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
        if ($bounds.Width -eq 0 -or $bounds.Height -eq 0) {
            Write-Host "  Screenshot $Name skipped - no virtual screen"
            return
        }
        $bmp = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
        $gfx = [System.Drawing.Graphics]::FromImage($bmp)
        $gfx.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bmp.Size)
        $bmp.Save((Join-Path $OutDir "$Name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
        $gfx.Dispose(); $bmp.Dispose()
        Write-Host "  Screenshot: $Name.png"
    } catch { Write-Host "  Screenshot $Name failed: $_" }
}

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

function Stop-Procs {
    if ($script:notepadProc -and -not $script:notepadProc.HasExited) {
        Stop-Process -Id $script:notepadProc.Id -Force -ErrorAction SilentlyContinue
    }
}

try {
    Write-Host "=== Interactive Insert Test ==="
    Write-Host ""
    
    # Session diagnostics
    Write-Host "[Session Info]"
    $currentSession = [SessionInfo]::GetCurrentSessionId()
    $consoleSession = [SessionInfo]::WTSGetActiveConsoleSessionId()
    $desktopName = [SessionInfo]::GetCurrentDesktopName()
    
    Write-Host "  Current session ID: $currentSession"
    Write-Host "  Console session ID: $consoleSession"
    Write-Host "  Current desktop: $desktopName"
    Write-Host "  Running as: $env:USERNAME"
    Write-Host ""
    
    # Check if we're in an interactive session
    $isInteractive = $currentSession -eq $consoleSession -or $currentSession -ne 0
    Write-Host "  Interactive session: $isInteractive"
    
    # Try to attach to the input desktop
    Write-Host ""
    Write-Host "[Attaching to input desktop...]"
    $attached = [SessionInfo]::TryAttachToInputDesktop()
    Write-Host "  Attached: $attached"
    
    # Check desktop window
    $desktopWindow = [SessionInfo]::GetDesktopWindow()
    Write-Host "  Desktop window: $desktopWindow"
    
    Write-Host ""
    Write-Host "[1] Opening Notepad..."
    $script:notepadProc = Start-Process notepad -PassThru
    Start-Sleep -Seconds 3
    $script:notepadProc.Refresh()
    
    if ($script:notepadProc.HasExited) {
        throw "Notepad failed to start or exited immediately"
    }
    
    $targetHwnd = $script:notepadProc.MainWindowHandle
    Write-Host "  Notepad PID: $($script:notepadProc.Id)"
    Write-Host "  Notepad HWND: $targetHwnd"
    
    if ($targetHwnd -eq 0) {
        Write-Host "  WARNING: No window handle - Notepad may not have a visible window"
    }
    
    Take-Screenshot "01-notepad-opened"
    
    Write-Host ""
    Write-Host "[2] Setting clipboard..."
    [System.Windows.Forms.Clipboard]::SetText($testText)
    Start-Sleep -Milliseconds 100
    $clipContent = [System.Windows.Forms.Clipboard]::GetText()
    Write-Host "  Clipboard: $clipContent"
    
    if ($clipContent -ne $testText) {
        throw "Clipboard write failed"
    }
    
    Write-Host ""
    Write-Host "[3] Focusing Notepad..."
    $focusResult = [SessionInfo]::TryFocusWindow($targetHwnd)
    Write-Host "  Focus result: $focusResult"
    Start-Sleep -Milliseconds 200
    
    $fg = [SessionInfo]::GetForegroundWindow()
    Write-Host "  Foreground window: $fg (target: $targetHwnd)"
    
    Take-Screenshot "02-before-paste"
    
    Write-Host ""
    Write-Host "[4] Sending Ctrl+V..."
    $sendResult = [SessionInfo]::SendPaste()
    $lastError = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    Write-Host "  SendInput result: $sendResult/4 (error: $lastError)"
    
    Start-Sleep -Milliseconds 500
    Take-Screenshot "03-after-paste"
    
    Write-Host ""
    Write-Host "[5] Reading Notepad content..."
    $notepadContent = Read-NotepadText
    Write-Host "  Content: '$notepadContent'"
    
    Take-Screenshot "04-final"
    
    # Write results to a text file for easy reading
    $resultFile = Join-Path $OutDir "test-results.txt"
    $results = @"
=== AIDictation Interactive Insert Test Results ===
Timestamp: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

[Session Info]
  Current session ID: $currentSession
  Console session ID: $consoleSession
  Current desktop: $desktopName
  Running as: $env:USERNAME

[Test]
  Test text: $testText
  Clipboard content: $clipContent
  Notepad content: '$notepadContent'

[Operations]
  Focus restore result: $focusResult
  SendInput events: $sendResult/4
  Win32 error: $lastError

=== VERDICT ===
"@
    
    Write-Host ""
    Write-Host "=== RESULT ==="
    Write-Host "Test text: $testText"
    Write-Host "Notepad content: '$notepadContent'"
    
    if ($notepadContent -match [regex]::Escape($testText)) {
        Write-Host ""
        Write-Host "SUCCESS: Text was inserted into Notepad!"
        Write-Host "The insert path works on this GitHub Windows VM."
        $results += "SUCCESS: Text insertion WORKS on this GitHub Windows VM.`n"
        $results | Out-File $resultFile -Encoding UTF8
        exit 0
    }
    else {
        Write-Host ""
        Write-Host "FAILURE: Text was NOT inserted into Notepad"
        Write-Host "Clipboard has: $clipContent"
        Write-Host "Notepad has: '$notepadContent'"
        Write-Host ""
        Write-Host "REPRODUCED: SendInput returned $sendResult/4 but text didn't arrive."
        
        $results += "FAILURE: Text was NOT inserted.`n"
        $results += "This REPRODUCES Sean's issue - SendInput succeeds but text doesn't arrive.`n`n"
        
        # Additional diagnostics
        $results += "[Analysis]`n"
        if ($sendResult -eq 4) {
            $results += "  SendInput accepted all 4 events - input injection was not blocked.`n"
            $results += "  But the Ctrl+V keystroke did not trigger paste in Notepad.`n"
            $results += "  Possible causes:`n"
            $results += "    - Notepad did not have keyboard focus when keys arrived`n"
            $results += "    - Input went to wrong window/thread`n"
            $results += "    - Timing issue between focus and input`n"
        }
        else {
            $results += "  SendInput only sent $sendResult/4 events (Win32 error: $lastError)`n"
            $results += "  Input injection was partially blocked.`n"
        }
        
        $results | Out-File $resultFile -Encoding UTF8
        
        Write-Host ""
        Write-Host "[Diagnostics]"
        Write-Host "  Session: $currentSession (console: $consoleSession)"
        Write-Host "  Desktop: $desktopName"
        Write-Host "  Focus restored: $focusResult"
        Write-Host "  SendInput events: $sendResult/4"
        
        exit 1
    }
}
finally {
    Stop-Procs
}
