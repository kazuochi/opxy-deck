#!/bin/bash
# opxy-bridge self-test — no device needed. Covers: legacy v0 decode, profile v1
# decode + primitives, --check validation, --capture, --use/--profiles state,
# hot reload (edit + switch + last-good on failure), ptt hold style, --migrate
# round-trip.
set -u
cd "$(dirname "$0")"

TD=$(mktemp -d)
export OPXY_CONFIG_DIR="$TD/config"
mkdir -p "$OPXY_CONFIG_DIR/profiles"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi }

echo "— legacy v0 (mapping.json) still decodes"
OUT=$(printf 'channel 1 control-change 56 127\nchannel 1 control-change 56 0\nchannel 1 control-change 57 127\nchannel 1 control-change 57 0\nchannel 1 control-change 1 10\nchannel 1 control-change 1 11\nchannel 1 control-change 1 12\nchannel 1 control-change 1 11\nchannel 1 control-change 2 60\nchannel 1 control-change 2 61\nchannel 1 control-change 2 60\nchannel 1 control-change 55 127\nchannel 1 control-change 55 0\n' | ./opxy-bridge mapping.json --dry-run 2>&1)
check "submit (Enter)"        "grep -q '\[dry\] Enter' <<< \"\$OUT\""
check "esc (Esc)"             "grep -q '\[dry\] Esc' <<< \"\$OUT\""
check "select knob up/down"   "grep -q '\[dry\] Up' <<< \"\$OUT\" && grep -q '\[dry\] Down' <<< \"\$OUT\""
check "effort knob left/right" "grep -q '\[dry\] Right' <<< \"\$OUT\" && grep -q '\[dry\] Left' <<< \"\$OUT\""
check "ptt (Space)"           "grep -q 'Space' <<< \"\$OUT\""

echo "— profile v1: census names + primitives (type / key / turn / shell)"
cat > "$OPXY_CONFIG_DIR/profiles/test.json" <<'EOF'
{
  "app": "Test",
  "controls": {
    "transport.play":   { "action": "type", "text": "/compact\n" },
    "transport.stop":   { "action": "key", "keys": ["Escape", "Escape"] },
    "transport.record": { "action": "key", "chord": "M-t" },
    "enc1.turn":        { "action": "turn", "cw": "Right", "ccw": "Left" },
    "kb.b1":            { "action": "shell", "command": "echo hi" },
    "kb.b2":            { "action": "key", "chord": "F6" }
  }
}
EOF
OUT=$(printf 'channel 1 control-change 56 127\nchannel 1 control-change 56 0\nchannel 1 control-change 57 127\nchannel 1 control-change 57 0\nchannel 1 control-change 55 127\nchannel 1 control-change 55 0\nchannel 1 control-change 1 10\nchannel 1 control-change 1 11\nchannel 1 control-change 1 12\nchannel 1 control-change 1 11\nchannel 1 note-on 56 100\nchannel 1 note-off 56 0\n' | ./opxy-bridge --profile test --dry-run 2>&1)
check "type text"            "grep -q '\[dry\] type \"/compact\"' <<< \"\$OUT\""
check "type trailing \\n=Enter" "grep -q '\[dry\] Enter' <<< \"\$OUT\""
check "key sequence ×2"      "[ \"\$(grep -c '\[dry\] Escape' <<< \"\$OUT\")\" = 2 ]"
check "key chord M-t"        "grep -q '\[dry\] M-t' <<< \"\$OUT\""
check "turn cw ×2"           "[ \"\$(grep -c '\[dry\] Right' <<< \"\$OUT\")\" = 2 ]"
check "turn ccw ×1"          "[ \"\$(grep -c '\[dry\] Left' <<< \"\$OUT\")\" = 1 ]"
check "shell on note"        "grep -q '\[dry\] shell: echo hi' <<< \"\$OUT\""
FOUT=$(printf 'channel 1 note-on 58 100\nchannel 1 note-off 58 0\n' | ./opxy-bridge --profile test --dry-run 2>&1)
check "function key chord F6" "grep -q '\[dry\] F6' <<< \"\$FOUT\""
check "note+cc same num coexist" "grep -q 'shell: echo hi' <<< \"\$OUT\" && grep -q 'type' <<< \"\$OUT\""

