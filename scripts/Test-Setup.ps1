<#
.SYNOPSIS
    Verify the WinToMac setup against what is actually true, not what should be.

.DESCRIPTION
    Checks token-level elevation of the running PowerToys processes, the keymap rule counts
    and orphans, module enable flags, Desktop shortcut targets, and Sysinternals signatures.

    Elevation is checked via GetTokenInformation(TokenElevation) because the two obvious
    checks both lie:
      * Process.Handle succeeds on elevated processes (.NET opens it with limited rights),
        so a successful handle does not mean the target is unelevated.
      * settings.json's is_elevated is written on exit and reports the previous session.

    The process that matters is PowerToys.KeyboardManagerEngine -- that is what performs the
    remapping. PowerToys.exe being elevated is necessary but not what does the work.

.EXAMPLE
    .\Test-Setup.ps1
#>
[CmdletBinding()]
param(
    [string]$SysinternalsPath = "$env:LOCALAPPDATA\Programs\Sysinternals",
    [string]$ShortcutDir     = "$env:USERPROFILE\Desktop\Tools"
)

$ErrorActionPreference = 'Stop'

$KbmDir   = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys\Keyboard Manager'
$Default  = Join-Path $KbmDir 'default.json'
$Settings = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys\settings.json'

$script:Fail = 0
$script:Warn = 0
function Ok($m)    { Write-Host "  [ok]   $m" -ForegroundColor Green }
function Bad($m)   { Write-Host "  [FAIL] $m" -ForegroundColor Red;    $script:Fail++ }
function Note($m)  { Write-Host "  [warn] $m" -ForegroundColor Yellow; $script:Warn++ }
function Info($m)  { Write-Host "         $m" -ForegroundColor DarkGray }
function Section($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }

