<#
.SYNOPSIS
    Reproduces the text insertion flow exactly as AIDictation uses it.
    
.DESCRIPTION
    This script mirrors the exact sequence in ClipboardService.PasteTextAsync:
    1. Capture foreground window handle (simulating hotkey press)
    2. Do some work (simulating recording + transcription)
    3. Set clipboard text
    4. Restore focus to captured window (SetForegroundWindow + AttachThreadInput)
    5. SendInput Ctrl+V
    6. Read the control text back to verify insertion
    
    If this fails, we've reproduced Sean's issue on windows-latest.

.PARAMETER OutDir
    Directory for diagnostic output (screenshots, logs)

.EXAMPLE
    .\repro-insert-failure.ps1 -OutDir .\artifacts\repro
#>
param(
    [Parameter(Mandatory = $true)][string]$OutDir
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

# P/Invoke declarations matching exactly what the app uses
Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class InsertRepro {
    // Exactly what ClipboardService uses
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
    
    // Exactly what SendInputHelper uses
    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    
    [DllImport("user32.dll")]
    public static extern IntPtr GetMessageExtraInfo();
    
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);
    
    public const int INPUT_KEYBOARD = 1;
    public const uint KEYEVENTF_KEYUP = 0x0002;
    public const ushort VK_CONTROL = 0x11;
    public const ushort VK_V = 0x56;
    public const ushort VK_F8 = 0x77;
    public const ushort VK_SHIFT = 0x10;
    public const ushort VK_MENU = 0x12; // Alt
    
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
    
    // Mirror of SendInputHelper.SendPaste()
    public static bool SendPaste() {
        var inputs = new INPUT[4];
        var size = Marshal.SizeOf<INPUT>();
        var extra = GetMessageExtraInfo();
        
        // Ctrl down
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].u.ki.wVk = VK_CONTROL;
        inputs[0].u.ki.dwFlags = 0;
        inputs[0].u.ki.dwExtraInfo = extra;
        
        // V down
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].u.ki.wVk = VK_V;
        inputs[1].u.ki.dwFlags = 0;
        inputs[1].u.ki.dwExtraInfo = extra;
        
        // V up
        inputs[2].type = INPUT_KEYBOARD;
        inputs[2].u.ki.wVk = VK_V;
        inputs[2].u.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[2].u.ki.dwExtraInfo = extra;
        
        // Ctrl up
        inputs[3].type = INPUT_KEYBOARD;
        inputs[3].u.ki.wVk = VK_CONTROL;
        inputs[3].u.ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[3].u.ki.dwExtraInfo = extra;
        
        var sent = SendInput(4, inputs, size);
        var error = Marshal.GetLastWin32Error();
        Console.WriteLine("SendInput sent {0}/4 events (error {1})", sent, error);
        return sent == 4;
    }
    
    // Mirror of ClipboardService.TryFocusWindowAsync (sync version for testing)
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
        
        Console.WriteLine("SetForegroundWindow returned {0}, attached={1}", requested, attached);
        return requested;
    }
    
    public static bool IsModifierDown(ushort vk) {
        return (GetAsyncKeyState(vk) & 0x8000) != 0;
    }
}
"@

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$script:notepadProc = $null
$testText = "AIDICTATION_REPRO_TEST_$(Get-Date -Format 'HHmmss')"

