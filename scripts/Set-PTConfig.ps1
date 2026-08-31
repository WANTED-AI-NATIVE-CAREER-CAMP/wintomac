<#
.SYNOPSIS
    Set PowerToys settings.json values that the keymap cannot reach: elevation mode and
    per-module enable flags.

.DESCRIPTION
    Two things live outside default.json and both silently break keymaps:

    run_elevated -- Keyboard Manager is a user-mode hook, so remaps stop applying whenever
    an elevated window has focus unless PowerToys itself runs elevated. Nothing warns you;
    the keyboard just reverts to stock behaviour in Procmon, Autoruns, RAMMap and friends.
    The cost is that apps launched from Command Palette inherit elevation, so this is opt-in.

    module enable flags -- a remap that targets a disabled module is a dead rule. The
    internal keys do not match the UI labels, so friendly names are translated below.

    settings.json is only safe to edit while PowerToys is stopped, otherwise PowerToys
    overwrites the change on exit. This script validates everything first, then stops it,
    edits, and restarts it -- and re-runs itself elevated when PowerToys is already
    elevated, since an unelevated shell cannot stop an elevated process.

.EXAMPLE
    .\Set-PTConfig.ps1 -List
    .\Set-PTConfig.ps1 -EnableAdminMode
    .\Set-PTConfig.ps1 -EnableModules 'Window Hopper','Text Extractor'
    .\Set-PTConfig.ps1 -DisableModules 'ZoomIt' -DisableAdminMode
#>
[CmdletBinding()]
param(
    [string[]]$EnableModules  = @(),
    [string[]]$DisableModules = @(),
    [switch]$EnableAdminMode,
    [switch]$DisableAdminMode,
    [switch]$List,
    [switch]$NoRestart
)

$ErrorActionPreference = 'Stop'

$Settings = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys\settings.json'
$PtExe    = Join-Path $env:LOCALAPPDATA 'PowerToys\PowerToys.exe'
if (-not (Test-Path $PtExe)) {
    $machine = Join-Path $env:ProgramFiles 'PowerToys\PowerToys.exe'
    if (Test-Path $machine) { $PtExe = $machine }
}

