<#
.SYNOPSIS
    Install PowerToys and the Sysinternals Suite, and build a Desktop\Tools shortcut folder.

.DESCRIPTION
    PowerToys installs cleanly via winget.

    Sysinternals does not. Sysinternals republishes new builds over one stable zip URL, so
    winget's manifest hash goes stale constantly and the install fails with "Installer hash
    does not match". The usual workaround, --ignore-security-hash, disables verification
    outright. This script instead fetches the same official URL and verifies the Authenticode
    signature of every executable in the archive -- a stronger check than a zip hash, since it
    proves Microsoft signed each binary. Extraction goes to a staging directory first, so a
    verification failure never reaches the install path.

.EXAMPLE
    .\Install-Tools.ps1
    .\Install-Tools.ps1 -SkipSysinternals
    .\Install-Tools.ps1 -ShortcutDir "$env:USERPROFILE\Desktop\Utils"
#>
[CmdletBinding()]
param(
    [switch]$SkipPowerToys,
    [switch]$SkipSysinternals,
    [switch]$SkipShortcuts,
    [string]$SysinternalsPath = "$env:LOCALAPPDATA\Programs\Sysinternals",
    [string]$ShortcutDir     = "$env:USERPROFILE\Desktop\Tools"
)

$ErrorActionPreference = 'Stop'
$SysinternalsUrl = 'https://download.sysinternals.com/files/SysinternalsSuite.zip'
$PtExeUser    = Join-Path $env:LOCALAPPDATA 'PowerToys\PowerToys.exe'
$PtExeMachine = Join-Path $env:ProgramFiles 'PowerToys\PowerToys.exe'

# Extensions that must carry a valid Microsoft Authenticode signature.
$MustBeSigned = @('.exe', '.dll', '.sys', '.ocx', '.scr', '.msi', '.cmd', '.bat', '.ps1', '.vbs', '.js')
# Inert data the suite legitimately ships. Compiled help is on this list because .chm files
# are not Authenticode-signed; they ride on the HTTPS origin and the signed binaries beside
# them. Anything outside both lists is refused rather than installed unexamined.
$InertAllowed = @('.txt', '.chm', '.md', '.htm', '.html', '.xml', '.json', '.pdb')

function Write-Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }

function Get-PowerToysPath {
    foreach ($p in @($PtExeUser, $PtExeMachine)) { if (Test-Path $p) { return $p } }
    $null
}

# ---- PowerToys -------------------------------------------------------
if (-not $SkipPowerToys) {
    Write-Step 'PowerToys'
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw 'winget not found. Install "App Installer" from the Microsoft Store first.'
    }

    # Test for the binary rather than grepping winget's table. "winget list --id" is a
    # substring filter and PowerToys also registers sparse MSIX context-menu packages, so
    # matching the name in that output reports "installed" when only those are present.
    $existing = Get-PowerToysPath
    if ($existing) {
        Write-Host "already installed: $existing" -ForegroundColor DarkGray
        # winget upgrade exits non-zero when there is nothing to upgrade, which is not a
        # failure -- so its exit code is reported, not thrown on.
        winget upgrade --exact --id Microsoft.PowerToys `
            --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 |
            Out-String | Write-Host
        Write-Host "(winget upgrade exit code $LASTEXITCODE -- non-zero usually just means 'no update available')" -ForegroundColor DarkGray
    } else {
        winget install --exact --id Microsoft.PowerToys --source winget `
            --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 |
            Out-String | Write-Host
        $code = $LASTEXITCODE
        if (-not (Get-PowerToysPath)) {
            throw "PowerToys install did not produce an executable (winget exit code $code)."
        }
        Write-Host "installed: $(Get-PowerToysPath)" -ForegroundColor Green
    }
}

