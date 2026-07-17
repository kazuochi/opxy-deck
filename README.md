# opxy-claude-deck

Use a Teenage Engineering OP-XY as a physical control deck for Claude Code:
dictate by holding a key, twist knobs to pick model / thinking effort / rewind
target, dedicated keys for submit and interrupt.

Mappings live in per-app **profiles** (Claude Code today; herdr, the desktop app,
or any app that takes keystrokes tomorrow) that **hot-reload** on edit — switch by
deck key, CLI, GUI picker, or by asking your agent to remap something. Schema and
agent workflow: `MAPPING-SCHEMA.md`.

```
OP-XY (MIDI controller mode) ──USB──▶ receivemidi ──▶ opxy-bridge ──▶ keystrokes ──▶ Claude Code
```

The bridge is a single dependency-free Swift file. Keystrokes go to the
frontmost app by default (works with the CLI in any terminal, and with the
desktop app), or into a specific tmux pane with `--tmux` (focus-free, no
permissions, works with iPad-over-SSH setups).

## Controls (v0)

The transport buttons carry the frequent actions (semantic + hard to fat-finger),
piano keys the rest, encoders the continuous stuff:

| Control | What it does | How it works |
|---|---|---|
| **RECORD** button | **Hold to dictate, release to send.** Or quick-tap to start, tap again to send | CC 55: `Space` on press, `Space` on release if held ≥ 0.25 s. Uses Claude Code `/voice tap` mode |
| **PLAY** button | Send prompt / accept selection | CC 56 → `Enter` |
| **STOP** button | Interrupt; press ×2 on empty input = **rewind menu** | CC 57 → `Esc` |
| Effort piano key | Run `/effort` | note → types `/effort` + `Enter` |
| Model piano key | Open model picker | note → types `/model` + `Enter` |
| Thinking piano key | Toggle extended thinking | note → `Option+T` |
| Select knob (1st) | Choose in any list: model, effort, **rewind target**, permission options, history | `Up`/`Down` |
| Effort knob (2nd) | Effort inside the model picker; dialog tabs | `Left`/`Right` |
| **Scroll knob (3rd)** | **Smooth-scroll the output** (line by line) | wheel events — mouse must be over the terminal |
| **Page knob (4th)** | **Page-scroll the output** (big jumps) | `PageUp`/`PageDown` — works regardless of mouse |
| **Knob click** (1st/2nd) | **Confirm the highlighted selection** | CC 15 / 16 → `Enter` |

Pick-a-model / pick-an-effort flow: tap the **Model** (or **Effort**) key to open it →
**turn the select knob** to highlight → **click the knob** to confirm. Same idea in the
rewind menu (`Stop`×2), permission dialogs, and history.

Transport buttons (record/play/stop) send momentary CC (127 press / 0 release), so
they behave exactly like keys — including hold-to-dictate on record. Notes and CCs
don't collide, so a piano key on note 56 and the play button on CC 56 coexist fine.

The flow you asked for: `Esc Esc` → rewind menu opens → turn select knob to
pick the message → submit key to revert. Same knobs work inside `/model`:
select knob picks the model, effort knob sets the thinking effort level
(`modelPicker` has dedicated Left/Right effort actions), submit key confirms.

## Profiles

One profile = one complete mapping for one context. `profiles/<name>.json` in the
repo holds the universally useful ones (`claude-code` ships); private ones go in
`~/.config/opxy-deck/profiles/` and win on name collision. The active profile is
`~/.config/opxy-deck/deck-state.json` — *writing that file is switching*, so every
switching surface is just a writer:

- `make use P=<name>` (or `./opxy-bridge --use <name>`)
- a deck key mapped to `"action": "profile_cycle"` (cycles alphabetically, chimes)
- the GUI's profile picker
- an agent editing the file

