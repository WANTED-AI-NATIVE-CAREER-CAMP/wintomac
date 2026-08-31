# Keymap reference

## Contents

1. [default.json schema](#defaultjson-schema)
2. [Key name table](#key-name-table)
3. [The shipped Mac to Windows mapping](#the-shipped-mac-to-windows-mapping)
4. [Mac shortcuts with no clean Windows equivalent](#mac-shortcuts-with-no-clean-windows-equivalent)
5. [App-specific rules](#app-specific-rules)
6. [PowerToys module keys](#powertoys-module-keys)
7. [File locations](#file-locations)

---

## default.json schema

`%LOCALAPPDATA%\Microsoft\PowerToys\Keyboard Manager\default.json`, written minified:

```json
{
  "remapKeys":            { "inProcess": [ { "originalKeys": "162", "newRemapKeys": "164" } ] },
  "remapKeysToText":      { "inProcess": [] },
  "remapShortcuts":       { "global": [ { "originalKeys": "162;9", "exactMatch": false,
                                          "operationType": 0, "newRemapKeys": "164;9" } ],
                            "appSpecific": [] },
  "remapShortcutsToText": { "global": [], "appSpecific": [] }
}
```

- Keys are decimal Windows virtual-key codes, semicolon-separated, modifiers first.
- `operationType: 0` is a plain shortcut-to-shortcut remap. Other values cover the
  run-app / open-URI / send-text actions, which the GUI writes.
- `exactMatch: false` means the rule still fires when additional keys are held. Set it true
  to require the exact combination — relevant mainly for shortcut-to-single-key remaps.
- Keep all four top-level objects present even when empty; that is the shape PowerToys writes.
- Emit canonical modifier order: **Win → Ctrl → Alt → Shift → action key**. PowerToys appears
  to classify codes by key type rather than position, but the order is undocumented, so
  matching what the GUI produces avoids depending on that.

---

## Key name table

Names accepted by `Set-MacKeymap.ps1`, with virtual-key codes.

| Name | VK | Name | VK |
|---|---|---|---|
| `LCtrl` / `Ctrl` | 162 | `Left` | 37 |
| `RCtrl` | 163 | `Up` | 38 |
| `LAlt` / `Alt` | 164 | `Right` | 39 |
| `RAlt` | 165 | `Down` | 40 |
| `LShift` / `Shift` | 160 | `Home` | 36 |
| `RShift` | 161 | `End` | 35 |
| `LWin` / `Win` | 91 | `PageUp` | 33 |
| `RWin` | 92 | `PageDown` | 34 |
| `Tab` | 9 | `Backtick` / `Grave` | 192 |
| `Space` | 32 | `Minus` | 189 |
| `Backspace` | 8 | `Equals` | 187 |
| `Enter` | 13 | `LBracket` | 219 |
| `Escape` / `Esc` | 27 | `RBracket` | 221 |
| `Delete` | 46 | `Backslash` | 220 |
| `Insert` | 45 | `Semicolon` | 186 |
| `CapsLock` | 20 | `Quote` | 222 |
| `PrintScreen` | 44 | `Comma` | 188 |
| `Hangul` | 21 | `Period` | 190 |
| `Hanja` | 25 | `Slash` | 191 |

`A`–`Z` are 65–90, `0`–`9` are 48–57, `F1`–`F24` are 112–135.

Only 162 / 164 / 160 / 91 appear as modifiers in the shipped map — see gotchas §6 for why the
right-hand variants are avoided.

---

## The shipped Mac to Windows mapping

Physical layout after the `LCtrl ⇄ LAlt` swap:

```
physical:   [ Left Ctrl ]   [ Win ]   [ Left Alt ]   [ Space ]
acts as:      Option                    Command
sends:        Alt                        Ctrl
```

The **From** column below is post-key-remap (gotchas §3). "Physical" is what the fingers do.

| Mac intent | Physical | From (rule) | To (rule) | Result |
|---|---|---|---|---|
| Copy / paste / save | Cmd+C/V/S | *(key remap only)* | — | `Ctrl+C/V/S` |
| Switch apps | Cmd+Tab | `Ctrl+Tab` | `Alt+Tab` | task switcher |
| Switch tabs in app | Opt+Tab | `Alt+Tab` | `Ctrl+Tab` | next tab |
| Browser Back | Cmd+Left | `Ctrl+Left` | `Alt+Left` | Back |
| Browser Forward | Cmd+Right | `Ctrl+Right` | `Alt+Right` | Forward |
| Word-wise move | Opt+Left/Right | `Alt+Left/Right` | `Ctrl+Left/Right` | word jump |
| Word-wise select | Opt+Shift+Left/Right | `Alt+Shift+Left/Right` | `Ctrl+Shift+Left/Right` | word select |
| Delete word | Opt+Delete | `Alt+Backspace` | `Ctrl+Backspace` | delete word |
| Cycle app windows | Cmd+backtick | `Ctrl+Backtick` | `Alt+Backtick` | Window Hopper |
| Cycle backwards | Cmd+Shift+backtick | `Ctrl+Shift+Backtick` | `Alt+Shift+Backtick` | Window Hopper reverse |
| Quit app | Cmd+Q | `Ctrl+Q` | `Alt+F4` | close window |
| Minimise | Cmd+M | `Ctrl+M` | `Win+Down` | minimise |
| Capture region | Cmd+Shift+4 | `Ctrl+Shift+4` | `Win+Shift+S` | Snipping overlay |
| Capture screen | Cmd+Shift+3 | `Ctrl+Shift+3` | `Win+PrintScreen` | saves to Screenshots |
| Force quit | Cmd+Opt+Esc | `Ctrl+Alt+Escape` | `Ctrl+Shift+Escape` | Task Manager |

Already native, no rule needed: `Cmd+W` (close tab), `Cmd+T`, `Cmd+F`, `Cmd+Z`, `Cmd+A`,
`Cmd+N`, `Cmd+R`, `Cmd+P` — the key remap alone handles them.

**Cmd+Shift+4 is the best single verification test.** It exercises three-modifier parsing and
produces an unmistakable visible result, so one keystroke validates every 3-key rule at once.

---

## Mac shortcuts with no clean Windows equivalent

Worth naming so they are not chased:

| Mac | Situation |
|---|---|
| `Cmd+,` preferences | No Windows convention; every app differs. |
| `Cmd+H` hide app | No equivalent. `Win+Down` minimises, which is not the same. |
| `Cmd+Opt+D` toggle Dock | No Dock. |
| `Cmd+Space` Spotlight | Command Palette is the analogue, default `Win+Alt+Space`. Binding it to `Ctrl+Space` makes it physical Cmd+Space but collides with IntelliJ / Visual Studio completion. |
| `Cmd+Left` line start | Conflicts with browser Back — see below. |
| `Ctrl+A` / `Ctrl+E` line start/end | Emacs bindings macOS honours system-wide; Windows has no equivalent layer. |
| Natural scroll direction | Not a keyboard setting — needs the per-device `FlipFlopWheel` registry value. |

---

## App-specific rules

The shipped map gives `Cmd+Left/Right` to browser Back/Forward globally, which means text
fields lose `Home`/`End` on those keys. To have both, move Back/Forward into app-specific
rules and let the global rule be `Home`/`End`:

| Scope | From | To |
|---|---|---|
| global | `Ctrl+Left` | `Home` |
| global | `Ctrl+Right` | `End` |
| `msedge` | `Ctrl+Left` | `Alt+Left` |
| `chrome` | `Ctrl+Left` | `Alt+Left` |

Keyboard Manager matches on **process name**, not window title or display name — `msedge`, not
"Microsoft Edge". Find names with `Get-Process` or `tasklist`. Common ones: `msedge`, `chrome`,
`explorer`, `Code`, `WindowsTerminal`, `outlook`, `ms-teams`, `winword`, `excel`.

The two global rows above are **shortcut-to-single-key** remaps (`Ctrl+Left` → `Home`, one key
on the To side). `Set-MacKeymap.ps1` supports these: write `To = 'Home'` and, if the rule
should only fire when nothing else is held, add `ExactMatch = $true`.

`Set-MacKeymap.ps1` only writes **global** rules. App-specific entries live in the
`remapShortcuts.appSpecific` array, which the GUI populates via its "Target app" field —
adding them through the editor avoids guessing at that array's field names. Note that a
GUI edit makes `default.json` diverge from the sidecar manifest, which `Test-Setup.ps1` will
report; the next `Set-MacKeymap.ps1` run overwrites global rules, so keep the app-specific
ones in the GUI and the global ones in the table.

---

## PowerToys module keys

`settings.json` → `enabled` block. Names that differ from the UI label are the ones that cause
silent no-ops:

| UI label | key | | UI label | key |
|---|---|---|---|---|
| Window Hopper | `AltWindowCycle` | | Advanced Paste | `AdvancedPaste` |
| Screen Ruler | `Measure Tool` | | Always On Top | `AlwaysOnTop` |
| Command Palette | `CmdPal` | | Awake | `Awake` |
| Command Not Found | `CmdNotFound` | | Color Picker | `ColorPicker` |
| Hosts File Editor | `Hosts` | | Crop And Lock | `CropAndLock` |
| New+ | `NewPlus` | | Environment Variables | `EnvironmentVariables` |
| Mouse Crosshairs | `MousePointerCrosshairs` | | FancyZones | `FancyZones` |
| File Explorer add-ons | `File Explorer` | | Find My Mouse | `FindMyMouse` |
| File Locksmith | `File Locksmith` | | Grab And Move | `GrabAndMove` |
| Image Resizer | `Image Resizer` | | Keyboard Manager | `Keyboard Manager` |
| Light Switch | `LightSwitch` | | Mouse Highlighter | `MouseHighlighter` |
| Mouse Jump | `MouseJump` | | Mouse Without Borders | `MouseWithoutBorders` |
| Peek | `Peek` | | Power Display | `PowerDisplay` |
| PowerRename | `PowerRename` | | PowerToys Run | `PowerToys Run` |
| Quick Accent | `QuickAccent` | | Registry Preview | `RegistryPreview` |
| Shortcut Guide | `Shortcut Guide` | | Text Extractor | `TextExtractor` |
| Workspaces | `Workspaces` | | ZoomIt | `ZoomIt` |

Modules relevant to this skill that ship **disabled** by default include Window Hopper — a
mapping to `Alt+backtick` is inert until it is turned on.

Default activation shortcuts worth knowing: Window Hopper `Alt+backtick` (reverse
`Shift+Alt+backtick`), Command Palette `Win+Alt+Space`, PowerToys Run `Alt+Space`, Text
Extractor `Win+Shift+T`, Always On Top `Win+Ctrl+T`.

---

## File locations

| What | Path |
|---|---|
| Keymap | `%LOCALAPPDATA%\Microsoft\PowerToys\Keyboard Manager\default.json` |
| Sidecar manifest | `%LOCALAPPDATA%\Microsoft\PowerToys\Keyboard Manager\wintomac.manifest.json` |
| PowerToys settings | `%LOCALAPPDATA%\Microsoft\PowerToys\settings.json` |
| PowerToys binary | `%LOCALAPPDATA%\PowerToys\PowerToys.exe` (user install) |
| Sysinternals | `%LOCALAPPDATA%\Programs\Sysinternals` (this skill's layout) |
| Shortcuts | `%USERPROFILE%\Desktop\Tools` |
| Scancode Map | `HKLM\SYSTEM\CurrentControlSet\Control\Keyboard Layout\Scancode Map` |

A machine-wide PowerToys install lives in `%PROGRAMFILES%\PowerToys` instead; winget's default
is the per-user path above.

### The sidecar manifest

`default.json`'s schema belongs to PowerToys, so `Set-MacKeymap.ps1` records intent that
PowerToys has no field for in a separate file beside it:

```json
{
  "generatedBy": "wintomac/Set-MacKeymap.ps1",
  "generatedAt": "2026-08-28T15:20:11.0000000+09:00",
  "allowedOrphans": ["164;8", "162;81", "162;77"],
  "defaultJsonSha256": "A1B2..."
}
```

It does two jobs. `allowedOrphans` lets `Test-Setup.ps1` subtract the deliberate orphans, so
the orphan warning stays high-signal instead of listing ten expected ones. `defaultJsonSha256`
lets it notice that `default.json` was changed out of band — almost always an edit made in the
Keyboard Manager GUI, which the next script run would silently overwrite. Porting the GUI edit
into the table first is the fix.

Deleting the manifest is harmless; the checks fall back to reporting everything.
