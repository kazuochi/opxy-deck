DEVICE ?= OP-XY
TARGET  ?= claude

build:
	swiftc -O opxy-bridge.swift -o opxy-bridge

# One-time dependency install (Homebrew required)
deps:
	brew install gbevin/tools/receivemidi gbevin/tools/sendmidi sox

# Install the /deck skill for Claude Code (user scope, all directories).
# Symlink, not copy: the skill in ~/.claude always reflects the repo, so schema
# or guard-rail updates load by default without a reinstall step.
skill:
	mkdir -p ~/.claude/skills
	rm -rf ~/.claude/skills/deck
	ln -sfn "$(CURDIR)/skills/deck" ~/.claude/skills/deck
	@echo "linked: ~/.claude/skills/deck → $(CURDIR)/skills/deck (repo edits are live)"

# GUI key mapper: click a control, press it on the OP-XY, assign an action, Save
# assets/opxy.svg is teenage engineering's panel artwork, bundled with the prebuilt
# opxy.pdf skin (removed immediately if TE objects). The PDF only regenerates when
# rsvg-convert (brew: librsvg) is present — cloners without it use the bundled PDF.
gui: opxy-mapper.app
	@if [ -f assets/opxy.svg ] && command -v rsvg-convert >/dev/null 2>&1; then \
	   python3 skinprep.py && \
	   rsvg-convert -f pdf -o assets/opxy.pdf assets/opxy-normalized.svg && \
	   echo "skin: opxy.svg → opxy.pdf"; fi
	pkill -x opxy-mapper 2>/dev/null || true
	sleep 0.3
	open opxy-mapper.app

# Build/sign only when sources actually changed. The app is ad-hoc signed, so every
# re-sign gives it a new cdhash — and macOS keys the Accessibility grant to that,
# silently dropping it while System Settings still shows the app ticked. Re-signing
# an unchanged tree would break GUI-launched bridges for no reason, so don't.
opxy-mapper: OpxyMapper.swift
	swiftc -O -parse-as-library OpxyMapper.swift -o opxy-mapper

# Signing: prefer the stable dev identity (make dev-cert) so the Accessibility
# grant survives rebuilds; fall back to ad-hoc, whose identity dies every rebuild.
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q opxy-deck-dev && echo opxy-deck-dev || echo -)

opxy-mapper.app: opxy-mapper Info.plist assets/AppIcon.icns
	rm -rf opxy-mapper.app
	mkdir -p opxy-mapper.app/Contents/MacOS opxy-mapper.app/Contents/Resources
	cp Info.plist opxy-mapper.app/Contents/Info.plist
	cp opxy-mapper opxy-mapper.app/Contents/MacOS/opxy-mapper
	cp assets/AppIcon.icns opxy-mapper.app/Contents/Resources/AppIcon.icns
	codesign -s "$(SIGN_ID)" --force opxy-mapper.app 2>/dev/null || codesign -s - --force opxy-mapper.app 2>/dev/null || true
ifeq ($(SIGN_ID),-)
	@echo ""
	@echo "  ⚠︎  ad-hoc re-sign → the app's Accessibility grant is now stale."
	@echo "      fix now:     make ax-reset, relaunch, click “Grant…”"
	@echo "      fix forever: make dev-cert   (stable identity; grant survives rebuilds)"
	@echo ""
else
	@echo "  signed with stable identity '$(SIGN_ID)' — Accessibility grant survives rebuilds"
endif

# One-time: create the stable self-signed signing identity (see dev-cert.sh)
dev-cert:
	./dev-cert.sh

# Clear the app's Accessibility entry so it can re-register cleanly.
# Needed because the app is ad-hoc signed: its code identity changes on every
# rebuild, and a stale entry keeps the app listed-but-refused — ticked in System
# Settings, silently denied at runtime, nothing logged. Reset, then relaunch and
# click "Grant…" in the app.
ax-reset:
	tccutil reset Accessibility dev.kaz.opxy-mapper || true
	@echo "cleared. now: make gui   → click “Grant…” in the banner → approve"

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

# Once per machine: herdr keybindings the deck profiles depend on (idempotent)
setup-herdr:
	@./setup-herdr.sh

# Full self-test with fake MIDI (no device needed): legacy + v1 schemas, primitives,
# --check validation, --capture, state round-trip, hot reload, --migrate
selftest: build
	./selftest.sh

.PHONY: build deps skill gui ax-reset dev-cert miditest list sniff learn dry run tmux check use profiles capture watch doctor setup-herdr selftest
