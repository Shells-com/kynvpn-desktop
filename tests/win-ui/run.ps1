# Windows UI test: installs a Kyn VPN build, starts the client and checks that
# its windows really come up on the desktop (see README.md).
#
#   powershell -ExecutionPolicy Bypass -File tests\win-ui\run.ps1 `
#       -Installer kyn-windows-x64-....exe -OutDir out
#
# Needs an elevated prompt on an interactive desktop. It installs the client
# on this machine, so run it on a throwaway one (the CI runner).
#
# Exits 0 if every step passed, 1 if one failed, 2 on a setup problem.
param(
    [Parameter(Mandatory = $true)][string]$Installer,
    [string]$OutDir = 'win-ui-out',
    [string]$ServiceName = 'KynVPNService',
    # A window whose screenshot has fewer distinct colors than this is blank
    [int]$MinColors = 12
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace KynTest -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
'@
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
namespace KynTest {
public static class Windows {
    delegate bool EnumProc(IntPtr hwnd, IntPtr lparam);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int l, t, r, b; }
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lparam);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out RECT r);
    [DllImport("user32.dll")] static extern int GetWindowRgnBox(IntPtr hwnd, out RECT r);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr hwnd, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr hwnd, StringBuilder s, int n);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
    [DllImport("user32.dll")] static extern bool GetLayeredWindowAttributes(IntPtr hwnd, out uint key, out byte alpha, out uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out int value, int size);

    // Every top-level window of a process, hidden ones too.
    public static string Describe(uint pid) {
        var sb = new StringBuilder();
        IntPtr fg = GetForegroundWindow();
        EnumWindows((hwnd, l) => {
            uint owner;
            GetWindowThreadProcessId(hwnd, out owner);
            if (owner != pid) return true;
            var title = new StringBuilder(256); GetWindowTextW(hwnd, title, 256);
            var cls = new StringBuilder(256); GetClassNameW(hwnd, cls, 256);
            RECT r; GetWindowRect(hwnd, out r);
            RECT rgn; int rgnType = GetWindowRgnBox(hwnd, out rgn);
            int cloaked = 0; DwmGetWindowAttribute(hwnd, 14, out cloaked, 4);
            uint key, flags; byte alpha;
            bool layered = GetLayeredWindowAttributes(hwnd, out key, out alpha, out flags);
            sb.AppendFormat("0x{0:X} \"{1}\" class={2} visible={3} rect={4},{5} {6}x{7} style=0x{8:X} exstyle=0x{9:X}",
                hwnd.ToInt64(), title, cls, IsWindowVisible(hwnd), r.l, r.t, r.r - r.l, r.b - r.t,
                GetWindowLongPtr(hwnd, -16).ToInt64() & 0xFFFFFFFF, GetWindowLongPtr(hwnd, -20).ToInt64() & 0xFFFFFFFF);
            if (rgnType != 0) sb.AppendFormat(" region={0},{1} {2}x{3}", rgn.l, rgn.t, rgn.r - rgn.l, rgn.b - rgn.t);
            if (layered) sb.AppendFormat(" layered(alpha={0} flags={1})", alpha, flags);
            if (cloaked != 0) sb.AppendFormat(" cloaked={0}", cloaked);
            if (hwnd == fg) sb.Append(" foreground");
            sb.AppendLine();
            return true;
        }, IntPtr.Zero);
        return sb.ToString();
    }
}
}
'@
# Screen and UI Automation coordinates in physical pixels
[void][KynTest.Native]::SetProcessDPIAware()

$OutDir = (New-Item -ItemType Directory -Force -Path $OutDir).FullName
$script:Steps = @()
$script:Failed = $false

function Log([string]$msg) { Write-Host "win-ui: $msg" }

function Record([string]$name, [bool]$pass, [string]$detail = '') {
    $script:Steps += [pscustomobject]@{ name = $name; pass = $pass; detail = $detail }
    if ($pass) { Log "PASS $name $detail" } else { $script:Failed = $true; Log "FAIL $name $detail" }
}

# Retries $test until it returns something, for up to $seconds.
function Wait-For([int]$seconds, [scriptblock]$test) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ($true) {
        $result = $null
        try { $result = & $test } catch { $result = $null }
        if ($result) { return $result }
        if ((Get-Date) -ge $deadline) { return $null }
        Start-Sleep -Milliseconds 100
    }
}