if (-not ('TokenElev' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class TokenElev {
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool OpenProcessToken(IntPtr h, uint access, out IntPtr tok);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool GetTokenInformation(IntPtr tok, int cls, out uint info, uint len, out uint ret);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    // 0x1000 = PROCESS_QUERY_LIMITED_INFORMATION (works across integrity levels)
    // 0x0008 = TOKEN_QUERY, 20 = TokenElevation
    public static string Check(int pid) {
        IntPtr h = OpenProcess(0x1000, false, pid);
        if (h == IntPtr.Zero) return "unknown";
        IntPtr tok;
        if (!OpenProcessToken(h, 0x0008, out tok)) { CloseHandle(h); return "unknown"; }
        uint elev, ret;
        bool ok = GetTokenInformation(tok, 20, out elev, 4, out ret);
        CloseHandle(tok); CloseHandle(h);
        if (!ok) return "unknown";
        return elev != 0 ? "elevated" : "normal";
    }
}
'@
}

# ---- 1. processes and elevation --------------------------------------
Section 'PowerToys processes'
# Scope to this logon session: on a shared or multi-user machine another session's
# PowerToys would otherwise be counted and reported.
$mySession = (Get-Process -Id $PID).SessionId
$procs = @(Get-Process | Where-Object {
    $_.ProcessName -like 'PowerToys*' -and $_.SessionId -eq $mySession
})
if ($procs.Count -eq 0) {
    Bad 'PowerToys is not running -- no remaps are active at all.'
} else {
    foreach ($p in $procs | Sort-Object ProcessName) {
        '         {0,-34} pid {1,-7} {2}' -f $p.ProcessName, $p.Id, [TokenElev]::Check($p.Id) | Write-Host
    }
    # Force an array: with more than one engine, $eng.Id would be an Object[] and the
    # Check(int) call would throw instead of reporting.
    $eng = @($procs | Where-Object { $_.ProcessName -eq 'PowerToys.KeyboardManagerEngine' })
    if ($eng.Count -eq 0) {
        Bad 'KeyboardManagerEngine is not running -- Keyboard Manager module is off or crashed.'
    } else {
        if ($eng.Count -gt 1) { Note "$($eng.Count) KeyboardManagerEngine processes -- expected one; a stale instance may be fighting the live one" }
        $states = @($eng | ForEach-Object { [TokenElev]::Check($_.Id) })
        if ($states -contains 'elevated') {
            Ok 'KeyboardManagerEngine is elevated -- remaps apply in elevated windows too.'
        } else {
            Note 'KeyboardManagerEngine is NOT elevated -- remaps will silently stop working'
            Info 'whenever an elevated window (Procmon, Autoruns, RAMMap) has focus.'
            Info 'Fix: .\Set-PTConfig.ps1 -EnableAdminMode'
        }
    }
}

# ---- 2. settings -----------------------------------------------------
Section 'settings.json'
if (-not (Test-Path $Settings)) {
    Bad "not found: $Settings"
} else {
    $s = $null
    try { $s = Get-Content $Settings -Raw | ConvertFrom-Json } catch { }
    if (-not $s -or -not $s.enabled) {
        Bad "settings.json is empty or malformed: $Settings"
    } else {
        if ($s.run_elevated) { Ok 'run_elevated = true' } else { Note 'run_elevated = false' }
        if ($s.startup)      { Ok 'startup = true' }      else { Note 'startup = false (will not launch at login)' }
        Info "version: $($s.powertoys_version)"
        Info "is_elevated = $($s.is_elevated)  <- stale by design, ignore for live state"
        if (-not $s.enabled.'Keyboard Manager') {
            Bad 'Keyboard Manager module is DISABLED -- the entire keymap is inert.'
        } else { Ok 'Keyboard Manager module enabled' }
    }
}

# ---- 3. keymap -------------------------------------------------------
Section 'Keyboard Manager keymap'
if (-not (Test-Path $Default)) {
    Bad "not found: $Default"
} else {
    $j = Get-Content $Default -Raw | ConvertFrom-Json
    $keys = @($j.remapKeys.inProcess)
    $scs  = @($j.remapShortcuts.global)
    Ok "$($keys.Count) key remap(s), $($scs.Count) global shortcut remap(s)"
    if (@($j.remapShortcuts.appSpecific).Count) { Info "$(@($j.remapShortcuts.appSpecific).Count) app-specific rule(s)" }

    # Read the manifest and settle whether it still describes this file BEFORE using it.
    # Trusting allowedOrphans from a manifest that no longer matches (after a -Restore, or
    # a GUI edit) would suppress the wrong orphans using another config's intent.
    $manifestPath = Join-Path $KbmDir 'wintomac.manifest.json'
    $manifest = $null; $manifestFresh = $false; $allowed = @()
    if (Test-Path $manifestPath) {
        try { $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json } catch { }
    }
    if ($manifest) {
        $hashNow = (Get-FileHash $Default -Algorithm SHA256).Hash
        $manifestFresh = ($manifest.defaultJsonSha256 -eq $hashNow)
        if ($manifestFresh) {
            $allowed = @($manifest.allowedOrphans)
            Ok 'default.json matches the manifest (no out-of-band edits)'
        } else {
            Note 'default.json does not match the manifest -- it was changed out of band'
            Info 'Usually an edit in the Keyboard Manager GUI, or a -Restore. Re-running'
            Info 'Set-MacKeymap.ps1 will overwrite it, so port the change into the table first.'
            Info 'Treating the config as unmanaged: acknowledged-orphan data is not applied.'
        }
    }

    # A shortcut rule consumes its source combination. If nothing emits that same
    # combination, it can no longer be typed -- the symptom is a key that quietly stops
    # working rather than doing the wrong thing. Deliberate orphans are common
    # (Cmd+Q -> Alt+F4 intentionally eats Ctrl+Q), so a fresh manifest's list is
    # subtracted to keep this check high-signal.
    $emitted = @{}
    foreach ($r in $scs) { $emitted[$r.newRemapKeys] = $true }
    $orphans = @($scs | Where-Object {
        -not $emitted.ContainsKey($_.originalKeys) -and $_.originalKeys -notin $allowed
    })

    if ($orphans.Count -eq 0) {
        if ($allowed.Count) { Ok "no unexpected orphans ($($allowed.Count) acknowledged)" }
        else                { Ok 'no orphaned combinations' }
    } else {
        Note "$($orphans.Count) combination(s) consumed but never emitted (unreachable):"
        foreach ($o in $orphans) { Info "$($o.originalKeys) -> $($o.newRemapKeys)" }
        if ($manifestFresh) {
            Info 'Not in the manifest, so not acknowledged. Add the reverse rule, or set'
            Info 'AllowOrphan = $true on that rule in Set-MacKeymap.ps1.'
        } else {
            Info 'Without a matching manifest, deliberate and accidental cannot be told apart.'
            Info 'Generating the config with Set-MacKeymap.ps1 makes this check meaningful.'
        }
    }

    # AltGr is LCtrl+RAlt, so remapping *either* of those can break it. Restricting the
    # swap to left-hand modifiers does not make it AltGr-safe -- LCtrl is half of AltGr.
    $altgrKeys = @($keys | Where-Object { $_.originalKeys -eq '162' -or $_.originalKeys -eq '165' -or
                                          $_.newRemapKeys -eq '162' -or $_.newRemapKeys -eq '165' })
    if ($altgrKeys.Count) {
        Note 'LCtrl (162) or RAlt (165) is remapped -- AltGr is LCtrl+RAlt, so AltGr characters'
        Info 'may break on ISO/European layouts. Korean 101/103-key layouts route Hangul on a'
        Info 'dedicated key and are usually unaffected. See gotchas section 6.'
    } else {
        Ok 'neither half of AltGr (LCtrl/RAlt) is remapped'
    }
    $otherRhs = @($keys | Where-Object { $_.originalKeys -eq '161' -or $_.originalKeys -eq '163' })
    if ($otherRhs.Count) { Note 'RShift (161) or RCtrl (163) is remapped -- unusual; check this is intended' }

    $bk = @(Get-ChildItem $KbmDir -Filter 'default.json.bak-*' -File -ErrorAction SilentlyContinue)
    Info "$($bk.Count) backup(s) available (.\Set-MacKeymap.ps1 -Restore)"
}

# ---- 4. modules referenced by the keymap -----------------------------
Section 'Modules targeted by keymap'
if ((Test-Path $Settings) -and (Test-Path $Default)) {
    $s = $null
    try { $s = Get-Content $Settings -Raw | ConvertFrom-Json } catch { }
    $j = Get-Content $Default -Raw | ConvertFrom-Json
    if ($s -and $s.enabled) {
        $emit = @($j.remapShortcuts.global | ForEach-Object { $_.newRemapKeys })

        # 164;192 = Alt+Backtick -> Window Hopper's default activation
        if ($emit -contains '164;192' -or $emit -contains '164;160;192') {
            if ($s.enabled.AltWindowCycle) {
                Ok 'Window Hopper (AltWindowCycle) enabled -- Cmd+backtick rules are live'
            } else {
                Bad 'keymap emits Alt+backtick but Window Hopper (AltWindowCycle) is DISABLED -- dead rule'
                Info "Fix: .\Set-PTConfig.ps1 -EnableModules 'Window Hopper'"
            }
        }
        if ($s.enabled.ZoomIt -and (Test-Path (Join-Path $SysinternalsPath 'ZoomIt64.exe'))) {
            Note 'PowerToys ZoomIt is on and standalone Sysinternals ZoomIt is installed -- hotkey clash if both run'
        }
    }
}

# ---- 5. shortcuts ----------------------------------------------------
Section "Shortcuts ($ShortcutDir)"
if (-not (Test-Path $ShortcutDir)) {
    Note 'shortcut folder not found (run .\Install-Tools.ps1)'
} else {
    $sh = New-Object -ComObject WScript.Shell
    $lnks = @(Get-ChildItem $ShortcutDir -Filter *.lnk -File)
    if ($lnks.Count -eq 0) {
        Note 'no shortcuts in the folder'
    } else {
        $broken = @()
        foreach ($l in $lnks) {
            $t = $sh.CreateShortcut($l.FullName).TargetPath
            if (-not $t -or -not (Test-Path $t)) { $broken += "$($l.BaseName) -> $t" }
        }
        if ($broken.Count -eq 0) { Ok "$($lnks.Count) shortcut(s), all targets resolve" }
        else {
            Bad "$($broken.Count) broken shortcut(s):"
            $broken | ForEach-Object { Info $_ }
        }
    }
}

# ---- 6. Sysinternals -------------------------------------------------
Section 'Sysinternals'
if (-not (Test-Path $SysinternalsPath)) {
    Note "not installed at $SysinternalsPath"
} else {
    $exes = @(Get-ChildItem $SysinternalsPath -Filter *.exe -File -ErrorAction SilentlyContinue)
    if ($exes.Count -eq 0) {
        Note "no .exe files under $SysinternalsPath -- nothing to check (install incomplete?)"
    } else {
        Ok "$($exes.Count) executable(s) at $SysinternalsPath"
        # Spot-check rather than all of them; a full pass over 150 binaries is slow.
        $sample = @($exes | Get-Random -Count ([Math]::Min(8, $exes.Count)))
        $bad = @($sample | Where-Object {
            $sig = Get-AuthenticodeSignature $_.FullName
            $sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation'
        })
        if ($bad.Count -eq 0) { Ok "signature spot-check passed ($($sample.Count) sampled)" }
        else { Bad "$($bad.Count) of $($sample.Count) sampled binaries failed signature check" }
        $newest = ($exes | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
        Info "newest binary: $newest  (no auto-update; re-run Install-Tools.ps1 to refresh)"
    }
}

# ---- summary ---------------------------------------------------------
Write-Host ''
if ($script:Fail -eq 0 -and $script:Warn -eq 0) {
    Write-Host 'All checks passed.' -ForegroundColor Green
} else {
    Write-Host "$($script:Fail) failure(s), $($script:Warn) warning(s)." -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Yellow' })
}
Write-Host 'Config being written is not proof the OS honours it. Confirm with a visible test:' -ForegroundColor DarkGray
Write-Host 'press physical Cmd+Shift+4 -- the capture overlay should appear.' -ForegroundColor DarkGray
exit $script:Fail
