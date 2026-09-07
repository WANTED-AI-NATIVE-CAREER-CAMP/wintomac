---
name: wintomac
description: Set up macOS-style keyboard behavior and power-user tooling on Windows — swap Ctrl/Alt so the key next to the spacebar acts like Cmd, install PowerToys and the Sysinternals Suite, and manage PowerToys Keyboard Manager remaps from a declarative script instead of clicking through the GUI. Use this whenever the user mentions switching from a Mac, missing Cmd+C / Cmd+Tab / Cmd+backtick on Windows, wanting Mac keyboard muscle memory, remapping Ctrl and Alt or other modifiers, PowerToys Keyboard Manager, editing a Keyboard Manager default.json, Sysinternals tools, or "make Windows feel like a Mac" — even if they only ask for one piece of it, such as installing PowerToys, enabling a PowerToys module, or fixing a single shortcut that stopped working.
---

# WinToMac

Make a Windows machine feel like a Mac for someone with Mac muscle memory, and manage the
result as code rather than as GUI state.

Two things make this harder than it looks, and both are the reason this skill exists:

1. **PowerToys Keyboard Manager has a precedence rule that inverts what you'd expect**, and
   getting it wrong silently makes some key combinations *unreachable* rather than wrong.
2. **Keyboard Manager is a user-mode hook**, so it stops working in exactly the places a
   power user cares about — elevated windows, the login screen, games — unless you handle it.

Read `references/gotchas.md` before debugging anything that "should work but doesn't." It is
a list of traps that each cost real time to diagnose.

## The mental model

A Mac's bottom-left row is `Ctrl · Option · Command`. Windows' is `Ctrl · Win · Alt`. The key
people actually care about is the third one — the one next to the spacebar — because that is
what `Cmd+C` uses. So the swap is:

```
physical:   [ Left Ctrl ]   [ Win ]   [ Left Alt ]   [ Space ]
acts as:      Option                    Command
sends:        Alt                        Ctrl
```

After the swap, physical Left Alt sends Ctrl, so `Cmd+C` (physical) becomes `Ctrl+C` (sent)
and copy works with Mac muscle memory. Physical Left Ctrl sends Alt and plays the Option role.

Remap only the **Left** variants, never the right-hand ones (`RShift` 161, `RCtrl` 163,
`RAlt` 165) — a keyboard needs at least one unremapped set.

Be clear-eyed that this does **not** make the swap AltGr-safe. Windows implements `AltGr` as
`LCtrl + RAlt`, so `LCtrl` is already half of it, and remapping `LCtrl` can break AltGr
characters on ISO and European layouts regardless of how carefully the right-hand keys are
left alone. Korean 101/103-key layouts route Hangul/English on a dedicated virtual key and
are usually unaffected, but that is luck, not protection. See gotchas §6.

## The precedence rule (read this before writing any mapping)

PowerToys applies **single-key remaps first**, then matches **shortcut remaps against the
already-remapped keys**. The official dev docs put it as: *"Single key remappings have
precedence over shortcut remaps and are correspondingly reflected in shortcut remaps."*

The reason is mechanical: if `Ctrl` is remapped to `X`, then by the time you press `Ctrl+A`
the runtime has already turned that `Ctrl` into `X`, so a rule written against `Ctrl+A` could
never match. So they resolve key remaps first and expect shortcut rules to be written in
post-remap terms.

**Consequence for authoring:** in `Set-MacKeymap.ps1`, the `From` column is the *post-remap*
name. Physical Cmd (Left Alt) has already become `Ctrl`, so a rule about Cmd+Tab is written
`From='Ctrl+Tab'`, not `From='Alt+Tab'`. This is the single most common source of confusion —
when a user reports a rule "doing nothing," check whether they wrote it in physical terms.

## The orphan trap

Because a shortcut rule *consumes* its source combination, remapping `Ctrl+Left → Alt+Left`
means nothing emits `Ctrl+Left` any more. If no other rule produces it, `Ctrl+Left` — word-wise
cursor movement — becomes impossible to type. Nothing warns you; the key just stops working.

