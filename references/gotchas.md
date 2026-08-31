# Gotchas

Every entry here cost real diagnosis time. Read the relevant section before concluding that
something "should work."

## Contents

1. [Keyboard Manager dies in elevated windows](#1-keyboard-manager-dies-in-elevated-windows)
2. [Two elevation checks that lie](#2-two-elevation-checks-that-lie)
3. [The precedence rule inverts how you write rules](#3-the-precedence-rule-inverts-how-you-write-rules)
4. [Orphaned combinations](#4-orphaned-combinations)
5. [Sysinternals cannot be installed via winget](#5-sysinternals-cannot-be-installed-via-winget)
6. [AltGr and right-hand modifiers](#6-altgr-and-right-hand-modifiers)
7. [Things that are simply impossible](#7-things-that-are-simply-impossible)
8. [Module names do not match UI labels](#8-module-names-do-not-match-ui-labels)
9. [Editing config while PowerToys runs](#9-editing-config-while-powertoys-runs)
10. [Smaller papercuts](#10-smaller-papercuts)
11. [The driver-level alternative](#11-the-driver-level-alternative)

---

## 1. Keyboard Manager dies in elevated windows

Keyboard Manager is a user-mode low-level keyboard hook. A process at a lower integrity level
cannot inject into a higher one, so the moment an elevated window takes focus, remapping stops.
The Microsoft docs are explicit: *"Remapping won't work on an app or window if that window is
running in administrator (elevated) mode and PowerToys is not running as administrator."*

**Why it is nasty:** there is no warning, no tray change, no log line. The keyboard just
reverts to stock Windows behaviour. If Ctrl and Alt are swapped, muscle memory now hits the
wrong modifier — pressing "copy" pops the menu bar instead.

This bites hardest right after setting up Sysinternals, because Procmon, Autoruns and RAMMap
all need elevation. Anyone who marks those shortcuts "run as administrator" has just created
several windows where their keymap silently does not exist.

**Fix:** `Set-PTConfig.ps1 -EnableAdminMode`, which sets `run_elevated: true`.

**The tradeoff, which the user should decide:** PowerToys running elevated means every app it
launches — from Command Palette, PowerToys Run, or a Keyboard Manager "Start App" action —
inherits elevation. That is a real expansion of what runs with admin rights.

---

## 2. Two elevation checks that lie

Both obvious ways to check whether PowerToys is elevated give the wrong answer.

**`Process.Handle` succeeds on elevated processes.** .NET opens the handle with limited rights,
which is permitted across integrity levels, so the call succeeding proves nothing. A check
built on it reports "not elevated" for a correctly elevated process. Confusingly,
`Process.Path` on the *same* object returns empty for an elevated target — so the two
properties disagree and only `Path` is telling the truth.

**`is_elevated` in `settings.json` is written on exit.** While PowerToys is running, that field
describes the *previous* session. It is not a live signal and should never be used as one.

**What actually works:** `GetTokenInformation` with `TokenElevation`, on a handle opened with
`PROCESS_QUERY_LIMITED_INFORMATION` (0x1000) — that access right is designed to work across
integrity levels. `Test-Setup.ps1` implements this.

**Check the right process.** `PowerToys.exe` is the runner; `PowerToys.KeyboardManagerEngine`
is what performs the remapping. The engine's elevation is what determines whether remaps reach
elevated windows.

---

## 3. The precedence rule inverts how you write rules

PowerToys resolves **single-key remaps first**, then matches **shortcut remaps against the
already-remapped keys**. From the PowerToys developer docs: *"Single key remappings have
precedence over shortcut remaps and are correspondingly reflected in shortcut remaps."*

The rationale is mechanical. If `Ctrl` is remapped to `X`, then pressing `Ctrl+A` has already
become `X+A` by the time any shortcut rule sees it — a rule written against `Ctrl+A` could
never fire. Resolving key remaps first and interpreting shortcut rules in post-remap terms is
the only self-consistent ordering.

**What this means in practice.** With `LCtrl ⇄ LAlt` swapped, and wanting physical Cmd+Tab
(that is, physical Left Alt + Tab) to switch apps:

| physical keys | after key remap | rule that matches | sent |
|---|---|---|---|
| LAlt + Tab | `Ctrl+Tab` | `Ctrl+Tab → Alt+Tab` | `Alt+Tab` — switch apps |
| LCtrl + Tab | `Alt+Tab` | `Alt+Tab → Ctrl+Tab` | `Ctrl+Tab` — switch tabs |

So the rule about the *Cmd* key is written `From='Ctrl+Tab'`. Writing it as `From='Alt+Tab'`
— the physically intuitive reading — produces a rule that never fires, or worse, fires for the
opposite key.

This is the most common cause of "I added the rule and nothing happened." Check the naming
before checking anything else.

**Multi-modifier ordering.** The `default.json` format is a semicolon-separated virtual-key
list, e.g. `164;160;37` for Alt+Shift+Left. The scripts emit canonical order
(Win → Ctrl → Alt → Shift → action key). PowerToys appears to classify each code by key type
rather than depending on position, but this is not documented, so canonical order is used to
stay on the safe side.

---

## 4. Orphaned combinations

A shortcut rule **consumes** its source. Adding `Ctrl+Left → Alt+Left` means nothing produces
`Ctrl+Left` any more. Since `Ctrl+Left` is Windows' word-wise cursor movement, that capability
disappears — and the only physical route to it was the combination the rule just ate.

The symptom is a key that **quietly stops working**, which reads as a broken keyboard rather
than a broken config.

**The discipline:** think in pairs. `Ctrl+Tab ⇄ Alt+Tab` works because both directions exist.
Arrow keys need the same treatment:

```
Ctrl+Left  -> Alt+Left     (Cmd+Left  = browser Back)
Alt+Left   -> Ctrl+Left    (Opt+Left  = word-wise move)   <- the half people forget
```

`Set-MacKeymap.ps1` computes this automatically: for every rule source, it checks whether some
rule emits that same combination, and refuses to write the config otherwise. When losing the
original is deliberate — `Cmd+Q → Alt+F4` intentionally eats `Ctrl+Q` — set
`AllowOrphan = $true` on that rule so the decision is recorded in the file instead of being
indistinguishable from a mistake.

---

## 5. Sysinternals cannot be installed via winget

`winget install Microsoft.Sysinternals.Suite` fails with `Installer hash does not match`.

**Why:** Sysinternals publishes to one stable URL,
`https://download.sysinternals.com/files/SysinternalsSuite.zip`, and overwrites it in place on
every release. winget manifests pin a hash of the file, so the manifest goes stale as soon as
Sysinternals ships anything. This is chronic, not a transient mirror problem.

**Do not use `--ignore-security-hash`.** That disables integrity verification for the download
entirely, which is a much bigger concession than the situation calls for.

**Better:** fetch the same official HTTPS URL and verify the **Authenticode signature of every
extracted executable**. That proves Microsoft signed each binary, which is a stronger claim
than a zip hash — a stale hash says nothing about authenticity, whereas a valid signature chain
does. `Install-Tools.ps1` extracts to a staging directory first and only copies into place if
every binary is `Valid` and signed by `O=Microsoft Corporation`, so a failure never leaves a
half-installed tree.

**Consequences of installing this way:**
- No auto-update. Re-run `Install-Tools.ps1` to refresh.
- The Microsoft Store MSIX build is signed and self-updating, and is a reasonable alternative
  if update automation matters more than the portable folder layout.

**First-run EULA.** Each tool shows a licence dialog on first launch. It can be pre-accepted by
writing `HKCU\Software\Sysinternals\<Tool>\EulaAccepted`, but accepting a licence on someone
else's behalf is not the installer's call — let the user click it.

---

## 6. AltGr and right-hand modifiers

Windows implements `AltGr` as **`LCtrl` + `RAlt`** internally. The PowerToys docs list this as a
known issue: *"AltGr and Ctrl+Alt gives issues, since AltGr behaves as (L)Ctrl + (R)Alt and
remapping one of these keys can break the function."*

Remapping `LCtrl` therefore has the potential to break AltGr, which on ISO and many European
layouts is how `@`, `€`, `\`, `[`, `]` and accented characters are typed. Korean 101/103-key
keyboards usually route Hangul/English on a dedicated virtual key rather than through AltGr, so
they typically survive — but that is luck, not design.

**Rule, with an honest caveat.** Remap only the Left variants (`LCtrl` 162, `LAlt` 164,
`LShift` 160) and never 161/163/165 — a keyboard needs one unremapped set, and `RAlt` in
particular is the other half of AltGr.

But "left variants only" is *not* a guarantee of AltGr safety, and it is tempting to read it
as one. `LCtrl` is itself half of AltGr, so the moment this skill's swap remaps `LCtrl` the
AltGr combination is already disturbed. There is no arrangement of Keyboard Manager rules
that swaps Ctrl and Alt *and* leaves AltGr intact, because they need the same physical key to
mean two things.

If AltGr matters on your layout, the driver-level swap (§11) is the way out: `Scancode Map`
changes what the key reports at the source, so the OS composes AltGr from whatever now sits
in the `LCtrl` position and the combination stays coherent.

`Test-Setup.ps1` reports when `LCtrl` or `RAlt` is remapped, and separately flags the unusual
case of `RShift`/`RCtrl` being touched.

Also note that `Ctrl+Alt+<key>` rules are in the same neighbourhood, since that combination is
indistinguishable from AltGr on some layouts.

---

## 7. Things that are simply impossible

Saying these up front avoids a wasted debugging cycle.

- **Secure desktop.** `Ctrl+Alt+Del`, `Win+L`, the login and lock screens, and UAC consent
  prompts run where no user-mode hook reaches. The docs confirm Keyboard Manager "doesn't work
  on any password screen, including while Run As Admin." Nothing in PowerToys can fix this —
  only a driver-level remap (see §11).
- **Context-dependent `Cmd+Left`.** On macOS it means "line start" in a text field and "Back"
  in a browser. Windows has no global way to distinguish those. Pick one for the global rule and
  put the other in an app-specific rule targeting the browser's process name (`msedge`,
  `chrome`) — Keyboard Manager matches on process name, not window title.
- **CJK word boundaries.** Windows' `Ctrl+Left/Right` does not do morphological analysis on
  Hangul; it mostly breaks on spacing units, and behaves differently in Notepad, VS Code, and
  browsers. It will not match macOS. English text feels essentially identical.
- **Games.** The docs advise against using Keyboard Manager while gaming: the hook costs frame
  time, and titles using lower-level input APIs or anti-cheat bypass or flag it.
- **`Win+G`** often opens Game Bar even when remapped. **Pause** only sends key-down, so
  holding it does not repeat.
- **Keys that are secretly shortcuts.** The Office key sends `Win+Ctrl+Alt+Shift`; the Copilot
  key sends `Win+C` or `LShift+Win+F23`. Remapping around them behaves unexpectedly.

---

## 8. Module names do not match UI labels

`settings.json`'s `enabled` block uses internal keys that differ from what the UI shows. Getting
this wrong means silently editing a key that does not exist.

| UI label | `settings.json` key |
|---|---|
| Window Hopper | `AltWindowCycle` |
| Screen Ruler | `Measure Tool` |
| Command Palette | `CmdPal` |
| Hosts File Editor | `Hosts` |
| New+ | `NewPlus` |
| Command Not Found | `CmdNotFound` |
| Mouse Crosshairs | `MousePointerCrosshairs` |

`Set-PTConfig.ps1` translates friendly names, and `-List` prints the live state with both.

**Dead rules.** A remap that targets a disabled module does nothing — `Alt+backtick` is emitted
and no one is listening. This is easy to create when adding a Window Hopper mapping without
noticing the module ships **off by default**. `Test-Setup.ps1` cross-checks the keymap's emitted
combinations against module state for exactly this case.

---

## 9. Editing config while PowerToys runs

PowerToys owns `settings.json` and rewrites it on exit, so edits made while it is running are
liable to be overwritten. Stop it, edit, restart.

And a circular problem: once `run_elevated` is on, PowerToys runs elevated, and an unelevated
shell **cannot** stop an elevated process. Scripts that only try `Stop-Process` fail halfway,
leaving config written but not loaded. `Set-MacKeymap.ps1` and `Set-PTConfig.ps1` detect this
(via `MainModule` being unreadable) and re-launch themselves elevated so one UAC prompt covers
the whole operation.

---

## 10. Smaller papercuts

- **A bare Alt tap opens the menu bar.** After the swap, physical Left Ctrl sends Alt, so
  tapping it activates the menu bar in Explorer, Office, and similar apps. There is no
  Keyboard Manager workaround; it is a consequence of Alt's meaning in Windows.
- **Remapped `Alt+Tab` hold behaviour is imperfect.** The task switcher expects Alt to stay
  physically held while Tab repeats. Synthesised modifiers make "hold and tab through" less
  reliable than native. Window Hopper (`Alt+backtick`) and Workspaces are steadier alternatives.
- **Window Hopper's default is `Alt+backtick`**, not `Win+backtick`. Some coverage reported the
  latter; the docs say Alt. Reverse cycle is `Shift+Alt+backtick`. It does not open when the
  focused app has fewer than two windows, which can read as "not working."
- **ZoomIt exists twice.** PowerToys absorbed the Sysinternals tool in 0.88, so having the
  PowerToys module enabled and running standalone ZoomIt puts two processes on the same hotkey.
  Pick one.
- **Other hook-based apps interfere.** If remaps stop being intercepted, toggling Keyboard
  Manager off and on in settings re-establishes the hook. Known conflicts include Avid Pro Tools
  and Microsoft Mouse and Keyboard Center.
- **Duplicate rule sources are silent.** Two rules with the same `From` — only the first can
  ever match. `Set-MacKeymap.ps1` throws instead.
- **No per-keyboard mappings.** There is no API to tell which device a keystroke came from, so a
  laptop with an external keyboard gets one shared mapping.

---

## 11. The driver-level alternative

For a swap that survives everything in §7, do the **physical** key swap in the keyboard driver
instead of in a hook:

```
HKLM\SYSTEM\CurrentControlSet\Control\Keyboard Layout\Scancode Map
```

`SharpKeys` (`winget install RandyRants.SharpKeys`) writes this for you.

**Why it is better:** the keyboard class driver applies it before anything in user mode runs, so
it works at the login screen, on the UAC secure desktop, in elevated apps, in games, and in
safe mode, with zero hook overhead.

**Costs:** needs admin, needs a reboot, is machine-wide, and cannot do per-app rules.

**The durable arrangement** is both layers: the physical modifier swap in the driver, and only
the app-aware shortcut exceptions in Keyboard Manager. A useful side effect is that it removes
the §3 ambiguity entirely — the driver hands PowerToys already-swapped keys, so shortcut rules
are written in plain physical terms and there is no post-remap naming to reason about.