The running bridge watches the state file and the active profile (0.5 s poll):
edits apply live with **validate-before-swap** — a broken edit is rejected with an
error chime (Sosumi) and the last-good mapping stays live. Switching plays the
profile's own `chime`. `make check` validates by hand; `make profiles` lists;
`make capture` prints the next control you touch as JSON (the "map *this* knob"
flow). Beyond the classic actions, `type` / `key` / `turn` / `shell` primitives map
anything — any slash command, chord, or shell hook — with zero recompiles; see
`MAPPING-SCHEMA.md` for the full schema, action table, and agent guard rails.

The old `mapping.json` (v0 arrays) still loads and `--migrate` converts it.

## Setup (once, ~10 min)

1. **Install MIDI CLIs** (done if you ran the session setup):
   `brew install gbevin/tools/receivemidi gbevin/tools/sendmidi`
2. **Connect the OP-XY** — either works, the software is identical (CoreMIDI
   abstracts the transport):
   - **USB-C:** just plug in.
   - **Bluetooth (no cable):** on the OP-XY, in the `com` screen press *down* the
     dark grey encoder to advertise BLE MIDI (device-side step, unavoidable).
     Mac side: the mapper detects the OP-XY advertising and highlights its
     **Connect Bluetooth MIDI** button — click it, pick the OP-XY in the system
     window, Connect. That's a **one-time** setup: macOS then remembers the OP-XY
     and auto-reconnects it whenever it advertises, so afterwards the flow is just
     power on → `com` → click knob → connected. (macOS exposes no fully-headless
     BLE→MIDI connect; the first connection must go through this system window —
     raw Bluetooth-level connection does not create a MIDI device.)
   Then put it in controller mode: press `com`, then `M2`. Run `make list` to see
   the exact device name and pass `DEVICE="<name>"` to the make targets if it
   isn't `OP-XY` (the Bluetooth name can differ from the USB one). Bluetooth adds
   a few ms latency — irrelevant for button/knob presses — and reaches ~10 m.
3. **Map your controls.** The **transport buttons** (record/play/stop → dictate/
   submit/esc) and knobs are already set in `profiles/claude-code.json`. To (re)map
   the **piano keys** and knobs, run `make learn` — it prompts action by action
   ("press the pad for MODEL…", "turn the knob for EFFORT…") and writes the active
   profile; it preserves everything else (transport buttons, macros). Or edit the
   profile directly — entries are `"<control-name>": { "action": "…" }` with census
   names like `transport.play` (see `MAPPING-SCHEMA.md`); the bridge hot-reloads and
   `make check` validates. Knobs default to `"mode": "absolute"` —
   the OP-XY's controller-mode default is absolute 0–127 positions, and the bridge
   turns position deltas into arrow presses. Add `"invert": true` to a knob to flip
   its direction. If you switch the device's encoders to relative (shift + mid gray
   knob in controller mode), set `"mode": "relative"`.
4. **Claude Code voice, tap mode:** in a Claude Code session run `/voice tap`.
   Tap mode is required — hold mode detects keys via terminal key-repeat, which
   synthetic keystrokes don't produce. (Dictating in Japanese? Set
   `"language": "japanese"` in `~/.claude/settings.json`; JA auto-submit needs
   Claude Code ≥ 2.1.195.)
5. **Mic permission:** first `/voice` run prompts for terminal mic access — allow.
6. **Accessibility permission** (default CGEvent mode only): System Settings →
   Privacy & Security → Accessibility → enable your terminal app, restart it.
   The bridge warns at startup if this is missing. (`--tmux` mode needs none.)
7. **Test safely:** `make dry` — press deck controls, watch decoded actions
   print without any keystrokes being sent. Then `make run` for real.

## Notes & gotchas

- **PTT starts only when the prompt input is empty** (Claude Code tap-mode
  rule). With text present, the first Space just types a space. The stop/send
  tap works regardless of input contents. Auto-submit needs ≥ 3 words —
  shorter dictations are inserted but not sent (protects against stray taps).