function Save-Capture([int]$x, [int]$y, [int]$w, [int]$h, [string]$file) {
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $gfx.CopyFromScreen($x, $y, 0, 0, $bmp.Size)
        $bmp.Save((Join-Path $OutDir $file), [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $gfx.Dispose() }
    return $bmp
}

# The window's own content from the compositor, whatever else is on top of it.
function Save-Window($win, [string]$file) {
    $r = $win.Current.BoundingRectangle
    $bmp = New-Object System.Drawing.Bitmap([int]$r.Width, [int]$r.Height)
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $hdc = $gfx.GetHdc()
        # PW_CLIENTONLY (the bounding rectangle is the client area's) and
        # PW_RENDERFULLCONTENT (needed for Direct3D windows)
        try { $ok = [KynTest.Native]::PrintWindow([IntPtr]$win.Current.NativeWindowHandle, $hdc, 3) }
        finally { $gfx.ReleaseHdc($hdc) }
        if (-not $ok) { throw 'PrintWindow failed' }
        $bmp.Save((Join-Path $OutDir $file), [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $gfx.Dispose() }
    return $bmp
}

function Save-Screen([string]$name) {
    try {
        $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
        (Save-Capture $b.X $b.Y $b.Width $b.Height "$name-screen.png").Dispose()
    } catch { Log "could not capture the screen for ${name}: $_" }
}

# Distinct colors on a grid over the middle of a bitmap (the edges are left
# out, so a native title bar or border doesn't count as content).
function Get-ColorCount($bmp) {
    $colors = New-Object 'System.Collections.Generic.HashSet[int]'
    $x0 = [int]($bmp.Width * 0.05); $y0 = [int]($bmp.Height * 0.12)
    $xs = [Math]::Max(1, [int](($bmp.Width - 2 * $x0) / 96))
    $ys = [Math]::Max(1, [int](($bmp.Height - $y0 - $x0) / 96))
    for ($y = $y0; $y -lt $bmp.Height - $x0; $y += $ys) {
        for ($x = $x0; $x -lt $bmp.Width - $x0; $x += $xs) {
            [void]$colors.Add($bmp.GetPixel($x, $y).ToArgb())
        }
    }
    return $colors.Count
}

$Auto = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]

# The client's visible top-level windows, as UI Automation elements.
function Get-ClientWindows {
    $found = @()
    foreach ($proc in @(Get-Process -Name $script:ClientName -ErrorAction SilentlyContinue)) {
        $cond = New-Object System.Windows.Automation.PropertyCondition($Auto::ProcessIdProperty, $proc.Id)
        foreach ($win in $Auto::RootElement.FindAll($Scope::Children, $cond)) {
            $r = $win.Current.BoundingRectangle
            if (-not $r.IsEmpty -and $r.Width -ge 100 -and $r.Height -ge 100) { $found += $win }
        }
    }
    return $found
}

function Find-Window([string]$title) {
    return Get-ClientWindows | Where-Object { $_.Current.Name -match $title } | Select-Object -First 1
}

function Find-Named($win, [string]$name) {
    $cond = New-Object System.Windows.Automation.PropertyCondition($Auto::NameProperty, $name)
    return $win.FindFirst($Scope::Descendants, $cond)
}

# Activates a control like a click would.
function Invoke-Control($el) {
    $pattern = $null
    if ($el.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
        $pattern.Invoke()
        return
    }
    Log 'no invoke pattern, clicking with the mouse'
    $r = $el.Current.BoundingRectangle
    [void][KynTest.Native]::SetCursorPos([int]($r.X + $r.Width / 2), [int]($r.Y + $r.Height / 2))
    [KynTest.Native]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)   # left down
    [KynTest.Native]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)   # left up
}

