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

# Guided setup — press each pad / turn each knob when prompted; writes mapping.json
learn: build
	$(call pipe_midi,--learn mapping.json)

# Decode + print actions without sending keystrokes (safe test)
dry: build
	$(call pipe_midi,mapping.json --dry-run)

# The real thing: keystrokes to the frontmost app (needs Accessibility permission)
run: build
	$(call pipe_midi,mapping.json)

# Focus-free variant: inject into a tmux pane, e.g. `make tmux TARGET=claude`
tmux: build
	$(call pipe_midi,mapping.json --tmux "$(TARGET)")

# Audible agent status: chime when any herdr-managed agent blocks or finishes
watch:
	./herdr-watch.sh

# Parser self-test with fake MIDI (no device needed): buttons, absolute encoder both
# directions + rail repeat, record tap-tap
selftest: build
	printf 'channel 1 control-change 56 127\nchannel 1 control-change 56 0\nchannel 1 control-change 57 127\nchannel 1 control-change 57 0\nchannel 1 control-change 1 10\nchannel 1 control-change 1 11\nchannel 1 control-change 1 12\nchannel 1 control-change 1 11\nchannel 1 control-change 1 0\nchannel 1 control-change 1 0\nchannel 1 control-change 2 60\nchannel 1 control-change 2 61\nchannel 1 control-change 2 60\nchannel 1 control-change 55 127\nchannel 1 control-change 55 0\nchannel 1 control-change 55 127\n' | ./opxy-bridge mapping.json --dry-run

.PHONY: build gui miditest list sniff learn dry run tmux watch selftest