- **Recording auto-stops** after 15 s of silence or 2 min total.
- Voice requires **Claude.ai account auth** (not API key / Bedrock / Vertex) and
  a **local mic** — dictation does not work over SSH, so in the iPad-over-SSH
  setup voice is unavailable; all other deck controls work.
- `Option+T` thinking toggle works without Option-as-Meta terminal config on
  Claude Code ≥ 2.1.132. It's a no-op on models that always think.
- Desktop app: default CGEvent mode types into whatever is frontmost — bring
  the Claude window forward. `/model`-typing and arrow/Enter/Esc/Space behave
  the same; if anything differs it's the app's keybinding coverage, not the bridge.
- If events feel laggy through the pipe, run `receivemidi` and the bridge in a
  real terminal (not an IDE task runner); receivemidi flushes per event.
- A bumped mode button on the OP-XY changes what it sends. If keys stop working,
  check you're still in controller mode (`com` → `M2`). Unknown notes/CCs are
  ignored by design.
- **Knob goes dead at one extreme?** Absolute mode clamps at 0/127. The bridge
  treats a re-sent bound as continued turning, but if your unit goes silent at the
  rail instead, flip the encoders to relative on the device (shift + mid gray knob),
  set that knob's `"mode": "relative"`, and check direction with `make dry`.

## iPad / iOS

Directly driving the Claude (or Codex) iOS app from the OP-XY is **not
possible**: iOS sandboxing has no cross-app synthetic input, Safari/WebKit has
no Web MIDI, and iOS apps only react to MIDI if the app itself implements it.

What works instead: **iPad as the screen, Mac as the engine.** Run Claude Code
CLI in tmux on the Mac, view it from the iPad (Blink/Termius over Tailscale, or
one of the "remote Claude Code" iPad apps), and run the deck against the same
session with `make tmux TARGET=<session>`. MIDI never touches the iPad — the
bridge injects server-side into tmux, and the SSH app just displays the result.

