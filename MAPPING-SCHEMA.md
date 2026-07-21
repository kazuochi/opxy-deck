# Profile schema & mapping reference

The single source of truth for opxy-deck profiles — written for humans *and* agents.
If you are an agent editing a profile: **edit → `make check` → done** (the running
bridge hot-reloads within ~0.5 s; a broken edit is rejected and the last-good
mapping stays live). Commit after applying.

## Files

| Path | What | Who writes it |
|---|---|---|
| `<repo>/profiles/<name>.json` | **Bundled profiles** — universally useful (e.g. `claude-code`) | you / GUI / agents |
| `~/.config/opxy-deck/profiles/<name>.json` | **Private profiles** — personal, machine-local. Wins over a bundled profile with the same name | you / GUI / agents |
| `~/.config/opxy-deck/deck-state.json` | `{ "active": "<name>" }` — which profile is live. Writing it IS switching | `--use`, `profile_cycle`, GUI picker, agents |
| `<repo>/opxy-controls.json` | **Census** — control name ↔ MIDI identity (76 identities, complete). Read-only: only the GUI identify / learn flows may change it | GUI identify flow only |

The bridge watches the state file and the active profile (0.5 s mtime poll):
edits apply live, validate-before-swap, keep-last-good on failure (error chime).
Switching plays the profile's `chime`.

## Profile file (schema v1)

```json
{
  "app": "Claude Code (TUI)",
  "chime": "Glass",
  "controls": {
    "transport.record": { "action": "ptt" },
    "transport.play":   { "action": "submit" },
    "transport.stop":   { "action": "esc" },
    "kb.b1":            { "action": "type", "text": "/compact\n" },
    "kb.w3":            { "action": "key", "chord": "M-t" },
    "kb.w4":            { "action": "key", "keys": ["Escape", "Escape"] },
    "step1":            { "action": "shell", "command": "herdr agent focus review" },
    "step16":           { "action": "profile_cycle" },
    "enc1.turn":        { "action": "select", "invert": true },
    "enc3.turn":        { "action": "turn", "cw": "Down", "ccw": "Up" },
    "weird-pad":        { "action": "submit", "note": 99 }
  }
}
```

- `app` (optional): human label of the target app. `chime` (optional): system sound
  name (letters only, from `/System/Library/Sounds`) played when switching to this profile.
- `controls` keys are **census names** (`opxy-controls.json`). For a control the census
  doesn't know, add explicit `"note": N` or `"cc": N` to the entry (any key name then works).
- `label` is free-form and ignored by the engine.
- Two entries must not resolve to the same MIDI control (`--check` errors).

### Control names (census, quick reference)

`transport.record/play/stop` · `enc1..4.turn` + `enc1..4.click` · `kb.w0..w13` +
`kb.b0..b9` (two octaves from F) · `step1..16` · `mod1..16` · `key_com`, `key_seq`,
`key_audio`, `key_bar`, `key_pen`, `key_metronome`, `key_minus`, `key_plus`, `key_shift`.
The main volume knob transmits nothing (stays hardware volume).

## Actions

**Key/button actions** (notes and momentary CC buttons; fire on press):

| Action | Payload | Effect |
|---|---|---|
| `type` | `text` | Types the string; `\n` = Enter. Any slash command: `{"action":"type","text":"/compact\n"}` |
| `key` | `chord` or `keys` (array) | One chord, or a sequence pressed in order |
| `shell` | `command` | Runs via `/bin/sh -c` (fire-and-forget) |
| `ptt` | `style` (optional) | Dictation. `"tap"` (default): Space on press, Space again on release if held ≥ 0.25 s — pairs with Claude Code's `/voice tap`, which only starts on an **empty** input. `"hold"`: emulates a held Space for the press duration — pairs with `/voice hold`, which has no empty-input rule, so dictation can append to a drafted prompt (release inserts; it does not auto-submit). Implementation: Claude's hold detection lives on the terminal auto-repeat stream, so the bridge sends key-down + repeats at a fixed 50 ms liveness cadence + key-up; the stream stopping is the release signal. Works over `--tmux` (char stream). Safety cap ends the stream after 150 s without a MIDI release |
| `submit` | — | Enter |
| `esc` | — | Esc |
| `profile_cycle` | — | Switch to the next profile (alphabetical), with chime |
| `model_picker` | — | Types `/model` + Enter (≡ `type "/model\n"`) |
| `effort_command` | — | Types `/effort` + Enter |
| `thinking_toggle` | — | Option+T (≡ `key "M-t"`) |
| `nop` | — | Explicit do-nothing (logs). Useful as a per-agent override for a verb an agent lacks |
| `layer_toggle` | `layer` | Latches the named layer on/off with a chime (Tink/Bottle). While active, entries with a matching `layers` key behave as that variant — see §Layers |

**Knob actions** (CC encoders; fire per detent):

| Action | Payload | Effect |
|---|---|---|
| `select` | — | Down / Up (lists, menus, history) |
| `effort` | — | Right / Left (model-picker effort, dialog tabs) |
| `scroll` | — | Smooth wheel scroll (pointer must be over the terminal) |
| `scroll_page` | — | PageUp / PageDown |
| `turn` | `cw`, `ccw` (chords) | Arbitrary key per detent, each direction |

Knob options: `"mode": "absolute"` (OP-XY controller-mode default) or `"relative"`;
`"invert": true` flips direction. The engine decides button-vs-knob decoding **by the
action**, so don't put knob actions on buttons or vice versa (`--check` catches it).

### Hold-to-repeat (`key` and `type` only)

`"repeat": true` makes a held control re-fire its payload like a real keyboard key:

