#!/bin/sh
# Ensure the herdr keybindings that opxy-deck profiles rely on. Idempotent.
#
# Encoder detents can only send a single chord, so pane cycling needs these
# one-chord direct bindings in herdr's config; herdr's defaults only offer
# two-key prefix sequences. Safe to re-run; respects an existing custom value.
set -e
CFG="${HERDR_CONFIG_PATH:-$HOME/.config/herdr/config.toml}"
NEED_NEXT='cycle_pane_next = "ctrl+alt+n"'
NEED_PREV='cycle_pane_previous = "ctrl+alt+p"'

mkdir -p "$(dirname "$CFG")"
touch "$CFG"

if grep -q '^cycle_pane_next' "$CFG"; then
  echo "setup-herdr: cycle_pane_next already set — leaving as-is:"
  grep '^cycle_pane_' "$CFG"
  echo "setup-herdr: deck profiles expect ctrl+alt+n / ctrl+alt+p (chords C-M-n / C-M-p)"
elif grep -q '^\[keys\]' "$CFG"; then
  # insert under the existing [keys] table (a second [keys] would be invalid TOML)
  awk -v a="$NEED_NEXT" -v b="$NEED_PREV" '{print} /^\[keys\]$/ {print a; print b}' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
  echo "setup-herdr: added pane-cycle bindings under existing [keys]"
else
  printf '\n[keys]\n# opxy-deck: direct one-chord bindings for deck encoder pane cycling\n%s\n%s\n' "$NEED_NEXT" "$NEED_PREV" >> "$CFG"
  echo "setup-herdr: appended [keys] section with pane-cycle bindings"
fi

if herdr server reload-config >/dev/null 2>&1; then
  echo "setup-herdr: herdr config reloaded"
else
  echo "setup-herdr: herdr not running — bindings apply on next start"
fi
