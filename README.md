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
