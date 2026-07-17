#!/bin/bash
# opxy-bridge self-test — no device needed. Covers: legacy v0 decode, profile v1
# decode + primitives, --check validation, --capture, --use/--profiles state,
# hot reload (edit + switch + last-good on failure), --migrate round-trip.
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
    "kb.b1":            { "action": "shell", "command": "echo hi" }
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

echo "— --migrate legacy → v1"
./opxy-bridge --migrate mapping.json "$TD/migrated.json" >/dev/null 2>&1 && ok "migrate runs" || bad "migrate runs"
./opxy-bridge --check "$TD/migrated.json" >/dev/null 2>&1 && ok "migrated profile validates" || bad "migrated profile validates"
check "migrated uses census names" "grep -q 'transport.record' '$TD/migrated.json' && grep -q 'enc1.turn' '$TD/migrated.json'"

rm -rf "$TD"
echo
echo "selftest: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
