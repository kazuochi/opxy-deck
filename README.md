# opxy-deck

Turn a Teenage Engineering **OP-XY** into a physical control deck for AI coding
agents — **Claude Code** and **Codex**, solo or multiplexed under
**[herdr](https://herdr.dev)** — and, via profiles, any Mac app that takes
keystrokes. Hold a key to dictate, twist knobs to pick model / thinking effort /
rewind target, dedicated keys for submit and interrupt, step keys to hop
between agents. Profiles are plain JSON that **hot-reload** — edit them by
hand, in the GUI, or **by asking your agent** ("map this knob to zoom").

The deck supplements your keyboard; it never replaces it. Same category OpenAI's
Codex Micro validated — on richer hardware you may already own, for $0.

MIT licensed. Not affiliated with teenage engineering; OP-XY is their trademark
and their excellent hardware — this is community software for it.

```
OP-XY (controller mode) ──USB/BLE──▶ receivemidi ─▶ opxy-bridge ─▶ keystrokes ─▶ focused app
                                        profiles/*.json (hot-reload, validated)
```

## Requirements

- **macOS** (Apple Silicon or Intel) with Xcode Command Line Tools (`xcode-select --install`)
- **Teenage Engineering OP-XY** (USB-C or Bluetooth MIDI)
- [Homebrew](https://brew.sh) for the MIDI CLIs and `sox`
- **Claude Code** and/or **Codex CLI** — or any terminal app you want to drive
- Voice (optional): Claude Code with **Claude.ai account auth** (not API key) — dictation is Claude's native cloud STT — plus **`sox`** (`brew install sox`), which the terminal CLI shells out to for recording. Without it the dictation key does nothing at all, silently. Claude's *desktop app* records through its own audio stack and needs no sox, so dictation working there tells you nothing about the terminal.
- Multi-agent (optional): [herdr](https://herdr.dev)

## Quickstart (~10 minutes)

```bash
git clone https://github.com/kazuochi/opxy-deck.git && cd opxy-deck
make deps      # brew installs receivemidi + sendmidi
make doctor    # preflight — prints the fix for anything missing
```

1. **Connect the OP-XY** — USB-C: just plug in. Bluetooth: on the device press
   `com`, then click the dark-grey encoder to advertise; connect once via the
   GUI's "Connect Bluetooth MIDI" button (macOS auto-reconnects afterwards).
2. **Controller mode:** press `com`, then `M2`. (A bumped mode button later is
   the #1 "keys stopped working" cause — `make doctor` checks visibility.)
3. **Accessibility permission:** System Settings → Privacy & Security →
   Accessibility → enable your terminal, restart it. (`--tmux` mode needs none.)
4. **Voice (optional):** in Claude Code run `/voice hold` (matches the default
   profile's hold-style PTT — dictation works even mid-draft; see Troubleshooting
   for the tap alternative). Needs `sox` (`make deps` installs it).
   First use prompts for mic access — that grant is **per-app**, so a second
   terminal prompts again.
5. **Test safely, then go:**

```bash
make dry    # press controls, watch decoded actions — no keystrokes sent
make run    # the real thing (keystrokes to the frontmost app)
```

The default profile ships ready for Claude Code: the census of every control's
MIDI identity (`opxy-controls.json` — the first public OP-XY controller-mode
emit map) is included, so nothing needs sniffing. If your unit differs, one
`make learn` or a GUI identify pass fixes it.

## Controls (bundled `claude-code` profile)

| Control | What it does | How |
|---|---|---|
| **RECORD** | Hold to dictate — works mid-draft; release inserts the transcript | held `Space` via Claude's `/voice hold` |
| **PLAY** | Submit / accept selection | `Enter` |
| **STOP** | Interrupt; ×2 on empty input = rewind menu | `Esc` |
| White key 13 | Open model picker | types `/model` + `Enter` |
| White key 14 | Run `/effort` | types `/effort` + `Enter` |
| Select knob | Navigate any list: models, rewind, permissions, history | `Up`/`Down` |
| Effort knob | Effort in the model picker; dialog tabs | `Left`/`Right` |
| Scroll knob | Smooth-scroll output (pointer over terminal) | wheel events |
| Page knob | Coarse scroll | `PageUp`/`PageDown` |
| Knob click (1/2) | Confirm highlighted selection | `Enter` |
| `com` key | Backspace (hold to repeat, like a real key) | `Backspace` |

Dictate-into-a-draft is the signature move: type half the prompt, hold RECORD,
speak the rest, release, PLAY to send.

Pick-a-model flow: Model key → turn select knob → click the knob. Same knobs
work in the rewind menu (`STOP`×2), permission dialogs, and history.

## Profiles

One profile = one complete mapping for one context. Bundled profiles live in
`profiles/` (repo); private ones in `~/.config/opxy-deck/profiles/` and win on
name collision. The active profile is `~/.config/opxy-deck/deck-state.json` —
*writing that file is switching*, so every surface is just a writer:

- `make use P=<name>` · a deck key mapped to `"profile_cycle"` (cycles with a
  per-profile chime) · the GUI's picker · your agent editing the file

The running bridge watches the state file and active profile (0.5 s):
edits apply live with **validate-before-swap** — a broken edit keeps the
last-good mapping and chimes an error. `make check` validates by hand;
`make profiles` lists; `make capture` prints the next control you touch as JSON.

Beyond the semantic actions, four primitives map anything with zero recompiles:
`type` (any text/slash-command), `key` (chords like `Cmd-b`, `F6`, sequences),
`turn` (any key per knob detent — jog wheels), `shell` (any command). Full
schema, census names, actions, and chord syntax: **`MAPPING-SCHEMA.md`**.

A Final Cut profile is ~10 lines of JSON: `Space` on play, `Cmd-b` blade on
record, a frame-step jog on knob 1, `Cmd-=`/`Cmd-Minus` zoom on knob 2.

## Ask the agent (`/deck` skill)

```bash
make skill    # installs the /deck skill into ~/.claude/skills
```

Then, in any Claude Code session on this Mac:

> "Map the ÷ key to /compact" · "Map **this** knob —" *(touch it)* "— to
> timeline zoom" · "Make me a Final Cut profile" · "What's on the deck?"

The skill knows the schema, resolves controls by census name or live capture,
validates every edit with `make check` (hot reload applies it), proposes a
layout table before writing any new profile, and refuses to remap the
record/play/stop core unless you insist. Per-app support becomes a prompt, not
a plugin marketplace.

## GUI mapper

`make gui` opens a clickable line-art OP-XY: touch a physical control and it
lights up; assign actions (incl. `shell`/`type`/`key` payloads and per-knob
invert); the toolbar picker switches profiles live. Save (⌘S) writes the active
profile, preserves agent-authored entries it doesn't edit, runs `--check`, and
the bridge hot-reloads — no restart. Also handles first-time Bluetooth pairing
and control identification (press-to-identify; one piano key places all 24).

## Multi-agent with herdr

[herdr](https://herdr.dev) runs one agent per pane with a status sidebar and a
socket API. `make use P=herdr` adds, on the step row (all focus-free socket
verbs): **steps 1–4** = focus pane left/down/up/right (h j k l), **step 5** =
zoom toggle, **step 6** = spawn a new Claude agent in a right split,
**step 16** = cycle back to the claude-code profile. Everything else hits the
focused pane — and the core vocabulary is agent-agnostic: submit/interrupt/
arrows/`/model` work in both Claude Code and Codex panes.

Keys that *do* differ per agent are *routed*: the profile's `agents` section
asks herdr which agent runs in the focused pane (~6 ms, per press) and swaps
the action — in a Codex pane the effort key opens `/model` (where Codex keeps
effort), the thinking key no-ops (no equivalent), and the record key switches
to hold-style dictation (Codex is hold-to-dictate). No herdr running → base
mapping, unchanged. Schema: `MAPPING-SCHEMA.md` §Per-agent routing.

Audible status: `make watch` chimes when any herdr-detected agent blocks or
finishes (→ blocked = urgent, → done = soft). Works for every agent herdr
detects (`herdr integration install claude codex`).

Once you name agents (`herdr agent start review -- claude`), direct-select
keys are one `shell` mapping each: `herdr agent focus review`.

## Troubleshooting & limitations

- **`make doctor` first** — it checks toolchain, device visibility, profile
  validity, and Accessibility, and prints the fix for each failure.
- **Keys stopped working?** You bumped out of controller mode: `com` → `M2`.
  Unknown notes/CCs are ignored by design.
- **Keystrokes silently dropped** → Accessibility not granted for the terminal
  actually running the bridge (each app grants separately; the GUI needs its
  own grant when it runs the bridge).
- **Bridge works from `make run` but not from the GUI's ▶ button** → the GUI app
  lacks Accessibility. The app is ad-hoc signed, so its code identity changes on
  every rebuild and the old grant stops matching — leaving it **ticked in System
  Settings but refused at runtime, with nothing logged**. Adding it again with
  "+" often re-creates the same non-matching entry. Fix:

  ```bash
  make ax-reset     # clear the stale entry
  make gui          # relaunch
  ```
  then click **Grant…** in the app's orange banner and approve. The banner
  clears itself once macOS reports the grant. A terminal running `make run` is
  unaffected — it uses the terminal's own, stable grant.

  To stop this recurring, give the app a stable signing identity once:

  ```bash
  make dev-cert     # self-signed cert in your login keychain (password dialogs)
  make gui && make ax-reset   # re-sign with it + clear the old grant, Grant… once
  ```
  From then on rebuilds keep the same identity and the grant survives.
  `make doctor` warns while the app is still ad-hoc signed.
- **Dictation works in Claude's desktop app but not in the terminal?** You're
  missing `sox` — the terminal CLI records through it, the desktop app doesn't.
  Failure is silent, and every other deck control keeps working, so it reads
  like a MIDI or permissions fault when it isn't. `brew install sox`
  (`make doctor` now checks this). If the *non-voice* controls are dead too,
  it's not sox — check Accessibility above.
- **PTT quirks are Claude's rules**: tap-mode dictation starts only on an
  **empty** input; <3-word dictations insert but don't auto-submit; auto-stops
  at 15 s silence / 2 min. Voice needs Claude.ai auth and a local mic — it
  doesn't work over SSH.
- **Dictating into a drafted prompt**: tap mode refuses to start once the input
  has text (that's how it tells "start dictating" from "type a space"). Fix:
  give the record key `"style": "hold"` in the profile and run `/voice hold` —
  hold mode has no empty-input rule and inserts the transcript at the cursor.
  While the deck key is held, the bridge feeds Claude the auto-repeat stream
  its hold detection listens for; releasing stops the stream, which *is* the
  release signal. Works over `--tmux` too. Note release **inserts** the
  transcript but does not auto-submit — that's Claude's hold-mode behavior;
  PLAY (submit) sends it.
- **Knob dead at one extreme?** Absolute mode clamps at 0/127 — the bridge
  treats re-sent bounds as continued turning; if your unit goes silent at the
  rail, switch the device encoders to relative (shift + mid grey knob) and set
  that knob's `"mode": "relative"`.
- **ANSI layout assumption**: chord letters (`key` action) use ANSI virtual
  keycodes; on JIS/ISO layouts some punctuation chords land differently
  (`type` is layout-safe — it sends unicode).
- **Firmware variance**: the bundled census matches current firmware; if TE
  remaps controller mode, `make learn` / GUI identify re-captures in minutes.
- **macOS only.** Keystroke injection and CoreMIDI are the whole game here.
- If events feel laggy, run the pipeline in a real terminal, not an IDE task
  runner.

## iPad / remote

The OP-XY is not a network device; iOS apps can't be driven directly. What
works: **iPad as the screen, Mac as the engine** — Claude Code in tmux on the
Mac, viewed over Tailscale (Blink/Termius), deck injecting server-side via
`make tmux TARGET=<pane>` (no Accessibility needed). At home, BLE MIDI reaches
~10 m. Fully-remote (OP-XY travels, RTP-MIDI relay over Tailscale) is on the
roadmap, untested. Voice is desk-only always (it records the Mac's mic).

## Roadmap

- Frontmost-app **follow-mode** + menu-bar status (auto profile switching)
- Signed Mac app (DMG) folding the bridge into the GUI — no terminal required
- Audio status motifs through the OP-XY's own synth engines; per-agent voices
- Local WhisperKit dictation (offline, Japanese, and voice for Codex)
- MIDI *to* the OP-XY: agent-generated patterns recorded into the sequencer

## Repo map

`opxy-bridge.swift` (engine, dep-free) · `OpxyMapper.swift` (GUI) ·
`profiles/` (bundled mappings) · `opxy-controls.json` (census) ·
`MAPPING-SCHEMA.md` (schema truth) · `skills/deck/` (agent skill) ·
`selftest.sh` (~50 assertions, no device needed) · `doctor.sh` (preflight) ·
`miditest.swift` (virtual MIDI source for device-free testing)
