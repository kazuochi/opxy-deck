# Herdr reference for deck mapping

The installed `herdr` CLI is the source of truth — re-check `herdr --help` /
`herdr <sub> --help` when a mapping misbehaves. `~/.config/herdr/config.toml`
is stock: all default keybindings apply, prefix = `ctrl+b`.

## What herdr is

Terminal workspace manager / multiplexer for AI coding agents ("one terminal
for the whole herd"). Hierarchy: **workspace → tab → pane**; panes host agents
(claude, codex, …) with semantic state (idle / working / blocked / done).
Everything is scriptable over a socket API via the `herdr` CLI.

## Two ways to drive herdr from the deck

1. **`shell` actions (preferred).** `herdr <verb>` talks to the server socket —
   works no matter which pane has keyboard focus, and can't collide with text
   the agent is typing. Use for pane/tab/workspace/agent operations.
2. **`key` chords.** Herdr's prefix is `ctrl+b`, so a herdr binding
   `prefix+z` maps to the deck as `{"action":"key","keys":["C-b","z"]}`.
   Keys land in the *focused* terminal — only use when no CLI verb exists
   (e.g. opening interactive pickers: goto, workspace picker, resize mode).

Blocking verbs (`herdr wait …`, `herdr agent wait …`) are for scripts —
don't map them to deck controls.

## CLI verbs useful on the deck

Pane IDs look like `1-1` and change as layouts change — prefer `--current`
and directional forms in mappings; hardcode IDs only for throwaway setups.

```
herdr pane focus  --direction left|right|up|down
herdr pane swap   --direction left|right|up|down
herdr pane resize --direction left|right|up|down [--amount FLOAT]
herdr pane zoom   --toggle            # also --on / --off
herdr pane split  --current --direction right|down [--ratio F] [--focus]
herdr pane close  <pane_id>           # destructive — confirm before mapping
herdr pane run    <pane_id> <command> # command + Enter
herdr pane send-text <pane_id> <text> # literal text, no Enter

herdr agent list
herdr agent focus <target>            # target = name/label, e.g. "review"
herdr agent send  <target> <text>
herdr agent start <name> [--split right|down] [--cwd PATH] [--focus] -- <argv…>
   # e.g. herdr agent start "claude-$(date +%H%M%S)" --split right --focus -- claude

herdr tab create [--label TEXT] [--focus]
herdr tab focus <tab_id>              # no next/prev CLI — use keys C-b n / C-b p

herdr workspace create [--cwd PATH] [--label TEXT] [--focus]
herdr workspace focus <workspace_id>

herdr worktree create [--branch NAME] [--focus]   # git worktree + workspace
herdr worktree open   (--path PATH | --branch NAME)

herdr notification show <title> [--body TEXT] [--sound none|done|request]
herdr server reload-config
```

## Default keybindings (stock config — what `key` mappings must send)

Deck chord syntax: prefix = `C-b`, then the key, as a `keys` sequence.

| Herdr action | Binding | Deck payload |
|---|---|---|
| goto (fuzzy jump) | prefix+g | `"keys": ["C-b","g"]` |
| workspace picker | prefix+w | `"keys": ["C-b","w"]` |
| next / previous tab | prefix+n / prefix+p | `["C-b","n"]` / `["C-b","p"]` |
| new tab | prefix+c | `["C-b","c"]` |
| switch to tab 1–9 | prefix+1..9 | `["C-b","1"]` … |
| split vertical / horizontal | prefix+v / prefix+minus | `["C-b","v"]` / `["C-b","Minus"]` |
| zoom pane | prefix+z | `["C-b","z"]` (CLI `pane zoom --toggle` preferred) |
| focus pane h/j/k/l | prefix+h/j/k/l | CLI `pane focus --direction …` preferred |
| cycle pane next/prev | prefix+tab / prefix+shift+tab | `["C-b","Tab"]` / `["C-b","S-Tab"]` |
| resize mode | prefix+r | `["C-b","r"]` (then arrows in-app) |
| toggle sidebar | prefix+b | `["C-b","b"]` |
| edit scrollback | prefix+e | `["C-b","e"]` |
| new workspace / worktree | prefix+shift+n / prefix+shift+g | CLI preferred |
| close pane / tab / workspace | prefix+x / prefix+shift+x / prefix+shift+d | destructive — confirm first |
| detach | prefix+q | `["C-b","q"]` |
| settings / help | prefix+s / prefix+? | `["C-b","s"]` / `["C-b","S-/"]` |
| open notification target | prefix+o | `["C-b","o"]` |

Inside the agents sidebar / pickers, plain `h j k l`, arrows, `enter`, `esc`
navigate — the deck's `select` (Down/Up) and `submit`/`esc` actions work there.

## Index-based selection (tabs / workspaces / agents)

All `herdr … list` commands print JSON. Tabs carry a stable per-workspace
`number`, workspaces a global `number`; agents have no number — list order =
sidebar order. Nop-safe when the index doesn't exist:

```sh
# tab N in the focused workspace
ws=$(herdr workspace list | jq -r '.result.workspaces[]|select(.focused).workspace_id'); id=$(herdr tab list --workspace "$ws" | jq -r '.result.tabs[]|select(.number==N).tab_id'); [ -n "$id" ] && herdr tab focus "$id"
# workspace N
id=$(herdr workspace list | jq -r '.result.workspaces[]|select(.number==N).workspace_id'); [ -n "$id" ] && herdr workspace focus "$id"
# agent N (1-based list order; focus jumps across workspaces)
t=$(herdr agent list | jq -r '.result.agents[N-1].terminal_id // empty'); [ -n "$t" ] && herdr agent focus "$t"
```

## OP-XY controls outside the census

- Track keys 1–8 = **CC 19–26**. Profile entries need explicit `"cc": N`
  (any entry key name works).
- `make capture` receives no MIDI from Claude's sandboxed shell (silent
  denial). Have the user run `! cd ~/Developer/opxy-deck && ./opxy-bridge
  --capture` themselves, or read their pane via `herdr pane read`.

## Herdr-specific mapping facts

- The bundled `herdr` profile already uses: step1–4 = pane focus h/j/k/l,
  step5 = zoom toggle, step6 = spawn new Claude agent in a right split,
  step16 = `profile_cycle`. Keep that spatial convention when extending
  (steps row ≈ session/nav).
- Claude-only deck actions (`ptt`, `thinking_toggle`, `effort_command`,
  `model_picker`) act on the **focused pane** — inert or near-inert when a
  Codex/other agent pane has focus. Fine to map; warn the user if they run
  mixed agents.
- `herdr agent start` names must be unique — the bundled profile appends
  `$(date +%H%M%S)` for repeat presses; keep that trick.
- Custom keybindings would live in `~/.config/herdr/config.toml` `[keys]`;
  it's currently stock. If Kaz customizes it, update the table above.
  `herdr config reset-keys` restores defaults.
- Shortcut source of truth order: user's config.toml → `herdr --default-config`
  → https://herdr.dev/docs/ (quick-start, cli-reference, configuration).