# UI label -> settings.json key. Only the ones that differ really matter, but the full map
# means callers never have to know the internal names.
$ModuleKey = @{
    'advanced paste'      = 'AdvancedPaste'
    'window hopper'       = 'AltWindowCycle'      # not "WindowHopper"
    'always on top'       = 'AlwaysOnTop'
    'awake'               = 'Awake'
    'command not found'   = 'CmdNotFound'
    'command palette'     = 'CmdPal'
    'color picker'        = 'ColorPicker'
    'crop and lock'       = 'CropAndLock'
    'cursor wrap'         = 'CursorWrap'
    'environment variables' = 'EnvironmentVariables'
    'fancyzones'          = 'FancyZones'
    'file explorer'       = 'File Explorer'
    'file locksmith'      = 'File Locksmith'
    'find my mouse'       = 'FindMyMouse'
    'grab and move'       = 'GrabAndMove'
    'hosts file editor'   = 'Hosts'
    'image resizer'       = 'Image Resizer'
    'keyboard manager'    = 'Keyboard Manager'
    'light switch'        = 'LightSwitch'
    'screen ruler'        = 'Measure Tool'        # not "ScreenRuler"
    'mouse highlighter'   = 'MouseHighlighter'
    'mouse jump'          = 'MouseJump'
    'mouse crosshairs'    = 'MousePointerCrosshairs'
    'mouse without borders' = 'MouseWithoutBorders'
    'new+'                = 'NewPlus'
    'peek'                = 'Peek'
    'power display'       = 'PowerDisplay'
    'powerrename'         = 'PowerRename'
    'powertoys run'       = 'PowerToys Run'
    'quick accent'        = 'QuickAccent'
    'registry preview'    = 'RegistryPreview'
    'shortcut guide'      = 'Shortcut Guide'
    'text extractor'      = 'TextExtractor'
    'workspaces'          = 'Workspaces'
    'zoomit'              = 'ZoomIt'
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-NeedsElevation {
    $p = @(Get-Process PowerToys -ErrorAction SilentlyContinue)
    if ($p.Count -eq 0) { return $false }
    if (Test-Admin) { return $false }
    try { $null = $p[0].MainModule.FileName; return $false }
    catch { return $true }
}

function Read-Settings {
    if (-not (Test-Path $Settings)) {
        throw "settings.json not found: $Settings`nInstall and run PowerToys once first (.\Install-Tools.ps1)."
    }
    $raw = Get-Content $Settings -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { throw "settings.json is empty: $Settings" }
    $j = $raw | ConvertFrom-Json
    if (-not $j -or -not $j.enabled) {
        throw "settings.json has no 'enabled' block -- malformed or written by an incompatible PowerToys version: $Settings"
    }
    $j
}

# Resolve a friendly name (or an internal key) to a key that actually exists in this
# settings.json. Assigning an absent property on a ConvertFrom-Json object throws, so an
# unknown key has to fail here -- before PowerToys is stopped -- rather than halfway
# through the edit with PowerToys already down.
function Resolve-ModuleKey([string]$name, $settings) {
    $k = $name.Trim()
    $candidate = if ($ModuleKey.ContainsKey($k)) { $ModuleKey[$k] } else { $k }
    if ($settings.enabled.PSObject.Properties.Name -notcontains $candidate) {
        throw "Module '$name' resolves to key '$candidate', which is not present in settings.json. Run -List to see valid names."
    }
    $candidate
}

# Re-run this script elevated.
#
# Start-Process -ArgumentList takes an array and joins it with spaces WITHOUT quoting, so
# rebuilding a [string[]] parameter through it mangles any value containing a space --
# 'Window Hopper' arrives as 'Window'. Passing one pre-quoted -Command string instead keeps
# the list intact. And because -Verb RunAs opens a console that closes the moment pwsh
# exits, the child's output is redirected to a log the parent prints, and its exit code is
# checked -- otherwise a failed elevated pass looks exactly like a successful one.
function Invoke-SelfElevated {
    $log = Join-Path ([IO.Path]::GetTempPath()) 'wintomac-elevated.log'
    Remove-Item $log -Force -ErrorAction SilentlyContinue

    $host_exe = try { (Get-Process -Id $PID).Path } catch { 'pwsh' }
    if (-not $host_exe) { $host_exe = 'pwsh' }

    function Quote-List($items) { (($items | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ',') }

    $sq  = $PSCommandPath -replace "'", "''"
    $lq  = $log           -replace "'", "''"
    $cmd = "& '" + $sq + "'"
    if ($EnableModules.Count)  { $cmd += ' -EnableModules '  + (Quote-List $EnableModules) }
    if ($DisableModules.Count) { $cmd += ' -DisableModules ' + (Quote-List $DisableModules) }
    if ($EnableAdminMode)      { $cmd += ' -EnableAdminMode' }
    if ($DisableAdminMode)     { $cmd += ' -DisableAdminMode' }
    if ($NoRestart)            { $cmd += ' -NoRestart' }
    $cmd += " *> '" + $lq + "'"

    $psArgs = '-NoProfile -ExecutionPolicy Bypass -Command "' + $cmd + '"'

    Write-Host 'PowerToys is running elevated; re-running this script elevated.' -ForegroundColor Yellow
    $proc = Start-Process $host_exe -Verb RunAs -ArgumentList $psArgs -Wait -PassThru
    if (Test-Path $log) { Get-Content $log | Write-Host }
    if ($proc.ExitCode -ne 0) {
        throw "Elevated run failed with exit code $($proc.ExitCode). See output above."
    }
}

# ---- list ------------------------------------------------------------
if ($List) {
    $j = Read-Settings
    Write-Host "`nrun_elevated : $($j.run_elevated)" -ForegroundColor Cyan
    Write-Host "startup      : $($j.startup)"
    Write-Host "version      : $($j.powertoys_version)"
    Write-Host "`n(is_elevated is written on exit and reports the PREVIOUS session -- use Test-Setup.ps1 for live state)" -ForegroundColor DarkGray
    Write-Host "`nModules:" -ForegroundColor Cyan
    $rev = @{}; $ModuleKey.GetEnumerator() | ForEach-Object { $rev[$_.Value] = $_.Key }
    $j.enabled.PSObject.Properties | Sort-Object Name | ForEach-Object {
        $label = if ($rev.ContainsKey($_.Name)) { $rev[$_.Name] } else { '' }
        '  {0} {1,-24} {2}' -f $(if ($_.Value) { '[x]' } else { '[ ]' }), $_.Name, $label
    }
    return
}

if (-not $EnableModules.Count -and -not $DisableModules.Count -and
    -not $EnableAdminMode -and -not $DisableAdminMode) {
    Write-Host 'Nothing to do. Use -List, -EnableModules, -DisableModules, -EnableAdminMode or -DisableAdminMode.' -ForegroundColor Yellow
    return
}
if ($EnableAdminMode -and $DisableAdminMode) {
    throw 'Pass only one of -EnableAdminMode / -DisableAdminMode.'
}

# Validate before anything is stopped or written: a bad module name should cost nothing.
$settings  = Read-Settings
$toEnable  = @($EnableModules  | ForEach-Object { Resolve-ModuleKey $_ $settings })
$toDisable = @($DisableModules | ForEach-Object { Resolve-ModuleKey $_ $settings })
$both = $toEnable | Where-Object { $toDisable -contains $_ }
if ($both) { throw "Module(s) listed as both enable and disable: $($both -join ', ')" }

if (Test-NeedsElevation) { Invoke-SelfElevated; return }

# ---- apply -----------------------------------------------------------
Get-Process | Where-Object { $_.ProcessName -like 'PowerToys*' } |
    Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 1500

$wantElevated = $settings.run_elevated
try {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Copy-Item $Settings "$Settings.bak-$stamp" -Force
    Write-Host "backup: settings.json.bak-$stamp" -ForegroundColor DarkGray

    $j = Read-Settings
    foreach ($k in $toEnable)  { $j.enabled.$k = $true;  Write-Host "enabled  : $k" -ForegroundColor Green }
    foreach ($k in $toDisable) { $j.enabled.$k = $false; Write-Host "disabled : $k" -ForegroundColor Yellow }
    if ($EnableAdminMode) {
        $j.run_elevated = $true
        Write-Host 'run_elevated = true  (UAC prompt on restart; launched apps inherit elevation)' -ForegroundColor Green
    }
    if ($DisableAdminMode) {
        $j.run_elevated = $false
        Write-Host 'run_elevated = false (remaps will stop working in elevated windows)' -ForegroundColor Yellow
    }
    $j | ConvertTo-Json -Depth 10 | Set-Content $Settings -Encoding utf8
    $wantElevated = $j.run_elevated
}
finally {
    # PowerToys is down at this point. Bringing it back even when the edit failed matters
    # more than a clean error, because leaving it stopped silently reverts the keyboard to
    # stock behaviour with no indication why.
    if (-not $NoRestart) {
        if (-not (Test-Path $PtExe)) {
            Write-Host "PowerToys.exe not found at $PtExe -- start it manually." -ForegroundColor Yellow
        }
        elseif ($wantElevated -and -not (Test-Admin)) {
            Start-Process $PtExe -Verb RunAs      # ask for the prompt rather than hoping
            Write-Host 'PowerToys restarted (elevated)' -ForegroundColor Green
        }
        elseif (-not $wantElevated -and (Test-Admin)) {
            # This shell is elevated, so a plain Start-Process would hand PowerToys the
            # admin token and -DisableAdminMode would have written run_elevated=false while
            # bringing it back elevated anyway. Launching via explorer.exe drops back to
            # the interactive user's token.
            try {
                Start-Process explorer.exe -ArgumentList $PtExe
                Write-Host 'PowerToys restarted de-elevated (via explorer)' -ForegroundColor Green
            } catch {
                Write-Host 'Could not restart de-elevated. Start PowerToys yourself from a normal shell,' -ForegroundColor Yellow
                Write-Host 'otherwise it keeps this shell''s admin token despite run_elevated=false.' -ForegroundColor Yellow
            }
        }
        else {
            Start-Process $PtExe
            Write-Host 'PowerToys restarted' -ForegroundColor Green
        }
    }
}

Write-Host "`nVerify with: .\Test-Setup.ps1" -ForegroundColor Cyan