```jsonc
"key_com": { "action": "key", "chord": "Backspace", "repeat": true }
```

- Delay and rate default to the **user's macOS key-repeat preferences** (System
  Settings → Keyboard), so it feels identical to holding the physical key and
  tracks the sliders if they change. Override per entry with `repeatDelayMs` /
  `repeatRateMs` (clamped to ≥50/≥20 ms).
- A quick tap fires exactly once — repeat only starts after the delay.
- **Safety cap**: repeat stops after 5 s without a release (a BLE drop can lose
  the release event; a real keyboard can't). Re-press to continue. This is the
  one deliberate difference from hardware key-repeat.
- On other actions `repeat` is ignored with a `--check` warning. Knob `turn`
  entries repeat per detent by nature and don't take this flag.

### Layers (`layer_toggle` + per-entry `layers`, optional)

A latched mode that re-purposes controls — toggle, not hold, because outside the
transport keys the OP-XY sends press+release together (bench truth). The bundled
profiles use it for **edit mode**: click encoder 2 → its turn becomes a word-eater
(readline kill/yank); click again → effort knob returns.

```jsonc
"enc2.click": { "action": "layer_toggle", "layer": "edit", "timeoutMs": 1500 },
"enc2.turn":  { "action": "effort",
                "layers": { "edit": { "action": "turn", "cw": "Right", "ccw": "Backspace" } } }
```

`timeoutMs` (optional) auto-drops the layer that long after its **last variant
use** — click, twist, stop, and the layer chimes itself off; no closing click.
Omit it for a persistent latch (click on / click off).

- Any key/button/knob entry may carry `layers`: while layer *N* is active, the
  entry behaves as `layers.N`. Knob variants take knob actions (inherit
  mode/invert from the base unless set); key variants take key/button actions.
- A layer variant wins over per-agent routing; variants can't nest layers or
  toggle one. A profile switch drops all active layers.
- Feedback is audible (no screen): Tink = layer on, Bottle = off.

### Per-agent routing (`agents` + `detect`, optional)

For a profile whose panes host **different agents** (herdr multiplexing Claude Code
and Codex), a top-level `agents` section overrides key/button entries **by action
name** when the focused pane's agent label matches:

```jsonc
"agents": {
  "codex": {
    "effort_command":  { "action": "type", "text": "/model\n" },  // effort lives in Codex's /model
    "thinking_toggle": { "action": "nop" },                        // no equivalent
    "ptt":             { "action": "ptt", "style": "hold" }        // Codex hold-to-dictate
  }
}
```

- Detection runs **per press**, only in profiles that have `agents` (~6 ms):
  built-in is herdr (`herdr pane current` → `.result.pane.agent`). A top-level
  `"detect": "<shell command>"` replaces it — the command prints a bare label.
- The press's resolution is pinned until release (a ptt release always pairs with
  the entry its press used, even if focus moves mid-hold).
- No herdr / detector fails (150 ms guard) / no label / no matching override →
  the base mapping fires, exactly as without the section.
- Override values use the normal entry schema (any key/button action + payload);
  knob actions can't be overridden (knobs stay universal).

**Per-entry form** — for keys where routing by action name can't work (every
slash-command key is the same `type` action), an entry carries its own `agents`:

```jsonc
"kb.w12": { "action": "type", "text": "/effort\n",
            "agents": { "codex": { "action": "type", "text": "/model\n" } } }
```

Resolution order per press: **layer variant → entry-level agent override →
profile-level action override → base.** Design intent: the engine ships routing
as a primitive; which agents exist and what each key does per agent is entirely
profile JSON — adding an agent never needs a code change.

### Chord syntax (`key`, `turn`, `keys`)

`[mods-]key` — modifiers `M` (Option/Alt), `C` (Ctrl), `S` (Shift), `Cmd` (macOS only,
not sendable over `--tmux`). Named keys: `Enter Escape Space Tab Backspace Delete Up
Down Left Right PageUp PageDown Home End Minus Equals`, plus single characters
(`a`–`z`, digits, punctuation). Examples: `M-t`, `C-c`, `S-Left`, `Cmd-k`, `Enter`, `/`.

## Guard rails

- **Transport core is invariant**: `transport.record`=`ptt`, `transport.play`=`submit`,
  `transport.stop`=`esc` in every profile. `--check` warns on overrides; agents must
  not override without the user explicitly asking (muscle-memory protection).
- Never edit `opxy-controls.json` — identities are bench truth from the device.
- Batch changes (≥3 controls or a new profile): propose the layout as a table first.
- Always `make check` after editing; always `git commit` after applying.

## CLI verbs

```
make check [P=<name-or-path>]   validate (default: active profile); exit 1 on errors
make use P=<name>               switch active profile (running bridge follows, chimes)
make profiles                   list profiles (* = active; private beats bundled)
make capture                    print next-touched control as JSON (agent "map THIS one" flow)
make learn                      guided capture → writes the active profile
make dry / run / tmux           run the bridge (PROFILE=<name> pins one)
./opxy-bridge --migrate old.json profiles/name.json    legacy v0 arrays → v1
```

`--capture` output: `{"control":"enc3.turn","isNote":false,"num":3,"value":42}`
(`control` is `null` if the census doesn't know it). Runs fine next to a live bridge —
CoreMIDI fans out to all listeners (verified).

## Legacy (schema v0)

The old `mapping.json` shape (`keys`/`knobs`/`buttons` arrays, raw note/CC numbers)
still loads anywhere a profile is accepted, and `--migrate` converts it. New features
(census names, primitives, per-profile chimes) are v1-only.
