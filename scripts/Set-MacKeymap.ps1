<#
.SYNOPSIS
    Generate PowerToys Keyboard Manager's default.json from a declarative table.

.DESCRIPTION
    Edit $KeyRemaps / $ShortcutRemaps below and re-run. The script resolves key names to
    virtual-key codes, sorts modifiers canonically, validates each rule, runs an orphan
    check, backs up the existing config, and restarts PowerToys.

    IMPORTANT - the From column is written in POST-KEY-REMAP terms.
    PowerToys applies single-key remaps first and matches shortcut remaps against the
    result: "Single key remappings have precedence over shortcut remaps and are
    correspondingly reflected in shortcut remaps."
    So with LCtrl<->LAlt swapped, physical Cmd (Left Alt) has already become Ctrl, and a
    rule about Cmd+Tab is written From='Ctrl+Tab'.

.EXAMPLE
    .\Set-MacKeymap.ps1 -DryRun     # print the table and the JSON, write nothing
    .\Set-MacKeymap.ps1             # back up, write, restart PowerToys
    .\Set-MacKeymap.ps1 -Restore    # roll back to the newest backup
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$NoRestart,
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'

# ======================================================================
#  KEYMAP  --  edit this section
# ======================================================================
#
#   physical:   [ Left Ctrl ]   [ Win ]   [ Left Alt ]   [ Space ]
#   acts as:      Option                    Command
#
#   Remap only the Left variants -- never 161/163/165. Note that this does NOT make the
#   swap AltGr-safe: AltGr is LCtrl+RAlt, and LCtrl is half of it, so on ISO/European
#   layouts this swap can still break AltGr characters. See gotchas section 6.
#
$KeyRemaps = @(
    @{ From = 'LCtrl'; To = 'LAlt';  Note = 'physical Ctrl -> Option role' }
    @{ From = 'LAlt';  To = 'LCtrl'; Note = 'physical Alt (next to space) -> Command role' }
)

# Optional per-rule properties:
#   AllowOrphan = $true  -- "I accept that this rule makes its own source combination
#                           unreachable." Without it the orphan check refuses to write.
#   ExactMatch  = $true  -- only fire when no additional keys are held. Mainly for
#                           shortcut-to-single-key targets (e.g. To = 'Home').
$ShortcutRemaps = @(
    # --- app / tab switching -------------------------------------------------
    @{ From = 'Ctrl+Tab';            To = 'Alt+Tab';            Note = 'Cmd+Tab      switch apps' }
    @{ From = 'Alt+Tab';             To = 'Ctrl+Tab';           Note = 'Opt+Tab      switch tabs within app' }

    # --- browser history -----------------------------------------------------
    # Mac overloads Cmd+Left (line start in text, Back in a browser). Windows cannot
    # tell those apart globally. This picks Back; see keymap-reference.md for the
    # app-specific alternative that gives Home/End globally instead.
    @{ From = 'Ctrl+Left';           To = 'Alt+Left';           Note = 'Cmd+Left     browser Back' }
    @{ From = 'Ctrl+Right';          To = 'Alt+Right';          Note = 'Cmd+Right    browser Forward' }

    # --- word-wise text navigation ------------------------------------------
    # These pair with the two rules above. Without them nothing emits Ctrl+Left, so
    # word-wise movement becomes impossible to type. See the orphan check.
    @{ From = 'Alt+Left';            To = 'Ctrl+Left';          Note = 'Opt+Left     word-wise move' }
    @{ From = 'Alt+Right';           To = 'Ctrl+Right';         Note = 'Opt+Right    word-wise move' }
    @{ From = 'Alt+Shift+Left';      To = 'Ctrl+Shift+Left';    Note = 'Opt+Sh+Left  word-wise select'; AllowOrphan = $true }
    @{ From = 'Alt+Shift+Right';     To = 'Ctrl+Shift+Right';   Note = 'Opt+Sh+Right word-wise select'; AllowOrphan = $true }
    @{ From = 'Alt+Backspace';       To = 'Ctrl+Backspace';     Note = 'Opt+Delete   delete word';      AllowOrphan = $true }

    # --- Window Hopper (PowerToys 0.101+; module key is AltWindowCycle) ------
    # Requires the module to be enabled or these are dead rules:
    #   .\Set-PTConfig.ps1 -EnableModules 'Window Hopper'
    @{ From = 'Ctrl+Backtick';       To = 'Alt+Backtick';       Note = 'Cmd+`        cycle windows of this app'; AllowOrphan = $true }
    @{ From = 'Ctrl+Shift+Backtick'; To = 'Alt+Shift+Backtick'; Note = 'Cmd+Shift+`  cycle backwards';           AllowOrphan = $true }

    # --- Mac system shortcuts -----------------------------------------------
    # Each of these deliberately consumes a shortcut some apps use natively; that is
    # what AllowOrphan records. Drop the line if the collision matters more.
    @{ From = 'Ctrl+Q';              To = 'Alt+F4';             Note = 'Cmd+Q        quit app   (eats Ctrl+Q)';  AllowOrphan = $true }
    @{ From = 'Ctrl+M';              To = 'Win+Down';           Note = 'Cmd+M        minimise   (eats Ctrl+M)';  AllowOrphan = $true }
    @{ From = 'Ctrl+Shift+4';        To = 'Win+Shift+S';        Note = 'Cmd+Shift+4  capture region';            AllowOrphan = $true }
    @{ From = 'Ctrl+Shift+3';        To = 'Win+PrintScreen';    Note = 'Cmd+Shift+3  capture screen to file';    AllowOrphan = $true }
    @{ From = 'Ctrl+Alt+Escape';     To = 'Ctrl+Shift+Escape';  Note = 'Cmd+Opt+Esc  Task Manager';              AllowOrphan = $true }
)

