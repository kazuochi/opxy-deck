---
name: deck
description: Map OP-XY deck controls to actions by editing opxy-deck profiles. Use when the user asks to map/remap a deck control ("map record to dictation"), create a profile for an app ("make me a Final Cut profile"), switch or inspect profiles, or wire a control they can't name ("map THIS knob"). Requires the opxy-deck repo (opxy-bridge) on this machine.
---

# opxy-deck — conversational mapping

You are editing declarative MIDI-mapping profiles for a running bridge that
hot-reloads them. Small, careful file edits — validated, then confirmed on the
device by the user — are the whole job.

## Locate the repo (once per session)

The repo is the directory containing `opxy-bridge.swift` and `MAPPING-SCHEMA.md`.
Check `~/Developer/opxy-deck` first; otherwise ask the user once and remember.
Run all `make` / `./opxy-bridge` commands from the repo root.

**Before your first edit, read `MAPPING-SCHEMA.md`** — it is the single source of
truth for file locations, the profile schema, census control names, actions,
payloads, and chord syntax. Do not rely on memory of the schema; read it.

## Core loop (single mapping change)

1. **Resolve the control name.** Census names live in `opxy-controls.json`
   (e.g. `transport.record`, `enc3.turn`, `kb.w3`, `step5`). If the user says
   "this one" or you can't tell which control they mean, run `make capture` and
   ask them to touch it — it prints the name as JSON.
2. **Resolve the profile.** Default to the active profile (`make profiles`
   shows it starred). If the user names an app/profile, use that one. Private
   profiles: `~/.config/opxy-deck/profiles/<name>.json` (win on name clash);
   bundled: `<repo>/profiles/<name>.json`.
3. **Edit the JSON** — one entry per control, minimal diff. Prefer semantic
   actions (`ptt`, `submit`, `esc`) where they exist; otherwise primitives:
   `type` (text, `\n` = Enter), `key` (chord or keys sequence), `turn`
   (cw/ccw chords, knobs only), `shell` (command).
4. **Validate: `make check P=<name-or-path>`.** Fix errors before declaring
   done. Warnings: surface them to the user verbatim.
5. **Confirm the reload.** If the bridge is running it hot-reloads within
   ~0.5 s — tell the user "try it now" (pressing the control is the real
   confirmation). If validation passed but behavior is wrong, read the bridge's
   stderr log for what actually fired.
6. **Commit** in the repo (`git add -A && git commit`) with a one-line message.
   Private-tier profiles: commit only if that directory is a git repo; skip
   silently otherwise.

## New-app profile ("make me a <app> profile")

1. Research the app's real keyboard shortcuts — official documentation first,
   never from memory. Where no shortcut exists, use `shell` (AppleScript /
   CLI hooks).
2. **Propose before writing** (this is mandatory for any new profile or change
   touching ≥3 controls): a table of control → action → why, honoring the
   layout conventions — frequent verbs on transport-adjacent controls,
   continuous parameters on encoder turns, toggles on piano keys, session/nav
   on step keys. Transport core stays untouched (next section).
3. On approval: write to the **private tier** by default
   (`~/.config/opxy-deck/profiles/<name>.json`); bundled `profiles/` only if
   the user says it is universally useful. Include `"app"` and a distinct
   `"chime"`. Copy an existing profile as the base so the shared core carries
   over.
4. `make check P=<name>`, then offer `make use P=<name>` to switch now.

## Guard rails (hard rules)

- **Profiles only — never edit engine source.** If a request needs behavior the
  schema cannot express (new timing semantics, new action kinds), stop and
  propose a schema extension to the user; do not patch `opxy-bridge.swift` or
  `OpxyMapper.swift` as part of a mapping request. Engine changes are
  human-gated, generic rather than feature-specific, and each should make the
  next engine change less likely. (Hold-to-repeat is already in the schema:
  `"repeat": true` — see MAPPING-SCHEMA.md.)
- **Transport core is invariant**: `transport.record` = `ptt`,
  `transport.play` = `submit`, `transport.stop` = `esc` in every profile.
  Refuse to remap these unless the user explicitly insists after you state the
  rule (muscle-memory protection). `--check` warns; you hard-stop.
- **Never edit `opxy-controls.json`** — control identities are bench truth
  captured from the device. Only the GUI identify / learn flows may change it.
- **Never edit files under `3-Resources/raw/`-style immutable dirs, and never
  delete a profile** without explicit confirmation.
- **Always `make check` after every write. Always commit after applying.**
- Do not spawn long-running processes; the user runs `make run`/`make gui`.

## Inspect / switch / undo

- "What's on the deck?" → read the active profile, render a table
  (control → action → payload), note the profile name and app.
- Switch: `make use P=<name>` (running bridge follows, with chime).
- Undo: `git log --oneline -- profiles/` in the repo, revert the relevant
  commit, `make check`. Hot reload applies the revert live.

## Facts that prevent common mistakes

- Button-vs-knob decoding follows the ACTION (knob actions: `select`/`effort`/
  `scroll`/`scroll_page`/`turn`), so never put a knob action on a button
  control or vice versa — `--check` catches it; don't write it.
- `Cmd-…` chords cannot be sent over `--tmux` mode (CGEvent mode only).
- Claude-only actions (`ptt`, `thinking_toggle`, `effort_command`) are inert
  or near-inert in Codex panes — fine to map, but say so if the user runs
  mixed agents under herdr.
- A control the census doesn't name needs explicit `"note": N` or `"cc": N`
  in its entry (any key name then works).