function Take-Screenshot([string]$Name) {
    try {
        Add-Type -AssemblyName System.Drawing
        $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
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
    Write-Host "=== AIDictation Insert Repro Test ==="
    Write-Host "Test text: $testText"
    Write-Host ""
    
    # =========================================================================
    # STEP 1: Open Notepad (the target edit control)
    # =========================================================================
    Write-Host "[1] Opening Notepad as target window..."
    $script:notepadProc = Start-Process notepad -PassThru
    Start-Sleep -Seconds 2
    $script:notepadProc.Refresh()
    
    if ($script:notepadProc.HasExited) {
        throw "Notepad failed to start"
    }
    
    $targetHwnd = $script:notepadProc.MainWindowHandle
    Write-Host "  Notepad HWND: $targetHwnd"
    
    # =========================================================================
    # STEP 2: Focus Notepad (simulates user focusing Word/email before F8)
    # =========================================================================
    Write-Host "[2] Focusing Notepad (simulating user's target window)..."
    [InsertRepro]::SetForegroundWindow($targetHwnd) | Out-Null
    Start-Sleep -Milliseconds 500
    
    # =========================================================================
    # STEP 3: Capture foreground window (exactly what app does at F8 press)
    # =========================================================================
    Write-Host "[3] Capturing foreground window (like app does at F8 press)..."
    $capturedHwnd = [InsertRepro]::GetForegroundWindow()
    Write-Host "  Captured HWND: $capturedHwnd"
    
    if ($capturedHwnd -ne $targetHwnd) {
        Write-Host "  WARNING: Captured HWND differs from target! Focus may have shifted."
    }
    
    Take-Screenshot "01-before-work"
    
    # =========================================================================
    # STEP 4: Simulate work (recording + transcription takes time)
    #         During this time, focus might change!
    # =========================================================================
    Write-Host "[4] Simulating recording + transcription delay (3 seconds)..."
    
    # Check for stuck modifiers that could interfere
    $ctrlDown = [InsertRepro]::IsModifierDown([InsertRepro]::VK_CONTROL)
    $shiftDown = [InsertRepro]::IsModifierDown([InsertRepro]::VK_SHIFT)
    $altDown = [InsertRepro]::IsModifierDown([InsertRepro]::VK_MENU)
    $f8Down = [InsertRepro]::IsModifierDown([InsertRepro]::VK_F8)
    Write-Host "  Modifier state: Ctrl=$ctrlDown Shift=$shiftDown Alt=$altDown F8=$f8Down"
    
    Start-Sleep -Seconds 3
    
    $currentFg = [InsertRepro]::GetForegroundWindow()
    Write-Host "  After delay, foreground HWND: $currentFg"
    if ($currentFg -ne $capturedHwnd) {
        Write-Host "  NOTE: Focus shifted during simulated work"
    }
    
    Take-Screenshot "02-after-work"
    
    # =========================================================================
    # STEP 5: Set clipboard (exactly what app does)
    # =========================================================================
    Write-Host "[5] Setting clipboard text..."
    [System.Windows.Forms.Clipboard]::SetText($testText)
    Start-Sleep -Milliseconds 50  # Match Constants.ClipboardDelayMs
    
    $clipVerify = [System.Windows.Forms.Clipboard]::GetText()
    if ($clipVerify -ne $testText) {
        throw "Clipboard write failed! Expected '$testText', got '$clipVerify'"
    }
    Write-Host "  Clipboard set successfully"
    
    # =========================================================================
    # STEP 6: Restore focus (exactly what ClipboardService.TryFocusWindowAsync does)
    # =========================================================================
    Write-Host "[6] Restoring focus to captured window..."
    
    if (-not [InsertRepro]::IsWindow($capturedHwnd)) {
        throw "Target window no longer exists!"
    }
    
    $focusResult = [InsertRepro]::TryFocusWindow($capturedHwnd)
    Start-Sleep -Milliseconds 150  # Match Constants.FocusRestoreDelayMs
    
    $afterFocus = [InsertRepro]::GetForegroundWindow()
    Write-Host "  Focus restore result: $focusResult"
    Write-Host "  Foreground after restore: $afterFocus"
    
    if ($afterFocus -ne $capturedHwnd) {
        Write-Host "  WARNING: Focus restoration may have failed!"
    }
    
    Take-Screenshot "03-after-focus-restore"
    
    # =========================================================================
    # STEP 7: SendInput Ctrl+V (exactly what SendInputHelper.SendPaste does)
    # =========================================================================
    Write-Host "[7] Sending Ctrl+V via SendInput..."
    
    # Check modifiers again right before paste
    $ctrlDown = [InsertRepro]::IsModifierDown([InsertRepro]::VK_CONTROL)
    $shiftDown = [InsertRepro]::IsModifierDown([InsertRepro]::VK_SHIFT)
    $altDown = [InsertRepro]::IsModifierDown([InsertRepro]::VK_MENU)
    Write-Host "  Modifier state before paste: Ctrl=$ctrlDown Shift=$shiftDown Alt=$altDown"
    
    $sendResult = [InsertRepro]::SendPaste()
    Start-Sleep -Milliseconds 30  # Match Constants.PasteDelayMs
    
    Write-Host "  SendInput result: $sendResult"
    
    Take-Screenshot "04-after-sendinput"
    
    # =========================================================================
    # STEP 8: Verify text was inserted
    # =========================================================================
    Write-Host "[8] Reading Notepad content to verify insertion..."
    Start-Sleep -Milliseconds 500  # Give app time to process
    
    $notepadContent = Read-NotepadText
    Write-Host "  Notepad content: '$notepadContent'"
    
    Take-Screenshot "05-final"
    
    # =========================================================================
    # STEP 9: Determine result
    # =========================================================================
    Write-Host ""
    Write-Host "=== RESULTS ==="
    
    if ($notepadContent -match [regex]::Escape($testText)) {
        Write-Host "PASS: Text was successfully inserted into Notepad"
        Write-Host ""
        Write-Host "Could not reproduce Sean's failure. The insert path works on windows-latest."
        Write-Host "Possible environmental factors on Sean's machine:"
        Write-Host "  - Security software blocking SendInput"
        Write-Host "  - Elevated target application (UIPI)"
        Write-Host "  - Different Windows configuration"
        exit 0
    }
    else {
        Write-Host "FAIL: Text was NOT inserted into Notepad"
        Write-Host ""
        Write-Host "REPRODUCED the failure! Text is on clipboard but not in edit control."
        Write-Host "Clipboard: '$clipVerify'"
        Write-Host "Notepad:   '$notepadContent'"
        
        # Try manual paste as diagnostic
        Write-Host ""
        Write-Host "[DIAGNOSTIC] Trying manual Ctrl+V via keybd_event..."
        Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class ManualPaste {
    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
}
"@
        [InsertRepro]::SetForegroundWindow($capturedHwnd) | Out-Null
        Start-Sleep -Milliseconds 300
        
        [ManualPaste]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)  # Ctrl down
        Start-Sleep -Milliseconds 50
        [ManualPaste]::keybd_event(0x56, 0, 0, [UIntPtr]::Zero)  # V down
        Start-Sleep -Milliseconds 50
        [ManualPaste]::keybd_event(0x56, 0, 2, [UIntPtr]::Zero)  # V up
        [ManualPaste]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero)  # Ctrl up
        Start-Sleep -Milliseconds 500
        
        $manualContent = Read-NotepadText
        Write-Host "After manual paste: '$manualContent'"
        
        if ($manualContent -match [regex]::Escape($testText)) {
            Write-Host ""
            Write-Host "DIAGNOSTIC: Manual keybd_event works but app's SendInput doesn't!"
            Write-Host "This points to an issue with our SendInput implementation."
        }
        else {
            Write-Host ""
            Write-Host "DIAGNOSTIC: Neither SendInput nor keybd_event works."
            Write-Host "This is an environment issue (headless runner can't inject keys)."
        }
        
        exit 1
    }
}
finally {
    Stop-Procs
}
