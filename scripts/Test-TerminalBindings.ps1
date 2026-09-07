# Isolated behavior tests; never reads or writes live Terminal settings.
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('wintomac-test-' + [guid]::NewGuid())
New-Item -ItemType Directory $root | Out-Null
$path = Join-Path $root 'settings.json'
$script = Join-Path $PSScriptRoot 'Set-TerminalBindings.ps1'
function Assert($condition, $message) { if (-not $condition) { throw $message } }
try {
    $original = '{"profiles":{"defaults":{"font":{"size":12}}},"actions":[],"keybindings":[{"id":"Terminal.PasteFromClipboard","keys":["v+ctrl","shift+insert"]},{"id":"custom","keys":"shift+ctrl+v"},{"id":"Terminal.CopyToClipboard","keys":"ctrl+c"}]}'
    [IO.File]::WriteAllText($path, $original)
    & $script -SettingsPath $path -DryRun | Out-Null
    Assert ([IO.File]::ReadAllText($path) -ceq $original) 'DryRun modified settings'
    Assert (@(Get-ChildItem $root -Filter '*.bak').Count -eq 0) 'DryRun created backup'
    & $script -SettingsPath $path
    $result = Get-Content $path -Raw | ConvertFrom-Json
    Assert ($result.profiles.defaults.font.size -eq 12) 'Unrelated profile changed'
    Assert (@($result.keybindings | Where-Object { $_.keys -eq 'ctrl+c' }).Count -eq 1) 'Copy binding lost'
    Assert (@($result.keybindings | Where-Object { $_.keys -eq 'shift+insert' }).Count -eq 1) 'Alternate paste binding lost'
    Assert (@($result.keybindings | Where-Object { $_.keys -eq 'ctrl+v' -and $_.id -eq 'unbound' }).Count -eq 1) 'Ctrl+V not unbound'
    Assert (@($result.keybindings | Where-Object { $_.keys -eq 'ctrl+shift+v' -and $_.id -eq 'Terminal.PasteFromClipboard' }).Count -eq 1) 'Shift paste missing'
    $backups = @(Get-ChildItem $root -Filter '*.bak')
    Assert ($backups.Count -eq 1) 'Expected one backup'
    Assert ([IO.File]::ReadAllText($backups[0].FullName) -ceq $original) 'Backup differs'
    $once = [IO.File]::ReadAllText($path)
    & $script -SettingsPath $path
    Assert ([IO.File]::ReadAllText($path) -ceq $once) 'Not idempotent'
    Assert (@(Get-ChildItem $root -Filter '*.bak').Count -eq 1) 'No-op created backup'
    foreach ($invalid in @('{broken', '{"actions":[{"command":"paste","keys":"ctrl+v"}]}', '{"keybindings":[],"actions":[{"command":"paste","keys":"ctrl+v"}]}')) {
        [IO.File]::WriteAllText($path, $invalid)
        $failed = $false
        try { & $script -SettingsPath $path } catch { $failed = $true }
        Assert $failed 'Unsafe input accepted'
        Assert ([IO.File]::ReadAllText($path) -ceq $invalid) 'Rejected input modified'
    }
    Write-Host 'PASS: dry-run, preservation, bindings, backup, idempotence, rejection'
} finally { Remove-Item $root -Recurse -Force }
