# What to borrow from AutoHotkey approaches

Notes from reading [ekocode/ahk-winToMac](https://github.com/ekocode/ahk-winToMac) — an
AutoHotkey v2 script that warps Windows input to match an Apple A1243 keyboard, aimed at music
production. Read for technique, not for mappings: it targets a French AZERTY layout on a
specific Apple keyboard, so almost none of its character table transfers.

**Licence.** That project is GPL-3.0. Nothing here is copied from it — these are observations
about approach, and the code in this skill is written independently. If you ever lift code from
it, this skill inherits GPL-3.0, so don't.

## Contents

1. [The one thing it does that PowerToys cannot](#1-the-one-thing-it-does-that-powertoys-cannot)
2. [Apple keyboard vs PC keyboard: a different key to remap](#2-apple-keyboard-vs-pc-keyboard-a-different-key-to-remap)
3. [Scancodes vs virtual keys](#3-scancodes-vs-virtual-keys)
4. [Why not to remap bare letter keys](#4-why-not-to-remap-bare-letter-keys)
5. [Ideas worth taking](#5-ideas-worth-taking)
6. [Capability boundary](#6-capability-boundary)
7. [What not to take](#7-what-not-to-take)

---

## 1. The one thing it does that PowerToys cannot

**Any key can become a modifier.** AHK lets an arbitrary key act as a chord prefix — that
script uses `F13` as a stand-in for the Mac `fn` key, so `F13 + F7` becomes previous-track,
`F13 + F11` becomes volume down, and so on. `CapsLock` gets the same treatment as a second
prefix for accented capitals.

PowerToys Keyboard Manager cannot express this. Its rule is that a shortcut source must begin
with one of `Ctrl / Shift / Alt / Win`, so `F13 + C` has nowhere to go. Its "chord" feature
looks similar but is a different mechanism: a chord is *one or more real modifiers plus two
action keys pressed in sequence* (`Ctrl+Shift+V` then `U`), not a custom prefix key.

**This is the answer to "can I map Fn + C?"** Not with PowerToys, and on most laptops not at
all — the Fn key is consumed by the keyboard's embedded controller and never reaches Windows
(see gotchas §7). But the *shape* of the request is achievable when a real key is available:

- A full-size Apple keyboard has physical `F13`–`F19` where PrtScn/ScrollLock/Pause sit, and
  those do reach Windows. PowerToys can map `F13`–`F24` as ordinary keys, just not as prefixes.
- So on PowerToys a bare `F13` can be remapped to **a key, a shortcut, or a text string** — the
  three things the Remap Keys "To send" column offers. It cannot *modify* another key, and it
  cannot launch an app either (see §5: Start App is a *shortcut* action and shortcut sources
  must begin with a modifier).
- If a custom prefix layer is genuinely needed, AHK is the right tool and this skill is not.
  That is a clean boundary, not a failing — say so rather than approximating it badly.

---

## 2. Apple keyboard vs PC keyboard: a different key to remap

That script maps `LWin → LControl`. This skill maps `LAlt → LControl`. Both are correct, for
different hardware, and picking the wrong one is the most likely reason a fresh setup feels
inverted.

The bottom-left row, left to right:

| Keyboard | Physical keys | What Windows sees | Which key sits where Cmd does |
|---|---|---|---|
| Mac | `Ctrl · Option · Cmd` | — | third |
| Apple keyboard on Windows | `Ctrl · Option · Cmd` | `Ctrl · Alt · **Win**` | `Win` |
| PC keyboard | `Ctrl · Win · Alt` | `Ctrl · Win · Alt` | `Alt` |

So the key you want to become Ctrl is:

- **PC keyboard** → `LAlt` (what this skill's `$KeyRemaps` does)
- **Apple keyboard** → `LWin`

On an Apple keyboard, adapt the table in `Set-MacKeymap.ps1`:

```powershell
$KeyRemaps = @(
    @{ From = 'LWin';  To = 'LCtrl'; Note = 'Cmd -> Ctrl' }
    @{ From = 'LCtrl'; To = 'LWin';  Note = 'Ctrl -> Win, so the Win key still exists' }
)
```

Note the second line: whatever you displace has to land somewhere or you lose the Win key
entirely. The same pairing discipline as the orphan check, one level down.

There is a bonus on Apple hardware: `Option` is already in the Option position and already
sends `Alt`, so no rule is needed for it — which is tidier than the PC case, where `LCtrl` has
to be pressed into service as Option and drags the AltGr problem along (gotchas §6).

---

## 3. Scancodes vs virtual keys

That script binds **scancodes** (`SC029`, `SC002`, …) rather than virtual keys. The difference
matters and is not cosmetic:

- A **scancode** identifies a physical key position. `SC010` is "the key left of `SC011`",
  regardless of what the active layout prints on it.
- A **virtual key** identifies a layout-resolved meaning. `VK 0x41` is "the A key" — which is
  a *different physical position* on AZERTY than on QWERTY.

PowerToys Keyboard Manager works in virtual keys. That is why its documentation answers the
"will this survive changing input language" question the way it does: remap `A → B` on
English (US), switch to French, and pressing the physical `Q` position now produces `B`,
because that position is `A` under the French layout. Consistent with how Windows handles
multilingual input, and rarely what a positional remap wants.

**Practical consequence.** For modifier swaps — which is what this skill does — VK and
scancode agree, because modifier positions don't move between layouts. For *character* keys,
VK-based remapping follows the layout and scancode-based remapping follows the finger. If you
ever need positional character remapping, PowerToys is the wrong layer; the driver-level
`Scancode Map` (gotchas §11) or AHK is the right one.

---

## 4. Why not to remap bare letter keys

The rule is: this skill remaps modifiers and whole shortcuts, never bare letters. The reason is
worth stating correctly, because the obvious explanation is wrong in an instructive way.

**Held modifiers ride along, in both tools.** A single-key remap substitutes at the virtual-key
level before the application sees the combination, and nothing touches modifier state unless
the *source* key is itself a modifier. So with `C → D`, pressing `Ctrl+C` yields `Ctrl+D`. The
PowerToys docs put it as: key remapping is maintained even when the remapped key is used inside
another shortcut. AHK behaves identically — its own remap documentation notes that `b::a` makes
`Ctrl+B` produce `Ctrl+A`, and remaps are implemented *with* `{Blind}` rather than in spite of
it.

So `{Blind}` is not protection against this; **it is the mechanism that causes it.** Remapping
a bare letter necessarily rewrites every shortcut built on that letter, in AHK just as much as
in PowerToys. Reaching for AHK does not fix it.

**Where PowerToys genuinely is less capable** is the send side of *shortcut* remaps. When a
shortcut rule fires, PowerToys releases source modifiers that aren't present in the target, and
there is no way to say "fire the target and leave `Ctrl` held." AHK's `Send` can, via `{Blind}`.

`exactMatch` is not the relevant control here, and it is easy to misread as if it were. It is a
property of a *shortcut* source — the docs introduce it under shortcut-to-single-key remaps —
and it decides only whether the rule still fires when extra keys are held. Bare-key remaps
carry no `exactMatch` at all; `Set-MacKeymap.ps1` writes it only into `remapShortcuts` entries.

---

## 5. Ideas worth taking

### Media keys as a layer — now supported

That script's `fn` layer puts media transport on the F-row, matching Apple keyboard behaviour.
The keys themselves are ordinary virtual keys and PowerToys can target them; this skill's VK
table simply didn't list them. It does now:

| Name | VK | Name | VK |
|---|---|---|---|
| `VolumeMute` | 173 | `MediaNext` | 176 |
| `VolumeDown` | 174 | `MediaPrev` | 177 |
| `VolumeUp` | 175 | `MediaStop` | 178 |
| | | `MediaPlayPause` | 179 |

So a working equivalent, using a real modifier instead of a custom prefix:

```powershell
@{ From = 'Alt+F8';  To = 'MediaPlayPause'; Note = 'Opt+F8  play/pause'; AllowOrphan = $true }
@{ From = 'Alt+F11'; To = 'VolumeDown';     Note = 'Opt+F11 volume down'; AllowOrphan = $true }
@{ From = 'Alt+F12'; To = 'VolumeUp';       Note = 'Opt+F12 volume up';   AllowOrphan = $true }
```

Browser keys came along for the ride: `BrowserBack` 166, `BrowserForward` 167,
`BrowserRefresh` 168, `BrowserStop` 169, `BrowserSearch` 170, `BrowserFavorites` 171,
`BrowserHome` 172. `BrowserBack` is a more honest target for a Back binding than `Alt+Left`,
since it means "back" rather than "the shortcut that usually means back."

### Show desktop / restore

`F13+F2` → minimise all, `F13+F3` → undo. The Mac reference is Mission Control / Show Desktop.
Windows equivalents are `Win+D` (toggle desktop) and `Win+M` / `Win+Shift+M`. `Win+D` already
toggles, so one binding covers both directions — no pair needed.

### Extra F-keys as launchers

`F14` → Snipping Tool, `F16`–`F19` → folders and apps. The generalisable idea is that
`F13`–`F24` are dead space on most keyboards and make good launcher targets.

**The bare-key version of this does not transfer.** PowerToys does have a launcher action —
"Start App", with arguments, working directory, elevation, visibility, and what to do if it is
already running — but it is an action of *shortcut* remapping, and shortcut sources must begin
with a modifier. A bare `F14` is rejected by both editors. So the trigger has to be
`Ctrl+F14`, `Ctrl+Alt+F16`, and so on. Single-key launchers stay an AHK-only capability; there
is an open PowerToys issue asking for the restriction to be lifted.

`Set-MacKeymap.ps1` only writes `operationType: 0` (shortcut-to-shortcut) and does not express
launchers at all; add them through the Keyboard Manager GUI, and expect `Test-Setup.ps1` to
report the resulting manifest mismatch (keymap-reference.md covers that).

### A generator, not a hand-edited config

That repo includes `createMapping.html`, a small tool that emits the mapping block rather than
having the author hand-write it. Same conclusion this skill reached from the other direction:
the config is generated from a declarative source, because hand-editing a table of key codes is
where the mistakes live. Convergent design is weak evidence, but it is evidence.

### Reserve Right Alt for a character layer

The script deliberately puts its special characters on **Right** Alt, with the stated reason
that Alt shortcuts keep working. That is the same conclusion as gotchas §6 from the opposite
side: `RAlt` is load-bearing, so leave it alone as a shortcut modifier and treat it as the
character layer it already is on ISO layouts.

---

## 6. Capability boundary

When someone asks for something in the left column, the answer is not PowerToys.

| Capability | PowerToys KBM | AHK |
|---|---|---|
| Swap modifiers | yes | yes |
| Remap shortcut → shortcut | yes | yes |
| Per-application rules | yes, by process name | yes, by window class/title/exe |
| Shortcut → launch app / open URI | yes (modifier-led source only) | yes |
| Bare non-modifier key as a hotkey / launcher trigger (`F14` → app) | **no** | yes |
| Arbitrary key as a modifier (`F13 + C`) | **no** | yes |
| Hold source modifiers through a *shortcut* remap | **no** | yes (`{Blind}`) |
| Bind by physical position, layout-independent | **no** (virtual keys) | yes (scancodes) |
| Conditional logic, state, functions | **no** | yes |
| Multi-key sequences | chords only (modifier + 2 action keys) | arbitrary |
| Works in elevated windows | only if PowerToys is elevated | yes when launched with UI access — elevation not required |
| Works on the secure desktop / login screen | no | no |
| Ships signed, auto-updating, GUI-configurable | yes | no |

Two rows deserve a footnote.

**Held modifiers.** The `{Blind}` row is about *shortcut* remaps only. Plain single-key remaps
already carry held modifiers through in both tools — that is §4, and it is the cause of the
bare-letter problem rather than a cure for it.

**Elevated windows.** AHK's documented and recommended answer here is not elevation but
**"Run with UI access"**: a UIAccess-manifested copy of the interpreter (created by the
installer, and only trusted from a Program Files directory) whose hotkeys fire against elevated
windows while the script itself stays unelevated. That avoids exactly the tradeoff this skill
has to surface for PowerToys — elevate it and everything it launches inherits admin
(gotchas §1). Notably, UIAccess is the fix PowerToys' own developer docs identify for this
Keyboard Manager limitation and have not yet shipped, so the gap is acknowledged upstream. UI
access does not cross the secure desktop, so the row below still reads "no" on both sides.

The last row is why this skill is built on PowerToys despite the gaps: it is Microsoft-signed,
updates itself, survives a reinstall, and a non-scripting user can inspect and toggle it. An
AHK script is more capable and less durable. Reach for AHK when a row marked **no** is the
actual requirement — and then run it *alongside* PowerToys rather than replacing it, since two
hooks on disjoint keys coexist fine.

---

## 7. What not to take

- **The character table.** It maps French AZERTY positions to macOS special characters
  (`≤ ‹ ≈ © ◊ ß`, accented capitals via CapsLock chords). Layout-specific, and irrelevant on a
  Korean or US layout.
- **Hard-coded local paths.** `F16` opens `D:\`, `F18` launches a specific plugin console.
  Fine for its author, meaningless anywhere else.
- **CapsLock as a chord prefix.** Their own readme flags it as broken for some characters, and
  PowerToys cannot do it anyway.
- **Remapping bare letter keys.** See §4 — held modifiers ride along, so remapping `C` rewrites
  `Ctrl+C` too. This is true in AHK as well, so switching tools is not the fix.