# ======================================================================
#  ENGINE  --  no need to edit below
# ======================================================================

$KbmDir       = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys\Keyboard Manager'
$Target       = Join-Path $KbmDir 'default.json'
$ManifestPath = Join-Path $KbmDir 'wintomac.manifest.json'
$PtExe        = Join-Path $env:LOCALAPPDATA 'PowerToys\PowerToys.exe'

$VK = @{
    'LCtrl' = 162; 'RCtrl' = 163; 'Ctrl' = 162
    'LAlt'  = 164; 'RAlt'  = 165; 'Alt'  = 164
    'LShift' = 160; 'RShift' = 161; 'Shift' = 160
    'LWin' = 91; 'RWin' = 92; 'Win' = 91
    'Tab' = 9; 'Space' = 32; 'Backspace' = 8; 'Enter' = 13; 'Escape' = 27; 'Esc' = 27
    'Delete' = 46; 'Insert' = 45; 'CapsLock' = 20; 'PrintScreen' = 44
    'Left' = 37; 'Up' = 38; 'Right' = 39; 'Down' = 40
    'Home' = 36; 'End' = 35; 'PageUp' = 33; 'PageDown' = 34
    'Hangul' = 21; 'Hanja' = 25
    'Backtick' = 192; 'Grave' = 192; 'Minus' = 189; 'Equals' = 187
    'LBracket' = 219; 'RBracket' = 221; 'Backslash' = 220
    'Semicolon' = 186; 'Quote' = 222; 'Comma' = 188; 'Period' = 190; 'Slash' = 191
}
foreach ($c in [char[]]'ABCDEFGHIJKLMNOPQRSTUVWXYZ') { $VK["$c"] = [int][char]$c }
foreach ($n in 0..9)  { $VK["$n"]  = 48 + $n }
foreach ($n in 1..24) { $VK["F$n"] = 111 + $n }