echo "— --check: valid profile passes, broken profiles fail"
./opxy-bridge --check test >/dev/null 2>&1 && ok "valid profile exit 0" || bad "valid profile exit 0"
cat > "$TD/bad1.json" <<'EOF'
{ "controls": { "transport.play": { "action": "warp" } } }
EOF
./opxy-bridge --check "$TD/bad1.json" >/dev/null 2>&1 && bad "unknown action rejected" || ok "unknown action rejected"
cat > "$TD/bad2.json" <<'EOF'
{ "controls": { "no.such.control": { "action": "submit" } } }
EOF
./opxy-bridge --check "$TD/bad2.json" >/dev/null 2>&1 && bad "unknown control rejected" || ok "unknown control rejected"
cat > "$TD/bad3.json" <<'EOF'
{ "controls": { "enc1.turn": { "action": "turn" } } }
EOF
./opxy-bridge --check "$TD/bad3.json" >/dev/null 2>&1 && bad "turn without cw/ccw rejected" || ok "turn without cw/ccw rejected"
cat > "$TD/bad4.json" <<'EOF'
{ "controls": { "kb.b1": { "action": "select" } } }
EOF
./opxy-bridge --check "$TD/bad4.json" >/dev/null 2>&1 && bad "knob action on note rejected" || ok "knob action on note rejected"
cat > "$TD/warn1.json" <<'EOF'
{ "controls": { "transport.record": { "action": "submit" } } }
EOF
OUT=$(./opxy-bridge --check "$TD/warn1.json" 2>&1); RC=$?
check "core-verb override warns, passes" "[ $RC = 0 ] && grep -q 'warning:.*core verb' <<< \"\$OUT\""

echo "— --capture"
OUT=$(printf 'channel 1 control-change 55 127\n' | ./opxy-bridge --capture --timeout 2 2>/dev/null)
check "capture names the control" "grep -q '\"control\":\"transport.record\"' <<< \"\$OUT\""
OUT=$(printf '' | ./opxy-bridge --capture --timeout 1 2>&1); RC=$?
check "capture EOF/timeout exit 1" "[ $RC = 1 ]"

echo "— --ax reports a status"
OUT=$(./opxy-bridge --ax 2>&1)
check "ax prints granted|missing" "grep -Eq '^(granted|missing)$' <<< \"\$OUT\""

echo "— --use / --profiles state round-trip"
./opxy-bridge --use test >/dev/null 2>&1 && ok "use known profile" || bad "use known profile"
check "state file written" "grep -q '\"active\" : \"test\"' '$OPXY_CONFIG_DIR/deck-state.json' || grep -q '\"active\": \"test\"' '$OPXY_CONFIG_DIR/deck-state.json'"
./opxy-bridge --use nonexistent >/dev/null 2>&1 && bad "use unknown profile exit 1" || ok "use unknown profile exit 1"
OUT=$(./opxy-bridge --profiles 2>&1)
check "profiles lists active marker" "grep -q '^\* test' <<< \"\$OUT\""