# ---- Sysinternals ----------------------------------------------------
if (-not $SkipSysinternals) {
    Write-Step 'Sysinternals Suite'

    $zip   = Join-Path ([IO.Path]::GetTempPath()) 'SysinternalsSuite.zip'
    $stage = Join-Path ([IO.Path]::GetTempPath()) "sysinternals-stage-$(Get-Date -Format 'yyyyMMddHHmmss')"

    try {
        Write-Host "downloading $SysinternalsUrl"
        Invoke-WebRequest -Uri $SysinternalsUrl -OutFile $zip -UseBasicParsing
        Write-Host ('downloaded {0:N1} MB' -f ((Get-Item $zip).Length / 1MB))

        New-Item -ItemType Directory -Force -Path $stage | Out-Null
        Expand-Archive -Path $zip -DestinationPath $stage -Force

        # Verify everything that will actually be copied, not just top-level *.exe -- the
        # copy below is recursive, so a narrower check would install unexamined files.
        $files = @(Get-ChildItem $stage -Recurse -File)
        if ($files.Count -eq 0) { throw 'Archive contained no files; refusing to install.' }

        $signable = @($files | Where-Object { $MustBeSigned -contains $_.Extension.ToLower() })
        $inert    = @($files | Where-Object { $InertAllowed -contains $_.Extension.ToLower() })
        $unknown  = @($files | Where-Object {
            ($MustBeSigned  -notcontains $_.Extension.ToLower()) -and
            ($InertAllowed -notcontains $_.Extension.ToLower())
        })

        Write-Host "archive: $($files.Count) file(s) -- $($signable.Count) signable, $($inert.Count) inert, $($unknown.Count) unrecognised"

        if ($unknown.Count -gt 0) {
            Write-Host "`nUNRECOGNISED FILE TYPES" -ForegroundColor Red
            $unknown | Select-Object -First 10 | ForEach-Object { "  $($_.Name)" }
            throw "$($unknown.Count) file(s) of unrecognised type. Refusing to install. Add the extension to `$MustBeSigned or `$InertAllowed after checking what it is."
        }
        if ($signable.Count -eq 0) { throw 'No signable binaries found; refusing to install.' }

        $bad = @()
        foreach ($f in $signable) {
            $s = Get-AuthenticodeSignature $f.FullName
            if ($s.Status -ne 'Valid' -or $s.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
                $bad += [pscustomobject]@{ Name = $f.Name; Status = $s.Status; Subject = $s.SignerCertificate.Subject }
            }
        }

        if ($bad.Count -gt 0) {
            Write-Host "`nSIGNATURE VERIFICATION FAILED" -ForegroundColor Red
            $bad | Select-Object -First 10 | ForEach-Object { "  $($_.Name)  [$($_.Status)]  $($_.Subject)" }
            throw "$($bad.Count) binary/binaries not validly signed by Microsoft. Nothing installed."
        }
        Write-Host "verified $($signable.Count) binary/binaries, all validly signed by Microsoft" -ForegroundColor Green

        # Copy file by file. A running Sysinternals tool holds its image locked, so a bulk
        # Copy-Item -Force throws partway through and abandons the rest of the install --
        # which is exactly what "re-run to refresh" would hit. Locked files are collected
        # and reported instead, leaving everything else updated.
        New-Item -ItemType Directory -Force -Path $SysinternalsPath | Out-Null
        $locked = @(); $copied = 0
        foreach ($f in $files) {
            $rel  = $f.FullName.Substring($stage.Length).TrimStart('\')
            $dest = Join-Path $SysinternalsPath $rel
            $dir  = Split-Path $dest -Parent
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            try { Copy-Item $f.FullName $dest -Force -ErrorAction Stop; $copied++ }
            catch { $locked += $rel }
        }

        Write-Host "installed $copied file(s) to $SysinternalsPath" -ForegroundColor Green
        if ($locked.Count -gt 0) {
            Write-Host "`n$($locked.Count) file(s) in use and left at the old version:" -ForegroundColor Yellow
            $locked | Select-Object -First 10 | ForEach-Object { "  $_" }
            Write-Host 'Close those tools and re-run to finish updating them.' -ForegroundColor Yellow
        }
        Write-Host 'Each tool shows its EULA on first run; accept it yourself rather than' -ForegroundColor DarkGray
        Write-Host 'pre-setting HKCU\Software\Sysinternals\*\EulaAccepted.' -ForegroundColor DarkGray
        Write-Host 'No auto-update: re-run this script to refresh.' -ForegroundColor DarkGray
    }
    finally {
        Remove-Item $zip   -Force -ErrorAction SilentlyContinue
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---- shortcuts -------------------------------------------------------
if (-not $SkipShortcuts) {
    Write-Step "Shortcuts -> $ShortcutDir"

    New-Item -ItemType Directory -Force -Path $ShortcutDir | Out-Null
    $sh = New-Object -ComObject WScript.Shell
    $pt = Get-PowerToysPath

    $map = @(
        @{ Name = 'PowerToys';        Target = $pt;                                             Desc = 'PowerToys' }
        @{ Name = 'Process Explorer'; Target = Join-Path $SysinternalsPath 'procexp64.exe';      Desc = 'Task Manager, but complete' }
        @{ Name = 'Process Monitor';  Target = Join-Path $SysinternalsPath 'Procmon64.exe';      Desc = 'File/Registry/Network call tracing (self-elevates)' }
        @{ Name = 'Autoruns';         Target = Join-Path $SysinternalsPath 'Autoruns64.exe';     Desc = 'Every autostart entry (needs admin)' }
        @{ Name = 'TCPView';          Target = Join-Path $SysinternalsPath 'tcpview64.exe';      Desc = 'Live per-process connections' }
        @{ Name = 'RAMMap';           Target = Join-Path $SysinternalsPath 'RAMMap64.exe';       Desc = 'Physical memory breakdown (needs admin)' }
        @{ Name = 'VMMap';            Target = Join-Path $SysinternalsPath 'vmmap64.exe';        Desc = 'Per-process virtual memory' }
        @{ Name = 'Desktops';         Target = Join-Path $SysinternalsPath 'Desktops.exe';       Desc = 'Four real virtual desktops' }
        @{ Name = 'WinObj';           Target = Join-Path $SysinternalsPath 'Winobj64.exe';       Desc = 'NT object namespace browser' }
        @{ Name = 'ZoomIt';           Target = Join-Path $SysinternalsPath 'ZoomIt64.exe';       Desc = 'Zoom, annotate, record' }
    )

    $made = 0; $skipped = @()
    foreach ($m in $map) {
        if (-not $m.Target -or -not (Test-Path $m.Target)) { $skipped += $m.Name; continue }
        $l = $sh.CreateShortcut((Join-Path $ShortcutDir "$($m.Name).lnk"))
        $l.TargetPath       = $m.Target
        $l.WorkingDirectory = Split-Path $m.Target -Parent
        $l.Description      = $m.Desc
        $l.Save()
        $made++
        Write-Host "  + $($m.Name)"
    }

    if (Test-Path $SysinternalsPath) {
        $n = @(Get-ChildItem $SysinternalsPath -Filter *.exe -File).Count
        $l = $sh.CreateShortcut((Join-Path $ShortcutDir "Sysinternals (all $n tools).lnk"))
        $l.TargetPath  = $SysinternalsPath
        $l.Description = 'Full Sysinternals Suite folder'
        $l.Save()
        $made++
        Write-Host "  + Sysinternals (all $n tools)"
    }

    Write-Host "$made shortcut(s) created" -ForegroundColor Green
    if ($skipped.Count -gt 0) {
        Write-Host "skipped (target missing): $($skipped -join ', ')" -ForegroundColor Yellow
    }

    # ZoomIt ships in both places and both bind the same style of hotkey, so running the
    # standalone while PowerToys' ZoomIt module is on makes them fight over it.
    Write-Host 'If PowerToys ZoomIt is enabled, leave the standalone ZoomIt closed (hotkey clash).' -ForegroundColor DarkGray
}

Write-Host "`nNext: .\Set-MacKeymap.ps1 -DryRun" -ForegroundColor Cyan