# Canonical emit order: Win -> Ctrl -> Alt -> Shift -> action key.
$ModRank = @{ 91 = 1; 92 = 1; 162 = 2; 163 = 2; 17 = 2; 164 = 3; 165 = 3; 18 = 3; 160 = 4; 161 = 4; 16 = 4 }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# PowerToys running elevated cannot be stopped from an unelevated shell, so a plain run
# would write the config and then fail to reload it. Detect by probing MainModule, which
# is unreadable across an integrity boundary.
function Test-NeedsElevation {
    $p = @(Get-Process PowerToys -ErrorAction SilentlyContinue)
    if ($p.Count -eq 0) { return $false }
    if (Test-Admin) { return $false }
    try { $null = $p[0].MainModule.FileName; return $false }
    catch { return $true }
}

# Re-run this script elevated.
#
# Two things make this fiddly, and both were bugs here before:
#   * Start-Process -ArgumentList takes an ARRAY and joins it with spaces WITHOUT quoting,
#     so a script path containing a space (C:\Users\First Last\...) gets split and the
#     child dies on a truncated path. Passing one pre-quoted string instead is the fix.
#   * -Verb RunAs opens a new console that closes the instant pwsh exits, so an error in
#     the child is invisible. Redirect the child's streams to a log the parent prints, and
#     check the exit code, or a failed run looks exactly like a successful one.
function Invoke-SelfElevated([string[]]$Flags) {
    $log = Join-Path ([IO.Path]::GetTempPath()) 'wintomac-elevated.log'
    Remove-Item $log -Force -ErrorAction SilentlyContinue

    $host_exe = try { (Get-Process -Id $PID).Path } catch { 'pwsh' }
    if (-not $host_exe) { $host_exe = 'pwsh' }

    $sq = $PSCommandPath -replace "'", "''"
    $lq = $log           -replace "'", "''"
    $inner  = "& '" + $sq + "' " + ($Flags -join ' ') + " *> '" + $lq + "'"
    $psArgs = '-NoProfile -ExecutionPolicy Bypass -Command "' + $inner + '"'

    Write-Host 'PowerToys is running elevated; re-running this script elevated.' -ForegroundColor Yellow
    $proc = Start-Process $host_exe -Verb RunAs -ArgumentList $psArgs -Wait -PassThru
    if (Test-Path $log) { Get-Content $log | Write-Host }
    if ($proc.ExitCode -ne 0) {
        throw "Elevated run failed with exit code $($proc.ExitCode). See output above."
    }
}

function Resolve-Key([string]$name) {
    $k = $name.Trim()
    if (-not $VK.ContainsKey($k)) { throw "Unknown key name '$k'. See references/keymap-reference.md." }
    [int]$VK[$k]
}

function ConvertTo-VkString {
    param(
        [string]$Combo,
        [switch]$SingleKey,   # a key remap: exactly one key
        [switch]$Target       # the To side: a lone key is allowed (shortcut-to-single-key)
    )

    $parts = @($Combo -split '\+' | Where-Object { $_.Trim() })
    $codes = @($parts | ForEach-Object { Resolve-Key $_ })

    if ($SingleKey) {
        if ($codes.Count -ne 1) { throw "Expected a single key, got '$Combo'." }
        return "$($codes[0])"
    }
    if ($codes.Count -eq 1) {
        if ($Target) { return "$($codes[0])" }
        throw "A shortcut source needs a modifier plus an action key: '$Combo'."
    }
    if ($codes.Count -gt 4) { throw "PowerToys allows at most 4 keys in a shortcut: '$Combo'." }

    $mods   = @($codes | Where-Object { $ModRank.ContainsKey($_) } | Sort-Object { $ModRank[$_] })
    $action = @($codes | Where-Object { -not $ModRank.ContainsKey($_) })

    if ($mods.Count -eq 0)   { throw "A shortcut must start with a modifier: '$Combo'." }
    if ($action.Count -ne 1) { throw "A shortcut needs exactly one action key: '$Combo'." }

    (@($mods) + @($action)) -join ';'
}

