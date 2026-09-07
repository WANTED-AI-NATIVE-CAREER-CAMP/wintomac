<#
.SYNOPSIS
    Pass Ctrl+V to terminal applications; keep terminal paste on Ctrl+Shift+V.
.DESCRIPTION
    Targets Windows Terminal's keybindings schema. Uses ConvertFrom-Json; Windows PowerShell 5.1 requires strict JSON.
    Refuses legacy inline bindings rather than risking unrelated settings.
    Physical Left Alt is Ctrl under the WinToMac key swap. No elevation needed.
#>
[CmdletBinding()]
param(
    [string]$SettingsPath = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$raw = [IO.File]::ReadAllText($SettingsPath)
$config = $raw | ConvertFrom-Json
if (-not $config -or $config -is [array] -or $config -isnot [pscustomobject]) {
    throw 'Expected a settings object; file unchanged.'
}
if ($config.PSObject.Properties.Name -notcontains 'keybindings' -or $config.keybindings -isnot [array]) {
    throw 'Expected the modern keybindings array; file unchanged.'
}
foreach ($entry in @($config.actions) + @($config.keybindings)) {
    if ($entry -and $entry.PSObject.Properties.Name -contains 'keys' -and
        $entry.PSObject.Properties.Name -contains 'command') {
        throw 'Legacy inline command bindings require manual migration; file unchanged.'
    }
}
$targets = @('ctrl+v', 'ctrl+shift+v')
$bindings = @()
foreach ($binding in $config.keybindings) {
    $remaining = @()
    foreach ($key in @($binding.keys)) {
        if ($key -isnot [string]) { throw 'Unsupported key binding; file unchanged.' }
        $normalized = (($key.ToLowerInvariant() -split '\+' | ForEach-Object { $_.Trim() } | Sort-Object) -join '+')
        if ($targets -notcontains $normalized) { $remaining += $key }
    }
    if ($remaining.Count -eq @($binding.keys).Count) { $bindings += $binding }
    elseif ($remaining.Count -gt 0) {
        $binding.keys = if ($remaining.Count -eq 1) { $remaining[0] } else { $remaining }
        $bindings += $binding
    }
}
$bindings += [pscustomobject]@{ id = 'unbound'; keys = 'ctrl+v' }
$bindings += [pscustomobject]@{ id = 'Terminal.PasteFromClipboard'; keys = 'ctrl+shift+v' }
$config.keybindings = $bindings
$json = ($config | ConvertTo-Json -Depth 100) + [Environment]::NewLine
if ($DryRun) { $json; return }
if ($raw -eq $json) { Write-Host 'Bindings already configured.'; return }
# Detect changes made since the read before creating a backup and writing.
if ([IO.File]::ReadAllText($SettingsPath) -cne $raw) { throw 'Settings changed during update; retry.' }
$backup = "$SettingsPath.wintomac-$([guid]::NewGuid().ToString('N')).bak"
[IO.File]::Copy($SettingsPath, $backup)
[IO.File]::WriteAllText($SettingsPath, $json, (New-Object Text.UTF8Encoding($false)))
Write-Host "Updated: $SettingsPath"
Write-Host "Backup:  $backup"