function Write-Tree($el, [int]$depth, [System.Text.StringBuilder]$sb) {
    if ($depth -gt 25) { return }
    $c = $el.Current
    $r = $c.BoundingRectangle
    $box = if ($r.IsEmpty) { 'empty' } else { '{0},{1} {2}x{3}' -f [int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height }
    [void]$sb.AppendLine(('{0}{1} "{2}" [{3}]{4}' -f ('  ' * $depth),
        $c.ControlType.ProgrammaticName.Replace('ControlType.', ''), $c.Name, $box,
        $(if ($c.IsOffscreen) { ' offscreen' } else { '' })))
    $walker = [System.Windows.Automation.TreeWalker]::RawViewWalker
    $child = $walker.GetFirstChild($el)
    while ($child) {
        Write-Tree $child ($depth + 1) $sb
        $child = $walker.GetNextSibling($child)
    }
}

# Everything UI Automation sees of the client, for the artifacts.
function Save-Trees([string]$name) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($win in @(Get-ClientWindows)) {
        try { Write-Tree $win 0 $sb } catch { [void]$sb.AppendLine("(incomplete: $_)") }
    }
    [IO.File]::WriteAllText((Join-Path $OutDir "$name-uia.txt"), $sb.ToString())
    $native = ''
    foreach ($proc in @(Get-Process -Name $script:ClientName -ErrorAction SilentlyContinue)) {
        $native += [KynTest.Windows]::Describe($proc.Id)
    }
    [IO.File]::WriteAllText((Join-Path $OutDir "$name-windows.txt"), $native)
}

# Checks one window: it's on screen with a title matching $title, shows the
# controls named in $controls, and its pixels aren't blank.
function Test-Window([string]$step, [string]$title, [string[]]$controls) {
    $win = Wait-For 60 { Find-Window $title }
    if ($win) {
        # The controls come up once the QML has loaded
        [void](Wait-For 30 { Find-Named $win $controls[0] })
        Start-Sleep -Seconds 3   # let the show animation finish
    }
    Save-Screen $step
    Save-Trees $step
    if ($win -and -not (Find-Window $title)) {
        Record "$step-window" $false "a window titled /$title/ appeared, then went away"
        return $null
    }
    if (-not $win) {
        $seen = (@(Get-ClientWindows) | ForEach-Object { '"' + $_.Current.Name + '"' }) -join ', '
        $running = [bool](Get-Process -Name $script:ClientName -ErrorAction SilentlyContinue)
        Record "$step-window" $false "no window titled /$title/ (client running: $running; windows: $seen)"
        return $null
    }
    $r = $win.Current.BoundingRectangle
    Record "$step-window" $true ('"{0}" {1}x{2} at {3},{4}' -f $win.Current.Name, [int]$r.Width, [int]$r.Height, [int]$r.X, [int]$r.Y)

    $missing = @($controls | Where-Object { -not (Find-Named $win $_) })
    Record "$step-controls" ($missing.Count -eq 0) $(if ($missing.Count) { 'missing: ' + ($missing -join ', ') } else { $controls -join ', ' })

    try {
        $bmp = Save-Window $win "$step-window.png"
        $count = Get-ColorCount $bmp
        $bmp.Dispose()
        Record "$step-rendered" ($count -ge $MinColors) "$count distinct colors (at least $MinColors expected)"
    } catch {
        Record "$step-rendered" $false "could not capture the window: $_"
    }
    return $win
}

function Stop-Client {
    Get-Process -Name $script:ClientName -ErrorAction SilentlyContinue | Stop-Process -Force
    [void](Wait-For 20 { -not (Get-Process -Name $script:ClientName -ErrorAction SilentlyContinue) })
}

function Start-Client {
    Stop-Client
    Start-Process -FilePath $script:ClientExe -WorkingDirectory $script:InstallDir
}

function Finish {
    Save-Screen 'final'
    Stop-Client
    $copies = @{
        'install.log' = (Join-Path $env:TEMP 'kyn-install.log')
        'daemon.log'  = $(if ($script:InstallDir) { Join-Path $script:InstallDir 'data\daemon.log' })
        'client.log'  = $(if ($script:ClientData) { Join-Path $script:ClientData 'client.log' })
        'clientsettings.json' = $(if ($script:ClientData) { Join-Path $script:ClientData 'clientsettings.json' })
    }
    foreach ($name in $copies.Keys) {
        if ($copies[$name] -and (Test-Path $copies[$name])) {
            Copy-Item $copies[$name] (Join-Path $OutDir $name) -ErrorAction SilentlyContinue
        }
    }
    $report = [pscustomobject]@{ pass = -not $script:Failed; steps = $script:Steps }
    [IO.File]::WriteAllText((Join-Path $OutDir 'report.json'), ($report | ConvertTo-Json -Depth 4))
    if ($script:Failed) { Log 'FAILED'; exit 1 }
    Log 'all steps passed'
    exit 0
}