echo "— hot reload: in-place edit, state switch, last-good on breakage"
cat > "$OPXY_CONFIG_DIR/profiles/hotA.json" <<'EOF'
{ "controls": { "transport.play": { "action": "submit" } } }
EOF
cat > "$OPXY_CONFIG_DIR/profiles/hotB.json" <<'EOF'
{ "controls": { "transport.play": { "action": "esc" } } }
EOF
./opxy-bridge --use hotA >/dev/null 2>&1
FIFO="$TD/fifo"; mkfifo "$FIFO"
LOGF="$TD/hot.log"
./opxy-bridge --dry-run < "$FIFO" > "$LOGF" 2>&1 &
BPID=$!
exec 3>"$FIFO"
printf 'channel 1 control-change 56 127\nchannel 1 control-change 56 0\n' >&3
sleep 0.4
# 1. edit the active profile in place → next press uses the new action
cat > "$OPXY_CONFIG_DIR/profiles/hotA.json" <<'EOF'
{ "controls": { "transport.play": { "action": "type", "text": "edited" } } }
EOF
sleep 1.3
printf 'channel 1 control-change 56 127\nchannel 1 control-change 56 0\n' >&3
sleep 0.4
# 2. switch profile via state file (what --use / profile_cycle do)
./opxy-bridge --use hotB >/dev/null 2>&1
sleep 1.3
printf 'channel 1 control-change 56 127\nchannel 1 control-change 56 0\n' >&3
sleep 0.4
# 3. break the active profile → keeps last-good
echo 'not json' > "$OPXY_CONFIG_DIR/profiles/hotB.json"
sleep 1.3
printf 'channel 1 control-change 56 127\nchannel 1 control-change 56 0\n' >&3
sleep 0.4
exec 3>&-
wait $BPID 2>/dev/null
check "initial action fired"      "grep -q '\[dry\] Enter' '$LOGF'"
check "in-place edit hot-applied" "grep -q 'reloaded hotA' '$LOGF' && grep -q 'type \"edited\"' '$LOGF'"
check "state switch hot-applied"  "grep -q 'profile: hotB' '$LOGF' && grep -q '\[dry\] Esc' '$LOGF'"
check "broken edit keeps last-good" "grep -q 'reload FAILED' '$LOGF' && [ \"\$(grep -c '\[dry\] Esc' '$LOGF')\" = 2 ]"

echo "— hold-to-repeat"
# Explicit delay/rate (200/50 ms) so the bands don't depend on this machine's
# key-repeat prefs. key_com = CC 29.
cat > "$OPXY_CONFIG_DIR/profiles/rep.json" <<'EOF'
{ "controls": { "key_com": { "action": "key", "chord": "Backspace",
                             "repeat": true, "repeatDelayMs": 200, "repeatRateMs": 50 } } }
EOF
./opxy-bridge --use rep >/dev/null 2>&1
RLOG="$TD/rep.log"
# tap 60 ms → repeat delay never reached → exactly one fire
( printf 'channel 1 control-change 29 127\n'; sleep 0.06
  printf 'channel 1 control-change 29 0\n';   sleep 0.5 ) | ./opxy-bridge --dry-run > "$RLOG" 2>&1
check "tap fires once (no repeat before delay)" "[ \"\$(grep -c Backspace '$RLOG')\" = 1 ]"
# hold 1 s → ~17 fires (1 + repeats 200..1000 ms @50 ms); then 1.2 s held-open
# silence after release. Band 8–24: <8 = repeat broken, >24 = release didn't cancel.
( printf 'channel 1 control-change 29 127\n'; sleep 1.0
  printf 'channel 1 control-change 29 0\n';   sleep 1.2 ) | ./opxy-bridge --dry-run > "$RLOG" 2>&1
N=$(grep -c Backspace "$RLOG")
check "hold repeats, release cancels ($N fires)" "[ \"$N\" -ge 8 ] && [ \"$N\" -le 24 ]"
# repeat on a non-key/type action → warning, still valid
cat > "$OPXY_CONFIG_DIR/profiles/repbad.json" <<'EOF'
{ "controls": { "transport.play": { "action": "submit", "repeat": true } } }
EOF
check "repeat on wrong action warns" "./opxy-bridge --check repbad 2>&1 | grep -q 'only applies'"

echo "— ptt hold style"
cat > "$OPXY_CONFIG_DIR/profiles/hold.json" <<'EOF'
{ "controls": { "transport.record": { "action": "ptt", "style": "hold" } } }
EOF
./opxy-bridge --check hold >/dev/null 2>&1 && ok "hold style validates" || bad "hold style validates"
./opxy-bridge --use hold >/dev/null 2>&1
HLOG="$TD/hold.log"
# press 60 ms → key-down on press, key-up on release, exactly once each
( printf 'channel 1 control-change 55 127\n'; sleep 0.06
  printf 'channel 1 control-change 55 0\n';   sleep 0.3 ) | ./opxy-bridge --dry-run > "$HLOG" 2>&1