function Get-Backups {
    @(Get-ChildItem $KbmDir -Filter 'default.json.bak-*' -File -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending)
}

function Restore-Backup {
    $bk = Get-Backups
    if ($bk.Count -eq 0) { Write-Host 'No backups found.' -ForegroundColor Yellow; return }
    Write-Host "`nAvailable backups (newest first):" -ForegroundColor Cyan
    $bk | ForEach-Object { "  $($_.Name)" }

    Get-Process | Where-Object { $_.ProcessName -like 'PowerToys*' } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
    Copy-Item $bk[0].FullName $Target -Force
    Write-Host "`nRestored from $($bk[0].Name)" -ForegroundColor Green

    # The manifest described the config we just replaced. A backup's intent is unknown, so
    # leaving a stale manifest would make Test-Setup suppress the wrong orphans and then
    # blame the mismatch on a GUI edit. Dropping it degrades cleanly to "unmanaged".
    if (Test-Path $ManifestPath) {
        Remove-Item $ManifestPath -Force
        Write-Host 'manifest removed (no longer describes this config)' -ForegroundColor DarkGray
    }
    if (-not $NoRestart -and (Test-Path $PtExe)) { Start-Process $PtExe }
}

# ---- flow -----------------------------------------------------------
# -DryRun must never mutate anything, so it is handled before the Restore dispatch and
# before the elevation bounce (a preview needs no admin rights).
if ($Restore -and $DryRun) {
    $bk = Get-Backups
    if ($bk.Count -eq 0) { Write-Host 'No backups found.' -ForegroundColor Yellow; return }
    Write-Host "`nWould restore the newest of:" -ForegroundColor Cyan
    $bk | ForEach-Object { "  $($_.Name)" }
    Write-Host "`n[DryRun] nothing restored.`n" -ForegroundColor Yellow
    return
}

if (-not $DryRun -and (Test-NeedsElevation)) {
    $flags = @()
    if ($Restore)   { $flags += '-Restore' }
    if ($NoRestart) { $flags += '-NoRestart' }
    Invoke-SelfElevated $flags
    return
}

if ($Restore) { Restore-Backup; return }

# ---- build ----------------------------------------------------------
$keyEntries = @()
$rows       = @()
foreach ($r in $KeyRemaps) {
    $f = ConvertTo-VkString $r.From -SingleKey
    $t = ConvertTo-VkString $r.To   -SingleKey
    $keyEntries += [ordered]@{ originalKeys = $f; newRemapKeys = $t }
    $rows += [pscustomobject]@{ Type = 'key'; From = $r.From; To = $r.To; VK = "$f -> $t"; Note = $r.Note }
}

$scEntries = @()
$seen      = @{}
$emitted   = @{}
foreach ($r in $ShortcutRemaps) {
    $f = ConvertTo-VkString $r.From
    $t = ConvertTo-VkString $r.To -Target
    if ($seen.ContainsKey($f)) {
        throw "Duplicate From: '$($r.From)' already claimed by '$($seen[$f])'. Only the first would ever match."
    }
    $seen[$f] = $r.From
    $emitted[$t] = $r.To
    $scEntries += [ordered]@{
        originalKeys  = $f
        exactMatch    = [bool]$r.ExactMatch
        operationType = 0
        newRemapKeys  = $t
    }
    $rows += [pscustomobject]@{ Type = 'shortcut'; From = $r.From; To = $r.To; VK = "$f -> $t"; Note = $r.Note }
}

