#!/bin/bash
# opxy-deck doctor — preflight checks with printed fixes. Run: make doctor
cd "$(dirname "$0")"
PASS=0; WARN=0; FAIL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
warn() { echo "  ! $1"; WARN=$((WARN+1)); }
fail() { echo "  ✗ $1"; echo "      fix: $2"; FAIL=$((FAIL+1)); }

echo "opxy-deck doctor"
echo "— toolchain"
command -v swiftc >/dev/null && ok "swiftc (Xcode Command Line Tools)" \
  || fail "swiftc missing" "xcode-select --install"
command -v receivemidi >/dev/null && ok "receivemidi" \
  || fail "receivemidi missing" "brew install gbevin/tools/receivemidi"
command -v sendmidi >/dev/null && ok "sendmidi" \
  || warn "sendmidi missing — only needed for audio-status/beat features: brew install gbevin/tools/sendmidi"
if [ -x ./opxy-bridge ]; then ok "opxy-bridge built"
elif command -v swiftc >/dev/null && swiftc -O opxy-bridge.swift -o opxy-bridge 2>/dev/null; then
  ok "opxy-bridge built (just now)"
else
  fail "opxy-bridge not built" "make build"
fi

echo "— config"
[ -f opxy-controls.json ] && ok "census (opxy-controls.json)" \
  || fail "census missing" "re-clone the repo, or identify controls via the GUI (make gui)"
if [ -x ./opxy-bridge ]; then
  ACTIVE=$(./opxy-bridge --profiles 2>/dev/null | awk '/^\*/{print $2}')
  if ./opxy-bridge --check >/dev/null 2>&1; then ok "active profile validates (${ACTIVE:-claude-code})"
  else fail "active profile invalid" "make check   # then fix the errors it prints"; fi
fi

echo "— device"
DEVICE="${DEVICE:-OP-XY}"
if command -v receivemidi >/dev/null; then
  if receivemidi list 2>/dev/null | grep -qi "$DEVICE"; then
    ok "OP-XY visible as a MIDI device"
  else
    fail "no MIDI device matching \"$DEVICE\"" "plug in via USB-C (or connect Bluetooth MIDI), then put it in controller mode: com → M2. Named differently? run: receivemidi list, then make run DEVICE=\"<name>\""
  fi
fi

echo "— permissions"
if [ -d opxy-mapper.app ]; then
  if codesign -dv opxy-mapper.app 2>&1 | grep -q "Signature=adhoc"; then
    warn "GUI app is ad-hoc signed — every rebuild kills its Accessibility grant (System Settings keeps showing it ticked). Fix forever: make dev-cert"
  else
    ok "GUI app signed with a stable identity (Accessibility grant survives rebuilds)"
  fi
fi
if [ -x ./opxy-bridge ]; then
  if ./opxy-bridge --ax >/dev/null 2>&1; then
    ok "Accessibility granted for this terminal (keystrokes will send)"
  else
    warn "Accessibility NOT granted for this terminal — default-mode keystrokes will be silently dropped. Fix: System Settings → Privacy & Security → Accessibility → enable your terminal app, then restart it. (tmux mode needs no permission: make tmux TARGET=<pane>)"
  fi
fi

echo "— voice"
command -v sox >/dev/null && ok "sox (dictation recorder)" \
  || fail "sox missing — the terminal CLI records through sox, so the dictation key will look dead: no error, nothing happens. The desktop app is unaffected (it records via its own audio stack), which is exactly why dictation can work there and nowhere else." "brew install sox"
echo "    manual checklist — not verifiable from here:"
echo "    · in Claude Code, run: /voice tap        (tap mode is required for the deck)"
echo "    · dictation needs Claude.ai account auth (not API key) + mic permission on first use"
echo "    · mic permission is per-app — granting it to one terminal does not cover another"
echo "    · Codex panes: no native dictation — every other deck control works"

echo
echo "doctor: $PASS ok, $WARN warning(s), $FAIL problem(s)"
[ "$FAIL" = 0 ]
