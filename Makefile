DEVICE ?= OP-XY
TARGET  ?= claude

build:
	swiftc -O opxy-bridge.swift -o opxy-bridge

# GUI key mapper: click a control, press it on the OP-XY, assign an action, Save
# If assets/opxy.svg exists (TE artwork, save it yourself — not redistributable),
# it is converted to a vector PDF skin the app renders. No SVG → self-drawn panel.
gui:
	@if [ -f assets/opxy.svg ]; then \
	   python3 skinprep.py && \
	   rsvg-convert -f pdf -o assets/opxy.pdf assets/opxy-normalized.svg && \
	   echo "skin: opxy.svg → opxy.pdf"; fi
	swiftc -O -parse-as-library OpxyMapper.swift -o opxy-mapper
	rm -rf opxy-mapper.app
	mkdir -p opxy-mapper.app/Contents/MacOS
	cp Info.plist opxy-mapper.app/Contents/Info.plist
	cp opxy-mapper opxy-mapper.app/Contents/MacOS/opxy-mapper
	codesign -s - --force opxy-mapper.app 2>/dev/null || true
	pkill -x opxy-mapper 2>/dev/null || true
	sleep 0.3
	open opxy-mapper.app

# Persistent virtual MIDI source for testing GUI/bridge without the device
miditest:
	swiftc -O miditest.swift -o miditest
	./miditest

list:
	receivemidi list

# Raw MIDI dump — watch what each control sends (Ctrl+C to stop)
sniff:
	receivemidi dev "$(DEVICE)" nn

# Run receivemidi feeding opxy-bridge through a FIFO, with a trap that kills
# receivemidi on exit. Without this, receivemidi outlives the bridge (e.g. when
# --learn finishes) and holds the terminal so Ctrl+C won't return. $(1) = bridge args.
define pipe_midi
@bash -c 'F=$$(mktemp -u); mkfifo "$$F"; \
	receivemidi dev "$(DEVICE)" nn > "$$F" & R=$$!; \
	trap "kill $$R 2>/dev/null; rm -f $$F" EXIT INT TERM; \
	./opxy-bridge $(1) < "$$F"'
endef

# Profiles: run/dry/tmux use the active profile from ~/.config/opxy-deck/deck-state.json,
# hot-reloaded on edit/switch. Pin one for this run with PROFILE=<name>.
PROFARG = $(if $(PROFILE),--profile $(PROFILE))

# Guided setup — press each pad / turn each knob when prompted; writes the active profile
learn: build
	$(call pipe_midi,--learn)

# Decode + print actions without sending keystrokes (safe test)
dry: build
	$(call pipe_midi,$(PROFARG) --dry-run)

# The real thing: keystrokes to the frontmost app (needs Accessibility permission)
run: build
	$(call pipe_midi,$(PROFARG))

# Focus-free variant: inject into a tmux pane, e.g. `make tmux TARGET=claude`
tmux: build
	$(call pipe_midi,$(PROFARG) --tmux "$(TARGET)")

# Validate a profile (P=<name-or-path>, default: active). Agents: run this after every edit.
check: build
	./opxy-bridge --check $(P)

# Switch the active profile: `make use P=herdr`
use: build
	./opxy-bridge --use $(P)

# List available profiles (* = active; private ~/.config beats bundled repo on name clash)
profiles: build
	./opxy-bridge --profiles

# Print the next-touched control as JSON (for agents / "map this knob" flows)
capture: build
	$(call pipe_midi,--capture)

# Audible agent status: chime when any herdr-managed agent blocks or finishes
watch:
	./herdr-watch.sh

# Preflight: toolchain, device, profile, permissions — prints the fix for anything missing
doctor:
	@./doctor.sh

# Full self-test with fake MIDI (no device needed): legacy + v1 schemas, primitives,
# --check validation, --capture, state round-trip, hot reload, --migrate
selftest: build
	./selftest.sh

.PHONY: build gui miditest list sniff learn dry run tmux check use profiles capture watch doctor selftest