check "hold: down on press, up on release" "[ \"\$(grep -c 'Space down' '$HLOG')\" = 1 ] && [ \"\$(grep -c 'Space up' '$HLOG')\" = 1 ]"
# hold 400 ms → liveness repeats at the fixed 50 ms cadence (~7; must beat Claude's
# ~200 ms warmup, so ≥4 in the first 400 ms proves cadence isn't on key-repeat prefs)
( printf 'channel 1 control-change 55 127\n'; sleep 0.4
  printf 'channel 1 control-change 55 0\n';   sleep 0.3 ) | ./opxy-bridge --dry-run > "$HLOG" 2>&1
N=$(grep -c 'Space repeat' "$HLOG")
check "hold: liveness repeats at 50 ms cadence ($N in 400 ms)" "[ \"$N\" -ge 4 ] && [ \"$N\" -le 12 ]"
cat > "$TD/badstyle.json" <<'EOF'
{ "controls": { "transport.record": { "action": "ptt", "style": "toggle" } } }
EOF
./opxy-bridge --check "$TD/badstyle.json" >/dev/null 2>&1 && bad "bad style value rejected" || ok "bad style value rejected"
cat > "$TD/stylewarn.json" <<'EOF'
{ "controls": { "transport.play": { "action": "submit", "style": "hold" } } }
EOF
OUT=$(./opxy-bridge --check "$TD/stylewarn.json" 2>&1); RC=$?
check "style on wrong action warns, passes" "[ $RC = 0 ] && grep -q 'only applies' <<< \"\$OUT\""

echo "— per-agent routing (agents / detect / nop)"
cat > "$OPXY_CONFIG_DIR/profiles/route.json" <<'EOF'
{
  "detect": "echo codex",
  "controls": {
    "transport.play": { "action": "submit" },
    "transport.stop": { "action": "esc" },
    "kb.b1":          { "action": "nop" }
  },
  "agents": {
    "codex": { "submit": { "action": "type", "text": "routed" } }
  }
}
EOF
./opxy-bridge --check route >/dev/null 2>&1 && ok "agents section validates" || bad "agents section validates"
./opxy-bridge --use route >/dev/null 2>&1
RTLOG="$TD/route.log"
printf 'channel 1 control-change 56 127\nchannel 1 control-change 56 0\nchannel 1 note-on 56 100\nchannel 1 note-off 56 0\n' | ./opxy-bridge --dry-run > "$RTLOG" 2>&1
check "override routes by agent label" "grep -q 'route: codex' '$RTLOG' && grep -q 'type \"routed\"' '$RTLOG' && ! grep -q '\[dry\] Enter' '$RTLOG'"
check "nop logs, sends nothing"        "grep -q 'nop (kb.b1)' '$RTLOG'"
# detector fails → base mapping fires (today's behavior)
sed -i '' 's/echo codex/false/' "$OPXY_CONFIG_DIR/profiles/route.json"
printf 'channel 1 control-change 56 127\nchannel 1 control-change 56 0\n' | ./opxy-bridge --dry-run > "$RTLOG" 2>&1
check "failed detect falls back to base" "grep -q '\[dry\] Enter' '$RTLOG' && ! grep -q 'route:' '$RTLOG'"
cat > "$TD/badroute.json" <<'EOF'
{ "controls": { "transport.play": { "action": "submit" } },
  "agents": { "codex": { "select": { "action": "esc" } } } }
EOF
./opxy-bridge --check "$TD/badroute.json" >/dev/null 2>&1 && bad "knob verb in agents rejected" || ok "knob verb in agents rejected"
cat > "$TD/badroute2.json" <<'EOF'
{ "controls": { "transport.play": { "action": "submit" } },
  "agents": { "codex": { "submit": { "action": "warp" } } } }
EOF
./opxy-bridge --check "$TD/badroute2.json" >/dev/null 2>&1 && bad "unknown override action rejected" || ok "unknown override action rejected"