The fix is to think in **pairs**: a modifier swap needs both directions, the way `Ctrl+Tab ⇄
Alt+Tab` does. `Set-MacKeymap.ps1` checks this automatically and refuses to write a config with
an unacknowledged orphan. When losing the original really is intended (e.g. `Cmd+Q → Alt+F4`
deliberately eats `Ctrl+Q`), mark that rule `AllowOrphan=$true` so the intent is recorded in
the file rather than lost.

## Workflow

Run these from `scripts/`. Each is idempotent and each backs up what it touches.

### 0. Install or share the skill itself

Distribution needs no registry, no GitHub, and no credentials — a `.skill` file is just a zip
whose entries are prefixed with the folder name, and Claude Code reads skills from
`~/.claude/skills` (personal) or `<project>/.claude/skills` (project-scoped).

```powershell
.\Install-Skill.ps1 -Verify     # is this package well-formed?
.\Install-Skill.ps1 -Install    # copy into ~/.claude/skills
.\Install-Skill.ps1 -Package    # build a .skill file to hand to someone
```

`-Verify` checks the things that decide whether the skill loads at all: frontmatter parses,
`name` matches the folder, every `references/` and `scripts/` path mentioned in this file
actually exists, and every script parses. `-Install` and `-Package` both refuse to run if it
fails, because a skill that silently doesn't load is worse than one that errors.

Skip this step when the skill is already installed and you are just running the workflow.

### 1. Install the tooling

```powershell
.\Install-Tools.ps1
```

Installs PowerToys via winget, installs the Sysinternals Suite, and builds a `Desktop\Tools`
folder of shortcuts to the tools people actually reach for.

Sysinternals does **not** install cleanly via winget: Sysinternals overwrites one stable zip
URL in place, so winget's manifest hash is chronically stale and the install fails with
`Installer hash does not match`. Do not reach for `--ignore-security-hash` — that turns off
verification entirely. The script instead downloads the same official URL and verifies the
**Authenticode signature of every extracted executable**, which is a stronger check than a
zip hash, and aborts without installing if any binary fails. See `references/gotchas.md`.

### 2. Apply the keymap

```powershell
.\Set-MacKeymap.ps1 -DryRun    # inspect first — prints the table and the JSON
.\Set-MacKeymap.ps1            # back up, write, restart PowerToys
```

Edit the `$KeyRemaps` / `$ShortcutRemaps` tables at the top of the script. The script converts
key names to virtual-key codes, sorts modifiers canonically, validates every rule, runs the
orphan check, and writes Keyboard Manager's `default.json`.

Editing the table and re-running is the intended loop — that is the whole point of keeping this
in a file. `-Restore` rolls back to the newest backup.

### 3. Set PowerToys' own configuration

```powershell
.\Set-PTConfig.ps1 -EnableAdminMode -EnableModules 'Window Hopper'
```

Two things live in `settings.json` rather than the keymap:

- **`run_elevated`** — without it, every remap dies whenever an elevated window has focus.
  Turning it on means PowerToys runs elevated, which also means apps launched from Command
  Palette inherit elevation. That is a real tradeoff; surface it rather than deciding for the
  user.
- **module enable flags** — a remap that targets a disabled module is a dead rule. The internal
  key names do not match the UI labels (Window Hopper is `AltWindowCycle`, Screen Ruler is
  `Measure Tool`); the script maps friendly names for you.

### 3a. Windows Terminal의 Ctrl+V 전달

CLI 이미지 붙여넣기가 실행되지 않을 때는 `references/gotchas.md` §12를 확인합니다.
Terminal의 바인딩 변경이 요청된 경우 다음 명령으로 미리보기 후 적용합니다.

```powershell
.\Set-TerminalBindings.ps1 -DryRun
.\Set-TerminalBindings.ps1
.\Test-TerminalBindings.ps1
```

물리 왼쪽 Alt+V는 CLI로 전달하고, Terminal 텍스트 붙여넣기는 물리
왼쪽 Alt+Shift+V에 유지합니다. 모든 Terminal 프로필에 적용되는 변경입니다.
관리자 권한이나 PowerToys 키맵을 변경하지 않습니다. 설정 파일 검증만으로
이미지 첨부 성공을 판단하지 않습니다.

