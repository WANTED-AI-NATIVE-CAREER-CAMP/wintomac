<#
.SYNOPSIS
    Install this skill into ~/.claude/skills, verify it, or re-package it for sharing.

.DESCRIPTION
    Distribution needs no registry, no GitHub, and no credentials: a .skill file is a zip
    whose entries are prefixed with the skill folder name, and Claude Code reads skills from
    ~/.claude/skills (personal) or <project>/.claude/skills (project-scoped). This script is
    the three operations around that.

    -Install  copy the skill folder to the skills directory, verifying first
    -Verify   check the package is well-formed without changing anything
    -Package  build a .skill file from the skill folder, for handing to someone else

    Run it from anywhere; it locates the skill by its own path (scripts/.. is the skill root).

.EXAMPLE
    .\Install-Skill.ps1 -Verify
    .\Install-Skill.ps1 -Install
    .\Install-Skill.ps1 -Install -Scope Project -ProjectPath C:\work\myrepo
    .\Install-Skill.ps1 -Package -OutDir ~\Desktop
#>
[CmdletBinding(DefaultParameterSetName = 'Verify')]
param(
    [Parameter(ParameterSetName = 'Install')][switch]$Install,
    [Parameter(ParameterSetName = 'Verify')][switch]$Verify,
    [Parameter(ParameterSetName = 'Package')][switch]$Package,

    [Parameter(ParameterSetName = 'Install')]
    [ValidateSet('User', 'Project')]
    [string]$Scope = 'User',

    [Parameter(ParameterSetName = 'Install')][string]$ProjectPath,
    [Parameter(ParameterSetName = 'Install')][switch]$Force,
    [Parameter(ParameterSetName = 'Package')][string]$OutDir = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'

$SkillRoot = Split-Path $PSScriptRoot -Parent
$SkillName = Split-Path $SkillRoot -Leaf

# Excluded from a package: build artefacts and the eval harness, which is development-time
# only. Matches what the official packager drops.
$ExcludeDirs  = @('__pycache__', 'node_modules', 'evals', '.git')
$ExcludeFiles = @('.DS_Store', 'Thumbs.db')

function Ok($m)   { Write-Host "  [ok]   $m" -ForegroundColor Green }
function Bad($m)  { Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Info($m) { Write-Host "         $m" -ForegroundColor DarkGray }

function Get-PackageFiles {
    Get-ChildItem $SkillRoot -Recurse -File | Where-Object {
        $rel   = $_.FullName.Substring($SkillRoot.Length).TrimStart('\')
        $parts = $rel -split '\\'
        -not ($parts | Where-Object { $ExcludeDirs -contains $_ }) -and
        ($ExcludeFiles -notcontains $_.Name) -and
        ($_.Extension -ne '.pyc')
    }
}

# A skill is only valid if Claude Code can read its metadata, so the checks here are the
# ones that decide whether it loads at all: SKILL.md present, YAML frontmatter parseable,
# name and description present. Everything else is a warning.
function Test-Skill {
    Write-Host "`n=== Verifying $SkillName ===" -ForegroundColor Cyan
    $fail = 0

    $md = Join-Path $SkillRoot 'SKILL.md'
    if (-not (Test-Path $md)) { Bad 'SKILL.md missing -- the skill cannot load'; return 1 }
    Ok 'SKILL.md present'

    $lines = Get-Content $md
    if ($lines.Count -lt 3 -or $lines[0].Trim() -ne '---') {
        Bad 'SKILL.md does not start with a --- frontmatter fence'; $fail++
    } else {
        $end = -1
        for ($i = 1; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -eq '---') { $end = $i; break } }
        if ($end -lt 0) { Bad 'frontmatter is not closed by a second ---'; $fail++ }
        else {
            $fm = $lines[1..($end - 1)]
            foreach ($field in 'name', 'description') {
                $hit = @($fm | Where-Object { $_ -match "^${field}\s*:" })
                if ($hit.Count -eq 0) { Bad "frontmatter has no '$field'"; $fail++ }
                else {
                    $val = ($hit[0] -replace "^${field}\s*:\s*", '').Trim()
                    if (-not $val) { Bad "'$field' is empty"; $fail++ }
                    else { Ok "$field present ($($val.Length) chars)" }
                }
            }
            $nameLine = @($fm | Where-Object { $_ -match '^name\s*:' })
            if ($nameLine.Count) {
                $declared = ($nameLine[0] -replace '^name\s*:\s*', '').Trim()
                if ($declared -ne $SkillName) {
                    Bad "frontmatter name '$declared' does not match folder name '$SkillName'"
                    Info 'Claude Code addresses the skill by folder name; a mismatch is confusing at best.'
                    $fail++
                } else { Ok "name matches folder ($SkillName)" }
            }
            $bodyLines = $lines.Count - $end - 1
            if ($bodyLines -gt 500) { Info "SKILL.md body is $bodyLines lines -- over the ~500 guideline; consider moving detail into references/" }
            else { Ok "body is $bodyLines lines" }
        }
    }

    # Any relative path SKILL.md points at must exist, or the skill sends its reader nowhere.
    $body = Get-Content $md -Raw
    $refs = [regex]::Matches($body, '(?:references|scripts|assets)/[A-Za-z0-9._-]+') |
            ForEach-Object { $_.Value } | Sort-Object -Unique
    $missing = @($refs | Where-Object { -not (Test-Path (Join-Path $SkillRoot ($_ -replace '/', '\'))) })
    if ($missing.Count) {
        Bad "$($missing.Count) referenced file(s) do not exist:"
        $missing | ForEach-Object { Info $_ }
        $fail++
    } elseif ($refs.Count) { Ok "$($refs.Count) referenced file(s) all exist" }

    $ps1 = @(Get-ChildItem (Join-Path $SkillRoot 'scripts') -Filter *.ps1 -File -ErrorAction SilentlyContinue)
    $bad = @()
    foreach ($f in $ps1) {
        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs) | Out-Null
        if ($errs.Count) { $bad += "$($f.Name): $($errs[0].Message)" }
    }
    if ($bad.Count) { Bad "$($bad.Count) script(s) have parse errors:"; $bad | ForEach-Object { Info $_ }; $fail++ }
    elseif ($ps1.Count) { Ok "$($ps1.Count) script(s) parse cleanly" }

    $files = @(Get-PackageFiles)
    $kb = [Math]::Round((($files | Measure-Object Length -Sum).Sum) / 1KB, 1)
    Info "$($files.Count) file(s), $kb KB total"

    if ($fail -eq 0) { Write-Host "`nValid." -ForegroundColor Green }
    else { Write-Host "`n$fail problem(s)." -ForegroundColor Red }
    $fail
}

# ---- verify ----------------------------------------------------------
if ($Verify -or $PSCmdlet.ParameterSetName -eq 'Verify') {
    exit (Test-Skill)
}

# ---- install ---------------------------------------------------------
if ($Install) {
    if ((Test-Skill) -ne 0) { throw 'Refusing to install an invalid skill. Fix the problems above.' }

    if ($Scope -eq 'Project') {
        if (-not $ProjectPath) { throw 'Pass -ProjectPath when using -Scope Project.' }
        if (-not (Test-Path $ProjectPath)) { throw "Project path not found: $ProjectPath" }
        $skillsDir = Join-Path $ProjectPath '.claude\skills'
    } else {
        $skillsDir = Join-Path $env:USERPROFILE '.claude\skills'
    }
    $dest = Join-Path $skillsDir $SkillName

    if ((Resolve-Path $SkillRoot).Path -eq (Resolve-Path $skillsDir -ErrorAction SilentlyContinue | ForEach-Object Path | Where-Object { $_ } | Select-Object -First 1)) {
        # not the same thing, but guard the obvious self-copy below
    }
    if (Test-Path $dest) {
        $sameplace = (Resolve-Path $dest).Path -eq (Resolve-Path $SkillRoot).Path
        if ($sameplace) {
            Write-Host "`nAlready installed at $dest (running from it)." -ForegroundColor Green
            return
        }
        if (-not $Force) {
            throw "$dest already exists. Re-run with -Force to overwrite it (a backup copy is kept)."
        }
        $bak = "$dest.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Move-Item $dest $bak
        Write-Host "existing install moved to $bak" -ForegroundColor DarkGray
    }

    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    foreach ($f in Get-PackageFiles) {
        $rel = $f.FullName.Substring($SkillRoot.Length).TrimStart('\')
        $to  = Join-Path $dest $rel
        $dir = Split-Path $to -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Copy-Item $f.FullName $to -Force
    }
    Write-Host "`nInstalled to $dest" -ForegroundColor Green
    Write-Host 'Start a new Claude Code session to pick it up, then ask for anything the' -ForegroundColor DarkGray
    Write-Host 'description covers -- or invoke it by name.' -ForegroundColor DarkGray
    return
}

# ---- package ---------------------------------------------------------
if ($Package) {
    if ((Test-Skill) -ne 0) { throw 'Refusing to package an invalid skill. Fix the problems above.' }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
    $out = Join-Path (Resolve-Path $OutDir) "$SkillName.skill"
    if ([IO.File]::Exists($out)) { [IO.File]::Delete($out) }

    # Entries must be prefixed with the skill folder name, so the archive expands into a
    # folder rather than scattering SKILL.md into the current directory.
    $zip = [IO.Compression.ZipFile]::Open($out, 'Create')
    try {
        foreach ($f in Get-PackageFiles) {
            $rel   = $f.FullName.Substring($SkillRoot.Length).TrimStart('\')
            $entry = "$SkillName/" + ($rel -replace '\\', '/')
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $entry, 'Optimal') | Out-Null
            Write-Host "  + $entry"
        }
    } finally { $zip.Dispose() }

    $kb = [Math]::Round((Get-Item $out).Length / 1KB, 1)
    Write-Host "`nPackaged: $out  ($kb KB)" -ForegroundColor Green
    Write-Host 'Hand that file to anyone; they install it from the file card, or unzip it into' -ForegroundColor DarkGray
    Write-Host '~/.claude/skills and run scripts/Install-Skill.ps1 -Verify.' -ForegroundColor DarkGray
    return
}