echo "— layers (layer_toggle + per-layer variants)"
cat > "$OPXY_CONFIG_DIR/profiles/layer.json" <<'EOF'
{
  "controls": {
    "enc2.click": { "action": "layer_toggle", "layer": "edit" },
    "enc2.turn":  { "action": "effort",
                    "layers": { "edit": { "action": "turn", "cw": "C-y", "ccw": "C-w" } } }
  }
}
EOF
./opxy-bridge --check layer >/dev/null 2>&1 && ok "layer profile validates" || bad "layer profile validates"
./opxy-bridge --use layer >/dev/null 2>&1
LLOG="$TD/layer.log"
# click → layer ON; turn ccw → C-w (variant); click → off; turn ccw → Left (base effort)
printf 'channel 1 control-change 16 127\nchannel 1 control-change 16 0\nchannel 1 control-change 2 60\nchannel 1 control-change 2 59\nchannel 1 control-change 16 127\nchannel 1 control-change 16 0\nchannel 1 control-change 2 58\n' | ./opxy-bridge --dry-run > "$LLOG" 2>&1
check "toggle logs ON then off"      "grep -q 'layer edit: ON' '$LLOG' && grep -q 'layer edit: off' '$LLOG'"
check "variant fires while active"   "[ \"\$(grep -c 'C-w' '$LLOG')\" = 1 ]"
check "base returns after toggle-off" "[ \"\$(grep -c '\[dry\] Left' '$LLOG')\" = 1 ]"
# timeout: 300 ms after the last variant use the layer drops itself
cat > "$OPXY_CONFIG_DIR/profiles/layerto.json" <<'EOF'
{
  "controls": {
    "enc2.click": { "action": "layer_toggle", "layer": "edit", "timeoutMs": 300 },
    "enc2.turn":  { "action": "effort",
                    "layers": { "edit": { "action": "turn", "cw": "Right", "ccw": "Backspace" } } }
  }
}
EOF
./opxy-bridge --use layerto >/dev/null 2>&1
TLOG="$TD/layerto.log"
( printf 'channel 1 control-change 16 127\nchannel 1 control-change 16 0\nchannel 1 control-change 2 60\nchannel 1 control-change 2 59\n'
  sleep 0.7   # > timeout → layer must expire on its own
  printf 'channel 1 control-change 2 58\n'; sleep 0.2 ) | ./opxy-bridge --dry-run > "$TLOG" 2>&1
check "variant fires inside timeout"  "[ \"\$(grep -c 'Backspace' '$TLOG')\" = 1 ]"
check "layer expires after inactivity" "grep -q 'layer edit: off (timeout)' '$TLOG'"
check "base action back after expiry"  "[ \"\$(grep -c '\[dry\] Left' '$TLOG')\" = 1 ]"
cat > "$TD/badlayer.json" <<'EOF'
{ "controls": { "enc2.click": { "action": "layer_toggle" } } }
EOF
./opxy-bridge --check "$TD/badlayer.json" >/dev/null 2>&1 && bad "layer_toggle without layer rejected" || ok "layer_toggle without layer rejected"
cat > "$TD/badlayer2.json" <<'EOF'
{ "controls": { "enc2.turn": { "action": "effort",
                "layers": { "edit": { "action": "submit" } } } } }
EOF
./opxy-bridge --check "$TD/badlayer2.json" >/dev/null 2>&1 && bad "button action as knob variant rejected" || ok "button action as knob variant rejected"

echo "— --migrate legacy → v1"
./opxy-bridge --migrate mapping.json "$TD/migrated.json" >/dev/null 2>&1 && ok "migrate runs" || bad "migrate runs"
./opxy-bridge --check "$TD/migrated.json" >/dev/null 2>&1 && ok "migrated profile validates" || bad "migrated profile validates"
check "migrated uses census names" "grep -q 'transport.record' '$TD/migrated.json' && grep -q 'enc1.turn' '$TD/migrated.json'"

rm -rf "$TD"
echo
echo "selftest: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