$script:ClientName = $null
$script:ClientExe = $null
$script:InstallDir = $null
$script:ClientData = $null

# --- Install -----------------------------------------------------------------
if (-not (Test-Path $Installer)) { Log "no installer at $Installer"; exit 2 }
$Installer = (Resolve-Path $Installer).Path
Log "installing $Installer"
$setup = Start-Process -FilePath $Installer -ArgumentList '/SILENT' -PassThru
if (-not $setup.WaitForExit(600000)) {
    Save-Screen 'install-timeout'
    Stop-Process -Id $setup.Id -Force
    Record 'install' $false 'the installer did not finish in 10 minutes'
    Finish
}
$service = Wait-For 30 { Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" }
if ($setup.ExitCode -ne 0 -or -not $service) {
    Save-Screen 'install-failed'
    Record 'install' $false "installer exit code $($setup.ExitCode), service $ServiceName $(if ($service) { 'installed' } else { 'missing' })"
    Finish
}
$serviceExe = if ($service.PathName -match '^"([^"]+)"') { $Matches[1] } else { ($service.PathName -split ' ')[0] }
$script:InstallDir = Split-Path $serviceExe
$client = Get-ChildItem $script:InstallDir -Filter '*-client.exe' | Select-Object -First 1
$ctl = Get-ChildItem $script:InstallDir -Filter '*ctl.exe' | Select-Object -First 1
if (-not $client -or -not $ctl) {
    Record 'install' $false "no client or ctl executable in $($script:InstallDir)"
    Finish
}
$script:ClientExe = $client.FullName
$script:ClientName = $client.BaseName
Record 'install' $true "$($script:InstallDir), $((Get-Content (Join-Path $script:InstallDir 'version.txt') -TotalCount 1))"

# --- Daemon ------------------------------------------------------------------
$state = Wait-For 60 { & $ctl.FullName get connectionstate 2>$null }
Record 'daemon' ([bool]$state) $(if ($state) { "connection state $state" } else { "$($ctl.Name) can't reach the daemon (service $((Get-Service $ServiceName).Status))" })
if ($state) { & $ctl.FullName set debuglogging true 2>&1 | Out-Null }

# --- First run: the Quick Tour -----------------------------------------------
# The installer starts the client as the desktop user. Without a shell to take
# that user from (or if it didn't work), start it here.
if (Wait-For 30 { Get-Process -Name $script:ClientName -ErrorAction SilentlyContinue }) {
    Log 'the installer started the client'
} else {
    Log 'the installer did not start the client, starting it'
    Start-Client
}
$tour = Test-Window 'onboarding' '^Quick Tour$' @('QUICK TOUR', 'LOG IN')

# --- Its LOG IN button opens the dashboard on the login page -----------------
if ($tour) {
    try { Invoke-Control (Find-Named $tour 'LOG IN') } catch { Log "could not click LOG IN: $_" }
    [void](Test-Window 'dashboard-popup' 'Dashboard$' @('Username', 'Password', 'LOG IN'))
}

# --- Second run: the dashboard as a regular window ---------------------------
Stop-Client
$script:ClientData = Get-ChildItem $env:LOCALAPPDATA -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName 'clientsettings.json') } |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $script:ClientData) {
    Record 'client-settings' $false "the client wrote no clientsettings.json under $env:LOCALAPPDATA"
    Finish
}
$settingsFile = Join-Path $script:ClientData 'clientsettings.json'
$settings = Get-Content $settingsFile -Raw | ConvertFrom-Json
$settings | Add-Member -NotePropertyName dashboardFrame -NotePropertyValue 'window' -Force
[IO.File]::WriteAllText($settingsFile, ($settings | ConvertTo-Json -Depth 20))
Start-Client
[void](Test-Window 'dashboard-window' '^Kyn VPN$' @('Username', 'Password', 'LOG IN'))

Finish