### 4. Verify

```powershell
.\Test-Setup.ps1
```

Checks what is actually true rather than what should be: token-level elevation of the running
processes, rule counts, orphans, module states, shortcut targets, and Sysinternals signatures.

## Verifying elevation correctly

This is worth calling out because two obvious checks both lie:

- **`Process.Handle` succeeds on elevated processes** — .NET opens it with limited rights, so a
  successful handle does *not* mean the target is unelevated. Using it will tell you elevation
  failed when it worked.
- **`is_elevated` in `settings.json` is written on exit**, so while PowerToys is running it
  reports the *previous* session. It is not a live signal.

Use `Test-Setup.ps1`, which calls `GetTokenInformation(TokenElevation)` through
`PROCESS_QUERY_LIMITED_INFORMATION` — that works across integrity levels and gives a real
answer. The process to check is **`PowerToys.KeyboardManagerEngine`**, not `PowerToys` itself,
since the engine is what performs the remapping.

## Asking for a screen-visible confirmation

Verification scripts can prove the config is *written*; they cannot prove the OS is *honoring*
it. When you need the user to confirm, pick a test with an unmistakable visible result rather
than asking them to read the GUI or interpret a mapping they did not write.

The best single test for multi-modifier rules is **physical `Cmd+Shift+4`** — a screen-capture
overlay appears, or it doesn't. It exercises three-modifier parsing, so one keystroke validates
every 3-key rule at once. Asking "does `Alt+Shift+Left` look right in the editor?" asks the user
to decode post-remap naming, which they have no reason to know.

## Scope and honesty about limits

Some Mac behavior cannot be reproduced, and saying so early saves a debugging cycle:

- `Ctrl+Alt+Del`, `Win+L`, the login screen, and UAC prompts run on the secure desktop. No
  user-mode hook reaches them.
- Mac's `Cmd+Left` means "line start" in a text field and "back" in a browser. Windows has no
  global way to tell those apart. Pick one for the global rule and put the other in an
  app-specific rule.
- CJK word boundaries differ. Windows' `Ctrl+Left` mostly breaks on spacing units for Hangul
  and behaves differently per application; it will not match macOS.
- Keyboard Manager degrades game performance and some games bypass it entirely.

For a swap that survives all of the above, the driver-level option is a `Scancode Map` registry
entry (SharpKeys). It works at the login screen, in games, and in safe mode, with no hook. It
needs admin plus a reboot and cannot do per-app rules — so the durable arrangement is the
physical swap in the driver and only the app-aware exceptions in Keyboard Manager.
`references/gotchas.md` covers the tradeoff.

## Reference files

- **`references/gotchas.md`** — every known trap, with why it happens. Read before debugging.
- **`references/keymap-reference.md`** — virtual-key name table, the Mac↔Windows shortcut
  mapping this skill ships, PowerToys module key names, and the `default.json` schema.
- **`references/ahk-comparison.md`** — where PowerToys' ceiling is and AutoHotkey's begins, and
  the **Apple-keyboard variant**: on Apple hardware the key to remap is `LWin`, not `LAlt`,
  because Windows reports Cmd as the Win key. Read this when the request involves a custom
  modifier key (`Fn + C`, `F13 + …`), layout-independent positional remapping, or an Apple
  keyboard.

## Scripts

| Script | Job |
|---|---|
| `Install-Skill.ps1` | verify / install / package this skill (step 0) |
| `Install-Tools.ps1` | PowerToys + Sysinternals + desktop shortcuts |
| `Set-MacKeymap.ps1` | the declarative keymap → `default.json` |
| `Set-PTConfig.ps1` | `run_elevated` and module enable flags |
| `Test-Setup.ps1` | verify the live state, token-level |

추가 스크립트: `scripts/Set-TerminalBindings.ps1`은 Terminal 바인딩을 백업·수정하며,
`scripts/Test-TerminalBindings.ps1`은 임시 설정으로 동작을 검증합니다.
