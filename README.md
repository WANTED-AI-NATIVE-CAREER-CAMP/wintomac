# wintomac

A Claude Code skill that makes a Windows machine feel like a Mac for someone with Mac muscle
memory — and manages the result as code rather than as GUI state.

It swaps Ctrl/Alt so the key next to the spacebar behaves like Cmd, installs PowerToys and the
Sysinternals Suite, and generates PowerToys Keyboard Manager's `default.json` from a
declarative table instead of clicking through the editor.

## Install

The repository root *is* the skill root, so cloning into the skills directory is the whole
install:

```powershell
git clone https://github.com/WANTED-AI-NATIVE-CAREER-CAMP/wintomac.git "$env:USERPROFILE\.claude\skills\wintomac"
```

Then start a new Claude Code session. To confirm the package is well-formed:

```powershell
.\scripts\Install-Skill.ps1 -Verify
```

To hand it to someone without git, build a `.skill` file — a zip Claude Code installs from a
file card:

```powershell
.\scripts\Install-Skill.ps1 -Package
```

## Workflow

| Step | Script |
|---|---|
| 0 | `Install-Skill.ps1` — verify / install / package the skill itself |
| 1 | `Install-Tools.ps1` — PowerToys + Sysinternals + desktop shortcuts |
| 2 | `Set-MacKeymap.ps1` — the keymap table → `default.json` |
| 3 | `Set-PTConfig.ps1` — `run_elevated` and module enable flags |
| 4 | `Test-Setup.ps1` — verify the live state |

Every script is idempotent, backs up what it touches, and supports `-DryRun` or `-Verify`
where a preview makes sense.

## Why this isn't just a list of remaps

Two things make Mac-style remapping on Windows harder than it looks, and both are why the
skill exists rather than a gist.

**Keyboard Manager's precedence rule inverts how you write rules.** Single-key remaps are
applied *first*, and shortcut remaps are matched against the already-remapped keys. So with
`LCtrl ⇄ LAlt` swapped, a rule about physical Cmd+Tab is written `From = 'Ctrl+Tab'` — not
`Alt+Tab`, which is the physically intuitive reading and produces a rule that never fires.

**A shortcut rule consumes its source, which can make a combination unreachable.** Remapping
`Ctrl+Left → Alt+Left` means nothing emits `Ctrl+Left` any more, so word-wise cursor movement
becomes impossible to type. Nothing warns you — the key just quietly stops working.
`Set-MacKeymap.ps1` computes this and refuses to write a config with an unacknowledged orphan;
deliberate ones are marked `AllowOrphan = $true` so the intent lives in the file.

`references/gotchas.md` covers eleven more, including why remaps silently die in elevated
windows, why two obvious ways to check for elevation both lie, and why Sysinternals cannot be
installed via winget.

## Scope

Some things are genuinely impossible and the skill says so rather than letting you chase them:
the secure desktop (`Ctrl+Alt+Del`, `Win+L`, the login screen, UAC prompts), the Fn key,
context-dependent `Cmd+Left`, CJK word boundaries, and games. For a swap that survives all of
those, `gotchas.md` §11 covers the driver-level `Scancode Map` route.

## Layout

```
SKILL.md                      what Claude reads
scripts/                      the five PowerShell scripts
references/gotchas.md         every known trap, with why
references/keymap-reference.md  VK table, Mac↔Windows mapping, module keys, schema
```

## Requirements

Windows 10/11, PowerShell 7 (the scripts avoid non-ASCII so they also survive Windows
PowerShell 5.1), winget, and PowerToys 0.101 or newer for Window Hopper.


## Windows Terminal의 CLI 이미지 붙여넣기

PowerToys가 왼쪽 Ctrl/Alt를 교환한 상태에서는 물리 **왼쪽 Alt+V**가
`Ctrl+V`로 전달됩니다. Windows Terminal에 `Ctrl+V` 붙여넣기가 등록되어 있으면
Terminal이 먼저 처리하여 CLI가 해당 키를 받지 못합니다.

```powershell
.\scripts\Set-TerminalBindings.ps1 -DryRun
.\scripts\Set-TerminalBindings.ps1
.\scripts\Test-TerminalBindings.ps1
```

| 물리 키 | 변환된 키 | 적용 후 동작 |
|---|---|---|
| 왼쪽 Alt+V | Ctrl+V | CLI에 전달합니다. 이미지 처리는 해당 CLI가 담당합니다. |
| 왼쪽 Alt+Shift+V | Ctrl+Shift+V | Terminal의 텍스트 붙여넣기를 실행합니다. |

스크립트는 Stable 버전의 현재 사용자 설정을 기본 대상으로 사용합니다. 다른 설치는
`-SettingsPath`로 지정합니다. 현대식 `keybindings` 배열을 대상으로 하며, 기존
프로필과 나머지 바인딩은 보존합니다. Windows PowerShell 5.1에서는 주석 없는 JSON이
필요합니다. 구형 인라인 `command` 바인딩은 자동 변환하지 않고 중단합니다.
변경 전에는 설정 옆에 `settings.json.wintomac-*.bak` 백업을 만듭니다.
복원할 때는 출력된 정확한 백업 경로를 원래 설정 경로로 복사합니다.

이 변경은 해당 Terminal 설정을 사용하는 모든 프로필에 적용됩니다. 일반 셸에서도
텍스트 붙여넣기에 물리 Alt+Shift+V를 사용합니다. PowerToys 재시작과 관리자 권한
변경은 수행하지 않습니다. 설정 검증과 실제 키 입력·이미지 첨부 성공은 별도로 확인합니다.

근거: [Microsoft의 키 바인딩 해제 문서](https://learn.microsoft.com/en-us/windows/terminal/customize-settings/actions#unbind-keys-disable-keybindings)입니다.