The OP-XY is **not a network device** (no WiFi/IP — it can't join Tailscale); it
speaks MIDI only over local USB and BLE. So *where the OP-XY physically is*
decides the setup:

| You are | OP-XY connects to | How |
|---|---|---|
| At the desk | Mac, USB-C | default `make run` / `make tmux` |
| Home, roaming ~10m (couch) | Mac, **BLE MIDI** | Audio MIDI Setup → Bluetooth; check name via `make list`. Same pipeline unchanged |
| **Out, Mac at home, iPad on Tailscale** | **iPad**, USB-C or BLE | see below — the OP-XY comes *with you* |

**Remote path (out of the house).** The OP-XY plugs into the *iPad* (iPadOS reads
MIDI via CoreMIDI). Bridge it to the Mac over Tailscale via **RTP-MIDI**: an iOS
app (e.g. "RTP-MIDI (Network MIDI)") exposes the OP-XY as a network MIDI session;
the **Mac initiates** the session across the tailnet (iOS can't initiate — it
needs an external initiator, which the Mac is). The OP-XY then appears as a
normal CoreMIDI source on the Mac, so `receivemidi` + this bridge run
**unchanged**. Button-press latency over Tailscale is negligible. Not yet
tested — verify the Mac can open the RTP-MIDI session to the iPad's tailnet IP
(UDP). Alternative: a custom iPad app that reads MIDI and SSHes keystrokes to the
Mac itself (self-contained, more work).

**Voice is desk-only, always.** Dictation records the *Mac's* mic, so it's
useless when you're not in the room — every other control still works remotely.

## GUI mapper

`make gui` opens the visual mapper — a full-panel line-art rendition of the
OP-XY (self-drawn, TE-style): speaker, display, main knob, 4 encoders,
module/step rows, transport, and the full two-octave keyboard, every control
clickable in its real position.

- **Touch any physical control** → it lights up and selects on screen.
  **Click an on-screen control** → if unidentified, press it on the device to
  capture its MIDI id (stored in `opxy-controls.json`). The keyboard ships
  pre-placed (F = note 53, learned 2026-07-15); identifying any one key
  re-places all 24 chromatically.
- **Control types are modeled**: encoders are endless + clickable (a
  turn/click segmented picker in the detail panel gives each its own action);
  the main knob is finite/no-click; keyboard keys are velocity-sensitive;
  everything else is a plain key.
- **Pick an action** (incl. `shell` / `type` / `key` with a payload field — e.g.
  `herdr agent focus review`, `/compact\n`, `M-t` — and per-knob invert), then
  **Save** (⌘S). Writes the **active profile** (picker in the toolbar switches it,
  live), preserving entries it doesn't own — agent-authored payloads survive GUI
  saves — and runs `--check` on the result, showing the verdict in the status bar.
- **▶ Run / ◼ Stop bridge** from the toolbar. No restart needed on Save — the
  bridge hot-reloads the profile by itself. Note: when the bridge runs from the
  GUI, macOS asks for Accessibility for the *mapper* app (one-time).
- **OP-XY connection dot** (green/red, live), MIDI monitor + bridge log strips.
- `make miditest` injects a synthetic test sequence for a device-free demo.

## Multi-agent with herdr

[herdr](https://herdr.dev) is an agent multiplexer: split panes, one agent per
pane, sidebar showing each agent's state (working / blocked / done / idle), a
persistent background server, and a socket API. The deck integrates two ways:

- **Bundled profile: `make use P=herdr`.** Everything from the claude-code
  profile, plus the step row (all focus-free socket verbs, no herdr window
  focus needed): **steps 1–4** = focus pane left/down/up/right (h j k l order,
  matching herdr's own `prefix+h/j/k/l`), **step 5** = zoom toggle, **step 6** =
  spawn a new Claude agent in a right split, **step 16** = cycle back to the
  claude-code profile. Edges are harmless no-ops; herdr's focus is server-side,
  so every attached client follows.
- **Named session keys (add when you name agents).** `herdr agent focus <name>`
  needs a real agent (bare panes error) — once you adopt names
  (`herdr agent start <name> -- claude`, or `herdr agent rename`), copy the
  profile to `~/.config/opxy-deck/profiles/herdr.json` (private wins) and add
  steps 7–14 as `"action": "shell"`, `"command": "herdr agent focus <name>"` —
  names survive layout changes. Tab switching is chord-only (no id-free CLI
  verb): map a key to `"action": "key", "keys": ["C-b","n"]` (herdr defaults:
  `prefix+n/p` tabs, `prefix+1..9` indexed).
- **Audible status → `make watch`.** `herdr-watch.sh` polls the socket and
  chimes on any agent's state change: → blocked = urgent (needs you),
  → done / turn ended = soft chime. Works for every agent herdr detects, no
  per-agent hooks. Swap `afplay` lines for `sendmidi` to voice it through the
  OP-XY itself.

Everything else on the deck (dictate/submit/esc/knobs) needs no changes — those
keystrokes go to the focused pane, and herdr routes them.

Quick start: `brew install herdr`, run `herdr` in your terminal, split panes
(prefix `Ctrl+B`, then `v` / `-`, or right-click), launch an agent per pane,
and `make watch` in a spare terminal.

## Roadmap

(v0.3 — profiles, primitives, hot reload, `--check`/`--capture`/`--use` — shipped;
see `MAPPING-SCHEMA.md`. Architecture doc lives in the vault: `ARCHITECTURE.md`.)

- Phase B: `/deck` skill — remap-by-chat from any Claude Code session
- Phase C: menu-bar status + pin, frontmost-app follow-mode, GUI live re-render
  on external edits, per-profile overlay-strip PDF
- Phase D: ⌘K agent command bar in the GUI (headless `claude -p`)
- Still parked: hooks → `sendmidi` status sounds through the OP-XY engines,
  per-session voices, session-select keys, launchd daemon