# ---- orphan check ---------------------------------------------------
# A shortcut rule consumes its source combination. If no other rule emits that same
# combination, it becomes impossible to type at all -- the failure mode is a key that
# silently stops working rather than doing the wrong thing. Flag it unless the rule
# said AllowOrphan.
$orphans        = @()
$allowedOrphans = @()
foreach ($r in $ShortcutRemaps) {
    $f = ConvertTo-VkString $r.From
    if ($emitted.ContainsKey($f)) { continue }
    if ($r.AllowOrphan) { $allowedOrphans += $f; continue }
    $orphans += $r
}
if ($orphans.Count -gt 0) {
    Write-Host ''
    Write-Host 'ORPHANED COMBINATIONS' -ForegroundColor Red
    Write-Host 'These rules consume a combination that nothing else emits, so it can no'
    Write-Host 'longer be typed. Add the reverse rule, or set AllowOrphan = $true if intended.'
    Write-Host ''
    foreach ($o in $orphans) { "  $($o.From)  (consumed by '$($o.From) -> $($o.To)')" }
    Write-Host ''
    throw "Refusing to write config: $($orphans.Count) unacknowledged orphan(s)."
}

$cfg = [ordered]@{
    remapKeys            = [ordered]@{ inProcess = @($keyEntries) }
    remapKeysToText      = [ordered]@{ inProcess = @() }
    remapShortcuts       = [ordered]@{ global = @($scEntries); appSpecific = @() }
    remapShortcutsToText = [ordered]@{ global = @(); appSpecific = @() }
}
$json = $cfg | ConvertTo-Json -Depth 6 -Compress

Write-Host ''
$rows | Format-Table Type, From, To, VK, Note -AutoSize | Out-String | Write-Host
Write-Host ("$($keyEntries.Count) key remap(s) / $($scEntries.Count) shortcut remap(s)") -ForegroundColor Cyan

if ($DryRun) {
    Write-Host "`n[DryRun] nothing written.`n" -ForegroundColor Yellow
    Write-Host $json
    return
}

# ---- apply ----------------------------------------------------------
if (-not (Test-Path $KbmDir)) {
    throw "Keyboard Manager config directory not found: $KbmDir`nInstall and run PowerToys once first (.\Install-Tools.ps1)."
}

Get-Process | Where-Object { $_.ProcessName -like 'PowerToys*' } |
    Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 800

try {
    if (Test-Path $Target) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        Copy-Item $Target (Join-Path $KbmDir "default.json.bak-$stamp") -Force
        Write-Host "backup: default.json.bak-$stamp" -ForegroundColor DarkGray
    }
    [IO.File]::WriteAllText($Target, $json, (New-Object Text.UTF8Encoding $false))
    Write-Host "written: $Target" -ForegroundColor Green

    # Sidecar manifest. default.json's schema belongs to PowerToys, so intent that PowerToys
    # has no field for is recorded alongside it instead: which orphans were deliberate (so
    # Test-Setup can stay high-signal), and a hash so a later GUI edit is detectable before
    # this script silently overwrites it.
    $manifest = [ordered]@{
        generatedBy       = 'wintomac/Set-MacKeymap.ps1'
        generatedAt       = (Get-Date -Format 'o')
        allowedOrphans    = @($allowedOrphans)
        defaultJsonSha256 = (Get-FileHash $Target -Algorithm SHA256).Hash
    }
    $manifest | ConvertTo-Json -Depth 4 | Set-Content $ManifestPath -Encoding utf8
    if ($allowedOrphans.Count) {
        Write-Host "manifest: $($allowedOrphans.Count) acknowledged orphan(s) recorded" -ForegroundColor DarkGray
    }
}
finally {
    # PowerToys is already stopped at this point. Bringing it back even when the write
    # failed matters more than reporting cleanly -- leaving it down means the keyboard
    # silently reverts to stock behaviour with no indication why.
    if (-not $NoRestart) {
        if (Test-Path $PtExe) {
            Start-Process $PtExe
            Write-Host 'PowerToys restarted' -ForegroundColor Green
            Write-Host 'Confirm 3-key rules with physical Cmd+Shift+4 -- the capture overlay should appear.' -ForegroundColor DarkGray
        } else {
            Write-Host "PowerToys.exe not found at $PtExe -- start it manually." -ForegroundColor Yellow
        }
    }
}
